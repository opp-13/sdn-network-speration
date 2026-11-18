#!/usr/bin/env bash
# FreeRADIUS 설정·인증서를 run/radius/ 에 렌더링한다 (sudo 불필요).
# 비밀값은 secrets/radius_secret (없으면 생성). run/ 은 git 제외.
set -euo pipefail
source "$(dirname "$0")/env.local.sh"

SECRET_FILE="$POC_REPO/secrets/radius_secret"
mkdir -p "$POC_REPO/secrets"; chmod 700 "$POC_REPO/secrets"
if [[ ! -s "$SECRET_FILE" ]]; then
  openssl rand -hex 24 > "$SECRET_FILE"; chmod 600 "$SECRET_FILE"
  echo "RADIUS 공유 비밀 생성: secrets/radius_secret"
fi

PKI="$POC_REPO/pki"
[[ -f "$PKI/certs/radius.pem" ]] || "$PKI/make-ca.sh"

OUT="$POC_RUN/radius"
rm -rf "$OUT"; mkdir -p "$OUT/certs/trust"
RADIUS_SECRET=$(tr -d '\n' < "$SECRET_FILE") envsubst '${RADIUS_SECRET}' \
  < "$POC_REPO/freeradius/clients.conf" > "$OUT/clients.conf"
cp "$POC_REPO/freeradius/eap" "$POC_REPO/freeradius/authorize" "$POC_REPO/freeradius/endpoints" "$OUT/"
cp "$PKI/certs/ca.pem" "$PKI/certs/radius.pem" "$PKI/private/radius.key" "$OUT/certs/"
cp "$PKI/certs/ca.pem" "$OUT/certs/trust/$(openssl x509 -hash -noout -in "$PKI/certs/ca.pem").0"
# 컨테이너 안의 freerad 사용자가 읽을 수 있게 (run/ 은 로컬 전용)
chmod -R a+rX "$OUT"
echo "렌더링 완료: $OUT"
