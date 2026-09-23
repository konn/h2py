Third-party licences of this wheel
==================================

The wheel's own licence is LICENSE, next to this directory.
The wheel also contains the following, whose licences are here:

HASKELL-LIBRARIES.txt
    Every Haskell library the extension module links against, the GHC
    runtime (rts) and GHC's boot libraries included, each under its own
    licence, taken from the package or, for the boot libraries, from GHC's
    source release.

XXHASH-LICENSE.txt
    xxHash, compiled into the GHC runtime (rts/Hash.c) and into the hashable
    library (xxHash 0.8.3).

LLVM-LICENSE.txt
    LLVM's ELF relocation tables, compiled into the GHC runtime's linker on
    Linux.

GMP-NOTICE.txt, LGPL-3.0.txt, GPL-3.0.txt
    GMP, inside libHSghc-bignum in the macOS wheels and as libgmp.so.10 in
    the Linux wheels; the notice says where its corresponding source is.

LIBFFI-LICENSE.txt
    libffi 3.5.2, GHC's own build of it, bundled as libffi.so.8 in the Linux
    wheels; the macOS wheels use the system's libffi.
