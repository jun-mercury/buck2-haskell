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
import qualified Data.Set as Set
import GHC.Data.Maybe (MaybeErr (..))
import GHC.Driver.DynFlags (DynFlags, ghcMode, isOneShot, xopt)
import GHC.Driver.Env.Types (Hsc, HscEnv (..))
import GHC.Driver.Main (getHscEnv)
import GHC.Driver.Plugins (CommandLineOption, Plugin (..), defaultPlugin, purePlugin)
import GHC.Iface.Load (WhereFrom (ImportBySystem), loadInterface, loadSysInterface)
import qualified GHC.LanguageExtensions as LangExt
import GHC.Tc.Utils.Monad (IfG, initIfaceLoad)
import GHC.Types.SrcLoc (unLoc)
import GHC.Unit.Finder (FindResult (Found), findImportedModule)
import GHC.Unit.Module (Module, mkModule, moduleUnit)
import GHC.Unit.Module.Deps (Dependencies (..), Usage (..))
import GHC.Unit.Module.ModSummary (ModSummary, ms_hspp_opts, ms_textual_imps)
import GHC.Unit.Module.ModIface (mi_deps, mi_usages)
import GHC.Unit.Types (GenWithIsBoot (..), IsBootInterface (..))
import GHC.Utils.Outputable (text)

#ifdef BUCK2_HASKELL_ONESHOT_LINKER
import Control.Applicative ((<|>))
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
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
#ifdef BUCK2_HASKELL_ONESHOT_LINKER
    , driverPlugin = \_ hsc_env -> pure hsc_env {hsc_linkables = linkables}
#endif
    }

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
      | ldOneShotMode opts = classifyDeps pls <$> oneshotDeps opts mods
      | otherwise = resolveLinkDeps opts pls span mods
#endif

loadInterfaces :: [CommandLineOption] -> ModSummary -> Hsc ()
loadInterfaces opts summary = do
  hsc_env <- getHscEnv
  when (isOneShot (ghcMode (hsc_dflags hsc_env))) $ liftIO $ do
    found <- traverse (\(qual, name) -> findImportedModule hsc_env (unLoc name) qual) (ms_textual_imps summary)
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
          [mkModule (moduleUnit m) dep | (_, GWIB dep NotBoot) <- Set.toList (dep_direct_mods (mi_deps iface))]
            ++ [usg_mod | UsagePackageModule {usg_mod} <- mi_usages iface]

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
