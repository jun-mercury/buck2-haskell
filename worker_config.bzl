def worker_enabled() -> bool:
    value = read_root_config("ghc-worker", "enable", "false").lower()
    return value in ["true", "yes", "on"]

def worker_per_configuration() -> bool:
    value = read_root_config("ghc-worker", "per_configuration", "true").lower()
    if value == "true":
        return True
    if value == "false":
        return False
    fail("ghc-worker.per_configuration must be `true` or `false`, got `{}`".format(value))

# Needed on a GHC whose default linker resolver has lost oneshot mode, such as
# 9.10.1 with MercuryTechnologies/ghc 155b0ba4 applied, whenever the worker is
# off. The plugin compiles only against a GHC that has `hsc_linkables`.
def oneshot_linkables_enabled() -> bool:
    value = read_root_config("haskell", "oneshot_linkables", "false").lower()
    if value in ["true", "false"]:
        return value == "true"
    fail("haskell.oneshot_linkables must be `true` or `false`, got `{}`".format(value))

# Also load the oneshot plugin into compiles without Template Haskell, for
# the instances make mode would have in scope; see compile.bzl.
def oneshot_preload_all_enabled() -> bool:
    value = read_root_config("haskell", "oneshot_preload_all", "false").lower()
    if value in ["true", "false"]:
        return value == "true"
    fail("haskell.oneshot_preload_all must be `true` or `false`, got `{}`".format(value))
