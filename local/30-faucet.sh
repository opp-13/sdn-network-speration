#!/usr/bin/env bash
# Faucet 컨테이너 기동/설정 적용 (계획서 Phase 3·6 대응)
# 사용: sudo local/30-faucet.sh static|dot1x
#   - 설정 파일을 check_faucet_config로 검증한 뒤 적용한다.
#   - 컨테이너가 없으면 만들고 eth0(br-mgmt 10.255.0.10), eth1(br-sdn port 20)을 붙인다.
#   - 이미 실행 중이면 설정만 바꾸고 HUP으로 다시 읽게 한다.
source "$(dirname "$0")/lib.sh"
need_root

MODE=${1:-static}
SRC="$POC_REPO/faucet/faucet.$MODE.yaml"
[[ -f "$SRC" ]] || die "설정 파일 없음: $SRC"
CFG_DIR="$POC_RUN/faucet"; LOG_DIR="$POC_RUN/faucet-log"
mkdir -p "$CFG_DIR" "$LOG_DIR"

log "설정 준비: $MODE"
if grep -q '\${RADIUS_SECRET}' "$SRC"; then
  SECRET_FILE="$POC_REPO/secrets/radius_secret"
  [[ -s "$SECRET_FILE" ]] || die "$SECRET_FILE 없음"
  RADIUS_SECRET=$(tr -d '\n' < "$SECRET_FILE") envsubst '${RADIUS_SECRET}' < "$SRC" > "$CFG_DIR/faucet.candidate.yaml"
else
  cp "$SRC" "$CFG_DIR/faucet.candidate.yaml"
fi
chmod 600 "$CFG_DIR/faucet.candidate.yaml"
grep -Eq '^\s*routers:' "$CFG_DIR/faucet.candidate.yaml" && die "routers: 블록 금지 (설계 원칙 1)"

log "check_faucet_config"
docker run --rm --network none --entrypoint check_faucet_config \
  -v "$CFG_DIR:/etc/faucet" "$FAUCET_IMAGE" /etc/faucet/faucet.candidate.yaml >/dev/null \
  || die "설정 검증 실패"
mv "$CFG_DIR/faucet.candidate.yaml" "$CFG_DIR/faucet.yaml"
echo "$MODE" > "$CFG_DIR/MODE"

running=$(docker inspect -f '{{.State.Running}}' poc-faucet 2>/dev/null || echo false)
if [[ "$running" == true ]]; then
  log "실행 중인 Faucet에 설정 재적용 (HUP)"
  docker kill -s HUP poc-faucet >/dev/null
else
  log "Faucet 컨테이너 기동"
  docker rm -f poc-faucet >/dev/null 2>&1 || true
  docker run -d --name poc-faucet --network none \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    -e FAUCET_CONFIG=/etc/faucet/faucet.yaml \
    -v "$CFG_DIR:/etc/faucet" -v "$LOG_DIR:/var/log/faucet" \
    "$FAUCET_IMAGE" >/dev/null
  sleep 1
  register_container_ns poc-faucet poc-faucet
  attach "$BR_MGMT" - poc-faucet v-fct0 eth0 "$FAUCET_MGMT_IP"
  attach "$BR_SDN" 20 poc-faucet v-fct1 eth1
fi

ovs-vsctl set-controller "$BR_SDN" "tcp:${FAUCET_MGMT_IP%/*}:6653"

log "Faucet 버전"
docker exec poc-faucet sh -c 'pip show faucet 2>/dev/null | grep -i ^version || python3 -c "import importlib.metadata as m; print(\"Version:\", m.version(\"faucet\"))"' \
  | tee "$POC_RUN/faucet-version.txt"

log "컨트롤러 연결 대기"
for _ in $(seq 1 20); do
  [[ "$(ovs-vsctl get controller "$BR_SDN" is_connected 2>/dev/null)" == true ]] && break
  sleep 1
done
echo "is_connected: $(ovs-vsctl get controller "$BR_SDN" is_connected)"
grep -E 'DPID 1|dp_id|Connected|connected' "$LOG_DIR/faucet.log" 2>/dev/null | tail -5 || true
