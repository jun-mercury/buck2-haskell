# GHC Plugin Support — Technical Report

## Overview

This report documents the implementation of GHC compiler plugin support for
the `buck2-haskell` rules, as specified in `plugins_spec.md`. The
implementation introduces a `ghc_plugin` rule and integrates plugin flags into
the existing compilation pipeline.

## Technical Choices

### 1. Plugin flags are compilation-only, not metadata-only

**Decision:** Plugin flags (`-fplugin`, `-plugin-package`, `-package-db`) are
passed to the compilation step but **not** to the metadata step
(`target_metadata` / `ghc -M`).

**Reason:** The metadata step runs `ghc -M` to discover module import
dependencies. At this stage, plugin library artifacts (`.hi` files) may not yet
be compiled. Passing plugin flags to `ghc -M` causes failures because GHC
eagerly loads the plugin module, which requires its `.hi` files to exist. Since
plugins don't affect the module dependency graph, omitting them from the
metadata step is safe and necessary.

### 2. Hidden artifact tracking for plugin dependencies

**Decision:** When computing plugin flags, the plugin library's interface
files, object files, and library artifacts are added as `hidden` inputs to the
`cmd_args`.

**Reason:** GHC loads plugin modules at startup when `-fplugin` is specified.
The plugin's `.hi` files are referenced from its package DB but are not
directly on the GHC command line. Without tracking them as hidden inputs, Buck2
would not materialize them before running the compile action, causing "file not
found" errors. Adding them as `hidden` ensures Buck2's dependency graph
correctly orders the actions.

### 3. Dual-mode `get_plugin_flags` API

**Decision:** `get_plugin_flags` supports two calling modes: (1) with a
context to compute flags for all global plugins, and (2) with a specific
`plugin_info` to compute flags for a single plugin.

**Reason:** Global plugins (`plugins` attr) compute all plugin flags at once
for the unit level. Per-module plugins (`srcs_plugins` attr) need flags
computed for each source file's plugin list individually. A single function
with a mode parameter avoids code duplication while serving both use cases.

### 4. Per-module plugin flags via `srcs_plugin_flags` dict

**Decision:** The `_DynamicDoCompileOptions` record carries a
`srcs_plugin_flags` dictionary mapping sources to their per-module plugin
flags. In `_compile_incr`, each module's source is looked up in this dict to
add module-specific plugin flags.

**Reason:** This follows the existing pattern used by `sources_deps` and
`srcs_envs`, which already map source files to per-module data. Using the same
pattern makes the implementation consistent and leverages the existing
infrastructure in `_compile_module`.

### 5. Mutual exclusion of `plugins` and `srcs_plugins`

**Decision:** Validation is performed at the beginning of each rule
implementation (`haskell_library_impl`, `_haskell_executable`). If both
attributes are non-empty, a `fail()` is called with a clear error message.

**Reason:** Per the spec, using both `plugins` (global) and `srcs_plugins`
(per-module) is an error. Early validation prevents this confusion. The check
uses `getattr` with defaults to safely handle rules that may not have both
attributes.

### 6. Mutual exclusion of `srcs_plugins` and `incremental = False`

**Decision:** Validation also checks that `srcs_plugins` is not used together
with  non-incremental mode, where `fail()` is called with an informative error
message.

**Reason:** Non-incremental mode invokes GHC once for all modules. There is no
mechanism to apply different flags per module, so the `srcs_plugins` attribute is
meaningful only in incremental mode.

### 7. `GhcPluginInfo` provider design

**Decision:** The `GhcPluginInfo` provider stores `module` (str), `deps`
(list[Dependency]), `toolchain_deps` (list[str]), `tools`
(list[Dependency]), and `plugin_opts` (list[str]). The `deps` attribute in
`defs.bzl` accepts any dependency (no `providers` constraint) and the
implementation in `ghc_plugin_impl` categorises each dep: those providing
`HaskellLibraryProvider` go into `deps`, those providing
`HaskellToolchainLibrary` go into `toolchain_deps` (as plain package names),
and anything else triggers a `fail()`.

**Reason:** Storing raw dependencies rather than pre-computed flags allows the
consumer to compute flags appropriate for its own link style. This is necessary
because the same plugin may be used by targets with different link styles
(static vs shared), and the package DB path varies by link style. The
`toolchain_deps` field stores only package names because toolchain libraries
have no link-style-specific artifacts — their package DBs are resolved
dynamically by the compilation flow.

### 8. Expected-failure tests in a self-contained package

**Decision:** Tests for error conditions (mutual exclusion, bad deps,
srcs_plugins + non-incremental, ghci, haddock) are placed in a separate
`expected_failures/` package at the repo root, outside `tests/`. A shell
script (`tests/plugins/test_expected_failures.sh`) invokes `buck build` on
each target, verifies the build fails, and checks that the error message
contains an expected substring. The script is wrapped in an `sh_test` target.

**Reason:** Targets that are expected to fail at analysis time cannot live
under `tests/` because `buck test 'buck2-haskell//tests/...'` discovers all
targets in the recursive pattern. Even though the expected-failure targets are
not test rules, Buck2 still analyzes them when evaluating the pattern, and
analysis failures count as build failures. Moving them to `expected_failures/`
at the repo root keeps them out of the standard test pattern.

The `expected_failures/` package is self-contained: it defines its own
toolchain libraries (`base`, `ghc`), its own `NoopPlugin.hs`, and its own
`noop_plugin` target. This avoids visibility issues — targets under `tests/`
have `visibility = ["//tests/..."]`, which does not include `//expected_failures/`.

The shell script (run as `sh_test`) calls `buck build` for each target and
checks the output with `grep -qF`. This is a nested Buck invocation (buck
build inside buck test). The expected error substrings are
chosen to be specific enough to avoid false positives:
- `"mutually exclusive"` — not just the word from the target name
- `"HaskellLibraryProvider"` — the provider name from Buck2's error
- `"Per-module plugins require incremental"` — avoids matching the target name
- `"GHC binary path"` — actual ghci failure message
- `"already used by another action"` — actual haddock failure message

### 9. Plugin tools scoped per-module for `srcs_plugins`

**Decision:** Plugin tools (from `ghc_plugin.tools`) are split into two scopes:
- **Global plugin tools** (from `plugins` attr) are injected into
  `extra_tool_paths` and become available to all modules via `--bin-exe=` in
  `unit_buck2_args()`.
- **Per-module plugin tools** (from `srcs_plugins` attr) are computed in
  `compute_plugin_flags()` as `srcs_tool_paths`, threaded through
  `_DynamicDoCompileOptions.srcs_plugin_tool_paths`, and added as `--bin-exe=`
  args only in `_compile_module()` for the specific module that uses the plugin.

**Reason:** Previously, `_get_all_plugin_tool_paths()` collected tools from
both global and per-module plugins and passed them all as `extra_tool_paths`,
making every module in the unit depend on every plugin tool binary. This
created unnecessary build dependencies: modules that don't use a plugin would
still wait for that plugin's tools to be built. By scoping per-module plugin
tools to only the modules that reference them, each module depends only on the
tools it actually needs. Global plugin tools remain available to all modules
since they apply to every compilation unit. The per-module tool paths are added
to `wrapper_args_for_file` (not `compile_args_for_file`) because `--bin-exe=`
is a `ghc_wrapper` (`haskell_tool wrap`) flag, not a GHC flag.

### 10. Compiler flags come after plugin opts in GHC invocation

**Decision:** In both `unit_ghc_args()` (incremental mode) and `compile_args()`
(non-incremental mode) in `compile.bzl`, `compiler_flags` are now added to the
GHC command line AFTER `plugin_flags`.

**Reason:** GHC processes `-fplugin-opt` flags in order. If `compiler_flags`
were inserted between plugin flags (e.g., between `-fplugin=Foo` and
`-fplugin-opt=Foo:bar`), it could interfere with how GHC associates options
with plugins. More importantly, users should be able to override
plugin behavior via `compiler_flags`, which only works if they appear later
in the command line. The `OrderPlugin` test enforces this: it verifies that
`plugin_opts = ["alpha", "beta", "gamma"]` arrive in exactly that order, which
would fail if `compiler_flags` were interleaved.

### 11. `srcs_plugins` requires incremental builds

**Decision:** `validate_plugins_attrs()` in `ghc_plugin.bzl` now also checks
that `srcs_plugins` is not used with `incremental = False`, raising a clear
error message.

**Reason:** In non-incremental mode, GHC receives all source files in a single
`ghc --make` invocation. There is no mechanism to apply different plugin flags
to different modules in this mode. Rather than silently applying all plugins to
all modules (which violates the per-module intent), we fail early with an
explanatory message guiding the user to either use global `plugins` or enable
incremental builds.

### 12. `srcs_plugins` is not supported in `haskell_ghci`

**Decision:** The `srcs_plugins` attribute produces an error in `haskell_ghci`
if set.

**Reason:** `haskell_ghci` does not compile or load modules separately, so
the `srcs_plugins` attribute is meaningless there.

### 13. Toolchain library support for `ghc_plugin` deps

**Decision:** `ghc_plugin.deps` accepts both `haskell_library` targets
(providing `HaskellLibraryProvider`) and `haskell_toolchain_library` targets
(providing `HaskellToolchainLibrary`). Toolchain library deps are handled
differently from regular deps throughout the compilation pipeline:

1. **`ghc_plugin_impl`** — categorises deps and stores toolchain dep package
   names in `GhcPluginInfo.toolchain_deps`.
2. **`_add_plugin_flags`** — emits `-plugin-package <name>` for each
   toolchain dep (telling GHC to expose the package as a plugin source).
   No `-package-db` is emitted here because the toolchain package DB is
   managed by the compilation flow.
3. **`compute_plugin_flags`** — collects all `toolchain_deps` from global and
   per-module plugins into a single `plugin_toolchain_deps` list, returned
   alongside the existing flag structs.

**Reason:** Toolchain libraries don't have per-link-style artifacts, and their
package databases are provided by the GHC toolchain rather than being built by Buck2.
When a plugin depends on a toolchain library, we only need to (a) tell GHC the
package name with `-plugin-package` so it exposes the package and loads the
plugin module, and (b) ensure the toolchain package DB that contains the
package is registered via `-package-db`. Part (a) is done at analysis time in
`_add_plugin_flags`; part (b) piggybacks on the existing
`HaskellToolchainPackageDbTSet` machinery that the compilation flow already
uses for regular toolchain library deps. By adding the plugin's toolchain dep
names to `toolchain_libs` in `_common_compile_module_args`, we reuse the
existing package-DB resolution.

## Test files

- **`buck2-haskell/tests/plugins/`** — Complete test suite:
  - `Plugin.hs` — Real GHC plugin that invokes a tool via `readProcess` and replaces string literals (exercises `tools` and `plugin_opts`)
  - `PluginTool.hs` — Trivial binary invoked by `Plugin.hs` at compile time
  - `PluginLib.hs` — Library compiled with the real plugin
  - `PluginMain.hs` — Binary/test that verifies string replacement at runtime
  - `TestPluginLib.hs` — Consumer test for library targets compiled with the plugin
  - `OrderPlugin.hs` — Plugin that verifies `plugin_opts` arrive as `["alpha", "beta", "gamma"]` (flag ordering test)
  - `OrderMain.hs` — Minimal main for order plugin test
  - `Lib.hs`, `Main.hs` — Modules for order plugin library tests
  - `InspectionMain.hs` — Test using `inspection-testing` as a toolchain-library plugin; uses `inspect $ 'myId === 'myId2` to verify GHC equates the two functions at Core level
  - `ghci_src/GhciPluginTest.hs` — Test source for `ghci_real_plugin` (defines `testGreeting`, replaced by plugin to `"plugin_ok"`)
  - `ghci_src/GhciOrderTest.hs` — Test source for `ghci_order_plugin` (defines `hello`, compiles only if plugin opts arrive in order)
  - `test_expected_failures.sh` — Shell script testing expected-failure scenarios
  - `BUCK` — Test targets covering all combinations in the spec

- **`buck2-haskell/tests/build_tests/rule_configs/`** — GHCi test infrastructure:
  - `test_ghci.sh` — Shell script testing GHCi targets (non-plugin and plugin) via `buck2 run`
  - `BUCK` — Contains `sh_test` target `test_ghci`

- **`buck2-haskell/expected_failures/`** — Self-contained expected-failure targets:
  - `BUCK` — Targets that are expected to fail at analysis time
  - `NoopPlugin.hs`, `Lib.hs` — Local sources to avoid cross-package visibility issues

- **`buck2-haskell/examples/plugins/inspection_testing/`** — Example of a toolchain-library plugin:
  - `BUCK` — Defines `ghc_plugin` with `haskell_toolchain_library` dep, `haskell_test`, and `sh_test`
  - `InspectionMain.hs` — Minimal `inspection-testing` usage (equivalent to the test source)

## Test Matrix

Every test uses a plugin that **verifies its execution**: the real plugin
invokes a tool and replaces string literals (compile-time and runtime checks),
and the order plugin asserts option ordering (compile-time check). There are
no noop plugin tests — a noop plugin cannot guarantee it was actually loaded.

The test suite in `buck2-haskell/tests/plugins/` covers:

| Rule type | Plugin | Mode | Link style | Target name |
|---|---|---|---|---|
| `haskell_library` | real (tools+opts) | global | any | `lib_real_plugin` |
| `haskell_library` | real (tools+opts) | srcs_plugins | any | `lib_srcs_real_plugin` |
| `haskell_library` | order (flag ordering) | global | any | `lib_order_plugin` |
| `haskell_library` consumer | real (tools+opts) | — | static | `ht_lib_real_plugin` |
| `haskell_library` consumer | real (tools+opts) | — | static | `ht_lib_srcs_real_plugin` |
| `haskell_library` consumer | order (flag ordering) | — | static | `ht_lib_order_plugin` |
| `haskell_binary` | real (tools+opts) | global | static | `bin_real_plugin_static` |
| `haskell_binary` | real (tools+opts) | global | shared | `bin_real_plugin_shared` |
| `haskell_binary` | real (tools+opts) | srcs_plugins | static | `bin_srcs_real_plugin_static` |
| `haskell_binary` | real (tools+opts) | srcs_plugins | shared | `bin_srcs_real_plugin_shared` |
| `haskell_binary` | order (flag ordering) | global | static | `bin_order_plugin` |
| `haskell_test` | real (tools+opts) | global | static | `ht_real_plugin_static` |
| `haskell_test` | real (tools+opts) | global | shared | `ht_real_plugin_shared` |
| `haskell_test` | real (tools+opts) | srcs_plugins | static | `ht_srcs_real_plugin_static` |
| `haskell_test` | real (tools+opts) | srcs_plugins | shared | `ht_srcs_real_plugin_shared` |
| `haskell_test` | order (flag ordering) | global | static | `ht_order_plugin` |
| `haskell_test` | inspection-testing (toolchain lib) | global | static | `ht_inspection_static` |
| `haskell_test` | inspection-testing (toolchain lib) | global | shared | `ht_inspection_shared` |
| `haskell_test` | inspection-testing (toolchain lib) | srcs_plugins | static | `ht_srcs_inspection_static` |
| `haskell_test` | inspection-testing (toolchain lib) | srcs_plugins | shared | `ht_srcs_inspection_shared` |
| `haskell_ghci` | real (tools+opts) | global | — | `ghci_real_plugin` |
| `haskell_ghci` | order (flag ordering) | global | — | `ghci_order_plugin` |
| `haskell_haddock` | real (tools+opts) | — | — | `haddock_plugin` |

Tests marked **real (tools+opts)** use `Plugin.hs` which invokes a tool at
compile time and replaces string literals. They fail if:
- The tool binary is not available on PATH during compilation
- The plugin_opts are not passed to the plugin
- The Core-to-Core pass does not execute

Tests marked **order (flag ordering)** use `OrderPlugin.hs` which verifies
that `plugin_opts` arrive in the expected order `["alpha", "beta", "gamma"]`.

Tests marked **inspection-testing (toolchain lib)** use the `inspection-testing`
package loaded from a `haskell_toolchain_library` target. The plugin runs at
compile time to verify that two locally-defined functions have identical GHC
Core representations (`inspect $ 'myId === 'myId2`). These tests exercise the
toolchain-library plugin pipeline: `ghc_plugin.deps` contains a toolchain
library, its package name flows through `GhcPluginInfo.toolchain_deps` →
`compute_plugin_flags().plugin_toolchain_deps` → `compile()` →
`_DynamicDoCompileOptions.plugin_toolchain_deps` → `toolchain_libs` →
`HaskellToolchainPackageDbTSet`, and `-plugin-package inspection-testing` is
emitted so GHC exposes the package for plugin loading.

### Expected-failure tests (in `expected_failures/`)

| Error condition | Target name | Expected error substring |
|---|---|---|
| `plugins` + `srcs_plugins` both set | `err_mutual_exclusion` | `"mutually exclusive"` |
| `ghc_plugin.deps` is not a haskell_library or toolchain library | `err_bad_deps` | `"HaskellLibraryProvider or HaskellToolchainLibrary"` |
| `srcs_plugins` + `incremental = False` | `err_srcs_plugins_non_incremental` | `"Per-module plugins require incremental"` |

