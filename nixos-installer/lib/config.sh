#!/usr/bin/env bash
# lib/config.sh — collect user preferences, generate configuration.nix, run nixos-install

# ── Password hashing ──────────────────────────────────────────────────────────
# Uses openssl directly if available; otherwise fetches it via nix-shell.
# This is needed because the NixOS minimal live ISO does not ship openssl.

_hash_password() {
    local pw="$1"
    if command -v openssl &>/dev/null; then
        printf '%s' "$pw" | openssl passwd -6 -stdin
    else
        # nix-shell pulls openssl into a temporary environment
        printf '%s' "$pw" | nix-shell -p openssl --run "openssl passwd -6 -stdin"
    fi
}

# ── User information ───────────────────────────────────────────────────────────

ask_user_info() {
    log_section "Installation Configuration"

    ask_input HOSTNAME "Hostname"                              "nixos"
    ask_input USERNAME "Username"                              "user"
    ask_input TIMEZONE "Timezone (e.g. Europe/Kyiv)"          "Europe/Kyiv"
    ask_input LOCALE   "Default locale"                       "en_US.UTF-8"
    ask_input KEYMAP   "Console keymap (e.g. us, ua, de)"     "us"

    echo ""
    echo -e "${CYAN}Root password:${NC}"
    read -rs ROOT_PASSWORD; echo ""
    echo -e "${CYAN}Confirm root password:${NC}"
    read -rs ROOT_PASSWORD2; echo ""
    [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD2" ]] || die "Root passwords do not match"
    [[ -n "$ROOT_PASSWORD" ]] || die "Root password cannot be empty"

    echo ""
    echo -e "${CYAN}Password for user '${USERNAME}':${NC}"
    read -rs USER_PASSWORD; echo ""
    echo -e "${CYAN}Confirm password:${NC}"
    read -rs USER_PASSWORD2; echo ""
    [[ "$USER_PASSWORD" == "$USER_PASSWORD2" ]] || die "User passwords do not match"
    [[ -n "$USER_PASSWORD" ]] || die "User password cannot be empty"

    # Generate SHA-512 password hashes for NixOS hashedPassword
    log_step "Generating password hashes..."
    ROOT_HASH=$(_hash_password "$ROOT_PASSWORD")
    USER_HASH=$(_hash_password "$USER_PASSWORD")

    echo ""
    log_info "Hostname : $HOSTNAME"
    log_info "Username : $USERNAME"
    log_info "Timezone : $TIMEZONE"
    log_info "Locale   : $LOCALE"
    log_info "Keymap   : $KEYMAP"

    export HOSTNAME USERNAME TIMEZONE LOCALE KEYMAP ROOT_HASH USER_HASH
}

# ── Nix config fragments ───────────────────────────────────────────────────────

_boot_config() {
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        cat << 'EOF'
  # Boot loader — systemd-boot (UEFI)
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;
EOF
    else
        cat << EOF
  # Boot loader — GRUB (BIOS/Legacy)
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "${DISK}";
  boot.loader.grub.useOSProber = true;
EOF
    fi
}

_cpu_config() {
    case "$CPU_TYPE" in
        intel)
            echo "  hardware.cpu.intel.updateMicrocode = true;"
            ;;
        amd)
            echo "  hardware.cpu.amd.updateMicrocode = true;"
            ;;
        *)
            echo "  # CPU microcode: not configured (unknown CPU vendor)"
            ;;
    esac
}

_gpu_config() {
    case "$GPU_TYPE" in
        intel)
            cat << 'EOF'
  # Intel GPU — open-source (mesa + VA-API)
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver   # VAAPI for Broadwell+
      vaapiIntel           # legacy VAAPI
      vaapiVdpau
      libvdpau-va-gl
    ];
  };
EOF
            ;;
        amd)
            cat << 'EOF'
  # AMD GPU — open-source (amdgpu + mesa + Vulkan)
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      amdvlk               # Vulkan support
      rocmPackages.clr.icd # OpenCL (optional, remove if unneeded)
    ];
    extraPackages32 = with pkgs; [ driversi686Linux.amdvlk ];
  };
  services.xserver.videoDrivers = [ "amdgpu" ];
EOF
            ;;
        nvidia)
            cat << 'EOF'
  # NVIDIA GPU — proprietary driver
  hardware.graphics.enable = true;
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    modesetting.enable = true;         # required for Wayland
    powerManagement.enable = false;
    powerManagement.finegrained = false;
    open = false;                      # set true for open-source kernel module (Turing+)
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };
  boot.kernelParams = [ "nvidia-drm.modeset=1" ];
EOF
            ;;
        hybrid-nvidia)
            # Build PRIME offload config, with bus IDs if available
            cat << 'EOF'
  # Hybrid Intel + NVIDIA — PRIME Offload mode
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      vaapiIntel
      vaapiVdpau
    ];
  };
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = true;
    powerManagement.finegrained = true;  # fine-grained power mgmt (Turing+)
    open = false;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true;   # adds `nvidia-offload` helper command
      };
EOF
            # Add bus IDs if they were detected
            if [[ -n "${INTEL_BUS_ID:-}" && -n "${NVIDIA_BUS_ID:-}" ]]; then
                echo "      intelBusId  = \"${INTEL_BUS_ID}\";"
                echo "      nvidiaBusId = \"${NVIDIA_BUS_ID}\";"
            else
                cat << 'EOF'
      # Bus IDs could not be auto-detected — fill these in manually.
      # Run: lspci | grep -E "VGA|3D"
      # Then convert "01:00.0" -> "PCI:1:0:0"
      # intelBusId  = "PCI:0:2:0";
      # nvidiaBusId = "PCI:1:0:0";
EOF
            fi
            cat << 'EOF'
    };
  };
  boot.kernelParams = [ "nvidia-drm.modeset=1" ];
EOF
            ;;
        *)
            cat << 'EOF'
  # GPU: generic mesa fallback
  hardware.graphics.enable = true;
EOF
            ;;
    esac
}

_trim_config() {
    if [[ "$DISK_TYPE" == "ssd" ]]; then
        echo "  services.fstrim = { enable = true; interval = \"weekly\"; };"
    else
        echo "  # fstrim: disabled (HDD detected)"
    fi
}

# ── configuration.nix generator ───────────────────────────────────────────────

generate_nixos_config() {
    log_section "Generating NixOS Configuration"

    log_step "Running nixos-generate-config --root $MOUNTPOINT ..."
    nixos-generate-config --root "$MOUNTPOINT" \
        || die "nixos-generate-config failed"

    log_step "Writing /etc/nixos/configuration.nix ..."

    local boot_cfg cpu_cfg gpu_cfg trim_cfg
    boot_cfg=$(_boot_config)
    cpu_cfg=$(_cpu_config)
    gpu_cfg=$(_gpu_config)
    trim_cfg=$(_trim_config)

    # Escape hashes for use inside the heredoc
    local root_hash_escaped="${ROOT_HASH//\$/\$}"
    local user_hash_escaped="${USER_HASH//\$/\$}"

    cat > "$MOUNTPOINT/etc/nixos/configuration.nix" << NIXEOF
# /etc/nixos/configuration.nix
# Generated by nixos-installer on $(date -u '+%Y-%m-%d %H:%M UTC')
# Edit this file to customise your system, then run: nixos-rebuild switch

{ config, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # ── Boot loader ────────────────────────────────────────────────────
${boot_cfg}
  # ── CPU microcode ──────────────────────────────────────────────────
${cpu_cfg}

  # ── GPU drivers ────────────────────────────────────────────────────
${gpu_cfg}
  # ── Networking ─────────────────────────────────────────────────────
  networking.hostName = "${HOSTNAME}";
  networking.networkmanager.enable = true;

  # ── Locale & time ──────────────────────────────────────────────────
  time.timeZone = "${TIMEZONE}";
  i18n.defaultLocale = "${LOCALE}";
  console.keyMap = "${KEYMAP}";

  # ── KDE Plasma 6 + Wayland ─────────────────────────────────────────
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;    # forces SDDM itself to run on Wayland
  };
  services.desktopManager.plasma6.enable = true;

  # ── PipeWire audio ─────────────────────────────────────────────────
  security.rtkit.enable = true;  # realtime scheduling for pipewire
  hardware.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;   # 32-bit app compat (Steam, Wine)
    pulse.enable = true;        # PulseAudio compat layer
    jack.enable = true;         # JACK compat layer
  };

  # ── Bluetooth ──────────────────────────────────────────────────────
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # ── SSD TRIM ───────────────────────────────────────────────────────
  ${trim_cfg}

  # ── Users ──────────────────────────────────────────────────────────
  users.mutableUsers = false;  # all users managed via this config file

  users.users.root.hashedPassword = "${root_hash_escaped}";

  users.users.${USERNAME} = {
    isNormalUser = true;
    description  = "${USERNAME}";
    extraGroups  = [ "wheel" "networkmanager" "audio" "video" "input" "render" ];
    hashedPassword = "${user_hash_escaped}";
  };

  # Allow wheel group to use sudo
  security.sudo.wheelNeedsPassword = true;

  # ── System packages ────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    # Editors & shell tools
    vim
    nano
    git
    wget
    curl
    htop
    unzip
    p7zip

    # Filesystem & hardware
    ntfs3g
    exfatprogs
    dosfstools
    usbutils
    pciutils
    lshw

    # Desktop utilities
    xdg-utils
    xdg-user-dirs

    # KDE applications (kdePackages.* namespace required in NixOS 25+)
    kdePackages.konsole
    kdePackages.dolphin
    kdePackages.kate
    kdePackages.ark
    kdePackages.spectacle
    kdePackages.gwenview
    kdePackages.okular
    kdePackages.kcalc

    # Browser
    firefox

    # Fonts
    noto-fonts
    noto-fonts-emoji
    noto-fonts-cjk-sans
    liberation_ttf
  ];

  # ── Optional services ──────────────────────────────────────────────
  services.printing.enable = true;      # CUPS printing
  services.flatpak.enable = true;       # Flatpak support
  # xdg.portal is configured automatically by services.desktopManager.plasma6

  # ── System state version ───────────────────────────────────────────
  # Do NOT change this after first install — see man configuration.nix(5)
  system.stateVersion = "24.11";
}
NIXEOF

    log_info "configuration.nix written to $MOUNTPOINT/etc/nixos/"
    echo ""
    log_step "Preview of generated config:"
    cat "$MOUNTPOINT/etc/nixos/configuration.nix"
}

# ── Install ───────────────────────────────────────────────────────────────────

run_nixos_install() {
    log_section "Running nixos-install"

    echo ""
    log_warn "This step downloads and builds the entire system."
    log_warn "It can take 20-60+ minutes depending on your internet connection."
    echo ""

    confirm "Start nixos-install now?" || die "Cancelled by user"

    nixos-install --root "$MOUNTPOINT" --no-root-passwd \
        || die "nixos-install failed — check the output above for errors"

    log_info "nixos-install completed successfully"
}
