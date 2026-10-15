# Shared helpers for the package scripts (source.sh, mirror.sh, build.sh). Source it:
#   . "$(dirname "$0")/../../scripts/lib.sh"

# fetch <url> <file>: downloads with retries, failing on HTTP errors.
fetch() {
  curl -fsSL --retry 3 --retry-all-errors -o "$2" "$1"
}

# fetch_text <url>: prints a small file (checksum lists, API answers).
fetch_text() {
  curl -fsSL --retry 3 --retry-all-errors "$1"
}

sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
md5_of() { if command -v md5sum >/dev/null; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1"; fi; }

# check_sha256 <file> <expected hex>, check_md5 <file> <expected hex>
check_sha256() {
  local got; got="$(sha256_of "$1")"
  [[ -n "$2" && "$got" == "$2" ]] || { echo "::error::$1: SHA-256 $got, expected ${2:-(none)}" >&2; return 1; }
  echo "✓ $(basename "$1") SHA-256 $got"
}
check_md5() {
  local got; got="$(md5_of "$1")"
  [[ -n "$2" && "$got" == "$2" ]] || { echo "::error::$1: MD5 $got, expected ${2:-(none)}" >&2; return 1; }
  echo "✓ $(basename "$1") MD5 $got"
}

# github_digest <owner/repo> <tag> <asset name>: the SHA-256 GitHub recorded for a release asset.
github_digest() {
  local auth=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl -fsSL --retry 3 "${auth[@]}" "https://api.github.com/repos/$1/releases/tags/$2" \
    | jq -r --arg n "$3" '.assets[] | select(.name == $n) | .digest // "" | sub("^sha256:"; "")'
}

# pack <dir> <archive>: an archive of the directory's contents, tar.gz or zip by extension.
pack() {
  local dir="$1" archive; archive="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
  rm -f "$archive"
  case "$archive" in
    *.tar.gz) tar -C "$dir" -czf "$archive" . ;;
    *.zip) (cd "$dir" && zip -qr -X "$archive" .) ;;
    *) echo "unknown archive type: $archive" >&2; return 1 ;;
  esac
}

# mariadb_sha256 <version> <file name>: the SHA-256 MariaDB's downloads API lists for a file.
mariadb_sha256() {
  fetch_text "https://downloads.mariadb.org/rest-api/mariadb/$1/" \
    | jq -r --arg v "$1" --arg n "$2" '.release_data[$v].files[] | select(.file_name == $n) | .checksum.sha256sum'
}

# mysql_fetch <version> <file name> <out>: downloads a MySQL release file from the CDN (current
# releases, with an MD5 we check) or the archives (older ones, no checksum: the binaries' Oracle
# code signatures are checked by the smoke test instead).
mysql_fetch() {
  local line="${1%.*}" url
  for url in "https://cdn.mysql.com/Downloads/MySQL-$line/$2" \
             "https://cdn.mysql.com/archives/mysql-$line/$2" \
             "https://downloads.mysql.com/archives/get/p/23/file/$2"; do
    if fetch "$url" "$3" 2>/dev/null; then
      local md5
      if md5="$(fetch_text "$url.md5" 2>/dev/null | cut -d' ' -f1)" && [[ -n "$md5" ]]; then
        check_md5 "$3" "$md5"
      else
        echo "::notice::$2: no MD5 published (archived release)"
      fi
      echo "downloaded $url"
      return 0
    fi
  done
  echo "::error::$2 not found on the MySQL CDN or archives" >&2
  return 1
}
