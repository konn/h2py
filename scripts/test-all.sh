#!/usr/bin/env bash
# Build everything, run the Haskell suite, check the weak references, install
# the module, run the Python suite, and check the rendered stubs against the
# committed copy; the typing-fail check runs when present.
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"
cabal build all
cabal test all
if [ "$(uname -s)" = Darwin ]; then
  scripts/gen-weakapi.sh --check
fi
if [ -x scripts/check-typing-fail.sh ]; then
  scripts/check-typing-fail.sh
fi
scripts/install-module.sh
PYTHONPATH="${root}/build" "${root}/.venv/bin/python" -m pytest -q h2py-examples/tests "$@"
"${root}/.venv/bin/python" scripts/h2py-stubs.py --path build --output build h2py_examples
"${root}/.venv/bin/python" -m mypy --strict build/h2py_examples-stubs
"${root}/.venv/bin/python" scripts/h2py-stubs.py --path build --check h2py-examples/stubs h2py_examples
