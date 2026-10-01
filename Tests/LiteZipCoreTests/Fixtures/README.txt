RAR fixtures are decoded, unmodified reference archives from libarchive v3.8.9:
https://github.com/libarchive/libarchive/tree/v3.8.9/libarchive/test
rar4.rar: test_read_format_rar.rar.uu (contains a symlink; expected rejection)
rar4-binary.rar: test_read_format_rar_binary_data.rar.uu
rar5.rar: test_read_format_rar5_compressed.rar.uu
Their license is in LIBARCHIVE-LICENSE.txt.
Other tiny ZIP/TAR fixtures were generated specifically for LiteZip security tests.
They intentionally contain malicious paths or link entries. Never extract them with an untrusted tool.
