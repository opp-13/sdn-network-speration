# 진행 기록

## 2026-11-18 — Phase 0 착수

- 실행 위치: 작업용 노트북(Ubuntu 26.04, OVS·libvirt 미설치). 호스트 A·B는 원격 KVM 호스트로 SSH 제어.
- 합의: **호스트 관리 NIC(NIC 1)는 수정하지 않는다.** 새 브리지는 모두 별도로 만들고, 터널 IP가 필요하면 `/etc/netplan/60-poc-tun.yaml` 별도 파일로만 부여한다. (계획 승인으로 합의)
- 결정: fw VM 외부 출구 = eth2 → 호스트 B libvirt `default` NAT. 커밋은 사용자가 직접.
- 저장소 골격, `env.sh.example`, `lib/remote.sh`, `tests/phase0-precheck.sh` 작성.
- 대기: 호스트 A·B SSH 접속 정보.

## 2026-11-18 — 로컬 lite 모드로 전환

- 원격 호스트 미준비. 노트북 자원(2코어, 7GB, 여유 약 1GB)으로는 VM 6대 불가 → netns + 컨테이너 lite 모드로 Phase 3~7 선행 검증 (PLAN.md 10장).
- 원격 모드는 집 Proxmox에 Ubuntu 24.04 VM 2대(호스트 A: 4vCPU/8GB/100GB, 호스트 B: 2~4vCPU/6GB/60GB, CPU 타입 host, 터널용 내부 브리지 MTU 1550)로 추후 진행.
- 작성: `local/` 스크립트, `faucet/faucet.static.yaml`, `firewall/nftables.conf`, `firewall/dnsmasq-{biz,inet}.conf`, `tests/lite-phase4.sh`. 문법 검사(bash -n, nft -c, YAML) 통과.
- 노트북 sudo에 비밀번호가 필요해 root 단계는 사용자가 실행.

## 2026-11-18 — Faucet 이미지 확인 (sudo 불필요 단계)

- 이미지: `faucet/faucet:latest` = **Faucet 1.10.12** (chewie 0.0.25, 이미지 생성 2026-03-05), `freeradius/freeradius-server:latest-3.2` 받음.
- `faucet/faucet.static.yaml` → `check_faucet_config` 통과.
- Phase 6 관문 사전 확인 (소스 `valve.py:1729 add_dot1x_native_vlan`):
  - RADIUS `Tunnel-Private-Group-Id` 값을 **VLAN 이름**(`vlan.name == vlan_name`)으로만 비교한다. 숫자 `100`은 이름 `biz`와 일치하지 않는다 → 응답값은 이름(`biz`/`inet`)이어야 한다. (실제 동작은 Phase 6에서 확인)
  - 이름이 어느 VLAN과도 맞지 않거나 속성이 없으면, **인증은 성공하고 포트는 설정의 native_vlan에 남는다**(오류 없음). 따라서 dot1x 포트의 native_vlan을 `inet`으로 두면, 오설정 시 업무망이 아니라 인터넷망으로 떨어진다 → 원칙 2(fail-closed: 업무망에 붙지 않음)와 일치. 단, "인증서는 유효하지만 VLAN 미지정" 단말이 인터넷망을 쓰게 되는 점은 RESULTS의 알려진 한계로 기록할 것.

## 2026-11-18 — Phase 3~4 (lite) 적용, Phase 5 완료

- 사용자가 `local/20-topology.sh`, `30-faucet.sh static`, `40-fw.sh` 적용. DHCP 리스: biz01 → 10.100.0.162, inet01 → 10.200.0.163. Faucet 로그에 port 10에서 VLAN 100/200 학습 확인.
- Faucet 기동 직후 `send_flow_msgs: DP not up` ERROR 1회 — 스위치 연결 전 기동 순서 문제로 보이며, 이후 정상 학습.
- Phase 3 남은 조건(컨트롤러 중지 시 신규 통신 차단)용 `tests/lite-phase3-failsecure.sh` 작성. 실행 대기.
- Phase 5 (`tests/phase5-eapol.sh`, Docker 시험망에서 RADIUS 단독): **PASS 5/5**
  - FreeRADIUS 3.2.10, EAP-TLS만 허용, TLS 1.2, 신뢰 CA는 PoC CA 하나.
  - vm-biz01 → Accept + `Tunnel-Private-Group-Id = "biz"` 등 속성 3개, vm-inet01 → `"inet"`.
  - 큰 인증서(4096비트 + SAN 패딩, 9.5KB) → Accept (EAP 단편화 정상).
  - 위조 인증서(같은 발급자 이름, 다른 CA 키) → `certificate verify failed`로 Reject.
  - 사칭(vm-inet01 인증서 + identity vm-biz01) → `check_cert_cn`으로 Reject. 계획서에 없던 방어 추가: CN과 User-Name 일치 강제.
  - 등록되지 않은 CN은 `DEFAULT Auth-Type := Reject`로 거부.
- 수정: `pki/make-client.sh`의 `((i++))`가 `set -e`에서 종료되던 버그.

## 2026-11-18 — Phase 3 fail-secure 관찰: 정적 모드에서 신규 단말 통신 허용됨

- `tests/lite-phase3-failsecure.sh` 실행 (사용자). 증거: dnsmasq-inet 리스 파일 갱신 14:58:55에 unauth01(02:00:00:00:01:03) → 10.200.0.164 할당, Faucet 재기동은 14:58:58. **컨트롤러가 꺼진 상태에서 새 단말이 DHCP를 받았다.**
- 원인: `fail-mode secure`는 "독립 학습 스위치로 전환하지 않음"만 보장하고, 이미 설치된 흐름은 지우지 않는다. Faucet 정적 모드의 흐름에는 "모르는 출발지 → 컨트롤러로 보내면서 동시에 다음 테이블로", "모르는 목적지 → 해당 VLAN에 flood"가 있어서, 컨트롤러가 없어도 같은 VLAN 안의 새 단말은 통신된다.
- 망 혼합 여부: VLAN 태깅 흐름은 포트별로 고정이라 VLAN을 넘나들지는 않는다 (unauth01은 원래 native VLAN인 inet에서 주소를 받음).
- 판단: 정적 모드에서는 계획서 Phase 3 완료 조건("신규 통신 차단")을 **충족하지 못함**. 다만 운영 구조는 802.1X 모드이므로, 핵심은 dot1x 모드에서 미인증 포트 차단 흐름이 컨트롤러 중지 후에도 유지되는지(t08)다. Phase 6에서 확인한다.
- 대책 후보 (t08 결과에 따라 결정): 호스트에서 컨트롤러 연결 끊김을 감시해 br-sdn 흐름을 모두 지우는 감시 스크립트 → 컨트롤러 장애 시 전면 차단(가용성 희생, 완전 fail-closed).

## 2026-11-18 — Phase 6 준비

- `faucet/faucet.dot1x.yaml` 작성, `check_faucet_config` 통과.
  - **계획서 수정**: NFV 포트(20)는 `native_vlan: inet`이 아니라 `output_only: true`여야 한다. Faucet 1.10.12 `dp.py`: "NFV Ports must have output_only set to True."
  - EAPOL 경로: 각 dot1x 포트의 EAPOL 프레임 → 목적지 MAC을 포트별 가상 MAC으로 바꿔 port 20(Faucet eth1, chewie)으로 전달하는 흐름 쌍 (`valve_acl.py create_dot1x_flow_pair`).
- `30-faucet.sh`: 모드가 바뀌면(static↔dot1x) 컨테이너 재생성. chewie는 기동 시에만 시작되기 때문.
- 작성: `local/50-radius.sh` (RADIUS 관리망 기동), `local/supp.sh` (단말 wpa_supplicant), `tests/lite-phase6.sh` (관문 시험, 결과를 tests/out/에 저장).
- 관문 1단계(응답값 = 이름 "biz")만 시험한다. 2단계(숫자 "100")는 소스상 `vlan.name == vlan_name` 비교라 동작할 수 없어 생략하고, 근거를 이 기록으로 남긴다.

## 2026-11-18 — Phase 6 관문 통과 (lite)

- `sudo tests/lite-phase6.sh` → **PASS 11 / FAIL 0** (tests/out/phase6.txt). Faucet 1.10.12 + chewie 0.0.25, FreeRADIUS 3.2.10.
- **동적 VLAN 동작 확인: RADIUS `Tunnel-Private-Group-Id = "biz"`(VLAN 이름) → port 1 VLAN 200 → 100 변경.** 숫자는 시험하지 않음(소스상 이름 비교).
- 인증 전 biz01·unauth01 DHCP 차단, 인증 후 biz01 = 10.100.0.162, inet01 = 10.200.0.163, unauth01 끝까지 주소 없음.
- 흐름 구조 (tests/out/phase6-flows-after.txt):
  - 인증 허용은 **(포트, 출발지 MAC) 쌍**: `table=0 in_port=1,dl_src=02:00:00:00:01:01 → goto_table:1`. 미인증 포트는 EAPOL(0x888e)만 port 20으로 가고 나머지는 table 0 기본 drop.
  - 인증 흐름에 timeout 없음 → 컨트롤러가 죽어도 미인증 포트 차단은 유지될 것으로 예상(t08에서 확인). 반대로 컨트롤러가 죽으면 EAPOL-Logoff도 처리되지 않아 인증된 단말은 계속 통신될 것으로 예상.
- 30-faucet.sh의 20초 대기 안에 연결되지 않음(is_connected false) → 이후 6초 뒤 연결. 시험 스크립트는 30초 대기라 영향 없음. 대기 시간 늘림.

## 2026-11-18 — Phase 7 1차 실행 (lite): PASS 10 / FAIL 3 → 원인 분석

- 실행: `sudo tests/lite-run-all.sh` (tests/out/phase7.txt).
- **실제 결함 1건 (t13)**: 관리망(poc-radius, poc-faucet)에서 fw의 업무망 주소 10.100.0.1로 ping이 응답됨. 원인: nftables input 규칙 `iifname eth0 ip saddr 10.255.0.0/24 icmp echo-request accept`에 목적지 제한이 없어, 리눅스 weak host 모델로 fw의 VLAN 쪽 주소도 관리망에서 응답. 업무망 단말(biz01)까지는 가지 않음(PASS). 수정: `ip daddr 10.255.0.30`으로 제한 + eth0에서 VLAN 대역 목적지 명시 차단.
- **시험 코드 오류 2건 (t10, t11)**: "통신 가능" 확인을 fw 게이트웨이 ping으로 했는데, fw 정책상 VLAN → fw는 DHCP·DNS만 허용이라 ping은 항상 실패. 같은 이유로 t03·t08·t10의 "고정 IP로 게이트웨이 접근 차단" PASS는 **무의미한 PASS**였다. 수정: 게이트웨이 도달을 ARP 응답(L2)으로 판정하는 `l2_reach`로 교체 후 전체 재실행 필요.
- **발견 (t11)**: EAPOL-Logoff는 즉시 반영(port 1 인증 흐름 제거, VLAN 200 복귀). 그러나 **같은 포트의 재인증이 약 45초 지연**됨 — 로그오프 후 chewie 상태가 LOGOFF2에 머물다가 선제 Identity 요청(`DEFAULT_PREEMPTIVE_IDENTITY_REQUEST_INTERVAL = 60`초) 때 재인증. 보안 문제는 아니고 가용성 한계. 그 결과 t13 시점 biz01 주소가 없어 t13의 biz01 대상 시험도 무의미했음(전제 조건 검사 추가).
- 유효한 결과: t01·t02·t04·t05·t06·t07·t09·t12, t08의 "새 단말 인증 불가 / DHCP 미수신 / 포트 VLAN 유지".

## 2026-11-18 — Phase 7 재실행 (lite): PASS 13 / FAIL 0

- nftables 수정 적용(`local/40-fw.sh`) 후 `tests/lite-run-all.sh` 재실행 → 전 항목 PASS.
- 관찰: t07·t08에서 기존 인증 단말은 RADIUS/컨트롤러 장애 중에도 통신 유지, 컨트롤러 장애 중 EAPOL-Logoff 미반영. t11 재인증 78초.
- 결과 정리: docs/RESULTS.md. 남은 일: Phase 8 재구축 확인(teardown → 스크립트만으로 재구성), 원격 2호스트 모드.

## 2026-11-18 — 단말 추가 도구 `local/endpoint.sh`

- 목적: 임의의 netns 또는 Docker 컨테이너를 업무망/인터넷망에 붙여 시험.
- 원리: 영역은 포트가 아니라 인증서로 결정. 인증서(CN=ep-<이름>) 발급 → `freeradius/endpoints`(authorize에서 `$INCLUDE`)에 VLAN 등록 → RADIUS 재기동 → br-sdn 예비 포트 4~9에 연결 → 호스트 wpa_supplicant를 그 네임스페이스에서 실행해 802.1X → DHCP.
- 컨테이너는 `--network none` + veth 1개만 붙이므로 단말 NIC 1개 원칙 유지. 이미지 수정 불필요(supplicant·DHCP는 호스트 바이너리가 컨테이너 netns에서 실행).
- `faucet.dot1x.yaml`에 예비 포트 4~9 추가(check 통과), `30-faucet.sh dot1x --recreate` 옵션 추가. `$INCLUDE` 적용 후 Phase 5 회귀 시험 5/5 PASS.

## 2026-11-18 — 발견: 미인증 포트가 인터넷망 브로드캐스트를 수신

- GUIDE 4.2 태깅 구성도 작성 중 흐름 규칙 확인: `table=4, dl_vlan=200,dl_dst=ff:ff:ff:ff:ff:ff actions=output:10,pop_vlan,output:2,output:3` → 미인증 port 3에도 인터넷망 브로드캐스트·미지 유니캐스트 flood가 나감. dot1x 포트의 native_vlan이 inet이기 때문.
- 영향: 미인증 단말은 송신은 불가하지만 인터넷망 브로드캐스트(ARP, DHCP 등)를 수동 관찰 가능. 업무망은 해당 없음.
- 개선안(미적용): dot1x 포트 native_vlan을 트렁크에 없는 격리 VLAN(quarantine, VID 999)으로 변경. RESULTS 한계 4번(유효 인증서 + VLAN 속성 누락 → inet)도 함께 해결.
- 그 외 확인: access 포트는 태그 없는 프레임만 매칭(`vlan_tci=0x0000/0x1fff`) → 단말 자체 태깅 drop, 트렁크는 VLAN 100·200 태그만 수용(native 없음).
