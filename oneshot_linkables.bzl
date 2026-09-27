# The driver plugin that restores oneshot Template Haskell linking on a GHC
# whose default linker resolver only supports make mode.
# See tools/oneshot_linkables/Buck2Haskell/OneshotLinkables.hs for why.

load(":toolchain.bzl", "HaskellToolchainInfo", "haskell_toolchain")

OneshotLinkablesInfo = provider(fields = {
    "ghc_args": provider_field(cmd_args),
})

def _oneshot_linkables_impl(ctx: AnalysisContext) -> list[Provider]:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
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
        )),
    ]

haskell_oneshot_linkables = rule(
    impl = _oneshot_linkables_impl,
    attrs = {
        "src": attrs.source(),
        "_builder": attrs.exec_dep(
            providers = [RunInfo],
            default = "@buck2-haskell//tools:build_oneshot_linkables",
        ),
        "_haskell_toolchain": haskell_toolchain(),
    },
)
