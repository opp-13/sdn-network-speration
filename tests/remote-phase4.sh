#!/usr/bin/env bash
# 원격(VM) Phase 3·4 완료 조건: 정적 VLAN + 경계 방화벽
# 전제: host-a/40-controller.sh, vm/deploy-faucet.sh static 완료
# 사용: sudo tests/remote-phase4.sh
# 결과: 화면 + tests/out/remote-phase4.txt, VLAN 태그 캡처 tests/out/remote-phase3-vlan.txt
source "$(dirname "$0")/../hosts/lib.sh"
need_root
set +e
exec > >(tee "$OUTD/remote-phase4.txt") 2>&1
trap fix_owner EXIT
T="$POC_REPO/vm/term.sh"
EXT_IP=1.1.1.1; EXT_HOST=example.com
ip_of() { bash "$T" "$1" run "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1" 10 2>/dev/null | head -1; }
echo "### 원격 Phase 3·4 $(date '+%F %T')  Faucet 모드: $(vmssh poc@$FAUCET_IP 'cat /etc/faucet/MODE 2>/dev/null')"

echo "== Phase 3: 컨트롤러·정적 VLAN"
res "$(ovs-vsctl get-fail-mode br-sdn)" secure "br-sdn fail-mode secure"
res "$(ovs-vsctl get controller br-sdn is_connected 2>/dev/null)" true "br-sdn ↔ Faucet 연결"
res "$(vmssh poc@$FAUCET_IP 'grep -c "DPID 1 (0x1)" /var/log/faucet/faucet.log' 2>/dev/null | awk '{print ($1>0)?"ok":"none"}')" ok "Faucet 로그에 datapath 0x1"

for t in vm-biz01 vm-inet01 vm-unauth01; do bash "$T" $t release >/dev/null 2>&1; done

# fw 쪽 트렁크 포트(tp-fw1, br-sdn port 10)에서 VLAN 태그 캡처 (Phase 3 완료 조건)
timeout 40 tcpdump -lnei tp-fw1 -c 20 vlan > "$OUTD/remote-phase3-vlan.txt" 2>&1 &
CAP=$!; sleep 1

echo "== Phase 4: 주소 수신"
res "$(try bash "$T" vm-biz01 dhcp)"  ok "vm-biz01 DHCP"
res "$(try bash "$T" vm-inet01 dhcp)" ok "vm-inet01 DHCP"
BIZ=$(ip_of vm-biz01); INET=$(ip_of vm-inet01)
echo "      vm-biz01=$BIZ  vm-inet01=$INET"
res "${BIZ%.*}"  10.100.0 "vm-biz01 주소가 업무망 10.100.0.0/24"
res "${INET%.*}" 10.200.0 "vm-inet01 주소가 인터넷망 10.200.0.0/24"

wait $CAP 2>/dev/null; kill $CAP 2>/dev/null
res "$(grep -c 'vlan 100' "$OUTD/remote-phase3-vlan.txt" | awk '{print ($1>0)?"ok":"none"}')" ok "fw 트렁크 포트에서 VLAN 100 태그 프레임 관측"
res "$(grep -c 'vlan 200' "$OUTD/remote-phase3-vlan.txt" | awk '{print ($1>0)?"ok":"none"}')" ok "fw 트렁크 포트에서 VLAN 200 태그 프레임 관측"

echo "== Phase 4: 정책"
# 주의: dig +short 는 시간 초과 시 ";; communications error ..." 를 표준출력에 찍는다 → IP 형태 응답만 "통함"으로 본다
res "$(try bash "$T" vm-inet01 run "ping -c2 -W3 $EXT_IP")" ok "inet01 → 외부 ping"
res "$(try bash "$T" vm-inet01 run "getent hosts $EXT_HOST")" ok "inet01 → 외부 DNS"
res "$(try bash "$T" vm-inet01 run "curl -sf -m8 -o /dev/null http://$EXT_HOST")" ok "inet01 → 외부 HTTP"
res "$(try bash "$T" vm-biz01 run "ping -c2 -W2 $EXT_IP")" fail "biz01 → 외부 ping 차단"
res "$(try bash "$T" vm-biz01 run "dig +time=2 +tries=1 @10.100.0.1 $EXT_HOST | grep -q 'status: NOERROR' && dig +short @10.100.0.1 $EXT_HOST | grep -qE '^[0-9]+(\\.[0-9]+){3}\$'")" fail "biz01 → DNS(fw 경유) 외부 이름 풀이 차단"
res "$(try bash "$T" vm-biz01 run "dig +time=2 +tries=1 +short @$EXT_IP $EXT_HOST | grep -qE '^[0-9]+(\\.[0-9]+){3}\$'")" fail "biz01 → 외부 DNS 서버 직접 차단"
res "$(try bash "$T" vm-biz01 run "curl -sf -m5 -o /dev/null http://$EXT_IP")" fail "biz01 → HTTP 차단"
res "$(try bash "$T" vm-biz01 run "ping -c2 -W2 $INET")" fail "biz01 → inet01 차단"
res "$(try bash "$T" vm-inet01 run "ping -c2 -W2 $BIZ")" fail "inet01 → biz01 차단"
res "$(try bash "$T" vm-unauth01 dhcp)" ok "vm-unauth01 DHCP (정적 모드에선 native VLAN inet — 802.1X 전 정상)"
bash "$T" vm-unauth01 release >/dev/null 2>&1

echo "== fw 차단 카운터"
vmssh poc@$FW_IP 'sudo nft list chain inet fw forward' 2>/dev/null | grep -E 'counter.*comment'
echo "== VLAN 태그 캡처 (앞부분)"; head -6 "$OUTD/remote-phase3-vlan.txt"
summary
