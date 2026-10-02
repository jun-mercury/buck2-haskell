load("@buck2-haskell//:library_info.bzl", "HaskellLibraryProvider")
load("@buck2-haskell//:toolchain.bzl", "HaskellToolchainInfo", "haskell_toolchain")
load("@prelude//linking:link_info.bzl", "LinkStyle")

# Asks ghc-pkg, with the deps dbs of `lib` and its `deps` on the stack, for
# `lib`'s exposed modules and dependencies. A db that is missing, has no
# package cache or holds another package fails the query; a conf without the
# plan's modules or the dependencies' ids fails the comparison.
_SCRIPT = """#!/usr/bin/env bash
set -euo pipefail
ghc_pkg=$1; pkg=$2; shift 2
dbs=(); depends=(); modules=()
while [ $# -gt 0 ]; do
    case $1 in
        --db) dbs+=(--package-db "$2"); shift 2;;
        --depends) depends+=("$2"); shift 2;;
        *) modules+=("$1"); shift;;
    esac
done
for db in "${dbs[@]}"; do
    # ghc-pkg answers from the confs when the cache is missing, with a warning; ghc does not.
    [ "$db" = --package-db ] || [ -f "$db/package.cache" ] || { echo "FAIL: $db has no package.cache"; exit 1; }
done
field() { "$ghc_pkg" --no-user-package-db "${dbs[@]}" field "$pkg" "$1" | tr -s ' ,\\n' '\\n\\n\\n'; }
for module in "${modules[@]}"; do
    field exposed-modules | grep -qx "$module" || { echo "FAIL: $pkg does not expose $module"; field exposed-modules; exit 1; }
done
for dep in "${depends[@]}"; do
    field depends | grep -qx "$dep" || { echo "FAIL: $pkg does not depend on $dep"; field depends; exit 1; }
done
echo "PASS $pkg"
"""

def _deps_db_test_impl(ctx: AnalysisContext) -> list[Provider]:
    lib = ctx.attrs.lib[HaskellLibraryProvider].lib[LinkStyle("shared")]
    deps = [dep[HaskellLibraryProvider].lib[LinkStyle("shared")] for dep in ctx.attrs.deps]
    ghc_pkg = ctx.attrs._haskell_toolchain[HaskellToolchainInfo].packager

    command = cmd_args(ghc_pkg, lib.name)
    for db in [lib.deps_db] + [dep.deps_db for dep in deps]:
        command.add("--db", db)
    for dep in deps:
        command.add("--depends", dep.name)
    command.add(ctx.attrs.modules)

    script = ctx.actions.write("test_deps_db.sh", _SCRIPT, is_executable = True)
    return [
        DefaultInfo(default_output = script),
        ExternalRunnerTestInfo(
            type = "custom",
            command = [script, command],
        ),
    ]

deps_db_test = rule(
    impl = _deps_db_test_impl,
    attrs = {
        "lib": attrs.dep(providers = [HaskellLibraryProvider]),
        "deps": attrs.list(attrs.dep(providers = [HaskellLibraryProvider]), default = []),
        "modules": attrs.list(attrs.string()),
        "_haskell_toolchain": haskell_toolchain(),
    },
)
