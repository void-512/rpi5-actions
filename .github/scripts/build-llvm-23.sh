#!/usr/bin/env bash
set -euo pipefail

requested_version="${REQUESTED_LLVM_VERSION:-}"
if [[ -n "$requested_version" && ! "$requested_version" =~ ^23\.[0-9]+\.[0-9]+$ ]]; then
  printf '%s\n' '::error::LLVM version must have the form 23.x.y, or be blank for the latest stable LLVM 23 release.' >&2
  exit 1
fi

work="$(mktemp -d)"
cd "$work"

apt_options=(-o APT::Keep-Downloaded-Packages=false
  -o Binary::apt::APT::Keep-Downloaded-Packages=false)
apt-get "${apt_options[@]}" update
apt-get "${apt_options[@]}" install -y --no-install-recommends \
  ca-certificates curl gnupg cmake ninja-build python3 xz-utils \
  libc6-dev libzstd-dev zlib1g-dev patchelf
mkdir -p /etc/apt/keyrings
curl --fail --silent --show-error --location --retry 5 \
  https://apt.llvm.org/llvm-snapshot.gpg.key \
  | gpg --dearmor -o /etc/apt/keyrings/llvm.gpg
printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/llvm.gpg] https://apt.llvm.org/trixie/ llvm-toolchain-trixie-23 main' \
  > /etc/apt/sources.list.d/llvm23.list
apt-get "${apt_options[@]}" update
apt-get "${apt_options[@]}" install -y --no-install-recommends \
  clang-23 lld-23 llvm-23 libclang-rt-23-dev \
  libc++-23-dev libc++abi-23-dev libunwind-23-dev
apt-get clean
rm -rf /var/lib/apt/lists/*
bootstrap_bin="$(dirname "$(readlink -f "$(command -v clang-23)")")"
export PATH="$bootstrap_bin:$PATH"
export CC=clang CXX=clang++ AR=llvm-ar RANLIB=llvm-ranlib
# libFuzzer's custom relocatable link does not forward CMake's linker flags.
# Default the ephemeral bootstrap drivers to LLD so they can read LTO archives.
for driver in clang clang++; do
  printf '%s\n' '-fuse-ld=lld' '--rtlib=compiler-rt' '--unwindlib=libunwind' \
    > "$bootstrap_bin/$driver.cfg"
done

# Resolve the requested stable LLVM 23 release, or the newest when left blank.
# The Git refs API returns the complete matching namespace, without pagination.
curl --fail --silent --show-error --location --retry 5 \
  https://api.github.com/repos/llvm/llvm-project/git/matching-refs/tags/llvmorg-23 \
  -o "$work/refs.json"
tag="$(python3 - "$work/refs.json" "$requested_version" <<'PY'
import json, re, sys
refs = json.load(open(sys.argv[1]))
tags = [r['ref'].removeprefix('refs/tags/') for r in refs]
stable = [t for t in tags if re.fullmatch(r'llvmorg-23\.\d+\.\d+', t)]
if not stable:
    sys.exit('No stable LLVM 23 release is published')
requested = sys.argv[2]
if requested:
    tag = f'llvmorg-{requested}'
    if tag not in stable:
        sys.exit(f'Requested LLVM 23 release is not published: {requested}')
else:
    tag = max(stable, key=lambda t: tuple(map(int, t.removeprefix('llvmorg-').split('.'))))
print(tag)
PY
)"
printf 'Building %s\n' "$tag"

# Stream only the projects used by this distribution into RAM. Avoid a second
# compressed source copy, Git history, test inputs and unrelated GPU projects.
mkdir source
curl --fail --silent --show-error --location --retry 5 \
  "https://github.com/llvm/llvm-project/archive/refs/tags/$tag.tar.gz" \
  | tar -xz -C source --strip-components=1 --wildcards \
      --exclude='*/test' --exclude='*/unittests' --exclude='*/benchmarks' \
      'llvm-project-*/cmake' 'llvm-project-*/llvm' \
      'llvm-project-*/clang' 'llvm-project-*/clang-tools-extra' \
      'llvm-project-*/lld' 'llvm-project-*/compiler-rt' \
      'llvm-project-*/libc' \
      'llvm-project-*/libcxx' 'llvm-project-*/libcxxabi' \
      'llvm-project-*/libunwind' 'llvm-project-*/runtimes' \
      'llvm-project-*/third-party' 'llvm-project-*/LICENSE.TXT'
release="llvm-${tag#llvmorg-}-debian13"
prefix="$work/$release"
mkdir -p "$prefix"

# The ELF loader expands the literal $ORIGIN in installed RUNPATH entries.
# shellcheck disable=SC2016
common=(-G Ninja -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DLLVM_ENABLE_PIC=ON
  "-DCMAKE_INSTALL_PREFIX=$prefix" -DCMAKE_INSTALL_LIBDIR=lib
  "-DCMAKE_C_COMPILER=$bootstrap_bin/clang"
  "-DCMAKE_CXX_COMPILER=$bootstrap_bin/clang++"
  "-DCMAKE_ASM_COMPILER=$bootstrap_bin/clang"
  -DCMAKE_C_COMPILER_TARGET=aarch64-unknown-linux-gnu
  -DCMAKE_CXX_COMPILER_TARGET=aarch64-unknown-linux-gnu
  -DCMAKE_ASM_COMPILER_TARGET=aarch64-unknown-linux-gnu
  "-DCMAKE_AR=$bootstrap_bin/llvm-ar"
  "-DCMAKE_RANLIB=$bootstrap_bin/llvm-ranlib"
  "-DCMAKE_STRIP=$bootstrap_bin/llvm-strip"
  # Preserve all requested flags while allowing LLVM's -Werror compile probes
  # to ignore the link-only options in that list.
  "-DCMAKE_C_FLAGS=--start-no-unused-arguments $CFLAGS --end-no-unused-arguments"
  "-DCMAKE_CXX_FLAGS=--start-no-unused-arguments $CXXFLAGS --end-no-unused-arguments"
  "-DCMAKE_EXE_LINKER_FLAGS=$LDFLAGS"
  "-DCMAKE_SHARED_LINKER_FLAGS=$LDFLAGS"
  "-DCMAKE_MODULE_LINKER_FLAGS=$LDFLAGS"
  '-DCMAKE_INSTALL_RPATH=$ORIGIN/../lib;$ORIGIN'
  -DLLVM_TARGETS_TO_BUILD=AArch64
  -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_DOCS=OFF)

# Install the runtime SDK first, then reclaim its build tree before compiling
# LLVM. Both phases use the requested flags and the same release sources.
cmake -S source/runtimes -B runtimes-build "${common[@]}" \
  '-DLLVM_ENABLE_RUNTIMES=compiler-rt;libunwind;libcxxabi;libcxx' \
  "-DCOMPILER_RT_INSTALL_PATH=$prefix/lib/clang/23" \
  -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
  -DCOMPILER_RT_BUILD_BUILTINS=ON -DCOMPILER_RT_BUILD_SANITIZERS=ON \
  -DCOMPILER_RT_BUILD_PROFILE=ON -DCOMPILER_RT_BUILD_LIBFUZZER=ON \
  -DCOMPILER_RT_BUILD_PROFILE_ROCM=OFF -DCOMPILER_RT_BUILD_XRAY=OFF \
  -DCOMPILER_RT_BUILD_MEMPROF=OFF -DCOMPILER_RT_INCLUDE_TESTS=OFF \
  -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON \
  -DLIBUNWIND_USE_COMPILER_RT=ON -DLIBUNWIND_INCLUDE_TESTS=OFF \
  -DLIBCXXABI_USE_COMPILER_RT=ON -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
  -DLIBCXXABI_INCLUDE_TESTS=OFF \
  -DLIBCXX_USE_COMPILER_RT=ON -DLIBCXX_INCLUDE_TESTS=OFF \
  -DLIBCXX_INCLUDE_BENCHMARKS=OFF
cmake --build runtimes-build --parallel 4
cmake --install runtimes-build
rm -rf runtimes-build
printf '%s\n' '::notice::Runtime SDK installed; building LLVM and Clang.'
df -h "$BUILD_ROOT"

components=(clang clang-resource-headers libclang libclang-headers clang-cpp clang-scan-deps
  clang-format clang-tidy clangd lld LLVM
  llc opt llvm-ar llvm-as llvm-dis llvm-bcanalyzer llvm-cov llvm-cxxfilt
  llvm-diff llvm-dwarfdump llvm-extract llvm-link llvm-lto llvm-lto2 llvm-mc
  llvm-nm llvm-objcopy llvm-objdump llvm-profdata llvm-readobj llvm-size
  llvm-strings llvm-symbolizer)
distribution="$(IFS=';'; printf '%s' "${components[*]}")"
cmake -S source/llvm -B llvm-build "${common[@]}" \
  '-DLLVM_ENABLE_PROJECTS=clang;clang-tools-extra;lld' \
  '-DLLVM_ENABLE_RUNTIMES=' '-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=' \
  "-DLLVM_DISTRIBUTION_COMPONENTS=$distribution" \
  -DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-unknown-linux-gnu \
  -DLLVM_ENABLE_LTO=Full -DLLVM_PARALLEL_LINK_JOBS=1 \
  -DLLVM_BUILD_LLVM_DYLIB=ON -DLLVM_LINK_LLVM_DYLIB=ON \
  -DCLANG_LINK_CLANG_DYLIB=ON -DLLVM_ENABLE_ASSERTIONS=OFF \
  -DLLVM_ENABLE_LIBCXX=ON \
  -DLLVM_ENABLE_BINDINGS=OFF -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_CURL=OFF \
  -DLLVM_ENABLE_ZLIB=ON -DLLVM_ENABLE_ZSTD=ON \
  -DCLANG_INCLUDE_TESTS=OFF -DCLANG_INCLUDE_DOCS=OFF \
  -DCLANG_ENABLE_HLSL=OFF -DCLANG_ENABLE_OBJC_REWRITER=OFF \
  -DCLANG_DEFAULT_CXX_STDLIB=libc++ -DCLANG_DEFAULT_RTLIB=compiler-rt \
  -DCLANG_DEFAULT_UNWINDLIB=libunwind -DCLANG_DEFAULT_LINKER=lld
cmake --build llvm-build --target distribution --parallel 4
# The distribution is fully linked. Reclaim completed objects and private
# archives before copying binaries into the installation. Invoke CMake's
# component installer directly so Ninja does not rebuild the deleted objects.
# The runtime SDK's distributable static archives are outside llvm-build.
find llvm-build -type f \( -name '*.o' -o -name '*.a' \) -delete
df -h "$BUILD_ROOT"
for component in "${components[@]}"; do
  cmake --install llvm-build --strip --component "$component"
done
mkdir -p "$prefix/share/licenses"
for project in llvm clang clang-tools-extra lld compiler-rt libc libcxx libcxxabi libunwind; do
  cp "source/$project/LICENSE.TXT" "$prefix/share/licenses/$project.txt"
done
rm -rf llvm-build source

# Some aliases are optional install components in upstream LLVM.
for pair in 'llvm-strip llvm-objcopy' 'llvm-ranlib llvm-ar' \
    'llvm-readelf llvm-readobj' 'llvm-addr2line llvm-symbolizer'; do
  read -r alias target <<< "$pair"
  ln -sf "$target" "$prefix/bin/$alias"
done

# Keep compression support relocatable. The C++ ABI and unwinder are the
# freshly built ones above; glibc and the ELF loader come from Debian.
for soname in libz.so.1 libzstd.so.1; do
  library="$(ldconfig -p | awk -v name="$soname" '$1 == name {path=$NF} END {print path}')"
  test -n "$library"
  cp -L "$library" "$prefix/lib/$soname"
done
for package in zlib1g libzstd1; do
  cp "/usr/share/doc/$package/copyright" "$prefix/share/licenses/$package.txt"
done
while IFS= read -r -d '' binary; do
  if patchelf --print-rpath "$binary" > /dev/null 2>&1; then
    relative="$(realpath --relative-to="$(dirname "$binary")" "$prefix/lib")"
    patchelf --set-rpath "\$ORIGIN/$relative:\$ORIGIN" "$binary"
  fi
done < <(find "$prefix/bin" "$prefix/lib" -type f -print0)
printf 'LLVM: %s\nOS: Debian Trixie arm64\nCPU: Cortex-A76\nTargets: AArch64\nCFLAGS=%s\nCXXFLAGS=%s\nLDFLAGS=%s\n' \
  "$tag" "$CFLAGS" "$CXXFLAGS" "$LDFLAGS" > "$prefix/BUILD-INFO.txt"

tar -C "$work" -cJf "$BUILD_ROOT/artifacts/$release.tar.xz" "$release"
