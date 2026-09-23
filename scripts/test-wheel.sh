#!/usr/bin/env bash
# Test a built wheel the way a user gets it.
#
# Usage: scripts/test-wheel.sh PYTHON PLATFORM WHEEL_DIR
#   PYTHON     an interpreter, or uv:VERSION for a uv-managed CPython
#              (a python-build-standalone build, which is what `uv python
#              install` gives users)
#   PLATFORM   the platform tag the wheel must carry, e.g. manylinux_2_28_x86_64
#   WHEEL_DIR  a directory holding exactly one cp312-abi3 wheel of the
#              distribution for it
#
# The wheel goes into a fresh virtual environment with its dependencies and
# nothing else; from a directory that holds no build of the module,
# scripts/check-installed-wheel.py then checks that the module and every
# Haskell library come from the wheel and that the licences and stubs are
# installed, and the smoke test runs.
# Then the suite's requirements are installed, and the pytest suite runs
# against the installed module.
# Which distribution and module, the smoke test, the suite and its
# requirements come from the [tool.h2py] table of the wheel's pyproject.toml
# (scripts/wheel-config.py lists the keys and their defaults).
#
# Environment:
#   H2PY_PACKAGE_DIR  the directory of that pyproject.toml, relative to the
#                     root of the tree (default: h2py-examples/python)
#   UV                the uv executable (default: uv on PATH, then ~/.local/bin/uv)
set -euo pipefail

if [ "$#" -ne 3 ]; then
  sed -n '2,26p' "$0" >&2
  exit 2
fi
python="$1"
platform="$2"
wheels="$(CDPATH= cd -- "$3" && pwd)"
root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
package_dir="${H2PY_PACKAGE_DIR:-h2py-examples/python}"
case "${package_dir}" in
  /*) ;;
  *) package_dir="${root}/${package_dir}" ;;
esac
if [ ! -f "${package_dir}/pyproject.toml" ]; then
  echo "test-wheel: no pyproject.toml in ${package_dir}; set H2PY_PACKAGE_DIR to the packaging directory" >&2
  exit 1
fi
uv="${UV:-$(command -v uv || echo "${HOME}/.local/bin/uv")}"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
case "${python}" in
  uv:*)
    "${uv}" venv --quiet --managed-python --python "${python#uv:}" "${tmp}/venv"
    install() { "${uv}" pip install --quiet --python "${tmp}/venv/bin/python" "$@"; }
    ;;
  *)
    "${python}" -m venv "${tmp}/venv"
    install() { "${tmp}/venv/bin/python" -m pip install --quiet --disable-pip-version-check "$@"; }
    ;;
esac
venv_python="${tmp}/venv/bin/python"

# h2py_name, h2py_wheel_name, h2py_module, h2py_smoke_test, h2py_tests, h2py_test_requires
config="$("${venv_python}" -I "${root}/scripts/wheel-config.py" --shell "${package_dir}/pyproject.toml")"
eval "${config}"

# A wheel's file name spells the distribution with its punctuation escaped
# and its case kept, so the names are compared normalised.
matches=()
for candidate in "${wheels}"/*-cp312-abi3-"${platform}".whl; do
  [ -f "${candidate}" ] || continue
  base="$(basename "${candidate}")"
  if [ "$(printf '%s' "${base%%-*}" | tr 'A-Z' 'a-z' | sed -E 's/[-_.]+/_/g')" = "${h2py_wheel_name}" ]; then
    matches+=("${candidate}")
  fi
done
if [ "${#matches[@]}" -ne 1 ]; then
  echo "test-wheel: expected one cp312-abi3-${platform} wheel of ${h2py_name} in ${wheels}, found:" >&2
  ls -l "${wheels}" >&2
  exit 1
fi
wheel="${matches[0]}"
echo "test-wheel: $(basename "${wheel}") on $("${venv_python}" -c 'import sys, sysconfig; print(sys.version.split()[0], sysconfig.get_platform())') (${python})"

# The wheel with the dependencies its metadata declares, as a user gets it.
install "${wheel}"

cd "${tmp}"
"${venv_python}" "${root}/scripts/check-installed-wheel.py" "${h2py_name}" "${h2py_module}"
if [ -n "${h2py_smoke_test}" ]; then
  echo "test-wheel: running the smoke test of ${h2py_name}"
  "${venv_python}" -c "${h2py_smoke_test}"
fi
if [ -n "${h2py_tests}" ]; then
  if [ "${#h2py_test_requires[@]}" -gt 0 ]; then
    install "${h2py_test_requires[@]}"
  fi
  "${venv_python}" -m pytest -q -p no:cacheprovider "${h2py_tests}"
else
  echo "test-wheel: ${h2py_name} has no [tool.h2py] tests; nothing more to run"
fi
