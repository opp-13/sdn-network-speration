#!/usr/bin/env bash
# PoC 전용 CA + RADIUS 서버 인증서 생성 (이미 있으면 건너뜀)
# 출력: pki/certs/ca.pem, pki/certs/radius.pem, pki/private/{ca,radius}.key
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p certs private && chmod 700 private
DAYS=825

if [[ ! -f private/ca.key ]]; then
  openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
    -keyout private/ca.key -out certs/ca.pem \
    -subj "/O=SDN-PoC/CN=SDN PoC Root CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
  echo "CA 생성: certs/ca.pem"
fi

if [[ ! -f private/radius.key ]]; then
  openssl req -newkey rsa:2048 -nodes -sha256 -keyout private/radius.key \
    -out private/radius.csr -subj "/O=SDN-PoC/CN=radius.poc"
  openssl x509 -req -in private/radius.csr -CA certs/ca.pem -CAkey private/ca.key \
    -CAcreateserial -days $DAYS -sha256 -out certs/radius.pem \
    -extfile <(printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:radius.poc\n')
  rm -f private/radius.csr
  echo "RADIUS 서버 인증서 생성: certs/radius.pem"
fi
chmod 600 private/*.key
