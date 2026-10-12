#!/usr/bin/env python3

"""Wrapper script to call ghc.

It accepts a dep file where all used inputs are written to. For any passed ABI
hash file, the corresponding interface is marked as unused, so these can change
without triggering compilation actions.

"""

import argparse
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, add_help=False, fromfile_prefix_chars="@"
    )
    parser.add_argument(
        "--buck2-dep",
        required=False,
        help="Path to the dep file.",
    )
    parser.add_argument(
        "--buck2-packagedb-dep",
        required=False,
        help="Path to the dep file.",
    )
    parser.add_argument(
        "--buck2-package-db",
        required=False,
        nargs="*",
        default=[],
        help="Path to a package db that is used during the module compilation",
    )
    parser.add_argument(
        "--ghc", required=True, type=str, help="Path to the Haskell compiler GHC."
    )
    parser.add_argument(
        "--ghc-dir", type=str, help="Worker option"
    )
    parser.add_argument(
        "--ghc-argsfile",
        required=False,
        type=str,
        help="File path containing arguments for GHC.")
    parser.add_argument(
        "--abi-out",
        required=False, # True,
        type=Path,
        help="Output path of the abi file to create.",
    )
    parser.add_argument(
        "--abi-from-plugin",
        required=False,
        type=Path,
        help="Path the oneshot driver plugin writes this module's ABI hash "
             "to. No second GHC starts for it; the wrapper only checks the "
             "plugin wrote it.",
    )
    parser.add_argument(
        "--bin-path",
        type=Path,
        action="append",
        default=[],
        help="Add given path to PATH.",
    )
    parser.add_argument(
        "--bin-exe",
        type=Path,
        action="append",
        default=[],
        help="Add given exe (more specific than bin-path)",
    )
    parser.add_argument(
        "--extra-env-key",
        type=str,
        action="append",
        default=[],
        help="Extra environment variable name",
    )
    parser.add_argument(
        "--extra-env-value",
        type=str,
        action="append",
        default=[],
        help="Extra environment variable value",
    )

    args, ghc_args = parser.parse_known_args()

    cmd = [args.ghc] + ghc_args + (["@" + args.ghc_argsfile] if args.ghc_argsfile else [])

    aux_paths = [str(binpath) for binpath in args.bin_path if binpath.is_dir()] + [str(os.path.dirname(binexepath)) for binexepath in args.bin_exe]
    env = os.environ.copy()
    path = env.get("PATH", "")
    env["PATH"] = os.pathsep.join([path] + aux_paths)

    extra_env_keys = [str(k) for k in args.extra_env_key]
    extra_env_values = [str(v) for v in args.extra_env_value]
    assert len(extra_env_keys) == len(extra_env_values), "number of --extra-env-key and --extra-env-value flags must match"
    n_extra_env = len(extra_env_keys)
    if n_extra_env > 0:
        for i in range(0, n_extra_env):
            k = extra_env_keys[i]
            v = extra_env_values[i]
            env[k] = v

    # Note, Buck2 swallows stdout on successful builds.
    # Redirect to stderr to avoid this.
    returncode = subprocess.call(cmd, env=env, stdout=sys.stderr.buffer)
    if returncode != 0:
        return returncode

    recompute_abi_hash(args.ghc, args.abi_out)

    check_plugin_abi_hash(args.abi_from_plugin)

    if args.buck2_dep:
        # write an empty dep file, to signal that all tagged files are unused
        try:
            with open(args.buck2_dep, "w") as f:
                f.write("\n")

        except Exception as e:
            # remove incomplete dep file
            os.remove(args.buck2_dep)
            raise e

    if args.buck2_packagedb_dep:
        # write an empty dep file, to signal that all tagged files are unused
        try:
            with open(args.buck2_packagedb_dep, "w") as f:
                for db in args.buck2_package_db:
                    f.write(db + "\n")
                if not args.buck2_package_db:
                    f.write("\n")

        except Exception as e:
            # remove incomplete dep file
            os.remove(args.buck2_packagedb_dep)
            raise e

    return 0


def check_plugin_abi_hash(abi_out):
    """Check the oneshot plugin wrote the ABI hash buck2 declared.

    buck2 declares this file an output of the compile, so the path has to be
    named on the command line whichever side writes it. Naming it here is also
    the only place the two derivations of that path are checked against each
    other: the build builds it from the interface path it told GHC through
    -hisuf, and the plugin builds it from GHC's ModLocation. A silent
    disagreement would otherwise surface as an unbound-artifact error with no
    cause attached to it.
    """
    if abi_out:
        if not abi_out.exists():
            # Say what the plugin did write. The two derivations of this path
            # disagreeing is the likely cause, and the sibling list names the
            # disagreement instead of leaving it to be guessed at.
            stem = abi_out.name.split(".")[0]
            siblings = sorted(
                p.name for p in abi_out.parent.glob(f"{stem}*") if p.is_file()
            )
            raise SystemExit(
                f"the oneshot plugin wrote no ABI hash at {abi_out}; "
                f"files for this module: {siblings}"
            )
        if abi_out.stat().st_size == 0:
            raise SystemExit(f"the oneshot plugin wrote an empty ABI hash at {abi_out}")


def recompute_abi_hash(ghc, abi_out):
    """Call ghc on the hi file and write the ABI hash to abi_out."""
    if abi_out:
        hi_file = abi_out.with_suffix("")

        cmd = [ghc, "-v0", "-package-env=-", "--show-iface-abi-hash", hi_file]

        hash = subprocess.check_output(cmd, text=True).split(maxsplit=1)[0]

        abi_out.write_text(hash)


if __name__ == "__main__":
    sys.exit(main())
