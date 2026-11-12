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

  # Our patches: third_party/patches/<name>-*.diff, applied in file-name order with `patch -p1`. The extracted tree
  # remembers which set it carries (.patches); a tree extracted before the set changed is extracted again.
  patches=""
  for p in "$ROOT"/third_party/patches/"$name"-*.diff; do
    if [ -f "$p" ]; then patches="$patches $p"; fi
  done
  if [ -n "$patches" ]; then
    # shellcheck disable=SC2086
    patchsum="$(cat $patches | shasum -a 256 | awk '{print $1}')"
  else
    patchsum="none"
  fi
  if [ -d "$src" ] && [ "$(cat "$src/.patches" 2>/dev/null || echo none)" != "$patchsum" ]; then
    log "$name: patch set changed, extracting again"
    rm -rf "$src"
  fi

  if [ ! -d "$src" ]; then
    tmp="$BUILD/src/.extract-$name-$version"
    rm -rf "$tmp"; mkdir -p "$tmp"
    tar -xf "$file" -C "$tmp" --strip-components=1
    for p in $patches; do
      log "$name: apply $(basename "$p")"
      patch -p1 -s -d "$tmp" < "$p" || die "$name: $(basename "$p") does not apply to the pinned archive"
    done
    echo "$patchsum" > "$tmp/.patches"
    mv "$tmp" "$src"
  fi
done
