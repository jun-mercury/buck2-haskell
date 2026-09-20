# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

load("@prelude//:paths.bzl", "paths")
load("@prelude//cxx:cxx_context.bzl", "get_cxx_toolchain_info")
load(
    "@prelude//cxx:preprocessor.bzl",
    "CPreprocessor",
    "CPreprocessorInfo",
    "CPreprocessorTSet",
    "cxx_inherited_preprocessor_infos",
)
load(
    "@prelude//linking:link_info.bzl",
    "LinkStyle",
    "MergedLinkInfo",
    "SharedLibLinkable",
    "get_link_args_for_strategy",
    "to_link_strategy",
    "unpack_link_args",
)
load("@prelude//utils:argfile.bzl", "argfile", "at_argfile")
load("@prelude//utils:arglike.bzl", "ArgLike")
load("@prelude//utils:graph_utils.bzl", "post_order_traversal")
load("@prelude//utils:strings.bzl", "strip_prefix")
load("@prelude//utils:utils.bzl", "dedupe_by_value")
load(
    ":library_info.bzl",
    "ExtraLibraryInfo",
    "HaskellLibraryInfo",
    "HaskellLibraryInfoTSet",
    "HaskellLibraryProvider",
    "get_libname",
    "merge_extra_lib_infos",
)
load(
    ":link_info.bzl",
    "GhcLinkableInfo",
    "HaskellLinkGroupInfo",
    "HaskellLinkGroupProvider",
    "HaskellLinkInfo",
    "get_link_infos_from_extra_lib_info",
)
load(
    ":toolchain.bzl",
    "DynamicHaskellToolchainPackageDbInfo",
    "HaskellToolchainInfo",
    "HaskellToolchainLibrary",
    "HaskellToolchainPackageDbTSet",
)
load(
    ":util.bzl",
    "attr_deps",
    "attr_deps_haskell_lib_infos",
    "attr_deps_haskell_link_group_infos",
    "attr_deps_haskell_link_infos",
    "attr_deps_haskell_toolchain_libraries",
    "check_is_worker_execute",
    "decompose_main",
    "get_artifact_suffix",
    "is_haskell_boot",
    "is_haskell_src",
    "make_haskell_names_from_label",
    "md_module_mapping",
    "output_extensions",
    "src_to_module_name",
    "srcs_to_pairs",
)

CompiledModuleInfo = provider(fields = {
    "name": provider_field(str),
    "abi": provider_field(Artifact | None),
    "interfaces": provider_field(list[Artifact]),
    "hie_files": provider_field(list[Artifact]),
    # TODO[AH] track this module's package-name/id & package-db instead.
    "db_deps": provider_field(list[Artifact]),
    "package": provider_field(str),
})

# Module dependency graph transitive sets including package deps as leaves
ModGraphTSet = transitive_set()

GraphInfo = record(
    graph = dict[str, list[str]],  # `dict[modname, list[modname]]`
    graph_set = dict[str, ModGraphTSet],
)

ArtifactOutputMap = record(
    outputs = dict[Artifact, OutputArtifact],
)

def _compiled_module_project_as_abi(mod: CompiledModuleInfo) -> cmd_args:
    if mod.abi:
        return cmd_args(mod.abi)
    else:
        return cmd_args()

def _compiled_module_project_as_interfaces(mod: CompiledModuleInfo) -> cmd_args:
    return cmd_args(mod.interfaces)

def _compiled_module_project_as_hie_files(mod: CompiledModuleInfo) -> cmd_args:
    return cmd_args(mod.hie_files)

def _compiled_module_reduce_as_packagedb_deps(children: list[dict[Artifact, None]], mod: CompiledModuleInfo | None) -> dict[Artifact, None]:
    # TODO[AH] is there a better way to avoid duplicate package-dbs?
    #   Using a projection instead would produce duplicates.
    result = {db: None for db in mod.db_deps} if mod else {}
    for child in children:
        result.update(child)
    return result

CompiledModuleTSet = transitive_set(
    args_projections = {
        "abi": _compiled_module_project_as_abi,
        "interfaces": _compiled_module_project_as_interfaces,
        "hie_files": _compiled_module_project_as_hie_files,
    },
    reductions = {
        "packagedb_deps": _compiled_module_reduce_as_packagedb_deps,
    },
)

DynamicCompileResultInfo = provider(fields = {
    "modules": dict[str, CompiledModuleTSet],
})

# The type of the return value of the `_compile()` function.
CompileResultInfo = record(
    objects = field(list[Artifact]),
    extra_objects = field(list[Artifact]),
    interfaces = field(list[Artifact]),
    extra_interfaces = field(list[Artifact]),
    hie = field(list[Artifact]),
    stubs = field(Artifact),
    hashes = field(list[Artifact]),
    producing_indices = field(bool),
    module_tsets = field(DynamicValue),
)

PackagesInfo = record(
    exposed_package_args = cmd_args,
    packagedb_args = cmd_args,
    local_packagedb_args = cmd_args,
    extra_libs_args = cmd_args,
    transitive_deps = field(HaskellLibraryInfoTSet),
)

# A record that holds module compilation results.
# NOTE: extra_interfaces and extra_objects are needed to hold
# dyn_hi/dyn_o artifacts built with static build. Those files
# are needed for compiling modules with TH for one-shot mode,
# unfortunately.
_Module = record(
    name = field(str),
    source = field(Artifact),
    interfaces = field(list[Artifact]),
    extra_interfaces = field(list[Artifact]),
    hash = field(Artifact | None),
    objects = field(list[Artifact]),
    extra_objects = field(list[Artifact]),
    hie_files = field(list[Artifact]),
    stub_dir = field(Artifact | None),
    prefix_dir = field(str),
)

def _get_module_outputs(
        module: _Module,
        outputs: ArtifactOutputMap) -> list[OutputArtifact]:
    outputs_dict = outputs.outputs
    objects = [outputs_dict[obj] for obj in module.objects]
    extra_objects = [outputs_dict[obj] for obj in module.extra_objects]
    his = [outputs_dict[hi] for hi in module.interfaces]
    extra_his = [outputs_dict[hi] for hi in module.extra_interfaces]
    hies = [outputs_dict[hie] for hie in module.hie_files]
    return objects + extra_objects + his + extra_his + hies

_DynamicDoCompileOptions = record(
    artifact_suffix = str,
    compiler_flags = list[typing.Any],  # Arguments.
    ghc_rts_flags = list[typing.Any],  # Arguments.
    deps = list[Dependency],
    direct_extra_libs = list[Dependency],
    direct_deps_info = list[HaskellLibraryInfoTSet],
    direct_deps_link_info = list[HaskellLinkInfo],
    haskell_direct_deps_lib_infos = list[HaskellLibraryInfo],
    enable_haddock = bool,
    enable_profiling = bool,
    external_tool_paths = list[RunInfo],
    ghc_wrapper = RunInfo,
    haskell_toolchain = HaskellToolchainInfo,
    linker_info = typing.Any,
    label = Label,
    link_style = LinkStyle,
    link_args = ArgLike,
    main = str | None,
    md_file = Artifact,
    modules = dict[str, _Module],
    pkgname = str,
    sources = list[typing.Any],  # Source.
    sources_deps = dict[typing.Any, list[typing.Any]],  # Source -> list[Source].
    srcs_envs = dict[typing.Any, dict[str, typing.Any]],  # Source -> (str -> Argument).
    toolchain_deps_by_name = dict[str, None],
    worker = WorkerInfo | None,
    allow_worker = bool,
    is_worker_execute = bool,
    allow_cache_upload = bool,
    link_group_libs = list[HaskellLinkGroupInfo],
    # GHC plugin flags applied to all modules in the unit (from `plugins` attr).
    # These flags will contain `-package-db`, `-plugin-package`,
    # `-fplugin-opt=...`, etc
    unit_plugin_flags = field(cmd_args | None, default = None),
    # Per-source plugin flags (from `srcs_plugins` attr). Source -> cmd_args.
    srcs_plugin_flags = field(dict[typing.Any, cmd_args], default = {}),
    # Per-source plugin tool paths (from `srcs_plugins` attr). Source -> list[RunInfo].
    srcs_plugin_tool_paths = field(dict[typing.Any, typing.Any], default = {}),
    # Toolchain library names required by plugins (from `plugins` attr) that
    # need to be added to the GHC command line. These are not necessarily the
    # same as the toolchain libraries required by the unit itself, since it's
    # possible that plugins require additional libraries that the unit doesn't
    # directly depend on.
    plugin_toolchain_deps = field(list[str], default = []),
)

def _strip_prefix(prefix: str, s: str) -> str:
    stripped = strip_prefix(prefix, s)

    return stripped if stripped != None else s

def _modules_by_name(
        ctx: AnalysisContext,
        *,
        sources: list[Artifact],
        is_worker_execute: bool,
        link_style: LinkStyle,
        enable_profiling: bool,
        suffix: str,
        module_prefix: str | None,
        is_haskell_binary: bool,
        src_main: Artifact | None) -> dict[str, _Module]:
    modules = {}
    predefined_name_map = {}

    if is_haskell_binary and src_main:
        if ctx.attrs.main:
            (main_module, _main_function) = decompose_main(ctx.attrs.main)
        else:
            main_module = "Main"
        predefined_name_map[src_main.short_path] = main_module
        main_path = main_module.replace(".", "/")
    else:
        main_module = None
        main_path = None

    osuf, hisuf = output_extensions(link_style, enable_profiling)

    for src in sources:
        bootsuf = ""
        if is_haskell_boot(src.short_path):
            bootsuf = "-boot"
        elif not is_haskell_src(src.short_path):
            continue

        module_name = src_to_module_name(src.short_path, predefined_name_map) + bootsuf
        if module_name == main_module:
            interface_path = main_path + "." + hisuf
            object_path = main_path + "." + osuf
            hie_path = main_path + ".hie"
        else:
            if module_prefix:
                short_path_stripped = module_prefix.replace(".", "/") + "/" + src.short_path
                interface_path = paths.replace_extension(short_path_stripped, "." + hisuf + bootsuf)
                module_name = "{}.{}".format(module_prefix, module_name)
            else:
                s = src.short_path
                for prefix in ctx.attrs.strip_prefix:
                    s1 = strip_prefix(prefix, src.short_path)
                    if s1 != None:
                        module_name = _strip_prefix(".", _strip_prefix(prefix.replace("/", "."), module_name))
                        s = s1
                        break
                short_path_stripped = _strip_prefix("/", s)
                interface_path = paths.replace_extension(short_path_stripped, "." + hisuf + bootsuf)
            object_path = paths.replace_extension(short_path_stripped, "." + osuf + bootsuf)
            hie_path = paths.replace_extension(short_path_stripped, ".hie")

        interface = ctx.actions.declare_output("mod-" + suffix, interface_path)
        interfaces = [interface]

        object = ctx.actions.declare_output("mod-" + suffix, object_path)
        objects = [object]

        hie_file = ctx.actions.declare_output("mod-" + suffix, hie_path)
        hie_files = [hie_file]

        if ctx.attrs.incremental:
            hash = ctx.actions.declare_output("mod-" + suffix, interface_path + ".hash")
        else:
            hash = None

        if link_style in [LinkStyle("static"), LinkStyle("static_pic")] and not is_worker_execute:
            dyn_osuf, dyn_hisuf = output_extensions(LinkStyle("shared"), enable_profiling)
            if module_name == main_module:
                extra_interface_path = main_path + "." + dyn_hisuf
                extra_object_path = main_path + "." + dyn_osuf
            else:
                extra_interface_path = paths.replace_extension(short_path_stripped, "." + dyn_hisuf + bootsuf)
                extra_object_path = paths.replace_extension(short_path_stripped, "." + dyn_osuf + bootsuf)
            extra_interface = ctx.actions.declare_output("mod-" + suffix, extra_interface_path)
            extra_interfaces = [extra_interface]
            extra_object = ctx.actions.declare_output("mod-" + suffix, extra_object_path)
            extra_objects = [extra_object]
        else:
            extra_interfaces = []
            extra_objects = []

        if ctx.attrs.incremental:
            if bootsuf == "":
                stub_dir = ctx.actions.declare_output("stub-" + suffix + "-" + module_name, dir = True)
            else:
                stub_dir = None
        else:
            stub_dir = None

        prefix_dir = "mod-" + suffix

        modules[module_name] = _Module(
            name = module_name,
            source = src,
            interfaces = interfaces,
            extra_interfaces = extra_interfaces,
            hash = hash,
            objects = objects,
            extra_objects = extra_objects,
            hie_files = hie_files,
            stub_dir = stub_dir,
            prefix_dir = prefix_dir,
        )
    return modules

# Collect the metadata outputs of the transitive closure of the current unit's dependencies.
def transitive_metadata(actions: AnalysisActions, dep_units_file: OutputArtifact, packages_info: PackagesInfo) -> Artifact:
    dep_units = reversed(packages_info.transitive_deps.project_as_json("dep_units", ordering = "topological").traverse())
    return actions.write_json(dep_units_file, dep_units, pretty = True)

# `argfile` for an output declared elsewhere: `argfile` takes a name or an
# `Artifact`, not an `OutputArtifact`.
def _write_argfile(actions: AnalysisActions, output: OutputArtifact, args: cmd_args) -> cmd_args:
    args_file, _ = actions.write(output, args, allow_args = True, with_inputs = True)
    return cmd_args(args_file, hidden = args)

# Static variant of the dependency unit list for the persistent worker's metadata calculation.
def direct_metadata_static(actions: AnalysisActions, pkgname: str, libs: list[HaskellLibraryInfo]) -> cmd_args:
    dep_units_file = actions.declare_output("dep-units-static-{}.json".format(pkgname))
    dep_units = [struct(name = lib.name, build_plan = lib.skeleton) for lib in libs]
    return cmd_args(
        actions.write_json(dep_units_file, dep_units, with_inputs = True, pretty = True),
        prepend = "--dep-units-static",
    )

def add_output_dirs(args: cmd_args, output_dir: cmd_args):
    for dir in ["o", "hi", "hie", "dump"]:
        args.add("-{}dir".format(dir), output_dir)

UnitParams = record(
    name = field(str),
    link_style = field(LinkStyle),
    enable_profiling = field(bool),
    main = field(None | str),
    enable_haddock = field(bool),
    external_tool_paths = field(list[RunInfo]),
    artifact_suffix = field(str),
    haskell_toolchain = field(HaskellToolchainInfo),
    compiler_flags = field(list[str | ResolvedStringWithMacros]),
    is_worker_execute = field(bool),
    # GHC plugin flags applied to all modules in the unit.
    plugin_flags = field(cmd_args | None, default = None),
)

def _add_dynamic_too_if_required(is_worker_execute: bool, link_style: LinkStyle, args: cmd_args) -> bool:
    if link_style in [LinkStyle("static_pic"), LinkStyle("static")] and not is_worker_execute:
        args.add("-dynamic-too")
        return True
    else:
        return False

# Assemble GHC arguments that are specific to a given unit, but not to a module.
# Used for the metadata step as a basis for oneshot mode and as the full argument list for the make mode worker.
# The worker also stores these in the metadata JSON in order to restore the unit state from cache after restarting.
# In oneshot mode, the compile step also uses these arguments.
def unit_ghc_args(actions: AnalysisActions, arg: UnitParams) -> cmd_args:
    args = cmd_args(
        "-no-link",
        "-i",
        "-j",
        "-hide-all-packages",
        "-fwrite-ide-info",
        "-package-env=-",
    )
    args.add(arg.haskell_toolchain.compiler_flags)

    # Plugin flags come before compiler_flags so that user-provided flags
    # appear later on the GHC command line and can override earlier defaults.
    if arg.plugin_flags != None:
        args.add(arg.plugin_flags)

    args.add(arg.compiler_flags)

    args.add("-this-unit-id", arg.name)

    if arg.enable_profiling:
        args.add("-prof")

    if arg.link_style == LinkStyle("shared"):
        args.add("-dynamic", "-fPIC")
    elif arg.link_style == LinkStyle("static_pic"):
        args.add("-fPIC", "-fexternal-dynamic-refs")

    _add_dynamic_too_if_required(arg.is_worker_execute, arg.link_style, args)

    args.add("-fbyte-code-and-object-code")

    osuf, hisuf = output_extensions(arg.link_style, arg.enable_profiling)
    args.add("-osuf", osuf, "-hisuf", hisuf)

    if arg.main != None:
        args.add(["-main-is", arg.main])

    if arg.enable_haddock:
        args.add("-haddock")

    return args

def unit_buck2_args(actions: AnalysisActions, arg: UnitParams) -> cmd_args:
    args = cmd_args()
    args.add(cmd_args(
        arg.external_tool_paths,
        format = "--bin-exe={}",
    ))
    return args

MetadataUnitParams = record(
    unit = field(UnitParams),
    toolchain_libs = field(list[str]),
    deps = field(list[Dependency]),
    direct_extra_libs = field(list[Dependency]),
    is_binary = field(bool),
)

def metadata_unit_args(
        actions: AnalysisActions,
        arg: MetadataUnitParams,
        packages_info: PackagesInfo,
        output: OutputArtifact) -> (cmd_args, cmd_args):
    # Configure all output directories to use e.g. `mod-shared` next to the metadata file (`output`).
    output_dir = cmd_args(
        [cmd_args(output, ignore_artifacts = True, parent = 1), "mod-" + arg.unit.artifact_suffix],
        delimiter = "/",
    )

    ghc_args = unit_ghc_args(actions, arg.unit)

    add_output_dirs(ghc_args, output_dir)

    package_flag = _package_flag(arg.unit.haskell_toolchain)
    ghc_args.add(cmd_args(arg.toolchain_libs, prepend = package_flag))

    if not arg.unit.is_worker_execute:
        ghc_args.add(cmd_args(packages_info.local_packagedb_args, prepend = "-package-db"))
        ghc_args.add(cmd_args(packages_info.exposed_package_args, hidden = packages_info.local_packagedb_args))
    else:
        # Real local package dbs are not inputs because the worker resolves local package flags against the db
        # built from --dep-units-static data.
        ghc_args.add(packages_info.exposed_package_args)

    ghc_args.add(cmd_args(packages_info.packagedb_args, prepend = "-package-db"))
    ghc_args.add("-fprefer-byte-code")
    ghc_args.add("-fpackage-db-byte-code")
    ghc_args.add(packages_info.extra_libs_args)

    buck2_args = unit_buck2_args(actions, arg.unit)

    return (ghc_args, buck2_args)

MetadataParams = record(
    unit = field(MetadataUnitParams),
    direct_deps_link_info = field(list[HaskellLinkInfo]),
    haskell_direct_deps_lib_infos = field(list[HaskellLibraryInfo]),
    md_gen = field(RunInfo),
    sources = field(list[Artifact]),
    strip_prefix = field(str),
    suffix = field(str),
    worker = field(None | WorkerInfo),
    allow_worker = field(bool),
    allow_cache_upload = field(bool),
    label = field(Label),
    incremental = field(bool),
    linker_info = field(typing.Any),
)

def _dynamic_target_metadata_impl(
        actions: AnalysisActions,
        output: OutputArtifact,
        worker_files: dict[str, OutputArtifact],
        arg: MetadataParams,
        pkg_deps: None | ResolvedDynamicValue) -> list[Provider]:
    munit = arg.unit
    unit = munit.unit

    haskell_toolchain = unit.haskell_toolchain

    is_worker_execute = arg.unit.unit.is_worker_execute

    # Add -package-db and -package/-expose-package flags for each Haskell
    # library dependency.

    packages_info = get_packages_info(
        actions,
        arg.label,
        munit.deps,
        munit.direct_extra_libs,
        arg.direct_deps_link_info,
        haskell_toolchain,
        arg.linker_info,
        arg.haskell_direct_deps_lib_infos,
        unit.link_style,
        specify_pkg_version = False,
        enable_profiling = unit.enable_profiling,
        use_empty_lib = True,
        for_deps = True,
        pkg_deps = pkg_deps,
        is_worker_execute = is_worker_execute,
    )
    package_flag = _package_flag(haskell_toolchain)

    (ghc_args, buck2_args) = metadata_unit_args(actions, munit, packages_info, output)

    if is_worker_execute:
        makefile = actions.declare_output(unit.name + ".depends.make")

        ghc_args.add("-include-pkg-deps")
        ghc_args.add("-dep-json", cmd_args(output, ignore_artifacts = True))
        ghc_args.add("-dep-makefile", cmd_args(makefile, ignore_artifacts = True))
        ghc_args.add(cmd_args(arg.sources))

        # The compile requests read these back through the plan; the files
        # are declared by `target_metadata`, see there.
        buck_args_file = _write_argfile(actions, worker_files["buck_args"], buck2_args)
        ghc_args_file = _write_argfile(actions, worker_files["ghc_args"], ghc_args)
    else:
        buck_args_file = argfile(
            actions = actions,
            name = "haskell_metadata_buck2_{}.args".format(unit.name),
            args = buck2_args,
            allow_args = True,
        )
        ghc_args_file = argfile(
            actions = actions,
            name = "haskell_metadata_ghc_{}.args".format(unit.name),
            args = ghc_args,
            allow_args = True,
        )

    if is_worker_execute:
        md_args = cmd_args()
        md_args.add("-M")
        md_args.add("--ghc-dir", haskell_toolchain.ghc_dir)
        add_worker_args(haskell_toolchain, md_args, unit.name)

        md_args.add(buck2_args)

        # Specifying this activates the new build plan logic
        md_args.add("--build-plan", cmd_args(output, ignore_artifacts = True))
        md_args.add("--fields", "exposed_modules,module_graph,package_deps,th_modules,cache")
        md_args.add(direct_metadata_static(actions, unit.name, arg.haskell_direct_deps_lib_infos))
        md_args.add("--unit", unit.name)
        if munit.is_binary:
            md_args.add("--unit-is-binary")
        md_args.add("--unit-buck-args-path", buck_args_file)
        md_args.add("--dep-units-path", transitive_metadata(actions, worker_files["dep_units"], packages_info))
        md_args.add(cmd_args(ghc_args_file, prepend = "--ghc-args", hidden = [output, makefile.as_output()]))

        actions.run(
            md_args,
            category = "haskell_metadata",
            identifier = arg.suffix if arg.suffix else None,
            exe = WorkerRunInfo(worker = arg.worker, exe = worker_fallback(haskell_toolchain)),
            allow_cache_upload = arg.allow_cache_upload,
        )
    else:
        md_args = cmd_args()

        md_args.add("--ghc", haskell_toolchain.compiler)

        md_args.add(cmd_args(ghc_args, format = "--ghc-arg={}"))

        md_args.add(cmd_args(arg.sources, format = "--source={}"))

        md_args.add("--source-prefix", arg.strip_prefix)

        md_args.add("--output", output)

        md_args.add(buck2_args)
        md_args.add("--unit-buck-args", buck_args_file)

        md_args.add("--unit-args", ghc_args_file)

        # We won't need to look at the ghc argsfile later, but the user might!
        md_args.add("--use-ghc-args-file-at", actions.declare_output("ghc-args").as_output())

        md_args_outer = cmd_args(arg.md_gen)
        md_args_outer.add(at_argfile(
            actions = actions,
            name = "dynamic_target_metadata_args",
            args = md_args,
            allow_args = True,
        ))

        actions.run(
            md_args_outer,
            category = "haskell_metadata",
            identifier = arg.suffix if arg.suffix else None,
            allow_cache_upload = arg.allow_cache_upload,
        )

    return []

_dynamic_target_metadata = dynamic_actions(
    impl = _dynamic_target_metadata_impl,
    attrs = {
        "output": dynattrs.output(),
        "worker_files": dynattrs.dict(str, dynattrs.output()),
        "arg": dynattrs.value(MetadataParams),
        "pkg_deps": dynattrs.option(dynattrs.dynamic_value()),
    },
)

def target_metadata(
        ctx: AnalysisContext,
        *,
        link_style: LinkStyle,
        enable_profiling: bool,
        enable_haddock: bool,
        main: None | str,
        is_binary: bool,
        sources: list[Artifact],
        worker: WorkerInfo | None) -> Artifact:
    prof_suffix = "-prof" if enable_profiling else ""
    link_suffix = "-" + link_style.value
    md_file = ctx.actions.declare_output(ctx.label.name + link_suffix + prof_suffix + ".md.json")
    md_gen = ctx.attrs._generate_target_metadata[RunInfo]

    libprefix = repr(ctx.label.path).replace("//", "_").replace("/", "_")

    if getattr(ctx.attrs, "use_same_package_name", None):  # haskell_library case
        (pkgname, libname) = make_haskell_names_from_label(ctx.label, ctx.attrs.use_same_package_name)
    else:  # haskell_binary case
        (pkgname, libname) = make_haskell_names_from_label(ctx.label, False)

    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    linker_info = get_cxx_toolchain_info(ctx).linker_info

    allow_worker = ctx.attrs.allow_worker
    is_worker_execute = check_is_worker_execute(worker, allow_worker, haskell_toolchain.use_worker)

    toolchain_libs = [dep.name for dep in attr_deps_haskell_toolchain_libraries(ctx)]

    haskell_direct_deps_lib_infos = attr_deps_haskell_lib_infos(
        ctx,
        link_style,
        enable_profiling,
    )

    # The object and interface file paths are depending on the real module name
    # as inferred by GHC, not the source file path; currently this requires the
    # module name to correspond to the source file path as otherwise GHC will
    # not be able to find the created object or interface files in the search
    # path.
    #
    # (module X.Y.Z must be defined in a file at X/Y/Z.hs)

    # In worker mode the compile requests restore the unit from the plan, and
    # the plan names these three files of the metadata action by path. A
    # worker that buck2 runs shares buck2's working directory and finds them
    # there; a worker on a remote executor sees the compile action's execution
    # root, which holds the action's inputs and nothing else. So the files
    # become inputs of every action that has the plan as an input, the compile
    # requests first of all, by being associated with the plan. Declared here
    # rather than inside the dynamic action because a dynamic action's own
    # outputs cannot be named before it runs.
    worker_files = {}
    if is_worker_execute:
        prefix = ctx.label.name + link_suffix + prof_suffix
        worker_files = {
            "buck_args": ctx.actions.declare_output(prefix + ".buck2.args"),
            "dep_units": ctx.actions.declare_output(prefix + ".dep-units.json"),
            "ghc_args": ctx.actions.declare_output(prefix + ".ghc.args"),
        }

    ctx.actions.dynamic_output_new(_dynamic_target_metadata(
        pkg_deps = haskell_toolchain.packages.dynamic if haskell_toolchain.packages else None,
        output = md_file.as_output(),
        worker_files = {name: f.as_output() for name, f in worker_files.items()},
        arg = MetadataParams(
            unit = MetadataUnitParams(
                unit = UnitParams(
                    name = pkgname,
                    link_style = link_style,
                    enable_profiling = enable_profiling,
                    enable_haddock = enable_haddock,
                    main = main,
                    external_tool_paths = [tool[RunInfo] for tool in ctx.attrs.external_tools],
                    artifact_suffix = get_artifact_suffix(link_style, enable_profiling),
                    haskell_toolchain = haskell_toolchain,
                    compiler_flags = ctx.attrs.compiler_flags,
                    is_worker_execute = is_worker_execute,
                ),
                toolchain_libs = toolchain_libs,
                deps = attr_deps(ctx),
                direct_extra_libs = ctx.attrs.extra_libraries,
                is_binary = is_binary,
            ),
            direct_deps_link_info = attr_deps_haskell_link_infos(ctx),
            haskell_direct_deps_lib_infos = haskell_direct_deps_lib_infos,
            md_gen = md_gen,
            sources = sources,
            strip_prefix = str(ctx.label.path),
            suffix = link_style.value + ("+prof" if enable_profiling else ""),
            worker = worker,
            allow_worker = allow_worker,
            allow_cache_upload = ctx.attrs.allow_cache_upload,
            label = ctx.label,
            incremental = ctx.attrs.incremental,
            linker_info = linker_info,
        ),
    ))

    return md_file.with_associated_artifacts([src for src in sources if not src.is_source] + worker_files.values())

# List of a unit's modules for the persistent worker's metadata calculation.
def target_skeleton(ctx: AnalysisContext, sources: list[Artifact]) -> Artifact:
    # Mirrors the module naming of _modules_by_name.
    # Boot files are skipped because they are not importable from other units.
    modules = []
    for src in sources:
        if is_haskell_boot(src.short_path) or not is_haskell_src(src.short_path):
            continue

        module_name = src_to_module_name(src.short_path)
        if ctx.attrs.module_prefix:
            module_name = "{}.{}".format(ctx.attrs.module_prefix, module_name)
        else:
            for prefix in ctx.attrs.strip_prefix:
                if strip_prefix(prefix, src.short_path) != None:
                    module_name = _strip_prefix(".", _strip_prefix(prefix.replace("/", "."), module_name))
                    break

        modules.append(module_name)

    skeleton_file = ctx.actions.declare_output("skeleton.json")
    ctx.actions.write_json(skeleton_file, modules, pretty = True)
    return skeleton_file

def _package_flag(toolchain: HaskellToolchainInfo) -> str:
    if toolchain.support_expose_package:
        return "-expose-package"
    else:
        return "-package"

# Get list of extra library artifacts and dynamic value associated with them
def get_extra_lib_info(
        link_style: LinkStyle,
        extra_libraries: list[Dependency]) -> ExtraLibraryInfo:
    extra_libs = []
    extra_lib_dyns = []
    for lib in extra_libraries:
        x = lib[MergedLinkInfo]._infos[to_link_strategy(link_style)].value
        extra_libs.extend([l.lib for l in x.default.linkables])
    extra_lib_dyns = [
        lib[GhcLinkableInfo].extra_ghc_linker_flags_dynamic
        for lib in extra_libraries
    ]
    extra_lib_info = ExtraLibraryInfo(
        extra_libs = dedupe_by_value(extra_libs),
        extra_lib_dyns = dedupe_by_value(extra_lib_dyns),
        as_deps = list(extra_libraries),  # NOTE: Should hold a *copy* of extra_libraries
    )
    return extra_lib_info

def get_packages_info(
        actions: AnalysisActions,
        label: Label,
        deps: list[Dependency],
        direct_extra_libs: list[Dependency],  # extra library dependency of this package
        direct_deps_link_info: list[HaskellLinkInfo],
        haskell_toolchain: HaskellToolchainInfo,
        linker_info: typing.Any,
        haskell_direct_deps_lib_infos: list[HaskellLibraryInfo],
        link_style: LinkStyle,
        specify_pkg_version: bool,
        enable_profiling: bool,
        use_empty_lib: bool,
        pkg_deps: ResolvedDynamicValue | None,
        for_deps: bool,
        is_worker_execute: bool) -> PackagesInfo:
    # Collect library dependencies. Note that these don't need to be in a
    # particular order.
    libs = actions.tset(
        HaskellLibraryInfoTSet,
        children = [
            lib.prof_info[link_style] if enable_profiling else lib.info[link_style]
            for lib in direct_deps_link_info
        ],
    )

    hidden_args = [l for lib in libs.traverse() for l in lib.libs]
    exposed_package_args = cmd_args()

    if for_deps:
        get_db = lambda l: l.deps_db
    elif use_empty_lib:
        get_db = lambda l: l.empty_db
    else:
        get_db = lambda l: l.db

    local_packagedb_args = cmd_args()
    packagedb_args = cmd_args()
    packagedb_set = {}

    for lib in libs.traverse():
        packagedb_set[get_db(lib)] = None
        if not for_deps:
            hidden_args = cmd_args(hidden = [
                lib.interfaces.values(),
                lib.stub_dirs,
                lib.libs,
            ])
            exposed_package_args.add(hidden_args)

    extra_libs_args = cmd_args()
    extra_lib_info_transitive = libs.reduce("extra_libs")
    direct_extra_lib_info = get_extra_lib_info(link_style, direct_extra_libs)
    extra_lib_info = merge_extra_lib_infos(direct_extra_lib_info, extra_lib_info_transitive)
    link_infos = get_link_infos_from_extra_lib_info(actions, label, linker_info, link_style, extra_lib_info)
    for link_info in link_infos:
        for linkable in link_info.linkables:
            if isinstance(linkable, SharedLibLinkable):
                extra_libs_args.add(cmd_args(linkable.lib, format = "-L{}", parent = 1))
                extra_libs_args.add(cmd_args(get_libname(linkable), format = "-l{}"))
            else:
                fail("Unimplemented linkable: {}".format(linkable))

    if pkg_deps:
        toolchain_package_db = pkg_deps.providers[DynamicHaskellToolchainPackageDbInfo].toolchain_packages
    else:
        toolchain_package_db = {}

    direct_toolchain_libs = [
        dep[HaskellToolchainLibrary].name
        for dep in deps
        if HaskellToolchainLibrary in dep
    ]

    toolchain_libs = direct_toolchain_libs + libs.reduce("packages")

    toolchain_package_db_tset = actions.tset(
        HaskellToolchainPackageDbTSet,
        children = [toolchain_package_db[name] for name in toolchain_libs if name in toolchain_package_db],
    )

    # These we need to add for all the packages/dependencies, i.e.
    # direct and transitive (e.g. `fbcode-common-hs-util-hs-array`)
    local_packagedb_args.add(packagedb_set.keys())

    packagedb_args.add(toolchain_package_db_tset.project_as_args("toolchain_package_db"))

    local_package_flag = "-package-id" if is_worker_execute else "-package"

    # Expose only the packages we depend on directly
    for lib in haskell_direct_deps_lib_infos:
        pkg_name = lib.name
        if (specify_pkg_version):
            pkg_name += "-{}".format(lib.version)

        exposed_package_args.add(local_package_flag, pkg_name)

    return PackagesInfo(
        exposed_package_args = exposed_package_args,
        local_packagedb_args = local_packagedb_args,
        packagedb_args = packagedb_args,
        extra_libs_args = extra_libs_args,
        transitive_deps = libs,
    )

CommonCompileModuleArgs = record(
    pkgname = field(str),
    command = field(cmd_args),
    args_for_file = field(cmd_args),
    oneshot_args_for_file = field(cmd_args),
    oneshot_wrapper_args = field(cmd_args),
    common_args_file = field(Artifact),
    package_env_args = field(cmd_args),
    target_deps_args = field(cmd_args),
    toolchain_package_db = field(dict[str, HaskellToolchainPackageDbTSet]),
    # Native libraries of dependency packages (`extra_libraries` reached
    # through `deps`), the artifacts named by the `library-dirs` in their
    # package confs. A Template Haskell module loads them through those confs.
    extra_libs = field(list[Artifact]),
    # Worker mode: what a compile request's server reads to restore a unit it
    # does not hold, and nothing in the module's own arguments names: the
    # transitive dependency units' build plans, each with its metadata files
    # (see `target_metadata`), and the toolchain package dbs the unit's
    # `-package-db` flags list. Empty in one-shot mode.
    unit_inputs = field(cmd_args),
)

def add_worker_args(
        haskell_toolchain: HaskellToolchainInfo,
        command: cmd_args,
        pkgname: str) -> None:
    command.add("--worker-target-id", "singleton")

# `WorkerRunInfo.exe` is what buck2 runs when it does not run the worker: on a
# remote executor, or on a platform without `use_persistent_workers`. The
# toolchain's `worker_client` is that command, a client whose command line is
# the request and whose exit code is the response's; the request's arguments
# follow it unchanged. Without a client the list stays empty, and such an
# action cannot run outside the worker, as before.
def worker_fallback(haskell_toolchain: HaskellToolchainInfo) -> list | RunInfo:
    if haskell_toolchain.worker_client:
        return haskell_toolchain.worker_client
    return []

def make_package_env(
        *,
        actions: AnalysisActions,
        haskell_toolchain: HaskellToolchainInfo,
        label: Label,
        link_style: LinkStyle,
        enable_profiling: bool,
        allow_worker: bool,
        worker: WorkerInfo | None,
        packagedb_args: cmd_args) -> Artifact:
    # TODO[AH] Avoid duplicates and share identical env files.
    #   The set of package-dbs can be known at the package level, not just the
    #   module level. So, we could generate this file outside of the
    #   dynamic_output action.
    package_env_file = actions.declare_output(".".join([
        label.name,
        "package-db",
        output_extensions(link_style, enable_profiling)[1],
        "env",
    ]))
    package_env = cmd_args(delimiter = "\n")

    is_worker_execute = check_is_worker_execute(worker, allow_worker, haskell_toolchain.use_worker)
    if not is_worker_execute:
        package_env.add(cmd_args(
            packagedb_args,
            format = "package-db {}",
        ).relative_to(package_env_file, parent = 1))
    actions.write(
        package_env_file,
        package_env,
    )
    return package_env_file

# Only add RTS argument list markers if the attribute was specified and is nonempty.
def add_rts_flags(args: cmd_args, flags: None | list[str]):
    if flags:
        args.add(["+RTS"] + flags + ["-RTS"])

# Arguments interpreted by `ghc_wrapper` or the worker.
# Since the worker receives arguments in gRPC requests, there is no executable at the head of the list.
# The worker does not need to invoke GHC as a subprocess, so `--ghc` is not needed.
def _common_compile_wrapper_args(
        ghc_wrapper: RunInfo,
        haskell_toolchain: HaskellToolchainInfo,
        pkgname: str,
        is_worker_execute: bool) -> cmd_args:
    args = cmd_args()

    if is_worker_execute:
        add_worker_args(haskell_toolchain, args, pkgname)
    else:
        args.add(ghc_wrapper)
        args.add("--ghc", haskell_toolchain.compiler)

    args.add("--ghc-dir", haskell_toolchain.ghc_dir)

    return args

# This _should_ be `tuple[Artifact, ResolvedDynamicValue]`, but:
#     error: `tuple[]` is implemented only for `tuple[T, ...]`
#
# This _could_ be `tuple[Artifact | ResolvedDynamicValue, ...]` but
# `buildifier` hard-errors when `...` is used.
_DirectDep = typing.Any

def _direct_dep_artifact(dep: _DirectDep) -> Artifact:
    """Get the `Artifact` out of a `_DirectDep`.

    `_DirectDep` is `Any`, so we provide type-annotated accessors for
    `_DirectDep` fields.
    """
    return dep[0]

def _direct_dep_compile_result(dep: _DirectDep) -> DynamicCompileResultInfo:
    """Get the `DynamicCompileResultInfo` out of a `_DirectDep`.

    `_DirectDep` is `Any`, so we provide type-annotated accessors for
    `_DirectDep` fields.
    """
    return dep[1].providers[DynamicCompileResultInfo]

_IndexedPackageDeps = record(
    # this will be deprecated.
    toolchain_deps = list[str],
    # this unified package_deps will be used later on.
    package_deps = list[str],
    exposed_package_modules = list[CompiledModuleTSet],
    exposed_package_dbs = list[Artifact],
)

DepsByNameInfo = record(
    direct = dict[str, _DirectDep],
    toolchain = dict[str, None],
)

ModulePackageDeps = record(
    packages = dict[str, list[str]],  # `dict[pkgname, list[modname]]`
)

def _categorize_package_deps(
        *,
        module_name: str,
        module_package_deps: ModulePackageDeps,
        deps_by_name: DepsByNameInfo) -> _IndexedPackageDeps:
    toolchain_deps = []
    exposed_package_modules = []
    exposed_package_dbs = []

    for (dep_pkgname, dep_modules) in module_package_deps.packages.items():
        if dep_pkgname in deps_by_name.toolchain:
            toolchain_deps.append(dep_pkgname)
        elif dep_pkgname in deps_by_name.direct:
            direct_dep = deps_by_name.direct[dep_pkgname]

            exposed_package_dbs.append(_direct_dep_artifact(direct_dep))

            for dep_modname in dep_modules:
                exposed_package_modules.append(_direct_dep_compile_result(direct_dep).modules[dep_modname])
        else:
            fail("Unknown library dependency '{}' for module '{}'. Add the library to the `deps` attribute".format(dep_pkgname, module_name))

    return _IndexedPackageDeps(
        toolchain_deps = toolchain_deps,
        package_deps = [],
        exposed_package_modules = exposed_package_modules,
        exposed_package_dbs = exposed_package_dbs,
    )

def _categorize_package_deps_oneshot(
        *,
        module_name: str,
        graph_info: GraphInfo,
        deps_by_name: DepsByNameInfo) -> _IndexedPackageDeps:
    tset = graph_info.graph_set.get(module_name)

    categorized = _categorize_package_deps(
        module_name = module_name,
        module_package_deps = ModulePackageDeps(packages = tset.value[1] if tset else {}),
        deps_by_name = deps_by_name,
    )

    package_deps = []
    if tset != None:
        for (p, _) in tset.traverse():
            if p[0] == "_":
                package_deps.append(p[1:])

    return _IndexedPackageDeps(
        toolchain_deps = categorized.toolchain_deps,
        package_deps = package_deps,
        exposed_package_modules = categorized.exposed_package_modules,
        exposed_package_dbs = categorized.exposed_package_dbs,
    )

# This function is from prelude//cxx/preprocessor.bzl only with ctx.actions -> actions
def cxx_merge_cpreprocessors_actions(actions: AnalysisActions, own: list[CPreprocessor], xs: list[CPreprocessorInfo]) -> CPreprocessorInfo:
    kwargs = {"children": [x.set for x in xs]}
    if own:
        kwargs["value"] = own
    return CPreprocessorInfo(
        set = actions.tset(CPreprocessorTSet, **kwargs),
    )

def _common_compile_module_args(
        actions: AnalysisActions,
        *,
        arg: _DynamicDoCompileOptions,
        incremental: bool,
        direct_deps_by_name: dict[str, _DirectDep],
        pkg_deps: ResolvedDynamicValue | None) -> CommonCompileModuleArgs:
    is_worker_execute = arg.is_worker_execute
    unit_params = UnitParams(
        name = arg.pkgname,
        link_style = arg.link_style,
        enable_profiling = arg.enable_profiling,
        enable_haddock = arg.enable_haddock,
        main = arg.main,
        external_tool_paths = arg.external_tool_paths,
        artifact_suffix = get_artifact_suffix(arg.link_style, arg.enable_profiling),
        haskell_toolchain = arg.haskell_toolchain,
        compiler_flags = arg.compiler_flags,
        is_worker_execute = is_worker_execute,
        plugin_flags = arg.unit_plugin_flags,
    )

    non_haskell_sources = [
        src
        for (path, src) in srcs_to_pairs(arg.sources)
        if not is_haskell_src(path) and not is_haskell_boot(path)
    ]

    # These arguments are used in both modes and can be passed in an argsfile.
    args_for_file = cmd_args([], hidden = non_haskell_sources)

    # These arguments are only for oneshot mode, as opposed to the worker's make mode.
    oneshot_args_for_file = unit_ghc_args(actions, unit_params)

    # Also oneshot-specific, but either consumed by `ghc_wrapper` or impossible to be passed as a response file, like
    # RTS options.
    oneshot_wrapper_args = unit_buck2_args(actions, unit_params)

    # These arguments are not intended for GHC, but for either `ghc_wrapper` or the worker.
    command = _common_compile_wrapper_args(arg.ghc_wrapper, arg.haskell_toolchain, arg.pkgname, is_worker_execute)

    if not is_worker_execute:
        # Some rules pass in RTS (e.g. `+RTS ... -RTS`) options for GHC, which can't
        # be parsed when inside an argsfile.
        add_rts_flags(oneshot_wrapper_args, arg.haskell_toolchain.ghc_rts_flags)
        add_rts_flags(oneshot_wrapper_args, arg.ghc_rts_flags)

        oneshot_args_for_file.add("-c")

    # Add args from preprocess-able inputs.
    inherited_pre = cxx_inherited_preprocessor_infos(arg.deps)
    pre = cxx_merge_cpreprocessors_actions(actions, [], inherited_pre)
    pre_args = pre.set.project_as_args("args")
    args_for_file.add(cmd_args(pre_args, format = "-optP={}"))

    if arg.haskell_toolchain.packages:
        toolchain_package_db = pkg_deps.providers[DynamicHaskellToolchainPackageDbInfo].toolchain_packages
    else:
        toolchain_package_db = []

    # `link_args` only covers this unit's own `extra_libraries`. The ones of
    # dependency packages reach GHC through the `library-dirs` and
    # `extra-libraries` of their package confs, which name the directory each
    # library sits in without making it an input. On a remote worker the conf is
    # there and the directory is empty, so GHC falls back to dlopen("libfoo.so")
    # against the worker's system paths and, under -Werror, fails on
    # -Wmissed-extra-shared-lib. Locally the whole buck-out masks this.
    extra_libs = actions.tset(HaskellLibraryInfoTSet, children = arg.direct_deps_info).reduce("extra_libs").extra_libs

    libs = actions.tset(HaskellLibraryInfoTSet, children = arg.direct_deps_info)

    direct_toolchain_libs = [
        dep[HaskellToolchainLibrary].name
        for dep in arg.deps
        if HaskellToolchainLibrary in dep
    ]
    toolchain_libs = direct_toolchain_libs + libs.reduce("packages") + arg.plugin_toolchain_deps

    toolchain_package_db_tset = actions.tset(
        HaskellToolchainPackageDbTSet,
        children = [toolchain_package_db[name] for name in toolchain_libs if name in toolchain_package_db],
    )

    if is_worker_execute:
        package_env_args = cmd_args()

        # The server restores the unit from the plan the request names, with
        # the arguments the metadata step wrote for it, and initialises GHC's
        # unit state from them: it reads the dependency units' plans and args
        # files, then opens every package db the unit's `-package-db` flags
        # name. The module's own arguments name none of those, so a compile
        # action on a remote executor has to list them as inputs or its
        # execution root lacks them; a worker buck2 runs shares buck2's
        # working directory and never notices. A plan carries its args files
        # as associated artifacts (see `target_metadata`).
        unit_inputs = cmd_args(hidden = [
            libs.project_as_args("build_plans"),
            toolchain_package_db_tset.project_as_args("toolchain_package_db"),
        ])
    else:
        unit_inputs = cmd_args()

        # Add -package-db and -package/-expose-package flags for each Haskell
        # library dependency.

        if incremental:
            packagedb_args = cmd_args(libs.project_as_args("empty_package_db"))
        else:
            all_link_group_ids = [l.id for lg in arg.link_group_libs for l in lg.libraries]
            packagedb_args = cmd_args()
            for d in list(libs.traverse()):
                if d.name in all_link_group_ids:
                    packagedb_args.add(cmd_args(d.empty_db))
                else:
                    packagedb_args.add(cmd_args(d.db))
        for lg in arg.link_group_libs:
            packagedb_args.add(cmd_args(lg.db))

        packagedb_args.add(toolchain_package_db_tset.project_as_args("toolchain_package_db"))

        package_env_file = make_package_env(
            actions = actions,
            haskell_toolchain = arg.haskell_toolchain,
            label = arg.label,
            link_style = arg.link_style,
            enable_profiling = arg.enable_profiling,
            allow_worker = arg.allow_worker,
            worker = arg.worker,
            packagedb_args = packagedb_args,
        )
        package_env_args = cmd_args(
            package_env_file,
            prepend = "-package-env",
            hidden = packagedb_args,
        )

    # target-level dependencies. needed for non-incremental build.
    target_deps_args = cmd_args()

    if not is_worker_execute:
        for pkg in arg.toolchain_deps_by_name:
            target_deps_args.add(cmd_args(pkg, prepend = "-package"))

        for pkg in direct_deps_by_name:
            target_deps_args.add(cmd_args(pkg, prepend = "-package"))

    # This file is passed as hidden dependencies for make-mode persistent worker
    # since unit params are loaded only once per unit, so the params are not passed
    # explicitly for each module build, but still need to trigger rebuilds when changed.
    common_args_file = actions.declare_output("common_shared.args")
    actions.write(
        common_args_file.as_output(),
        cmd_args(args_for_file, oneshot_args_for_file, oneshot_wrapper_args),
        allow_args = True,
    )

    return CommonCompileModuleArgs(
        pkgname = arg.pkgname,
        command = command,
        args_for_file = args_for_file,
        oneshot_args_for_file = oneshot_args_for_file,
        oneshot_wrapper_args = oneshot_wrapper_args,
        common_args_file = common_args_file,
        package_env_args = package_env_args,
        target_deps_args = target_deps_args,
        toolchain_package_db = toolchain_package_db,
        extra_libs = extra_libs,
        unit_inputs = unit_inputs,
    )

# Arguments for GHC when running in oneshot mode.
def _compile_oneshot_args(
        actions: AnalysisActions,
        common_args: CommonCompileModuleArgs,
        is_worker_execute: bool,
        link_style: LinkStyle,
        link_args: ArgLike,
        enable_th: bool,
        module: _Module,
        md_file: Artifact,
        outputs: ArtifactOutputMap,
        artifact_suffix: str,
        package_deps: list[str],
        packagedb_tag: ArtifactTag) -> cmd_args:
    args = cmd_args()
    args.add(packagedb_tag.tag_artifacts(common_args.package_env_args))

    outputs_dict = outputs.outputs
    objects = [outputs_dict[obj] for obj in module.objects]
    extra_objects = [outputs_dict[obj] for obj in module.extra_objects]
    his = [outputs_dict[hi] for hi in module.interfaces]
    extra_his = [outputs_dict[hi] for hi in module.extra_interfaces]
    hies = [outputs_dict[hie] for hie in module.hie_files]

    args.add("-o", objects[0])
    if not hies:
        args.add(cmd_args("-ohi", his[0]))
    else:
        args.add(cmd_args("-ohi", his[0], hidden = [hies[0]]))

    output_dir = cmd_args([cmd_args(md_file, ignore_artifacts = True, parent = 1), module.prefix_dir], delimiter = "/")
    add_output_dirs(args, output_dir)

    if enable_th:
        args.add("-fprefer-byte-code")
        args.add("-fpackage-db-byte-code")

        # The splices run in this process and load every package they reach,
        # native libraries included; see `CommonCompileModuleArgs.extra_libs`.
        args.add(cmd_args(hidden = common_args.extra_libs))

    if module.stub_dir != None:
        stubs = outputs_dict[module.stub_dir]
        args.add("-stubdir", stubs)

    is_dynamic_too_added = _add_dynamic_too_if_required(is_worker_execute, link_style, args)
    if is_dynamic_too_added:
        args.add("-dyno", extra_objects[0])
        args.add("-dynohi", extra_his[0])

    args.add(link_args)

    args.add(
        cmd_args(
            cmd_args(md_file, format = "-i{}", ignore_artifacts = True, parent = 1),
            "/",
            module.prefix_dir,
            delimiter = "",
        ),
    )

    args.add(cmd_args(package_deps, prepend = "-package"))

    args.add(module.source)
    return args

# Arguments for `ghc_wrapper` or the worker when running in oneshot mode.
def _wrapper_oneshot_args(
        actions: AnalysisActions,
        link_style: LinkStyle,
        enable_profiling: bool,
        label: Label,
        module_name: str,
        dependency_modules: CompiledModuleTSet,
        src_envs: None | dict[str, ArgLike],
        packagedb_tag: ArtifactTag):
    args = cmd_args()
    args.add(cmd_args(dependency_modules.reduce("packagedb_deps").keys(), prepend = "--buck2-package-db"))

    dep_file = actions.declare_output(".".join([
        label.name,
        module_name or "pkg",
        "package-db",
        output_extensions(link_style, enable_profiling)[1],
        "dep",
    ])).as_output()
    tagged_dep_file = packagedb_tag.tag_artifacts(dep_file)
    args.add("--buck2-packagedb-dep", tagged_dep_file)

    # Environment variables are configured per module, and they are global to a process.
    # The worker runs in a single process per target or build, so these would be shared with other modules.
    # Furthermore, lots of entries here would cause high memory usage spikes in the worker, since these have to be
    # decoded as Strings.
    if src_envs:
        for k, v in src_envs.items():
            args.add(cmd_args(
                k,
                format = "--extra-env-key={}",
            ))
            args.add(cmd_args(
                v,
                format = "--extra-env-value={}",
            ))
    return args

# Arguments for the worker when running in make mode.
def _compile_make_args(
        common_args: CommonCompileModuleArgs,
        module_name: str,
        module: _Module,
        outputs: ArtifactOutputMap,
        md_file: Artifact) -> cmd_args:
    return cmd_args(
        "--unit",
        common_args.pkgname,
        "--module",
        module_name,
        "--home-unit",
        md_file,
        "-c",
        hidden = [
            common_args.common_args_file,
            common_args.unit_inputs,
            _get_module_outputs(module, outputs),
            module.source,
        ],
    )

# Arguments for `ghc_wrapper` or the worker needed in both modes.
def _shared_wrapper_args(
        tagged_dep_file: TaggedCommandLine | TaggedValue,
        module: _Module,
        outputs: ArtifactOutputMap) -> cmd_args:
    args = cmd_args()
    args.add("--buck2-dep", tagged_dep_file)
    args.add("--abi-out", outputs.outputs[module.hash])
    return args

def _compile_module(
        actions: AnalysisActions,
        *,
        common_args: CommonCompileModuleArgs,
        link_style: LinkStyle,
        link_args: ArgLike,
        enable_profiling: bool,
        enable_th: bool,
        haskell_toolchain: HaskellToolchainInfo,
        label: Label,
        module_name: str,
        module: _Module,
        module_tsets: DynamicCompileResultInfo,
        md_file: Artifact,
        graph_info: GraphInfo,
        outputs: ArtifactOutputMap,  #dict[Artifact, OutputArtifact],
        artifact_suffix: str,
        deps_by_name: DepsByNameInfo,
        aux_deps: None | list[Artifact],
        src_envs: None | dict[str, ArgLike],
        worker: None | WorkerInfo,
        allow_worker: bool,
        allow_cache_upload: bool,
        module_package_deps: ModulePackageDeps | None = None,
        module_plugin_flags: cmd_args | None = None,
        module_plugin_tool_paths: typing.Any = None) -> CompiledModuleTSet:
    is_worker_execute = check_is_worker_execute(worker, allow_worker, haskell_toolchain.use_worker)

    abi_tag = actions.artifact_tag()
    packagedb_tag = actions.artifact_tag()

    if is_worker_execute:
        categorized_package_deps = _categorize_package_deps(
            module_name = module_name,
            module_package_deps = module_package_deps,
            deps_by_name = deps_by_name,
        )
    else:
        categorized_package_deps = _categorize_package_deps_oneshot(
            module_name = module_name,
            graph_info = graph_info,
            deps_by_name = deps_by_name,
        )

    toolchain_deps = categorized_package_deps.toolchain_deps
    hidden_toolchain_deps = []
    for p in toolchain_deps:
        pkg = common_args.toolchain_package_db.get(p)
        if pkg:
            hidden_toolchain_deps.append(pkg.value.path)

    # Transitive module dependencies from other packages.
    cross_package_modules = actions.tset(
        CompiledModuleTSet,
        children = categorized_package_deps.exposed_package_modules,
    )

    # Transitive module dependencies from the same package.
    this_package_modules = [
        module_tsets.modules[dep_name]
        for dep_name in graph_info.graph[module_name]
    ]

    dependency_modules = actions.tset(
        CompiledModuleTSet,
        children = [cross_package_modules] + this_package_modules,
    )

    tagged_dep_file = abi_tag.tag_artifacts(
        actions.declare_output("dep-{}_{}".format(module_name, artifact_suffix)).as_output(),
    )

    # ----------------------------------------------------------------------------------------------------

    # These arguments for `ghc_wrapper`/the worker can be passed in a response file.
    wrapper_args_for_file = _shared_wrapper_args(tagged_dep_file, module, outputs)

    # These compiler arguments can be passed in a response file.
    compile_args_for_file = cmd_args(common_args.args_for_file, hidden = aux_deps or [])

    compile_cmd_args = cmd_args()

    # For the make worker, options related to local package dependencies need to be omitted entirely, since it uses the
    # unit env instead of package DBs to load them.
    if is_worker_execute:
        wrapper_args_for_file.add(_compile_make_args(
            common_args = common_args,
            module_name = module_name,
            module = module,
            outputs = outputs,
            md_file = md_file,
        ))

        # The splices run in the server and load every native library the
        # unit's `-l` flags name, this unit's own (`link_args`) and its
        # dependencies' (`extra_libs`), the way `_compile_oneshot_args` makes
        # them inputs of a one-shot compile.
        if enable_th:
            wrapper_args_for_file.add(cmd_args(hidden = [common_args.extra_libs, link_args]))

        # The make worker does not support stub dirs at the moment, so we create it directly.
        # Since the entire module graph's flags are supposed to be fully initialized in the metadata step, we can't pass
        # any module-specific args to the worker (or rather, the worker ignores them in that case).
        if module.stub_dir != None:
            stubs = outputs.outputs[module.stub_dir]
            actions.run(
                cmd_args(["bash", "-euc", "mkdir -p \"$0\"", stubs]),
                category = "haskell_stubs",
                identifier = "worker-dummy-stubdir-{}-{}".format(module_name, artifact_suffix),
                local_only = True,
                # FIXME(jadel): determine whether this is safe to upload to cache
                allow_cache_upload = False,
            )

        dep_files = {
            "abi": abi_tag,
        }
    else:
        compile_args_for_file.add(common_args.oneshot_args_for_file)
        compile_args_for_file.add(_compile_oneshot_args(
            actions,
            common_args = common_args,
            is_worker_execute = is_worker_execute,
            link_style = link_style,
            link_args = link_args,
            enable_th = enable_th,
            module = module,
            md_file = md_file,
            outputs = outputs,
            artifact_suffix = artifact_suffix,
            package_deps = categorized_package_deps.package_deps,
            packagedb_tag = packagedb_tag,
        ))

        wrapper_args_for_file.add(_wrapper_oneshot_args(
            actions,
            link_style = link_style,
            enable_profiling = enable_profiling,
            label = label,
            module_name = module_name,
            dependency_modules = dependency_modules,
            src_envs = src_envs,
            packagedb_tag = packagedb_tag,
        ))

        compile_cmd_args.add(common_args.oneshot_wrapper_args)

        dep_files = {
            "abi": abi_tag,
            "packagedb": packagedb_tag,
        }

    # Add per-module plugin flags (from srcs_plugins).
    # These are module-specific flags that we add after the unit-level compiler_flags
    # in common_args.oneshot_args_for_file. In practice, this order should not make
    # much difference to compilation.
    if module_plugin_flags != None:
        compile_args_for_file.add(module_plugin_flags)

    # Add per-module plugin tool paths as --bin-exe= args so only the modules
    # that use srcs_plugins depend on the corresponding tool executables.
    if module_plugin_tool_paths != None:
        for tool_run_info in module_plugin_tool_paths:
            wrapper_args_for_file.add(cmd_args(tool_run_info, format = "--bin-exe={}"))

    category_prefix = "haskell_compile_" + artifact_suffix.replace("-", "_")

    if not is_worker_execute:
        wrapper_args_for_file.add(cmd_args(argfile(
            actions = actions,
            name = "{}_{}_ghc.argsfile".format(category_prefix, module_name),
            args = compile_args_for_file,
            allow_args = True,
        ), prepend = "--ghc-argsfile"))
        compile_cmd_args.add(at_argfile(
            actions = actions,
            name = "{}_{}.argsfile".format(category_prefix, module_name),
            args = wrapper_args_for_file,
            allow_args = True,
        ))
    else:
        # TODO: Is there a reason we can't use argfiles when using the worker?
        compile_cmd_args.add(wrapper_args_for_file)
        compile_cmd_args.add(compile_args_for_file)

    worker_args = {}
    if worker != None and is_worker_execute:
        worker_args["exe"] = WorkerRunInfo(worker = worker, exe = worker_fallback(haskell_toolchain))

    actions.run(
        cmd_args(
            common_args.command,
            compile_cmd_args,
            hidden = [
                abi_tag.tag_artifacts(dependency_modules.project_as_args("interfaces")),
                dependency_modules.project_as_args("abi"),
            ] + hidden_toolchain_deps,
        ),
        category = "haskell_compile_" + artifact_suffix.replace("-", "_"),
        identifier = module_name,
        dep_files = dep_files,
        allow_cache_upload = allow_cache_upload,
        **worker_args
    )

    module_tset = actions.tset(
        CompiledModuleTSet,
        value = CompiledModuleInfo(
            package = common_args.pkgname,
            name = module.name,
            abi = module.hash,
            interfaces = module.interfaces,
            hie_files = module.hie_files,
            db_deps = categorized_package_deps.exposed_package_dbs,
        ),
        children = [cross_package_modules] + this_package_modules,
    )

    return module_tset

def _get_module_from_map(mapped_modules: dict[str, _Module], module_name: str) -> _Module:
    module = mapped_modules.get(module_name)
    if module == None:
        mapped_module_names = list(mapped_modules.keys())
        if len(mapped_module_names) > 32:
            truncated_list = mapped_module_names[:32]
            available_names = "{} (and {} more)".format(truncated_list, len(mapped_module_names) - 32)
        else:
            available_names = str(mapped_module_names)
        fail("Can't compile module `{}` as it's not in the module map. Available module names are: {}".format(module_name, available_names))
    return module

# Compile incrementally and fill module_tsets accordingly.
def _compile_incr(
        actions: AnalysisActions,
        # Note: `module_tsets` is always empty in practice, but this must
        # correspond to `DynamicCompileResultInfo.modules`.
        module_tsets: DynamicCompileResultInfo,
        arg: _DynamicDoCompileOptions,
        common_args: CommonCompileModuleArgs,
        graph_info: GraphInfo,
        mapped_modules: dict[str, _Module],
        th_modules: list[str],
        package_deps: dict[str, dict[str, list[str]]],  # `dict[modname, dict[pkgname, list[modname]]`
        direct_deps_by_name: dict[str, _DirectDep],
        outputs: ArtifactOutputMap) -> None:
    is_worker_execute = check_is_worker_execute(arg.worker, arg.allow_worker, arg.haskell_toolchain.use_worker)
    deps_by_name = DepsByNameInfo(
        direct = direct_deps_by_name,
        toolchain = arg.toolchain_deps_by_name,
    )

    for module_name in post_order_traversal(graph_info.graph):
        module = _get_module_from_map(mapped_modules, module_name)
        module_tsets.modules[module_name] = _compile_module(
            actions,
            aux_deps = arg.sources_deps.get(module.source),
            src_envs = arg.srcs_envs.get(module.source),
            common_args = common_args,
            link_style = arg.link_style,
            link_args = arg.link_args,
            enable_profiling = arg.enable_profiling,
            enable_th = module_name in th_modules,
            haskell_toolchain = arg.haskell_toolchain,
            label = arg.label,
            module_name = module_name,
            module = module,
            module_tsets = module_tsets,
            graph_info = graph_info,
            outputs = outputs,
            md_file = arg.md_file,
            artifact_suffix = arg.artifact_suffix,
            deps_by_name = deps_by_name,
            worker = arg.worker,
            allow_worker = arg.allow_worker,
            allow_cache_upload = arg.allow_cache_upload,
            module_package_deps = ModulePackageDeps(packages = package_deps.get(module_name, {})),
            module_plugin_flags = arg.srcs_plugin_flags.get(module.source),
            module_plugin_tool_paths = arg.srcs_plugin_tool_paths.get(module.source),
        )

def compile_args_for_non_incr(
        actions: AnalysisActions,
        label: Label,
        haskell_toolchain: HaskellToolchainInfo,
        linker_info: typing.Any,
        md_file: Artifact,
        compiler_flags: list[typing.Any],  # Arguments.
        main: str | None,
        deps: list[Dependency],
        direct_extra_libs: list[Dependency],
        sources: list[typing.Any],  # Source.
        external_tool_paths: list[RunInfo],
        link_style: LinkStyle,
        is_worker_execute: bool,
        link_args: ArgLike,
        enable_profiling: bool,
        direct_deps_link_info: list[HaskellLinkInfo],
        haskell_direct_deps_lib_infos: list[HaskellLibraryInfo],
        package_env_args: cmd_args,
        target_deps_args: cmd_args,
        link_group_libs: list[HaskellLinkGroupProvider],
        pkgname = None,
        suffix: str = "",
        plugin_flags = None) -> cmd_args:
    args = cmd_args()
    args.add(haskell_toolchain.compiler_flags)

    # Plugin flags come before compiler_flags so that user-provided flags
    # appear later on the GHC command line.
    if plugin_flags != None:
        args.add(plugin_flags)

    # Some rules pass in RTS (e.g. `+RTS ... -RTS`) options for GHC, which can't
    # be parsed when inside an argsfile.
    args.add(compiler_flags)

    # `extra-libraries` or other linker flags.
    args.add(link_args)

    args.add("-fbyte-code-and-object-code")
    args.add("-fprefer-byte-code")
    args.add("-fpackage-db-byte-code")
    args.add("-j")

    args.add("-no-link", "-i")

    args.add(package_env_args)
    args.add(target_deps_args)

    if enable_profiling:
        args.add("-prof")

    if link_style == LinkStyle("shared"):
        args.add("-dynamic", "-fPIC")
    elif link_style == LinkStyle("static_pic"):
        args.add("-fPIC", "-fexternal-dynamic-refs")

    _add_dynamic_too_if_required(is_worker_execute, link_style, args)

    osuf, hisuf = output_extensions(link_style, enable_profiling)
    args.add("-osuf", osuf, "-hisuf", hisuf)

    if main != None:
        args.add(["-main-is", main])

    artifact_suffix = get_artifact_suffix(link_style, enable_profiling, suffix)

    for dir in ["o", "hi", "hie"]:
        args.add(
            "-{}dir".format(dir),
            cmd_args([cmd_args(md_file, ignore_artifacts = True, parent = 1), "mod-" + artifact_suffix], delimiter = "/"),
        )

    # Add -package-db and -package/-expose-package flags for each Haskell
    # library dependency.
    packages_info = get_packages_info(
        actions,
        label,
        deps,
        direct_extra_libs,
        direct_deps_link_info,
        haskell_toolchain,
        linker_info,
        haskell_direct_deps_lib_infos,
        LinkStyle("shared"),
        specify_pkg_version = False,
        enable_profiling = enable_profiling,
        use_empty_lib = False,
        for_deps = False,
        pkg_deps = None,
        is_worker_execute = is_worker_execute,
    )

    args.add(packages_info.exposed_package_args)

    # Inputs only: the native libraries of dependency packages, which the
    # Template Haskell splices in this unit load through the package confs.
    args.add(cmd_args(hidden = packages_info.extra_libs_args))

    # handle link group

    for lg in link_group_libs:
        args.add(cmd_args(lg.db, prepend = "-package-db"))
        args.add(cmd_args(lg.pkgname, prepend = "-package", hidden = [lg.lib]))

    # Add args from preprocess-able inputs.
    inherited_pre = cxx_inherited_preprocessor_infos(deps)
    pre = cxx_merge_cpreprocessors_actions(actions, [], inherited_pre)
    pre_args = pre.set.project_as_args("args")
    args.add(cmd_args(pre_args, format = "-optP={}"))

    args.add(cmd_args(
        external_tool_paths,
        format = "--bin-exe={}",
    ))

    if pkgname:
        args.add(["-this-unit-id", pkgname])

    for (path, src) in srcs_to_pairs(sources):
        # hs-boot files aren't expected to be an argument to compiler but does need
        # to be included in the directory of the associated src file
        if is_haskell_src(path):
            args.add(src)
        else:
            args.add(hidden = src)

    producing_indices = "-fwrite-ide-info" in compiler_flags

    return args

def _make_module_tsets_non_incr(
        actions: AnalysisActions,
        module: _Module,
        graph_info: GraphInfo,
        toolchain_deps_by_name: dict[str, None],
        direct_deps_by_name: dict[str, _DirectDep],
        name: str,
        pkgname: str) -> CompiledModuleTSet:
    categorized_package_deps = _categorize_package_deps_oneshot(
        module_name = name,
        graph_info = graph_info,
        deps_by_name = DepsByNameInfo(
            direct = direct_deps_by_name,
            toolchain = toolchain_deps_by_name,
        ),
    )

    # Transitive module dependencies from other packages.
    cross_package_modules = actions.tset(
        CompiledModuleTSet,
        children = categorized_package_deps.exposed_package_modules,
    )

    module_tsets = actions.tset(
        CompiledModuleTSet,
        value = CompiledModuleInfo(
            name = name,
            package = pkgname,
            abi = module.hash,
            interfaces = module.interfaces,
            hie_files = module.hie_files,
            db_deps = categorized_package_deps.exposed_package_dbs,
        ),
        children = [cross_package_modules],
    )
    return module_tsets

# Compile in one step all the context's sources
def _compile_non_incr(
        actions: AnalysisActions,
        # Note: `module_tsets` is always empty in practice, but this must
        # correspond to `DynamicCompileResultInfo.modules`.
        module_tsets: DynamicCompileResultInfo,
        arg: _DynamicDoCompileOptions,
        common_args: CommonCompileModuleArgs,
        graph_info: GraphInfo,
        mapped_modules: dict[str, _Module],
        th_modules: list[str],
        package_deps: dict[str, dict[str, list[str]]],  # `dict[modname, dict[pkgname, list[modname]]`
        direct_deps_by_name: dict[str, _DirectDep],
        outputs: ArtifactOutputMap) -> None:
    haskell_toolchain = arg.haskell_toolchain
    link_style = arg.link_style
    enable_profiling = arg.enable_profiling

    args = cmd_args(hidden = outputs.outputs.values())
    args.add("--ghc", haskell_toolchain.compiler)
    args.add(
        compile_args_for_non_incr(
            actions,
            arg.label,
            haskell_toolchain = haskell_toolchain,
            linker_info = arg.linker_info,
            md_file = arg.md_file,
            compiler_flags = arg.compiler_flags,
            main = arg.main,
            deps = arg.deps,
            direct_extra_libs = arg.direct_extra_libs,
            sources = arg.sources,
            external_tool_paths = arg.external_tool_paths,
            link_style = link_style,
            is_worker_execute = False,  # non-incr build is always non-worker.
            link_args = arg.link_args,
            direct_deps_link_info = arg.direct_deps_link_info,
            haskell_direct_deps_lib_infos = arg.haskell_direct_deps_lib_infos,
            enable_profiling = enable_profiling,
            package_env_args = common_args.package_env_args,
            target_deps_args = common_args.target_deps_args,
            link_group_libs = arg.link_group_libs,
            pkgname = arg.pkgname,
            plugin_flags = arg.unit_plugin_flags,
        ),
    )

    artifact_suffix = get_artifact_suffix(link_style, enable_profiling)

    for module_name in post_order_traversal(graph_info.graph):
        module = _get_module_from_map(mapped_modules, module_name)
        module_tsets.modules[module_name] = _make_module_tsets_non_incr(
            actions,
            module = module,
            graph_info = graph_info,
            toolchain_deps_by_name = arg.toolchain_deps_by_name,
            direct_deps_by_name = direct_deps_by_name,
            name = module_name,
            pkgname = arg.pkgname,
        )
        for deps in module_tsets[module_name].children:
            args.add(cmd_args(hidden = deps.project_as_args("interfaces")))

    category = "haskell_compile_" + artifact_suffix.replace("-", "_")

    actions.run(
        cmd_args(
            arg.ghc_wrapper,
            at_argfile(
                actions = actions,
                name = "{}.argsfile".format(category),
                args = args,
                allow_args = True,
            ),
        ),
        category = category,
        # FIXME(jadel): determine whether this is safe to upload to cache
        allow_cache_upload = False,
        # We can't use no_outputs_cleanup because GHC's recompilation checking
        # is based on file timestamps, and Buck doesn't maintain timestamps when
        # artifacts may come from RE.
        # TODO: enable this for GHC 9.4 which tracks file changes using hashes
        # not timestamps.
        # no_outputs_cleanup = True,
    )

def _dynamic_do_compile_impl(
        actions: AnalysisActions,
        incremental: bool,
        md_file: ArtifactValue,
        arg: _DynamicDoCompileOptions,
        pkg_deps: ResolvedDynamicValue | None,
        outputs_dict: dict[Artifact, OutputArtifact],
        direct_deps_by_name: dict[str, _DirectDep]) -> list[Provider]:
    common_args = _common_compile_module_args(
        actions,
        arg = arg,
        incremental = incremental,
        direct_deps_by_name = direct_deps_by_name,
        pkg_deps = pkg_deps,
    )

    # See `./tools/generate_target_metadata.py` for schema information.
    md = md_file.read_json()
    th_modules = md["th_modules"]
    module_map = md_module_mapping(md)
    module_graph = md["module_graph"]
    package_deps = md["package_deps"]

    mapped_modules = {module_map.get(k, k): v for k, v in arg.modules.items()}

    # NOTE: This function needs to be defined as internal function since the
    # free variables, module_graph and package_deps, are shared captured state
    # in the recursive function closure. Due to the limitation of Starlark,
    # if they are passed around as arguments alternatively like normal functional
    # programming language, then the performance gets very bad.
    def _create_graph_set(module_name: str) -> ModGraphTSet:
        if graph_set.get(module_name):
            return graph_set.get(module_name)
        else:
            deps = module_graph.get(module_name, [])
            children = []
            mod_pkg_deps = package_deps.get(module_name, {})
            for pkg in mod_pkg_deps.keys():
                pkg_key = "_" + pkg
                if graph_set.get(pkg_key):
                    pkg_tset = graph_set.get(pkg_key)
                else:
                    pkg_tset = actions.tset(ModGraphTSet, value = (pkg_key, {}), children = [])
                    graph_set[pkg_key] = pkg_tset
                children.append(pkg_tset)

            if deps:  # not leaf
                for dep in deps:
                    dep_tset = _create_graph_set(dep)
                    children.append(dep_tset)
            tset = actions.tset(ModGraphTSet, value = (module_name, mod_pkg_deps), children = children)
            graph_set[module_name] = tset
            return tset

    is_worker_execute = check_is_worker_execute(arg.worker, arg.allow_worker, arg.haskell_toolchain.use_worker)
    graph_set = {}
    if not is_worker_execute:
        for m in module_graph.keys():
            xs = _create_graph_set(m)

    module_tsets = DynamicCompileResultInfo(modules = {})
    outputs = ArtifactOutputMap(outputs = outputs_dict)
    if incremental:
        _compile_incr(
            actions,
            module_tsets,
            arg,
            common_args,
            GraphInfo(
                graph = module_graph,
                graph_set = graph_set,
            ),
            mapped_modules,
            th_modules,
            package_deps,
            direct_deps_by_name,
            outputs,
        )
    else:
        _compile_non_incr(
            actions,
            module_tsets,
            arg,
            common_args,
            GraphInfo(
                graph = module_graph,
                graph_set = graph_set,
            ),
            mapped_modules,
            th_modules,
            package_deps,
            direct_deps_by_name,
            outputs,
        )

    return [module_tsets]

_dynamic_do_compile = dynamic_actions(
    impl = _dynamic_do_compile_impl,
    attrs = {
        "incremental": dynattrs.value(bool),
        "md_file": dynattrs.artifact_value(),
        "arg": dynattrs.value(_DynamicDoCompileOptions),
        "pkg_deps": dynattrs.option(dynattrs.dynamic_value()),
        "outputs_dict": dynattrs.dict(Artifact, dynattrs.output()),
        "direct_deps_by_name": dynattrs.dict(str, dynattrs.tuple(dynattrs.value(Artifact), dynattrs.dynamic_value())),
    },
)

# Compile all the context's sources.
def compile(
        ctx: AnalysisContext,
        link_style: LinkStyle,
        enable_profiling: bool,
        enable_haddock: bool,
        md_file: Artifact,
        pkgname: str,
        worker: WorkerInfo | None = None,
        incremental: bool = False,
        is_haskell_binary: bool = False,
        src_main: Artifact | None = None,
        unit_plugin_flags = None,
        srcs_plugin_flags = {},
        extra_tool_paths = [],
        srcs_plugin_tool_paths = {},
        plugin_toolchain_deps = []) -> CompileResultInfo:
    artifact_suffix = get_artifact_suffix(link_style, enable_profiling)

    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    linker_info = get_cxx_toolchain_info(ctx).linker_info

    is_worker_execute = check_is_worker_execute(worker, ctx.attrs.allow_worker, haskell_toolchain.use_worker)

    modules = _modules_by_name(
        ctx,
        sources = ctx.attrs.srcs,
        is_worker_execute = is_worker_execute,
        link_style = link_style,
        enable_profiling = enable_profiling,
        suffix = artifact_suffix,
        module_prefix = ctx.attrs.module_prefix,
        is_haskell_binary = is_haskell_binary,
        src_main = src_main,
    )

    interfaces = [interface for module in modules.values() for interface in module.interfaces]
    extra_interfaces = [interface for module in modules.values() for interface in module.extra_interfaces]
    objects = [object for module in modules.values() for object in module.objects]
    extra_objects = [object for module in modules.values() for object in module.extra_objects]
    hie_files = [hie_file for module in modules.values() for hie_file in module.hie_files]
    stub_dirs = [
        module.stub_dir
        for module in modules.values()
        if module.stub_dir != None
    ]
    abi_hashes = [
        module.hash
        for module in modules.values()
        if module.stub_dir != None
    ]

    # Collect library dependencies. Note that these don't need to be in a
    # particular order.
    toolchain_deps_by_name = {
        lib.name: None
        for lib in attr_deps_haskell_toolchain_libraries(ctx)
    }
    direct_deps_info = [
        lib.prof_info[link_style] if enable_profiling else lib.info[link_style]
        for lib in attr_deps_haskell_link_infos(ctx)
    ]

    haskell_direct_deps_lib_infos = attr_deps_haskell_lib_infos(
        ctx,
        LinkStyle("shared"),
        enable_profiling = False,
    )

    link_args = unpack_link_args(
        get_link_args_for_strategy(
            ctx.actions,
            ctx.label,
            get_cxx_toolchain_info(ctx).linker_info,
            [
                lib[MergedLinkInfo]
                for lib in ctx.attrs.extra_libraries
                if MergedLinkInfo in lib
            ],
            to_link_strategy(link_style),
            prefer_stripped = True,
            transformation_spec_context = None,
        ),
    )

    is_worker_execute = check_is_worker_execute(worker, ctx.attrs.allow_worker, haskell_toolchain.use_worker)

    dyn_module_tsets = ctx.actions.dynamic_output_new(_dynamic_do_compile(
        incremental = incremental,
        md_file = md_file,
        pkg_deps = haskell_toolchain.packages.dynamic if haskell_toolchain.packages else None,
        outputs_dict = {
            o: o.as_output()
            for o in interfaces + extra_interfaces + objects + extra_objects + hie_files + stub_dirs + abi_hashes
        },
        direct_deps_by_name = {
            info.value.name: (info.value.empty_db, info.value.dynamic[enable_profiling])
            for info in direct_deps_info
        },
        arg = _DynamicDoCompileOptions(
            artifact_suffix = artifact_suffix,
            compiler_flags = ctx.attrs.compiler_flags,
            ghc_rts_flags = ctx.attrs.ghc_rts_flags,
            deps = attr_deps(ctx),
            direct_extra_libs = ctx.attrs.extra_libraries,
            direct_deps_info = direct_deps_info,
            # though this is redundant. for now let's pass them.
            direct_deps_link_info = attr_deps_haskell_link_infos(ctx),
            haskell_direct_deps_lib_infos = haskell_direct_deps_lib_infos,
            enable_haddock = enable_haddock,
            enable_profiling = enable_profiling,
            external_tool_paths = [tool[RunInfo] for tool in ctx.attrs.external_tools] + extra_tool_paths,
            ghc_wrapper = ctx.attrs._ghc_wrapper[RunInfo],
            haskell_toolchain = haskell_toolchain,
            linker_info = linker_info,
            label = ctx.label,
            link_style = link_style,
            link_args = link_args,
            main = getattr(ctx.attrs, "main", None),
            md_file = md_file,
            modules = modules,
            pkgname = pkgname,
            sources = ctx.attrs.srcs,
            sources_deps = ctx.attrs.srcs_deps,
            srcs_envs = ctx.attrs.srcs_envs,
            toolchain_deps_by_name = toolchain_deps_by_name,
            worker = worker,
            allow_worker = ctx.attrs.allow_worker,
            is_worker_execute = is_worker_execute,
            allow_cache_upload = ctx.attrs.allow_cache_upload,
            link_group_libs = attr_deps_haskell_link_group_infos(ctx, link_style),
            unit_plugin_flags = unit_plugin_flags,
            srcs_plugin_flags = srcs_plugin_flags,
            srcs_plugin_tool_paths = srcs_plugin_tool_paths,
            plugin_toolchain_deps = plugin_toolchain_deps,
        ),
    ))

    stubs_dir = ctx.actions.declare_output("stubs-" + artifact_suffix, dir = True)

    # collect the stubs from all modules into the stubs_dir
    stub_copy_cmd = cmd_args([
        "bash",
        "-euc",
        """\
        mkdir -p \"$0\"
        cat $1 | while read stub; do
          find \"$stub\" -mindepth 1 -maxdepth 1 -exec cp -r -t \"$0\" '{}' ';'
        done
        """,
    ])
    stub_copy_cmd.add(stubs_dir.as_output())
    stub_copy_cmd.add(argfile(
        actions = ctx.actions,
        name = "haskell_stubs_" + artifact_suffix + ".argsfile",
        args = stub_dirs,
        allow_args = True,
    ))

    ctx.actions.run(
        stub_copy_cmd,
        category = "haskell_stubs",
        identifier = artifact_suffix,
        local_only = True,
        # FIXME(jadel): determine whether this is safe to upload to cache
        allow_cache_upload = False,
    )

    return CompileResultInfo(
        objects = objects,
        extra_objects = extra_objects,
        interfaces = interfaces,
        extra_interfaces = extra_interfaces,
        hashes = abi_hashes,
        stubs = stubs_dir,
        hie = hie_files,
        producing_indices = False,
        module_tsets = dyn_module_tsets,
    )
