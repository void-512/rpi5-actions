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

python3 - "$build_dir/.config" "$recipe_dir/rpi5.config" "$recipe_dir/expected.config" <<'PY'
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
errors = []
for path in sys.argv[2:]:
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
PY

"${kbuild[@]}" -j6 Image modules dtbs
release=$("${kbuild[@]}" -s kernelrelease)
name="rpi5-kernel-$release"
package="$TMPDIR/package/$name"
archive="$dist_dir/$name.tar.zst"

mkdir -p "$package/boot/overlays"
"${kbuild[@]}" -j6 modules_install "INSTALL_MOD_PATH=$package" INSTALL_MOD_STRIP=1 DEPMOD=true
rm -f -- "$package/lib/modules/$release/build"
printf '%s\n' "$release" > "$package/kernel.release"
cp -- "$recipe_dir/Makefile" "$recipe_dir/INSTALL.md" "$build_dir/System.map" "$build_dir/.config" "$package/"
cp -- "$build_dir/arch/arm64/boot/Image" "$package/boot/kernel_2712.img"
cp -- "$build_dir"/arch/arm64/boot/dts/broadcom/bcm2712*.dtb "$package/boot/"
cp -- "$build_dir"/arch/arm64/boot/dts/overlays/*.dtbo "$source_dir/arch/arm/boot/dts/overlays/README" \
  "$package/boot/overlays/"
{
  printf '\n## Build information\n\n'
  printf 'Kernel release: %s\n\n' "$release"
  printf 'Source: raspberrypi/linux at %s (%s)\n\n' "$(git -C "$source_dir" rev-parse HEAD)" "$KERNEL_BRANCH"
  printf 'Toolchain: %s / %s\n' "${clang_version%%$'\n'*}" "${lld_version%%$'\n'*}"
} >> "$package/INSTALL.md"

tar -C "$(dirname -- "$package")" -I 'zstd -T2 -10' -cf "$archive" "$name"
verify="$TMPDIR/verify"
mkdir -p "$verify"
tar --zstd -xf "$archive" -C "$verify"
make -C "$verify/$name" modules_install "INSTALL_MOD_PATH=$verify/root"
test -s "$verify/root/lib/modules/$release/modules.dep"
test -s "$verify/$name/boot/kernel_2712.img"
test -s "$verify/$name/boot/bcm2712-rpi-5-b.dtb"

printf 'archive=%s\n' "$archive" >> "$GITHUB_OUTPUT"
