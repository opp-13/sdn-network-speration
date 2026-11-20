#!/usr/bin/env bash
# 이 PoC가 호스트 VM에 만든 브리지·유닛만 제거한다 (host-a, host-b 공통).
# 관리 NIC, 터널 NIC netplan(60-poc-tun.yaml), 설치한 패키지는 남긴다.
source "$(dirname "$0")/lib.sh"
need_root
set +e
role=$(my_role)
confirm "host-$role 의 PoC OVS 브리지(br-mgmt, br-sdn, br-trunk)와 poc-ip-* 유닛 삭제" \
"ovs-vsctl --if-exists del-br br-sdn / br-trunk / br-mgmt
systemctl disable --now poc-ip-*.service"
for u in /etc/systemd/system/poc-ip-*.service; do
  [[ -f "$u" ]] || continue
  systemctl disable --now "$(basename "$u")" >/dev/null 2>&1; rm -f "$u"
done
systemctl daemon-reload
for br in br-sdn br-trunk br-mgmt; do ovs-vsctl --if-exists del-br "$br"; done
log "완료"; ovs-vsctl show
