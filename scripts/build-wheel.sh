#!/usr/bin/env bash
# Build the wheel of an H2Py extension module, h2py-examples unless
# H2PY_PACKAGE_DIR names another, bundle the Haskell runtime libraries into
# it, and verify it in a fresh virtual environment.
#
# The packaging directory holds the wheel's pyproject.toml, whose [tool.h2py]
# table names the module, its foreign library and its Cabal package
# (scripts/wheel-config.py lists the keys and their defaults), the hatchling
# hook hatch_build.py, build-requirements.txt (the build tools, locked with
# hashes) and the licence files.
#
# 1. `python -m build --wheel <packaging directory>` runs the hatchling hook,
#    which runs cabal, renames the foreign library to <module>.abi3.so, writes
#    the stub package <module>-stubs/ with scripts/h2py-stubs.py, and tags the
#    wheel cp312-abi3-<platform>.
#    The wheel is built straight from the source tree, never from an sdist,
#    because the Haskell sources live outside the packaging directory.
# 2. delocate-wheel (macOS) or auditwheel (Linux), in a staging directory,
#    copies every non-system
#    dylib/.so the module links against, transitively, into the wheel and
#    rewrites the install names / rpaths to point at the bundled copies.
#    On macOS that is libHSh2py, libHSpure-borrow, libHSlinear-base, the GHC
#    boot libraries and libHSrts; libffi, libiconv and libSystem come from the
#    OS and are left alone.
# 3. A throwaway venv installs the repaired wheel, and
#    scripts/check-installed-wheel.py checks that the module and every Haskell
#    library come from the wheel, and that the licences and stubs are there;
#    then the smoke test of [tool.h2py], if any, runs there.
#
# On macOS the deployment target comes from cabal.project, which passes it to
# GHC's C compiler, assembler and linker; MACOSX_DEPLOYMENT_TARGET is set to
# the same version so that delocate rejects any library built for a newer
# macOS, and the objects of the local packages are checked as well, because
# GHC does not recompile a module when only those options change.
#
# On Linux, run it inside a manylinux image (scripts/manylinux-wheel.sh does)
# and set H2PY_AUDITWHEEL_PLAT to the policy of that image.
#
# Usage: scripts/build-wheel.sh [python]
#   python   the interpreter to build against; defaults to .venv/bin/python
#            and then to H2PY_PYTHON.
# Environment:
#   H2PY_PACKAGE_DIR the packaging directory, relative to the root of the tree
#                    (default: h2py-examples/python)
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
package_dir="${H2PY_PACKAGE_DIR:-h2py-examples/python}"
case "${package_dir}" in
  /*) ;;
  *) package_dir="${root}/${package_dir}" ;;
esac
if [ ! -f "${package_dir}/pyproject.toml" ]; then
  echo "build-wheel: no pyproject.toml in ${package_dir}; set H2PY_PACKAGE_DIR to the packaging directory" >&2
  exit 1
fi
# h2py_name, h2py_module, h2py_foreign_library, h2py_smoke_test, ...
config="$("${python}" -I "${root}/scripts/wheel-config.py" --shell "${package_dir}/pyproject.toml")"
eval "${config}"

if [ "$(uname -s)" = Darwin ]; then
  target="$(grep -o -- '-mmacosx-version-min=[0-9.]*' cabal.project | sort -u | cut -d= -f2)"
  if [ -z "${target}" ] || [ "$(printf '%s\n' "${target}" | wc -l)" -ne 1 ]; then
    echo "build-wheel: cabal.project must set exactly one -mmacosx-version-min" >&2
    exit 1
  fi
  if [ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ] && [ "${MACOSX_DEPLOYMENT_TARGET}" != "${target}" ]; then
    echo "build-wheel: MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} but cabal.project targets ${target}" >&2
    exit 1
  fi
  export MACOSX_DEPLOYMENT_TARGET="${target}"
fi
wheelhouse="${H2PY_WHEEL_DIR:-${root}/build/wheelhouse}"
raw="${root}/build/wheel-raw"
# The wheel is repaired and checked in a staging directory, and moved into the
# wheelhouse only once every check has passed, so that no wheel with a release
# name stays behind from a failed build.
stage="$(mktemp -d "${TMPDIR:-/tmp}/h2py-stage.XXXXXX")"
tmp=""
trap 'rm -rf "${stage}" ${tmp:+"${tmp}"}' EXIT
rm -rf "${raw}"
mkdir -p "${raw}" "${wheelhouse}"

# The build front end and the repair tools live in the build interpreter's
# environment, at the versions build-requirements.txt in the packaging
# directory locks with hashes.
# Every Python step runs isolated (-I): the build/ directory at the root of
# the tree would otherwise pass for the `build` package.
lock="${package_dir}/build-requirements.txt"
echo "build-wheel: installing the wheel tools into $(dirname "${python}") from ${lock##*/}"
"${uv}" pip install --quiet --python "${python}" --require-hashes -r "${lock}"

echo "build-wheel: building the wheel of ${h2py_name} (module ${h2py_module}) with ${python}"
# --no-isolation: hatchling is already in the environment, and the hook wants
# the interpreter whose headers cabal.project.local names, not a copy of it.
"${python}" -I -m build --wheel --no-isolation --outdir "${raw}" "${package_dir}"
wheel="$(ls "${raw}"/*.whl | head -1)"
echo "build-wheel: raw wheel ${wheel} ($(du -h "${wheel}" | cut -f1))"

if [ "$(uname -s)" = Darwin ]; then
  # A module object compiled before the target changed keeps the old minimum
  # version inside the linked library, where delocate cannot see it.
  newer="$(find dist-newstyle/build -type f \( -name '*.o' -o -name '*.dyn_o' \) \
      -not -path '*/t/*' -not -path '*/x/*' -not -path '*/b/*' -print0 \
    | xargs -0 otool -l 2>/dev/null \
    | awk -v target="${MACOSX_DEPLOYMENT_TARGET}" '
        /^[^ \t].*:$/ { file = substr($0, 1, length($0) - 1) }
        $1 == "minos" { split($2, v, "."); split(target, t, ".");
                        if (v[1] + 0 > t[1] + 0 || (v[1] + 0 == t[1] + 0 && v[2] + 0 > t[2] + 0)) print file " (" $2 ")" }')"
  if [ -n "${newer}" ]; then
    echo "build-wheel: these objects were built for a macOS newer than ${MACOSX_DEPLOYMENT_TARGET}:" >&2
    echo "${newer}" | head -20 >&2
    echo "build-wheel: remove dist-newstyle/build and build again" >&2
    exit 1
  fi
fi

case "$(uname -s)" in
  Darwin)
    # delocate resolves the @rpath references through the LC_RPATH entries
    # that GHC wrote into the foreign library (the cabal store and the GHC
    # library directory), so no DYLD_LIBRARY_PATH is needed.
    # With MACOSX_DEPLOYMENT_TARGET set (above, from cabal.project), delocate
    # refuses any bundled library whose minimum macOS is newer than the
    # target, and keeps the tag the hatch hook computed from it.
    "${python}" -I -m delocate.cmd.delocate_wheel -w "${stage}" -v "${wheel}"
    ;;
  *)
    # auditwheel repairs against the manylinux policy of the image the build
    # runs in (H2PY_AUDITWHEEL_PLAT, which scripts/manylinux-wheel.sh sets from
    # the image); --only-plat keeps it from adding any other tag.
    "${python}" -I -m auditwheel repair -w "${stage}" \
      ${H2PY_AUDITWHEEL_PLAT:+--plat "${H2PY_AUDITWHEEL_PLAT}" --only-plat} "${wheel}"
    ;;
esac
repaired="$(ls "${stage}"/*.whl | head -1)"
echo "build-wheel: repaired wheel $(basename "${repaired}") ($(du -h "${repaired}" | cut -f1))"

# Every library the repair tool bundled has its licence in the wheel.
"${python}" -I "${root}/scripts/wheel-licenses.py" --check-wheel "${repaired}" \
  --licenses "${package_dir}/third-party-licenses" \
  --pyproject "${package_dir}/pyproject.toml" --module "${h2py_module}" "flib:${h2py_foreign_library}"

if [ "$(uname -s)" != Darwin ]; then
  # glibc 2.41 and later refuse to load a library that asks for an executable
  # stack, which a library without a GNU_STACK header does on x86_64, so every
  # shared library in the wheel must have exactly one, without the E flag.
  unpacked="${stage}/unpacked"
  mkdir -p "${unpacked}"
  unzip -q "${repaired}" -d "${unpacked}"
  bad=""
  while IFS= read -r -d '' lib; do
    if ! headers="$(readelf -lW "${lib}")"; then
      bad="${bad}${lib}: readelf failed"$'\n'
      continue
    fi
    stacks="$(printf '%s\n' "${headers}" | awk '$1 == "GNU_STACK" { print $(NF - 1) }')"
    if [ "$(printf '%s' "${stacks}" | grep -c .)" -ne 1 ] || printf '%s' "${stacks}" | grep -q E; then
      bad="${bad}${lib}: GNU_STACK [${stacks}]"$'\n'
    fi
  done < <(find "${unpacked}" -type f -name '*.so*' -print0)
  if [ -n "${bad}" ]; then
    echo "build-wheel: these libraries ask for an executable stack, or cannot be read:" >&2
    printf '%s' "${bad}" >&2
    exit 1
  fi
  rm -rf "${unpacked}"
fi

if [ -z "${H2PY_SKIP_VERIFY:-}" ]; then
  # Verify in a venv that has nothing but the wheel: the module must import
  # from the bundled libraries alone, away from the cabal store and dist-newstyle.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/h2py-wheel.XXXXXX")"
  "${uv}" venv --quiet --python "${python}" "${tmp}/venv"
  "${uv}" pip install --quiet --python "${tmp}/venv/bin/python" "${repaired}"
  (
    cd "${tmp}"
    "${tmp}/venv/bin/python" "${root}/scripts/check-installed-wheel.py" "${h2py_name}" "${h2py_module}"
    if [ -n "${h2py_smoke_test}" ]; then
      echo "build-wheel: running the smoke test of ${h2py_name}"
      "${tmp}/venv/bin/python" -c "${h2py_smoke_test}"
    fi
  )
fi

# Every check passed: the wheel replaces this distribution's previous ones,
# which are named as it is up to the version and the tags.
wheel_file="$(basename "${repaired}")"
find "${wheelhouse}" -maxdepth 1 -name "${wheel_file%%-*}-*.whl" -delete
mv "${repaired}" "${wheelhouse}/"
rm -rf "${raw}"
echo "build-wheel: ${wheelhouse}/${wheel_file}"
