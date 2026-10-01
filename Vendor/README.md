# Bundled engines

## 7-Zip 26.03

- Official release: https://github.com/ip7z/7zip/releases/tag/26.03
- macOS universal package: https://github.com/ip7z/7zip/releases/download/26.03/7z2603-mac.tar.xz
- Package SHA-256: `5ca87677072c59f5602e5c49baa27d4694bacd2259b4e507f0094249d4281480`
- Corresponding source: https://github.com/ip7z/7zip/releases/download/26.03/7z2603-src.tar.xz
- `7zip/7zz` is the unmodified upstream executable (code signatures are applied to copies in build products).
- LGPL 2.1+ and unRAR restrictions plus listed component licenses. Read `7zip/License.txt`.
- The bundled executable can be replaced by a compatible user-built executable.

## Zstandard 1.5.7

- Source: https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz
- Source package SHA-256: `eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`
- BSD license option: `zstd/LICENSE`.
- Standalone universal executable, linked only to system `libSystem`, built from the unmodified source using:

```sh
make -C zstd-1.5.7/programs -j4 zstd \
  HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0 ZSTD_NO_ASM=1 \
  CFLAGS='-O2 -arch arm64 -arch x86_64 -mmacosx-version-min=13.0' \
  LDFLAGS='-arch arm64 -arch x86_64 -mmacosx-version-min=13.0'
```

The tool is bundled because upstream 7-Zip reads ZSTD but does not create it.
Additional stream formats use standalone universal engines documented in
[Formats/README.md](Formats/README.md). WIM uses 7-Zip; ISO and AAR use native
macOS components.
