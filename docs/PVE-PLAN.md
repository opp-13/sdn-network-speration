# Proxmox 일반 VM 적용 계획: Proxmox에 직접 띄우는 일반 VM에 인증서 기반 망 분리 적용

## Context
지금 PoC는 SDN01(중첩 KVM) 안의 VM 6대에서만 동작하고, 실제 VM 환경에서 Phase 0~7, 격리 VLAN, 포트 가드까지 검증을 마쳤다.
다음 목표는 **Proxmox GUI로 만드는 보통의 Linux 게스트 VM**도 802.1X 인증서에 따라 업무망(VLAN 100)이나 인터넷망(VLAN 200)에 자동 배정되게 하는 것이다.
결정 사항:
- Proxmox 노드에 OVS 브리지 **추가는 허용**한다. 기존 vmbr0·vmbr1은 변경하지 않는다.
- 게스트 OS는 Linux.
- 기존 방화벽(fw)과 RADIUS(SDN01 안의 VM)는 그대로 재사용한다.

## 1. 구조

```
Proxmox 노드
 ├ vmbr0 (LAN·인터넷)          기존 그대로
 ├ vmbr1 (내부, MTU 1550)       기존 그대로 → VXLAN 언더레이로 사용 (노드 10.10.0.254 ↔ SDN01 10.10.0.1)
 ├ vmbr11 (새 OVS, PoC 관리망)  노드 10.255.0.13, faucet-pve 10.255.0.40
 │    └ vx-mgmt (VXLAN key 300) ══ SDN01 br-mgmt  → radius 10.255.0.20, faucet-ctl, fw 와 연결
 └ vmbr10 (새 OVS, Faucet 제어 엑세스 스위치, secure, dpid 0x2)
      ├ port 20  faucet-pve eth1 (EAPOL, output_only)
      ├ port 10  vx-trunk (VXLAN key 110) ══ SDN01 br-sdn port 11 (tagged biz,inet) → port 10 → fw
      └ port 1000+VMID  일반 게스트 VM NIC (tap<VMID>i0, 802.1X, 기본 격리 VLAN 999)
```
- **Faucet 인스턴스를 하나 더 둔다(faucet-pve, Proxmox VM).** Faucet 1.10.12의 802.1X 모듈(chewie)은 첫 번째 DP의 `nfv_intf` 하나만 쓴다(`faucet_dot1x.py`, `first_valve`). 그래서 기존 faucet-ctl 하나로 두 스위치의 802.1X를 처리하기 어렵다. 각 엑세스 스위치가 자기 Faucet을 갖고, 트렁크로 기존 코어(SDN01 br-sdn → fw)에 올라가는 구조로 한다. 상용망에서 엑세스 스위치가 코어 스위치에 붙는 것과 같은 모양이다.
- 망 간 통신 결정은 계속 fw 한 곳에서만 한다(원칙 1). VLAN 100·200은 트렁크로 fw까지 그대로 간다.

## 2. 단계

### P0. 사전 확인 (노드, 읽기 전용)
- `pveversion`, ifupdown2 사용 여부, `systemctl is-active systemd-networkd`(tap 자동 설정 여부. SDN01의 `vt-*` 사고 재발 방지), 기존 브리지 이름, snippets 저장소(`local:snippets`) 사용 가능 여부.
- 작업 방식: 노트북 SSH 키를 노드 root에 등록할지, 아니면 사용자가 노드에서 직접 실행할지 정한다(노드 변경은 매번 내용을 보여 주고 y/N 확인).

### P1. Proxmox 노드 네트워크 (`pve/10-network.sh`, 검사 `pve/11-check.sh`) — P0 결과로 방식 변경
- P0 결과(2026-11-19): Proxmox 9.2.4·ifupdown2 3.3, systemd-networkd inactive, vmbr1 MTU 1550·SDN01까지 1550바이트 DF PASS, OVS 미설치(3.5.0), **Proxmox 방화벽 enabled**, **local 저장소에 snippets 없음**, `/etc/network/interfaces.d/sdn`(Proxmox SDN) 존재, VMID 100~130 사용 중, 16코어·여유 41GB.
- **변경: 브리지를 `/etc/network/interfaces`가 아니라 `ovs-vsctl`로만 생성**(OVS DB에 저장, 재부팅 후 유지). 관리망 IP는 systemd 유닛 `poc-pve-net`. → 노드 네트워크 설정 파일·`ifreload` 무관. 대신 GUI 브리지 목록에는 안 보이므로 VM 연결은 `qm set`.
  - vmbr10: secure, OF1.3, dpid 0x2, in-band 끔, 컨트롤러 tcp:10.255.0.40:6653, `vx-trunk` VXLAN key 110 → 10.10.0.1, ofport 10.
  - vmbr11: 10.255.0.13/24, `vx-mgmt` VXLAN key 300 → 10.10.0.1.
- **추가: Proxmox 호스트 방화벽 규칙**(`/etc/pve/nodes/<노드>/host.fw`, 백업 후): vmbr1에서 SDN01의 VXLAN(UDP 4789) 수신, vmbr11 관리망 ICMP.
- **추가: 저장소 local에 snippets 용도**(P3·P4용).
- SDN01 쪽 `host-a/60-pve-uplink.sh`: br-mgmt `vx-pve`(key 300), br-sdn `vx-pve-trunk`(key 110, ofport 11). 단일 구성 삭제 로직은 vx-mgmt/vx-trunk 이름만 지우므로 영향 없음. `check-phase1.sh`는 vx-pve* 제외, SDN01 포트 가드 제외 목록에 11 추가.
- 완료 조건(`pve/11-check.sh`): vmbr10 secure·dpid 2·port 10·컨트롤러, vmbr11 IP, 노드 → SDN01·radius·faucet-ctl 관리망 ping, VXLAN 위 1500바이트 DF, 방화벽 규칙, snippets.

- **2026-11-20 문서·소스 대조**: Proxmox wiki `Open_vSwitch`(2022-01 수정)는 interfaces 파일 예시만 있고 컨트롤러·fail-mode·VXLAN은 다루지 않음. pve-common `PVE/Network.pm` 확인 결과:
  - OVS 브리지 판별은 `ovs-vsctl br-exists` → ovs-vsctl로만 만든 브리지도 VM NIC 연결 가능.
  - `firewall=1`이면 tap과 OVS 사이에 Linux 브리지 `fwbr<VMID>i<N>`를 끼운다 → EAPOL 미전달 → `firewall=0` 필수.
  - VM 기동마다 `del-port` → `add-port`, `ofport_request`는 설정하지 않음 → hookscript post-start에서 포트 번호 고정 필요.
  - tap MTU = 브리지 MTU → vmbr10·vmbr11에 `mtu_request=1500` 명시.
  - `tag=`/`trunks=`가 NIC에 있으면 OVS 포트에 설정됨 → hookscript에서 거부.

### P2. faucet-pve VM (Proxmox VM, 1 vCPU / 1GB)
- SDN01에서 이미 만든 **role-faucet.qcow2를 그대로 가져와** `qm importdisk`로 쓴다(인터넷 불필요, Faucet 1.10.12 검증 버전).
- NIC: net0 = vmbr11 (10.255.0.40), net1 = vmbr10 (`firewall=0`), ofport 20 고정.
- 설정 `faucet/faucet.pve.yaml`:
  - dp `pve`(0x2), VLAN biz 100 / inet 200 / quarantine 999 (이름 동일)
  - port 10 tagged [biz, inet], port 20 output_only
  - **`interface_ranges: "1100-1999": {dot1x: true, native_vlan: quarantine}`** (VMID 100~999 → 포트 1100~1999)
  - dot1x: radius 10.255.0.20
- SDN01 dp1 설정 `faucet/faucet.dot1x.yaml`에 port 11(tagged biz, inet) 추가.
- RADIUS `freeradius/clients.conf`에 faucet-pve(10.255.0.40) 추가.
- `vm/deploy-faucet.sh`는 대상 IP·설정 파일을 인자로 받게 일반화한다.

### P3. Proxmox hookscript + 포트 가드 (노드)
- `local:snippets/poc-sdn-hook.sh`를 대상 VM에 `qm set --hookscript`로 연결한다.
  - **pre-start**: 태그 `poc-sdn`이 붙은 VM은 NIC가 정확히 1개이고, bridge=vmbr10, `firewall=0`, **`tag=`·`trunks=` 없음**이어야 한다. 아니면 기동을 거부한다(원칙 3 강제. VLAN은 Faucet만 결정).
    - `firewall=1`이면 Proxmox가 tap과 OVS 사이에 리눅스 브리지(fwbr)를 끼운다. 리눅스 브리지는 EAPOL을 전달하지 않아 802.1X가 깨진다.
  - **post-start**: `ovs-vsctl set interface tap<VMID>i0 ofport_request=1000+VMID`(포트 번호 고정).
- 포트 가드: `hosts/port-guard.sh` 재사용. `PORT_GUARD_BR=vmbr10`, `PORT_GUARD_SKIP="10 20"`, systemd 서비스로 설치.
- SDN01 포트 가드 제외 목록에 11 추가.

### P4. 게스트 VM 등록 도구 (`tools/pve-enroll.sh <VMID> <이름> <biz|inet>`)
1. 인증서 발급: `pki/make-client.sh`, CN = 이름.
2. RADIUS 등록부(`freeradius/endpoints`) 추가 후 `vm/deploy-radius.sh`로 반영.
3. cloud-init snippet 생성:
   - user-data: 인증서·키를 `/etc/poc/pki`에 넣음.
   - network-config: **netplan 내장 802.1X**(`auth: {key-management: 802.1x, method: tls, identity, ca-certificate, client-certificate, client-key}`) + `dhcp4: true`. 인증되면 networkd가 자동으로 DHCP를 받는다.
4. `qm set <VMID> --cicustom ... --tags poc-sdn --hookscript ... --net0 virtio,bridge=vmbr10,firewall=0`.
5. 등록 후 키가 담긴 snippet은 첫 부팅 확인 뒤 삭제한다(노드 저장소에 개인키를 남기지 않음).

- 게스트 템플릿: 인증 전에는 인터넷이 없어 패키지를 받을 수 없다. 그래서 **SDN01의 role-term.qcow2**(wpasupplicant, qemu-guest-agent 포함)를 Proxmox 템플릿(VM 9000)으로 가져와 복제해서 쓴다.

### P5. 검증 (`tests/pve-run.sh`, 노드에서 실행)
- 시범 VM 3대(템플릿 복제): pve-biz(biz), pve-inet(inet), pve-unauth(인증서 없음).
- 단말 조작은 `qm guest exec`(게스트 에이전트, 네트워크 비경유).
- 시나리오: 기존 t01~t06, t10, t11, 격리 VLAN 엿듣기, 컨트롤러 장애(faucet-pve 중지 + VM 재부팅, 포트 가드).
- **hookscript 거부 시험**: firewall=1 이거나 NIC가 2개면 기동이 거부되는지.
- **크로스 시험**: Proxmox VM ↔ SDN01 안 단말 사이에서 같은 망 연결과 업무↔인터넷 차단(트렁크로 fw를 거치는지).

## 3. 재사용하는 것
`hosts/port-guard.sh`, `vm/files/faucet.service`, role-faucet·role-term 이미지, `pki/make-client.sh`, `local/radius-render.sh`·`vm/deploy-radius.sh`, `freeradius/{eap,authorize,endpoints}`, `firewall/nftables.conf`(변경 없음), `tests/remote-*.sh`의 시나리오 로직·판정 함수(`l2_reach`, `port_vid`, `static_probe`).

## 4. 위험과 대응
| 위험 | 대응 |
|---|---|
| 노드 네트워크 변경 중 접속 끊김 | vmbr0·vmbr1 무변경, 별도 파일만 추가, `ifreload` 전 내용 확인, Proxmox 웹 콘솔 준비 |
| Proxmox 방화벽(fwbr)이 EAPOL 차단 | hookscript가 `firewall=0`을 강제 |
| VMID ≥ 1000이면 포트 번호 계산이 넘침 | 범위 밖 VMID는 hookscript가 기동 거부(또는 매핑 표) |
| 라이브 마이그레이션·다른 노드 | 범위 밖(노드 1대 기준). 다중 노드면 노드마다 vmbr10 + faucet 인스턴스 필요 |
| Faucet 802.1X 실험 기능 | 검증 버전 1.10.12 고정 |

## 5. 검증 완료 조건
- P1: 노드 ↔ 관리망 ping, VXLAN 1500바이트 DF 통과.
- P2: faucet-pve ↔ vmbr10 연결(`is_connected true`), check_faucet_config 통과.
- P5: `tests/pve-run.sh` 전 항목 PASS, `docs/RESULTS.md`에 "C. Proxmox 일반 VM 적용" 절 추가.
