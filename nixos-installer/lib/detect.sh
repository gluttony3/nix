#!/bin/bash
# lib/detect.sh — hardware detection: CPU microcode and GPU drivers for NixOS

detect_cpu() {
    log_section "CPU Detection"
    if grep -qi "intel" /proc/cpuinfo; then
        CPU_TYPE="intel"
        log_info "Intel CPU detected -> hardware.cpu.intel.updateMicrocode will be enabled"
    elif grep -qi "amd" /proc/cpuinfo; then
        CPU_TYPE="amd"
        log_info "AMD CPU detected -> hardware.cpu.amd.updateMicrocode will be enabled"
    else
        CPU_TYPE="generic"
        log_warn "Unknown CPU vendor, microcode update will be skipped"
    fi
    export CPU_TYPE
}

# Convert "01:00.0" (lspci format) to "PCI:1:0:0" (NixOS PRIME format)
_pci_to_nixos() {
    local raw="$1"
    local bus dev func
    IFS=':.' read -r bus dev func <<< "$raw"
    printf "PCI:%d:%d:%d" "$((16#${bus}))" "$((16#${dev}))" "$((10#${func}))"
}

detect_gpu() {
    log_section "GPU Detection"

    local gpu_info
    gpu_info=$(lspci 2>/dev/null | grep -iE "VGA compatible|3D controller|Display controller" || true)

    if [[ -z "$gpu_info" ]]; then
        log_warn "No GPU found via lspci, using generic fallback"
        GPU_TYPE="generic"
        export GPU_TYPE
        return
    fi

    log_step "Detected GPU(s):"
    echo "$gpu_info"
    echo ""

    # Check for hybrid Intel+NVIDIA first (most specific case)
    if echo "$gpu_info" | grep -qi "intel" && echo "$gpu_info" | grep -qi "nvidia"; then
        GPU_TYPE="hybrid-nvidia"

        # Try to auto-detect PCI bus IDs for PRIME configuration
        local intel_raw nvidia_raw
        intel_raw=$(lspci | grep -iE "VGA.*[Ii]ntel|[Ii]ntel.*UHD|[Ii]ntel.*HD Graphics|[Ii]ntel.*Iris" \
            | head -1 | awk '{print $1}')
        nvidia_raw=$(lspci | grep -i "NVIDIA" | head -1 | awk '{print $1}')

        if [[ -n "$intel_raw" && -n "$nvidia_raw" ]]; then
            INTEL_BUS_ID=$(_pci_to_nixos "$intel_raw")
            NVIDIA_BUS_ID=$(_pci_to_nixos "$nvidia_raw")
            log_info "Hybrid Intel+NVIDIA (PRIME Offload)"
            log_step "Intel bus ID : $INTEL_BUS_ID"
            log_step "NVIDIA bus ID: $NVIDIA_BUS_ID"
        else
            log_warn "Could not determine PCI bus IDs — PRIME offload config will need manual review"
            INTEL_BUS_ID=""
            NVIDIA_BUS_ID=""
        fi

    elif echo "$gpu_info" | grep -qi "nvidia"; then
        GPU_TYPE="nvidia"
        INTEL_BUS_ID=""
        NVIDIA_BUS_ID=""
        log_info "NVIDIA GPU -> proprietary driver (nvidia)"

    elif echo "$gpu_info" | grep -qi "amd\|radeon\|advanced micro devices"; then
        GPU_TYPE="amd"
        log_info "AMD GPU -> open-source drivers (amdgpu + mesa)"

    elif echo "$gpu_info" | grep -qi "intel"; then
        GPU_TYPE="intel"
        log_info "Intel GPU -> open-source drivers (mesa + intel-media-driver)"

    else
        GPU_TYPE="generic"
        log_warn "Unknown GPU -> generic mesa fallback"
    fi

    export GPU_TYPE INTEL_BUS_ID NVIDIA_BUS_ID
}
