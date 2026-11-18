#!/usr/bin/env bash
# GNU toolchain overrides are intentionally scoped to the glibc subshell.
# shellcheck disable=SC2030,SC2031
set -euo pipefail

work="$(mktemp -d)"
cd "$work"
prefix="$work/prefix"
sysroot="$work/sysroot"
mkdir -p "$prefix" "$sysroot" "$work/src" "$work/build"

# APT is only for bootstrap/build tools and LLVM's matching runtimes.
# Application libraries are built below from their newest stable tags.
apt_options=(-o APT::Keep-Downloaded-Packages=false
  -o Binary::apt::APT::Keep-Downloaded-Packages=false)
apt-get "${apt_options[@]}" update
apt-get "${apt_options[@]}" install -y --no-install-recommends \
  ca-certificates curl gnupg git python3 xz-utils bzip2 \
  gcc make binutils libc6-dev cmake ninja-build pkg-config gawk bison flex \
  texinfo linux-libc-dev tcl
# Use Trixie's default GCC and GNU binutils only for glibc.
gcc="$(command -v gcc)"
gnu_bin="$(dirname "$(command -v ld)")"
system_prefix="$(dirname "$(dirname "$gcc")")"
system_include="$system_prefix/include"
target_include="$sysroot$system_include"
target_lib="$sysroot$system_prefix/lib"
multiarch="$("$gcc" -dumpmachine)"
"$gcc" --version
test "$("$gcc" -dumpversion)" = 14
printf 'gcc\tDebian Trixie apt\t%s\n' "$("$gcc" -dumpfullversion)" >> "$work/versions.tsv"
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
  clang-23 lld-23 llvm-23 llvm-23-tools libclang-rt-23-dev \
  libc++-23-dev libc++abi-23-dev libunwind-23-dev
apt-get clean
rm -rf "${apt_lists:?}/"*

llvm_bin="$(dirname "$(readlink -f "$(command -v clang-23)")")"
llvm_prefix="$(dirname "$llvm_bin")"
llvm_lib="$llvm_prefix/lib"
llvm_cxx_include="$llvm_prefix/include/c++/v1"
export PATH="$llvm_bin:$PATH"
export CC="$llvm_bin/clang" CXX="$llvm_bin/clang++" LD="$llvm_bin/ld.lld"
export AR="$llvm_bin/llvm-ar" NM="$llvm_bin/llvm-nm" RANLIB="$llvm_bin/llvm-ranlib"
export STRIP="$llvm_bin/llvm-strip" OBJCOPY="$llvm_bin/llvm-objcopy"
export OBJDUMP="$llvm_bin/llvm-objdump" READELF="$llvm_bin/llvm-readelf" SIZE="$llvm_bin/llvm-size"
# Clang's integrated assembler handles .S inputs. llvm-as is an LLVM IR
# assembler and must never be used as the platform assembly compiler.
export AS="$CC"
jobs=6
export CMAKE_BUILD_PARALLEL_LEVEL="$jobs"
base_cflags="$CFLAGS"
base_cxxflags="$CXXFLAGS"
base_ldflags="$LDFLAGS"

fetch() { curl --fail --location --retry 5 --retry-all-errors "$1"; }
# Sort numerical release tags, excluding RC/beta/branch builds. Resolve
# at run time rather than hard-coding yesterday's dependency versions.
latest_tag() {
  git ls-remote --tags --refs "https://github.com/$1.git" \
    | python3 -c '
import re, sys
pattern = re.compile(sys.argv[1])
tags = [line.split("refs/tags/", 1)[1].strip() for line in sys.stdin]
candidates = [(tuple(map(int, m.groups())), tag)
              for tag in tags if (m := pattern.fullmatch(tag))]
if not candidates:
    sys.exit("No stable release matching " + sys.argv[1])
print(max(candidates)[1])
' "$2"
}
clone_release() {
  local name="$1" repo="$2" pattern="$3" tag
  tag="$(latest_tag "$repo" "$pattern")"
  printf '%s\t%s\t%s\n' "$name" "$repo" "$tag" >> "$work/versions.tsv"
  git clone --depth 1 --branch "$tag" --recurse-submodules --shallow-submodules \
    "https://github.com/$repo.git" "$work/src/$name"
  rm -rf "$work/src/$name/.git"
}
cmake_build() {
  local name="$1"
  shift
  cmake -S "$work/src/$name" -B "$work/build/$name" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$work/llvm23.cmake" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_CXX_STANDARD=26 -DCMAKE_CXX_STANDARD_REQUIRED=ON \
    -DCMAKE_CXX_EXTENSIONS=OFF "$@"
  cmake --build "$work/build/$name"
  cmake --install "$work/build/$name"
  rm -rf -- "$work/src/$name" "$work/build/$name"
}

# Install glibc to a private sysroot, never over Trixie's host libc.
# GNU binutils are intentionally confined to this GCC/glibc step.
glibc_tag="$(latest_tag bminor/glibc 'glibc-([0-9]+)\.([0-9]+)')"
printf 'glibc\tbminor/glibc\t%s\n' "$glibc_tag" >> "$work/versions.tsv"
mkdir -p "$work/src/glibc" "$work/build/glibc" "$target_include"
fetch "https://ftp.gnu.org/gnu/libc/$glibc_tag.tar.xz" \
  | tar -xJ --strip-components=1 -C "$work/src/glibc"
# Materialize Debian UAPI header symlinks for the discovered target.
cp -aL "$system_include/linux" "$system_include/asm-generic" "$target_include/"
cp -aL "$system_include/$multiarch/asm" "$target_include/"
test -r "$target_include/asm/errno.h"
(
  cd "$work/build/glibc"
  # No inherited -flto, LLD, stripping or --gc-sections for glibc.
  # Use Trixie's GCC 14 and GNU ld/as for glibc.
  export CC="$gcc" CXX=false LD="$gnu_bin/ld" AS="$gnu_bin/as"
  export AR="$gnu_bin/ar" NM="$gnu_bin/nm" RANLIB="$gnu_bin/ranlib"
  export OBJCOPY="$gnu_bin/objcopy" OBJDUMP="$gnu_bin/objdump" READELF="$gnu_bin/readelf"
  export STRIP="$gnu_bin/strip"
  # +noras is a Clang-only CPU modifier; GCC does not accept it.
  # Keep the full requested CPU flags for every LLVM-built component.
  export CFLAGS='-O3 -mcpu=cortex-a76+nossbs -fno-lto'
  export CXXFLAGS="$CFLAGS" LDFLAGS='-fno-lto'
  if ! "$work/src/glibc/configure" --prefix="$system_prefix" --libdir="$system_prefix/lib" \
    --with-headers="$target_include" --enable-kernel=6.12 \
    --enable-static-nss --disable-nscd --disable-werror; then
    cat config.log
    exit 1
  fi
  make -j"$jobs"
  make DESTDIR="$sysroot" install
)
test -f "$target_lib/libc.a"
rm -rf -- "$work/src/glibc" "$work/build/glibc"

# Use matching LLVM 23 libc++, libc++abi, libunwind and compiler-rt.
# These are the official Trixie LLVM toolchain packages, not libstdc++.
# Rebase only the libc headers/startup objects through --sysroot.
test -f "$llvm_cxx_include/__config"
test -f "$llvm_lib/libc++.a"
test -f "$llvm_lib/libc++abi.a"
test -f "$llvm_lib/libunwind.a"
export CFLAGS="$base_cflags --sysroot=$sysroot --rtlib=compiler-rt"
export CXXFLAGS="$base_cxxflags --sysroot=$sysroot --rtlib=compiler-rt -stdlib=libc++ -isystem $llvm_cxx_include"
export LDFLAGS="$base_ldflags --sysroot=$sysroot --rtlib=compiler-rt --unwindlib=libunwind -L$llvm_lib -L$prefix/lib -static -no-pie -Wl,--start-group -lc++ -lc++abi -lunwind -Wl,--end-group"
export CPPFLAGS="-I$prefix/include"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
export PATH="$prefix/bin:$PATH"
cat > "$work/llvm23.cmake" <<CMAKE
set(CMAKE_C_COMPILER "$CC")
set(CMAKE_CXX_COMPILER "$CXX")
set(CMAKE_ASM_COMPILER "$AS")
set(CMAKE_LINKER "$LD")
set(CMAKE_AR "$AR")
set(CMAKE_RANLIB "$RANLIB")
set(CMAKE_NM "$NM")
set(CMAKE_STRIP "$STRIP")
set(CMAKE_OBJCOPY "$OBJCOPY")
set(CMAKE_OBJDUMP "$OBJDUMP")
set(CMAKE_READELF "$READELF")
set(CMAKE_C_COMPILER_AR "$AR")
set(CMAKE_CXX_COMPILER_AR "$AR")
set(CMAKE_C_COMPILER_RANLIB "$RANLIB")
set(CMAKE_CXX_COMPILER_RANLIB "$RANLIB")
set(CMAKE_C_FLAGS_RELEASE "-O3 -DNDEBUG" CACHE STRING "" FORCE)
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -DNDEBUG" CACHE STRING "" FORCE)
set(CMAKE_PREFIX_PATH "$prefix")
set(CMAKE_FIND_LIBRARY_SUFFIXES .a)
set(OPENSSL_USE_STATIC_LIBS TRUE)
set(ZLIB_USE_STATIC_LIBS TRUE)
set(Boost_USE_STATIC_LIBS TRUE)
CMAKE
clone_release zlib-ng zlib-ng/zlib-ng '([0-9]+)\.([0-9]+)\.([0-9]+)'
cmake_build zlib-ng -DZLIB_COMPAT=ON -DZLIB_ENABLE_TESTS=OFF -DWITH_GTEST=OFF

clone_release openssl openssl/openssl 'openssl-([0-9]+)\.([0-9]+)\.([0-9]+)'
(
  cd "$work/src/openssl"
  openssl_dir="$(openssl version -d | cut -d '"' -f2)"
  ./Configure linux-aarch64 --prefix="$prefix" --libdir=lib --openssldir="$openssl_dir" \
    no-shared no-module no-dso no-tests no-docs no-comp
  make -j"$jobs"
  make install_sw
)
rm -rf -- "$work/src/openssl"

# Install all Boost headers and official CMake metadata through B2.
# Build its engine explicitly: bootstrap.sh otherwise discards CXXFLAGS.
boost_tag="$(latest_tag boostorg/boost 'boost-([0-9]+)\.([0-9]+)\.([0-9]+)')"
printf 'boost\tboostorg/boost\t%s\n' "$boost_tag" >> "$work/versions.tsv"
mkdir -p "$work/src/boost"
fetch "https://github.com/boostorg/boost/releases/download/$boost_tag/$boost_tag-b2-nodocs.tar.xz" \
  | tar -xJ --strip-components=1 -C "$work/src/boost"
(
  cd "$work/src/boost"
  boost_b2="$work/src/boost/tools/build/src/engine/b2"
  ./tools/build/src/engine/build.sh cxx --cxx="$CXX" \
    --cxxflags="$CXXFLAGS $LDFLAGS -pthread"
  ./bootstrap.sh --with-bjam="$boost_b2" --with-toolset=clang \
    --with-libraries=headers --without-icu --prefix="$prefix"
  "$boost_b2" --with-headers --prefix="$prefix" --layout=system \
    toolset=clang cxxstd=26 cxxflags="$CXXFLAGS" linkflags="$LDFLAGS" \
    link=static -j"$jobs" /boost/headers//install
)
rm -rf -- "$work/src/boost"

clone_release libtorrent arvidn/libtorrent 'v([0-9]+)\.([0-9]+)\.([0-9]+)'
cmake_build libtorrent -Dbuild_tests=OFF -Dbuild_examples=OFF -Dpython-bindings=OFF \
  -Ddeprecated-functions=OFF -Dwebtorrent=OFF

clone_release double-conversion google/double-conversion 'v([0-9]+)\.([0-9]+)\.([0-9]+)'
# Upstream honors the common CMAKE_CXX_STANDARD=26 setting.
cmake_build double-conversion -DBUILD_TESTING=OFF

clone_release pcre2 PCRE2Project/pcre2 'pcre2-([0-9]+)\.([0-9]+)'
cmake_build pcre2 -DPCRE2_BUILD_PCRE2_16=ON -DPCRE2_BUILD_PCRE2GREP=OFF \
  -DPCRE2_BUILD_TESTS=OFF -DPCRE2_SUPPORT_JIT=ON

# Use SQLite's upstream configure and static-library install targets.
sqlite_path="$(fetch https://www.sqlite.org/download.html | python3 -c '
import re, sys
candidates = re.findall(r"([0-9]{4}/sqlite-autoconf-([0-9]+)\.tar\.gz)", sys.stdin.read())
if not candidates: sys.exit("No stable SQLite amalgamation found")
print(max(candidates, key=lambda x: int(x[1]))[0])
')"
printf 'sqlite\thttps://www.sqlite.org/\t%s\n' "$sqlite_path" >> "$work/versions.tsv"
mkdir -p "$work/src/sqlite"
fetch "https://www.sqlite.org/$sqlite_path" \
  | tar -xz --strip-components=1 -C "$work/src/sqlite"
mkdir -p "$work/build/sqlite"
(
  cd "$work/build/sqlite"
  autosetup_tclsh="$(command -v tclsh)" CC_FOR_BUILD="$CC" \
    "$work/src/sqlite/configure" --prefix="$prefix" --libdir="$prefix/lib" \
    --disable-shared --enable-static --disable-load-extension --disable-readline \
    --disable-math --disable-carray --fts5 --rtree --column-metadata
  make -j"$jobs" install-lib install-headers install-pc
)
rm -rf -- "$work/src/sqlite" "$work/build/sqlite"

# QtBase and QtTools must have exactly the same latest stable Qt tag.
qt_tag="$(latest_tag qt/qtbase 'v(6)\.([0-9]+)\.([0-9]+)')"
for module in qtbase qttools; do
  printf '%s\tqt/%s\t%s\n' "$module" "$module" "$qt_tag" >> "$work/versions.tsv"
  git clone --depth 1 --branch "$qt_tag" "https://github.com/qt/$module.git" "$work/src/$module"
  rm -rf "$work/src/$module/.git"
done
# Retain this narrow workaround: QtBase adds qlalr unconditionally,
# without a feature switch, and its iterator comparisons fail with
# libc++ 23/C++26. qBittorrent does not need this developer-only tool.
sed -i '/^add_subdirectory(qlalr)$/d' "$work/src/qtbase/src/tools/CMakeLists.txt"
# Static Qt otherwise embeds the temporary build prefix in runtime
# paths, including qtlogging.ini. Resolve them relative to the executable.
cmake_build qtbase \
  -DQT_FEATURE_relocatable=ON \
  -DQT_BUILD_TESTS=OFF -DQT_BUILD_EXAMPLES=OFF -DQT_BUILD_BENCHMARKS=OFF \
  -DQT_FEATURE_cxx2c=ON -DQT_FEATURE_shared=OFF -DQT_FEATURE_static=ON \
  -DQT_FEATURE_icu=OFF -DQT_FEATURE_gui=OFF -DQT_FEATURE_widgets=OFF \
  -DQT_FEATURE_dbus=OFF -DQT_FEATURE_glib=OFF -DQT_FEATURE_opengl=OFF \
  -DQT_FEATURE_openssl_linked=ON -DQT_FEATURE_openssl_runtime=OFF \
  -DQT_FEATURE_system_zlib=ON -DQT_FEATURE_system_pcre2=ON \
  -DQT_FEATURE_system_doubleconversion=ON -DQT_FEATURE_system_sqlite=ON \
  -DQT_FEATURE_sql_sqlite=ON -DQT_FEATURE_sql_mysql=OFF -DQT_FEATURE_sql_odbc=OFF \
  -DQT_FEATURE_sql_psql=OFF -DQT_FEATURE_sql_ibase=OFF -DQT_FEATURE_sql_oci=OFF \
  -DQT_FEATURE_brotli=OFF -DQT_FEATURE_zstd=OFF -DQT_FEATURE_libproxy=OFF \
  -DQT_FEATURE_gssapi=OFF -DQT_FEATURE_journald=OFF -DQT_FEATURE_syslog=OFF
cmake_build qttools -DQT_BUILD_TESTS=OFF -DQT_BUILD_EXAMPLES=OFF \
  -DQT_FEATURE_linguist=ON -DQT_FEATURE_assistant=OFF -DQT_FEATURE_designer=OFF \
  -DQT_FEATURE_qdoc=OFF -DQT_FEATURE_clang=OFF

clone_release mimalloc microsoft/mimalloc 'v([0-9]+)\.([0-9]+)\.([0-9]+)'
cmake_build mimalloc -DMI_BUILD_SHARED=OFF -DMI_BUILD_STATIC=ON -DMI_BUILD_OBJECT=ON \
  -DMI_BUILD_TESTS=OFF -DMI_OVERRIDE=ON -DMI_USE_CXX=OFF -DMI_OPT_ARCH=OFF \
  -DMI_INSTALL_TOPLEVEL=ON
# The documented single object override wins over libc's allocator.
# Discover the installed file instead of hard-coding a mimalloc version.
mapfile -t mimalloc_objects < <(find "$prefix" -name mimalloc.o -type f)
test "${#mimalloc_objects[@]}" = 1
mimalloc_object="${mimalloc_objects[0]}"

clone_release qbittorrent qbittorrent/qBittorrent 'release-([0-9]+)\.([0-9]+)\.([0-9]+)'
# Retain the HTTP correctness fix: no upstream build option controls
# this initializer. Full LTO exposes an initialization-order bug: EOH can be
# constructed before the inline CRLF QByteArray and become empty.
# Use an independent constant view; keep newer upstream fixes intact.
python3 - "$work/src/qbittorrent/src/base/http/requestparser.cpp" <<'PY_HTTP'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text()
old = "const QByteArray EOH = CRLF.repeated(2);"
new = r'constexpr QByteArrayView EOH = "\x0D\x0A\x0D\x0A";'
if old in source:
    assert source.count(old) == 1, "Unexpected HTTP delimiter declarations"
    path.write_text(source.replace(old, new))
    print("Applied constant HTTP delimiter fix")
PY_HTTP
cmake -S "$work/src/qbittorrent" -B "$work/build/qbittorrent" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$work/llvm23.cmake" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_CXX_STANDARD=26 \
  -DCMAKE_CXX_STANDARD_REQUIRED=ON -DCMAKE_CXX_EXTENSIONS=OFF \
  -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS $mimalloc_object" \
  -DGUI=OFF -DWEBUI=ON -DSTACKTRACE=OFF -DDBUS=OFF -DSYSTEMD=OFF \
  -DBUILD_SHARED_LIBS=OFF -DTESTING=OFF
cmake --build "$work/build/qbittorrent"
cmake --install "$work/build/qbittorrent"
binary="$prefix/bin/qbittorrent-nox"
"$STRIP" --strip-all "$binary"
rm -rf -- "$work/src/qbittorrent" "$work/build/qbittorrent"

mkdir "$work/package"
install -m 0755 "$binary" "$work/package/qbittorrent-nox"
{
  printf 'OS: Debian 13 arm64\nCPU: Cortex-A76\nLLVM: %s\n' "$(clang -dumpversion)"
  printf 'CFLAGS=%s\nCXXFLAGS=%s\nLDFLAGS=%s\n' "$base_cflags" "$base_cxxflags" "$base_ldflags"
  printf '\nDependencies (name, source, version)\n'
  cat "$work/versions.tsv"
} > "$work/package/BUILD-INFO.txt"

tar -C "$work/package" -czf "$BUILD_ROOT/artifacts/qbittorrent-nox-debian13-arm64-cortex-a76.tar.gz" .
