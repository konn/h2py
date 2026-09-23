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
The platform is the one the module was built for, not the interpreter's:
on macOS it is ``macosx_<target>_<arch>``, with the deployment target that
``cabal.project`` passes to GHC's C compiler, assembler and linker and the
architecture of the built library, because a python.org interpreter reports
``macosx-10.13-universal2`` while GHC builds one architecture; on Linux it is
``linux_<arch>``, which auditwheel replaces with the manylinux tag.
The build interpreter (``sys.executable``) is the one whose headers the module
is compiled against; ``scripts/configure-python.sh`` records its include
directory in ``cabal.project.local``.

Before packaging, ``scripts/wheel-licenses.py --check`` compares the licence
files that ``project.license-files`` lists (``LICENSE`` and
``third-party-licenses/``) with the libraries the build plan links in, and the
build fails when a bundled library has no licence text.

The wheel that leaves this hook still refers to the Haskell runtime libraries
by absolute ``@rpath`` entries; ``scripts/build-wheel.sh`` runs
``delocate-wheel`` (macOS) or ``auditwheel`` (Linux) afterwards to bundle them.

Environment variables:

- ``H2PY_MODULE`` (default ``h2py_examples``): the module to package.
- ``H2PY_ABI`` (default ``abi3``): ``abi3`` or ``abi3t``, which selects the
  extension suffix and the wheel tag.
- ``H2PY_SKIP_CABAL``: when set, the hook does not run ``cabal build`` and
  packages whatever ``dist-newstyle`` already holds.
- ``MACOSX_DEPLOYMENT_TARGET``: must agree with ``cabal.project`` when set;
  the tag always follows ``cabal.project``.
"""

from __future__ import annotations

import os
import re
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
        _check_licences(repo, scripts, python_dir, module)
        ext_name = f"{module}.{abi}.so"
        ext_path = stage / ext_name
        shutil.copy2(built, ext_path)
        self.app.display_info(f"h2py: {built} -> {ext_name}")

        stub_files = _write_stubs(scripts, stage, module)
        for path in stub_files:
            self.app.display_info(f"h2py: stub {path.relative_to(stage)}")

        build_data["pure_python"] = False
        build_data["infer_tag"] = False
        build_data["tag"] = _wheel_tag(abi, repo, built)
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


def _check_licences(repo: Path, scripts: Path, python_dir: Path, module: str) -> None:
    """Fail the build when a library the module links in has no licence file."""
    _run(
        [
            sys.executable,
            str(scripts / "wheel-licenses.py"),
            "--check",
            "--plan",
            str(repo / "dist-newstyle" / "cache" / "plan.json"),
            "--licenses",
            str(python_dir / "third-party-licenses"),
            "--pyproject",
            str(python_dir / "pyproject.toml"),
            f"flib:{module}",
        ],
        cwd=repo,
    )


def _wheel_tag(abi: str, repo: Path, built: Path) -> str:
    python_tag = "cp315" if abi == "abi3t" else "cp312"
    return f"{python_tag}-{abi}-{_platform_tag(repo, built)}"


def _platform_tag(repo: Path, built: Path) -> str:
    """The platform the module was built for."""
    if sys.platform != "darwin":
        return sysconfig.get_platform().replace("-", "_").replace(".", "_")
    target = macos_deployment_target(repo)
    requested = os.environ.get("MACOSX_DEPLOYMENT_TARGET")
    if requested and _macos_version(requested) != _macos_version(target):
        raise RuntimeError(
            f"MACOSX_DEPLOYMENT_TARGET={requested} but cabal.project builds for macOS {target}; "
            "unset it or change both"
        )
    major, minor = _macos_version(target)
    archs = subprocess.run(["lipo", "-archs", str(built)], capture_output=True, text=True, check=True).stdout.split()
    if len(archs) != 1:
        raise RuntimeError(f"{built} holds architectures {archs}; H2Py wheels hold exactly one")
    return f"macosx_{major}_{minor}_{archs[0]}"


def macos_deployment_target(repo: Path) -> str:
    """The -mmacosx-version-min that cabal.project passes to GHC on macOS."""
    found = set(re.findall(r"-mmacosx-version-min=([0-9]+(?:\.[0-9]+)?)", (repo / "cabal.project").read_text()))
    if len(found) != 1:
        raise RuntimeError(f"cabal.project must set one macOS deployment target, not {sorted(found)}")
    return found.pop()


def _macos_version(text: str) -> tuple[int, int]:
    parts = [int(part) for part in text.split(".")]
    if len(parts) > 2 and any(parts[2:]):
        raise RuntimeError(f"macOS deployment target {text}: patch versions are not supported")
    version = (parts[0], parts[1] if len(parts) > 1 else 0)
    # From macOS 11 on, a wheel tag names the major version only, so a target
    # with a minor version cannot be expressed: 11.3 would be tagged 11_0.
    if version[0] >= 11 and version[1] != 0:
        raise RuntimeError(f"macOS deployment target {text}: from macOS 11 on it must be a major version (11.0, 12.0, ...)")
    return version
