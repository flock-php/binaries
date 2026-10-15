# Flock binaries

Prebuilt PHP, PostgreSQL and Valkey for [Flock](https://github.com/flock-php/flock), built
reproducibly on GitHub Actions and published as GitHub Releases. Flock downloads them from a
signed manifest, so nothing has to be compiled on your machine.

## Releases

What we build is pinned in [`versions.json`](versions.json). The daily `Release` workflow
(`release.yml`) asks `tools/flockrel plan` which package versions aren't published yet, builds and
tests each one, and uploads it to a release tagged `<package>-<version>` as
`<package>-<version>-<platform>.tar.gz|zip`. A package is only uploaded when every check passed, and
an uploaded asset is never replaced.

Then it rebuilds `manifest.json` from all releases and signs it with ed25519. Flock downloads
`releases/download/manifest/manifest.json` and `manifest.json.sig` and checks them against the
public key in [`manifest.pub`](manifest.pub), which it ships with. It rejects a manifest that
doesn't verify, has expired (30 days; the daily run re-signs it), or has a lower `serial` than the
last one it accepted. Every package is then checked against the manifest's SHA-256.

| Package | Platforms | Workflow |
|---|---|---|
| PHP (cli + fpm, extensions compiled in, optional extensions in `ext/`) | macOS arm64 (13+) | `build-php-macos.yml` |

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
versions.json                 what we build: PHP minors, static-php-cli, extensions, manifest expiry
tools/flockrel/               release tooling: plan, manifest (build + sign), verify, keygen
packages/<name>/<platform>/   build or packaging script per package and platform
scripts/verify-macos.sh       fails when a Mach-O file links outside macOS or targets macOS > 13
scripts/smoke-*.sh|ps1        smoke tests run against every package before it is published
```

## Licenses

Each published package contains the licenses of the software it bundles in `LICENSES/`.
