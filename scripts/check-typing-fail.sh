#!/usr/bin/env bash
# Check that every fixture under h2py/test/typing-fail fails to compile for the
# expected reason, with the compiler cabal selected for this project.
# Multiplicity errors, Unsatisfiable instance contexts and role refusals behind
# upcast are never deferred to runtime, so they cannot live in the TypingCases
# module of the tasty suite; each fixture states its expected diagnostic in
# `-- EXPECT: <substring>` lines, all of which must appear in the compiler's
# output.
#
# Usage: scripts/check-typing-fail.sh [cabal options...]
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"
cabal_cmd=(cabal "$@")
"${cabal_cmd[@]}" build -v0 h2py
ghc="$("${cabal_cmd[@]}" path -v0 --output-format=json --compiler-info | sed -n 's/.*"path":"\([^"]*\)".*/\1/p')"
if [ -z "${ghc}" ]; then
  echo "check-typing-fail: could not find the cabal-selected compiler" >&2
  exit 1
fi
tmp="$(mktemp -d "${TMPDIR:-/tmp}/h2py-typing-fail.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

# `cabal exec` loads the package environment of this project's plan, which
# exposes exactly one unit of every dependency; naming packages by hand would
# be ambiguous when the store holds several builds of one.
compile() {
  "${cabal_cmd[@]}" exec -v0 -- "${ghc}" \
    -fno-code -fdiagnostics-color=never \
    -XGHC2021 -XBlockArguments -XDataKinds -XDerivingStrategies -XExplicitNamespaces \
    -XLambdaCase -XLinearTypes -XOverloadedStrings -XQualifiedDo -XTypeOperators \
    -outputdir "${tmp}" "$1"
}

# A positive control: the shapes the fixtures deviate from must compile, or a
# failure below would say nothing.
cat > "${tmp}/Positive.hs" <<'HASKELL'
{-# LANGUAGE NoImplicitPrelude #-}
module Positive where

import Control.Functor.Linear qualified as Control
import Control.Monad.Borrow.IO (liftBO)
import Control.Monad.Borrow.Pure (Mut, parBO, share, upcast)
import Data.Ref.Linear (Ref)
import Data.Ref.Linear.Borrow qualified as RefB
import H2Py
import H2Py.Module.Internal (unsafeNewTypeCell)
import Prelude.Linear

newtype Payload = Payload (Ref Int)
  deriving newtype (Consumable)

instance PyClass Payload where
  pyClassName _ = "Payload"
  pyClassTypeCell _ = unsafeNewTypeCell

oneDerefMut :: forall π. Bound π Payload %1 -> Py π π ()
oneDerefMut b = Control.do
  r <- derefMut b
  Control.pure (consume r)

boundUsedOnce :: forall π. Bound π PyAny %1 -> Py π π (PyResult (Bound π PyAny))
boundUsedOnce b = case share b of
  Ur v -> getAttr v "x"

receiverConsumed :: forall π. Mut π Payload %1 -> Int -> Py π π ()
receiverConsumed m k = Control.do
  m' <- RefB.modify (+ k) (upcast m :: Mut π (Ref Int))
  Control.pure (consume m')

pureParInPy :: forall π γ. Py π γ ((), ())
pureParInPy = liftBO (parBO (Control.pure ()) (Control.pure ()))

widen :: forall π. Bound π PyBool %1 -> Bound π PyLong
widen = upcastMut
HASKELL

if ! compile "${tmp}/Positive.hs" > "${tmp}/positive.log" 2>&1; then
  cat "${tmp}/positive.log"
  echo "FAIL: the positive control did not compile." >&2
  exit 1
fi
echo "PASS: the positive control compiles."

status=0
for fixture in h2py/test/typing-fail/*.hs; do
  name="$(basename "${fixture}" .hs)"
  log="${tmp}/${name}.log"
  if compile "${fixture}" > "${log}" 2>&1; then
    echo "FAIL: ${name} unexpectedly compiled." >&2
    status=1
    continue
  fi
  expected="$(sed -n 's/^-- EXPECT: //p' "${fixture}")"
  if [ -z "${expected}" ]; then
    echo "FAIL: ${name} states no expected diagnostic." >&2
    status=1
    continue
  fi
  ok=1
  while IFS= read -r fragment; do
    [ -n "${fragment}" ] || continue
    if ! grep -Fq -- "${fragment}" "${log}"; then
      echo "FAIL: ${name} was rejected, but not for the expected reason (missing: ${fragment})." >&2
      cat "${log}" >&2
      ok=0
      break
    fi
  done <<< "${expected}"
  if [ "${ok}" -eq 1 ]; then
    echo "PASS: ${name} was rejected for the expected reason."
  else
    status=1
  fi
done
exit "${status}"
