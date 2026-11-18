# 로컬 lite 모드 고정값. local/*.sh가 source 한다.
# (원격 2호스트 모드의 env.sh와는 별개)

POC_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POC_RUN="$POC_REPO/run"            # 실행 중 생성물(렌더링된 설정, 로그). git 제외

MTU=1500                           # 로컬은 VXLAN 없음(patch 포트) → 1500

# 브리지
BR_SDN=br-sdn                      # Faucet 제어, fail-mode secure, dpid 0x1
BR_MGMT=br-mgmt                    # 관리망 (OpenFlow, RADIUS)
BR_TRUNK=br-trunk                  # "호스트 B" 쪽 트렁크 (일반 OVS)

# 관리망 주소 (계획서와 동일)
MGMT_HOST_IP=10.255.0.11/24        # br-mgmt 내부 포트 (OVS → 컨트롤러 연결용)
FAUCET_MGMT_IP=10.255.0.10/24
RADIUS_MGMT_IP=10.255.0.20/24
FW_MGMT_IP=10.255.0.30/24

# fw 외부 출구: fw(eth2) ↔ 노트북(fw-egr) → 노트북 NAT → 인터넷
EGR_NET=192.168.250.0/30
EGR_HOST_IP=192.168.250.1/30
EGR_FW_IP=192.168.250.2/30
FW_UPSTREAM_DNS=1.1.1.1

# 컨테이너 이미지
FAUCET_IMAGE="${FAUCET_IMAGE:-faucet/faucet:latest}"
RADIUS_IMAGE="${RADIUS_IMAGE:-freeradius/freeradius-server:latest-3.2}"

# 단말 (netns 이름 접두어 poc-)
# 이름:ofport:MAC
TERMINALS=(
  "biz01:1:02:00:00:00:01:01"
  "inet01:2:02:00:00:00:01:02"
  "unauth01:3:02:00:00:00:01:03"
)
