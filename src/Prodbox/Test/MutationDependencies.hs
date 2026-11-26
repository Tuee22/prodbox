{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Prepare the reconciled public package inputs used by the offline mutant
-- build. Only the new private copy is eligible to be mounted in the child.
module Prodbox.Test.MutationDependencies
  ( PreparedMutationDependencies (..)
  , prepareMutationDependencies
  ) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (unless)
import Data.Bits ((.&.))
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Bytes
import Data.List (sortOn)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  )
import Prodbox.Test.MutationDependencyFiles
  ( copyDependencyEntry
  , dependencyDirectoryFlags
  , newDependencyCopyBudget
  , readDependencyPlan
  )
import Prodbox.Test.MutationDependencyPlan
  ( MutationDependency (..)
  , MutationDependencyPlan (..)
  , selectMutationDependencyPlan
  )
import Prodbox.Test.Qualification.Evidence (PublicEvidenceDigest, hashPublicEvidence)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (isAbsolute, normalise, (</>))
import System.IO (hClose)
import System.Posix.Directory qualified as Directory
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.Types (Fd (..))
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

data PreparedMutationDependencies = PreparedMutationDependencies
  { dependencyRootPath :: !FilePath
  , dependencyHostStorePath :: !FilePath
  , dependencyContainerStorePath :: !FilePath
  , dependencyConfigPath :: !FilePath
  , dependencyPlanFingerprint :: !PublicEvidenceDigest
  , dependencyContentFingerprint :: !PublicEvidenceDigest
  }
  deriving (Eq, Show)

prepareMutationDependencies
  :: FilePath -> FilePath -> Fd -> IO Bool -> FilePath -> IO (Either String PreparedMutationDependencies)
prepareMutationDependencies project campaign root stable home = do
  observed <- timeout 300000000 $ try $ do
    unless (all validPath [project, campaign, home]) (refuse "invalid dependency paths")
    requireStable
    owner <- getEffectiveUserID
    planBytes <-
      withDirectory (project </> ".build" </> "cache") (readDependencyPlan owner)
    plan <- either refuse pure (selectMutationDependencyPlan planBytes)
    budget <- newDependencyCopyBudget
    let abi = dependencyCompilerDirectory plan
        copiedRoot = campaign </> "dependencies"
        copiedStore = copiedRoot </> "store"
        containerStore = home </> ".cabal" </> "store"
        config = copiedRoot </> "cabal.config"
        copiedDb = copiedStore </> abi </> "package.db"
    verifyCampaignName
    Directory.createDirectory (descriptorPath root </> "dependencies") 0o700
    manifest <- withChild root "dependencies" $ \target ->
      withDirectory home $ \ownerHome ->
        withChild ownerHome ".cabal" $ \cabal -> do
          store <- newChild target "store" $ \storeTarget ->
            newChild storeTarget abi $ \abiTarget ->
              withChild cabal "store" $ \sourceStore ->
                withChild sourceStore abi $ \abiSource ->
                  withChild abiSource "package.db" $ \packageDb ->
                    newChild abiTarget "package.db" $ \dbTarget -> do
                      packages <-
                        concat
                          <$> traverse
                            (\unit -> copyDependencyEntry owner budget abiSource abiTarget (dependencyUnitId unit))
                            (dependencyUnits plan)
                      registrations <-
                        concat
                          <$> traverse
                            (\unit -> copyDependencyEntry owner budget packageDb dbTarget (dependencyUnitId unit ++ ".conf"))
                            (filter dependencyHasRegistration (dependencyUnits plan))
                      pure (prefix ["store", abi] packages ++ prefix ["store", abi, "package.db"] registrations)
          index <- newChild target "packages" $ \packageTarget ->
            newChild packageTarget "hackage.haskell.org" $ \indexTarget ->
              withChild cabal "packages" $ \packages ->
                withChild packages "hackage.haskell.org" $ \indexSource ->
                  concat <$> traverse (copyDependencyEntry owner budget indexSource indexTarget) publicIndexFiles
          writeConfig target copiedRoot containerStore
          fileSynchronise target
          pure (store ++ prefix ["packages", "hackage.haskell.org"] index)
    recache <- recachePackageDatabase home copiedDb
    unless recache (refuse "cannot index the private package database")
    requireStable
    verifyCampaignName
    secondPlan <- withDirectory (project </> ".build" </> "cache") (readDependencyPlan owner)
    unless (secondPlan == planBytes) (refuse "dependency plan changed while preparing the store")
    fileSynchronise root
    let planFingerprint = hashPublicEvidence (Text.decodeUtf8 (hexSha256 planBytes))
        contentFingerprint =
          hashPublicEvidence $
            Text.pack $
              concatMap
                (\(path, digest) -> show (length path) ++ ":" ++ path ++ show digest)
                (sortOn fst manifest)
    pure
      ( PreparedMutationDependencies
          copiedRoot
          copiedStore
          containerStore
          config
          planFingerprint
          contentFingerprint
      )
  pure $ case observed of
    Just (Right result) -> Right result
    Just (Left (_ :: IOException)) -> Left "the selected Cabal dependency inputs could not be prepared"
    Nothing -> Left "the private dependency preparation exceeded its deadline"
 where
  requireStable = do
    unchanged <- stable
    unless unchanged (refuse "campaign identity changed")
  verifyCampaignName =
    withDirectory campaign $ \named -> do
      expected <- Files.getFdStatus root
      current <- Files.getFdStatus named
      unless (sameDirectory expected current) (refuse "campaign name changed")
  prefix components = map (\(path, digest) -> (foldr (</>) path components, digest))
  validPath value =
    isAbsolute value
      && normalise value == value
      && all (\c -> c >= ' ' && c /= '\DEL' && c /= ':') value

publicIndexFiles :: [FilePath]
publicIndexFiles =
  [ "01-index.tar"
  , "01-index.cache"
  , "01-index.tar.idx"
  , "01-index.timestamp"
  , "root.json"
  , "mirrors.json"
  , "snapshot.json"
  , "timestamp.json"
  ]

writeConfig :: Fd -> FilePath -> FilePath -> IO ()
writeConfig root prepared store = do
  let readFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True}
      flags = readFlags {Posix.exclusive = True, Posix.creat = Just 0o600}
      content =
        Bytes.pack $
          unlines
            [ "repository hackage.haskell.org"
            , "  url: http://hackage.haskell.org/"
            , "  secure: True"
            , "remote-repo-cache: " ++ (prepared </> "packages")
            , "store-dir: " ++ store
            ]
  bracket (Posix.openFdAt (Just root) "cabal.config" Posix.WriteOnly flags) Posix.closeFd $ \output -> do
    bracket (Posix.dup output >>= Posix.fdToHandle) hClose (`ByteString.hPut` content)
    fileSynchronise output

recachePackageDatabase :: FilePath -> FilePath -> IO Bool
recachePackageDatabase home database = do
  result <-
    captureSubprocessBounded (BoundedSubprocessLimits 1 65536 8192 20000000) $
      Subprocess
        (home </> ".ghcup" </> "bin" </> "ghc-pkg-9.12.4")
        ["--no-user-package-db", "--package-db", database, "recache"]
        (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
        Nothing
  pure $ case result of
    Right output -> processExitCode output == ExitSuccess
    Left _ -> False

withDirectory :: FilePath -> (Fd -> IO a) -> IO a
withDirectory path =
  bracket (Posix.openFd path Posix.ReadOnly dependencyDirectoryFlags) Posix.closeFd

withChild :: Fd -> FilePath -> (Fd -> IO a) -> IO a
withChild parent name =
  bracket (Posix.openFdAt (Just parent) name Posix.ReadOnly dependencyDirectoryFlags) Posix.closeFd

newChild :: Fd -> FilePath -> (Fd -> IO a) -> IO a
newChild parent name action = do
  Directory.createDirectory (descriptorPath parent </> name) 0o700
  value <- withChild parent name $ \directory -> do
    result <- action directory
    fileSynchronise directory
    pure result
  fileSynchronise parent
  pure value

descriptorPath :: Fd -> FilePath
descriptorPath (Fd raw) = "/proc/self/fd/" ++ show raw

sameDirectory :: Files.FileStatus -> Files.FileStatus -> Bool
sameDirectory original observed =
  Files.isDirectory original
    && Files.isDirectory observed
    && Files.deviceID original == Files.deviceID observed
    && Files.fileID original == Files.fileID observed
    && Files.fileOwner original == Files.fileOwner observed
    && all (\status -> Files.fileMode status .&. 0o077 == 0) [original, observed]

refuse :: String -> IO a
refuse = ioError . userError
