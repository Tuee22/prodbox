{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Production retained-object binding for the in-cluster Lifecycle Authority.
--
-- This sole production binding uses the role's cached Kubernetes-auth Vault
-- session and the MinIO Service DNS endpoint. The
-- dedicated MinIO credential is read from @secret/minio/lifecycle-authority@;
-- the object-name HMAC and Transit key remain independently scoped.  Native S3
-- requests and the shared encrypted-object functions preserve byte identity
-- with the pre-cutover store without requiring @aws@ or a host port-forward.
module Prodbox.ControlPlane.InClusterAuthorityStore
  ( InClusterAuthorityStoreConfig
  , InClusterAuthorityStoreConfigError (..)
  , InClusterAuthorityStoreError (..)
  , InClusterAuthorityStore
  , mkInClusterAuthorityStoreConfig
  , defaultInClusterAuthorityEndpoint
  , defaultInClusterAuthorityBucket
  , inClusterAuthorityStoreClusterId
  , inClusterAuthorityStoreEndpoint
  , inClusterAuthorityStoreBucket
  , inClusterAuthorityCheckpointAuthority
  , newInClusterAuthorityStore
  , inClusterAuthorityTransport
  , inClusterAuthorityModelBCasAdapter
  , inClusterAuthorityReady
  , PrimaryAuthorityEnvelope (..)
  , observePrimaryAuthorityEnvelope
  , PrimaryPulumiCheckpointBlob
  , PrimaryPulumiCheckpointObservation (..)
  , primaryPulumiCheckpointCiphertext
  , primaryPulumiCheckpointCiphertextDigest
  , primaryPulumiCheckpointVersion
  , publishPrimaryPulumiCheckpointBlob
  , observePrimaryPulumiCheckpointBlob
  , PrimaryConfigBlob
  , PrimaryConfigObservation (..)
  , primaryConfigCiphertext
  , primaryConfigReference
  , publishPrimaryConfigBlob
  , observePrimaryConfigBlob
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Char (isAlphaNum, isSpace)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock (getCurrentTime)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Crypto.Envelope
  ( DekCipher (..)
  , openEnvelope
  , renderEnvelopeError
  , sealEnvelope
  )
import Prodbox.Http.Client (renderHttpError)
import Prodbox.Lifecycle.Authority.Config
  ( ConfigDigest (..)
  , ConfigReference (..)
  )
import Prodbox.Lifecycle.AuthorityObjectCore
  ( AuthorityCore (..)
  , compareAndSwapAuthorityObjectCore
  , readAuthorityObjectCore
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( AuthorityCoordinateError
  , LongLivedCheckpointAuthority
  , ModelBCasAdapter
  , ModelBCodec
  , ModelBObjectCoordinate
  , StoreLifetime (ClusterRetained)
  , mkLongLivedCheckpointAuthority
  , modelBObjectLogicalName
  )
import Prodbox.Lifecycle.ModelBCasTransport
  ( ModelBTransport (..)
  , modelBCasAdapterOverTransport
  )
import Prodbox.Lifecycle.PulumiCheckpoint
  ( CanonicalPulumiCheckpoint
  , PulumiCheckpointPayloadKind (PulumiFileBackendCheckpoint)
  , RegisteredPulumiCheckpoint
  , canonicalPulumiCheckpointBytes
  , canonicalPulumiCheckpointDigest
  , decodeCanonicalPulumiCheckpoint
  , pulumiCheckpointDigestText
  , pulumiCheckpointMaximumBytes
  , registeredPulumiCheckpointName
  )
import Prodbox.Minio.EncryptedObject
  ( LogicalObject (LogicalLongLivedState)
  , authorityLogicalObject
  , getLogicalVersionedWith
  , logicalObjectAad
  , objectKeyForOpaqueId
  , opaqueObjectId
  , putLogicalIfAbsentWith
  , putLogicalIfVersionWith
  )
import Prodbox.Minio.ObjectStoreNative qualified as Native
import Prodbox.Minio.ObjectStoreTypes
  ( ConditionalPutResult (..)
  , ObjectStoreConfig (..)
  , ObjectVersion (..)
  , VersionedObject (..)
  , defaultObjectStoreBucket
  )
import Prodbox.Vault.Client
  ( vaultKvReadV2
  , vaultTransitDecrypt
  , vaultTransitEncrypt
  )
import Prodbox.Vault.Session
  ( VaultSession
  , sessionAddress
  , withSessionToken
  )

data InClusterAuthorityStoreConfig = InClusterAuthorityStoreConfig
  { authorityStoreClusterId :: !Text
  , authorityStoreEndpoint :: !String
  , authorityStoreBucket :: !String
  }
  deriving (Eq, Show)

data InClusterAuthorityStoreConfigError
  = InClusterAuthorityClusterIdEmpty
  | InClusterAuthorityClusterIdContainsWhitespace
  | InClusterAuthorityEndpointInvalid !Text
  | InClusterAuthorityBucketInvalid !Text
  deriving (Eq, Show)

data InClusterAuthorityStoreError
  = InClusterAuthorityVaultReadFailed !Text !String
  | InClusterAuthorityVaultFieldMissing !Text !Text
  | InClusterAuthorityVaultFieldEmpty !Text !Text
  deriving (Eq, Show)

-- Deliberately no Show instance: the value owns the MinIO secret key and HMAC
-- material for the process lifetime.
data InClusterAuthorityStore = InClusterAuthorityStore
  { authorityStoreObjectConfig :: !ObjectStoreConfig
  , authorityStoreVaultSession :: !VaultSession
  , authorityStoreHmacKey :: !ByteString
  , authorityStoreClusterIdentity :: !Text
  }

defaultInClusterAuthorityEndpoint :: Text
defaultInClusterAuthorityEndpoint = "http://minio.prodbox.svc.cluster.local:9000"

defaultInClusterAuthorityBucket :: Text
defaultInClusterAuthorityBucket = Text.pack defaultObjectStoreBucket

inClusterAuthorityStoreClusterId :: InClusterAuthorityStoreConfig -> Text
inClusterAuthorityStoreClusterId = authorityStoreClusterId

inClusterAuthorityStoreEndpoint :: InClusterAuthorityStoreConfig -> Text
inClusterAuthorityStoreEndpoint = Text.pack . authorityStoreEndpoint

inClusterAuthorityStoreBucket :: InClusterAuthorityStoreConfig -> Text
inClusterAuthorityStoreBucket = Text.pack . authorityStoreBucket

-- | Canonical retained-authority descriptor derived only from the validated
-- schema-v3 in-cluster store coordinate.  The object namespace and Vault
-- keyspace are fixed by the Lifecycle Authority role; neither is guessed from
-- ambient repository or Gateway configuration.
inClusterAuthorityCheckpointAuthority
  :: InClusterAuthorityStoreConfig
  -> Either AuthorityCoordinateError LongLivedCheckpointAuthority
inClusterAuthorityCheckpointAuthority config =
  mkLongLivedCheckpointAuthority
    (authorityStoreClusterId config)
    (Text.pack (authorityStoreBucket config))
    "authority"
    "secret/lifecycle"

mkInClusterAuthorityStoreConfig
  :: Text
  -> Text
  -> Text
  -> Either InClusterAuthorityStoreConfigError InClusterAuthorityStoreConfig
mkInClusterAuthorityStoreConfig rawClusterId rawEndpoint rawBucket = do
  let clusterId = Text.strip rawClusterId
      endpoint = Text.strip rawEndpoint
      bucket = Text.strip rawBucket
  if Text.null clusterId
    then Left InClusterAuthorityClusterIdEmpty
    else
      if Text.any isSpace clusterId
        then Left InClusterAuthorityClusterIdContainsWhitespace
        else
          if not (validEndpoint endpoint)
            then Left (InClusterAuthorityEndpointInvalid endpoint)
            else
              if not (validBucket bucket)
                then Left (InClusterAuthorityBucketInvalid bucket)
                else
                  Right
                    InClusterAuthorityStoreConfig
                      { authorityStoreClusterId = clusterId
                      , authorityStoreEndpoint = Text.unpack endpoint
                      , authorityStoreBucket = Text.unpack bucket
                      }
 where
  validEndpoint value =
    not (Text.any isSpace value)
      && ("http://" `Text.isPrefixOf` value || "https://" `Text.isPrefixOf` value)
      && Text.length value > Text.length "http://"
  validBucket value =
    let lengthOk = Text.length value >= 3 && Text.length value <= 63
        allowed character = isAlphaNum character || character == '-' || character == '.'
     in lengthOk && Text.all allowed value

newInClusterAuthorityStore
  :: VaultSession
  -> InClusterAuthorityStoreConfig
  -> IO (Either InClusterAuthorityStoreError InClusterAuthorityStore)
newInClusterAuthorityStore session config = do
  credentialResult <- readVaultFields session credentialPath
  hmacResult <- readVaultFields session hmacPath
  pure $ do
    credentials <- credentialResult
    hmacFields <- hmacResult
    accessKey <- requireField credentialPath "minio_access_key" credentials
    secretKey <- requireField credentialPath "minio_secret_key" credentials
    hmacKey <- requireField hmacPath "key" hmacFields
    Right
      InClusterAuthorityStore
        { authorityStoreObjectConfig =
            ObjectStoreConfig
              { objectStoreEndpoint = authorityStoreEndpoint config
              , objectStoreBucket = authorityStoreBucket config
              , objectStoreAccessKey = Text.unpack accessKey
              , objectStoreSecretKey = Text.unpack secretKey
              }
        , authorityStoreVaultSession = session
        , authorityStoreHmacKey = TextEncoding.encodeUtf8 hmacKey
        , authorityStoreClusterIdentity = authorityStoreClusterId config
        }
 where
  credentialPath = "minio/lifecycle-authority"
  hmacPath = "object-store/hmac"

readVaultFields
  :: VaultSession
  -> Text
  -> IO (Either InClusterAuthorityStoreError (Map Text Text))
readVaultFields session path = do
  result <-
    withSessionToken session $ \token ->
      vaultKvReadV2 (sessionAddress session) token "secret" path
  pure $ case result of
    Left err -> Left (InClusterAuthorityVaultReadFailed path (renderHttpError err))
    Right fields -> Right fields

requireField
  :: Text
  -> Text
  -> Map Text Text
  -> Either InClusterAuthorityStoreError Text
requireField path field fields =
  case Map.lookup field fields of
    Nothing -> Left (InClusterAuthorityVaultFieldMissing path field)
    Just value
      | Text.null (Text.strip value) ->
          Left (InClusterAuthorityVaultFieldEmpty path field)
      | otherwise -> Right (Text.strip value)

inClusterAuthorityTransport :: InClusterAuthorityStore -> ModelBTransport
inClusterAuthorityTransport store =
  ModelBTransport
    { transportObserveObject = \logicalName -> do
        result <- readAuthorityObjectCore (inClusterAuthorityCore store) logicalName
        pure (mapLeft Text.pack result)
    , transportCasObject = \request -> do
        result <- compareAndSwapAuthorityObjectCore (inClusterAuthorityCore store) request
        pure (mapLeft Text.pack result)
    }

inClusterAuthorityModelBCasAdapter
  :: InClusterAuthorityStore
  -> LongLivedCheckpointAuthority
  -> ModelBCodec value
  -> ModelBCasAdapter lifetime IO value
inClusterAuthorityModelBCasAdapter store authority =
  modelBCasAdapterOverTransport authority (inClusterAuthorityTransport store)

-- | Readiness is a real signed S3 list operation through the dedicated
-- principal.  A merely-open TCP socket cannot make the role ready.
inClusterAuthorityReady :: InClusterAuthorityStore -> IO Bool
inClusterAuthorityReady store = do
  result <- Native.listKeys (authorityStoreObjectConfig store)
  pure (either (const False) (const True) result)

-- | The exact physical Transit envelope backing one retained Authority object.
-- It is intentionally opaque: backup copies preserve these bytes verbatim and
-- never decrypt/reseal them, so a retry can prove byte identity.
data PrimaryAuthorityEnvelope = PrimaryAuthorityEnvelope
  { primaryAuthorityEnvelopeCiphertext :: !ByteString
  , primaryAuthorityEnvelopeDigest :: !Text
  , primaryAuthorityEnvelopeVersion :: !Text
  }
  deriving (Eq)

instance Show PrimaryAuthorityEnvelope where
  show envelope =
    "<primary-authority-envelope:"
      <> show (ByteString.length (primaryAuthorityEnvelopeCiphertext envelope))
      <> " bytes>"

-- | Observe the physical encrypted object selected by an already-typed Model-B
-- coordinate. A missing object and an unavailable object are kept distinct.
observePrimaryAuthorityEnvelope
  :: InClusterAuthorityStore
  -> ModelBObjectCoordinate 'ClusterRetained
  -> IO (Either Text (Maybe PrimaryAuthorityEnvelope))
observePrimaryAuthorityEnvelope store coordinate = do
  let logicalObject =
        authorityLogicalObject (modelBObjectLogicalName coordinate)
      objectKey =
        objectKeyForOpaqueId
          (opaqueObjectId (authorityStoreHmacKey store) logicalObject)
  observed <- Native.getObjectVersioned (authorityStoreObjectConfig store) objectKey
  pure $ case observed of
    Left detail -> Left (Text.pack detail)
    Right Nothing -> Right Nothing
    Right (Just versioned) ->
      Right
        ( Just
            PrimaryAuthorityEnvelope
              { primaryAuthorityEnvelopeCiphertext = versionedObjectBytes versioned
              , primaryAuthorityEnvelopeDigest = sha256Text (versionedObjectBytes versioned)
              , primaryAuthorityEnvelopeVersion =
                  objectVersionText (versionedObjectVersion versioned)
              }
        )

-- | One immutable primary copy.  The plaintext checkpoint digest and the
-- sealed-envelope digest are deliberately distinct; the latter addresses the
-- exact ciphertext copied to the independent Authority Backup Adapter.
data PrimaryPulumiCheckpointBlob = PrimaryPulumiCheckpointBlob
  { internalPrimaryCheckpointCiphertext :: !ByteString
  , internalPrimaryCheckpointCiphertextDigest :: !Text
  , internalPrimaryCheckpointVersion :: !Text
  }
  deriving (Eq)

instance Show PrimaryPulumiCheckpointBlob where
  show blob =
    "<primary-pulumi-checkpoint-blob:"
      <> show (ByteString.length (primaryPulumiCheckpointCiphertext blob))
      <> " bytes>"

data PrimaryPulumiCheckpointObservation
  = PrimaryPulumiCheckpointMissing
  | PrimaryPulumiCheckpointCurrent
      !CanonicalPulumiCheckpoint
      !PrimaryPulumiCheckpointBlob
  | PrimaryPulumiCheckpointCorrupt !Text
  | PrimaryPulumiCheckpointUnobservable !Text
  deriving (Eq, Show)

primaryPulumiCheckpointCiphertext :: PrimaryPulumiCheckpointBlob -> ByteString
primaryPulumiCheckpointCiphertext = internalPrimaryCheckpointCiphertext

primaryPulumiCheckpointCiphertextDigest :: PrimaryPulumiCheckpointBlob -> Text
primaryPulumiCheckpointCiphertextDigest =
  internalPrimaryCheckpointCiphertextDigest

primaryPulumiCheckpointVersion :: PrimaryPulumiCheckpointBlob -> Text
primaryPulumiCheckpointVersion = internalPrimaryCheckpointVersion

-- | Seal once, immutably put, and read back the exact primary bytes.  A lost
-- PUT response converges through the same read-back.  A retry after a process
-- crash may create another content-addressed ciphertext for the same plaintext;
-- only the reference promoted into the Authority aggregate becomes current and
-- unreferenced immutable copies are later GC candidates.
publishPrimaryPulumiCheckpointBlob
  :: InClusterAuthorityStore
  -> RegisteredPulumiCheckpoint
  -> CanonicalPulumiCheckpoint
  -> IO (Either Text PrimaryPulumiCheckpointBlob)
publishPrimaryPulumiCheckpointBlob store registered checkpoint = do
  sealed <-
    sealEnvelope
      checkpointCipher
      (checkpointBlobAad store registered checkpointDigest)
      (canonicalPulumiCheckpointBytes checkpoint)
  case sealed of
    Left err -> pure (Left (Text.pack (renderEnvelopeError err)))
    Right ciphertext
      | ByteString.length ciphertext > primaryCheckpointCiphertextMaximumBytes ->
          pure (Left "sealed Pulumi checkpoint exceeds the primary blob bound")
      | otherwise -> do
          let ciphertextDigest = sha256Text ciphertext
              objectKey = checkpointBlobObjectKey store ciphertextDigest
          attempted <-
            Native.putIfAbsentObserved
              (authorityStoreObjectConfig store)
              objectKey
              ciphertext
          confirmPrimaryCheckpointPut
            store
            objectKey
            ciphertextDigest
            ciphertext
            attempted
 where
  checkpointDigest =
    pulumiCheckpointDigestText (canonicalPulumiCheckpointDigest checkpoint)
  checkpointCipher =
    sessionTransitCipher
      (authorityStoreVaultSession store)
      "prodbox-pulumi-state"

observePrimaryPulumiCheckpointBlob
  :: InClusterAuthorityStore
  -> RegisteredPulumiCheckpoint
  -> Text
  -- ^ canonical plaintext checkpoint digest
  -> Text
  -- ^ sealed-envelope digest
  -> Text
  -- ^ primary object version
  -> IO PrimaryPulumiCheckpointObservation
observePrimaryPulumiCheckpointBlob
  store
  registered
  checkpointDigest
  ciphertextDigest
  expectedVersion = do
    observed <-
      Native.getObjectVersioned
        (authorityStoreObjectConfig store)
        (checkpointBlobObjectKey store ciphertextDigest)
    case observed of
      Left detail ->
        pure (PrimaryPulumiCheckpointUnobservable (Text.pack detail))
      Right Nothing -> pure PrimaryPulumiCheckpointMissing
      Right (Just versioned)
        | objectVersionText (versionedObjectVersion versioned) /= expectedVersion ->
            pure (PrimaryPulumiCheckpointCorrupt "primary checkpoint version changed")
        | sha256Text (versionedObjectBytes versioned) /= ciphertextDigest ->
            pure (PrimaryPulumiCheckpointCorrupt "primary checkpoint ciphertext digest mismatch")
        | otherwise -> do
            opened <-
              openEnvelope
                checkpointCipher
                (checkpointBlobAad store registered checkpointDigest)
                (versionedObjectBytes versioned)
            pure $ case opened of
              Left err ->
                PrimaryPulumiCheckpointCorrupt
                  (Text.pack (renderEnvelopeError err))
              Right plaintext ->
                case decodeCanonicalPulumiCheckpoint
                  (Set.singleton PulumiFileBackendCheckpoint)
                  pulumiCheckpointMaximumBytes
                  plaintext of
                  Left err ->
                    PrimaryPulumiCheckpointCorrupt (Text.pack (show err))
                  Right checkpoint
                    | pulumiCheckpointDigestText
                        (canonicalPulumiCheckpointDigest checkpoint)
                        == checkpointDigest ->
                        PrimaryPulumiCheckpointCurrent
                          checkpoint
                          PrimaryPulumiCheckpointBlob
                            { internalPrimaryCheckpointCiphertext =
                                versionedObjectBytes versioned
                            , internalPrimaryCheckpointCiphertextDigest =
                                ciphertextDigest
                            , internalPrimaryCheckpointVersion = expectedVersion
                            }
                    | otherwise ->
                        PrimaryPulumiCheckpointCorrupt
                          "primary checkpoint plaintext digest mismatch"
   where
    checkpointCipher =
      sessionTransitCipher
        (authorityStoreVaultSession store)
        "prodbox-pulumi-state"

-- | Exact immutable primary ciphertext for one canonical config proposal.
-- The content-addressed reference is promoted into the Authority aggregate
-- only after the independent backup has read back the same bytes.
data PrimaryConfigBlob = PrimaryConfigBlob
  { internalPrimaryConfigCiphertext :: !ByteString
  , internalPrimaryConfigReference :: !ConfigReference
  }
  deriving (Eq)

instance Show PrimaryConfigBlob where
  show blob =
    "<primary-config-blob:"
      <> show (ByteString.length (primaryConfigCiphertext blob))
      <> " bytes>"

data PrimaryConfigObservation
  = PrimaryConfigMissing
  | PrimaryConfigCurrent !ByteString !PrimaryConfigBlob
  | PrimaryConfigCorrupt !Text
  | PrimaryConfigUnobservable !Text
  deriving (Eq, Show)

primaryConfigCiphertext :: PrimaryConfigBlob -> ByteString
primaryConfigCiphertext = internalPrimaryConfigCiphertext

primaryConfigReference :: PrimaryConfigBlob -> ConfigReference
primaryConfigReference = internalPrimaryConfigReference

publishPrimaryConfigBlob
  :: InClusterAuthorityStore
  -> ConfigDigest
  -> ByteString
  -> IO (Either Text PrimaryConfigBlob)
publishPrimaryConfigBlob store digest plaintext
  | ByteString.null plaintext = pure (Left "canonical config must not be empty")
  | ByteString.length plaintext > primaryConfigPlaintextMaximumBytes =
      pure (Left "canonical config exceeds the primary blob bound")
  | otherwise = do
      sealed <-
        sealEnvelope
          configCipher
          (configBlobAad store digest)
          plaintext
      case sealed of
        Left err -> pure (Left (Text.pack (renderEnvelopeError err)))
        Right ciphertext
          | ByteString.length ciphertext > primaryConfigCiphertextMaximumBytes ->
              pure (Left "sealed config exceeds the primary blob bound")
          | otherwise -> do
              let reference = ConfigReference (sha256Text ciphertext)
                  objectKey = configBlobObjectKey store reference
              attempted <-
                Native.putIfAbsentObserved
                  (authorityStoreObjectConfig store)
                  objectKey
                  ciphertext
              observed <-
                Native.getObjectVersioned
                  (authorityStoreObjectConfig store)
                  objectKey
              pure $ case observed of
                Left detail ->
                  Left
                    ( putAttemptDetail attempted
                        <> "; primary config read-back failed: "
                        <> Text.pack detail
                    )
                Right Nothing -> Left (putAttemptDetail attempted)
                Right (Just versioned)
                  | versionedObjectBytes versioned /= ciphertext ->
                      Left "primary config object already exists with different bytes"
                  | sha256Text (versionedObjectBytes versioned) /= configReferenceText reference ->
                      Left "primary config read-back digest mismatch"
                  | otherwise ->
                      Right
                        PrimaryConfigBlob
                          { internalPrimaryConfigCiphertext = ciphertext
                          , internalPrimaryConfigReference = reference
                          }
 where
  configCipher =
    sessionTransitCipher
      (authorityStoreVaultSession store)
      "prodbox-active-config"

observePrimaryConfigBlob
  :: InClusterAuthorityStore
  -> ConfigDigest
  -> ConfigReference
  -> IO PrimaryConfigObservation
observePrimaryConfigBlob store digest reference = do
  observed <-
    Native.getObjectVersioned
      (authorityStoreObjectConfig store)
      (configBlobObjectKey store reference)
  case observed of
    Left detail -> pure (PrimaryConfigUnobservable (Text.pack detail))
    Right Nothing -> pure PrimaryConfigMissing
    Right (Just versioned)
      | sha256Text (versionedObjectBytes versioned) /= configReferenceText reference ->
          pure (PrimaryConfigCorrupt "primary config ciphertext digest mismatch")
      | otherwise -> do
          opened <-
            openEnvelope
              configCipher
              (configBlobAad store digest)
              (versionedObjectBytes versioned)
          pure $ case opened of
            Left err ->
              PrimaryConfigCorrupt (Text.pack (renderEnvelopeError err))
            Right plaintext
              | sha256Text plaintext /= configDigestText digest ->
                  PrimaryConfigCorrupt "primary config plaintext digest mismatch"
              | otherwise ->
                  PrimaryConfigCurrent
                    plaintext
                    PrimaryConfigBlob
                      { internalPrimaryConfigCiphertext = versionedObjectBytes versioned
                      , internalPrimaryConfigReference = reference
                      }
 where
  configCipher =
    sessionTransitCipher
      (authorityStoreVaultSession store)
      "prodbox-active-config"

primaryConfigPlaintextMaximumBytes :: Int
primaryConfigPlaintextMaximumBytes = 4 * 1024 * 1024

primaryConfigCiphertextMaximumBytes :: Int
primaryConfigCiphertextMaximumBytes = 8 * 1024 * 1024

configBlobAad
  :: InClusterAuthorityStore
  -> ConfigDigest
  -> ByteString
configBlobAad store digest =
  logicalObjectAad
    (authorityStoreClusterIdentity store)
    ( LogicalLongLivedState
        ("authority-config/sha256-" <> configDigestText digest)
    )

configBlobObjectKey
  :: InClusterAuthorityStore
  -> ConfigReference
  -> Text
configBlobObjectKey store reference =
  objectKeyForOpaqueId
    ( opaqueObjectId
        (authorityStoreHmacKey store)
        ( LogicalLongLivedState
            ("authority-config-ciphertext/sha256-" <> configReferenceText reference)
        )
    )

configDigestText :: ConfigDigest -> Text
configDigestText (ConfigDigest value) = value

configReferenceText :: ConfigReference -> Text
configReferenceText (ConfigReference value) = value

primaryCheckpointCiphertextMaximumBytes :: Int
primaryCheckpointCiphertextMaximumBytes = 96 * 1024 * 1024

confirmPrimaryCheckpointPut
  :: InClusterAuthorityStore
  -> Text
  -> Text
  -> ByteString
  -> Either String ConditionalPutResult
  -> IO (Either Text PrimaryPulumiCheckpointBlob)
confirmPrimaryCheckpointPut store objectKey ciphertextDigest ciphertext attempted = do
  observed <- Native.getObjectVersioned (authorityStoreObjectConfig store) objectKey
  pure $ case observed of
    Left detail ->
      Left
        ( putAttemptDetail attempted
            <> "; primary checkpoint read-back failed: "
            <> Text.pack detail
        )
    Right Nothing -> Left (putAttemptDetail attempted)
    Right (Just versioned)
      | versionedObjectBytes versioned /= ciphertext ->
          Left "primary checkpoint object already exists with different bytes"
      | sha256Text (versionedObjectBytes versioned) /= ciphertextDigest ->
          Left "primary checkpoint read-back digest mismatch"
      | otherwise ->
          Right
            PrimaryPulumiCheckpointBlob
              { internalPrimaryCheckpointCiphertext = ciphertext
              , internalPrimaryCheckpointCiphertextDigest = ciphertextDigest
              , internalPrimaryCheckpointVersion =
                  objectVersionText (versionedObjectVersion versioned)
              }

putAttemptDetail :: Either String ConditionalPutResult -> Text
putAttemptDetail attempted = case attempted of
  Left detail -> "primary checkpoint PUT failed: " <> Text.pack detail
  Right (ConditionalPutApplied _) -> "primary checkpoint PUT was not visible"
  Right ConditionalPutConflict ->
    "primary checkpoint object conflicted and was not visible"

checkpointBlobAad
  :: InClusterAuthorityStore
  -> RegisteredPulumiCheckpoint
  -> Text
  -> ByteString
checkpointBlobAad store registered checkpointDigest =
  logicalObjectAad
    (authorityStoreClusterIdentity store)
    ( LogicalLongLivedState
        ( "pulumi-checkpoint/"
            <> registeredPulumiCheckpointName registered
            <> "/sha256-"
            <> checkpointDigest
        )
    )

checkpointBlobObjectKey :: InClusterAuthorityStore -> Text -> Text
checkpointBlobObjectKey store ciphertextDigest =
  objectKeyForOpaqueId
    ( opaqueObjectId
        (authorityStoreHmacKey store)
        ( LogicalLongLivedState
            ("pulumi-checkpoint-ciphertext/sha256-" <> ciphertextDigest)
        )
    )

objectVersionText :: ObjectVersion -> Text
objectVersionText = objectVersionEtag

sha256Text :: ByteString -> Text
sha256Text = TextEncoding.decodeUtf8 . hexSha256

inClusterAuthorityCore :: InClusterAuthorityStore -> AuthorityCore IO
inClusterAuthorityCore store =
  AuthorityCore
    { authGetVersioned =
        getLogicalVersionedWith
          (Native.getObjectVersioned objectConfig)
          cipher
          hmacKey
          clusterId
    , authPutIfAbsent =
        putLogicalIfAbsentWith
          (Native.putIfAbsentObserved objectConfig)
          cipher
          hmacKey
          clusterId
    , authPutIfVersion = \logicalObject version ->
        putLogicalIfVersionWith
          (\key -> Native.putIfVersionObserved objectConfig key version)
          cipher
          hmacKey
          clusterId
          logicalObject
    , authNow = getCurrentTime
    }
 where
  objectConfig = authorityStoreObjectConfig store
  cipher = sessionTransitCipher (authorityStoreVaultSession store) "prodbox-pulumi-state"
  hmacKey = authorityStoreHmacKey store
  clusterId = authorityStoreClusterIdentity store

sessionTransitCipher :: VaultSession -> Text -> DekCipher
sessionTransitCipher session keyName =
  DekCipher
    { dekWrap = \bytes -> do
        result <-
          withSessionToken session $ \token ->
            vaultTransitEncrypt (sessionAddress session) token keyName bytes
        pure (mapLeft renderHttpError result)
    , dekUnwrap = \wrapped -> do
        result <-
          withSessionToken session $ \token ->
            vaultTransitDecrypt (sessionAddress session) token keyName wrapped
        pure (mapLeft renderHttpError result)
    }

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft convert result = case result of
  Left err -> Left (convert err)
  Right value -> Right value
