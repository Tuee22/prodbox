{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Scoped, unpublished staging for a test node archive. Publication is
-- delegated to the public artifact importer supplied by the caller.
module Prodbox.Test.NodeRegistryPreparation
  ( PreparationResult (..)
  , PreparationFailure (..)
  , RegistrySource (..)
  , prepareRegistryNodeArchive
  , prepareRegistryNodeArchiveWith
  , preparePinnedKindArtifact
  , prepareFreshNodeArchive
  , prepareFreshNodeArchiveWith
  , prepareAdverseImportSources
  , pinnedNodeImage
  ) where

import Control.Exception (IOException, bracket, mask, onException, try)
import Control.Monad (foldM, unless, void)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Text qualified as Text
import Prodbox.Config.BootstrapProjection
  ( ArtifactDeclaration (..)
  , BootstrapProjection
  , bootstrapKindTool
  , bootstrapNodeArtifact
  , bootstrapRootGeneration
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , DeploymentScope
  , ScopeGenerationObservation (ScopeGenerationMatches)
  , ScopeRootObservation (ScopeRootAbsent)
  , observeScopeGeneration
  , observeScopeRoot
  , scopeEnvironment
  , scopeIdentifier
  )
import Prodbox.Control.NodeRegistryArchive
  ( NodeRegistryArchiveResult (..)
  , writeNodeRegistryArchive
  )
import Prodbox.Control.NodeRegistryBlob
  ( NodeBlobVerification (NodeBlobVerified)
  , verifyNodeRegistryBlob
  )
import Prodbox.Control.NodeRegistryClient
  ( NodeRegistryDocument (..)
  , NodeRegistryReadError
  , fetchNodeRegistryBlob
  , fetchNodeRegistryManifest
  , fetchPinnedKindTool
  )
import Prodbox.Control.NodeRegistryManifest
  ( NodeRegistryBlob (..)
  , NodeRegistryPlan (..)
  , parseNodeRegistryManifest
  , validNodeRegistryDigest
  )
import System.Directory (listDirectory, removeDirectory, removeFile)
import System.FilePath ((</>))
import System.IO (Handle, IOMode (ReadMode, WriteMode), hClose, hFileSize, hFlush, hSetBinaryMode)
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (createTempDirectory)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , fileMode
  , fileOwner
  , getFdStatus
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , linkCount
  )
import System.Posix.IO qualified as Posix
import System.Posix.Types (Fd (..))
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

data PreparationFailure
  = PreparationInvalidScope
  | PreparationInvalidImage
  | PreparationInvalidKindTool
  | PreparationGenerationUnavailable
  | PreparationFreshScopeUnavailable
  | PreparationSourceFailure !NodeRegistryReadError
  | PreparationArchiveFailure !NodeRegistryArchiveResult
  | PreparationArchiveDoesNotMatchDeclaration
  | PreparationManifestMismatch
  | PreparationCapacityExceeded
  | PreparationKindToolMismatch
  | PreparationInvalidAdverseFixture
  | PreparationIoFailure
  | PreparationTimedOut
  deriving (Eq, Show)

data PreparationResult a = PreparationResult
  { preparationPrimary :: !(Either PreparationFailure a)
  , preparationCleanupConfirmed :: !Bool
  , preparationRetainedDirectory :: !(Maybe FilePath)
  }
  deriving (Eq, Show)

data RegistrySource = RegistrySource
  { readRegistryManifest :: Text.Text -> IO (Either NodeRegistryReadError NodeRegistryDocument)
  , readRegistryBlob :: NodeRegistryBlob -> Handle -> IO (Either NodeRegistryReadError ())
  }

-- | The callback must invoke the public import path. Staging never publishes
-- or loads an image. Cleanup failure is returned separately from the primary.
prepareRegistryNodeArchive
  :: forall a. BootstrapProjection -> String -> (FilePath -> IO a) -> IO (PreparationResult a)
prepareRegistryNodeArchive =
  prepareRegistryNodeArchiveWith
    (RegistrySource fetchNodeRegistryManifest fetchNodeRegistryBlob)
    "/tmp"

-- | Acquire the reviewed provider executable for this selected test root.
-- The file is checked again from the held staging directory before import.
preparePinnedKindArtifact :: BootstrapProjection -> (FilePath -> IO a) -> IO (PreparationResult a)
preparePinnedKindArtifact projection publish
  | scopeEnvironment scope /= Test = refuse PreparationInvalidScope
  | otherwise = case bootstrapKindTool projection of
      Nothing -> refuse PreparationInvalidKindTool
      Just declaration -> do
        generation <- observeScopeGeneration scope (Text.unpack (bootstrapRootGeneration projection))
        if generation /= Right ScopeGenerationMatches
          then refuse PreparationGenerationUnavailable
          else withTestStaging "/tmp" (scopeIdentifier scope) (prepare declaration)
 where
  scope = bootstrapScope projection
  refuse failure = pure (PreparationResult (Left failure) True Nothing)
  prepare declaration directory held initial created = do
    fetched <-
      withStageFile held created "kind-tool" WriteMode $
        fetchPinnedKindTool
          (Text.pack (artifactDigest declaration))
          (min 104857600 (artifactMaximumBytes declaration))
    case fetched of
      Left failure -> pure (Left (PreparationSourceFailure failure))
      Right () -> do
        verified <- withStageFile held created "kind-tool" ReadMode $ \handle -> do
          size <- hFileSize handle
          verifyNodeRegistryBlob
            (NodeRegistryBlob (Text.pack (artifactDigest declaration)) size "application/octet-stream")
            handle
        generation <- observeScopeGeneration scope (Text.unpack (bootstrapRootGeneration projection))
        current <- getSymbolicLinkStatus directory
        if verified /= NodeBlobVerified
          then pure (Left PreparationKindToolMismatch)
          else
            if generation /= Right ScopeGenerationMatches || not (sameDirectory initial current)
              then pure (Left PreparationGenerationUnavailable)
              else Right <$> publish (directory </> "kind-tool")

-- | Injection is used for deterministic protocol tests; the public runner
-- always uses the fixed registry source and system temporary parent above.
prepareRegistryNodeArchiveWith
  :: forall a
   . RegistrySource
  -> FilePath
  -> BootstrapProjection
  -> String
  -> (FilePath -> IO a)
  -> IO (PreparationResult a)
prepareRegistryNodeArchiveWith source temporaryParent projection image publish
  | scopeEnvironment scope /= Test = refuse PreparationInvalidScope
  | otherwise = case (bootstrapNodeArtifact projection, stripImage image) of
      (Just declaration, Just digest) -> do
        generation <- observeScopeGeneration scope (Text.unpack (bootstrapRootGeneration projection))
        if generation /= Right ScopeGenerationMatches
          then refuse PreparationGenerationUnavailable
          else
            withTestStaging
              temporaryParent
              (scopeIdentifier scope)
              (\directory held initial created -> prepare directory held initial created declaration digest)
      _ -> refuse PreparationInvalidImage
 where
  scope = bootstrapScope projection
  refuse failure = pure (PreparationResult (Left failure) True Nothing)
  prepare directory held initial created declaration digest =
    stageRegistryNode source digest directory held created $ \output actual size ->
      if Text.unpack actual /= artifactDigest declaration || size > artifactMaximumBytes declaration
        then pure (Left PreparationArchiveDoesNotMatchDeclaration)
        else do
          generation <- observeScopeGeneration scope (Text.unpack (bootstrapRootGeneration projection))
          current <- getSymbolicLinkStatus directory
          if generation /= Right ScopeGenerationMatches || not (sameDirectory initial current)
            then pure (Left PreparationGenerationUnavailable)
            else Right <$> publish output

-- The pinned registry descriptor is a public content identity. The caller
-- receives only a verified unpublished archive and its exact digest and size.
pinnedNodeImage :: String
pinnedNodeImage = "kindest/node@sha256:21c46cf61fd45873f89e6a1bfcba4b7904dffa84c2bec88aeeca9a0409af4725"

prepareFreshNodeArchive
  :: DeploymentScope -> (FilePath -> Text.Text -> Integer -> IO a) -> IO (PreparationResult a)
prepareFreshNodeArchive =
  prepareFreshNodeArchiveWith
    (RegistrySource fetchNodeRegistryManifest fetchNodeRegistryBlob)
    "/tmp"
    pinnedNodeImage

prepareFreshNodeArchiveWith
  :: RegistrySource
  -> FilePath
  -> String
  -> DeploymentScope
  -> (FilePath -> Text.Text -> Integer -> IO a)
  -> IO (PreparationResult a)
prepareFreshNodeArchiveWith source temporaryParent image scope publish
  | scopeEnvironment scope /= Test =
      pure (PreparationResult (Left PreparationInvalidScope) True Nothing)
  | otherwise = do
      observation <- observeScopeRoot scope
      if observation /= Right ScopeRootAbsent
        then pure (PreparationResult (Left PreparationFreshScopeUnavailable) True Nothing)
        else case stripImage image of
          Nothing -> pure (PreparationResult (Left PreparationInvalidImage) True Nothing)
          Just selected -> withTestStaging temporaryParent (scopeIdentifier scope) $ \directory held initial created ->
            stageRegistryNode
              source
              selected
              directory
              held
              created
              $ \output actual size -> do
                current <- getSymbolicLinkStatus directory
                if sameDirectory initial current
                  then Right <$> publish output actual size
                  else pure (Left PreparationIoFailure)

-- | Create bounded non-secret adverse sources in the same isolated staging
-- discipline. The caller must drive the public import handler and record the
-- independent before/after observations; this helper claims no refusal.
prepareAdverseImportSources
  :: BootstrapProjection
  -> BS.ByteString
  -> (FilePath -> FilePath -> FilePath -> IO a)
  -> IO (PreparationResult a)
prepareAdverseImportSources projection foreignConfig action
  | scopeEnvironment scope /= Test = refuse PreparationInvalidScope
  | BS.null foreignConfig || BS.length foreignConfig > 1048576 =
      refuse PreparationInvalidAdverseFixture
  | otherwise = case bootstrapNodeArtifact projection of
      Nothing -> refuse PreparationInvalidAdverseFixture
      Just declaration
        | Text.pack (artifactDigest declaration) == alteredDigest -> refuse PreparationInvalidAdverseFixture
        | otherwise -> do
            generation <- observeScopeGeneration scope (Text.unpack (bootstrapRootGeneration projection))
            if generation /= Right ScopeGenerationMatches
              then refuse PreparationGenerationUnavailable
              else withTestStaging "/tmp" (scopeIdentifier scope) stage
 where
  scope = bootstrapScope projection
  altered = "prodbox-controlled-altered-artifact"
  alteredDigest = "sha256:" <> Text.pack (show (hash altered :: Digest SHA256))
  refuse failure = pure (PreparationResult (Left failure) True Nothing)
  stage directory held initial created = do
    withStageFile held created "altered" WriteMode (\handle -> BS.hPut handle altered)
    withStageFile held created "foreign.dhall" WriteMode (\handle -> BS.hPut handle foreignConfig)
    current <- getSymbolicLinkStatus directory
    generation <- observeScopeGeneration scope (Text.unpack (bootstrapRootGeneration projection))
    missing <- try (Posix.openFdAt (Just held) "missing" Posix.ReadOnly fileReadFlags)
    case missing of
      Right fd -> Posix.closeFd fd >> pure (Left PreparationInvalidAdverseFixture)
      Left failure
        | not (isDoesNotExistError (failure :: IOException)) -> pure (Left PreparationInvalidAdverseFixture)
        | not (sameDirectory initial current) || generation /= Right ScopeGenerationMatches ->
            pure (Left PreparationGenerationUnavailable)
        | otherwise ->
            Right <$> action (directory </> "altered") (directory </> "missing") (directory </> "foreign.dhall")

stageRegistryNode
  :: RegistrySource
  -> Text.Text
  -> FilePath
  -> Fd
  -> IORef [(FilePath, FileStatus)]
  -> (FilePath -> Text.Text -> Integer -> IO (Either PreparationFailure a))
  -> IO (Either PreparationFailure a)
stageRegistryNode source digest directory held created publish = do
  selected <- readRegistryManifest source digest
  case selected of
    Left failure -> pure (Left (PreparationSourceFailure failure))
    Right document
      | parseNodeRegistryManifest digest (nodeRegistryManifestBytes document)
          /= Right (nodeRegistryManifestPlan document) ->
          pure (Left PreparationManifestMismatch)
    Right document -> do
      let plan = nodeRegistryManifestPlan document
          blobs = nodeRegistryConfig plan : nodeRegistryLayers plan
          stagedBytes = sum (map nodeRegistryBlobSize blobs)
      if 2 * stagedBytes + 3 * 1048576 > 1073741824
        then pure (Left PreparationCapacityExceeded)
        else do
          fetched <- fetchAll blobs
          case fetched of
            Left failure -> pure (Left failure)
            Right paths -> withInputs held created paths $ \inputs -> do
              let output = directory </> "node-archive.tar"
              result <-
                withStageFile
                  held
                  created
                  "node-archive.tar"
                  WriteMode
                  (writeNodeRegistryArchive digest document inputs)
              case result of
                NodeRegistryArchiveWritten actual size -> publish output actual size
                other -> pure (Left (PreparationArchiveFailure other))
 where
  fetchAll blobs = foldM fetchOne (Right []) (zip [(0 :: Int) ..] blobs)
  fetchOne (Left failure) _ = pure (Left failure)
  fetchOne (Right paths) (number, blob) = do
    let path = "blob-" ++ show number
    fetched <- withStageFile held created path WriteMode $ \handle -> do
      result <- readRegistryBlob source blob handle
      hFlush handle
      pure result
    pure $ case fetched of
      Left failure -> Left (PreparationSourceFailure failure)
      Right () -> Right (paths ++ [path])

withTestStaging
  :: forall a
   . FilePath
  -> String
  -> (FilePath -> Fd -> FileStatus -> IORef [(FilePath, FileStatus)] -> IO (Either PreparationFailure a))
  -> IO (PreparationResult a)
withTestStaging temporaryParent identifier action = mask $ \restore -> do
  made <- try (createTempDirectory temporaryParent ("prodbox-node-" ++ identifier ++ "-"))
  case made of
    Left (_ :: IOException) -> pure (PreparationResult (Left PreparationIoFailure) True Nothing)
    Right directory -> do
      identified <- try (getSymbolicLinkStatus directory)
      case identified of
        Left (_ :: IOException) -> unconfirmed directory
        Right initial -> do
          opened <- try (Posix.openFd directory Posix.ReadOnly directoryFlags)
          case opened of
            Left (_ :: IOException) -> unconfirmed directory
            Right held -> do
              attempted <-
                ( do
                    current <- try (getFdStatus held)
                    owner <- getEffectiveUserID
                    case current of
                      Left (_ :: IOException) -> unconfirmed directory
                      Right status
                        | not (sameDirectory initial status && fileOwner status == owner && fileMode status .&. 0o077 == 0) ->
                            unconfirmed directory
                      Right _ -> do
                        created <- newIORef []
                        let cleanup = cleanupStaging directory initial held created
                        primary <-
                          restore (timeout 900000000 (try (action directory held initial created))) `onException` void cleanup
                        cleaned <- cleanup
                        pure $
                          PreparationResult
                            ( case primary of
                                Nothing -> Left PreparationTimedOut
                                Just result ->
                                  either
                                    (const (Left PreparationIoFailure))
                                    id
                                    (result :: Either IOException (Either PreparationFailure a))
                            )
                            cleaned
                            (if cleaned then Nothing else Just directory)
                )
                  `onException` void (try (Posix.closeFd held) :: IO (Either IOException ()))
              closed <- try (Posix.closeFd held) :: IO (Either IOException ())
              pure $ case closed of
                Right () -> attempted
                Left _ -> attempted {preparationCleanupConfirmed = False}
 where
  unconfirmed path = pure (PreparationResult (Left PreparationIoFailure) False (Just path))

stripImage :: String -> Maybe Text.Text
stripImage image = case splitAt (length prefix) image of
  (name, digest) | name == prefix && validNodeRegistryDigest (Text.pack digest) -> Just (Text.pack digest)
  _ -> Nothing
 where
  prefix = "kindest/node@"

withInputs :: Fd -> IORef [(FilePath, FileStatus)] -> [FilePath] -> ([Handle] -> IO a) -> IO a
withInputs _ _ [] action = action []
withInputs held created (path : paths) action =
  withStageFile held created path ReadMode $ \handle -> withInputs held created paths (action . (handle :))

directoryFlags :: Posix.OpenFileFlags
directoryFlags = Posix.defaultFileFlags {Posix.directory = True, Posix.nofollow = True, Posix.cloexec = True}

fileReadFlags :: Posix.OpenFileFlags
fileReadFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}

withStageFile
  :: Fd -> IORef [(FilePath, FileStatus)] -> FilePath -> IOMode -> (Handle -> IO a) -> IO a
withStageFile held created name mode action = mask $ \restore -> do
  let (access, selectedFlags) = case mode of
        WriteMode -> (Posix.WriteOnly, fileReadFlags {Posix.creat = Just 0o600, Posix.exclusive = True})
        _ -> (Posix.ReadOnly, fileReadFlags)
  fd <- Posix.openFdAt (Just held) name access selectedFlags
  status <- getFdStatus fd `onException` Posix.closeFd fd
  owner <- getEffectiveUserID `onException` Posix.closeFd fd
  existing <- readIORef created
  let sameFile = case mode of
        WriteMode -> True
        _ -> case lookup name existing of
          Just original -> deviceID status == deviceID original && fileID status == fileID original
          Nothing -> False
  unless
    ( isRegularFile status
        && linkCount status == 1
        && fileOwner status == owner
        && fileMode status .&. 0o077 == 0
        && sameFile
    )
    $ do
      Posix.closeFd fd
      ioError (userError "unsafe node staging file")
  case mode of
    WriteMode -> modifyIORef' created ((name, status) :)
    _ -> pure ()
  handle <- Posix.fdToHandle fd `onException` Posix.closeFd fd
  hSetBinaryMode handle True `onException` hClose handle
  bracket (pure handle) hClose (restore . action)

sameDirectory :: FileStatus -> FileStatus -> Bool
sameDirectory left right =
  isDirectory left
    && isDirectory right
    && deviceID right == deviceID left
    && fileID right == fileID left
    && fileOwner right == fileOwner left
    && fileMode right .&. 0o077 == 0

-- Retain unexpected contents for recovery; never recursively delete them.
cleanupStaging :: FilePath -> FileStatus -> Fd -> IORef [(FilePath, FileStatus)] -> IO Bool
cleanupStaging directory initial (Fd rawFd) created = do
  attempted <- try $ do
    status <- getSymbolicLinkStatus directory
    if not (sameDirectory initial status)
      then pure False
      else do
        let heldPath = "/proc/self/fd/" ++ show rawFd
        names <- listDirectory heldPath
        owned <- readIORef created
        if sort names /= sort (map fst owned)
          then pure False
          else do
            safe <- traverse (checkOwned heldPath owned) names
            if not (and safe)
              then pure False
              else do
                mapM_ (removeFile . (heldPath </>)) names
                final <- getSymbolicLinkStatus directory
                if sameDirectory initial final
                  then do
                    removeDirectory directory
                    observed <- try (getSymbolicLinkStatus directory)
                    pure $ case observed of
                      Left failure -> isDoesNotExistError (failure :: IOException)
                      Right _ -> False
                  else pure False
  pure $ either (const False) id (attempted :: Either IOException Bool)
 where
  checkOwned heldPath owned name = do
    status <- getSymbolicLinkStatus (heldPath </> name)
    pure $ case lookup name owned of
      Just original ->
        isRegularFile status
          && linkCount status == 1
          && deviceID status == deviceID original
          && fileID status == fileID original
          && fileOwner status == fileOwner original
      Nothing -> False
