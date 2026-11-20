#!/usr/bin/env bash
# Phase 2 완료 조건 검사 (host-a, host-b 각각, 읽기 전용)
# 결과: 화면 + tests/out/phase2-host-<a|b>.txt
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/../vm/vms.sh"
need_root
set +e
H=$(my_role)
exec > >(tee "$OUTD/phase2-host-$H.txt") 2>&1
trap fix_owner EXIT
G="$POC_REPO/vm/gexec.sh"
SSHI=(vmssh)   # hosts/lib.sh
echo "### Phase 2 검사 host-$H $(date '+%F %T')"

for v in $(vms_on_host "$H" | tr ' ' '#'); do
  v=${v//#/ }; name=$(vm_field "$v" 1); role=$(vm_field "$v" 3); nics=$(vm_field "$v" 6)
  res "$(virsh domstate "$name" 2>/dev/null)" running "$name 실행 중"
  res "$(virsh domiflist "$name" 2>/dev/null | grep -cE '^ *tp-')" "$(wc -w <<<"$nics")" "$name NIC 개수 $(wc -w <<<"$nics")"
  res "$(try virsh qemu-agent-command "$name" '{"execute":"guest-ping"}' --timeout 5)" ok "$name 게스트 에이전트 응답"
  [[ $role == term ]] && res "$("$G" "$name" 'ls /sys/class/net | grep -v lo | tr "\n" " "' 10 2>/dev/null)" "eth0 " "$name 안에서 보이는 NIC = eth0 하나"
  for nic in $nics; do
    IFS=, read -r kind tgt mac tap ofp addr <<<"$nic"
    [[ "$ofp" != - ]] && res "$(ovs-vsctl get interface "$tap" ofport 2>/dev/null)" "$ofp" "$name $tap = $tgt port $ofp"
  done
done

echo "== 호스트가 tap 을 건드리지 않는지 (OVS/Faucet 우회 경로 없음)"
res "$(ip -4 -o addr | awk '{print $2}' | grep -c '^tp-')" 0 "tp-* tap 에 호스트 IPv4 주소 없음"
res "$(networkctl list --no-pager 2>/dev/null | awk '$2 ~ /^tp-/ && $5 != "unmanaged"' | wc -l)" 0 "tp-* tap 은 systemd-networkd 관리 제외(unmanaged)"
if [[ -n "$(vm_entry fw)" && "$(vm_field "$(vm_entry fw)" 2)" == "$H" ]]; then
  res "$(ip -o link show tp-fw2 2>/dev/null | grep -o 'master [^ ]*' | awk '{print $2}')" virbr0 "fw 외부 NIC(tp-fw2)가 libvirt NAT 브리지 virbr0 에 연결"
fi

echo "== 관리 오버레이 (호스트 → 인프라 VM)"
for ip in 10.255.0.10 10.255.0.20 10.255.0.30; do
  res "$(try ping -c2 -W2 $ip)" ok "host-$H → $ip"
done

on_here() { [[ "$(vm_field "$(vm_entry "$1")" 2)" == "$H" ]]; }

if on_here faucet-ctl; then
  echo "== faucet-ctl 안"
  res "$(try "${SSHI[@]}" poc@10.255.0.10 'ping -c2 -W2 10.255.0.20 && ping -c2 -W2 10.255.0.30')" ok "faucet-ctl → radius, fw (관리망)"
  res "$("${SSHI[@]}" poc@10.255.0.10 'systemctl is-active faucet' 2>/dev/null)" active "Faucet 서비스 active"
  echo "관찰  Faucet: $("${SSHI[@]}" poc@10.255.0.10 'cat /etc/faucet/VERSION; systemctl show faucet -p NRestarts' 2>&1 | tr '\n' ' ')"
  echo "관찰  faucet-ctl eth1(port 20): $("${SSHI[@]}" poc@10.255.0.10 'ip -br link show eth1' 2>&1)"
fi

if on_here fw; then
  echo "== fw 안"
  res "$(try "${SSHI[@]}" poc@10.255.0.30 'ping -c2 -W2 10.255.0.10 && ping -c2 -W2 10.255.0.20')" ok "fw → faucet-ctl, radius (관리망)"
  res "$("${SSHI[@]}" poc@10.255.0.30 'sudo nft list chain inet fw forward | grep -c "policy drop"' 2>/dev/null)" 1 "fw nftables forward 기본 drop 적용"
  res "$(try "${SSHI[@]}" poc@10.255.0.30 'ping -c2 -W3 1.1.1.1')" ok "fw → 인터넷 (eth2, libvirt NAT)"
  res "$("${SSHI[@]}" poc@10.255.0.30 'ip -4 -o addr show eth2' 2>/dev/null | grep -c ' 192\.168\.122\.')" 1 "fw eth2 주소가 libvirt NAT 대역(192.168.122.0/24)"
  echo "관찰  fw 주소: $("${SSHI[@]}" poc@10.255.0.30 'ip -br -4 addr | grep -v ^lo' 2>&1 | tr '\n' ';')"
  echo "관찰  dnsmasq: $("${SSHI[@]}" poc@10.255.0.30 'systemctl is-active poc-dnsmasq@biz poc-dnsmasq@inet' 2>&1 | tr '\n' ' ')"
fi

if on_here radius; then
  echo "관찰  radius: $("${SSHI[@]}" poc@10.255.0.20 'freeradius -v | head -1; which eapol_test' 2>&1 | tr '\n' ' ')"
fi

echo; virsh list --all
[[ $H == a ]] && ovs-ofctl -O OpenFlow13 show br-sdn | grep -E '^\s*[0-9]+\('
summary
