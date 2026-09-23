#!/usr/bin/env bash
# Test a built wheel the way a user gets it.
#
# Usage: scripts/test-wheel.sh PYTHON PLATFORM WHEEL_DIR
#   PYTHON     an interpreter, or uv:VERSION for a uv-managed CPython
#              (a python-build-standalone build, which is what `uv python
#              install` gives users)
#   PLATFORM   the platform tag the wheel must carry, e.g. manylinux_2_28_x86_64
#   WHEEL_DIR  a directory holding exactly one h2py-examples wheel for it
#
# The wheel goes into a fresh virtual environment with numpy and pytest and
# nothing else; scripts/check-installed-wheel.py then checks, from a directory
# that holds no build of the module, that the module and every Haskell library
# come from the wheel and that the licences and stubs are installed, and the
# whole pytest suite runs against the installed module.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  sed -n '2,15p' "$0" >&2
  exit 2
fi
python="$1"
platform="$2"
wheels="$(CDPATH= cd -- "$3" && pwd)"
root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

shopt -s nullglob
matches=("${wheels}"/h2py_examples-*-cp312-abi3-"${platform}".whl)
if [ "${#matches[@]}" -ne 1 ]; then
  echo "test-wheel: expected one cp312-abi3-${platform} wheel in ${wheels}, found:" >&2
  ls -l "${wheels}" >&2
  exit 1
fi
wheel="${matches[0]}"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
case "${python}" in
  uv:*)
    uv venv --quiet --managed-python --python "${python#uv:}" "${tmp}/venv"
    install() { uv pip install --quiet --python "${tmp}/venv/bin/python" "$@"; }
    ;;
  *)
    "${python}" -m venv "${tmp}/venv"
    install() { "${tmp}/venv/bin/python" -m pip install --quiet --disable-pip-version-check "$@"; }
    ;;
esac
venv_python="${tmp}/venv/bin/python"
echo "test-wheel: $(basename "${wheel}") on $("${venv_python}" -c 'import sys, sysconfig; print(sys.version.split()[0], sysconfig.get_platform())') (${python})"

install numpy pytest
install --no-index --no-deps "${wheel}"

cd "${tmp}"
"${venv_python}" "${root}/scripts/check-installed-wheel.py" h2py-examples h2py_examples
"${venv_python}" -m pytest -q -p no:cacheprovider "${root}/h2py-examples/tests"
