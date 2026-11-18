#!/usr/bin/env bash
# 로컬 lite: Phase 6 관문 — 802.1X 인증 + RADIUS 응답에 따른 동적 VLAN
# 사용: sudo tests/lite-phase6.sh
# 출력: 화면 + tests/out/phase6.txt, 증거 파일 tests/out/phase6-*.txt (사용자 소유로 저장)
source "$(dirname "$0")/../local/lib.sh"
need_root
set +e
OUTD="$POC_REPO/tests/out"; mkdir -p "$OUTD"
exec > >(tee "$OUTD/phase6.txt") 2>&1
trap fix_owner EXIT

L="$POC_REPO/local"
pass=0; fail=0
res() { if [[ $1 == "$2" ]]; then echo "PASS  $3"; ((pass++)); else echo "FAIL  $3 (기대 $2, 실제 $1)"; ((fail++)); fi; }
try() { "$@" >/dev/null 2>&1 && echo ok || echo fail; }
ip_of() { ip -n "poc-$1" -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1; }
port_vid() { # 포트의 untagged → VLAN 태깅 흐름에서 VID 추출
  ovs-ofctl -O OpenFlow13 dump-flows "$BR_SDN" | grep "in_port=$1,vlan_tci=0x0000/0x1fff" \
    | grep -o 'set_field:[0-9]*->vlan_vid' | head -1 | grep -o '[0-9]*' | awk '{print $1-4096}'
}

echo "### Phase 6 관문 $(date '+%F %T')"
echo "Faucet: $(cat "$POC_RUN/faucet-version.txt" 2>/dev/null)"

echo "== 준비: RADIUS 기동, Faucet dot1x 모드 =="
"$L/50-radius.sh" || { echo "FAIL  RADIUS 기동"; exit 1; }
"$L/30-faucet.sh" dot1x || { echo "FAIL  Faucet dot1x 적용"; exit 1; }
wait_controller 30
sleep 3
for t in biz01 inet01 unauth01; do "$L/supp.sh" $t stop >/dev/null; "$L/term.sh" $t release; done
ovs-ofctl -O OpenFlow13 dump-flows "$BR_SDN" > "$OUTD/phase6-flows-before.txt"
echo "port 1 VID(인증 전): $(port_vid 1)"

echo "== 인증 전: 모든 단말 차단 =="
res "$(try "$L/term.sh" unauth01 dhcp)" fail "unauth01 (인증 시도 없음) DHCP 차단"
res "$(try "$L/term.sh" biz01 dhcp)"    fail "biz01 인증 전 DHCP 차단"

echo "== vm-biz01 인증 =="
"$L/supp.sh" biz01 start vm-biz01
res "$(try "$L/supp.sh" biz01 wait 30)" ok "biz01 802.1X 인증 성공"
sleep 2
res "$(port_vid 1)" 100 "port 1 VLAN이 100(biz)으로 변경 (RADIUS 응답값 = 이름 \"biz\")"
res "$(try "$L/term.sh" biz01 dhcp)" ok "biz01 DHCP"
BIZ=$(ip_of biz01); echo "      biz01 = $BIZ"
res "${BIZ%.*}" 10.100.0 "biz01 업무망 주소"

echo "== vm-inet01 인증 =="
"$L/supp.sh" inet01 start vm-inet01
res "$(try "$L/supp.sh" inet01 wait 30)" ok "inet01 802.1X 인증 성공"
sleep 2
res "$(port_vid 2)" 200 "port 2 VLAN이 200(inet)"
res "$(try "$L/term.sh" inet01 dhcp)" ok "inet01 DHCP"
INET=$(ip_of inet01); echo "      inet01 = $INET"
res "${INET%.*}" 10.200.0 "inet01 인터넷망 주소"

echo "== vm-unauth01: 인증서 없음 =="
res "$(try "$L/term.sh" unauth01 dhcp)" fail "unauth01 DHCP 차단 (어떤 주소도 못 받음)"

echo "== 증거 수집 =="
ovs-ofctl -O OpenFlow13 dump-flows "$BR_SDN" > "$OUTD/phase6-flows-after.txt"
grep -iE 'dot1x|auth|eap|radius' "$POC_RUN/faucet-log/faucet.log" | tail -40 > "$OUTD/phase6-faucet-dot1x.txt"
docker logs poc-radius > "$OUTD/phase6-radius.txt" 2>&1
grep -E 'Sent Access-(Accept|Reject)|Tunnel-Private-Group-Id' "$OUTD/phase6-radius.txt" | tail -10
cp "$POC_RUN"/supplicant/*.log "$OUTD/" 2>/dev/null
echo "port VID: 1=$(port_vid 1) 2=$(port_vid 2) 3=$(port_vid 3)"

echo; echo "결과: PASS $pass / FAIL $fail"
[[ $fail -eq 0 ]]
