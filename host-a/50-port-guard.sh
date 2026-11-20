#!/usr/bin/env bash
# 포트 가드 설치 (systemd 서비스 poc-port-guard). hosts/port-guard.sh 설명 참고.
# 사용: sudo host-a/50-port-guard.sh [port|all]   (기본 port)
source "$(dirname "$0")/../hosts/lib.sh"
need_root
require_role a
MODE=${1:-port}
[[ "$MODE" == port || "$MODE" == all ]] || die "모드는 port 또는 all"

confirm "포트 가드 서비스 설치 (mode=$MODE): 컨트롤러 장애 중 br-sdn 포트가 내려가거나 다시 생기면 그 포트 흐름 삭제$( [[ $MODE == all ]] && echo ', 장애 순간 br-sdn 흐름 전체 삭제')" \
"install hosts/port-guard.sh → /usr/local/sbin/poc-port-guard
/etc/systemd/system/poc-port-guard.service (PORT_GUARD_MODE=$MODE), enable --now"

install -m 755 "$POC_REPO/hosts/port-guard.sh" /usr/local/sbin/poc-port-guard
cat > /etc/systemd/system/poc-port-guard.service <<EOF
[Unit]
Description=PoC port guard: flush br-sdn port flows on port change while controller is down
After=openvswitch-switch.service
Requires=openvswitch-switch.service

[Service]
Environment=PORT_GUARD_MODE=$MODE
# 10 = fw 트렁크, 11 = Proxmox 노드 트렁크(vx-pve-trunk), 20 = Faucet 인증 포트
Environment="PORT_GUARD_SKIP=10 11 20"
ExecStart=/usr/local/sbin/poc-port-guard
SyslogIdentifier=poc-port-guard
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable poc-port-guard.service >/dev/null
systemctl restart poc-port-guard.service
sleep 1
systemctl is-active poc-port-guard.service
journalctl -u poc-port-guard --no-pager -n 3
