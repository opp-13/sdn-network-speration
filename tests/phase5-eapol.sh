#!/usr/bin/env bash
# Phase 5: FreeRADIUS EAP-TLS 단독 시험 (Faucet 없이, sudo 불필요 — docker 그룹이면 됨)
# Docker 시험 네트워크 poc-radtest(172.31.255.0/24)에 RADIUS와 eapol_test 컨테이너를 띄운다.
# 사용: tests/phase5-eapol.sh [--keep]   (--keep: 끝나고 RADIUS 컨테이너 남김)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/local/env.local.sh"
NET=poc-radtest; RIP=172.31.255.20; RCTR=poc-radius-test
OUTD="$ROOT/tests/out"; mkdir -p "$OUTD"

# --- 준비: 인증서, 설정, 이미지 ---
"$ROOT/pki/make-ca.sh"
for n in vm-biz01 vm-inet01; do [[ -f "$ROOT/pki/certs/$n.pem" ]] || "$ROOT/pki/make-client.sh" "$n"; done
[[ -f "$ROOT/pki/certs/vm-inet-big.pem" ]] || "$ROOT/pki/make-client.sh" vm-inet-big 4096 --pad 6000
[[ -f "$ROOT/pki/certs/rogue-vm-biz01.pem" ]] || "$ROOT/pki/make-rogue.sh"
"$ROOT/local/radius-render.sh"
docker image inspect poc-eapol-test >/dev/null 2>&1 || docker build -q -t poc-eapol-test "$ROOT/tools/eapol-test"
SECRET=$(tr -d '\n' < "$ROOT/secrets/radius_secret")

# --- RADIUS 기동 ---
docker network inspect $NET >/dev/null 2>&1 || docker network create --subnet 172.31.255.0/24 $NET >/dev/null
docker rm -f $RCTR >/dev/null 2>&1
R="$POC_RUN/radius"
docker run -d --name $RCTR --network $NET --ip $RIP \
  -v "$R/eap:/etc/freeradius/mods-available/eap:ro" \
  -v "$R/clients.conf:/etc/freeradius/clients.conf:ro" \
  -v "$R/authorize:/etc/freeradius/mods-config/files/authorize:ro" \
  -v "$R/certs:/etc/freeradius/certs/poc:ro" \
  "$RADIUS_IMAGE" -X >/dev/null
for _ in $(seq 1 15); do docker logs $RCTR 2>&1 | grep -q 'Ready to process requests' && break; sleep 1; done
if ! docker logs $RCTR 2>&1 | grep -q 'Ready to process requests'; then
  echo "FAIL  FreeRADIUS 기동 실패"; docker logs $RCTR 2>&1 | tail -30; exit 1
fi
docker logs $RCTR 2>&1 | grep -m1 'FreeRADIUS Version'

pass=0; fail=0
# run_case <설명> <기대 SUCCESS|FAILURE> <기대 VLAN 이름|-> <identity> <cert> <key>
run_case() {
  local desc=$1 want=$2 vlan=$3 id=$4 cert=$5 key=$6 conf log got
  conf=$(mktemp); log="$OUTD/phase5-$id-$cert.log"
  "$ROOT/supplicant/render.sh" "$id" "$cert" "$key" /pki > "$conf"
  docker run --rm --network $NET -v "$ROOT/pki:/pki:ro" -v "$conf:/eapol.conf:ro" \
    poc-eapol-test -c /eapol.conf -a $RIP -s "$SECRET" -M 02:00:00:00:01:01 -t 15 > "$log" 2>&1
  got=$(tail -1 "$log"); rm -f "$conf"
  local ok=1
  [[ "$got" == "$want" ]] || ok=0
  if [[ $want == SUCCESS && $ok == 1 ]]; then
    # 응답 속성 확인: FreeRADIUS 디버그 로그의 마지막 Access-Accept 블록
    local acc; acc=$(docker logs $RCTR 2>&1 | awk '/Sent Access-Accept/{b=""; f=1} f{b=b $0 "\n"} /Finished request/{if(f){last=b}; f=0} END{printf "%s", last}')
    for a in 'Tunnel-Type = VLAN' 'Tunnel-Medium-Type = IEEE-802' "Tunnel-Private-Group-Id = \"$vlan\""; do
      grep -qF "$a" <<<"$acc" || { ok=0; echo "      속성 누락: $a"; }
    done
    [[ $ok == 1 ]] && echo "      응답 속성 3개 확인 (VLAN 이름: $vlan)"
  fi
  if [[ $ok == 1 ]]; then echo "PASS  $desc"; ((pass++)); else echo "FAIL  $desc (결과 $got, 로그 $log)"; ((fail++)); fi
}

echo "== Phase 5 EAP-TLS 시험 =="
run_case "vm-biz01 정상 인증서"                    SUCCESS biz  vm-biz01  vm-biz01       vm-biz01
run_case "vm-inet01 정상 인증서"                   SUCCESS inet vm-inet01 vm-inet01      vm-inet01
run_case "큰 인증서 (4096비트 + SAN 패딩, 단편화)"   SUCCESS inet vm-inet-big vm-inet-big vm-inet-big
run_case "위조 인증서 (다른 CA, CN=vm-biz01)"       FAILURE -    vm-biz01  rogue-vm-biz01 rogue-vm-biz01
run_case "사칭 (vm-inet01 인증서로 vm-biz01 행세)"  FAILURE -    vm-biz01  vm-inet01      vm-inet01

docker logs $RCTR > "$OUTD/phase5-radius-debug.log" 2>&1
if [[ "${1:-}" != "--keep" ]]; then
  docker rm -f $RCTR >/dev/null; docker network rm $NET >/dev/null
fi
echo; echo "결과: PASS $pass / FAIL $fail  (RADIUS 디버그 로그: tests/out/phase5-radius-debug.log)"
[[ $fail -eq 0 ]]
