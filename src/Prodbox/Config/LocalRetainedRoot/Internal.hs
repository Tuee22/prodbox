{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Package-private retained-root observation and marker store.  Raw marker
-- values and filesystem/authentication boundaries remain hidden so neither a
-- caller-selected path nor a fake config client can mint an Authority-bound
-- root.
module Prodbox.Config.LocalRetainedRoot.Internal
  ( BootstrapRetainedRootLocator
  , AuthorityBoundRetainedRoot
  , LocalRetainedRootEntry (..)
  , LocalRetainedRootError (..)
  , RetainedRootMarkerReconcileOutcome (..)
  , bootstrapRetainedRootLocatorPath
  , authorityBoundRetainedRootPath
  , authorityBoundRetainedRootInForceConfig
  , renderLocalRetainedRootError
  , renderRetainedRootMarkerReconcileOutcome
  , locateBootstrapRetainedRoot
  , reconcileAuthorityBoundRetainedRootMarker
  , reobserveAuthorityBoundRetainedRoot
  , LocalRetainedRootFixtureRegression
  , fixedLocalRetainedRootFixtureRegression
  , localRetainedRootFixtureMarkerRoundTrips
  , localRetainedRootFixtureMarkerLengthFramed
  , localRetainedRootFixtureMismatchRefused
  , localRetainedRootFixtureLegacyRequiresAuthority
  , localRetainedRootFixtureLayoutClosed
  )
where

import Codec.CBOR.Decoding qualified as Cbor
import Codec.CBOR.Encoding qualified as Cbor
import Codec.Serialise
  ( DeserialiseFailure
  , Serialise (decode, encode)
  , deserialiseOrFail
  , serialise
  )
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception
  ( IOException
  , SomeException
  , bracket
  , displayException
  , mask_
  , throwIO
  , try
  )
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Dhall qualified
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.ConfigClient
  ( ConfigClient (observeConfig)
  , ConfigClientError
  , configClientWithTransport
  )
import Prodbox.ControlPlane.ConfigEndpoint
  ( ConfigObservation (..)
  , ConfigProjection (..)
  , ConfigProjectionScope (ConfigProjectionOperator)
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityOperator)
  , renderLifecycleAuthorityAuthenticationError
  , withHostLifecycleAuthorityAuthentication
  , withLifecycleAuthorityAuthenticatedTransport
  )
import Prodbox.Lifecycle.Authority.Config
  ( ConfigDigest (ConfigDigest)
  , ConfigSchemaVersion (ConfigSchemaVersion)
  , ConfigState (ConfigInForce)
  , InForceConfig (..)
  , validateConfigState
  )
import Prodbox.Repo (resolveTier0ConfigPath)
import Prodbox.Settings
  ( ConfigFile (storage)
  , StorageSection (manual_pv_host_root)
  , decodeConfigDhallBytes
  , renderConfigDhall
  )
import Prodbox.Settings.Coordinate
  ( mkSafeRelativePath
  , renderCoordinateError
  , safeRelativePathText
  )
import System.Directory
  ( canonicalizePath
  , makeAbsolute
  , removeFile
  , renameFile
  )
import System.FilePath
  ( isAbsolute
  , makeRelative
  , normalise
  , splitDirectories
  , takeDirectory
  , (</>)
  )
import System.IO (SeekMode (AbsoluteSeek))
import System.IO.Error (isDoesNotExistError, isEOFError)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Files
  ( FileStatus
  , accessModes
  , fileMode
  , fileSize
  , getFdStatus
  , getSymbolicLinkStatus
  , intersectFileModes
  , isDirectory
  , isRegularFile
  , isSymbolicLink
  , ownerReadMode
  , ownerWriteMode
  , setFdMode
  , unionFileModes
  )
import System.Posix.IO
  ( LockRequest (Unlock, WriteLock)
  , OpenFileFlags (..)
  , OpenMode (ReadOnly, WriteOnly)
  , closeFd
  , defaultFileFlags
  , openFd
  , setLock
  )
import System.Posix.IO.ByteString qualified as PosixByteString
import System.Posix.Types (Fd, FileMode)
import System.Posix.Unistd (fileSynchronise)

-- | Filesystem identities whose exact kind is relevant to the retained-root
-- boundary.  The list is closed so missing layout never becomes an unbounded
-- path supplied by a caller.
data LocalRetainedRootEntry
  = LocalRetainedRootRepository
  | LocalRetainedRootCabalMarker
  | LocalRetainedRootPlanMarker
  | LocalRetainedRootTier0Config
  | LocalRetainedRootDirectory
  | LocalRetainedRootControlDirectory
  | LocalRetainedRootMinioDirectory
  | LocalRetainedRootVaultDirectory
  | LocalRetainedRootEstablishmentMarker
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data LocalRetainedRootError
  = LocalRetainedRootRepositoryInvalid !Text
  | LocalRetainedRootTier0Unobservable !Text
  | LocalRetainedRootCoordinateInvalid !Text
  | LocalRetainedRootEntryMissing !LocalRetainedRootEntry
  | LocalRetainedRootEntryUnsafe !LocalRetainedRootEntry !Text
  | LocalRetainedRootMarkerLegacyUntrusted
  | LocalRetainedRootMarkerInvalid !Text
  | LocalRetainedRootMarkerConflict
  | LocalRetainedRootMarkerBusy
  | LocalRetainedRootMarkerWriteFailed !Text
  | LocalRetainedRootAuthorityUnavailable !Text
  | LocalRetainedRootAuthorityConfigMissing
  | LocalRetainedRootAuthorityConfigCorrupt !Text
  | LocalRetainedRootAuthorityConfigUnobservable !Text
  | LocalRetainedRootAuthorityConfigInvalid !Text
  | LocalRetainedRootAuthorityMismatch
  deriving stock (Eq, Show)

data RetainedRootMarkerReconcileOutcome
  = RetainedRootMarkerCreated
  | RetainedRootMarkerAlreadyCurrent
  | RetainedRootLegacyMarkerReplaced
  deriving stock (Eq, Show)

-- Deliberately not a newtype: representational coercion must not turn a raw
-- path into even the non-authorizing locator.
data BootstrapRetainedRootLocator = BootstrapRetainedRootLocator
  { bootstrapLocatorRepository :: !FilePath
  , bootstrapLocatorCoordinate :: !Text
  , bootstrapLocatorRoot :: !FilePath
  , bootstrapLocatorMarker :: !RetainedRootMarker
  }

-- This constructor occurs only in 'reobserveAuthorityBoundRetainedRoot'.  The
-- exact current config identity is retained even though the marker coordinate
-- intentionally remains stable across unrelated config generations.
data AuthorityBoundRetainedRoot = AuthorityBoundRetainedRoot
  { authorityRootPath :: !FilePath
  , authorityRootInForceConfig :: !InForceConfig
  }

bootstrapRetainedRootLocatorPath :: BootstrapRetainedRootLocator -> FilePath
bootstrapRetainedRootLocatorPath = bootstrapLocatorRoot

authorityBoundRetainedRootPath :: AuthorityBoundRetainedRoot -> FilePath
authorityBoundRetainedRootPath = authorityRootPath

authorityBoundRetainedRootInForceConfig
  :: AuthorityBoundRetainedRoot -> InForceConfig
authorityBoundRetainedRootInForceConfig = authorityRootInForceConfig

renderLocalRetainedRootError :: LocalRetainedRootError -> Text
renderLocalRetainedRootError err = case err of
  LocalRetainedRootRepositoryInvalid detail ->
    "retained-root repository identity is invalid: " <> detail
  LocalRetainedRootTier0Unobservable detail ->
    "Tier-0 retained-root coordinate is unobservable: " <> detail
  LocalRetainedRootCoordinateInvalid detail ->
    "retained-root coordinate is invalid: " <> detail
  LocalRetainedRootEntryMissing entry ->
    "retained-root layout entry is missing: " <> entryLabel entry
  LocalRetainedRootEntryUnsafe entry detail ->
    "retained-root layout entry is unsafe (" <> entryLabel entry <> "): " <> detail
  LocalRetainedRootMarkerLegacyUntrusted ->
    "legacy empty cluster-established marker is non-authorizing until a live Authority reconcile replaces it"
  LocalRetainedRootMarkerInvalid detail ->
    "cluster-established marker is invalid: " <> detail
  LocalRetainedRootMarkerConflict ->
    "cluster-established marker names a different canonical retained root"
  LocalRetainedRootMarkerBusy ->
    "cluster-established marker reconciliation is already in progress"
  LocalRetainedRootMarkerWriteFailed detail ->
    "cluster-established marker write/read-back failed: " <> detail
  LocalRetainedRootAuthorityUnavailable detail ->
    "Lifecycle Authority config observation failed: " <> detail
  LocalRetainedRootAuthorityConfigMissing ->
    "Lifecycle Authority in-force config is absent"
  LocalRetainedRootAuthorityConfigCorrupt detail ->
    "Lifecycle Authority in-force config is corrupt: " <> detail
  LocalRetainedRootAuthorityConfigUnobservable detail ->
    "Lifecycle Authority in-force config is unobservable: " <> detail
  LocalRetainedRootAuthorityConfigInvalid detail ->
    "Lifecycle Authority in-force config projection is invalid: " <> detail
  LocalRetainedRootAuthorityMismatch ->
    "authenticated retained-root observation does not exactly match the bootstrap locator"

renderRetainedRootMarkerReconcileOutcome
  :: RetainedRootMarkerReconcileOutcome -> Text
renderRetainedRootMarkerReconcileOutcome outcome = case outcome of
  RetainedRootMarkerCreated ->
    "Created and read back the canonical retained-root establishment marker."
  RetainedRootMarkerAlreadyCurrent ->
    "The canonical retained-root establishment marker is already current."
  RetainedRootLegacyMarkerReplaced ->
    "Replaced the legacy empty establishment marker from the live Authority root observation."

entryLabel :: LocalRetainedRootEntry -> Text
entryLabel entry = case entry of
  LocalRetainedRootRepository -> "repository root"
  LocalRetainedRootCabalMarker -> "prodbox.cabal"
  LocalRetainedRootPlanMarker -> "DEVELOPMENT_PLAN/README.md"
  LocalRetainedRootTier0Config -> "binary-sibling prodbox.dhall"
  LocalRetainedRootDirectory -> "configured retained root"
  LocalRetainedRootControlDirectory -> "prodbox control directory"
  LocalRetainedRootMinioDirectory -> "prodbox/minio/0"
  LocalRetainedRootVaultDirectory -> "vault/vault/0"
  LocalRetainedRootEstablishmentMarker -> "prodbox/.cluster-established"

markerMagic :: Text
markerMagic = "prodbox-local-retained-root"

markerSchemaVersion :: Word
markerSchemaVersion = 1

maximumRetainedRootMarkerBytes :: Int
maximumRetainedRootMarkerBytes = 4096

data RetainedRootMarker = RetainedRootMarker
  { markerRepository :: !Text
  , markerCoordinate :: !Text
  , markerRoot :: !Text
  }
  deriving stock (Eq, Show, Generic)

instance Serialise RetainedRootMarker where
  encode marker =
    Cbor.encodeListLen 5
      <> Cbor.encodeString markerMagic
      <> Cbor.encodeWord markerSchemaVersion
      <> Cbor.encodeString (markerRepository marker)
      <> Cbor.encodeString (markerCoordinate marker)
      <> Cbor.encodeString (markerRoot marker)
  decode = do
    encodedFields <- Cbor.decodeListLen
    unless (encodedFields == 5) $
      fail "retained-root marker must contain exactly five fields"
    magic <- Cbor.decodeString
    unless (magic == markerMagic) $
      fail "retained-root marker magic is invalid"
    version <- Cbor.decodeWord
    unless (version == markerSchemaVersion) $
      fail "retained-root marker schema version is unsupported"
    RetainedRootMarker
      <$> Cbor.decodeString
      <*> Cbor.decodeString
      <*> Cbor.decodeString

encodeMarker :: RetainedRootMarker -> ByteString
encodeMarker = LazyByteString.toStrict . serialise

decodeMarker :: ByteString -> Either LocalRetainedRootError RetainedRootMarker
decodeMarker bytes
  | ByteString.null bytes = Left LocalRetainedRootMarkerLegacyUntrusted
  | ByteString.length bytes > maximumRetainedRootMarkerBytes =
      Left (LocalRetainedRootMarkerInvalid "encoded marker exceeds 4096 bytes")
  | otherwise =
      case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left failure -> Left (markerDecodeFailure failure)
        Right marker
          | encodeMarker marker == bytes -> Right marker
          | otherwise ->
              Left (LocalRetainedRootMarkerInvalid "marker bytes are not canonical")

markerDecodeFailure :: DeserialiseFailure -> LocalRetainedRootError
markerDecodeFailure =
  LocalRetainedRootMarkerInvalid . boundedDetail . Text.pack . show

data ObservedAuthorityRoot = ObservedAuthorityRoot
  { observedAuthorityRepository :: !FilePath
  , observedAuthorityCoordinate :: !Text
  , observedAuthorityRoot :: !FilePath
  , observedAuthorityIdentity :: !InForceConfig
  }

expectedMarker :: FilePath -> Text -> FilePath -> RetainedRootMarker
expectedMarker repository coordinate root =
  RetainedRootMarker
    { markerRepository = Text.pack repository
    , markerCoordinate = coordinate
    , markerRoot = Text.pack root
    }

markerPath :: FilePath -> FilePath
markerPath root = root </> "prodbox" </> ".cluster-established"

markerLockPath :: FilePath -> FilePath
markerLockPath root = root </> "prodbox" </> ".cluster-established.lock"

markerTemporaryPath :: FilePath -> FilePath
markerTemporaryPath root = root </> "prodbox" </> ".cluster-established.tmp"

-- | Bootstrap reads only the Tier-0 storage subrecord and the canonical marker.
-- The resulting locator carries no config identity and authorizes nothing.
locateBootstrapRetainedRoot
  :: FilePath -> IO (Either LocalRetainedRootError BootstrapRetainedRootLocator)
locateBootstrapRetainedRoot suppliedRepository = do
  repositoryResult <- validateRepository suppliedRepository
  case repositoryResult of
    Left err -> pure (Left err)
    Right repository -> do
      coordinateResult <- loadTier0StorageCoordinate repository
      case coordinateResult of
        Left err -> pure (Left err)
        Right coordinate -> do
          rootResult <- validateRetainedRootLayout repository coordinate
          case rootResult of
            Left err -> pure (Left err)
            Right root -> do
              stored <- readMarkerFile (markerPath root)
              pure $ do
                bytes <- stored
                marker <- decodeMarker bytes
                let expected = expectedMarker repository coordinate root
                unless (marker == expected) (Left LocalRetainedRootMarkerConflict)
                Right
                  BootstrapRetainedRootLocator
                    { bootstrapLocatorRepository = repository
                    , bootstrapLocatorCoordinate = coordinate
                    , bootstrapLocatorRoot = root
                    , bootstrapLocatorMarker = marker
                    }

-- | Normal-reconcile migration hook.  It performs a fresh authenticated
-- Operator observation before touching the marker, then create-or-replays and
-- independently reads back canonical v1 bytes under a process + POSIX lock.
reconcileAuthorityBoundRetainedRootMarker
  :: FilePath
  -> IO
       ( Either
           LocalRetainedRootError
           RetainedRootMarkerReconcileOutcome
       )
reconcileAuthorityBoundRetainedRootMarker suppliedRepository = do
  observed <- observeAuthenticatedAuthorityRoot suppliedRepository
  case observed of
    Left err -> pure (Left err)
    Right authorityRoot ->
      withMVar retainedRootProcessLock $ \() ->
        withMarkerLock (observedAuthorityRoot authorityRoot) $ do
          let root = observedAuthorityRoot authorityRoot
              path = markerPath root
              bytes =
                encodeMarker
                  ( expectedMarker
                      (observedAuthorityRepository authorityRoot)
                      (observedAuthorityCoordinate authorityRoot)
                      root
                  )
          existing <- readOptionalMarkerFile path
          case existing of
            Left err -> pure (Left err)
            Right Nothing -> persistAndReadBack root bytes RetainedRootMarkerCreated
            Right (Just current)
              | ByteString.null current ->
                  persistAndReadBack root bytes RetainedRootLegacyMarkerReplaced
              | current == bytes -> confirmMarkerReadBack path bytes RetainedRootMarkerAlreadyCurrent
              | otherwise -> case decodeMarker current of
                  Right _ -> pure (Left LocalRetainedRootMarkerConflict)
                  Left err -> pure (Left err)

-- | The only production upgrade from the non-authorizing locator.  It freshly
-- observes the authenticated Operator projection and retains the exact current
-- 'InForceConfig' identity after exact repository/coordinate/root/marker match.
reobserveAuthorityBoundRetainedRoot
  :: FilePath
  -> BootstrapRetainedRootLocator
  -> IO (Either LocalRetainedRootError AuthorityBoundRetainedRoot)
reobserveAuthorityBoundRetainedRoot suppliedRepository locator = do
  observed <- observeAuthenticatedAuthorityRoot suppliedRepository
  case observed of
    Left err -> pure (Left err)
    Right authorityRoot -> do
      markerResult <- readMarkerFile (markerPath (observedAuthorityRoot authorityRoot))
      pure $ do
        markerBytes <- markerResult
        marker <- decodeMarker markerBytes
        let sameIdentity =
              observedAuthorityRepository authorityRoot
                == bootstrapLocatorRepository locator
                && observedAuthorityCoordinate authorityRoot
                  == bootstrapLocatorCoordinate locator
                && observedAuthorityRoot authorityRoot
                  == bootstrapLocatorRoot locator
                && marker == bootstrapLocatorMarker locator
                && marker
                  == expectedMarker
                    (observedAuthorityRepository authorityRoot)
                    (observedAuthorityCoordinate authorityRoot)
                    (observedAuthorityRoot authorityRoot)
        unless sameIdentity (Left LocalRetainedRootAuthorityMismatch)
        Right
          ( AuthorityBoundRetainedRoot
              (observedAuthorityRoot authorityRoot)
              (observedAuthorityIdentity authorityRoot)
          )

observeAuthenticatedAuthorityRoot
  :: FilePath -> IO (Either LocalRetainedRootError ObservedAuthorityRoot)
observeAuthenticatedAuthorityRoot suppliedRepository = do
  repositoryResult <- validateRepository suppliedRepository
  case repositoryResult of
    Left err -> pure (Left err)
    Right repository -> do
      observed <- runProductionOperatorObservation repository
      case observed of
        Left err -> pure (Left err)
        Right ConfigObservationMissing ->
          pure (Left LocalRetainedRootAuthorityConfigMissing)
        Right (ConfigObservationCorrupt detail) ->
          pure (Left (LocalRetainedRootAuthorityConfigCorrupt (boundedDetail detail)))
        Right (ConfigObservationUnobservable detail) ->
          pure (Left (LocalRetainedRootAuthorityConfigUnobservable (boundedDetail detail)))
        Right (ConfigObservationObserved projection) ->
          validateAuthorityProjection repository projection

runProductionOperatorObservation
  :: FilePath
  -> IO (Either LocalRetainedRootError ConfigObservation)
runProductionOperatorObservation repository = do
  authenticated <-
    withHostLifecycleAuthorityAuthentication
      LifecycleAuthorityOperator
      repository
      ( \authentication ->
          withLifecycleAuthorityAuthenticatedTransport authentication $ \transport ->
            observeConfig
              (configClientWithTransport transport ConfigProjectionOperator)
      )
  pure $ case authenticated of
    Left err ->
      Left
        ( LocalRetainedRootAuthorityUnavailable
            (boundedDetail (Text.pack (renderLifecycleAuthorityAuthenticationError err)))
        )
    Right (Left err) ->
      Left
        ( LocalRetainedRootAuthorityUnavailable
            (boundedDetail (Text.pack (renderLifecycleAuthorityAuthenticationError err)))
        )
    Right (Right (Left err)) ->
      Left (renderConfigClientFailure err)
    Right (Right (Right observation)) -> Right observation

renderConfigClientFailure :: ConfigClientError -> LocalRetainedRootError
renderConfigClientFailure =
  LocalRetainedRootAuthorityUnavailable . boundedDetail . Text.pack . show

validateAuthorityProjection
  :: FilePath
  -> ConfigProjection
  -> IO (Either LocalRetainedRootError ObservedAuthorityRoot)
validateAuthorityProjection repository projection
  | configProjectionScope projection /= ConfigProjectionOperator =
      pure
        ( Left
            ( LocalRetainedRootAuthorityConfigInvalid
                "projection scope is not Operator"
            )
        )
  | otherwise =
      case validateConfigState (ConfigInForce identity) of
        Left detail ->
          pure
            ( Left
                ( LocalRetainedRootAuthorityConfigInvalid
                    (boundedDetail (Text.pack (show detail)))
                )
            )
        Right ()
          | inForceSchema identity /= ConfigSchemaVersion 1 ->
              pure
                ( Left
                    ( LocalRetainedRootAuthorityConfigInvalid
                        "projection schema is not version 1"
                    )
                )
          | actualDigest /= expectedDigest ->
              pure
                ( Left
                    ( LocalRetainedRootAuthorityConfigInvalid
                        "projection bytes do not match the in-force digest"
                    )
                )
          | otherwise -> do
              decoded <- decodeConfigDhallBytes repository bytes
              case decoded of
                Left detail ->
                  pure
                    ( Left
                        ( LocalRetainedRootAuthorityConfigInvalid
                            (boundedDetail (Text.pack detail))
                        )
                    )
                Right config
                  | TextEncoding.encodeUtf8 (Text.pack (renderConfigDhall config)) /= bytes ->
                      pure
                        ( Left
                            ( LocalRetainedRootAuthorityConfigInvalid
                                "Operator projection bytes are not canonical"
                            )
                        )
                  | otherwise -> authorityRootFromConfig repository identity config
 where
  identity = configProjectionIdentity projection
  bytes = configProjectionBytes projection
  ConfigDigest expectedDigest = inForceDigest identity
  actualDigest = TextEncoding.decodeUtf8 (hexSha256 bytes)

authorityRootFromConfig
  :: FilePath
  -> InForceConfig
  -> ConfigFile
  -> IO (Either LocalRetainedRootError ObservedAuthorityRoot)
authorityRootFromConfig repository identity config =
  case validateStorageCoordinate (manual_pv_host_root (storage config)) of
    Left err -> pure (Left err)
    Right coordinate -> do
      rootResult <- validateRetainedRootLayout repository coordinate
      pure $ do
        root <- rootResult
        Right
          ObservedAuthorityRoot
            { observedAuthorityRepository = repository
            , observedAuthorityCoordinate = coordinate
            , observedAuthorityRoot = root
            , observedAuthorityIdentity = identity
            }

loadTier0StorageCoordinate
  :: FilePath -> IO (Either LocalRetainedRootError Text)
loadTier0StorageCoordinate repository = do
  path <- resolveTier0ConfigPath repository
  pathResult <- validateRegularFile LocalRetainedRootTier0Config path
  case pathResult of
    Left err -> pure (Left err)
    Right canonicalPath -> do
      let expression = "( " <> Text.pack canonicalPath <> " ).parameters.storage"
      decoded <-
        try (Dhall.input Dhall.auto expression)
          :: IO (Either SomeException StorageSection)
      pure $ case decoded of
        Left err ->
          Left
            ( LocalRetainedRootTier0Unobservable
                (boundedDetail (Text.pack (displayException err)))
            )
        Right section ->
          validateStorageCoordinate (manual_pv_host_root section)

validateStorageCoordinate :: Text -> Either LocalRetainedRootError Text
validateStorageCoordinate raw = do
  safe <-
    case mkSafeRelativePath raw of
      Left err ->
        Left
          ( LocalRetainedRootCoordinateInvalid
              (boundedDetail (Text.pack (renderCoordinateError err)))
          )
      Right value -> Right value
  let coordinate = safeRelativePathText safe
      segments = Text.splitOn "/" coordinate
  if any (\segment -> Text.null segment || segment == ".") segments
    then
      Left
        ( LocalRetainedRootCoordinateInvalid
            "coordinate must contain only nonempty, non-dot path segments"
        )
    else Right coordinate

validateRepository
  :: FilePath -> IO (Either LocalRetainedRootError FilePath)
validateRepository supplied = do
  absolute <- normalise <$> makeAbsolute supplied
  directoryResult <- validateDirectoryPath LocalRetainedRootRepository absolute
  case directoryResult of
    Left err -> pure (Left (repositoryError err))
    Right repository -> do
      cabalResult <-
        validateRegularFile LocalRetainedRootCabalMarker (repository </> "prodbox.cabal")
      planResult <-
        validateRegularFile
          LocalRetainedRootPlanMarker
          (repository </> "DEVELOPMENT_PLAN" </> "README.md")
      pure $ do
        _ <- firstRepositoryError cabalResult
        _ <- firstRepositoryError planResult
        Right repository

repositoryError :: LocalRetainedRootError -> LocalRetainedRootError
repositoryError =
  LocalRetainedRootRepositoryInvalid . boundedDetail . renderLocalRetainedRootError

firstRepositoryError
  :: Either LocalRetainedRootError value
  -> Either LocalRetainedRootError value
firstRepositoryError = either (Left . repositoryError) Right

validateRetainedRootLayout
  :: FilePath -> Text -> IO (Either LocalRetainedRootError FilePath)
validateRetainedRootLayout repository coordinate = do
  let lexicalRoot = normalise (repository </> Text.unpack coordinate)
      relative = makeRelative repository lexicalRoot
  if isAbsolute relative || relative == ".." || ".." `elem` splitDirectories relative
    then
      pure
        ( Left
            ( LocalRetainedRootEntryUnsafe
                LocalRetainedRootDirectory
                "configured root escapes the canonical repository"
            )
        )
    else do
      rootResult <- validateDirectoryPath LocalRetainedRootDirectory lexicalRoot
      case rootResult of
        Left err -> pure (Left err)
        Right root -> do
          control <-
            validateDirectoryPath LocalRetainedRootControlDirectory (root </> "prodbox")
          minio <-
            validateDirectoryPath
              LocalRetainedRootMinioDirectory
              (root </> "prodbox" </> "minio" </> "0")
          vault <-
            validateDirectoryPath
              LocalRetainedRootVaultDirectory
              (root </> "vault" </> "vault" </> "0")
          pure $ do
            _ <- control
            _ <- minio
            _ <- vault
            Right root

validateDirectoryPath
  :: LocalRetainedRootEntry
  -> FilePath
  -> IO (Either LocalRetainedRootError FilePath)
validateDirectoryPath entry path = do
  let normalized = normalise path
  componentsResult <- validatePathComponents ExpectedDirectory normalized
  case componentsResult of
    Left detail -> pure (Left (entryPathError entry detail))
    Right () -> do
      canonicalResult <- try (canonicalizePath normalized)
      pure $ case canonicalResult of
        Left (err :: IOException)
          | isDoesNotExistError err -> Left (LocalRetainedRootEntryMissing entry)
          | otherwise ->
              Left
                ( LocalRetainedRootEntryUnsafe
                    entry
                    (boundedDetail (Text.pack (displayException err)))
                )
        Right canonical
          | normalise canonical /= normalized ->
              Left
                ( LocalRetainedRootEntryUnsafe
                    entry
                    "canonical path differs from its lexical path"
                )
          | otherwise -> Right normalized

validateRegularFile
  :: LocalRetainedRootEntry
  -> FilePath
  -> IO (Either LocalRetainedRootError FilePath)
validateRegularFile entry path = do
  let normalized = normalise path
  componentsResult <- validatePathComponents ExpectedRegularFile normalized
  case componentsResult of
    Left detail -> pure (Left (entryPathError entry detail))
    Right () -> do
      canonicalResult <- try (canonicalizePath normalized)
      pure $ case canonicalResult of
        Left (err :: IOException)
          | isDoesNotExistError err -> Left (LocalRetainedRootEntryMissing entry)
          | otherwise ->
              Left
                ( LocalRetainedRootEntryUnsafe
                    entry
                    (boundedDetail (Text.pack (displayException err)))
                )
        Right canonical
          | normalise canonical /= normalized ->
              Left
                ( LocalRetainedRootEntryUnsafe
                    entry
                    "canonical path differs from its lexical path"
                )
          | otherwise -> Right normalized

entryPathError :: LocalRetainedRootEntry -> PathComponentFailure -> LocalRetainedRootError
entryPathError entry failure = case failure of
  PathComponentMissing -> LocalRetainedRootEntryMissing entry
  PathComponentUnsafe detail -> LocalRetainedRootEntryUnsafe entry detail

data PathComponentFailure
  = PathComponentMissing
  | PathComponentUnsafe !Text

data ExpectedPathKind
  = ExpectedDirectory
  | ExpectedRegularFile

validatePathComponents
  :: ExpectedPathKind -> FilePath -> IO (Either PathComponentFailure ())
validatePathComponents expectedKind absolutePath = go (pathPrefixes absolutePath)
 where
  go [] = pure (Right ())
  go (path : remaining) = do
    observed <- try (getSymbolicLinkStatus path)
    case observed of
      Left (err :: IOException)
        | isDoesNotExistError err -> pure (Left PathComponentMissing)
        | otherwise ->
            pure
              ( Left
                  (PathComponentUnsafe (boundedDetail (Text.pack (displayException err))))
              )
      Right status
        | isSymbolicLink status ->
            pure (Left (PathComponentUnsafe "path contains a symbolic link"))
        | null remaining && expectedPathKindMatches expectedKind status -> pure (Right ())
        | null remaining ->
            pure (Left (PathComponentUnsafe "path has the wrong file kind"))
        | isDirectory status -> go remaining
        | otherwise -> pure (Left (PathComponentUnsafe "path component has the wrong file kind"))

expectedPathKindMatches :: ExpectedPathKind -> FileStatus -> Bool
expectedPathKindMatches expected status = case expected of
  ExpectedDirectory -> isDirectory status
  ExpectedRegularFile -> isRegularFile status

pathPrefixes :: FilePath -> [FilePath]
pathPrefixes path = case scanl (</>) "" (splitDirectories path) of
  [] -> []
  _root : prefixes -> prefixes

data StoredMarker
  = StoredMarkerMissing
  | StoredMarkerPresent !ByteString

readOptionalMarkerFile
  :: FilePath -> IO (Either LocalRetainedRootError (Maybe ByteString))
readOptionalMarkerFile path = do
  observed <- readStoredMarker path
  pure $ case observed of
    Left err -> Left err
    Right StoredMarkerMissing -> Right Nothing
    Right (StoredMarkerPresent bytes) -> Right (Just bytes)

readMarkerFile :: FilePath -> IO (Either LocalRetainedRootError ByteString)
readMarkerFile path = do
  observed <- readStoredMarker path
  pure $ case observed of
    Left err -> Left err
    Right StoredMarkerMissing ->
      Left (LocalRetainedRootEntryMissing LocalRetainedRootEstablishmentMarker)
    Right (StoredMarkerPresent bytes) -> Right bytes

readStoredMarker :: FilePath -> IO (Either LocalRetainedRootError StoredMarker)
readStoredMarker path = do
  opened <-
    try
      ( bracket
          ( openFd
              path
              ReadOnly
              defaultFileFlags {nofollow = True, cloexec = True}
          )
          safeCloseFd
          readOpenMarker
      )
  pure $ case opened of
    Left (err :: IOException)
      | isDoesNotExistError err -> Right StoredMarkerMissing
      | otherwise ->
          Left
            ( LocalRetainedRootEntryUnsafe
                LocalRetainedRootEstablishmentMarker
                (boundedDetail (Text.pack (displayException err)))
            )
    Right result -> result

readOpenMarker :: Fd -> IO (Either LocalRetainedRootError StoredMarker)
readOpenMarker fd = do
  status <- getFdStatus fd
  if not (isRegularFile status)
    then
      pure
        ( Left
            ( LocalRetainedRootEntryUnsafe
                LocalRetainedRootEstablishmentMarker
                "marker is not a regular file"
            )
        )
    else
      if toInteger (fileSize status) > toInteger maximumRetainedRootMarkerBytes
        then
          pure
            ( Left
                (LocalRetainedRootMarkerInvalid "encoded marker exceeds 4096 bytes")
            )
        else do
          bytes <- readFdBounded fd (maximumRetainedRootMarkerBytes + 1)
          pure
            ( if ByteString.length bytes > maximumRetainedRootMarkerBytes
                then
                  Left
                    (LocalRetainedRootMarkerInvalid "encoded marker exceeds 4096 bytes")
                else Right (StoredMarkerPresent bytes)
            )

{-# NOINLINE retainedRootProcessLock #-}
retainedRootProcessLock :: MVar ()
retainedRootProcessLock = unsafePerformIO (newMVar ())

withMarkerLock
  :: FilePath
  -> IO (Either LocalRetainedRootError value)
  -> IO (Either LocalRetainedRootError value)
withMarkerLock root action = do
  opened <-
    try
      ( openFd
          (markerLockPath root)
          WriteOnly
          defaultFileFlags
            { creat = Just ownerFileMode
            , nofollow = True
            , cloexec = True
            }
      )
  case opened of
    Left (err :: IOException) ->
      pure
        ( Left
            ( LocalRetainedRootMarkerWriteFailed
                (boundedDetail (Text.pack (displayException err)))
            )
        )
    Right fd ->
      bracket
        (pure fd)
        safeCloseFd
        ( \held -> do
            status <- getFdStatus held
            if not (isRegularFile status)
              then
                pure
                  ( Left
                      ( LocalRetainedRootMarkerWriteFailed
                          "marker lock is not a regular file"
                      )
                  )
              else do
                setFdMode held ownerFileMode
                locked <- try (setLock held (WriteLock, AbsoluteSeek, 0, 0))
                case locked of
                  Left (_ :: IOException) -> pure (Left LocalRetainedRootMarkerBusy)
                  Right () -> do
                    result <- action
                    _ <- try (setLock held (Unlock, AbsoluteSeek, 0, 0)) :: IO (Either IOException ())
                    pure result
        )

persistAndReadBack
  :: FilePath
  -> ByteString
  -> RetainedRootMarkerReconcileOutcome
  -> IO (Either LocalRetainedRootError RetainedRootMarkerReconcileOutcome)
persistAndReadBack root bytes outcome = do
  let temporary = markerTemporaryPath root
      active = markerPath root
  stale <- readOptionalMarkerFile temporary
  case stale of
    Left err -> pure (Left err)
    Right (Just _) -> do
      removed <- try (removeFile temporary)
      case removed of
        Left (err :: IOException) -> pure (Left (markerWriteError err))
        Right () -> writePublishConfirm temporary active
    Right Nothing -> writePublishConfirm temporary active
 where
  writePublishConfirm temporary active = do
    written <- writeMarkerTemporary temporary bytes
    case written of
      Left err -> pure (Left err)
      Right () -> do
        published <-
          try . mask_ $ do
            renameFile temporary active
            syncDirectory (takeDirectory active)
        case published of
          Left (err :: IOException) -> pure (Left (markerWriteError err))
          Right () -> confirmMarkerReadBack active bytes outcome

writeMarkerTemporary
  :: FilePath -> ByteString -> IO (Either LocalRetainedRootError ())
writeMarkerTemporary path bytes = do
  written <-
    try . mask_ $
      bracket
        ( openFd
            path
            WriteOnly
            defaultFileFlags
              { exclusive = True
              , creat = Just ownerFileMode
              , nofollow = True
              , cloexec = True
              }
        )
        safeCloseFd
        ( \fd -> do
            setFdMode fd ownerFileMode
            status <- getFdStatus fd
            unless (isRegularFile status && exactMode ownerFileMode status) $
              throwIO (userError "temporary marker file kind or mode is invalid")
            writeAll fd bytes
            fileSynchronise fd
        )
  pure $ case written of
    Left (err :: IOException) -> Left (markerWriteError err)
    Right () -> Right ()

confirmMarkerReadBack
  :: FilePath
  -> ByteString
  -> RetainedRootMarkerReconcileOutcome
  -> IO (Either LocalRetainedRootError RetainedRootMarkerReconcileOutcome)
confirmMarkerReadBack path expected outcome = do
  observed <- readMarkerFile path
  pure $ do
    bytes <- observed
    unless (bytes == expected) (Left LocalRetainedRootMarkerConflict)
    _ <- decodeMarker bytes
    Right outcome

syncDirectory :: FilePath -> IO ()
syncDirectory path =
  bracket
    ( openFd
        path
        ReadOnly
        defaultFileFlags
          { directory = True
          , nofollow = True
          , cloexec = True
          }
    )
    safeCloseFd
    fileSynchronise

ownerFileMode :: FileMode
ownerFileMode = ownerReadMode `unionFileModes` ownerWriteMode

exactMode :: FileMode -> FileStatus -> Bool
exactMode expected status =
  fileMode status `intersectFileModes` accessModes == expected

markerWriteError :: IOException -> LocalRetainedRootError
markerWriteError =
  LocalRetainedRootMarkerWriteFailed . boundedDetail . Text.pack . displayException

safeCloseFd :: Fd -> IO ()
safeCloseFd fd = do
  _ <- try (closeFd fd) :: IO (Either IOException ())
  pure ()

writeAll :: Fd -> ByteString -> IO ()
writeAll _ bytes | ByteString.null bytes = pure ()
writeAll fd bytes = do
  written <- PosixByteString.fdWrite fd bytes
  let count = fromIntegral written
  if count <= 0
    then throwIO (userError "retained-root marker write made no progress")
    else writeAll fd (ByteString.drop count bytes)

readFdBounded :: Fd -> Int -> IO ByteString
readFdBounded fd maximumBytes = go maximumBytes []
 where
  go remaining chunks
    | remaining <= 0 = pure (ByteString.concat (reverse chunks))
    | otherwise = do
        readResult <-
          try
            ( PosixByteString.fdRead
                fd
                (fromIntegral (min remaining 4096))
            )
        case readResult of
          Left (err :: IOException)
            | isEOFError err -> pure (ByteString.concat (reverse chunks))
            | otherwise -> throwIO err
          Right chunk
            | ByteString.null chunk -> pure (ByteString.concat (reverse chunks))
            | otherwise -> go (remaining - ByteString.length chunk) (chunk : chunks)

boundedDetail :: Text -> Text
boundedDetail = Text.take 512

-- Fixed, non-parameterized diagnostics let the external unit component prove
-- codec/refusal invariants without importing hidden constructors or an
-- injectable Authority/filesystem boundary.
data LocalRetainedRootFixtureRegression = LocalRetainedRootFixtureRegression
  { fixtureMarkerRoundTrips :: !Bool
  , fixtureMarkerLengthFramed :: !Bool
  , fixtureMismatchRefused :: !Bool
  , fixtureLegacyRequiresAuthority :: !Bool
  , fixtureLayoutClosed :: !Bool
  }

fixedLocalRetainedRootFixtureRegression :: LocalRetainedRootFixtureRegression
fixedLocalRetainedRootFixtureRegression =
  LocalRetainedRootFixtureRegression
    { fixtureMarkerRoundTrips = decodeMarker encoded == Right fixtureMarker
    , fixtureMarkerLengthFramed =
        encodeMarker (expectedMarker "/a/b" "c" "/a/b/c")
          /= encodeMarker (expectedMarker "/a" "b/c" "/a/b/c")
    , fixtureMismatchRefused =
        fixtureMarker
          /= expectedMarker "/srv/prodbox" "data" "/srv/prodbox/data"
    , fixtureLegacyRequiresAuthority =
        decodeMarker ByteString.empty == Left LocalRetainedRootMarkerLegacyUntrusted
    , fixtureLayoutClosed =
        [minBound .. maxBound]
          == [ LocalRetainedRootRepository
             , LocalRetainedRootCabalMarker
             , LocalRetainedRootPlanMarker
             , LocalRetainedRootTier0Config
             , LocalRetainedRootDirectory
             , LocalRetainedRootControlDirectory
             , LocalRetainedRootMinioDirectory
             , LocalRetainedRootVaultDirectory
             , LocalRetainedRootEstablishmentMarker
             ]
    }
 where
  encoded = encodeMarker fixtureMarker

fixtureMarker :: RetainedRootMarker
fixtureMarker = expectedMarker "/srv/prodbox" ".data" "/srv/prodbox/.data"

localRetainedRootFixtureMarkerRoundTrips
  :: LocalRetainedRootFixtureRegression -> Bool
localRetainedRootFixtureMarkerRoundTrips = fixtureMarkerRoundTrips

localRetainedRootFixtureMarkerLengthFramed
  :: LocalRetainedRootFixtureRegression -> Bool
localRetainedRootFixtureMarkerLengthFramed = fixtureMarkerLengthFramed

localRetainedRootFixtureMismatchRefused
  :: LocalRetainedRootFixtureRegression -> Bool
localRetainedRootFixtureMismatchRefused = fixtureMismatchRefused

localRetainedRootFixtureLegacyRequiresAuthority
  :: LocalRetainedRootFixtureRegression -> Bool
localRetainedRootFixtureLegacyRequiresAuthority = fixtureLegacyRequiresAuthority

localRetainedRootFixtureLayoutClosed
  :: LocalRetainedRootFixtureRegression -> Bool
localRetainedRootFixtureLayoutClosed = fixtureLayoutClosed
