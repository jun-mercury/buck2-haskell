load(
    "@prelude//linking:link_info.bzl",
    "LinkInfo",
    "SharedLibLinkable",
)
load(":library_info.bzl", "get_libname")
load(":link_info.bzl", "ExtraGhcLinkerFlagsInfo")

# See: https://ghc.gitlab.haskell.org/ghc/doc/users_guide/packages.html#installedpackageinfo-a-package-specification
PkgConfLinkFields = record(
    library_dirs = cmd_args,
    extra_libraries = cmd_args,
    cc_options = cmd_args,
    ld_options = cmd_args,
)

def get_pkg_conf_link_fields(
        *,
        pkgname: str,
        link_infos: list[LinkInfo],
        ) -> PkgConfLinkFields:
    """
    Arguments:
        pkgname: Used for debug messages
        link_infos: Artifacts to link
    """

    # TODO: Should these be relative to `${pkgroot}`?
    # `cmd_args(relative_to=...)` is supposed to accept an `OutputArtifact` but
    # our version of Buck2 must be too old to support it.
    # I'm not sure it matters though.
    library_dirs = cmd_args(parent = 1)
    extra_libraries = cmd_args()
    cc_options = cmd_args()
    ld_options = cmd_args()

    for link_info in link_infos:
        if link_info.pre_flags:
            ld_options.add(link_info.pre_flags)
        if link_info.post_flags:
            ld_options.add(link_info.post_flags)

        for linkable in link_info.linkables:
            if isinstance(linkable, SharedLibLinkable):
                library_dirs.add(linkable.lib)
                extra_libraries.add(get_libname(linkable))
            else:
                fail("Unimplemented linkable for package {}: {}".format(pkgname, linkable))

    return PkgConfLinkFields(
        library_dirs = library_dirs,
        extra_libraries = extra_libraries,
        cc_options = cc_options,
        ld_options = ld_options,
    )

def append_pkg_conf_link_fields(
    *,
    pkg_conf: cmd_args,
    link_fields: PkgConfLinkFields,
    extra_ld_opts: cmd_args) -> None:
    pkg_conf.add(cmd_args(cmd_args(link_fields.library_dirs, delimiter = ","), format = "library-dirs: {}"))
    pkg_conf.add(cmd_args(cmd_args(link_fields.extra_libraries, delimiter = ","), format = "extra-libraries: {}"))
    pkg_conf.add(cmd_args(extra_ld_opts, format = "ld-options: {}"))

def append_pkg_conf_link_fields_for_link_infos(
    *,
    pkgname: str,
    pkg_conf: cmd_args,
    link_infos: list[LinkInfo],
    extra_ld_opts: cmd_args) -> None:

    append_pkg_conf_link_fields(
        pkg_conf = pkg_conf,
        link_fields = get_pkg_conf_link_fields(pkgname = pkgname, link_infos = link_infos),
        extra_ld_opts = extra_ld_opts,
    )

# The conf of a unit's package as analysis knows it: identity, dependencies
# and how its native libraries link. `library_fields` sit between the two,
# the unit's own `exposed-modules` and, for the final conf, its library; a
# conf the metadata action registers leaves them out, because the build plan
# that lists the modules does not exist yet at analysis.
def package_conf_fields(
        *,
        pkgname: str,
        import_dirs: list[str],
        toolchain_lib_ids: list[str],
        project_deps: list[cmd_args],
        library_fields: list[typing.Any],
        link_infos: list[LinkInfo],
        extra_libs: list[Artifact],
        extra_lib_dyns: list[ResolvedDynamicValue]) -> cmd_args:
    conf = cmd_args(
        "name: " + pkgname,
        "version: 1.0.0",
        "id: " + pkgname,
        "key: " + pkgname,
        "exposed: False",
        "import-dirs:" + ", ".join(import_dirs),
    )

    toolchain_deps_args = [cmd_args(id) for id in toolchain_lib_ids]
    conf.add(cmd_args(cmd_args(toolchain_deps_args + project_deps, delimiter = ", "), format = "depends: {}"))
    conf.add(library_fields)

    extra_ld_opts = cmd_args(hidden = extra_libs)

    # Extra flags that can be dynamically resolved. For example, -rpath /nix/store/...
    for dyn in extra_lib_dyns:
        fs = dyn.providers[ExtraGhcLinkerFlagsInfo].flags
        extra_ld_opts.add(cmd_args(cmd_args(fs, delimiter = ","), format = "\"-Wl,{}\""))

    append_pkg_conf_link_fields_for_link_infos(
        pkgname = pkgname,
        pkg_conf = conf,
        link_infos = link_infos,
        extra_ld_opts = extra_ld_opts,
    )

    return conf
