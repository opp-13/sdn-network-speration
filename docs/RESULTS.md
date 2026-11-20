# 검증 결과

> 처음 보는 사람은 입문 가이드 [GUIDE.md](GUIDE.md)부터 읽기.
>
> 이 문서는 두 환경의 결과를 담는다. **A. 원격 VM 모드**(Proxmox, 실제 VM 단말)와 **B. 로컬 lite 모드**(노트북, 네임스페이스·컨테이너). 두 환경의 결과는 서로 일치한다.

# A. 원격 VM 모드 (Proxmox, 2026-11-19)

## A-1. 개요

| 항목 | 값 |
|---|---|
| 환경 | Proxmox 노드 → **SDN01**(Ubuntu 24.04.5, 4코어/8GB/52GB, cpu host, 중첩 KVM) → 안쪽 VM 6대. 단일 호스트 구성 (`POC_TOPOLOGY=single`) |
| 안쪽 VM | faucet-ctl, vm-biz01, vm-inet01, vm-unauth01, radius, fw (Ubuntu 24.04 클라우드 이미지, 역할별로 미리 패키지 설치) |
| 스위치 | Open vSwitch 3.3.9, br-sdn `fail-mode secure`, dpid 0x1, OpenFlow 1.3 |
| Faucet | 1.10.12 (venv, systemd), 관리망 10.255.0.10 |
| RADIUS | FreeRADIUS 3.2.5 (Ubuntu 패키지), EAP-TLS만, TLS 1.2 |
| 단말 접근 | 게스트 에이전트(virsh qemu-agent-command)만. 단말은 NIC 1개·SSH 꺼짐 |
| **결과** | Phase 1 10/10(2호스트 VXLAN) · Phase 2 38/38 · Phase 3·4 18/19(실패 1건은 시험 버그, 실제 차단 확인) · Phase 5 6/6 · **Phase 6 관문 16/16** · **Phase 7 13/13** · **격리 VLAN 개선 16/17**(실패 1건은 시험 문제) + 개선 후 Phase 7 회귀 **13/13** |
| 미인증 포트 기본 VLAN | **quarantine(999)**, 트렁크 미포함 (2026-11-19 개선, A-4 5번) |
| 컨트롤러 장애 대비 | **포트 가드**(`poc-port-guard`, port 모드): 장애 중 포트 변화 시 그 포트 흐름 삭제 (A-4 6번). `tests/remote-controller-outage.sh` 개선 전 17/20 → 개선 후 **21/21** |

## A-2. 토폴로지

```
Proxmox ── vmbr0 (LAN·인터넷) ── SDN01 ens18 (관리 NIC, 192.168.50.240)
SDN01
 ├ br-mgmt (관리망 10.255.0.0/24): SDN01 .11 / faucet-ctl .10 / radius .20 / fw .30
 ├ br-sdn (Faucet 제어, secure)
 │   ├ 1 vm-biz01 / 2 vm-inet01 / 3 vm-unauth01   (단말, NIC 1개, tap tp-*)
 │   ├ 10 fw eth1 (VLAN 100·200 트렁크)
 │   └ 20 faucet-ctl eth1 (EAPOL, output_only)
 └ virbr0 (libvirt NAT 192.168.122.0/24) ── fw eth2 (외부 출구)
```

## A-3. 시나리오 결과 (tests/remote-run-all.sh, 2026-11-19 04:45)

| 번호 | 시나리오 | 결과 | 근거·관찰 |
|---|---|---|---|
| t01 | 업무 단말 인증 | PASS | port 1 VLAN 200→100, 10.100.0.162, 게이트웨이 L2 도달 |
| t02 | 인터넷 단말 인증 | PASS | VLAN 200, 10.200.0.163, 외부 ping·DNS·HTTP 성공 |
| t03 | 인증서 없음 | PASS | DHCP 미수신, 주소를 직접 넣어도 양 망 게이트웨이 ARP 무응답 |
| t04 | 위조 인증서 | PASS | 인증 실패, port 3 VLAN 불변, 주소 미수신 |
| t05 | 업무 → 외부 | PASS | ping·DNS(fw 경유/외부 직접)·HTTP 모두 차단 |
| t06 | 업무 ↔ 인터넷 | PASS | 양방향 차단, 업무 단말에서 인터넷망 게이트웨이 L2 불가 |
| t07 | RADIUS 중지 중 새 인증 | PASS | 정상 인증서여도 실패, port 1 업무망으로 안 열림. 기존 인증 단말은 통신 유지(관찰) |
| t08 | 컨트롤러 중지 | PASS | 새 인증 불가, 미인증 포트 차단 유지, 망 혼합 없음. **기존 세션 유지·로그오프 미반영(관찰, 한계 1)** |
| t09 | fw·radius VM 정지 | PASS | 양 망 외부 불가, 새 인증 실패, 복구 후 정상 |
| t10 | MAC 복제 | PASS | 미인증 포트에서 차단, 원래 단말 영향 없음 |
| t11 | EAPOL-Logoff | PASS | 인증 흐름 즉시 제거·차단·격리 VLAN 999 복귀(개선 후). 재인증까지 97초(한계 3) |
| t12 | 큰 인증서 20회 + MTU | PASS | 20/20, 단말 → 외부 1500바이트 DF 통과 |
| t13 | 관리망 → 업무망 | PASS | radius·faucet-ctl·SDN01에서 업무 단말·fw 업무망 주소 모두 차단 |

## A-4. 원격 모드에서 새로 발견·수정한 것

1. **[보안] 호스트 → 단말 VM 우회 경로**: Ubuntu 24.04 기본 `80-vm-vt.network`가 `vt-*` 이름 tap에 주소·DHCP 서버·NAT·IPv6 RA를 설정. 처음 tap 이름이 `vt-*`여서 9개 모두 해당 → OVS/Faucet을 거치지 않고 호스트가 단말 VM으로 패킷을 보낼 수 있었음. tap 이름 `tp-*` + networkd 관리 제외 규칙으로 해결, Phase 2 검사에 포함. **운영 전환 시 하이퍼바이저의 자동 네트워크 설정이 가상 스위치 포트를 건드리지 않는지 반드시 확인할 것.**
2. Faucet systemd 유닛 PATH 누락으로 기동 실패 → 수정.
3. 이미지 준비: `virt-resize`로 만든 디스크 부팅 불가, virt-customize 내장 네트워크 불가 → 임시 VM 부팅 방식으로 변경.
4. 시험 버그 2건(dig 오류 출력 판정, 변수 대입 순서) — 결함 아님, 수정.

5. **미인증 포트가 인터넷망 브로드캐스트를 엿들음 → 격리 VLAN 으로 해결** (`tests/remote-quarantine.sh`, 2026-11-19 04:59):

   | 항목 | 개선 전 (native_vlan inet) | 개선 후 (native_vlan quarantine 999) |
   |---|---|---|
   | 미인증 port 3 VLAN | 200 | 999 |
   | 인터넷망 브로드캐스트 출력 포트 | `10 2 3 4 5 6 7 8 9` | `10 2` |
   | 미인증 단말이 20초간 받은 인터넷 단말 프레임 | **8개** | **0개** |
   | 로그오프 후 포트 | 인터넷망(200) | 격리(999), 어느 게이트웨이에도 도달 불가 |
   | 트렁크로 나간 VLAN 999 프레임 | — | 0개 |

   정상 인증(biz 100, inet 200)과 t01~t13 회귀는 개선 후에도 13/13. FAIL 1건은 "예비 포트 4" 흐름 확인인데, VM 이 없는 포트는 스위치에 존재하지 않아 흐름이 없음(= 전부 차단) — 설정값 확인으로 시험 수정.

6. **[보안] 컨트롤러 장애 중 인증됐던 포트 재연결 시 재인증 없이 업무망 접속 → 포트 가드로 해결** (`tests/remote-controller-outage.sh`):

   | 장애 중 상황 | 포트 가드 없음 | 포트 가드 있음 (port 모드) |
   |---|---|---|
   | 빈 포트(5)에 새 장비 | 차단 (흐름 없음 → 기본 drop) | 차단 |
   | 미인증 포트 재연결 (vm-unauth01 재부팅) | 차단 | 차단 |
   | **인증됐던 포트 재연결 (vm-biz01 재부팅, 재인증 안 함)** | **옛 흐름 `in_port=1,dl_src=biz MAC` 남음 → 업무망 도달·DHCP 수신 ❌** | **옛 흐름 0개 → 차단 ✅** |
   | 포트 변화 없는 기존 세션 (vm-inet01) | 유지 | 유지 |
   | 컨트롤러 복구 후 | 흐름 정리, 정상 재인증 | 동일 |

   - 원인: Faucet 은 정상 시 포트 down 에 인증 흐름을 지우지만 장애 중엔 지울 주체가 없고, `fail-mode secure` 는 기존 흐름을 유지한다.
   - 대책: `hosts/port-guard.sh` (systemd `poc-port-guard`, `host-a/50-port-guard.sh` 로 설치). 1초 주기로 br-sdn 포트의 ofport·ifindex·link 상태를 보고, **컨트롤러가 끊긴 동안** 포트가 내려가거나 삭제·재생성되면 `del-flows in_port=N`. 트렁크(10)·인증 포트(20) 제외. `all` 모드는 끊기는 순간 전체 흐름 삭제(기존 세션도 차단).
   - 남은 한계: 컨트롤러 종료 후 is_connected 갱신까지 수 초 동안의 포트 변화는 감지 못함. 링크 변화 없이 인증 포트에 허브로 장비를 추가하는 경우는 대상 아님(802.1X 단일 호스트 모드 일반 한계).
   - **운영 전환 시**: 상용 스위치는 링크 down 시 스위치 자체가 802.1X 세션을 해제한다. 컨트롤러 의존 구조라면 이 동작을 데이터 평면에서 보장해야 한다.

## A-5. 이 구성에서 검증하지 않은 것

- 호스트 간 VXLAN 위 VLAN 트렁크(단일 호스트라 fw 트렁크가 br-sdn에 직접 연결). VXLAN 위 1500바이트 프레임 통과는 2호스트 Phase 1에서 확인함.
- 물리 호스트 B 전원 장애(t09는 fw·radius VM 일시정지로 모사).

---

# B. 로컬 lite 모드 (노트북, 2026-11-18)

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
4. ~~**인증서는 유효하지만 VLAN 속성이 없는 단말은 인터넷망(native_vlan)에 붙는다.**~~ → **해결 (2026-11-19)**: native_vlan 을 격리 VLAN(999)으로 변경 (A-4 5번). 이 lite 결과표의 "VLAN 200 복귀"는 개선 전 기록이다.
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
