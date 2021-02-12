{-# LANGUAGE CPP, OverloadedStrings, ImplicitParams, MultiWayIf, LambdaCase, RecordWildCards, ViewPatterns #-}

-- |

module FSNotify.Test.EventTests where

import Control.Monad
import Data.Monoid
import FSNotify.Test.Util
import Prelude hiding (FilePath)
import System.Directory
import System.FSNotify
import System.FilePath
import System.IO
import System.IO.Temp
import Test.Hspec


eventTests :: ThreadingMode -> Spec
eventTests threadingMode = describe "Tests" $
  forM_ [False, True] $ \poll -> describe (if poll then "Polling" else "Native") $ do
    let ?timeInterval = if poll then 2*10^(6 :: Int) else 5*10^(5 :: Int)
    forM_ [False, True] $ \recursive -> describe (if recursive then "Recursive" else "Non-recursive") $
      forM_ [False, True] $ \nested -> describe (if nested then "In a subdirectory" else "Right here") $
        makeTestFolder threadingMode poll recursive nested $ do
          unless (nested || poll || isMac || isWin) $ it "deletes the watched directory" $ \(watchedDir, _f, getEvents, _clearEvents) -> do
            removeDirectory watchedDir

            pauseAndRetryOnExpectationFailure 3 $ getEvents >>= \case
              [WatchedDirectoryRemoved {..}] | eventPath `equalFilePath` watchedDir && eventIsDirectory == IsDirectory -> return ()
              events -> expectationFailure $ "Got wrong events: " <> show events

          it "works with a new file" $ \(_watchedDir, f, getEvents, _clearEvents) -> do
            openFile f AppendMode >>= hClose

            pauseAndRetryOnExpectationFailure 3 $ getEvents >>= \events ->
              if | nested && not recursive -> events `shouldBe` []
                 | otherwise -> case events of
                     [Added {..}] | eventPath `equalFilePath` f && eventIsDirectory == IsFile -> return ()
                     _ -> expectationFailure $ "Got wrong events: " <> show events

          it "works with a new directory" $ \(_watchedDir, f, getEvents, _clearEvents) -> do
            createDirectory f

            pauseAndRetryOnExpectationFailure 3 $ getEvents >>= \events ->
              if | nested && not recursive -> events `shouldBe` []
                 | otherwise -> case events of
                     [Added {..}] | eventPath `equalFilePath` f && eventIsDirectory == IsDirectory -> return ()
                     _ -> expectationFailure $ "Got wrong events: " <> show events

          it "works with a deleted file" $ \(_watchedDir, f, getEvents, clearEvents) -> do
            writeFile f "" >> clearEvents

            removeFile f

            pauseAndRetryOnExpectationFailure 3 $ getEvents >>= \events ->
              if | nested && not recursive -> events `shouldBe` []
                 | otherwise -> case events of
                     [Removed {..}] | eventPath `equalFilePath` f && eventIsDirectory == IsFile -> return ()
                     _ -> expectationFailure $ "Got wrong events: " <> show events

          it "works with a deleted directory" $ \(_watchedDir, f, getEvents, clearEvents) -> do
            createDirectory f >> clearEvents

            removeDirectory f

            pauseAndRetryOnExpectationFailure 3 $ getEvents >>= \events ->
              if | nested && not recursive -> events `shouldBe` []
                 | otherwise -> case events of
                     [Removed {..}] | eventPath `equalFilePath` f && eventIsDirectory == IsDirectory -> return ()
                     _ -> expectationFailure $ "Got wrong events: " <> show events

          it "works with modified file attributes" $ \(_watchedDir, f, getEvents, clearEvents) -> do
            writeFile f "" >> clearEvents

            changeFileAttributes f

            -- This test is disabled when polling because the PollManager only keeps track of
            -- modification time, so it won't catch an unrelated file attribute change
            pauseAndRetryOnExpectationFailure 3 $ getEvents >>= \events ->
              if | poll -> return ()
                 | nested && not recursive -> events `shouldBe` []
                 | otherwise -> case events of
#ifdef mingw32_HOST_OS
                     [Modified {..}] | eventPath `equalFilePath` f && eventIsDirectory == IsFile -> return ()
#else
                     [ModifiedAttributes {..}] | eventPath `equalFilePath` f && eventIsDirectory == IsFile -> return ()
#endif
                     _ -> expectationFailure $ "Got wrong events: " <> show events

          it "works with a modified file" $ \(_watchedDir, f, getEvents, clearEvents) -> do
            writeFile f "" >> clearEvents

            appendFile f "foo"

            pauseAndRetryOnExpectationFailure 3 $ getEvents >>= \events ->
              if | nested && not recursive -> events `shouldBe` []
                 | otherwise -> case events of
                     [Modified {..}] | eventPath `equalFilePath` f && eventIsDirectory == IsFile -> return ()
                     _ -> expectationFailure $ "Got wrong events: " <> show events

          when isFreeBSD $ it "renames directory" $ \(_watchedDir, f, getEvents, clearEvents) -> do
            createDirectory f >> clearEvents
            renameDirectory f (init f)

            pauseAndRetryOnExpectationFailure 3 $ getEvents >>= \case
              [Removed {eventPath=oldPath}, Added {eventPath=newPath}] | oldPath == f && newPath == init f -> return ()
              events -> expectationFailure $ "Got wrong events: " <> show events

          when isFreeBSD $ it "renames file" $ \(_watchedDir, f, getEvents, clearEvents) -> do
            writeFile f "" >> clearEvents
            renameFile f (init f)

            pauseAndRetryOnExpectationFailure 3 $ getEvents >>= \case
              [Removed {eventPath=oldPath}, Added {eventPath=newPath}] | oldPath == f && newPath == init f -> return ()
              events -> expectationFailure $ "Got wrong events: " <> show events

          when isFreeBSD $ it "renames directory outside watched dir" $ \(_watchedDir, f, getEvents, clearEvents) -> do
            withRandomTempDirectory $ \tmpDir -> do
              clearEvents
              createDirectory f >> clearEvents
              renameDirectory f (tmpDir </> "newdir")

              pauseAndRetryOnExpectationFailure 3 $ getEvents >>= \case
                [Removed {eventPath=oldPath}, Added {eventPath=newPath}] | oldPath == f && newPath == (tmpDir </> "newdir") -> return ()
                events -> expectationFailure $ "Got wrong events: " <> show events

          when isFreeBSD $ it "renames file outside watched dir" $ \(_watchedDir, f, getEvents, clearEvents) -> do
            withRandomTempDirectory $ \tmpDir -> do
              writeFile f "" >> clearEvents
              renameFile f (tmpDir </> "testfile")

              pauseAndRetryOnExpectationFailure 3 $ getEvents >>= \case
                [Removed {eventPath=oldPath}, Added {eventPath=newPath}] | oldPath == f && newPath == (tmpDir </> "testfile") -> return ()
                events -> expectationFailure $ "Got wrong events: " <> show events
