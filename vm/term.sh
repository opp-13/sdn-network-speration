#!/usr/bin/env bash
# 단말 VM 조작 (게스트 에이전트 — 네트워크를 거치지 않음, 원칙 3)
# 사용:
#   sudo vm/term.sh <VM> dhcp       # 주소 받기 (받으면 0, 못 받으면 1)
#   sudo vm/term.sh <VM> release    # 주소 반납
#   sudo vm/term.sh <VM> addr       # 현재 주소·경로
#   sudo vm/term.sh <VM> run '<명령>' [타임아웃]
set -uo pipefail
G="$(dirname "$0")/gexec.sh"
vm=${1:?VM}; cmd=${2:?명령}; shift 2

case "$cmd" in
  dhcp)
    bash "$G" "$vm" '
      ip link set eth0 up
      timeout 25 dhclient -1 eth0 >/dev/null 2>&1
      a=$(ip -4 -o addr show dev eth0 | awk "{print \$4}")
      [ -n "$a" ] || exit 1
      dns=$(grep -h "option domain-name-servers" /var/lib/dhcp/dhclient*.leases 2>/dev/null | tail -1 | sed "s/.*servers //; s/;//; s/,/ /g")
      [ -n "$dns" ] && resolvectl dns eth0 $dns 2>/dev/null && resolvectl domain eth0 "~." 2>/dev/null
      echo "$a dns=$dns"' 45
    ;;
  release)
    bash "$G" "$vm" 'dhclient -r eth0 >/dev/null 2>&1; pkill dhclient; ip addr flush dev eth0; ip route flush dev eth0; rm -f /var/lib/dhcp/dhclient*.leases; true' 20
    ;;
  addr)  bash "$G" "$vm" 'ip -4 -br addr show eth0; ip route' 10 ;;
  run)   bash "$G" "$vm" "$1" "${2:-60}" ;;
  *) echo "알 수 없는 명령: $cmd" >&2; exit 2 ;;
esac
