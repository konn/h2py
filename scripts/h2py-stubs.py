#!/usr/bin/env python3
"""``h2py stubs <module>``: write the type stub of an H2Py extension module.

An H2Py module carries its own stub: the hidden ``__h2py_stub__()`` returns a
``.pyi`` rendered from the same description the initialiser registered, so
the stub can never disagree with the module.
This script imports the module and writes ``<module>.pyi`` and a ``py.typed``
marker next to the extension file, which is where a type checker looks for
them once the module is installed.

Usage::

    h2py-stubs.py h2py_examples                 # write next to the extension
    h2py-stubs.py --path build h2py_examples    # after adding build/ to sys.path
    h2py-stubs.py --output DIR h2py_examples    # write into DIR instead
    h2py-stubs.py --check DIR h2py_examples     # exit 1 unless DIR holds the same files

When the module registers submodules (``submodule`` in ``pymodule``), each
one has its own ``__h2py_stub__`` and the stubs are written as a stub-only
package, ``<module>-stubs/__init__.pyi`` plus one ``.pyi`` per submodule,
which is the layout PEP 561 gives to a single-file extension with submodules.

``--check DIR`` renders the same files and compares them with those under
``DIR`` (a committed golden copy, say), writing nothing; a missing or stale
file is reported and the exit status is 1.
``hatch_build.py`` in the packaging directory of ``h2py-examples`` runs this
script with ``--output`` to put the same files into a wheel.
"""

from __future__ import annotations

import argparse
import importlib
import os
import sys
import types
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="h2py stubs",
        description="Write the .pyi stub and py.typed marker of an H2Py extension module.",
    )
    parser.add_argument("module", help="the importable name of the extension module")
    parser.add_argument(
        "--path",
        action="append",
        default=[],
        metavar="DIR",
        help="a directory to prepend to sys.path before importing (repeatable)",
    )
    parser.add_argument(
        "--output",
        metavar="DIR",
        help="write the files here instead of next to the extension",
    )
    parser.add_argument(
        "--check",
        metavar="DIR",
        help="write nothing; compare with the files under DIR and exit 1 if any is missing or stale",
    )
    args = parser.parse_args(argv)

    for directory in reversed(args.path):
        sys.path.insert(0, os.path.abspath(directory))

    module = importlib.import_module(args.module)
    stub = getattr(module, "__h2py_stub__", None)
    if stub is None:
        print(f"h2py stubs: {args.module} is not an H2Py module (no __h2py_stub__)", file=sys.stderr)
        return 2

    module_file = getattr(module, "__file__", None)
    if args.check:
        target = Path(args.check)
    elif args.output:
        target = Path(args.output)
    elif module_file:
        target = Path(module_file).resolve().parent
    else:
        print(f"h2py stubs: {args.module} has no __file__; pass --output", file=sys.stderr)
        return 2

    files = render_all(module, args.module.rsplit(".", 1)[-1], target)

    if args.check:
        return check(files)
    for path in write_all(files):
        print(f"wrote {path}")
    return 0


def render_all(module: types.ModuleType, name: str, target: Path) -> dict[Path, str]:
    """The files to write, as ``{path: contents}``."""
    subs = submodules_of(module)
    if not subs:
        return {
            target / f"{name}.pyi": module.__h2py_stub__(),
            target / "py.typed": "",
        }
    package = target / f"{name}-stubs"
    files = {
        package / "__init__.pyi": module.__h2py_stub__(),
        package / "py.typed": "",
    }
    for sub_name, sub in subs.items():
        files[package / f"{sub_name}.pyi"] = sub.__h2py_stub__()
    return files


def write_all(files: dict[Path, str]) -> list[Path]:
    """Write the rendered files, creating their directories; the paths written."""
    for path, text in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return list(files)


def submodules_of(module: types.ModuleType) -> dict[str, types.ModuleType]:
    """The H2Py submodules registered on a module, by attribute name."""
    found: dict[str, types.ModuleType] = {}
    prefix = module.__name__ + "."
    for attr, value in vars(module).items():
        if (
            isinstance(value, types.ModuleType)
            and value.__name__ == prefix + attr
            and hasattr(value, "__h2py_stub__")
        ):
            found[attr] = value
    return found


def check(files: dict[Path, str]) -> int:
    stale = False
    for path, expected in files.items():
        if not path.is_file():
            print(f"h2py stubs: {path} is missing", file=sys.stderr)
            stale = True
        elif path.read_text(encoding="utf-8") != expected:
            print(f"h2py stubs: {path} is stale", file=sys.stderr)
            stale = True
    if stale:
        print("h2py stubs: rerun with --output DIR in place of --check DIR to regenerate", file=sys.stderr)
        return 1
    print("h2py stubs: up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
