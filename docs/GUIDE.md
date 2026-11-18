# 입문 가이드: 인증서 하나로 업무망과 인터넷망을 나누는 네트워크

> 대상: 리눅스와 Docker는 다룰 줄 알지만 VLAN, SDN, 802.1X, RADIUS는 처음인 개발자.
> 이 문서 하나로 **왜 하는지 → 어떻게 동작하는지 → 직접 띄우고 시험하고 확장하는 법**까지 따라올 수 있게 썼다.
> 더 자세한 원래 계획은 [PLAN.md](../PLAN.md), 시험 결과는 [RESULTS.md](RESULTS.md), 작업 기록은 [LOG.md](LOG.md).

---

## 1. 한 장 요약

**하고 싶은 것**: 회사 PC가 랜선을 꽂으면, 그 PC에 들어 있는 **인증서**를 보고
- 업무용 PC면 **업무망**(인터넷 안 됨)에,
- 인터넷용 PC면 **인터넷망**(인터넷 됨)에

자동으로 붙인다. 두 망은 서로 통신할 수 없고, 오직 **방화벽 한 곳**에서만 만난다. 인증서가 없거나 가짜면 아무 데도 못 붙는다.

```
           인증서 보고 "업무용"         ┌──────────── 업무망 (VLAN 100) ──────┐
 [PC] ──▶ 스위치 ──▶ RADIUS에 물어봄 ──▶│                                    │──▶ 방화벽 ──X 인터넷
                       "인터넷용"       └──────────── 인터넷망 (VLAN 200) ───┘        └──▶ 인터넷
```

**결과**: 노트북 한 대에서 전부 재현해 시나리오 13개를 모두 통과했다(13/13). 정상 인증, 위조 인증서, MAC 복제, 장비 장애가 포함된다.

---

## 2. 왜 이걸 하나

금융회사는 **전자금융감독규정 제15조 제1항 제3호**에 따라 내부 업무 시스템을 인터넷과 분리해야 한다. 3호 영역은 랜선을 물리적으로 따로 까는 대신 **논리적 분리**도 허용되는 것으로 해석된다. 이 PoC는 "소프트웨어로 망을 나눠도 규정이 요구하는 수준으로 안전하게 동작하는가"를 검증한다.

지킨 원칙 5개를 개발자 언어로 옮기면 이렇다.

| 원칙 | 개발자 언어로 |
|---|---|
| 1. 망 간 통신은 방화벽에서만 결정 | 권한 검사를 미들웨어 한 곳에 모은다. 스위치(라우팅)에는 넣지 않는다 |
| 2. 실패하면 닫힌다 (fail-closed) | 인증 서버나 컨트롤러가 죽으면 기본값은 **deny**. 업무망에 새로 붙는 일은 절대 없다 |
| 3. 단말은 NIC 하나 | 우회 경로(두 번째 랜카드)가 있으면 분리 자체가 무의미하다 |
| 4. 관리망 분리 | 제어용 트래픽(OpenFlow, RADIUS)은 사용자 트래픽과 다른 망으로만 흐른다 |
| 5. 인증서 기반 인증 | 비밀번호나 MAC 주소가 아니라 **mTLS 클라이언트 인증서**로 단말을 식별한다 |

---

## 3. 꼭 필요한 개념 8개

### 3.1 MAC, IP, ARP, DHCP: 같은 방과 문

- **MAC 주소**: 랜카드 고유 번호(`02:00:00:00:01:01`). 같은 "방"(L2, 이더넷) 안에서 서로 찾을 때 쓴다.
- **IP 주소**: 논리 주소(`10.100.0.162`). 다른 방으로 가려면 **게이트웨이**(라우터, 방의 문)를 거친다.
- **ARP**: "10.100.0.1 가진 사람 MAC 주소 알려줘"라고 방 안에 외치는 것. **같은 방에 있어야만** 대답이 온다. 이 PoC는 ARP 응답 여부로 "그 망에 실제로 붙었는가"를 판정한다.
- **DHCP**: 단말이 켜지면 "IP 주세요"라고 방 전체에 외치고(브로드캐스트) 서버가 IP·게이트웨이·DNS를 준다. **IP를 받았다는 것 자체가 그 망에 붙었다는 증거**다.

### 3.2 VLAN: 스위치 하나를 여러 방으로 쪼개기

스위치 한 대를 소프트웨어로 여러 방으로 나눈 것이 **VLAN**이다. 번호(VID)로 구분한다.
- **VLAN 100 = 업무망**(`10.100.0.0/24`), **VLAN 200 = 인터넷망**(`10.200.0.0/24`)
- 다른 VLAN끼리는 ARP조차 닿지 않는다. 같은 스위치에 꽂혀 있어도 완전히 다른 방이다.

포트에는 두 종류가 있다.
- **access(untagged) 포트**: 단말이 꽂히는 포트. 단말은 VLAN을 모른다. 스위치가 "이 포트는 VLAN 100"이라고 정해 둔다. Faucet 설정에서는 `native_vlan`이다.
- **trunk(tagged) 포트**: 스위치와 방화벽 사이처럼 여러 VLAN이 한 선으로 지나가는 포트. 프레임마다 **802.1Q 태그**(봉투에 붙은 "100번 방" 라벨)가 붙는다. 설정에서는 `tagged_vlans`이다.

방화벽은 트렁크 하나를 받아서 `eth1.100`, `eth1.200`이라는 가상 인터페이스로 라벨별로 나눠 받는다.

### 3.3 SDN, OpenFlow, Open vSwitch: 스위치를 코드로

보통 스위치는 동작이 장비 안에 박혀 있다. **SDN**은 그 판단을 밖의 프로그램(**컨트롤러**)으로 꺼낸다.
- **Open vSwitch(OVS)**: 리눅스에서 도는 소프트웨어 스위치. 내부는 **흐름 규칙 테이블**, 즉 `if (조건) then (동작)` 목록이다.
- **OpenFlow**: 컨트롤러가 OVS에 규칙을 넣고 빼는 프로토콜.
- **`fail-mode secure`**: 컨트롤러와 연결이 끊겨도 OVS가 "알아서 일반 스위치처럼 동작"하지 않게 하는 설정. **원칙 2의 출발점**이다. 단, 이미 들어 있는 규칙은 지우지 않는다(9장 한계 1번).

실제 규칙 한 줄은 이렇게 생겼다 (`ovs-ofctl dump-flows br-sdn`, 실제 시험 출력):

```
table=1, priority=4096,in_port=1,vlan_tci=0x0000/0x1fff
         actions=push_vlan:0x8100,set_field:4196->vlan_vid,goto_table:2
```
"1번 포트로 태그 없는 프레임이 들어오면 VLAN 태그를 붙이고 VID를 4196(= 4096 + **100**)으로 설정해 다음 테이블로 보낸다." 즉 **1번 포트 = 업무망**이라는 뜻이다.

### 3.4 Faucet: YAML을 흐름 규칙으로 바꾸는 컨트롤러

**Faucet**은 오픈소스 OpenFlow 컨트롤러다. 사람이 YAML로 "포트 1은 VLAN 100" 같은 의도를 쓰면, Faucet이 위와 같은 흐름 규칙으로 **컴파일**해서 OVS에 넣는다. 이 PoC는 Faucet 1.10.12를 쓴다. [faucet/faucet.dot1x.yaml](../faucet/faucet.dot1x.yaml) 일부:

```yaml
vlans:
  biz:  { vid: 100 }      # 업무망
  inet: { vid: 200 }      # 인터넷망
interfaces:
  1:  { dot1x: true, native_vlan: inet }       # 인증이 필요한 포트. 기본은 인터넷망
  10: { tagged_vlans: [biz, inet] }            # 방화벽으로 가는 트렁크
  20: { output_only: true }                    # 인증 프레임을 Faucet으로 넘기는 포트
```
`routers:` 블록이 없다는 점이 중요하다. Faucet은 **망 사이 라우팅을 하지 않는다**(원칙 1).

### 3.5 802.1X: 랜선을 꽂으면 로그인부터

웹 로그인처럼 **포트 단위 로그인**이다. 등장인물은 셋이다.

| 역할 | 표준 이름 | 이 PoC에서 |
|---|---|---|
| 로그인하는 쪽 | Supplicant | 단말에서 도는 `wpa_supplicant` |
| 문지기 | Authenticator | Faucet (안의 `chewie` 모듈) |
| 판정하는 쪽 | Authentication Server | FreeRADIUS |

- 인증 전 포트는 **EAPOL**(802.1X 전용 프레임, EtherType `0x888e`)만 통과시키고 나머지는 모두 버린다.
- 문지기는 판정하지 않는다. 단말과 RADIUS 사이에서 메시지를 **중계**만 한다.

### 3.6 EAP-TLS와 PKI: 랜선에서 하는 mTLS

- **EAP**: 802.1X 위에서 인증 대화를 주고받는 틀. 그 안에서 실제 인증 방식을 고른다.
- **EAP-TLS**: 그 방식으로 **TLS 상호 인증(mTLS)**을 쓴다. 서버도 인증서를 내고, 단말도 클라이언트 인증서를 낸다.
- **PKI**: PoC 전용 CA를 만들고([pki/make-ca.sh](../pki/make-ca.sh)), 단말마다 인증서를 발급한다([pki/make-client.sh](../pki/make-client.sh)). **인증서의 CN = 단말 이름**(`vm-biz01`)이다.
- 추가한 방어 두 가지:
  - `check_cert_cn = %{User-Name}`: 인증서 CN과 로그인 ID가 같아야 한다. 이게 없으면 인터넷 단말 인증서를 들고 "나 vm-biz01이야"라고 주장할 수 있다.
  - 단말도 RADIUS 서버 인증서를 검증한다(`domain_match="radius.poc"`). 가짜 RADIUS에 속지 않는다.

### 3.7 RADIUS: "누구냐"에 "어느 방으로"까지 답한다

**RADIUS**는 네트워크 장비가 쓰는 인증 서버 프로토콜이다(포트 1812/UDP). 핵심은 인증 성공 응답(Access-Accept)에 **추가 속성**을 실어 보낼 수 있다는 것이다. [freeradius/authorize](../freeradius/authorize):

```
vm-biz01
	Tunnel-Type = VLAN,
	Tunnel-Medium-Type = IEEE-802,
	Tunnel-Private-Group-Id = "biz"      ← "이 단말은 biz VLAN으로"
```
Faucet은 이 값을 **VLAN 이름**으로 해석해 포트의 VLAN을 바꾼다. 숫자 `"100"`은 안 된다. Faucet 소스가 `vlan.name == vlan_name`으로 비교하기 때문이다. 목록에 없는 이름은 `DEFAULT Auth-Type := Reject`로 거부된다.

### 3.8 네트워크 네임스페이스와 veth: 가벼운 가상 PC와 랜선

VM 대신 리눅스 기능으로 "PC"를 흉내 냈다.
- **네트워크 네임스페이스(netns)**: 자기만의 랜카드·IP·라우팅 표를 가진 격리 공간. Docker 컨테이너의 네트워크 격리가 바로 이것이다. `ip netns exec poc-biz01 <명령>`은 "biz01 PC 안에서 명령 실행"이다.
- **veth**: 양 끝이 이어진 가상 랜선. 한쪽은 netns 안(`eth0`), 다른 쪽은 OVS 포트에 꽂는다.
- 컨테이너도 `--network none`으로 띄운 뒤 같은 방식으로 veth를 꽂으면 똑같이 단말이 된다(7장).

---

## 4. 이 PoC의 구성

### 4.1 전체 그림

```
 관리망 br-mgmt (10.255.0.0/24) ── 사용자 트래픽은 절대 안 다님
   ├ 노트북            10.255.0.11   (OVS → 컨트롤러 연결용)
   ├ poc-faucet 컨테이너 10.255.0.10  (Faucet, OpenFlow 6653)
   ├ poc-radius 컨테이너 10.255.0.20  (FreeRADIUS, 1812/udp)
   └ poc-fw eth0       10.255.0.30

 br-sdn (Faucet이 조종하는 스위치, fail-mode secure)
   ├ 1  poc-biz01     업무 단말 (인증서 vm-biz01)
   ├ 2  poc-inet01    인터넷 단말 (인증서 vm-inet01)
   ├ 3  poc-unauth01  인증서 없는 단말 (공격자 역할)
   ├ 4~9 예비 포트     endpoint.sh로 붙이는 자리
   ├ 10 ─── 트렁크(VLAN 100, 200) ─── br-trunk ─── poc-fw eth1
   └ 20 ─── poc-faucet eth1 (인증 프레임 수신)

 poc-fw (경계 방화벽 netns)
   eth1.100 10.100.0.1  업무망 게이트웨이 + DHCP(외부 DNS 없음)
   eth1.200 10.200.0.1  인터넷망 게이트웨이 + DHCP + DNS
   eth2 ──▶ 노트북 NAT ──▶ 인터넷 (인터넷망 출발만 허용)
```

### 4.2 포트 모드와 태깅: 태그가 어디서 붙고 어디서 떨어지나

#### 802.1Q 태그가 뭔지

```
일반 이더넷 프레임   | 목적지 MAC | 출발지 MAC |               | 타입 0x0800 | IP 데이터 |
802.1Q 태그 프레임   | 목적지 MAC | 출발지 MAC | 0x8100 | VID |  타입 0x0800 | IP 데이터 |
                                              └─ 4바이트 태그 ─┘
```
태그 안의 **VID**(VLAN 번호)가 "이 프레임은 몇 번 방 소속"이라는 라벨이다. OVS 규칙에서는 `set_field:4196->vlan_vid`처럼 보이는데, 4196 = 4096(태그 있음 표시 비트) + **100**이다.

#### 포트별 모드

| 위치 | 포트 | 모드 | 그 선 위를 다니는 프레임 |
|---|---|---|---|
| br-sdn | 1~3, 4~9 (단말) | **access** + 802.1X | 태그 없음. 어느 VLAN인지는 스위치가 정한다 (인증 결과, 기본 200) |
| br-sdn | 10 (방화벽 쪽) | **trunk** | VLAN 100, 200 태그가 붙은 것만. 태그 없는 프레임은 버림 (native VLAN 없음) |
| br-sdn | 20 (Faucet) | output_only (인증 전용) | 태그 없는 EAPOL만 |
| br-trunk | 전부 | 일반 학습 스위치 | 태그를 건드리지 않고 그대로 통과 ("호스트 B까지 이어진 케이블" 역할) |
| poc-fw | eth1 | trunk 수신 | 태그 프레임. 커널이 VID를 보고 `eth1.100`, `eth1.200`으로 나눠 태그를 떼고 전달 |
| br-mgmt | 전부 | VLAN 없음 | 관리망 전용. 업무·인터넷 VLAN과 섞이지 않음 |

#### 구성도: 태그 상태를 따라가 보기

```
   ① 단말 (access)           ② br-sdn: Faucet 규칙            ③ 트렁크 (tagged)              ④ 방화벽 poc-fw
      태그 없음                  태그 붙이기/떼기                  태그 있음                       서브인터페이스

 biz01 ─[ETH|IP]──▶ port 1 ──▶ push_vlan 100 ─┐
                                               ├─▶ port 10 ═[ETH|100|IP]═╗                 ┌─▶ eth1.100  10.100.0.1
 inet01 ─[ETH|IP]─▶ port 2 ──▶ push_vlan 200 ─┘            [ETH|200|IP]  ╠═ br-trunk ═▶ eth1 ┤     (업무망 GW, DHCP)
                                                                         ║  (patch)        └─▶ eth1.200  10.200.0.1
 unauth01 ────────▶ port 3 ──▶ EAPOL 외에는 drop                         ║                       (인터넷망 GW, DHCP, DNS)
                                                                         ║
 돌아오는 길:  biz01 ◀─[ETH|IP]── pop_vlan, output:1 ◀── port 10 ◀═[ETH|100|IP]═╝  ◀── eth1.100이 보낼 때 커널이 태그 100을 붙임

                                                         ┌──── 방화벽 nftables ────┐
                                eth1.100 ──X──▶ eth2 (외부)    업무망 → 외부 drop
                                eth1.100 ──X──▶ eth1.200       업무망 ↔ 인터넷망 drop
                                eth1.200 ─────▶ eth2 (NAT) ──▶ 인터넷
```

#### 실제 규칙으로 확인 (`tests/out/phase6-flows-after.txt`, 인증 완료 상태)

| 의미 | 규칙 |
|---|---|
| access 1번: 태그 없는 프레임에만 VLAN 100 태그 부착 | `table=1, in_port=1,vlan_tci=0x0000/0x1fff actions=push_vlan:0x8100,set_field:4196->vlan_vid` |
| access 2번: VLAN 200 태그 부착 | `table=1, in_port=2,vlan_tci=0x0000/0x1fff actions=push_vlan:0x8100,set_field:4296->vlan_vid` |
| trunk 10번: 태그 100, 200만 받음 | `table=1, in_port=10,dl_vlan=100 actions=goto_table:2` (200도 동일) |
| 그 외 전부 버림 | `table=1, priority=0 actions=drop` |
| 업무 PC로 갈 때: 태그 떼고 1번으로 | `table=3, dl_vlan=100,dl_dst=02:00:00:00:01:01 actions=pop_vlan,output:1` |
| 방화벽으로 갈 때: 태그 유지한 채 10번으로 | `table=3, dl_vlan=100,dl_dst=1a:a1:9d:dd:dd:42 actions=output:10` |
| 업무망 브로드캐스트: 트렁크와 1번에만 | `table=4, dl_vlan=100,dl_dst=ff:ff:ff:ff:ff:ff actions=output:10,pop_vlan,output:1` |

이 규칙들이 만드는 보안 효과는 다음과 같다.
- **단말이 스스로 태그를 붙여도 소용없다 (VLAN hopping 방지).** access 포트 규칙은 `vlan_tci=0x0000/0x1fff`, 즉 태그 없는 프레임에만 매칭된다. 인터넷 단말이 직접 태그 100을 붙여 보내면 맞는 규칙이 없어 `priority=0 drop`에 걸린다.
- **트렁크에 native VLAN이 없다.** 10번은 태그 100·200만 받고 태그 없는 프레임은 버린다. 이중 태그로 다른 VLAN에 끼어드는 공격의 여지가 없다.
- **브로드캐스트는 자기 VLAN 안에서만 퍼진다.** 업무망 브로드캐스트는 트렁크와 업무 포트(1번)에만 나간다.
- **802.1X 인증이 access 포트의 VLAN을 바꾼다.** 인증 전 1번 포트 규칙은 `set_field:4296`(200)이고, `"biz"` 응답 후 `4196`(100)으로 교체된다. 1번 포트는 VLAN 100의 브로드캐스트 목록으로 옮겨진다.

> **발견 (개선 권장)**: 인터넷망 브로드캐스트 규칙은 `dl_vlan=200 ... output:10,pop_vlan,output:2,output:3`이다. **미인증 3번 포트에도 나간다.** 미인증 포트의 기본 VLAN(native_vlan)이 인터넷망이기 때문이다. 미인증 단말은 아무것도 보낼 수 없지만, 인터넷망의 브로드캐스트(ARP 요청, DHCP 응답 등)는 엿들을 수 있다. 업무망은 해당 없다. 개선안: 802.1X 포트의 기본 VLAN을 **트렁크에 실리지 않는 격리 VLAN**(예: `quarantine`, VID 999)으로 바꾼다. 그러면 미인증 포트는 아무것도 받지 못하고, "인증서는 유효한데 VLAN 속성이 빠진" 경우도 인터넷망 대신 격리 VLAN에 떨어진다(9장 한계 4번도 함께 해결).

### 4.3 구성요소와 파일

| 구성요소 | 무엇 | 설정·스크립트 |
|---|---|---|
| OVS 브리지 3개, 단말·방화벽 netns | 스위치와 PC들 | [local/20-topology.sh](../local/20-topology.sh), 주소는 [local/env.local.sh](../local/env.local.sh) |
| Faucet 컨테이너 | SDN 컨트롤러 + 802.1X 문지기 | [local/30-faucet.sh](../local/30-faucet.sh), [faucet/](../faucet/) |
| 방화벽 | 망 사이 유일한 통로 | [local/40-fw.sh](../local/40-fw.sh), [firewall/nftables.conf](../firewall/nftables.conf), [firewall/dnsmasq-biz.conf](../firewall/dnsmasq-biz.conf), [firewall/dnsmasq-inet.conf](../firewall/dnsmasq-inet.conf) |
| RADIUS 컨테이너 | 인증서 판정 + VLAN 지정 | [local/50-radius.sh](../local/50-radius.sh), [freeradius/](../freeradius/) |
| 인증서 | CA, 단말 인증서, 위조 인증서 | [pki/](../pki/) (개인키는 `pki/private/`, git 제외) |
| 단말 조작 | 인증, DHCP, 명령 실행 | [local/supp.sh](../local/supp.sh), [local/term.sh](../local/term.sh), [local/endpoint.sh](../local/endpoint.sh) |
| 시험 | 단계별 PASS/FAIL | [tests/](../tests/) |

### 4.4 원래 계획(VM 2대 호스트)과의 대응

원래 계획은 KVM 호스트 2대에 VM 6대를 올리는 것이다. 노트북 자원(2코어, 7GB)으로는 무리라서 같은 구조를 가볍게 옮겼다.

| 원래 계획 | 이 PoC (lite) |
|---|---|
| 단말 VM 3대 | netns 3개 (NIC 1개씩) |
| faucet-ctl VM, radius VM | 컨테이너 2개 |
| fw VM | netns |
| 호스트 A↔B VXLAN 터널 | 같은 노트북 안이라 patch 포트(가상 케이블) |

로직(설정 파일, 정책, 시험)은 그대로 재사용된다. VXLAN·MTU·물리 분리는 나중에 2호스트 환경에서 따로 검증한다.

---

## 5. 패킷 한 개의 여행: 업무 PC가 붙기까지

`biz01`이 처음 켜져서 업무망 주소를 받고, 인터넷에 나가려다 막히기까지를 따라가 본다.

**① 인증 전: 포트가 닫혀 있다**
1번 포트에는 EAPOL만 통과하는 규칙만 있다.
```
table=0, priority=20481,in_port=1,dl_type=0x888e actions=set_field:00:00:00:00:00:01->eth_dst,output:20
```
EAPOL 프레임은 목적지를 "포트 1용 가상 MAC"으로 바꿔 20번 포트(Faucet)로 보낸다. 그래서 Faucet은 이 프레임이 몇 번 포트에서 왔는지 안다. 그 밖의 프레임(DHCP 포함)은 매칭되는 규칙이 없어 **버려진다**.

**② 단말이 로그인을 시작한다**
`wpa_supplicant`가 EAPOL-Start를 보내고, Faucet(chewie)과 EAP 대화를 시작한다. TLS 핸드셰이크 메시지가 단말 → Faucet → RADIUS(관리망)로 중계된다.

**③ RADIUS가 판정하고 VLAN을 알려 준다**
인증서가 PoC CA로 서명됐는지, CN이 로그인 ID와 같은지, 등록된 이름인지 확인한다. 통과하면 이렇게 응답한다 (`docker logs poc-radius`):
```
Sent Access-Accept Id 6 from 10.255.0.20:1812 to 10.255.0.10:60867
  Tunnel-Private-Group-Id = "biz"
```

**④ Faucet이 포트를 업무망으로 옮긴다**
Faucet 로그: `Success from MAC 02:00:00:00:01:01 on 1`. 그리고 규칙 두 개를 바꾼다.
```
table=0, priority=16384,in_port=1,dl_src=02:00:00:00:01:01 actions=goto_table:1     ← 이 MAC만 통과
table=1, priority=4096,in_port=1,vlan_tci=0x0000/0x1fff
         actions=push_vlan:0x8100,set_field:4196->vlan_vid,goto_table:2             ← VLAN 200 → 100
```
통과 규칙이 **(포트, MAC) 쌍**이라는 점이 중요하다. 다른 포트에서 이 MAC을 흉내 내도 통과하지 못한다(t10).

**⑤ DHCP로 업무망 주소를 받는다**
DHCP 브로드캐스트에 VLAN 100 태그가 붙어 10번 포트(트렁크)로 나간다 → 방화벽 `eth1.100` → 업무망 전용 dnsmasq가 `10.100.0.162`를 준다.

**⑥ 인터넷에 나가려다 방화벽에서 막힌다**
`ping 1.1.1.1` → 게이트웨이 `10.100.0.1`(방화벽) → nftables forward 체인:
```
iifname "eth1.100" oifname "eth2" counter drop comment "biz->external"
```
DNS로 우회해 보려 해도 업무망 dnsmasq에는 외부 DNS 서버가 설정돼 있지 않아 실패한다(t05).

같은 과정에서 `inet01`은 ③에서 `"inet"`을 받아 VLAN 200에 붙고, ⑥에서 `eth1.200 → eth2` 규칙에 걸려 주소 변환(NAT)을 거쳐 인터넷으로 나간다.

---

## 6. 직접 해 보기

### 6.1 준비
- Ubuntu(26.04에서 시험), Docker(사용자가 `docker` 그룹), 디스크 여유 수 GB.
- root가 필요한 스크립트는 `sudo`로 실행한다. 결과 파일은 사용자 소유로 `tests/out/`에 저장된다.

### 6.2 순서

```bash
cd sdn-network-speration

# 1) 설치: Open vSwitch, 컨테이너 이미지(Faucet, FreeRADIUS)
sudo local/10-packages.sh

# 2) 스위치·단말·방화벽 뼈대 (여러 번 실행해도 같은 결과)
sudo local/20-topology.sh
#    확인: 마지막에 "fail-mode: secure", 포트 1·2·3·10이 보이면 OK

# 3) 802.1X 없이 VLAN·방화벽 경로부터 확인 (Phase 3·4)
sudo local/30-faucet.sh static
sudo local/40-fw.sh
sudo tests/lite-phase4.sh                 # 기대: biz01 → 10.100.x, inet01 → 10.200.x, 정책 PASS

# 4) 인증서 + RADIUS 단독 시험 (sudo 불필요, Phase 5)
tests/phase5-eapol.sh                     # 기대: PASS 5/5 (정상 2, 큰 인증서, 위조 거부, 사칭 거부)

# 5) 802.1X 켜기 + 동적 VLAN 관문 (Phase 6)
sudo tests/lite-phase6.sh                 # 기대: PASS 11/11, "port 1 VLAN이 100(biz)으로 변경"

# 6) 시나리오 13개 (Phase 7, 약 7분)
sudo tests/lite-run-all.sh                # 기대: PASS 13 / FAIL 0

# 정리 (이 PoC가 만든 것만 지움)
sudo local/90-teardown.sh
```

### 6.3 손으로 만져 보기

```bash
sudo local/term.sh biz01 addr                       # biz01의 IP·경로
sudo local/term.sh biz01 run ping -c2 1.1.1.1       # 업무 단말 → 인터넷 (막혀야 정상)
sudo local/term.sh inet01 run curl -sI http://example.com   # 인터넷 단말 → 됨
sudo local/supp.sh biz01 status                     # 802.1X 상태 (suppPortStatus=Authorized)
sudo local/supp.sh biz01 logoff                     # 로그오프 → 즉시 차단
sudo ovs-ofctl -O OpenFlow13 dump-flows br-sdn      # 현재 흐름 규칙 전체
docker logs -f poc-radius                           # RADIUS 판정 실시간
tail -f run/faucet-log/faucet.log                   # Faucet 이벤트 실시간
```

---

## 7. 단말·컨테이너를 원하는 망에 붙이기

**영역은 포트가 아니라 인증서로 정해진다.** 어느 포트에 꽂든 인증서가 업무용이면 업무망이 된다. 실제 회사 NAC와 같은 방식이다.

```bash
# 처음 한 번: 예비 포트 4~9를 Faucet에 반영 (기존 단말은 60초 안에 자동 재인증)
sudo local/30-faucet.sh dot1x --recreate

sudo local/endpoint.sh add pc1 biz                                   # 업무망 PC (netns)
sudo local/endpoint.sh add web1 inet --container nginx:alpine        # 인터넷망 nginx
sudo local/endpoint.sh add box1 biz --container ubuntu:24.04 --cmd "sleep infinity"

sudo local/endpoint.sh list           # 이름, 영역, 포트, VLAN, IP
sudo local/endpoint.sh test pc1       # 게이트웨이·외부·다른 단말까지 도달/차단 표
sudo local/endpoint.sh exec web1 sh   # 단말 안으로 들어가기
sudo local/endpoint.sh del web1       # 제거 (RADIUS 등록도 해제)
```

`add`가 하는 일은 다음 다섯 가지다.
1. 인증서 발급: `CN=ep-<이름>`
2. [freeradius/endpoints](../freeradius/endpoints)에 "이름 → biz/inet" 등록 후 RADIUS 재기동
3. netns 또는 컨테이너(`--network none`)를 만들고 빈 예비 포트에 veth로 연결
4. 노트북의 `wpa_supplicant`를 그 네임스페이스 안에서 실행해 802.1X 인증. 이미지에 아무것도 설치할 필요가 없다.
5. DHCP로 주소 받기

`pc1`(업무)과 `web1`(인터넷)을 붙이고 `test pc1`을 실행하면, **업무망 게이트웨이만 "도달"이고 나머지(인터넷망, 외부, web1, 관리망)는 모두 "차단"**이어야 정상이다.

---

## 8. 시험 시나리오 해설

각 시험은 "어떤 공격이나 장애를 막으려는가"를 확인한다. 스크립트는 [tests/lite-run-all.sh](../tests/lite-run-all.sh)이다.

| 번호 | 막으려는 것 / 확인할 것 | 확인 방법 | 결과 |
|---|---|---|---|
| t01 | 업무 단말이 올바른 망에 붙는가 | 인증 후 포트 VLAN 100, 주소 10.100.x | PASS |
| t02 | 인터넷 단말은 인터넷이 되는가 | VLAN 200, ping·DNS·HTTP 성공 | PASS |
| t03 | 인증서 없는 PC가 꽂혀도 막히는가 | DHCP 실패 + **IP를 직접 넣어도** 게이트웨이 ARP 무응답 | PASS |
| t04 | 가짜 CA로 만든 "vm-biz01" 인증서 | RADIUS가 `certificate verify failed`로 거부 | PASS |
| t05 | 업무망에서 인터넷 유출 (ping, DNS 터널, HTTP) | 모두 실패 | PASS |
| t06 | 업무망 ↔ 인터넷망 직접 통신 | 양방향 실패 (방화벽 drop) | PASS |
| t07 | RADIUS가 죽었을 때 업무망이 열리는가 | 새 인증 실패, 포트는 업무망으로 안 바뀜 | PASS |
| t08 | 컨트롤러(Faucet)가 죽었을 때 | 새 단말 차단, 망 혼합 없음 | PASS (한계 1 참고) |
| t09 | 방화벽 쪽 호스트 전체 장애 | 양 망 모두 외부 불가, 새 인증 실패, 복구 후 정상 | PASS |
| t10 | 미인증 포트에서 업무 PC의 MAC 흉내 | (포트, MAC) 쌍 규칙이라 차단, 원래 PC는 영향 없음 | PASS |
| t11 | 로그오프하면 바로 끊기는가 | 통과 규칙 즉시 삭제, VLAN 200 복귀 | PASS |
| t12 | 큰 인증서(9.5KB)에서 인증이 깨지는가 | 20회 연속 성공 (EAP 조각내기 정상) | PASS |
| t13 | 관리망에서 업무망으로 들어가기 | 업무 PC·방화벽 업무망 주소 모두 차단 | PASS (1차에서 결함 발견·수정) |

참고로 방화벽은 정책상 VLAN에서 오는 ping에 응답하지 않는다(DHCP·DNS만 허용). 그래서 "망에 붙었는가"는 ping이 아니라 **ARP 응답**으로 판정한다. 1차 시험에서 이걸 놓쳐 의미 없는 PASS가 섞였다가, 고친 뒤 재실행했다([LOG.md](LOG.md)).

---

## 9. 발견한 것과 한계

**시험 중에 찾아서 고친 것**
- 방화벽이 관리망에서 오는 ping에 **자신의 업무망 쪽 주소(10.100.0.1)로도** 응답했다. 리눅스는 어느 인터페이스로 들어왔든 자기 주소면 응답하기 때문이다. ping 허용을 관리망 주소(10.255.0.30)로 한정해 해결했다.
- 계획서의 포트 20 설정(`native_vlan`)은 Faucet이 거부한다. `output_only: true`로 수정했다.

**알려진 한계 (운영에서 결정이 필요)**
1. **컨트롤러가 죽어 있는 동안에는 이미 인증된 단말이 계속 통신하고, 로그오프도 반영되지 않는다.** `fail-mode secure`가 기존 규칙을 지우지 않기 때문이다. 새 단말은 막히고 망도 섞이지 않는다. 완전 차단이 필요하면 "컨트롤러 연결이 끊기면 규칙을 전부 지우는" 감시 스크립트를 둔다. 대신 컨트롤러 장애 때 전체가 멈춘다.
2. 802.1X를 끈 정적 VLAN 모드에서는 컨트롤러가 꺼져도 같은 VLAN의 새 단말이 통신된다. 운영은 802.1X 모드 전제라 해당하지 않는다.
3. 로그오프한 뒤 같은 포트에서 다시 인증하는 데 45~78초가 걸린다. Faucet의 인증 모듈이 60초 주기로만 다시 묻기 때문이다. 가용성 문제이고 보안 문제는 아니다.
4. 인증서는 유효한데 RADIUS 설정에 VLAN이 빠지면 기본 VLAN(인터넷망)에 붙는다. 업무망으로는 절대 가지 않게 기본값을 인터넷망으로 둔 것이다.
5. Faucet의 802.1X는 공식 문서상 실험 기능이다. 실행 중 권한 변경(RFC 5176 CoA)은 지원하지 않는다.
6. 노트북 lite 환경이라 VXLAN·MTU, 실제 VM, 물리적 호스트 분리는 검증되지 않았다.

---

## 10. 문제가 생겼을 때

| 증상 | 확인 | 흔한 원인 |
|---|---|---|
| 컨트롤러 연결 안 됨 | `sudo ovs-vsctl get controller br-sdn is_connected` | Faucet 컨테이너 중지 → `sudo local/30-faucet.sh dot1x` |
| 인증이 안 됨 | `sudo local/supp.sh biz01 status`, `run/supplicant/biz01.log`, `docker logs poc-radius \| grep -E 'Reject\|ERROR'` | RADIUS 중지, 미등록 이름, CN 불일치, 로그오프 직후 지연(최대 60초 대기) |
| 인증은 됐는데 IP를 못 받음 | `sudo cat run/fw/dnsmasq-biz.log`, 포트 VLAN 확인 | 방화벽 dnsmasq 중지 → `sudo local/40-fw.sh` |
| 어느 VLAN에 붙었는지 | `sudo ovs-ofctl -O OpenFlow13 dump-flows br-sdn \| grep 'in_port=1,vlan_tci'` | `4196`=100(업무), `4296`=200(인터넷) |
| 방화벽에서 뭐가 막혔는지 | `sudo ip netns exec poc-fw nft list chain inet fw forward` | `counter packets N` 증가 항목 확인 |
| 전부 꼬였을 때 | `sudo local/90-teardown.sh` 후 6.2 순서대로 | — |

---

## 11. 용어집

| 용어 | 한 줄 정의 |
|---|---|
| VLAN / VID | 스위치를 논리적으로 나눈 방 / 그 방 번호 |
| access(native) / trunk(tagged) | 단말용 포트(태그 없음) / 여러 VLAN이 태그를 달고 지나가는 포트 |
| 802.1Q 태그 | 프레임에 붙는 VLAN 번호 라벨 |
| SDN | 스위치의 판단 로직을 외부 프로그램(컨트롤러)으로 뺀 구조 |
| OpenFlow | 컨트롤러가 스위치에 흐름 규칙을 넣는 프로토콜 |
| OVS | 리눅스 소프트웨어 스위치 (Open vSwitch) |
| Faucet / chewie | YAML 기반 OpenFlow 컨트롤러 / 그 안의 802.1X 모듈 |
| fail-mode secure | 컨트롤러가 없어도 일반 스위치로 바뀌지 않는 OVS 모드 |
| 802.1X / EAPOL | 포트 단위 로그인 표준 / 그 전용 이더넷 프레임 (0x888e) |
| EAP-TLS | 인증서로 하는 802.1X 인증 (= 랜선 mTLS) |
| RADIUS | 네트워크 장비용 인증 서버 프로토콜 |
| Tunnel-Private-Group-Id | RADIUS 응답에서 VLAN을 지정하는 속성 |
| CA / CN | 인증서 발급 기관 / 인증서 주체 이름 (= 단말 ID) |
| MAB | MAC 주소로 인증하는 우회 방식 (이 PoC는 미사용, 쉽게 위조되므로) |
| netns / veth | 격리된 네트워크 공간(= 가상 PC) / 가상 랜선 |
| nftables / dnsmasq | 리눅스 방화벽 / 작은 DHCP·DNS 서버 |
| fail-closed | 장애 시 기본값이 차단인 설계 |

---

## 12. 다음 단계

1. **2호스트 환경에서 재검증**: Proxmox 위에 Ubuntu 24.04 VM 2대(호스트 A: 4vCPU/8GB/100GB, 호스트 B: 2~4vCPU/6GB/60GB, CPU 타입 `host`, 터널용 내부 브리지 MTU 1550)를 만들고, [PLAN.md](../PLAN.md) Phase 0부터 진행한다. VXLAN·MTU·실제 VM 단말을 확인한다.
2. **운영 정책 결정**: 9장 한계 1번(컨트롤러 장애 시 기존 세션 처리)을 정한다.
3. **상용 장비로 이전**: [RESULTS.md](RESULTS.md)의 "운영 전환 시 상용 장비로 옮길 정책"(VLAN 체계, 단말 분류, 방화벽 규칙)이 기준이다.
