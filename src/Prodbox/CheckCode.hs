module Prodbox.CheckCode
    ( runCheckCode,
    )
where

import Control.Monad (unless)
import System.Directory
    ( createDirectoryIfMissing,
      createFileLink,
      doesFileExist,
    )
import System.Environment (getEnvironment)
import System.Exit
    ( ExitCode (..),
    )
import System.FilePath ((</>))
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
    environment <- addBuildSupport repoRoot baseEnvironment
    putStrLn "Running prodbox check-code (Haskell entrypoint: cabal build + cabal test compilation)"
    buildExit <- runStreaming repoRoot environment "cabal" ["build", "--builddir=.build", "all"]
    pure buildExit

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

addBuildSupport :: FilePath -> [(String, String)] -> IO [(String, String)]
addBuildSupport repoRoot environment = do
    let supportDir = repoRoot </> ".build/support"
        supportLib = supportDir </> "libtinfo.so"
    createDirectoryIfMissing True supportDir
    supportExists <- doesFileExist supportLib
    unless supportExists $ do
        sourceLib <- firstExistingSystemLib
        case sourceLib of
            Nothing -> pure ()
            Just sourcePath -> createFileLink sourcePath supportLib
    pure (upsertEnv "LIBRARY_PATH" supportDir environment)

firstExistingSystemLib :: IO (Maybe FilePath)
firstExistingSystemLib =
    firstExistingFile
        [ "/usr/lib/x86_64-linux-gnu/libtinfo.so.6",
          "/lib/x86_64-linux-gnu/libtinfo.so.6"
        ]

firstExistingFile :: [FilePath] -> IO (Maybe FilePath)
firstExistingFile paths = go paths
  where
    go [] = pure Nothing
    go (path : remaining) = do
        exists <- doesFileExist path
        if exists then pure (Just path) else go remaining

upsertEnv :: String -> String -> [(String, String)] -> [(String, String)]
upsertEnv key value environment = (key, value) : filter ((/= key) . fst) environment
