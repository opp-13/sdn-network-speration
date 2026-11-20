#!/usr/bin/env bash
# Phase 2-1: 기본 클라우드 이미지 다운로드 + 역할별 이미지 굽기 (호스트에서)
#
# 단말·faucet-ctl·radius VM은 인터넷이 없다. 그래서 필요한 패키지를 미리 이미지에 넣는다.
# 방법: 역할 이미지를 임시 VM으로 libvirt default NAT 에 붙여 한 번 부팅 →
#       cloud-init 이 패키지 설치·역할 스크립트 실행 후 스스로 전원 끔 →
#       네트워크가 필요 없는 마무리(설정 파일 넣기, cloud-init 초기화)는 virt-customize --no-network.
#   (virt-customize 의 내장 네트워크는 이 환경에서 동작하지 않아 이 방식을 씀 — docs/LOG.md)
# 결과: /var/lib/libvirt/images/poc/role-<역할>.qcow2  (이미 있으면 건너뜀)
# 사용: sudo vm/images.sh [--rebuild term|faucet|radius|fw]
source "$(dirname "$0")/../hosts/lib.sh"
source "$(dirname "$0")/vms.sh"
need_root
export LIBGUESTFS_BACKEND=direct
role_host=$(my_role); [[ "$role_host" == a || "$role_host" == b ]] || die "호스트 판정 실패"
REBUILD=""; [[ "${1:-}" == --rebuild ]] && REBUILD=${2:?역할}
mkdir -p "$POC_IMG_DIR"; cd "$POC_IMG_DIR"
F="$POC_REPO/vm/files"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

log "기본 이미지: $BASE_IMG"
if [[ ! -f "$BASE_IMG" ]]; then
  curl -fL --retry 3 -o "$BASE_IMG.part" "$BASE_URL/$BASE_IMG"
  curl -fsL "$BASE_URL/SHA256SUMS" -o SHA256SUMS
  want=$(awk -v f="*$BASE_IMG" '$2==f || $2==substr(f,2){print $1}' SHA256SUMS)
  got=$(sha256sum "$BASE_IMG.part" | awk '{print $1}')
  [[ -n "$want" && "$want" == "$got" ]] || die "SHA256 불일치 (기대 $want, 실제 $got)"
  mv "$BASE_IMG.part" "$BASE_IMG"
fi
echo "OK $(qemu-img info "$BASE_IMG" | grep -E 'virtual size')"
[[ "$(virsh net-info default 2>/dev/null | awk '/^Active/{print $2}')" == yes ]] \
  || die "libvirt default NAT 비활성: 먼저 sudo host-a/30-br-sdn.sh"

# bake <역할> "<패키지 공백구분>" <역할 스크립트 파일|-> [virt-customize 마무리 옵션...]
bake() {
  local role=$1 pkgs=$2 script=$3; shift 3
  local out="role-$role.qcow2" tmp="role-$role.qcow2.tmp" dom="poc-bake-$role" d="$POC_IMG_DIR/bake-$role"
  # seed ISO는 libvirt-qemu 사용자가 읽을 수 있는 이미지 디렉터리에 둔다 (/tmp 는 권한 문제)
  if [[ -f "$out" && "$REBUILD" != "$role" ]]; then echo "건너뜀: $out (이미 있음)"; return; fi
  log "[$role] 디스크 준비 (원본 복사 + 크기 확장, 파티션은 첫 부팅 때 cloud-init이 늘림)"
  virsh destroy "$dom" &>/dev/null || true; virsh undefine "$dom" &>/dev/null || true
  rm -f "$tmp"; mkdir -p "$d"
  qemu-img convert -q -O qcow2 "$BASE_IMG" "$tmp"
  qemu-img resize -q "$tmp" "$ROLE_DISK_SIZE"

  # 임시 VM용 cloud-init: 패키지 설치 → 역할 스크립트 → 성공 표시 → 전원 끔
  {
    echo "#cloud-config"
    echo "package_update: true"
    echo "packages: [qemu-guest-agent$(for p in $pkgs; do printf ', %s' "$p"; done)]"
    echo "write_files:"
    echo "  - path: /root/poc-bake.sh"
    echo "    permissions: '0755'"
    echo "    encoding: b64"
    echo "    content: $( { echo 'set -euxo pipefail'; echo "dpkg -s qemu-guest-agent $pkgs >/dev/null"; [[ "$script" != - ]] && cat "$script"; true; } | base64 -w0)"
    echo "runcmd:"
    echo "  - [bash, -c, 'bash /root/poc-bake.sh > /var/log/poc-bake.log 2>&1 && touch /var/lib/poc-bake-ok']"
    echo "power_state: {mode: poweroff, delay: now, timeout: 1800, condition: true}"
  } > "$d/user-data"
  printf 'instance-id: bake-%s-%s\nlocal-hostname: bake-%s\n' "$role" "$(date +%s)" "$role" > "$d/meta-data"
  printf 'version: 2\nethernets:\n  any:\n    match: {name: "en*"}\n    dhcp4: true\n' > "$d/network-config"
  cloud-localds -N "$d/network-config" "$d/seed.iso" "$d/user-data" "$d/meta-data"

  log "[$role] 임시 VM 부팅 → 패키지 설치 (libvirt NAT, 완료되면 자동 종료, 최대 20분). 진행 상황: sudo tail -f $d/console.log"
  local t0=$SECONDS
  virt-install --name "$dom" --memory 2048 --vcpus 2 --cpu host-passthrough \
    --import --osinfo ubuntu24.04 \
    --disk "path=$POC_IMG_DIR/$tmp,format=qcow2,bus=virtio" --disk "path=$d/seed.iso,device=cdrom" \
    --network network=default,model.type=virtio \
    --graphics none --serial "file,path=$d/console.log" \
    --noautoconsole --wait 20 >/dev/null || echo "virt-install 종료 코드 $?"
  echo "임시 VM 실행 시간: $(( (SECONDS-t0)/60 ))분 $(( (SECONDS-t0)%60 ))초"
  virsh destroy "$dom" &>/dev/null || true
  virsh undefine "$dom" &>/dev/null || true

  if ! virt-cat -a "$tmp" /var/lib/poc-bake-ok &>/dev/null; then
    echo "---- /var/log/poc-bake.log (마지막 30줄) ----"
    virt-cat -a "$tmp" /var/log/poc-bake.log 2>/dev/null | tail -30 || echo "(없음)"
    echo "---- cloud-init-output.log (마지막 30줄) ----"
    virt-cat -a "$tmp" /var/log/cloud-init-output.log 2>/dev/null | tail -30 || echo "(없음)"
    echo "---- 임시 VM 화면(시리얼 콘솔) 마지막 40줄: $d/console.log ----"
    tail -40 "$d/console.log" 2>/dev/null | tr -d '\r' || true
    [[ -s "$d/console.log" ]] || echo "(콘솔 출력 없음 → 부트로더/커널 단계에서 멈춤)"
    echo "---- libvirt QEMU 로그 마지막 15줄 ----"
    tail -15 "/var/log/libvirt/qemu/$dom.log" 2>/dev/null || true
    die "[$role] 굽기 실패 — 위 로그 확인 (디스크 $tmp 는 남겨 둠)"
  fi

  log "[$role] 마무리 (네트워크 없이): 설정 넣기, cloud-init 초기화"
  virt-customize -q --no-network -a "$tmp" \
    "$@" \
    --run-command 'systemctl enable qemu-guest-agent || true' \
    --run-command 'rm -f /etc/netplan/50-cloud-init.yaml /var/lib/poc-bake-ok /root/poc-bake.sh' \
    --run-command 'cloud-init clean --logs --seed' \
    --truncate /etc/machine-id
  mv "$tmp" "$out"; rm -rf "$d"
  echo "완료: $out ($(du -h "$out" | cut -f1))"
}

# 이 호스트에 필요한 역할 (single 구성이면 host-a 가 4개 역할 모두)
ROLES=$(for v in $(vms_on_host "$role_host" | tr ' ' '#'); do vm_field "${v//#/ }" 3; done | sort -u | tr '\n' ' ')
log "이 호스트에서 구울 역할: $ROLES"
need() { [[ " $ROLES " == *" $1 "* ]]; }

if need term; then
  # 단말 공통: 802.1X supplicant, DHCP 클라이언트, 시험 도구. SSH는 끔(단말 접근은 콘솔·게스트 에이전트로만)
  cat > "$WORK/term.sh" <<'EOF'
systemctl disable ssh.service ssh.socket || true
mkdir -p /etc/poc/pki
EOF
  bake term "wpasupplicant isc-dhcp-client curl dnsutils tcpdump iputils-ping" "$WORK/term.sh"
fi

if need faucet; then
  # Faucet: lite 모드에서 검증한 1.10.12 고정
  cat > "$WORK/faucet.sh" <<'EOF'
python3 -m venv /opt/faucet
/opt/faucet/bin/pip install --no-cache-dir faucet==1.10.12
mkdir -p /etc/faucet /var/log/faucet
/opt/faucet/bin/pip show faucet | grep ^Version > /etc/faucet/VERSION
EOF
  bake faucet "python3-venv python3-dev gcc tcpdump" "$WORK/faucet.sh" \
    --upload "$POC_REPO/faucet/faucet.static.yaml:/etc/faucet/faucet.yaml" \
    --upload "$F/faucet.service:/etc/systemd/system/faucet.service" \
    --run-command 'systemctl enable faucet.service'
fi

if need radius; then
  # RADIUS: 설정은 Phase 5에서 배포
  bake radius "freeradius freeradius-utils eapoltest tcpdump" -
fi

if need fw; then
  # 경계 방화벽: 첫 부팅부터 nftables 정책(기본 drop) 적용 → 정책 없는 순간이 없게
  cp "$POC_REPO/firewall/dnsmasq-biz.conf" "$WORK/"
  { cat "$POC_REPO/firewall/dnsmasq-inet.conf"; echo "server=1.1.1.1"; } > "$WORK/dnsmasq-inet.conf"
  bake fw "nftables dnsmasq-base tcpdump" - \
    --mkdir /etc/poc \
    --upload "$POC_REPO/firewall/nftables.conf:/etc/nftables.conf" \
    --upload "$WORK/dnsmasq-biz.conf:/etc/poc/dnsmasq-biz.conf" \
    --upload "$WORK/dnsmasq-inet.conf:/etc/poc/dnsmasq-inet.conf" \
    --upload "$F/poc-dnsmasq@.service:/etc/systemd/system/poc-dnsmasq@.service" \
    --write '/etc/sysctl.d/90-poc-fw.conf:net.ipv4.ip_forward=1' \
    --run-command 'systemctl enable nftables.service poc-dnsmasq@biz.service poc-dnsmasq@inet.service'
fi

log "결과"; ls -lh "$POC_IMG_DIR"
fix_owner
