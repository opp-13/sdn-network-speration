#!/usr/bin/env bash
# 로컬 lite: Phase 3 완료 조건 "컨트롤러 중지 시 신규 통신 차단" (t08 사전 관찰)
# Faucet을 멈춘 상태에서 아래를 관찰하고, 끝나면 Faucet을 다시 띄운다.
#   1) 기존 흐름: biz01 → fw(10.100.0.1) ping   (OVS에 남은 흐름으로 유지될 수 있음 — 관찰값)
#   2) 신규 단말: unauth01 DHCP                 (차단되어야 PASS)
#   3) 망 혼합: biz01 → 10.200.0.1 ping          (실패해야 PASS)
# 사용: sudo tests/lite-phase3-failsecure.sh
source "$(dirname "$0")/../local/lib.sh"
need_root
set +e
T="$POC_REPO/local/term.sh"
pass=0; fail=0
res() { if [[ $1 == "$2" ]]; then echo "PASS  $3"; ((pass++)); else echo "FAIL  $3 (기대 $2, 실제 $1)"; ((fail++)); fi; }
try() { "$@" >/dev/null 2>&1 && echo ok || echo fail; }

FLOWS_BEFORE=$(ovs-ofctl -O OpenFlow13 dump-flows br-sdn | wc -l)
$T unauth01 release

echo "== Faucet 중지 =="
docker stop poc-faucet >/dev/null
sleep 3
echo "is_connected: $(ovs-vsctl get controller br-sdn is_connected), fail-mode: $(ovs-vsctl get-fail-mode br-sdn)"
echo "흐름 수: 중지 전 $FLOWS_BEFORE / 중지 후 $(ovs-ofctl -O OpenFlow13 dump-flows br-sdn | wc -l)"

echo "관찰  기존 흐름 biz01 → 10.100.0.1: $(try $T biz01 run ping -c2 -W2 10.100.0.1)"
res "$(try $T unauth01 dhcp)" fail "신규 단말 unauth01 DHCP 차단"
res "$(try $T biz01 run ping -c2 -W2 10.200.0.1)" fail "biz01 → 인터넷망 게이트웨이 차단"

echo "== Faucet 재기동 =="
docker start poc-faucet >/dev/null
sleep 1
register_container_ns poc-faucet poc-faucet
attach "$BR_MGMT" - poc-faucet v-fct0 eth0 "$FAUCET_MGMT_IP"
attach "$BR_SDN" 20 poc-faucet v-fct1 eth1
for _ in $(seq 1 20); do [[ "$(ovs-vsctl get controller br-sdn is_connected)" == true ]] && break; sleep 1; done
echo "is_connected: $(ovs-vsctl get controller br-sdn is_connected)"

echo; echo "결과: PASS $pass / FAIL $fail"
[[ $fail -eq 0 ]]
