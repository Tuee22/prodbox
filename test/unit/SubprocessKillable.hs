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
import Control.Exception (IOException, finally, try)
import Data.List (isInfixOf)
import Data.Maybe (isNothing)
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Subprocess
import Prodbox.Subprocess.OwnedProcessTree
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Signals (nullSignal, sigKILL, signalProcess)
import System.Posix.Types (CPid (..))
import System.Process qualified as Process
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
    ownedProcessTreeCases
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

    it "repeats SIGTERM before it escalates, for a child that stops only on the second" $
      withSystemTempDirectory "killable" $ \directory -> do
        let pidFile = directory <> "/pid"
        (result, elapsed) <-
          elapsedMillis
            ( captureSubprocessKillable
                (KillableSubprocessLimits 300000 4000000)
                ( script
                    ( "echo $$ > "
                        <> pidFile
                        <> "; n=0; trap 'n=$((n+1)); echo term-$n; if [ $n -ge 2 ]; then exit 7; fi' TERM; "
                        <> "echo started; while true; do sleep 0.1; done"
                    )
                )
            )
        case result of
          Right (KillableSubprocessTimedOut output) -> do
            -- It saw both signals and left on its own accord, which is the way a
            -- Pulumi stops its plugins and releases its backend lock; the kill
            -- would have ended it with a signal status instead.
            processStdout output `shouldSatisfy` isInfixOf "term-2"
            processExitCode output `shouldBe` ExitFailure 7
          other -> expectationFailure ("expected a timed-out child, got " <> show other)
        -- ...and well inside the grace, so nothing waited for the kill.
        elapsed `shouldSatisfy` (< 3500)
        recordedPid pidFile >>= eventuallyGone >>= (`shouldBe` True)

    it "does not repeat SIGTERM to a child that left on the first" $
      withSystemTempDirectory "killable" $ \directory -> do
        let pidFile = directory <> "/pid"
        (result, _) <-
          elapsedMillis
            ( captureSubprocessKillable
                (KillableSubprocessLimits 300000 4000000)
                ( script
                    ( "echo $$ > "
                        <> pidFile
                        <> "; n=0; trap 'n=$((n+1)); echo term-$n; exit 5' TERM; "
                        <> "echo started; while true; do sleep 0.1; done"
                    )
                )
            )
        case result of
          Right (KillableSubprocessTimedOut output) -> do
            processStdout output `shouldSatisfy` isInfixOf "term-1"
            processStdout output `shouldSatisfy` (not . isInfixOf "term-2")
            processExitCode output `shouldBe` ExitFailure 5
          other -> expectationFailure ("expected a timed-out child, got " <> show other)

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

-- A process in a separate session also has a separate process group, which is
-- stronger than the Pulumi plugin shape that originally escaped the group kill.
ownedProcessTreeCases :: SuiteBuilder ()
ownedProcessTreeCases = describe "Sprint 4.111 owned descendant stop" $ do
  it "parses proc identities even when the command contains parentheses and spaces" $ do
    let fields = "S 10 123 123 " ++ unwords (replicate 15 "0") ++ " 999 0 0"
    parseProcessStat (Text.pack ("123 (command with ) spaces) " ++ fields))
      `shouldBe` Just (ProcessStat 123 10 123 999 "S")
    map parseProcessStat ["", "123", "123 (name) S 1 2 3", "nonnumeric (name) S 1 2 3"]
      `shouldBe` replicate 4 Nothing

  it "stops a separately grouped plugin after killing its parent, preserving a foreign process" $
    withSystemTempDirectory "killable-plugin" $ \directory -> do
      (_, _, _, foreignProcess) <- Process.createProcess (Process.proc "/bin/sleep" ["30"])
      let pluginFile = directory <> "/plugin"
          body = pluginBody pluginFile ++ " trap '' TERM; echo parent-started; wait"
      ( do
          (result, elapsed) <-
            elapsedMillis
              ( captureSubprocessKillable
                  (KillableSubprocessLimits 500000 600000)
                  (script body)
              )
          case result of
            Right (KillableSubprocessTimedOut output) -> processStdout output `shouldContain` "parent-started"
            other -> expectationFailure (show other)
          elapsed `shouldSatisfy` (< 4000)
          recordedPid pluginFile >>= processStopped >>= (`shouldBe` True)
          Process.getProcessExitCode foreignProcess >>= (`shouldBe` Nothing)
        )
        `finally` ( cleanupPlugin pluginFile
                      >> Process.terminateProcess foreignProcess
                      >> Process.waitForProcess foreignProcess
                      >> pure ()
                  )

  it "stops a separately grouped plugin when the caller is cancelled" $
    withSystemTempDirectory "killable-plugin-cancel" $ \directory -> do
      let pluginFile = directory <> "/plugin"
      ( do
          (result, elapsed) <-
            elapsedMillis
              ( timeout
                  500000
                  ( captureSubprocessKillable
                      (KillableSubprocessLimits 30000000 600000)
                      (script (pluginBody pluginFile ++ " trap '' TERM; wait"))
                  )
              )
          result `shouldSatisfy` isNothing
          elapsed `shouldSatisfy` (< 4000)
          recordedPid pluginFile >>= processStopped >>= (`shouldBe` True)
        )
        `finally` cleanupPlugin pluginFile
 where
  -- Positional shell arguments keep the fixture path out of the program text.
  pluginBody path =
    "setsid /bin/sh -c 'echo $$ > \"$1\"; cat /proc/$$/stat > \"$1.stat\"; trap \"\" TERM; exec sleep 30' plugin "
      ++ quote path
      ++ " &"
  quote value = "'" ++ concatMap (\c -> if c == '\'' then "'\"'\"'" else [c]) value ++ "'"
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
  processStopped pid = do
    contents <- try (readFile ("/proc/" ++ show pid ++ "/stat")) :: IO (Either IOException String)
    pure $ case contents of
      Left err -> isDoesNotExistError err
      Right value -> case parseProcessStat (Text.pack value) of
        Just row -> statState row `elem` ["Z", "X"]
        Nothing -> False
