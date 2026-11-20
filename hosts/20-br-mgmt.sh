#!/usr/bin/env bash
# Phase 1: 관리망 br-mgmt (OVS). 멱등.
#   single: SDN01 안의 로컬 브리지. 호스트 10.255.0.11, faucet-ctl .10, radius .20, fw .30 이 모두 여기에 붙는다.
#   dual  : host-a 10.255.0.11 ⇄ host-b 10.255.0.12 를 VXLAN key 300 으로 연결
source "$(dirname "$0")/lib.sh"
need_root

role=$(my_role)
case "$role" in
  a) LOCAL=$HOST_A_TUN_IP; REMOTE=$HOST_B_TUN_IP; OVL=$HOST_A_MGMT_OVL_IP ;;
  b) LOCAL=$HOST_B_TUN_IP; REMOTE=$HOST_A_TUN_IP; OVL=$HOST_B_MGMT_OVL_IP ;;
  *) die "역할 판정 실패: 터널 NIC에 env.sh의 HOST_A/B_TUN_IP가 없음" ;;
esac

if is_single; then
  confirm "host-a(단일 구성) 에 OVS 브리지 br-mgmt (로컬 관리망), 내부 포트 IP $OVL/24. 이전 2호스트용 VXLAN 포트(vx-mgmt)가 있으면 제거" \
"ovs-vsctl --may-exist add-br br-mgmt
ovs-vsctl --if-exists del-port br-mgmt vx-mgmt
ip addr replace $OVL/24 dev br-mgmt (MTU 1500)"
  ovs-vsctl --may-exist add-br br-mgmt
  ovs-vsctl --if-exists del-port br-mgmt vx-mgmt
else
  confirm "host-$role 에 OVS 브리지 br-mgmt 생성, VXLAN(key 300, $LOCAL → $REMOTE), 내부 포트 IP $OVL/24" \
"ovs-vsctl --may-exist add-br br-mgmt
ovs-vsctl --may-exist add-port br-mgmt vx-mgmt -- set interface vx-mgmt type=vxlan options:local_ip=$LOCAL options:remote_ip=$REMOTE options:key=300
ip addr replace $OVL/24 dev br-mgmt (MTU 1500)"
  ovs-vsctl --may-exist add-br br-mgmt
  # 포트 생성과 타입 지정을 한 트랜잭션으로 (따로 하면 "No such device" 경고가 남음)
  ovs-vsctl --may-exist add-port br-mgmt vx-mgmt \
    -- set interface vx-mgmt type=vxlan \
       options:local_ip="$LOCAL" options:remote_ip="$REMOTE" options:key=300
fi
persist_ovs_ip br-mgmt "$OVL/24" 1500

log "결과"
ovs-vsctl list-ports br-mgmt
ip -br addr show br-mgmt
