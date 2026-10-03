# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

load("@prelude//utils:arglike.bzl", "ArgLike")

HaskellPlatformInfo = provider(fields = {
    "name": provider_field(typing.Any, default = None),
})

HaskellToolchainPackagesInfo = record(
    dynamic = DynamicValue,
)

HaskellToolchainPackage = record(
    db = ArgLike,
    # The directory backing the package db, used to materialize the package's
    # files (interfaces, libs) as hidden inputs. May be `None` for package dbs
    # that are provided as a bare path without a tracked artifact.
    path = field(Artifact | None, None),
    name = field(str, ""),
)

HaskellToolchainInfo = provider(
    # @unsorted-dict-items
    fields = {
        "compiler": provider_field(RunInfo),
        "compiler_flags": provider_field(typing.Any, default = None),
        "linker": provider_field(RunInfo),
        "linker_flags": provider_field(typing.Any, default = None),
        "haddock": provider_field(RunInfo),
        "compiler_major_version": provider_field(str | None, default = None),
        "package_name_prefix": provider_field(typing.Any, default = None),
        "packager": provider_field(RunInfo),
        "support_expose_package": provider_field(bool, default = False),
        "archive_contents": provider_field(typing.Any, default = None),
        "ghci_script_template": provider_field(Artifact | None, default = None),
        "ghci_iserv_template": provider_field(Artifact | None, default = None),
        "ide_script_template": provider_field(Artifact | None, default = None),
        "ghci_binutils_path": provider_field(typing.Any, default = None),
        "ghci_lib_path": provider_field(typing.Any, default = None),
        "ghci_ghc_path": provider_field(typing.Any, default = None),
        "ghci_iserv_path": provider_field(typing.Any, default = None),
        "ghci_iserv_prof_path": provider_field(typing.Any, default = None),
        "ghci_cxx_path": provider_field(typing.Any, default = None),
        "ghci_cc_path": provider_field(typing.Any, default = None),
        "ghci_cpp_path": provider_field(typing.Any, default = None),
        "ghci_packager": provider_field(typing.Any, default = None),
        "cache_links": provider_field(typing.Any, default = None),
        "script_template_processor": provider_field(Dependency | None, default = None),
        "packages": provider_field(HaskellToolchainPackagesInfo | None, default = None),
        "use_persistent_workers": provider_field(bool, default = False),
        "use_worker": provider_field(bool, default = False),
        "use_remote_dep_file_cache": provider_field(bool, default = False),
        # The command an action runs where buck2 does not run its worker: a
        # remote executor, or a platform without persistent workers. Its command
        # line is the worker's request; it sends it to a server the execution
        # environment runs and returns the response's exit code. Without one,
        # a worker action has no executable outside the worker.
        "worker_client": provider_field(RunInfo | None, default = None),
        # The worker itself, as a Bazel-protocol persistent worker: a remote
        # executor that supports the protocol (BuildBuddy's persistentWorkerKey)
        # keeps it in a recycled runner and sends it each request on stdin. Set,
        # a worker request's arguments travel as one @argfile, the only form
        # buck2 sends such a worker, and `worker_client` is the fallback
        # executable, which must name the worker's files so that they reach the
        # action's input root.
        "bazel_worker": provider_field(RunInfo | None, default = None),
        "ghc_dir": provider_field(Artifact | None, default = None),
        # RTS options passed to GHC, changing the behavior of the compiler process, not the resulting binaries like
        # `-with-rtsopts` would.
        "ghc_rts_flags": provider_field(typing.Any, default = None),
        # Remote execution properties by action class, merged over the
        # execution platform's for each action of that class: "small" for
        # package registration and metadata, "compile" for module compiles.
        # A buck2 without `ctx.actions.run(remote_execution_properties)`
        # rejects the argument, so an unset table passes nothing.
        "action_classes": provider_field(dict[str, dict[str, str]] | None, default = None),
    },
)

def remote_execution_class(haskell_toolchain, action_class: str) -> dict[str, typing.Any]:
    classes = haskell_toolchain.action_classes or {}
    properties = classes.get(action_class)
    if not properties:
        return {}
    return {"remote_execution_properties": properties}

HaskellToolchainLibrary = provider(
    fields = {
        "name": provider_field(str),
        "dynamic": DynamicValue,
        # For toolchain libraries whose package db is provided directly (e.g.
        # `haskell_toolchain_library_from_package_db_impl`), this carries the path to
        # the package db directory so that consumers can resolve it without
        # looking it up in the toolchain-wide package db. `None` for libraries
        # resolved through the toolchain's package db.
        "package_db_path": provider_field(typing.Any, default = None),  # str | None
    },
)

DynamicHaskellToolchainLibraryInfo = provider(
    fields = {
        "id": provider_field(str),
    },
)

def _haskell_toolchain_package_info_as_toolchain_package_db(p: HaskellToolchainPackage):
    return cmd_args(p.db)

def _haskell_toolchain_package_set_root(children: list[HaskellToolchainPackage], p: HaskellToolchainPackage | None):
    return p

HaskellToolchainPackageDbTSet = transitive_set(
    args_projections = {
        "toolchain_package_db": _haskell_toolchain_package_info_as_toolchain_package_db,
    },
    reductions = {
        "toolchain_root": _haskell_toolchain_package_set_root,
    },
)

DynamicHaskellToolchainPackageDbInfo = provider(fields = {
    "toolchain_packages": dict[str, HaskellToolchainPackageDbTSet],
})

def augment_toolchain_package_db(actions, base, toolchain_libs):
    """Merge package dbs carried by toolchain libraries into a package db dict.

    `base` is the toolchain-wide `name -> HaskellToolchainPackageDbTSet` dict.
    `toolchain_libs` is a list of `HaskellToolchainLibrary` (direct and/or
    transitive); for each whose `package_db_path` is set (see
    `haskell_toolchain_library_from_package_db`), a single-entry
    `HaskellToolchainPackageDbTSet` is built and added to the resulting dict
    keyed by the library name. Returns `base` unchanged when there is nothing to
    add.
    """
    extra = {
        lib.name: actions.tset(
            HaskellToolchainPackageDbTSet,
            value = HaskellToolchainPackage(
                db = cmd_args(lib.package_db_path),
                # `package_db_path` is an impure on-disk path, not a tracked
                # artifact, so there is no backing artifact to materialize.
                path = None,
                name = lib.name,
            ),
        )
        for lib in toolchain_libs
        if lib.package_db_path != None
    }
    if not extra:
        return base
    return base | extra

def _toolchain(lang: str, providers: list[typing.Any]) -> Attr:
    return attrs.toolchain_dep(default = "toolchains//:" + lang, providers = providers)

def haskell_toolchain():
    return _toolchain("haskell", [HaskellToolchainInfo, HaskellPlatformInfo])
