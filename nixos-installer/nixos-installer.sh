#!/bin/bash
# nixos-installer.sh — NixOS Installer
#
# Stack:
#   Desktop : KDE Plasma 6 (Wayland)
#   Audio   : PipeWire + WirePlumber
#   Network : NetworkManager
#   Boot    : systemd-boot (UEFI) / GRUB (BIOS)
#
# Auto-detected:
#   - Boot mode  : UEFI or BIOS/Legacy
#   - CPU        : Intel / AMD microcode
#   - GPU        : Intel / AMD / NVIDIA / Hybrid Intel+NVIDIA (PRIME)
#   - Disk type  : SSD (fstrim enabled) / HDD
#
# Usage: run as root from a NixOS live ISO
#   bash nixos-installer.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/detect.sh"
source "${SCRIPT_DIR}/lib/disk.sh"
source "${SCRIPT_DIR}/lib/config.sh"

export SCRIPT_DIR

# ── Cleanup on any exit ────────────────────────────────────────────
cleanup() {
    local exit_code=$?
    if (( exit_code != 0 )); then
        echo ""
        log_warn "Installer exited with error (code $exit_code)"
        log_warn "Attempting to unmount filesystems..."
        swapoff "${PART_SWAP:-}" 2>/dev/null || true
        umount -R "${MOUNTPOINT:-/mnt}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Welcome screen ─────────────────────────────────────────────────
show_welcome() {
    clear
    echo -e "${BOLD}${BLUE}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║              NIXOS INSTALLER                         ║"
    echo "  ║   KDE Plasma 6  |  PipeWire  |  Wayland             ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "  This installer will:"
    echo "    1. Detect your hardware (boot mode, CPU, GPU, disk type)"
    echo "    2. Partition and format the chosen disk automatically"
    echo "    3. Generate hardware-configuration.nix"
    echo "    4. Write a complete configuration.nix"
    echo "       (KDE Plasma 6 + Wayland, PipeWire, correct drivers)"
    echo "    5. Run nixos-install"
    echo ""
    log_warn "The target disk will be COMPLETELY ERASED."
    echo ""
    confirm "Start the installer?" || { echo "Bye."; exit 0; }
}

# ── Summary before install ─────────────────────────────────────────
show_summary() {
    log_section "Installation Summary"
    echo ""
    echo -e "  ${BOLD}Hardware${NC}"
    echo "    Boot mode  : $BOOT_MODE"
    echo "    CPU type   : $CPU_TYPE"
    echo "    GPU type   : $GPU_TYPE"
    echo "    Disk type  : $DISK_TYPE"
    echo ""
    echo -e "  ${BOLD}Disk layout${NC}"
    echo "    Device     : $DISK"
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        echo "    Partitions : EFI ($PART_EFI)  SWAP ($PART_SWAP)  ROOT ($PART_ROOT)"
    else
        echo "    Partitions : SWAP ($PART_SWAP)  ROOT ($PART_ROOT)"
    fi
    echo ""
    echo -e "  ${BOLD}System${NC}"
    echo "    Hostname   : $HOSTNAME"
    echo "    Username   : $USERNAME"
    echo "    Timezone   : $TIMEZONE"
    echo "    Locale     : $LOCALE"
    echo "    Keymap     : $KEYMAP"
    echo ""
}

# ── Finish ─────────────────────────────────────────────────────────
show_finish() {
    log_section "Installation Finished!"
    echo ""
    echo -e "  ${GREEN}${BOLD}NixOS is installed and ready.${NC}"
    echo ""
    echo "  What to do next:"
    echo "    1. Remove the installation media (USB/CD)"
    echo "    2. Reboot: ${BOLD}reboot${NC}"
    echo "    3. At the SDDM login screen, select 'Plasma (Wayland)'"
    echo "    4. Log in as: ${BOLD}${USERNAME}${NC}"
    echo ""
    echo "  After first boot, you can customise the system by editing:"
    echo "    ${BOLD}/etc/nixos/configuration.nix${NC}"
    echo "  and applying changes with:"
    echo "    ${BOLD}sudo nixos-rebuild switch${NC}"
    echo ""
    if [[ "$GPU_TYPE" == "hybrid-nvidia" && -z "${INTEL_BUS_ID:-}" ]]; then
        log_warn "PRIME bus IDs were not auto-detected."
        log_warn "To enable PRIME offload, edit /etc/nixos/configuration.nix,"
        log_warn "fill in hardware.nvidia.prime.intelBusId and nvidiaBusId,"
        log_warn "then run: sudo nixos-rebuild switch"
        echo ""
    fi

    confirm "Reboot now?" && reboot
}

# ── Main flow ──────────────────────────────────────────────────────
main() {
    check_root
    check_deps

    # 1 — Welcome
    show_welcome

    # 2 — Hardware detection
    detect_boot_mode
    detect_cpu
    detect_gpu

    # 3 — Disk setup
    select_disk
    plan_partitions
    do_partition
    do_format
    do_mount

    # 4 — User preferences (hostname, user, passwords, locale)
    ask_user_info

    # 5 — Summary
    show_summary
    confirm "Everything looks correct. Proceed?" || die "Cancelled by user"

    # 6 — Generate config & install
    generate_nixos_config
    run_nixos_install

    # 7 — Done
    show_finish
}

main
