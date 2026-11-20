# Proxmox 환경 준비 (원격 모드)

> 노트북 lite 모드([GUIDE.md](GUIDE.md))에서 검증한 설정을 실제 VM으로 옮기기 위한 준비 문서.
> 명령은 사용자가 실행한다. 결과는 `tools/pull-results.sh`로 노트북에 모아 분석한다.

## 0. 현재 구성: 단일 호스트 (`POC_TOPOLOGY="single"`, 2026-11-19 결정)

**SDN01(VM 101) 한 대가 KVM 호스트**이고, 그 안에 안쪽 VM 6대를 모두 올린다. SDN02는 사용하지 않는다(나중에 2호스트 구성 `dual`로 확장할 때 사용).

```
Proxmox
 └ SDN01 (192.168.50.240, 4코어/8GB/52GB, cpu host)
     br-mgmt (관리망 10.255.0.0/24, 로컬)
       ├ SDN01 자신 10.255.0.11
       ├ faucet-ctl eth0 10.255.0.10
       ├ radius     eth0 10.255.0.20
       └ fw         eth0 10.255.0.30
     br-sdn (Faucet 제어, secure, dpid 1)
       ├ 1 vm-biz01 / 2 vm-inet01 / 3 vm-unauth01   (단말, NIC 1개)
       ├ 10 fw eth1 (VLAN 100·200 트렁크, 직접 연결)
       └ 20 faucet-ctl eth1 (EAPOL)
     fw eth2 → libvirt default NAT (192.168.122.0/24) → SDN01 ens18 → vmbr0 → 인터넷
```

- 안쪽 VM 메모리: faucet-ctl 1GB, 나머지 768MB씩 → 합계 약 4.8GB (SDN01 8GB 안).
- 호스트 사이 VXLAN이 없으므로 vmbr1·ens19(터널 NIC)는 이 구성에서 쓰지 않는다. 설정은 남겨 두어도 무방.
- 아래 1~5장은 2호스트(`dual`) 기준으로 작성된 내용이다. 단일 구성에서는 **SDN01에서만** host-a 스크립트를 실행한다.

## 1. 네트워크 역할

| Proxmox 브리지 | 실제 연결 | 이 PoC에서의 역할 | 지나가는 트래픽 |
|---|---|---|---|
| **vmbr0** | 물리 NIC (LAN 192.168.50.x, 인터넷) | 호스트 VM의 **관리 NIC**: SSH(노트북 → VPN), apt, fw 외부 출구 | SSH, 패키지 다운로드, 인터넷망 단말의 NAT 트래픽 |
| **vmbr1** | 물리 포트 없음 (Proxmox 노드 IP만) | 호스트 A↔B **VXLAN 터널 전용** (언더레이) | VXLAN UDP 4789만 (key 100 트렁크, key 300 관리 오버레이) |

```
Proxmox 노드
 ├ vmbr0 ── 물리 NIC ── LAN/인터넷
 │   ├ host-a net0 (관리)     ← 노트북 SSH (VPN 192.168.50.x)
 │   └ host-b net0 (관리)     ← fw 외부 출구도 여기로 (libvirt NAT 경유)
 └ vmbr1 (MTU 1550, 내부 전용)
     ├ host-a net1  10.10.0.1  ═╗
     └ host-b net1  10.10.0.2  ═╝ VXLAN key 100 (업무·인터넷 VLAN 트렁크), key 300 (관리 오버레이)

host-a VM 안: br-sdn(Faucet 제어) + 단말 VM 3대 + faucet-ctl VM
host-b VM 안: br-trunk + fw VM + radius VM
```

참고:
- **802.1X 프레임(EAPOL)은 vmbr0·vmbr1을 지나지 않는다.** host-a 안에서 단말 VM ↔ OVS(br-sdn) 사이에서만 오간다. 리눅스 브리지가 EAPOL을 전달하지 않는 문제는 해당 없다.
- 업무망·인터넷망 VLAN 트래픽은 vmbr1 위에 VXLAN으로 캡슐화되어 지나간다. vmbr1에 물리 포트가 없으니 외부로 새지 않는다. VXLAN은 암호화되지 않으므로 **vmbr1에 물리 포트를 붙이지 말 것.**
- 주소 `10.10.0.x`는 예시다. vmbr1에 이미 준 IP와 **같은 대역의 빈 주소**를 쓴다.

## 2. Proxmox 노드에서 (1회)

### 2.1 중첩 가상화 확인
```bash
cat /sys/module/kvm_intel/parameters/nested    # Intel: Y
cat /sys/module/kvm_amd/parameters/nested      # AMD: 1
```
`N`/`0`이면 켜고 재부팅:
```bash
echo "options kvm_intel nested=1" > /etc/modprobe.d/kvm-nested.conf   # AMD는 kvm_amd
```

### 2.2 vmbr1 MTU 1550
`/etc/network/interfaces`의 vmbr1 블록에 `mtu 1550` 한 줄을 추가한다. **vmbr0 블록은 건드리지 않는다.**
```
auto vmbr1
iface vmbr1 inet static
        address 10.10.0.254/24      (기존 10.10.0.0은 네트워크 주소라 변경)
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        mtu 1550
```
```bash
ifreload -a
ip link show vmbr1 | grep -o 'mtu [0-9]*'      # → mtu 1550
```

### 2.3 호스트 VM 2대 설정
VM ID를 `<A>`, `<B>`로 표기한다. VM을 끈 상태에서 실행:
```bash
qm set <A> --cpu host --balloon 0 --cores 4 --memory 8192 \
  --net0 virtio,bridge=vmbr0,firewall=0 \
  --net1 virtio,bridge=vmbr1,firewall=0,mtu=1550
qm set <B> --cpu host --balloon 0 --cores 2 --memory 6144 \
  --net0 virtio,bridge=vmbr0,firewall=0 \
  --net1 virtio,bridge=vmbr1,firewall=0,mtu=1550
qm config <A> | grep -E 'cpu|net|memory|balloon'
```
- `--net0`, `--net1`을 다시 지정하면 **MAC 주소가 바뀔 수 있다.** 이미 NIC가 있으면 GUI(Hardware → Network Device → Edit)에서 bridge·Firewall 체크 해제·MTU만 바꾸는 것이 안전하다.
- `cpu host`가 없으면 안쪽 VM이 KVM 가속 없이 느리게 돈다.
- `firewall=0`: Proxmox 방화벽이 VXLAN 등을 가로채지 않게 한다.
- 디스크: host-a 100GB, host-b 60GB 권장 (안쪽 VM 이미지 보관).

## 3. 호스트 VM 안에서 (각 1회)

### 3.1 SSH
노트북에서 (VPN 연결 상태):
```bash
ssh-copy-id <user>@192.168.50.<A>      # host-b도 동일
ssh <user>@192.168.50.<A> 'hostname; ip -br link'
```

### 3.2 터널 NIC 설정
[hosts/60-poc-tun.yaml.example](../hosts/60-poc-tun.yaml.example)의 안내대로 `/etc/netplan/60-poc-tun.yaml`을 만들고 `sudo netplan try`를 실행한다. 관리 NIC 설정 파일은 손대지 않는다.
```bash
ip -br addr show ens19; cat /sys/class/net/ens19/mtu      # 주소, 1550
ping -M do -s 1522 -c3 10.10.0.2                         # host-a → host-b, 1550바이트 통과해야 함
```

## 4. 노트북에서: env.sh와 사전 점검 (Phase 0)

```bash
cp env.sh.example env.sh      # 아래 값 채우기
#   HOST_A_SSH="<user>@192.168.50.<A>"   HOST_B_SSH="<user>@192.168.50.<B>"
#   HOST_A_MGMT_NIC="ens18"  HOST_B_MGMT_NIC="ens18"      (vmbr0 쪽, 기록용)
#   HOST_A_TUN_NIC="ens19"   HOST_B_TUN_NIC="ens19"
#   HOST_A_TUN_IP="10.10.0.1"  HOST_B_TUN_IP="10.10.0.2"
#   VM_MTU="1500"
tests/phase0-precheck.sh      # 읽기 전용: OS, KVM, NIC, MTU 1472/1522 측정 → tests/out/
```
완료 조건: 두 호스트 SSH 성공, `ping -s 1522 (MTU 1550): PASS` → `VM_MTU=1500`.

## 5. Phase 1: 호스트 기반 구성

```bash
# 노트북
tools/push.sh                                  # 저장소 → 두 호스트 ~/poc

# host-a 에서
cd ~/poc && sudo host-a/10-packages.sh && sudo host-a/20-br-mgmt.sh && sudo host-a/30-br-sdn.sh
# host-b 에서
cd ~/poc && sudo host-b/10-packages.sh && sudo host-b/20-br-mgmt.sh && sudo host-b/30-br-trunk.sh

# 양쪽 모두 끝난 뒤 각 호스트에서
sudo hosts/check-phase1.sh                     # PASS/FAIL, tests/out/phase1-host-<a|b>.txt

# 노트북
tools/pull-results.sh                          # → tests/out/remote/host-{a,b}/ (Claude가 분석)
```

| 스크립트 | 하는 일 | 호스트 네트워크 변경 |
|---|---|---|
| `10-packages.sh` | KVM, libvirt, OVS, libguestfs 등 설치 | 없음 |
| `20-br-mgmt.sh` | OVS `br-mgmt` + VXLAN key 300, 10.255.0.11/.12 (systemd 유닛으로 재부팅 후 유지) | 있음 → 실행 전 y/N 확인 |
| `host-a/30-br-sdn.sh` | `br-sdn` (secure, dpid 1) + `vx-trunk` (key 100, port 10) | 있음 → y/N |
| `host-b/30-br-trunk.sh` | `br-trunk` + `vx-trunk` (key 100), libvirt default NAT 활성 | 있음 → y/N |
| `hosts/check-phase1.sh` | 완료 조건 검사 | 없음 (읽기 전용) |
| `90-teardown.sh` | 이 PoC 브리지·유닛만 삭제 | 있음 → y/N |

Phase 1 완료 조건 (`check-phase1.sh`가 확인):
- KVM 가속 사용 가능, 터널 NIC MTU 1550
- 관리 오버레이 10.255.0.11 ↔ .12 ping, **VXLAN 위로 1500바이트 프레임 단편화 없이 통과**
- host-a: `br-sdn` secure, dpid 0x1, vx-trunk = port 10 / key 100
- host-b: vx-trunk key 100, libvirt default NAT 활성
- 스크립트를 두 번 실행해도 오류 없이 같은 결과

## 6. 다음 단계 (Phase 2~)
안쪽 VM 6대 생성. 단말·faucet-ctl·radius는 인터넷이 없으므로 `virt-customize`로 이미지에 패키지와 인증서를 미리 구워 넣는다. 이후 lite 모드의 Faucet·방화벽·RADIUS 설정과 시험 로직을 재사용한다. 스크립트는 Phase 1 통과 후 작성한다.
