{-# LANGUAGE OverloadedStrings #-}

-- | Native kernel-owned children require the local user manager and cgroup2.
module SubprocessOwned (ownedSubprocessLifecycleSuite) where

import Control.Exception (IOException, finally, try)
import Control.Monad (forM_, void)
import Prodbox.Subprocess
import SubprocessFixtures
import System.Exit (ExitCode (..))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (FileStatus, fileOwner, getSymbolicLinkStatus, isSocket)
import System.Posix.User (getEffectiveUserID)
import System.Process qualified as Process
import System.Timeout (timeout)
import TestSupport

ownedSubprocessLifecycleSuite :: SuiteBuilder ()
ownedSubprocessLifecycleSuite = describe "kernel-owned subprocess lifecycle" $ do
  it "retires 2048 short children across cgroup teardown windows under their original bounds" $ do
    resources <- ownedFixtureResources
    limits <-
      either (fail . show) pure (mkOwnedSubprocessLimits resources 500000 50000 100000 50000 128 128)
    forM_ [1 .. (2048 :: Int)] $ \_ -> do
      result <- captureOwnedSubprocess limits (Subprocess "/bin/true" [] Nothing Nothing)
      result `shouldBe` Right (ProcessOutput ExitSuccess "" "")

  it "reports the exact exit and both streams after confirmed shutdown" $ do
    result <- runOwned 2000000 4 4 (script "printf out; printf err >&2; sleep 0.1; exit 3")
    result `shouldBe` Right (ProcessOutput (ExitFailure 3) "out" "err")

  it "admits exact output ceilings without an extra retained chunk" $ do
    result <- runOwned 2000000 4 4 (script "printf 1234; printf 5678 >&2; sleep 0.1")
    result `shouldBe` Right (ProcessOutput ExitSuccess "1234" "5678")

  forM_
    [("stdout", "", OwnedSubprocessStdoutExceeded), ("stderr", " >&2", OwnedSubprocessStderrExceeded)]
    $ \(label, redirect, expected) ->
      it ("stops on " <> label <> " overflow and confirms the owned child gone") $
        withSystemTempDirectory "bounded-owned-output" $ \directory -> do
          let pidPath = directory <> "/pid"
              body = "echo $$ > " <> pidPath <> "; sleep 0.05; while true; do printf 12345" <> redirect <> "; done"
          (result, elapsed) <- elapsedMillis (runOwned 2000000 4 4 (script body))
          result `shouldBe` Left expected
          elapsed `shouldSatisfy` (< 1500)
          recordedPid pidPath >>= eventuallyGone >>= (`shouldBe` True)

  it "reserves ignored-TERM stop and confirmation inside the original total" $
    withSystemTempDirectory "bounded-owned-timeout" $ \directory -> do
      let pidPath = directory <> "/pid"
          body = "echo $$ > " <> pidPath <> "; trap '' TERM; while true; do sleep 0.1; done"
      (result, elapsed) <- elapsedMillis (runOwned 1000000 32 32 (script body))
      result `shouldBe` Left OwnedSubprocessDeadlineReached
      elapsed `shouldSatisfy` (< 1500)
      recordedPid pidPath >>= eventuallyGone >>= (`shouldBe` True)

  it "propagates cancellation after confirming the owned child stopped" $
    withSystemTempDirectory "bounded-owned-cancel" $ \directory -> do
      let pidPath = directory <> "/pid"
          body = "echo $$ > " <> pidPath <> "; trap '' TERM; while true; do sleep 0.1; done"
      (result, elapsed) <- elapsedMillis (timeout 200000 (runOwned 5000000 32 32 (script body)))
      result `shouldBe` Nothing
      elapsed `shouldSatisfy` (< 1500)
      recordedPid pidPath >>= eventuallyGone >>= (`shouldBe` True)

  it "stops a separately grouped pipe holder after normal parent exit and preserves a foreign child" $
    withSystemTempDirectory "bounded-owned-pipe" $ \directory -> do
      (_, _, _, foreignProcess) <- Process.createProcess (Process.proc "/bin/sleep" ["30"])
      let pidPath = directory <> "/plugin"
          body =
            "setsid /bin/sh -c 'echo $$ > \"$1\"; cat /proc/$$/stat > \"$1.stat\"; trap \"\" TERM; exec sleep 30' plugin "
              <> pidPath
              <> " & sleep 0.2; printf done"
      ( do
          (result, elapsed) <- elapsedMillis (runOwned 2000000 4 4 (script body))
          result `shouldBe` Right (ProcessOutput ExitSuccess "done" "")
          elapsed `shouldSatisfy` (< 1500)
          recordedPid pidPath >>= processStopped >>= (`shouldBe` True)
          Process.getProcessExitCode foreignProcess >>= (`shouldBe` Nothing)
        )
        `finally` do
          cleanupPlugin pidPath
          Process.terminateProcess foreignProcess
          void (Process.waitForProcess foreignProcess)

  it "refuses an unstartable child without returning exception payload" $ do
    result <- runOwned 2000000 4 4 (Subprocess "/prodbox-fixture-absent/child" [] Nothing Nothing)
    result `shouldBe` Left OwnedSubprocessStartFailed
 where
  runOwned total out err child = do
    uid <- getEffectiveUserID
    socket <-
      try (getSymbolicLinkStatus ("/run/user/" <> show uid <> "/bus"))
        :: IO (Either IOException FileStatus)
    unlessNative (either (const False) (\status -> isSocket status && fileOwner status == uid) socket)
    result <- runOwnedFixture total out err child
    case result of
      Left OwnedSubprocessManagerRefused -> refuse result
      Left OwnedSubprocessScopeUnobservable -> refuse result
      Left OwnedSubprocessRuntimeUnsupported -> refuse result
      _ -> pure result
  refuse result = do
    expectationFailure
      ( "native child ownership refused: "
          <> show result
          <> "; use a Linux user session with its systemd user bus, delegated cgroup v2 and one runtime capability"
      )
    pure result
  unlessNative available =
    if available
      then pure ()
      else
        expectationFailure
          "native child ownership requires an owned systemd user socket and delegated cgroup v2"
