# Flock binaries

Prebuilt PHP and services (PostgreSQL, MariaDB, MySQL, MongoDB, Valkey, Redis, Meilisearch,
Typesense, RustFS, Node.js) for [Flock](https://github.com/flock-php/flock), built
reproducibly on GitHub Actions and published as GitHub Releases. Flock downloads them from a
signed manifest, so nothing has to be compiled on your machine.

## Releases

What we build is pinned in [`versions.json`](versions.json). The daily `Release` workflow
(`release.yml`) asks `tools/flockrel plan` which package versions aren't published yet, builds and
tests each one, and uploads it to a release tagged `<package>-<version>` as
`<package>-<version>-build<N>-<platform>.tar.gz|zip`. A package is only uploaded when every check
passed, and an uploaded asset is never replaced.

To rebuild versions that are already published (a security fix in a bundled library, an added
extension, a bug the tests missed), raise the platform's `build` in `versions.json`. The next run
builds the newest patch of every minor again as the new build, next to the old one. The manifest
lists only the newest build, and Flock updates an installed package when the manifest has a higher
build of the same version.

Then it rebuilds `manifest.json` from all releases and signs it with ed25519. Flock downloads
`releases/download/manifest/manifest.json` and `manifest.json.sig` and checks them against the
public key in [`manifest.pub`](manifest.pub), which it ships with. It rejects a manifest that
doesn't verify, has expired (30 days; the daily run re-signs it), or has a lower `serial` than the
last one it accepted. Every package is then checked against the manifest's SHA-256.

| Package | Platforms | Workflow |
|---|---|---|
| PHP (cli + fpm, extensions compiled in, optional extensions in `ext/`) | macOS arm64 (13+) | `build-php-macos.yml` |
| PHP, the official thread-safe build from windows.php.net, mirrored | Windows x64 | `mirror.yml` |
| PostgreSQL (server, client tools, contrib), built | macOS arm64, Windows x64 | `build-service.yml` |
| MariaDB, built | macOS arm64 | `build-service.yml` |
| Valkey, built | macOS arm64, Windows x64 (MSYS2) | `build-service.yml` |
| Redis, built | macOS arm64 | `build-service.yml` |
| MySQL, MongoDB, Meilisearch (Community Edition), RustFS, Node.js, mirrored | macOS arm64, Windows x64 | `mirror.yml` |
| MariaDB, mirrored | Windows x64 | `mirror.yml` |
| Typesense, mirrored | macOS arm64 | `mirror.yml` |

Services are tracked by release line in `versions.json` (`packages.<name>.lines`): every day the
newest upstream version of each line is looked up (`tools/flockrel/upstream.go`) and built or
mirrored when it isn't published yet. Mirrored packages are the vendor's own binaries, checked
against the vendor's checksum or signature in `packages/<name>/mirror.sh` (and, for MySQL, MongoDB
and Node.js, the vendor's code signature on the binaries), and published unchanged unless upstream
ships a bare executable without its license (Meilisearch, RustFS, Typesense), which is then packed
together with it. For GPL, SSPL and AGPL software the matching upstream source is published on the
same release as `<name>-<version>-source.tar.gz`. Meilisearch is only ever mirrored as its MIT
Community Edition, never the BUSL `meilisearch-enterprise-*` builds.

Run a build workflow by hand to test a version without publishing it.

The signing key is the `MANIFEST_SIGNING_KEY` secret of the `release` environment. To replace it:

```sh
go -C tools/flockrel run . keygen -pub ../../manifest.pub | gh secret set MANIFEST_SIGNING_KEY --env release
```

then commit `manifest.pub` and ship the new public key in Flock.

## Proofs of concept

The `PoC:` workflows (run manually from the Actions tab) check the riskiest parts before they
become release workflows:

| Workflow | Question it answers |
|---|---|
| `poc-php-macos.yml` | Does static-php-cli build PHP 8.1–8.5 with the optional extensions (imagick, pcov, mongodb, memcached, xdebug) as shared `.so` files, portable to Macs without Homebrew? |
| `poc-valkey-windows.yml` | Does Valkey built with MSYS2 survive Flock's use on Windows (fork-based persistence, hard kills, restarts)? |
| `poc-php-ext-windows.yml` | Does php-windows-builder build the thread-safe extension DLLs (imagick, redis, igbinary, apcu, pcov, mongodb) for PHP 7.4–8.5? |
| `poc-frankenphp.yml` | Can we build FrankenPHP for PHP 8.2–8.5 on macOS (static-php-cli, same extensions) and natively on Windows, with worker mode working? |

## Layout

```
versions.json                 what we build: PHP minors per platform, static-php-cli, extensions, service lines, manifest expiry
tools/flockrel/               release tooling: plan, manifest (build + sign), verify, keygen
packages/<name>/<platform>/   build script per package and platform
packages/<name>/mirror.sh     download + verify a vendor release (mirrored packages)
packages/<name>/source.sh     download + verify the upstream source (builds, and published for copyleft)
scripts/macos/                static OpenSSL build, relocation of macOS installs (@loader_path)
scripts/publish.sh            upload a package (and its source) to its release
scripts/verify-macos.sh       fails when a Mach-O file links outside macOS or targets macOS > 13
scripts/smoke-*.sh|ps1        smoke tests run against every package before it is published
scripts/windows/smoke-service.ps1  the same for services on Windows
```

## Licenses

Each published package contains the licenses of the software it bundles in `LICENSES/`.
