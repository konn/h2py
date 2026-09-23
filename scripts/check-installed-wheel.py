#!/usr/bin/env python3
"""Check an installed H2Py extension wheel the way a user gets it.

Usage::

    check-installed-wheel.py DISTRIBUTION MODULE

Run it with the interpreter the wheel was installed into, from a directory
that holds no build of the module.  It fails unless

- the module is imported from the installed distribution, not from a build
  tree on ``sys.path``;
- every Haskell library the process has loaded lies inside the installed
  wheel, so nothing is taken from a cabal store or a GHC installation, and
  the GHC runtime is among them;
- the metadata lists the licence files (``License-File``), the package's own
  licence and the third-party notices among them, and every one is installed
  under ``.dist-info/licenses``;
- the stub package and its ``py.typed`` marker are installed.
"""

from __future__ import annotations

import ctypes
import importlib
import importlib.metadata as metadata
import sys
from pathlib import Path

# Whatever else the metadata lists, these must be among the licence files.
REQUIRED_LICENCES = (
    "LICENSE",
    "third-party-licenses/README.txt",
    "third-party-licenses/HASKELL-LIBRARIES.txt",
    "third-party-licenses/GMP-NOTICE.txt",
)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    dist_name, module_name = argv[1], argv[2]
    dist = metadata.distribution(dist_name)
    files = {str(f): f for f in dist.files or []}
    problems: list[str] = []

    module = importlib.import_module(module_name)
    module_file = Path(module.__file__ or "").resolve()
    installed = {Path(dist.locate_file(f)).resolve() for f in files.values()}
    if module_file not in installed:
        problems.append(f"{module_name} was imported from {module_file}, which {dist_name} did not install")

    site = module_file.parent
    haskell = [image for image in loaded_images() if Path(image).name.startswith("libHS")]
    for image in haskell:
        if site not in Path(image).resolve().parents:
            problems.append(f"a Haskell library was loaded from outside the wheel: {image}")
    if not any(Path(image).name.startswith("libHSrts") for image in haskell):
        problems.append("the GHC runtime (libHSrts) was not loaded, so the library check saw nothing")

    listed = set(dist.metadata.get_all("License-File") or [])
    for name in sorted(set(REQUIRED_LICENCES) - listed):
        problems.append(f"the metadata lists no License-File {name}")
    for name in sorted(listed):
        entries = [f for key, f in files.items() if key.endswith(f".dist-info/licenses/{name}")]
        if not entries or not Path(dist.locate_file(entries[0])).is_file():
            problems.append(f"the licence file {name} is not installed")

    for suffix in (f"{module_name}-stubs/__init__.pyi", f"{module_name}-stubs/py.typed"):
        if suffix not in files:
            problems.append(f"{suffix} is not installed")

    for problem in problems:
        print(f"check-installed-wheel: {problem}", file=sys.stderr)
    if problems:
        return 1
    print(f"check-installed-wheel: {dist_name} {dist.version} is complete, imported from {module_file}")
    return 0


def loaded_images() -> list[str]:
    """The shared libraries mapped into this process."""
    if sys.platform == "darwin":
        libc = ctypes.CDLL(None)
        libc._dyld_image_count.restype = ctypes.c_uint32
        libc._dyld_get_image_name.restype = ctypes.c_char_p
        libc._dyld_get_image_name.argtypes = [ctypes.c_uint32]
        return [libc._dyld_get_image_name(i).decode() for i in range(libc._dyld_image_count())]
    with open("/proc/self/maps") as maps:
        return sorted({line.split()[-1] for line in maps if line.rstrip().endswith(".so") or ".so." in line})


if __name__ == "__main__":
    sys.exit(main(sys.argv))
