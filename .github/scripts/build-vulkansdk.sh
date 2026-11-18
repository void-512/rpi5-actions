#!/usr/bin/env bash
set -euo pipefail

work="$(mktemp -d)"
cd "$work"

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg jq git file xz-utils tar findutils \
  cmake ninja-build make pkg-config patchelf binutils \
  python3 python3-pip python3-setuptools python3-wheel python3-venv libpython3-all-dev python3-jsonschema python-is-python3 \
  bison ocaml-core \
  libglm-dev libpng-dev libpciaccess-dev \
  libxcb-dri3-dev libxcb-present-dev libxcb-keysyms1-dev \
  libxcb-randr0-dev libxcb-ewmh-dev \
  libx11-dev libx11-xcb-dev libxrandr-dev \
  libwayland-dev wayland-protocols liblz4-dev libzstd-dev libxml2-dev \
  libssl-dev zlib1g-dev libdrm-dev \
  libxkbcommon-dev libxext-dev libxfixes-dev \
  qtbase5-dev qt6-base-dev qt6-wayland-dev

# LLVM 23 for Debian Trixie, from the upstream LLVM project.
curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key \
  | gpg --dearmor -o /usr/share/keyrings/apt-llvm.gpg
echo 'deb [signed-by=/usr/share/keyrings/apt-llvm.gpg] https://apt.llvm.org/trixie/ llvm-toolchain-trixie-23 main' \
  > /etc/apt/sources.list.d/llvm23.list
apt-get update
apt-get install -y --no-install-recommends \
  clang-23 clang-tools-23 lld-23 llvm-23 llvm-23-dev \
  libclang-rt-23-dev libc++-23-dev libc++abi-23-dev \
  libunwind-23-dev
apt-get clean
rm -rf /var/lib/apt/lists/*
export CC=clang-23 CXX=clang++-23 LD=ld.lld-23 AR=llvm-ar-23 RANLIB=llvm-ranlib-23
export NM=llvm-nm-23 STRIP=llvm-strip-23 OBJCOPY=llvm-objcopy-23
export CMAKE_GENERATOR=Ninja

sdk_version="${REQUESTED_SDK_VERSION:-}"
if [[ -z "$sdk_version" ]]; then
  sdk_version="$(curl -fsSL https://vulkan.lunarg.com/sdk/latest/linux.txt | tr -d '\r\n')"
fi
[[ "$sdk_version" =~ ^[0-9]+(\.[0-9]+)+$ ]]
mimalloc_tag="$(curl -fsSL https://api.github.com/repos/microsoft/mimalloc/releases/latest \
  | jq -r '.tag_name')"
[[ "$mimalloc_tag" =~ ^v3\.[0-9]+\.[0-9]+$ ]]

git clone --depth 1 --branch "$mimalloc_tag" \
  https://github.com/microsoft/mimalloc.git mimalloc-src
cmake -S mimalloc-src -B mimalloc-build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/opt/mimalloc \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
  -DMI_BUILD_SHARED=OFF \
  -DMI_BUILD_STATIC=ON \
  -DMI_BUILD_OBJECT=ON \
  -DMI_BUILD_TESTS=OFF \
  -DMI_OVERRIDE=ON \
  -DMI_OPT_ARCH=OFF
cmake --build mimalloc-build --parallel "$CMAKE_BUILD_PARALLEL_LEVEL"
cmake --install mimalloc-build
mkdir -p /opt/mimalloc/lib
mi_object="$(find mimalloc-build -type f -name mimalloc.o -print -quit)"
test -n "$mi_object"
cp "$mi_object" /opt/mimalloc/lib/mimalloc.o
rm -rf mimalloc-src mimalloc-build

mkdir -p /opt/llvm-wrappers
cat > /opt/llvm-wrappers/clang <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

compiler="${0##*/}"
for arg in "$@"; do
  case "$arg" in
    -c|-S|-E|-shared|-r|-fsyntax-only|-M|-MM|-###|--version|--help|-print-*|-dump*)
      exec "/usr/bin/$compiler-23" "$@"
      ;;
  esac
done

# Link executables with the mimalloc override and static C++ runtimes.
runtimes=()
if [[ "$compiler" == clang++ ]]; then
  runtimes=(-nostdlib++ -Wl,-Bstatic -lc++ -lc++abi -lunwind -Wl,-Bdynamic)
fi
exec "/usr/bin/$compiler-23" /opt/mimalloc/lib/mimalloc.o "$@" "${runtimes[@]}"
WRAPPER
chmod +x /opt/llvm-wrappers/clang
install -m 0755 /opt/llvm-wrappers/clang /opt/llvm-wrappers/clang++

cat > /opt/llvm-wrappers/rpi5-static.cmake <<'CMAKE'
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Prefer static dependencies" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON CACHE BOOL "PIC in static archives" FORCE)
CMAKE
export CC=/opt/llvm-wrappers/clang CXX=/opt/llvm-wrappers/clang++
export CMAKE_TOOLCHAIN_FILE=/opt/llvm-wrappers/rpi5-static.cmake

mkdir vulkan
# The Linux SDK bundles prebuilt x86_64 files alongside the source recipe.
curl --retry 5 --fail --silent --show-error --location \
  "https://sdk.lunarg.com/sdk/download/${sdk_version}/linux/vulkan_sdk.tar.xz" \
  | tar -xJ --exclude='*/x86_64' -C vulkan
cd "vulkan/$sdk_version"

# The default build includes the headless SDK components.
if [[ "${FULL_SDK:-false}" == true ]]; then
  ./vulkansdk --skip-deps -j "$CMAKE_BUILD_PARALLEL_LEVEL" all
else
  ./vulkansdk --skip-deps -j "$CMAKE_BUILD_PARALLEL_LEVEL" \
    vulkan-loader vulkan-validationlayers vulkan-extensionlayer \
    vulkan-tools shaderc glslang spirv-tools spirv-cross \
    spirv-reflect vulkan-profiles volk vma vul
fi

release="vulkan-sdk-${sdk_version}-aarch64-linux-debian13-llvm23-cortex-a76"
out="$work/$release"
mv aarch64 "$out"
cd "$work"
rm -rf vulkan
mkdir -p "$out"/{bin,include,lib,share}

# Keep LLVM runtime DSOs for components that must remain shared.
# libc (glibc) and Mesa/V3DV intentionally come from the host OS.
for soname in libc++.so.1 libc++abi.so.1 libunwind.so.1; do
  runtime="$(ldconfig -p | awk -v name="$soname" '$1 == name && !found {print $NF; found=1}')"
  if [[ -n "$runtime" && -f "$runtime" ]]; then
    cp -L "$runtime" "$out/lib/$soname"
  fi
done

# The upstream SDK may itself contain environment helper scripts.
# Do not distribute any: users configure their environment manually.
find "$out" -type f \( -name 'setup-env.sh' -o -name 'setup_env.sh' \) -delete

# Relative RUNPATH for executables, so no SDK-wide LD_LIBRARY_PATH is
# required for normal binaries. Preserve system Vulkan ICD discovery.
while IFS= read -r -d '' f; do
  if file "$f" | grep -Eq 'ELF.*(executable|pie executable)'; then
    patchelf --set-rpath "\$ORIGIN/../lib:\$ORIGIN/../lib64:\$ORIGIN/../lib/VulkanLoader/lib" "$f"
  fi
done < <(find "$out/bin" -type f -print0)

# Shared SDK objects need to locate co-packaged dependencies too.
while IFS= read -r -d '' f; do
  if file "$f" | grep -q 'ELF.*shared object'; then
    patchelf --set-rpath "\$ORIGIN:\$ORIGIN/..:\$ORIGIN/../VulkanLoader/lib" "$f"
  fi
done < <(find "$out/lib" -type f -print0)

printf 'Vulkan SDK: %s\nLLVM: 23\nCPU: Cortex-A76\nOS: Debian 13 aarch64\nmimalloc: %s\n' \
  "$sdk_version" "$mimalloc_tag" > "$out/BUILD-INFO.txt"
tar -C "$work" -cJf "$BUILD_ROOT/artifacts/$release.tar.xz" "$release"
