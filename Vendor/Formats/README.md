# Additional standalone format engines

These unmodified command-line implementations run as separate processes.
`bin/` contains universal ARM64 / x86_64 executables targeting macOS 13+.
Dependencies are linked statically except for Apple's system libraries.
`Licenses/` contains complete licenses; `SourcePackages/` contains corresponding
unmodified upstream source archives. The application bundle includes both.

Rebuild with `bash Scripts/build-format-engines.sh`. The script pins URLs and
SHA-256 values, verifies downloaded archives, generates Snappy's configure
headers for portable code, disables ZPAQ JIT on macOS, and builds only inside
the project's `build/format-engines` directory. It does not install host tools.

| Tool | Version | Source | License |
| --- | --- | --- | --- |
| lzip | 1.26 | https://download-mirror.savannah.gnu.org/releases/lzip/lzip-1.26.tar.gz | GPL 2+ |
| lz4 | 1.10.0 | https://github.com/lz4/lz4/tree/v1.10.0 | CLI: GPL 2+; library: BSD 2 clause |
| brotli | 1.2.0 | https://github.com/google/brotli/tree/v1.2.0 | MIT |
| snzip | 1.0.5 | https://github.com/kubo/snzip/releases/tag/v1.0.5 | BSD 2 clause |
| snappy (snzip dependency) | 1.2.2 | https://github.com/google/snappy/tree/1.2.2 | BSD 3 clause |
| lrzip | 0.7.3 | https://github.com/ckolivas/lrzip/releases/tag/v0.7.3 | GPL 2+; bundled components as documented in source |
| lzo (lrzip dependency) | 2.10 | https://www.oberhumer.com/opensource/lzo/ | GPL 2+ |

7-Zip handles WIM without additional dependencies. ISO and Apple Archive use
macOS system components rather than downloaded tools.
