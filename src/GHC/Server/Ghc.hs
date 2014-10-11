{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Ghc monad actions.

module GHC.Server.Ghc where

import           GHC.Compat
import           GHC.Server.Cabal
import           GHC.Server.Info
import           GHC.Server.Types

import           Control.Concurrent.STM
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Data.List
import qualified Data.Map as M
import           Data.Monoid
import           Data.Text (Text)
import qualified Data.Text as T
import           Linker
import           System.Environment

-- | Initialize the GHC service.
initializeGhc :: (MonadLogger m,GhcMonad m)
                   => m ()
initializeGhc =
  do (libincs,exts,pkgs) <- liftIO getDependencyInfo
     initialDynFlags <- getSessionDynFlags
     userFlags <- fmap (<> concat [exts,initFlags,deps pkgs,src libincs]) makeUserFlags
     (dflags',_,_) <- parseDynamicFlags
                        (initialDynFlags {hscTarget = HscAsm
                                         ,ghcLink = LinkInMemory
                                         ,ghcMode = CompManager
                                         ,optLevel = 0})
                        (map (mkGeneralLocated "flag") userFlags)
     let dflags'' = dflags'
     _ <- setSessionDynFlags dflags''
     (dflags''',packageids) <- liftIO (initPackages dflags'')
     _ <- setSessionDynFlags dflags'''
     mapM parseImportDecl necessaryImports >>=
       setContext
     liftIO (initDynLinker dflags''')
     $(logInfo)
       ("User flags: " <>
        T.pack (unwords userFlags))
     $(logInfo)
       ("Packages: " <>
        T.pack (unwords (map (showppr dflags''') packageids)))
  where initFlags =
          ["-fobject-code"
          ,"-dynamic-too"
          ,"-v1"
          ,"-optP-include"
          ,"-optPdist/build/autogen/cabal_macros.h"] <>
          ["-fdefer-type-errors" | ghcVersion >= Ghc78]
        deps [] = []
        deps xs =
          ["-hide-all-packages"] <>
          map (\pkg -> "-package " <> renderPackageId pkg) xs
        src [] = []
        src xs = map (\x -> "-i" <> x) xs

-- | Basic standard imports.
necessaryImports :: [String]
necessaryImports = ["import Prelude"]

-- | Add any GHC logs.
withMessages :: (MonadDuplex i o m,GhcMonad m)
             => (Severity -> SrcSpan -> SDoc -> Duplex i o ()) -> m a -> m a
withMessages handler m =
  do dflags <- getSessionDynFlags
     st <- ask
     setLogAction (addLog st)
     result <- m
     _ <- setSessionDynFlags dflags
     return result
  where addLog st dflags severity' span' _style msg =
          runReaderT (runDuplexT (handler severity span' msg))
                     st
          where msgstr = showSDoc dflags msg
                severity =
                  case severity' of
                    SevWarning
                      | isError msgstr -> SevError
                      | otherwise -> SevWarning
                    s -> s

-- | Is the message actually an error?
isError :: [Char] -> Bool
isError s =
  isPrefixOf "No instance for "
             (trim s) ||
  isPrefixOf "Couldn't match "
             (trim s) ||
  isPrefixOf "Ambiguous "
             (trim s)
  where trim = unwords . words

-- | Print list of loaded imports.
loadedImports :: [ModuleName] -> [String]
loadedImports = map (\m -> "import " <> moduleNameString m)

-- | Make user flags, if HSENV is activated then use the
-- PACKAGE_DB_FOR_GHC environment variable for package flags.
makeUserFlags :: GhcMonad m => m [String]
makeUserFlags =
  do env <- liftIO getEnvironment
     case lookup "HSENV" env >>
          lookup "PACKAGE_DB_FOR_GHC" env of
       Just uflags -> return (words uflags)
       Nothing ->
         case lookup "GHC_PACKAGE_PATH" env of
           Just path ->
             return ["-hide-all-packages","-pkg-db=" <> path]
           Nothing -> return []

-- | Pretty print a type.
formatType :: DynFlags -> Type -> Text
formatType dflags = T.pack . unwords . lines . showppr dflags . snd .
                    splitForAllTys

-- | Apply a flag.
setFlag :: GhcMonad m => String -> m ()
setFlag flag =
  do df <- getSessionDynFlags
     (dflags,_,_) <- parseDynamicFlags
                       df
                       (map (mkGeneralLocated "flag")
                            [flag])
     void (setSessionDynFlags dflags)

-- | Collect type info data for the loaded modules.
collectInfo :: (MonadDuplex i o m,GhcMonad m)
            => [ModuleName] -> m ()
collectInfo loaded =
  do ($(logDebug)
        ("Collecting module data for " <>
         T.pack (show (length loaded)) <>
         " modules ..."))
     forM_ loaded
           (\name ->
              do info <- getModInfo name
                 var <- asks (stateModuleInfos . duplexState)
                 io (atomically
                       (modifyTVar var
                                   (M.insert name info))))
     $(logDebug) ("Done collecting module data.")
