#!/usr/bin/env bash
# PoC 포트 가드: 컨트롤러(Faucet) 장애 중 포트가 내려가거나 다시 생기면 그 포트의 흐름을 모두 지운다.
#
# 이유 (tests/remote-controller-outage.sh C 단계에서 실측):
#   Faucet 이 살아 있으면 포트 down 시 그 포트의 802.1X 인증 흐름(in_port, MAC)을 스스로 지운다.
#   컨트롤러가 죽어 있으면 지울 주체가 없어, 같은 번호로 다시 생긴 포트에서 옛 인증 흐름으로
#   재인증 없이 업무망에 붙을 수 있다 (MAC 복제 장비 교체 공격).
# 동작:
#   - 컨트롤러 연결 중: 아무것도 하지 않음 (Faucet 이 처리)
#   - 연결 끊김 + 포트 변화(down, 삭제, 재생성=ifindex 변경) → `del-flows in_port=<번호>`
#     → 그 포트는 table 0 기본 drop 에 걸려 완전 차단. 컨트롤러 복구 시 Faucet 이 다시 설치.
#   - PORT_GUARD_MODE=all: 연결이 끊기는 순간 br-sdn 흐름 전체 삭제 (기존 세션까지 모두 차단)
# 제외: 트렁크(10), Faucet 인증 포트(20)
BR=${PORT_GUARD_BR:-br-sdn}
MODE=${PORT_GUARD_MODE:-port}
SKIP=" ${PORT_GUARD_SKIP:-10 20} "
declare -A LAST
flushed_all=0
# systemd 가 표준출력을 저널에 SyslogIdentifier=poc-port-guard 로 남긴다 (logger 를 함께 쓰면 두 번 기록됨)
say() { echo "$*"; }

snapshot() { # 출력: "이름 ofport ifindex link_state" (br-sdn 포트만)
  local p
  for p in $(ovs-vsctl list-ports "$BR" 2>/dev/null); do
    echo "$p $(ovs-vsctl --bare get interface "$p" ofport ifindex link_state 2>/dev/null | tr '\n' ' ')"
  done
}

say "시작 (bridge=$BR, mode=$MODE, 제외 포트=$SKIP)"
while true; do
  conn=$(ovs-vsctl get controller "$BR" is_connected 2>/dev/null)
  declare -A NOW=()
  while read -r name ofp idx link; do
    [[ -n "$name" ]] && NOW[$name]="$ofp $idx $link"
  done < <(snapshot)

  if [[ "$conn" != true ]]; then
    if [[ "$MODE" == all && $flushed_all == 0 ]]; then
      ovs-ofctl -O OpenFlow13 del-flows "$BR"
      flushed_all=1; say "컨트롤러 연결 끊김 → $BR 흐름 전체 삭제 (mode=all)"
    fi
    # 사라졌거나 바뀐 포트
    for name in "${!LAST[@]}"; do
      read -r o_ofp o_idx o_link <<<"${LAST[$name]}"
      read -r n_ofp n_idx n_link <<<"${NOW[$name]:-- - -}"
      [[ "${LAST[$name]}" == "${NOW[$name]:-}" ]] && continue
      [[ "$o_link" == down && "$n_link" == down && "$o_ofp" == "$n_ofp" ]] && continue
      for ofp in $o_ofp $n_ofp; do
        [[ "$ofp" =~ ^[0-9]+$ && "$ofp" -gt 0 && "$SKIP" != *" $ofp "* ]] || continue
        ovs-ofctl -O OpenFlow13 del-flows "$BR" "in_port=$ofp" 2>/dev/null
        say "컨트롤러 장애 중 포트 변화: $name (ofport $o_ofp→$n_ofp, ifindex $o_idx→$n_idx, link $o_link→$n_link) → in_port=$ofp 흐름 삭제"
      done
    done
    # 새로 나타난 포트 (같은 번호에 남아 있을지 모를 옛 흐름 제거)
    for name in "${!NOW[@]}"; do
      [[ -n "${LAST[$name]:-}" ]] && continue
      read -r n_ofp _ _ <<<"${NOW[$name]}"
      [[ "$n_ofp" =~ ^[0-9]+$ && "$n_ofp" -gt 0 && "$SKIP" != *" $n_ofp "* ]] || continue
      ovs-ofctl -O OpenFlow13 del-flows "$BR" "in_port=$n_ofp" 2>/dev/null
      say "컨트롤러 장애 중 새 포트: $name (ofport $n_ofp) → in_port=$n_ofp 흐름 삭제"
    done
  else
    flushed_all=0
  fi

  LAST=()
  for name in "${!NOW[@]}"; do LAST[$name]="${NOW[$name]}"; done
  unset NOW
  sleep 1
done
