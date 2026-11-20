#!/usr/bin/env bash
# 원격(VM): 격리 VLAN(quarantine, VID 999) 개선 검증 — 개선 전/후 비교
#
# 문제(GUIDE 4.2): dot1x 포트의 기본 VLAN 이 inet 이면, 인터넷망 브로드캐스트 흐름 규칙에
#   미인증 포트(3, 4~9)가 포함되어 미인증 단말이 인터넷망 브로드캐스트(ARP·DHCP 등)를 엿들을 수 있다.
# 개선: 기본 VLAN 을 트렁크에 싣지 않는 quarantine(999)으로.
#
# 순서: ① 지금 적용된 설정에서 측정(개선 전 관찰) → ② 개선 설정 배포(재시작) → ③ 검증(PASS/FAIL)
# 사용: sudo tests/remote-quarantine.sh      (약 5분)
# 결과: 화면 + tests/out/remote-quarantine.txt
source "$(dirname "$0")/../hosts/lib.sh"
need_root
set +e
exec > >(tee "$OUTD/remote-quarantine.txt") 2>&1
trap fix_owner EXIT
T="$POC_REPO/vm/term.sh"; S="$POC_REPO/vm/supp.sh"
QVID=999; INET_MAC=02:00:00:00:01:02

in_vm() { bash "$T" "$1" run "$2" "${3:-30}"; }
ip_of() { in_vm "$1" "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1" 10 2>/dev/null | head -1; }
port_vid() {
  ovs-ofctl -O OpenFlow13 dump-flows br-sdn | grep "in_port=$1,vlan_tci=0x0000/0x1fff" \
    | grep -o 'set_field:[0-9]*->vlan_vid' | head -1 | grep -o '[0-9]*' | awk '{print $1-4096}'
}
# VLAN 의 브로드캐스트 출력 포트 목록 (예: "10 2 3")
flood_ports() {
  ovs-ofctl -O OpenFlow13 dump-flows br-sdn | grep "dl_vlan=$1,dl_dst=ff:ff:ff:ff:ff:ff " \
    | head -1 | grep -o 'output:[0-9]*' | cut -d: -f2 | tr '\n' ' ' | sed 's/ $//'
}
l2_reach() {
  in_vm "$1" "ip neigh flush dev eth0; ping -c1 -W1 $2 >/dev/null 2>&1; sleep 0.5; ip neigh show $2 dev eth0 | grep -qE 'REACHABLE|STALE|DELAY|PROBE'" 15 >/dev/null 2>&1
}
reset_term() { bash "$S" "$1" stop >/dev/null 2>&1; bash "$T" "$1" release >/dev/null 2>&1; }
auth_dhcp() {
  reset_term "$1"; bash "$S" "$1" start "$2" >/dev/null || return 1
  bash "$S" "$1" wait "${3:-90}" >/dev/null || return 1
  sleep 2; bash "$T" "$1" dhcp >/dev/null
}

# 미인증 vm-unauth01 이 20초 동안 vm-inet01 이 만든 브로드캐스트를 몇 개 받는지
leak_count() {
  reset_term vm-unauth01
  in_vm vm-unauth01 "ip link set eth0 up; rm -f /tmp/q.txt; setsid sh -c 'timeout 20 tcpdump -lnei eth0 ether src $INET_MAC > /tmp/q.txt 2>/dev/null' >/dev/null 2>&1 &" 10 >/dev/null
  sleep 2
  # vm-inet01 에서 브로드캐스트 만들기: 없는 주소로 ARP 요청 + 서브넷 브로드캐스트 ping
  in_vm vm-inet01 "for i in 1 2 3; do ip neigh flush dev eth0; ping -c1 -W1 10.200.0.77 >/dev/null 2>&1; done; ping -b -c3 -i0.5 -W1 10.200.0.255 >/dev/null 2>&1; true" 30 >/dev/null
  sleep 20
  in_vm vm-unauth01 "grep -c . /tmp/q.txt 2>/dev/null || echo 0" 10 | tail -1
}

echo "### 격리 VLAN 검증 $(date '+%F %T')"

echo "== ① 개선 전 측정 (현재 faucet-ctl 에 적용된 설정)"
[[ "$(ip_of vm-inet01)" == 10.200.0.* ]] || auth_dhcp vm-inet01 vm-inet01
B_VID3=$(port_vid 3); B_FLOOD=$(flood_ports 200); B_LEAK=$(leak_count)
echo "  관찰  port 3(미인증) VLAN = $B_VID3"
echo "  관찰  인터넷망(200) 브로드캐스트 출력 포트 = [$B_FLOOD]"
echo "  관찰  미인증 vm-unauth01 이 받은 vm-inet01 프레임 = $B_LEAK 개"

echo "== ② 개선 설정 배포 (quarantine VID $QVID, 재시작)"
bash "$POC_REPO/vm/deploy-faucet.sh" dot1x --restart >/dev/null || { echo "FAIL  배포 실패"; exit 1; }
res "$(ovs-vsctl get controller br-sdn is_connected)" true "Faucet 재연결"
sleep 3
timeout 120 tcpdump -lnei tp-fw1 "vlan $QVID" > "$OUTD/remote-quarantine-trunk999.txt" 2>/dev/null &
CAP=$!

echo "== ③ 검증: 미인증 포트 격리"
reset_term vm-biz01; reset_term vm-inet01; reset_term vm-unauth01
res "$(port_vid 1)$(port_vid 2)$(port_vid 3)" "$QVID$QVID$QVID" "인증 전 포트 1·2·3 = 격리 VLAN $QVID"
# 예비 포트(4~9)는 연결된 VM 이 없으면 스위치에 포트 자체가 없어 흐름이 설치되지 않는다(= 전부 차단).
# → 연결돼 있으면 흐름으로, 없으면 Faucet 에 적용된 설정값으로 확인
if ovs-ofctl -O OpenFlow13 show br-sdn | grep -qE '^ *4\('; then
  res "$(port_vid 4)" $QVID "예비 포트 4 = 격리 VLAN $QVID"
else
  echo "  관찰  예비 포트 4: 연결된 단말 없음 → 흐름 없음(전부 차단)"
  res "$(vmssh poc@$FAUCET_IP "sudo grep -E '^ +[4-9]: ' /etc/faucet/faucet.yaml | grep -c 'native_vlan: quarantine'" 2>/dev/null)" 6 "예비 포트 4~9 설정 native_vlan = quarantine"
fi
res "$(ovs-ofctl -O OpenFlow13 dump-flows br-sdn | grep -c "in_port=10,dl_vlan=$QVID")" 0 "트렁크(port 10)는 VLAN $QVID 를 받지 않음"
res "$(flood_ports $QVID | tr ' ' '\n' | grep -cx 10)" 0 "격리 VLAN 브로드캐스트는 트렁크로 나가지 않음"

echo "== ③ 검증: 정상 인증은 그대로"
res "$(auth_dhcp vm-biz01 vm-biz01 && echo ok || echo fail)" ok "vm-biz01 인증 + DHCP"
res "$(port_vid 1)" 100 "port 1 → VLAN 100"
res "$(auth_dhcp vm-inet01 vm-inet01 && echo ok || echo fail)" ok "vm-inet01 인증 + DHCP"
res "$(port_vid 2)" 200 "port 2 → VLAN 200"
res "$(try in_vm vm-inet01 "ping -c2 -W3 1.1.1.1")" ok "vm-inet01 외부 통신"

echo "== ③ 검증: 엿듣기 차단 (개선의 핵심)"
A_FLOOD=$(flood_ports 200)
echo "  관찰  인터넷망(200) 브로드캐스트 출력 포트 = [$A_FLOOD]  (개선 전 [$B_FLOOD])"
res "$(echo " $A_FLOOD " | grep -cE ' (3|4|5|6|7|8|9) ')" 0 "인터넷망 브로드캐스트가 미인증 포트(3~9)로 나가지 않음"
A_LEAK=$(leak_count)
res "$A_LEAK" 0 "미인증 vm-unauth01 이 인터넷망 브로드캐스트를 받지 못함 (개선 전 $B_LEAK 개 → 개선 후 $A_LEAK 개)"
res "$(try bash "$T" vm-unauth01 dhcp)" fail "vm-unauth01 주소 미수신"

echo "== ③ 검증: 로그오프하면 격리로 복귀"
bash "$S" vm-biz01 logoff >/dev/null; sleep 2
res "$(port_vid 1)" $QVID "vm-biz01 로그오프 → port 1 격리 VLAN $QVID (인터넷망 아님)"
res "$(l2_reach vm-biz01 10.100.0.1 && echo ok || echo fail)" fail "로그오프 후 업무망 게이트웨이 도달 불가"
res "$(l2_reach vm-biz01 10.200.0.1 && echo ok || echo fail)" fail "로그오프 후 인터넷망 게이트웨이도 도달 불가"

kill $CAP 2>/dev/null; wait $CAP 2>/dev/null
res "$(grep -c . "$OUTD/remote-quarantine-trunk999.txt")" 0 "시험 중 fw 트렁크(tp-fw1)에 VLAN $QVID 프레임 0개"

echo "== 복구: vm-biz01 재인증 (로그오프 직후라 최대 90초)"
auth_dhcp vm-biz01 vm-biz01 && echo "  vm-biz01 = $(ip_of vm-biz01)"
summary
