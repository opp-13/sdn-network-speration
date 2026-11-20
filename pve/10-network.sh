#!/usr/bin/env bash
# P1: Proxmox 노드에 PoC 용 OVS 브리지 2개 추가 (노드 root 로 실행, 이 파일 하나로 완결)
#
#   vmbr11 : PoC 관리망. 노드 10.255.0.13/24, VXLAN key 300 → SDN01(10.10.0.1) br-mgmt
#   vmbr10 : Faucet 제어 엑세스 스위치. fail-mode secure, OpenFlow13, dpid 0x2,
#            컨트롤러 tcp:10.255.0.40:6653 (faucet-pve VM, P2), 트렁크 VXLAN key 110 → SDN01 br-sdn port 11 (ofport 10)
#
# 근거 (2026-11-20 확인):
#   - Proxmox wiki Open_vSwitch(2022-01): 설치는 apt install openvswitch-switch. 브리지 정의는 interfaces 파일 예시뿐,
#     OpenFlow 컨트롤러·fail-mode·VXLAN 설정은 다루지 않음. "OVS 와 Linux bridge/bond/vlan 을 섞지 말 것".
#   - pve-common PVE/Network.pm: OVS 브리지 판별은 `ovs-vsctl br-exists` (interfaces 파일 미참조) → ovs-vsctl 로만
#     만든 브리지도 VM NIC 연결 가능. firewall=1 이면 tap 과 OVS 사이에 Linux 브리지 fwbr 삽입(EAPOL 미전달),
#     VM 기동마다 del-port → add-port(ofport_request 미설정), tap MTU = 브리지 MTU.
# 기존 설정은 바꾸지 않는다:
#   - /etc/network/interfaces, interfaces.d/(sdn 포함) 수정 없음, ifreload 하지 않음
#   - 브리지는 ovs-vsctl 로만 생성(OVS DB 에 저장되어 재부팅 후에도 유지), IP 는 systemd 유닛
#   - 그래서 Proxmox GUI 의 브리지 목록에는 안 보인다 → VM 연결은 qm set --netN ...,bridge=vmbr10
# 추가로 하는 것 (각각 실행 전 확인):
#   - openvswitch-switch 설치
#   - Proxmox 호스트 방화벽: vmbr1 에서 SDN01 의 VXLAN(UDP 4789) 수신, vmbr11 관리망 ICMP 허용
#   - 저장소 local 에 snippets 용도 추가 (P3·P4 의 hookscript·cloud-init 용)
# 멱등: 여러 번 실행해도 같은 상태.
set -euo pipefail
SDN01_TUN=10.10.0.1; NODE_TUN=10.10.0.254
NODE_MGMT=10.255.0.13/24; FAUCET_PVE=10.255.0.40
NODE=$(hostname)
HOSTFW=/etc/pve/nodes/$NODE/host.fw

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date '+%T')" "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
confirm() {
  echo "===================================================="; echo "$1"; echo "$2" | sed 's/^/    /'
  echo "vmbr0·vmbr1·/etc/network/interfaces 는 변경하지 않습니다."; echo "===================================================="
  read -r -p "진행할까요? [y/N] " a; [[ "$a" == y || "$a" == Y ]] || die "취소"
}
[[ $EUID -eq 0 ]] || die "root 로 실행"
command -v pveversion >/dev/null || die "Proxmox 노드에서 실행"
ip -4 -o addr show vmbr1 | grep -q " $NODE_TUN/" || die "vmbr1 에 $NODE_TUN 이 없음"

# ---- 1. Open vSwitch ----
if ! command -v ovs-vsctl >/dev/null; then
  confirm "[1/4] openvswitch-switch 패키지 설치" "apt-get install -y openvswitch-switch"
  apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q openvswitch-switch
fi
systemctl enable --now openvswitch-switch >/dev/null
log "OVS $(ovs-vsctl --version | head -1 | awk '{print $NF}')"

# ---- 2. 브리지 ----
confirm "[2/4] OVS 브리지 vmbr10(Faucet 제어 스위치), vmbr11(PoC 관리망 $NODE_MGMT) 생성 + VXLAN 2개 (→ $SDN01_TUN)" \
"ovs-vsctl --may-exist add-br vmbr11
ovs-vsctl --may-exist add-port vmbr11 vx-mgmt -- set interface vx-mgmt type=vxlan options:local_ip=$NODE_TUN options:remote_ip=$SDN01_TUN options:key=300
ovs-vsctl --may-exist add-br vmbr10 -- set bridge vmbr10 protocols=OpenFlow13 other-config:datapath-id=0000000000000002 other-config:disable-in-band=true -- set-fail-mode vmbr10 secure
ovs-vsctl --may-exist add-port vmbr10 vx-trunk -- set interface vx-trunk type=vxlan options:local_ip=$NODE_TUN options:remote_ip=$SDN01_TUN options:key=110 ofport_request=10
ovs-vsctl set-controller vmbr10 tcp:$FAUCET_PVE:6653
ovs-vsctl set interface vmbr10 mtu_request=1500 -- set interface vmbr11 mtu_request=1500
systemd 유닛 poc-pve-net: vmbr11 에 $NODE_MGMT, vmbr10 내부 포트는 IP 없이 down"

ovs-vsctl --may-exist add-br vmbr11
ovs-vsctl --may-exist add-port vmbr11 vx-mgmt \
  -- set interface vx-mgmt type=vxlan options:local_ip=$NODE_TUN options:remote_ip=$SDN01_TUN options:key=300
ovs-vsctl --may-exist add-br vmbr10 \
  -- set bridge vmbr10 protocols=OpenFlow13 \
  -- set bridge vmbr10 other-config:datapath-id=0000000000000002 other-config:disable-in-band=true \
  -- set-fail-mode vmbr10 secure
ovs-vsctl --may-exist add-port vmbr10 vx-trunk \
  -- set interface vx-trunk type=vxlan options:local_ip=$NODE_TUN options:remote_ip=$SDN01_TUN options:key=110 ofport_request=10
ovs-vsctl set-controller vmbr10 "tcp:$FAUCET_PVE:6653"
# Proxmox 는 VM tap 을 붙일 때 브리지 MTU(/sys/class/net/<브리지>/mtu)를 그대로 쓴다 (PVE/Network.pm read_bridge_mtu)
ovs-vsctl set interface vmbr10 mtu_request=1500 -- set interface vmbr11 mtu_request=1500

cat > /etc/systemd/system/poc-pve-net.service <<EOF
[Unit]
Description=PoC: vmbr11 관리망 IP, vmbr10 내부 포트 down
After=openvswitch-switch.service network-online.target
Wants=openvswitch-switch.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ip link set vmbr11 mtu 1500 up
ExecStart=/usr/sbin/ip addr replace $NODE_MGMT dev vmbr11
ExecStart=/usr/sbin/ip link set vmbr10 down

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable poc-pve-net >/dev/null; systemctl restart poc-pve-net

# ---- 3. Proxmox 호스트 방화벽 ----
RULES="IN ACCEPT -i vmbr1 -source $SDN01_TUN -p udp -dport 4789 # PoC VXLAN from SDN01
IN ACCEPT -i vmbr11 -source 10.255.0.0/24 -p icmp # PoC mgmt ping"
if ! grep -q 'PoC VXLAN from SDN01' "$HOSTFW" 2>/dev/null; then
  echo "현재 $HOSTFW:"; sed 's/^/    | /' "$HOSTFW" 2>/dev/null || echo "    (없음)"
  confirm "[3/4] Proxmox 호스트 방화벽에 규칙 2줄 추가 (백업: $HOSTFW.poc-bak)" "$RULES"
  [[ -f "$HOSTFW" ]] && cp "$HOSTFW" "$HOSTFW.poc-bak" || true
  if [[ -f "$HOSTFW" ]] && grep -q '^\[RULES\]' "$HOSTFW"; then
    awk -v r="$RULES" '{print} /^\[RULES\]/{print r}' "$HOSTFW" > /tmp/host.fw.new
  else
    { cat "$HOSTFW" 2>/dev/null; printf '\n[RULES]\n%s\n' "$RULES"; } > /tmp/host.fw.new
  fi
  cp /tmp/host.fw.new "$HOSTFW"; rm -f /tmp/host.fw.new
  pve-firewall compile >/dev/null 2>&1 || die "pve-firewall compile 실패 — $HOSTFW.poc-bak 로 복구"
  sleep 12   # pve-firewall 이 변경을 반영하는 주기 (10초)
fi

# ---- 4. snippets 저장소 ----
content=$(awk '/^[a-z]+: /{blk=($0=="dir: local")} blk && $1=="content"{print $2}' /etc/pve/storage.cfg)
[[ -n "$content" ]] || die "storage.cfg 에서 local 저장소 content 를 찾지 못함"
if [[ ",$content," != *",snippets,"* ]]; then
  confirm "[4/4] 저장소 local 에 snippets 용도 추가 (hookscript·cloud-init 파일 저장용, /var/lib/vz/snippets)" \
    "pvesm set local --content $content,snippets"
  pvesm set local --content "$content,snippets"
fi
mkdir -p /var/lib/vz/snippets

log "결과"
ovs-vsctl show
ip -br addr show vmbr11
echo "vmbr10 fail-mode: $(ovs-vsctl get-fail-mode vmbr10)  controller: $(ovs-vsctl get-controller vmbr10)"
echo "다음: SDN01 에서 sudo host-a/60-pve-uplink.sh → 노드에서 bash 11-check.sh"
