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
    (</>),
 )

data ConfigPaths = ConfigPaths
    { configDhallPath :: FilePath
    , configSchemaPath :: FilePath
    }
    deriving (Eq, Show)

findRepoRoot :: IO (Either String FilePath)
findRepoRoot = do
    currentDir <- getCurrentDirectory
    repoMarkerPresent <- hasRepoMarkers currentDir
    pure $
        if repoMarkerPresent
            then Right currentDir
            else Left "Current working directory is not the repository root."

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
