module Prodbox.CheckCode (
    runCheckCode,
)
where

import Prodbox.BuildSupport (
    addBuildSupportEnvironment,
    syncBuiltOperatorBinary,
 )
import System.Directory (findExecutable)
import System.Environment (getEnvironment)
import System.Exit (
    ExitCode (..),
 )
import System.IO (hPutStrLn, stderr)
import System.Process (
    CreateProcess (
        cwd,
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
    putStrLn "Running prodbox check-code (formatter + linter + warning-clean build)"
    fourmoluResult <- requireTool "fourmolu"
    case fourmoluResult of
        Left err -> failWith err
        Right () -> do
            hlintResult <- requireTool "hlint"
            case hlintResult of
                Left err -> failWith err
                Right () -> do
                    formatExit <- runStreaming repoRoot environment "fourmolu" ["--mode", "check", "app", "src", "test"]
                    case formatExit of
                        ExitFailure _ -> pure formatExit
                        ExitSuccess -> do
                            lintExit <- runStreaming repoRoot environment "hlint" ["app", "src", "test", "--hint=.hlint.yaml"]
                            case lintExit of
                                ExitFailure _ -> pure lintExit
                                ExitSuccess -> do
                                    buildExit <- runStreaming repoRoot environment "cabal" ["build", "--builddir=.build", "all", "--ghc-options=-Werror"]
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
                { cwd = Just repoRoot
                , env = Just environment
                , std_in = Inherit
                , std_out = Inherit
                , std_err = Inherit
                , delegate_ctlc = True
                }
    waitForProcess handle

requireTool :: String -> IO (Either String ())
requireTool toolName = do
    executable <- findExecutable toolName
    pure $
        case executable of
            Just _ -> Right ()
            Nothing ->
                Left
                    ( "Missing required tool `"
                        ++ toolName
                        ++ "`. Install the Haskell quality tools and rerun `./.build/prodbox check-code`."
                    )

failWith :: String -> IO ExitCode
failWith message = do
    hPutStrLn stderr message
    pure (ExitFailure 1)
