RAR fixtures are decoded, unmodified reference archives from libarchive v3.8.9:
https://github.com/libarchive/libarchive/tree/v3.8.9/libarchive/test
rar4.rar: test_read_format_rar.rar.uu (contains a symlink; expected rejection)
rar4-binary.rar: test_read_format_rar_binary_data.rar.uu
rar5.rar: test_read_format_rar5_compressed.rar.uu
Their license is in LIBARCHIVE-LICENSE.txt.
Other tiny ZIP/TAR fixtures were generated specifically for LiteZip security tests.
They intentionally contain malicious paths or link entries. Never extract them with an untrusted tool.

legacy.rar/r00/r01 derive from libarchive v3.8.9
  test_rar_multivolume_single_file.part1/2/3.rar.uu.
Only the RAR4 main-header NEWNUMBERING bit (0x10) is cleared and that
header's CRC16 is recomputed; compressed payload bytes are unchanged.
This exercises old .rar/.r00 naming. License: LIBARCHIVE-LICENSE.txt.
ZIPX LZMA/BZIP2 fixtures were generated with Python zipfile (UTF-8 names,
empty file and directory); unsupported.zipx has method IDs changed to 255.

Extract-only format fixtures (ExtractOnlyFormatTests):
libarchive.cab = libarchive v3.8.9 test_read_format_cab_1.cab.uu, decoded and unmodified.
symlinks.lzh = libarchive v3.8.9 test_read_format_lha_lh6.lzh.uu, decoded and unmodified.
  It contains LHA symbolic links (name|target); expected rejection.
libarchive.tar.lzo = libarchive v3.8.9 test_compat_lzop_1.tar.lzo.uu, decoded and unmodified.
  Written by another lzop implementation. Licence: LIBARCHIVE-LICENSE.txt.
plain.lzh was generated with Python following the LHA level-0 header layout (-lh0- stored,
  CRC-16/ARC); 7-Zip verifies it. sample.cpio comes from macOS bsdcpio (odc, UTF-8 name).
sample.txt.lzma is Python lzma.FORMAT_ALONE; sample.txt.Z is /usr/bin/compress;
sample.txt.lzo was written by the bundled lzop 1.04.
