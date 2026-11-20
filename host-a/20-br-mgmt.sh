#!/usr/bin/env bash
# host-a Phase 1: 관리 오버레이 (공통 스크립트 호출)
exec "$(dirname "$0")/../hosts/20-br-mgmt.sh" "$@"
