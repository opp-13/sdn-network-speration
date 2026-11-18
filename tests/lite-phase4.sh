#!/usr/bin/env bash
# 로컬 lite: Phase 3(정적 VLAN) + Phase 4(방화벽) 완료 조건 검사
# 사용: sudo tests/lite-phase4.sh   (faucet static 모드, fw 구성 완료 상태)
source "$(dirname "$0")/../local/lib.sh"
need_root
set +e

T="$POC_REPO/local/term.sh"
EXT_IP=1.1.1.1
EXT_HOST=example.com
pass=0; fail=0
check() { # check "<설명>" <기대: ok|fail> <명령...>
  local desc=$1 want=$2; shift 2
  if "$@" >/dev/null 2>&1; then got=ok; else got=fail; fi
  if [[ $got == "$want" ]]; then echo "PASS  $desc"; ((pass++)); else echo "FAIL  $desc (기대 $want, 실제 $got)"; ((fail++)); fi
}
ip_of() { ip -n "poc-$1" -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1; }

echo "== Phase 3: 컨트롤러 연결 =="
check "br-sdn fail-mode secure" ok  test "$(ovs-vsctl get-fail-mode br-sdn)" = secure
check "Faucet 연결됨"           ok  test "$(ovs-vsctl get controller br-sdn is_connected)" = true

echo "== Phase 4: 주소 수신 =="
$T biz01 release; $T inet01 release
check "biz01 DHCP"  ok $T biz01 dhcp
check "inet01 DHCP" ok $T inet01 dhcp
BIZ=$(ip_of biz01); INET=$(ip_of inet01)
echo "      biz01=$BIZ inet01=$INET"
check "biz01 주소가 10.100.0.0/24"  ok test "${BIZ%.*}" = 10.100.0
check "inet01 주소가 10.200.0.0/24" ok test "${INET%.*}" = 10.200.0

echo "== Phase 4: 정책 =="
check "inet01 → 외부 ping"        ok   $T inet01 run ping -c2 -W2 $EXT_IP
check "inet01 → 외부 DNS"         ok   $T inet01 run busybox nslookup $EXT_HOST
check "biz01 → 외부 ping"         fail $T biz01 run ping -c2 -W2 $EXT_IP
check "biz01 → 외부 DNS"          fail $T biz01 run busybox nslookup $EXT_HOST
check "biz01 → inet01 ping"       fail $T biz01 run ping -c2 -W2 "$INET"
check "inet01 → biz01 ping"       fail $T inet01 run ping -c2 -W2 "$BIZ"

echo "== fw 차단 카운터 =="
ip netns exec poc-fw nft list chain inet fw forward | grep -E 'counter.*comment'

echo; echo "결과: PASS $pass / FAIL $fail"
[[ $fail -eq 0 ]]
