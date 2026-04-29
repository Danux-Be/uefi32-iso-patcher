#!/usr/bin/env bash
# uefi32-iso-patcher.sh — Inject bootia32.efi into a Linux ISO for 32-bit UEFI boot
# Target: Intel Atom Bay Trail (Z3735F and similar) tablets with 32-bit UEFI firmware

set -euo pipefail

# Global so the EXIT trap can always access it
WORKDIR=""

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}Usage:${NC}
  $(basename "$0") <input.iso> [output.iso]

${BOLD}Description:${NC}
  Patches a Linux ISO by injecting a 32-bit GRUB EFI bootloader (bootia32.efi)
  so it can boot on machines with 32-bit UEFI firmware (Bay Trail tablets, etc.).

${BOLD}Arguments:${NC}
  input.iso   Path to the source ISO image
  output.iso  Path for the patched ISO (default: <input>-uefi32.iso)

${BOLD}Examples:${NC}
  $(basename "$0") ubuntu-24.04-desktop-amd64.iso
  $(basename "$0") archlinux-2024.01.01-x86_64.iso patched.iso
EOF
    exit 0
}

# ── Dependency helpers ───────────────────────────────────────────────────────
detect_distro() {
    if command -v pacman &>/dev/null; then
        echo "arch"
    elif command -v apt-get &>/dev/null; then
        echo "debian"
    elif command -v dnf &>/dev/null; then
        echo "fedora"
    else
        echo "unknown"
    fi
}

install_deps() {
    local distro
    distro=$(detect_distro)
    info "Detected package manager: ${distro}"

    case "$distro" in
        arch)
            local pkgs=()
            command -v grub-mkimage &>/dev/null || pkgs+=(grub)
            command -v xorriso      &>/dev/null || pkgs+=(xorriso)
            command -v mformat      &>/dev/null || pkgs+=(mtools)
            if [[ ${#pkgs[@]} -gt 0 ]]; then
                info "Installing: ${pkgs[*]}"
                sudo pacman -Sy --noconfirm "${pkgs[@]}"
            fi
            ;;
        debian)
            local pkgs=()
            command -v grub-mkimage &>/dev/null || pkgs+=(grub-efi-ia32-bin)
            command -v xorriso      &>/dev/null || pkgs+=(xorriso)
            command -v mformat      &>/dev/null || pkgs+=(mtools)
            if [[ ${#pkgs[@]} -gt 0 ]]; then
                info "Installing: ${pkgs[*]}"
                sudo apt-get update -qq
                sudo apt-get install -y "${pkgs[@]}"
            fi
            ;;
        fedora)
            local pkgs=()
            command -v grub-mkimage &>/dev/null || pkgs+=(grub2-efi-ia32-modules)
            command -v xorriso      &>/dev/null || pkgs+=(xorriso)
            command -v mformat      &>/dev/null || pkgs+=(mtools)
            if [[ ${#pkgs[@]} -gt 0 ]]; then
                info "Installing: ${pkgs[*]}"
                sudo dnf install -y "${pkgs[@]}"
            fi
            ;;
        *)
            warn "Unknown distro — please install manually: grub (with i386-efi modules), xorriso, mtools"
            ;;
    esac
}

check_deps() {
    info "Checking dependencies…"
    local missing=()

    for cmd in grub-mkimage xorriso mformat; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    # grub i386-efi modules
    local grub_prefix
    grub_prefix=$(dirname "$(command -v grub-mkimage 2>/dev/null || true)")
    local module_dirs=(
        /usr/lib/grub/i386-efi
        /usr/share/grub/i386-efi
        /usr/lib/grub2/i386-efi
        /usr/lib64/grub/i386-efi
    )
    local found_modules=false
    for d in "${module_dirs[@]}"; do
        [[ -d "$d" ]] && { found_modules=true; break; }
    done
    $found_modules || missing+=("grub-i386-efi-modules")

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Missing: ${missing[*]}"
        info "Attempting automatic installation…"
        install_deps
        # re-check after install
        for cmd in grub-mkimage xorriso mformat; do
            command -v "$cmd" &>/dev/null || die "'$cmd' still not found after install attempt."
        done
        found_modules=false
        for d in "${module_dirs[@]}"; do
            [[ -d "$d" ]] && { found_modules=true; break; }
        done
        $found_modules || die "grub i386-efi modules not found. Install grub-efi-ia32-bin (Debian) or grub (Arch)."
    fi

    success "All dependencies are present."
}

# ── Find grub i386-efi module directory ─────────────────────────────────────
find_grub_modules() {
    local dirs=(
        /usr/lib/grub/i386-efi
        /usr/share/grub/i386-efi
        /usr/lib/grub2/i386-efi
        /usr/lib64/grub/i386-efi
    )
    for d in "${dirs[@]}"; do
        [[ -d "$d" ]] && { echo "$d"; return; }
    done
    die "Cannot locate grub i386-efi module directory."
}

# ── Build bootia32.efi ───────────────────────────────────────────────────────
build_bootia32() {
    local workdir="$1"
    local module_dir
    module_dir=$(find_grub_modules)
    info "Using grub modules from: ${module_dir}"

    local grub_cfg="${workdir}/grub-early.cfg"
    cat > "$grub_cfg" <<'GRUBCFG'
search --no-floppy --file --set=root /boot/grub/grub.cfg
set prefix=($root)/boot/grub
source ($root)/boot/grub/grub.cfg
GRUBCFG

    # Only pass modules that are actually present — the set varies across distros
    local wanted=(
        all_video boot btrfs cat chain configfile echo
        efifwsetup efinet ext2 fat font gettext
        gfxmenu gfxterm gfxterm_background gzip halt help
        hfsplus iso9660 jpeg keystatus linux linuxefi
        lsefi lsefimmap lzma lzopio mdraid09 memdisk
        minicmd normal ntfs part_apple part_gpt part_msdos
        password_pbkdf2 png reboot regexp search
        search_fs_file search_fs_uuid search_label serial
        sleep squash4 tpm video xfs zstd
    )
    local modules=()
    for m in "${wanted[@]}"; do
        [[ -f "${module_dir}/${m}.mod" ]] && modules+=("$m")
    done
    info "Embedding ${#modules[@]} modules"

    info "Building bootia32.efi with grub-mkimage…"
    grub-mkimage \
        --directory "$module_dir" \
        --prefix    "/boot/grub" \
        --output    "${workdir}/bootia32.efi" \
        --format    i386-efi \
        --config    "$grub_cfg" \
        "${modules[@]}"

    [[ -f "${workdir}/bootia32.efi" ]] || die "grub-mkimage failed to produce bootia32.efi"
    success "bootia32.efi built ($(du -sh "${workdir}/bootia32.efi" | cut -f1))."
}

# ── Probe EFI image path inside the ISO ─────────────────────────────────────
find_efi_path() {
    local iso="$1"
    # Look for an existing 64-bit EFI entry to mirror the path
    local path
    path=$(xorriso -osirrox on -indev "$iso" -find / -name 'bootx64.efi' 2>/dev/null | head -1 || true)
    if [[ -n "$path" ]]; then
        dirname "$path"
    else
        # Fallback: standard EFI path
        echo "/EFI/BOOT"
    fi
}

# ── Inject bootia32.efi into the ISO ────────────────────────────────────────
patch_iso() {
    local input_iso="$1"
    local output_iso="$2"
    local workdir="$3"

    local efi_dir
    efi_dir=$(find_efi_path "$input_iso")
    info "EFI directory inside ISO: ${efi_dir}"

    # Check if bootia32.efi already exists
    if xorriso -osirrox on -indev "$input_iso" -find / -name 'bootia32.efi' 2>/dev/null | grep -q .; then
        warn "bootia32.efi already exists in the ISO. It will be replaced."
    fi

    info "Injecting bootia32.efi into the ISO…"
    xorriso \
        -indev  "$input_iso" \
        -outdev "$output_iso" \
        -map    "${workdir}/bootia32.efi" "${efi_dir}/bootia32.efi" \
        -boot_image any replay \
        2>&1 | grep -v '^xorriso : UPDATE' || true

    [[ -f "$output_iso" ]] || die "xorriso failed to produce output ISO."
    success "Patched ISO written to: ${output_iso}"
    info "Size: $(du -sh "$output_iso" | cut -f1)"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}━━━ uefi32-iso-patcher ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "    Add bootia32.efi to any Linux ISO for 32-bit UEFI (Bay Trail tablets)"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo

    [[ $# -eq 0 ]] && usage
    [[ "$1" == "-h" || "$1" == "--help" ]] && usage

    local input_iso="$1"
    local output_iso="${2:-}"

    # Validate input
    [[ -f "$input_iso" ]] || die "File not found: ${input_iso}"
    file "$input_iso" | grep -qi "ISO 9660" || warn "File may not be a valid ISO 9660 image."

    # Default output name
    if [[ -z "$output_iso" ]]; then
        local base="${input_iso%.iso}"
        output_iso="${base}-uefi32.iso"
    fi

    [[ "$input_iso" == "$output_iso" ]] && die "Input and output paths must differ."

    info "Input:  ${input_iso}"
    info "Output: ${output_iso}"
    echo

    # Step 1 — dependencies
    check_deps
    echo

    # Step 2 — working directory
    WORKDIR=$(mktemp -d /tmp/uefi32-patcher.XXXXXX)
    trap '[[ -n "$WORKDIR" ]] && rm -rf "$WORKDIR"' EXIT
    info "Temp workdir: ${WORKDIR}"
    echo

    # Step 3 — build EFI binary
    build_bootia32 "$WORKDIR"
    echo

    # Step 4 — patch ISO
    patch_iso "$input_iso" "$output_iso" "$WORKDIR"
    echo

    echo -e "${BOLD}${GREEN}Done!${NC} You can now write the patched ISO to a USB drive:"
    echo -e "  dd if=${output_iso} of=/dev/sdX bs=4M status=progress oflag=sync"
    echo -e "  (replace /dev/sdX with your actual USB device)"
    echo
}

main "$@"
