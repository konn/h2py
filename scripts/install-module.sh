#!/usr/bin/env bash
# Copy the built extension module to build/<name>.abi3.so, the file name CPython imports.
# Usage: scripts/install-module.sh [module] [suffix] [foreign-library]
#   module           the importable name (default: h2py_examples)
#   suffix           abi3 or abi3t (default: abi3)
#   foreign-library  the Cabal foreign-library that builds it (default: the module's name)
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
name="${1:-h2py_examples}"
suffix="${2:-abi3}"
flib="${3:-${name}}"
case "$(uname -s)" in
  Darwin) ext=dylib ;;
  *) ext=so ;;
esac
# The newest build, as hatch_build.py takes it, should several configurations exist.
built="$(find "${root}/dist-newstyle" -name "lib${flib}.${ext}" -type f -exec ls -t {} + 2>/dev/null | head -1)"
if [ -z "${built}" ]; then
  echo "install-module: lib${flib}.${ext} not found under dist-newstyle; run cabal build first" >&2
  exit 1
fi
mkdir -p "${root}/build"
# A new file, not an overwrite: macOS kills a process that maps a signed
# binary whose file was rewritten in place after it had been loaded.
cp "${built}" "${root}/build/${name}.${suffix}.so.tmp"
mv -f "${root}/build/${name}.${suffix}.so.tmp" "${root}/build/${name}.${suffix}.so"
echo "installed ${root}/build/${name}.${suffix}.so (from ${built})"
