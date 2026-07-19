{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Prodbox.Settings
  ( AcmeSection (..)
  , AwsCredentialsRef (..)
  , AwsSubstrateSection (..)
  , CapacityBudget (..)
  , CapacitySection (..)
  , ClusterTopology
  , ConfigFile (..)
  , Credentials (..)
  , DeploymentSection (..)
  , DomainSection (..)
  , FailoverScenario (..)
  , FixtureId (..)
  , MetallbBgpPeer (..)
  , PulumiStateBackendSection (..)
  , Route53Section (..)
  , RunVariant (..)
  , SesSection (..)
  , StorageSection (..)
  , TestBudget (..)
  , TestSuite (..)
  , TestTopology (..)
  , TestTopologyError (..)
  , ValidatedSettings (..)
  , SeedInForceOutcome (..)
  , defaultConfigFile
  , defaultTestTopology
  , decodeConfigDhallBytes
  , inForceConfigObjectAbsent
  , loadConfigFile
  , loadConfigFileAtPath
  , loadTestTopology
  , loadTestTopologyAtPath
  , loadConfigForSettingsWith
  , loadUnencryptedBasics
  , loadUnencryptedBasicsAtPath
  , renderConfigDhall
  , renderSeedInForceOutcome
  , renderSettingsDisplay
  , resolveAwsCredentialsRefFromHostVault
  , seedInForceConfigFromFileWithToken
  , forceSyncInForceConfigFromFile
  , supportedPublicHostname
  , renderTestTopologyError
  , validateAwsBootstrapConfig
  , validateAndLoadSettings
  , validateAndLoadSettingsAtPath
  , validateAndLoadBootstrapSettings
  , validateAndLoadSettingsWithVaultToken
  , certDnsNamesForServedHost
  , certScopeSetForServedHost
  , validateConfiguredCertScope
  , validateOperationalAwsCredentials
  , validatePublicEdgeDeployment
  , validateTestTopology
  )
where

import Control.Exception (SomeException, displayException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (isDigit, isHexDigit, toLower)
import Data.Char qualified as Char
import Data.List (intercalate)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Void (Void)
import Dhall
  ( FromDhall (..)
  , InterpretOptions (..)
  , ToDhall (..)
  , auto
  , defaultInterpretOptions
  , genericAutoWith
  , genericToDhallWith
  , input
  , inputFile
  )
import Dhall qualified
import Dhall.Core qualified as Core
import Dhall.Src (Src)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Capacity.Config
  ( CapacityBudget (..)
  , CapacitySection (..)
  , NamespaceQuota (..)
  , ResourcePlan (..)
  , ResourceVector (..)
  , RuntimeMemoryProfile (..)
  , WorkloadResourceProfile (..)
  , defaultCapacitySection
  , resourceVectorMinus
  , validateCapacitySection
  )
import Prodbox.Cluster.Topology
  ( ClusterTopology
  , clusterType
  , defaultClusterTopology
  , renderClusterType
  , renderTopologyError
  , validateClusterTopology
  )
import Prodbox.Config.Basics
  ( UnencryptedBasics (..)
  )
import Prodbox.Config.ComponentGraph
  ( ComponentNode
  , defaultComponentGraph
  )
import Prodbox.Config.FloorDhall (loadUnencryptedBasics, loadUnencryptedBasicsAtPath)
import Prodbox.Config.InForce.Core
  ( ConfigSource (..)
  , SeedProposeDecision (..)
  , fetchInForceValueWith
  , renderInForceConfigError
  , seedProposeDecision
  , storeInForcePayloadWith
  )
import Prodbox.Http.Client (renderHttpError)
import Prodbox.Infra.MinioBackend (withMinioPortForward)
import Prodbox.Minio.EncryptedObject
  ( LogicalObject (LogicalInForceConfig)
  , objectKeyForOpaqueId
  , opaqueObjectId
  )
import Prodbox.Minio.ObjectStore
  ( ObjectStoreConfig (..)
  , defaultObjectStoreBucket
  , getObject
  , putObject
  )
import Prodbox.Repo
  ( ConfigPaths (..)
  , canonicalConfigPaths
  , resolveTestTopologyConfigPath
  , resolveTier0ConfigPath
  )
import Prodbox.Settings.SecretRef
  ( PromptSpec (..)
  , SecretRef (..)
  , VaultSecretRef (..)
  )
import Prodbox.Substrate
  ( ElasticScalingBounds (..)
  , ScalingPolicy (..)
  , ScalingPolicyBySubstrate (..)
  , fixedScalingPolicyBySubstrate
  , validateScalingPolicyBySubstrate
  )
import Prodbox.TestTopology
  ( FailoverScenario (..)
  , FixtureId (..)
  , RunVariant (..)
  , TestBudget (..)
  , TestSuite (..)
  , TestTopology (..)
  , TestTopologyError (..)
  , defaultTestTopology
  , renderTestTopologyError
  , validateTestTopology
  )
import Prodbox.Tls.CertScope
  ( CertScope (..)
  , CertScopeSet
  , bindListener
  , certScopeSetDnsNames
  , mkDelegatedZone
  , mkFqdn
  , mkScopeSet
  , renderScopeError
  )
import Prodbox.Vault.Client
  ( VaultAddress (..)
  , VaultToken
  , vaultKvReadV2
  )
import Prodbox.Vault.Host
  ( loadReadyVaultRootToken
  , readHostVaultKvField
  )
import Prodbox.Vault.Orchestration (clusterEstablishedMarkerPath)
import Prodbox.Vault.TransitCipher (vaultTransitDekCipher)
import System.Directory
  ( copyFile
  , doesFileExist
  , makeAbsolute
  )
import System.FilePath
  ( (</>)
  )
import System.IO.Temp (withSystemTempDirectory)

data Credentials = Credentials
  { access_key_id :: Text
  , secret_access_key :: Text
  , session_token :: Maybe Text
  , region :: Text
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data AwsCredentialsRef = AwsCredentialsRef
  { awsCredentialAccessKeyId :: SecretRef
  , awsCredentialSecretAccessKey :: SecretRef
  , awsCredentialSessionToken :: Maybe SecretRef
  , awsCredentialRegion :: Text
  }
  deriving (Eq, Show, Generic)

instance FromDhall AwsCredentialsRef where
  autoWith _ =
    genericAutoWith
      defaultInterpretOptions {fieldModifier = awsCredentialFieldModifier}
   where
    awsCredentialFieldModifier :: Text -> Text
    awsCredentialFieldModifier value =
      case Text.stripPrefix "awsCredential" value of
        Just stripped -> haskellCamelToDhallSnake stripped
        Nothing -> value

instance ToDhall AwsCredentialsRef where
  injectWith _ =
    genericToDhallWith
      defaultInterpretOptions {fieldModifier = awsCredentialFieldModifier}
   where
    awsCredentialFieldModifier :: Text -> Text
    awsCredentialFieldModifier value =
      case Text.stripPrefix "awsCredential" value of
        Just stripped -> haskellCamelToDhallSnake stripped
        Nothing -> value

data Route53Section = Route53Section
  { zone_id :: Text
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data AwsSubstrateSection = AwsSubstrateSection
  { hosted_zone_id :: Text
  , subzone_name :: Text
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data SesSection = SesSection
  { sender_domain :: Text
  , receive_subdomain :: Text
  , capture_bucket :: Text
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data DomainSection = DomainSection
  { demo_fqdn :: Text
  , demo_ttl :: Natural
  , cert_scopes :: [Text]
  -- ^ Sprint 2.35: the operator-configured certificate scope set, each entry an
  -- exact host (@vscode.example.com@) or a single-label wildcard (@*.example.com@)
  -- anchored at a delegated zone. Empty means "just the served host"
  -- ('demo_fqdn') — today's behavior — so widening scope is opt-in. Validated
  -- fail-closed by 'validateConfiguredCertScope': an uncovered served host or a
  -- wildcard at an undelegated zone is unrepresentable on the managed side.
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data MetallbBgpPeer = MetallbBgpPeer
  { peer_name :: Text
  , peer_address :: Text
  , peer_asn :: Natural
  , my_asn :: Natural
  , ebgp_multi_hop :: Maybe Bool
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data AcmeSection = AcmeSection
  { email :: Text
  , server :: Text
  , eab_key_id :: Maybe SecretRef
  , eab_hmac_key :: Maybe SecretRef
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data DeploymentSection = DeploymentSection
  { dev_mode :: Bool
  , bootstrap_public_ip_override :: Maybe Text
  , pulumi_enable_dns_bootstrap :: Bool
  , public_edge_advertisement_mode :: Maybe Text
  , public_edge_bgp_peers :: Maybe [MetallbBgpPeer]
  , envoy_gateway_controller_scaling :: ScalingPolicyBySubstrate
  , envoy_gateway_data_plane_scaling :: ScalingPolicyBySubstrate
  , api_scaling :: ScalingPolicyBySubstrate
  , websocket_scaling :: ScalingPolicyBySubstrate
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data StorageSection = StorageSection
  { manual_pv_host_root :: Text
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | Sprint 4.10: dedicated S3 bucket that backs long-lived Pulumi
-- stacks (today: @aws-ses@). Per-run stacks (@aws-eks@,
-- @aws-eks-subzone@, @aws-test@) continue using the in-cluster MinIO
-- backend; this record names the long-lived destination only. An
-- empty @bucket_name@ means the operator has not yet provisioned the
-- long-lived backend, and long-lived Pulumi operations remain on the
-- legacy MinIO backend until the migration command runs.
--
-- The Haskell field names carry a @psb@ prefix to avoid collision
-- with @Credentials.region@; a custom 'FromDhall' instance strips the
-- prefix so the Dhall config keeps bare field names
-- (@bucket_name@, @region@, @key_prefix@).
data PulumiStateBackendSection = PulumiStateBackendSection
  { psbBucketName :: Text
  , psbRegion :: Text
  , psbKeyPrefix :: Text
  }
  deriving (Eq, Show, Generic)

instance FromDhall PulumiStateBackendSection where
  autoWith _ =
    genericAutoWith
      defaultInterpretOptions {fieldModifier = stripPsbPrefix}
   where
    stripPsbPrefix :: Text -> Text
    stripPsbPrefix value = case Text.stripPrefix "psb" value of
      Just stripped -> haskellCamelToDhallSnake stripped
      Nothing -> value

instance ToDhall PulumiStateBackendSection where
  injectWith _ =
    genericToDhallWith
      defaultInterpretOptions {fieldModifier = stripPsbPrefix}
   where
    stripPsbPrefix :: Text -> Text
    stripPsbPrefix value = case Text.stripPrefix "psb" value of
      Just stripped -> haskellCamelToDhallSnake stripped
      Nothing -> value

haskellCamelToDhallSnake :: Text -> Text
haskellCamelToDhallSnake value =
  Text.toLower
    ( Text.concat
        [ if i > 0 && Char.isUpper c
            then Text.pack ['_', c]
            else Text.singleton c
        | (i :: Int, c) <- zip [0 ..] (Text.unpack value)
        ]
    )

data ConfigFile = ConfigFile
  { aws :: AwsCredentialsRef
  , route53 :: Route53Section
  , aws_substrate :: AwsSubstrateSection
  , ses :: SesSection
  , domain :: DomainSection
  , acme :: AcmeSection
  , deployment :: DeploymentSection
  , capacity :: CapacitySection
  , cluster_topology :: ClusterTopology
  , storage :: StorageSection
  , pulumi_state_backend :: PulumiStateBackendSection
  , components :: [ComponentNode]
  -- ^ Sprint 1.56: the Tier-0 component dependency/readiness graph that
  -- bootstrap ordering is projected from
  -- (bootstrap_readiness_doctrine.md M2). Non-secret; validated by
  -- 'Prodbox.Config.ComponentGraph.validateComponentGraph' when projected.
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data ValidatedSettings = ValidatedSettings
  { validatedConfig :: ConfigFile
  , resolvedManualPvHostRoot :: FilePath
  }
  deriving (Eq, Show)

supportedPublicHostname :: Text
supportedPublicHostname = "test.resolvefintech.com"

validateAndLoadSettings :: FilePath -> IO (Either String ValidatedSettings)
validateAndLoadSettings repoRoot = do
  configResult <- loadConfigForSettingsWith (loadRuntimeInForceConfig repoRoot) repoRoot
  case configResult of
    Left err -> pure (Left err)
    Right config -> validateConfig repoRoot config

-- | Validate + load settings from a Tier-0 config at an EXPLICIT prodbox.dhall
-- path, resolving repo-relative fields (the manual PV root) against @repoRoot@.
-- This is the path-injection seam in-process unit tests exercise directly;
-- production 'validateAndLoadSettings' resolves the binary-sibling config and
-- consults the established-marker / in-force SSoT. Sprint 1.48.
validateAndLoadSettingsAtPath
  :: FilePath -> FilePath -> IO (Either String ValidatedSettings)
validateAndLoadSettingsAtPath configPath repoRoot = do
  configResult <- loadConfigFileAtPath configPath
  case configResult of
    Left err -> pure (Left err)
    Right config -> validateConfig repoRoot config

-- | Lifecycle bootstrap settings are the repository Dhall seed/propose input.
-- Use this only for the pre-Vault/pre-MinIO steps that cannot read the
-- encrypted in-force config yet.
validateAndLoadBootstrapSettings :: FilePath -> IO (Either String ValidatedSettings)
validateAndLoadBootstrapSettings repoRoot = do
  configResult <- loadConfigFile repoRoot
  case configResult of
    Left err -> pure (Left err)
    Right config -> validateConfig repoRoot config

validateAndLoadSettingsWithVaultToken
  :: FilePath -> VaultToken -> IO (Either String ValidatedSettings)
validateAndLoadSettingsWithVaultToken repoRoot token = do
  configResult <-
    loadConfigForSettingsWith (loadRuntimeInForceConfigWithToken repoRoot token) repoRoot
  case configResult of
    Left err -> pure (Left err)
    Right config -> validateConfig repoRoot config

-- | Resolve the config source for supported host settings loads. Without a
-- sealed-Vault basics floor (no Tier-0 @prodbox.dhall@ to project it from), the
-- filesystem Dhall remains the first-bring-up seed input. Once a floor exists,
-- the filesystem file is no longer authoritative: the caller-supplied in-force
-- loader must fetch and decrypt the MinIO SSoT.
--
-- Sprint 7.18: the floor is projected straight off @prodbox.dhall@ (via
-- 'Prodbox.Config.FloorDhall.loadUnencryptedBasics') — there is no separate
-- derived @prodbox-basics.json@ artifact. A floor read that fails because the
-- Tier-0 @prodbox.dhall@ is absent means the cluster is not yet established, so
-- the filesystem seed is the right fallback.
loadConfigForSettingsWith
  :: (UnencryptedBasics -> IO (Either String ConfigFile))
  -> FilePath
  -> IO (Either String ConfigFile)
loadConfigForSettingsWith loadInForce repoRoot = do
  basicsResult <- loadUnencryptedBasics repoRoot
  case basicsResult of
    -- No Tier-0 prodbox.dhall floor at all: the cluster is not configured.
    -- 'loadConfigFile' surfaces the actionable "run config setup" message.
    Left _ -> loadConfigFile repoRoot
    Right basics -> do
      -- Sprint 1.42 Part B / Sprint 7.25: the "established" signal is the
      -- presence of the NON-SECRET cluster-established marker, stamped on host
      -- disk at first-ever @vault init@. Before establishment — first-ever
      -- bring-up, and every host integration test with no real cluster — there
      -- is no marker, so the in-force SSoT cannot exist yet: read the
      -- operator-authored Tier-0 @prodbox.dhall@ @parameters@ directly (the
      -- seed/pre-establishment source). This is NOT a fallback for a sealed
      -- Vault. (Sprint 7.25 made the unlock bundle MinIO-only; this cheap,
      -- port-forward-free probe uses the marker instead of the former on-disk
      -- bundle file.)
      established <- doesFileExist (clusterEstablishedMarkerPath repoRoot)
      if not established
        then loadConfigFile repoRoot
        else do
          inForceResult <- loadInForce basics
          case inForceResult of
            Right config -> pure (Right config)
            Left err
              -- The cluster IS established but the in-force SSoT object was not
              -- seeded yet (the brief window between @vault init@ and the
              -- first-bring-up seed): read the Tier-0 @parameters@ seed. Every
              -- OTHER in-force error — a sealed or unreachable Vault, a decrypt
              -- failure — is returned as-is: per the fail-closed doctrine the
              -- cluster simply cannot read its config (it keeps running), with
              -- NO fallback to the authored @parameters@ (operator decision
              -- 2026-06-19).
              | inForceConfigObjectAbsent err -> loadConfigFile repoRoot
              | otherwise -> pure (Left err)

-- | True when an in-force config load failed specifically because the SSoT
-- object is absent from MinIO (not yet seeded), as distinct from a sealed
-- Vault, an unreachable backend, or a decrypt failure — which must stay
-- fail-closed. Mirrors the 'in-force config object missing' surface emitted by
-- 'fetchInForceConfigEnvelope'.
inForceConfigObjectAbsent :: String -> Bool
inForceConfigObjectAbsent err =
  Text.isInfixOf "in-force config object missing" (Text.pack err)

loadRuntimeInForceConfig :: FilePath -> UnencryptedBasics -> IO (Either String ConfigFile)
loadRuntimeInForceConfig repoRoot basics = do
  let address = VaultAddress (basicsVaultAddress basics)
  tokenResult <- loadReadyVaultRootToken repoRoot address
  case tokenResult of
    Left err -> pure (Left err)
    Right token -> loadRuntimeInForceConfigWithToken repoRoot token basics

loadRuntimeInForceConfigWithToken
  :: FilePath -> VaultToken -> UnencryptedBasics -> IO (Either String ConfigFile)
loadRuntimeInForceConfigWithToken repoRoot token basics = do
  let address = VaultAddress (basicsVaultAddress basics)
  credentialsResult <- readMinioRootCredentials address token
  case credentialsResult of
    Left err -> pure (Left err)
    Right (accessKey, secretKey) -> do
      hmacKeyResult <- readObjectStoreHmacKey address token
      case hmacKeyResult of
        Left err -> pure (Left err)
        Right hmacKey -> do
          let cipher = vaultTransitDekCipher address token "prodbox-active-config"
          portForwardResult <-
            withMinioPortForward $ \localPort ->
              fetchInForceValueWith
                ( fetchInForceConfigEnvelope
                    localPort
                    (Text.unpack accessKey)
                    (Text.unpack secretKey)
                    hmacKey
                )
                cipher
                (basicsClusterId basics)
                (decodeConfigDhallBytes repoRoot)
          pure $ case portForwardResult of
            Left err -> Left ("failed to reach in-force config MinIO backend: " ++ err)
            Right result -> mapLeft renderInForceConfigError result

readMinioRootCredentials :: VaultAddress -> VaultToken -> IO (Either String (Text, Text))
readMinioRootCredentials address token = do
  result <- vaultKvReadV2 address token "secret" "minio/root"
  pure $ case result of
    Left err -> Left ("failed to read secret/minio/root from Vault: " ++ renderHttpError err)
    Right fields -> do
      accessKey <- requireVaultField "secret/minio/root" "rootUser" fields
      secretKey <- requireVaultField "secret/minio/root" "rootPassword" fields
      Right (accessKey, secretKey)

readObjectStoreHmacKey :: VaultAddress -> VaultToken -> IO (Either String ByteString)
readObjectStoreHmacKey address token = do
  result <- vaultKvReadV2 address token "secret" "object-store/hmac"
  pure $ case result of
    Left err -> Left ("failed to read secret/object-store/hmac from Vault: " ++ renderHttpError err)
    Right fields -> TextEncoding.encodeUtf8 <$> requireVaultField "secret/object-store/hmac" "key" fields

fetchInForceConfigEnvelope
  :: Int
  -> String
  -> String
  -> ByteString
  -> IO (Either String ByteString)
fetchInForceConfigEnvelope localPort accessKey secretKey hmacKey = do
  let key = objectKeyForOpaqueId (opaqueObjectId hmacKey LogicalInForceConfig)
      config =
        ObjectStoreConfig
          { objectStoreEndpoint = "http://127.0.0.1:" ++ show localPort
          , objectStoreBucket = defaultObjectStoreBucket
          , objectStoreAccessKey = accessKey
          , objectStoreSecretKey = secretKey
          }
  result <- getObject config key
  pure $ case result of
    Left err -> Left err
    Right Nothing -> Left ("in-force config object missing at " ++ Text.unpack key)
    Right (Just envelope) -> Right envelope

-- | Sprint 1.42 PART A: the outcome of the in-force MinIO SSoT seed step, so
-- the reconcile can log precisely what happened. Seeding is the establish step;
-- it is a no-op once the SSoT exists or when there is no filesystem seed.
data SeedInForceOutcome
  = -- | The SSoT object was absent and the filesystem operator config was
    -- present, so the operator config was sealed and written as the SSoT
    -- ('SeedProposeDecision.SeedInForce').
    SeededInForce
  | -- | The SSoT object already exists; the seed is a no-op
    -- ('SeedProposeDecision.UseInForceAsIs').
    InForceAlreadyPresent
  | -- | Both the SSoT object and a filesystem operator config exist; the file
    -- is a proposed update, which PART A does not auto-apply
    -- ('SeedProposeDecision.ProposeUpdate').
    InForceProposeUpdateSkipped
  | -- | Neither the SSoT object nor a filesystem operator config is available;
    -- there is nothing to seed ('SeedProposeDecision.NoConfigAvailable').
    NoConfigToSeed
  deriving (Eq, Show)

renderSeedInForceOutcome :: SeedInForceOutcome -> String
renderSeedInForceOutcome outcome = case outcome of
  SeededInForce ->
    "Seeded the in-force config SSoT in MinIO from the filesystem operator config."
  InForceAlreadyPresent ->
    "In-force config SSoT already present in MinIO; seed is a no-op."
  InForceProposeUpdateSkipped ->
    "In-force config SSoT present and a filesystem config exists; the file is a"
      ++ " proposed update (not auto-applied)."
  NoConfigToSeed ->
    "No in-force config SSoT and no filesystem operator config; nothing to seed."

-- | Sprint 1.42 PART A: establish the in-force MinIO SSoT on first-ever
-- bring-up. Mirrors the read path 'loadRuntimeInForceConfigWithToken' exactly —
-- same Vault-derived MinIO root credentials ('readMinioRootCredentials'), same
-- HMAC key ('readObjectStoreHmacKey'), same MinIO port-forward
-- ('withMinioPortForward'), same Vault-Transit DEK cipher
-- (@prodbox-active-config@), same opaque object key
-- (@objectKeyForOpaqueId . opaqueObjectId@ over 'LogicalInForceConfig') — but
-- it GETs to observe presence and then PUTs the sealed operator config envelope
-- instead of GETting to read.
--
-- The seed decision is 'seedProposeDecision': SSoT-absent + file-present ⇒
-- 'SeedInForce' (seal + write); SSoT-present ⇒ 'UseInForceAsIs' / 'ProposeUpdate'
-- (no-op, PART A never auto-applies a proposed update); both absent ⇒
-- 'NoConfigAvailable' (no-op). The sealed envelope is the same shape the read
-- path decodes back to the identical 'ConfigFile' (unit-tested round-trip).
seedInForceConfigFromFileWithToken
  :: FilePath -> VaultToken -> UnencryptedBasics -> IO (Either String SeedInForceOutcome)
seedInForceConfigFromFileWithToken repoRoot token basics = do
  let address = VaultAddress (basicsVaultAddress basics)
  credentialsResult <- readMinioRootCredentials address token
  case credentialsResult of
    Left err -> pure (Left err)
    Right (accessKey, secretKey) -> do
      hmacKeyResult <- readObjectStoreHmacKey address token
      case hmacKeyResult of
        Left err -> pure (Left err)
        Right hmacKey -> do
          let cipher = vaultTransitDekCipher address token "prodbox-active-config"
              key = objectKeyForOpaqueId (opaqueObjectId hmacKey LogicalInForceConfig)
          portForwardResult <-
            withMinioPortForward $ \localPort -> do
              let storeConfig =
                    ObjectStoreConfig
                      { objectStoreEndpoint = "http://127.0.0.1:" ++ show localPort
                      , objectStoreBucket = defaultObjectStoreBucket
                      , objectStoreAccessKey = Text.unpack accessKey
                      , objectStoreSecretKey = Text.unpack secretKey
                      }
              -- Observe SSoT presence the same way the read path does (GET the
              -- opaque key); a present object short-circuits the seal.
              presenceResult <- getObject storeConfig key
              case presenceResult of
                Left err -> pure (Left ("failed to observe in-force config SSoT: " ++ err))
                Right inForcePresence -> do
                  fileResult <- loadConfigFile repoRoot
                  let inForcePresent = maybe False (const True) inForcePresence
                      filePresent = either (const False) (const True) fileResult
                      source =
                        ConfigSource
                          { configSourceFilePresent = filePresent
                          , configSourceInForcePresent = inForcePresent
                          }
                  case seedProposeDecision source of
                    SeedInForce ->
                      case fileResult of
                        Left err ->
                          -- Should not happen (filePresent implies a Right),
                          -- but stay total and fail-closed if the file vanished.
                          pure (Left ("failed to load filesystem operator config to seed SSoT: " ++ err))
                        Right config -> do
                          storeResult <-
                            storeInForcePayloadWith
                              (putObject storeConfig key)
                              cipher
                              (basicsClusterId basics)
                              (renderInForceSeedPayload config)
                          pure $ case storeResult of
                            Left err -> Left (renderInForceConfigError err)
                            Right () -> Right SeededInForce
                    UseInForceAsIs -> pure (Right InForceAlreadyPresent)
                    ProposeUpdate -> pure (Right InForceProposeUpdateSkipped)
                    NoConfigAvailable -> pure (Right NoConfigToSeed)
          pure $ case portForwardResult of
            Left err -> Left ("failed to reach in-force config MinIO backend: " ++ err)
            Right result -> result

-- | Sprint 5.10 follow-up: FORCE-apply the binary-sibling operator config to the
-- in-force MinIO SSoT. The test harness OWNS the test cluster's config, so —
-- unlike 'seedInForceConfigFromFileWithToken', which never auto-applies a
-- proposed update on an established cluster (@ProposeUpdate@ is a no-op) — this
-- UNCONDITIONALLY re-seals the binary-sibling config into the in-force SSoT,
-- keeping the edge reconcile (which reads the in-force SSoT, not the
-- binary-sibling file) in sync with the config the harness regenerated and the
-- preflight validated. Best-effort + graceful: a no-op @Right ()@ when the
-- cluster is not established (no Tier-0 floor), when Vault is sealed/unreachable
-- (a fresh cluster seeds from the file on first reconcile instead), or when no
-- binary-sibling config exists; @Left@ only on a genuine MinIO write failure.
forceSyncInForceConfigFromFile :: FilePath -> IO (Either String ())
forceSyncInForceConfigFromFile repoRoot = do
  basicsResult <- loadUnencryptedBasics repoRoot
  case basicsResult of
    Left _ -> pure (Right ())
    Right basics -> do
      let address = VaultAddress (basicsVaultAddress basics)
      tokenResult <- loadReadyVaultRootToken repoRoot address
      case tokenResult of
        Left _ -> pure (Right ())
        Right token -> do
          configResult <- loadConfigFile repoRoot
          case configResult of
            Left _ -> pure (Right ())
            Right config -> forceStoreInForceConfigWithToken token basics config

-- | The unconditional in-force seal+write — the force analog of the
-- @SeedInForce@ branch of 'seedInForceConfigFromFileWithToken' (same
-- Vault-derived MinIO credentials, HMAC key, Transit DEK cipher, opaque object
-- key, and payload shape), but with no presence/decision gate. Sprint 5.10.
forceStoreInForceConfigWithToken
  :: VaultToken -> UnencryptedBasics -> ConfigFile -> IO (Either String ())
forceStoreInForceConfigWithToken token basics config = do
  let address = VaultAddress (basicsVaultAddress basics)
  credentialsResult <- readMinioRootCredentials address token
  case credentialsResult of
    Left err -> pure (Left err)
    Right (accessKey, secretKey) -> do
      hmacKeyResult <- readObjectStoreHmacKey address token
      case hmacKeyResult of
        Left err -> pure (Left err)
        Right hmacKey -> do
          let cipher = vaultTransitDekCipher address token "prodbox-active-config"
              key = objectKeyForOpaqueId (opaqueObjectId hmacKey LogicalInForceConfig)
          portForwardResult <-
            withMinioPortForward $ \localPort -> do
              let storeConfig =
                    ObjectStoreConfig
                      { objectStoreEndpoint = "http://127.0.0.1:" ++ show localPort
                      , objectStoreBucket = defaultObjectStoreBucket
                      , objectStoreAccessKey = Text.unpack accessKey
                      , objectStoreSecretKey = Text.unpack secretKey
                      }
              storeInForcePayloadWith
                (putObject storeConfig key)
                cipher
                (basicsClusterId basics)
                (renderInForceSeedPayload config)
          pure $ case portForwardResult of
            Left err -> Left ("failed to reach in-force config MinIO backend: " ++ err)
            Right (Left err) -> Left (renderInForceConfigError err)
            Right (Right ()) -> Right ()

-- | Serialize a 'ConfigFile' to its in-force payload bytes (the same Dhall text
-- the read path decodes via 'decodeConfigDhallBytes'). Mirrors
-- 'Prodbox.Config.InForce.renderInForcePayload' without importing it (that
-- module depends on this one).
renderInForceSeedPayload :: ConfigFile -> ByteString
renderInForceSeedPayload = TextEncoding.encodeUtf8 . Text.pack . renderConfigDhall

requireVaultField :: Text -> Text -> Map.Map Text Text -> Either String Text
requireVaultField path field fields =
  case Map.lookup field fields of
    Nothing -> Left ("Vault KV object " ++ Text.unpack path ++ " missing field `" ++ Text.unpack field ++ "`")
    Just value
      | Text.null (Text.strip value) ->
          Left ("Vault KV object " ++ Text.unpack path ++ " field `" ++ Text.unpack field ++ "` is empty")
      | otherwise -> Right value

resolveAwsCredentialsRefFromHostVault
  :: FilePath -> String -> AwsCredentialsRef -> IO (Either String Credentials)
resolveAwsCredentialsRefFromHostVault repoRoot label refs = do
  accessKeyResult <- resolveRequiredSecret "access_key_id" (awsCredentialAccessKeyId refs)
  secretKeyResult <- resolveRequiredSecret "secret_access_key" (awsCredentialSecretAccessKey refs)
  sessionTokenResult <- resolveOptionalSecret "session_token" (awsCredentialSessionToken refs)
  pure $ do
    accessKey <- accessKeyResult
    secretKey <- secretKeyResult
    sessionTokenValue <- sessionTokenResult
    let regionValue = Text.strip (awsCredentialRegion refs)
    if Text.null regionValue
      then Left (label ++ ".region must not be empty")
      else
        Right
          Credentials
            { access_key_id = accessKey
            , secret_access_key = secretKey
            , session_token = sessionTokenValue
            , region = regionValue
            }
 where
  resolveRequiredSecret
    :: String -> SecretRef -> IO (Either String Text)
  resolveRequiredSecret field ref = do
    result <- resolveHostSecretRef field ref
    pure $ case result of
      Left err -> Left err
      Right value
        | Text.null (Text.strip value) ->
            Left (label ++ "." ++ field ++ " resolved from Vault as empty")
        | otherwise -> Right (Text.strip value)

  resolveOptionalSecret
    :: String -> Maybe SecretRef -> IO (Either String (Maybe Text))
  resolveOptionalSecret _ Nothing = pure (Right Nothing)
  resolveOptionalSecret field (Just ref) = do
    result <- resolveHostSecretRef field ref
    pure $ case result of
      Left err -> Left err
      Right value -> Right (normalizeOptionalText value)

  resolveHostSecretRef :: String -> SecretRef -> IO (Either String Text)
  resolveHostSecretRef field ref =
    case ref of
      SecretRefVault resolvedVaultRef ->
        readHostVaultKvField
          repoRoot
          (vaultSecretMount resolvedVaultRef)
          (vaultSecretPath resolvedVaultRef)
          (vaultSecretField resolvedVaultRef)
      SecretRefTestPlaintext _ ->
        pure
          ( Left
              ( label
                  ++ "."
                  ++ field
                  ++ ": plaintext secret values are forbidden in production config; use a SecretRef.Vault reference"
              )
          )
      SecretRefTransitKey _ ->
        pure (Left (label ++ "." ++ field ++ ": TransitKey references are not readable AWS credentials"))
      SecretRefPrompt spec ->
        pure
          ( Left
              ( label
                  ++ "."
                  ++ field
                  ++ ": prompted secret "
                  ++ Text.unpack (promptSpecName spec)
                  ++ " cannot be resolved non-interactively"
              )
          )

renderSettingsDisplay :: ValidatedSettings -> String
renderSettingsDisplay settings =
  unlines
    [ "aws.region=" ++ renderText (awsCredentialRegion (aws config))
    , "aws.access_key_id=" ++ renderSecretRefDisplay (awsCredentialAccessKeyId (aws config))
    , "aws.secret_access_key=" ++ renderSecretRefDisplay (awsCredentialSecretAccessKey (aws config))
    , "aws.session_token=" ++ renderMaybeSecretRefDisplay (awsCredentialSessionToken (aws config))
    , "route53.zone_id=" ++ renderText (zone_id (route53 config))
    , "aws_substrate.hosted_zone_id=" ++ renderText (hosted_zone_id (aws_substrate config))
    , "aws_substrate.subzone_name=" ++ renderText (subzone_name (aws_substrate config))
    , "ses.sender_domain=" ++ renderText (sender_domain (ses config))
    , "ses.receive_subdomain=" ++ renderText (receive_subdomain (ses config))
    , "ses.capture_bucket=" ++ renderText (capture_bucket (ses config))
    , "domain.demo_fqdn=" ++ renderText (demo_fqdn (domain config))
    , "domain.demo_ttl=" ++ show (demo_ttl (domain config))
    , "acme.email=" ++ renderSensitive (email (acme config))
    , "acme.server=" ++ renderText (server (acme config))
    , "acme.eab_key_id=" ++ renderMaybeSecretRefDisplay (eab_key_id (acme config))
    , "acme.eab_hmac_key=" ++ renderMaybeSecretRefDisplay (eab_hmac_key (acme config))
    , "deployment.dev_mode=" ++ renderBool (dev_mode (deployment config))
    , "deployment.bootstrap_public_ip_override="
        ++ renderMaybeText (bootstrap_public_ip_override (deployment config))
    , "deployment.pulumi_enable_dns_bootstrap="
        ++ renderBool (pulumi_enable_dns_bootstrap (deployment config))
    , "deployment.public_edge_advertisement_mode="
        ++ renderMaybeText (public_edge_advertisement_mode (deployment config))
    , "deployment.public_edge_bgp_peers=" ++ renderBgpPeers (public_edge_bgp_peers (deployment config))
    , "deployment.envoy_gateway_controller_scaling="
        ++ renderScalingPolicyBySubstrate (envoy_gateway_controller_scaling (deployment config))
    , "deployment.envoy_gateway_data_plane_scaling="
        ++ renderScalingPolicyBySubstrate (envoy_gateway_data_plane_scaling (deployment config))
    , "deployment.api_scaling=" ++ renderScalingPolicyBySubstrate (api_scaling (deployment config))
    , "deployment.websocket_scaling="
        ++ renderScalingPolicyBySubstrate (websocket_scaling (deployment config))
    , "capacity.node_budget=" ++ renderCapacityBudget (node_budget (capacity config))
    , "capacity.workload_budget=" ++ renderCapacityBudget (workload_budget (capacity config))
    , "capacity.region_quota=" ++ renderCapacityBudget (region_quota (capacity config))
    , "capacity.resource_plan.host_capacity="
        ++ renderResourceVector (host_capacity (resource_plan (capacity config)))
    , "capacity.resource_plan.rke2_reserved="
        ++ renderResourceVector (rke2_reserved (resource_plan (capacity config)))
    , "capacity.resource_plan.eviction_floor="
        ++ renderResourceVector (eviction_floor (resource_plan (capacity config)))
    , "capacity.resource_plan.cluster_allocatable="
        ++ renderResourceVector (clusterAllocatable (resource_plan (capacity config)))
    , "capacity.resource_plan.namespace_quotas="
        ++ renderNamespaceQuotas (namespace_quotas (resource_plan (capacity config)))
    , "capacity.resource_plan.workload_profiles="
        ++ renderWorkloadProfiles (workload_profiles (resource_plan (capacity config)))
    , "capacity.runtime_memory_profiles="
        ++ renderRuntimeMemoryProfiles (runtime_memory_profiles (capacity config))
    , "cluster_topology.type=" ++ renderClusterType (clusterType (cluster_topology config))
    , "storage.manual_pv_host_root=" ++ resolvedManualPvHostRoot settings
    , "pulumi_state_backend.bucket_name="
        ++ renderText (psbBucketName (pulumi_state_backend config))
    , "pulumi_state_backend.region="
        ++ renderText (psbRegion (pulumi_state_backend config))
    , "pulumi_state_backend.key_prefix="
        ++ renderText (psbKeyPrefix (pulumi_state_backend config))
    ]
 where
  config = validatedConfig settings

-- | Decode a @ConfigFile@-shaped Dhall file directly at @configPath@. The file
-- is a @prodbox-config.dhall@-shaped record (a @let Config = ./prodbox-config-types.dhall@
-- body) sitting beside its schema. This is the in-force SSoT payload decoder
-- ('decodeConfigDhallBytes'); the repository-root operator config is read from
-- the Tier-0 @prodbox.dhall@ by 'loadConfigFile' instead (Sprint 1.42 Part B).
decodeConfigFileAtPath :: FilePath -> IO (Either String ConfigFile)
decodeConfigFileAtPath configPath = do
  configExists <- doesFileExist configPath
  if not configExists
    then pure (Left (missingConfigMessage configPath))
    else do
      result <- try (inputFile auto configPath)
      pure $ case result of
        Left (e :: SomeException) ->
          Left
            ( "Failed to decode Dhall config `"
                ++ configPath
                ++ "`: "
                ++ displayException e
            )
        Right config -> Right config

-- | Sprint 1.42 Part B: the operator's non-secret config is read from the
-- Tier-0 @prodbox.dhall@'s @parameters@ sub-record (structurally a 'ConfigFile'),
-- retiring the standalone @prodbox-config.dhall@ seed/propose file. The decode
-- projects @( <abs prodbox.dhall> ).parameters@ via a Dhall field-access
-- expression so this stays in "Prodbox.Settings" without importing
-- "Prodbox.Config.Tier0" (which imports this module). All existing
-- 'loadConfigFile' callers (the seed, the pre-establishment fallback in
-- 'loadConfigForSettingsWith', the direct config readers, and the authoring
-- read in 'loadConfigForWrite') therefore now read the Tier-0 file.
loadConfigFile :: FilePath -> IO (Either String ConfigFile)
loadConfigFile repoRoot = resolveTier0ConfigPath repoRoot >>= loadConfigFileAtPath

-- | Decode and validate the executable-sibling @prodbox.test.dhall@. This is
-- the authored test-run SSoT from test_topology_doctrine.md. It is deliberately
-- separate from 'loadConfigFile': production fails when @prodbox.dhall@ is
-- absent, while the test runner preflight refuses when that production sibling
-- is present.
loadTestTopology :: FilePath -> IO (Either String TestTopology)
loadTestTopology repoRoot = resolveTestTopologyConfigPath repoRoot >>= loadTestTopologyAtPath

loadTestTopologyAtPath :: FilePath -> IO (Either String TestTopology)
loadTestTopologyAtPath testTopologyPath = do
  testTopologyExists <- doesFileExist testTopologyPath
  if not testTopologyExists
    then pure (Left (missingTestTopologyMessage testTopologyPath))
    else do
      result <- try (inputFile auto testTopologyPath)
      pure $ case result of
        Left (e :: SomeException) ->
          Left
            ( "Failed to decode test topology `"
                ++ testTopologyPath
                ++ "`: "
                ++ displayException e
            )
        Right topology ->
          case validateTestTopology topology of
            Left err ->
              Left
                ( "Invalid test topology `"
                    ++ testTopologyPath
                    ++ "`: "
                    ++ renderTestTopologyError err
                )
            Right () -> Right topology

-- | Decode the operator config from the @parameters@ of a Tier-0 prodbox.dhall
-- at an EXPLICIT path. 'loadConfigFile' resolves the binary-sibling path
-- ('resolveTier0ConfigPath') and delegates here; this is the path-injection
-- seam in-process unit tests exercise directly (the binary-sibling resolution
-- itself is proven by the integration suites). Sprint 1.48.
loadConfigFileAtPath :: FilePath -> IO (Either String ConfigFile)
loadConfigFileAtPath tier0Path = do
  tier0Exists <- doesFileExist tier0Path
  if not tier0Exists
    then pure (Left (missingConfigMessage tier0Path))
    else do
      absPath <- makeAbsolute tier0Path
      let expr = "( " <> Text.pack absPath <> " ).parameters"
      result <- try (input auto expr)
      pure $ case result of
        Left (e :: SomeException) ->
          Left
            ( "Failed to decode Tier-0 prodbox.dhall `parameters` from `"
                ++ tier0Path
                ++ "`: "
                ++ displayException e
            )
        Right config -> Right config

-- | Decode in-force config payload bytes as Dhall, preserving the repository
-- import contract by materializing the payload beside
-- @prodbox-config-types.dhall@ before calling the same Dhall decoder as
-- 'loadConfigFile'.
decodeConfigDhallBytes :: FilePath -> ByteString -> IO (Either String ConfigFile)
decodeConfigDhallBytes repoRoot payload =
  withSystemTempDirectory "prodbox-in-force-config" $ \tmpDir -> do
    let paths = canonicalConfigPaths repoRoot
        schemaPath = configSchemaPath paths
        tmpSchemaPath = tmpDir </> "prodbox-config-types.dhall"
        tmpConfigPath = tmpDir </> "prodbox-config.dhall"
    schemaCopyResult <- try (copyFile schemaPath tmpSchemaPath) :: IO (Either SomeException ())
    case schemaCopyResult of
      Left err ->
        pure
          ( Left
              ( "Failed to prepare Dhall schema for in-force config decode `"
                  ++ schemaPath
                  ++ "`: "
                  ++ displayException err
              )
          )
      Right () -> do
        payloadWriteResult <- try (BS.writeFile tmpConfigPath payload) :: IO (Either SomeException ())
        case payloadWriteResult of
          Left err ->
            pure
              ( Left
                  ( "Failed to materialize in-force config payload `"
                      ++ tmpConfigPath
                      ++ "`: "
                      ++ displayException err
                  )
              )
          Right () -> decodeConfigFileAtPath tmpConfigPath

validateConfig :: FilePath -> ConfigFile -> IO (Either String ValidatedSettings)
validateConfig repoRoot config = do
  resolvedManualRoot <- makeAbsolute (repoRoot </> Text.unpack (manual_pv_host_root (storage config)))
  pure $ do
    -- Local commands (cluster, charts, host, config, gateway) decode and
    -- validate config WITHOUT requiring operational AWS credentials or the
    -- Route 53 / ACME public-edge fields. Those belong to the AWS / edge
    -- tier ('validateAwsBootstrapConfig' / 'validateOperationalAwsCredentials')
    -- and are validated lazily only when a command actually reaches AWS.
    validateLocalConfig config
    pure
      ValidatedSettings
        { validatedConfig = config
        , resolvedManualPvHostRoot = resolvedManualRoot
        }

-- | Purely-local config invariants: the supported public hostname, the
-- demo TTL bounds, the operational @aws.*@ SecretRef shape, and the
-- public-edge deployment knobs. No operational AWS credentials, Route 53
-- zone, or ACME account are required here, so a host with an empty @aws.*@
-- block still decodes config for every local cluster command.
validateLocalConfig :: ConfigFile -> Either String ()
validateLocalConfig config = do
  validateConfiguredCertScope (domain config) (aws_substrate config)
  validateDemoTtl (demo_ttl (domain config))
  validateAwsCredentialsRef "aws" (aws config)
  validatePublicEdgeDeployment (deployment config)
  validateCapacitySection (capacity config)
  mapLeft renderTopologyError (validateClusterTopology (cluster_topology config))

mapLeft :: (left -> left') -> Either left right -> Either left' right
mapLeft f value = case value of
  Left err -> Left (f err)
  Right result -> Right result

-- | The AWS / public-edge tier: everything 'validateLocalConfig' checks
-- plus the Route 53 zone and ACME account required to provision public
-- DNS + TLS. Called by AWS-touching flows (the IAM harness, SES, and the
-- @prodbox aws ...@ surface), never by local cluster commands.
validateAwsBootstrapConfig :: ConfigFile -> Either String ()
validateAwsBootstrapConfig config = do
  validateLocalConfig config
  requireNonEmpty "route53.zone_id" (zone_id (route53 config))
  requireNonEmpty "acme.email" (email (acme config))
  requireNonEmpty "acme.server" (server (acme config))
  validateAcmeBinding (acme config)

-- | Operational AWS credentials gate. Local commands never call this;
-- AWS-credential-consuming flows (edge reconcile, the Route 53 checks,
-- the @AwsCredentialsValid@ prerequisite) call it so an empty @aws.*@
-- block fails fast with a remedy ("Run @prodbox aws setup@") instead of
-- an opaque AWS-CLI error.
validateOperationalAwsCredentials :: ConfigFile -> Either String ()
validateOperationalAwsCredentials config = do
  validateAwsCredentialsRef "aws" (aws config)
  requireNonEmpty "aws.region" (awsCredentialRegion (aws config))

validatePublicEdgeDeployment :: DeploymentSection -> Either String ()
validatePublicEdgeDeployment deploymentSection = do
  validateBootstrapOverride
  validateAdvertisementMode
  validateScalingPolicyBySubstrate
    "deployment.envoy_gateway_controller_scaling"
    (envoy_gateway_controller_scaling deploymentSection)
  validateScalingPolicyBySubstrate
    "deployment.envoy_gateway_data_plane_scaling"
    (envoy_gateway_data_plane_scaling deploymentSection)
  validateScalingPolicyBySubstrate "deployment.api_scaling" (api_scaling deploymentSection)
  validateScalingPolicyBySubstrate
    "deployment.websocket_scaling"
    (websocket_scaling deploymentSection)
 where
  normalizedMode =
    fmap (Text.toLower . Text.strip) (public_edge_advertisement_mode deploymentSection)
  validateBootstrapOverride =
    validateOptionalIpAddressField
      "deployment.bootstrap_public_ip_override"
      (normalizeMaybeText (bootstrap_public_ip_override deploymentSection))
  validateAdvertisementMode =
    case normalizedMode of
      Nothing -> Right ()
      Just "l2" -> Right ()
      Just "bgp" ->
        case public_edge_bgp_peers deploymentSection of
          Just peers
            | not (null peers) ->
                mapM_ (uncurry validateBgpPeer) (zip [1 :: Int ..] peers)
          _ ->
            Left
              "deployment.public_edge_bgp_peers must contain at least one non-empty peer when deployment.public_edge_advertisement_mode is bgp"
      _ -> Left "deployment.public_edge_advertisement_mode must be l2 or bgp when set"

requireNonEmpty :: String -> Text -> Either String ()
requireNonEmpty fieldName value =
  if Text.strip value == ""
    then Left (fieldName ++ " must not be empty")
    else Right ()

validateBgpPeer :: Int -> MetallbBgpPeer -> Either String ()
validateBgpPeer index peer = do
  requireNonEmpty fieldPrefixName (peer_name peer)
  requireNonEmpty fieldPrefixAddress (peer_address peer)
  validateOptionalIpAddressField fieldPrefixAddress (normalizeOptionalText (peer_address peer))
 where
  fieldPrefix = "deployment.public_edge_bgp_peers[" ++ show index ++ "]"
  fieldPrefixName = fieldPrefix ++ ".peer_name"
  fieldPrefixAddress = fieldPrefix ++ ".peer_address"

validateOptionalIpAddressField :: String -> Maybe Text -> Either String ()
validateOptionalIpAddressField _ Nothing = Right ()
validateOptionalIpAddressField fieldName (Just value)
  | isValidIpLiteral (Text.strip value) = Right ()
  | otherwise = Left (fieldName ++ " must be a valid IP address when set")

isValidIpLiteral :: Text -> Bool
isValidIpLiteral value =
  isValidIpv4Literal value || isValidIpv6Literal value

isValidIpv4Literal :: Text -> Bool
isValidIpv4Literal value =
  case Text.splitOn "." value of
    [firstOctet, secondOctet, thirdOctet, fourthOctet] ->
      all isValidIpv4Octet [firstOctet, secondOctet, thirdOctet, fourthOctet]
    _ -> False

isValidIpv4Octet :: Text -> Bool
isValidIpv4Octet octet =
  not (Text.null octet)
    && Text.all isDigit octet
    && case reads (Text.unpack octet) of
      [(value, "")] -> value >= (0 :: Int) && value <= 255
      _ -> False

isValidIpv6Literal :: Text -> Bool
isValidIpv6Literal value =
  case Text.splitOn "::" value of
    [groupsText] ->
      let groups = splitIpv6Groups groupsText
       in not (null groups) && isValidIpv6GroupList groups && ipv6GroupWidth groups == 8
    [leftText, rightText] ->
      let leftGroups = splitIpv6Groups leftText
          rightGroups = splitIpv6Groups rightText
          totalWidth = ipv6GroupWidth leftGroups + ipv6GroupWidth rightGroups
       in isValidIpv6GroupList leftGroups
            && isValidIpv6GroupList rightGroups
            && totalWidth < 8
    _ -> False

splitIpv6Groups :: Text -> [Text]
splitIpv6Groups value
  | Text.null value = []
  | otherwise = Text.splitOn ":" value

isValidIpv6GroupList :: [Text] -> Bool
isValidIpv6GroupList groups =
  and (zipWith validateGroup [0 :: Int ..] groups)
 where
  lastIndex = length groups - 1
  validateGroup index group
    | Text.null group = False
    | isValidIpv4Literal group = index == lastIndex
    | otherwise = isValidIpv6Hextet group

isValidIpv6Hextet :: Text -> Bool
isValidIpv6Hextet group =
  let lengthValue = Text.length group
   in lengthValue >= 1 && lengthValue <= 4 && Text.all isHexDigit group

ipv6GroupWidth :: [Text] -> Int
ipv6GroupWidth =
  sum . map (\group -> if isValidIpv4Literal group then 2 else 1)

-- | Sprint 2.35: the served host must be covered by the configured certificate
-- scope set, and every configured scope must be well-formed — a wildcard only at
-- a delegated zone. Empty @cert_scopes@ means "just the served host", so the
-- default is behavior-identical to the pre-2.35 single-host pin (which is why no
-- widening happens until an operator adds a scope). Illegal states — an uncovered
-- served host, a malformed name, a wildcard at an undelegated zone — are rejected
-- fail-closed at config-validation time.
validateConfiguredCertScope :: DomainSection -> AwsSubstrateSection -> Either String ()
validateConfiguredCertScope domainSection awsSection
  | Text.null (Text.strip (demo_fqdn domainSection)) =
      Left "domain.demo_fqdn must not be empty"
  | otherwise = do
      servedHost <-
        mapLeft (\e -> "domain.demo_fqdn: " ++ renderScopeError e) (mkFqdn (demo_fqdn domainSection))
      scopeSet <- configuredCertScopeSet domainSection awsSection
      mapLeft (\e -> "domain.cert_scopes: " ++ renderScopeError e) (bindListener scopeSet servedHost)

-- | Build the configured 'CertScopeSet' from Tier-0 config. Delegated zones are
-- config-anchored (the served host's parent zone and, when set, the AWS subzone
-- plus its parent) — never the Public Suffix List. Empty @cert_scopes@ defaults
-- to the single exact served host.
configuredCertScopeSet :: DomainSection -> AwsSubstrateSection -> Either String CertScopeSet
configuredCertScopeSet domainSection awsSection =
  certScopeSetForServedHost domainSection awsSection (demo_fqdn domainSection)

-- | The configured 'CertScopeSet' as seen from a specific served host (the home
-- served host on the home substrate, the AWS subzone on the AWS substrate). The
-- delegated-zone anchors are the same config-declared set; only the empty-scope
-- default changes — an empty @cert_scopes@ means "just this served host", so
-- each substrate's certificate defaults to exactly its own served FQDN and there
-- is no behavior change until an operator widens scope. Sprint 2.35.
certScopeSetForServedHost
  :: DomainSection -> AwsSubstrateSection -> Text -> Either String CertScopeSet
certScopeSetForServedHost domainSection awsSection servedHost = do
  zones <- traverse parseZone (configuredDelegatedZoneNames domainSection awsSection)
  scopes <- traverse parseScope rawScopeNames
  mapLeft renderScopeError (mkScopeSet zones scopes)
 where
  rawScopeNames =
    case filter (not . Text.null . Text.strip) (cert_scopes domainSection) of
      [] -> [servedHost]
      configured -> configured
  parseZone name =
    mapLeft (\e -> "cert-scope delegated zone: " ++ renderScopeError e) (mkDelegatedZone name)
  parseScope raw =
    case Text.stripPrefix "*." (Text.strip raw) of
      Just zoneName ->
        mapLeft
          (\e -> "domain.cert_scopes wildcard: " ++ renderScopeError e)
          (ScopeWildcard <$> mkDelegatedZone zoneName)
      Nothing ->
        mapLeft
          (\e -> "domain.cert_scopes: " ++ renderScopeError e)
          (ScopeExact <$> mkFqdn (Text.strip raw))

-- | The certificate @dnsNames@ list a served host projects to under the
-- configured scope set — the single source the keycloak public-edge Certificate
-- template derives from (Sprint 2.35). Empty @cert_scopes@ yields exactly the
-- served host, so the rendered dnsNames are behavior-identical until an operator
-- widens scope.
certDnsNamesForServedHost
  :: DomainSection -> AwsSubstrateSection -> Text -> Either String [Text]
certDnsNamesForServedHost domainSection awsSection servedHost =
  certScopeSetDnsNames <$> certScopeSetForServedHost domainSection awsSection servedHost

-- | The delegated zones the configured wildcards may anchor at: the served
-- host's parent zone, plus (on the AWS substrate) the subzone and its parent.
configuredDelegatedZoneNames :: DomainSection -> AwsSubstrateSection -> [Text]
configuredDelegatedZoneNames domainSection awsSection =
  filter (not . Text.null) $
    parentZoneName (demo_fqdn domainSection)
      : ( let subzone = Text.strip (subzone_name awsSection)
           in if Text.null subzone then [] else [subzone, parentZoneName subzone]
        )

-- | The parent zone of a name — everything after the first label; empty when the
-- name has fewer than two labels.
parentZoneName :: Text -> Text
parentZoneName name = Text.drop 1 (Text.dropWhile (/= '.') (Text.strip name))

validateDemoTtl :: Natural -> Either String ()
validateDemoTtl ttl
  | ttl < 30 = Left "domain.demo_ttl must be between 30 and 86400"
  | ttl > 86400 = Left "domain.demo_ttl must be between 30 and 86400"
  | otherwise = Right ()

-- | Sprint 7.15: the ZeroSSL external-account-binding (EAB) key ID and HMAC
-- key are no longer plaintext @Optional Text@; they are @SecretRef.Vault@
-- references into @secret/acme/eab@ (fields @key_id@ / @hmac_key@), resolved
-- through Vault exactly like the operational @aws.*@ credentials. ZeroSSL
-- still requires both present; non-ZeroSSL servers may omit both; one without
-- the other is rejected; and a plaintext (non-@Vault@) reference is rejected
-- through the same 'validateVaultRef' discipline used for @aws.*@.
validateAcmeBinding :: AcmeSection -> Either String ()
validateAcmeBinding acmeSection
  | isZeroSslServer (server acmeSection)
      && (eab_key_id acmeSection == Nothing || eab_hmac_key acmeSection == Nothing) =
      Left "acme.eab_key_id and acme.eab_hmac_key are required for ZeroSSL ACME"
  | hasExactlyOne (eab_key_id acmeSection) (eab_hmac_key acmeSection) =
      Left "acme.eab_key_id and acme.eab_hmac_key must either both be set or both be empty"
  | otherwise = do
      mapM_ (validateVaultRef "acme.eab_key_id") (eab_key_id acmeSection)
      mapM_ (validateVaultRef "acme.eab_hmac_key") (eab_hmac_key acmeSection)

validateAwsCredentialsRef :: String -> AwsCredentialsRef -> Either String ()
validateAwsCredentialsRef prefix refs = do
  validateVaultRef (prefix ++ ".access_key_id") (awsCredentialAccessKeyId refs)
  validateVaultRef (prefix ++ ".secret_access_key") (awsCredentialSecretAccessKey refs)
  mapM_ (validateVaultRef (prefix ++ ".session_token")) (awsCredentialSessionToken refs)

validateVaultRef :: String -> SecretRef -> Either String ()
validateVaultRef fieldName ref =
  case ref of
    SecretRefVault _ -> Right ()
    _ -> Left (fieldName ++ " must be a SecretRef.Vault reference")

normalizeOptionalText :: Text -> Maybe Text
normalizeOptionalText value =
  if Text.strip value == ""
    then Nothing
    else Just value

normalizeMaybeText :: Maybe Text -> Maybe Text
normalizeMaybeText maybeValue = maybeValue >>= normalizeOptionalText

isZeroSslServer :: Text -> Bool
isZeroSslServer serverUrl =
  "https://acme.zerossl.com" `Text.isPrefixOf` Text.toLower serverUrl

hasExactlyOne :: Maybe a -> Maybe b -> Bool
hasExactlyOne left right =
  case (left, right) of
    (Just _, Nothing) -> True
    (Nothing, Just _) -> True
    _ -> False

-- | Sprint 1.61: a sensitive field is ALWAYS masked. The former
-- @config show --show-secrets@ unrestricted secret-reveal path is removed;
-- @config show@ has no generic secret-reveal capability or flag alias.
renderSensitive :: Text -> String
renderSensitive value =
  renderMaybeText $
    if Text.strip value == ""
      then Nothing
      else Just (maskSecret value)

renderMaybeText :: Maybe Text -> String
renderMaybeText maybeValue =
  maybe "" renderText maybeValue

renderText :: Text -> String
renderText = Text.unpack

renderSecretRefDisplay :: SecretRef -> String
renderSecretRefDisplay ref =
  case ref of
    SecretRefVault vault ->
      "Vault:"
        ++ Text.unpack (vaultSecretMount vault)
        ++ "/"
        ++ Text.unpack (vaultSecretPath vault)
        ++ "#"
        ++ Text.unpack (vaultSecretField vault)
    SecretRefTransitKey keyName -> "TransitKey:" ++ Text.unpack keyName
    SecretRefPrompt spec -> "Prompt:" ++ Text.unpack (promptSpecName spec)
    SecretRefTestPlaintext _ -> "TestPlaintext:<redacted>"

renderMaybeSecretRefDisplay :: Maybe SecretRef -> String
renderMaybeSecretRefDisplay =
  maybe "" renderSecretRefDisplay

renderBool :: Bool -> String
renderBool value =
  map toLower (show value)

renderScalingPolicyBySubstrate :: ScalingPolicyBySubstrate -> String
renderScalingPolicyBySubstrate policies =
  "home_local="
    ++ renderScalingPolicy (scalingHomeLocal policies)
    ++ ";aws="
    ++ renderScalingPolicy (scalingAws policies)

renderScalingPolicy :: ScalingPolicy -> String
renderScalingPolicy policy =
  case policy of
    ScalingPolicyFixed count -> "Fixed " ++ show count
    ScalingPolicyElastic bounds ->
      "Elastic{min=" ++ show (elasticMin bounds) ++ ",max=" ++ show (elasticMax bounds) ++ "}"

renderCapacityBudget :: CapacityBudget -> String
renderCapacityBudget budget =
  "cpu="
    ++ show (budgetCpu budget)
    ++ ";memory="
    ++ show (budgetMemory budget)
    ++ ";storage="
    ++ show (budgetStorage budget)

renderResourceVector :: ResourceVector -> String
renderResourceVector vector =
  "cpu_milli="
    ++ show (milli_cpu vector)
    ++ ";memory_mib="
    ++ show (memory_mib vector)
    ++ ";ephemeral_storage_mib="
    ++ show (ephemeral_storage_mib vector)
    ++ ";durable_storage_mib="
    ++ show (durable_storage_mib vector)

clusterAllocatable :: ResourcePlan -> ResourceVector
clusterAllocatable plan =
  host_capacity plan
    `resourceVectorMinus` rke2_reserved plan
    `resourceVectorMinus` eviction_floor plan

renderNamespaceQuotas :: [NamespaceQuota] -> String
renderNamespaceQuotas quotas =
  Text.unpack
    ( Text.intercalate
        ";"
        [ namespace_name namespaceQuota
            <> "="
            <> Text.pack (renderResourceVector (quota namespaceQuota))
        | namespaceQuota <- quotas
        ]
    )

renderWorkloadProfiles :: [WorkloadResourceProfile] -> String
renderWorkloadProfiles profiles =
  Text.unpack
    ( Text.intercalate
        ";"
        [ profile_id profile
            <> "@"
            <> profile_namespace profile
            <> "#replicas="
            <> Text.pack (show (replicas profile))
        | profile <- profiles
        ]
    )

renderRuntimeMemoryProfiles :: [RuntimeMemoryProfile] -> String
renderRuntimeMemoryProfiles profiles =
  Text.unpack
    ( Text.intercalate
        ";"
        [ runtime_profile_id profile
            <> ":heap_cap_bytes="
            <> Text.pack (show (heap_cap_bytes profile))
        | profile <- profiles
        ]
    )

renderBgpPeers :: Maybe [MetallbBgpPeer] -> String
renderBgpPeers maybePeers =
  case maybePeers of
    Nothing -> ""
    Just peers ->
      Text.unpack
        ( Text.intercalate
            ";"
            [ peer_name peer
                <> "@"
                <> peer_address peer
                <> ":peer_asn="
                <> Text.pack (show (peer_asn peer))
                <> ":my_asn="
                <> Text.pack (show (my_asn peer))
            | peer <- peers
            ]
        )

maskSecret :: Text -> Text
maskSecret value =
  if Text.length value > 4
    then "****" <> Text.takeEnd 4 value
    else "****"

operationalAwsCredentialsRef :: Text -> AwsCredentialsRef
operationalAwsCredentialsRef regionValue =
  AwsCredentialsRef
    { awsCredentialAccessKeyId = vaultRef "gateway/gateway/aws" "access_key_id"
    , awsCredentialSecretAccessKey = vaultRef "gateway/gateway/aws" "secret_access_key"
    , awsCredentialSessionToken = Nothing
    , awsCredentialRegion = regionValue
    }

vaultRef :: Text -> Text -> SecretRef
vaultRef path field =
  SecretRefVault
    VaultSecretRef
      { vaultSecretMount = "secret"
      , vaultSecretPath = path
      , vaultSecretField = field
      }

defaultConfigFile :: ConfigFile
defaultConfigFile =
  ConfigFile
    { aws = operationalAwsCredentialsRef "us-east-1"
    , route53 = Route53Section {zone_id = ""}
    , aws_substrate =
        AwsSubstrateSection
          { hosted_zone_id = ""
          , subzone_name = ""
          }
    , ses =
        SesSection
          { sender_domain = ""
          , receive_subdomain = ""
          , capture_bucket = ""
          }
    , domain =
        DomainSection
          { demo_fqdn = supportedPublicHostname
          , demo_ttl = 60
          , cert_scopes = []
          }
    , acme =
        AcmeSection
          { email = ""
          , server = "https://acme.zerossl.com/v2/DV90"
          , eab_key_id = Just (vaultRef "acme/eab" "key_id")
          , eab_hmac_key = Just (vaultRef "acme/eab" "hmac_key")
          }
    , deployment =
        DeploymentSection
          { dev_mode = True
          , bootstrap_public_ip_override = Nothing
          , pulumi_enable_dns_bootstrap = True
          , public_edge_advertisement_mode = Just "l2"
          , public_edge_bgp_peers = Nothing
          , envoy_gateway_controller_scaling = fixedScalingPolicyBySubstrate 1
          , envoy_gateway_data_plane_scaling = fixedScalingPolicyBySubstrate 1
          , api_scaling = fixedScalingPolicyBySubstrate 2
          , websocket_scaling = fixedScalingPolicyBySubstrate 2
          }
    , capacity = defaultCapacitySection
    , cluster_topology = defaultClusterTopology
    , storage = StorageSection {manual_pv_host_root = ".data"}
    , pulumi_state_backend =
        PulumiStateBackendSection
          { psbBucketName = ""
          , psbRegion = ""
          , psbKeyPrefix = "pulumi/"
          }
    , components = defaultComponentGraph
    }

renderConfigDhall :: ConfigFile -> String
renderConfigDhall config =
  unlines
    [ "let Config = ./prodbox-config-types.dhall"
    , ""
    , "in  Config::{"
    , "    , aws = Config.default.aws // {"
    , "        , access_key_id = " ++ dhallSecretRef (awsCredentialAccessKeyId (aws config))
    , "        , secret_access_key = " ++ dhallSecretRef (awsCredentialSecretAccessKey (aws config))
    , "        , session_token = " ++ dhallOptionalSecretRef (awsCredentialSessionToken (aws config))
    , "        , region = " ++ dhallText (awsCredentialRegion (aws config))
    , "        }"
    , "    , route53 = { zone_id = " ++ dhallText (zone_id (route53 config)) ++ " }"
    , "    , aws_substrate = Config.default.aws_substrate // {"
    , "        , hosted_zone_id = " ++ dhallText (hosted_zone_id (aws_substrate config))
    , "        , subzone_name = " ++ dhallText (subzone_name (aws_substrate config))
    , "        }"
    , "    , ses = Config.default.ses // {"
    , "        , sender_domain = " ++ dhallText (sender_domain (ses config))
    , "        , receive_subdomain = " ++ dhallText (receive_subdomain (ses config))
    , "        , capture_bucket = " ++ dhallText (capture_bucket (ses config))
    , "        }"
    , "    , domain = Config.default.domain // {"
    , "        , demo_fqdn = " ++ dhallText (demo_fqdn (domain config))
    , "        , demo_ttl = " ++ show (demo_ttl (domain config))
    , "        , cert_scopes = " ++ dhallTextList (cert_scopes (domain config))
    , "        }"
    , "    , acme = Config.default.acme // {"
    , "        , email = " ++ dhallText (email (acme config))
    , "        , server = " ++ dhallText (server (acme config))
    , "        , eab_key_id = " ++ dhallOptionalSecretRef (eab_key_id (acme config))
    , "        , eab_hmac_key = " ++ dhallOptionalSecretRef (eab_hmac_key (acme config))
    , "        }"
    , "    , deployment = Config.default.deployment // {"
    , "        , dev_mode = " ++ dhallBool (dev_mode (deployment config))
    , "        , bootstrap_public_ip_override = "
        ++ dhallOptionalText (bootstrap_public_ip_override (deployment config))
    , "        , pulumi_enable_dns_bootstrap = "
        ++ dhallBool (pulumi_enable_dns_bootstrap (deployment config))
    , "        , public_edge_advertisement_mode = "
        ++ dhallOptionalText (public_edge_advertisement_mode (deployment config))
    , "        , public_edge_bgp_peers = "
        ++ dhallOptionalBgpPeers (public_edge_bgp_peers (deployment config))
    , "        , envoy_gateway_controller_scaling = "
        ++ dhallScalingPolicyBySubstrate (envoy_gateway_controller_scaling (deployment config))
    , "        , envoy_gateway_data_plane_scaling = "
        ++ dhallScalingPolicyBySubstrate (envoy_gateway_data_plane_scaling (deployment config))
    , "        , api_scaling = " ++ dhallScalingPolicyBySubstrate (api_scaling (deployment config))
    , "        , websocket_scaling = "
        ++ dhallScalingPolicyBySubstrate (websocket_scaling (deployment config))
    , "        }"
    , "    , capacity = Config.default.capacity // {"
    , "        , node_budget = " ++ dhallCapacityBudget (node_budget (capacity config))
    , "        , workload_budget = " ++ dhallCapacityBudget (workload_budget (capacity config))
    , "        , region_quota = " ++ dhallCapacityBudget (region_quota (capacity config))
    , "        , resource_plan = " ++ dhallResourcePlan (resource_plan (capacity config))
    , "        , runtime_memory_profiles = "
        ++ dhallRuntimeMemoryProfiles (runtime_memory_profiles (capacity config))
    , "        }"
    , "    , cluster_topology = " ++ dhallClusterTopology (cluster_topology config)
    , "    , storage = Config.default.storage // {"
    , "        , manual_pv_host_root = " ++ dhallText (manual_pv_host_root (storage config))
    , "        }"
    , "    , pulumi_state_backend = Config.default.pulumi_state_backend // {"
    , "        , bucket_name = " ++ dhallText (psbBucketName (pulumi_state_backend config))
    , "        , region = " ++ dhallText (psbRegion (pulumi_state_backend config))
    , "        , key_prefix = " ++ dhallText (psbKeyPrefix (pulumi_state_backend config))
    , "        }"
    , "    }"
    , ""
    ]

dhallText :: Text -> String
dhallText = show . Text.unpack

-- | Render a @List Text@ Dhall literal; an empty list needs its type annotation.
dhallTextList :: [Text] -> String
dhallTextList [] = "([] : List Text)"
dhallTextList values = "[ " ++ intercalate ", " (map dhallText values) ++ " ]"

dhallOptionalText :: Maybe Text -> String
dhallOptionalText maybeValue =
  case maybeValue of
    Nothing -> "None Text"
    Just value -> "Some " ++ dhallText value

dhallSecretRef :: SecretRef -> String
dhallSecretRef ref =
  case ref of
    SecretRefVault vault ->
      "Config.SecretRef.Vault { mount = "
        ++ dhallText (vaultSecretMount vault)
        ++ ", path = "
        ++ dhallText (vaultSecretPath vault)
        ++ ", field = "
        ++ dhallText (vaultSecretField vault)
        ++ " }"
    SecretRefTransitKey name ->
      "Config.SecretRef.TransitKey " ++ dhallText name
    SecretRefPrompt spec ->
      "Config.SecretRef.Prompt { name = "
        ++ dhallText (promptSpecName spec)
        ++ ", purpose = "
        ++ dhallText (promptSpecPurpose spec)
        ++ " }"
    SecretRefTestPlaintext value ->
      "Config.SecretRef.TestPlaintext " ++ dhallText value

dhallOptionalSecretRef :: Maybe SecretRef -> String
dhallOptionalSecretRef maybeValue =
  case maybeValue of
    Nothing -> "None Config.SecretRef"
    Just value -> "Some (" ++ dhallSecretRef value ++ ")"

dhallScalingPolicyBySubstrate :: ScalingPolicyBySubstrate -> String
dhallScalingPolicyBySubstrate policies =
  "{ home_local = "
    ++ dhallScalingPolicy (scalingHomeLocal policies)
    ++ ", aws = "
    ++ dhallScalingPolicy (scalingAws policies)
    ++ " }"

dhallScalingPolicy :: ScalingPolicy -> String
dhallScalingPolicy policy =
  case policy of
    ScalingPolicyFixed count ->
      scalingPolicyDhallType ++ ".Fixed " ++ show count
    ScalingPolicyElastic bounds ->
      scalingPolicyDhallType
        ++ ".Elastic { min = "
        ++ show (elasticMin bounds)
        ++ ", max = "
        ++ show (elasticMax bounds)
        ++ " }"

scalingPolicyDhallType :: String
scalingPolicyDhallType =
  "< Fixed : Natural | Elastic : { min : Natural, max : Natural } >"

dhallCapacityBudget :: CapacityBudget -> String
dhallCapacityBudget budget =
  "{ cpu = "
    ++ show (budgetCpu budget)
    ++ ", memory = "
    ++ show (budgetMemory budget)
    ++ ", storage = "
    ++ show (budgetStorage budget)
    ++ " }"

dhallResourcePlan :: ResourcePlan -> String
dhallResourcePlan =
  Text.unpack . Core.pretty . injectedValue (Dhall.inject @ResourcePlan)

dhallRuntimeMemoryProfiles :: [RuntimeMemoryProfile] -> String
dhallRuntimeMemoryProfiles =
  Text.unpack . Core.pretty . injectedValue (Dhall.inject @[RuntimeMemoryProfile])

type DhallExpr = Core.Expr Src Void

dhallClusterTopology :: ClusterTopology -> String
dhallClusterTopology topology =
  Text.unpack (Core.pretty (injectedValue (Dhall.inject @ClusterTopology) topology))

injectedValue :: Dhall.Encoder a -> a -> DhallExpr
injectedValue encoder value = Core.denote (Dhall.embed encoder value)

dhallOptionalBgpPeers :: Maybe [MetallbBgpPeer] -> String
dhallOptionalBgpPeers maybePeers =
  case maybePeers of
    Nothing ->
      "None (List { peer_name : Text, peer_address : Text, peer_asn : Natural, my_asn : Natural, ebgp_multi_hop : Optional Bool })"
    Just [] ->
      "Some ([] : List { peer_name : Text, peer_address : Text, peer_asn : Natural, my_asn : Natural, ebgp_multi_hop : Optional Bool })"
    Just peers ->
      "Some [ "
        ++ foldr1
          (\left right -> left ++ ", " ++ right)
          (map dhallBgpPeer peers)
        ++ " ]"
 where
  dhallBgpPeer peer =
    "{ peer_name = "
      ++ dhallText (peer_name peer)
      ++ ", peer_address = "
      ++ dhallText (peer_address peer)
      ++ ", peer_asn = "
      ++ show (peer_asn peer)
      ++ ", my_asn = "
      ++ show (my_asn peer)
      ++ ", ebgp_multi_hop = "
      ++ dhallOptionalBool (ebgp_multi_hop peer)
      ++ " }"

dhallOptionalBool :: Maybe Bool -> String
dhallOptionalBool maybeValue =
  case maybeValue of
    Nothing -> "None Bool"
    Just value -> "Some " ++ dhallBool value

dhallBool :: Bool -> String
dhallBool True = "True"
dhallBool False = "False"

missingConfigMessage :: FilePath -> String
missingConfigMessage configPath =
  unlines
    [ "Missing required repository config `" ++ configPath ++ "`."
    , "Run `./.build/prodbox config setup` from the repository root to create it, then rerun the command."
    ]

missingTestTopologyMessage :: FilePath -> String
missingTestTopologyMessage testTopologyPath =
  unlines
    [ "Missing required test topology `" ++ testTopologyPath ++ "`."
    , "Create `prodbox.test.dhall` beside the prodbox binary before running topology-driven tests; the `test init` authoring command lands in Sprint 5.11."
    ]
