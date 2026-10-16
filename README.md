# Flock binaries

Prebuilt PHP, FrankenPHP and services (PostgreSQL, MariaDB, MySQL, MongoDB, Valkey, Redis,
Meilisearch, Typesense, RustFS, Node.js) for [Flock](https://github.com/flock-php/flock), built
reproducibly on GitHub Actions and published as GitHub Releases. Flock downloads them from a
signed manifest, so nothing has to be compiled on your machine.

## What we publish

Platforms are macOS on Apple Silicon (`macos-arm64`, macOS 13+) and Windows x64 (`windows-x64`).
Every package is either **built** here from verified upstream source, or **mirrored**: the
vendor's own binaries, checked against the vendor's checksum or signature.

| Package | macOS arm64 | Windows x64 | Versions (`versions.json`) |
|---|---|---|---|
| `php` | built: cli + fpm, extensions compiled in, optional ones in `ext/` | mirrored: the official thread-safe build from windows.php.net | macOS 8.1–8.5, Windows 7.4–8.5 |
| `php-exts` | – | built: extension DLLs for the Windows build (below) | one pack per Windows minor |
| `frankenphp` | built: FrankenPHP with the same PHP and extensions as `php` | built: FrankenPHP next to the official PHP build it links against | PHP 8.2–8.5 |
| `postgres` | built: server, client tools (psql, pg_dump, …), contrib | built | 14–18 |
| `mariadb` | built | mirrored | 10.11, 11.4, 11.8, 12.3 |
| `mysql` | mirrored | mirrored | 8.0, 8.4, 9.7 |
| `mongodb` | mirrored | mirrored | 7.0, 8.0, 9.0 |
| `valkey` | built | built with MSYS2 (`fork()` for persistence) | 9.1 |
| `redis` | built | – (Valkey only) | 7.2, 7.4, 8.4, 8.10 |
| `meilisearch` | mirrored (Community Edition) | mirrored (Community Edition) | 1 |
| `typesense` | mirrored | – (no Windows build upstream) | 29, 30 |
| `rustfs` | mirrored | mirrored | 1 |
| `node` | mirrored | mirrored | 16, 18, 20, 22, 24, 26 |

The versions column lists release lines: every day the newest upstream release of each line is
looked up (`tools/flockrel/upstream.go`, php.net and windows.php.net for PHP) and built or mirrored
when it isn't published yet. Patch releases come in on their own; a new line (PostgreSQL 19, Node.js
28, PHP 8.6) is one entry in `versions.json`.

### Windows extension packs

`php-exts-<minor>` holds thread-safe DLLs built with
[php-windows-builder](https://github.com/php/php-windows-builder) against the official build of
that minor, so they load into both `php` and `frankenphp` for Windows: apcu, igbinary, imagick
(with ImageMagick), pcov, redis and xdebug, plus the MongoDB maintainers' own DLLs from PHP 8.1 on.
Releases per extension, and per minor where one needs another release (xdebug 3.1 for PHP 7.4),
are in `php.windows.extensions`. memcached is macOS only. On Windows, imagick reports its version
as `@PACKAGE_VERSION@` (`phpversion('imagick')`), like the imagick maintainers' own Windows DLLs:
its source leaves the version to the PECL release. The pack only depends on the minor, so it
isn't rebuilt for PHP patch releases; raise `php.windows.extensions.build` to rebuild it.

### Package layouts

Archives are `.tar.gz` on macOS and `.zip` on Windows. Mirrored packages keep the vendor's layout,
usually one top-level folder (`mysql-8.4.11-macos15-arm64/bin/mysqld`); unpack and drop it. What we
build has `flock-package.json` at the top (what it is, how it was built) and `LICENSES/`.

| Package | Layout |
|---|---|
| `php` (macOS) | `bin/php`, `bin/php-fpm`, `ext/*.so` |
| `php` (Windows) | the official zip: `php.exe`, `php-cgi.exe`, `ext/` |
| `php-exts` | `ext/php_<name>.dll` into PHP's `ext\`; `*.dll` next to `php.exe` (ImageMagick) |
| `frankenphp` (macOS) | `bin/frankenphp`, `ext/*.so` |
| `frankenphp` (Windows) | `frankenphp.exe` next to the official PHP build of the same version |
| `postgres` | `bin/`, `lib/`, `share/` (relocatable) |
| `mariadb` (macOS) | `bin/`, `scripts/mariadb-install-db`, `share/`, `lib/plugin/`; run with `--basedir` |
| `valkey`, `redis` | `<name>-server`, `<name>-cli`, `<name>-benchmark` (Windows: with the MSYS2 DLLs) |
| `meilisearch`, `rustfs`, `typesense` | the executable and its license |

### Things to know

- **MySQL on macOS** needs macOS 15: Oracle builds it for no older release.
- **PostgreSQL on Windows** refuses to run as an administrator: start it with `pg_ctl`, which drops
  the administrator rights first.
- **PHP on Windows** is only mirrored while it is windows.php.net's current build of its minor
  (older builds have no published checksum): a patch the daily run misses entirely is skipped.
- **Meilisearch** is only ever the MIT Community Edition, never the BUSL `meilisearch-enterprise-*`
  builds.

## Releases

What we build is pinned in [`versions.json`](versions.json). The daily `Release` workflow
(`release.yml`) asks `tools/flockrel plan` which package versions aren't published yet, builds or
mirrors and tests each one, and uploads it to a release tagged `<package>-<version>` as
`<package>-<version>-build<N>-<platform>.tar.gz|zip`. A package is only uploaded when every check
passed (a smoke test on a fresh runner: on macOS without Homebrew), and an uploaded asset is never
replaced. Run `Release` by hand with `packages` (e.g. `postgres,node`, or `php`, `php-exts`,
`frankenphp`) to publish only some packages, or a build workflow by hand to test a version without
publishing it.

To rebuild versions that are already published (a security fix in a bundled library, an added
extension, a bug the tests missed), raise the platform's `build` in `versions.json`. The next run
builds the newest version of every line again as the new build, next to the old one. The manifest
lists only the newest build, and Flock updates an installed package when the manifest has a higher
build of the same version.

| Workflow | What |
|---|---|
| `release.yml` | daily: plan, build/mirror everything missing, rebuild and sign the manifest |
| `build-php-macos.yml` | `php` and `frankenphp` for macOS (static-php-cli) |
| `build-php-exts-windows.yml` | `php-exts` for one PHP minor |
| `build-frankenphp-windows.yml` | `frankenphp` for Windows |
| `build-service.yml` | PostgreSQL, MariaDB (macOS), Valkey, Redis from source |
| `mirror.yml` | everything mirrored, including PHP for Windows |

### Licenses and sources

Each package contains the licenses of what it bundles in `LICENSES/` (mirrored archives: the
vendor's own license files). For GPL, SSPL and AGPL software (MySQL, MariaDB, MongoDB, Typesense,
Redis) the matching upstream source is published on the same release as
`<package>-<version>-source.tar.gz`; Valkey for Windows has the source package of the MSYS2
runtime it ships (LGPL) next to it.

## The manifest

After each run, `manifest.json` is rebuilt from all releases and signed with ed25519:

```json
{
  "schema": 1,
  "serial": 1792168157,
  "generated": "2026-10-16T16:29:17Z",
  "expires": "2026-11-15T16:29:17Z",
  "packages": {
    "<package>": {
      "<version>": {
        "<platform>": { "build": 1, "url": "https://…", "sha256": "…", "size": 92651566, "published": "…" }
      }
    }
  }
}
```

Flock downloads `releases/download/manifest/manifest.json` and `manifest.json.sig` and checks them
against the public key in [`manifest.pub`](manifest.pub), which it ships with. It rejects a manifest
that doesn't verify, has expired (30 days; the daily run re-signs it), or has a lower `serial` than
the last one it accepted. A version only lists the platforms it was published for; every download
is checked against the manifest's SHA-256.

The signing key is the `MANIFEST_SIGNING_KEY` secret of the `release` environment. To replace it:

```sh
go -C tools/flockrel run . keygen -pub ../../manifest.pub | gh secret set MANIFEST_SIGNING_KEY --env release
```

then commit `manifest.pub` and ship the new public key in Flock.

## Layout

```
versions.json                    what we build: PHP per platform, extensions, FrankenPHP, service lines, manifest expiry
tools/flockrel/                  release tooling: plan, manifest (build + sign), verify, keygen
packages/<name>/<platform>/      build script per package and platform
packages/<name>/mirror.sh        download + verify a vendor release (mirrored packages)
packages/<name>/source.sh        download + verify the upstream source (builds, and published for copyleft)
scripts/lib.sh                   download and checksum helpers for the package scripts
scripts/macos/                   static OpenSSL build, relocation of macOS installs (@loader_path)
scripts/windows/                 php-windows-builder setup, extension packs, Windows smoke tests
scripts/publish.sh               upload a package (and its sources) to its release
scripts/verify-macos.sh          fails when a Mach-O file links outside macOS or targets macOS > 13
scripts/smoke-*.sh               smoke tests run against every package before it is published
```
