#!/usr/bin/env bash
# host-a Phase 1: 패키지 (공통 스크립트 호출)
exec "$(dirname "$0")/../hosts/10-packages.sh" "$@"
