#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$PWD"
work="$repo/build/format-engines"
prefix="$work/prefix"
flags='-O2 -arch arm64 -arch x86_64 -mmacosx-version-min=13.0'
mkdir -p "$work/sources" "$prefix/lib" "$prefix/include" Vendor/Formats/bin Vendor/Formats/Licenses
fetch() {
  local name="$1" hash="$2" url="$3"
  test -f "$work/sources/$name" || curl -fsSL --retry 2 "$url" -o "$work/sources/$name"
  echo "$hash  $work/sources/$name" | shasum -a 256 -c -
  tar -xf "$work/sources/$name" -C "$work"
}
fetch lzip-1.26.tar.gz 641cf30961525cbe3b340cc883436c8854e9f5032f459f444de4782b621e6572 https://download-mirror.savannah.gnu.org/releases/lzip/lzip-1.26.tar.gz
fetch lz4-1.10.0.tar.gz 537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b https://github.com/lz4/lz4/archive/refs/tags/v1.10.0.tar.gz
fetch brotli-1.2.0.tar.gz 816c96e8e8f193b40151dad7e8ff37b1221d019dbcb9c35cd3fadbfe6477dfec https://github.com/google/brotli/archive/refs/tags/v1.2.0.tar.gz
fetch snappy-1.2.2.tar.gz 90f74bc1fbf78a6c56b3c4a082a05103b3a56bb17bca1a27e052ea11723292dc https://github.com/google/snappy/archive/refs/tags/1.2.2.tar.gz
fetch snzip-1.0.5.tar.gz fbb6b816619628f385b62f44a00a1603be157fba6ed2d30de490b0c5e645bff8 https://github.com/kubo/snzip/releases/download/v1.0.5/snzip-1.0.5.tar.gz
fetch lzo-2.10.tar.gz c0f892943208266f9b6543b3ae308fab6284c5c90e627931446fb49b4221a072 https://www.oberhumer.com/opensource/lzo/download/lzo-2.10.tar.gz
fetch lrzip-0.7.3.tar.xz 6928862de7c4bbb3cfbcd12fae9fd0a7d230d5bbf27486e52c4de60717ebfdbb https://github.com/ckolivas/lrzip/releases/download/v0.7.3/lrzip-0.7.3.tar.xz
(cd "$work/lzip-1.26"; ./configure "CXXFLAGS=$flags" "LDFLAGS=$flags"; make -j4)
make -C "$work/lz4-1.10.0/lib" clean
make -C "$work/lz4-1.10.0" -j4 lz4 CFLAGS="$flags" LDFLAGS="$flags" BUILD_SHARED=no
make -C "$work/lz4-1.10.0/lib" -j4 lib-release CFLAGS="$flags" LDFLAGS="$flags" BUILD_SHARED=no
cp "$work/lz4-1.10.0/lib/liblz4.a" "$prefix/lib/"
cp "$work/lz4-1.10.0/lib/"*.h "$prefix/include/"
# Build the portable Brotli CLI from the upstream C sources, without host dylibs.
clang $flags -DBROTLI_BUILD_PORTABLE -I"$work/brotli-1.2.0/c/include" \
  "$work/brotli-1.2.0/c/common/"*.c "$work/brotli-1.2.0/c/enc/"*.c \
  "$work/brotli-1.2.0/c/dec/"*.c "$work/brotli-1.2.0/c/tools/brotli.c" -lm -o "$work/brotli"
# Snappy's public and private configure headers; use portable code on both CPUs.
python3 - "$work/snappy-1.2.2" <<'PY'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1])
ones={'HAVE_ATTRIBUTE_ALWAYS_INLINE','HAVE_BUILTIN_CTZ','HAVE_BUILTIN_EXPECT','HAVE_BUILTIN_PREFETCH','HAVE_FUNC_MMAP','HAVE_FUNC_SYSCONF','HAVE_SYS_MMAN_H','HAVE_SYS_RESOURCE_H','HAVE_SYS_TIME_H','HAVE_SYS_UIO_H','HAVE_UNISTD_H'}
s=(p/'cmake/config.h.in').read_text()
s=re.sub(r'#cmakedefine01 (\w+)',lambda m: '#define '+m[1]+' '+str(int(m[1] in ones)),s)
(p/'config.h').write_text(s)
s=(p/'snappy-stubs-public.h.in').read_text()
for k,v in {'HAVE_SYS_UIO_H_01':'1','PROJECT_VERSION_MAJOR':'1','PROJECT_VERSION_MINOR':'2','PROJECT_VERSION_PATCH':'2'}.items(): s=s.replace('${'+k+'}',v)
(p/'snappy-stubs-public.h').write_text(s)
PY
(cd "$work/snappy-1.2.2"; clang++ $flags -std=c++11 -DHAVE_CONFIG_H -I. -c snappy.cc snappy-c.cc snappy-sinksource.cc snappy-stubs-internal.cc; libtool -static -o "$prefix/lib/libsnappy.a" snappy.o snappy-c.o snappy-sinksource.o snappy-stubs-internal.o)
cp "$work/snappy-1.2.2/"*.h "$prefix/include/"
(cd "$work/snzip-1.0.5"; ./configure --with-snappy="$prefix" CC=clang CXX=clang++ CFLAGS="$flags" CXXFLAGS="$flags" LDFLAGS="$flags"; make -j4)
(cd "$work/lzo-2.10"; ./configure --prefix="$prefix" --disable-shared CC=clang CFLAGS="$flags" LDFLAGS="$flags"; make -j4; make install)
(cd "$work/lrzip-0.7.3"; ./configure CC=clang CXX=clang++ CFLAGS="$flags" CXXFLAGS="$flags -DNOJIT" CPPFLAGS="-I$prefix/include" LDFLAGS="$flags -L$prefix/lib"; make -j4)
cp "$work/lzip-1.26/lzip" "$work/lz4-1.10.0/lz4" "$work/brotli" "$work/snzip-1.0.5/snzip" "$work/lrzip-0.7.3/lrzip" Vendor/Formats/bin/
for name in lzip lz4 brotli snzip lrzip; do
  archs="$(lipo "Vendor/Formats/bin/$name" -archs)"
  [[ " $archs " == *' arm64 '* && " $archs " == *' x86_64 '* ]]
  otool -L "Vendor/Formats/bin/$name"
  chmod 755 "Vendor/Formats/bin/$name"
done
cp "$work/lzip-1.26/COPYING" Vendor/Formats/Licenses/lzip.txt
cp "$work/lz4-1.10.0/lib/LICENSE" Vendor/Formats/Licenses/lz4.txt
cp "$work/lz4-1.10.0/programs/COPYING" Vendor/Formats/Licenses/lz4-cli.txt
cp "$work/brotli-1.2.0/LICENSE" Vendor/Formats/Licenses/brotli.txt
cp "$work/snappy-1.2.2/COPYING" Vendor/Formats/Licenses/snappy.txt
cp "$work/snzip-1.0.5/COPYING" Vendor/Formats/Licenses/snzip.txt
cp "$work/lzo-2.10/COPYING" Vendor/Formats/Licenses/lzo.txt
cp "$work/lrzip-0.7.3/COPYING" Vendor/Formats/Licenses/lrzip.txt
mkdir -p Vendor/Formats/SourcePackages
cp "$work/sources/"* Vendor/Formats/SourcePackages/
