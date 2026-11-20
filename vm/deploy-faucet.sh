#!/usr/bin/env bash
# Faucet 설정 배포 (faucet-ctl VM, 관리망 SSH)
# 사용: sudo vm/deploy-faucet.sh static|dot1x [--restart]   (--restart: 같은 모드여도 재시작 — 포트 VLAN 구성 변경 시)
#   faucet/faucet.<모드>.yaml → (dot1x면 secrets/radius_secret 으로 렌더링) → check_faucet_config 검증
#   → /etc/faucet/faucet.yaml 교체 → 모드가 바뀌면 재시작(802.1X 모듈은 기동 시에만 켜짐), 같으면 HUP
source "$(dirname "$0")/../hosts/lib.sh"
need_root
MODE=${1:?static|dot1x}
SRC="$POC_REPO/faucet/faucet.$MODE.yaml"; [[ -f "$SRC" ]] || die "$SRC 없음"
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
if grep -q '\${RADIUS_SECRET}' "$SRC"; then
  [[ -s "$POC_REPO/secrets/radius_secret" ]] || die "secrets/radius_secret 없음"
  RADIUS_SECRET=$(tr -d '\n' < "$POC_REPO/secrets/radius_secret") envsubst '${RADIUS_SECRET}' < "$SRC" > "$tmp"
else
  cp "$SRC" "$tmp"
fi
grep -Eq '^\s*routers:' "$tmp" && die "routers: 블록 금지 (설계 원칙 1)"

log "faucet-ctl 로 복사·검증 ($MODE)"
vmscp "$tmp" "poc@$FAUCET_IP:/tmp/faucet.candidate.yaml"
vmssh "poc@$FAUCET_IP" 'sudo /opt/faucet/bin/check_faucet_config /tmp/faucet.candidate.yaml >/dev/null' \
  || die "check_faucet_config 실패"
prev=$(vmssh "poc@$FAUCET_IP" 'cat /etc/faucet/MODE 2>/dev/null || echo static')
vmssh "poc@$FAUCET_IP" "sudo install -m 600 /tmp/faucet.candidate.yaml /etc/faucet/faucet.yaml && rm -f /tmp/faucet.candidate.yaml && echo $MODE | sudo tee /etc/faucet/MODE >/dev/null"
if [[ "$prev" != "$MODE" || "${2:-}" == --restart ]]; then
  log "faucet 재시작 ($prev → $MODE ${2:-})"
  vmssh "poc@$FAUCET_IP" 'sudo systemctl restart faucet'
else
  log "같은 모드: HUP 로 설정 재적용"
  vmssh "poc@$FAUCET_IP" 'sudo systemctl reload faucet'
fi
sleep 3
echo "faucet: $(vmssh "poc@$FAUCET_IP" 'systemctl is-active faucet')"
wait_controller 40 && echo "br-sdn is_connected: true" || echo "br-sdn is_connected: false"
