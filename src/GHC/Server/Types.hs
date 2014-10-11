{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | All server types.

module GHC.Server.Types
  (-- * Project state
   -- $state
   State(..)
  ,ModInfo(..)
  ,SpanInfo(..)
  -- * Commands
  ,Command(..)
  -- * Duplex monad
  -- $duplex
  ,MonadDuplex
  ,MonadGhc(..)
  ,DuplexT(..)
  ,DuplexState(..)
  ,Duplex
  ,Producer
  ,Returns
  ,Unit
  -- * Transport types
  ,Incoming(..)
  ,Outgoing(..)
  ,Input(..)
  ,Output(..)
  ,Outputish
  ,Inputish
  -- * Generic types
  ,SomeCommand(..)
  ,SomeChan(..)
  -- * Result types
  ,EvalResult(..)
  ,Msg(..))
  where


import           GHC.Compat

import           Control.Concurrent
import           Control.Concurrent.STM.TVar
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Data.AttoLisp (FromLisp(..),ToLisp(..))
import qualified Data.AttoLisp as L
import           Data.Attoparsec.Number
import           Data.ByteString (ByteString)
import           Data.Map (Map)
import           Data.Text (Text)
import qualified Data.Text as T

--------------------------------------------------------------------------------
-- Project state
-- $state
--
-- All state is stored in one pure value which has 'TVar' slots. It is
-- passed to all command handlers as a reader value. The value itself
-- should never change for a given instance of ghc-server.

-- | Project-wide state.
data State =
  State {stateModuleInfos :: !(TVar (Map ModuleName ModInfo))
         -- ^ A mapping from local module names to information about that
         -- module such as scope, types, exports, imports, etc.  Regenerated
         -- after every module reload.
        }

-- | Info about a module. This information is generated every time a
-- module is loaded.
data ModInfo =
  ModInfo {modinfoSummary :: !ModSummary
           -- ^ Summary generated by GHC. Can be used to access more
           -- information about the module.
          ,modinfoSpans :: ![SpanInfo]
           -- ^ Generated set of information about all spans in the
           -- module that correspond to some kind of identifier for
           -- which there will be type info and/or location info.
          ,modinfoInfo :: !ModuleInfo
           -- ^ Again, useful from GHC for accessing information
           -- (exports, instances, scope) from a module.
          }

-- | Type of some span of source code. Most of these fields are
-- unboxed but Haddock doesn't show that.
data SpanInfo =
  SpanInfo {spaninfoStartLine :: {-# UNPACK #-} !Int
            -- ^ Start line of the span.
           ,spaninfoStartCol :: {-# UNPACK #-} !Int
            -- ^ Start column of the span.
           ,spaninfoEndLine :: {-# UNPACK #-} !Int
            -- ^ End line of the span (absolute).
           ,spaninfoEndCol :: {-# UNPACK #-} !Int
            -- ^ End column of the span (absolute).
           ,spaninfoType :: {-# UNPACK #-} !ByteString
            -- ^ A pretty-printed representation fo the type.
           ,spaninfoVar :: !(Maybe Id)
            -- ^ The actual 'Var' associated with the span, if
            -- any. This can be useful for accessing a variety of
            -- information about the identifier such as module,
            -- locality, definition location, etc.
           }

--------------------------------------------------------------------------------
-- Duplex types
-- $duplex
--
-- All commands are handled in this monad. It supports full duplex
-- communication between the server and a client. This is useful for
-- things like streaming arbitrary many results in a compilation job,
-- or in doing input/output for evaluation in a REPL.

-- | State for the duplex.
data DuplexState i o =
  DuplexState {duplexIn :: !(Chan i)
               -- ^ A channel which is written to whenever a line is
               -- received on the client's 'Handle'. This is read from
               -- by the function 'GHC.Server.recv'.
              ,duplexOut :: !(Chan o)
               -- ^ A channel written to by the function
               -- 'Ghc.Server.send', which will encode whatever is
               -- written to it, @o@, into the transport format used
               -- (probably 'Lisp') and then write it to the client's
               -- 'Handle'.
              ,duplexRunGhc :: !(Chan (Ghc ()))
               -- ^ A channel on which one can put actions for the GHC
               -- slave to perform. There is only one GHC slave per
               -- ghc-server instance, and the GHC API is not
               -- thread-safe, so we process one command at a time via
               -- this interface.
              ,duplexState :: !State
               -- ^ The global project 'State'.
              }

-- | Full duplex command handling monad. This is the monad
-- used for any command handlers. This is an instance of 'GhcMonad'
-- and 'MonadLogger' and 'MonadIO', so you can do GHC commands in it
-- via 'GHC.Server.Duplex.withGHC', you can log via the usual
-- monad-logger functions, and you can do IO via 'GHC.Compat.io'.
newtype DuplexT m i o r =
  DuplexT {runDuplexT :: ReaderT (DuplexState i o) m r}
  deriving (Functor,Applicative,Monad,MonadIO)

-- | Anything that can access the duplexing state, do IO and log. In
-- other words, any 'DuplexT' transformer.
type MonadDuplex i o m =
  (MonadReader (DuplexState i o) m
  ,MonadIO m
  ,Inputish i
  ,Outputish o
  ,MonadLogger m
  ,MonadGhc m)

-- | This monad can run GHC actions inside it.
class MonadGhc m where
  liftGhc :: Ghc r -> m r

instance MonadGhc (DuplexT IO i o) where
  liftGhc m =
    do ghcChan <- asks duplexRunGhc
       io (do result <- newEmptyMVar
              io (writeChan ghcChan
                            (do v <- m
                                io (putMVar result v)))
              takeMVar result)

instance MonadGhc (DuplexT Ghc i o) where
  liftGhc m =
    DuplexT (ReaderT (const m))

instance ExceptionMonad (DuplexT Ghc i o) where
  gcatch (DuplexT (ReaderT fm)) fh =
    DuplexT (ReaderT (\r ->
                        gcatch (fm r)
                               (\e ->
                                  let DuplexT (ReaderT fh') = fh e
                                  in fh' r)))
  gmask getsF =
    DuplexT (ReaderT (\r ->
                        gmask (\f ->
                                 case getsF (\(DuplexT (ReaderT x')) ->
                                               DuplexT (ReaderT (f . x'))) of
                                   DuplexT (ReaderT rf) -> rf r)))

instance Monad m => MonadReader (DuplexState i o) (DuplexT m i o) where
  ask = DuplexT ask
  local f (DuplexT m) = DuplexT (local f m)

instance MonadIO m => MonadLogger (DuplexT m i o) where
  monadLoggerLog loc source level msg =
    liftIO (runStdoutLoggingT (monadLoggerLog loc source level msg))

instance HasDynFlags (DuplexT Ghc i o) where
  getDynFlags =
    DuplexT (ReaderT (const getDynFlags))

instance GhcMonad (DuplexT Ghc i o) where
  getSession =
    DuplexT (ReaderT (const getSession))
  setSession s =
    DuplexT (ReaderT (const (setSession s)))

instance ExceptionMonad (LoggingT Ghc) where
  gcatch (LoggingT fm) fh =
    LoggingT (\r ->
               gcatch (fm r)
                      (\e ->
                         let (LoggingT fh') = fh e
                         in fh' r))
  gmask getsF =
    LoggingT (\r ->
               gmask (\f ->
                        case getsF (\(LoggingT x') ->
                                      LoggingT (f . x')) of
                          (LoggingT rf) -> rf r))

instance HasDynFlags (LoggingT Ghc) where
  getDynFlags =
    LoggingT (const getDynFlags)

instance GhcMonad (LoggingT Ghc) where
  getSession =
    LoggingT (const getSession)
  setSession s =
    LoggingT (const (setSession s))

-- | Duplex transformed over IO. Default command handler monad.
type Duplex i o r = DuplexT IO i o r

-- | Command that only produces output and a result, consumes no input.
type Producer o r = Duplex () o r

-- | Command that only returns a result.
type Returns r = Duplex () () r

-- | Command that returns no results at all.
type Unit = Duplex () () ()

--------------------------------------------------------------------------------
-- Transport layer types

-- | A input payload wrapper.
data Incoming i =
  Incoming !Integer
           !(Input i)
  deriving (Show)

-- | An output input payload wrapper.
data Outgoing o =
  Outgoing !Integer
           !(Output o)
  deriving (Show)

-- | An input value for some serialization type.
data Input i
  = Request !SomeCommand
  | FeedIn !i
  deriving (Show)

-- | An input value for some serialization type.
data Output o
  = EndResult !o
  | FeedOut !o
  | ErrorResult !SomeException
  deriving (Show)

-- | Outputable things.
type Outputish a = (ToLisp a,Show a)

-- | Inputable things.
type Inputish a = (FromLisp a,Show a)

-- | Generic command.
data SomeCommand =
  forall i o r. (Inputish i,Outputish o,Outputish r) => SomeCommand (Command (Duplex i o r))

-- | A generic channel.
data SomeChan = forall a. Inputish a => SomeChan (Chan a)

--------------------------------------------------------------------------------
-- Transport serialization code

instance FromLisp l => FromLisp (Incoming l) where
  parseLisp (L.List (L.Symbol "request" :i:input:_)) =
    do input' <- parseLisp input
       x <- parseLisp i
       return (Incoming x (Request input'))
  parseLisp (L.List (L.Symbol "feed" :i:input:_)) =
    do input' <- parseLisp input
       x <- parseLisp i
       return (Incoming x (FeedIn input'))
  parseLisp l = L.typeMismatch "Incoming" l

instance ToLisp l => ToLisp (Outgoing l) where
  toLisp (Outgoing ix output) =
    case output of
      EndResult o ->
        L.List [L.Symbol "end-result",toLisp ix,toLisp o]
      FeedOut o ->
        L.List [L.Symbol "result",toLisp ix,toLisp o]
      ErrorResult o ->
        L.List [L.Symbol "error-result",toLisp ix,toLisp o]

deriving instance Show SomeCommand
instance L.FromLisp SomeCommand where
  parseLisp (L.List (L.Symbol "ping":i:_)) =
    do x <- L.parseLisp i
       return (SomeCommand (Ping x))
  parseLisp (L.List (L.Symbol "eval":L.String x:_)) =
    return (SomeCommand (Eval x))
  parseLisp (L.List (L.Symbol "type-of":L.String x:_)) =
    return (SomeCommand (TypeOf x))
  parseLisp (L.List (L.Symbol "type-at":L.String fp:L.String string:L.Number (I sl):L.Number (I sc):L.Number (I el):L.Number (I ec):_)) =
    return (SomeCommand
              (TypeAt (T.unpack fp)
                      string
                      (fromIntegral sl)
                      (fromIntegral sc)
                      (fromIntegral el)
                      (fromIntegral ec)))
  parseLisp (L.List (L.Symbol "uses":L.String fp:L.String string:L.Number (I sl):L.Number (I sc):L.Number (I el):L.Number (I ec):_)) =
    return (SomeCommand
              (Uses (T.unpack fp)
                    string
                    (fromIntegral sl)
                    (fromIntegral sc)
                    (fromIntegral el)
                    (fromIntegral ec)))
  parseLisp (L.List (L.Symbol "loc-at":L.String fp:L.String string:L.Number (I sl):L.Number (I sc):L.Number (I el):L.Number (I ec):_)) =
    return (SomeCommand
              (LocationAt (T.unpack fp)
                          string
                          (fromIntegral sl)
                          (fromIntegral sc)
                          (fromIntegral el)
                          (fromIntegral ec)))
  parseLisp (L.List (L.Symbol "kind-of":L.String x:_)) =
    return (SomeCommand (KindOf x))
  parseLisp (L.List (L.Symbol "info":L.String x:_)) =
    return (SomeCommand (InfoOf x))
  parseLisp (L.List (L.Symbol "load-target":L.String t:_)) =
    return (SomeCommand (LoadTarget t))
  parseLisp (L.List (L.Symbol "set":L.String opt:_)) =
    return (SomeCommand (Set opt))
  parseLisp (L.List (L.Symbol "package-conf":L.String pkgconf:_)) =
    return (SomeCommand (PackageConf (T.unpack pkgconf)))
  parseLisp (L.List (L.Symbol "cd":L.String dir:_)) =
    return (SomeCommand (SetCurrentDir (T.unpack dir)))
  parseLisp l = L.typeMismatch "Cmd" l

instance ToLisp SomeException where
  toLisp e = toLisp (show e)

--------------------------------------------------------------------------------
-- Commands

-- | Command.
data Command a where
  LoadTarget    :: Text -> Command (Producer Msg (SuccessFlag,Integer))
   -- Load a module.
  Eval          :: Text -> Command (Duplex Text Text EvalResult)
  -- Eval something for the REPL.
  Ping          :: Integer -> Command (Returns Integer)
  -- Ping/pong. Handy for debugging.
  TypeOf        :: Text -> Command (Returns Text)
  -- Type of identifier.
  LocationAt    :: FilePath -> Text -> Int -> Int -> Int -> Int -> Command (Returns SrcSpan)
  -- Location of identifier at point.
  TypeAt        :: FilePath -> Text -> Int -> Int -> Int -> Int -> Command (Returns Text)
  -- Type of identifier at point.
  Uses          :: FilePath -> Text -> Int -> Int -> Int -> Int -> Command (Returns Text)
  -- Find uses.
  KindOf        :: Text -> Command (Returns Text)
  -- Kind of the identifier.
  InfoOf        :: Text -> Command (Returns [Text])
  -- Info of the identifier.
  Set           :: Text -> Command (Returns ())
  -- Set the options.
  PackageConf   :: FilePath -> Command (Returns ())
  -- Set the package conf.
  SetCurrentDir :: FilePath -> Command (Returns ())
  -- Set the current directory.

deriving instance Show (Command a)

-- | Evaluation result.
data EvalResult =
  NewContext [String]
  deriving (Show)

instance ToLisp EvalResult where
  toLisp (NewContext is) =
    L.List [L.Symbol "new-context",toLisp is]

-- | A message.
data Msg =
  Msg !Severity
      !SrcSpan
      !Text
  deriving (Show)

deriving instance Show Severity

instance ToLisp Msg where
  toLisp (Msg sev span' text') =
    L.List [L.Symbol "msg",toLisp sev,toLisp span',toLisp text']

instance ToLisp Severity where
  toLisp t = L.Symbol (T.pack (showSeverity t))

instance Show SuccessFlag where
  show Succeeded = "Succeeded"
  show Failed = "Failed"

instance ToLisp SuccessFlag where
  toLisp Succeeded = L.Symbol "succeeded"
  toLisp Failed = L.Symbol "failed"

--------------------------------------------------------------------------------
-- Spans

instance ToLisp SrcSpan where
  toLisp (RealSrcSpan realsrcspan) = toLisp realsrcspan
  toLisp (UnhelpfulSpan fs) = toLisp fs

instance ToLisp RealSrcSpan where
  toLisp span' =
    L.List [toLisp (srcSpanFile span')
           ,toLisp (srcSpanStartLine span')
           ,toLisp (srcSpanEndLine span')
           ,toLisp (srcSpanStartCol span')
           ,toLisp (srcSpanEndCol span')]

instance ToLisp FastString where
  toLisp = toLisp . unpackFS
