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

## 2026-11-19 — 원격 2호스트 모드 착수 (Proxmox)

- 환경: Proxmox에 Ubuntu VM 2대(호스트 A·B) 설치 완료. Proxmox 브리지 br0 = 물리 NIC(LAN 192.168.50.x, 인터넷, 노트북은 VPN으로 접근), br1 = 물리 포트 없는 내부망.
- 결정: br0 → 호스트 VM 관리 NIC(net0), br1 → VXLAN 터널 NIC(net1), br1 MTU 1550(안쪽 VM 1500). 명령 실행은 사용자, Claude는 스크립트 작성·결과 분석.
- 작성: `docs/PROXMOX.md`(Proxmox·호스트 준비 절차), `hosts/lib.sh`, `hosts/{10-packages,20-br-mgmt,check-phase1,90-teardown}.sh`, `host-a/30-br-sdn.sh`, `host-b/30-br-trunk.sh`, `hosts/60-poc-tun.yaml.example`, `tools/push.sh`, `tools/pull-results.sh`. 문법 검사 통과, 실행 전.
- 설계 메모: 단말·faucet-ctl·radius VM은 인터넷이 없으므로 Phase 2에서 virt-customize로 패키지·인증서를 이미지에 미리 넣는다. 관리 오버레이 IP는 netplan 대신 systemd 유닛(poc-ip-br-mgmt)으로 유지해 관리 NIC 설정 파일을 건드리지 않는다.

## 2026-11-19 — 호스트 VM 상태 확인 (읽기 전용 SSH)

- sdn01(192.168.50.240) = 호스트 A, sdn02(192.168.50.241) = 호스트 B. Ubuntu 24.04.5. SSH 키 등록 완료, sudo는 비밀번호 필요.
- NIC: ens18 = 관리(vmbr0, 192.168.50.x, 기본 경로), ens19 = 터널 후보(아직 down, MTU 1500, IP 없음). MAC: sdn01 ens19 bc:24:11:96:c8:1c, sdn02 ens19 bc:24:11:3f:a4:7c.
- **Proxmox VM 설정 미적용**: 두 VM 모두 1 vCPU, 메모리 2GB, `/dev/kvm` 없음·svm 플래그 0(CPU 타입이 host가 아님). 디스크 32GB 중 루트 LV 15GB만 사용(VG에 15GB 남음).
- 조치 필요: Proxmox에서 cpu host·코어·메모리·balloon 0 적용, 루트 LV 확장(VG 남은 공간), ens19가 vmbr1에 붙었는지 MAC으로 확인, 터널 netplan 적용.

## 2026-11-19 — Phase 0 완료 (원격)

- Proxmox: VM 101(SDN1=호스트 A) 4코어/8GB/52GB, 102(SDN2=호스트 B) 2코어/6GB/32GB, cpu host, balloon 0, 두 NIC 모두 Proxmox 방화벽 off, net1=vmbr1 MTU 1550. vmbr1 주소 10.10.0.0 → 10.10.0.254/24, mtu 1550. 노드 메모리 58GB.
- 호스트 VM: /dev/kvm 생김(AMD svm), 루트 LV 확장(A 50GB, B 30GB), ens19 = 10.10.0.1/.2, MTU 1550 (/etc/netplan/60-poc-tun.yaml).
- 터널 첫 ping 실패 → 재시도 시 성공. ufw는 서비스만 active, 실제 상태 inactive라 원인 아님. sdn01 netplan 적용 직후 타이밍 문제로 추정. `ufw allow in on ens19` 규칙은 추가됨(ufw 꺼져 있어 무효).
- `tests/phase0-precheck.sh`: A→B `ping -M do -s 1472` PASS, `-s 1522` PASS → **VM_MTU=1500 확정**. sudo는 비밀번호 필요(스크립트는 사용자가 sudo로 실행).

## 2026-11-19 — Phase 1 완료 (원격)

- `hosts/check-phase1.sh`: **host-a PASS 10/0, host-b PASS 8/0** (tests/out/remote/host-{a,b}/phase1-*.txt). OVS 3.3.9.
  - 관리 오버레이 10.255.0.11 ↔ .12 ping, **VXLAN 위로 1500바이트 프레임 단편화 없이 통과**(lite에서 못 한 MTU 검증 1차 확인).
  - host-a br-sdn secure / dpid 0x1 / vx-trunk = port 10, key 100. host-b br-trunk vx-trunk key 100, libvirt default NAT 활성.
- 실행 중 `could not open network device vx-trunk (No such device)` 경고: 포트를 타입 없이 먼저 추가한 스크립트 문제. 결과 상태는 정상. 포트 추가와 VXLAN 타입 지정을 한 트랜잭션으로 수정.

## 2026-11-19 — Phase 2 스크립트 작성 (안쪽 VM 6대)

- `vm/vms.sh`(VM 표), `vm/images.sh`(기본 이미지 + 역할 이미지 굽기), `vm/define.sh`(VM 생성), `vm/gexec.sh`(게스트 에이전트 명령), `hosts/check-phase2.sh`.
- 설계:
  - 단말·faucet-ctl·radius는 인터넷이 없으므로 호스트에서 `virt-resize`(루트 확장) + `virt-customize`로 역할 이미지(term, faucet, radius, fw)에 패키지를 미리 설치. VM은 역할 이미지 위 qcow2 오버레이.
  - Faucet은 venv에 `faucet==1.10.12`(lite 검증 버전) + systemd 유닛. fw는 첫 부팅부터 nftables(기본 drop)·dnsmasq(업무/인터넷 분리) 적용, ip_forward=1.
  - 단말: 인증서·supplicant 설정을 디스크에 직접 넣음(`/etc/poc/`), SSH 비활성, SSH 키 없음, NIC 1개. vm-unauth01은 위조 인증서만.
  - NIC 이름은 cloud-init에서 MAC 매칭 + set-name eth0/1/2로 고정 → 방화벽 규칙 그대로 재사용. 단말 MAC은 lite와 같은 02:00:00:00:01:0x.
  - br-sdn 포트 번호(1,2,3,20)는 libvirt qemu hook으로 VM 재기동 때도 유지.
  - 인프라 VM은 호스트 root 키(/root/.ssh/poc_ed25519)로 관리망 SSH. 콘솔 계정 poc, 비밀번호 secrets/vm_password.
- `firewall/nftables.conf`: 관리망 → fw 관리 주소(10.255.0.30) SSH 허용 추가 (VLAN 쪽에서는 불가). lite에는 sshd가 없어 영향 없음.
- 로컬 검증: bash 문법, cloud-init YAML 생성 결과(faucet-ctl 2 NIC, vm-biz01 1 NIC·SSH 키 없음, fw 3 NIC + VLAN 2개), nft 문법.

## 2026-11-19 — 구성 변경: 단일 호스트 (SDN01에 안쪽 VM 6대 전부)

- 사용자 결정: SDN01 VM 위에 KVM으로 필요한 VM을 모두 올린다. SDN02는 사용하지 않음.
- `env.sh`에 `POC_TOPOLOGY="single"` 추가 (기본값 single, `dual`이면 기존 2호스트 동작).
- 변경:
  - `hosts/lib.sh`: single이면 역할은 항상 a.
  - `hosts/20-br-mgmt.sh`: single이면 br-mgmt는 로컬 브리지, 기존 vx-mgmt 포트 제거.
  - `host-a/30-br-sdn.sh`: single이면 기존 vx-trunk 제거(port 10은 fw VM 자리), libvirt default NAT를 SDN01에서 활성화.
  - `vm/vms.sh`: radius·fw도 host a. fw eth1(vt-fw1)을 br-sdn port 10에 직접 연결. 메모리 faucet-ctl 1024MB, 나머지 768MB.
  - `vm/images.sh`: 호스트에 배치된 VM의 역할만 굽기(single이면 4개 역할 모두 SDN01).
  - `vm/define.sh`: fw VLAN 서브인터페이스 판정을 vt-fw1 기준으로.
  - `hosts/check-phase1.sh`, `hosts/check-phase2.sh`: 구성에 맞춰 검사 항목 분기.
- 영향: 앞서 통과한 Phase 1(2호스트 VXLAN)은 SDN01에서 단일 구성으로 다시 적용 필요. SDN02의 br-mgmt·br-trunk는 그대로 두거나 `host-b/90-teardown.sh`로 정리.
- 이 구성에서 검증되지 않는 것: 호스트 간 VXLAN·MTU(이미 Phase 1 dual에서 1500바이트 통과 확인), 호스트 B 장애(t09는 fw 트렁크 down으로 대체).

## 2026-11-19 — Phase 2 1차: 이미지 굽기 실패 (DNS)

- `vm/images.sh`: 기본 이미지 다운로드·SHA256 확인은 성공. term 이미지 굽기에서 `virt-customize --install` 실패: 임시 VM 안에서 `archive.ubuntu.com` 이름 풀이 불가.
- 원인: 클라우드 이미지의 `/etc/resolv.conf`가 systemd-resolved 스텁(127.0.0.53) 링크인데, virt-customize 임시 VM 안에는 resolved가 없음. 호스트(SDN01) 자체는 8.8.8.8로 정상.
- 수정: 굽는 동안만 `/etc/resolv.conf`를 호스트 상위 DNS(`resolvectl dns`에서 추출, 기본 8.8.8.8)로 바꾸고, 마지막에 원래 링크로 복원. `BAKE_DNS` 환경 변수로 덮어쓸 수 있음.
- 이후 `define.sh`, `check-phase2.sh`는 이미지가 없어 연쇄 실패(VM 0대) — 별도 문제 아님.

## 2026-11-19 — Phase 2 2차: 굽기 방식 변경 (virt-customize 네트워크 → 임시 VM 부팅)

- DNS를 8.8.8.8로 직접 지정해도 `Temporary failure resolving` 동일 → libguestfs 임시 VM(appliance)에 네트워크 자체가 없는 것으로 판단. SDN01: libguestfs 1.52, passt 미설치, dhcpcd 있음. 원인 추적 대신 방식 변경.
- 새 방식(`vm/images.sh`): 역할 이미지를 임시 VM(`poc-bake-<역할>`)으로 libvirt default NAT에 붙여 부팅 → cloud-init이 패키지 설치 + 역할 스크립트 실행 → 성공 표시(`/var/lib/poc-bake-ok`) 후 자동 전원 끔 → `virt-customize --no-network`로 설정 파일 넣기, `cloud-init clean`, machine-id 초기화.
- 실패 시 이미지 안의 `/var/log/poc-bake.log`, `cloud-init-output.log` 마지막 30줄을 출력하고 중단.
- 이 방식은 fw 외부 출구와 같은 libvirt NAT 경로를 쓰므로 그 경로도 함께 검증됨.

## 2026-11-19 — Phase 2 3차: 임시 VM 굽기 시간 초과

- `[term]` 임시 VM이 40분 대기 끝까지 꺼지지 않음(02:43→03:23). 이미지 안 `/var/log/poc-bake.log`, `cloud-init-output.log` 모두 비어 있음 → 부팅이 끝나지 않았거나 cloud-init이 실행되지 않은 것으로 추정. 화면 출력이 없어 원인 미확정.
- 조치: 임시 VM 시리얼 콘솔을 `$POC_IMG_DIR/bake-<역할>/console.log`로 저장하고 실패 시 마지막 40줄 출력, 대기 20분으로 단축. 남아 있는 `role-term.qcow2.tmp`를 virt-ls/virt-cat으로 진단 요청.

## 2026-11-19 — Phase 2 4차: 역할 이미지 굽기 성공

- 원인 확정: `virt-resize --expand /dev/sda1`로 만든 디스크가 부팅되지 않음(시리얼 출력 0바이트로 20분 정지). 원본 클라우드 이미지는 같은 환경에서 정상 부팅(`ubuntu login:`) 확인.
  - 참고: 부팅 테스트 VM이 DHCP를 받지 못한 것은 seed 없이 부팅해 Ubuntu 24.04 cloud-init이 스스로 비활성화됐기 때문(네트워크 설정 미생성). libvirt NAT 자체 문제 아님 — 굽기 성공으로 확인.
- 수정 후(`qemu-img convert` + `qemu-img resize`, 파티션 확장은 cloud-init growpart) `vm/images.sh` 성공:
  - term 1분 39초, faucet 1분 59초, radius 1분 17초, fw 2분 21초. 모두 패키지 확인(`dpkg -s`)과 역할 스크립트 성공 표시 통과.
  - 결과 이미지: role-term 2.4G, role-faucet 2.8G, role-radius 2.3G, role-fw 2.2G.
- libvirt default NAT 경로(임시 VM → virbr0 → SDN01 → 인터넷) 동작 확인 → fw 외부 출구 경로도 같은 경로.

## 2026-11-19 — Phase 2 완료(33/33)하였으나 결함 2건 발견·수정

`vm/define.sh` → VM 6대 기동, `hosts/check-phase2.sh` **PASS 33/0** (단말 NIC 1개, 포트 1·2·3·10·20 일치, 관리망 통신, fw nftables 기본 drop, fw 인터넷). 그러나 관찰 항목에서:

1. **Faucet 서비스가 기동 실패 반복(NRestarts=22)**: faucet 이 내부 엔진을 `os.execvp`로 이름 실행하는데 systemd PATH에 `/opt/faucet/bin`이 없어 `FileNotFoundError`. → `vm/files/faucet.service`에 `Environment=PATH=/opt/faucet/bin:...` 추가, faucet 역할 이미지 재굽기 필요.
2. **[보안] systemd-networkd가 VM tap 9개 전부를 관리**: Ubuntu 24.04 기본 `/usr/lib/systemd/network/80-vm-vt.network`(systemd-vmspawn용)가 `Name=vt-*` tap에 `/28` 주소, DHCPServer, IPMasquerade, IPv6SendRA, LLDP를 설정. 우리 tap 이름이 `vt-*`라 해당됨.
   - 영향: 호스트 → 단말 VM으로 OVS/Faucet을 거치지 않는 직접 경로(RA, LLDP, DHCP 응답 등)가 생김 — 원칙 2·3 위반. fw eth2 tap(vt-fw2)은 virbr0에 붙지 않고 networkd NAT(192.168.192.224/28)로 우연히 인터넷 연결.
   - 수정: tap 이름을 `tp-*`로 변경(`vm/vms.sh`), `vm/define.sh`가 `/etc/systemd/network/10-poc-taps.network`(`Name=tp-* vt-*`, `Unmanaged=yes`) 설치. `check-phase2.sh`에 "tp-*에 호스트 IPv4 없음 / networkd unmanaged / tp-fw2가 virbr0에 연결 / fw eth2가 192.168.122.0/24 / Faucet active" 검사 추가.
   - 교훈: 이 검사가 없었다면 33/33 PASS로 통과됐을 결함. 호스트 측 tap 상태도 완료 조건에 포함.

## 2026-11-19 — Phase 2 재생성 후 검사 32/6: SSH 호스트 키 불일치

- tap 이름 변경(tp-*)·networkd 제외 규칙 적용 후 VM 재생성. 새 검사 3개(tap에 호스트 IP 없음, networkd unmanaged, tp-fw2 → virbr0) **PASS**.
- FAIL 6건은 모두 SSH `REMOTE HOST IDENTIFICATION HAS CHANGED`: VM 재생성으로 호스트 키가 바뀌었는데 /root/.ssh/known_hosts에 옛 키가 남음. VM 자체 문제 아님.
- 수정: `hosts/lib.sh`에 `vmssh`(PoC 전용 known_hosts `/root/.ssh/poc_known_hosts`, accept-new) 추가, `vm/define.sh`가 VM을 만들 때 해당 관리망 IP의 옛 키를 두 known_hosts에서 제거.

## 2026-11-19 — Phase 2 완료 (원격, 단일 호스트)

- `hosts/check-phase2.sh` **PASS 38 / FAIL 0** (tests/out/remote/host-a/phase2-host-a.txt).
  - VM 6대 running, 단말 NIC 1개(VM 안에서도 eth0 하나), br-sdn 포트 1·2·3·10·20 일치.
  - tp-* tap 에 호스트 IPv4 없음, networkd unmanaged, tp-fw2 → virbr0 (우회 경로 제거 확인).
  - Faucet 1.10.12 active(NRestarts=0), fw nftables forward 기본 drop, fw eth2 = 192.168.122.164 (libvirt NAT), dnsmasq biz/inet active, FreeRADIUS 3.2.5 + eapol_test.
- 다음: Phase 3·4 스크립트 작성 — `host-a/40-controller.sh`(컨트롤러 지정, in-band 끔), `vm/deploy-faucet.sh`(설정 배포·검증·적용), `vm/term.sh`(단말 조작, 게스트 에이전트), `tests/remote-phase4.sh`(정적 VLAN + 정책 + fw 트렁크 포트 VLAN 태그 캡처).

## 2026-11-19 — Phase 3·4 (원격): PASS 18 / FAIL 1 → 시험 버그, 실질 통과

- `host-a/40-controller.sh`: br-sdn → tcp:10.255.0.10:6653, in-band 끔, is_connected true. `vm/deploy-faucet.sh static`: check_faucet_config 통과, HUP 적용.
- `tests/remote-phase4.sh` (tests/out/remote/host-a/remote-phase4.txt):
  - Phase 3: fail-mode secure, 컨트롤러 연결, Faucet 로그 DPID 0x1, **fw 트렁크 포트(tp-fw1)에서 VLAN 100·200 태그 프레임 실측**(remote-phase3-vlan.txt: biz01 DHCP Request가 vlan 100으로).
  - Phase 4: biz01 = 10.100.0.162, inet01 = 10.200.0.163. inet01 외부 ping·DNS·HTTP 성공. biz01 외부 ping·DNS(fw 경유)·HTTP 차단, biz↔inet 양방향 차단. fw 카운터 biz->external 8, biz->inet 2, inet->biz 2, mgmt->vlans 0.
  - FAIL 1건 "biz01 → 외부 DNS 서버 직접 차단": 실제로는 차단됨. 직접 확인 결과 `dig @1.1.1.1` → `communications error ... timed out`, `no servers could be reached`(exit 9). `dig +short`가 오류 문구를 표준출력에 찍는데 시험이 "출력 있음"을 응답으로 판정한 버그. IP 형태 응답만 통함으로 보도록 수정.

## 2026-11-19 — Phase 5·6 스크립트 (원격)

- `vm/deploy-radius.sh`: local/radius-render.sh 결과(lite 검증 설정)를 /etc/freeradius/3.0 구조로 묶어 radius VM에 배포, root:freerad 640, `freeradius -XC` 검사 후 재시작. 시험용 127.0.0.1 클라이언트 추가.
- `tests/remote-phase5.sh`: radius VM 안에서 eapol_test → 127.0.0.1, lite와 같은 5개 시나리오. 속성은 eapol_test 출력의 16진수(Tunnel-Type 0000000d, Medium 00000006, Group-Id "biz"=62697a)로 확인. 시험용 키는 /tmp/poc-pki 에 두고 끝나면 삭제.
- `vm/supp.sh`(단말 wpa_supplicant, 게스트 에이전트), `tests/remote-phase6.sh`(dot1x 배포 → 인증 전 차단 → biz/inet 인증·VLAN·DHCP → unauth 무인증/위조 차단 → 흐름·Faucet 로그·wpa 로그 증거).
- 사전 확인(읽기 전용): 단말 VM 안 /etc/poc — vm-biz01: vm-biz01 인증서, vm-inet01: vm-inet01·vm-inet-big, vm-unauth01: 위조 인증서만. wpa_supplicant/wpa_cli/dhclient 존재.

## 2026-11-19 — Phase 6 관문 통과 (원격, 실제 VM 단말) / Phase 5 시험 스크립트 버그

- `vm/deploy-radius.sh`: FreeRADIUS 3.2.5 설정 검사(-XC) 통과, active.
- `tests/remote-phase5.sh`: 첫 시나리오에서 `id: unbound variable`로 중단 — 한 `local` 문 안에서 앞서 선언한 `$id`를 참조한 스크립트 버그(set -u). 수정, 재실행 필요.
- `tests/remote-phase6.sh` **PASS 16 / FAIL 0** (tests/out/remote/host-a/remote-phase6*.txt):
  - Faucet dot1x 재시작 후 인증 전 포트 VLAN 1·2·3 = 200, 인증 전 vm-biz01·vm-unauth01 DHCP 차단.
  - vm-biz01 인증 → **port 1 VLAN 200 → 100**, 10.100.0.162. vm-inet01 인증 → VLAN 200, 10.200.0.163.
  - vm-unauth01: supplicant 없음·위조 인증서 모두 주소 미수신, port 3 VLAN 200 유지. Faucet 로그 `Failure from MAC 02:00:00:00:01:03 on 3`.
  - 인증 흐름은 (포트, MAC) 쌍: in_port=1,dl_src=02:00:00:00:01:01 / in_port=2,dl_src=02:00:00:00:01:02. lite와 동일한 동작을 실제 VM에서 재현.

## 2026-11-19 — Phase 5 완료 (원격) / Phase 7 스크립트

- `tests/remote-phase5.sh` **PASS 6 / FAIL 0**: FreeRADIUS 3.2.5(radius VM)에서 정상 인증서 2개 성공(응답 속성 VLAN "biz"=62697a, "inet"=696e6574), 큰 인증서 성공, 위조·사칭 거부. → **원격 Phase 0~6 모두 통과.**
- `tests/remote-run-all.sh` 작성: lite t01~t13 을 VM 으로 이식. 단말은 게스트 에이전트로 조작, 장애는 systemctl stop(faucet, freeradius)·virsh suspend(fw, radius)로 모사.
  - lite 대비 변경: t07·t08 "새 단말"은 vm-unauth01(위조 인증서만 보유) 대신 vm-biz01 을 로그오프시킨 뒤 정상 인증서로 재시도. t09 는 fw·radius VM 일시정지(호스트 B 전체 장애 모사). t12 에 단말→외부 1500바이트 DF ping 추가.
  - 격리 VLAN 개선은 미적용(계획서 원안 구성 그대로 시험), 이후 별도 시험으로 추가 예정.

## 2026-11-19 — Phase 7 완료 (원격): PASS 13 / FAIL 0

- `tests/remote-run-all.sh` 04:45 실행, t01~t13 전부 PASS (tests/out/remote/host-a/remote-phase7*.txt). 실행 후 자동 원상 복구 확인(vm-biz01 10.100.0.162, vm-inet01 10.200.0.163, port VLAN 1=100 2=200 3=200).
- 관찰(lite와 동일):
  - t07: RADIUS 중지 중 기존 인증 단말(vm-inet01)은 외부 통신 유지.
  - t08: 컨트롤러 중지 중 기존 세션 유지, 로그오프 미반영. 재기동 시 인증 흐름 전부 초기화(port1=0, port2=0) → 재인증 필요.
  - t11: 로그오프 후 같은 포트 재인증 97초.
  - t12: 큰 인증서 20/20, 단말 → 외부 1500바이트 DF 통과.
- `docs/RESULTS.md`에 "A. 원격 VM 모드" 절 추가. 남은 것: Phase 8 재구축 확인(선택), 격리 VLAN 개선, 컨트롤러 장애 시 정책 결정.

## 2026-11-19 — 격리 VLAN 개선 적용 (설정·시험 작성)

- 현 상태 실측 근거: Phase 7 종료 시점 흐름(remote-phase7-flows-end.txt)에서 인터넷망 브로드캐스트 출력 포트 = `10 2 3 4 5 6 7 8 9` → 미인증 포트 3·예비 4~9 모두 포함.
- Faucet 소스 확인: 로그오프 시 `del_dot1x_native_vlan` → 동적 VLAN 해제 → 설정의 native_vlan 으로 복귀. VLAN 멤버십은 동적 VLAN 이 없을 때만 native_vlan (vlan.py).
- 변경 `faucet/faucet.dot1x.yaml`: VLAN `quarantine`(999) 추가, dot1x 포트 1~9 native_vlan inet → quarantine, 트렁크(port 10)는 biz·inet 만. check_faucet_config 통과.
- `vm/deploy-faucet.sh --restart` 추가(포트 VLAN 구성 변경 시 재시작). `tests/remote-phase6.sh`는 항상 재시작.
- 시험 기대값 갱신: 미인증·로그오프 포트 VLAN 200 → 999 (remote-phase6, remote-run-all, lite-phase6, lite-run-all).
- 새 시험 `tests/remote-quarantine.sh`: 개선 전 측정(포트 3 VLAN, 200 브로드캐스트 출력 포트, 미인증 단말이 받은 인터넷 단말 프레임 수) → 배포 → 격리·트렁크 미포함·정상 인증 회귀·엿듣기 0개·로그오프 후 격리 복귀·트렁크에 999 프레임 0개.

## 2026-11-19 — 격리 VLAN 개선 검증 완료 (원격)

- `tests/remote-quarantine.sh` PASS 16 / FAIL 1:
  - 개선 전: port 3 VLAN 200, 인터넷망 브로드캐스트 출력 포트 `10 2 3 4 5 6 7 8 9`, 미인증 vm-unauth01 이 20초간 받은 vm-inet01 프레임 **8개**.
  - 개선 후: 포트 1·2·3 인증 전 999, 트렁크는 999 미수용·미송출, 정상 인증 100/200 및 외부 통신 유지, 인터넷망 브로드캐스트 출력 `10 2`, 미인증 단말 수신 **0개**, 로그오프 후 port 1 → 999(업무·인터넷 게이트웨이 모두 도달 불가), 시험 중 트렁크 VLAN 999 프레임 0개.
  - FAIL 1건(예비 포트 4 VLAN 빈 값): 연결된 VM 이 없어 스위치에 포트가 없으므로 흐름 없음(= 전부 차단). 시험을 "연결 시 흐름, 미연결 시 설정값" 확인으로 수정.
- 개선 후 `tests/remote-run-all.sh` 회귀 **13/13 PASS** (미인증·로그오프 포트 기대값 999).
- 문서: GUIDE 3.4·4.2·8·9장, RESULTS A-1·A-3·A-4(5번 신설)·B 한계 4 갱신. RESULTS B(lite) 표의 "VLAN 200 복귀"는 개선 전 기록으로 표시.

## 2026-11-19 — 질문: 컨트롤러 장애 중 "연결 안 됐던 포트"와 critical port

- 정리:
  - 장애 중 연결돼 있던 미인증 포트: 차단 확인됨(t08). RADIUS 장애 중 새 인증: 차단 확인됨(t07).
  - Faucet 에는 상용 NAC 의 critical port/critical VLAN(RADIUS 장애 시 제한 VLAN 으로 fail-open) 기능이 없다 → 장애 시 신규 포트는 아무 망에도 붙지 않음(fail-closed). 설계 원칙 2와 일치.
  - 미검증 2건: (A) 장애 중 빈 포트에 새 장비 연결, (C) 장애 중 인증됐던 포트에서 장비 재연결 — Faucet 이 옛 인증 흐름(in_port, MAC)을 지울 수 없어 재인증 없이 통할 가능성.
- table 0 기본 drop(`priority=0 actions=drop`) 확인 → A 는 차단 예상.
- `tests/remote-controller-outage.sh` 작성: A(netns+veth 로 port 5 연결), B(vm-unauth01 재부팅), C(vm-biz01 재부팅 후 재인증 없이 업무망 도달 시도), D(복구 후 옛 흐름 정리·새 포트 격리·정상 재인증).

## 2026-11-19 — [보안 결함] 컨트롤러 장애 중 인증됐던 포트 재연결 시 재인증 없이 업무망 접속

- `tests/remote-controller-outage.sh` PASS 17 / FAIL 3:
  - A 빈 포트(5)에 새 장비: 전용 흐름 없음 → table 0 기본 drop, 게이트웨이·DHCP 차단 ✅
  - B 미인증 포트 재연결(vm-unauth01 재부팅): 차단 ✅
  - **C 인증됐던 포트 재연결(vm-biz01 재부팅, 재인증 안 함): 옛 인증 흐름 `in_port=1,dl_src=02:00:00:00:01:01` 1개가 남아 업무망 게이트웨이 도달, DHCP 수신 ❌** → 장애 중 업무 PC 를 뽑고 MAC 복제 장비를 꽂으면 인증 없이 업무망 접속 가능.
  - D 복구: Faucet 재연결 시 옛 흐름 정리, 새 포트 격리 VLAN, 정상 재인증 ✅
  - FAIL "Faucet 연결 끊김": 중지 3초 후 is_connected 갱신 지연(타이밍). A 에서 port 5 흐름이 설치되지 않은 것으로 실제 장애 상태 확인. → 최대 20초 대기로 수정.
- 원인: Faucet 은 정상 시 포트 down 에 인증 흐름을 지우지만, 장애 중에는 지울 주체가 없고 OVS `fail-mode secure` 는 흐름을 유지.
- 대책: `hosts/port-guard.sh` + `host-a/50-port-guard.sh`(systemd `poc-port-guard`). 1초마다 br-sdn 포트(ofport·ifindex·link_state) 감시, **컨트롤러 끊김 중 포트 down/삭제/재생성 시 `del-flows in_port=N`** → 기본 drop 으로 완전 차단. 변화 없는 포트의 기존 세션은 유지(가용성). `all` 모드는 끊기는 순간 전체 흐름 삭제. 트렁크 10·인증 20 제외.
  - 가짜 ovs-vsctl/ovs-ofctl 로 로직 점검: 포트 삭제·재생성 시 in_port=1 삭제, 트렁크 10 미변경.
  - 한계: is_connected 갱신 지연(수 초) 동안의 포트 변화는 감지 못함. 인증된 포트에 허브를 끼워 링크 변화 없이 장비를 추가하는 경우는 대상 아님(802.1X 단일 호스트 모드 일반 한계).
- 운영 시사점: 상용 스위치는 링크 down 시 802.1X 세션을 스위치 자체에서 해제한다. SDN(컨트롤러 의존) 구조로 갈 때는 이 동작을 데이터 평면 쪽에서 보장해야 함.

## 2026-11-19 — 포트 가드 검증 완료

- `host-a/50-port-guard.sh` 설치(port 모드) 후 `tests/remote-controller-outage.sh` **PASS 21 / FAIL 0**.
  - C: vm-biz01 재부팅 후 port 1 옛 인증 흐름 **0개**, 재인증 없이 업무망·DHCP 차단 ✅. 포트 변화 없는 vm-inet01 세션은 유지.
  - 포트 가드 기록: tp-newdev(5) 새 포트, tp-unauth01 삭제(3)·재생성(처음 ofport 14 → libvirt hook 으로 3), tp-biz01 삭제(1)·재생성(1) 모두 해당 포트 흐름 삭제.
  - 관찰: VM 재기동 직후 tap 이 잠깐 임의 번호(14)로 붙었다가 hook 이 3으로 바꿈 — 포트 가드가 두 번호 모두 처리.
- 정리: 포트 가드 로그가 logger 와 표준출력 두 번 기록 → 표준출력 + `SyslogIdentifier=poc-port-guard` 로 단일화(재설치 시 반영).
- 문서: RESULTS A-1·A-4 6번, GUIDE 9장 한계 1 갱신.

## 2026-11-19 — Proxmox 일반 VM 적용 계획 승인

- 계획: `docs/PVE-PLAN.md`. 요지: Proxmox 노드에 OVS 브리지 vmbr10(Faucet 제어 엑세스 스위치, dpid 0x2)·vmbr11(PoC 관리망) 추가, 별도 Faucet 인스턴스(faucet-pve VM) — Faucet 1.10.12 chewie 는 첫 DP 의 nfv_intf 하나만 사용(`faucet_dot1x.py` first_valve)하므로. 트렁크는 VXLAN key 110 으로 SDN01 br-sdn port 11 → fw. 게스트 포트 번호 1000+VMID(`interface_ranges`), Proxmox hookscript 로 NIC 1개·vmbr10·firewall=0 강제, 포트 가드 재사용, netplan 내장 802.1X 로 게스트 등록.
- `pve/00-precheck.sh`(P0, 노드 읽기 전용 점검) 작성.

## 2026-11-19 — P0 (Proxmox 노드 점검) 결과와 P1 스크립트

- P0: Proxmox 9.2.4(커널 7.0.14), ifupdown2 3.3, systemd-networkd **inactive**(tap 자동 설정 위험 없음), vmbr0 192.168.50.238 / vmbr1 10.10.0.254 MTU 1550, SDN01까지 1550바이트 DF PASS, OVS 미설치(후보 3.5.0), **Proxmox 방화벽 enabled/running**, local 저장소 content=iso,vztmpl,backup(**snippets 없음**), interfaces.d/sdn(Proxmox SDN) 존재, VMID 100~130 사용, 16코어/58GB(여유 41GB).
- 계획 수정(docs/PVE-PLAN.md P1): 브리지를 interfaces 파일이 아니라 ovs-vsctl 로만 생성(노드 네트워크 파일·ifreload 무관), 호스트 방화벽에 VXLAN(UDP 4789)·관리망 ICMP 허용 규칙 추가, snippets 용도 추가.
- 작성: `pve/10-network.sh`(단계별 확인), `pve/11-check.sh`, `host-a/60-pve-uplink.sh`. `check-phase1.sh`·`50-port-guard.sh`(SKIP 10 11 20) 수정.
