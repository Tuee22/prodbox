{-# LANGUAGE OverloadedStrings #-}

-- | The killable subprocess runner.
--
-- A Pulumi destroy that ignores SIGTERM, or a caller that is cancelled while
-- one runs, must not leave a child running past its deadline. These cases run
-- real children (small shell scripts) and check that they are stopped, that
-- the partial transcript survives, and that a child's own children die with it.
module SubprocessKillable
  ( subprocessKillableSuite
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Data.List (isInfixOf)
import Data.Maybe (isNothing)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Subprocess
import System.Exit (ExitCode (..))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Signals (nullSignal, signalProcess)
import System.Posix.Types (CPid (..))
import System.Timeout (timeout)
import TestSupport

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

subprocessKillableSuite :: SuiteBuilder ()
subprocessKillableSuite =
  describe "killable subprocess runner" $ do
    it "reports the exit and both streams of a child that completes" $ do
      result <-
        captureSubprocessKillable
          (KillableSubprocessLimits 5000000 1000000)
          (script "echo out; echo err >&2; exit 3")
      case result of
        Right (KillableSubprocessCompleted output) -> do
          processExitCode output `shouldBe` ExitFailure 3
          processStdout output `shouldBe` "out\n"
          processStderr output `shouldBe` "err\n"
        other -> expectationFailure ("expected a completed child, got " <> show other)

    it "stops a child that outlives its deadline and keeps its partial transcript" $
      withSystemTempDirectory "killable" $ \directory -> do
        let pidFile = directory <> "/pid"
        (result, elapsed) <-
          elapsedMillis
            ( captureSubprocessKillable
                (KillableSubprocessLimits 300000 2000000)
                (script ("echo $$ > " <> pidFile <> "; echo started; sleep 30"))
            )
        case result of
          Right (KillableSubprocessTimedOut output) ->
            processStdout output `shouldBe` "started\n"
          other -> expectationFailure ("expected a timed-out child, got " <> show other)
        elapsed `shouldSatisfy` (< 4000)
        recordedPid pidFile >>= eventuallyGone >>= (`shouldBe` True)

    it "sends SIGTERM, then SIGKILL after the grace, to a child that ignores SIGTERM" $
      withSystemTempDirectory "killable" $ \directory -> do
        let pidFile = directory <> "/pid"
        (result, elapsed) <-
          elapsedMillis
            ( captureSubprocessKillable
                (KillableSubprocessLimits 300000 1000000)
                ( script
                    ( "echo $$ > "
                        <> pidFile
                        <> "; trap 'echo got-term' TERM; echo started; "
                        <> "while true; do sleep 0.2; done"
                    )
                )
            )
        case result of
          Right (KillableSubprocessTimedOut output) ->
            -- The child saw the polite signal and survived it.
            processStdout output `shouldSatisfy` isInfixOf "got-term"
          other -> expectationFailure ("expected a timed-out child, got " <> show other)
        -- ...so only the escalation after the grace could have stopped it.
        elapsed `shouldSatisfy` (>= 1000)
        elapsed `shouldSatisfy` (< 6000)
        recordedPid pidFile >>= eventuallyGone >>= (`shouldBe` True)

    it "stops a process the child started along with the child" $
      withSystemTempDirectory "killable" $ \directory -> do
        let pidFile = directory <> "/grandchild"
        result <-
          captureSubprocessKillable
            (KillableSubprocessLimits 300000 1000000)
            (script ("sleep 60 & echo $! > " <> pidFile <> "; wait"))
        case result of
          Right (KillableSubprocessTimedOut _) -> pure ()
          other -> expectationFailure ("expected a timed-out child, got " <> show other)
        recordedPid pidFile >>= eventuallyGone >>= (`shouldBe` True)

    it "stops the child when the caller is cancelled" $
      withSystemTempDirectory "killable" $ \directory -> do
        let pidFile = directory <> "/pid"
        (cancelled, elapsed) <-
          elapsedMillis
            ( timeout
                400000
                ( captureSubprocessKillable
                    (KillableSubprocessLimits 30000000 1000000)
                    (script ("echo $$ > " <> pidFile <> "; sleep 30"))
                )
            )
        cancelled `shouldSatisfy` isNothing
        elapsed `shouldSatisfy` (< 4000)
        recordedPid pidFile >>= eventuallyGone >>= (`shouldBe` True)

    it "refuses limits that are not positive" $ do
      zeroTimeout <- captureSubprocessKillable (KillableSubprocessLimits 0 1000) (script "true")
      zeroGrace <- captureSubprocessKillable (KillableSubprocessLimits 1000 0) (script "true")
      zeroTimeout `shouldSatisfy` isRefused
      zeroGrace `shouldSatisfy` isRefused
 where
  isRefused result = case result of
    Left _ -> True
    Right _ -> False
