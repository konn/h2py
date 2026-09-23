"""The hatchling build hook of the ``h2py-examples`` wheel.

Building the wheel means building the Haskell extension module, so the hook
drives ``cabal`` from the repository root (two directories up) and then puts
the extension and its stubs at the top level of the wheel:

- ``h2py_examples.abi3.so``: the ``foreign-library`` that Cabal built, renamed
  to the file name CPython imports (a ``.so`` on macOS too, as CPython
  expects);
- the type stubs, written by ``scripts/h2py-stubs.py`` after importing the
  built module once in a subprocess: the stub-only package
  ``h2py_examples-stubs/`` (``__init__.pyi``, one ``.pyi`` per submodule and
  ``py.typed``) that PEP 561 gives to a module with submodules, or
  ``h2py_examples.pyi`` and ``py.typed`` for a module without any.

The wheel is tagged ``cp312-abi3-<platform>`` because the module is built
against the limited API at 3.12 (``Py_LIMITED_API = 0x030C0000``).
The build interpreter (``sys.executable``) is the one whose headers the module
is compiled against; ``scripts/configure-python.sh`` records its include
directory in ``cabal.project.local``.

The wheel that leaves this hook still refers to the Haskell runtime libraries
by absolute ``@rpath`` entries; ``scripts/build-wheel.sh`` runs
``delocate-wheel`` (macOS) or ``auditwheel`` (Linux) afterwards to bundle them.

Environment variables:

- ``H2PY_MODULE`` (default ``h2py_examples``): the module to package.
- ``H2PY_ABI`` (default ``abi3``): ``abi3`` or ``abi3t``, which selects the
  extension suffix and the wheel tag.
- ``H2PY_SKIP_CABAL``: when set, the hook does not run ``cabal build`` and
  packages whatever ``dist-newstyle`` already holds.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import sysconfig
from pathlib import Path
from typing import Any

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class H2PyBuildHook(BuildHookInterface):  # type: ignore[type-arg]
    PLUGIN_NAME = "custom"

    def initialize(self, version: str, build_data: dict[str, Any]) -> None:
        if self.target_name != "wheel":
            return

        module = os.environ.get("H2PY_MODULE", "h2py_examples")
        abi = os.environ.get("H2PY_ABI", "abi3")
        if abi not in ("abi3", "abi3t"):
            raise ValueError(f"H2PY_ABI must be abi3 or abi3t, not {abi!r}")

        python_dir = Path(self.root).resolve()
        repo = python_dir.parent.parent
        scripts = repo / "scripts"
        if not (scripts / "configure-python.sh").is_file():
            raise RuntimeError(
                f"{python_dir} is not inside a checkout of the h2py repository; "
                "the wheel can only be built from one"
            )

        stage = python_dir / "build" / "stage"
        if stage.exists():
            shutil.rmtree(stage)
        stage.mkdir(parents=True)

        if not os.environ.get("H2PY_SKIP_CABAL"):
            self.app.display_info(f"h2py: configuring for {sys.executable}")
            _run([str(scripts / "configure-python.sh"), sys.executable], cwd=repo)
            self.app.display_info("h2py: cabal build h2py-examples")
            _run(["cabal", "build", "h2py-examples"], cwd=repo)

        built = _find_built_library(repo, module)
        ext_name = f"{module}.{abi}.so"
        ext_path = stage / ext_name
        shutil.copy2(built, ext_path)
        self.app.display_info(f"h2py: {built} -> {ext_name}")

        stub_files = _write_stubs(scripts, stage, module)
        for path in stub_files:
            self.app.display_info(f"h2py: stub {path.relative_to(stage)}")

        build_data["pure_python"] = False
        build_data["infer_tag"] = False
        build_data["tag"] = _wheel_tag(abi)
        force_include = build_data.setdefault("force_include", {})
        force_include[str(ext_path)] = ext_name
        for path in stub_files:
            force_include[str(path)] = path.relative_to(stage).as_posix()


def _run(cmd: list[str], cwd: Path) -> None:
    subprocess.run(cmd, cwd=str(cwd), check=True)


def _find_built_library(repo: Path, module: str) -> Path:
    ext = "dylib" if sys.platform == "darwin" else "so"
    name = f"lib{module}.{ext}"
    candidates = [p for p in (repo / "dist-newstyle").rglob(name) if p.is_file()]
    if not candidates:
        raise RuntimeError(f"{name} not found under {repo / 'dist-newstyle'}; did cabal build fail?")
    # The newest one wins when several configurations have been built.
    return max(candidates, key=lambda p: p.stat().st_mtime)


def _write_stubs(scripts: Path, stage: Path, module: str) -> list[Path]:
    """Write the stubs of the staged module with ``scripts/h2py-stubs.py``.

    The script imports the module and writes the same files the command line
    does (``<module>-stubs/`` with submodules, ``<module>.pyi`` without), next
    to the staged extension; the paths written are returned.
    A subprocess, because the module starts a GHC runtime that is never shut
    down, and because the build interpreter must not keep the module loaded
    while the wheel is being written.
    """
    before = _files_under(stage)
    subprocess.run(
        [
            sys.executable,
            str(scripts / "h2py-stubs.py"),
            "--path",
            str(stage),
            "--output",
            str(stage),
            module,
        ],
        cwd=str(stage),
        check=True,
    )
    written = sorted(_files_under(stage) - before)
    if not written:
        raise RuntimeError(f"h2py-stubs.py wrote no stub for {module} under {stage}")
    return written


def _files_under(root: Path) -> set[Path]:
    return {p for p in root.rglob("*") if p.is_file()}


def _wheel_tag(abi: str) -> str:
    platform_tag = sysconfig.get_platform().replace("-", "_").replace(".", "_")
    if abi == "abi3t":
        # PEP 803: the free-threaded stable ABI, CPython 3.15 and later.
        return f"cp315-abi3t-{platform_tag}"
    return f"cp312-abi3-{platform_tag}"
