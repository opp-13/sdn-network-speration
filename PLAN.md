# PoC 실행 계획: Faucet SDN + 802.1X 동적 VLAN으로 3호망(업무망/인터넷망) 분리

> 이 문서는 Claude Code 세션이 그대로 따라 실행할 수 있도록 작성한 계획서입니다.
> 저장소 루트에 두고 "PLAN.md를 읽고 Phase 0부터 진행해 줘"처럼 지시하면 됩니다.
>
> **이 저장소에 맞춘 결정 사항은 문서 끝의 "9. 결정 사항"을 먼저 보세요.**

---

## 0. 배경과 목표 (작업자가 반드시 이해해야 할 것)

- 근거 규정: 전자금융감독규정 제15조 제1항 제3호. 내부 업무용 시스템을 인터넷 등 외부통신망과 분리·차단해야 하며, 3호는 논리적 분리도 허용되는 것으로 해석된다. (5호 전산실 영역은 물리적 분리가 필요하므로 이 PoC 범위가 아님.)
- 목표: 단말이 802.1X로 인증하면 RADIUS가 돌려준 값에 따라 업무망 VLAN 또는 인터넷망 VLAN에 자동 배정되고, 두 망은 경계 방화벽에서만 정책적으로 만나는 구조를 KVM 두 대 위에서 검증한다.
- 이 PoC는 **정책 검증용**이다. 운영 적용 시에는 상용 장비로 옮긴다는 전제.

### 설계 원칙 (위반 금지)

1. **Faucet에서 VLAN 간 라우팅을 정의하지 않는다.** `routers:` 블록을 쓰지 않는다. 망 간 통신 결정은 경계 방화벽 VM 한 곳에서만 한다.
2. **실패 시 닫힌다(fail-closed).** 컨트롤러 중지, RADIUS 중지, 인증 실패 어느 경우에도 단말이 업무망에 붙으면 안 된다. Faucet 제어 브리지는 `fail-mode secure`.
3. **단말 VM은 NIC를 하나만 가진다.** 단말 VM에 관리용 NIC를 추가하면 그 자체가 우회 경로가 되어 검증이 무의미해진다. 단말 VM 접근은 `virsh console`로만 한다.
4. **관리망은 업무망·인터넷망 VLAN과 분리한다.** OpenFlow 제어, RADIUS 통신은 별도 관리 오버레이로만 흐른다.
5. **인증은 인증서 기반(EAP-TLS)으로 한다.** VLAN 배정을 사용자가 아니라 단말 인증서에 묶는다. MAC 주소 기반 인증 우회(MAB)는 쓰지 않는다.

---

## 1. 작업 안전 규칙 (Claude Code 세션용)

- 호스트의 **관리 NIC(NIC 1)는 절대 수정하지 않는다.** 브리지로 바꾸거나 IP를 바꾸면 SSH가 끊긴다. 새 브리지는 모두 별도로 만든다.
- 호스트 네트워크 설정을 바꾸는 명령은 실행 전에 명령과 영향 범위를 사용자에게 보여 주고 확인을 받는다.
- 모든 설정은 저장소 안의 파일로 만들고, 호스트에는 스크립트로 적용한다. 손으로 친 명령만으로 끝내지 않는다.
- 각 Phase의 **완료 조건**을 만족하지 못하면 다음 Phase로 넘어가지 않는다. 막히면 원인과 시도한 것을 `docs/LOG.md`에 남기고 사용자에게 묻는다.
- 비밀값(RADIUS 공유 비밀, 인증서 개인키)은 저장소에 커밋하지 않는다. `.gitignore`에 `secrets/`, `pki/private/`를 넣는다.

---

## 2. 토폴로지 (안 A: 단말과 컨트롤러를 호스트 A에 모음)

```
                         관리 오버레이 br-mgmt (VXLAN key 300, 10.255.0.0/24)
        ┌──────────────────────────────────────────────────────────────────┐
        │                                                                  │
 [호스트 A]                                                         [호스트 B]
  faucet-ctl VM ─ eth0(mgmt) 10.255.0.10                    radius VM ─ eth0 10.255.0.20
               └ eth1(nfv) ──┐                              fw VM     ─ eth0 10.255.0.30
                             │                                        ├ eth1 (트렁크) ─┐
  br-sdn (Faucet 제어, secure)                                        └ eth2 → libvirt default (NAT, 외부 출구)
   ├ port 1  vm-biz01   (업무 단말)                         br-trunk (일반 OVS)       │
   ├ port 2  vm-inet01  (인터넷 단말)                        └ vx-trunk ◀─────────────┘
   ├ port 3  vm-unauth01 (미인증 단말)                               ▲
   ├ port 10 vx-trunk ── VXLAN key 100 ─────────────────────────────┘
   └ port 20 faucet-ctl eth1 (인증 프레임 수신)

  호스트 A 내부 포트 on br-mgmt: 10.255.0.11      호스트 B 내부 포트 on br-mgmt: 10.255.0.12
```

### 2.1 주소 계획

| 구분 | 값 |
|---|---|
| 업무망 VLAN | 100, `10.100.0.0/24`, 게이트웨이 `10.100.0.1` (fw VM) |
| 인터넷망 VLAN | 200, `10.200.0.0/24`, 게이트웨이 `10.200.0.1` (fw VM) |
| 관리 오버레이 | `10.255.0.0/24` (br-mgmt, VXLAN key 300) |
| 트렁크 터널 | VXLAN key 100 (A `br-sdn` port 10 ↔ B `br-trunk`) |
| 예비: 스택 링크 | VXLAN key 200 (안 B 확장 시) |
| 호스트 터널망 IP | `env.sh`의 `HOST_A_TUN_IP`, `HOST_B_TUN_IP` (NIC 2) |
| 외부 출구 | fw VM eth2 → 호스트 B libvirt `default` NAT 네트워크 |

### 2.2 MTU

- VXLAN은 50바이트를 더한다. 터널망 NIC(NIC 2) MTU를 1550 이상으로 올릴 수 있으면 VM MTU는 1500 유지.
- 올릴 수 없으면 **모든 VM NIC MTU를 1450**으로 둔다. (libvirt `<mtu size='1450'/>`, cloud-init 네트워크 설정에도 반영)
- Phase 1 완료 조건에서 실제 경로 MTU를 측정해 어느 쪽인지 확정하고 `env.sh`에 기록한다.

---

## 3. 저장소 구조

```
.
├── PLAN.md                     # 이 문서
├── env.sh.example              # 호스트 IP, NIC 이름, MTU 등 환경 변수 (복사해서 env.sh로 사용)
├── lib/
│   └── remote.sh               # env.sh 로드, run_a/run_b(SSH), confirm
├── host-a/
│   ├── 10-packages.sh
│   ├── 20-br-mgmt.sh           # 관리 오버레이 브리지 + VXLAN key 300
│   ├── 30-br-sdn.sh            # Faucet 제어 브리지 + VXLAN key 100 + 포트 번호 고정
│   └── 90-teardown.sh          # 이 PoC가 만든 브리지·포트만 제거
├── host-b/
│   ├── 10-packages.sh
│   ├── 20-br-mgmt.sh
│   ├── 30-br-trunk.sh
│   └── 90-teardown.sh
├── vm/
│   ├── images.sh               # 클라우드 이미지 다운로드
│   ├── cloud-init/<vm>/        # user-data, network-config
│   ├── define-<vm>.sh          # virt-install 또는 virsh define
│   └── xml/                    # 필요 시 libvirt XML
├── faucet/
│   ├── faucet.static.yaml      # Phase 3: 802.1X 없이 정적 VLAN
│   └── faucet.dot1x.yaml       # Phase 6: 802.1X + 동적 VLAN (radius_secret은 템플릿 변수)
├── firewall/
│   ├── nftables.conf
│   ├── dnsmasq.conf            # VLAN별 DHCP
│   └── netplan.yaml            # eth1.100, eth1.200 서브 인터페이스, eth2 DHCP(외부)
├── pki/
│   ├── make-ca.sh
│   ├── make-client.sh          # 단말별 인증서 발급 (CN = 단말 이름)
│   └── private/                # 커밋 금지
├── freeradius/
│   ├── clients.conf            # faucet-ctl 등록
│   ├── authorize               # 단말별 응답 속성
│   └── eap.conf                # EAP-TLS 설정
├── supplicant/
│   └── wired-<vm>.conf         # 단말별 wpa_supplicant 설정
├── tests/
│   ├── phase0-precheck.sh      # Phase 0 읽기 전용 점검
│   ├── run-all.sh
│   └── t<번호>-<이름>.sh        # 시나리오별 스크립트, 결과는 PASS/FAIL로 출력
└── docs/
    ├── LOG.md                  # 진행 기록, 막힌 점
    └── RESULTS.md              # 최종 검증 결과
```

---

## 4. 단계별 작업

### Phase 0. 사전 점검

작업:
- Claude Code가 어디서 실행되는지 확인하고, 호스트 A·B 양쪽에 SSH가 되는지 확인한다.
- 두 호스트의 OS 버전, CPU 가상화 지원(`kvm-ok` 또는 `/dev/kvm`), NIC 목록(관리 NIC, 터널 NIC)을 조사해 `env.sh.example`을 채운다.
- 터널 NIC 간 통신 확인: `ping -M do -s 1472` 및 `-s 1522`로 MTU 1500/1550 통과 여부를 측정한다.

완료 조건:
- [ ] `env.sh`에 호스트별 관리 NIC, 터널 NIC, 터널 IP, 확정 MTU가 적혀 있다.
- [ ] 관리 NIC는 건드리지 않는다는 것을 사용자와 합의했다.

### Phase 1. 호스트 기반 구성

작업 (양쪽 호스트):
- 패키지 설치: `qemu-kvm`, `libvirt-daemon-system`, `virtinst`, `openvswitch-switch`, `cloud-image-utils`, `tcpdump`.
- `br-mgmt` 생성(일반 OVS 브리지), VXLAN key 300 포트 추가, 호스트 내부 포트에 관리 오버레이 IP 부여(A: 10.255.0.11, B: 10.255.0.12).
- 호스트 B: `br-trunk` 생성, VXLAN key 100 포트 추가.
- 호스트 A: `br-sdn` 생성. 아래 속성을 반드시 설정.

```bash
ovs-vsctl add-br br-sdn \
  -- set bridge br-sdn other-config:datapath-id=0000000000000001 \
  -- set bridge br-sdn protocols=OpenFlow13 \
  -- set-fail-mode br-sdn secure
ovs-vsctl add-port br-sdn vx-trunk \
  -- set interface vx-trunk type=vxlan \
     options:remote_ip=${HOST_B_TUN_IP} options:key=100 ofport_request=10
```

- 컨트롤러 지정은 Phase 3에서 faucet-ctl VM이 뜬 뒤에 한다.

완료 조건:
- [ ] 호스트 A ↔ B 간 관리 오버레이 IP(10.255.0.11 ↔ .12) ping 성공.
- [ ] `ovs-vsctl get-fail-mode br-sdn` 결과가 `secure`.
- [ ] `ovs-vsctl show`에 `vx-trunk`(key 100)과 관리 오버레이 VXLAN(key 300)이 보인다.
- [ ] 스크립트를 두 번 실행해도 오류 없이 같은 상태가 된다(멱등성).

### Phase 2. VM 생성

VM 목록:

| VM | 호스트 | NIC | 비고 |
|---|---|---|---|
| faucet-ctl | A | eth0 → br-mgmt (10.255.0.10), eth1 → br-sdn port 20 | eth1은 IP 없음 |
| vm-biz01 | A | eth0 → br-sdn port 1 | NIC 하나만 |
| vm-inet01 | A | eth0 → br-sdn port 2 | NIC 하나만 |
| vm-unauth01 | A | eth0 → br-sdn port 3 | 인증서 없음, 공격 시나리오용 |
| radius | B | eth0 → br-mgmt (10.255.0.20) | |
| fw | B | eth0 → br-mgmt (10.255.0.30), eth1 → br-trunk, eth2 → libvirt `default` (NAT, 외부 출구) | eth1은 VLAN 트렁크 |

작업:
- Ubuntu LTS 클라우드 이미지 + cloud-init으로 생성. 콘솔 로그인용 계정은 cloud-init으로 만든다.
- br-sdn에 붙는 NIC는 libvirt에서 `<virtualport type='openvswitch'/>`로 Open vSwitch에 직접 연결하고 리눅스 브리지를 거치지 않는다. (리눅스 브리지는 802.1X 프레임을 기본적으로 전달하지 않음)
- VM 기동 후 `ovs-vsctl set interface <tap> ofport_request=<번호>`로 포트 번호를 고정하고, `ovs-ofctl -O OpenFlow13 show br-sdn`으로 번호를 확인한다. tap 이름은 libvirt `<target dev='...'/>`로 고정한다.
- MTU는 Phase 0 결정값을 따른다.
- 단말 VM 3대에는 `qemu-guest-agent`를 설치한다 (Phase 7 시나리오용, 네트워크 비경유).

완료 조건:
- [ ] 위 6대가 모두 기동되고 `virsh console`로 접속된다.
- [ ] br-sdn 포트 번호가 표와 정확히 일치한다.
- [ ] 단말 VM 3대에는 NIC가 하나뿐이다 (`virsh domiflist`로 확인).
- [ ] faucet-ctl, radius, fw는 관리 오버레이로 서로 ping 된다.

### Phase 3. Faucet 설치와 정적 VLAN 동작 확인 (802.1X 없이)

목적: 인증 기능을 켜기 전에 VLAN·트렁크·방화벽 경로가 맞는지 먼저 확인한다.

작업:
- faucet-ctl VM에 Faucet 최신 안정 버전 설치. 설치 방법은 공식 문서(https://docs.faucet.nz/en/latest/installation.html)를 따른다. **설치 버전을 `docs/LOG.md`에 기록**한다.
- 호스트 A에서 `ovs-vsctl set-controller br-sdn tcp:10.255.0.10:6653`.
- `faucet/faucet.static.yaml` 적용:

```yaml
vlans:
  biz:  { vid: 100, description: "업무망" }
  inet: { vid: 200, description: "인터넷망" }

dps:
  host-a:
    dp_id: 0x1
    hardware: "Open vSwitch"
    interfaces:
      1:  { description: "vm-biz01",   native_vlan: biz }
      2:  { description: "vm-inet01",  native_vlan: inet }
      3:  { description: "vm-unauth01", native_vlan: inet }
      10: { description: "호스트 B 방화벽 트렁크", tagged_vlans: [biz, inet] }
# routers: 블록 금지
```

- `check_faucet_config`로 설정 검증 후 적용.

완료 조건:
- [ ] Faucet 로그에 datapath 0x1 연결이 보인다.
- [ ] fw VM의 eth1에서 `tcpdump -e`로 VLAN 100, 200 태그가 붙은 프레임이 보인다 (Phase 4 이후 단말 ping으로 확인).
- [ ] 컨트롤러 VM을 중지하면 단말 간 신규 통신이 막힌다 (fail-mode secure 확인).

### Phase 4. 경계 방화벽 VM

작업:
- fw VM에 `eth1.100`(10.100.0.1/24), `eth1.200`(10.200.0.1/24) 생성. `eth2`는 libvirt `default` 네트워크에서 DHCP로 주소를 받는 외부 출구.
- dnsmasq로 VLAN별 DHCP 제공. **업무망 DHCP는 기본 게이트웨이를 주되, 방화벽이 업무망→외부를 막는다.** (또는 업무망에는 기본 경로 없이 내부 대역 경로만 배포)
- nftables 정책 ("외부" = `oifname eth2`):

| 출발 → 도착 | 정책 |
|---|---|
| 업무망 → 외부(eth2) | drop |
| 인터넷망 → 외부(eth2) | 주소 변환(masquerade) 후 허용 |
| 업무망 ↔ 인터넷망 | drop |
| 업무망/인터넷망 → fw 자신 | DHCP, DNS만 허용 |
| 관리 오버레이 → 업무망/인터넷망 | drop |

- 외부 출구는 fw VM eth2(호스트 B libvirt `default` NAT)로 확정 (9장 참조). 인터넷망 DNS는 dnsmasq가 eth2 경유 상위 DNS로 포워딩.
- 정책 파일 상단에 기본 정책 `drop`을 명시한다.

완료 조건 (Phase 3의 정적 VLAN 상태에서):
- [ ] vm-biz01이 10.100.0.0/24 주소를 받고, vm-inet01이 10.200.0.0/24 주소를 받는다.
- [ ] vm-inet01 → 외부 테스트 대상 통신 성공.
- [ ] vm-biz01 → 외부 테스트 대상 실패.
- [ ] vm-biz01 ↔ vm-inet01 통신 실패.

### Phase 5. PKI와 FreeRADIUS (EAP-TLS)

작업:
- `pki/make-ca.sh`로 PoC 전용 CA 생성, `pki/make-client.sh`로 `vm-biz01`, `vm-inet01` 인증서 발급. `vm-unauth01`에는 발급하지 않는다. 별도로 **다른 CA로 서명한 위조 인증서** 하나를 만들어 시나리오에 쓴다.
- radius VM에 FreeRADIUS 설치, EAP-TLS만 허용(PEAP·MD5 비활성).
- `clients.conf`에 faucet-ctl(10.255.0.10) 등록, 공유 비밀은 `secrets/`에서 읽는다.
- `authorize`에 단말별 응답 속성:

```
vm-biz01
        Tunnel-Type = VLAN,
        Tunnel-Medium-Type = IEEE-802,
        Tunnel-Private-Group-Id = "biz"

vm-inet01
        Tunnel-Type = VLAN,
        Tunnel-Medium-Type = IEEE-802,
        Tunnel-Private-Group-Id = "inet"
```

- 인증서 CN과 위 사용자 이름이 일치하도록 한다.
- `freeradius -X` 디버그 모드로 먼저 확인한다. 가능하면 `eapol_test`(wpa_supplicant 소스에 포함)로 Faucet 없이 RADIUS 단독 EAP-TLS 테스트를 한다.

완료 조건:
- [ ] `eapol_test`로 vm-biz01 인증서 인증 성공, 응답에 Tunnel 속성 3개가 보인다.
- [ ] 위조 인증서는 거부된다.

### Phase 6. 802.1X 활성화와 동적 VLAN (핵심 관문)

작업:
- faucet-ctl VM의 eth1을 인증 프레임 수신 인터페이스로 사용 (IP 없음, link up).
- `faucet/faucet.dot1x.yaml` 적용 (저장소에는 `${RADIUS_SECRET}` 템플릿, 배포 시 `secrets/radius_secret`으로 렌더링한 `*.rendered.yaml`을 올림):

```yaml
vlans:
  biz:  { vid: 100, description: "업무망" }
  inet: { vid: 200, description: "인터넷망" }

dps:
  host-a:
    dp_id: 0x1
    hardware: "Open vSwitch"
    dot1x:
      nfv_intf: eth1
      nfv_sw_port: 20
      radius_ip: 10.255.0.20
      radius_port: 1812
      radius_secret: "<secrets/radius_secret 값>"
    interfaces:
      1:  { description: "vm-biz01",    dot1x: true, native_vlan: inet }
      2:  { description: "vm-inet01",   dot1x: true, native_vlan: inet }
      3:  { description: "vm-unauth01", dot1x: true, native_vlan: inet }
      10: { description: "호스트 B 방화벽 트렁크", tagged_vlans: [biz, inet] }
      20: { description: "Faucet 인증 프레임 수신", native_vlan: inet }
```

- 단말 VM에서 `wpa_supplicant -D wired -i eth0 -c /etc/wpa_supplicant/wired.conf` 실행, 인증 후 `dhclient -r && dhclient`.

**관문 검증 (반드시 이 순서로):**
1. RADIUS 응답값을 VLAN 이름(`biz`)으로 두었을 때 vm-biz01이 VLAN 100으로 옮겨지는지 확인한다. Faucet 소스 코드상 인증 성공 콜백이 `vlan_name` 인자로 포트 기본 VLAN을 바꾸므로 이름 매칭일 가능성이 높다.
2. 이름으로 안 되면 숫자(`100`)로 바꿔 다시 시험한다.
3. 둘 다 안 되면 설치된 Faucet 버전이 동적 VLAN 배정을 지원하지 않는 것이다. 이 경우 **진행을 멈추고 사용자에게 보고**한다. (구버전 문서는 동적 VLAN 배정을 미지원으로 표기했음)

- 확인 방법: `ovs-ofctl -O OpenFlow13 dump-flows br-sdn`에서 port 1의 VLAN 태깅 흐름 변화, Faucet 로그의 인증 이벤트, fw VM에서 VLAN 100 태그 프레임 관측.
- 결과(이름/숫자 중 무엇이 동작했는지, Faucet 버전)를 `docs/LOG.md`에 기록한다.

완료 조건:
- [ ] vm-biz01 인증 → VLAN 100, 업무망 주소 수신.
- [ ] vm-inet01 인증 → VLAN 200, 인터넷망 주소 수신.
- [ ] vm-unauth01 → 어떤 주소도 받지 못함.

### Phase 7. 검증 시나리오 자동화

`tests/`에 아래 시나리오를 스크립트로 만들고 `run-all.sh`로 일괄 실행한다. 단말 VM 내부 명령은 `virsh console` 대신 `virsh qemu-agent-command`(게스트 에이전트) 사용을 검토한다. 게스트 에이전트는 네트워크를 거치지 않으므로 원칙 3을 깨지 않는다.

| 번호 | 시나리오 | 기대 결과 |
|---|---|---|
| t01 | 업무 단말 인증서로 인증 | VLAN 100, 10.100.0.0/24 주소 |
| t02 | 인터넷 단말 인증서로 인증 | VLAN 200, 외부 테스트 대상 통신 성공 |
| t03 | 인증서 없이 접속 | 주소 미수신, 통신 불가 |
| t04 | 다른 CA 서명 위조 인증서 | 인증 실패, 통신 불가 |
| t05 | 업무 단말 → 외부 (ping, DNS, HTTP) | 모두 실패 |
| t06 | 업무 단말 ↔ 인터넷 단말 | 실패 |
| t07 | RADIUS VM 중지 후 새 단말 인증 시도 | 차단 유지 (업무망으로 열리면 FAIL) |
| t08 | faucet-ctl VM 중지 | 신규 통신 차단, 망 혼합 없음 |
| t09 | 호스트 B 전체 중지 (또는 vx-trunk down) | 업무·인터넷 모두 외부 불가, 새 인증 실패 |
| t10 | vm-unauth01에 vm-biz01의 MAC 복제 | 차단 |
| t11 | 인증된 단말 EAP 로그오프 | 즉시 차단 상태 복귀 |
| t12 | 큰 인증서로 EAP-TLS 20회 반복 | 매회 성공 (MTU 문제 없음) |
| t13 | 관리 오버레이(10.255.0.0/24)에서 업무망 주소로 접근 | 실패 |

완료 조건:
- [ ] `run-all.sh` 결과 전 항목 PASS, 결과를 `docs/RESULTS.md`에 날짜·Faucet 버전과 함께 기록.

### Phase 8. 정리

- `docs/RESULTS.md`에 아래를 정리한다: 최종 토폴로지, 사용 버전, 동작/미동작 기능, 알려진 한계, 운영 전환 시 상용 장비로 옮겨야 할 정책 목록(VLAN 체계, 단말 분류, 방화벽 규칙).
- `90-teardown.sh`로 깨끗이 지우고 다시 Phase 1부터 스크립트만으로 재구축되는지 확인한다.

---

## 5. 확인이 필요한 불확실 사항

| 항목 | 내용 | 확인 시점 |
|---|---|---|
| 동적 VLAN 응답값 형식 | RADIUS가 VLAN 이름을 줘야 하는지 VID를 줘야 하는지 | Phase 6 관문 |
| 설치 버전의 동적 VLAN 지원 | 구버전 문서는 미지원 표기, 최신 코드에는 구현 | Phase 6 관문 |
| Faucet 802.1X 안정성 | 공식 문서가 실험 단계 기능으로 명시 | Phase 6~7 전반 |
| 실행 중 권한 변경(RFC 5176) | Faucet 소스에서 확인되지 않음. 격리 전환은 재인증으로 대체 | Phase 7 (범위 밖으로 기록) |
| fail-mode secure 동작 | 컨트롤러 중지 시 기존 흐름이 언제까지 유지되는지 | t08 |

---

## 6. 범위 밖 (이번 PoC에서 하지 않는 것)

- 안 B(호스트 B에도 Faucet 제어 스위치와 단말 배치, Faucet 스태킹). 안 A 완료 후 별도 계획으로 진행.
- 망연계 VM 실제 구현 (자리만 예약).
- 5호망(전산실) 구성.
- 상용 네트워크 접근 제어 솔루션 연동.

---

## 7. 참고 자료

- Faucet 설정 문서 (802.1X 절): https://docs.faucet.nz/en/latest/configuration.html
- Faucet 802.1X 소스 코드: https://docs.faucet.nz/en/latest/_modules/faucet/faucet_dot1x.html
- Faucet 스태킹 튜토리얼 (안 B 참고): https://github.com/faucetsdn/faucet/blob/master/docs/tutorials/stacking.rst
- RFC 3580 (802.1X RADIUS 사용 지침, VLAN 배정 속성): https://datatracker.ietf.org/doc/html/rfc3580
- RFC 5176 (RADIUS 동적 권한 변경): https://datatracker.ietf.org/doc/html/rfc5176
- Open vSwitch 터널 설정: https://docs.openvswitch.org/en/latest/howto/userspace-tunneling/
- 리눅스 브리지 802.1X 프레임 전달 논의(group_fwd_mask): https://lists.openwall.net/netdev/2025/04/23/183
- 전자금융감독규정 제15조 해설(3호/5호 비교): https://aws.amazon.com/ko/blogs/tech/financial-cloud-guide-a-to-z-part1/

---

## 9. 결정 사항 (2026-11-18 확정)

| 항목 | 결정 |
|---|---|
| 실행 위치 | Claude Code는 작업용 노트북에서 실행되고, 호스트 A·B는 **원격 KVM 호스트**로 SSH로 조작한다. 모든 `host-a/`·`host-b/` 스크립트는 로컬에서 실행하며 `lib/remote.sh`의 `run_a`/`run_b`로 원격에 적용한다. |
| 외부 출구 | fw VM에 세 번째 NIC `eth2`를 두고 호스트 B의 libvirt `default` NAT 네트워크에 연결해 실제 인터넷으로 나간다. 관리 NIC(eth0)은 출구로 쓰지 않는다. |
| Git | 파일은 저장소에 만들되 커밋은 사용자가 한다. |
| 비밀값 | `faucet.dot1x.yaml`은 `${RADIUS_SECRET}` 템플릿으로 두고, 배포 시 `secrets/radius_secret`으로 렌더링한 `faucet/*.rendered.yaml`(git 제외)만 VM에 올린다. |
| 터널 IP | 터널 NIC에 IP가 없으면 `/etc/netplan/60-poc-tun.yaml` 별도 파일로만 부여한다(관리 NIC 설정 파일은 손대지 않음). 적용 전 사용자 확인. |

---

## 10. 로컬 lite 모드 (원격 호스트 준비 전 선행 검증)

노트북(2코어, 메모리 7GB)에서 VM 6대 대신 **OVS + 네트워크 네임스페이스 + 컨테이너**로 Phase 3~7 정책을 먼저 검증한다. 원격 2호스트 모드(Phase 0~2)는 집 Proxmox에 Ubuntu 24.04 VM 2대를 준비한 뒤 진행한다.

| 계획서 구성요소 | lite 대체 | 스크립트 |
|---|---|---|
| br-sdn / br-mgmt / br-trunk | 노트북 OVS에 동일하게 생성 (`fail-mode secure`, dpid 0x1) | `local/20-topology.sh` |
| VXLAN key 100 트렁크 | patch 포트 (br-sdn port 10 ↔ br-trunk) | 〃 |
| 단말 VM 3대 | netns `poc-biz01/inet01/unauth01`, NIC(eth0) 하나 | 〃, 조작은 `local/term.sh` |
| fw VM | netns `poc-fw` (eth0 관리, eth1 트렁크, eth2 → 노트북 NAT) | `local/40-fw.sh` |
| faucet-ctl VM | Faucet 공식 컨테이너 `poc-faucet` (eth0 10.255.0.10, eth1 = port 20) | `local/30-faucet.sh static\|dot1x` |
| radius VM | FreeRADIUS 컨테이너 `poc-radius` (10.255.0.20) | Phase 5에서 작성 |

- 실행 순서: `sudo local/10-packages.sh` → `sudo local/20-topology.sh` → `sudo local/30-faucet.sh static` → `sudo local/40-fw.sh` → `sudo tests/lite-phase4.sh`
- 정리: `sudo local/90-teardown.sh` (PoC가 만든 브리지·netns·컨테이너·iptables 규칙만 제거)
- 방화벽 DNS: 업무망 dnsmasq는 외부 포워딩 없음(`dnsmasq-biz.conf`), 인터넷망만 상위 DNS 포워딩(`dnsmasq-inet.conf`). t05(업무망 → 외부 DNS 차단)를 만족시키기 위함.
- lite 모드에서 검증되지 않는 것: VXLAN·MTU(t12), 실제 VM 단말 동작, 호스트 B 전체 중지(t09는 patch 포트 down으로 대체).
