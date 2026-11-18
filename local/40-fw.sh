#!/usr/bin/env bash
# 경계 방화벽(poc-fw netns) 구성 (계획서 Phase 4 대응). 멱등.
source "$(dirname "$0")/lib.sh"
need_root
[[ -e /run/netns/poc-fw ]] || die "poc-fw 없음: 먼저 local/20-topology.sh"

FWX="ip netns exec poc-fw"

log "VLAN 서브 인터페이스"
for v in 100 200; do
  ip -n poc-fw link show "eth1.$v" &>/dev/null || ip -n poc-fw link add link eth1 name "eth1.$v" type vlan id "$v"
  ip -n poc-fw addr replace "10.$v.0.1/24" dev "eth1.$v"
  ip -n poc-fw link set "eth1.$v" up
done

log "nftables 적용"
$FWX nft -c -f "$POC_REPO/firewall/nftables.conf"
$FWX nft -f "$POC_REPO/firewall/nftables.conf"

log "dnsmasq (업무망/인터넷망 각각)"
mkdir -p "$POC_RUN/fw"
for net in biz inet; do
  pidf="$POC_RUN/fw/dnsmasq-$net.pid"
  if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
    kill "$(cat "$pidf")"; sleep 0.5
  fi
  extra=()
  [[ $net == inet ]] && extra=(--server="$FW_UPSTREAM_DNS")
  $FWX dnsmasq --conf-file="$POC_REPO/firewall/dnsmasq-$net.conf" \
    --user=root --pid-file="$pidf" \
    --dhcp-leasefile="$POC_RUN/fw/dnsmasq-$net.leases" \
    --log-facility="$POC_RUN/fw/dnsmasq-$net.log" "${extra[@]}"
done

log "결과"
ip -n poc-fw -br addr
$FWX ip route
$FWX nft list ruleset | head -5
