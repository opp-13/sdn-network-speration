#!/usr/bin/env bash
exec "$(dirname "$0")/../hosts/90-teardown.sh" "$@"
