#!/usr/bin/env bash
# 두 호스트 VM의 시험 결과(~/$REMOTE_DIR/tests/out/) → 노트북 tests/out/remote/host-{a,b}/
# 읽기 전용 (원격에서 아무것도 바꾸지 않음).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/env.sh"
: "${REMOTE_DIR:=poc}"
for t in a b; do
  var="HOST_${t^^}_SSH"; host=${!var}
  dst="$ROOT/tests/out/remote/host-$t"; mkdir -p "$dst"
  rsync -az -e "ssh $SSH_OPTS" "$host:$REMOTE_DIR/tests/out/" "$dst/" 2>/dev/null \
    && echo "host-$t → $dst ($(ls "$dst" | wc -l)개 파일)" \
    || echo "host-$t: 가져올 결과 없음 또는 접속 실패"
done
