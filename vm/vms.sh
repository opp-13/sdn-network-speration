# 안쪽 VM 정의표 (vm/*.sh, hosts/check-phase2.sh 가 source 한다)
#
# 원칙 3: 단말 VM(vm-*)은 NIC 하나만. 관리망 NIC를 주지 않는다.
# MAC은 고정값 → 시험 스크립트·Faucet 로그에서 바로 알아볼 수 있게 lite 모드와 같은 값 사용.

POC_IMG_DIR=/var/lib/libvirt/images/poc
BASE_URL=https://cloud-images.ubuntu.com/noble/current
BASE_IMG=noble-server-cloudimg-amd64.img
ROLE_DISK_SIZE=8G          # 역할 이미지(패키지 설치용 루트 확장)
VM_DISK_SIZE=10G           # VM별 오버레이 크기

# 형식: 이름|호스트(a|b)|역할|메모리MB|vCPU|NIC 목록(공백 구분)
# NIC: 종류,연결대상,MAC,tap이름,ofport(-=지정안함),주소(-=없음|dhcp|CIDR)
#   종류 ovs = OVS 브리지에 직접 (virtualport openvswitch), net = libvirt 네트워크
#
# 구성 (env.sh POC_TOPOLOGY):
#   single(기본): SDN01 한 대에 6대 전부. fw 트렁크 NIC(tp-fw1)가 br-sdn port 10에 직접 붙음.
#                 메모리는 SDN01 8GB 안에 들어가게 (합계 약 5GB + 호스트)
#   dual        : radius·fw 를 host-b 에, fw 트렁크는 host-b br-trunk (VXLAN key 100 으로 host-a port 10)
if [[ "${POC_TOPOLOGY:-single}" == single ]]; then
  _B=a; _FW_TRUNK="ovs,br-sdn,52:54:00:00:1e:01,tp-fw1,10,-"
  _M_F=1024; _M_T=768; _M_R=768; _M_W=768
else
  _B=b; _FW_TRUNK="ovs,br-trunk,52:54:00:00:1e:01,tp-fw1,-,-"
  _M_F=1536; _M_T=1024; _M_R=1024; _M_W=1024
fi
VMS=(
  "faucet-ctl|a|faucet|$_M_F|2|ovs,br-mgmt,52:54:00:00:0a:00,tp-fctl0,-,10.255.0.10/24 ovs,br-sdn,52:54:00:00:0a:01,tp-fctl1,20,-"
  "vm-biz01|a|term|$_M_T|1|ovs,br-sdn,02:00:00:00:01:01,tp-biz01,1,-"
  "vm-inet01|a|term|$_M_T|1|ovs,br-sdn,02:00:00:00:01:02,tp-inet01,2,-"
  "vm-unauth01|a|term|$_M_T|1|ovs,br-sdn,02:00:00:00:01:03,tp-unauth01,3,-"
  "radius|$_B|radius|$_M_R|1|ovs,br-mgmt,52:54:00:00:14:00,tp-rad0,-,10.255.0.20/24"
  "fw|$_B|fw|$_M_W|1|ovs,br-mgmt,52:54:00:00:1e:00,tp-fw0,-,10.255.0.30/24 $_FW_TRUNK net,default,52:54:00:00:1e:02,tp-fw2,-,dhcp"
)

# 단말별 인증서 (bake 시 이미지에 넣는 것). identity:cert 이름
declare -A TERM_CERTS=(
  [vm-biz01]="vm-biz01:vm-biz01"
  [vm-inet01]="vm-inet01:vm-inet01 vm-inet-big:vm-inet-big"
  [vm-unauth01]="vm-biz01:rogue-vm-biz01"     # 정상 인증서 없음. 위조 인증서만 (t04)
)

vm_field() { # vm_field <VMS 항목> <번호 1..6>
  echo "$1" | cut -d'|' -f"$2"
}
vms_on_host() { # vms_on_host a|b → 해당 호스트 VM 항목들
  local v; for v in "${VMS[@]}"; do [[ "$(vm_field "$v" 2)" == "$1" ]] && echo "$v"; done
}
vm_entry() { # vm_entry <이름>
  local v; for v in "${VMS[@]}"; do [[ "$(vm_field "$v" 1)" == "$1" ]] && { echo "$v"; return; }; done
}
