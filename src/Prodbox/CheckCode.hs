module Prodbox.CheckCode
  ( DoctrineViolation (..)
  , doctrineViolationsInPaths
  , listRepoOwnedPaths
  , runCheckCode
  )
where

import Control.Monad (forM)
import Data.List (sort)
import Prodbox.BuildSupport
  ( addBuildSupportEnvironment
  , syncBuiltOperatorBinary
  )
import System.Directory
  ( doesDirectoryExist
  , findExecutable
  , listDirectory
  )
import System.Environment (getEnvironment)
import System.Exit
  ( ExitCode (..)
  )
import System.FilePath
  ( normalise
  , splitDirectories
  , takeDirectory
  , takeFileName
  , (</>)
  )
import System.IO (hPutStrLn, stderr)
import System.IO.Error (tryIOError)
import System.Process
  ( CreateProcess
      ( cwd
      , delegate_ctlc
      , env
      , std_err
      , std_in
      , std_out
      )
  , StdStream (Inherit)
  , createProcess
  , proc
  , waitForProcess
  )

data DoctrineViolation
  = ForbiddenWorkflowDirectory FilePath
  | ForbiddenHookSurface FilePath
  deriving (Eq, Show)

doctrineViolationsInPaths :: [FilePath] -> [DoctrineViolation]
doctrineViolationsInPaths =
  concatMap (pathViolations . normalise)
 where
  pathViolations relativePath
    | takeFileName relativePath == ".github" =
        [ForbiddenWorkflowDirectory relativePath]
    | takeFileName relativePath `elem` forbiddenHookDirectories =
        [ForbiddenHookSurface relativePath]
    | takeFileName relativePath `elem` forbiddenHookConfigs =
        [ForbiddenHookSurface relativePath]
    | takeFileName relativePath `elem` forbiddenHookScripts
        && (isRepoRootPath relativePath || "hooks" `elem` splitDirectories relativePath) =
        [ForbiddenHookSurface relativePath]
    | otherwise = []

  forbiddenHookDirectories = [".githooks", ".husky"]
  forbiddenHookConfigs = [".pre-commit-config.yaml", ".pre-commit-hooks.yaml", "lefthook.yml"]
  forbiddenHookScripts = ["pre-commit", "pre-push", "post-commit", "pre-merge-commit"]
  isRepoRootPath relativePath = takeDirectory relativePath `elem` [".", ""]

runCheckCode :: FilePath -> IO ExitCode
runCheckCode repoRoot = do
  baseEnvironment <- getEnvironment
  environment <- addBuildSupportEnvironment repoRoot baseEnvironment
  putStrLn "Running prodbox check-code (policy + formatter + linter + warning-clean build)"
  doctrineExit <- runDoctrineAlignmentCheck repoRoot
  case doctrineExit of
    ExitFailure _ -> pure doctrineExit
    ExitSuccess -> do
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
                      buildExit <-
                        runStreaming
                          repoRoot
                          environment
                          "cabal"
                          ["build", "--builddir=.build", "all", "--ghc-options=-Werror"]
                      case buildExit of
                        ExitFailure _ -> pure buildExit
                        ExitSuccess -> do
                          syncResult <- syncBuiltOperatorBinary repoRoot environment
                          case syncResult of
                            Left err -> failWith err
                            Right _ -> pure ExitSuccess

runDoctrineAlignmentCheck :: FilePath -> IO ExitCode
runDoctrineAlignmentCheck repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let violations = doctrineViolationsInPaths repoPaths
  case violations of
    [] -> pure ExitSuccess
    _ ->
      failWith
        ( unlines
            ( "Doctrine alignment failed. Remove unsupported workflow or git-hook surfaces:"
                : map (("- " ++) . renderDoctrineViolation) violations
                ++ ["Rerun `./.build/prodbox check-code` after removing the listed paths."]
            )
        )

listRepoOwnedPaths :: FilePath -> IO [FilePath]
listRepoOwnedPaths repoRoot = scanDirectory ""
 where
  scanDirectory :: FilePath -> IO [FilePath]
  scanDirectory relativeRoot = do
    let directoryPath =
          if null relativeRoot
            then repoRoot
            else repoRoot </> relativeRoot
    entriesResult <- tryIOError (sort <$> listDirectory directoryPath)
    case entriesResult of
      Left _ -> pure []
      Right entries ->
        fmap concat $
          forM entries $ \entry -> do
            let relativePath =
                  if null relativeRoot
                    then entry
                    else relativeRoot </> entry
                absolutePath = repoRoot </> relativePath
            isDirectory <- doesDirectoryExist absolutePath
            if not isDirectory
              then pure [relativePath]
              else
                if entry `elem` excludedDirectories
                  then pure []
                  else
                    if entry `elem` forbiddenDirectories
                      then pure [relativePath]
                      else do
                        descendants <- scanDirectory relativePath
                        pure (relativePath : descendants)

  excludedDirectories = [".git", ".build", "dist-newstyle", ".prodbox-state", ".data"]
  forbiddenDirectories = [".github", ".githooks", ".husky"]

renderDoctrineViolation :: DoctrineViolation -> String
renderDoctrineViolation violation =
  case violation of
    ForbiddenWorkflowDirectory relativePath ->
      relativePath ++ " is forbidden because repository-owned CI workflow automation is not supported."
    ForbiddenHookSurface relativePath ->
      relativePath
        ++ " is forbidden because repository-owned git-hook and pre-commit style tooling is not supported."

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
