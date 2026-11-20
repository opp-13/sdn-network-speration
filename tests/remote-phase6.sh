#!/usr/bin/env bash
# 원격(VM) Phase 6 관문: 802.1X 인증 + RADIUS 응답에 따른 동적 VLAN (실제 VM 단말)
# 전제: sudo vm/deploy-radius.sh (Phase 5 통과)
# 사용: sudo tests/remote-phase6.sh
# 결과: 화면 + tests/out/remote-phase6.txt, 증거 tests/out/remote-phase6-*.txt
source "$(dirname "$0")/../hosts/lib.sh"
need_root
set +e
exec > >(tee "$OUTD/remote-phase6.txt") 2>&1
trap fix_owner EXIT
T="$POC_REPO/vm/term.sh"; S="$POC_REPO/vm/supp.sh"
QVID=999   # 미인증 포트의 격리 VLAN (faucet.dot1x.yaml quarantine)
ip_of() { bash "$T" "$1" run "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1" 10 2>/dev/null | head -1; }
port_vid() {
  ovs-ofctl -O OpenFlow13 dump-flows br-sdn | grep "in_port=$1,vlan_tci=0x0000/0x1fff" \
    | grep -o 'set_field:[0-9]*->vlan_vid' | head -1 | grep -o '[0-9]*' | awk '{print $1-4096}'
}
echo "### 원격 Phase 6 관문 $(date '+%F %T')"

echo "== 준비: Faucet 802.1X 모드"
bash "$POC_REPO/vm/deploy-faucet.sh" dot1x --restart || { echo "FAIL  dot1x 설정 적용"; exit 1; }
res "$(ovs-vsctl get controller br-sdn is_connected)" true "br-sdn ↔ Faucet 연결 (dot1x)"
res "$(vmssh poc@$RADIUS_IP 'systemctl is-active freeradius' 2>/dev/null)" active "FreeRADIUS 실행 중"
sleep 3
for t in vm-biz01 vm-inet01 vm-unauth01; do bash "$S" $t stop >/dev/null 2>&1; bash "$T" $t release >/dev/null 2>&1; done
ovs-ofctl -O OpenFlow13 dump-flows br-sdn > "$OUTD/remote-phase6-flows-before.txt"
echo "      인증 전 포트 VLAN: 1=$(port_vid 1) 2=$(port_vid 2) 3=$(port_vid 3)"
res "$(port_vid 1)$(port_vid 2)$(port_vid 3)" "$QVID$QVID$QVID" "인증 전 포트 1·2·3 모두 격리 VLAN $QVID"

echo "== 인증 전: 모든 단말 차단"
res "$(try bash "$T" vm-biz01 dhcp)"    fail "vm-biz01 인증 전 DHCP 차단"
res "$(try bash "$T" vm-unauth01 dhcp)" fail "vm-unauth01 DHCP 차단"

echo "== vm-biz01 인증 (인증서 vm-biz01)"
bash "$S" vm-biz01 start vm-biz01 >/dev/null
res "$(try bash "$S" vm-biz01 wait 40)" ok "vm-biz01 802.1X 인증 성공"
sleep 2
res "$(port_vid 1)" 100 "port 1 VLAN $QVID → 100 (RADIUS 응답 \"biz\")"
res "$(try bash "$T" vm-biz01 dhcp)" ok "vm-biz01 DHCP"
BIZ=$(ip_of vm-biz01); echo "      vm-biz01 = $BIZ"
res "${BIZ%.*}" 10.100.0 "vm-biz01 업무망 주소"

echo "== vm-inet01 인증 (인증서 vm-inet01)"
bash "$S" vm-inet01 start vm-inet01 >/dev/null
res "$(try bash "$S" vm-inet01 wait 40)" ok "vm-inet01 802.1X 인증 성공"
sleep 2
res "$(port_vid 2)" 200 "port 2 VLAN 200 (RADIUS 응답 \"inet\")"
res "$(try bash "$T" vm-inet01 dhcp)" ok "vm-inet01 DHCP"
INET=$(ip_of vm-inet01); echo "      vm-inet01 = $INET"
res "${INET%.*}" 10.200.0 "vm-inet01 인터넷망 주소"

echo "== vm-unauth01: 인증서 없음 / 위조 인증서"
res "$(try bash "$T" vm-unauth01 dhcp)" fail "vm-unauth01 (supplicant 없음) 주소 미수신"
bash "$S" vm-unauth01 start rogue-vm-biz01 >/dev/null
res "$(try bash "$S" vm-unauth01 wait 20)" fail "vm-unauth01 위조 인증서 인증 실패"
res "$(port_vid 3)" $QVID "port 3 가 격리 VLAN($QVID)에 머묾 (업무망으로 바뀌지 않음)"
res "$(try bash "$T" vm-unauth01 dhcp)" fail "vm-unauth01 위조 인증서로 주소 미수신"
bash "$S" vm-unauth01 stop >/dev/null

echo "== 증거"
ovs-ofctl -O OpenFlow13 dump-flows br-sdn > "$OUTD/remote-phase6-flows-after.txt"
vmssh poc@$FAUCET_IP 'grep -E "Success from|Failure from|Logoff from|Yay|DOT1X" /var/log/faucet/faucet.log | tail -30' > "$OUTD/remote-phase6-faucet-dot1x.txt" 2>&1
grep -E 'Success from|Failure from' "$OUTD/remote-phase6-faucet-dot1x.txt" | tail -4
for t in vm-biz01 vm-inet01 vm-unauth01; do bash "$S" $t log 60 > "$OUTD/remote-phase6-wpa-$t.txt" 2>&1; done
echo "      인증 후 포트 VLAN: 1=$(port_vid 1) 2=$(port_vid 2) 3=$(port_vid 3)"
echo "      인증 흐름(포트,MAC): $(ovs-ofctl -O OpenFlow13 dump-flows br-sdn table=0 | grep -oE 'in_port=[0-9]+,dl_src=[0-9a-f:]+' | tr '\n' ' ')"
summary
