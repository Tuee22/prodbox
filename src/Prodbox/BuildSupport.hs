module Prodbox.BuildSupport
  ( addBuildSupportEnvironment
  , canonicalOperatorBinaryPath
  , syncBuiltOperatorBinary
  )
where

import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( CommandSpec (..)
  , ProcessOutput (..)
  , captureCommand
  )
import System.Directory
  ( Permissions (..)
  , copyFile
  , createDirectoryIfMissing
  , createFileLink
  , doesFileExist
  , getPermissions
  , setPermissions
  )
import System.Exit
  ( ExitCode (..)
  )
import System.FilePath ((</>))

addBuildSupportEnvironment :: FilePath -> [(String, String)] -> IO [(String, String)]
addBuildSupportEnvironment repoRoot environment = do
  supportDir <- ensureBuildSupportDirectory repoRoot
  let existingLibraryPath = maybe "" id (lookup "LIBRARY_PATH" environment)
      updatedLibraryPath =
        if existingLibraryPath == ""
          then supportDir
          else supportDir ++ ":" ++ existingLibraryPath
  pure (("LIBRARY_PATH", updatedLibraryPath) : filter ((/= "LIBRARY_PATH") . fst) environment)

canonicalOperatorBinaryPath :: FilePath -> FilePath
canonicalOperatorBinaryPath repoRoot = repoRoot </> ".build" </> "prodbox"

syncBuiltOperatorBinary :: FilePath -> [(String, String)] -> IO (Either String FilePath)
syncBuiltOperatorBinary repoRoot environment = do
  createDirectoryIfMissing True (repoRoot </> ".build")
  captureResult <-
    captureCommand
      CommandSpec
        { commandPath = "cabal"
        , commandArguments = ["list-bin", "--builddir=.build", "exe:prodbox"]
        , commandEnvironment = Just environment
        , commandWorkingDirectory = Just repoRoot
        }
  case captureResult of
    Failure err -> pure (Left err)
    Success output ->
      case processExitCode output of
        ExitFailure _ -> pure (Left (trim (processStderr output)))
        ExitSuccess -> do
          let builtBinaryPath = trim (processStdout output)
              targetBinaryPath = canonicalOperatorBinaryPath repoRoot
          copyFile builtBinaryPath targetBinaryPath
          sourcePermissions <- getPermissions builtBinaryPath
          setPermissions targetBinaryPath sourcePermissions {executable = True}
          pure (Right targetBinaryPath)

ensureBuildSupportDirectory :: FilePath -> IO FilePath
ensureBuildSupportDirectory repoRoot = do
  let supportDir = repoRoot </> ".build" </> "support"
      supportLink = supportDir </> "libtinfo.so"
  createDirectoryIfMissing True supportDir
  linkExists <- doesFileExist supportLink
  if linkExists
    then pure supportDir
    else do
      sourceLib <- firstExistingSystemLib
      case sourceLib of
        Nothing -> pure supportDir
        Just sourcePath -> do
          createFileLink sourcePath supportLink
          pure supportDir

firstExistingSystemLib :: IO (Maybe FilePath)
firstExistingSystemLib =
  firstExistingFile
    [ "/usr/lib/x86_64-linux-gnu/libtinfo.so.6"
    , "/lib/x86_64-linux-gnu/libtinfo.so.6"
    ]

firstExistingFile :: [FilePath] -> IO (Maybe FilePath)
firstExistingFile paths = go paths
 where
  go [] = pure Nothing
  go (path : remaining) = do
    exists <- doesFileExist path
    if exists then pure (Just path) else go remaining

trim :: String -> String
trim = reverse . dropWhile (`elem` ['\n', '\r', ' ']) . reverse
