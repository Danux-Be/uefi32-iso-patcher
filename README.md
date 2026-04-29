# uefi32-iso-patcher

Patch any Linux ISO to make it bootable on **32-bit UEFI** machines — Intel Atom Bay Trail tablets (Z3735F, Z3736F, Z3740, …) and other devices that ship with a 32-bit UEFI firmware despite having a 64-bit CPU.

---

## The problem

Dozens of cheap Windows tablets manufactured between 2013 and 2016 (Asus T100, Dell Venue 8 Pro, HP Stream 7/8, Teclast X98 Pro, Chuwi Hi8, …) use an **Intel Atom Bay Trail** SoC.  
These CPUs are 64-bit (x86_64), but their UEFI firmware is **32-bit only** — a cost-cutting decision by the manufacturers.

Standard Linux ISO images only ship with `bootx64.efi` (64-bit UEFI bootloader). The tablet firmware cannot execute it, so the USB drive simply never appears in the boot menu.

The fix is to add `bootia32.efi` — a 32-bit GRUB EFI binary — alongside the existing 64-bit one.

---

## What this script does

1. **Checks / installs** required tools (`grub-mkimage`, `xorriso`, `mtools`)
2. **Compiles** `bootia32.efi` using `grub-mkimage` with the `i386-efi` target and a wide set of modules
3. **Injects** the binary into the ISO's `EFI/BOOT/` directory using `xorriso`, preserving all existing boot entries
4. Outputs a new patched ISO ready to be written to USB

---

## Requirements

| Tool | Purpose |
|------|---------|
| `grub-mkimage` + i386-efi modules | Build the 32-bit EFI binary |
| `xorriso` | Read/write the ISO without re-extracting it |
| `mtools` | Manipulate the FAT EFI System Partition inside the ISO |

The script will **auto-install** these on Arch/CachyOS, Debian/Ubuntu, and Fedora if they are missing.

---

## Installation

```bash
git clone https://github.com/Danux-Be/uefi32-iso-patcher.git
cd uefi32-iso-patcher
chmod +x uefi32-iso-patcher.sh
```

---

## Usage

```bash
# Basic — output will be <input>-uefi32.iso
./uefi32-iso-patcher.sh ubuntu-24.04-desktop-amd64.iso

# Specify output path
./uefi32-iso-patcher.sh archlinux-2024.01.01-x86_64.iso patched.iso
```

### Write to USB

```bash
# Replace /dev/sdX with your actual USB device (check with lsblk)
sudo dd if=ubuntu-24.04-desktop-amd64-uefi32.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

---

## Tested ISOs

| Distribution | Status |
|-------------|--------|
| Ubuntu 22.04 / 24.04 | ✅ |
| Debian 12 | ✅ |
| Arch Linux | ✅ |
| CachyOS | ✅ |
| Fedora 40 | ✅ |
| Linux Mint 21 | ✅ |
| Manjaro | ✅ |

---

## Tested devices

| Device | SoC | Notes |
|--------|-----|-------|
| Asus T100TA / T100CHI | Z3740 / Z3775 | Needs 32-bit UEFI shim |
| Dell Venue 8 Pro | Z3740D | |
| HP Stream 7 / 8 | Z3735G / Z3745 | |
| Teclast X98 Pro | Z3736F | Dual-boot with Android |
| Chuwi Hi8 / Vi8 | Z3735F | |
| Linx 7 / 8 | Z3735G | |
| Generic Bay Trail tablets | Z3735F/G/E | Most 7–10" Windows tablets |

---

## How it works

### Why 32-bit UEFI on a 64-bit CPU?

Intel Atom Bay Trail CPUs fully support 64-bit mode, but many tablet OEMs saved money by licensing a 32-bit UEFI implementation. The firmware initializes the CPU in 32-bit protected mode and only loads EFI applications compiled for `IA32` (`i386-efi` in GRUB terminology).

### The EFI boot process

When the firmware scans removable media it looks for:
- `\EFI\BOOT\BOOTIA32.EFI` — 32-bit UEFI (our addition)
- `\EFI\BOOT\BOOTX64.EFI` — 64-bit UEFI (already present in most ISOs)

By adding `BOOTIA32.EFI`, the tablet's firmware finds a compatible bootloader and the USB drive appears in the boot menu. GRUB then loads the normal 64-bit Linux kernel — the 32-bit limitation only applies to the **firmware**, not the OS.

### grub-mkimage modules

The script builds `bootia32.efi` with an extensive set of modules embedded (filesystem drivers, video, partition tables, etc.) so that it works without an external module directory — useful since the tablet firmware can only load one EFI binary.

---

## Troubleshooting

**The USB drive still doesn't appear in the boot menu**  
→ Some tablets also require Secure Boot to be disabled in the UEFI setup (usually accessible via the Volume Down key at power-on).

**GRUB loads but can't find the kernel**  
→ The embedded `grub-early.cfg` searches for `/boot/grub/grub.cfg`. If the ISO uses a non-standard path (e.g. `/boot/grub2/`), rebuild with a custom config by editing the `build_bootia32()` function.

**xorriso: cannot find boot image**  
→ The ISO may use an unusual structure. Open an issue with the ISO name/URL.

---

## License

[MIT](LICENSE)
