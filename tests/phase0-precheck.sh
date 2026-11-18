#!/usr/bin/env bash
# Phase 0 사전 점검 — 원격 호스트에 대해 읽기 전용 명령만 실행한다.
# 사용: tests/phase0-precheck.sh
# 결과: 화면 출력 + tests/out/phase0-<host>.txt
set -u
source "$(dirname "$0")/../lib/remote.sh"

OUT="$REPO_ROOT/tests/out"
mkdir -p "$OUT"

INSPECT='
echo "## hostname"; hostname
echo "## os"; . /etc/os-release; echo "$PRETTY_NAME"; uname -r
echo "## kvm"; ls -l /dev/kvm 2>&1; echo "vmx/svm flags: $(grep -Ec "(vmx|svm)" /proc/cpuinfo)"
command -v kvm-ok >/dev/null && kvm-ok 2>&1 | tail -1
echo "## cpu/mem"; nproc; free -g | sed -n 2p
echo "## disk"; df -h /var/lib/libvirt 2>/dev/null || df -h /var/lib
echo "## links"; ip -br link
echo "## addrs"; ip -br addr
echo "## mtu"; ip -o link | awk -F": " "{print \$2}" | while read -r n; do n=${n%@*}; printf "%s mtu %s\n" "$n" "$(cat /sys/class/net/$n/mtu 2>/dev/null)"; done
echo "## default route (=> 관리 NIC 후보)"; ip route get 1.1.1.1 2>&1 | head -1
echo "## ssh session iface"; [ -n "${SSH_CONNECTION:-}" ] && ip route get "$(echo $SSH_CONNECTION | cut -d" " -f1)" | head -1
echo "## sudo"; sudo -n true 2>/dev/null && echo "passwordless sudo: yes" || echo "passwordless sudo: no"
echo "## ovs"; if command -v ovs-vsctl >/dev/null; then ovs-vsctl --version | head -1; sudo -n ovs-vsctl show 2>&1 | head -40; else echo "ovs-vsctl: not installed"; fi
echo "## libvirt"; if command -v virsh >/dev/null; then virsh --version; sudo -n virsh net-list --all 2>&1; sudo -n virsh list --all 2>&1; else echo "virsh: not installed"; fi
echo "## netplan files"; ls -l /etc/netplan/ 2>&1
'

for h in A B; do
  var="HOST_${h}_SSH"; target="${!var}"
  log "호스트 $h ($target) 점검"
  if ! ssh $SSH_OPTS "$target" true 2>/dev/null; then
    echo "FAIL: 호스트 $h SSH 접속 실패 ($target)" | tee "$OUT/phase0-host$h.txt"
    continue
  fi
  ssh $SSH_OPTS "$target" "bash -s" <<<"$INSPECT" 2>&1 | tee "$OUT/phase0-host$h.txt"
done

# MTU 측정 (터널 IP가 env.sh에 있을 때만). A → B 방향, DF 설정.
if [[ -n "${HOST_A_TUN_IP:-}" && -n "${HOST_B_TUN_IP:-}" ]]; then
  log "MTU 측정: A($HOST_A_TUN_IP) → B($HOST_B_TUN_IP)"
  r1472=$(run_a "ping -M do -s 1472 -c 3 -W 2 -I $HOST_A_TUN_IP $HOST_B_TUN_IP >/dev/null 2>&1 && echo PASS || echo FAIL")
  r1522=$(run_a "ping -M do -s 1522 -c 3 -W 2 -I $HOST_A_TUN_IP $HOST_B_TUN_IP >/dev/null 2>&1 && echo PASS || echo FAIL")
  echo "ping -s 1472 (MTU 1500): $r1472"
  echo "ping -s 1522 (MTU 1550): $r1522"
  if [[ "$r1522" == PASS ]]; then echo "=> 권장 VM_MTU=1500"
  elif [[ "$r1472" == PASS ]]; then echo "=> 권장 VM_MTU=1450"
  else echo "=> 터널망 통신 불가: 터널 NIC/IP 확인 필요"; fi | tee "$OUT/phase0-mtu.txt"
else
  echo "HOST_A_TUN_IP / HOST_B_TUN_IP 미설정: MTU 측정 생략"
fi
