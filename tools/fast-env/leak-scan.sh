#!/usr/bin/env bash
# leak-scan.sh BLOB FILE... — fail-closed credential-form tripwire.
#
# Exits 1 (naming the offending file) when the HTTP-Basic blob BLOB appears
# in any FILE; exits 0 otherwise. Skips missing files.
#
# Why blobs, not literal passwords: with fixed test-only creds (bfm/bfm) the
# literal is public and ubiquitous in logs, while its secret-bearing form —
# the base64 Basic blob the HTTP clients actually send — must never be stored.
set -euo pipefail

blob="${1:-}"; shift || true
[ -n "$blob" ] || { echo "leak-scan.sh: usage: leak-scan.sh BLOB FILE..." >&2; exit 2; }
rc=0
for f in "$@"; do
  [ -f "$f" ] || continue
  if grep -qF -- "$blob" "$f" 2>/dev/null; then
    echo "leak-scan: credential blob present in stored log $f (pre-storage redaction failed; refusing)" >&2
    rc=1
  fi
done
exit "$rc"
