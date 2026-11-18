#!/usr/bin/env bash
set -euo pipefail

prefix="${REQUESTED_PREFIX:-}"
if [[ -n "$prefix" && "$prefix" != /* ]]; then
  printf '%s\n' '::error::The installation prefix must be an absolute path.' >&2
  exit 1
fi
work="$(mktemp -d)"
cd "$work"

apt_options=(-o APT::Keep-Downloaded-Packages=false
  -o Binary::apt::APT::Keep-Downloaded-Packages=false)
apt-get "${apt_options[@]}" update
apt-get "${apt_options[@]}" install -y --no-install-recommends \
  ca-certificates curl gnupg git make perl libc6-dev openssl
# Discover APT configuration and tool locations rather than assuming
# installation paths. Always install the newest LLVM 23 packages.
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
  clang-23 lld-23 llvm-23 libclang-rt-23-dev
apt-get clean
rm -rf "${apt_lists:?}/"*
llvm_bin="$(dirname "$(readlink -f "$(command -v clang-23)")")"
export PATH="$llvm_bin:$PATH"
export CC=clang CXX=clang++ LD=ld.lld AR=llvm-ar RANLIB=llvm-ranlib
export NM=llvm-nm STRIP=llvm-strip OBJCOPY=llvm-objcopy
export AS="$CC"

tag="${REQUESTED_OPENSSL_TAG:-}"
if [[ -z "$tag" ]]; then
  tag="$(git ls-remote --tags --refs https://github.com/openssl/openssl.git \
    | sed -n 's|.*refs/tags/\(openssl-[0-9]\+\.[0-9]\+\.[0-9]\+\)$|\1|p' \
    | sort -V | tail -n1)"
fi
if [[ ! "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  printf '::error::Invalid OpenSSL tag: %s\n' "$tag" >&2
  exit 1
fi
# Fetch the exact tag: a branch with the same name cannot be selected.
git init source
git -C source remote add origin https://github.com/openssl/openssl.git
git -C source fetch --depth 1 origin "refs/tags/$tag"
git -C source checkout --detach FETCH_HEAD
rm -rf source/.git
mkdir build stage
cd build
if [[ -n "$prefix" ]]; then
  openssl_dir="${prefix%/}/ssl"
else
  prefix="$(dirname "$(dirname "$(command -v make)")")"
  openssl_dir="$(openssl version -d | cut -d '"' -f2)"
fi
perl ../source/Configure linux-aarch64 shared enable-pic no-tests no-docs \
  --prefix="$prefix" --libdir=lib --openssldir="$openssl_dir"
make -j"$(nproc)"
make DESTDIR="$work/stage" install_sw

tar -C "$work/stage$prefix" -czf "$BUILD_ROOT/artifacts/${tag}-debian13.tar.gz" .
