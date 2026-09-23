#!/usr/bin/env bash
# Build the h2py-examples wheel, bundle the Haskell runtime libraries into it,
# and verify it in a fresh virtual environment.
#
# 1. `python -m build --wheel h2py-examples/python` runs the hatchling hook
#    (h2py-examples/python/hatch_build.py), which runs cabal, renames the
#    foreign library to h2py_examples.abi3.so, writes the stub package
#    h2py_examples-stubs/ with scripts/h2py-stubs.py, and tags the wheel
#    cp312-abi3-<platform>.
#    The wheel is built straight from the source tree, never from an sdist,
#    because the Haskell sources live outside the packaging directory.
# 2. delocate-wheel (macOS) or auditwheel (Linux) copies every non-system
#    dylib/.so the module links against, transitively, into the wheel and
#    rewrites the install names / rpaths to point at the bundled copies.
#    On macOS that is libHSh2py, libHSpure-borrow, libHSlinear-base, the GHC
#    boot libraries and libHSrts; libffi, libiconv and libSystem come from the
#    OS and are left alone.
# 3. A throwaway venv installs the repaired wheel and imports the module.
#
# Usage: scripts/build-wheel.sh [python]
#   python   the interpreter to build against; defaults to .venv/bin/python
#            and then to H2PY_PYTHON.
# Environment:
#   H2PY_WHEEL_DIR   where the repaired wheel lands (default: build/wheelhouse)
#   H2PY_SKIP_VERIFY set to skip the fresh-venv check
#   UV               the uv executable (default: uv on PATH, then ~/.local/bin/uv)
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"

python="${1:-${H2PY_PYTHON:-${root}/.venv/bin/python}}"
if [ ! -x "${python}" ]; then
  echo "build-wheel: no interpreter at ${python}; pass one or set H2PY_PYTHON" >&2
  exit 1
fi
uv="${UV:-$(command -v uv || echo "${HOME}/.local/bin/uv")}"
wheelhouse="${H2PY_WHEEL_DIR:-${root}/build/wheelhouse}"
raw="${root}/build/wheel-raw"
rm -rf "${raw}" "${wheelhouse}"
mkdir -p "${raw}" "${wheelhouse}"

# The build front end and the repair tool live in the build interpreter's
# environment; install them if they are missing (only ever adds packages).
need=()
"${python}" -c 'import build' 2>/dev/null || need+=(build)
"${python}" -c 'import hatchling' 2>/dev/null || need+=(hatchling)
case "$(uname -s)" in
  Darwin) "${python}" -c 'import delocate' 2>/dev/null || need+=(delocate) ;;
  *) "${python}" -c 'import auditwheel' 2>/dev/null || need+=(auditwheel) ;;
esac
if [ "${#need[@]}" -gt 0 ]; then
  echo "build-wheel: installing ${need[*]} into $(dirname "${python}")"
  "${uv}" pip install --python "${python}" "${need[@]}"
fi

echo "build-wheel: building the wheel with ${python}"
# --no-isolation: hatchling is already in the environment, and the hook wants
# the interpreter whose headers cabal.project.local names, not a copy of it.
"${python}" -m build --wheel --no-isolation --outdir "${raw}" "${root}/h2py-examples/python"
wheel="$(ls "${raw}"/*.whl | head -1)"
echo "build-wheel: raw wheel ${wheel} ($(du -h "${wheel}" | cut -f1))"

case "$(uname -s)" in
  Darwin)
    # delocate resolves the @rpath references through the LC_RPATH entries
    # that GHC wrote into the foreign library (the cabal store and the GHC
    # library directory), so no DYLD_LIBRARY_PATH is needed.
    # delocate raises the wheel's macOS platform tag to the highest minimum
    # OS version among the bundled libraries.  Libraries built on this
    # machine without MACOSX_DEPLOYMENT_TARGET carry the host's version (the
    # ghcup bindist's carry 11.0), so for a wheel that installs on older
    # macOS, set MACOSX_DEPLOYMENT_TARGET before building the cabal store
    # and the tree; the tag of the raw wheel comes from the interpreter's
    # own sysconfig platform.
    "${python}" -m delocate.cmd.delocate_wheel -w "${wheelhouse}" -v "${wheel}"
    ;;
  *)
    # auditwheel repairs against a manylinux policy; the Haskell libraries are
    # linked against the build machine's glibc, so the policy that applies is
    # whatever `auditwheel show` reports for that machine, and the tag is
    # chosen accordingly.  --plat must be passed when the default policy is
    # too strict for the build host.
    "${python}" -m auditwheel repair -w "${wheelhouse}" ${H2PY_AUDITWHEEL_PLAT:+--plat "${H2PY_AUDITWHEEL_PLAT}"} "${wheel}"
    ;;
esac
repaired="$(ls "${wheelhouse}"/*.whl | head -1)"
echo "build-wheel: repaired wheel ${repaired} ($(du -h "${repaired}" | cut -f1))"

if [ -n "${H2PY_SKIP_VERIFY:-}" ]; then
  exit 0
fi

# Verify in a venv that has nothing but the wheel: the module must import
# from the bundled libraries alone, away from the cabal store and dist-newstyle.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/h2py-wheel.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
"${uv}" venv --quiet --python "${python}" "${tmp}/venv"
"${uv}" pip install --quiet --python "${tmp}/venv/bin/python" "${repaired}"
(
  cd "${tmp}"
  "${tmp}/venv/bin/python" - <<'EOF'
import h2py_examples, os
assert h2py_examples.Counter(1).get() == 1
assert h2py_examples.add(40, 2) == 42
here = os.path.dirname(h2py_examples.__file__)
stubs = os.path.join(here, "h2py_examples-stubs")
assert os.path.isfile(os.path.join(stubs, "__init__.pyi")), "root stub missing"
assert os.path.isfile(os.path.join(stubs, "shapes.pyi")), "submodule stub missing"
assert os.path.isfile(os.path.join(stubs, "py.typed")), "py.typed missing"
print("build-wheel: verified", h2py_examples.__file__)
EOF
)
