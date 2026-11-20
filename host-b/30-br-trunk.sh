#!/usr/bin/env bash
# host-b Phase 1: 방화벽 쪽 트렁크 br-trunk(일반 OVS) + VXLAN key 100, fw 외부 출구용 libvirt default NAT.
source "$(dirname "$0")/../hosts/lib.sh"
need_root
require_role b

confirm "host-b 에 OVS 브리지 br-trunk + vx-trunk(VXLAN key 100 → $HOST_A_TUN_IP), libvirt 'default' NAT 네트워크(192.168.122.0/24) 자동 시작" \
"ovs-vsctl --may-exist add-br br-trunk
ovs-vsctl --may-exist add-port br-trunk vx-trunk -- set interface vx-trunk type=vxlan options:local_ip=$HOST_B_TUN_IP options:remote_ip=$HOST_A_TUN_IP options:key=100
virsh net-autostart default; virsh net-start default"

ovs-vsctl --may-exist add-br br-trunk
ovs-vsctl --may-exist add-port br-trunk vx-trunk \
  -- set interface vx-trunk type=vxlan \
     options:local_ip="$HOST_B_TUN_IP" options:remote_ip="$HOST_A_TUN_IP" options:key=100
ip link set br-trunk down   # 트렁크 브리지 내부 포트도 IP 없이

virsh net-info default >/dev/null 2>&1 || die "libvirt default 네트워크 없음"
virsh net-autostart default >/dev/null
[[ "$(virsh net-info default | awk '/^Active/{print $2}')" == yes ]] || virsh net-start default

log "결과"
ovs-vsctl show | sed -n '/Bridge br-trunk/,/Bridge [^t]/p' | head -10
virsh net-list --all
