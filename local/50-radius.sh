#!/usr/bin/env bash
# FreeRADIUS 컨테이너를 관리망(br-mgmt 10.255.0.20)에 기동 (계획서 Phase 5 배치 대응)
# 디버그 모드(-X)로 실행: docker logs poc-radius 로 요청·응답 확인
source "$(dirname "$0")/lib.sh"
need_root

log "설정 렌더링 (사용자 권한)"
sudo -u "${SUDO_USER:-root}" "$POC_REPO/local/radius-render.sh"
R="$POC_RUN/radius"

docker rm -f poc-radius >/dev/null 2>&1 || true
docker run -d --name poc-radius --network none \
  -v "$R/eap:/etc/freeradius/mods-available/eap:ro" \
  -v "$R/clients.conf:/etc/freeradius/clients.conf:ro" \
  -v "$R/authorize:/etc/freeradius/mods-config/files/authorize:ro" \
  -v "$R/certs:/etc/freeradius/certs/poc:ro" \
  "$RADIUS_IMAGE" -X >/dev/null
sleep 1
radius_attach

for _ in $(seq 1 15); do docker logs poc-radius 2>&1 | grep -q 'Ready to process requests' && break; sleep 1; done
docker logs poc-radius 2>&1 | grep -q 'Ready to process requests' || { docker logs poc-radius 2>&1 | tail -20; die "FreeRADIUS 기동 실패"; }
log "FreeRADIUS 준비됨 ($(docker logs poc-radius 2>&1 | grep -m1 -o 'FreeRADIUS Version [0-9.]*'))"
ip netns exec poc-faucet ping -c1 -W2 "${RADIUS_MGMT_IP%/*}" >/dev/null 2>&1 \
  && echo "faucet → radius 관리망 ping OK" || echo "경고: faucet 컨테이너에서 radius로 ping 실패 (faucet 미기동이면 무시)"
