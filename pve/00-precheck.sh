#!/usr/bin/env bash
# P0: Proxmox 노드 사전 점검 (읽기 전용 — 아무것도 바꾸지 않음)
# 사용 (Proxmox 노드 root 셸):  bash 00-precheck.sh | tee /tmp/poc-pve-precheck.txt
# docs/PVE-PLAN.md P0 항목을 확인한다.
set -u
h() { echo; echo "## $*"; }

h "버전"
pveversion 2>/dev/null; uname -r
h "네트워크 설정 도구"
dpkg -l ifupdown2 2>/dev/null | awk '/^ii/{print $2, $3}'
echo "systemd-networkd: $(systemctl is-active systemd-networkd 2>/dev/null)  (active 면 tap 자동 설정 위험 — SDN01 vt-* 사고 참고)"
ls /etc/systemd/network/ /usr/lib/systemd/network/ 2>/dev/null | grep -E 'vt|tap|80-' | head
h "기존 브리지 (vmbr0·vmbr1 은 변경하지 않음)"
ip -br link | grep -E '^vmbr|^ovs|^tap|^fwbr' ; ip -br -4 addr | grep -E '^vmbr'
grep -nE '^(auto|iface|source)' /etc/network/interfaces
ls /etc/network/interfaces.d/ 2>/dev/null
h "vmbr1 (VXLAN 언더레이)"
ip -d link show vmbr1 | grep -oE 'mtu [0-9]+'; ip -br -4 addr show vmbr1
ping -M do -s 1522 -c2 -W2 10.10.0.1 >/dev/null 2>&1 && echo "SDN01(10.10.0.1)까지 1550바이트 DF: PASS" || echo "SDN01(10.10.0.1)까지 1550바이트 DF: FAIL"
h "Open vSwitch"
command -v ovs-vsctl >/dev/null && { ovs-vsctl --version | head -1; ovs-vsctl show; } || echo "미설치 (P1 에서 설치)"
dpkg -l openvswitch-switch 2>/dev/null | awk '/^ii/{print $2, $3}'
apt-cache policy openvswitch-switch 2>/dev/null | grep -E 'Installed|Candidate'
h "Proxmox 방화벽"
pve-firewall status 2>/dev/null
h "저장소 (snippets: cloud-init·hookscript 용)"
pvesm status 2>/dev/null
grep -nA6 '^dir: local$' /etc/pve/storage.cfg 2>/dev/null | grep -E 'content|path'
h "VM ID 사용 현황 (게스트 포트 번호 = 1000 + VMID, 100~999 범위)"
qm list 2>/dev/null
h "자원"
nproc; free -g | sed -n 2p; df -h /var/lib/vz | tail -1
