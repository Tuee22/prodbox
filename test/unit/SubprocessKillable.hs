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

import Control.Exception (finally)
import Control.Monad (forM_)
import Data.List (isInfixOf)
import Data.Maybe (isNothing)
import Data.Text qualified as Text
import Prodbox.Subprocess
import Prodbox.Subprocess.OwnedProcessTree
import SubprocessFixtures
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Process
import System.Timeout (timeout)
import TestSupport

subprocessKillableSuite :: SuiteBuilder ()
subprocessKillableSuite =
  describe "killable subprocess runner" $ do
    ownedProcessTreeCases
    boundedOwnedCases
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

boundedOwnedCases :: SuiteBuilder ()
boundedOwnedCases = describe "Sprint 6.5 total-budget bounded owned child" $ do
  forM_
    [ ("total", (0, 100000, 100000, 100000, 4, 4))
    , ("grace", (1000000, 0, 100000, 100000, 4, 4))
    , ("confirmation", (1000000, 100000, 0, 100000, 4, 4))
    , ("settlement", (1000000, 100000, 100000, 0, 4, 4))
    , ("stdout", (1000000, 100000, 100000, 100000, 0, 4))
    , ("stderr", (1000000, 100000, 100000, 100000, 4, 0))
    , ("no work reserve", (300000, 100000, 100000, 100000, 4, 4))
    , ("overflowing cleanup", (maxBound, maxBound, maxBound, maxBound, 4, 4))
    ]
    $ \(label, (total, grace, confirmation, settlement, out, err)) ->
      it ("refuses invalid " <> label <> " before launch") $ do
        resources <- ownedFixtureResources
        case mkOwnedSubprocessLimits resources total grace confirmation settlement out err of
          Left cause -> cause `shouldBe` OwnedSubprocessInvalidLimits
          Right _ -> expectationFailure "invalid owned-child budget was admitted"

  forM_ [0 .. 7 :: Int] $ \index ->
    forM_ [0, maxBound] $ \invalid ->
      it ("refuses non-finite resource field " <> show index <> " = " <> show invalid) $ do
        let base = [67108864, 16, 1000000, 16777216, 8, 1000000, 30000, 30000]
            fields = take index base <> [invalid] <> drop (index + 1) base
        case fields of
          [memory, tasks, cpu, helperMemory, helperTasks, helperCpu, helperStart, helperStop] ->
            case mkOwnedSubprocessResourceBounds
              memory
              tasks
              cpu
              helperMemory
              helperTasks
              helperCpu
              helperStart
              helperStop of
              Left cause -> cause `shouldBe` OwnedSubprocessInvalidLimits
              Right _ -> expectationFailure "invalid resource field admitted"
          _ -> expectationFailure "invalid fixture field count"

  forM_ [("child", 10001, 1000000), ("helper", 1000000, 10001)] $ \(label, cpu, helperCpu) ->
    it ("refuses an inexact " <> label <> " CPU projection") $
      case mkOwnedSubprocessResourceBounds 67108864 16 cpu 16777216 8 helperCpu 30000 30000 of
        Left cause -> cause `shouldBe` OwnedSubprocessInvalidLimits
        Right _ -> expectationFailure "inexact CPU quota admitted"

  it "reserves helper startup and stop strictly inside confirmation" $ do
    resources <- ownedFixtureResources
    case mkOwnedSubprocessLimits resources 1000000 100000 60000 100000 4 4 of
      Left cause -> cause `shouldBe` OwnedSubprocessInvalidLimits
      Right _ -> expectationFailure "helper consumes the complete confirmation reserve"
    case mkOwnedSubprocessLimits resources 1000000 100000 60001 100000 4 4 of
      Left cause -> expectationFailure (show cause)
      Right _ -> pure ()

  it "refuses monotonic deadline overflow before child creation" $
    withSystemTempDirectory "bounded-owned-overflow" $ \directory -> do
      let pidPath = directory <> "/pid"
      result <- runOwnedFixture maxBound 4 4 (script ("echo $$ > " <> pidPath))
      result `shouldBe` Left OwnedSubprocessInvalidLimits
      doesFileExist pidPath `shouldReturn` False

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

-- Positional shell arguments keep the fixture path out of the program text.
pluginBody :: FilePath -> String
pluginBody path =
  "setsid /bin/sh -c 'echo $$ > \"$1\"; cat /proc/$$/stat > \"$1.stat\"; trap \"\" TERM; exec sleep 30' plugin "
    ++ quote path
    ++ " &"
quote :: String -> String
quote value = "'" ++ concatMap (\c -> if c == '\'' then "'\"'\"'" else [c]) value ++ "'"
