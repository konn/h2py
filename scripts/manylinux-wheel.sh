#!/usr/bin/env bash
# Build the manylinux wheel of h2py-examples inside a PyPA manylinux image.
#
# Run it from the root of the repository, in quay.io/pypa/manylinux_2_28_x86_64
# or quay.io/pypa/manylinux_2_28_aarch64 at the tag CI pins; CI runs it as a
# container job, and locally, with volumes that keep GHC and the cabal store
# between runs and the tree mounted read-only:
#
#     docker run --rm -v "$PWD":/src:ro -v "$PWD/build/wheelhouse-linux":/out \
#       -v h2py-ghc:/opt/ghc -v h2py-cabal:/opt/cabal \
#       -e CABAL_DIR=/opt/cabal -e H2PY_WHEEL_DIR=/out \
#       quay.io/pypa/manylinux_2_28_aarch64:2026.09.14-1 /src/scripts/manylinux-wheel.sh
#
# 1. GHC and cabal-install come from pinned, checksummed bindists built on
#    glibc 2.28 (rocky8 for x86_64, deb10 for aarch64), so that the Haskell
#    libraries the wheel bundles need no newer glibc than the image has.
#    An installation of the right version under the prefix is reused.
# 2. The tree is copied to a work directory, so that the build never touches
#    the dist-newstyle or cabal.project.local of a checkout shared with the
#    host.
# 3. The gmp package of the image must be the one
#    h2py-examples/python/third-party-licenses/GMP-NOTICE.txt names, since
#    auditwheel copies its library into the wheel and the notice says where
#    its source is.
# 4. scripts/build-wheel.sh runs with the image's oldest supported CPython;
#    its auditwheel step bundles the Haskell libraries, libgmp and GHC's
#    libffi and tags the wheel with the image's policy (AUDITWHEEL_PLAT, which
#    every manylinux image sets), and it verifies the wheel in a fresh venv.
#
# With --deps-only it stops after building the Haskell dependencies into the
# cabal store, so that CI can save the store before the wheel steps run.
#
# Environment:
#   H2PY_GHC_PREFIX  where GHC and cabal are installed (default /opt/ghc)
#   H2PY_WORKDIR     the copy of the tree that is built (default /tmp/h2py-build)
#   H2PY_WHEEL_DIR   where the wheel lands (default build/wheelhouse-<policy>)
#   CABAL_DIR        cabal's configuration, package cache and store; cache
#                    its store between runs
set -euo pipefail

deps_only=0
case "${1:-}" in
  --deps-only) deps_only=1 ;;
  "") ;;
  *)
    echo "manylinux-wheel: unknown argument $1" >&2
    exit 2
    ;;
esac

ghc_version=9.12.4
cabal_version=3.14.2.0
case "$(uname -m)" in
  x86_64)
    ghc_dist=x86_64-rocky8-linux
    ghc_sha256=414357ae54a4b978b773f8408ede2ea7fe95dd5ecc9259580860c1446e0ddf31
    cabal_dist=x86_64-linux-rocky8
    cabal_sha256=328d722679199b6e4d5116df1c7cf9281bee94745524344525d538a304e693d9
    ;;
  aarch64)
    ghc_dist=aarch64-deb10-linux
    ghc_sha256=e0e2b536e56f08ee9b6eb9c2c4fe43f8d289257afb786ea8f5538c5c7b252f2f
    cabal_dist=aarch64-linux-deb10
    cabal_sha256=63ee40229900527e456bb71835d3d7128361899c14e691cc7024a5ce17235ec3
    ;;
  *)
    echo "manylinux-wheel: no GHC bindist is pinned for $(uname -m)" >&2
    exit 1
    ;;
esac

: "${AUDITWHEEL_PLAT:?run this inside a manylinux image, which sets AUDITWHEEL_PLAT}"
root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="${H2PY_GHC_PREFIX:-/opt/ghc}"
work="${H2PY_WORKDIR:-/tmp/h2py-build}"
out="${H2PY_WHEEL_DIR:-${root}/build/wheelhouse-${AUDITWHEEL_PLAT}}"
python=/opt/python/cp312-cp312/bin/python
export PATH="${prefix}/bin:${PATH}"
export LANG=C.UTF-8 LC_ALL=C.UTF-8

fetch() {
  local url="$1" sha256="$2" file="$3"
  curl -fsSL --retry 3 -o "${file}" "${url}"
  echo "${sha256}  ${file}" | sha256sum -c --quiet -
}

# GHC's ghc-bignum links the system GMP on Linux; the -devel package has the
# libgmp.so link that linking needs, and auditwheel bundles libgmp.so.10.
# gmp-devel at the version of the image's gmp: a newer one from the live
# mirrors would upgrade gmp itself, away from what the notice names.
gmp_evr="$(rpm -q --qf '%{VERSION}-%{RELEASE}' gmp)"
if ! rpm -q gmp-devel >/dev/null 2>&1; then
  echo "manylinux-wheel: installing gmp-devel-${gmp_evr}"
  dnf install -y -q "gmp-devel-${gmp_evr}"
fi
gmp="gmp $(rpm -q --qf '%{VERSION}-%{RELEASE}' gmp)"
notice="${root}/h2py-examples/python/third-party-licenses/GMP-NOTICE.txt"
if ! grep -qF -- "${gmp} package" "${notice}"; then
  echo "manylinux-wheel: the image has ${gmp}, which ${notice} does not name;" >&2
  echo "manylinux-wheel: update the notice and its source links before building" >&2
  exit 1
fi

if ! command -v "ghc-${ghc_version}" >/dev/null 2>&1; then
  echo "manylinux-wheel: installing GHC ${ghc_version} (${ghc_dist}) into ${prefix}"
  tmp="$(mktemp -d)"
  fetch "https://downloads.haskell.org/~ghc/${ghc_version}/ghc-${ghc_version}-${ghc_dist}.tar.xz" \
    "${ghc_sha256}" "${tmp}/ghc.tar.xz"
  tar -xJf "${tmp}/ghc.tar.xz" -C "${tmp}"
  (
    cd "${tmp}"/ghc-"${ghc_version}"-*/
    ./configure --prefix="${prefix}" >"${tmp}/configure.log" 2>&1 || { tail -30 "${tmp}/configure.log"; exit 1; }
    make install >"${tmp}/install.log" 2>&1 || { tail -30 "${tmp}/install.log"; exit 1; }
  )
  rm -rf "${tmp}"
  # cabal.project.local names the compiler with its version suffix.
  [ -e "${prefix}/bin/ghc-${ghc_version}" ] || ln -s ghc "${prefix}/bin/ghc-${ghc_version}"
  [ -e "${prefix}/bin/ghc-pkg-${ghc_version}" ] || ln -s ghc-pkg "${prefix}/bin/ghc-pkg-${ghc_version}"
fi

if [ "$(cabal --numeric-version 2>/dev/null || true)" != "${cabal_version}" ]; then
  echo "manylinux-wheel: installing cabal-install ${cabal_version} (${cabal_dist}) into ${prefix}/bin"
  tmp="$(mktemp -d)"
  fetch "https://downloads.haskell.org/~cabal/cabal-install-${cabal_version}/cabal-install-${cabal_version}-${cabal_dist}.tar.xz" \
    "${cabal_sha256}" "${tmp}/cabal.tar.xz"
  mkdir -p "${prefix}/bin"
  tar -xJf "${tmp}/cabal.tar.xz" -C "${prefix}/bin" cabal
  rm -rf "${tmp}"
fi
echo "manylinux-wheel: $(ghc-${ghc_version} --version), cabal $(cabal --numeric-version), $(ldd --version | head -1)"

rm -rf "${work}"
mkdir -p "${work}"
tar -C "${root}" --exclude=./dist-newstyle --exclude=./build --exclude=./.venv \
  --exclude=./cabal.project.local -cf - . | tar -C "${work}" -xf -

venv="$(mktemp -d)/venv"
"${python}" -m venv "${venv}"
"${venv}/bin/python" -m pip install -q --disable-pip-version-check uv

cd "${work}"
scripts/configure-python.sh "${venv}/bin/python"
cabal update
if [ "${deps_only}" -eq 1 ]; then
  cabal build --only-dependencies h2py-examples
  echo "manylinux-wheel: the dependencies of h2py-examples are in the cabal store"
  exit 0
fi
H2PY_AUDITWHEEL_PLAT="${AUDITWHEEL_PLAT}" UV="${venv}/bin/uv" H2PY_WHEEL_DIR="${out}" \
  scripts/build-wheel.sh "${venv}/bin/python"
echo "manylinux-wheel: $(ls "${out}"/*.whl)"
