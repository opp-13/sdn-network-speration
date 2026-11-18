#!/usr/bin/env bash
# 단말 netns 조작 (virsh console 대신)
# 사용:
#   sudo local/term.sh <biz01|inet01|unauth01> dhcp       # 주소 받기 (실패 시 비0 종료)
#   sudo local/term.sh <name> release                     # 주소 반납
#   sudo local/term.sh <name> addr                        # 현재 주소
#   sudo local/term.sh <name> run <명령...>               # 단말 안에서 명령 실행
#   sudo local/term.sh <name> shell                       # 단말 셸
source "$(dirname "$0")/lib.sh"
need_root

name=${1:?단말 이름}; cmd=${2:?명령}; shift 2
ns="poc-$name"
[[ -e "/run/netns/$ns" ]] || die "$ns 없음"
X=(ip netns exec "$ns")

case "$cmd" in
  dhcp)
    "${X[@]}" env POC_NS="$ns" busybox udhcpc -i eth0 -n -q -f -t 4 -T 2 -A 1 \
      -s "$POC_REPO/local/udhcpc.script"
    ;;
  release)
    "${X[@]}" ip addr flush dev eth0
    "${X[@]}" ip route flush table main
    echo "# poc" > "/etc/netns/$ns/resolv.conf"
    ;;
  addr)  "${X[@]}" ip -br addr show dev eth0; "${X[@]}" ip route ;;
  run)   "${X[@]}" "$@" ;;
  shell) "${X[@]}" bash ;;
  *) die "알 수 없는 명령: $cmd" ;;
esac
