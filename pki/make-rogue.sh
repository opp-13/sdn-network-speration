#!/usr/bin/env bash
# 공격 시나리오(t04)용: 별도 CA("rogue")로 서명한, CN=vm-biz01 위조 인증서
# 출력: pki/certs/rogue-ca.pem, pki/certs/rogue-vm-biz01.pem, pki/private/rogue-*.key
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p certs private && chmod 700 private

if [[ ! -f private/rogue-ca.key ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -keyout private/rogue-ca.key -out certs/rogue-ca.pem \
    -subj "/O=SDN-PoC/CN=SDN PoC Root CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign"
fi
openssl req -newkey rsa:2048 -nodes -sha256 -keyout private/rogue-vm-biz01.key \
  -out private/rogue.csr -subj "/O=SDN-PoC/CN=vm-biz01"
openssl x509 -req -in private/rogue.csr -CA certs/rogue-ca.pem -CAkey private/rogue-ca.key \
  -CAcreateserial -days 825 -sha256 -out certs/rogue-vm-biz01.pem \
  -extfile <(printf 'basicConstraints=CA:FALSE\nextendedKeyUsage=clientAuth\n')
rm -f private/rogue.csr
chmod 600 private/*.key
echo "위조 인증서: certs/rogue-vm-biz01.pem (발급자 이름은 진짜 CA와 같지만 키가 다름)"
