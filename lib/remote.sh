#!/usr/bin/env bash
# 공통 헬퍼: env.sh 로드, 원격 실행, 변경 전 확인.
# 사용: source "$(dirname "$0")/../lib/remote.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$REPO_ROOT/env.sh" ]]; then
  echo "env.sh가 없습니다. cp env.sh.example env.sh 후 값을 채우세요." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$REPO_ROOT/env.sh"

: "${SSH_OPTS:=-o BatchMode=yes -o ConnectTimeout=10}"

# 원격 명령 실행. 인자는 하나의 셸 스크립트 문자열로 전달된다.
run_a() { ssh $SSH_OPTS "$HOST_A_SSH" "bash -s" <<<"$*"; }
run_b() { ssh $SSH_OPTS "$HOST_B_SSH" "bash -s" <<<"$*"; }

# 호스트 네트워크를 바꾸는 명령 전에 호출한다.
# confirm "<영향 설명>" "<실행할 명령 문자열>"
confirm() {
  local impact="$1" cmds="$2"
  echo "===================================================="
  echo "영향 범위: $impact"
  echo "실행할 명령:"
  echo "$cmds" | sed 's/^/    /'
  echo "===================================================="
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    echo "(ASSUME_YES=1: 확인 생략)"
    return 0
  fi
  read -r -p "진행할까요? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
