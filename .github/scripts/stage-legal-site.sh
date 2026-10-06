#!/usr/bin/env bash
# Validates legal-site/ (or any given source dir) against an allow-list and
# copies ONLY the entries that pass into a fresh destination directory.
#
# This replaces a symlink-only deny-list check: that check only ever
# special-cased one bad entry type (symlinks) and would miss anything else
# unusual that landed in the directory. This script instead allow-lists
# exactly what's safe to publish — a regular file, not hard-linked, with an
# approved extension, under no dotfile/hidden path component — and refuses
# (fails closed) on everything else: symlinks, hardlinks, device/FIFO/socket
# nodes, nested .git directories, dotfiles, and disallowed extensions.
#
# Usage: stage-legal-site.sh SRC_DIR DEST_DIR
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 SRC_DIR DEST_DIR" >&2
  exit 2
fi

SRC="$1"
DEST="$2"

if [ ! -d "$SRC" ]; then
  echo "Refusing: source directory does not exist: $SRC" >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"

ALLOWED_EXT_REGEX='\.(html|css|js|png|svg|ico)$'
fail=0
copied=0

while IFS= read -r -d '' entry; do
  rel="${entry#"$SRC"/}"

  # Reject dotfiles/hidden entries anywhere in the path — this is also how
  # a nested .git directory (legal-site/**/.git) gets refused, since every
  # path component of it starts with a dot.
  case "/$rel" in
    */.*)
      echo "Refusing: dotfile or hidden entry: $entry" >&2
      fail=1
      continue
      ;;
  esac

  if [ -L "$entry" ]; then
    echo "Refusing: symlink: $entry" >&2
    fail=1
    continue
  fi

  if [ -d "$entry" ]; then
    # Directories are walked into by find; nothing to copy for the
    # directory node itself (files under it create their own parent dirs
    # in DEST below).
    continue
  fi

  if [ ! -f "$entry" ]; then
    echo "Refusing: not a regular file (device, FIFO, socket, or other special file): $entry" >&2
    fail=1
    continue
  fi

  links="$(stat -c '%h' "$entry" 2>/dev/null || stat -f '%l' "$entry")"
  if [ "${links:-1}" -gt 1 ]; then
    echo "Refusing: hard-linked file (link count $links, may alias content outside $SRC): $entry" >&2
    fail=1
    continue
  fi

  if ! printf '%s' "$rel" | grep -Eqi "$ALLOWED_EXT_REGEX"; then
    echo "Refusing: disallowed file extension: $entry" >&2
    fail=1
    continue
  fi

  mkdir -p "$DEST/$(dirname "$rel")"
  cp --no-dereference --preserve=mode,timestamps "$entry" "$DEST/$rel"
  copied=$((copied + 1))
done < <(find "$SRC" -mindepth 1 -print0)

if [ "$fail" -ne 0 ]; then
  echo "Refusing to publish: $SRC contains one or more disallowed entries (see above)." >&2
  exit 1
fi

if [ "$copied" -eq 0 ]; then
  echo "Refusing to publish: $SRC produced zero allow-listed files to stage." >&2
  exit 1
fi

echo "Staged $copied file(s) from $SRC into $DEST." >&2
