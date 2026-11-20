#!/usr/bin/env bash
# Phase 1: 호스트 VM 공통 패키지 (host-a, host-b 모두). 네트워크 설정은 바꾸지 않는다.
source "$(dirname "$0")/lib.sh"
need_root

PKGS=(qemu-kvm libvirt-daemon-system libvirt-clients virtinst openvswitch-switch
      cloud-image-utils libguestfs-tools tcpdump cpu-checker rsync)
log "패키지 설치: ${PKGS[*]}"
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${PKGS[@]}"
systemctl enable --now openvswitch-switch libvirtd >/dev/null

[[ -n "${SUDO_USER:-}" ]] && usermod -aG libvirt,kvm "$SUDO_USER"
# libguestfs(virt-customize)가 커널 이미지를 읽을 수 있게 (Ubuntu 기본은 root만 읽기)
chmod 0644 /boot/vmlinuz-* 2>/dev/null || true

log "확인"
kvm-ok | tail -1
ovs-vsctl --version | head -1
virsh --version
