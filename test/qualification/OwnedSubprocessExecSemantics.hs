{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- | Paired execution behavior for the actual public kernel-owned runner.
-- Explicit fixture limits are not a production host-admission claim.
module Main (main) where

import Control.Concurrent.Async (concurrently)
import Control.Exception (IOException, bracket, finally, onException, try)
import Control.Monad (forM, unless, void)
import Data.Aeson (encode, object, (.=))
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy.Char8 qualified as Lazy
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Subprocess
import System.Directory
import System.Environment
import System.Exit
import System.FilePath ((</>))
import System.IO (hClose)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createSymbolicLink, getFdStatus, isRegularFile)
import System.Posix.IO
import System.Posix.Types (Fd (..))
import System.Process qualified as Process
import System.Timeout (timeout)
import Text.Read (readMaybe)

data ExecExpectation = MatchProcess | RefuseNul deriving (Eq, Show)

data ExecCase
  = ExecCase ExecExpectation String FilePath [String] (Maybe FilePath) (Maybe [(String, String)])
data Outcome = StartRefused | Finished ExitCode String String deriving (Eq, Show)

main :: IO ()
main = do
  args <- getArgs
  case args of
    "--inspect" : descriptor : _ -> inspect descriptor
    ["--unsupported"] -> unsupportedRuntime
    _ -> comparePaths

inspect :: String -> IO ()
inspect rawDescriptor = do
  command <- Bytes.readFile "/proc/self/cmdline"
  cwd <- getCurrentDirectory
  selected <- lookupEnv "EXEC_EQ_PROBE"
  path <- lookupEnv "PATH"
  descriptor <- maybe (fail "fixture descriptor malformed") (pure . Fd) (readMaybe rawDescriptor)
  visible <- try (isRegularFile <$> getFdStatus descriptor) :: IO (Either IOException Bool)
  input <- Bytes.getContents
  Lazy.putStrLn
    ( encode
        ( object
            [ "cmdline" .= Bytes.unpack command
            , "cwd" .= cwd
            , "selected" .= selected
            , "path" .= path
            , "inherited_fd_visible" .= (visible == Right True)
            , "stdin" .= Bytes.unpack input
            ]
        )
    )

comparePaths :: IO ()
comparePaths = do
  self <- getExecutablePath >>= canonicalizePath
  withSystemTempDirectory "prodbox-owned-exec-semantics" $ \scratch -> do
    let bin = scratch </> "bin"
        cwd = scratch </> "work-λ"
        sentinel = scratch </> "sentinel"
    createDirectory bin
    createDirectory cwd
    Bytes.writeFile sentinel "owned fixture"
    createSymbolicLink self (bin </> "fixture-reporter")
    createSymbolicLink self (cwd </> "report-λ")
    writeFile (cwd </> "plain-script") "printf shell-fallback\n"
    permissions <- getPermissions (cwd </> "plain-script")
    setPermissions (cwd </> "plain-script") permissions {executable = True}
    setEnv "PATH" (bin <> ":/usr/bin:/bin")
    setEnv "EXEC_EQ_PROBE" "ambient"
    bracket (openFd sentinel ReadOnly defaultFileFlags) closeFd $ \fd -> do
      let report = ["--inspect", show fd, "", "a b", "λ", "\"quoted\"", "back\\slash", "\n"]
          explicit = [("PATH", "/provided-env-only"), ("EXEC_EQ_PROBE", "explicit-λ")]
          cases =
            [ ExecCase MatchProcess "absolute-inherited" self report Nothing Nothing
            , ExecCase MatchProcess "absolute-explicit-cwd-env" self report (Just cwd) (Just explicit)
            , ExecCase MatchProcess "search-uses-parent-path" "fixture-reporter" report (Just cwd) (Just explicit)
            , ExecCase MatchProcess "relative-unicode" "./report-λ" report (Just cwd) (Just explicit)
            , ExecCase RefuseNul "nul-argument" self (report <> ["a\0b"]) Nothing Nothing
            , ExecCase MatchProcess "missing-executable" (scratch </> "absent") [] Nothing Nothing
            , ExecCase MatchProcess "missing-cwd" self report (Just (scratch </> "missing-cwd")) Nothing
            , ExecCase
                MatchProcess
                "plain-executable-shell-fallback"
                "./plain-script"
                []
                (Just cwd)
                (Just explicit)
            , ExecCase
                MatchProcess
                "sigpipe-inheritance"
                "/bin/sh"
                ["-c", "kill -PIPE $$; printf survived"]
                Nothing
                Nothing
            , ExecCase
                MatchProcess
                "sigint-inheritance"
                "/bin/sh"
                ["-c", "kill -INT $$; printf survived"]
                Nothing
                Nothing
            , ExecCase
                MatchProcess
                "sigquit-inheritance"
                "/bin/sh"
                ["-c", "kill -QUIT $$; printf survived"]
                Nothing
                Nothing
            ]
          schedules =
            map (False,False,) cases
              <> [ (True, False, ExecCase MatchProcess "close-on-exec-descriptor" self report Nothing Nothing)
                 , (False, True, ExecCase MatchProcess "closed-stdin" self report Nothing Nothing)
                 ]
      rows <- forM schedules $ \(cloexec, closedInput, entry@(ExecCase expectation label _ _ _ _)) -> do
        setFdOption fd CloseOnExec cloexec
        let inputState operation = if closedInput then withoutStdin operation else operation
        process <- bounded (inputState (viaProcess entry))
        owned <- bounded (inputState (viaOwned entry))
        let matched = process == owned
            passed = case expectation of
              MatchProcess -> matched
              RefuseNul -> owned == StartRefused
        pure
          ( passed
          , object
              [ "case" .= label
              , "expectation" .= show expectation
              , "passed" .= passed
              , "matched" .= matched
              , "process" .= show process
              , "owned" .= show owned
              ]
          )
      Lazy.putStrLn
        ( encode
            ( object
                [ "passed" .= all fst rows
                , "count" .= length rows
                , "paired_count" .= length [() | (_, _, ExecCase MatchProcess _ _ _ _ _) <- schedules]
                , "invalid_input_count" .= length [() | (_, _, ExecCase RefuseNul _ _ _ _ _) <- schedules]
                , "cases" .= map snd rows
                , "actual_public_api" .= True
                ]
            )
        )
      unless (all fst rows) exitFailure

bounded :: IO value -> IO value
bounded operation = timeout 2500000 operation >>= maybe (fail "fixture exceeded original 2.5 seconds") pure

viaProcess :: ExecCase -> IO Outcome
viaProcess (ExecCase _ _ path args cwd environment) = do
  attempted <- try $ bracket (openFd "/dev/null" ReadOnly defaultFileFlags >>= fdToHandle) hClose $ \input -> do
    (_, out, err, child) <-
      Process.createProcess
        (Process.proc path args)
          { Process.cwd = cwd
          , Process.env = environment
          , Process.std_in = Process.UseHandle input
          , Process.std_out = Process.CreatePipe
          , Process.std_err = Process.CreatePipe
          , Process.new_session = True
          }
    let close = mapM_ (maybe (pure ()) hClose) [out, err]
        stop = Process.terminateProcess child >> void (Process.waitForProcess child)
    ( do
        output <- maybe (fail "missing stdout") pure out
        errors <- maybe (fail "missing stderr") pure err
        (stdout, stderr) <- concurrently (Bytes.hGetContents output) (Bytes.hGetContents errors)
        code <- Process.waitForProcess child
        pure (Finished code (Char8.unpack stdout) (Char8.unpack stderr))
      )
      `onException` stop
      `finally` close
  pure (either (const StartRefused) id (attempted :: Either IOException Outcome))

viaOwned :: ExecCase -> IO Outcome
viaOwned (ExecCase _ _ path args cwd environment) = do
  bounds <-
    either
      (fail . show)
      pure
      (mkOwnedSubprocessResourceBounds 67108864 16 1000000 16777216 8 1000000 30000 30000)
  limits <-
    either (fail . show) pure (mkOwnedSubprocessLimits bounds 2000000 100000 300000 100000 4096 4096)
  started <- getMonotonicTimeNSec
  result <- captureOwnedSubprocess limits (Subprocess path args environment cwd)
  finished <- getMonotonicTimeNSec
  unless (finished - started < 2000000000) (fail "owner exceeded the original total bound")
  case result of
    Left OwnedSubprocessStartFailed -> pure StartRefused
    Left cause -> fail ("actual owner refused: " <> show cause)
    Right output -> pure (Finished (processExitCode output) (processStdout output) (processStderr output))

withoutStdin :: IO value -> IO value
withoutStdin operation = bracket (dup stdInput) closeFd $ \saved -> do
  closeFd stdInput
  operation `finally` void (dupTo saved stdInput)

unsupportedRuntime :: IO ()
unsupportedRuntime = withSystemTempDirectory "prodbox-owned-runtime" $ \scratch -> do
  let marker = scratch </> "executed"
  bounds <-
    either
      (fail . show)
      pure
      (mkOwnedSubprocessResourceBounds 67108864 16 1000000 16777216 8 1000000 30000 30000)
  limits <-
    either (fail . show) pure (mkOwnedSubprocessLimits bounds 500000 50000 100000 50000 128 128)
  started <- getMonotonicTimeNSec
  result <-
    captureOwnedSubprocess
      limits
      ( Subprocess
          "/bin/sh"
          ["-c", "printf executed > \"$1\"", "unsupported-fixture", marker]
          Nothing
          Nothing
      )
  finished <- getMonotonicTimeNSec
  exists <- doesFileExist marker
  let passed = result == Left OwnedSubprocessRuntimeUnsupported && not exists && finished - started < 500000000
  Lazy.putStrLn
    ( encode
        ( object
            [ "passed" .= passed
            , "runtime_refused_before_effect" .= not exists
            , "elapsed_micros" .= ((finished - started) `div` 1000)
            ]
        )
    )
  unless passed exitFailure
