module Prodbox.Repo (
    ConfigPaths (..),
    canonicalConfigPaths,
    findRepoRoot,
)
where

import System.Directory (
    doesFileExist,
    getCurrentDirectory,
 )
import System.FilePath (
    takeDirectory,
    (</>),
 )

data ConfigPaths = ConfigPaths
    { configDhallPath :: FilePath
    , configSchemaPath :: FilePath
    }
    deriving (Eq, Show)

findRepoRoot :: IO (Either String FilePath)
findRepoRoot = do
    startDir <- getCurrentDirectory
    search startDir
  where
    search currentDir = do
        repoMarkerPresent <- hasRepoMarkers currentDir
        if repoMarkerPresent
            then pure (Right currentDir)
            else
                let parentDir = takeDirectory currentDir
                 in if parentDir == currentDir
                        then pure (Left "Could not locate the repository root from the current working directory.")
                        else search parentDir

hasRepoMarkers :: FilePath -> IO Bool
hasRepoMarkers candidate = do
    cabalPresent <- doesFileExist (candidate </> "prodbox.cabal")
    planPresent <- doesFileExist (candidate </> "DEVELOPMENT_PLAN/README.md")
    pure (cabalPresent && planPresent)

canonicalConfigPaths :: FilePath -> ConfigPaths
canonicalConfigPaths repoRoot =
    ConfigPaths
        { configDhallPath = repoRoot </> "prodbox-config.dhall"
        , configSchemaPath = repoRoot </> "prodbox-config-types.dhall"
        }
