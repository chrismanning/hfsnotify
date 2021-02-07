{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module System.FSNotify.KQueue (
  NativeManager,
  KQueueListener ()
) where

import Control.Concurrent (ThreadId, forkIO, killThread)
import Control.Concurrent.MVar
import Control.Monad
import qualified Data.List as L
import qualified Data.Map as M
import Data.Map ((!?))
import Data.Maybe
import Data.Time.Clock
import Foreign.Ptr
import System.FSNotify.Listener
import System.FSNotify.Path
import System.FSNotify.Types
import System.Posix.Files
import System.Posix.IO
import System.PosixCompat.Types
import Data.Time.Clock.System
import System.KQueue

import Debug.Trace

newtype KQueueListener = KQueueListener (MVar Watchers)

type NativeManager = KQueueListener

instance FileListener KQueueListener () where
  initSession _ = Right . KQueueListener <$> newMVar M.empty
  killSession (KQueueListener wt) = do
    modifyMVar wt $ \wt -> do
      killAllWatchers wt
      pure (M.empty, ())
    where
      killAllWatchers ws = forM_ (snd <$> M.toList ws) killWatcher
  listen _config (KQueueListener ws) dir' actPred callback = do
    dir <- canonicalizeDirPath dir'
    files <- findFiles False dir
    dfd <- openFd dir ReadOnly Nothing defaultFileFlags
    let dirEvent =
          KEvent
            { ident = fromIntegral dfd,
              evfilter = EvfiltVnode,
              flags = [],
              fflags = [NoteDelete, NoteRename, NoteWrite, NoteAttrib],
              data_ = 0,
              udata = nullPtr
            }
        mkFileEvent (FdPath _ fd) =
          KEvent
            { ident = fromIntegral fd,
              evfilter = EvfiltVnode,
              flags = [],
              fflags = [NoteDelete, NoteWrite, NoteRename, NoteAttrib],
              data_ = 0,
              udata = nullPtr
            }
    ffds <- forM files $ \path ->
      FdPath path <$> openFd path ReadOnly Nothing defaultFileFlags
    let eventsToMonitor = dirEvent : fmap mkFileEvent ffds
    -- create new kqueue
    traceIO "creating kqueue"
    kq <- kqueue
    traceIO "kqueue created"
    -- add events to be monitored
    traceIO "adding events to kqueue to be monitored"
    traceShowM eventsToMonitor
    _ <- kevent kq (fmap (setFlag EvAdd) eventsToMonitor) 0 Nothing
    traceIO "events added to kqueue"
    listenerThreadId <- forkIO $ forever $ do
      traceIO "waiting for event from kqueue"
      -- block until an event occurs
      [change] <- kevent kq [] 1 Nothing
      traceIO $ "event received: " <> show change
      eventTime <- systemToUTCTime <$> getSystemTime
      getPath change (FdPath dir dfd : ffds) >>= \case
        -- no path for fd - throw exception?
        Nothing -> traceIO ("no path for fd " <> show dfd) >> pure ()
        Just (eventPath, eventIsDirectory) -> do
          traceIO $ "eventPath: " <> eventPath
          case convertToEvent change eventPath eventTime eventIsDirectory of
            Just changeEvent | actPred changeEvent -> do
              traceIO "actPred returned True"
                -- TODO start watching new files
              case changeEvent of
                Removed {eventPath, eventIsDirectory=IsFile} ->
                  modifyMVar_ ws $ \ws -> do
                    traceIO $ "removing file " <> show eventPath <> " from watch state"
                    case ws !? dir of
                      Just w -> stopWatchingPath w eventPath >>= \case
                        Just w -> pure $ M.insert dir w ws
                        Nothing -> pure $ M.delete dir ws
                      Nothing -> pure ws
                Removed {eventPath, eventIsDirectory=IsDirectory} ->
                  modifyMVar_ ws $ \ws -> do
                    traceIO $ "removing dir " <> show eventPath <> " from watch state"
                    case ws !? dir of
                      Just w -> stopWatchingPath w eventPath >>= \case
                        Just w -> pure $ M.insert dir w ws
                        Nothing -> pure $ M.delete dir ws
                      Nothing -> pure ws
                WatchedDirectoryRemoved {eventPath} -> do
                  modifyMVar_ ws $ \ws -> do
                    traceIO $ "removing watched dir " <> show eventPath <> " from watch state"
                    case ws !? eventPath of
                      Just w -> killWatcher w >> pure (M.delete eventPath ws)
                      Nothing -> pure ws
                _ -> pure ()
              traceIO $ "invoking callback with " <> show changeEvent
              callback changeEvent
            _otherwise -> pure ()
    let watcher = DirWatcher kq listenerThreadId (FdPath dir dfd) ffds
    modifyMVar_ ws $ \ws -> do
      pure $ M.insert dir watcher ws
    pure $ killWatcher watcher
  listenRecursive _config (KQueueListener wt) path actPred callback = error "unimplemented"
  usesPolling _ = False

getPath :: KEvent -> [FdPath] -> IO (Maybe (FilePath, EventIsDirectory))
getPath KEvent {..} fds = do
  status <- getFdStatus (Fd (fromIntegral ident))
  let eventIsDirectory = if isRegularFile status then IsFile else IsDirectory
  case filter (\(FdPath _ (Fd fd)) -> fromIntegral fd == ident) fds of
    (FdPath path _ : _) -> pure $ Just (path, eventIsDirectory)
    _ -> pure Nothing

convertToEvent :: KEvent -> FilePath -> UTCTime -> EventIsDirectory -> Maybe Event
convertToEvent KEvent {..} eventPath eventTime eventIsDirectory
  | NoteDelete `elem` fflags = mkEvent Removed
  | NoteWrite `elem` fflags = mkEvent Modified
  | NoteAttrib `elem` fflags = mkEvent ModifiedAttributes
  | NoteRename `elem` fflags = mkEvent Removed
  | otherwise = Nothing
  where
    mkEvent e = Just $ e eventPath eventTime eventIsDirectory

setFlag :: Flag -> KEvent -> KEvent
setFlag flag ev = ev {flags = flag : flags ev}

data Watcher
  = DirWatcher KQueue ThreadId FdPath [FdPath]

killWatcher :: Watcher -> IO ()
killWatcher (DirWatcher _kq tid dfd ffds) = do
  closeFdPath dfd
  closeFdPath `mapM_` ffds
  killThread tid

type Watchers = M.Map FilePath Watcher

data FdPath = FdPath FilePath Fd

closeFdPath :: FdPath -> IO ()
closeFdPath (FdPath _ fd) = closeFd fd

stopWatchingPath :: Watcher -> FilePath -> IO (Maybe Watcher)
stopWatchingPath w@(DirWatcher kq tid dfd@(FdPath root _) ffds) stopPath
  | root == stopPath = do
    traceIO $ "stopping watch on " <> show stopPath
    traceIO "path is watch root; killing watcher"
    killWatcher w >> pure Nothing
  | otherwise = do
    traceIO $ "stopping watch on " <> show stopPath
    newFfds <- forM ffds $ \ffd@(FdPath path _) ->
      if stopPath `L.isPrefixOf` path then do
        closeFdPath ffd
        pure Nothing
      else
        pure $ Just ffd
    pure $ Just (DirWatcher kq tid dfd (catMaybes newFfds))