#!/usr/bin/env python3

"""Build the oneshot linkables plugin into a relocatable package db.

The output directory holds `package.db`, the interfaces under `hi` and the
shared library under `lib`. GHC loads plugins into the compiler process, so
the library is dynamic and links against the compiler's own `ghc` unit.
"""

import argparse
import os
import shutil
import subprocess
import sys

UNIT = "buck2-haskell-oneshot-linkables"
MODULE = "Buck2Haskell.OneshotLinkables"
PACKAGES = ["base", "containers", "ghc", "transformers"]


def run(cmd, **kwargs):
    res = subprocess.run(cmd, stderr=sys.stderr.buffer, **kwargs)
    if res.returncode != 0:
        sys.exit(res.returncode)
    return res


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ghc", required=True)
    parser.add_argument("--ghc-pkg", required=True)
    parser.add_argument("--src", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    out = os.path.abspath(args.out)
    hi = os.path.join(out, "hi")
    lib = os.path.join(out, "lib")
    obj = os.path.join(out, "obj")
    db = os.path.join(out, "package.db")
    for d in (hi, lib, obj):
        os.makedirs(d, exist_ok=True)

    version = run([args.ghc, "--numeric-version"], stdout=subprocess.PIPE, text=True).stdout.strip()
    ids = [
        run([args.ghc_pkg, "field", p, "id", "--simple-output"], stdout=subprocess.PIPE, text=True).stdout.split()[0]
        for p in PACKAGES
    ]

    common = ["-hide-all-packages", "-package-env=-", "-this-unit-id", UNIT]
    for p in PACKAGES:
        common += ["-package", p]

    # -dynamic-too gives both interface flavours: a compile loads the plugin's
    # interface with its own -hisuf, which is dyn_hi for shared compiles and hi
    # for static ones.
    run([args.ghc, *common, "-c", "-O", "-fPIC", "-dynamic-too",
         "-odir", obj, "-hidir", hi, "-osuf", "o", "-hisuf", "hi",
         "-dynosuf", "dyn_o", "-dynhisuf", "dyn_hi", args.src])
    dyn_o = os.path.join(obj, *MODULE.split(".")) + ".dyn_o"
    so = os.path.join(lib, "libHS{}-ghc{}.so".format(UNIT, version))
    run([args.ghc, *common, "-shared", "-dynamic", "-o", so, dyn_o])
    shutil.rmtree(obj)

    conf = os.path.join(out, UNIT + ".conf")
    with open(conf, "w") as f:
        f.write("\n".join([
            "name: " + UNIT,
            "version: 0",
            "id: " + UNIT,
            "key: " + UNIT,
            "exposed: True",
            "exposed-modules: " + MODULE,
            "import-dirs: ${pkgroot}/hi",
            "library-dirs: ${pkgroot}/lib",
            "dynamic-library-dirs: ${pkgroot}/lib",
            "hs-libraries: HS" + UNIT,
            "depends: " + " ".join(ids),
            "",
        ]))
    run([args.ghc_pkg, "init", db])
    run([args.ghc_pkg, "register", "--package-db", db, "--no-expand-pkgroot", "--force", "-v0", conf])
    os.remove(conf)


if __name__ == "__main__":
    main()
