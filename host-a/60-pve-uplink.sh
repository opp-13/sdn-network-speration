#!/usr/bin/env bash
# P1 (SDN01 쪽): Proxmox 노드(10.10.0.254)와의 연결 — docs/PVE-PLAN.md
#   br-mgmt  + vx-pve       (VXLAN key 300) : 노드 vmbr11 과 관리망 공유 (faucet-pve 10.255.0.40, 노드 10.255.0.13)
#   br-sdn   + vx-pve-trunk (VXLAN key 110, ofport 11) : 노드 vmbr10 트렁크 → (Faucet dp1 port 11) → port 10 fw
#   port 11 은 P2 에서 Faucet dp1 설정(tagged biz, inet)에 추가하기 전까지는 Faucet 이 모르는 포트라 전부 버려진다.
source "$(dirname "$0")/../hosts/lib.sh"
need_root
require_role a
PVE_TUN=10.10.0.254

confirm "SDN01 에 Proxmox 노드($PVE_TUN) 연결용 VXLAN 2개 추가" \
"ovs-vsctl --may-exist add-port br-mgmt vx-pve -- set interface vx-pve type=vxlan options:local_ip=$HOST_A_TUN_IP options:remote_ip=$PVE_TUN options:key=300
ovs-vsctl --may-exist add-port br-sdn vx-pve-trunk -- set interface vx-pve-trunk type=vxlan options:local_ip=$HOST_A_TUN_IP options:remote_ip=$PVE_TUN options:key=110 ofport_request=11"

ovs-vsctl --may-exist add-port br-mgmt vx-pve \
  -- set interface vx-pve type=vxlan options:local_ip="$HOST_A_TUN_IP" options:remote_ip=$PVE_TUN options:key=300
ovs-vsctl --may-exist add-port br-sdn vx-pve-trunk \
  -- set interface vx-pve-trunk type=vxlan options:local_ip="$HOST_A_TUN_IP" options:remote_ip=$PVE_TUN options:key=110 ofport_request=11

log "결과"
echo "br-mgmt: $(ovs-vsctl list-ports br-mgmt | tr '\n' ' ')"
echo "vx-pve-trunk ofport: $(ovs-vsctl get interface vx-pve-trunk ofport)"
ping -c2 -W2 10.255.0.13 >/dev/null 2>&1 && echo "노드 관리망(10.255.0.13) ping OK" || echo "노드 관리망 ping 안 됨 (노드 쪽 10-network.sh·방화벽 확인)"
