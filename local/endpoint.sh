#!/usr/bin/env bash
# 새 단말(네임스페이스 또는 Docker 컨테이너)을 업무망/인터넷망에 붙이고 시험한다.
# 영역은 포트가 아니라 "인증서 → RADIUS 응답 VLAN"으로 정해진다.
#
# 사용:
#   sudo local/endpoint.sh add  <이름> <biz|inet> [--container <이미지> [--cmd "<명령>"]]
#   sudo local/endpoint.sh test <이름>           # 영역·주소·도달성 표
#   sudo local/endpoint.sh exec <이름> <명령...>  # 단말 안에서 명령 (컨테이너면 docker exec)
#   sudo local/endpoint.sh list
#   sudo local/endpoint.sh del  <이름>
#
# 예:
#   sudo local/endpoint.sh add pc1 biz                                  # 업무망 PC(netns)
#   sudo local/endpoint.sh add web1 inet --container nginx:alpine       # 인터넷망 nginx
#   sudo local/endpoint.sh add box1 biz --container ubuntu:24.04 --cmd "sleep infinity"
#   sudo local/endpoint.sh test pc1
#
# 동작: ① 인증서 발급(CN=ep-<이름>) ② RADIUS 등록부(freeradius/endpoints)에 VLAN 기록 후 RADIUS 재기동
#       ③ netns/컨테이너 생성(NIC 1개) → br-sdn 예비 포트(4~9)에 연결
#       ④ 호스트의 wpa_supplicant를 그 네임스페이스에서 실행해 802.1X 인증 ⑤ DHCP
source "$(dirname "$0")/lib.sh"
need_root

REG="$POC_REPO/freeradius/endpoints"
STATE="$POC_RUN/endpoints"; mkdir -p "$STATE"
SPARE_PORTS=(4 5 6 7 8 9)
L="$POC_REPO/local"
as_user() { sudo -u "${SUDO_USER:-root}" "$@"; }

cmd=${1:?"명령: add|test|exec|list|del"}; shift || true

ep_ns()   { echo "poc-ep-$1"; }
ep_port() { cat "$STATE/$1.port" 2>/dev/null; }
ep_kind() { cat "$STATE/$1.kind" 2>/dev/null; }
ep_ip()   { ip -n "$(ep_ns "$1")" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1; }
port_vid() {
  ovs-ofctl -O OpenFlow13 dump-flows "$BR_SDN" | grep "in_port=$1,vlan_tci=0x0000/0x1fff" \
    | grep -o 'set_field:[0-9]*->vlan_vid' | head -1 | grep -o '[0-9]*' | awk '{print $1-4096}'
}
free_port() {
  local p n
  for p in "${SPARE_PORTS[@]}"; do
    for n in $(ls "$STATE"/*.port 2>/dev/null); do [[ "$(cat "$n")" == "$p" ]] && continue 2; done
    echo "$p"; return
  done
}
radius_restart() { log "RADIUS 재기동 (등록부 반영)"; "$L/50-radius.sh" >/dev/null || die "RADIUS 재기동 실패"; }
reg_del() { # 등록부에서 블록 제거
  as_user python3 - "$REG" "$1" <<'PY'
import sys,re
p,name=sys.argv[1],sys.argv[2]
s=open(p).read()
s=re.sub(r'(?m)^%s\n(?:[ \t].*\n)*\n?' % re.escape(name), '', s)
open(p,'w').write(s)
PY
}

case "$cmd" in
add)
  name=${1:?이름}; zone=${2:?"biz|inet"}; shift 2
  [[ "$name" =~ ^[a-z0-9]{1,12}$ ]] || die "이름은 소문자·숫자 12자 이내"
  [[ "$zone" == biz || "$zone" == inet ]] || die "영역은 biz 또는 inet"
  image=""; ccmd=""
  while (($#)); do case "$1" in
    --container) image=${2:?이미지}; shift 2 ;;
    --cmd) ccmd=${2:?명령}; shift 2 ;;
    *) die "알 수 없는 옵션: $1" ;;
  esac; done
  [[ "$(cat "$POC_RUN/faucet/MODE" 2>/dev/null)" == dot1x ]] || die "Faucet이 dot1x 모드가 아님"
  ovs-ofctl -O OpenFlow13 dump-flows "$BR_SDN" | grep -q 'in_port=4,' \
    || die "Faucet에 예비 포트(4~9)가 없음: sudo local/30-faucet.sh dot1x --recreate"
  [[ -f "$STATE/$name.port" ]] && die "$name 이미 있음 (del 후 다시)"
  port=$(free_port); [[ -n "$port" ]] || die "예비 포트(4~9)가 모두 사용 중"
  id="ep-$name"; ns=$(ep_ns "$name"); mac=$(printf '02:00:00:00:02:%02x' "$port")

  log "① 인증서 발급: CN=$id"
  [[ -f "$POC_REPO/pki/certs/$id.pem" ]] || as_user "$POC_REPO/pki/make-client.sh" "$id" >/dev/null 2>&1 \
    || die "인증서 발급 실패"

  log "② RADIUS 등록: $id → $zone"
  reg_del "$id"
  printf '%s\n\tTunnel-Type = VLAN,\n\tTunnel-Medium-Type = IEEE-802,\n\tTunnel-Private-Group-Id = "%s"\n\n' \
    "$id" "$zone" | as_user tee -a "$REG" >/dev/null
  radius_restart

  log "③ 단말 생성 → br-sdn port $port"
  if [[ -n "$image" ]]; then
    docker rm -f "$ns" >/dev/null 2>&1
    # shellcheck disable=SC2086
    docker run -d --name "$ns" --network none "$image" $ccmd >/dev/null || die "컨테이너 실행 실패"
    sleep 1
    [[ "$(docker inspect -f '{{.State.Running}}' "$ns")" == true ]] \
      || die "컨테이너가 바로 종료됨 — --cmd \"sleep infinity\" 를 붙여 보세요"
    register_container_ns "$ns" "$ns"
    mkdir -p "/etc/netns/$ns"; echo "# poc" > "/etc/netns/$ns/resolv.conf"
    echo "container" > "$STATE/$name.kind"
  else
    ensure_ns "$ns"
    echo "netns" > "$STATE/$name.kind"
  fi
  attach "$BR_SDN" "$port" "$ns" "v-ep$port" eth0 "" "$mac"
  echo "$port" > "$STATE/$name.port"; echo "$zone" > "$STATE/$name.zone"

  log "④ 802.1X 인증 ($id)"
  "$L/supp.sh" "ep-$name" start "$id" >/dev/null
  "$L/supp.sh" "ep-$name" wait 30 || die "인증 실패 — 로그: run/supplicant/ep-$name.log, docker logs poc-radius"
  sleep 2

  log "⑤ DHCP"
  "$L/term.sh" "ep-$name" dhcp >/dev/null || die "DHCP 실패"
  if [[ -n "$image" ]]; then  # 컨테이너의 resolv.conf에도 DNS 반영 (sh가 있는 이미지만)
    dns=$(awk '/^nameserver/{print $2; exit}' "/etc/netns/$ns/resolv.conf")
    [[ -n "$dns" ]] && docker exec "$ns" sh -c "echo nameserver $dns > /etc/resolv.conf" 2>/dev/null || true
  fi
  echo "완료: $name  영역=$zone  port=$port  VLAN=$(port_vid "$port")  IP=$(ep_ip "$name")"
  fix_owner
  ;;

test)
  name=${1:?이름}; [[ -f "$STATE/$name.port" ]] || die "$name 없음"
  ns=$(ep_ns "$name"); port=$(ep_port "$name")
  reach() { ip netns exec "$ns" ping -c1 -W2 "$1" >/dev/null 2>&1 && echo "도달" || echo "차단"; }
  arp() {
    ip -n "$ns" neigh flush dev eth0 2>/dev/null
    ip netns exec "$ns" ping -c1 -W1 "$1" >/dev/null 2>&1; sleep 0.5
    ip -n "$ns" neigh show "$1" dev eth0 | grep -qE 'REACHABLE|STALE|DELAY|PROBE' && echo "도달(ARP)" || echo "차단"
  }
  printf '%-28s %s\n' "단말" "$name ($(ep_kind "$name"), port $port)" \
    "등록 영역" "$(cat "$STATE/$name.zone")" \
    "현재 VLAN" "$(port_vid "$port")" \
    "802.1X" "$("$L/supp.sh" "ep-$name" status 2>/dev/null | sed -n 's/^suppPortStatus=//p')" \
    "IP" "$(ep_ip "$name")"
  echo "--- 도달성 ---"
  printf '%-28s %s\n' "업무망 게이트웨이 10.100.0.1" "$(arp 10.100.0.1)" \
    "인터넷망 게이트웨이 10.200.0.1" "$(arp 10.200.0.1)" \
    "외부 1.1.1.1" "$(reach 1.1.1.1)" \
    "관리망 fw 10.255.0.30" "$(reach 10.255.0.30)"
  for t in biz01 inet01; do
    a=$(ip -n "poc-$t" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    [[ -n "$a" ]] && printf '%-28s %s\n' "$t ($a)" "$(reach "$a")"
  done
  for f in "$STATE"/*.port; do
    o=$(basename "$f" .port); [[ "$o" == "$name" ]] && continue
    a=$(ep_ip "$o"); [[ -n "$a" ]] && printf '%-28s %s\n' "$o ($a)" "$(reach "$a")"
  done
  ;;

exec)
  name=${1:?이름}; shift
  if [[ "$(ep_kind "$name")" == container ]]; then docker exec -it "$(ep_ns "$name")" "$@"
  else ip netns exec "$(ep_ns "$name")" "$@"; fi
  ;;

list)
  printf '%-14s %-10s %-6s %-6s %-5s %s\n' 이름 종류 영역 포트 VLAN IP
  for f in "$STATE"/*.port; do
    [[ -f "$f" ]] || continue
    n=$(basename "$f" .port); p=$(cat "$f")
    printf '%-14s %-10s %-6s %-6s %-5s %s\n' "$n" "$(ep_kind "$n")" "$(cat "$STATE/$n.zone")" "$p" "$(port_vid "$p")" "$(ep_ip "$n")"
  done
  ;;

del)
  name=${1:?이름}; [[ -f "$STATE/$name.port" ]] || die "$name 없음"
  ns=$(ep_ns "$name"); port=$(ep_port "$name")
  "$L/supp.sh" "ep-$name" stop >/dev/null 2>&1
  if [[ "$(ep_kind "$name")" == container ]]; then docker rm -f "$ns" >/dev/null; rm -f "/run/netns/$ns"
  else ip netns del "$ns"; fi
  rm -rf "/etc/netns/$ns"
  ip link del "v-ep$port" 2>/dev/null; ovs-vsctl --if-exists del-port "$BR_SDN" "v-ep$port"
  reg_del "ep-$name"; radius_restart
  rm -f "$STATE/$name".*
  echo "삭제: $name (인증서 pki/certs/ep-$name.pem 은 남김)"
  ;;

*) die "알 수 없는 명령: $cmd" ;;
esac
