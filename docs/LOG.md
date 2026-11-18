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
