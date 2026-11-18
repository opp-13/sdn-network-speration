#!/usr/bin/env bash
# 로컬 lite 모드 공통 함수
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.local.sh"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date '+%T')" "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "root 권한 필요: sudo $0 $*"; }

# NetworkManager가 PoC 인터페이스를 건드리지 않게 한다.
nm_unmanage() {
  command -v nmcli >/dev/null || return 0
  for i in "$@"; do nmcli device set "$i" managed no 2>/dev/null || true; done
}

# netns 생성(멱등) + IPv6 비활성화
ensure_ns() {
  local ns=$1
  [[ -e "/run/netns/$ns" ]] || ip netns add "$ns"
  ip -n "$ns" link set lo up
  ip netns exec "$ns" sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
  # ip netns exec 시 /etc/resolv.conf 대신 쓰일 파일 (호스트 resolv.conf 보호)
  mkdir -p "/etc/netns/$ns"
  [[ -f "/etc/netns/$ns/resolv.conf" ]] || echo "# poc" > "/etc/netns/$ns/resolv.conf"
}

# 컨테이너의 네트워크 네임스페이스를 ip netns 이름으로 노출
register_container_ns() {
  local ctr=$1 ns=$2 pid
  pid=$(docker inspect -f '{{.State.Pid}}' "$ctr")
  [[ "$pid" != 0 ]] || die "$ctr 컨테이너가 실행 중이 아님"
  mkdir -p /run/netns
  ln -sfT "/proc/$pid/ns/net" "/run/netns/$ns"
  ip netns exec "$ns" sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
}

# veth 한 쌍을 만들어 한쪽은 OVS 브리지에, 다른 쪽은 netns에 넣는다(멱등).
# attach <bridge> <ofport|-> <ns> <host_if> <ns_if> [cidr] [mac]
attach() {
  local br=$1 ofp=$2 ns=$3 hif=$4 nif=$5 cidr=${6:-} mac=${7:-}
  if ! ip link show "$hif" &>/dev/null; then
    ip link add "$hif" type veth peer name "${hif}-p"
    ip link set "${hif}-p" netns "$ns"
    ip -n "$ns" link set "${hif}-p" name "$nif"
  fi
  [[ -n "$mac" ]] && ip -n "$ns" link set "$nif" address "$mac"
  ip link set "$hif" mtu "$MTU" up
  ip -n "$ns" link set "$nif" mtu "$MTU" up
  ovs-vsctl --may-exist add-port "$br" "$hif"
  if [[ "$ofp" != "-" ]]; then
    ovs-vsctl set interface "$hif" ofport_request="$ofp"
  fi
  [[ -n "$cidr" ]] && ip -n "$ns" addr replace "$cidr" dev "$nif"
  nm_unmanage "$hif"
}

# 컨테이너(재)기동 후 관리망·br-sdn 연결
faucet_attach() {
  register_container_ns poc-faucet poc-faucet
  attach "$BR_MGMT" - poc-faucet v-fct0 eth0 "$FAUCET_MGMT_IP"
  attach "$BR_SDN" 20 poc-faucet v-fct1 eth1
}
radius_attach() {
  register_container_ns poc-radius poc-radius
  attach "$BR_MGMT" - poc-radius v-rad0 eth0 "$RADIUS_MGMT_IP"
}
wait_controller() {
  for _ in $(seq 1 "${1:-20}"); do
    [[ "$(ovs-vsctl get controller "$BR_SDN" is_connected 2>/dev/null)" == true ]] && return 0
    sleep 1
  done
  return 1
}

# sudo로 만든 결과물을 원래 사용자 소유로 (Claude가 읽을 수 있게)
fix_owner() {
  [[ -n "${SUDO_USER:-}" ]] || return 0
  chown -R "$SUDO_USER:" "$POC_REPO/tests/out" "$POC_RUN" 2>/dev/null || true
}

# 노트북 기본 경로 NIC (Wi-Fi 등)
wan_if() { ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'; }

# iptables 규칙 멱등 추가: ipt_ensure <table> <chain> <rule...>
ipt_ensure() {
  local t=$1 c=$2; shift 2
  iptables -t "$t" -C "$c" "$@" 2>/dev/null || iptables -t "$t" -I "$c" "$@"
}
ipt_remove() {
  local t=$1 c=$2; shift 2
  while iptables -t "$t" -D "$c" "$@" 2>/dev/null; do :; done
}

# Docker가 FORWARD 기본 정책을 DROP으로 두므로 DOCKER-USER 체인을 우선 사용
fwd_chain() { iptables -n -L DOCKER-USER &>/dev/null && echo DOCKER-USER || echo FORWARD; }
