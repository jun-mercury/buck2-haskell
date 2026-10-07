# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

load("@prelude//utils:graph_utils.bzl", "post_order_traversal")
load("@prelude//:paths.bzl", "paths")
load(":compile.bzl", "CompileResultInfo", "CompiledModuleTSet", "DynamicCompileResultInfo")
load(":library_info.bzl", "HaskellLibraryInfoTSet")
load(":link_info.bzl", "cxx_toolchain_link_style")
load(
    ":toolchain.bzl",
    "HaskellToolchainInfo",
    "DynamicHaskellToolchainPackageDbInfo",
    "HaskellToolchainLibrary",
    "HaskellToolchainPackageDbTSet",
    "augment_toolchain_package_db",
)
load(
    ":util.bzl",
    "attr_deps",
    "attr_deps_haskell_link_infos",
    "md_module_mapping",
    "src_to_module_name",
)

HaskellHaddockInfo = provider(
    fields = {
        "html": provider_field(dict[str, typing.Any], default = {}),
        "interfaces": provider_field(list[typing.Any], default = []),
    },
)


_HaddockInfo = record(
    interface = Artifact,
    haddock = Artifact,
    html = Artifact,
)

def _haskell_interfaces_args(info: _HaddockInfo):
    return cmd_args(info.interface, format="--one-shot-dep-hi={}")

_HaddockInfoTSet = transitive_set(
    args_projections = {
        "interfaces": _haskell_interfaces_args
    }
)

def _haddock_module_to_html(module_name: str) -> str:
    return module_name.replace(".", "-") + ".html"

def _haddock_dump_interface(
    actions: AnalysisActions,
    cmd: cmd_args,
    module_name: str,
    module_tsets: dict[str, _HaddockInfoTSet],
    haddock_info: _HaddockInfo,
    module_deps: list[CompiledModuleTSet],
    graph: dict[str, list[str]],
    toolchain_packagedb_args: TransitiveSetArgsProjection,
    outputs: dict[Artifact, OutputArtifact]) -> _HaddockInfoTSet:

    # Transitive module dependencies from other packages.
    cross_package_modules = actions.tset(
        CompiledModuleTSet,
        children = module_deps,
    )
    cross_interfaces = cross_package_modules.project_as_args("interfaces")

    # Package databases of the transitive module dependencies from other
    # packages (locally built Haskell libraries).
    cross_package_dbs = cross_package_modules.reduce("packagedb_deps").keys()

    # Transitive module dependencies from the same package.
    this_package_modules = [
        module_tsets[dep_name]
        for dep_name in graph[module_name]
    ]

    expected_html = haddock_info.html
    module_html = _haddock_module_to_html(module_name)

    if paths.basename(expected_html.short_path) != module_html:
        html_output = actions.declare_output("haddock-html", module_html)
        html_output_arg = cmd_args(html_output.as_output(), parent = 1)
        make_copy = True
    else:
        html_output_arg = cmd_args(outputs[expected_html], parent = 1)
        make_copy = False

    actions.run(
        cmd.copy().add(
            "--odir", html_output_arg,
            "--dump-interface", outputs[haddock_info.haddock],
            "--html",
            "--hoogle",
            cmd_args(
                haddock_info.interface,
                format="--one-shot-hi={}"),
            cmd_args(
                [haddock_info.project_as_args("interfaces") for haddock_info in this_package_modules],
            ),
            cmd_args(
                cross_interfaces, format="--one-shot-dep-hi={}"
            ),
            cmd_args(
                cross_package_dbs, format="--optghc=-package-db={}"
            ),
            cmd_args(
                toolchain_packagedb_args, format="--optghc=-package-db={}"
            ),
        ),
        category = "haskell_haddock",
        identifier = module_name,
        no_outputs_cleanup = True,
        # FIXME(jadel): determine whether this is safe to upload to cache
        allow_cache_upload = False,
    )
    if make_copy:
        # XXX might as well use `symlink_file`` but that does not work with buck2 RE
        # (see https://github.com/facebook/buck2/issues/222)
        actions.copy_file(outputs[expected_html], html_output)

    return actions.tset(
        _HaddockInfoTSet,
        value = _HaddockInfo(interface = haddock_info.interface, haddock = haddock_info.haddock, html = haddock_info.html),
        children = this_package_modules,
    )

def _dynamic_haddock_dump_interfaces_impl(
    actions,
    md_file,
    dynamic_info_lib,
    toolchain_pkg_deps,
    outputs,
    arg):

    md = md_file.read_json()
    module_map = md_module_mapping(md)
    graph = md["module_graph"]
    package_deps = md["package_deps"]
    if toolchain_pkg_deps:
        toolchain_package_db = toolchain_pkg_deps.providers[DynamicHaskellToolchainPackageDbInfo].toolchain_packages
    else:
        toolchain_package_db = {}

    toolchain_package_db = augment_toolchain_package_db(
        actions,
        toolchain_package_db,
        getattr(arg, "toolchain_lib_objs", []),
    )

    # Package databases of the toolchain library dependencies (and their
    # transitive closure). These provide packages such as `base` or
    # `hspec-core` that the interface files being documented refer to. Only
    # include the package-dbs of the actual (transitive) dependencies rather
    # than every package the toolchain knows about.
    toolchain_package_db_tset = actions.tset(
        HaskellToolchainPackageDbTSet,
        children = [
            toolchain_package_db[name]
            for name in arg.toolchain_libs
            if name in toolchain_package_db
        ],
    )
    toolchain_packagedb_args = toolchain_package_db_tset.project_as_args("toolchain_package_db")

    haddock_infos = { module_map.get(k, k): v for k, v in arg.haddock_infos.items() }
    module_tsets = {}

    for module_name in post_order_traversal(graph):
        module_deps = [
            info.providers[DynamicCompileResultInfo].modules[mod]
            for lib, info in dynamic_info_lib.items()
            for mod in package_deps.get(module_name, {}).get(lib, [])
        ]

        module_tsets[module_name] = _haddock_dump_interface(
            actions,
            arg.dyn_cmd.copy(),
            module_name = module_name,
            module_tsets = module_tsets,
            haddock_info = haddock_infos[module_name],
            module_deps = module_deps,
                graph = graph,
            toolchain_packagedb_args = toolchain_packagedb_args,
            outputs = outputs,
        )

    return []

_dynamic_haddock_dump_interfaces = dynamic_actions(
    impl = _dynamic_haddock_dump_interfaces_impl,
    attrs = {
        "md_file": dynattrs.artifact_value(),
        "arg": dynattrs.value(typing.Any),
        "dynamic_info_lib": dynattrs.dict(str, dynattrs.dynamic_value()),
        "toolchain_pkg_deps": dynattrs.option(dynattrs.dynamic_value()),
        "outputs": dynattrs.dict(Artifact, dynattrs.output()),
    },
)

def haskell_haddock_lib(ctx: AnalysisContext, pkgname: str, compiled: CompileResultInfo, md_file: Artifact) -> HaskellHaddockInfo:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    link_style = cxx_toolchain_link_style(ctx)

    cmd = cmd_args(haskell_toolchain.haddock)

    cmd.add(
        "--use-index",
        "doc-index.html",
        "--use-contents",
        "index.html",
        "--no-tmp-comp-dir",
        "--no-warnings",
        "--optghc=-package-env=-",
        "--package-name",
        pkgname,
    )

    cmd.add(ctx.attrs.haddock_flags)

    source_entity = read_root_config("haskell", "haddock_source_entity", None)
    if source_entity:
        cmd.add("--source-entity", source_entity)

    haddock_infos = {
        src_to_module_name(hi.short_path): _HaddockInfo(
            interface = hi,
            haddock = ctx.actions.declare_output("haddock-interface/{}.haddock".format(src_to_module_name(hi.short_path))),
            html = ctx.actions.declare_output("haddock-html", _haddock_module_to_html(src_to_module_name(hi.short_path))),
        )
        for hi in compiled.interfaces
        if not hi.extension.endswith("-boot")
    }

    direct_deps_link_info = attr_deps_haskell_link_infos(ctx)
    pkg_deps = haskell_toolchain.packages.dynamic if haskell_toolchain.packages else None

    # Compute the transitive set of toolchain library dependencies (by name)
    # so that only their package-dbs are passed to haddock.
    libs = ctx.actions.tset(
        HaskellLibraryInfoTSet,
        children = [lib.info[link_style] for lib in direct_deps_link_info],
    )
    direct_toolchain_libs = [
        dep[HaskellToolchainLibrary].name
        for dep in attr_deps(ctx)
        if HaskellToolchainLibrary in dep
    ]
    transitive_toolchain_libs = libs.reduce("toolchain_packages")
    toolchain_libs = direct_toolchain_libs + [p.name for p in transitive_toolchain_libs]

    ctx.actions.dynamic_output_new(_dynamic_haddock_dump_interfaces(
        md_file = md_file,
        dynamic_info_lib = {
            info.value.name: info.value.dynamic[False]
            for lib in direct_deps_link_info
            for info in [
                #lib.prof_info[link_style]
                #if enable_profiling else
                lib.info[link_style],
            ]
        },
        toolchain_pkg_deps = pkg_deps,
        outputs = {output: output.as_output() for info in haddock_infos.values() for output in [info.haddock, info.html]},
        arg = struct(
            dyn_cmd = cmd.copy(),
            haddock_infos = haddock_infos,
            link_style = link_style,
            md_file = md_file,
            toolchain_libs = toolchain_libs,
            toolchain_lib_objs =
                [dep[HaskellToolchainLibrary] for dep in attr_deps(ctx) if HaskellToolchainLibrary in dep] +
                transitive_toolchain_libs,
        ),
    ))

    return HaskellHaddockInfo(
        interfaces = [i.haddock for i in haddock_infos.values()],
        html = {module: i.html for module, i in haddock_infos.items()},
    )

def haskell_haddock_impl(ctx: AnalysisContext) -> list[Provider]:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    out = ctx.actions.declare_output("haddock-html", dir = True)

    cmd = cmd_args(haskell_toolchain.haddock)

    cmd.add(
        "--optghc=-package-env=-",
        "--gen-index",
        "--gen-contents",
        "-o",
        out.as_output(),
    )

    dep_htmls = []
    for lib in attr_deps(ctx):
        hi = lib.get(HaskellHaddockInfo)
        if hi != None:
            cmd.add(cmd_args(hi.interfaces, format="--read-interface={}"))
            if hi.html:
                dep_htmls.extend(hi.html.values())

    cmd.add(ctx.attrs.haddock_flags)

    script_args = cmd_args([
        "#!/bin/sh",
        cmd_args(
            cmd_args(cmd, delimiter = " ", quote = "shell"),
            [
                cmd_args(
                    ["cp", "-f", html, cmd_args(out, ignore_artifacts = True)],
                    delimiter = " ",
                ) for html in dep_htmls
            ],
            delimiter = " && \\\n  "
        )
    ])

    script = ctx.actions.write(
        "haddock-script",
        script_args,
        is_executable = True,
        with_inputs = True,
    )

    ctx.actions.run(
        cmd_args(script, hidden=out.as_output()),
        category = "haskell_haddock",
        no_outputs_cleanup = True,
        # FIXME(jadel): determine whether this is safe to upload to cache
        allow_cache_upload = False,
    )

    return [DefaultInfo(default_outputs = [out])]
