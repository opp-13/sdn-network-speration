#!/usr/bin/env bash
# Phase 3: br-sdn 의 컨트롤러를 faucet-ctl VM(10.255.0.10:6653, 관리망)으로 지정
source "$(dirname "$0")/../hosts/lib.sh"
need_root
require_role a

confirm "br-sdn 컨트롤러를 tcp:$FAUCET_IP:6653 으로 지정 (관리망 br-mgmt 경유). in-band 제어 끔(br-sdn 자체에는 IP 없음)" \
"ovs-vsctl set-controller br-sdn tcp:$FAUCET_IP:6653
ovs-vsctl set bridge br-sdn other-config:disable-in-band=true"

ovs-vsctl set bridge br-sdn other-config:disable-in-band=true
ovs-vsctl set-controller br-sdn "tcp:$FAUCET_IP:6653"
log "연결 대기"
wait_controller 40 && echo "is_connected: true" || echo "is_connected: false (faucet-ctl 의 faucet 서비스 확인)"
echo "fail-mode: $(ovs-vsctl get-fail-mode br-sdn)"
