#!/usr/bin/env bash
# 원격(VM) Phase 5: radius VM 단독 EAP-TLS 시험 (Faucet 없이, radius VM 안에서 eapol_test → 127.0.0.1)
# lite 의 tests/phase5-eapol.sh 와 같은 5개 시나리오
# 사용: sudo tests/remote-phase5.sh   (전제: sudo vm/deploy-radius.sh)
source "$(dirname "$0")/../hosts/lib.sh"
need_root
set +e
exec > >(tee "$OUTD/remote-phase5.txt") 2>&1
trap 'vmssh poc@$RADIUS_IP "rm -rf /tmp/poc-pki" 2>/dev/null; fix_owner' EXIT
SECRET=$(tr -d '\n' < "$POC_REPO/secrets/radius_secret")
P="$POC_REPO/pki"
echo "### 원격 Phase 5 $(date '+%F %T')  $(vmssh poc@$RADIUS_IP 'freeradius -v | head -1' 2>/dev/null)"
res "$(vmssh poc@$RADIUS_IP 'systemctl is-active freeradius' 2>/dev/null)" active "FreeRADIUS 실행 중"

# 시험용 인증서·설정을 radius VM 임시 디렉터리로 (끝나면 삭제)
stage=$(mktemp -d)
mkdir -p "$stage/poc-pki/certs" "$stage/poc-pki/private"
for c in ca vm-biz01 vm-inet01 vm-inet-big rogue-vm-biz01; do cp "$P/certs/$c.pem" "$stage/poc-pki/certs/"; done
for c in vm-biz01 vm-inet01 vm-inet-big rogue-vm-biz01; do cp "$P/private/$c.key" "$stage/poc-pki/private/"; done
tar -C "$stage" -czf "$stage/pki.tgz" poc-pki
vmscp "$stage/pki.tgz" "poc@$RADIUS_IP:/tmp/pki.tgz"
vmssh poc@$RADIUS_IP 'rm -rf /tmp/poc-pki; tar -xzf /tmp/pki.tgz -C /tmp && rm /tmp/pki.tgz && chmod -R go= /tmp/poc-pki'
rm -rf "$stage"

hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
# run_case <설명> <기대 SUCCESS|FAILURE> <기대 VLAN|-> <identity> <cert>
run_case() {
  # 주의: 한 local 문 안에서 앞 변수($id)를 쓰면 아직 비어 있다 → 따로 대입
  local desc=$1 want=$2 vlan=$3 id=$4 cert=$5 log got ok=1
  log="$OUTD/remote-phase5-$id-$cert.log"
  "$POC_REPO/supplicant/render.sh" "$id" "$cert" "$cert" /tmp/poc-pki \
    | vmssh poc@$RADIUS_IP "cat > /tmp/poc-pki/$cert.conf"
  vmssh poc@$RADIUS_IP "eapol_test -c /tmp/poc-pki/$cert.conf -a 127.0.0.1 -s '$SECRET' -M 02:00:00:00:01:01 -t 15" > "$log" 2>&1
  got=$(tail -1 "$log")
  [[ "$got" == "$want" ]] || ok=0
  if [[ $want == SUCCESS && $ok == 1 ]]; then
    # 마지막 Access-Accept 의 속성 (eapol_test 는 값을 16진수로 출력)
    local t64 t65 t81
    t64=$(grep -A1 'Attribute 64 (Tunnel-Type)' "$log" | tail -1 | awk '{print $2}')
    t65=$(grep -A1 'Attribute 65 (Tunnel-Medium-Type)' "$log" | tail -1 | awk '{print $2}')
    t81=$(grep -A1 'Attribute 81 (Tunnel-Private-Group-Id)' "$log" | tail -1 | awk '{print $2}')
    [[ "$t64" == 0000000d ]] || { ok=0; echo "      Tunnel-Type=$t64 (기대 0000000d=VLAN)"; }
    [[ "$t65" == 00000006 ]] || { ok=0; echo "      Tunnel-Medium-Type=$t65 (기대 00000006=IEEE-802)"; }
    [[ "$t81" == "$(hex "$vlan")" ]] || { ok=0; echo "      Tunnel-Private-Group-Id=$t81 (기대 $(hex "$vlan")=\"$vlan\")"; }
    [[ $ok == 1 ]] && echo "      응답 속성 3개 확인 (VLAN 이름 \"$vlan\" = $t81)"
  fi
  if [[ $ok == 1 ]]; then echo "PASS  $desc"; pass=$((pass+1)); else echo "FAIL  $desc (결과 $got, 로그 $log)"; fail=$((fail+1)); fi
}

echo "== EAP-TLS 시나리오"
run_case "vm-biz01 정상 인증서"                    SUCCESS biz  vm-biz01    vm-biz01
run_case "vm-inet01 정상 인증서"                   SUCCESS inet vm-inet01   vm-inet01
run_case "큰 인증서 (4096비트 + SAN 패딩, 단편화)"  SUCCESS inet vm-inet-big vm-inet-big
run_case "위조 인증서 (다른 CA, CN=vm-biz01)"      FAILURE -    vm-biz01    rogue-vm-biz01
run_case "사칭 (vm-inet01 인증서로 vm-biz01 행세)" FAILURE -    vm-biz01    vm-inet01
summary
