# Archive formats

LiteZip now creates 21 formats, with ZIPX additionally available for extraction.
All create formats have named color badges in the main window and menu-bar panel.

| Format | Extension | Creation and extraction |
| --- | --- | --- |
| ZIP, 7Z | .zip, .7z | Multiple files and folders; password and volumes |
| RAR | .rar | Creation uses the separately connected official RAR engine; extraction is built in |
| TAR | .tar | Multiple files and folders, without compression |
| TAR.GZ, TAR.BZ2, TAR.XZ, TAR.ZST | .tar.gz, .tar.bz2, .tar.xz, .tar.zst | Multiple files and folders, packed then compressed |
| GZIP, BZIP2, XZ, ZSTD | .gz, .bz2, .xz, .zst | One regular file per stream |
| LZIP, LZ4, BROTLI, LRZIP, SNAPPY | .lz, .lz4, .br, .lrz, .sz | One regular file per stream, with bundled standalone engines |
| AAR | .aar | Apple Archive; files and folders, native macOS reader and writer |
| WIM | .wim | Windows Imaging archive; files and folders |
| DMG | .dmg | Native image creation and read-only preview; mount in Finder for filesystem semantics |
| ISO | .iso | ISO9660 / Joliet / UDF hybrid image creation, preview and extraction; no compression or encryption |
| ZIPX | .zipx | Extraction of methods supported by bundled 7-Zip |

Single-file formats reject folders and multiple inputs. “分别压缩” makes one
stream per regular file. They have no password or split-volume controls.
GZIP and BZIP2 also recognize `.gzip` and `.bzip2`; LZIP, Brotli, LRZIP and
Snappy recognize their full names as aliases. Brotli has no fixed magic header,
so extension detection is required. Stream output names are inferred from the
archive name because these formats generally do not retain an original filename.
Snappy uses the official framed format; its compression settings are fixed.

ISO uses `/usr/bin/hdiutil makehybrid`; ISO filenames and large files use the
Joliet/UDF portions of the hybrid image. ISO does not preserve the full macOS
filesystem semantics of DMG. AAR uses `/usr/bin/aa` to write source snapshots
and AppleArchive streams to decode without letting an engine create arbitrary
paths. AAR supports raw, LZ4, LZFSE and LZMA creation; encrypted AEA and clone /
hard-link references are not implemented. Like normal archive extraction,
AAR extraction creates ordinary files and directories, without restoring ACLs
or privileged metadata.

Stream previews decode data to count and validate the actual expanded size.
The output is discarded, not buffered in memory. Limits and cancellation use the
same path during preview, verification and extraction. LRZIP ignores external
configuration, uses a private registered scratch directory, a 100 MB window
and a 200 MB memory setting. New engines are universal ARM64 / x86_64 binaries
with only macOS system-library dependencies; no Homebrew tools are required at
runtime. Source packages and license texts accompany the bundle.

Validation: `swift test --filter MoreFormatsTests` covers Unicode paths, random
and empty data, source preservation, format aliases, truncated streams,
decompression limits, AAR traversal / duplicates / links, native AAR algorithms,
folder round trips and Mac resource exclusions. The full core suite covers
existing ZIP / TAR safety, volumes, RAR and DMG behaviour.
