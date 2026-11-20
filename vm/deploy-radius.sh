#!/usr/bin/env bash
# Phase 5: FreeRADIUS 설정·인증서를 radius VM(10.255.0.20)에 배포 (관리망 SSH)
#   lite 모드에서 검증한 freeradius/{eap,authorize,endpoints,clients.conf} + PoC CA·서버 인증서 그대로 사용
#   Ubuntu 패키지 구조(/etc/freeradius/3.0)에 배치 → freeradius -XC 로 설정 검사 → 재시작
#   clients.conf 에 radius VM 자신(127.0.0.1) 시험용 클라이언트 추가 (tests/remote-phase5.sh 의 eapol_test 용)
# 사용: sudo vm/deploy-radius.sh
source "$(dirname "$0")/../hosts/lib.sh"
need_root

log "설정 렌더링 (secrets/radius_secret, pki/)"
sudo -u "${SUDO_USER:-root}" "$POC_REPO/local/radius-render.sh" >/dev/null
R="$POC_REPO/run/radius"
SECRET=$(tr -d '\n' < "$POC_REPO/secrets/radius_secret")

stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
E="$stage/etc/freeradius/3.0"
mkdir -p "$E/mods-available" "$E/mods-config/files" "$E/certs/poc"
{ cat "$R/clients.conf"
  printf '\n# radius VM 자신 — tests/remote-phase5.sh 의 eapol_test 전용\nclient poc-localhost {\n\tipaddr = 127.0.0.1\n\tsecret = %s\n\trequire_message_authenticator = yes\n}\n' "$SECRET"
} > "$E/clients.conf"
cp "$R/eap" "$E/mods-available/eap"
cp "$R/authorize" "$R/endpoints" "$E/mods-config/files/"
cp -r "$R/certs/." "$E/certs/poc/"
tar -C "$stage" -czf "$stage/radius.tgz" etc

log "radius VM 으로 복사·적용"
vmscp "$stage/radius.tgz" "poc@$RADIUS_IP:/tmp/radius.tgz"
vmssh "poc@$RADIUS_IP" 'set -e
  sudo tar -xzf /tmp/radius.tgz -C / --no-same-owner && rm -f /tmp/radius.tgz
  D=/etc/freeradius/3.0
  sudo chown root:freerad $D/clients.conf $D/mods-available/eap $D/mods-config/files/authorize $D/mods-config/files/endpoints
  sudo chmod 640 $D/clients.conf $D/mods-available/eap $D/mods-config/files/authorize $D/mods-config/files/endpoints
  sudo chown -R root:freerad $D/certs/poc && sudo chmod -R u=rwX,g=rX,o= $D/certs/poc
  sudo ln -sfn ../mods-available/eap $D/mods-enabled/eap
  if ! sudo freeradius -XC > /tmp/radius-check.log 2>&1; then tail -25 /tmp/radius-check.log; exit 1; fi
  sudo systemctl restart freeradius
  sleep 1; systemctl is-active freeradius' || die "radius 배포 실패 (위 로그)"
log "완료: FreeRADIUS active, 설정 검사(freeradius -XC) 통과"
