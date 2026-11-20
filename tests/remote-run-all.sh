#!/usr/bin/env bash
# 원격(VM) Phase 7: 검증 시나리오 t01~t13 — 실제 VM 단말, 단일 호스트(SDN01) 구성
# lite 의 tests/lite-run-all.sh 와 같은 시나리오. 단말 조작은 게스트 에이전트(vm/term.sh, vm/supp.sh).
# 전제: tests/remote-phase6.sh 통과 (Faucet dot1x, RADIUS 기동)
# 사용: sudo tests/remote-run-all.sh [t01 t05 ...]   (인자 없으면 전체, 약 10분)
# 결과: 화면 + tests/out/remote-phase7.txt, 요약 tests/out/remote-phase7-summary.txt
source "$(dirname "$0")/../hosts/lib.sh"
need_root
set +e
exec > >(tee "$OUTD/remote-phase7.txt") 2>&1
trap 'echo; echo "== 원상 복구"; restore_all; fix_owner' EXIT

T="$POC_REPO/vm/term.sh"; S="$POC_REPO/vm/supp.sh"; G="$POC_REPO/vm/gexec.sh"
EXT_IP=1.1.1.1; EXT_HOST=example.com
QVID=999   # 미인증·로그오프 포트의 격리 VLAN (faucet.dot1x.yaml quarantine)
SUMMARY="$OUTD/remote-phase7-summary.txt"; : > "$SUMMARY"
CUR=""; cur_fail=0

# ---------- 공통 ----------
begin() { CUR=$1; cur_fail=0; echo; echo "===== $1: $2 ====="; }
end()   { local r=PASS; ((cur_fail)) && r=FAIL; echo "$CUR $r" >> "$SUMMARY"; echo "----- $CUR: $r"; }
res()   { if [[ "$1" == "$2" ]]; then echo "  PASS  $3"; else echo "  FAIL  $3 (기대 $2, 실제 $1)"; cur_fail=1; fi; }
note()  { echo "  관찰  $*"; }
in_vm() { bash "$T" "$1" run "$2" "${3:-30}"; }
ip_of() { in_vm "$1" "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1" 10 2>/dev/null | head -1; }
port_vid() {
  ovs-ofctl -O OpenFlow13 dump-flows br-sdn | grep "in_port=$1,vlan_tci=0x0000/0x1fff" \
    | grep -o 'set_field:[0-9]*->vlan_vid' | head -1 | grep -o '[0-9]*' | awk '{print $1-4096}'
}
authed_flow() { ovs-ofctl -O OpenFlow13 dump-flows br-sdn table=0 | grep -c "in_port=$1,dl_src="; }
# 게이트웨이 L2 도달 (fw 는 VLAN 에서 오는 ping 에 응답하지 않으므로 ARP 로 판정)
l2_reach() {
  in_vm "$1" "ip neigh flush dev eth0; ping -c1 -W1 $2 >/dev/null 2>&1; sleep 0.5; ip neigh show $2 dev eth0 | grep -qE 'REACHABLE|STALE|DELAY|PROBE'" 15 >/dev/null 2>&1
}
static_probe() { # <VM> <ip/24> <gw> : 주소를 직접 넣고 게이트웨이 L2 도달 시도
  in_vm "$1" "ip addr flush dev eth0; ip addr add $2 dev eth0" 10 >/dev/null
  l2_reach "$1" "$3"; local rc=$?
  in_vm "$1" "ip addr flush dev eth0" 10 >/dev/null
  return $rc
}
reset_term() { bash "$S" "$1" stop >/dev/null 2>&1; bash "$T" "$1" release >/dev/null 2>&1; }
auth_dhcp() { # <VM> <인증서> [대기초] — 로그오프 직후 재인증은 최대 60초+ 지연(chewie)
  reset_term "$1"
  bash "$S" "$1" start "$2" >/dev/null || return 1
  bash "$S" "$1" wait "${3:-90}" >/dev/null || return 1
  sleep 2; bash "$T" "$1" dhcp >/dev/null
}
faucet_stop()  { vmssh poc@$FAUCET_IP 'sudo systemctl stop faucet' >/dev/null 2>&1; sleep 3; }
faucet_start() { vmssh poc@$FAUCET_IP 'sudo systemctl start faucet' >/dev/null 2>&1; wait_controller 60; sleep 5; }
radius_stop()  { vmssh poc@$RADIUS_IP 'sudo systemctl stop freeradius' >/dev/null 2>&1; }
radius_start() { vmssh poc@$RADIUS_IP 'sudo systemctl start freeradius' >/dev/null 2>&1; sleep 1; }
restore_all() {
  [[ "$(virsh domstate fw 2>/dev/null)" == paused ]] && virsh resume fw >/dev/null
  [[ "$(virsh domstate radius 2>/dev/null)" == paused ]] && virsh resume radius >/dev/null
  [[ "$(vmssh poc@$FAUCET_IP 'systemctl is-active faucet' 2>/dev/null)" == active ]] || faucet_start
  [[ "$(vmssh poc@$RADIUS_IP 'systemctl is-active freeradius' 2>/dev/null)" == active ]] || radius_start
  in_vm vm-unauth01 "ip link set eth0 address 02:00:00:00:01:03" 10 >/dev/null 2>&1
  reset_term vm-unauth01
  [[ "$(ip_of vm-biz01)" == 10.100.0.* ]]  || auth_dhcp vm-biz01 vm-biz01
  [[ "$(ip_of vm-inet01)" == 10.200.0.* ]] || auth_dhcp vm-inet01 vm-inet01
  echo "  복구 후: vm-biz01=$(ip_of vm-biz01) vm-inet01=$(ip_of vm-inet01) port VLAN 1=$(port_vid 1) 2=$(port_vid 2) 3=$(port_vid 3)"
}

# ---------- 시나리오 ----------
t01() { begin t01 "업무 단말 인증서로 인증"
  res "$(auth_dhcp vm-biz01 vm-biz01 && echo ok || echo fail)" ok "vm-biz01 인증 + DHCP"
  res "$(port_vid 1)" 100 "port 1 VLAN 100"
  local a; a=$(ip_of vm-biz01); res "${a%.*}" 10.100.0 "업무망 주소 ($a)"
  res "$(l2_reach vm-biz01 10.100.0.1 && echo ok || echo fail)" ok "업무망 게이트웨이 L2 도달"
  end; }

t02() { begin t02 "인터넷 단말 인증서로 인증 → 외부 통신"
  res "$(auth_dhcp vm-inet01 vm-inet01 && echo ok || echo fail)" ok "vm-inet01 인증 + DHCP"
  res "$(port_vid 2)" 200 "port 2 VLAN 200"
  local a; a=$(ip_of vm-inet01); res "${a%.*}" 10.200.0 "인터넷망 주소 ($a)"
  res "$(try in_vm vm-inet01 "ping -c2 -W3 $EXT_IP")" ok "외부 ping $EXT_IP"
  res "$(try in_vm vm-inet01 "getent hosts $EXT_HOST")" ok "외부 DNS $EXT_HOST"
  res "$(try in_vm vm-inet01 "curl -sf -m8 -o /dev/null http://$EXT_HOST")" ok "외부 HTTP"
  end; }

t03() { begin t03 "인증서 없이 접속"
  reset_term vm-unauth01
  res "$(try bash "$T" vm-unauth01 dhcp)" fail "DHCP 미수신"
  res "$(static_probe vm-unauth01 10.200.0.50/24 10.200.0.1 && echo ok || echo fail)" fail "주소를 직접 넣어도 인터넷망 게이트웨이 도달 불가"
  res "$(static_probe vm-unauth01 10.100.0.50/24 10.100.0.1 && echo ok || echo fail)" fail "주소를 직접 넣어도 업무망 게이트웨이 도달 불가"
  end; }

t04() { begin t04 "다른 CA 서명 위조 인증서 (CN=vm-biz01)"
  reset_term vm-unauth01
  bash "$S" vm-unauth01 start rogue-vm-biz01 >/dev/null
  res "$(try bash "$S" vm-unauth01 wait 20)" fail "인증 실패"
  res "$(port_vid 3)" $QVID "port 3 격리 VLAN 유지 (업무망으로 바뀌지 않음)"
  res "$(try bash "$T" vm-unauth01 dhcp)" fail "DHCP 미수신"
  reset_term vm-unauth01
  end; }

t05() { begin t05 "업무 단말 → 외부 (ping, DNS, HTTP)"
  [[ "$(ip_of vm-biz01)" == 10.100.0.* ]] || auth_dhcp vm-biz01 vm-biz01
  res "$(try in_vm vm-biz01 "ping -c2 -W2 $EXT_IP")" fail "외부 ping"
  res "$(try in_vm vm-biz01 "dig +short +time=2 +tries=1 @10.100.0.1 $EXT_HOST | grep -qE '^[0-9]+(\\.[0-9]+){3}\$'")" fail "DNS (fw 경유) 외부 이름"
  res "$(try in_vm vm-biz01 "dig +short +time=2 +tries=1 @$EXT_IP $EXT_HOST | grep -qE '^[0-9]+(\\.[0-9]+){3}\$'")" fail "DNS (외부 서버 직접)"
  res "$(try in_vm vm-biz01 "curl -sf -m5 -o /dev/null http://$EXT_IP")" fail "HTTP"
  end; }

t06() { begin t06 "업무 단말 ↔ 인터넷 단말"
  local b i; b=$(ip_of vm-biz01); i=$(ip_of vm-inet01)
  res "$(try in_vm vm-biz01 "ping -c2 -W2 $i")" fail "vm-biz01 → vm-inet01 ($i)"
  res "$(try in_vm vm-inet01 "ping -c2 -W2 $b")" fail "vm-inet01 → vm-biz01 ($b)"
  res "$(l2_reach vm-biz01 10.200.0.1 && echo ok || echo fail)" fail "vm-biz01 → 인터넷망 게이트웨이 L2"
  end; }

t07() { begin t07 "RADIUS 중지 중 정상 업무 인증서로 새 인증 시도"
  bash "$S" vm-biz01 logoff >/dev/null; sleep 2; reset_term vm-biz01
  res "$(port_vid 1)" $QVID "로그오프 후 port 1 격리 VLAN $QVID"
  radius_stop
  bash "$S" vm-biz01 start vm-biz01 >/dev/null
  res "$(try bash "$S" vm-biz01 wait 30)" fail "인증 실패"
  res "$(port_vid 1)" $QVID "port 1 이 업무망(100)으로 열리지 않음 (격리 유지)"
  res "$(try bash "$T" vm-biz01 dhcp)" fail "DHCP 미수신"
  note "기존 인증 단말 vm-inet01 → $EXT_IP: $(try in_vm vm-inet01 "ping -c2 -W3 $EXT_IP")"
  radius_start
  res "$(auth_dhcp vm-biz01 vm-biz01 && echo ok || echo fail)" ok "RADIUS 복구 후 재인증"
  end; }

t08() { begin t08 "faucet 컨트롤러 중지"
  bash "$S" vm-biz01 logoff >/dev/null; sleep 2; reset_term vm-biz01
  faucet_stop
  note "is_connected=$(ovs-vsctl get controller br-sdn is_connected), fail-mode=$(ovs-vsctl get-fail-mode br-sdn)"
  bash "$S" vm-biz01 start vm-biz01 >/dev/null
  res "$(try bash "$S" vm-biz01 wait 20)" fail "새 인증 불가 (정상 인증서)"
  res "$(try bash "$T" vm-biz01 dhcp)" fail "DHCP 미수신"
  res "$(static_probe vm-biz01 10.100.0.50/24 10.100.0.1 && echo ok || echo fail)" fail "주소를 직접 넣어도 업무망 도달 불가"
  res "$(static_probe vm-unauth01 10.200.0.50/24 10.200.0.1 && echo ok || echo fail)" fail "미인증 포트 3 차단 유지"
  res "$(port_vid 2)" 200 "인증된 port 2 는 VLAN 200 유지 (혼합 없음)"
  res "$(l2_reach vm-inet01 10.100.0.1 && echo ok || echo fail)" fail "vm-inet01 → 업무망 게이트웨이 L2 불가 (혼합 없음)"
  note "기존 인증 단말 vm-inet01 → $EXT_IP: $(try in_vm vm-inet01 "ping -c2 -W3 $EXT_IP") (ok 면 컨트롤러 장애 중 기존 세션 유지)"
  bash "$S" vm-inet01 logoff >/dev/null; sleep 3
  note "컨트롤러 없이 vm-inet01 로그오프 후 → $EXT_IP: $(try in_vm vm-inet01 "ping -c2 -W3 $EXT_IP") (ok 면 로그오프 미반영)"
  faucet_start
  note "재기동 후 인증 흐름 수 port1=$(authed_flow 1) port2=$(authed_flow 2)"
  res "$(auth_dhcp vm-biz01 vm-biz01 && echo ok || echo fail)" ok "컨트롤러 복구 후 vm-biz01 재인증"
  res "$(auth_dhcp vm-inet01 vm-inet01 && echo ok || echo fail)" ok "컨트롤러 복구 후 vm-inet01 재인증"
  end; }

t09() { begin t09 "fw·radius VM 정지 (방화벽 쪽 전체 장애 모사)"
  bash "$S" vm-unauth01 stop >/dev/null
  virsh suspend fw >/dev/null; virsh suspend radius >/dev/null
  res "$(try in_vm vm-inet01 "ping -c2 -W2 $EXT_IP")" fail "인터넷 단말 외부 불가"
  res "$(try in_vm vm-biz01 "ping -c2 -W2 $EXT_IP")" fail "업무 단말 외부 불가"
  bash "$S" vm-unauth01 start rogue-vm-biz01 >/dev/null
  res "$(try bash "$S" vm-unauth01 wait 15)" fail "새 인증 실패"
  res "$(port_vid 3)" $QVID "port 3 업무망으로 열리지 않음 (격리 유지)"
  reset_term vm-unauth01
  virsh resume fw >/dev/null; virsh resume radius >/dev/null; sleep 3
  res "$(try in_vm vm-inet01 "ping -c2 -W3 $EXT_IP")" ok "복구 후 인터넷 단말 외부 통신"
  end; }

t10() { begin t10 "vm-unauth01 에 vm-biz01 MAC 복제"
  reset_term vm-unauth01
  in_vm vm-unauth01 "ip link set eth0 address 02:00:00:00:01:01" 10 >/dev/null
  res "$(try bash "$T" vm-unauth01 dhcp)" fail "DHCP 미수신"
  res "$(static_probe vm-unauth01 10.100.0.50/24 10.100.0.1 && echo ok || echo fail)" fail "주소를 직접 넣어도 업무망 도달 불가"
  in_vm vm-unauth01 "ip link set eth0 address 02:00:00:00:01:03" 10 >/dev/null
  res "$(l2_reach vm-biz01 10.100.0.1 && echo ok || echo fail)" ok "원래 vm-biz01 통신 영향 없음"
  end; }

t11() { begin t11 "인증된 단말 EAPOL-Logoff"
  [[ "$(ip_of vm-biz01)" == 10.100.0.* ]] || auth_dhcp vm-biz01 vm-biz01
  res "$(l2_reach vm-biz01 10.100.0.1 && echo ok || echo fail)" ok "로그오프 전 업무망 도달"
  bash "$S" vm-biz01 logoff >/dev/null; sleep 2
  res "$(authed_flow 1)" 0 "port 1 인증 흐름 즉시 제거"
  res "$(l2_reach vm-biz01 10.100.0.1 && echo ok || echo fail)" fail "로그오프 후 차단"
  res "$(port_vid 1)" $QVID "port 1 격리 VLAN $QVID 복귀"
  local t0=$SECONDS
  bash "$S" vm-biz01 wait 90 >/dev/null
  note "같은 supplicant 재인증까지 $((SECONDS-t0))초 (chewie 선제 Identity 요청 주기 60초)"
  auth_dhcp vm-biz01 vm-biz01 >/dev/null
  end; }

t12() { begin t12 "큰 인증서(9.5KB) EAP-TLS 20회 반복 + MTU"
  local ok=0 i
  for i in $(seq 1 20); do
    reset_term vm-inet01
    bash "$S" vm-inet01 start vm-inet-big >/dev/null
    bash "$S" vm-inet01 wait 40 >/dev/null && ok=$((ok+1))
  done
  res "$ok" 20 "20회 중 성공 $ok회"
  res "$(auth_dhcp vm-inet01 vm-inet01 && echo ok || echo fail)" ok "원래 인증서로 복귀"
  res "$(try in_vm vm-inet01 "ping -M do -s 1472 -c3 -W3 $EXT_IP")" ok "단말 → 외부 1500바이트 프레임 단편화 없이 통과"
  end; }

t13() { begin t13 "관리망(10.255.0.0/24)에서 업무망 주소로 접근"
  [[ "$(ip_of vm-biz01)" == 10.100.0.* ]] || auth_dhcp vm-biz01 vm-biz01
  local b; b=$(ip_of vm-biz01)
  res "${b%.*}" 10.100.0 "전제: vm-biz01 업무망 주소 있음 ($b)"
  for ip in $RADIUS_IP $FAUCET_IP; do
    vmssh poc@$ip "sudo ip route replace 10.100.0.0/24 via $FW_IP; sudo ip route replace 10.200.0.0/24 via $FW_IP" >/dev/null 2>&1
    res "$(try vmssh poc@$ip "ping -c2 -W2 $b")" fail "$ip → vm-biz01 ($b)"
    res "$(try vmssh poc@$ip "ping -c2 -W2 10.100.0.1")" fail "$ip → fw 업무망 주소 10.100.0.1"
    vmssh poc@$ip "sudo ip route del 10.100.0.0/24; sudo ip route del 10.200.0.0/24" >/dev/null 2>&1
  done
  res "$(try ping -c2 -W2 -I br-mgmt "$b")" fail "SDN01 호스트(10.255.0.11) → vm-biz01"
  end; }

# ---------- 실행 ----------
echo "### 원격 Phase 7 $(date '+%F %T')  Faucet $(vmssh poc@$FAUCET_IP 'cat /etc/faucet/VERSION' 2>/dev/null), $(vmssh poc@$RADIUS_IP 'freeradius -v | head -1 | grep -o "Version [0-9.]*"' 2>/dev/null)"
[[ "$(vmssh poc@$FAUCET_IP 'cat /etc/faucet/MODE' 2>/dev/null)" == dot1x ]] || { echo "Faucet 이 dot1x 모드가 아님: 먼저 sudo tests/remote-phase6.sh"; exit 1; }
CASES=("$@"); ((${#CASES[@]})) || CASES=(t01 t02 t03 t04 t05 t06 t07 t08 t09 t10 t11 t12 t13)
for c in "${CASES[@]}"; do "$c"; done

ovs-ofctl -O OpenFlow13 dump-flows br-sdn > "$OUTD/remote-phase7-flows-end.txt"
vmssh poc@$FAUCET_IP 'tail -300 /var/log/faucet/faucet.log' > "$OUTD/remote-phase7-faucet.log" 2>&1
vmssh poc@$FW_IP 'sudo nft list ruleset' > "$OUTD/remote-phase7-nft.txt" 2>&1
echo; echo "===== 요약 ====="; cat "$SUMMARY"
echo "PASS $(grep -c ' PASS' "$SUMMARY") / FAIL $(grep -c ' FAIL' "$SUMMARY")"
! grep -q ' FAIL' "$SUMMARY"
