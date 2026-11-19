#!/usr/bin/env bash
set -euo pipefail

prefix="${REQUESTED_PREFIX:-/usr}"
if [[ "$prefix" != /* || "$prefix/" == */../* ]]; then
  printf '%s\n' '::error::The installation prefix must be an absolute path without parent directory components.' >&2
  exit 1
fi

source_dir=source
clone_options=(--depth 1)
case "$BUILD_LIBRARY" in
  pcre2)
    repository=https://github.com/PCRE2Project/pcre2.git
    archive_name=pcre2-jit
    clone_options+=(--recurse-submodules --shallow-submodules)
    cmake_options=(
      -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=ON
      -DPCRE2_BUILD_PCRE2_8=ON -DPCRE2_BUILD_PCRE2_16=ON -DPCRE2_BUILD_PCRE2_32=ON
      -DPCRE2_SUPPORT_JIT=ON -DPCRE2_BUILD_TESTS=ON
    )
    ;;
  zstd)
    repository=https://github.com/meta/zstd.git
    archive_name=zstd
    source_dir=source/build/cmake
    cmake_options=(
      -DZSTD_BUILD_SHARED=ON -DZSTD_BUILD_STATIC=ON
      -DZSTD_BUILD_PROGRAMS=ON -DZSTD_BUILD_TESTS=ON
    )
    ;;
  zlib-ng)
    repository=https://github.com/zlib-ng/zlib-ng.git
    archive_name=zlib-ng-compat
    # The upstream default builds both library types.
    cmake_options=(-DZLIB_COMPAT=ON -DBUILD_TESTING=ON)
    ;;
  *)
    printf '::error::Unknown library: %s\n' "$BUILD_LIBRARY" >&2
    exit 1
    ;;
esac

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
cd "$work"

apt_options=(-o APT::Keep-Downloaded-Packages=false
  -o Binary::apt::APT::Keep-Downloaded-Packages=false)
apt-get "${apt_options[@]}" update
apt-get "${apt_options[@]}" install -y --no-install-recommends \
  ca-certificates cmake curl git gnupg libc6-dev ninja-build

apt_sources='' apt_lists=''
eval "$(apt-config shell apt_sources Dir::Etc::sourceparts/d apt_lists Dir::State::lists/d)"
apt_keyrings="$(dirname "$apt_sources")/keyrings"
mkdir -p "$apt_keyrings"
curl --fail --silent --show-error --location --retry 5 \
  https://apt.llvm.org/llvm-snapshot.gpg.key \
  | gpg --dearmor -o "$apt_keyrings/llvm.gpg"
printf 'deb [signed-by=%s] https://apt.llvm.org/trixie/ llvm-toolchain-trixie-23 main\n' \
  "$apt_keyrings/llvm.gpg" > "$apt_sources/llvm23.list"
apt-get "${apt_options[@]}" update
apt-get "${apt_options[@]}" install -y --no-install-recommends \
  clang-23 lld-23 llvm-23 libclang-rt-23-dev libc++-23-dev libc++abi-23-dev libunwind-23-dev
apt-get clean
rm -rf "${apt_lists:?}/"*

llvm_bin="$(dirname "$(readlink -f "$(command -v clang-23)")")"
export PATH="$llvm_bin:$PATH"
export CC=clang CXX=clang++ LD=ld.lld
"$CC" --version

git clone "${clone_options[@]}" "$repository" source
revision="$(git -C source rev-parse HEAD)"
printf 'Building %s at %s\n' "$BUILD_LIBRARY" "$revision"

cmake -S "$source_dir" -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_AR="$llvm_bin/llvm-ar" -DCMAKE_RANLIB="$llvm_bin/llvm-ranlib" \
  "${cmake_options[@]}"
cmake --build build --parallel "$(nproc)"
ctest --test-dir build --output-on-failure --no-tests=error
DESTDIR="$work/stage" cmake --install build

tar -C "$work/stage$prefix" -czf \
  "$BUILD_ROOT/artifacts/$archive_name-${revision:0:12}-debian13.tar.gz" .
