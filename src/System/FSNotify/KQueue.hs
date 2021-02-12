{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module System.FSNotify.KQueue
  ( NativeManager,
    KQueueListener (),
    KQueueError (..),
  )
where

import Control.Concurrent
import Control.Exception.Safe
import Control.Monad
import Data.Functor
import qualified Data.List as L
import Data.Map ((!?))
import qualified Data.Map as M
import Data.Maybe
import Data.Time.Clock
import Data.Time.Clock.System
import Debug.Trace
import Foreign.Ptr
import System.FSNotify.Listener
import System.FSNotify.Path
import System.FSNotify.Types
import System.KQueue
import System.Posix.Files
import System.Posix.IO
import System.PosixCompat.Types

newtype KQueueListener = KQueueListener (MVar Watchers)

type NativeManager = KQueueListener

instance FileListener KQueueListener () where
  initSession _ = Right . KQueueListener <$> newMVar M.empty
  killSession (KQueueListener wt) = readMVar wt >>= killAllWatchers
    where
      killAllWatchers ws = forM_ (snd <$> M.toList ws) killWatcher
  listen _config = startWatching False
  listenRecursive _config = startWatching True
  usesPolling _ = False

data KQueueError
  = KEventError String
  | PathUnknown KEvent
  deriving (Show)

instance Exception KQueueError

startWatching :: Bool -> KQueueListener -> FilePath -> ActionPredicate -> EventCallback -> IO StopListening
startWatching recursive (KQueueListener ws) dir' actPred callback = do
  dir <- canonicalizeDirPath dir'
  files <- findFilesAndDirs recursive dir
  traceIO $ "files: " <> show files
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
  _ <- kevent kq (fmap (setFlag EvAdd . setFlag EvOneshot) eventsToMonitor) 0 Nothing
  traceIO "events added to kqueue"
  sem <- newQSem 0
  listenerThreadId <- forkIO $ do
    waitQSem sem
    forever $ do
      M.lookup dir <$> readMVar ws >>= \case
        Nothing -> do
          traceIO "watcher no longer exists but watch thread still running; killing self"
          myThreadId >>= killThread
        Just (DirWatcher kq _ dfd ffds) -> do
          traceIO "waiting for event from kqueue"
          -- block until an event occurs or 1s timeout
          changes <- kevent kq [] 1 (Just 1)
          forM_ changes $ \change -> do
            traceIO $ "event received: " <> show change
            eventTime <- systemToUTCTime <$> getSystemTime
            events <- filter actPred <$> convertToEvents recursive dfd change eventTime ffds
            traceIO $ "converted events: " <> show events
            forM_ events $ \changeEvent -> do
              traceIO $ "actPred returned True for event " <> show changeEvent
              traceIO $ "invoking callback with " <> show changeEvent
              callback changeEvent
              case changeEvent of
                Added {eventPath} ->
                  modifyMVar_ ws $ \ws -> do
                    traceIO $ "watching new file " <> show eventPath
                    case ws !? dir of
                      Just (DirWatcher kq tid dfd ffds) -> do
                        ffd <- FdPath eventPath <$> openFd eventPath ReadOnly Nothing defaultFileFlags
                        let event = mkFileEvent ffd
                        _ <- kevent kq [setFlag EvAdd . setFlag EvOneshot $ event] 0 Nothing
                        let newWatcher = DirWatcher kq tid dfd (ffd : ffds)
                        pure (M.insert dir newWatcher ws)
                      Nothing -> pure ws
                Removed {eventPath} ->
                  modifyMVar_ ws $ \ws -> do
                    traceIO $ "removing " <> show eventPath <> " from watch state"
                    case ws !? dir of
                      Just w ->
                        stopWatchingPath w eventPath >>= \case
                          Just w -> pure $ M.insert dir w ws
                          Nothing -> pure $ M.delete dir ws
                      Nothing -> pure ws
                WatchedDirectoryRemoved {eventPath} -> do
                  modifyMVar_ ws $ \ws -> do
                    traceIO $ "removing watched dir " <> show eventPath <> " from watch state"
                    case ws !? eventPath of
                      Just w -> killWatcher w >> pure (M.delete eventPath ws)
                      Nothing -> pure ws
                _any -> do
                  traceIO "re-adding event to kqueue"
                  _ <- kevent kq [setFlag EvAdd . setFlag EvOneshot $ change] 0 Nothing
                  pure ()
  let watcher = DirWatcher kq listenerThreadId (FdPath dir dfd) ffds
  modifyMVar_ ws $ \ws -> do
    pure $ M.insert dir watcher ws
  signalQSem sem
  pure $ killWatcher watcher

convertToEvents :: Bool -> FdPath -> KEvent -> UTCTime -> [FdPath] -> IO [Event]
convertToEvents recursive (FdPath rootPath rootFd) kev@KEvent {..} eventTime fds
  -- sub dir removed or added
  | NoteWrite `elem` fflags && NoteLink `elem` fflags && (recursive || rootFd == Fd (fromIntegral ident)) = do
    (path, _) <- getEventPath
    dirs <- findDirs False path
    traceIO $ "dirs: " <> show dirs
    let newDirs = dirs L.\\ fmap fdPath fds
    traceIO $ "newDirs: " <> show newDirs
    let oldDirs = filter (/= path) $ fmap fdPath fds L.\\ dirs
    traceIO $ "oldDirs: " <> show oldDirs
    let removed = oldDirs <&> \oldDir -> Removed oldDir eventTime IsDirectory
    let added = newDirs <&> \newDir -> Added newDir eventTime IsDirectory
    pure (removed <> added)
  | NoteWrite `elem` fflags && NoteLink `elem` fflags = pure []
  | NoteWrite `elem` fflags = handleWriteEvent
  | NoteDelete `elem` fflags =
    if (fromIntegral rootFd) == ident
      then mkEvent WatchedDirectoryRemoved
      else mkEvent Removed
  | NoteAttrib `elem` fflags = mkEvent ModifiedAttributes
  | NoteRename `elem` fflags = do
    let fd' = Fd (fromIntegral ident)
    stat <- getFdStatus fd'
    let isFile = isRegularFile stat
    let eventIsDirectory = if isFile then IsFile else IsDirectory
    case filter ((== fd') . fd) fds of
      [] -> pure []
      ((FdPath oldPath fd') : _) -> do
        files <- findFilesAndDirs recursive rootPath
        let newFiles = files L.\\ fmap fdPath fds
        added <- forM newFiles $ \newPath -> do
          newFd <- openFd newPath ReadOnly Nothing defaultFileFlags
          sameFile <- isSameFile fd' newFd
          closeFd newFd
          if sameFile
            then pure $ Just $ Added newPath eventTime eventIsDirectory
            else pure Nothing
        pure $ [Removed oldPath eventTime eventIsDirectory] <> catMaybes added
  | otherwise = pure []
  where
    getEventPath :: IO (FilePath, EventIsDirectory)
    getEventPath
      | rootFd == Fd (fromIntegral ident) = pure (rootPath, IsDirectory)
      | otherwise =
        getPath kev fds >>= \case
          Just c -> pure c
          Nothing -> throwIO $ PathUnknown kev
    mkEvent e = do
      (eventPath, eventIsDirectory) <- getEventPath
      pure [e eventPath eventTime eventIsDirectory]
    handleWriteEvent = do
      isDir <- isDirectory <$> getFdStatus (Fd (fromIntegral ident))
      if (fromIntegral rootFd) == ident
        then do
          filesAndDirs <- findFilesAndDirs False rootPath
          let newFiles = filesAndDirs L.\\ fmap fdPath fds
          forM newFiles $ \newFile -> do
            eventIsDirectory <-
              isRegularFile <$> getFileStatus newFile >>= \case
                True -> pure IsFile
                False -> pure IsDirectory
            fileExist newFile >>= \case
              True -> pure $ Added newFile eventTime eventIsDirectory
              False -> pure $ Removed newFile eventTime eventIsDirectory
        else
          if isDir && not recursive
            then pure []
            else do
              (eventPath, eventIsDirectory) <- getEventPath
              case eventIsDirectory of
                IsDirectory -> do
                  allFiles <- findFiles False eventPath
                  let newFiles = allFiles L.\\ fmap fdPath fds
                  pure $ Added <$> newFiles <*> pure eventTime <*> pure IsFile
                IsFile -> pure [Modified eventPath eventTime eventIsDirectory]

getPath :: KEvent -> [FdPath] -> IO (Maybe (FilePath, EventIsDirectory))
getPath KEvent {..} fds = do
  eventIsDirectory <- fdEventIsDirectory (Fd (fromIntegral ident))
  case filter (\(FdPath _ (Fd fd)) -> fromIntegral fd == ident) fds of
    (FdPath path _ : _) -> do
      traceIO $ "eventPath: " <> path
      pure $ Just (path, eventIsDirectory)
    _ -> pure Nothing

fdEventIsDirectory :: Fd -> IO EventIsDirectory
fdEventIsDirectory fd =
  getFdStatus fd <&> isRegularFile >>= \case
    True -> pure IsFile
    False -> pure IsDirectory

isSameFile :: Fd -> Fd -> IO Bool
isSameFile a b = do
  statA <- getFdStatus a
  statB <- getFdStatus b
  pure $ deviceID statA == deviceID statB && fileID statA == fileID statB

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

data FdPath = FdPath
  { fdPath :: FilePath,
    fd :: Fd
  }
  deriving (Show)

closeFdPath :: FdPath -> IO ()
closeFdPath (FdPath _ fd) = handleAny (const $ pure ()) $ closeFd fd

stopWatchingPath :: Watcher -> FilePath -> IO (Maybe Watcher)
stopWatchingPath w@(DirWatcher kq tid dfd@(FdPath root _) ffds) stopPath
  | root == stopPath = do
    traceIO $ "stopping watch on " <> show stopPath
    traceIO "path is watch root; killing watcher"
    killWatcher w >> pure Nothing
  | otherwise = do
    traceIO $ "stopping watch on " <> show stopPath
    newFfds <- forM ffds $ \ffd@(FdPath path _) ->
      if stopPath `L.isPrefixOf` path
        then do
          closeFdPath ffd
          pure Nothing
        else pure $ Just ffd
    pure $ Just (DirWatcher kq tid dfd (catMaybes newFfds))
