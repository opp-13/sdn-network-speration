#!/usr/bin/env bash
# 로컬 lite: Phase 7 검증 시나리오 t01~t13 일괄 실행
# 전제: tests/lite-phase6.sh 통과 상태 (Faucet dot1x 모드, RADIUS 기동)
# 사용: sudo tests/lite-run-all.sh [t01 t05 ...]   (인자 없으면 전체)
# 출력: 화면 + tests/out/phase7.txt, 요약 tests/out/phase7-summary.txt
source "$(dirname "$0")/../local/lib.sh"
need_root
set +e
OUTD="$POC_REPO/tests/out"; mkdir -p "$OUTD"
exec > >(tee "$OUTD/phase7.txt") 2>&1
trap 'restore_all >/dev/null 2>&1; fix_owner' EXIT

L="$POC_REPO/local"; T="$L/term.sh"; S="$L/supp.sh"
EXT_IP=1.1.1.1; EXT_HOST=example.com
SUMMARY="$OUTD/phase7-summary.txt"; : > "$SUMMARY"
CUR=""; cur_fail=0

# ---------- 공통 ----------
begin() { CUR=$1; cur_fail=0; echo; echo "===== $1: $2 ====="; }
end()   { local r=PASS; ((cur_fail)) && r=FAIL; echo "$CUR $r" >> "$SUMMARY"; echo "----- $CUR: $r"; }
res()   { if [[ $1 == "$2" ]]; then echo "  PASS  $3"; else echo "  FAIL  $3 (기대 $2, 실제 $1)"; cur_fail=1; fi; }
note()  { echo "  관찰  $*"; }
try()   { "$@" >/dev/null 2>&1 && echo ok || echo fail; }
ip_of() { ip -n "poc-$1" -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1; }
port_vid() {
  ovs-ofctl -O OpenFlow13 dump-flows "$BR_SDN" | grep "in_port=$1,vlan_tci=0x0000/0x1fff" \
    | grep -o 'set_field:[0-9]*->vlan_vid' | head -1 | grep -o '[0-9]*' | awk '{print $1-4096}'
}
authed_flow() { ovs-ofctl -O OpenFlow13 dump-flows "$BR_SDN" table=0 | grep -c "in_port=$1,dl_src=" ; }

# 단말을 깨끗한 상태로: supplicant 중지, 주소 반납
reset_term() { "$S" "$1" stop >/dev/null 2>&1; "$T" "$1" release >/dev/null 2>&1; }
# 인증 + DHCP. 성공 시 0
auth_dhcp() { # <단말> <identity> [cert]
  reset_term "$1"
  "$S" "$1" start "$2" "${3:-$2}" >/dev/null || return 1
  "$S" "$1" wait 30 >/dev/null || return 1
  sleep 2
  "$T" "$1" dhcp >/dev/null
}
# 게이트웨이 L2 도달 여부 (ARP 응답을 받으면 도달).
# fw는 정책상 VLAN에서 오는 ping에 응답하지 않으므로(DHCP·DNS만 허용) ping 대신 ARP로 판정한다.
l2_reach() { # <단말> <gw>
  ip -n "poc-$1" neigh flush dev eth0 2>/dev/null
  ip netns exec "poc-$1" ping -c1 -W1 "$2" >/dev/null 2>&1
  sleep 0.5
  ip -n "poc-$1" neigh show "$2" dev eth0 | grep -qE 'REACHABLE|STALE|DELAY|PROBE'
}
# 고정 IP를 직접 넣고 게이트웨이 L2 도달 (DHCP 없이도 뚫리는지)
static_probe() { # <단말> <ip/24> <gw>
  ip -n "poc-$1" addr replace "$2" dev eth0
  l2_reach "$1" "$3"; local rc=$?
  ip -n "poc-$1" addr flush dev eth0
  return $rc
}
faucet_up() {
  docker start poc-faucet >/dev/null; sleep 1; faucet_attach; wait_controller 40; sleep 3
}
radius_up() { "$L/50-radius.sh" >/dev/null 2>&1; }
restore_all() {
  [[ "$(docker inspect -f '{{.State.Running}}' poc-faucet 2>/dev/null)" == true ]] || faucet_up
  [[ "$(docker inspect -f '{{.State.Running}}' poc-radius 2>/dev/null)" == true ]] || radius_up
  ip -n poc-fw link set eth1 up
  ip -n poc-unauth01 link set eth0 address 02:00:00:00:01:03
  reset_term unauth01
  auth_dhcp biz01 vm-biz01; auth_dhcp inet01 vm-inet01
}

# ---------- 시나리오 ----------
t01() { begin t01 "업무 단말 인증서로 인증"
  res "$(try auth_dhcp biz01 vm-biz01)" ok "biz01 인증 + DHCP"
  res "$(port_vid 1)" 100 "port 1 VLAN 100"
  local a; a=$(ip_of biz01); res "${a%.*}" 10.100.0 "업무망 주소 ($a)"
  end; }

t02() { begin t02 "인터넷 단말 인증서로 인증 → 외부 통신"
  res "$(try auth_dhcp inet01 vm-inet01)" ok "inet01 인증 + DHCP"
  res "$(port_vid 2)" 200 "port 2 VLAN 200"
  local a; a=$(ip_of inet01); res "${a%.*}" 10.200.0 "인터넷망 주소 ($a)"
  res "$(try "$T" inet01 run ping -c2 -W3 $EXT_IP)" ok "외부 ping $EXT_IP"
  res "$(try "$T" inet01 run busybox nslookup $EXT_HOST)" ok "외부 DNS $EXT_HOST"
  res "$(try "$T" inet01 run curl -sf -m8 -o /dev/null http://$EXT_HOST)" ok "외부 HTTP"
  end; }

t03() { begin t03 "인증서 없이 접속"
  reset_term unauth01
  res "$(try "$T" unauth01 dhcp)" fail "DHCP 미수신"
  res "$(try static_probe unauth01 10.200.0.50/24 10.200.0.1)" fail "고정 IP로 인터넷망 게이트웨이 접근"
  res "$(try static_probe unauth01 10.100.0.50/24 10.100.0.1)" fail "고정 IP로 업무망 게이트웨이 접근"
  end; }

t04() { begin t04 "다른 CA 서명 위조 인증서 (CN=vm-biz01)"
  reset_term unauth01
  "$S" unauth01 start vm-biz01 rogue-vm-biz01 >/dev/null
  res "$(try "$S" unauth01 wait 20)" fail "인증 실패"
  res "$(port_vid 3)" 999 "port 3 격리 VLAN 유지 (biz로 바뀌지 않음)"
  res "$(try "$T" unauth01 dhcp)" fail "DHCP 미수신"
  reset_term unauth01
  end; }

t05() { begin t05 "업무 단말 → 외부 (ping, DNS, HTTP)"
  [[ "$(ip_of biz01)" == 10.100.0.* ]] || auth_dhcp biz01 vm-biz01
  res "$(try "$T" biz01 run ping -c2 -W2 $EXT_IP)" fail "외부 ping"
  res "$(try "$T" biz01 run busybox nslookup $EXT_HOST)" fail "DNS (fw 경유)"
  res "$(try "$T" biz01 run busybox nslookup $EXT_HOST $EXT_IP)" fail "DNS (외부 서버 직접)"
  res "$(try "$T" biz01 run curl -sf -m5 -o /dev/null http://$EXT_IP)" fail "HTTP"
  end; }

t06() { begin t06 "업무 단말 ↔ 인터넷 단말"
  local b i; b=$(ip_of biz01); i=$(ip_of inet01)
  res "$(try "$T" biz01 run ping -c2 -W2 "$i")" fail "biz01 → inet01 ($i)"
  res "$(try "$T" inet01 run ping -c2 -W2 "$b")" fail "inet01 → biz01 ($b)"
  res "$(try "$T" biz01 run ping -c2 -W2 10.200.0.1)" fail "biz01 → 인터넷망 게이트웨이"
  end; }

t07() { begin t07 "RADIUS 중지 후 새 단말 인증 시도 (정상 업무 인증서)"
  docker stop poc-radius >/dev/null
  reset_term unauth01
  "$S" unauth01 start vm-biz01 >/dev/null
  res "$(try "$S" unauth01 wait 25)" fail "인증 실패"
  res "$(port_vid 3)" 999 "port 3가 업무망(100)으로 열리지 않음 (격리 유지)"
  res "$(try "$T" unauth01 dhcp)" fail "DHCP 미수신"
  note "기존 인증 단말 biz01 → 10.100.0.1: $(try l2_reach biz01 10.100.0.1)"
  reset_term unauth01
  radius_up
  end; }

t08() { begin t08 "faucet 컨트롤러 중지"
  docker stop poc-faucet >/dev/null; sleep 3
  note "is_connected=$(ovs-vsctl get controller "$BR_SDN" is_connected), fail-mode=$(ovs-vsctl get-fail-mode "$BR_SDN")"
  reset_term unauth01
  "$S" unauth01 start vm-biz01 >/dev/null
  res "$(try "$S" unauth01 wait 15)" fail "새 단말 인증 불가"
  res "$(try "$T" unauth01 dhcp)" fail "새 단말 DHCP 미수신"
  res "$(try static_probe unauth01 10.200.0.50/24 10.200.0.1)" fail "새 단말 고정 IP 통신"
  res "$(port_vid 1)" 100 "biz01 포트는 계속 VLAN 100 (혼합 없음)"
  res "$(try "$T" biz01 run ping -c2 -W2 10.200.0.1)" fail "biz01 → 인터넷망 차단 유지"
  note "기존 인증 단말 biz01 → 10.100.0.1: $(try l2_reach biz01 10.100.0.1)"
  "$S" biz01 logoff >/dev/null; sleep 3
  note "컨트롤러 없는 상태에서 biz01 EAPOL-Logoff 후 → 10.100.0.1: $(try l2_reach biz01 10.100.0.1) (ok면 로그오프가 반영되지 않음)"
  reset_term unauth01
  faucet_up
  note "재기동 후 인증 흐름 수 port1=$(authed_flow 1) port2=$(authed_flow 2) (0이면 재인증 필요)"
  auth_dhcp biz01 vm-biz01; auth_dhcp inet01 vm-inet01
  end; }

t09() { begin t09 "호스트 B 중지 (fw 트렁크 down + RADIUS 중지)"
  ip -n poc-fw link set eth1 down; docker stop poc-radius >/dev/null
  res "$(try "$T" inet01 run ping -c2 -W2 $EXT_IP)" fail "인터넷 단말 외부 불가"
  res "$(try "$T" biz01 run ping -c2 -W2 $EXT_IP)" fail "업무 단말 외부 불가"
  reset_term unauth01
  "$S" unauth01 start vm-biz01 >/dev/null
  res "$(try "$S" unauth01 wait 20)" fail "새 인증 실패"
  reset_term unauth01
  ip -n poc-fw link set eth1 up; radius_up
  res "$(try "$T" inet01 run ping -c2 -W3 $EXT_IP)" ok "복구 후 인터넷 단말 외부 통신"
  end; }

t10() { begin t10 "vm-unauth01에 vm-biz01 MAC 복제"
  reset_term unauth01
  ip -n poc-unauth01 link set eth0 address 02:00:00:00:01:01
  res "$(try "$T" unauth01 dhcp)" fail "DHCP 미수신"
  res "$(try static_probe unauth01 10.100.0.50/24 10.100.0.1)" fail "고정 IP로 업무망 접근"
  ip -n poc-unauth01 link set eth0 address 02:00:00:00:01:03
  res "$(try l2_reach biz01 10.100.0.1)" ok "원래 biz01 통신 영향 없음"
  end; }

t11() { begin t11 "인증된 단말 EAPOL-Logoff"
  [[ "$(ip_of biz01)" == 10.100.0.* ]] || auth_dhcp biz01 vm-biz01
  res "$(try l2_reach biz01 10.100.0.1)" ok "로그오프 전 통신"
  "$S" biz01 logoff >/dev/null; sleep 2
  res "$(authed_flow 1)" 0 "port 1 인증 흐름 제거"
  res "$(try l2_reach biz01 10.100.0.1)" fail "로그오프 후 차단"
  note "로그오프 후 port 1 VID=$(port_vid 1) (격리 VLAN 복귀 예상 999)"
  local t0=$SECONDS
  "$S" biz01 wait 75 >/dev/null
  note "같은 supplicant의 재인증까지 $((SECONDS-t0))초 (chewie 선제 Identity 요청 주기 60초)"
  auth_dhcp biz01 vm-biz01 || { "$S" biz01 wait 75 >/dev/null; "$T" biz01 dhcp >/dev/null; }
  end; }

t12() { begin t12 "큰 인증서(9.5KB) EAP-TLS 20회 반복"
  local ok=0 i
  for i in $(seq 1 20); do
    reset_term inet01
    "$S" inet01 start vm-inet-big >/dev/null
    "$S" inet01 wait 30 >/dev/null && ok=$((ok+1))
  done
  res "$ok" 20 "20회 중 성공 $ok회"
  auth_dhcp inet01 vm-inet01
  end; }

t13() { begin t13 "관리망(10.255.0.0/24)에서 업무망 주소로 접근"
  [[ "$(ip_of biz01)" == 10.100.0.* ]] || auth_dhcp biz01 vm-biz01
  local b; b=$(ip_of biz01)
  res "${b%.*}" 10.100.0 "전제: biz01 업무망 주소 있음 ($b)"
  for ns in poc-radius poc-faucet; do
    ip -n $ns route replace 10.100.0.0/24 via 10.255.0.30
    ip -n $ns route replace 10.200.0.0/24 via 10.255.0.30
    res "$(try ip netns exec $ns ping -c2 -W2 "$b")" fail "$ns → biz01 ($b)"
    res "$(try ip netns exec $ns ping -c2 -W2 10.100.0.1)" fail "$ns → fw 업무망 주소"
    ip -n $ns route del 10.100.0.0/24; ip -n $ns route del 10.200.0.0/24
  done
  res "$(try ping -c2 -W2 -I br-mgmt "$b")" fail "노트북(10.255.0.11) → biz01"
  end; }

# ---------- 실행 ----------
echo "### Phase 7 (lite) $(date '+%F %T')  Faucet $(cat "$POC_RUN/faucet-version.txt" 2>/dev/null)"
[[ "$(cat "$POC_RUN/faucet/MODE" 2>/dev/null)" == dot1x ]] || { echo "Faucet이 dot1x 모드가 아님: 먼저 sudo tests/lite-phase6.sh"; exit 1; }
CASES=("$@"); ((${#CASES[@]})) || CASES=(t01 t02 t03 t04 t05 t06 t07 t08 t09 t10 t11 t12 t13)
for c in "${CASES[@]}"; do "$c"; done

ovs-ofctl -O OpenFlow13 dump-flows "$BR_SDN" > "$OUTD/phase7-flows-end.txt"
docker logs poc-radius > "$OUTD/phase7-radius.txt" 2>&1
cp "$POC_RUN/faucet-log/faucet.log" "$OUTD/phase7-faucet.log" 2>/dev/null
echo; echo "===== 요약 ====="; cat "$SUMMARY"
echo "PASS $(grep -c ' PASS' "$SUMMARY") / FAIL $(grep -c ' FAIL' "$SUMMARY")"
! grep -q ' FAIL' "$SUMMARY"
