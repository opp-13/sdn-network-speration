#!/usr/bin/env bash
# Phase 1 완료 조건 검사 (읽기 전용). single: SDN01 에서만, dual: host-a·host-b 각각
# 결과: 화면 + tests/out/phase1-host-<a|b>.txt
source "$(dirname "$0")/lib.sh"
need_root
set +e
role=$(my_role)
exec > >(tee "$OUTD/phase1-host-$role.txt") 2>&1
trap fix_owner EXIT
echo "### Phase 1 검사 host-$role ($POC_TOPOLOGY) $(date '+%F %T')"

case "$role" in
  a) TUN_NIC=$HOST_A_TUN_NIC; PEER=$HOST_B_MGMT_OVL_IP; ME=$HOST_A_MGMT_OVL_IP ;;
  b) TUN_NIC=$HOST_B_TUN_NIC; PEER=$HOST_A_MGMT_OVL_IP; ME=$HOST_B_MGMT_OVL_IP ;;
  *) echo "FAIL  역할 판정 실패"; exit 1 ;;
esac

res "$(try kvm-ok)" ok "KVM 가속 사용 가능 (중첩 가상화)"
res "$(ip -4 -o addr show br-mgmt | grep -c " $ME/24")" 1 "br-mgmt 주소 $ME/24"
if [[ $role == a ]]; then
  res "$(ovs-vsctl get-fail-mode br-sdn 2>/dev/null)" secure "br-sdn fail-mode secure"
  res "$(ovs-vsctl get bridge br-sdn other-config:datapath-id 2>/dev/null | tr -d '"')" 0000000000000001 "br-sdn dpid 0x1"
fi

if is_single; then
  res "$(ovs-vsctl list-ports br-mgmt | grep '^vx-' | grep -vc '^vx-pve')" 0 "br-mgmt 에 2호스트용 VXLAN 포트 없음 (단일 구성, Proxmox 연결 vx-pve 제외)"
  res "$(ovs-vsctl list-ports br-sdn | grep '^vx-' | grep -vc '^vx-pve')" 0 "br-sdn 에 2호스트용 VXLAN 포트 없음 (port 10 은 fw VM 자리, Proxmox 트렁크 vx-pve-trunk 제외)"
  res "$(virsh net-info default 2>/dev/null | awk '/^Active/{print $2}')" yes "libvirt default NAT 활성 (fw 외부 출구)"
  res "$(virsh net-info default 2>/dev/null | awk '/^Autostart/{print $2}')" yes "libvirt default NAT 자동 시작"
  echo "관찰  메모리 $(free -m | awk '/Mem/{print $2}')MB, 디스크 여유 $(df -h /var/lib/libvirt | awk 'NR==2{print $4}')"
else
  res "$(cat /sys/class/net/$TUN_NIC/mtu 2>/dev/null)" 1550 "터널 NIC $TUN_NIC MTU 1550"
  res "$(ovs-vsctl get interface vx-mgmt options:key 2>/dev/null | tr -d '"')" 300 "vx-mgmt VXLAN key 300"
  res "$(try ping -c3 -W2 "$PEER")" ok "관리 오버레이 ping $ME → $PEER"
  res "$(try ping -M do -s 1472 -c3 -W2 "$PEER")" ok "VXLAN 위로 1500바이트 프레임 통과 (단편화 없음)"
  if [[ $role == a ]]; then
    res "$(ovs-vsctl get interface vx-trunk ofport)" 10 "vx-trunk = br-sdn port 10"
    res "$(ovs-vsctl get interface vx-trunk options:key | tr -d '"')" 100 "vx-trunk VXLAN key 100"
  else
    res "$(ovs-vsctl get interface vx-trunk options:key 2>/dev/null | tr -d '"')" 100 "br-trunk vx-trunk VXLAN key 100"
    res "$(virsh net-info default 2>/dev/null | awk '/^Active/{print $2}')" yes "libvirt default NAT 활성 (fw 외부 출구)"
  fi
fi

echo; ovs-vsctl show
summary
