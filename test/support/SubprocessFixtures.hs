{-# LANGUAGE OverloadedStrings #-}

-- | Concrete process fixtures shared by unit boundaries and native lifecycle cases.
module SubprocessFixtures
  ( script
  , elapsedMillis
  , recordedPid
  , eventuallyGone
  , ownedFixtureResources
  , runOwnedFixture
  , cleanupPlugin
  , processStopped
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Subprocess
import Prodbox.Subprocess.OwnedProcessTree
import System.Directory (doesFileExist)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Signals (nullSignal, sigKILL, signalProcess)
import System.Posix.Types (CPid (..))

script :: String -> Subprocess
script body =
  Subprocess
    { subprocessPath = "/bin/sh"
    , subprocessArguments = ["-c", body]
    , subprocessEnvironment = Nothing
    , subprocessWorkingDirectory = Nothing
    }

elapsedMillis :: IO a -> IO (a, Int)
elapsedMillis action = do
  start <- getMonotonicTimeNSec
  result <- action
  end <- getMonotonicTimeNSec
  pure (result, fromIntegral ((end - start) `div` 1000000))

-- | The pid a script recorded for itself or for a child it started.
recordedPid :: FilePath -> IO Int
recordedPid path = read <$> readFile path

-- | Whether the process is gone, allowing the init process a moment to reap an
-- orphan.
eventuallyGone :: Int -> IO Bool
eventuallyGone pid = go (40 :: Int)
 where
  go 0 = not <$> alive
  go remaining = do
    stillAlive <- alive
    if stillAlive then threadDelay 50000 >> go (remaining - 1) else pure True
  alive = do
    result <-
      try (signalProcess nullSignal (CPid (fromIntegral pid))) :: IO (Either IOException ())
    pure (either (const False) (const True) result)

ownedFixtureResources :: IO OwnedSubprocessResourceBounds
ownedFixtureResources =
  either
    (fail . show)
    pure
    (mkOwnedSubprocessResourceBounds 67108864 16 1000000 16777216 8 1000000 30000 30000)

runOwnedFixture :: Int -> Int -> Int -> Subprocess -> IO (Either OwnedSubprocessError ProcessOutput)
runOwnedFixture total out err child = do
  resources <- ownedFixtureResources
  case mkOwnedSubprocessLimits resources total 100000 300000 100000 out err of
    Left cause -> pure (Left cause)
    Right limits -> captureOwnedSubprocess limits child

cleanupPlugin :: FilePath -> IO ()
cleanupPlugin path = do
  exists <- doesFileExist (path <> ".stat")
  if exists
    then do
      original <- parseProcessStat . Text.pack <$> readFile (path <> ".stat")
      case original of
        Nothing -> pure ()
        Just identity -> do
          current <-
            try (readFile ("/proc/" ++ show (statPid identity) ++ "/stat")) :: IO (Either IOException String)
          case current of
            Right value
              | Just row <- parseProcessStat (Text.pack value)
              , statStart row == statStart identity -> do
                  _ <- try (signalProcess sigKILL (statPid identity)) :: IO (Either IOException ())
                  pure ()
            _ -> pure ()
    else pure ()

-- A zombie has stopped and no longer holds a plugin's memory or pipes.
processStopped :: Int -> IO Bool
processStopped pid = do
  contents <- try (readFile ("/proc/" ++ show pid ++ "/stat")) :: IO (Either IOException String)
  pure $ case contents of
    Left err -> isDoesNotExistError err
    Right value -> case parseProcessStat (Text.pack value) of
      Just row -> statState row `elem` ["Z", "X"]
      Nothing -> False
