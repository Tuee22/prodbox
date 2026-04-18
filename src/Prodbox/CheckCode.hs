module Prodbox.CheckCode
    ( runCheckCode,
    )
where

import Prodbox.BuildSupport
    ( addBuildSupportEnvironment,
      syncBuiltOperatorBinary,
    )
import System.Environment (getEnvironment)
import System.Exit
    ( ExitCode (..),
    )
import System.IO (hPutStrLn, stderr)
import System.Process
    ( CreateProcess
        ( cwd,
          delegate_ctlc,
          env,
          std_err,
          std_in,
          std_out
        ),
      StdStream (Inherit),
      createProcess,
      proc,
      waitForProcess,
    )

runCheckCode :: FilePath -> IO ExitCode
runCheckCode repoRoot = do
    baseEnvironment <- getEnvironment
    environment <- addBuildSupportEnvironment repoRoot baseEnvironment
    putStrLn "Running prodbox check-code (Haskell entrypoint: cabal build + cabal test compilation)"
    buildExit <- runStreaming repoRoot environment "cabal" ["build", "--builddir=.build", "all"]
    case buildExit of
        ExitFailure _ -> pure buildExit
        ExitSuccess -> do
            syncResult <- syncBuiltOperatorBinary repoRoot environment
            case syncResult of
                Left err -> failWith err
                Right _ -> pure ExitSuccess

runStreaming :: FilePath -> [(String, String)] -> FilePath -> [String] -> IO ExitCode
runStreaming repoRoot environment commandPath arguments = do
    (_, _, _, handle) <-
        createProcess
            (proc commandPath arguments)
                { cwd = Just repoRoot,
                  env = Just environment,
                  std_in = Inherit,
                  std_out = Inherit,
                  std_err = Inherit,
                  delegate_ctlc = True
                }
    waitForProcess handle

failWith :: String -> IO ExitCode
failWith message = do
    hPutStrLn stderr message
    pure (ExitFailure 1)
