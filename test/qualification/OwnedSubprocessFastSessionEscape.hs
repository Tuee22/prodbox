{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Native regression for a short-lived parent whose new-session child redirects
-- its streams away. The parent exits only after the child records its identity.
-- Exit zero requires actual command success and that exact child already stopped.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, finally, try)
import Control.Monad (forM, unless)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.Maybe (isNothing)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Subprocess
import Prodbox.Subprocess.OwnedProcessTree
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..), exitFailure)
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Signals (sigKILL, signalProcess)

main :: IO ()
main = withSystemTempDirectory "prodbox-fast-session" $ \directory -> do
  resources <-
    either
      (fail . show)
      pure
      (mkOwnedSubprocessResourceBounds 67108864 16 1000000 16777216 8 1000000 30000 30000)
  limits <-
    either (fail . show) pure (mkOwnedSubprocessLimits resources 500000 50000 100000 50000 128 128)
  rows <- forM [1 .. 8 :: Int] $ \index -> do
    let path = directory <> "/child-" <> show index
        program =
          "setsid /bin/sh -c 'echo $$ > \"$1\"; cat /proc/$$/stat > \"$1.stat\"; exec /bin/sleep 20' child \"$1\" </dev/null >/dev/null 2>&1 & while [ ! -s \"$1.stat\" ]; do :; done; exit 0"
        child = Subprocess "/bin/sh" ["-c", program, "fast-session-fixture", path] Nothing Nothing
        collect = do
          started <- getMonotonicTimeNSec
          outcome <- captureOwnedSubprocess limits child
          finished <- getMonotonicTimeNSec
          original <- awaitIdentity path (100 :: Int)
          live <- maybe (pure False) stillLive original
          let tag = case outcome of
                Left cause -> show cause
                Right output -> "Completed " <> show (processExitCode output)
          pure
            ( live
                || isNothing original
                || outcome /= Right (ProcessOutput ExitSuccess "" "")
                || finished - started >= 500000000
            , object
                [ "case" .= index
                , "outcome" .= tag
                , "elapsed_micros" .= ((finished - started) `div` 1000)
                , "observed_child_identity" .= not (isNothing original)
                , "escaped_child_live_after_return" .= live
                ]
            )
    collect `finally` cleanup path
  Lazy.putStrLn
    ( encode
        ( object
            [ "fixed_case_count" .= length rows
            , "failed_cases" .= length (filter fst rows)
            , "cases" .= map snd rows
            ]
        )
    )
  if any fst rows then exitFailure else pure ()

awaitIdentity :: FilePath -> Int -> IO (Maybe ProcessStat)
awaitIdentity path remaining = do
  exists <- doesFileExist (path <> ".stat")
  if exists
    then do
      parsed <- parseProcessStat <$> TextIO.readFile (path <> ".stat")
      case parsed of
        Nothing -> fail "fixture child identity is malformed"
        Just identity -> pure (Just identity)
    else
      if remaining <= 0
        then pure Nothing
        else threadDelay 5000 >> awaitIdentity path (remaining - 1)

stillLive :: ProcessStat -> IO Bool
stillLive original = do
  observed <-
    try (TextIO.readFile ("/proc/" <> show (statPid original) <> "/stat"))
      :: IO (Either IOException Text.Text)
  case observed of
    Left cause
      | isDoesNotExistError cause -> pure False
      | otherwise -> fail "fixture child identity cannot be observed"
    Right body -> case parseProcessStat body of
      Just current -> pure (statStart current == statStart original && statState current `notElem` ["Z", "X"])
      Nothing -> fail "observed fixture child identity is malformed"

cleanup :: FilePath -> IO ()
cleanup path = do
  original <- awaitIdentity path 10
  case original of
    Nothing -> pure ()
    Just identity -> do
      running <- stillLive identity
      if running
        then do
          _ <- try (signalProcess sigKILL (statPid identity)) :: IO (Either IOException ())
          confirm identity (100 :: Int)
        else pure ()
 where
  confirm identity remaining = do
    running <- stillLive identity
    unless (not running) $
      if remaining <= 0
        then fail "fixture cleanup unconfirmed"
        else threadDelay 5000 >> confirm identity (remaining - 1)
