#!/usr/bin/env bash
# 로컬 lite 모드가 만든 것만 제거한다. (다른 Docker 컨테이너·NIC는 건드리지 않음)
source "$(dirname "$0")/lib.sh"
need_root
set +e

log "컨테이너"
docker rm -f poc-faucet poc-radius 2>/dev/null
for c in $(docker ps -aq --filter name=^poc-ep-); do docker rm -f "$c" >/dev/null; done
rm -rf "$POC_RUN/endpoints"   # 등록부(freeradius/endpoints)는 남김

log "dnsmasq / wpa_supplicant"
for p in "$POC_RUN"/fw/*.pid "$POC_RUN"/supplicant/*.pid; do
  [[ -f "$p" ]] && kill "$(cat "$p")" 2>/dev/null; rm -f "$p"
done

log "netns"
for ns in $(ip netns list | awk '{print $1}' | grep '^poc-'); do
  ip netns del "$ns" 2>/dev/null || rm -f "/run/netns/$ns"
  rm -rf "/etc/netns/$ns"
done

log "veth / 브리지"
ip link del fw-egr 2>/dev/null
for br in "$BR_SDN" "$BR_TRUNK" "$BR_MGMT"; do ovs-vsctl --if-exists del-br "$br"; done
for i in $(ip -o link | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E '^v-(biz01|inet01|unauth01|fw0|fw1|fct0|fct1|rad0|ep[0-9])$'); do
  ip link del "$i"
done

log "iptables 규칙"
ipt_remove nat POSTROUTING -s "$EGR_NET" ! -o fw-egr -j MASQUERADE
for c in DOCKER-USER FORWARD; do
  ipt_remove filter "$c" -o fw-egr -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  ipt_remove filter "$c" -i fw-egr -j ACCEPT
done

log "완료 (run/ 디렉터리는 남겨 둠)"
