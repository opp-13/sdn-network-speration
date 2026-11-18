#!/usr/bin/env bash
# 단말 netns에서 wpa_supplicant(유선 802.1X) 조작
# 사용:
#   sudo local/supp.sh <단말> start <identity> [인증서 이름(기본=identity)]
#   sudo local/supp.sh <단말> wait [초]        # Authorized 될 때까지 대기 (실패 시 비0)
#   sudo local/supp.sh <단말> status
#   sudo local/supp.sh <단말> logoff           # EAPOL-Logoff 전송
#   sudo local/supp.sh <단말> stop
# 예: sudo local/supp.sh biz01 start vm-biz01
#     sudo local/supp.sh unauth01 start vm-biz01 rogue-vm-biz01   (위조 인증서)
source "$(dirname "$0")/lib.sh"
need_root

term=${1:?단말}; cmd=${2:?명령}; shift 2
ns="poc-$term"; [[ -e "/run/netns/$ns" ]] || die "$ns 없음"
D="$POC_RUN/supplicant"; CTRL="/run/poc-wpa/$term"
mkdir -p "$D" "$(dirname "$CTRL")"
PID="$D/$term.pid"; LOG="$D/$term.log"; CONF="$D/$term.conf"
cli() { ip netns exec "$ns" wpa_cli -p "$CTRL" -i eth0 "$@"; }

stop() {
  if [[ -f "$PID" ]] && kill -0 "$(cat "$PID")" 2>/dev/null; then kill "$(cat "$PID")"; sleep 0.5; fi
  rm -f "$PID"; rm -rf "$CTRL"
}

case "$cmd" in
  start)
    id=${1:?identity}; cert=${2:-$id}
    stop
    { echo "ctrl_interface=$CTRL"; echo "ap_scan=0";
      "$POC_REPO/supplicant/render.sh" "$id" "$cert" "$cert" "$POC_REPO/pki"; } > "$CONF"
    chmod 600 "$CONF"
    : > "$LOG"
    ip netns exec "$ns" wpa_supplicant -B -D wired -i eth0 -c "$CONF" -P "$PID" -f "$LOG" -dd
    echo "wpa_supplicant 시작: $term (identity=$id, cert=$cert)"
    ;;
  wait)
    t=${1:-20}
    for _ in $(seq 1 "$t"); do
      cli status 2>/dev/null | grep -q '^suppPortStatus=Authorized' && { echo "Authorized"; exit 0; }
      sleep 1
    done
    echo "미인증 ($(cli status 2>/dev/null | grep -E '^(EAP state|suppPortStatus)=' | tr '\n' ' '))"; exit 1
    ;;
  status) cli status ;;
  logoff) cli logoff ;;
  stop)   stop; echo "중지: $term" ;;
  *) die "알 수 없는 명령: $cmd" ;;
esac
