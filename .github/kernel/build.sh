#!/usr/bin/env bash
set -euo pipefail

source_dir=$1
build_dir=$2
dist_dir=$3
recipe_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$build_dir" "$dist_dir"

clang_version=$(clang --version)
lld_version=$(ld.lld --version)
printf '%s\n%s\n' "$clang_version" "$lld_version"
[[ "$clang_version" == *"clang version 23."* && "$lld_version" == *"LLD 23."* ]]

local_version="-$(TZ=America/Toronto date +%Y%m%d)"
kbuild=(
  make --no-print-directory -C "$source_dir" "O=$build_dir"
  ARCH=arm64 LLVM=1 LLVM_IAS=1 LOCALVERSION=
  'LD=ld.lld --thinlto-jobs=6'
  'HOSTLDFLAGS=-fuse-ld=lld'
  'KCFLAGS=-mcpu=cortex-a76+nossbs+noras'
)

"${kbuild[@]}" bcm2712_defconfig
(
  cd "$TMPDIR"
  "$source_dir/scripts/kconfig/merge_config.sh" -m -Q -O "$build_dir" \
    "$build_dir/.config" "$recipe_dir/rpi5.config"
)
"$source_dir/scripts/config" --file "$build_dir/.config" --set-str LOCALVERSION "$local_version" \
  --disable LOCALVERSION_AUTO
"${kbuild[@]}" olddefconfig

python3 - "$build_dir/.config" "$source_dir" "$recipe_dir/rpi5.config" "$recipe_dir/expected.config" <<'PY'
import re
import sys
from pathlib import Path


def config_values(path):
    values = {}
    for line in Path(path).read_text().splitlines():
        if line.startswith("CONFIG_"):
            symbol, value = line.split("=", 1)
            values[symbol] = value
        elif match := re.fullmatch(r"# (CONFIG_\w+) is not set", line):
            values[match[1]] = "n"
    return values


actual = config_values(sys.argv[1])
memory_source = Path(sys.argv[2]) / "mm"
shmem_source = (memory_source / "shmem.c").read_text()
# Some branches define these defaults directly in mm/shmem.c.
for kind in ("shmem", "tmpfs"):
    symbol = f"CONFIG_TRANSPARENT_HUGEPAGE_{kind.upper()}_HUGE_NEVER"
    if symbol not in actual and re.search(
        rf"\bstatic int {kind}_huge __read_mostly = SHMEM_HUGE_NEVER;", shmem_source
    ):
        actual[symbol] = "y"

errors = []
for path in sys.argv[3:]:
    for symbol, expected in config_values(path).items():
        value = actual.get(symbol, "n")
        if value != expected:
            errors.append(f"{symbol}: expected {expected}, got {value}")
for symbol in ("CONFIG_CLANG_VERSION", "CONFIG_LLD_VERSION"):
    value = actual.get(symbol, "missing")
    if not re.fullmatch(r"23\d{4}", value):
        errors.append(f"{symbol}: expected LLVM 23, got {value}")
if errors:
    sys.exit("The selected branch did not resolve the Raspberry Pi 5 profile:\n" + "\n".join(dict.fromkeys(errors)))
print("Verified the Raspberry Pi 5 Kconfig profile.")

# The defrag sysfs policy has a separate compiled default from THP eligibility.
huge_memory_path = memory_source / "huge_memory.c"
huge_memory = huge_memory_path.read_text()
defaults = re.search(r"(?ms)^unsigned long transparent_hugepage_flags\b[^=]*=(.*?);", huge_memory)
madvise = "TRANSPARENT_HUGEPAGE_DEFRAG_REQ_MADV_FLAG"
defer = "TRANSPARENT_HUGEPAGE_DEFRAG_KSWAPD_FLAG"
if defaults is None:
    sys.exit("Unable to locate the THP defrag defaults in mm/huge_memory.c.")
flags = defaults[1]
if madvise in flags and defer not in flags:
    updated_flags = flags.replace(madvise, defer)
    huge_memory_path.write_text(huge_memory[:defaults.start(1)] + updated_flags + huge_memory[defaults.end(1):])
elif defer not in flags or madvise in flags:
    sys.exit("Unable to set the THP defrag default to defer in mm/huge_memory.c.")
print("Verified the kernel's default THP defrag policy is defer.")
PY

"${kbuild[@]}" -j6 Image modules dtbs
release=$("${kbuild[@]}" -s kernelrelease)
name="rpi5-kernel-$release"
package="$TMPDIR/package/$name"
archive="$dist_dir/$name.tar.gz"

mkdir -p "$package/boot/overlays"
"${kbuild[@]}" -j6 modules_install "INSTALL_MOD_PATH=$package" INSTALL_MOD_STRIP=1 DEPMOD=true
rm -f -- "$package/lib/modules/$release/build"
printf '%s\n' "$release" > "$package/kernel.release"
cp -- "$recipe_dir/Makefile" "$recipe_dir/INSTALL.md" "$build_dir/System.map" "$build_dir/.config" "$package/"
cp -- "$build_dir/arch/arm64/boot/Image" "$package/boot/kernel_2712.img"
cp -- "$build_dir"/arch/arm64/boot/dts/broadcom/bcm2712*.dtb "$package/boot/"
cp -- "$build_dir"/arch/arm64/boot/dts/overlays/*.dtb* "$source_dir/arch/arm/boot/dts/overlays/README" \
  "$package/boot/overlays/"
{
  printf '\n## Build information\n\n'
  printf 'Kernel release: %s\n\n' "$release"
  printf 'Source: raspberrypi/linux at %s (%s)\n\n' "$(git -C "$source_dir" rev-parse HEAD)" "$KERNEL_BRANCH"
  printf 'Toolchain: %s / %s\n' "${clang_version%%$'\n'*}" "${lld_version%%$'\n'*}"
} >> "$package/INSTALL.md"

tar -C "$(dirname -- "$package")" -czf "$archive" "$name"
verify="$TMPDIR/verify"
mkdir -p "$verify"
tar -xzf "$archive" -C "$verify"
make -C "$verify/$name" modules_install "INSTALL_MOD_PATH=$verify/root"
test -s "$verify/root/lib/modules/$release/modules.dep"
test -s "$verify/$name/boot/kernel_2712.img"
test -s "$verify/$name/boot/bcm2712-rpi-5-b.dtb"
test -s "$verify/$name/boot/overlays/overlay_map.dtb"

printf 'archive=%s\n' "$archive" >> "$GITHUB_OUTPUT"
