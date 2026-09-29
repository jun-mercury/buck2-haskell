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

# Whether the plugin also installs the oneshot linker resolver. A GHC with
# 155b0ba4 has none; one with the earlier revision e11740a9, or a stock one,
# keeps its own, and the plugin then compiles against the stock GHC API.
def oneshot_linker_enabled() -> bool:
    value = read_root_config("haskell", "oneshot_linker", "true").lower()
    if value in ["true", "false"]:
        return value == "true"
    fail("haskell.oneshot_linker must be `true` or `false`, got `{}`".format(value))
