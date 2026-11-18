#!/usr/bin/env bash
# 로컬 lite 모드 패키지 설치 + 컨테이너 이미지 받기
source "$(dirname "$0")/lib.sh"
need_root

log "패키지 설치: openvswitch-switch"
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q openvswitch-switch
systemctl enable --now openvswitch-switch

log "컨테이너 이미지 받기"
docker pull "$FAUCET_IMAGE"
docker pull "$RADIUS_IMAGE"

log "확인"
ovs-vsctl --version | head -1
docker image inspect -f '{{.RepoTags}} {{.Created}}' "$FAUCET_IMAGE" "$RADIUS_IMAGE"
for t in wpa_supplicant nft dnsmasq busybox tcpdump openssl; do
  command -v "$t" >/dev/null && echo "ok: $t" || echo "없음: $t"
done
