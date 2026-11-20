#!/usr/bin/env bash
# Phase 2-2: 이 호스트의 안쪽 VM 만들기·기동 (vm/vms.sh 표 기준)
#   ① 역할 이미지 위에 VM별 오버레이 디스크
#   ② 단말: 인증서·supplicant 설정을 디스크에 넣음 (네트워크 없이)
#   ③ cloud-init seed (계정, NIC 이름 고정 eth0/eth1/eth2, 주소)
#   ④ virt-install (OVS 브리지 직접 연결, tap 이름 고정, 게스트 에이전트 채널)
#   ⑤ br-sdn 포트 번호 고정 (libvirt hook 으로 재기동 때도 유지)
# 사용: sudo vm/define.sh                 # 없는 VM만 생성
#       sudo vm/define.sh --recreate <VM>  # 그 VM을 지우고 다시 (all = 이 호스트 전체)
source "$(dirname "$0")/../hosts/lib.sh"
source "$(dirname "$0")/vms.sh"
need_root
export LIBGUESTFS_BACKEND=direct
H=$(my_role); [[ "$H" == a || "$H" == b ]] || die "호스트 판정 실패"
RECREATE=""; [[ "${1:-}" == --recreate ]] && RECREATE=${2:?VM 이름 또는 all}
cd "$POC_IMG_DIR" || die "$POC_IMG_DIR 없음: 먼저 sudo vm/images.sh"

# 인프라 VM(faucet-ctl, radius, fw) SSH용 호스트 root 키 — 관리망(10.255.0.0/24)으로만 접근
KEY=/root/.ssh/poc_ed25519
[[ -f $KEY ]] || ssh-keygen -q -t ed25519 -N '' -C "poc-host-$H" -f $KEY
PUBKEY=$(cat $KEY.pub)
[[ -s "$POC_REPO/secrets/vm_password" ]] || die "secrets/vm_password 없음 (노트북에서 tools/push.sh)"
PWHASH=$(openssl passwd -6 "$(cat "$POC_REPO/secrets/vm_password")")

# systemd-networkd 가 VM tap 을 건드리지 못하게 한다.
# Ubuntu 24.04 기본 규칙 80-vm-vt.network 는 vt-* 이름의 tap 에 주소·DHCP 서버·NAT·IPv6 RA 를 설정한다.
# 그러면 호스트가 OVS/Faucet 을 거치지 않고 단말 VM 에 직접 패킷을 보낼 수 있다 (원칙 2·3 위반).
# → tap 이름은 tp-* 로 쓰고, tp-*/vt-* 모두 networkd 관리 대상에서 제외.
nwf=/etc/systemd/network/10-poc-taps.network
new=$(mktemp)
printf '%s\n' '# PoC (vm/define.sh): VM tap 은 networkd 가 관리하지 않음 — docs/LOG.md 참고' \
  '[Match]' 'Name=tp-* vt-*' '' '[Link]' 'Unmanaged=yes' > "$new"
if ! cmp -s "$new" "$nwf" 2>/dev/null; then
  install -m 644 "$new" "$nwf"; networkctl reload; log "systemd-networkd: tp-*/vt-* tap 관리 제외 규칙 설치"
fi
rm -f "$new"

# br-sdn 포트 번호를 VM 재기동 때도 유지하는 libvirt hook (host-a)
if [[ $H == a ]]; then
  hook=/etc/libvirt/hooks/qemu
  new=$(mktemp)
  {
    echo '#!/bin/bash'
    echo '# PoC: br-sdn 포트 번호 고정 (vm/define.sh가 생성)'
    echo '[[ "$2" == started ]] || exit 0'
    for v in "${VMS[@]}"; do
      for nic in $(vm_field "$v" 6); do
        IFS=, read -r _ tgt _ tap ofp _ <<<"$nic"
        if [[ "$tgt" == br-sdn && "$ofp" != - ]]; then
          echo "ovs-vsctl --timeout=5 list-ifaces br-sdn 2>/dev/null | grep -qx $tap && ovs-vsctl --timeout=5 set interface $tap ofport_request=$ofp"
        fi
      done
    done
    echo 'exit 0'
  } > "$new"
  if ! cmp -s "$new" "$hook" 2>/dev/null; then
    mkdir -p /etc/libvirt/hooks; install -m 755 "$new" "$hook"
    systemctl restart libvirtd; log "libvirt hook 설치 (포트 번호 고정)"
  fi
  rm -f "$new"
fi

netcfg() { # netcfg <NIC 목록> → netplan v2 (cloud-init network-config)
  local i=0 nic kind tgt mac tap ofp addr
  echo "version: 2"; echo "ethernets:"
  for nic in $1; do
    IFS=, read -r kind tgt mac tap ofp addr <<<"$nic"
    echo "  eth$i:"
    echo "    match: {macaddress: \"$mac\"}"
    echo "    set-name: eth$i"
    echo "    mtu: $VM_MTU"
    echo "    accept-ra: false"
    case "$addr" in
      dhcp) echo "    dhcp4: true"; echo "    dhcp4-overrides: {use-dns: true}" ;;
      -)    echo "    dhcp4: false"; echo "    link-local: []"; echo "    optional: true" ;;
      *)    echo "    dhcp4: false"; echo "    link-local: []"; echo "    addresses: [$addr]" ;;
    esac
    i=$((i+1))
  done
  if [[ "$1" == *tp-fw1* ]]; then   # fw: VLAN 서브인터페이스 (eth1 = 트렁크)
    echo "vlans:"
    echo "  eth1.100: {id: 100, link: eth1, addresses: [10.100.0.1/24], link-local: []}"
    echo "  eth1.200: {id: 200, link: eth1, addresses: [10.200.0.1/24], link-local: []}"
  fi
}

userdata() { # userdata <이름> <역할>
  cat <<EOF
#cloud-config
hostname: $1
users:
  - name: poc
    groups: [sudo]
    shell: /bin/bash
    lock_passwd: false
    passwd: "$PWHASH"
    sudo: "ALL=(ALL) NOPASSWD:ALL"
EOF
  if [[ "$2" != term ]]; then echo "    ssh_authorized_keys: [\"$PUBKEY\"]"; fi
  echo "ssh_pwauth: false"
  echo "package_update: false"
  echo "runcmd:"
  echo "  - [systemctl, start, qemu-guest-agent]"
}

term_files() { # term_files <VM 이름> <오버레이> : 인증서·supplicant 설정 넣기
  local name=$1 disk=$2 pair id cert args=() tmp
  tmp=$(mktemp -d)
  args+=(--upload "$POC_REPO/pki/certs/ca.pem:/etc/poc/pki/ca.pem")
  for pair in ${TERM_CERTS[$name]}; do
    id=${pair%%:*}; cert=${pair#*:}
    args+=(--upload "$POC_REPO/pki/certs/$cert.pem:/etc/poc/pki/$cert.pem"
           --upload "$POC_REPO/pki/private/$cert.key:/etc/poc/pki/$cert.key")
    { echo "ctrl_interface=/run/wpa_supplicant"; echo "ap_scan=0"
      "$POC_REPO/supplicant/render.sh" "$id" "$cert" "$cert" /etc/poc/pki \
        | sed 's#/etc/poc/pki/certs/#/etc/poc/pki/#; s#/etc/poc/pki/private/#/etc/poc/pki/#'
    } > "$tmp/wired-$cert.conf"
    args+=(--upload "$tmp/wired-$cert.conf:/etc/poc/wired-$cert.conf")
  done
  virt-customize -q --no-network -a "$disk" "${args[@]}" \
    --run-command 'chmod 600 /etc/poc/pki/*.key /etc/poc/*.conf'
  rm -rf "$tmp"
}

for v in $(vms_on_host "$H" | tr ' ' '#'); do
  v=${v//#/ }
  name=$(vm_field "$v" 1); role=$(vm_field "$v" 3); mem=$(vm_field "$v" 4); cpu=$(vm_field "$v" 5); nics=$(vm_field "$v" 6)
  disk="$POC_IMG_DIR/$name.qcow2"; seed="$POC_IMG_DIR/$name-seed.iso"

  if virsh dominfo "$name" &>/dev/null; then
    if [[ "$RECREATE" == "$name" || "$RECREATE" == all ]]; then
      log "$name 삭제 후 재생성"
      virsh destroy "$name" &>/dev/null || true
      virsh undefine "$name" --nvram &>/dev/null || virsh undefine "$name"
      rm -f "$disk" "$seed"
    else
      echo "건너뜀: $name (이미 있음)"; continue
    fi
  fi
  [[ -f "$POC_IMG_DIR/role-$role.qcow2" ]] || die "role-$role.qcow2 없음: 먼저 sudo vm/images.sh"

  # 새로 만드는 VM 은 SSH 호스트 키가 바뀌므로 PoC known_hosts 에서 옛 키 제거
  for nic in $nics; do
    IFS=, read -r kind tgt mac tap ofp addr <<<"$nic"
    if [[ "$tgt" == br-mgmt && "$addr" == */* ]]; then
      ssh-keygen -q -f "$POC_KNOWN" -R "${addr%/*}" &>/dev/null || true
      ssh-keygen -q -f /root/.ssh/known_hosts -R "${addr%/*}" &>/dev/null || true
    fi
  done

  log "$name: 디스크·cloud-init"
  qemu-img create -q -f qcow2 -F qcow2 -b "$POC_IMG_DIR/role-$role.qcow2" "$disk" "$VM_DISK_SIZE"
  if [[ $role == term ]]; then term_files "$name" "$disk"; fi
  tmp=$(mktemp -d)
  userdata "$name" "$role" > "$tmp/user-data"
  printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "$name" "$(date +%s)" "$name" > "$tmp/meta-data"
  netcfg "$nics" > "$tmp/network-config"
  cloud-localds -N "$tmp/network-config" "$seed" "$tmp/user-data" "$tmp/meta-data"
  rm -rf "$tmp"

  netargs=()
  for nic in $nics; do
    IFS=, read -r kind tgt mac tap ofp addr <<<"$nic"
    if [[ $kind == ovs ]]; then
      netargs+=(--network "bridge=$tgt,virtualport.type=openvswitch,model.type=virtio,mac.address=$mac,target.dev=$tap,mtu.size=$VM_MTU")
    else
      netargs+=(--network "network=$tgt,model.type=virtio,mac.address=$mac,target.dev=$tap")
    fi
  done

  log "$name: virt-install (${mem}MB, ${cpu} vCPU, NIC $(wc -w <<<"$nics")개)"
  virt-install --name "$name" --memory "$mem" --vcpus "$cpu" --cpu host-passthrough \
    --import --osinfo ubuntu24.04 \
    --disk "path=$disk,format=qcow2,bus=virtio" --disk "path=$seed,device=cdrom" \
    "${netargs[@]}" \
    --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
    --graphics none --console pty,target.type=serial \
    --autostart --noautoconsole >/dev/null

  # 포트 번호 고정 (hook 외에 즉시 한 번 더)
  for nic in $nics; do
    IFS=, read -r kind tgt mac tap ofp addr <<<"$nic"
    if [[ "$ofp" != - ]]; then ovs-vsctl set interface "$tap" ofport_request="$ofp"; fi
  done
done

log "결과"
virsh list --all
[[ $H == a ]] && ovs-ofctl -O OpenFlow13 show br-sdn | grep -E '^\s*[0-9]+\(' || true
echo "콘솔 접속: sudo virsh console <VM>  (계정 poc / 비밀번호: secrets/vm_password, 빠져나오기 Ctrl+])"
