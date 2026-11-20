#!/usr/bin/env bash
# 원격(VM): 컨트롤러(Faucet) 장애 중 "새로 연결되는 포트" 시험
#
#   A. 빈 예비 포트(5)에 새 장비 연결        — 호스트에서 netns + veth 로 모사 (MAC 02:00:00:00:02:05)
#   B. 미인증 포트 재연결 (vm-unauth01 재부팅) — 포트 3 삭제 후 다시 생김
#   C. 인증됐던 포트 재연결 (vm-biz01 재부팅)  — 포트 1 삭제 후 같은 번호로 다시 생김.
#      장애 중엔 Faucet 이 옛 인증 흐름(in_port=1,dl_src=biz MAC)을 지울 수 없음 → 재인증 없이 통하는지?
#   D. 컨트롤러 복구 후: 옛 흐름 정리·새 포트 격리 VLAN 적용·정상 재인증
#
# 사용: sudo tests/remote-controller-outage.sh      (약 6분, VM 2대 재부팅 포함)
# 결과: 화면 + tests/out/remote-ctl-outage.txt, 흐름 스냅샷 tests/out/remote-ctl-outage-flows-*.txt
source "$(dirname "$0")/../hosts/lib.sh"
need_root
set +e
exec > >(tee "$OUTD/remote-ctl-outage.txt") 2>&1
T="$POC_REPO/vm/term.sh"; S="$POC_REPO/vm/supp.sh"
QVID=999; NS=poc-newdev; NMAC=02:00:00:00:02:05; NPORT=5

cleanup() {
  ip netns del $NS 2>/dev/null; ovs-vsctl --if-exists del-port br-sdn tp-newdev; ip link del tp-newdev 2>/dev/null
  [[ "$(vmssh poc@$FAUCET_IP 'systemctl is-active faucet' 2>/dev/null)" == active ]] || { vmssh poc@$FAUCET_IP 'sudo systemctl start faucet'; wait_controller 60; }
  fix_owner
}
trap cleanup EXIT

in_vm() { bash "$T" "$1" run "$2" "${3:-30}"; }
port_vid() {
  ovs-ofctl -O OpenFlow13 dump-flows br-sdn | grep "in_port=$1,vlan_tci=0x0000/0x1fff" \
    | grep -o 'set_field:[0-9]*->vlan_vid' | head -1 | grep -o '[0-9]*' | awk '{print $1-4096}'
}
port_flows() { ovs-ofctl -O OpenFlow13 dump-flows br-sdn | grep -c "in_port=$1[, ]"; }
l2_reach_vm() { in_vm "$1" "ip neigh flush dev eth0; ping -c1 -W1 $2 >/dev/null 2>&1; sleep 0.5; ip neigh show $2 dev eth0 | grep -qE 'REACHABLE|STALE|DELAY|PROBE'" 15 >/dev/null 2>&1; }
static_probe_vm() { # <VM> <ip/24> <gw>
  in_vm "$1" "ip addr flush dev eth0; ip addr add $2 dev eth0" 10 >/dev/null
  l2_reach_vm "$1" "$3"; local rc=$?
  in_vm "$1" "ip addr flush dev eth0" 10 >/dev/null; return $rc
}
static_probe_ns() { # <ip/24> <gw>
  ip -n $NS addr flush dev eth0; ip -n $NS addr add "$1" dev eth0
  ip -n $NS neigh flush dev eth0; ip netns exec $NS ping -c1 -W1 "$2" >/dev/null 2>&1; sleep 0.5
  ip -n $NS neigh show "$2" dev eth0 | grep -qE 'REACHABLE|STALE|DELAY|PROBE'; local rc=$?
  ip -n $NS addr flush dev eth0; return $rc
}
vm_reboot_wait() { # <VM> : 강제 재시작(포트 삭제→재생성) 후 게스트 에이전트 응답까지
  virsh destroy "$1" >/dev/null; sleep 2; virsh start "$1" >/dev/null
  for _ in $(seq 1 90); do virsh qemu-agent-command "$1" '{"execute":"guest-ping"}' --timeout 3 &>/dev/null && return 0; sleep 2; done
  return 1
}
auth_dhcp() {
  bash "$S" "$1" stop >/dev/null 2>&1; bash "$T" "$1" release >/dev/null 2>&1
  bash "$S" "$1" start "$2" >/dev/null || return 1
  bash "$S" "$1" wait "${3:-90}" >/dev/null || return 1
  sleep 2; bash "$T" "$1" dhcp >/dev/null
}

echo "### 컨트롤러 장애 중 새 포트 시험 $(date '+%F %T')"
echo "== 준비: 정상 상태 (vm-biz01 인증, vm-unauth01 미인증)"
[[ "$(port_vid 1)" == 100 ]] || auth_dhcp vm-biz01 vm-biz01
res "$(port_vid 1)" 100 "vm-biz01 인증 상태 (port 1 VLAN 100)"
bash "$S" vm-unauth01 stop >/dev/null 2>&1; bash "$T" vm-unauth01 release >/dev/null 2>&1
res "$(port_vid 3)" $QVID "vm-unauth01 미인증 (port 3 격리 VLAN)"
ovs-ofctl -O OpenFlow13 dump-flows br-sdn > "$OUTD/remote-ctl-outage-flows-0-before.txt"

echo "== 컨트롤러 중지"
GUARD=$(systemctl is-active poc-port-guard 2>/dev/null)
echo "  관찰  포트 가드(poc-port-guard): ${GUARD:-없음} (mode $(systemctl show poc-port-guard -p Environment --value 2>/dev/null | grep -o 'MODE=[a-z]*'))"
GSINCE=$(date '+%F %T')
vmssh poc@$FAUCET_IP 'sudo systemctl stop faucet'
for _ in $(seq 1 20); do [[ "$(ovs-vsctl get controller br-sdn is_connected)" == false ]] && break; sleep 1; done
res "$(ovs-vsctl get controller br-sdn is_connected)" false "Faucet 연결 끊김 (fail-mode $(ovs-vsctl get-fail-mode br-sdn))"

echo "== A. 빈 예비 포트 $NPORT 에 새 장비 연결 (장애 중)"
ip netns add $NS; ip -n $NS link set lo up
ip link add tp-newdev type veth peer name eth0 netns $NS
ip -n $NS link set eth0 address $NMAC; ip -n $NS link set eth0 up; ip link set tp-newdev up
ovs-vsctl add-port br-sdn tp-newdev -- set interface tp-newdev ofport_request=$NPORT
sleep 2
res "$(ovs-vsctl get interface tp-newdev ofport)" $NPORT "새 장비가 port $NPORT 에 연결됨"
res "$(port_flows $NPORT)" 0 "port $NPORT 전용 흐름 없음 (컨트롤러가 없어 설치 불가)"
res "$(static_probe_ns 10.200.0.55/24 10.200.0.1 && echo ok || echo fail)" fail "새 장비 → 인터넷망 게이트웨이 도달 불가"
res "$(static_probe_ns 10.100.0.55/24 10.100.0.1 && echo ok || echo fail)" fail "새 장비 → 업무망 게이트웨이 도달 불가"
res "$(timeout 15 ip netns exec $NS busybox udhcpc -i eth0 -n -q -t 3 -T 2 -s /bin/true >/dev/null 2>&1 && echo ok || echo fail)" fail "새 장비 DHCP 미수신"

echo "== B. 미인증 포트 재연결: vm-unauth01 재부팅 (장애 중)"
res "$(vm_reboot_wait vm-unauth01 && echo ok || echo fail)" ok "vm-unauth01 재부팅 완료"
res "$(static_probe_vm vm-unauth01 10.200.0.50/24 10.200.0.1 && echo ok || echo fail)" fail "재연결된 미인증 포트 → 인터넷망 도달 불가"
res "$(static_probe_vm vm-unauth01 10.100.0.50/24 10.100.0.1 && echo ok || echo fail)" fail "재연결된 미인증 포트 → 업무망 도달 불가"

echo "== C. 인증됐던 포트 재연결: vm-biz01 재부팅 (장애 중, 재인증 안 함)"
echo "  관찰  재부팅 전 port 1 인증 흐름 수 = $(ovs-ofctl -O OpenFlow13 dump-flows br-sdn table=0 | grep -c 'in_port=1,dl_src=')"
res "$(vm_reboot_wait vm-biz01 && echo ok || echo fail)" ok "vm-biz01 재부팅 완료 (supplicant 꺼진 상태)"
ovs-ofctl -O OpenFlow13 dump-flows br-sdn > "$OUTD/remote-ctl-outage-flows-1-during.txt"
STALE=$(ovs-ofctl -O OpenFlow13 dump-flows br-sdn table=0 | grep -c 'in_port=1,dl_src=02:00:00:00:01:01')
echo "  관찰  재연결 후 port 1 옛 인증 흐름(in_port=1,dl_src=biz MAC) 남음: $STALE 개"
res "$(static_probe_vm vm-biz01 10.100.0.162/24 10.100.0.1 && echo ok || echo fail)" fail "재인증 없이 업무망 도달 불가 (옛 인증 흐름으로 통하면 FAIL)"
res "$(bash "$T" vm-biz01 dhcp >/dev/null 2>&1 && echo ok || echo fail)" fail "재인증 없이 DHCP 미수신"
bash "$T" vm-biz01 release >/dev/null 2>&1

echo "  관찰  기존 인증 단말 vm-inet01(포트 변화 없음) → 1.1.1.1: $(bash "$T" vm-inet01 run "ping -c2 -W3 1.1.1.1" 15 >/dev/null 2>&1 && echo ok || echo fail)"
if [[ "$GUARD" == active ]]; then
  echo "  포트 가드 기록:"; journalctl -t poc-port-guard --since "$GSINCE" --no-pager -o cat | sed 's/^/    /'
  res "$(journalctl -t poc-port-guard --since "$GSINCE" --no-pager -o cat | grep -c 'in_port=1 흐름 삭제' | awk '{print ($1>0)?"ok":"none"}')" ok "포트 가드가 장애 중 port 1 흐름 삭제"
fi

echo "== D. 컨트롤러 복구"
vmssh poc@$FAUCET_IP 'sudo systemctl start faucet'; wait_controller 60; sleep 5
res "$(ovs-vsctl get controller br-sdn is_connected)" true "Faucet 재연결"
ovs-ofctl -O OpenFlow13 dump-flows br-sdn > "$OUTD/remote-ctl-outage-flows-2-after.txt"
res "$(ovs-ofctl -O OpenFlow13 dump-flows br-sdn table=0 | grep -c 'in_port=1,dl_src=')" 0 "복구 시 옛 인증 흐름 모두 정리"
res "$(port_vid $NPORT)" $QVID "새 장비 port $NPORT 에 격리 VLAN 적용"
res "$(static_probe_ns 10.200.0.55/24 10.200.0.1 && echo ok || echo fail)" fail "복구 후에도 새 장비(인증 안 함) 차단"
res "$(auth_dhcp vm-biz01 vm-biz01 && echo ok || echo fail)" ok "vm-biz01 정상 재인증 → 업무망"
res "$(port_vid 1)" 100 "port 1 VLAN 100"
summary
