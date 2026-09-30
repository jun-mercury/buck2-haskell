# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

load("@prelude//:paths.bzl", "paths")
load(
    "@prelude//cxx:cxx_toolchain_types.bzl",
    "CxxPlatformInfo",
)
load(
    "@prelude//linking:link_info.bzl",
    "LinkStyle",
    "MergedLinkInfo",
)
load(
    "@prelude//linking:shared_libraries.bzl",
    "SharedLibraryInfo",
)
load("@prelude//utils:utils.bzl", "flatten")
load(
    ":library_info.bzl",
    "HaskellLibraryInfo",
    "HaskellLibraryProvider",
)
load(
    ":link_info.bzl",
    "HaskellLinkGroupInfo",
    "HaskellLinkGroupProvider",
    "HaskellLinkGroupTSet",
    "HaskellLinkGroupTSetProvider",
    "HaskellLinkInfo",
)
load(
    ":toolchain.bzl",
    "HaskellToolchainLibrary",
)

HASKELL_EXTENSIONS = [
    ".hs",
    ".lhs",
    ".hsc",
    ".chs",
    ".x",
    ".y",
]

HASKELL_BOOT_EXTENSIONS = [
    ".hs-boot",
    ".lhs-boot",
]

# String to hexadecimal hash (only abs value).
# This is to shorten worker-target-id, which can be used in unix socket path.
def to_hash(pkgname) -> str:
    n = hash(pkgname)
    if n > 0:
        n2 = n
    else:
        n2 = -n
    s = "00000000%x" % n2
    return s[-8:]

# We take a named_set for srcs, which is sometimes a list, sometimes a dict.
# In future we should only accept a list, but for now, cope with both.
def srcs_to_pairs(srcs) -> list[(str, Artifact)]:
    if type(srcs) == type({}):
        return srcs.items()
    else:
        return [(src.short_path, src) for src in srcs]

def is_haskell_src(x: str) -> bool:
    _, ext = paths.split_extension(x)
    return ext in HASKELL_EXTENSIONS

def is_haskell_boot(x: str) -> bool:
    _, ext = paths.split_extension(x)
    return ext in HASKELL_BOOT_EXTENSIONS

def src_to_module_name(x: str, predefined_name_map: dict[str, str] = {}) -> str:
    predefined = predefined_name_map.get(x)
    if predefined:
        return predefined
    else:
        base, _ext = paths.split_extension(x)
        return base.replace("/", ".")

def strip_source_prefix(path: str, strip_prefix: list[str]) -> str:
    """Strip the first matching strip_prefix entry from a source path to get the module-relative path."""
    for prefix in strip_prefix:
        if path.startswith(prefix + "/"):
            return path[len(prefix) + 1:]
    return path

def _full_strip_prefixes(package: str, strip_prefix: list[str]) -> list[str]:
    """Build the strip-prefix list applied to cell-root paths.

    Package-relative entries come first so they take precedence over bare
    ones — matters when both could match (e.g. a package at
    //local-packages/foo with bare strip "src" and entries "src" already
    appearing as the first path component).
    """
    return (
        [paths.join(package, p) for p in strip_prefix] +
        list(strip_prefix)
    )

def compute_source_module_paths(
        package: str,
        module_prefix: [str, None],
        strip_prefix: list[str],
        sources) -> list[(str, Artifact)]:
    """Compute the module-tree-relative path for each Haskell source file.

    Used by `HaskellSourceInfo` construction to symlink sources at the
    right location for GHCi's `-i` import search to find them by
    qualified module name.

    Three cases:

      1. `sources` is a dict {path: artifact}. The key IS the input path
         (typically cell-root); strip configured prefixes from it. We do
         not consult `module_prefix` here — the dict form is used when
         the caller already knows exactly where each file should live.

      2. `sources` is a list of artifacts AND `module_prefix` is set. The
         library's modules are GHC-known as `<module_prefix>.<short_path_module>`,
         so the in-tree path must mirror that:
         `<module_prefix_as_dir>/<short_path_with_strip_prefix_stripped>`.
         This handles sub-packages like
         //local-packages/foo/src/Acme/Foo/Bar that live at the module
         location (their package path IS the module path).

      3. `sources` is a list and `module_prefix` is empty. Strip a matching
         prefix from the artifact's `short_path`, mirroring how
         `compile.bzl` derives module names in the same case. Do NOT join
         the package path on first: a source file's `short_path` is already
         package-relative, and a target src's (e.g. `export_file`) is the
         `out` the declaring rule chose, which is the module path outright.
         Joining the package would give a target src a
         `<package>/<module path>` location that GHCi's `-i` search can
         never resolve, so its modules go missing from every library whose
         package path isn't "". See `tests/build_tests/export_file_src`.
    """
    if type(sources) == type({}):
        full_strip = _full_strip_prefixes(package, strip_prefix)
        return [
            (strip_source_prefix(path, full_strip), artifact)
            for (path, artifact) in sources.items()
            if is_haskell_src(path)
        ]

    if module_prefix:
        module_prefix_dir = module_prefix.replace(".", "/")
        return [
            (paths.join(module_prefix_dir, strip_source_prefix(src.short_path, strip_prefix)), src)
            for src in sources
            if is_haskell_src(src.short_path)
        ]

    return [
        (strip_source_prefix(src.short_path, strip_prefix), src)
        for src in sources
        if is_haskell_src(src.short_path)
    ]

def attr_deps(ctx: AnalysisContext) -> list[Dependency]:
    return ctx.attrs.deps + (getattr(ctx.attrs, "deps_query", []) or [])

def attr_deps_haskell_link_infos(ctx: AnalysisContext) -> list[HaskellLinkInfo]:
    return dedupe(filter(
        None,
        [
            d.get(HaskellLinkInfo)
            for d in attr_deps(ctx) + ctx.attrs.template_deps
        ],
    ))

def attr_deps_haskell_link_group_infos(ctx: AnalysisContext, link_style: LinkStyle) -> list[HaskellLinkGroupInfo]:
    libs = []
    for d in attr_deps(ctx):
       p = d.get(HaskellLinkGroupProvider)
       if p:
           if p.link_group.get(link_style):
               libs.append(p.link_group[link_style])
    return dedupe(libs)

def attr_deps_haskell_link_group_tsets(ctx: AnalysisContext, link_style: LinkStyle) -> list[HaskellLinkGroupTSet]:
    direct_deps_lg_tsets = []
    for d in attr_deps(ctx):
        p = d.get(HaskellLinkGroupTSetProvider)
        if p:
            if p.link_group_tsets.get(link_style):
                direct_deps_lg_tsets.append(p.link_group_tsets[link_style])
    return direct_deps_lg_tsets

def attr_deps_haskell_toolchain_libraries(ctx: AnalysisContext) -> list[HaskellToolchainLibrary]:
    return filter(
        None,
        [
            d.get(HaskellToolchainLibrary)
            for d in attr_deps(ctx) + ctx.attrs.template_deps
        ],
    )

# DONT CALL THIS FUNCTION, you want attr_deps_haskell_link_infos instead
def attr_deps_haskell_link_infos_sans_template_deps(ctx: AnalysisContext) -> list[HaskellLinkInfo]:
    return dedupe(filter(
        None,
        [
            d.get(HaskellLinkInfo)
            for d in attr_deps(ctx)
        ],
    ))

def attr_deps_haskell_lib_infos(
        ctx: AnalysisContext,
        link_style: LinkStyle,
        enable_profiling: bool,
        skip_missing_link_style: bool = False) -> list[HaskellLibraryInfo]:
    if enable_profiling and link_style == LinkStyle("shared"):
        fail("Profiling isn't supported when using dynamic linking")
    results = []
    for x in filter(None, [
        d.get(HaskellLibraryProvider)
        for d in attr_deps(ctx) + ctx.attrs.template_deps
    ]):
        lib = x.prof_lib if enable_profiling else x.lib
        if skip_missing_link_style:
            info = lib.get(link_style)
            if info != None:
                results.append(info)
        else:
            results.append(lib[link_style])
    return results

def attr_deps_merged_link_infos(ctx: AnalysisContext) -> list[MergedLinkInfo]:
    return dedupe(filter(
        None,
        [
            d.get(MergedLinkInfo)
            for d in attr_deps(ctx)
        ],
    ))

def attr_deps_shared_library_infos(ctx: AnalysisContext) -> list[SharedLibraryInfo]:
    return filter(
        None,
        [
            d.get(SharedLibraryInfo)
            for d in attr_deps(ctx)
        ],
    )

def _link_style_extensions(link_style: LinkStyle) -> (str, str):
    if link_style == LinkStyle("shared"):
        return ("dyn_o", "dyn_hi")
    elif link_style == LinkStyle("static_pic"):
        return ("o", "hi")  # is this right?
    elif link_style == LinkStyle("static"):
        return ("o", "hi")
    fail("unknown LinkStyle")

def output_extensions(
        link_style: LinkStyle,
        profiled: bool) -> (str, str):
    osuf, hisuf = _link_style_extensions(link_style)
    if profiled:
        return ("p_" + osuf, "p_" + hisuf)
    else:
        return (osuf, hisuf)

# Single place to build the suffix used in artifacts (e.g. package directories,
# lib names) considering attributes like link style and profiling.
def get_artifact_suffix(link_style: LinkStyle, enable_profiling: bool, suffix: str = "") -> str:
    artifact_suffix = link_style.value
    if enable_profiling:
        artifact_suffix += "-prof"
    return artifact_suffix + suffix

def _source_prefix(source: Artifact, module_name: str) -> str:
    """Determine the directory prefix of the given artifact, considering that ghc has determined `module_name` for that file."""
    source_path = paths.replace_extension(source.short_path, "")

    module_name_for_file = src_to_module_name(source_path)

    # assert that source_path (without extension) and its module name have the same length
    if len(source_path) != len(module_name_for_file):
        fail("{} should have the same length as {}".format(source_path, module_name_for_file))

    if module_name != module_name_for_file and module_name_for_file.endswith("." + module_name):
        # N.B. the prefix could have some '.' characters in it, use the source_path to determine the prefix
        return source_path[0:-len(module_name) - 1]

    return ""

def md_module_mapping(md) -> dict[str, str]:
    """The mapping from source-path-derived module names to declared module names."""
    mapping = md.get("module_mapping")
    if mapping != None:
        return mapping
    # Worker-provided metadata does not have module_mapping populated, but we can calculate it here
    mapping = {}
    for modname, entry in (md.get("cache") or {}).items():
        apparent = src_to_module_name(entry["source"])
        if apparent != modname:
            mapping[apparent] = modname
    return mapping

def get_source_prefixes(srcs: list[Artifact], module_map: dict[str, str]) -> list[str]:
    """Determine source prefixes for the given haskell files and a mapping from source file module name to module name."""
    source_prefixes = {}
    for path, src in srcs_to_pairs(srcs):
        if not is_haskell_src(path):
            continue

        name = src_to_module_name(path)
        real_name = module_map.get(name)
        prefix = _source_prefix(src, real_name) if real_name else ""
        source_prefixes[prefix] = None

    return source_prefixes.keys()

def make_haskell_names_from_label(
        label: Label,
        use_same_package_name: bool,
    ) -> (str, str):
    if use_same_package_name:
        libname = label.name
        pkgname = libname
    else:
        libprefix = repr(label.path).replace("//", "_").replace("/", "_")

        # avoid consecutive "--" in package name, which is not allowed by ghc-pkg.
        if libprefix[-1] == "_":
            libname0 = libprefix + label.name
        else:
            libname0 = libprefix + "_" + label.name
        pkgname = libname0.replace("_", "-").replace(".", "-")
        libname = "HS" + pkgname
    return (pkgname, libname)

# the main attr is decomposed into (module name, function name)
def decompose_main(main: str) -> (str, str | None):
    head, _dot, tail = main.rpartition(".")
    if tail[0].isupper():
        module_name = main
        function_name = None
    else:
        module_name = head
        function_name = tail
    return (module_name, function_name)

# check worker consistency
#
# A worker request needs somewhere to go: the worker instance buck2 runs, or
# the toolchain's `worker_client`, which sends it to a server the execution
# environment runs. A target that names no worker (a plain `haskell_library`
# leaves `_worker` unset) still compiles through the client.
def check_is_worker_execute(
        worker: WorkerInfo | None,  # is worker instance instantiated?
        allow_worker: bool,  # is this target allowing worker build?
        use_worker: bool,  # is toolchain-level worker enabled?
        worker_client: RunInfo | None,  # the toolchain's client, if any
    ) -> bool:
    is_worker_execute = allow_worker and use_worker
    if is_worker_execute and worker == None and worker_client == None:
        fail("Haskell toolchain use_worker and the target allow_worker are set to True, but neither a worker instance nor a worker_client is set")
    return is_worker_execute
