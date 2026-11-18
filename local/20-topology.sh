#!/usr/bin/env bash
# 로컬 lite 모드 토폴로지 (계획서 Phase 1~2 대응). 여러 번 실행해도 같은 상태(멱등).
#
#  br-mgmt (10.255.0.0/24) : 노트북 .11, faucet .10, radius .20, fw .30
#  br-sdn  (secure, dpid 1): 1 biz01 / 2 inet01 / 3 unauth01 / 10 patch→br-trunk / 20 faucet eth1
#  br-trunk (standalone)   : patch←br-sdn, fw eth1 (VLAN 트렁크)
#  fw eth2 ↔ 노트북 fw-egr → NAT → 인터넷
#
# 영향 범위: 노트북에 OVS 브리지 3개, netns 4개, veth, iptables NAT/FORWARD 규칙 추가.
#           기존 NIC(Wi-Fi 등)와 기존 Docker 네트워크는 변경하지 않는다.
source "$(dirname "$0")/lib.sh"
need_root

log "브리지 생성"
ovs-vsctl --may-exist add-br "$BR_MGMT"
ovs-vsctl --may-exist add-br "$BR_TRUNK"
ovs-vsctl --may-exist add-br "$BR_SDN" \
  -- set bridge "$BR_SDN" other-config:datapath-id=0000000000000001 \
  -- set bridge "$BR_SDN" protocols=OpenFlow13 \
  -- set-fail-mode "$BR_SDN" secure
nm_unmanage "$BR_MGMT" "$BR_TRUNK" "$BR_SDN"

ip link set "$BR_MGMT" mtu "$MTU" up
ip addr replace "$MGMT_HOST_IP" dev "$BR_MGMT"

log "트렁크: br-sdn port 10 ↔ br-trunk (VXLAN 대신 patch 포트)"
ovs-vsctl --may-exist add-port "$BR_SDN" p-sdn-trunk \
  -- set interface p-sdn-trunk type=patch options:peer=p-trunk-sdn ofport_request=10
ovs-vsctl --may-exist add-port "$BR_TRUNK" p-trunk-sdn \
  -- set interface p-trunk-sdn type=patch options:peer=p-sdn-trunk

log "단말 netns (NIC 하나만)"
for t in "${TERMINALS[@]}"; do
  name=${t%%:*}; rest=${t#*:}; ofp=${rest%%:*}; mac=${rest#*:}
  ensure_ns "poc-$name"
  attach "$BR_SDN" "$ofp" "poc-$name" "v-$name" eth0 "" "$mac"
done

log "방화벽 netns poc-fw"
ensure_ns poc-fw
attach "$BR_MGMT"  - poc-fw v-fw0 eth0 "$FW_MGMT_IP"
attach "$BR_TRUNK" - poc-fw v-fw1 eth1
ip netns exec poc-fw sysctl -qw net.ipv4.ip_forward=1

log "방화벽 외부 출구 (fw eth2 ↔ 노트북 fw-egr)"
if ! ip link show fw-egr &>/dev/null; then
  ip link add fw-egr type veth peer name fw-egr-p
  ip link set fw-egr-p netns poc-fw
  ip -n poc-fw link set fw-egr-p name eth2
fi
nm_unmanage fw-egr
ip addr replace "$EGR_HOST_IP" dev fw-egr
ip link set fw-egr up
ip -n poc-fw addr replace "$EGR_FW_IP" dev eth2
ip -n poc-fw link set eth2 up
ip -n poc-fw route replace default via "${EGR_HOST_IP%/*}" dev eth2

sysctl -qw net.ipv4.ip_forward=1
ipt_ensure nat POSTROUTING -s "$EGR_NET" ! -o fw-egr -j MASQUERADE
FWD=$(fwd_chain)
ipt_ensure filter "$FWD" -o fw-egr -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
ipt_ensure filter "$FWD" -i fw-egr -j ACCEPT

log "결과"
ovs-vsctl show
ovs-ofctl -O OpenFlow13 show "$BR_SDN" | grep -E '^\s*[0-9]+\(' || true
echo "fail-mode: $(ovs-vsctl get-fail-mode "$BR_SDN")"
ip netns list
