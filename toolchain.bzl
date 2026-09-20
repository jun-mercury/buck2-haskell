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
    path = Artifact,
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
        # The command an action runs where buck2 does not run its worker: a
        # remote executor, or a platform without persistent workers. Its command
        # line is the worker's request; it sends it to a server the execution
        # environment runs and returns the response's exit code. Without one,
        # a worker action has no executable outside the worker.
        "worker_client": provider_field(RunInfo | None, default = None),
        "ghc_dir": provider_field(Artifact | None, default = None),
        # RTS options passed to GHC, changing the behavior of the compiler process, not the resulting binaries like
        # `-with-rtsopts` would.
        "ghc_rts_flags": provider_field(typing.Any, default = None),
    },
)

HaskellToolchainLibrary = provider(
    fields = {
        "name": provider_field(str),
        "dynamic": DynamicValue,
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

def _toolchain(lang: str, providers: list[typing.Any]) -> Attr:
    return attrs.toolchain_dep(default = "toolchains//:" + lang, providers = providers)

def haskell_toolchain():
    return _toolchain("haskell", [HaskellToolchainInfo, HaskellPlatformInfo])
