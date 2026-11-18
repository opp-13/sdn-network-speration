#!/usr/bin/env bash
# 사용: supplicant/render.sh <identity> <cert이름> <key이름> <PKI경로>
# 예:   supplicant/render.sh vm-biz01 vm-biz01 vm-biz01 /pki
#       supplicant/render.sh vm-biz01 rogue-vm-biz01 rogue-vm-biz01 /pki   (위조)
#       supplicant/render.sh vm-biz01 vm-inet01 vm-inet01 /pki             (사칭)
set -euo pipefail
IDENTITY=$1 CERT=$2 KEY=$3 PKI=$4 \
  envsubst '${IDENTITY} ${CERT} ${KEY} ${PKI}' < "$(dirname "$0")/wired.conf.tmpl"
