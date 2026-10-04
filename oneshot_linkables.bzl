# The driver plugin that restores oneshot Template Haskell linking on a GHC
# whose default linker resolver only supports make mode.
# See tools/oneshot_linkables/Buck2Haskell/OneshotLinkables.hs for why.

load(":toolchain.bzl", "HaskellToolchainInfo", "haskell_toolchain")

# `ghc_args` loads the plugin as a package, through GHC's loader, which a
# splice-running compile initialises anyway. `preload_args` loads it with
# -fplugin-library, a plain dlopen: the loader stays down, so a compile
# without splices links none of its dependencies' libraries and records no
# library usages in its interface.
OneshotLinkablesInfo = provider(fields = {
    "ghc_args": provider_field(cmd_args),
    "preload_args": provider_field(cmd_args),
})

def _oneshot_linkables_impl(ctx: AnalysisContext) -> list[Provider]:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    linker = ctx.attrs.linker if haskell_toolchain.oneshot_linker == None else haskell_toolchain.oneshot_linker
    out = ctx.actions.declare_output("oneshot_linkables", dir = True)
    ctx.actions.run(
        cmd_args(
            ctx.attrs._builder[RunInfo],
            "--ghc",
            haskell_toolchain.compiler,
            "--ghc-pkg",
            haskell_toolchain.packager,
            "--src",
            ctx.attrs.src,
            "--out",
            out.as_output(),
            cmd_args("--linker") if linker else cmd_args(),
        ),
        category = "haskell_oneshot_linkables",
    )
    return [
        DefaultInfo(default_output = out),
        OneshotLinkablesInfo(ghc_args = cmd_args(
            cmd_args(out, format = "-package-db={}/package.db"),
            "-plugin-package-id",
            "buck2-haskell-oneshot-linkables",
            "-fplugin=Buck2Haskell.OneshotLinkables",
            [] if ctx.attrs.th_closure else ["-fplugin-opt=Buck2Haskell.OneshotLinkables:no-th-closure"],
        ), preload_args = cmd_args(
            out,
            format = "-fplugin-library={}/plugin.so;buck2-haskell-oneshot-linkables;Buck2Haskell.OneshotLinkables;[]",
        )),
    ]

haskell_oneshot_linkables = rule(
    impl = _oneshot_linkables_impl,
    attrs = {
        # Compile the linker resolver as well as the interface loading. Only a
        # GHC with MercuryTechnologies/ghc 155b0ba4 has the API it names; the
        # toolchain's `oneshot_linker`, when set, overrides this.
        "linker": attrs.bool(),
        "src": attrs.source(),
        # Load the import closure before a splice runs, for a `reifyInstances`
        # that enumerates class instances. Off, a splice sees the instances of
        # the interfaces GHC loads on its own.
        "th_closure": attrs.bool(),
        "_builder": attrs.exec_dep(
            providers = [RunInfo],
            default = "@buck2-haskell//tools:build_oneshot_linkables",
        ),
        "_haskell_toolchain": haskell_toolchain(),
    },
)
