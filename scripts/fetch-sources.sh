#!/bin/bash
# Downloads every source listed in third_party/sources.lock, verifies SHA-256 and the
# publisher's signature, and extracts it to build/src/<name>-<version>.
# Downloaded files are untrusted until both checks pass.
source "$(dirname "$0")/lib/common.sh"

grep -v '^#' "$ROOT/third_party/sources.lock" | while IFS=$'\t' read -r name version url sha sigurl fpr keyurl; do
  [ -n "${name:-}" ] || continue
  dl="$BUILD/downloads/$name-$version"
  src="$BUILD/src/$name-$version"
  file="$dl/$(basename "$url")"
  mkdir -p "$dl" "$BUILD/src"

  if [ ! -f "$file" ]; then
    log "download $name $version"
    curl -fL --silent --show-error -o "$file" "$url"
  fi

  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  [ "$actual" = "$sha" ] || die "$name: SHA-256 mismatch (expected $sha, got $actual)"

  if [ -n "${sigurl:-}" ]; then
    [ -f "$file.asc" ] || curl -fL --silent --show-error -o "$file.asc" "$sigurl"
    export GNUPGHOME="$BUILD/gnupg"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
    [ -f "$dl/key.asc" ] || curl -fL --silent --show-error -o "$dl/key.asc" "$keyurl"
    gpg --batch --quiet --import "$dl/key.asc" 2>/dev/null
    signer="$(gpg --batch --status-fd 1 --verify "$file.asc" "$file" 2>/dev/null | awk '/VALIDSIG/ {print $NF}')"
    [ "$signer" = "$fpr" ] || die "$name: signature not made by the pinned key (got '${signer:-none}')"
  fi
  log "$name $version verified (sha256${sigurl:+ + signature})"

  if [ ! -d "$src" ]; then
    tmp="$BUILD/src/.extract-$name-$version"
    rm -rf "$tmp"; mkdir -p "$tmp"
    tar -xf "$file" -C "$tmp" --strip-components=1
    mv "$tmp" "$src"
  fi
done
