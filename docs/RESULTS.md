# 검증 결과 — 로컬 lite 모드

> 원격 2호스트(KVM VM) 모드 결과는 Proxmox 환경 구축 후 이 문서에 별도 절로 추가한다.

## 개요

| 항목 | 값 |
|---|---|
| 실행 일자 | 2026-11-18 |
| 환경 | 노트북 1대 (Ubuntu 26.04, 2코어/7GB), OVS 3.7.1 + 네트워크 네임스페이스 + 컨테이너 (PLAN.md 10장) |
| Faucet | 1.10.12 (`faucet/faucet:latest`, chewie 0.0.25) |
| RADIUS | FreeRADIUS 3.2.10 (`freeradius/freeradius-server:latest-3.2`), EAP-TLS만, TLS 1.2 |
| 동적 VLAN 응답값 형식 | **VLAN 이름** (`Tunnel-Private-Group-Id = "biz"`). 숫자는 미지원 (`valve.py add_dot1x_native_vlan`이 `vlan.name`과 비교) |
| 최종 결과 | **Phase 5: 5/5, Phase 6 관문: 11/11, Phase 7: 13/13 PASS** |

## 최종 토폴로지 (lite)

```
 br-mgmt 10.255.0.0/24 ── 노트북 .11 / poc-faucet .10 / poc-radius .20 / poc-fw eth0 .30
 br-sdn (secure, dpid 0x1, Faucet 제어)
   ├ 1  poc-biz01    eth0 (NIC 1개)
   ├ 2  poc-inet01   eth0
   ├ 3  poc-unauth01 eth0
   ├ 10 patch ── br-trunk ── poc-fw eth1 (eth1.100 10.100.0.1 / eth1.200 10.200.0.1)
   └ 20 poc-faucet eth1 (chewie, output_only)
 poc-fw eth2 ── 노트북 NAT ── 인터넷
```

## 시나리오 결과 (tests/lite-run-all.sh, 2026-11-18 15:27)

| 번호 | 시나리오 | 결과 | 근거·비고 |
|---|---|---|---|
| t01 | 업무 단말 인증서로 인증 | PASS | port 1 VLAN 200→100, 10.100.0.162 |
| t02 | 인터넷 단말 인증서로 인증 | PASS | VLAN 200, 10.200.0.163, 외부 ping·DNS·HTTP 성공 |
| t03 | 인증서 없이 접속 | PASS | DHCP 미수신, 고정 IP로도 양쪽 게이트웨이 ARP 무응답 |
| t04 | 다른 CA 서명 위조 인증서 | PASS | `certificate verify failed`로 Reject, 포트 VLAN 불변 |
| t05 | 업무 단말 → 외부 (ping, DNS, HTTP) | PASS | 모두 실패. 업무망 dnsmasq는 외부 포워딩 없음 |
| t06 | 업무 단말 ↔ 인터넷 단말 | PASS | 양방향 실패 (fw forward drop) |
| t07 | RADIUS 중지 후 새 단말 인증 | PASS | 인증 실패, port 3가 VLAN 100으로 열리지 않음. 기존 인증 단말은 통신 유지(관찰) |
| t08 | faucet 컨트롤러 중지 | PASS | 새 단말 인증·DHCP·고정 IP 모두 차단, 포트 VLAN 유지(혼합 없음). **한계: 아래 1번** |
| t09 | 호스트 B 중지 (fw 트렁크 down + RADIUS 중지) | PASS | 양 망 외부 불가, 새 인증 실패, 복구 후 정상 |
| t10 | 미인증 포트에 업무 단말 MAC 복제 | PASS | 인증 허용이 (포트, MAC) 쌍이라 차단. 원래 단말 영향 없음 |
| t11 | EAPOL-Logoff | PASS | 인증 흐름 즉시 제거, 차단, VLAN 200 복귀. **한계: 아래 2번** |
| t12 | 큰 인증서(4096비트, 9.5KB) 20회 반복 | PASS | 20/20 (EAP 단편화 정상). lite는 VXLAN이 없어 MTU 영향은 미검증 |
| t13 | 관리망 → 업무망 주소 | PASS | 1차 실행에서 결함 발견 후 수정 (아래 "발견·수정") |

## 계획서 대비 추가·수정한 사항

| 항목 | 내용 |
|---|---|
| NFV 포트 설정 | 계획서의 `20: native_vlan: inet`은 Faucet이 거부. `output_only: true`로 수정 |
| 인증서 CN = Identity 강제 | FreeRADIUS `check_cert_cn = %{User-Name}`. 없으면 인터넷 단말 인증서로 업무망 VLAN을 받아낼 수 있음 (Phase 5 사칭 시험으로 확인) |
| 미등록 단말 거부 | `DEFAULT Auth-Type := Reject`. CA가 서명했어도 목록에 없으면 거부 |
| dot1x 포트 기본 VLAN | `inet`. RADIUS가 VLAN을 안 주거나 이름이 틀려도 업무망으로는 가지 않음 |
| 업무망 DNS | 업무망 DHCP/DNS 인스턴스를 분리하고 외부 포워딩 제거 (t05 DNS 차단) |
| 서버 인증서 검증 | 단말이 `domain_match="radius.poc"`로 RADIUS 서버 인증서도 검증 (가짜 RADIUS 차단) |

## 발견·수정

1. **fw가 관리망에서 자신의 VLAN 쪽 주소로 오는 ping에 응답** (t13 1차 FAIL). 관리망 ping 허용 규칙에 목적지 제한이 없어 리눅스 weak host 모델로 10.100.0.1도 응답. 업무 단말까지는 도달하지 않음. → `ip daddr 10.255.0.30`으로 제한 + eth0에서 VLAN 대역 목적지 명시 차단. 재실행 PASS.
2. 시험 코드: fw는 VLAN → fw ping을 정책상 허용하지 않으므로 게이트웨이 ping으로 "통신 가능"을 판정하던 시험이 무의미했음. ARP 기반 판정(`l2_reach`)으로 교체 후 전체 재실행.

## 알려진 한계

1. **컨트롤러 장애 중에는 이미 인증된 단말이 계속 통신하고, 로그오프도 반영되지 않는다** (t08 관찰). Faucet 인증 흐름에 timeout이 없고 `fail-mode secure`는 기존 흐름을 지우지 않기 때문. 망 혼합은 없고 새 단말은 차단되므로 원칙 2(업무망에 새로 붙지 않음)는 지켜진다. 완전 차단이 필요하면 호스트에서 컨트롤러 연결 끊김을 감지해 br-sdn 흐름을 지우는 감시 스크립트를 둔다(가용성 희생).
2. **정적 VLAN 모드(Phase 3)에서는 컨트롤러가 꺼져도 같은 VLAN의 새 단말이 통신된다.** Faucet의 flood 흐름이 남기 때문. 802.1X 모드에서는 미인증 포트 drop 흐름이 남아 차단됨(t08). 운영은 802.1X 모드 전제.
3. **로그오프 후 같은 포트의 재인증이 45~78초 지연.** chewie가 로그오프 후 단말의 EAPOL-Start에 바로 반응하지 않고 60초 주기의 선제 Identity 요청 때 재인증. 보안 문제 아님, 가용성 한계.
4. **인증서는 유효하지만 VLAN 속성이 없는 단말은 인터넷망(native_vlan)에 붙는다.** 미등록 CN은 RADIUS에서 거부하므로 실제로는 authorize 파일 실수에서만 발생.
5. Faucet 802.1X는 공식 문서상 실험 기능. 실행 중 권한 변경(RFC 5176 CoA)은 미지원 → 격리 전환은 재인증으로 대체.
6. lite 모드는 VXLAN·MTU, 실제 VM 단말, 물리적 호스트 분리를 검증하지 않는다 → 원격 2호스트 모드에서 재검증 필요.

## 운영 전환 시 상용 장비로 옮길 정책

| 구분 | 내용 |
|---|---|
| VLAN 체계 | 업무망 100 (10.100.0.0/24), 인터넷망 200 (10.200.0.0/24), 관리망 분리. 802.1X 포트 기본 VLAN = 인터넷망 또는 격리 VLAN (업무망 금지) |
| 단말 분류 | 단말 인증서 CN = 단말 ID = RADIUS User-Name. RADIUS가 `Tunnel-Type=VLAN`, `Tunnel-Medium-Type=IEEE-802`, `Tunnel-Private-Group-Id=<VLAN>` 반환. 미등록 단말 거부, CN·Identity 일치 강제, MAB 미사용 |
| 방화벽 | 기본 drop. 업무망 → 외부 drop, 인터넷망 → 외부 NAT 허용, 업무망 ↔ 인터넷망 drop, VLAN → 방화벽은 DHCP·DNS만, 관리망 → VLAN(방화벽 VLAN 주소 포함) drop. 업무망 DNS는 외부 포워딩 금지 |
| 장애 시 동작 | 인증 서버·컨트롤러 장애 시 신규 인증 차단(fail-closed) 확인 항목으로 유지. 기존 세션 처리(유지/차단)는 운영 정책으로 결정 |

## 재현 방법

```bash
sudo local/10-packages.sh && sudo local/20-topology.sh
sudo local/30-faucet.sh static && sudo local/40-fw.sh && sudo tests/lite-phase4.sh
tests/phase5-eapol.sh                       # sudo 불필요
sudo tests/lite-phase6.sh                   # 802.1X 관문
sudo tests/lite-run-all.sh                  # t01~t13
sudo local/90-teardown.sh                   # 정리
```
