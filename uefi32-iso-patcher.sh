#!/usr/bin/env bash
# uefi32-iso-patcher.sh — Inject bootia32.efi into a Linux ISO for 32-bit UEFI boot
# Target: Intel Atom Bay Trail (Z3735F and similar) tablets with 32-bit UEFI firmware

set -euo pipefail

# Global so the EXIT trap can always access it
WORKDIR=""

# Possible locations of the grub i386-efi modules, depending on the distro
GRUB_MODULE_DIRS=(
    /usr/lib/grub/i386-efi
    /usr/share/grub/i386-efi
    /usr/lib/grub2/i386-efi
    /usr/lib64/grub/i386-efi
)

# Candidate GRUB configs inside the ISO, in order of preference
GRUB_CFG_CANDIDATES=(
    /boot/grub/grub.cfg
    /EFI/BOOT/grub.cfg
    /boot/grub2/grub.cfg
)

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
# grub-mkimage is called grub2-mkimage on Fedora
find_grub_mkimage() {
    local cmd
    for cmd in grub-mkimage grub2-mkimage; do
        command -v "$cmd" &>/dev/null && { echo "$cmd"; return; }
    done
    return 0
}

find_grub_modules() {
    local d
    for d in "${GRUB_MODULE_DIRS[@]}"; do
        [[ -d "$d" ]] && { echo "$d"; return; }
    done
    return 0
}

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

    # grub-mkimage alone is not enough: the i386-efi modules are often a separate package
    local need_grub=false
    [[ -n "$(find_grub_mkimage)" && -n "$(find_grub_modules)" ]] || need_grub=true

    local pkgs=()
    case "$distro" in
        arch)
            $need_grub                     && pkgs+=(grub)
            command -v xorriso &>/dev/null || pkgs+=(xorriso)
            command -v mformat &>/dev/null || pkgs+=(mtools)
            if [[ ${#pkgs[@]} -gt 0 ]]; then
                info "Installing: ${pkgs[*]}"
                sudo pacman -S --needed --noconfirm "${pkgs[@]}"
            fi
            ;;
        debian)
            $need_grub                     && pkgs+=(grub-efi-ia32-bin)
            command -v xorriso &>/dev/null || pkgs+=(xorriso)
            command -v mformat &>/dev/null || pkgs+=(mtools)
            if [[ ${#pkgs[@]} -gt 0 ]]; then
                info "Installing: ${pkgs[*]}"
                sudo apt-get update -qq
                sudo apt-get install -y "${pkgs[@]}"
            fi
            ;;
        fedora)
            $need_grub                     && pkgs+=(grub2-tools grub2-efi-ia32-modules)
            command -v xorriso &>/dev/null || pkgs+=(xorriso)
            command -v mformat &>/dev/null || pkgs+=(mtools)
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

# Prints the missing dependencies, one per line
missing_deps() {
    [[ -n "$(find_grub_mkimage)" ]] || echo "grub-mkimage"
    [[ -n "$(find_grub_modules)" ]] || echo "grub-i386-efi-modules"
    command -v xorriso &>/dev/null  || echo "xorriso"
    command -v mformat &>/dev/null  || echo "mformat (mtools)"
}

check_deps() {
    info "Checking dependencies…"
    local missing
    missing=$(missing_deps)

    if [[ -n "$missing" ]]; then
        warn "Missing: $(echo $missing)"
        info "Attempting automatic installation…"
        install_deps
        missing=$(missing_deps)
        [[ -z "$missing" ]] || die "Still missing after install attempt: $(echo $missing). Install grub-efi-ia32-bin (Debian), grub (Arch) or grub2-efi-ia32-modules (Fedora)."
    fi

    success "All dependencies are present."
}

# ── Probe the ISO contents ───────────────────────────────────────────────────
# Turn a name or path into a case-insensitive xorriso -find pattern
ci_pattern() {
    local s="$1" pattern="" c i
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        if [[ "$c" == [[:alpha:]] ]]; then
            pattern+="[${c,}${c^}]"
        else
            pattern+="$c"
        fi
    done
    echo "$pattern"
}

# Find a file in the ISO (case-insensitive) and print its unquoted path.
# Usage: iso_find <iso> -name|-wholename <name or path>
# xorriso -find prints shell-quoted paths ('/EFI/boot/x' with ' as '"'"'), so unquote them.
iso_find() {
    local iso="$1" test="$2" name="$3"
    local path
    path=$(xorriso -osirrox on -indev "$iso" -find / "$test" "$(ci_pattern "$name")" 2>/dev/null | head -1 || true)
    [[ -n "$path" ]] || return 0
    path="${path#\'}"
    path="${path%\'}"
    echo "${path//\'\"\'\"\'/\'}"
}

find_efi_path() {
    local iso="$1"
    # Look for an existing 64-bit EFI entry to mirror the path
    local path
    path=$(iso_find "$iso" -name 'bootx64.efi')
    if [[ -n "$path" ]]; then
        dirname "$path"
    else
        # Fallback: standard EFI path
        echo "/EFI/BOOT"
    fi
}

# Print the path of the GRUB config to chain-load (empty if none found)
find_grub_cfg() {
    local iso="$1" cfg path
    for cfg in "${GRUB_CFG_CANDIDATES[@]}"; do
        path=$(iso_find "$iso" -wholename "$cfg")
        [[ -n "$path" ]] && { echo "$path"; return; }
    done
    return 0
}

# Escape a string for use inside double quotes in a grub script
grub_quote() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//\$/\\\$}"
    echo "\"$s\""
}

# ── Build bootia32.efi ───────────────────────────────────────────────────────
# Usage: build_bootia32 <workdir> <grub.cfg path in ISO> <marker path in ISO>
build_bootia32() {
    local workdir="$1"
    local iso_cfg="$2"
    local marker="$3"
    local module_dir mkimage
    module_dir=$(find_grub_modules)
    mkimage=$(find_grub_mkimage)
    [[ -n "$module_dir" ]] || die "Cannot locate grub i386-efi module directory."
    info "Using grub modules from: ${module_dir}"

    # Locate the ISO by a marker file unique to this patched image, so we never pick up
    # a grub.cfg from another disk (e.g. a Linux already installed on the internal eMMC).
    # Fall back to searching for the config itself if the marker got lost (file-copy tools).
    # No explicit source: once this script ends, GRUB's normal mode loads $prefix/grub.cfg
    # by itself (sourcing it here too would show every menu entry twice).
    local grub_cfg="${workdir}/grub-early.cfg"
    cat > "$grub_cfg" <<GRUBCFG
set root=
search --no-floppy --file --set=root $(grub_quote "$marker")
if [ -z "\$root" ]; then
    search --no-floppy --file --set=root $(grub_quote "$iso_cfg")
fi
set prefix=(\$root)$(grub_quote "$(dirname "$iso_cfg")")
GRUBCFG

    # Only pass modules that are actually present — the set varies across distros.
    # Everything grub.cfg may need must be embedded: there is no i386-efi module
    # directory on the ISO, so any insmod of a missing module fails.
    local wanted=(
        all_video boot btrfs cat chain configfile cpuid echo
        efifwsetup efinet eval ext2 fat font gettext
        gfxmenu gfxterm gfxterm_background gfxterm_menu gzip halt help
        hfsplus iso9660 jpeg keystatus linux linuxefi loadenv loopback ls
        lsefi lsefimmap lzma lzopio mdraid09 memdisk
        minicmd normal ntfs part_apple part_gpt part_msdos
        password_pbkdf2 play png probe reboot regexp search
        search_fs_file search_fs_uuid search_label serial
        sleep smbios squash4 test tpm tr true udf video xfs zstd
    )
    local modules=() m
    for m in "${wanted[@]}"; do
        [[ -f "${module_dir}/${m}.mod" ]] && modules+=("$m")
    done
    info "Embedding ${#modules[@]} modules"

    info "Building bootia32.efi with ${mkimage}…"
    "$mkimage" \
        --directory "$module_dir" \
        --prefix    "$(dirname "$iso_cfg")" \
        --output    "${workdir}/bootia32.efi" \
        --format    i386-efi \
        --config    "$grub_cfg" \
        "${modules[@]}"

    [[ -f "${workdir}/bootia32.efi" ]] || die "grub-mkimage failed to produce bootia32.efi"
    success "bootia32.efi built ($(du -sh "${workdir}/bootia32.efi" | cut -f1))."
}

# ── Patch the EFI System Partition image ────────────────────────────────────
# When the ISO is written with dd, the firmware only reads the FAT EFI System
# Partition (the El Torito EFI image), never the ISO 9660 tree. bootia32.efi
# must therefore also be added inside that image.

# Locate the El Torito EFI boot image. Prints one of:
#   tree <path in ISO>                              (e.g. Debian: /boot/grub/efi.img)
#   appended <partition> <type> <start> <end>       (e.g. Ubuntu; 512-byte blocks)
# Prints nothing if the ISO has no EFI boot image.
find_efi_boot_image() {
    local iso="$1" report e
    report=$(xorriso -indev "$iso" -report_el_torito as_mkisofs 2>/dev/null || true)
    e=$(grep -m1 "^-e '" <<<"$report" || true)
    [[ -n "$e" ]] || return 0
    e="${e#-e \'}"
    e="${e%\'}"

    if [[ "$e" =~ ^--interval:appended_partition_([0-9]+)_ ]]; then
        local part="${BASH_REMATCH[1]}" line
        line=$(grep -m1 "^-append_partition ${part} " <<<"$report" || true)
        [[ "$line" =~ ^-append_partition\ [0-9]+\ ([^ ]+)\ --interval:local_fs:([0-9]+)d-([0-9]+)d: ]] || return 0
        echo "appended ${part} ${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"
    elif [[ "$e" == /* ]]; then
        echo "tree ${e}"
    fi
}

# Extract the EFI boot image described by find_efi_boot_image into <dest>
extract_efi_boot_image() {
    local iso="$1" dest="$2" kind="$3"
    shift 3
    case "$kind" in
        tree)
            xorriso -osirrox on -indev "$iso" -extract "$1" "$dest" >/dev/null 2>&1
            chmod u+w "$dest"
            ;;
        appended)
            local start="$3" end="$4"
            dd if="$iso" of="$dest" bs=512 skip="$start" count=$(( end - start + 1 )) status=none
            ;;
    esac
}

# Rebuild a FAT ESP image with bootia32.efi added, growing it as needed.
# Usage: build_esp <old image> <new image> <bootia32.efi> <workdir>
build_esp() {
    local old="$1" new="$2" efi="$3" workdir="$4"
    local tree="${workdir}/esp-tree"

    mdir -i "$old" ::/ &>/dev/null || return 1
    rm -rf "$tree" && mkdir -p "$tree"
    mcopy -s -i "$old" ::/ "$tree/" || return 1

    # Mirror the case of the existing EFI/BOOT directory, if any
    local boot_dir=""
    local listing
    listing=$(mdir -/ -b -i "$old" ::/ 2>/dev/null || true)
    boot_dir=$(grep -im1 '/bootx64\.efi$' <<<"$listing" || true)
    if [[ -n "$boot_dir" ]]; then
        boot_dir="${boot_dir#::}"
        boot_dir="${boot_dir%/*}"
    else
        boot_dir="/EFI/BOOT"
    fi
    # Replace an existing bootia32.efi in place
    local target="${boot_dir}/bootia32.efi"
    local existing
    existing=$(grep -im1 '/bootia32\.efi$' <<<"$listing" || true)
    [[ -n "$existing" ]] && target="${existing#::}"
    mkdir -p "${tree}$(dirname "$target")"
    cp "$efi" "${tree}${target}"

    # Size: content + 1 MiB for FAT metadata and slack, in 512-byte sectors
    local bytes sectors
    bytes=$(du -sb --apparent-size "$tree" | cut -f1)
    sectors=$(( (bytes + 1024 * 1024) / 512 ))
    (( sectors % 2 )) && (( sectors++ ))

    # Keep the original volume label (some loaders search the ESP by label)
    local label label_args=()
    label=$(mlabel -s -i "$old" :: 2>/dev/null | sed -n 's/^ *Volume label is //p' || true)
    [[ -n "$label" ]] && label_args=(-v "$label")

    rm -f "$new"
    mformat -C -i "$new" -T "$sectors" "${label_args[@]}" :: || return 1
    local entries=()
    shopt -s dotglob nullglob
    entries=("$tree"/*)
    shopt -u dotglob nullglob
    mcopy -s -i "$new" "${entries[@]}" ::/ || return 1

    info "EFI System Partition: added ${target} ($(( sectors / 2 )) KiB image)"
}

# ── Inject bootia32.efi into the ISO ────────────────────────────────────────
# Usage: patch_iso <input> <output> <workdir> <efi dir in ISO> <marker path in ISO>
patch_iso() {
    local input_iso="$1"
    local output_iso="$2"
    local workdir="$3"
    local efi_dir="$4"
    local marker="$5"

    # Check if bootia32.efi already exists; if so, replace it in place
    local target="${efi_dir}/bootia32.efi"
    local existing
    existing=$(iso_find "$input_iso" -name 'bootia32.efi')
    if [[ -n "$existing" ]]; then
        warn "bootia32.efi already exists in the ISO (${existing}). It will be replaced."
        target="$existing"
    fi

    echo "uefi32-iso-patcher marker — used by bootia32.efi to find this image" > "${workdir}/marker"

    # Patch the EFI System Partition too (needed for dd-written USB drives)
    local esp_args=() esp_info
    esp_info=$(find_efi_boot_image "$input_iso")
    if [[ -z "$esp_info" ]]; then
        warn "No El Torito EFI boot image found: only the ISO 9660 tree is patched."
        warn "A dd-written USB drive may not boot; copy the ISO contents to a FAT32 drive instead."
    else
        local kind esp_spec
        read -r kind esp_spec <<<"$esp_info"
        info "EFI boot image: ${esp_info}"
        local -a spec
        read -ra spec <<<"$esp_spec"
        if extract_efi_boot_image "$input_iso" "${workdir}/esp-old.img" "$kind" "${spec[@]}" \
            && build_esp "${workdir}/esp-old.img" "${workdir}/esp-new.img" "${workdir}/bootia32.efi" "$workdir"; then
            case "$kind" in
                # Same path in the tree: -boot_image replay re-points El Torito and the
                # hybrid partition table to the new (bigger) file
                tree)     esp_args=(-map "${workdir}/esp-new.img" "${spec[0]}") ;;
                appended) esp_args=(-append_partition "${spec[0]}" "${spec[1]}" "${workdir}/esp-new.img") ;;
            esac
        else
            warn "Could not rebuild the EFI boot image: only the ISO 9660 tree is patched."
        fi
    fi

    # Never leave a stale output around: it would hide a failed run
    rm -f "$output_iso"

    info "Injecting bootia32.efi into the ISO…"
    local log="${workdir}/xorriso.log"
    if ! xorriso \
        -indev  "$input_iso" \
        -outdev "$output_iso" \
        -map    "${workdir}/bootia32.efi" "$target" \
        -map    "${workdir}/marker" "$marker" \
        -boot_image any replay \
        "${esp_args[@]}" \
        >"$log" 2>&1; then
        grep -v '^xorriso : UPDATE' "$log" >&2 || true
        rm -f "$output_iso"
        die "xorriso failed to produce the output ISO."
    fi
    grep -v '^xorriso : UPDATE' "$log" || true

    [[ -s "$output_iso" ]] || die "xorriso failed to produce output ISO."
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
    # ISO 9660 primary volume descriptor signature ("CD001" at offset 32769).
    # Must be fatal: xorriso silently starts from a blank image on non-ISO input.
    [[ "$(dd if="$input_iso" bs=1 skip=32769 count=5 2>/dev/null)" == "CD001" ]] \
        || die "Not an ISO 9660 image: ${input_iso}"

    # Default output name
    if [[ -z "$output_iso" ]]; then
        local base="${input_iso%.[iI][sS][oO]}"
        output_iso="${base}-uefi32.iso"
    fi

    [[ "$(realpath -m "$input_iso")" == "$(realpath -m "$output_iso")" ]] \
        && die "Input and output paths must differ."

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

    # Step 3 — probe the ISO
    local efi_dir iso_cfg marker
    efi_dir=$(find_efi_path "$input_iso")
    info "EFI directory inside ISO: ${efi_dir}"
    iso_cfg=$(find_grub_cfg "$input_iso")
    if [[ -n "$iso_cfg" ]]; then
        info "GRUB config inside ISO: ${iso_cfg}"
    else
        iso_cfg="${GRUB_CFG_CANDIDATES[0]}"
        warn "No GRUB config found in the ISO (looked for: ${GRUB_CFG_CANDIDATES[*]})."
        warn "bootia32.efi will try ${iso_cfg} but will most likely drop to a GRUB shell."
    fi
    marker="/.uefi32-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    echo

    # Step 4 — build EFI binary
    build_bootia32 "$WORKDIR" "$iso_cfg" "$marker"
    echo

    # Step 5 — patch ISO
    patch_iso "$input_iso" "$output_iso" "$WORKDIR" "$efi_dir" "$marker"
    echo

    echo -e "${BOLD}${GREEN}Done!${NC} You can now write the patched ISO to a USB drive:"
    echo -e "  dd if=${output_iso} of=/dev/sdX bs=4M status=progress oflag=sync"
    echo -e "  (replace /dev/sdX with your actual USB device)"
    echo
}

main "$@"
