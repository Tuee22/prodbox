module Prodbox.Repo
  ( ConfigPaths (..)
  , canonicalConfigPaths
  , findRepoRoot
  )
where

import System.Directory
  ( doesFileExist
  , getCurrentDirectory
  )
import System.FilePath
  ( (</>)
  )

data ConfigPaths = ConfigPaths
  { configDhallPath :: FilePath
  , configSchemaPath :: FilePath
  , configTier0Path :: FilePath
  -- ^ Sprint 1.39: the Tier-0 binary-owned, project-local non-secret config
  -- (@prodbox.dhall@ at the repository root). Carries
  -- @{ parameters, context, witness }@ and never a secret value. Sprint 7.18:
  -- this is also the SOLE source of the sealed-Vault bootstrap floor — the
  -- floor is projected straight off @prodbox.dhall@'s @context@
  -- ('Prodbox.Config.FloorDhall.loadUnencryptedBasics'); there is no longer a
  -- separate derived @prodbox-basics.json@ or legacy
  -- @.data\/prodbox\/unencrypted-basics.json@ artifact.
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
    , configTier0Path = repoRoot </> "prodbox.dhall"
    }
