"""Registering a package conf into a fresh package db with ghc-pkg.
"""

import subprocess
import sys


def register(ghc_pkg, db, package_conf):
    """Create the db at `db` and register `package_conf` into it, exiting on failure like ghc-pkg did."""
    res = subprocess.run([ghc_pkg, "init", db], stderr=sys.stderr.buffer)
    if res.returncode != 0:
        sys.exit(res.returncode)

    # --force: the conf's `depends` name packages in other dbs, which this
    # db does not see, and ghc-pkg would otherwise refuse the conf.
    register_cmd = [
        ghc_pkg,
        "register",
        "--package-conf",
        db,
        "--no-expand-pkgroot",
        package_conf,
        "--force",
        "-v0",
    ]

    res = subprocess.run(register_cmd, stderr=sys.stderr.buffer)
    if res.returncode != 0:
        sys.exit(res.returncode)
