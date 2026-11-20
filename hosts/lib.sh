#!/usr/bin/env bash
# 호스트 VM(host-a / host-b) 안에서 실행하는 스크립트의 공통 함수.
# 저장소는 tools/push.sh로 ~/poc 에 복사되어 있고, env.sh도 함께 있다.
set -euo pipefail
POC_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$POC_REPO/env.sh" ]] || { echo "env.sh 없음: 노트북에서 tools/push.sh 로 복사하세요" >&2; exit 1; }
# shellcheck source=/dev/null
source "$POC_REPO/env.sh"
OUTD="$POC_REPO/tests/out"; mkdir -p "$OUTD"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date '+%T')" "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "root 권한 필요: sudo $0 $*"; }

# 구성: single = SDN01 한 대에 안쪽 VM 6대 전부 (기본), dual = 호스트 A·B 두 대 (계획서 원안)
POC_TOPOLOGY="${POC_TOPOLOGY:-single}"
is_single() { [[ "$POC_TOPOLOGY" == single ]]; }

# 이 VM이 어느 호스트인지: single이면 항상 a, dual이면 터널 NIC에 붙은 IP로 판단
my_role() {
  if is_single; then echo a
  elif ip -4 -o addr | grep -q " ${HOST_A_TUN_IP}/"; then echo a
  elif ip -4 -o addr | grep -q " ${HOST_B_TUN_IP}/"; then echo b
  else echo unknown; fi
}
require_role() {
  local r; r=$(my_role)
  [[ "$r" == "$1" ]] || die "이 스크립트는 host-$1 용입니다 (현재 VM 판정: host-$r). env.sh의 터널 IP와 netplan 확인"
}

# 호스트 네트워크를 바꾸기 전에 변경 내용을 보여 주고 확인받는다.
confirm() { # confirm "<영향 설명>" "<변경 내용>"
  echo "===================================================="
  echo "영향 범위: $1"
  echo "변경 내용:"; echo "$2" | sed 's/^/    /'
  echo "관리 NIC(${HOST_A_MGMT_NIC:-?}/${HOST_B_MGMT_NIC:-?})는 변경하지 않습니다."
  echo "===================================================="
  [[ "${ASSUME_YES:-0}" == 1 ]] && return 0
  read -r -p "진행할까요? [y/N] " ans; [[ "$ans" == y || "$ans" == Y ]] || die "취소"
}

# 인프라 VM(faucet-ctl, radius, fw) 관리망 SSH. PoC 전용 known_hosts 를 쓰고,
# VM 을 다시 만들면 vm/define.sh 가 그 VM 의 옛 호스트 키를 지운다.
POC_KNOWN=/root/.ssh/poc_known_hosts
vmssh() {
  ssh -i /root/.ssh/poc_ed25519 -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$POC_KNOWN" "$@"
}
vmscp() {
  scp -q -i /root/.ssh/poc_ed25519 -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$POC_KNOWN" "$@"
}
FAUCET_IP=10.255.0.10; RADIUS_IP=10.255.0.20; FW_IP=10.255.0.30
wait_controller() { # wait_controller [초]
  for _ in $(seq 1 "${1:-30}"); do
    [[ "$(ovs-vsctl get controller br-sdn is_connected 2>/dev/null)" == true ]] && return 0
    sleep 1
  done
  return 1
}

ipt_ensure() { local t=$1 c=$2; shift 2; iptables -t "$t" -C "$c" "$@" 2>/dev/null || iptables -t "$t" -I "$c" "$@"; }

# OVS 내부 포트(브리지 이름과 같은 인터페이스)에 IP를 주고 재부팅 후에도 유지되게 한다.
# netplan(관리 NIC 파일)은 건드리지 않고 별도 systemd 유닛으로 처리.
persist_ovs_ip() { # persist_ovs_ip <bridge> <cidr> <mtu>
  local br=$1 cidr=$2 mtu=$3 unit="/etc/systemd/system/poc-ip-$1.service"
  cat > "$unit" <<EOF
[Unit]
Description=PoC: IP for OVS bridge $br
After=openvswitch-switch.service network-online.target
Wants=openvswitch-switch.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ip link set $br mtu $mtu up
ExecStart=/usr/sbin/ip addr replace $cidr dev $br

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "poc-ip-$br.service" >/dev/null
  systemctl restart "poc-ip-$br.service"
}

# sudo로 만든 결과물을 원래 사용자 소유로 (tools/pull-results.sh가 읽을 수 있게)
fix_owner() { [[ -n "${SUDO_USER:-}" ]] && chown -R "$SUDO_USER:" "$OUTD" 2>/dev/null || true; }

# PASS/FAIL 집계
pass=0; fail=0
res() { if [[ "$1" == "$2" ]]; then echo "PASS  $3"; pass=$((pass+1)); else echo "FAIL  $3 (기대 $2, 실제 $1)"; fail=$((fail+1)); fi; }
try() { "$@" >/dev/null 2>&1 && echo ok || echo fail; }
summary() { echo; echo "결과: PASS $pass / FAIL $fail"; [[ $fail -eq 0 ]]; }
