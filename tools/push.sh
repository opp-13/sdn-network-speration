#!/usr/bin/env bash
# 노트북 저장소 → 두 호스트 VM의 ~/$REMOTE_DIR 로 복사 (sudo 불필요).
# 포함: 스크립트, 설정, env.sh, secrets/, pki/ (개인키 포함 — PoC 전용 VM이므로)
# 제외: .git, run/, tests/out/ (호스트 쪽 결과는 지우지 않음)
# 사용: tools/push.sh [a|b]   (인자 없으면 둘 다)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/env.sh"
: "${REMOTE_DIR:=poc}"
if (($#)); then targets=("$@"); else targets=(a b); fi
for t in "${targets[@]}"; do
  var="HOST_${t^^}_SSH"; host=${!var}
  echo "== host-$t ($host:~/$REMOTE_DIR)"
  rsync -az --info=stats1 -e "ssh $SSH_OPTS" \
    --exclude .git/ --exclude run/ --exclude tests/out/ --exclude 'vm/images/' --exclude '*.qcow2' \
    "$ROOT/" "$host:$REMOTE_DIR/"
  ssh $SSH_OPTS "$host" "chmod 700 $REMOTE_DIR/secrets $REMOTE_DIR/pki/private 2>/dev/null; true"
done
