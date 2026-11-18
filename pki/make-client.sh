#!/usr/bin/env bash
# 단말 인증서 발급. CN = 단말 이름 = RADIUS User-Name.
# 사용: pki/make-client.sh <이름> [rsa 비트수(기본 2048)] [--pad <바이트>]
#   --pad: 인증서 크기를 키우기 위한 SAN 패딩 (t12 큰 인증서 / 단편화 시험용)
# 출력: pki/certs/<이름>.pem, pki/private/<이름>.key
set -euo pipefail
cd "$(dirname "$0")"
name=${1:?단말 이름}; bits=${2:-2048}; pad=0
[[ "${3:-}" == "--pad" ]] && pad=${4:?패딩 바이트}
[[ -f private/ca.key ]] || { echo "먼저 pki/make-ca.sh" >&2; exit 1; }

ext=$(mktemp); trap 'rm -f "$ext" private/'"$name"'.csr' EXIT
{
  echo "basicConstraints=CA:FALSE"
  echo "keyUsage=critical,digitalSignature,keyEncipherment"
  echo "extendedKeyUsage=clientAuth"
  san="DNS:$name.poc"
  if (( pad > 0 )); then
    i=0; while (( ${#san} < pad )); do san+=",DNS:pad$i-$(printf '%040d' 0).$name.poc"; i=$((i+1)); done
  fi
  echo "subjectAltName=$san"
} > "$ext"

openssl req -newkey "rsa:$bits" -nodes -sha256 -keyout "private/$name.key" \
  -out "private/$name.csr" -subj "/O=SDN-PoC/CN=$name"
openssl x509 -req -in "private/$name.csr" -CA certs/ca.pem -CAkey private/ca.key \
  -CAcreateserial -days 825 -sha256 -out "certs/$name.pem" -extfile "$ext"
chmod 600 "private/$name.key"
echo "발급: certs/$name.pem ($(wc -c < "certs/$name.pem") bytes)"
