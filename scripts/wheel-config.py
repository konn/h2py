#!/usr/bin/env python3
"""Read the H2Py settings of an extension wheel from its ``pyproject.toml``.

The hatchling hook (``hatch_build.py``) and the scripts that build and test a
wheel (``build-wheel.sh``, ``manylinux-wheel.sh``, ``test-wheel.sh``) learn
which module they handle from the ``[tool.h2py]`` table of the wheel's
``pyproject.toml``; this script resolves that table, defaults included, so
that all of them agree.

Usage::

    wheel-config.py [--shell | --json] PYPROJECT

``--shell`` (the default) prints ``h2py_<key>=<value>`` assignments for
``eval``, with ``-`` in a key written ``_`` and ``test-requires`` as an array;
``--json`` prints one object with the keys below, ``name`` and ``wheel-name``.

Every key of ``[tool.h2py]`` is optional:

``module``
    The importable name of the extension module: the ``H2PY_MODULE`` of its C
    file and the name in ``pymodule``; the wheel carries ``<module>.abi3.so``.
    Default: the project's name with each ``-`` and ``.`` replaced by ``_``.
``foreign-library``
    The Cabal ``foreign-library`` that builds the module, ``lib<name>.dylib``
    or ``lib<name>.so``.
    Default: the module's name.
``cabal-package``
    The Cabal package that holds the foreign library.
    Default: the project's name, which must then be a Cabal package name.
``smoke-test``
    Python source that ``build-wheel.sh`` and ``test-wheel.sh`` run in a fresh
    environment with nothing but the wheel and its dependencies installed.
    Default: none.
``tests``
    The ``pytest`` suite that ``test-wheel.sh`` runs against the installed
    wheel, relative to the ``pyproject.toml``.
    Default: none.
``test-requires``
    The requirements ``test-wheel.sh`` installs next to the wheel and its
    dependencies before it runs ``tests``.
    Default: ``["pytest"]``.

``name`` is ``project.name``; ``wheel-name`` is its normalised form, which a
wheel's file name starts with up to case and punctuation.
"""

from __future__ import annotations

import argparse
import json
import keyword
import re
import shlex
import sys
import tomllib
from pathlib import Path

KEYS = ("module", "foreign-library", "cabal-package", "smoke-test", "tests", "test-requires")


class ConfigError(Exception):
    pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="wheel-config",
        description="Print the [tool.h2py] settings of an H2Py extension wheel, defaults included.",
    )
    fmt = parser.add_mutually_exclusive_group()
    fmt.add_argument("--shell", action="store_true", help="h2py_<key>=<value> assignments for eval (the default)")
    fmt.add_argument("--json", action="store_true", help="one JSON object")
    parser.add_argument("pyproject", help="the pyproject.toml of the wheel")
    args = parser.parse_args(argv)
    try:
        config = resolve(Path(args.pyproject))
    except ConfigError as err:
        print(f"wheel-config: {err}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(config, indent=2))
    else:
        print(shell(config))
    return 0


def resolve(pyproject: Path) -> dict[str, object]:
    """The settings of the wheel whose ``pyproject.toml`` is given, defaults filled in."""
    try:
        data = tomllib.loads(pyproject.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as err:
        raise ConfigError(f"cannot read {pyproject}: {err}") from err
    project, tool = data.get("project", {}), data.get("tool", {})
    if not isinstance(project, dict) or not isinstance(tool, dict):
        raise ConfigError(f"project and tool in {pyproject} must be tables")
    name = project.get("name")
    if not isinstance(name, str) or not name:
        raise ConfigError(f"{pyproject} has no project.name")
    table = tool.get("h2py", {})
    if not isinstance(table, dict):
        raise ConfigError(f"tool.h2py in {pyproject} is not a table")
    unknown = sorted(set(table) - set(KEYS))
    if unknown:
        raise ConfigError(f"unknown keys in [tool.h2py] of {pyproject}: {', '.join(unknown)} (known: {', '.join(KEYS)})")

    def string(key: str, default: str | None) -> str | None:
        value = table.get(key, default)
        if value is not None and not isinstance(value, str):
            raise ConfigError(f"tool.h2py.{key} in {pyproject} must be a string")
        return value

    module = string("module", re.sub(r"[-.]", "_", name)) or ""
    if not module.isidentifier() or keyword.iskeyword(module):
        raise ConfigError(f"{module!r} cannot name a Python module; set tool.h2py.module in {pyproject}")
    foreign_library = string("foreign-library", module) or ""
    if not foreign_library or re.search(r"[\s:/]", foreign_library):
        raise ConfigError(f"tool.h2py.foreign-library in {pyproject} is not a Cabal component name: {foreign_library!r}")
    cabal_package = string("cabal-package", name) or ""
    # Cabal's rule: words of letters and digits joined by hyphens, each word
    # with a letter in it.
    words = cabal_package.split("-")
    if not all(w.isalnum() and not w.isdigit() for w in words):
        raise ConfigError(
            f"{cabal_package!r} is not a Cabal package name; set tool.h2py.cabal-package in {pyproject}"
        )
    tests = string("tests", None)
    requires = table.get("test-requires", ["pytest"])
    if not isinstance(requires, list) or not all(isinstance(r, str) for r in requires):
        raise ConfigError(f"tool.h2py.test-requires in {pyproject} must be a list of strings")
    return {
        "name": name,
        "wheel-name": re.sub(r"[-_.]+", "_", name).lower(),
        "module": module,
        "foreign-library": foreign_library,
        "cabal-package": cabal_package,
        "smoke-test": string("smoke-test", None) or "",
        "tests": str((pyproject.resolve().parent / tests).resolve()) if tests else "",
        "test-requires": requires,
    }


def shell(config: dict[str, object]) -> str:
    lines = []
    for key, value in config.items():
        var = "h2py_" + key.replace("-", "_")
        if isinstance(value, list):
            lines.append(f"{var}=({' '.join(shlex.quote(v) for v in value)})")
        else:
            lines.append(f"{var}={shlex.quote(str(value))}")
    return "\n".join(lines)


if __name__ == "__main__":
    sys.exit(main())
