{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

-- | A driver plugin that gives a oneshot-mode GHC back its linker dependency
-- resolution for Template Haskell.
--
-- The Mercury GHC 9.10 patch "Split getLinkDeps and abstract over the
-- interface" (MercuryTechnologies/ghc 155b0ba4) moves the resolver behind
-- 'hsc_linkables' and keeps only its make-mode half, because the persistent
-- worker compiles in make mode and installs its own resolver. A oneshot
-- compile (@ghc -c@, which is what buck2-haskell runs when the worker is off)
-- then treats every module a splice needs as external and links it as a
-- library:
--
-- * a module of the unit being compiled has no library, so GHC fails with
--   @unknown package: <this unit>@;
-- * a dependency package that buck2-haskell registers without a library
--   (its "empty" package db, which relies on @-fpackage-db-byte-code@) loads
--   nothing, so the splice fails on an unresolved closure symbol.
--
-- This plugin installs the oneshot half of the resolver as it stood before that
-- patch. In make mode it defers to GHC's own resolver. That half is compiled
-- only under @BUCK2_HASKELL_ONESHOT_LINKER@, which the builder defines when
-- @haskell.oneshot_linker@ is on: it names 'resolveLinkDeps' and
-- 'selectLinkDeps', which only 155b0ba4 exports. The earlier revision of the
-- patch, e11740a9, keeps the oneshot half inside 'getLinkDeps', and a GHC on
-- it, or a stock one, needs only the interface loading below.
--
-- It also loads interfaces before the renamer runs, because make mode has
-- more of them in memory than a oneshot compile does. In make mode the
-- build's libraries are home units and the type checker starts from the
-- family instances of every home module below the current one. A oneshot
-- compile loads a non-orphan family-instance module only once a name from it
-- is forced. The constraint solver snapshots the family-instance environment
-- before it looks at a wanted, so a 'Coercible' through two data-family
-- newtype layers fails on the inner one, and injectivity improvement never
-- sees a @type instance@ for a type the module does not name. The modules to
-- load are each direct import's @dep_finsts@, the set GHC's own
-- @loadDependentFamInstModules@ loads for a module that defines a family
-- instance itself.
--
-- A module that runs splices also gets the interface of every module it
-- imports transitively, since 'reifyInstances' enumerates class instances
-- from the interfaces that are loaded. Without it a splice such as
-- persistent's @discoverEntities@ finds only the instances of the modules
-- imported directly and generates different code from make mode. The plugin
-- option @no-th-closure@ turns that off: a module at the top of a large graph
-- loads the whole graph this way, which on an executor with a memory limit
-- per action kills the compile, and a tree whose splices reify nothing an
-- import list would hide can leave the closure out.
module Buck2Haskell.OneshotLinkables (plugin) where

import Control.Monad (forM_, when)
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import GHC.Data.Maybe (MaybeErr (..))
import GHC.Driver.DynFlags (DynFlags, ghcMode, isOneShot, xopt)
import GHC.Driver.Env.Types (Hsc, HscEnv (..))
import GHC.Driver.Main (getHscEnv)
import GHC.Driver.Plugins (CommandLineOption, Plugin (..), defaultPlugin, purePlugin)
import GHC.Driver.Hooks (Hooks (..))
import GHC.Driver.Pipeline.Execute (runPhase)
import GHC.Driver.Pipeline.Phases (PhaseHook (..), TPhase (..))
import GHC.Unit.Module.Location (ModLocation (..))
#if __GLASGOW_HASKELL__ >= 914
import GHC.Unit.Module.ModIface (mi_mod_hash)
#else
import GHC.Unit.Module.ModIface (mi_final_exts, mi_mod_hash)
#endif
import GHC.Unit.Module.Status (HscRecompStatus (..))
import GHC.Iface.Load (WhereFrom (ImportBySystem), loadInterface, loadSysInterface)
import qualified GHC.LanguageExtensions as LangExt
import GHC.Tc.Utils.Monad (IfG, initIfaceLoad)
import GHC.Types.PkgQual (PkgQual)
import GHC.Types.SrcLoc (Located, unLoc)
import GHC.Unit.Finder (FindResult (Found), findImportedModule)
import GHC.Unit.Module (Module, ModuleName, mkModule, moduleUnit)
import GHC.Unit.Module.Deps (Dependencies (..), Usage (..))
import GHC.Unit.Module.ModSummary (ModSummary, ms_hspp_opts, ms_location, ms_textual_imps)
import GHC.Unit.Module.ModIface (ModIface, mi_deps, mi_usages)
import GHC.Unit.Types (GenWithIsBoot (..), IsBootInterface (..), ModuleNameWithIsBoot)
import GHC.Utils.Outputable (text)
import System.Environment (lookupEnv)
import GHC.Builtin.Names (gHC_PRIM)
import GHC.Driver.Env (hscEPS)
import GHC.Unit.External (ExternalPackageState (..))
import GHC.Unit.Finder (findExactModule)
import GHC.Unit.Finder.Types (InstalledFindResult (..))
import GHC.Unit.Module (moduleName, toUnitId)
import GHC.Unit.Module.Env (moduleEnvToList)
import qualified GHC.Unit.Module.ModIface as ModIface
#if __GLASGOW_HASKELL__ < 914
import GHC.Driver.Config.Finder (initFinderOpts)
import GHC.Driver.Env (hsc_HUG, hsc_home_unit_maybe, hsc_units)
import GHC.Unit.Env (HomeUnitEnv (..))
#endif

#ifdef BUCK2_HASKELL_ONESHOT_LINKER
import Control.Applicative ((<|>))
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import System.IO.Unsafe (unsafePerformIO)
import GHC.Driver.Env (hscInterp)
import GHC.Iface.Errors.Ppr (missingInterfaceErrorDiagnostic)
import GHC.Iface.Errors.Types (MissingInterfaceError)
import GHC.Linker.Deps
  ( LinkDep (..)
  , LinkDepsOpts (..)
  , LinkModule (..)
  , resolveLinkDeps
  , selectLinkDeps
  )
import GHC.Linker.Loader (initLinkDepsOpts)
import GHC.Linker.Types (Linkable, Linkables (..), LoaderState (..))
import GHC.Types.SrcLoc (SrcSpan)
import GHC.Types.Unique.DFM
  ( UniqDFM
  , addListToUDFM
  , addToUDFM
  , alterUDFM
  , eltsUDFM
  , elemUDFM
  , emptyUDFM
  , lookupUDFM
  , minusUDFM
  , unitUDFM
  )
import GHC.Types.Unique.DSet (UniqDSet, getUniqDSet, mkUniqDSet)
import GHC.Unit.Env (ue_homeUnit)
import GHC.Unit.Home (homeUnitAsUnit)
import GHC.Unit.Home.ModInfo (hm_iface)
import GHC.Unit.Module (moduleName, moduleUnitId)
import GHC.Unit.Module.Env (lookupModuleEnv)
import GHC.Unit.Module.ModIface (ModIface, mi_boot, mi_module)
import GHC.Unit.Types (UnitId)
import GHC.Utils.Misc (partitionWith)
import GHC.Utils.Outputable (SDoc, ppr, renderWithContext, (<+>))
import GHC.Utils.Panic (GhcException (ProgramError), throwGhcExceptionIO)
#endif

plugin :: Plugin
plugin =
  defaultPlugin
    { parsedResultAction = \opts summary parsed -> parsed <$ loadInterfaces opts summary
    , pluginRecompile = purePlugin
    , driverPlugin = \_opts hsc_env -> pure (installAbiHashHook (withOneshotLinkables hsc_env))
    }
  where
#ifdef BUCK2_HASKELL_ONESHOT_LINKER
    withOneshotLinkables hsc_env = hsc_env {hsc_linkables = linkables}
#else
    withOneshotLinkables hsc_env = hsc_env
#endif

-- | Where this module's @.hash@ goes.
--
-- 'ml_hi_file' is the interface GHC is about to write, boot suffix included:
-- by the time a phase holds a 'ModLocation', GHC has already applied
-- 'addBootSuffixLocn' to it. The user's guide calls the field @foo.hi@ "even
-- when an hi-boot file exists", which describes the location before that
-- step, and taking it at its word wrote @Foo.dyn_hi-boot-boot.hash@ for every
-- hs-boot module while buck2 waited for @Foo.dyn_hi-boot.hash@.
hashPath :: ModLocation -> FilePath
hashPath location = ml_hi_file location ++ ".hash"

-- | Write the module's ABI hash beside its interface, so that a one-shot
-- compile does not need a second GHC to read it back.
--
-- Without this, @ghc_wrapper@ starts GHC again with @--show-iface-abi-hash@
-- purely to print a hash this process already holds. The hash is
-- @mi_mod_hash@, which 'show' renders as the same 32 hex characters that
-- flag prints, so the file is byte-identical to the wrapper's: the bare
-- token, no trailing newline. Rendering through 'ppr' instead would risk a
-- line break, which is why the worker's sidecar writer strips whitespace.
--
-- Two phases can finish a compile, and a missing @.hash@ fails the action
-- because buck2 declares it an output:
--
--   * 'T_HscBackend' returns the finished interface when the module is
--     compiled or its interface updated;
--   * 'T_HscRecomp' returns 'HscUpToDate' when nothing needs doing, and the
--     backend never runs. Its interface is the one GHC loaded, which carries
--     the same hash. ('HscRecomp' carries only a partial interface, which has
--     no final hash, so the backend hook is the one that sees it.)
installAbiHashHook :: HscEnv -> HscEnv
installAbiHashHook hsc_env =
  hsc_env
    { hsc_hooks = (hsc_hooks hsc_env) {runPhaseHook = Just (PhaseHook (hook inner))}
    }
  where
    inner :: TPhase a -> IO a
    inner = case runPhaseHook (hsc_hooks hsc_env) of
      Just (PhaseHook k) -> k
      Nothing -> runPhase

    hook :: (forall b. TPhase b -> IO b) -> TPhase a -> IO a
    hook k phase = do
      result <- k phase
      case phase of
        T_HscBackend _ env _ _ location _ -> case result of
          (_, iface, _, _) -> writeAbiHash (hashPath location) iface >> writeReadInterfaces env
        -- This arm cannot fire under buck2 and is kept for GHC's sake rather
        -- than ours. `HscUpToDate` means GHC found the interface already
        -- current, which needs the interface to exist when the compile starts;
        -- buck2 passes it as an output instead (`-ohi`, compile.bzl:1424) and a
        -- remote action begins with none of its outputs present, so every
        -- compile takes `HscRecompNeeded` and runs the backend. Nothing here
        -- claims coverage for it.
        T_HscRecomp _ env _ _ -> case result of
          (_, summary, HscUpToDate iface _) ->
            writeAbiHash (hashPath (ms_location summary)) iface >> writeReadInterfaces env
          _ -> pure ()
        _ -> pure ()
      pure result

writeAbiHash :: FilePath -> ModIface -> IO ()
-- GHC 9.14 keeps the module hash among the interface's ABI hashes and
-- exports mi_mod_hash on the ModIface itself; mi_final_exts is gone.
#if __GLASGOW_HASKELL__ >= 914
writeAbiHash path iface = writeFile path (show (mi_mod_hash iface))
#else
writeAbiHash path iface = writeFile path (show (mi_mod_hash (mi_final_exts iface)))
#endif

-- | Where the wrapper asks for the list of interfaces this compile read.
usedInterfacesVar :: String
usedInterfacesVar = "BUCK2_HASKELL_READ_INTERFACES"

-- | List every interface file this compile read, for the wrapper to turn into
-- buck2's dep file.
--
-- A one-shot compile keys on the ABI hash of every module below it, because
-- without a list buck2 cannot tell which of them the compile used. GHC
-- already knows: every interface it read is in the external package state,
-- since in one-shot mode the modules of this unit are external too. That set
-- covers GHC's own usages (direct imports and the defining module of every
-- name used, which 'mkUsageM' loads), the orphan and family-instance modules
-- the type checker loads, and the interfaces this plugin loads. A module GHC
-- never read cannot have shaped the output, apart from through the hashes of
-- the modules that import it, which carry its orphan and export changes
-- upward (GHC's Note in 'GHC.HsToCore.Usage' on depend_on_exports). So its
-- hash file can be left out of the key.
--
-- GHC.Prim has no interface file, and the finder panics when asked for one.
--
-- Each interface is written as both its static and dynamic paths, and a boot
-- interface with the suffix as well; the wrapper keeps the paths whose hash
-- file the action has. Nothing is written unless the wrapper set the
-- variable, so the metadata step and a compile outside buck2 are unchanged.
writeReadInterfaces :: HscEnv -> IO ()
writeReadInterfaces hsc_env =
  lookupEnv usedInterfacesVar >>= \case
    Nothing -> pure ()
    Just out -> do
      eps <- hscEPS hsc_env
      readLines <- traverse (\(m, iface) -> locate "read" m (ModIface.mi_boot iface)) (filter ((/= gHC_PRIM) . fst) (moduleEnvToList (eps_PIT eps)))
      linked <- linkedLines
      writeFile out (unlines (concat readLines ++ linked))
  where
    locate kind m isBoot = do
      let installed = mkModule (toUnitId (moduleUnit m)) (moduleName m)
      found <- findInstalled installed isBoot
      pure $ case found of
        Just loc -> map ((kind ++ "\t") ++) (concatMap (withBoot isBoot) [ml_hi_file loc, ml_dyn_hi_file loc])
        Nothing -> []

    -- A splice runs the byte code in the interfaces of the modules it links,
    -- which a body-only edit changes while their ABI hashes stay put, so the
    -- wrapper names those interfaces themselves. "linker" says this plugin
    -- resolved the links, so the list is whole; without the resolver GHC's
    -- own does the linking and the list is empty, and the wrapper refuses to
    -- tag a splice-running compile's interfaces on it.
    linkedLines :: IO [String]
#ifdef BUCK2_HASKELL_ONESHOT_LINKER
    linkedLines = do
      mods <- readIORef linkedModules
      paths <- traverse (\m -> locate "linked" m NotBoot) mods
      pure ("linker" : concat paths)
#else
    linkedLines = pure []
#endif

    withBoot IsBoot path = [path, path ++ "-boot"]
    withBoot NotBoot path = [path]

#if __GLASGOW_HASKELL__ >= 914
    findInstalled installed isBoot =
      findExactModule hsc_env installed isBoot >>= \case
        InstalledFound loc -> pure (Just loc)
        _ -> pure Nothing
#else
    findInstalled installed isBoot =
      findExactModule
        (hsc_FC hsc_env)
        (initFinderOpts (hsc_dflags hsc_env))
        (initFinderOpts . homeUnitEnv_dflags <$> hsc_HUG hsc_env)
        (hsc_units hsc_env)
        (hsc_home_unit_maybe hsc_env)
        installed
        isBoot
        >>= \case
          InstalledFound loc -> pure (Just loc)
          _ -> pure Nothing
#endif

#ifdef BUCK2_HASKELL_ONESHOT_LINKER
linkables :: HscEnv -> LoaderState -> IO Linkables
linkables hsc_env pls =
  pure
    Linkables
      { linkablesResolve = resolve
      , linkablesSelect = selectLinkDeps opts (hscInterp hsc_env)
      }
  where
    opts = initLinkDepsOpts hsc_env

    resolve :: SrcSpan -> [Module] -> IO ([Linkable], [LinkModule], UniqDSet UnitId, [UnitId])
    resolve span mods
      | ldOneShotMode opts = do
          deps <- oneshotDeps opts mods
          modifyIORef' linkedModules (++ [linkModule lm | LinkModules ms <- deps, lm <- eltsUDFM ms])
          pure (classifyDeps pls deps)
      | otherwise = resolveLinkDeps opts pls span mods

-- | Every module whose code a splice in this compile linked, byte code or
-- object, for 'writeReadInterfaces'. One GHC process compiles one module in
-- one-shot mode, so a process-wide list is that module's.
{-# NOINLINE linkedModules #-}
linkedModules :: IORef [Module]
linkedModules = unsafePerformIO (newIORef [])
#endif

loadInterfaces :: [CommandLineOption] -> ModSummary -> Hsc ()
loadInterfaces opts summary = do
  hsc_env <- getHscEnv
  when (isOneShot (ghcMode (hsc_dflags hsc_env))) $ liftIO $ do
    found <- traverse (\(qual, name) -> findImportedModule hsc_env (unLoc name) qual) (textualImports summary)
    let direct = [m | Found _ m <- found]
    initIfaceLoad hsc_env $ do
      loadFamInstModules direct
      when (runsSplices (ms_hspp_opts summary) && "no-th-closure" `notElem` opts) (visit Set.empty direct)
  where
    runsSplices :: DynFlags -> Bool
    runsSplices dflags = xopt LangExt.TemplateHaskell dflags || xopt LangExt.QuasiQuotes dflags

    -- A direct import that fails to load is the renamer's error to report. A
    -- family-instance module that fails is ours: GHC's own
    -- loadDependentFamInstModules stops on it too, and a silent skip would
    -- bring the original type error back with no hint of why.
    loadFamInstModules :: [Module] -> IfG ()
    loadFamInstModules direct = forM_ direct $ \m ->
      loadInterface reason m ImportBySystem >>= \case
        Failed _ -> pure ()
        Succeeded iface -> forM_ (dep_finsts (mi_deps iface)) $ \d -> loadSysInterface reason d
      where
        reason = text "family instances make mode would see"

    visit :: Set.Set Module -> [Module] -> IfG ()
    visit _ [] = pure ()
    visit seen (m : rest)
      | m `Set.member` seen = visit seen rest
      | otherwise =
          loadInterface (text "instances visible to splices") m ImportBySystem >>= \case
            Failed _ -> visit (Set.insert m seen) rest
            Succeeded iface -> visit (Set.insert m seen) (imports iface ++ rest)
      where
        imports iface =
          [mkModule (moduleUnit m) dep | GWIB dep NotBoot <- directModules iface]
            ++ [usg_mod | UsagePackageModule {usg_mod} <- usages iface]

-- GHC 9.14 tags each import, and each direct dependency an interface
-- records, with its Template Haskell level (explicit level imports,
-- ghc-proposals 682), and keeps an interface's usages in a Maybe. Every level
-- counts here, as every import did before levels existed.
#if __GLASGOW_HASKELL__ >= 914
textualImports :: ModSummary -> [(PkgQual, Located ModuleName)]
textualImports summary = [(qual, name) | (_, qual, name) <- ms_textual_imps summary]

directModules :: ModIface -> [ModuleNameWithIsBoot]
directModules iface = [dep | (_, _, dep) <- Set.toList (dep_direct_mods (mi_deps iface))]

usages :: ModIface -> [Usage]
usages = fromMaybe [] . mi_usages
#else
textualImports :: ModSummary -> [(PkgQual, Located ModuleName)]
textualImports = ms_textual_imps

directModules :: ModIface -> [ModuleNameWithIsBoot]
directModules iface = [dep | (_, dep) <- Set.toList (dep_direct_mods (mi_deps iface))]

usages :: ModIface -> [Usage]
usages = mi_usages
#endif

#ifdef BUCK2_HASKELL_ONESHOT_LINKER
data OneshotError
  = NoInterface !MissingInterfaceError
  | LinkBootModule !Module

oneshotDeps :: LinkDepsOpts -> [Module] -> IO [LinkDep]
oneshotDeps opts mods =
  runExceptT (depsLoop opts mods emptyUDFM) >>= \case
    Right acc -> pure (eltsUDFM acc)
    Left err -> throwProgramError opts (message err)
  where
    message = \case
      NoInterface err -> missingInterfaceErrorDiagnostic (ldMsgOpts opts) err
      LinkBootModule m ->
        text "module" <+> ppr m <+> text "cannot be linked; it is only available as a boot module"

depsLoop ::
  LinkDepsOpts ->
  [Module] ->
  UniqDFM UnitId LinkDep ->
  ExceptT OneshotError IO (UniqDFM UnitId LinkDep)
depsLoop _ [] acc = pure acc
depsLoop opts (m : rest) acc
  | alreadySeen = depsLoop opts rest acc
  | isHome || packageByteCode = do
      (acc', new) <- viaIface
      depsLoop opts (new ++ rest) acc'
  | otherwise = depsLoop opts rest (addLibrary acc)
  where
    unitId = moduleUnitId m
    name = moduleName m

    -- Keyed by unit: once a unit is linked as a library, none of its modules
    -- needs looking at again.
    alreadySeen = case lookupUDFM acc unitId of
      Just (LinkModules seen) -> elemUDFM name seen
      Just (LinkLibrary _) -> True
      Nothing -> False

    isHome = case ue_homeUnit (ldUnitEnv opts) of
      Just home -> homeUnitAsUnit home == moduleUnit m
      Nothing -> False

    packageByteCode = ldPkgByteCode opts

    viaIface =
      liftIO (ldLoadIface opts reason m) >>= \case
        Failed err -> throwE (NoInterface err)
        Succeeded (iface, loc) -> do
          loadByteCode <- liftIO (ldLoadByteCode opts (mi_module iface))
          choose iface loc loadByteCode

    reason = text "need to link module" <+> ppr m <+> text "due to use of Template Haskell"

    choose iface loc loadByteCode
      | IsBoot <- mi_boot iface = throwE (LinkBootModule m)
      | ldUseByteCode opts, Just bc <- loadByteCode = pure (withModule iface (LinkByteCodeModule m bc))
      | isHome = pure (withModule iface (LinkObjectModule m loc))
      | otherwise = pure (addLibrary acc, [])

    addLibrary a = addToUDFM a unitId (LinkLibrary unitId)

    withModule :: ModIface -> LinkModule -> (UniqDFM UnitId LinkDep, [Module])
    withModule iface lm =
      (addListToUDFM (alterUDFM (addModule lm) acc unitId) libs, local ++ packages)
      where
        local =
          [mkModule (moduleUnit m) dep | (_, GWIB dep _) <- Set.toList (dep_direct_mods (mi_deps iface))]
        !(!libs, !packages)
          | packageByteCode = ([], [usg_mod | UsagePackageModule {usg_mod} <- mi_usages iface])
          | otherwise = ([(u, LinkLibrary u) | u <- Set.toList (dep_direct_pkgs (mi_deps iface))], [])

    addModule :: LinkModule -> Maybe LinkDep -> Maybe LinkDep
    addModule lm = \case
      Just (LinkLibrary u) -> Just (LinkLibrary u)
      Just (LinkModules old) -> Just (LinkModules (addToUDFM old name lm))
      Nothing -> Just (LinkModules (unitUDFM name lm))

-- GHC's own classify_deps, which the patch leaves unexported.
classifyDeps :: LoaderState -> [LinkDep] -> ([Linkable], [LinkModule], UniqDSet UnitId, [UnitId])
classifyDeps pls deps =
  (loaded, needed, allPackages, neededPackages)
  where
    (loaded, needed) = partitionWith loadedOrNeeded (concatMap eltsUDFM modules)

    (modules, packages) = flip partitionWith deps $ \case
      LinkModules ms -> Left ms
      LinkLibrary lib -> Right lib

    allPackages = mkUniqDSet packages
    neededPackages = eltsUDFM (getUniqDSet allPackages `minusUDFM` pkgs_loaded pls)

    loadedOrNeeded lm = maybe (Right lm) Left (loadedModule (linkModule lm))

    loadedModule m = lookupModuleEnv (objs_loaded pls) m <|> lookupModuleEnv (bcos_loaded pls) m

linkModule :: LinkModule -> Module
linkModule = \case
  LinkHomeModule hmi -> mi_module (hm_iface hmi)
  LinkObjectModule m _ -> m
  LinkByteCodeModule m _ -> m

throwProgramError :: LinkDepsOpts -> SDoc -> IO a
throwProgramError opts doc = throwGhcExceptionIO (ProgramError (renderWithContext (ldPprOpts opts) doc))
#endif
