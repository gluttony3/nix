#!/usr/bin/env bash
# lib/disk.sh — disk selection, partitioning, formatting, mounting

list_disks() {
    echo ""
    printf "  %-14s %-8s %-6s %-6s %s\n" "DEVICE" "SIZE" "TYPE" "MEDIA" "MODEL"
    echo "  -------------------------------------------------------"
    while IFS= read -r line; do
        local name size rota model
        name=$(awk '{print $1}' <<< "$line")
        size=$(awk '{print $2}' <<< "$line")
        rota=$(awk '{print $3}' <<< "$line")
        model=$(awk '{$1=$2=$3=""; print $0}' <<< "$line" | sed 's/^ *//')
        local media
        [[ "$rota" == "0" ]] && media="SSD" || media="HDD"
        printf "  %-14s %-8s %-6s %-6s %s\n" "/dev/$name" "$size" "disk" "$media" "$model"
    done < <(lsblk -d -o NAME,SIZE,ROTA,MODEL --noheadings | grep -v "^loop\|^sr\|^fd")
    echo ""
}

select_disk() {
    log_section "Disk Selection"
    list_disks

    ask_input DISK "Enter target disk (e.g. /dev/sda or /dev/nvme0n1)" ""
    [[ -b "$DISK" ]] || die "Device $DISK does not exist"

    # Detect SSD vs HDD via rotational flag
    local dev="${DISK##*/}"
    local rota
    rota=$(cat "/sys/block/${dev}/queue/rotational" 2>/dev/null || echo "1")

    if [[ "$rota" == "0" ]]; then
        DISK_TYPE="ssd"
        log_info "$DISK identified as SSD (fstrim will be enabled)"
    else
        DISK_TYPE="hdd"
        log_info "$DISK identified as HDD"
    fi

    export DISK DISK_TYPE
}

plan_partitions() {
    log_section "Partition Plan"

    # Swap = RAM size, capped at 8 GB
    local ram_kb
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local ram_gb=$(( (ram_kb + 1048575) / 1048576 ))
    if (( ram_gb <= 2 )); then
        SWAP_GB=$(( ram_gb * 2 ))
    elif (( ram_gb <= 8 )); then
        SWAP_GB=$ram_gb
    else
        SWAP_GB=8
    fi

    local disk_size
    disk_size=$(lsblk -d -o SIZE --noheadings "$DISK" | tr -d ' ')

    echo "  Disk      : $DISK  ($disk_size, $DISK_TYPE)"
    echo "  Boot mode : $BOOT_MODE"
    echo "  RAM       : ${ram_gb} GB  ->  Swap: ${SWAP_GB} GB"
    echo ""

    if [[ "$BOOT_MODE" == "uefi" ]]; then
        echo "  Proposed layout (GPT):"
        echo "    Part 1 :  512 MB   EFI  (FAT32)"
        echo "    Part 2 :  ${SWAP_GB} GB    SWAP"
        echo "    Part 3 :  rest     ROOT (ext4)"
    else
        echo "  Proposed layout (MBR):"
        echo "    Part 1 :  ${SWAP_GB} GB    SWAP"
        echo "    Part 2 :  rest     ROOT (ext4, bootable)"
    fi
    echo ""

    log_warn "ALL DATA ON $DISK WILL BE PERMANENTLY ERASED!"
    confirm "Continue with automatic partitioning?" || die "Cancelled by user"

    export SWAP_GB
}

do_partition() {
    log_section "Partitioning $DISK"

    log_step "Wiping existing signatures..."
    wipefs -af "$DISK" &>/dev/null || true
    sgdisk --zap-all "$DISK" &>/dev/null 2>&1 || true
    sync

    local swap_mb=$(( SWAP_GB * 1024 ))

    if [[ "$BOOT_MODE" == "uefi" ]]; then
        local efi_end=513
        local swap_end=$(( efi_end + swap_mb ))

        log_step "Creating GPT partition table..."
        parted -s "$DISK" mklabel gpt
        parted -s "$DISK" mkpart EFI  fat32       1MiB          ${efi_end}MiB
        parted -s "$DISK" set 1 esp on
        parted -s "$DISK" mkpart SWAP linux-swap  ${efi_end}MiB ${swap_end}MiB
        parted -s "$DISK" mkpart ROOT ext4        ${swap_end}MiB 100%

        PART_EFI=$(get_part  "$DISK" 1)
        PART_SWAP=$(get_part "$DISK" 2)
        PART_ROOT=$(get_part "$DISK" 3)

    else
        local swap_end=$(( 1 + swap_mb ))

        log_step "Creating MBR partition table..."
        parted -s "$DISK" mklabel msdos
        parted -s "$DISK" mkpart primary linux-swap 1MiB          ${swap_end}MiB
        parted -s "$DISK" mkpart primary ext4        ${swap_end}MiB 100%
        parted -s "$DISK" set 2 boot on

        PART_EFI=""
        PART_SWAP=$(get_part "$DISK" 1)
        PART_ROOT=$(get_part "$DISK" 2)
    fi

    log_step "Updating kernel partition table..."
    partprobe "$DISK"
    sleep 2
    udevadm settle

    log_info "Partition layout:"
    lsblk "$DISK"

    export PART_EFI PART_SWAP PART_ROOT
}

do_format() {
    log_section "Formatting Partitions"

    if [[ -n "$PART_EFI" ]]; then
        log_step "Formatting EFI: $PART_EFI  -> FAT32"
        mkfs.fat -F32 -n ESP "$PART_EFI"
    fi

    log_step "Formatting SWAP: $PART_SWAP"
    mkswap -L SWAP "$PART_SWAP"

    log_step "Formatting ROOT: $PART_ROOT  -> ext4"
    mkfs.ext4 -L ROOT -F "$PART_ROOT"

    log_info "All partitions formatted"
}

do_mount() {
    log_section "Mounting Partitions"

    log_step "ROOT -> $MOUNTPOINT"
    mount "$PART_ROOT" "$MOUNTPOINT"

    if [[ -n "$PART_EFI" ]]; then
        log_step "EFI  -> $MOUNTPOINT/boot"
        mkdir -p "$MOUNTPOINT/boot"
        mount "$PART_EFI" "$MOUNTPOINT/boot"
    fi

    log_step "Enabling SWAP"
    swapon "$PART_SWAP"

    log_info "Mount summary:"
    lsblk "$DISK"
}
