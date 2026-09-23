#!/usr/bin/env bash
# Copy the built extension module to build/<name>.abi3.so, the file name CPython imports.
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
name="${1:-h2py_examples}"
suffix="${2:-abi3}"
case "$(uname -s)" in
  Darwin) ext=dylib ;;
  *) ext=so ;;
esac
built="$(find "${root}/dist-newstyle" -name "lib${name}.${ext}" -type f | head -1)"
if [ -z "${built}" ]; then
  echo "install-module: lib${name}.${ext} not found under dist-newstyle; run cabal build first" >&2
  exit 1
fi
mkdir -p "${root}/build"
cp "${built}" "${root}/build/${name}.${suffix}.so"
echo "installed ${root}/build/${name}.${suffix}.so (from ${built})"
