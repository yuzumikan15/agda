{-# LANGUAGE CPP #-}
{-# LANGUAGE TupleSections #-}

#if __GLASGOW_HASKELL__ >= 710
{-# LANGUAGE FlexibleContexts #-}
#endif

{-| This module deals with finding imported modules and loading their
    interface files.
-}
module Agda.Interaction.Imports where

import Prelude

import Control.Monad.Reader
import Control.Monad.State
import qualified Control.Exception as E

import Data.Function (on)
import qualified Data.Map as Map
import qualified Data.List as List
import qualified Data.Set as Set
import qualified Data.Foldable as Fold (toList)
import Data.List
import Data.Maybe
import Data.Monoid (mempty, mappend)
import Data.Map (Map)
import Data.Set (Set)

import System.Directory (doesFileExist, getModificationTime, removeFile)
import System.FilePath ((</>))

import qualified Text.PrettyPrint.Boxes as Boxes

import qualified Agda.Syntax.Abstract as A
import qualified Agda.Syntax.Concrete as C
import Agda.Syntax.Abstract.Name
import Agda.Syntax.Parser
import Agda.Syntax.Position
import Agda.Syntax.Scope.Base
import Agda.Syntax.Translation.ConcreteToAbstract
import Agda.Syntax.Internal

import Agda.TypeChecking.Errors
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Monad.Base.KillRange  -- killRange for Signature
import Agda.TypeChecking.Serialise
import Agda.TypeChecking.Telescope
import Agda.TypeChecking.Primitive
import qualified Agda.TypeChecking.Monad.Benchmark as Bench

import Agda.TheTypeChecker

import Agda.Interaction.FindFile
import {-# SOURCE #-} Agda.Interaction.InteractionTop (showOpenMetas)
import Agda.Interaction.Options
import qualified Agda.Interaction.Options.Lenses as Lens
import Agda.Interaction.Highlighting.Precise (HighlightingInfo)
import Agda.Interaction.Highlighting.Generate
import Agda.Interaction.Highlighting.Vim

import Agda.Utils.Except ( MonadError(catchError, throwError) )
import Agda.Utils.FileName
import Agda.Utils.Lens
import Agda.Utils.Monad
import Agda.Utils.Null (unlessNullM)
import Agda.Utils.IO.Binary
import Agda.Utils.Pretty
import Agda.Utils.Time
import Agda.Utils.Hash
import qualified Agda.Utils.HashMap as HMap
import qualified Agda.Utils.Trie as Trie

#include "undefined.h"
import Agda.Utils.Impossible

-- | Are we loading the interface for the user-loaded file
--   or for an import?
data MainInterface
  = MainInterface     -- ^ Interface for main file.
  | NotMainInterface  -- ^ Interface for imported file.
  deriving (Eq, Show)

-- | Merge an interface into the current proof state.
mergeInterface :: Interface -> TCM ()
mergeInterface i = do
    let sig     = iSignature i
        builtin = Map.toList $ iBuiltin i
        prim    = [ x | (_,Prim x) <- builtin ]
        bi      = Map.fromList [ (x,Builtin t) | (x,Builtin t) <- builtin ]
    bs <- gets stBuiltinThings
    reportSLn "import.iface.merge" 10 $ "Merging interface"
    reportSLn "import.iface.merge" 20 $
      "  Current builtins " ++ show (Map.keys bs) ++ "\n" ++
      "  New builtins     " ++ show (Map.keys bi)
    let check b = case (b1, b2) of
            (Builtin x, Builtin y)
              | x == y    -> return ()
              | otherwise -> typeError $ DuplicateBuiltinBinding b x y
            _ -> __IMPOSSIBLE__
          where
            Just b1 = Map.lookup b bs
            Just b2 = Map.lookup b bi
    mapM_ check (map fst $ Map.toList $ Map.intersection bs bi)
    addImportedThings sig bi (iHaskellImports i) (iPatternSyns i)
    reportSLn "import.iface.merge" 20 $
      "  Rebinding primitives " ++ show prim
    prim <- Map.fromList <$> mapM rebind prim
    stImportedBuiltins %= (`Map.union` prim)
    where
        rebind (x, q) = do
            PrimImpl _ pf <- lookupPrimitiveFunction x
            return (x, Prim $ pf { primFunName = q })

addImportedThings ::
  Signature -> BuiltinThings PrimFun -> Set String -> A.PatternSynDefns -> TCM ()
addImportedThings isig ibuiltin hsImports patsyns = do
  stImports %= \imp -> unionSignatures [imp, isig]
  stImportedBuiltins %= \imp -> Map.union imp ibuiltin
  stHaskellImports %= \imp -> Set.union imp hsImports
  stPatternSynImports %= \imp -> Map.union imp patsyns
  addSignatureInstances isig

-- | Scope checks the given module. A proper version of the module
-- name (with correct definition sites) is returned.

scopeCheckImport :: ModuleName -> TCM (ModuleName, Map ModuleName Scope)
scopeCheckImport x = do
    reportSLn "import.scope" 5 $ "Scope checking " ++ show x
    verboseS "import.scope" 10 $ do
      visited <- Map.keys <$> getVisitedModules
      reportSLn "import.scope" 10 $
        "  visited: " ++ intercalate ", " (map (render . pretty) visited)
    -- Since scopeCheckImport is called from the scope checker,
    -- we need to reimburse her account.
    i <- Bench.billTo [] $ getInterface x
    addImport x
    return (iModuleName i `withRangesOfQ` mnameToConcrete x, iScope i)

data MaybeWarnings = NoWarnings | SomeWarnings Warnings

hasWarnings :: MaybeWarnings -> Bool
hasWarnings NoWarnings     = False
hasWarnings SomeWarnings{} = True

-- | If the module has already been visited (without warnings), then
-- its interface is returned directly. Otherwise the computation is
-- used to find the interface and the computed interface is stored for
-- potential later use.

alreadyVisited :: C.TopLevelModuleName ->
                  TCM (Interface, MaybeWarnings) ->
                  TCM (Interface, MaybeWarnings)
alreadyVisited x getIface = do
    mm <- getVisitedModule x
    case mm of
        -- A module with warnings should never be allowed to be
        -- imported from another module.
        Just mi | not (miWarnings mi) -> do
          reportSLn "import.visit" 10 $ "  Already visited " ++ render (pretty x)
          return (miInterface mi, NoWarnings)
        _ -> do
          reportSLn "import.visit" 5 $ "  Getting interface for " ++ render (pretty x)
          r@(i, wt) <- getIface
          reportSLn "import.visit" 5 $ "  Now we've looked at " ++ render (pretty x)
          visitModule $ ModuleInfo
            { miInterface  = i
            , miWarnings   = hasWarnings wt
            }
          return r

-- | Type checks the main file of the interaction.
--   This could be the file loaded in the interacting editor (emacs),
--   or the file passed on the command line.
--
--   First, the primitive modules are imported.
--   Then, @getInterface'@ is called to do the main work.

typeCheckMain :: AbsolutePath -> TCM (Interface, MaybeWarnings)
typeCheckMain f = do
  -- liftIO $ putStrLn $ "This is typeCheckMain " ++ show f
  -- liftIO . putStrLn . show =<< getVerbosity
  reportSLn "import.main" 10 $ "Importing the primitive modules."
  libdir <- liftIO defaultLibDir
  reportSLn "import.main" 20 $ "Library dir = " ++ show libdir
  -- To allow posulating the built-ins, check the primitive module
  -- in unsafe mode
  _ <- bracket_ (gets $ Lens.getSafeMode) Lens.putSafeMode $ do
    Lens.putSafeMode False
    -- Turn off import-chasing messages.
    -- We have to modify the persistent verbosity setting, since
    -- getInterface resets the current verbosity settings to the persistent ones.
    bracket_ (gets $ Lens.getPersistentVerbosity) Lens.putPersistentVerbosity $ do
      Lens.modifyPersistentVerbosity (Trie.delete [])  -- set root verbosity to 0
      -- We don't want to generate highlighting information for Agda.Primitive.
      withHighlightingLevel None $
        getInterface_ =<< do
          moduleName $ mkAbsolute $
            libdir </> "prim" </> "Agda" </> "Primitive.agda"
  reportSLn "import.main" 10 $ "Done importing the primitive modules."

  -- Now do the type checking via getInterface.
  m <- moduleName f
  getInterface' m MainInterface

-- | Tries to return the interface associated to the given (imported) module.
--   The time stamp of the relevant interface file is also returned.
--   Calls itself recursively for the imports of the given module.
--   May type check the module.
--   An error is raised if a warning is encountered.
--
--   Do not use this for the main file, use 'typeCheckMain' instead.

getInterface :: ModuleName -> TCM Interface
getInterface = getInterface_ . toTopLevelModuleName

-- | See 'getInterface'.

getInterface_ :: C.TopLevelModuleName -> TCM Interface
getInterface_ x = do
  (i, wt) <- getInterface' x NotMainInterface
  case wt of
    SomeWarnings w  -> warningsToError w
    NoWarnings      -> return i

-- | A more precise variant of 'getInterface'. If warnings are
-- encountered then they are returned instead of being turned into
-- errors.

getInterface'
  :: C.TopLevelModuleName
  -> MainInterface
     -- ^ If type checking is necessary,
     --   should all state changes inflicted by 'createInterface' be preserved?
  -> TCM (Interface, MaybeWarnings)
getInterface' x isMain = do
  withIncreasedModuleNestingLevel $ do
    -- Preserve the pragma options unless includeStateChanges is True.
    bracket_ (use stPragmaOptions)
             (unless includeStateChanges . setPragmaOptions) $ do
     -- Forget the pragma options (locally).
     setCommandLineOptions . stPersistentOptions . stPersistentState =<< get

     alreadyVisited x $ addImportCycleCheck x $ do
      file <- findFile x  -- requires source to exist

      reportSLn "import.iface" 10 $ "  Check for cycle"
      checkForImportCycle

      uptodate <- Bench.billTo [Bench.Import] $ do
        ignore <- ignoreInterfaces
        cached <- isCached file -- if it's cached ignoreInterfaces has no effect
                                -- to avoid typechecking a file more than once
        sourceH <- liftIO $ hashFile file
        ifaceH  <-
          case cached of
            Nothing -> fmap fst <$> getInterfaceFileHashes (filePath $ toIFile file)
            Just i  -> return $ Just $ iSourceHash i
        let unchanged = Just sourceH == ifaceH
        return $ unchanged && (not ignore || isJust cached)

      reportSLn "import.iface" 5 $
        "  " ++ render (pretty x) ++ " is " ++
        (if uptodate then "" else "not ") ++ "up-to-date."

      -- Andreas, 2014-10-20 AIM XX:
      -- Always retype-check the main file to get the iInsideScope
      -- which is no longer serialized.
      (stateChangesIncluded, (i, wt)) <-
        if uptodate && isMain == NotMainInterface then skip file else typeCheckThe file

      -- Ensure that the given module name matches the one in the file.
      let topLevelName = toTopLevelModuleName $ iModuleName i
      unless (topLevelName == x) $ do
        -- Andreas, 2014-03-27 This check is now done in the scope checker.
        -- checkModuleName topLevelName file
        typeError $ OverlappingProjects file topLevelName x

      visited <- isVisited x
      reportSLn "import.iface" 5 $ if visited then "  We've been here. Don't merge."
                                   else "  New module. Let's check it out."
      unless (visited || stateChangesIncluded) $ do
        mergeInterface i
        Bench.billTo [Bench.Highlighting] $
          ifTopLevelAndHighlightingLevelIs NonInteractive $
            highlightFromInterface i file

      stCurrentModule .= Just (iModuleName i)

      -- Interfaces are only stored if no warnings were encountered.
      case wt of
        SomeWarnings w -> return ()
        NoWarnings     -> storeDecodedModule i

      return (i, wt)

    where
      includeStateChanges = isMain == MainInterface

      isCached file = do
        let ifile = filePath $ toIFile file
        exist <- liftIO $ doesFileExistCaseSensitive ifile
        if not exist
          then return Nothing
          else do
            h  <- fmap snd <$> getInterfaceFileHashes ifile
            mm <- getDecodedModule x
            return $ case mm of
              Just mi | Just (iFullHash mi) == h -> Just mi
              _                                  -> Nothing

      -- Formats the "Checking", "Finished" and "Skipping" messages.
      chaseMsg kind file = do
        nesting <- envModuleNestingLevel <$> ask
        let s = genericReplicate nesting ' ' ++ kind ++
                " " ++ render (pretty x) ++
                case file of
                  Nothing -> "."
                  Just f  -> " (" ++ f ++ ")."
        reportSLn "import.chase" 1 s

      skip file = do
        -- Examine the hash of the interface file. If it is different from the
        -- stored version (in stDecodedModules), or if there is no stored version,
        -- read and decode it. Otherwise use the stored version.
        let ifile = filePath $ toIFile file
        h <- fmap snd <$> getInterfaceFileHashes ifile
        mm <- getDecodedModule x
        (cached, mi) <- Bench.billTo [Bench.Deserialization] $ case mm of
          Just mi ->
            if Just (iFullHash mi) /= h
            then do dropDecodedModule x
                    reportSLn "import.iface" 50 $ "  cached hash = " ++ show (iFullHash mi)
                    reportSLn "import.iface" 50 $ "  stored hash = " ++ show h
                    reportSLn "import.iface" 5 $ "  file is newer, re-reading " ++ ifile
                    (False,) <$> readInterface ifile
            else do reportSLn "import.iface" 5 $ "  using stored version of " ++ ifile
                    return (True, Just mi)
          Nothing -> do
            reportSLn "import.iface" 5 $ "  no stored version, reading " ++ ifile
            (False,) <$> readInterface ifile

        -- Check that it's the right version
        case mi of
          Nothing       -> do
            reportSLn "import.iface" 5 $ "  bad interface, re-type checking"
            typeCheckThe file
          Just i        -> do

            reportSLn "import.iface" 5 $ "  imports: " ++ show (iImportedModules i)

            hs <- map iFullHash <$> mapM getInterface (map fst $ iImportedModules i)

            -- If any of the imports are newer we need to retype check
            if hs /= map snd (iImportedModules i)
              then do
                -- liftIO close -- Close the interface file. See above.
                typeCheckThe file
              else do
                unless cached $ chaseMsg "Skipping" (Just ifile)
                -- We set the pragma options of the skipped file here,
                -- because if the top-level file is skipped we want the
                -- pragmas to apply to interactive commands in the UI.
                mapM_ setOptionsFromPragma (iPragmaOptions i)
                return (False, (i, NoWarnings))

      typeCheckThe file = do
          unless includeStateChanges cleanCachedLog
          let withMsgs = bracket_
                (chaseMsg "Checking" $ Just $ filePath file)
                (const $ chaseMsg "Finished" Nothing)

          -- Do the type checking.

          if includeStateChanges then do
            r <- withMsgs $ createInterface file x

            -- Merge the signature with the signature for imported
            -- things.
            sig <- getSignature
            patsyns <- getPatternSyns
            addImportedThings sig Map.empty Set.empty patsyns
            setSignature emptySignature
            setPatternSyns Map.empty

            return (True, r)
           else do
            ms       <- getImportPath
            nesting  <- asks envModuleNestingLevel
            range    <- asks envRange
            call     <- asks envCall
            mf       <- use stModuleToSource
            vs       <- getVisitedModules
            ds       <- getDecodedModules
            opts     <- stPersistentOptions . stPersistentState <$> get
            isig     <- getImportedSignature
            ibuiltin <- use stImportedBuiltins
            ipatsyns <- getPatternSynImports
            ho       <- getInteractionOutputCallback
            -- Every interface is treated in isolation. Note: Changes
            -- to stDecodedModules are not preserved if an error is
            -- encountered in an imported module.
            -- Andreas, 2014-03-23: freshTCM spawns a new TCM computation
            -- with initial state and environment
            -- but on the same Benchmark accounts.
            r <- freshTCM $
                   withImportPath ms $
                   local (\e -> e { envModuleNestingLevel = nesting
                                    -- Andreas, 2014-08-18:
                                    -- Preserve the range of import statement
                                    -- for reporting termination errors in
                                    -- imported modules:
                                  , envRange              = range
                                  , envCall               = call
                                  }) $ do
                     setDecodedModules ds
                     setCommandLineOptions opts
                     setInteractionOutputCallback ho
                     stModuleToSource .= mf
                     setVisitedModules vs
                     addImportedThings isig ibuiltin Set.empty ipatsyns

                     r  <- withMsgs $ createInterface file x
                     mf <- use stModuleToSource
                     ds <- getDecodedModules
                     return (r, do
                        stModuleToSource .= mf
                        setDecodedModules ds
                        case r of
                          (i, NoWarnings) -> storeDecodedModule i
                          _               -> return ()
                        )

            case r of
                Left err          -> throwError err
                Right (r, update) -> do
                  update
                  case r of
                    (_, NoWarnings) ->
                      -- We skip the file which has just been type-checked to
                      -- be able to forget some of the local state from
                      -- checking the module.
                      -- Note that this doesn't actually read the interface
                      -- file, only the cached interface.
                      skip file
                    _ -> return (False, r)

-- | Print the highlighting information contained in the given
-- interface.

highlightFromInterface
  :: Interface
  -> AbsolutePath
     -- ^ The corresponding file.
  -> TCM ()
highlightFromInterface i file = do
  reportSLn "import.iface" 5 $
    "Generating syntax info for " ++ filePath file ++
    " (read from interface)."
  printHighlightingInfo (iHighlighting i)

readInterface :: FilePath -> TCM (Maybe Interface)
readInterface file = do
    -- Decode the interface file
    (s, close) <- liftIO $ readBinaryFile' file
    do  i <- liftIO . E.evaluate =<< decodeInterface s

        -- Close the file. Note
        -- ⑴ that evaluate ensures that i is evaluated to WHNF (before
        --   the next IO operation is executed), and
        -- ⑵ that decode returns Nothing if an error is encountered,
        -- so it is safe to close the file here.
        liftIO close

        return i
      -- Catch exceptions and close
      `catchError` \e -> liftIO close >> handler e
  -- Catch exceptions
  `catchError` handler
  where
    handler e = case e of
      IOException _ e -> do
        reportSLn "" 0 $ "IO exception: " ++ show e
        return Nothing   -- Work-around for file locking bug.
                         -- TODO: What does this refer to? Please
                         -- document.
      _               -> throwError e

-- | Writes the given interface to the given file. Returns the file's
-- new modification time stamp, or 'Nothing' if the write failed.

writeInterface :: FilePath -> Interface -> TCM ()
writeInterface file i = do
    reportSLn "import.iface.write" 5  $ "Writing interface file " ++ file ++ "."
    -- Andreas, Makoto, 2014-10-18 AIM XX:
    -- iInsideScope is bloating the interface files, so we do not serialize it?
    i <- return $
      i { iInsideScope  = emptyScopeInfo
        }
    encodeFile file i
    reportSLn "import.iface.write" 5 $ "Wrote interface file."
    reportSLn "import.iface.write" 50 $ "  hash = " ++ show (iFullHash i) ++ ""
  `catchError` \e -> do
    reportSLn "" 1 $
      "Failed to write interface " ++ file ++ "."
    liftIO $
      whenM (doesFileExist file) $ removeFile file
    throwError e

-- | Tries to type check a module and write out its interface. The
-- function only writes out an interface file if it does not encounter
-- any warnings.
--
-- If appropriate this function writes out syntax highlighting
-- information.

createInterface
  :: AbsolutePath          -- ^ The file to type check.
  -> C.TopLevelModuleName  -- ^ The expected module name.
  -> TCM (Interface, MaybeWarnings)
createInterface file mname =
  local (\e -> e { envCurrentPath = Just file }) $ do
    modFile       <- use stModuleToSource
    fileTokenInfo <- Bench.billTo [Bench.Highlighting] $
                       generateTokenInfo file
    stTokens .= fileTokenInfo

    reportSLn "import.iface.create" 5 $
      "Creating interface for " ++ render (pretty mname) ++ "."
    verboseS "import.iface.create" 10 $ do
      visited <- Map.keys <$> getVisitedModules
      reportSLn "import.iface.create" 10 $
        "  visited: " ++ intercalate ", " (map (render . pretty) visited)

    previousHsImports <- getHaskellImports

    -- Parsing.
    (pragmas, top) <- Bench.billTo [Bench.Parsing] $
      liftIO $ parseFile' moduleParser file

    pragmas <- concat <$> concreteToAbstract_ pragmas
               -- identity for top-level pragmas at the moment
    let getOptions (A.OptionsPragma opts) = Just opts
        getOptions _                      = Nothing
        options = catMaybes $ map getOptions pragmas
    mapM_ setOptionsFromPragma options


    -- Scope checking.
    topLevel <- Bench.billTo [Bench.Scoping] $
      concreteToAbstract_ (TopLevel file top)

    let ds = topLevelDecls topLevel

    -- Highlighting from scope checker.
    Bench.billTo [Bench.Highlighting] $ do
      ifTopLevelAndHighlightingLevelIs NonInteractive $ do
        -- Generate and print approximate syntax highlighting info.
        printHighlightingInfo fileTokenInfo
        mapM_ (\ d -> generateAndPrintSyntaxInfo d Partial) ds


    -- Type checking.

    -- invalidate cache if pragmas change, TODO move
    cachingStarts
    opts <- use stPragmaOptions
    me <- readFromCachedLog
    case me of
      Just (Pragmas opts', _) | opts == opts'
        -> return ()
      _ -> do
        reportSLn "cache" 10 $ "pragma changed: " ++ show (isJust me)
        cleanCachedLog
    writeToCurrentLog $ Pragmas opts

    Bench.billTo [Bench.Typing] $ mapM_ checkDeclCached ds `finally_` cacheCurrentLog

    -- Ulf, 2013-11-09: Since we're rethrowing the error, leave it up to the
    -- code that handles that error to reset the state.
    -- Ulf, 2013-11-13: Errors are now caught and highlighted in InteractionTop.
    -- catchError_ (checkDecls ds) $ \e -> do
    --   ifTopLevelAndHighlightingLevelIs NonInteractive $
    --     printErrorInfo e
    --   throwError e

    unfreezeMetas

    -- Profiling: Count number of metas.
    verboseS "profile.metas" 10 $ do
      MetaId n <- fresh
      tickN "metas" (fromIntegral n)

    -- Highlighting from type checker.
    Bench.billTo [Bench.Highlighting] $ do

      -- Move any remaining token highlighting to stSyntaxInfo.
      toks <- use stTokens
      ifTopLevelAndHighlightingLevelIs NonInteractive $ printHighlightingInfo toks
      stTokens .= mempty
      stSyntaxInfo %= \inf -> inf `mappend` toks

      whenM (optGenerateVimFile <$> commandLineOptions) $
        -- Generate Vim file.
        withScope_ (insideScope topLevel) $ generateVimFile $ filePath file

    setScope $ outsideScope topLevel

    reportSLn "scope.top" 50 $ "SCOPE " ++ show (insideScope topLevel)

    -- Serialization.
    syntaxInfo <- use stSyntaxInfo
    i <- Bench.billTo [Bench.Serialization] $ do
      buildInterface file topLevel syntaxInfo previousHsImports options

    reportSLn "tc.top" 101 $ concat $
      "Signature:\n" :
      [ show x ++ "\n  type: " ++ show (defType def)
               ++ "\n  def:  " ++ show cc ++ "\n"
      | (x, def) <- HMap.toList $ sigDefinitions $ iSignature i,
        Function{ funCompiled = cc } <- [theDef def]
      ]

    -- TODO: It would be nice if unsolved things were highlighted
    -- after every mutual block.

    openMetas           <- getOpenMetas
    unless (null openMetas) $ do
      reportSLn "import.metas" 10 . unlines =<< showOpenMetas
    unsolvedMetas       <- List.nub <$> mapM getMetaRange openMetas
    unsolvedConstraints <- getAllConstraints
    interactionPoints   <- getInteractionPoints

    ifTopLevelAndHighlightingLevelIs NonInteractive $
      printUnsolvedInfo

    r <- if and [ null unsolvedMetas, null unsolvedConstraints, null interactionPoints ]
     then Bench.billTo [Bench.Serialization] $ do
      -- The file was successfully type-checked (and no warnings were
      -- encountered), so the interface should be written out.
      let ifile = filePath $ toIFile file
      writeInterface ifile i
      return (i, NoWarnings)
     else do
      return (i, SomeWarnings $ Warnings unsolvedMetas unsolvedConstraints)

    -- Profiling: Print statistics.
    printStatistics 30 (Just mname) =<< getStatistics

    -- Get the statistics of the current module
    -- and add it to the accumulated statistics.
    localStatistics <- getStatistics
    lensAccumStatistics %= Map.unionWith (+) localStatistics
    verboseS "profile" 1 $ do
      reportSLn "import.iface" 5 $ "Accumulated statistics."

    return r

-- | Builds an interface for the current module, which should already
-- have been successfully type checked.

buildInterface
  :: AbsolutePath
  -> TopLevelInfo
     -- ^ 'TopLevelInfo' for the current module.
  -> HighlightingInfo
     -- ^ Syntax highlighting info for the module.
  -> Set String
     -- ^ Haskell modules imported in imported modules (transitively).
  -> [OptionsPragma]
     -- ^ Options set in @OPTIONS@ pragmas.
  -> TCM Interface
buildInterface file topLevel syntaxInfo previousHsImports pragmas = do
    reportSLn "import.iface" 5 "Building interface..."
    let m = topLevelModuleName topLevel
    scope'  <- getScope
    let scope = scope' { scopeCurrent = m }
    -- Andreas, 2014-05-03: killRange did not result in significant reduction
    -- of .agdai file size, and lost a few seconds performance on library-test.
    -- Andreas, Makoto, 2014-10-18 AIM XX: repeating the experiment
    -- with discarding also the nameBindingSite in QName:
    -- Saves 10% on serialization time (and file size)!
    sig     <- killRange <$> getSignature
    builtin <- use stLocalBuiltins
    ms      <- getImports
    mhs     <- mapM (\ m -> (m,) <$> moduleHash m) $ Set.toList ms
    hsImps  <- getHaskellImports
    -- Andreas, 2015-02-09 kill ranges in pattern synonyms before
    -- serialization to avoid error locations pointing to external files
    -- when expanding a pattern synoym.
    patsyns <- killRange <$> getPatternSyns
    h       <- liftIO $ hashFile file
    let builtin' = Map.mapWithKey (\ x b -> (x,) . primFunName <$> b) builtin
    reportSLn "import.iface" 7 "  instantiating all meta variables"
    i <- instantiateFull $ Interface
      { iSourceHash      = h
      , iImportedModules = mhs
      , iModuleName      = m
      , iScope           = publicModules scope
      , iInsideScope     = insideScope topLevel
      , iSignature       = sig
      , iBuiltin         = builtin'
      , iHaskellImports  = hsImps `Set.difference` previousHsImports
      , iHighlighting    = syntaxInfo
      , iPragmaOptions   = pragmas
      , iPatternSyns     = patsyns
      }
    reportSLn "import.iface" 7 "  interface complete"
    return i

-- | Returns (iSourceHash, iFullHash)
getInterfaceFileHashes :: FilePath -> TCM (Maybe (Hash, Hash))
getInterfaceFileHashes ifile = do
  exist <- liftIO $ doesFileExist ifile
  if not exist then return Nothing else do
    (s, close) <- liftIO $ readBinaryFile' ifile
    let hs = decodeHashes s
    liftIO $ maybe 0 (uncurry (+)) hs `seq` close
    return hs

safeReadInterface :: FilePath -> TCM (Maybe Interface)
safeReadInterface ifile = do
  exist <- liftIO $ doesFileExist ifile
  if exist then readInterface ifile
           else return Nothing

moduleHash :: ModuleName -> TCM Hash
moduleHash m = iFullHash <$> getInterface m

-- | True if the first file is newer than the second file. If a file doesn't
-- exist it is considered to be infinitely old.
isNewerThan :: FilePath -> FilePath -> IO Bool
isNewerThan new old = do
    newExist <- doesFileExist new
    oldExist <- doesFileExist old
    if not (newExist && oldExist)
        then return newExist
        else do
            newT <- getModificationTime new
            oldT <- getModificationTime old
            return $ newT >= oldT
