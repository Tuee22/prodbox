{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Broker-only mounted Dhall settings.
--
-- The decoder accepts one schema and one explicit file.  It has no environment
-- or generic-daemon fallback, and the schema has no credential, password,
-- recovery-share, token, or private-key field.  The burn recipient identity is
-- compiled into the runtime settings rather than accepted as configuration.
module Prodbox.Bootstrap.Broker.Settings
  ( BootstrapBrokerConfigDhall (..)
  , BrokerListenerDhall (..)
  , BootstrapStoreDhall (..)
  , BrokerLimitsDhall (..)
  , BootstrapBrokerSettings
  , brokerSchemaVersion
  , brokerClusterId
  , brokerVaultAddress
  , brokerServiceIdentity
  , brokerListener
  , brokerBootstrapStore
  , brokerLimits
  , brokerBurnRecipient
  , BrokerListener
  , brokerListenAddress
  , brokerListenPort
  , LoopbackAddress (..)
  , loopbackAddressText
  , BootstrapStore
  , bootstrapStoreEndpoint
  , bootstrapStoreBucket
  , bootstrapStorageKeys
  , BootstrapStorageKeys
  , vaultStorageGenerationKey
  , bootstrapSessionFenceKey
  , preparedInitEnvelopeKey
  , encryptedInitResponseKey
  , finalUnlockBundleKey
  , childCustodyReceiptKey
  , childRecoveryDeliveryKey
  , rootInitJournalKey
  , rootSessionJournalKey
  , childCustodyJournalKey
  , childRecoveryJournalKey
  , postUnsealHandoffKey
  , secretWorkerCheckpointKey
  , BrokerLimits
  , brokerQueueCapacity
  , brokerMaximumRequestBodyBytes
  , brokerRequestDeadlineMilliseconds
  , brokerDrainDeadlineMilliseconds
  , BurnRecipientFingerprint
  , unBurnRecipientFingerprint
  , BurnRecipientPublicKeyDigest
  , unBurnRecipientPublicKeyDigest
  , CompiledBurnRecipient
  , burnRecipientPublicKeyBase64
  , burnRecipientFingerprint
  , burnRecipientPublicKeyDigest
  , compiledBurnRecipient
  , BrokerConfigField (..)
  , BrokerLimitName (..)
  , BootstrapBrokerSettingsError (..)
  , renderBootstrapBrokerSettingsError
  , supportedBootstrapBrokerSchemaVersion
  , maximumBrokerQueueCapacity
  , maximumBrokerRequestBodyBytes
  , maximumBrokerRequestDeadlineMilliseconds
  , maximumBrokerDrainDeadlineMilliseconds
  , validateBootstrapBrokerConfig
  , decodeBootstrapBrokerConfigDhall
  , loadBootstrapBrokerConfig
  )
where

import Control.Exception (SomeException, displayException, try)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import Dhall (FromDhall, auto, input, inputFile)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

-- | Dhall DTO for the Bootstrap Broker.  Deliberately no sum with gateway
-- settings exists: the runtime role is selected before this decoder runs.
data BootstrapBrokerConfigDhall = BootstrapBrokerConfigDhall
  { schemaVersion :: Natural
  , cluster_id :: Text
  , vault_address :: Text
  , service_identity :: Text
  , listener :: BrokerListenerDhall
  , bootstrap_store :: BootstrapStoreDhall
  , limits :: BrokerLimitsDhall
  }
  deriving (Eq, Show, Generic, FromDhall)

data BrokerListenerDhall = BrokerListenerDhall
  { listen_host :: Text
  , listen_port :: Natural
  }
  deriving (Eq, Show, Generic, FromDhall)

data BootstrapStoreDhall = BootstrapStoreDhall
  { store_endpoint :: Text
  , store_bucket :: Text
  , vault_storage_generation_key :: Text
  , bootstrap_session_fence_key :: Text
  , prepared_init_envelope_key :: Text
  , encrypted_init_response_key :: Text
  , final_unlock_bundle_key :: Text
  , child_custody_receipt_key :: Text
  , child_recovery_delivery_key :: Text
  , root_init_journal_key :: Text
  , root_session_journal_key :: Text
  , child_custody_journal_key :: Text
  , child_recovery_journal_key :: Text
  , post_unseal_handoff_key :: Text
  , secret_worker_checkpoint_key :: Text
  }
  deriving (Eq, Show, Generic, FromDhall)

data BrokerLimitsDhall = BrokerLimitsDhall
  { queue_capacity :: Natural
  , max_request_body_bytes :: Natural
  , request_deadline_milliseconds :: Natural
  , drain_deadline_milliseconds :: Natural
  }
  deriving (Eq, Show, Generic, FromDhall)

data BootstrapBrokerSettings = BootstrapBrokerSettings
  { brokerSchemaVersion :: Natural
  , brokerClusterId :: Text
  , brokerVaultAddress :: Text
  , brokerServiceIdentity :: Text
  , brokerListener :: BrokerListener
  , brokerBootstrapStore :: BootstrapStore
  , brokerLimits :: BrokerLimits
  , brokerBurnRecipient :: CompiledBurnRecipient
  }
  deriving (Eq, Show)

data BrokerListener = BrokerListener
  { brokerListenAddress :: LoopbackAddress
  , brokerListenPort :: Word16
  }
  deriving (Eq, Show)

data LoopbackAddress
  = LoopbackIpv4
  | LoopbackIpv6
  deriving (Eq, Ord, Show, Enum, Bounded)

loopbackAddressText :: LoopbackAddress -> Text
loopbackAddressText address = case address of
  LoopbackIpv4 -> "127.0.0.1"
  LoopbackIpv6 -> "::1"

data BootstrapStore = BootstrapStore
  { bootstrapStoreEndpoint :: Text
  , bootstrapStoreBucket :: Text
  , bootstrapStorageKeys :: BootstrapStorageKeys
  }
  deriving (Eq, Show)

data BootstrapStorageKeys = BootstrapStorageKeys
  { vaultStorageGenerationKey :: Text
  , bootstrapSessionFenceKey :: Text
  , preparedInitEnvelopeKey :: Text
  , encryptedInitResponseKey :: Text
  , finalUnlockBundleKey :: Text
  , childCustodyReceiptKey :: Text
  , childRecoveryDeliveryKey :: Text
  , rootInitJournalKey :: Text
  , rootSessionJournalKey :: Text
  , childCustodyJournalKey :: Text
  , childRecoveryJournalKey :: Text
  , postUnsealHandoffKey :: Text
  , secretWorkerCheckpointKey :: Text
  }
  deriving (Eq, Show)

data BrokerLimits = BrokerLimits
  { brokerQueueCapacity :: Natural
  , brokerMaximumRequestBodyBytes :: Natural
  , brokerRequestDeadlineMilliseconds :: Natural
  , brokerDrainDeadlineMilliseconds :: Natural
  }
  deriving (Eq, Show)

newtype BurnRecipientFingerprint = BurnRecipientFingerprint {unBurnRecipientFingerprint :: Text}
  deriving (Eq, Ord, Show)

newtype BurnRecipientPublicKeyDigest = BurnRecipientPublicKeyDigest
  { unBurnRecipientPublicKeyDigest :: Text
  }
  deriving (Eq, Ord, Show)

-- | The exact non-secret public value and identity pins for the compiled burn
-- recipient.  There is no private-key field or constructor in this settings
-- model.
data CompiledBurnRecipient = CompiledBurnRecipient
  { burnRecipientPublicKeyBase64 :: Text
  , burnRecipientFingerprint :: BurnRecipientFingerprint
  , burnRecipientPublicKeyDigest :: BurnRecipientPublicKeyDigest
  }
  deriving (Eq, Show)

-- | Version-one compile-time burn recipient.  The canonical base64 value is a
-- standards-valid transferable OpenPGP public entity produced by the audited
-- destructive ceremony documented in @burn_recipient_provenance.md@: its
-- certification-only RSA primary created the UID and subkey signatures, its
-- encryption-only RSA subkey is Vault-compatible, and the entire ephemeral
-- private keyring was destroyed before these public bytes were committed.  No
-- private material is retained, accepted, or available to prodbox.  The PGP
-- interpreter must match the exact value and both pins before initialization;
-- none is accepted from Dhall.
compiledBurnRecipient :: CompiledBurnRecipient
compiledBurnRecipient =
  CompiledBurnRecipient
    { burnRecipientPublicKeyBase64 =
        "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"
    , burnRecipientFingerprint =
        BurnRecipientFingerprint
          "f0debca077828f2a82813f420020e4e04a4dd831"
    , burnRecipientPublicKeyDigest =
        BurnRecipientPublicKeyDigest
          "sha256:3873c5409fba7088e036f4cd56c0ab35aab889920802ecf956a5be579ecadd56"
    }

data BrokerConfigField
  = ClusterIdField
  | VaultAddressField
  | ServiceIdentityField
  | StoreEndpointField
  | StoreBucketField
  | VaultStorageGenerationKeyField
  | BootstrapSessionFenceKeyField
  | PreparedInitEnvelopeKeyField
  | EncryptedInitResponseKeyField
  | FinalUnlockBundleKeyField
  | ChildCustodyReceiptKeyField
  | ChildRecoveryDeliveryKeyField
  | RootInitJournalKeyField
  | RootSessionJournalKeyField
  | ChildCustodyJournalKeyField
  | ChildRecoveryJournalKeyField
  | PostUnsealHandoffKeyField
  | SecretWorkerCheckpointKeyField
  deriving (Eq, Ord, Show, Enum, Bounded)

data BrokerLimitName
  = QueueCapacityLimit
  | RequestBodyBytesLimit
  | RequestDeadlineMillisecondsLimit
  | DrainDeadlineMillisecondsLimit
  deriving (Eq, Ord, Show, Enum, Bounded)

data BootstrapBrokerSettingsError
  = BrokerDhallDecodeFailed String
  | BrokerSchemaVersionMismatch Natural Natural
  | BrokerConfigFieldEmpty BrokerConfigField
  | BrokerListenerNotLoopback Text
  | BrokerListenerPortOutOfRange Natural
  | BrokerLimitOutOfRange BrokerLimitName Natural Natural
  | BrokerStorageKeysNotDistinct
  deriving (Eq, Show)

renderBootstrapBrokerSettingsError :: BootstrapBrokerSettingsError -> String
renderBootstrapBrokerSettingsError err = case err of
  BrokerDhallDecodeFailed detail ->
    "failed to decode bootstrap-broker Dhall config: " ++ detail
  BrokerSchemaVersionMismatch expected observed ->
    "config_schema_mismatch: expected schemaVersion "
      ++ show expected
      ++ ", got "
      ++ show observed
  BrokerConfigFieldEmpty field ->
    "bootstrap-broker config field must not be empty: " ++ brokerConfigFieldName field
  BrokerListenerNotLoopback observed ->
    "bootstrap-broker listener must be exactly 127.0.0.1 or ::1, got `"
      ++ Text.unpack observed
      ++ "`"
  BrokerListenerPortOutOfRange observed ->
    "bootstrap-broker listen_port must be between 1 and 65535, got " ++ show observed
  BrokerLimitOutOfRange limitName maximumValue observed ->
    "bootstrap-broker "
      ++ brokerLimitName limitName
      ++ " must be between 1 and "
      ++ show maximumValue
      ++ ", got "
      ++ show observed
  BrokerStorageKeysNotDistinct ->
    "bootstrap-broker storage keys must be pairwise distinct"

brokerConfigFieldName :: BrokerConfigField -> String
brokerConfigFieldName field = case field of
  ClusterIdField -> "cluster_id"
  VaultAddressField -> "vault_address"
  ServiceIdentityField -> "service_identity"
  StoreEndpointField -> "bootstrap_store.store_endpoint"
  StoreBucketField -> "bootstrap_store.store_bucket"
  VaultStorageGenerationKeyField -> "bootstrap_store.vault_storage_generation_key"
  BootstrapSessionFenceKeyField -> "bootstrap_store.bootstrap_session_fence_key"
  PreparedInitEnvelopeKeyField -> "bootstrap_store.prepared_init_envelope_key"
  EncryptedInitResponseKeyField -> "bootstrap_store.encrypted_init_response_key"
  FinalUnlockBundleKeyField -> "bootstrap_store.final_unlock_bundle_key"
  ChildCustodyReceiptKeyField -> "bootstrap_store.child_custody_receipt_key"
  ChildRecoveryDeliveryKeyField -> "bootstrap_store.child_recovery_delivery_key"
  RootInitJournalKeyField -> "bootstrap_store.root_init_journal_key"
  RootSessionJournalKeyField -> "bootstrap_store.root_session_journal_key"
  ChildCustodyJournalKeyField -> "bootstrap_store.child_custody_journal_key"
  ChildRecoveryJournalKeyField -> "bootstrap_store.child_recovery_journal_key"
  PostUnsealHandoffKeyField -> "bootstrap_store.post_unseal_handoff_key"
  SecretWorkerCheckpointKeyField -> "bootstrap_store.secret_worker_checkpoint_key"

brokerLimitName :: BrokerLimitName -> String
brokerLimitName limitName = case limitName of
  QueueCapacityLimit -> "limits.queue_capacity"
  RequestBodyBytesLimit -> "limits.max_request_body_bytes"
  RequestDeadlineMillisecondsLimit -> "limits.request_deadline_milliseconds"
  DrainDeadlineMillisecondsLimit -> "limits.drain_deadline_milliseconds"

supportedBootstrapBrokerSchemaVersion :: Natural
supportedBootstrapBrokerSchemaVersion = 1

maximumBrokerQueueCapacity :: Natural
maximumBrokerQueueCapacity = 256

maximumBrokerRequestBodyBytes :: Natural
maximumBrokerRequestBodyBytes = 64 * 1024

maximumBrokerRequestDeadlineMilliseconds :: Natural
maximumBrokerRequestDeadlineMilliseconds = 5 * 60 * 1000

maximumBrokerDrainDeadlineMilliseconds :: Natural
maximumBrokerDrainDeadlineMilliseconds = 60 * 1000

validateBootstrapBrokerConfig
  :: BootstrapBrokerConfigDhall
  -> Either BootstrapBrokerSettingsError BootstrapBrokerSettings
validateBootstrapBrokerConfig config = do
  validateSchemaVersion (schemaVersion config)
  clusterId <- requireNonEmpty ClusterIdField (cluster_id config)
  vaultAddress <- requireNonEmpty VaultAddressField (vault_address config)
  serviceIdentity <- requireNonEmpty ServiceIdentityField (service_identity config)
  validatedListener <- validateListener (listener config)
  validatedStore <- validateStore (bootstrap_store config)
  validatedLimits <- validateLimits (limits config)
  Right
    BootstrapBrokerSettings
      { brokerSchemaVersion = supportedBootstrapBrokerSchemaVersion
      , brokerClusterId = clusterId
      , brokerVaultAddress = vaultAddress
      , brokerServiceIdentity = serviceIdentity
      , brokerListener = validatedListener
      , brokerBootstrapStore = validatedStore
      , brokerLimits = validatedLimits
      , brokerBurnRecipient = compiledBurnRecipient
      }

validateSchemaVersion :: Natural -> Either BootstrapBrokerSettingsError ()
validateSchemaVersion observed =
  if observed == supportedBootstrapBrokerSchemaVersion
    then Right ()
    else
      Left
        ( BrokerSchemaVersionMismatch
            supportedBootstrapBrokerSchemaVersion
            observed
        )

requireNonEmpty
  :: BrokerConfigField
  -> Text
  -> Either BootstrapBrokerSettingsError Text
requireNonEmpty field value =
  let stripped = Text.strip value
   in if Text.null stripped
        then Left (BrokerConfigFieldEmpty field)
        else Right stripped

validateListener
  :: BrokerListenerDhall
  -> Either BootstrapBrokerSettingsError BrokerListener
validateListener listenerDto = do
  address <- parseLoopbackAddress (listen_host listenerDto)
  port <- validateListenerPort (listen_port listenerDto)
  Right
    BrokerListener
      { brokerListenAddress = address
      , brokerListenPort = port
      }

parseLoopbackAddress :: Text -> Either BootstrapBrokerSettingsError LoopbackAddress
parseLoopbackAddress host = case host of
  "127.0.0.1" -> Right LoopbackIpv4
  "::1" -> Right LoopbackIpv6
  _ -> Left (BrokerListenerNotLoopback host)

validateListenerPort :: Natural -> Either BootstrapBrokerSettingsError Word16
validateListenerPort port =
  if port > 0 && port <= fromIntegral (maxBound :: Word16)
    then Right (fromIntegral port)
    else Left (BrokerListenerPortOutOfRange port)

validateStore
  :: BootstrapStoreDhall
  -> Either BootstrapBrokerSettingsError BootstrapStore
validateStore storeDto = do
  endpoint <- requireNonEmpty StoreEndpointField (store_endpoint storeDto)
  bucket <- requireNonEmpty StoreBucketField (store_bucket storeDto)
  generationKey <-
    requireNonEmpty
      VaultStorageGenerationKeyField
      (vault_storage_generation_key storeDto)
  fenceKey <-
    requireNonEmpty
      BootstrapSessionFenceKeyField
      (bootstrap_session_fence_key storeDto)
  preparedKey <-
    requireNonEmpty PreparedInitEnvelopeKeyField (prepared_init_envelope_key storeDto)
  responseKey <-
    requireNonEmpty EncryptedInitResponseKeyField (encrypted_init_response_key storeDto)
  bundleKey <-
    requireNonEmpty FinalUnlockBundleKeyField (final_unlock_bundle_key storeDto)
  custodyKey <-
    requireNonEmpty ChildCustodyReceiptKeyField (child_custody_receipt_key storeDto)
  recoveryKey <-
    requireNonEmpty ChildRecoveryDeliveryKeyField (child_recovery_delivery_key storeDto)
  rootInitJournal <-
    requireNonEmpty RootInitJournalKeyField (root_init_journal_key storeDto)
  rootSessionJournal <-
    requireNonEmpty RootSessionJournalKeyField (root_session_journal_key storeDto)
  childCustodyJournal <-
    requireNonEmpty ChildCustodyJournalKeyField (child_custody_journal_key storeDto)
  childRecoveryJournal <-
    requireNonEmpty ChildRecoveryJournalKeyField (child_recovery_journal_key storeDto)
  postUnsealHandoff <-
    requireNonEmpty PostUnsealHandoffKeyField (post_unseal_handoff_key storeDto)
  secretWorkerCheckpoint <-
    requireNonEmpty SecretWorkerCheckpointKeyField (secret_worker_checkpoint_key storeDto)
  let keys =
        [ generationKey
        , fenceKey
        , preparedKey
        , responseKey
        , bundleKey
        , custodyKey
        , recoveryKey
        , rootInitJournal
        , rootSessionJournal
        , childCustodyJournal
        , childRecoveryJournal
        , postUnsealHandoff
        , secretWorkerCheckpoint
        ]
  if length (nub keys) /= length keys
    then Left BrokerStorageKeysNotDistinct
    else
      Right
        BootstrapStore
          { bootstrapStoreEndpoint = endpoint
          , bootstrapStoreBucket = bucket
          , bootstrapStorageKeys =
              BootstrapStorageKeys
                { vaultStorageGenerationKey = generationKey
                , bootstrapSessionFenceKey = fenceKey
                , preparedInitEnvelopeKey = preparedKey
                , encryptedInitResponseKey = responseKey
                , finalUnlockBundleKey = bundleKey
                , childCustodyReceiptKey = custodyKey
                , childRecoveryDeliveryKey = recoveryKey
                , rootInitJournalKey = rootInitJournal
                , rootSessionJournalKey = rootSessionJournal
                , childCustodyJournalKey = childCustodyJournal
                , childRecoveryJournalKey = childRecoveryJournal
                , postUnsealHandoffKey = postUnsealHandoff
                , secretWorkerCheckpointKey = secretWorkerCheckpoint
                }
          }

validateLimits
  :: BrokerLimitsDhall
  -> Either BootstrapBrokerSettingsError BrokerLimits
validateLimits limitsDto = do
  queueCapacity <-
    validateLimit QueueCapacityLimit maximumBrokerQueueCapacity (queue_capacity limitsDto)
  requestBodyBytes <-
    validateLimit
      RequestBodyBytesLimit
      maximumBrokerRequestBodyBytes
      (max_request_body_bytes limitsDto)
  requestDeadline <-
    validateLimit
      RequestDeadlineMillisecondsLimit
      maximumBrokerRequestDeadlineMilliseconds
      (request_deadline_milliseconds limitsDto)
  drainDeadline <-
    validateLimit
      DrainDeadlineMillisecondsLimit
      maximumBrokerDrainDeadlineMilliseconds
      (drain_deadline_milliseconds limitsDto)
  Right
    BrokerLimits
      { brokerQueueCapacity = queueCapacity
      , brokerMaximumRequestBodyBytes = requestBodyBytes
      , brokerRequestDeadlineMilliseconds = requestDeadline
      , brokerDrainDeadlineMilliseconds = drainDeadline
      }

validateLimit
  :: BrokerLimitName
  -> Natural
  -> Natural
  -> Either BootstrapBrokerSettingsError Natural
validateLimit limitName maximumValue observed =
  if observed > 0 && observed <= maximumValue
    then Right observed
    else Left (BrokerLimitOutOfRange limitName maximumValue observed)

-- | Decode a Dhall expression and validate it into broker-only runtime settings.
decodeBootstrapBrokerConfigDhall
  :: Text
  -> IO (Either BootstrapBrokerSettingsError BootstrapBrokerSettings)
decodeBootstrapBrokerConfigDhall source = do
  decoded <- try (input auto source) :: IO (Either SomeException BootstrapBrokerConfigDhall)
  case decoded of
    Left err -> pure (Left (BrokerDhallDecodeFailed (displayException err)))
    Right config -> pure (validateBootstrapBrokerConfig config)

-- | Load exactly the supplied mounted Dhall file.  No environment/default-path
-- fallback is attempted.
loadBootstrapBrokerConfig
  :: FilePath
  -> IO (Either BootstrapBrokerSettingsError BootstrapBrokerSettings)
loadBootstrapBrokerConfig path = do
  decoded <- try (inputFile auto path) :: IO (Either SomeException BootstrapBrokerConfigDhall)
  case decoded of
    Left err ->
      pure
        ( Left
            ( BrokerDhallDecodeFailed
                ("`" ++ path ++ "`: " ++ displayException err)
            )
        )
    Right config -> pure (validateBootstrapBrokerConfig config)
