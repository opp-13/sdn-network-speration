#!/usr/bin/env bash
# P1 완료 조건 검사 (Proxmox 노드, 읽기 전용). 전제: 노드 10-network.sh + SDN01 host-a/60-pve-uplink.sh
set -u
pass=0; fail=0
res() { if [[ "$1" == "$2" ]]; then echo "PASS  $3"; pass=$((pass+1)); else echo "FAIL  $3 (기대 $2, 실제 $1)"; fail=$((fail+1)); fi; }
try() { "$@" >/dev/null 2>&1 && echo ok || echo fail; }
echo "### P1 검사 $(hostname) $(date '+%F %T')"
res "$(systemctl is-active openvswitch-switch)" active "openvswitch-switch 실행 중"
res "$(ovs-vsctl get-fail-mode vmbr10 2>/dev/null)" secure "vmbr10 fail-mode secure"
res "$(ovs-vsctl get bridge vmbr10 other-config:datapath-id 2>/dev/null | tr -d '"')" 0000000000000002 "vmbr10 dpid 0x2"
res "$(ovs-vsctl get interface vx-trunk ofport 2>/dev/null)" 10 "vx-trunk = vmbr10 port 10 (VXLAN key 110)"
res "$(ovs-vsctl get-controller vmbr10)" "tcp:10.255.0.40:6653" "vmbr10 컨트롤러 = faucet-pve"
res "$(ip -4 -o addr show vmbr11 | grep -c ' 10.255.0.13/24')" 1 "vmbr11 관리망 10.255.0.13"
res "$(ip -4 -o addr show vmbr10 | wc -l)" 0 "vmbr10 내부 포트에 IP 없음"
res "$(try ping -c2 -W2 10.255.0.11)" ok "관리망: 노드 → SDN01 호스트(10.255.0.11)"
res "$(try ping -c2 -W2 10.255.0.20)" ok "관리망: 노드 → radius(10.255.0.20)"
res "$(try ping -c2 -W2 10.255.0.10)" ok "관리망: 노드 → faucet-ctl(10.255.0.10)"
res "$(try ping -M do -s 1472 -c2 -W2 10.255.0.11)" ok "VXLAN(관리망) 위 1500바이트 DF 통과"
res "$(grep -c 'PoC VXLAN from SDN01' /etc/pve/nodes/$(hostname)/host.fw 2>/dev/null)" 1 "호스트 방화벽 VXLAN 허용 규칙"
res "$(awk '/^[a-z]+: /{blk=($0=="dir: local")} blk && $1=="content"{print $2}' /etc/pve/storage.cfg | grep -c snippets)" 1 "저장소 local 에 snippets 용도"
echo; echo "결과: PASS $pass / FAIL $fail"
