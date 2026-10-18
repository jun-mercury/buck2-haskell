#!/usr/bin/env python3

"""Helper script to generate metadata about Haskell targets provided by the Haskell toolchain.

The result is a JSON object with the following fields:
* `exposed_modules`: List of modules exposed by the package.
"""

import argparse
import sys
import json
import shlex
import subprocess

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--ghc-pkg",
        required=True,
        type=str,
        help="Path to ghc-pkg",
    )
    parser.add_argument(
        "--package-name",
        required=True,
        type=str,
        help="Read info about this package.",
    )
    parser.add_argument(
        "--package-dir",
        required=False,
        type=str,
        help="Read package info from this directory.",
    )
    parser.add_argument(
        "--output",
        required=True,
        type=argparse.FileType("w"),
        help="Write package metadata to this file in JSON format.",
    )

    args = parser.parse_args()
    result = obtain_lib_metadata(args.ghc_pkg, args.package_name, args.package_dir)

    json.dump(result, args.output, indent=4, default=json_default_handler)


def json_default_handler(o):
    if isinstance(o, set):
        return sorted(o)
    raise TypeError(f"Object of type {o.__class__.__name__} is not JSON serializable")


def obtain_lib_metadata(ghc_pkg, package_name, pkgdb):
    package_id = determine_id(ghc_pkg, package_name, pkgdb)
    exposed_modules = determine_exposed_modules(ghc_pkg, package_name, pkgdb)
    return {
        "id": package_id,
        "exposed_modules": exposed_modules,
    }


def determine_id(ghc_pkg, package_name, pkgdb):
    package_id = run_ghc_pkg(
        ghc_pkg, "field", pkgdb, args=[package_name, "id", "--simple-output"]
    )
    return package_id.strip()


def determine_exposed_modules(ghc_pkg, package_name, pkgdb):
    package_data = run_ghc_pkg(
        ghc_pkg, "field", pkgdb, args=[package_name, "exposed-modules", "--simple-output"]
    ).strip()
    if ',' in package_data:
        # When re-exported modules are present, the list of exposed-modules is comma-separated, even
        # when `--simple-output` is used. (See https://gitlab.haskell.org/ghc/ghc/-/issues/26351.)
        #
        # Currently, targets that use a module must directly depend on a package which implements
        # the module; depending on a package which re-exports that module isn't sufficient.
        #
        # The `exposed_modules` field is used by downstream tooling for deleting unused dependencies;
        # in order for this list to be reliable for this purpose, re-exported modules must be excluded
        # from it.
        #
        # Re-exported modules appear in this list followed by `from <versioned package name>`.
        # We exclude re-exports by filtering out modules listed in this form.
        packages_with_source_packages = [m.split(' from ') for m in package_data.split(', ')]
        return list(map(lambda x: x[0], filter(lambda x: len(x) == 1, packages_with_source_packages)))
    else:
        return package_data.split()


def run_ghc_pkg(ghc_pkg, cmd, pkgdb=None, args=[]):
    outer_args = [ghc_pkg, "--no-user-package-db", cmd] + args
    if pkgdb:
        outer_args += [f"--package-db={pkgdb}"]

    res = subprocess.run(outer_args, capture_output=True)

    if res.returncode != 0:
        # ghc-pkg's own output is the diagnosis; printing only our arguments
        # left a failed action with no reason in its stderr.
        print(shlex.join(outer_args), file=sys.stderr)
        if res.returncode < 0:
            print(f"ghc-pkg was killed by signal {-res.returncode}", file=sys.stderr)
        else:
            print(f"ghc-pkg exited with status {res.returncode}", file=sys.stderr)
        sys.stderr.write(res.stderr.decode("utf-8", "replace"))
        sys.stderr.write(res.stdout.decode("utf-8", "replace"))
        sys.exit(res.returncode)

    return res.stdout.decode("utf-8")


if __name__ == "__main__":
    main()
