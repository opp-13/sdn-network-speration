#!/usr/bin/env bash
# 단말 VM 안의 wpa_supplicant(유선 802.1X) 조작 — 게스트 에이전트 사용 (네트워크 비경유)
# 인증서·설정은 이미지 굽기 때 /etc/poc/ 에 들어가 있음 (vm/define.sh term_files)
# 사용:
#   sudo vm/supp.sh <VM> start <인증서 이름>   # 예: vm-biz01, vm-inet-big, rogue-vm-biz01
#   sudo vm/supp.sh <VM> wait [초]             # Authorized 될 때까지 (실패 시 1)
#   sudo vm/supp.sh <VM> status | logoff | stop | log
set -uo pipefail
G="$(dirname "$0")/gexec.sh"
vm=${1:?VM}; cmd=${2:?명령}; shift 2
g() { bash "$G" "$vm" "$1" "${2:-30}"; }

case "$cmd" in
  start)
    cert=${1:?인증서 이름}
    g "pkill -x wpa_supplicant; rm -rf /run/wpa_supplicant; ip link set eth0 up
       [ -f /etc/poc/wired-$cert.conf ] || { echo '이 VM 에 $cert 설정 없음'; exit 2; }
       : > /var/log/poc-wpa.log
       wpa_supplicant -B -D wired -i eth0 -c /etc/poc/wired-$cert.conf -P /run/poc-wpa.pid -f /var/log/poc-wpa.log" ;;
  wait)
    t=${1:-30}
    for _ in $(seq 1 "$t"); do
      g "wpa_cli -i eth0 status 2>/dev/null | grep -q '^suppPortStatus=Authorized'" 10 >/dev/null 2>&1 && { echo Authorized; exit 0; }
      sleep 1
    done
    echo "미인증: $(g "wpa_cli -i eth0 status 2>/dev/null | grep -E '^(EAP state|suppPortStatus)=' | tr '\n' ' '" 10)"; exit 1 ;;
  status) g "wpa_cli -i eth0 status" ;;
  logoff) g "wpa_cli -i eth0 logoff" ;;
  stop)   g "pkill -x wpa_supplicant; rm -rf /run/wpa_supplicant; true" ;;
  log)    g "tail -n ${1:-40} /var/log/poc-wpa.log" ;;
  *) echo "알 수 없는 명령: $cmd" >&2; exit 2 ;;
esac
