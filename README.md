# Flock binaries

Prebuilt PHP, PostgreSQL and Valkey for [Flock](https://github.com/flock-php/flock), built
reproducibly on GitHub Actions and published as GitHub Releases. Flock downloads them from a
signed manifest, so nothing has to be compiled on your machine.

**Status:** proof of concept. The `PoC:` workflows (run manually from the Actions tab) check the
riskiest parts before the release pipeline is built:

| Workflow | Question it answers |
|---|---|
| `poc-php-macos.yml` | Does static-php-cli build PHP 8.1–8.5 with the optional extensions (imagick, swoole, pcov, mongodb, memcached, xdebug) as shared `.so` files, portable to Macs without Homebrew? |
| `poc-valkey-windows.yml` | Does Valkey built with MSYS2 survive Flock's use on Windows (fork-based persistence, hard kills, restarts)? |
| `poc-php-ext-windows.yml` | Does php-windows-builder build the extension DLLs (imagick, redis, igbinary, apcu, pcov, mongodb) for PHP 7.4–8.5? |

## Layout

```
packages/<name>/<platform>/   build or packaging script per package and platform
scripts/verify-macos.sh       fails when a Mach-O file links outside macOS or targets macOS > 13
scripts/smoke-*.sh|ps1        smoke tests run against every package before it is published
```

## Licenses

Each published package contains the licenses of the software it bundles in `LICENSES/`.
