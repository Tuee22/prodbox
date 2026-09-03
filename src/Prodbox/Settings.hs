{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Prodbox.Settings
  ( AcmeSection (..)
  , AwsCredentialsRef (..)
  , AwsSubstrateSection (..)
  , AwsSubstrateProfile
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
  , DeploymentContextInput (..)
  , ValidatedDeploymentContext
  , deploymentClusterId
  , deploymentVaultAddress
  , deploymentMinioEndpoint
  , deploymentMachineIds
  , ValidatedSettings (..)
  , ValidatedCoordinates (..)
  , AcmeAccount (..)
  , validatedCoordinatesFor
  , requireAcmeAccount
  , requireHomeZoneId
  , requireOperationalAwsRegion
  , requireAwsSubstrateProfile
  , requireSesCaptureBucket
  , homeZoneIdTextForRendering
  , operationalAwsRegionTextForRendering
  , SeedInForceOutcome (..)
  , defaultConfigFile
  , configGenerationTemplate
  , defaultTestTopology
  , decodeConfigDhallBytes
  , loadConfigFile
  , loadConfigFileAtPath
  , loadTestTopology
  , loadTestTopologyAtPath
  , loadConfigForSettingsWith
  , loadUnencryptedBasics
  , loadUnencryptedBasicsAtPath
  , renderConfigDhall
  , renderSeedInForceOutcome
  , reconcileInForceConfigFromFile
  , renderSettingsDisplay
  , resolveLifecycleProviderCredentials
  , zeroSslAcmeDirectory
  , renderTestTopologyError
  , validateAwsBootstrapConfig
  , validateAwsSubstrateSection
  , validateComponentNodes
  , validateLocalConfig
  , validateAndLoadSettings
  , validateAndLoadSettingsAtPath
  , validateAndLoadBootstrapSettings
  , certDnsNamesForServedHost
  , certScopeSetForServedHost
  , validateConfiguredCertScope
  , validateConfig
  , validateConfigWithContext
  , validatedDeploymentContextFor
  , ValidatedServedHost (..)
  , ValidatedPublicEdge (..)
  , validatedPublicEdgeFor
  , substrateServedHost
  , validateOperationalAwsCredentials
  , PublicEdgeAdvertisementMode (..)
  , parsePublicEdgeAdvertisementMode
  , renderPublicEdgeAdvertisementMode
  , validatePublicEdgeDeployment
  , validateTestTopology
  , validatedResourcePlan
  )
where

import Control.Exception (SomeException, displayException, try)
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (toLower)
import Data.Char qualified as Char
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
import Prodbox.Capacity.Allocation qualified as Allocation
import Prodbox.Capacity.Config
  ( CapacityBudget (..)
  , CapacitySection (..)
  , ResourcePlan (..)
  , ResourceVector (..)
  , RuntimeMemoryProfile (..)
  , WorkloadResourceProfile (..)
  , defaultCapacitySection
  , validateCapacitySection
  , validateOneShotSecretWorkerCapacity
  )
import Prodbox.Cluster.Topology
  ( ClusterTopology
  , ClusterType (..)
  , MachineId
  , clusterTopologyMachines
  , clusterType
  , machine_id
  , renderClusterType
  , renderTopologyError
  , unconfiguredClusterTopology
  , validateClusterTopology
  )
import Prodbox.Config.Basics
  ( UnencryptedBasics (..)
  )
import Prodbox.Config.ComponentGraph
  ( ComponentNode
  , defaultComponentGraph
  , renderComponentGraphError
  , validateComponentGraph
  )
import Prodbox.Config.FloorDhall (loadUnencryptedBasics, loadUnencryptedBasicsAtPath)
import Prodbox.Config.RetainedArtifacts
  ( RetainedArtifactsSection
  , declaredRetainedArtifacts
  , emptyRetainedArtifactsSection
  , renderRetainedArtifactDeclarationError
  )
import Prodbox.ControlPlane.ConfigClient
  ( ConfigClient (..)
  , ConfigClientError
  , configClientWithTransport
  )
import Prodbox.ControlPlane.ConfigEndpoint
  ( ConfigObservation (..)
  , ConfigProjection (..)
  , ConfigProjectionScope (ConfigProjectionOperator, ConfigProjectionTestHarness)
  , ConfigProposeCasRequest (..)
  , ConfigProposeCasResponse (..)
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (..)
  , renderLifecycleAuthorityAuthenticationError
  , withHostLifecycleAuthorityAuthentication
  , withLifecycleAuthorityAuthenticatedTransport
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity (..)
  , TargetSecretId (TargetAwsCredential)
  , targetSecretIdVaultLogicalPath
  )
import Prodbox.Lifecycle.Authority.Config
  ( ConfigSchemaVersion (ConfigSchemaVersion)
  , inForceGeneration
  )
import Prodbox.Repo
  ( ConfigPaths (..)
  , canonicalConfigPaths
  , resolveTestTopologyConfigPath
  , resolveTier0ConfigPath
  )
import Prodbox.Settings.AwsSubstrateProfile
  ( AwsSubstrateProfile
  )
import Prodbox.Settings.Coordinate
  ( AcmeDirectoryUrl
  , AwsRegion
  , CoordinateError
  , DnsLabel
  , DnsTtl
  , EmailAddress
  , IpLiteral
  , Route53ZoneId
  , S3BucketName
  , SafeRelativePath
  , awsRegionText
  , mkAcmeDirectoryUrl
  , mkAwsRegion
  , mkDnsLabel
  , mkDnsTtl
  , mkEmailAddress
  , mkIpLiteral
  , mkRoute53ZoneId
  , mkS3BucketName
  , mkSafeRelativePath
  , normalizeCoordinateText
  , renderCoordinateError
  , route53ZoneIdText
  , traverseOptionalCoordinate
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
  , Substrate (..)
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
  , Fqdn
  , bindListener
  , certScopeSetDnsNames
  , mkDelegatedZone
  , mkFqdn
  , mkScopeSet
  , renderScopeError
  )
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
  , profile :: Maybe AwsSubstrateProfile
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
  , eab_key_id :: Maybe SecretRef
  , eab_hmac_key :: Maybe SecretRef
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | Sprint 1.80: how the public edge advertises its addresses. The legal set is
-- closed, known, and two elements wide; it used to be carried as free 'Text' and
-- decided by string comparison, in the same record that already carries eight
-- properly-unioned scaling policies plus 'WorkerSubstrate', 'ClusterTopology',
-- and 'ComponentId' as real Dhall unions.
--
-- This is the one field on the Tier-0 surface where the illegal state is
-- closable __in Dhall__ rather than merely detectable in Haskell: the generated
-- schema carries the union, so a misspelling stops type-checking instead of
-- reaching a Ring-2 comparison. The *Distinguishability* class of
-- [chaos_hardening_doctrine.md § 21](../../../documents/engineering/chaos_hardening_doctrine.md).
--
-- The @bgp ⇒ at least one peer@ rule deliberately stays in Haskell: it is a
-- cross-field invariant, and Dhall's @assert@ operates on closed terms, so it
-- cannot reach authored values. @prodbox-config-types.dhall@ contains zero
-- asserts and this type does not change that.
data PublicEdgeAdvertisementMode
  = AdvertiseLayer2
  | AdvertiseBgp
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | The operator-facing spelling of a mode.
renderPublicEdgeAdvertisementMode :: PublicEdgeAdvertisementMode -> Text
renderPublicEdgeAdvertisementMode mode = case mode of
  AdvertiseLayer2 -> "l2"
  AdvertiseBgp -> "bgp"

-- | Parse an operator-supplied spelling. The one place a string becomes a mode,
-- so the prompt surface can accept @l2@/@bgp@ without any other site comparing
-- strings.
parsePublicEdgeAdvertisementMode :: Text -> Maybe PublicEdgeAdvertisementMode
parsePublicEdgeAdvertisementMode raw = case Text.toLower (Text.strip raw) of
  "l2" -> Just AdvertiseLayer2
  "bgp" -> Just AdvertiseBgp
  _ -> Nothing

data DeploymentSection = DeploymentSection
  { dev_mode :: Bool
  , bootstrap_public_ip_override :: Maybe Text
  , pulumi_enable_dns_bootstrap :: Bool
  , public_edge_advertisement_mode :: Maybe PublicEdgeAdvertisementMode
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
  , retained_artifacts :: RetainedArtifactsSection
  -- ^ Sprint 4.86: the operator-declared retained artifacts an
  -- ordinary-teardown repair reinstalls the local substrate and the recovery
  -- closure's images from. See 'RetainedArtifactsSection'.
  , components :: [ComponentNode]
  -- ^ Sprint 1.56: the Tier-0 component dependency/readiness graph that
  -- bootstrap ordering is projected from
  -- (bootstrap_readiness_doctrine.md M2). Non-secret; validated by
  -- 'Prodbox.Config.ComponentGraph.validateComponentGraph' when projected.
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | The deployment-varying coordinates carried by Tier-0's @context@ record.
-- The projection is intentionally narrower than 'ProdboxContext': Settings
-- owns validation without importing the Tier-0 envelope module (which imports
-- Settings for @parameters@). The Dhall loader projects exactly these fields.
data DeploymentContextInput = DeploymentContextInput
  { contextInputClusterId :: Text
  , contextInputVaultAddress :: Text
  , contextInputMinioEndpoint :: Text
  }
  deriving (Eq, Show, Generic)

instance FromDhall DeploymentContextInput where
  autoWith _ =
    genericAutoWith
      defaultInterpretOptions {fieldModifier = deploymentContextFieldModifier}

instance ToDhall DeploymentContextInput where
  injectWith _ =
    genericToDhallWith
      defaultInterpretOptions {fieldModifier = deploymentContextFieldModifier}

deploymentContextFieldModifier :: Text -> Text
deploymentContextFieldModifier value =
  case Text.stripPrefix "contextInput" value of
    Just stripped -> haskellCamelToDhallSnake stripped
    Nothing -> value

-- | The one narrowed deployment context carried by every validated command.
-- Its constructor is private: the only minting path is
-- 'validatedDeploymentContextFor'. Machine identifiers have already crossed
-- 'ClusterTopology''s validating Dhall decoder and are retained here beside
-- the context coordinates they must agree with.
data ValidatedDeploymentContext = ValidatedDeploymentContext
  { deploymentClusterId :: !Text
  , deploymentVaultAddress :: !Text
  , deploymentMinioEndpoint :: !Text
  , deploymentMachineIds :: ![MachineId]
  }
  deriving (Eq, Show)

data ValidatedSettings = ValidatedSettings
  { validatedConfig :: ConfigFile
  , resolvedManualPvHostRoot :: FilePath
  , validatedAllocatedPlan :: Allocation.SomeAllocatedPlan
  , validatedPublicEdge :: ValidatedPublicEdge
  -- ^ Sprint 1.83: the parsed public-edge projection, built by the one parse
  -- validation performs rather than re-derived from the raw record at each
  -- use. See 'ValidatedPublicEdge'.
  , validatedCoordinates :: ValidatedCoordinates
  -- ^ Sprint 1.89: the remaining Tier-0 coordinates, parsed once by the same
  -- validation. Sprint 1.83 did this for the public edge and stopped there;
  -- this is the rest of the surface that row described. See
  -- 'ValidatedCoordinates'.
  , validatedDeploymentContext :: ValidatedDeploymentContext
  -- ^ Sprint 1.92: the Tier-0 context and topology identities narrowed once,
  -- carried beside every other validated projection.
  }
  deriving (Eq, Show)

-- | Sprint 1.89: every Tier-0 coordinate whose invariant is decided by
-- validation, carried as the type that decision established.
--
-- __Why a record rather than narrower fields on 'ConfigFile'.__ 'ConfigFile' is
-- the Dhall wire record; its field types are the authored file's types. Retyping
-- them would change every generated @prodbox.dhall@, which Standard P counts as
-- a generated-config identity change. This record sits one ring in — built by
-- 'validateConfig', which is already the sole minter of 'ValidatedSettings' —
-- so the narrowing is real for every consumer while the authored bytes are
-- untouched.
--
-- __Why so many 'Maybe's.__ Blank is the correct state for most of these on a
-- home-only host: no SES identity, no AWS subzone, no long-lived state backend,
-- no ACME account. 'Nothing' means the operator declared none, and is
-- structurally distinct from a value that failed to parse — which is a refusal,
-- not a 'Nothing'. The two fields that are not optional
-- ('coordinateDemoTtl' and 'coordinateManualPvHostRoot') are the two the local
-- tier has always required.
--
-- __What this does not carry.__ The public edge ('validatedPublicEdge'), the
-- resource plan ('validatedAllocatedPlan'), the cluster topology (smart-
-- constructed at decode by Sprint 1.86), and the component graph each already
-- have a retained parse of their own; duplicating them here would create a
-- second copy that could disagree with the first.
data ValidatedCoordinates = ValidatedCoordinates
  { coordinateHomeZoneId :: !(Maybe Route53ZoneId)
  -- ^ @route53.zone_id@. Before Sprint 1.89 this was checked only for
  -- emptiness, and only on the AWS tier — while the structurally identical
  -- @aws_substrate.hosted_zone_id@ below was shape-checked on every load.
  , coordinateAwsSubstrateZoneId :: !(Maybe Route53ZoneId)
  -- ^ @aws_substrate.hosted_zone_id@.
  , coordinateOperationalAwsRegion :: !(Maybe AwsRegion)
  -- ^ @aws.region@. No shape rule existed for this field anywhere before
  -- Sprint 1.89; a typo reached the AWS SDK.
  , coordinatePulumiBackendRegion :: !(Maybe AwsRegion)
  -- ^ @pulumi_state_backend.region@ — the only field of its section with no
  -- check at all, while both its siblings had one.
  , coordinatePulumiBackendBucket :: !(Maybe S3BucketName)
  -- ^ @pulumi_state_backend.bucket_name@.
  , coordinatePulumiBackendKeyPrefix :: !SafeRelativePath
  -- ^ @pulumi_state_backend.key_prefix@, concatenated into object keys.
  , coordinateSesSenderDomain :: !(Maybe Fqdn)
  -- ^ @ses.sender_domain@.
  , coordinateSesReceiveSubdomain :: !(Maybe DnsLabel)
  -- ^ @ses.receive_subdomain@.
  , coordinateSesCaptureBucket :: !(Maybe S3BucketName)
  -- ^ @ses.capture_bucket@.
  , coordinateDemoTtl :: !DnsTtl
  -- ^ @domain.demo_ttl@.
  , coordinateBootstrapPublicIp :: !(Maybe IpLiteral)
  -- ^ @deployment.bootstrap_public_ip_override@.
  , coordinateManualPvHostRoot :: !SafeRelativePath
  -- ^ @storage.manual_pv_host_root@, before it is joined onto the repository
  -- root. 'resolvedManualPvHostRoot' carries the joined absolute result; this
  -- carries the proof that joining it cannot escape.
  , coordinateAcmeAccount :: !(Maybe AcmeAccount)
  -- ^ Operator-authored @acme.email@ paired with the one compiled ZeroSSL
  -- directory.
  }
  deriving (Eq, Show)

-- | An ACME account's non-secret coordinates. Both halves or neither: the ACME
-- registration needs a contact and a directory, and a config carrying one
-- without the other has configured nothing.
--
-- The external-account-binding key pair beside these in @acme@ stays a
-- 'SecretRef' and is deliberately absent here — this record is the non-secret
-- projection, and Standard P forbids secret material entering a value that
-- qualification evidence may digest.
data AcmeAccount = AcmeAccount
  { acmeAccountEmail :: !EmailAddress
  , acmeAccountDirectoryUrl :: !AcmeDirectoryUrl
  }
  deriving (Eq, Show)

-- | The one ACME directory supported by prodbox. This is vendor protocol
-- identity, not a deployment choice, so it is compiled once and is absent from
-- the Tier-0 authoring schema.
zeroSslAcmeDirectory :: Text
zeroSslAcmeDirectory = "https://acme.zerossl.com/v2/DV90"

-- | A served public host together with the certificate scope set it projects.
--
-- Both halves come from the same parse. Before Sprint 1.83 the parse happened at
-- config validation and its result was bound to @_@, so eight production call
-- sites re-derived the scope set from the raw @Text@ and every consumer of the
-- served host re-read an unparsed field. This is the /Provenance/ class of
-- [chaos_hardening_doctrine.md § 21](../../../documents/engineering/chaos_hardening_doctrine.md):
-- the one place a real parse happened threw the proof away.
data ValidatedServedHost = ValidatedServedHost
  { servedHostFqdn :: !Fqdn
  , servedHostCertScopes :: !CertScopeSet
  }
  deriving (Eq, Show)

-- | The served hosts this config declares, keyed by the substrate that serves
-- them.
--
-- The AWS entry is 'Maybe' because __absent is the correct state for a home-only
-- host__ — @aws_substrate.subzone_name@ is required by the AWS tier
-- ('validateAwsBootstrapConfig') and deliberately not by the local tier. Before
-- Sprint 1.83 that absence was carried as the empty string, so a config validated
-- only by the local tier reached the former @Prodbox.PublicEdge.substratePublicFqdn@
-- and received @\"\"@ — a served hostname that is not one. Sprint 1.87 deleted
-- that accessor; 'Prodbox.PublicEdge.requireSubstrateServedHost' is now the only
-- way to obtain a substrate's served host.
data ValidatedPublicEdge = ValidatedPublicEdge
  { validatedHomeServedHost :: !ValidatedServedHost
  , validatedAwsServedHost :: !(Maybe ValidatedServedHost)
  }
  deriving (Eq, Show)

validatedResourcePlan :: ValidatedSettings -> ResourcePlan
validatedResourcePlan settings =
  case validatedAllocatedPlan settings of
    Allocation.SomeAllocatedPlan _ plan -> Allocation.allocatedPlanSource plan

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
-- consults the Lifecycle Authority's in-force generation. Sprint 1.48.
validateAndLoadSettingsAtPath
  :: FilePath -> FilePath -> IO (Either String ValidatedSettings)
validateAndLoadSettingsAtPath configPath repoRoot = do
  configResult <- loadConfigFileAtPath configPath
  case configResult of
    Left err -> pure (Left err)
    Right config -> do
      contextResult <- loadDeploymentContextInputAtPath configPath
      case contextResult of
        Left err -> pure (Left err)
        Right contextInput -> validateConfigWithContext repoRoot contextInput config

-- | Lifecycle bootstrap settings are the repository Dhall seed/propose input.
-- Use this only for the Tier-0 bootstrap steps that run before the frozen
-- Lifecycle Authority and its backup are established.
validateAndLoadBootstrapSettings :: FilePath -> IO (Either String ValidatedSettings)
validateAndLoadBootstrapSettings repoRoot = do
  configResult <- loadConfigFile repoRoot
  case configResult of
    Left err -> pure (Left err)
    Right config -> validateConfig repoRoot config

-- | Resolve the config source for supported host settings loads. Without a
-- Tier-0 basics floor (no @prodbox.dhall@ to project it from), the filesystem
-- Dhall remains the first-bring-up seed input. Once a floor exists, the
-- filesystem file is no longer authoritative: the caller-supplied loader must
-- observe the role-scoped Lifecycle Authority projection.
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
    Right basics -> loadInForce basics

loadRuntimeInForceConfig :: FilePath -> UnencryptedBasics -> IO (Either String ConfigFile)
loadRuntimeInForceConfig repoRoot _basics = do
  observed <-
    runHostConfigClient
      LifecycleAuthorityOperator
      ConfigProjectionOperator
      repoRoot
      observeConfig
  case observed of
    Left detail -> pure (Left detail)
    Right ConfigObservationMissing ->
      pure (Left "Lifecycle Authority config is absent; run cluster reconcile to submit the Tier-0 seed")
    Right (ConfigObservationCorrupt detail) ->
      pure (Left ("Lifecycle Authority config is corrupt: " ++ Text.unpack detail))
    Right (ConfigObservationUnobservable detail) ->
      pure (Left ("Lifecycle Authority config is unobservable: " ++ Text.unpack detail))
    Right (ConfigObservationObserved projection) ->
      decodeConfigDhallBytes repoRoot (configProjectionBytes projection)

-- | The observable result of reconciling the Tier-0 proposal with the
-- Lifecycle Authority's exact in-force generation.
data SeedInForceOutcome
  = -- | No in-force generation existed and the Authority accepted generation 1.
    SeededInForce
  | -- | The proposed canonical bytes already name the current generation.
    InForceAlreadyPresent
  | -- | An existing generation was advanced by an exact-generation proposal.
    InForceUpdated
  | -- | No filesystem proposal is available during an optional authoring flow.
    NoConfigToSeed
  deriving (Eq, Show)

renderSeedInForceOutcome :: SeedInForceOutcome -> String
renderSeedInForceOutcome outcome = case outcome of
  SeededInForce ->
    "Seeded the Lifecycle Authority in-force config from the Tier-0 proposal."
  InForceAlreadyPresent ->
    "The proposed config is already the current Lifecycle Authority generation."
  InForceUpdated ->
    "Advanced the Lifecycle Authority in-force config generation and read it back."
  NoConfigToSeed ->
    "No Tier-0 config proposal was available."

-- | Observe the Authority generation, submit the Tier-0 bytes with the exact
-- prior generation (or as the one legal seed), and trust only the typed
-- read-back response.  No root token or object-store coordinate crosses this
-- host boundary.
reconcileInForceConfigFromFile
  :: ExternalLifecycleAuthorityCaller
  -> FilePath
  -> IO (Either String SeedInForceOutcome)
reconcileInForceConfigFromFile caller repoRoot = do
  configResult <- loadConfigFile repoRoot
  case configResult of
    Left err -> pure (Left err)
    Right config -> do
      let scope = callerProjectionScope caller
          canonicalBytes =
            TextEncoding.encodeUtf8 (Text.pack (renderConfigDhall config))
      observed <-
        runHostConfigClient caller scope repoRoot observeConfig
      case observed of
        Left detail -> pure (Left detail)
        Right (ConfigObservationCorrupt detail) ->
          pure (Left ("Lifecycle Authority config is corrupt: " ++ Text.unpack detail))
        Right (ConfigObservationUnobservable detail) ->
          pure (Left ("Lifecycle Authority config is unobservable: " ++ Text.unpack detail))
        Right ConfigObservationMissing ->
          submit canonicalBytes Nothing
        Right (ConfigObservationObserved projection) ->
          submit
            canonicalBytes
            (Just (inForceGeneration (configProjectionIdentity projection)))
 where
  submit canonicalBytes expected = do
    proposed <-
      runHostConfigClient
        caller
        (callerProjectionScope caller)
        repoRoot
        ( \client ->
            proposeConfigCas
              client
              ConfigProposeCasRequest
                { configProposeExpectedGeneration = expected
                , configProposeSchema = ConfigSchemaVersion 1
                , configProposeCanonicalBytes = canonicalBytes
                }
        )
    pure $ case proposed of
      Left detail -> Left detail
      Right (ConfigProposalSeeded _) -> Right SeededInForce
      Right (ConfigProposalAdvanced _) -> Right InForceUpdated
      Right (ConfigProposalAlreadyCurrent _) -> Right InForceAlreadyPresent
      Right (ConfigProposalRefusedByGate refusal) ->
        Left ("Lifecycle Authority refused config proposal: " ++ show refusal)
      Right (ConfigProposalRefused refusal) ->
        Left ("Lifecycle Authority refused config proposal: " ++ show refusal)
      Right (ConfigProposalInvalid detail) -> Left (Text.unpack detail)
      Right (ConfigProposalConflict _) -> Left "Lifecycle Authority config generation CAS conflict"
      Right (ConfigProposalUnavailable detail) -> Left (Text.unpack detail)

runHostConfigClient
  :: ExternalLifecycleAuthorityCaller
  -> ConfigProjectionScope
  -> FilePath
  -> (ConfigClient IO -> IO (Either ConfigClientError value))
  -> IO (Either String value)
runHostConfigClient caller scope repoRoot action = do
  authenticated <-
    withHostLifecycleAuthorityAuthentication caller repoRoot $ \authentication ->
      withLifecycleAuthorityAuthenticatedTransport authentication $ \transport ->
        action (configClientWithTransport transport scope)
  pure $ case authenticated of
    Left err -> Left (renderLifecycleAuthorityAuthenticationError err)
    Right (Left err) -> Left (renderLifecycleAuthorityAuthenticationError err)
    Right (Right (Left err)) -> Left ("Lifecycle Authority config client failed: " ++ show err)
    Right (Right (Right value)) -> Right value

callerProjectionScope
  :: ExternalLifecycleAuthorityCaller -> ConfigProjectionScope
callerProjectionScope caller = case caller of
  LifecycleAuthorityOperator -> ConfigProjectionOperator
  LifecycleAuthorityTestHarness -> ConfigProjectionTestHarness

-- | Resolve the root operational credential through the exact registered
-- Lifecycle-provider Target Agent object.
--
-- LEGACY-ESCAPE[tier0-generic-aws-credential-aggregate]: the general-purpose
-- Tier-0 @aws.*@ aggregate and this resolver still represent the registered
-- Lifecycle-provider identity outside its fenced Provider-Worker ownership.
-- Registered in "Prodbox.Legacy.EscapeRegistry"; owned by Sprint @4.50@.  The Tier-0 SecretRefs remain a
-- non-secret schema assertion; no supported host path reads Vault KV fields.
resolveLifecycleProviderCredentials
  :: FilePath -> String -> AwsCredentialsRef -> IO (Either String Credentials)
resolveLifecycleProviderCredentials _repoRoot label refs =
  case validateRegisteredAwsRefs AwsLifecycleProvider refs of
    Left err -> pure (Left (label ++ ": " ++ err))
    Right () ->
      pure
        ( Left
            ( label
                ++ ": lifecycle-provider credentials are consumer-owned; host plaintext materialization is disabled"
            )
        )

validateRegisteredAwsRefs
  :: AwsCredentialIdentity -> AwsCredentialsRef -> Either String ()
validateRegisteredAwsRefs identity refs = do
  validateField "access_key_id" (awsCredentialAccessKeyId refs)
  validateField "secret_access_key" (awsCredentialSecretAccessKey refs)
  case awsCredentialSessionToken refs of
    Nothing -> Right ()
    Just ref -> validateField "session_token" ref
 where
  expectedPath = targetSecretIdVaultLogicalPath (TargetAwsCredential identity)
  validateField expectedField ref = case ref of
    SecretRefVault registeredVaultRef
      | vaultSecretMount registeredVaultRef == "secret"
          && vaultSecretPath registeredVaultRef == expectedPath
          && vaultSecretField registeredVaultRef == expectedField ->
          Right ()
      | otherwise ->
          Left
            ( "expected SecretRef.Vault secret/"
                ++ Text.unpack expectedPath
                ++ "#"
                ++ Text.unpack expectedField
            )
    SecretRefTestPlaintext _ -> Left "plaintext AWS credential references are forbidden"
    SecretRefTransitKey _ -> Left "TransitKey is not an AWS credential target"
    SecretRefPrompt spec ->
      Left
        ( "prompted secret `"
            ++ Text.unpack (promptSpecName spec)
            ++ "` cannot be a runtime AWS credential target"
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
    , "aws_substrate.profile="
        ++ maybe "<unauthored>" (const "<authored>") (profile (aws_substrate config))
    , "ses.sender_domain=" ++ renderText (sender_domain (ses config))
    , "ses.receive_subdomain=" ++ renderText (receive_subdomain (ses config))
    , "ses.capture_bucket=" ++ renderText (capture_bucket (ses config))
    , "domain.demo_fqdn=" ++ renderText (demo_fqdn (domain config))
    , "domain.demo_ttl=" ++ show (demo_ttl (domain config))
    , "acme.email=" ++ renderSensitive (email (acme config))
    , "acme.eab_key_id=" ++ renderMaybeSecretRefDisplay (eab_key_id (acme config))
    , "acme.eab_hmac_key=" ++ renderMaybeSecretRefDisplay (eab_hmac_key (acme config))
    , "deployment.dev_mode=" ++ renderBool (dev_mode (deployment config))
    , "deployment.bootstrap_public_ip_override="
        ++ renderMaybeText (bootstrap_public_ip_override (deployment config))
    , "deployment.pulumi_enable_dns_bootstrap="
        ++ renderBool (pulumi_enable_dns_bootstrap (deployment config))
    , "deployment.public_edge_advertisement_mode="
        ++ renderMaybeText
          (fmap renderPublicEdgeAdvertisementMode (public_edge_advertisement_mode (deployment config)))
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
        ++ renderResourceVector (host_capacity plan)
    , "capacity.resource_plan.rke2_reserved="
        ++ renderResourceVector (rke2_reserved plan)
    , "capacity.resource_plan.eviction_floor="
        ++ renderResourceVector (eviction_floor plan)
    , "capacity.resource_plan.cluster_allocatable="
        ++ renderResourceVector (Allocation.planAllocatable (validatedAllocatedPlan settings))
    , "capacity.resource_plan.workload_profiles="
        ++ renderWorkloadProfiles (workload_profiles plan)
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
  plan = validatedResourcePlan settings

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
-- 'loadConfigForSettingsWith' and the authoring
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

-- | Decode only the deployment-varying context coordinates from Tier-0. The
-- explicit projection avoids a Settings ↔ Tier0 module cycle while keeping the
-- full envelope's @parameters@ and @context@ values in one Dhall document.
loadDeploymentContextInputAtPath
  :: FilePath -> IO (Either String DeploymentContextInput)
loadDeploymentContextInputAtPath tier0Path = do
  tier0Exists <- doesFileExist tier0Path
  if not tier0Exists
    then pure (Left (missingConfigMessage tier0Path))
    else do
      absPath <- makeAbsolute tier0Path
      let expr =
            "let context = ( "
              <> Text.pack absPath
              <> " ).context in context.{ cluster_id, vault_address, minio_endpoint }"
      result <- try (input auto expr)
      pure $ case result of
        Left (e :: SomeException) ->
          Left
            ( "Failed to decode Tier-0 prodbox.dhall `context` from `"
                ++ tier0Path
                ++ "`: "
                ++ displayException e
            )
        Right contextInput -> Right contextInput

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
    -- Sprint 1.79: BEST-EFFORT. A payload rendered by the derived renderer is
    -- self-contained and imports nothing, so requiring the schema to exist would
    -- make the decode fail on a generated, git-ignored file it does not need.
    -- The copy is retained because a payload stored by the superseded renderer
    -- still carries `let Config = ./prodbox-config-types.dhall`; such a payload
    -- fails at the Dhall import with its own message when the schema is absent,
    -- which is the accurate error rather than a preparation error standing in
    -- for it.
    _ <- try (copyFile schemaPath tmpSchemaPath) :: IO (Either SomeException ())
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
  tier0Path <- resolveTier0ConfigPath repoRoot
  contextResult <- loadDeploymentContextInputAtPath tier0Path
  case contextResult of
    Left err -> pure (Left err)
    Right contextInput -> validateConfigWithContext repoRoot contextInput config

-- | Validate a config against an explicitly supplied Tier-0 context. Production
-- reaches this through 'validateConfig'; tests and generated-config checks use
-- the explicit seam so no filesystem or environment fallback can answer a
-- deployment-coordinate question.
validateConfigWithContext
  :: FilePath
  -> DeploymentContextInput
  -> ConfigFile
  -> IO (Either String ValidatedSettings)
validateConfigWithContext repoRoot contextInput config = do
  resolvedManualRoot <- makeAbsolute (repoRoot </> Text.unpack (manual_pv_host_root (storage config)))
  pure $ do
    -- Local commands (cluster, charts, host, config, gateway) decode and
    -- validate config WITHOUT requiring operational AWS credentials or the
    -- Route 53 / ACME public-edge fields. Those belong to the AWS / edge
    -- tier ('validateAwsBootstrapConfig' / 'validateOperationalAwsCredentials')
    -- and are validated lazily only when a command actually reaches AWS.
    validateLocalConfig config
    allocatedPlan <-
      mapLeft
        Allocation.renderCompileError
        (Allocation.compileResourcePlanUncertified (resource_plan (capacity config)))
    validateOneShotSecretWorkerCapacity (resource_plan (capacity config))
    -- Sprint 1.83: the public-edge parse is retained rather than repeated. The
    -- same call inside `validateLocalConfig` above is the refusal; this is the
    -- value, and it is the only one any consumer sees.
    publicEdge <- validatedPublicEdgeFor (domain config) (aws_substrate config)
    -- Sprint 1.89: the same move as the line above, for the rest of the
    -- coordinate surface. `validateLocalConfig` refuses on exactly these rules;
    -- this is the value it refused on.
    coordinates <- validatedCoordinatesFor config
    deploymentContext <- validatedDeploymentContextFor contextInput (cluster_topology config)
    pure
      ValidatedSettings
        { validatedConfig = config
        , resolvedManualPvHostRoot = resolvedManualRoot
        , validatedAllocatedPlan = allocatedPlan
        , validatedPublicEdge = publicEdge
        , validatedCoordinates = coordinates
        , validatedDeploymentContext = deploymentContext
        }

-- | Narrow every Tier-0 deployment-context coordinate exactly once.
validatedDeploymentContextFor
  :: DeploymentContextInput
  -> ClusterTopology
  -> Either String ValidatedDeploymentContext
validatedDeploymentContextFor contextInput topologyInput = do
  mapLeft renderTopologyError (validateClusterTopology topologyInput)
  clusterIdentity <- contextField "context.cluster_id" (contextInputClusterId contextInput)
  vaultEndpoint <- httpEndpointField "context.vault_address" (contextInputVaultAddress contextInput)
  minioEndpoint <- httpEndpointField "context.minio_endpoint" (contextInputMinioEndpoint contextInput)
  let machineIds = map machine_id (clusterTopologyMachines topologyInput)
  case (clusterType topologyInput, machineIds) of
    (ClusterTypeEks, []) -> pure ()
    (_, []) -> Left "cluster_topology must name at least one machine for this deployment context"
    _ -> pure ()
  Right
    ValidatedDeploymentContext
      { deploymentClusterId = clusterIdentity
      , deploymentVaultAddress = vaultEndpoint
      , deploymentMinioEndpoint = minioEndpoint
      , deploymentMachineIds = machineIds
      }

contextField :: String -> Text -> Either String Text
contextField fieldName raw
  | Text.null value = Left (fieldName ++ " must not be empty")
  | Text.any Char.isSpace value = Left (fieldName ++ " must not contain whitespace")
  | otherwise = Right value
 where
  value = Text.strip raw

httpEndpointField :: String -> Text -> Either String Text
httpEndpointField fieldName raw = do
  value <- contextField fieldName raw
  let lower = Text.toLower value
      authority
        | "http://" `Text.isPrefixOf` lower = Text.drop 7 value
        | "https://" `Text.isPrefixOf` lower = Text.drop 8 value
        | otherwise = Text.empty
  if Text.null authority || "/" `Text.isPrefixOf` authority
    then Left (fieldName ++ " must be an http:// or https:// endpoint with an authority")
    else Right value

-- | Sprint 1.89: build every Tier-0 coordinate, or refuse naming the field.
--
-- This is the builder behind the refusal-only section validators below, in
-- exactly the relationship Sprint 1.83 established between
-- 'validateConfiguredCertScope' and 'validatedPublicEdgeFor': each
-- @validate*Section@ is now @void@ over the corresponding builder, so there is
-- one rule per coordinate rather than a rule and a re-derivation that can drift.
--
-- The order matches 'validateLocalConfig' so the first refusal a config meets is
-- the same through either entry point.
validatedCoordinatesFor :: ConfigFile -> Either String ValidatedCoordinates
validatedCoordinatesFor config = do
  demoTtl <- demoTtlCoordinateFor (domain config)
  (substrateZoneId, _) <- awsSubstrateCoordinatesFor (aws_substrate config)
  (senderDomain, receiveSubdomain, captureBucket) <-
    sesCoordinatesFor (ses config)
  bootstrapIp <- bootstrapPublicIpCoordinateFor (deployment config)
  manualPvRoot <- storageCoordinateFor (storage config)
  (backendBucket, backendRegion, backendKeyPrefix) <-
    pulumiStateBackendCoordinatesFor (pulumi_state_backend config)
  homeZoneId <- homeZoneIdCoordinateFor (route53 config)
  acmeAccount <- acmeAccountCoordinateFor (acme config)
  operationalRegion <- awsRegionCoordinateFor "aws.region" (aws config)
  Right
    ValidatedCoordinates
      { coordinateHomeZoneId = homeZoneId
      , coordinateAwsSubstrateZoneId = substrateZoneId
      , coordinateOperationalAwsRegion = operationalRegion
      , coordinatePulumiBackendRegion = backendRegion
      , coordinatePulumiBackendBucket = backendBucket
      , coordinatePulumiBackendKeyPrefix = backendKeyPrefix
      , coordinateSesSenderDomain = senderDomain
      , coordinateSesReceiveSubdomain = receiveSubdomain
      , coordinateSesCaptureBucket = captureBucket
      , coordinateDemoTtl = demoTtl
      , coordinateBootstrapPublicIp = bootstrapIp
      , coordinateManualPvHostRoot = manualPvRoot
      , coordinateAcmeAccount = acmeAccount
      }

-- | Sprint 1.89: the ACME account, for a caller that needs one.
--
-- The pair is optional in config because a home-only host configures no ACME
-- account; it is required by the flows that issue certificates. This is where
-- those flows turn "declared" into "present", so the pure manifest renderers
-- downstream take an 'AcmeAccount' and have no absent case to render.
requireAcmeAccount :: ValidatedSettings -> Either String AcmeAccount
requireAcmeAccount settings =
  maybe
    (Left "acme.email must be configured to issue certificates")
    Right
    (coordinateAcmeAccount (validatedCoordinates settings))

-- | Sprint 1.89: the home Route 53 zone id, for a caller that needs one.
--
-- Optional in config (a home-only host that never touches AWS declares none),
-- required by every flow that reads or writes a home DNS record. This is the
-- one place that turns the first into the second.
requireHomeZoneId :: ValidatedSettings -> Either String Route53ZoneId
requireHomeZoneId settings =
  maybe
    (Left "route53.zone_id must be configured to reach the home Route 53 zone")
    Right
    (coordinateHomeZoneId (validatedCoordinates settings))

-- | Sprint 1.89: the home zone id as text, or empty when none is configured.
--
-- __This is a tolerance, and it is named so it is visible.__ Every consumer that
-- can refuse does, through 'requireHomeZoneId'. This exists for the two that
-- cannot, and the set is closed at two:
--
--   1. @Prodbox.Gateway.renderGatewayConfigTemplate@ — @prodbox gateway
--      config-gen@, which emits a __starter template the operator edits__. It
--      already renders @\"replace-with-home-cluster-id\"@ and @\"\/path\/to\/…\"@
--      placeholders, so a blank coordinate is the same kind of blank the
--      operator is being asked to fill in.
--   2. @Prodbox.TestValidation.renderGatewayValidationConfigDhall@ — the
--      /validation/ daemon config, whose @dns_write_gate@ names a zone the
--      harness never writes through.
--
-- Neither is a production DNS path and neither has an error channel. Reaching
-- for this anywhere else re-creates exactly the empty-string inhabitant Sprints
-- 1.84 and 1.87 spent two passes removing, which is why
-- @checkTier0CoordinateReads@ pins the call sites rather than trusting this
-- comment.
homeZoneIdTextForRendering :: ValidatedSettings -> Text
homeZoneIdTextForRendering settings =
  maybe Text.empty route53ZoneIdText (coordinateHomeZoneId (validatedCoordinates settings))

-- | Sprint 1.89: the operational region as text, or empty when none is
-- configured. The same closed tolerance as 'homeZoneIdTextForRendering', for the
-- same two renderers.
operationalAwsRegionTextForRendering :: ValidatedSettings -> Text
operationalAwsRegionTextForRendering settings =
  maybe Text.empty awsRegionText (coordinateOperationalAwsRegion (validatedCoordinates settings))

-- | Sprint 1.89: the operational AWS region, for a caller that needs one.
requireOperationalAwsRegion :: ValidatedSettings -> Either String AwsRegion
requireOperationalAwsRegion settings =
  maybe
    (Left "aws.region must be configured. Run `prodbox aws setup`.")
    Right
    (coordinateOperationalAwsRegion (validatedCoordinates settings))

-- | Sprint 1.91: the configured SES capture bucket, for a caller that needs one.
--
-- @prodbox aws policy@ prints the grant an operator pastes into IAM, and the
-- capture-bucket ARNs in it were compiled. A compiled bucket name in a printed
-- grant is worse than a missing one: the operator installs a policy that names
-- somebody else's bucket and discovers it as an @AccessDenied@ from S3 rather
-- than as a refusal from prodbox.
requireSesCaptureBucket :: ValidatedSettings -> Either String S3BucketName
requireSesCaptureBucket settings =
  maybe
    ( Left
        "ses.capture_bucket must be configured. Author it in the Tier-0 \
        \prodbox.dhall `parameters.ses` block."
    )
    Right
    (coordinateSesCaptureBucket (validatedCoordinates settings))

-- | Attach a field name to a coordinate refusal.
--
-- Every coordinate message in this module is produced here, which is why
-- 'CoordinateError' carries no field name of its own: the algebra knows the
-- rule and the call site knows the field, and joining them at one point is what
-- keeps the messages identical to the ones these rules produced before they
-- were types.
coordinateField
  :: String -> Either CoordinateError coordinate -> Either String coordinate
coordinateField fieldName =
  mapLeft (\err -> fieldName ++ " " ++ renderCoordinateError err)

-- | An optional coordinate: blank stays blank, present must parse.
optionalCoordinateField
  :: String
  -> (Text -> Either CoordinateError coordinate)
  -> Text
  -> Either String (Maybe coordinate)
optionalCoordinateField fieldName build rawValue =
  coordinateField
    fieldName
    (traverseOptionalCoordinate build (normalizeCoordinateText rawValue))

demoTtlCoordinateFor :: DomainSection -> Either String DnsTtl
demoTtlCoordinateFor domainSection =
  coordinateField "domain.demo_ttl" (mkDnsTtl (demo_ttl domainSection))

awsSubstrateCoordinatesFor
  :: AwsSubstrateSection -> Either String (Maybe Route53ZoneId, Maybe Fqdn)
awsSubstrateCoordinatesFor section = do
  -- Field order matches the refusal order this section has always had, so the
  -- first message a malformed pair produces is unchanged.
  subzone <- optionalFqdnCoordinate "aws_substrate.subzone_name" (subzone_name section)
  zoneId <-
    optionalCoordinateField
      "aws_substrate.hosted_zone_id"
      mkRoute53ZoneId
      (hosted_zone_id section)
  Right (zoneId, subzone)

sesCoordinatesFor
  :: SesSection -> Either String (Maybe Fqdn, Maybe DnsLabel, Maybe S3BucketName)
sesCoordinatesFor section = do
  senderDomain <- optionalFqdnCoordinate "ses.sender_domain" (sender_domain section)
  receiveSubdomain <-
    optionalCoordinateField "ses.receive_subdomain" mkDnsLabel (receive_subdomain section)
  captureBucket <-
    optionalCoordinateField "ses.capture_bucket" mkS3BucketName (capture_bucket section)
  Right (senderDomain, receiveSubdomain, captureBucket)

-- | An optional dotted name, minted through the repository's existing FQDN
-- constructor rather than a second rule of the same shape.
optionalFqdnCoordinate :: String -> Text -> Either String (Maybe Fqdn)
optionalFqdnCoordinate fieldName rawValue =
  case normalizeCoordinateText rawValue of
    Nothing -> Right Nothing
    Just value ->
      mapLeft
        (const (fieldName ++ " must be a valid fully qualified domain name"))
        (Just <$> mkFqdn value)

bootstrapPublicIpCoordinateFor :: DeploymentSection -> Either String (Maybe IpLiteral)
bootstrapPublicIpCoordinateFor section =
  coordinateField
    "deployment.bootstrap_public_ip_override"
    ( traverseOptionalCoordinate
        mkIpLiteral
        (normalizeMaybeText (bootstrap_public_ip_override section))
    )

storageCoordinateFor :: StorageSection -> Either String SafeRelativePath
storageCoordinateFor section =
  coordinateField
    "storage.manual_pv_host_root"
    (mkSafeRelativePath (manual_pv_host_root section))

pulumiStateBackendCoordinatesFor
  :: PulumiStateBackendSection
  -> Either String (Maybe S3BucketName, Maybe AwsRegion, SafeRelativePath)
pulumiStateBackendCoordinatesFor section = do
  bucket <-
    optionalCoordinateField
      "pulumi_state_backend.bucket_name"
      mkS3BucketName
      (psbBucketName section)
  -- Sprint 1.89: this field had no rule at all. Its two siblings did.
  region <-
    optionalCoordinateField "pulumi_state_backend.region" mkAwsRegion (psbRegion section)
  keyPrefix <-
    coordinateField
      "pulumi_state_backend.key_prefix"
      (mkSafeRelativePath (psbKeyPrefix section))
  Right (bucket, region, keyPrefix)

-- | Sprint 1.89: @route53.zone_id@ gains the shape rule
-- @aws_substrate.hosted_zone_id@ has always had.
--
-- It stays /optional/ here, and that is not a weakening: an empty home zone id
-- is the correct state for a host that never touches AWS, which is why
-- 'validateLocalConfig' never required it and why requiring it now would refuse
-- configs that work. What changes is that a non-empty value must be a zone id.
-- The AWS tier's existing @requireNonEmpty@ still supplies the presence rule
-- where presence is genuinely required.
homeZoneIdCoordinateFor :: Route53Section -> Either String (Maybe Route53ZoneId)
homeZoneIdCoordinateFor section =
  optionalCoordinateField "route53.zone_id" mkRoute53ZoneId (zone_id section)

-- | The optional operator-authored ACME contact paired with the one compiled
-- ZeroSSL directory. The directory is protocol vocabulary rather than a Dhall
-- choice, so absence is decided solely by whether @acme.email@ is authored.
acmeAccountCoordinateFor :: AcmeSection -> Either String (Maybe AcmeAccount)
acmeAccountCoordinateFor section = do
  parsedEmail <- optionalCoordinateField "acme.email" mkEmailAddress (email section)
  case parsedEmail of
    Nothing -> Right Nothing
    Just parsed -> do
      directory <-
        coordinateField
          "compiled ZeroSSL ACME directory"
          (mkAcmeDirectoryUrl zeroSslAcmeDirectory)
      Right (Just (AcmeAccount parsed directory))

-- | Sprint 1.89: @aws.region@ gains a shape rule.
--
-- 'validateAwsCredentialsRef' checks the three 'SecretRef' fields beside this
-- one and has never touched the region; 'validateOperationalAwsCredentials'
-- checks it for emptiness on AWS-touching flows only. So on every local load the
-- region was entirely undecided, and the first thing to notice a typo was the
-- AWS endpoint resolver.
-- The field name is a parameter because 'validateAwsCredentialsRef' is
-- prefix-parameterised; passing @\"aws.region\"@ from here and @prefix ++
-- \".region\"@ from there would be two names for one field waiting to disagree.
awsRegionCoordinateFor :: String -> AwsCredentialsRef -> Either String (Maybe AwsRegion)
awsRegionCoordinateFor fieldName refs =
  optionalCoordinateField fieldName mkAwsRegion (awsCredentialRegion refs)

-- | Purely-local config invariants. No operational AWS credentials, Route 53
-- zone, or ACME account are required here, so a host with an empty @aws.*@
-- block still decodes config for every local cluster command.
--
-- Sprint 1.81: this is a __positional__ constructor pattern, not a list of checks
-- over field accessors. The distinction is the whole point. As a list it never
-- mentioned the record, so @-Wall@ had nothing to warn about and a field added to
-- 'ConfigFile' was skipped by construction — four sections (@ses@,
-- @pulumi_state_backend@, @storage@, @components@) had in fact accumulated no
-- coverage at all.
--
-- The pattern is positional rather than the field-named form the sprint first
-- proposed, and the reason was established by trying it: a __named__ record
-- pattern is not a forcing function at all. @ConfigFile{ aws = a, … }@ silently
-- ignores fields it does not mention, and GHC has no warning for it — adding a
-- field to the record produced an objection only at an unrelated /construction/
-- site, never here. A positional pattern makes the arity a compile error at
-- exactly the place that must decide whether the new field needs checking, which
-- is what was actually wanted. The cost is that the bindings must stay in field
-- order; that is why each is named after its field.
--
-- This is the *Totality* class of
-- [chaos_hardening_doctrine.md § 21](../../../documents/engineering/chaos_hardening_doctrine.md),
-- and the companion to Sprint 1.79 — the same record, the other partial fold.
--
-- Note the bound honestly: making the fold total says every field is *visited*,
-- not that every field is *well-typed*.
--
-- Sprint 1.89 closed the second half. Every coordinate this fold decides is now
-- decided by a smart constructor in "Prodbox.Settings.Coordinate" whose result
-- 'validateConfig' keeps as 'ValidatedCoordinates', so a consumer reads the
-- parsed value rather than re-reading the raw field. The counts this Haddock
-- used to carry — "~30 `Text` and ~40 `Natural`" — were restatements and both
-- were wrong; Sprint 1.88 measured 27 and 18 against them. They are not restated
-- here, because the registry `checkTier0CoordinateReads` enforces is the
-- inventory, and a number in prose beside it is exactly the drift that made the
-- original figures wrong.
validateLocalConfig :: ConfigFile -> Either String ()
validateLocalConfig
  ( ConfigFile
      awsSection
      route53Section
      awsSubstrateSection
      sesSection
      domainSection
      acmeSection
      deploymentSection
      capacitySection
      clusterTopologySection
      storageSection
      pulumiStateBackendSection
      retainedArtifactsSection
      componentNodes
    ) = do
    validateConfiguredCertScope domainSection awsSubstrateSection
    validateDemoTtl (demo_ttl domainSection)
    validateAwsCredentialsRef "aws" awsSection
    validateAwsSubstrateSection awsSubstrateSection
    validateSesSection sesSection
    validatePublicEdgeDeployment deploymentSection
    validateCapacitySection capacitySection
    mapLeft renderTopologyError (validateClusterTopology clusterTopologySection)
    validateStorageSection storageSection
    validatePulumiStateBackendSection pulumiStateBackendSection
    validateRetainedArtifactsSection retainedArtifactsSection
    validateComponentNodes componentNodes
    validateLocallyOptionalCoordinates route53Section acmeSection

-- | Sprint 4.86: the operator-declared retained artifacts.
--
-- Validated by projecting them, rather than by a second list of shape rules:
-- the inventory and the source catalog a recovery consumes are exactly what
-- this projection produces, so a declaration that loads here is one a repair
-- can be rendered against. A malformed digest, an unsafe retained path, an
-- unusable locator, a duplicate kind, or an unrecognized architecture or kind
-- is refused at config load rather than at the moment a control plane is
-- already gone.
validateRetainedArtifactsSection :: RetainedArtifactsSection -> Either String ()
validateRetainedArtifactsSection section =
  case declaredRetainedArtifacts section of
    Left err -> Left (renderRetainedArtifactDeclarationError err)
    Right _ -> Right ()

-- | Sprint 1.89: the two sections with no purely-local /presence/ rule.
--
-- This function replaces @ignoreLocallyUnconstrained@, whose name and comment
-- both said these sections "carry no purely-local invariant". That was true of
-- presence and false of shape, and the difference mattered: an empty
-- @route53.zone_id@ and an empty ACME account are the correct state for a host
-- that never touches AWS — but @route53.zone_id = \"not-a-zone\"@ was not
-- correct anywhere, and nothing anywhere refused it. The AWS tier's
-- 'validateAwsBootstrapConfig' supplies the presence rule; this supplies the
-- shape rule that was missing, on every load, for a value that is only ever
-- optional.
validateLocallyOptionalCoordinates
  :: Route53Section -> AcmeSection -> Either String ()
validateLocallyOptionalCoordinates route53Section acmeSection = do
  void (homeZoneIdCoordinateFor route53Section)
  void (acmeAccountCoordinateFor acmeSection)

-- | Sprint 1.81: the AWS substrate coordinates. Both fields are legitimately
-- empty on a home-only host — and @hosted_zone_id@ is legitimately empty even
-- when @subzone_name@ is set, because 'Prodbox.PublicEdge.resolveSubstrateHostedZoneId'
-- consults the live @aws-eks-subzone@ stack snapshot in that case. So this
-- refuses only a value that is present and malformed; it deliberately does not
-- require the two to be set together.
validateAwsSubstrateSection :: AwsSubstrateSection -> Either String ()
validateAwsSubstrateSection = void . awsSubstrateCoordinatesFor

-- | Require the fully narrowed AWS resource envelope at the AWS mutation
-- boundary. Home-only config keeps @profile = None@; no AWS flow may turn that
-- absence into a compiled deployment shape.
requireAwsSubstrateProfile :: ValidatedSettings -> Either String AwsSubstrateProfile
requireAwsSubstrateProfile settings =
  case profile (aws_substrate (validatedConfig settings)) of
    Nothing ->
      Left
        "aws_substrate.profile is required for AWS substrate provisioning; author every profile field in Tier-0 Dhall"
    Just authored -> Right authored

-- | Sprint 1.81: the SES identity coordinates. Empty is the correct state for a
-- host with no SES workflow, so each field is checked only when set.
validateSesSection :: SesSection -> Either String ()
validateSesSection = void . sesCoordinatesFor

-- | Sprint 1.81: the manual-PV host root is joined onto the repository root by
-- 'validateConfig', so a value that escapes it is a path traversal expressed as
-- config. It must be a safe relative path: non-empty, not absolute, and with no
-- @..@ segment.
validateStorageSection :: StorageSection -> Either String ()
validateStorageSection = void . storageCoordinateFor

-- | Sprint 1.81: the long-lived Pulumi state backend. Bucket and region are
-- empty until the backend is provisioned, so they are checked only when set; the
-- key prefix is always present and must be a safe relative path, because it is
-- concatenated into object keys.
validatePulumiStateBackendSection :: PulumiStateBackendSection -> Either String ()
validatePulumiStateBackendSection = void . pulumiStateBackendCoordinatesFor

-- | Sprint 1.81: the component graph is validated at DECODE rather than only at
-- projection. Before this, an authored graph with a cycle, a dangling edge, or a
-- probe that cannot satisfy its declared edge decoded cleanly and failed later,
-- at bring-up.
validateComponentNodes :: [ComponentNode] -> Either String ()
validateComponentNodes nodes =
  case validateComponentGraph nodes of
    Left err -> Left ("components: " ++ renderComponentGraphError err)
    Right _ -> Right ()

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
  validateAcmeBinding (acme config)
  -- Sprint 1.81: the AWS-substrate public hostname is required on THIS tier and
  -- only on this tier. It used to be checked by a partial `error` at its point of
  -- use in the former @Prodbox.PublicEdge.substratePublicFqdn@, which turned a
  -- config mistake into a crash. It is not checked in 'validateLocalConfig' because an
  -- empty `subzone_name` is the correct state for a home-only host.
  requireNonEmpty "aws_substrate.subzone_name" (subzone_name (aws_substrate config))

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
  -- Sprint 1.89: one rule, shared with the builder that keeps the value.
  validateBootstrapOverride = void (bootstrapPublicIpCoordinateFor deploymentSection)
  -- Sprint 1.80: a total match over the union. The "must be l2 or bgp when set"
  -- arm is gone because there is nothing left for it to reject — Dhall refuses a
  -- misspelling at type-check. What remains is the cross-field rule Dhall cannot
  -- express.
  validateAdvertisementMode =
    case public_edge_advertisement_mode deploymentSection of
      Nothing -> Right ()
      Just AdvertiseLayer2 -> Right ()
      Just AdvertiseBgp ->
        case public_edge_bgp_peers deploymentSection of
          Just peers
            | not (null peers) ->
                mapM_ (uncurry validateBgpPeer) (zip [1 :: Int ..] peers)
          _ ->
            Left
              "deployment.public_edge_bgp_peers must contain at least one non-empty peer when deployment.public_edge_advertisement_mode is bgp"

requireNonEmpty :: String -> Text -> Either String ()
requireNonEmpty fieldName value =
  if Text.strip value == ""
    then Left (fieldName ++ " must not be empty")
    else Right ()

validateBgpPeer :: Int -> MetallbBgpPeer -> Either String ()
validateBgpPeer index peer = do
  requireNonEmpty fieldPrefixName (peer_name peer)
  requireNonEmpty fieldPrefixAddress (peer_address peer)
  validateOptionalIpAddressField fieldPrefixAddress (normalizeCoordinateText (peer_address peer))
 where
  fieldPrefix = "deployment.public_edge_bgp_peers[" ++ show index ++ "]"
  fieldPrefixName = fieldPrefix ++ ".peer_name"
  fieldPrefixAddress = fieldPrefix ++ ".peer_address"

-- | Sprint 1.89: the rule now lives in "Prodbox.Settings.Coordinate"; this is
-- the field-naming wrapper the BGP-peer fold still wants, because a peer's
-- address is refused with its index in the message.
validateOptionalIpAddressField :: String -> Maybe Text -> Either String ()
validateOptionalIpAddressField fieldName maybeValue =
  coordinateField fieldName (void (traverseOptionalCoordinate mkIpLiteral maybeValue))

-- | Sprint 2.35: the served host must be covered by the configured certificate
-- scope set, and every configured scope must be well-formed — a wildcard only at
-- a delegated zone. Empty @cert_scopes@ means "just the served host", so the
-- default is behavior-identical to the pre-2.35 single-host pin (which is why no
-- widening happens until an operator adds a scope). Illegal states — an uncovered
-- served host, a malformed name, a wildcard at an undelegated zone — are rejected
-- fail-closed at config-validation time.
validateConfiguredCertScope :: DomainSection -> AwsSubstrateSection -> Either String ()
validateConfiguredCertScope domainSection awsSection =
  void (validatedPublicEdgeFor domainSection awsSection)

-- | Sprint 1.83: the builder behind 'validateConfiguredCertScope'.
--
-- 'validateConfiguredCertScope' is now exactly this with its result discarded,
-- which is honest for a refusal-only check inside 'validateLocalConfig'. What
-- changed is that the __value__ is no longer discarded everywhere:
-- 'validateConfig' — the sole constructor of 'ValidatedSettings' — keeps it, so
-- the parse happens once per config rather than once per consumer.
validatedPublicEdgeFor
  :: DomainSection -> AwsSubstrateSection -> Either String ValidatedPublicEdge
validatedPublicEdgeFor domainSection awsSection
  | Text.null (Text.strip (demo_fqdn domainSection)) =
      Left "domain.demo_fqdn must not be empty"
  | otherwise = do
      home <- servedHostFor (demo_fqdn domainSection)
      let awsServedHost = Text.strip (subzone_name awsSection)
      aws <-
        if Text.null awsServedHost
          then Right Nothing
          else Just <$> servedHostFor awsServedHost
      Right
        ValidatedPublicEdge
          { validatedHomeServedHost = home
          , validatedAwsServedHost = aws
          }
 where
  servedHostFor raw = do
    parsed <- mapLeft (\e -> "served hostname: " ++ renderScopeError e) (mkFqdn raw)
    scopeSet <- certScopeSetForServedHost domainSection awsSection raw
    Right ValidatedServedHost {servedHostFqdn = parsed, servedHostCertScopes = scopeSet}

-- | The served host a substrate presents, or 'Nothing' when this config declares
-- none for it.
--
-- 'Nothing' is reachable only for 'SubstrateAws' on a config the AWS tier never
-- validated, which is exactly the state Sprint 1.81 left representable as the
-- empty string. Every caller consumes it through
-- 'Prodbox.PublicEdge.requireSubstrateServedHost' (or its string- and
-- scope-projecting siblings) and refuses.
--
-- Sprint 1.87 removed the bound that used to be stated here. The former
-- @Prodbox.PublicEdge.substratePublicFqdn@, which answered @\"\"@ for this
-- 'Nothing', is deleted: the public-edge renderers take a 'ValidatedServedHost'
-- rather than a @ValidatedSettings@ and a 'Prodbox.Substrate.Substrate', so
-- there is no longer a pure renderer with nowhere to put a refusal — the
-- refusal happens before the renderer is reached, and the renderer's host
-- argument has no empty inhabitant.
substrateServedHost :: ValidatedSettings -> Substrate -> Maybe ValidatedServedHost
substrateServedHost settings substrate = case substrate of
  SubstrateHomeLocal -> Just (validatedHomeServedHost edge)
  SubstrateAws -> validatedAwsServedHost edge
 where
  edge = validatedPublicEdge settings

-- | The configured 'CertScopeSet' as seen from a specific served host (the home
-- served host on the home substrate, the AWS subzone on the AWS substrate). The
-- delegated-zone anchors are the same config-declared set; only the empty-scope
-- default changes — an empty @cert_scopes@ means "just this served host", so
-- each substrate's certificate defaults to exactly its own served FQDN and there
-- is no behavior change until an operator widens scope. Sprint 2.35.
certScopeSetForServedHost
  :: DomainSection -> AwsSubstrateSection -> Text -> Either String CertScopeSet
certScopeSetForServedHost domainSection awsSection servedHost = do
  parsedServedHost <-
    mapLeft (\e -> "served hostname: " ++ renderScopeError e) (mkFqdn servedHost)
  zones <- traverse parseZone (configuredDelegatedZoneNames domainSection awsSection)
  scopes <- traverse parseScope rawScopeNames
  scopeSet <- mapLeft renderScopeError (mkScopeSet zones scopes)
  _ <-
    mapLeft
      (\e -> "domain.cert_scopes: " ++ renderScopeError e)
      (bindListener scopeSet parsedServedHost)
  Right scopeSet
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
-- __Sprint 1.85: kept as a named contract, deliberately.__ Sprint 1.83 replaced
-- this function's one production consumer (the keycloak @dnsNames@ projection)
-- with 'certScopeSetDnsNames' over the scope set 'ValidatedServedHost' already
-- carries, leaving it reachable only from tests. The ledger recorded the choice
-- — inline it into the contract cases, or keep it — so that it was made rather
-- than inherited.
--
-- It is kept, and made load-bearing rather than merely retained. This is not the
-- guard-shaped defect Sprint 1.82 closed: nothing reads as enforced while
-- enforcing nothing, because it is a one-line projection of
-- 'certScopeSetForServedHost', which /is/ production-reachable through
-- 'validatedPublicEdgeFor'. A unit case now asserts that for a validated config
-- this contract and the carried scope set agree on both substrates, which pins
-- the provenance property Sprint 1.83 established: the carried set /is/ the
-- parse, not a second derivation free to drift from it. Inlining it would have
-- deleted the only place that agreement is stated.
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
validateDemoTtl ttl =
  coordinateField "domain.demo_ttl" (void (mkDnsTtl ttl))

-- | Sprint 7.15: the ZeroSSL external-account-binding (EAB) key ID and HMAC
-- key are no longer plaintext @Optional Text@; they are @SecretRef.Vault@
-- references into @secret/acme/eab@ (fields @key_id@ / @hmac_key@), resolved
-- through Vault exactly like the operational @aws.*@ credentials. ZeroSSL
-- still requires both present; non-ZeroSSL servers may omit both; one without
-- the other is rejected; and a plaintext (non-@Vault@) reference is rejected
-- through the same 'validateVaultRef' discipline used for @aws.*@.
validateAcmeBinding :: AcmeSection -> Either String ()
validateAcmeBinding acmeSection
  | eab_key_id acmeSection == Nothing || eab_hmac_key acmeSection == Nothing =
      Left "acme.eab_key_id and acme.eab_hmac_key are required for ZeroSSL ACME"
  | otherwise = do
      mapM_ (validateVaultRef "acme.eab_key_id") (eab_key_id acmeSection)
      mapM_ (validateVaultRef "acme.eab_hmac_key") (eab_hmac_key acmeSection)

validateAwsCredentialsRef :: String -> AwsCredentialsRef -> Either String ()
validateAwsCredentialsRef prefix refs = do
  validateVaultRef (prefix ++ ".access_key_id") (awsCredentialAccessKeyId refs)
  validateVaultRef (prefix ++ ".secret_access_key") (awsCredentialSecretAccessKey refs)
  mapM_ (validateVaultRef (prefix ++ ".session_token")) (awsCredentialSessionToken refs)
  -- Sprint 1.89: the fourth field. This function checked the three 'SecretRef's
  -- and skipped the region beside them, so on a local load the region was
  -- decided by nothing at all — the AWS tier's 'validateOperationalAwsCredentials'
  -- checks only that it is non-empty, and only when an AWS flow runs.
  void (awsRegionCoordinateFor (prefix ++ ".region") refs)

validateVaultRef :: String -> SecretRef -> Either String ()
validateVaultRef fieldName ref =
  case ref of
    SecretRefVault _ -> Right ()
    _ -> Left (fieldName ++ " must be a SecretRef.Vault reference")

-- | Sprint 1.89: the blank-is-absent rule now has one implementation
-- ('normalizeCoordinateText'); this lifts it over an already-optional field.
normalizeMaybeText :: Maybe Text -> Maybe Text
normalizeMaybeText maybeValue = maybeValue >>= normalizeCoordinateText

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

-- | Sprint 1.91: the generated @aws.*@ block, with @region@ emitted __empty__.
--
-- It took a 'Text' argument and 'defaultConfigFile' passed a literal region, so
-- every @prodbox config generate@ output arrived pre-filled with a region
-- nobody chose and the three refusals written against an absent one
-- ('requireOperationalAwsRegion', 'validateOperationalAwsCredentials', and
-- @validateLifecycleProviderAwsRegion@) were unreachable code. The argument is
-- gone rather than passed empty, so a seeded region is not expressible here at
-- all — the shape @config_doctrine.md@ § 0 names under "a seeded non-empty
-- default is a compiled default".
operationalAwsCredentialsRef :: AwsCredentialsRef
operationalAwsCredentialsRef =
  AwsCredentialsRef
    { awsCredentialAccessKeyId = vaultRef "aws/lifecycle-provider" "access_key_id"
    , awsCredentialSecretAccessKey = vaultRef "aws/lifecycle-provider" "secret_access_key"
    , awsCredentialSessionToken = Nothing
    , awsCredentialRegion = Text.empty
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
    { aws = operationalAwsCredentialsRef
    , route53 = Route53Section {zone_id = ""}
    , aws_substrate =
        AwsSubstrateSection
          { hosted_zone_id = ""
          , subzone_name = ""
          , profile = Nothing
          }
    , ses =
        SesSection
          { sender_domain = ""
          , receive_subdomain = ""
          , capture_bucket = ""
          }
    , domain =
        DomainSection
          { demo_fqdn = ""
          , demo_ttl = 60
          , cert_scopes = []
          }
    , acme =
        AcmeSection
          { email = ""
          , eab_key_id = Just (vaultRef "acme/eab" "key_id")
          , eab_hmac_key = Just (vaultRef "acme/eab" "hmac_key")
          }
    , deployment =
        DeploymentSection
          { dev_mode = True
          , bootstrap_public_ip_override = Nothing
          , pulumi_enable_dns_bootstrap = True
          , public_edge_advertisement_mode = Just AdvertiseLayer2
          , public_edge_bgp_peers = Nothing
          , envoy_gateway_controller_scaling = fixedScalingPolicyBySubstrate 1
          , envoy_gateway_data_plane_scaling = fixedScalingPolicyBySubstrate 1
          , api_scaling = fixedScalingPolicyBySubstrate 2
          , websocket_scaling = fixedScalingPolicyBySubstrate 2
          }
    , capacity = defaultCapacitySection
    , cluster_topology = unconfiguredClusterTopology
    , storage = StorageSection {manual_pv_host_root = ".data"}
    , pulumi_state_backend =
        PulumiStateBackendSection
          { psbBucketName = ""
          , psbRegion = ""
          , psbKeyPrefix = "pulumi/"
          }
    , retained_artifacts = emptyRetainedArtifactsSection
    , components = defaultComponentGraph
    }

-- | The unauthored value emitted by @prodbox config generate@.
--
-- Keep this distinct from 'defaultConfigFile': the latter is a valid value used
-- by pure tests and builders, while generated operator input must never acquire
-- a compiled deployment identity, public hostname, or machine identity.
configGenerationTemplate :: ConfigFile
configGenerationTemplate = defaultConfigFile

-- | Render the canonical in-force config payload from the Haskell record.
--
-- Sprint 1.79: derived through @'Dhall.inject' \@'ConfigFile'@ — the same
-- mechanism "Prodbox.Config.Tier0" already uses for the Tier-0 file — rather
-- than a hand-written field-by-field emitter.
--
-- The emitter it replaces produced @Config::{…}@ and __never emitted
-- @components@__. Because Dhall record completion refills an omitted field from
-- the schema default, an operator-authored component graph was silently replaced
-- by @defaultComponentGraph@ in the payload — and that payload is the canonical
-- in-force config, submitted by 'reconcileInForceConfigFromFile' and read back by
-- every runtime load. The Tier-0 /file/ path renders the same record through
-- 'Dhall.inject' and is total, so two renderers of one record disagreed about
-- what the record contains, and the value survived exactly where it did not
-- matter and was lost where it did.
--
-- Deriving it removes the class rather than the instance: a field added to
-- 'ConfigFile' is emitted because the instance is generic, not because someone
-- remembered a line.
--
-- Two consequences worth stating:
--
--   * The emitted payload no longer imports @./prodbox-config-types.dhall@; an
--     injected value is self-contained. 'decodeConfigDhallBytes' still
--     materializes the schema beside the payload, deliberately — a payload
--     stored by the superseded renderer still carries that import, and dropping
--     the materialization would make already-stored in-force objects
--     undecodable.
--   * The bytes change. That is the fix, not a regression: what must be stable
--     is the /record/, and the round-trip assertion pins exactly that.
renderConfigDhall :: ConfigFile -> String
renderConfigDhall config =
  Text.unpack (Core.pretty injected) ++ "\n"
 where
  injected :: Core.Expr Src Void
  injected = Core.denote (Dhall.embed (Dhall.inject @ConfigFile) config)

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
