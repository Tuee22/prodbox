module Prodbox.Repo
  ( ConfigPaths (..)
  , SiblingConfigSurface (..)
  , canonicalConfigPaths
  , findRepoRoot
  , resolveSiblingConfigPath
  , resolveTestTopologyConfigPath
  , resolveTier0ConfigPath
  , testTopologyConfigFileName
  , tier0ConfigFileName
  )
where

import System.Directory
  ( doesFileExist
  , getCurrentDirectory
  )
import System.Environment (getExecutablePath)
import System.FilePath
  ( takeDirectory
  , (</>)
  )

-- | Repo-root-relative Dhall paths the binary still resolves against the
-- repository root: the GENERATED schema and the RETIRED legacy seed. The
-- Tier-0 @prodbox.dhall@ is NOT here — it is binary-sibling
-- ('resolveTier0ConfigPath'), not repo-root (Sprint 1.48; config_doctrine.md
-- §2/§3).
data ConfigPaths = ConfigPaths
  { configDhallPath :: FilePath
  , configSchemaPath :: FilePath
  }
  deriving (Eq, Show)

data SiblingConfigSurface
  = ProductionTier0
  | TestTopology
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

-- | The Tier-0 config filename, identical in every context (host, container,
-- test harness) per config_doctrine.md §2/§3. The binary owns this file and
-- resolves it beside its own executable.
tier0ConfigFileName :: FilePath
tier0ConfigFileName = "prodbox.dhall"

testTopologyConfigFileName :: FilePath
testTopologyConfigFileName = "prodbox.test.dhall"

-- | Resolve the Tier-0 @prodbox.dhall@ at the BINARY-SIBLING path — the file
-- beside the running executable (e.g. @.build\/prodbox.dhall@), the same
-- filename in every context, never the repository root and never a @--config@
-- flag (config_doctrine.md §2 "Single Dhall surface per binary instance", §3
-- "Canonical paths"). @repoRoot@ is the fallback anchor, used only when the
-- executable directory cannot be determined. Sprint 1.48.
resolveTier0ConfigPath :: FilePath -> IO FilePath
resolveTier0ConfigPath = resolveSiblingConfigPath ProductionTier0

resolveTestTopologyConfigPath :: FilePath -> IO FilePath
resolveTestTopologyConfigPath = resolveSiblingConfigPath TestTopology

resolveSiblingConfigPath :: SiblingConfigSurface -> FilePath -> IO FilePath
resolveSiblingConfigPath surface repoRoot = do
  exeDir <- takeDirectory <$> getExecutablePath
  pure ((if null exeDir then repoRoot else exeDir) </> siblingConfigFileName surface)

siblingConfigFileName :: SiblingConfigSurface -> FilePath
siblingConfigFileName surface =
  case surface of
    ProductionTier0 -> tier0ConfigFileName
    TestTopology -> testTopologyConfigFileName
