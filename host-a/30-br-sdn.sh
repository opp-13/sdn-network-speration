#!/usr/bin/env bash
# host-a Phase 1: Faucet 제어 브리지 br-sdn (secure, dpid 0x1). 컨트롤러 지정은 Phase 3.
#   single: port 10 = fw VM의 트렁크 NIC(vt-fw1)가 직접 붙는다 (vm/define.sh). VXLAN 없음.
#           fw 외부 출구용 libvirt default NAT 도 이 호스트에서 활성화.
#   dual  : port 10 = vx-trunk (VXLAN key 100 → host-b br-trunk)
source "$(dirname "$0")/../hosts/lib.sh"
need_root
require_role a

if is_single; then
  confirm "host-a(단일 구성) 에 OVS 브리지 br-sdn (fail-mode secure, dpid 0x1, OpenFlow13). 이전 2호스트용 vx-trunk 가 있으면 제거. libvirt 'default' NAT(192.168.122.0/24) 자동 시작" \
"ovs-vsctl --may-exist add-br br-sdn -- set bridge br-sdn other-config:datapath-id=0000000000000001 protocols=OpenFlow13 -- set-fail-mode br-sdn secure
ovs-vsctl --if-exists del-port br-sdn vx-trunk
virsh net-autostart default; virsh net-start default"
else
  confirm "host-a 에 OVS 브리지 br-sdn (fail-mode secure, dpid 0x1, OpenFlow13) 과 vx-trunk(VXLAN key 100 → $HOST_B_TUN_IP, ofport 10) 생성" \
"ovs-vsctl --may-exist add-br br-sdn -- set bridge br-sdn other-config:datapath-id=0000000000000001 protocols=OpenFlow13 -- set-fail-mode br-sdn secure
ovs-vsctl --may-exist add-port br-sdn vx-trunk -- set interface vx-trunk type=vxlan options:local_ip=$HOST_A_TUN_IP options:remote_ip=$HOST_B_TUN_IP options:key=100 ofport_request=10"
fi

ovs-vsctl --may-exist add-br br-sdn \
  -- set bridge br-sdn other-config:datapath-id=0000000000000001 \
  -- set bridge br-sdn protocols=OpenFlow13 \
  -- set-fail-mode br-sdn secure
if is_single; then
  ovs-vsctl --if-exists del-port br-sdn vx-trunk
  virsh net-info default >/dev/null 2>&1 || die "libvirt default 네트워크 없음"
  virsh net-autostart default >/dev/null
  [[ "$(virsh net-info default | awk '/^Active/{print $2}')" == yes ]] || virsh net-start default
else
  ovs-vsctl --may-exist add-port br-sdn vx-trunk \
    -- set interface vx-trunk type=vxlan \
       options:local_ip="$HOST_A_TUN_IP" options:remote_ip="$HOST_B_TUN_IP" options:key=100 \
       ofport_request=10
fi
# br-sdn 자체 내부 포트는 IP 없이 내려 둔다 (사용자 트래픽이 호스트로 새지 않게)
ip link set br-sdn down

log "결과"
echo "fail-mode: $(ovs-vsctl get-fail-mode br-sdn)"
ovs-ofctl -O OpenFlow13 show br-sdn | grep -E '^\s*[0-9]+\(' || echo "(포트 없음 — VM 생성 후 붙음)"
is_single && virsh net-list --all
true
