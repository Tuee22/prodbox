{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Prodbox.Aws
  ( AwsSetupInput (..)
  , AwsCheckQuotasInput (..)
  , AwsTeardownInput (..)
  , AwsTeardownLongLivedPreflight
  , ConfigSetupInput (..)
  , QuotaSpec (..)
  , QuotaStatus (..)
  , configFromSetupInput
  , harnessConfigSetupInput
  , regenerateConfigFromTestSecrets
  , IamProbe (..)
  , PulumiResiduePolicy (..)
  , ResidueError (..)
  , SessionTokenPromptShape (..)
  , SpotPriceRequest (..)
  , VaultProbe (..)
  , adminAwsEnvironment
  , applyAwsCheckQuotas
  , applyAwsRegionQuotaPreflight
  , applyAwsTeardown
  , awsRegionQuotaPreflightFromStatuses
  , assertOperationalTeardownComplete
  , awsErrorCodeIsTransient
  , awsSpotPriceHistoryArgs
  , buildIamPolicyDocument
  , buildIamPolicyDocumentForAccount
  , buildIamPolicyDocumentForAccountAndCaptureBucket
  , buildIamPolicyJson
  , checkPulumiResidueBeforeTeardown
  , harnessPostflightResiduePolicy
  , residuePolicyBypassesLongLivedProtection
  , longLivedResourceNames
  , operationalAwsConfigResidueFromKey
  , operationalBootstrapDnsRecordExists
  , operationalCredentialsClearedDecision
  , operationalIamUserExists
  , operationalIamUserResidueFromExists
  , operationalManagedResources
  , observeAwsSpotPrice
  , refineAwsConfigResidueAgainstIamUser
  , partitionResidueByLifecycle
  , perRunStackNames
  , spotObservationFromAwsSpotPriceHistory
  , spotObservationFromAwsSpotPriceOutput
  , renderResidueError
  , residueFromProbe
  , promptAdminCredentialsWithRegionChoice
  , prodboxIamUserName
  , pulumiDestroyPlanForResidue
  , quotaStatusRegionObservation
  , renderAwsSetupPlan
  , renderAwsTeardownPlan
  , renderConfigSetupPlan
  , renderPulumiResidueRefusal
  , renderPulumiResidueLongLivedRefusal
  , runAwsCommand
  , runAwsIamHarnessInspect
  , runAwsIamHarnessSetup
  , runAwsIamHarnessTeardown
  , runInteractiveConfigSetup
  , runInteractiveConfigSetupWithPlan
  , sessionTokenPromptShape
  , validateAdminCredentialsInput
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception
  ( Exception
  , IOException
  , SomeException
  , bracket_
  , displayException
  , fromException
  , throwIO
  , try
  )
import Control.Monad (forM, unless, when)
import Data.Aeson
  ( Array
  , Object
  , Value (..)
  , eitherDecode
  , encode
  , object
  , (.=)
  )
import Data.Aeson.Encode.Pretty qualified as AesonPretty
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (isAlphaNum, isAsciiLower, isAsciiUpper, isSpace, toLower)
import Data.List
  ( findIndex
  , intercalate
  , isPrefixOf
  , partition
  , transpose
  )
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Numeric.Natural (Natural)
import Prodbox.Aws.AdminCredentials
  ( SessionTokenPromptShape (..)
  , acquireAdminAwsCredentials
  , promptAdminCredentials
  , sessionTokenPromptShape
  , validateAdminCredentialsInput
  )
import Prodbox.AwsEnvironment
  ( awsCliSubprocessEnvironment
  )
import Prodbox.BuildSupport (canonicalOperatorBinaryPath)
import Prodbox.CLI.Command
  ( AwsCommand (..)
  , AwsTeardownFlags (..)
  , Plan (..)
  , PlanOptions (..)
  , PolicyTier (..)
  , PulumiResiduePolicy (..)
  , buildPlan
  , runPlanWithOptions
  )
import Prodbox.CLI.Interactive
  ( awsCheckQuotasGuard
  , awsRequestQuotasGuard
  , awsSetupGuard
  , awsTeardownGuard
  , configSetupGuard
  , requireInteractiveTty
  )
import Prodbox.CLI.Output
  ( writeDiagnosticLine
  , writeError
  , writeOutput
  , writeOutputLine
  )
import Prodbox.Capacity.Storage
  ( AwsRegionQuotaObservation (..)
  , StorageCapacityRefusal
  , regionQuotaPreflight
  )
import Prodbox.Config.Tier0 qualified as Tier0
import Prodbox.Error (fatalError)
import Prodbox.Gateway.Client qualified as GatewayClient
import Prodbox.Host (defaultGatewayNodePort)
import Prodbox.Infra.AwsEksTestStack
  ( awsEksCanonicalClusterName
  )
import Prodbox.Infra.AwsSesLeaseRole qualified as AwsSesLeaseRole
import Prodbox.Infra.StackDescriptor
  ( perRunStackDescriptorNames
  )
import Prodbox.Lifecycle.EbsVolume qualified as EbsVolume
import Prodbox.Lifecycle.LiveResidue
  ( PerRunResidueStatuses (..)
  , queryAwsSesResidueStatus
  , queryPerRunResidueStatuses
  )
import Prodbox.Lifecycle.ResidueStatus qualified as ResidueStatus
import Prodbox.Lifecycle.ResourceClass qualified as ResourceClass
import Prodbox.Lifecycle.ResourceRegistry
  ( ManagedResource (..)
  , pairAwsSesResidue
  , pairPerRunResidue
  , reconcileAbsent
  , residueGateRefusalList
  )
import Prodbox.Repo
  ( resolveTier0ConfigPath
  , tier0ConfigFileName
  )
import Prodbox.Result (Result (..))
import Prodbox.Scaling.Spot
  ( SpotObservation (..)
  , UnobservableReason (..)
  , UsdPerHour
  , parseUsdPerHour
  )
import Prodbox.Settings
  ( AcmeSection (..)
  , AwsCredentialsRef (..)
  , ConfigFile (..)
  , Credentials (..)
  , DeploymentSection (..)
  , DomainSection (..)
  , MetallbBgpPeer (..)
  , PulumiStateBackendSection (..)
  , Route53Section (..)
  , SesSection (..)
  , StorageSection (..)
  , defaultConfigFile
  , loadConfigFile
  , resolveAwsCredentialsRefFromHostVault
  , supportedPublicHostname
  , validateAndLoadSettings
  , validateAwsBootstrapConfig
  , validatePublicEdgeDeployment
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , runSubprocessStreaming
  )
import Prodbox.Substrate
  ( ScalingPolicyBySubstrate
  , fixedScalingPolicyBySubstrate
  )
import Prodbox.Vault.Host
  ( AcmeEabFixture (hmac_key, key_id)
  , TestSecrets
    ( acme_eab
    , pulumi_state_backend_bucket_name
    , pulumi_state_backend_region
    , route53_zone_id
    , ses_capture_bucket
    , ses_receive_subdomain
    , ses_sender_domain
    )
  , loadTestSecrets
  , seedAcmeEabFromTestSecrets
  , writeHostVaultKvObject
  )
import System.Directory
  ( doesFileExist
  )
import System.Environment
  ( lookupEnv
  )
import System.Exit
  ( ExitCode (ExitFailure, ExitSuccess)
  )
import System.FilePath
  ( takeDirectory
  , (</>)
  )
import System.IO
  ( hFlush
  , hGetEcho
  , hIsTerminalDevice
  , hSetEcho
  , stdin
  , stdout
  )
import System.IO.Error (isEOFError)

data SpotPriceRequest = SpotPriceRequest
  { spotPriceInstanceType :: Text
  , spotPriceProductDescription :: Text
  }
  deriving (Eq, Show)

newtype AwsError = AwsError String
  deriving (Show)

instance Exception AwsError where
  displayException (AwsError message) = message

data RegionChoice = RegionChoice
  { regionChoiceName :: Text
  , regionChoiceOptInStatus :: Text
  }
  deriving (Eq, Show)

data HostedZoneChoice = HostedZoneChoice
  { hostedZoneChoiceId :: Text
  , hostedZoneChoiceName :: Text
  }
  deriving (Eq, Show)

data QuotaSpec = QuotaSpec
  { quotaDisplayName :: Text
  , quotaServiceCode :: Text
  , quotaCode :: Text
  , quotaTargetValue :: Double
  }
  deriving (Eq, Show)

data QuotaStatus = QuotaStatus
  { quotaStatusDisplayName :: Text
  , quotaStatusServiceCode :: Text
  , quotaStatusQuotaCode :: Text
  , quotaStatusCurrentValue :: Double
  , quotaStatusTargetValue :: Double
  , quotaStatusSource :: Text
  , quotaStatusMeetsTarget :: Bool
  , quotaStatusRequestStatus :: Maybe Text
  , quotaStatusNote :: Maybe Text
  }
  deriving (Eq, Show)

data IamSetupResult = IamSetupResult
  { iamSetupUserName :: Text
  , iamSetupPolicyTier :: PolicyTier
  , iamSetupAccessKeyId :: Text
  , iamSetupCredentialSource :: Text
  , iamSetupQuotaStatuses :: [QuotaStatus]
  , iamSetupDhallPath :: FilePath
  }
  deriving (Eq, Show)

data IamTeardownResult = IamTeardownResult
  { iamTeardownUserName :: Text
  , iamTeardownDeletedAccessKeys :: [Text]
  , iamTeardownUserDeleted :: Bool
  , iamTeardownDhallPath :: FilePath
  }
  deriving (Eq, Show)

data IamUserCleanupResult = IamUserCleanupResult
  { iamUserCleanupUserName :: Text
  , iamUserCleanupDeletedAccessKeys :: [Text]
  , iamUserCleanupUserDeleted :: Bool
  }
  deriving (Eq, Show)

data EksIamOrphanCleanupResult = EksIamOrphanCleanupResult
  { eksIamOrphanCleanupSkippedReason :: Maybe Text
  , eksIamOrphanCleanupDeletedPolicies :: [Text]
  , eksIamOrphanCleanupDeletedRoles :: [Text]
  }
  deriving (Eq, Show)

-- | Sprint 7.20: the observed AWS-side state of the operational @prodbox@
-- IAM user AFTER teardown, fed to the pure teardown-completeness
-- classifier 'residueFromProbe'. Both facts are carried independently so
-- the classifier can name precisely what leaked: a present user, leftover
-- access keys, or both. Populated by the effectful wrapper
-- 'assertOperationalTeardownComplete' from the existing
-- 'operationalIamUserExists' (user) and 'listOperationalAccessKeyIds'
-- (keys) probes. No IO; pure value.
data IamProbe = IamProbe
  { iamProbeUserPresent :: Bool
  -- ^ Whether @iam:get-user prodbox@ still resolves.
  , iamProbeAccessKeyIds :: [Text]
  -- ^ Access-key IDs still attached to the operational user (empty when
  -- the user is gone or has no remaining keys).
  }
  deriving (Eq, Show)

-- | Sprint 7.20: the observed Vault-side state of the operational
-- @secret/gateway/gateway/aws@ credential AFTER teardown. "Cleared" means
-- the credential block reads back empty — NOT that the KV path was hard
-- deleted; the harness clears by writing empty values
-- ('writeOperationalAwsVaultCredentials' over empties), and the guard
-- asserts CLEARED, not DELETED. A true KV delete is an optional future
-- refinement (see 'assertOperationalTeardownComplete'). Populated by the
-- effectful wrapper from the existing 'operationalCredentialsCleared'
-- probe. No IO; pure value.
data VaultProbe
  = VaultCredsCleared
  | VaultCredsPopulated
  deriving (Eq, Show)

-- | Sprint 7.20: structured teardown-completeness verdict. An empty
-- residue (all three flags clear / no leaked keys) is the PASS state;
-- 'residueFromProbe' returns @Right ()@ for it and 'Left' a populated
-- 'ResidueError' otherwise. The fields name exactly what the harness left
-- behind so the loud abort message points the operator at the specific
-- leak (user / keys / Vault cred). Pure value, unit-testable.
data ResidueError = ResidueError
  { residueUserLeaked :: Bool
  -- ^ The operational IAM user still exists in AWS.
  , residueLeakedKeys :: [Text]
  -- ^ Access-key IDs still attached to the operational IAM user.
  , residueVaultPopulated :: Bool
  -- ^ The Vault operational credential at @secret/gateway/gateway/aws@
  -- still reads back populated.
  }
  deriving (Eq, Show)

data OperationalIdentityProbe
  = OperationalCredentialsMissing
  | OperationalIdentityProbeFailed String
  | OperationalIdentityNonUserArn Text
  | OperationalIdentityIamUser Text
  | OperationalIdentityFederatedUser Text
  deriving (Eq, Show)

data ConfigSetupResult = ConfigSetupResult
  { configSetupRegion :: Text
  , configSetupRoute53ZoneId :: Text
  , configSetupDemoFqdn :: Text
  , configSetupPolicyTier :: PolicyTier
  , configSetupAccessKeyId :: Text
  , configSetupQuotaStatuses :: [QuotaStatus]
  , configSetupDhallPath :: FilePath
  }
  deriving (Eq, Show)

data AwsSetupInput = AwsSetupInput
  { awsSetupAdminCredentials :: Credentials
  , awsSetupPolicyTierInput :: PolicyTier
  }
  deriving (Eq, Show)

data AwsTeardownInput = AwsTeardownInput
  { awsTeardownAdminCredentials :: Credentials
  , awsTeardownResiduePolicy :: PulumiResiduePolicy
  }
  deriving (Eq, Show)

-- | Per-run Pulumi stack names per
-- @DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes@. These
-- stacks are auto-managed by the test runner's
-- 'awsPostflightDestroyActions' and may safely be bypassed by the
-- harness-internal 'BypassPerRunResidueOnly' policy.
-- Sprint 4.27: derived from the 'StackDescriptor' SSoT
-- ('perRunStackDescriptorNames') — the @PerRun@-class Pulumi-managed
-- stacks — so this list cannot drift from the single typed source that
-- also feeds the CLI verbs, project dirs, and the generated
-- registry-name↔CLI-command doc section. A unit test pins it equal to
-- both the prior literal and the @PerRun@ slice of the managed-resource
-- registry ('Prodbox.Lifecycle.ResourceClass').
perRunStackNames :: [String]
perRunStackNames = perRunStackDescriptorNames

-- | Long-lived cross-substrate shared resource names per
-- @DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes@: the
-- @aws-ses@ Pulumi stack, the Sprint 4.39 @aws-ebs-volumes@ EC2 volume
-- class, and the Sprint 4.24 retained @public-edge-tls@ production
-- certificate material (an S3 object class, not a Pulumi stack). These
-- are retained by design; the harness must NEVER bypass residue refusal
-- for live long-lived Pulumi stacks. Sprint 4.27: renamed from
-- @longLivedStackNames@ — the long-lived class spans more than Pulumi
-- stacks, so it is derived from the @LongLived@-class managed-resource
-- registry facts rather than from the 'StackDescriptor' Pulumi-stack list
-- (which only knows about @aws-ses@).
longLivedResourceNames :: [String]
longLivedResourceNames = ResourceClass.resourceNamesOfClass ResourceClass.LongLived

-- | Sprint 7.7 — partition residue tuples into (per-run, long-lived)
-- buckets using 'perRunStackNames'. The partition keys must match the
-- substrates-doctrine Resource Lifecycle Classes verbatim; adding a new
-- stack requires updating both this module and the substrates doc.
partitionResidueByLifecycle
  :: [(String, String)] -> ([(String, String)], [(String, String)])
partitionResidueByLifecycle = partition (\(name, _) -> name `elem` perRunStackNames)

-- | Sprint 7.9 — the residue policy used by the end-of-run harness
-- postflight teardown ('runAwsIamHarnessTeardown'). Named as a pure
-- single source of truth so the postflight's policy choice is testable
-- without exercising IO.
--
-- Sprint 7.34: it is 'BypassPerRunResidueForHarnessRefresh' (narrowed from the
-- Sprint 7.9 'BypassAllResidueForHarnessRefresh'). The Sprint 7.9 stranding fix
-- is retained — clearing operational @aws.*@ still cannot strand @aws-ses@
-- (which is admin-credentialed post-Sprint-4.10) and proceeds unconditionally
-- (per-run residue is destroyed separately by 'awsPostflightDestroyActions').
-- But the all-residue bypass conflated destroyability with should-destroy: the
-- @LCPC-2026-07-11@ forensics show the all-residue scope structurally bypasses
-- the long-lived protection that the lifecycle preconditions otherwise enforce.
-- The narrowed per-run scope restores that protection
-- ('residuePolicyBypassesLongLivedProtection' is 'False'), so the postflight is
-- structurally unable to authorize destroying the retained @aws-ses@ /
-- @public-edge-tls@ stacks while still clearing @aws.*@ + per-run residue.
harnessPostflightResiduePolicy :: PulumiResiduePolicy
harnessPostflightResiduePolicy = BypassPerRunResidueForHarnessRefresh

-- | Sprint 7.34: whether a residue policy bypasses the long-lived
-- cross-substrate protection — i.e. whether it authorizes proceeding without
-- refusing/protecting the retained @aws-ses@ and @public-edge-tls@ stacks. Only
-- the superseded 'BypassAllResidueForHarnessRefresh' does; every other policy
-- (including the narrowed 'BypassPerRunResidueForHarnessRefresh' now used by the
-- postflight) keeps the long-lived protection intact. Pure SSoT so the
-- structural narrowing is unit-testable without IO.
residuePolicyBypassesLongLivedProtection :: PulumiResiduePolicy -> Bool
residuePolicyBypassesLongLivedProtection policy = case policy of
  BypassAllResidueForHarnessRefresh -> True
  RefuseOnAnyResidue -> False
  DestroyPulumiResidueFirst -> False
  AcceptOrphanResidue -> False
  BypassPerRunResidueOnly -> False
  BypassPerRunResidueForHarnessRefresh -> False

-- | Sprint 7.7 — canonical destroy order for
-- 'DestroyPulumiResidueFirst'. Mirrors 'awsPostflightDestroyActions':
-- subzone first (depends on EKS for nothing but is cheap to remove),
-- then eks (the heavy stack), then test (HA-RKE2 EC2), then ses last
-- because its re-creation is the most expensive (5–30 min DKIM
-- verification + ~24 h S3 bucket name cooldown).
pulumiDestroyPlanForResidue :: [(String, String)] -> [(String, String)]
pulumiDestroyPlanForResidue residue =
  let canonical = ["aws-eks-subzone", "aws-eks", "aws-test", "aws-ses"]
   in [pair | stackName <- canonical, pair@(name, _) <- residue, name == stackName]

data AwsCheckQuotasInput = AwsCheckQuotasInput
  { awsCheckQuotasAdminCredentials :: Credentials
  }
  deriving (Eq, Show)

data AwsRequestQuotasInput = AwsRequestQuotasInput
  { awsRequestQuotasAdminCredentials :: Credentials
  , awsRequestQuotasPolicyTierInput :: PolicyTier
  }
  deriving (Eq, Show)

data ConfigSetupInput = ConfigSetupInput
  { configSetupAdminCredentialsInput :: Credentials
  , configSetupRoute53ZoneIdInput :: Text
  , configSetupDemoFqdnInput :: Text
  , configSetupDemoTtlInput :: Natural
  , configSetupAcmeEmailInput :: Text
  , configSetupAcmeServerInput :: Text
  , configSetupAcmeEabKeyIdInput :: Maybe Text
  , configSetupAcmeEabHmacKeyInput :: Maybe Text
  , configSetupDevModeInput :: Bool
  , configSetupBootstrapPublicIpOverrideInput :: Maybe Text
  , configSetupPulumiEnableDnsBootstrapInput :: Bool
  , configSetupPublicEdgeAdvertisementModeInput :: Maybe Text
  , configSetupPublicEdgeBgpPeersInput :: Maybe [MetallbBgpPeer]
  , configSetupEnvoyGatewayControllerScalingInput :: ScalingPolicyBySubstrate
  , configSetupEnvoyGatewayDataPlaneScalingInput :: ScalingPolicyBySubstrate
  , configSetupApiScalingInput :: ScalingPolicyBySubstrate
  , configSetupWebsocketScalingInput :: ScalingPolicyBySubstrate
  , configSetupManualPvHostRootInput :: Text
  , configSetupPolicyTierInput :: PolicyTier
  }
  deriving (Eq, Show)

defaultAwsRegion :: Text
defaultAwsRegion = "us-east-1"

zeroSslAcmeServer :: Text
zeroSslAcmeServer = "https://acme.zerossl.com/v2/DV90"

prodboxIamUserName :: Text
prodboxIamUserName = "prodbox"

prodboxIamInlinePolicyName :: Text
prodboxIamInlinePolicyName = "prodbox-inline"

awsEksFixedIamPolicyName :: Text
awsEksFixedIamPolicyName = "aws-eks-test-aws-lb-controller"

awsEksFixedIamRoleNames :: [Text]
awsEksFixedIamRoleNames =
  [ "aws-eks-test-aws-lb-controller"
  , "aws-eks-test-ebs-csi-driver"
  ]

operationalCredentialReadyAttempts :: Int
operationalCredentialReadyAttempts = 30

operationalCredentialRetryDelayMicros :: Int
operationalCredentialRetryDelayMicros = 2000000

route53CredentialReadyAttempts :: Int
route53CredentialReadyAttempts = 90

route53CredentialReadyConsecutiveSuccesses :: Int
route53CredentialReadyConsecutiveSuccesses = 3

route53CredentialRetryDelayMicros :: Int
route53CredentialRetryDelayMicros = 10000000

baselineQuotaSpecs :: [QuotaSpec]
baselineQuotaSpecs =
  [ QuotaSpec "Running On-Demand Standard vCPU" "ec2" "L-1216C47A" 32.0
  , QuotaSpec "VPCs per Region" "vpc" "L-F678F1CE" 10.0
  , QuotaSpec "Internet gateways per Region" "vpc" "L-A4707A72" 10.0
  ]

fullQuotaSpecs :: [QuotaSpec]
fullQuotaSpecs =
  baselineQuotaSpecs
    ++ [ QuotaSpec "Elastic IP addresses" "ec2" "L-0263D0A3" 10.0
       , QuotaSpec "Security groups per Region" "vpc" "L-E79EC296" 300.0
       , QuotaSpec "Hosted zones per account" "route53" "L-4EA4796A" 500.0
       , QuotaSpec "Subnets per VPC" "vpc" "L-407747CB" 200.0
       ]

buildIamPolicyDocument :: PolicyTier -> Value
buildIamPolicyDocument policyTier =
  object
    [ "Version" .= ("2012-10-17" :: String)
    , "Statement" .= (corePolicyStatements ++ extraPolicyStatements policyTier)
    ]

-- | Build the policy that is actually installed on the operational IAM
-- user. The account-qualified form keeps the SES transaction capability
-- exact: it can assume only this account's fixed lease role and can perform
-- only the two pre-lease observations against the fixed SMTP user. Compatible
-- @"*"@-resource platform actions are grouped into one statement so the
-- compact document remains below IAM's 2,048-byte inline-user-policy limit;
-- grouping changes no effective permission.
buildIamPolicyDocumentForAccount
  :: Text -> PolicyTier -> Either AwsSesLeaseRole.AwsSesLeaseRoleValueError Value
buildIamPolicyDocumentForAccount accountId =
  buildIamPolicyDocumentForAccountAndCaptureBucket accountId Nothing

-- | Account-qualified installed-policy builder with the configured SES
-- capture bucket. @Nothing@ deliberately omits capture reads: an incomplete
-- initial config may create operational credentials, but no SES transaction
-- can start until its resource scope is authored and setup is rerun.
buildIamPolicyDocumentForAccountAndCaptureBucket
  :: Text
  -> Maybe Text
  -> PolicyTier
  -> Either AwsSesLeaseRole.AwsSesLeaseRoleValueError Value
buildIamPolicyDocumentForAccountAndCaptureBucket accountId maybeCaptureBucket policyTier = do
  roleArn <- AwsSesLeaseRole.awsSesLeaseRoleArn accountId
  operationalUserArn <- AwsSesLeaseRole.awsSesLeaseOperationalUserArn accountId
  validatedCaptureBucket <- traverse (validateCaptureBucket accountId) maybeCaptureBucket
  let accountScopedStatements =
        case policyTier of
          PolicyCore -> []
          PolicyFull ->
            [ statement
                "AssumeSesRole"
                ["sts:AssumeRole"]
                (Text.unpack roleArn)
            , statement
                "ObserveSmtpUser"
                ["iam:GetUser", "iam:ListAccessKeys"]
                (Text.unpack (operationalUserArn <> "-ses-smtp"))
            ]
      installedExtraStatements =
        case policyTier of
          PolicyCore -> []
          PolicyFull ->
            statement
              "PlatformLifecycle"
              deploymentFullWildcardActions
              "*"
              : case validatedCaptureBucket of
                Nothing -> []
                Just bucket ->
                  let bucketArn = "arn:aws:s3:::" ++ Text.unpack bucket
                   in [ statementWithResources
                          "CaptureRead"
                          ["s3:GetBucketLocation", "s3:ListBucket", "s3:GetObject"]
                          [bucketArn, bucketArn ++ "/*"]
                      ]
  pure
    ( object
        [ "Version" .= ("2012-10-17" :: String)
        , "Statement"
            .= ( corePolicyStatements
                   ++ installedExtraStatements
                   ++ accountScopedStatements
               )
        ]
    )
 where
  validateCaptureBucket account bucket = do
    _ <-
      AwsSesLeaseRole.mkAwsSesLeaseRolePolicyScope
        account
        "PRODBOXVALIDATION"
        bucket
        Nothing
    pure (Text.strip bucket)

buildIamPolicyJson :: PolicyTier -> String
buildIamPolicyJson policyTier =
  BL8.unpack (AesonPretty.encodePretty' prettyConfig (buildIamPolicyDocument policyTier)) ++ "\n"

buildFederatedSessionPolicyDocument :: PolicyTier -> Value
buildFederatedSessionPolicyDocument policyTier =
  object
    [ "Version" .= ("2012-10-17" :: String)
    , "Statement" .= [statement "FederatedValidationSession" actions "*"]
    ]
 where
  actions =
    case policyTier of
      PolicyCore -> ["sts:GetCallerIdentity", "route53:*"]
      PolicyFull ->
        [ "sts:GetCallerIdentity"
        , "sts:AssumeRole"
        , "route53:*"
        , "ec2:*"
        , "eks:*"
        , "iam:*"
        ]

-- | Sprint 4.26: the operator @prodbox aws teardown@ preflight refuses on
-- a live long-lived Pulumi stack ('aws-ses' / retained 'public-edge-tls')
-- via 'Prodbox.Lifecycle.Preconditions.noLiveLongLivedPulumiStacks'. That
-- precondition module imports 'Prodbox.Aws', so the check is
-- dependency-injected here as @FilePath -> IO (Either String ())@ (the
-- caller in 'Prodbox.Native' supplies it). @Right ()@ proceeds; @Left
-- narrative@ is rendered as the refusal. The HARNESS teardown paths
-- ('runAwsIamHarnessSetup' / 'runAwsIamHarnessTeardown') never inject it —
-- Sprint 7.9's deliberate aws-ses relaxation for the harness postflight is
-- preserved.
type AwsTeardownLongLivedPreflight = FilePath -> IO (Either String ())

runAwsCommand :: FilePath -> AwsTeardownLongLivedPreflight -> AwsCommand -> IO ExitCode
runAwsCommand repoRoot longLivedPreflight command = do
  result <-
    try (executeAwsCommand repoRoot longLivedPreflight command)
      :: IO (Either SomeException ExitCode)
  case result of
    Left err
      | Just (exitCode :: ExitCode) <- fromException err -> throwIO exitCode
      | otherwise -> do
          writeDiagnosticLine (displayException err)
          pure (ExitFailure 1)
    Right exitCode -> pure exitCode

runInteractiveConfigSetup :: FilePath -> IO ExitCode
runInteractiveConfigSetup repoRoot = do
  runInteractiveConfigSetupWithPlan repoRoot (PlanOptions False Nothing)

runInteractiveConfigSetupWithPlan :: FilePath -> PlanOptions -> IO ExitCode
runInteractiveConfigSetupWithPlan repoRoot planOptions = do
  result <- try (executeConfigSetup repoRoot planOptions) :: IO (Either SomeException ExitCode)
  case result of
    Left err
      | Just (exitCode :: ExitCode) <- fromException err -> throwIO exitCode
      | otherwise -> do
          writeDiagnosticLine (displayException err)
          pure (ExitFailure 1)
    Right exitCode -> pure exitCode

executeAwsCommand :: FilePath -> AwsTeardownLongLivedPreflight -> AwsCommand -> IO ExitCode
executeAwsCommand repoRoot longLivedPreflight command =
  case command of
    AwsPolicy policyTier -> do
      writeOutput (buildIamPolicyJson policyTier)
      pure ExitSuccess
    AwsSetup policyTier planOptions -> do
      input <- interactiveAwsSetupInput repoRoot policyTier
      runPlanWithOptions
        planOptions
        (buildAwsSetupExecutionPlan repoRoot input)
        $ \plannedInput -> do
          result <- applyAwsSetup repoRoot plannedInput
          writeOutput (renderAwsSetupResult result)
          pure ExitSuccess
    AwsTeardown planOptions flags -> do
      decision <- interactiveAwsTeardownInput repoRoot longLivedPreflight flags
      case decision of
        Left refusal -> do
          writeError (fatalError (Text.pack refusal))
          pure (ExitFailure 1)
        Right Nothing -> do
          writeOutputLine
            ( "AWS teardown: no operational `aws.*` configured and no Pulumi "
                ++ "residue. Nothing to do."
            )
          pure ExitSuccess
        Right (Just input) ->
          runPlanWithOptions
            planOptions
            (buildAwsTeardownExecutionPlan repoRoot input)
            $ \plannedInput -> do
              teardownResult <- applyAwsTeardown repoRoot plannedInput
              case teardownResult of
                Left err -> do
                  writeError (fatalError (Text.pack err))
                  pure (ExitFailure 1)
                Right result -> do
                  writeOutput (renderAwsTeardownResult result)
                  pure ExitSuccess
    AwsCheckQuotas -> do
      input <- interactiveAwsCheckQuotasInput repoRoot
      statuses <- applyAwsCheckQuotas repoRoot input
      writeOutput (renderQuotaTable "Supported AWS Quotas" statuses)
      pure ExitSuccess
    AwsRequestQuotas policyTier -> do
      input <- interactiveAwsRequestQuotasInput repoRoot policyTier
      statuses <- applyAwsRequestQuotas repoRoot input
      writeOutput (renderQuotaTable "Requested AWS Quotas" statuses)
      pure ExitSuccess
    AwsReapTestEbs confirmed -> do
      if confirmed
        then runAwsReapTestEbs repoRoot
        else do
          writeError (fatalError "Refusing to delete test-scoped EBS volumes without --yes.")
          pure (ExitFailure 1)

runAwsReapTestEbs :: FilePath -> IO ExitCode
runAwsReapTestEbs repoRoot = do
  config <- loadConfigForWrite repoRoot
  credentialsResult <- resolveAwsCredentialsRefFromHostVault repoRoot "aws" (aws config)
  case credentialsResult of
    Left err -> do
      writeError
        ( fatalError
            ( Text.pack
                ( "Test-scoped EBS reaper requires populated operational aws.* credentials in Vault: "
                    ++ err
                )
            )
        )
      pure (ExitFailure 1)
    Right credentials ->
      if not (operationalCredentialsConfigured credentials)
        then do
          writeError
            (fatalError "Test-scoped EBS reaper requires populated operational aws.* credentials.")
          pure (ExitFailure 1)
        else do
          environment <- operationalAwsEnvironment credentials
          result <-
            EbsVolume.runTestScopedEbsReaper
              EbsVolume.TestEbsReaperInput
                { EbsVolume.testEbsReaperEnvironment = environment
                , EbsVolume.testEbsReaperWorkingDirectory = Just repoRoot
                , EbsVolume.testEbsReaperClusterName = awsEksCanonicalClusterName
                }
          case result of
            Left err -> do
              writeError (fatalError (Text.pack ("Test-scoped EBS reaper failed: " ++ err)))
              pure (ExitFailure 1)
            Right report -> do
              writeOutputLine (EbsVolume.renderTestScopedEbsReaperReport report)
              pure ExitSuccess

executeConfigSetup :: FilePath -> PlanOptions -> IO ExitCode
executeConfigSetup repoRoot planOptions = do
  input <- interactiveConfigSetupInput repoRoot
  runPlanWithOptions
    planOptions
    (buildConfigSetupExecutionPlan repoRoot input)
    $ \plannedInput -> do
      result <- applyConfigSetup repoRoot plannedInput
      writeOutput (renderConfigSetupResult result)
      pure ExitSuccess

buildAwsSetupExecutionPlan :: FilePath -> AwsSetupInput -> Plan AwsSetupInput
buildAwsSetupExecutionPlan repoRoot =
  buildPlan (renderAwsSetupPlan repoRoot)

buildAwsTeardownExecutionPlan :: FilePath -> AwsTeardownInput -> Plan AwsTeardownInput
buildAwsTeardownExecutionPlan repoRoot =
  buildPlan (renderAwsTeardownPlan repoRoot)

buildConfigSetupExecutionPlan :: FilePath -> ConfigSetupInput -> Plan ConfigSetupInput
buildConfigSetupExecutionPlan repoRoot =
  buildPlan (renderConfigSetupPlan repoRoot)

renderAwsSetupPlan :: FilePath -> AwsSetupInput -> String
renderAwsSetupPlan repoRoot input =
  unlines
    [ "AWS_SETUP_PLAN"
    , "CONFIG_PATH=" ++ canonicalTier0ConfigDisplayPath repoRoot
    , "POLICY_TIER=" ++ renderPolicyTier (awsSetupPolicyTierInput input)
    , "ACCESS_KEY_ID=" ++ Text.unpack (access_key_id (awsSetupAdminCredentials input))
    ]

renderAwsTeardownPlan :: FilePath -> AwsTeardownInput -> String
renderAwsTeardownPlan repoRoot input =
  unlines
    [ "AWS_TEARDOWN_PLAN"
    , "CONFIG_PATH=" ++ canonicalTier0ConfigDisplayPath repoRoot
    , "ACCESS_KEY_ID=" ++ Text.unpack (access_key_id (awsTeardownAdminCredentials input))
    ]

renderConfigSetupPlan :: FilePath -> ConfigSetupInput -> String
renderConfigSetupPlan repoRoot input =
  unlines
    [ "CONFIG_SETUP_PLAN"
    , "CONFIG_PATH=" ++ canonicalTier0ConfigDisplayPath repoRoot
    , "ZONE_ID=" ++ Text.unpack (configSetupRoute53ZoneIdInput input)
    , "PUBLIC_HOST=" ++ Text.unpack (configSetupDemoFqdnInput input)
    , "POLICY_TIER=" ++ renderPolicyTier (configSetupPolicyTierInput input)
    ]

canonicalTier0ConfigDisplayPath :: FilePath -> FilePath
canonicalTier0ConfigDisplayPath repoRoot =
  takeDirectory (canonicalOperatorBinaryPath repoRoot) </> tier0ConfigFileName

corePolicyStatements :: [Value]
corePolicyStatements =
  [ statement "StsIdentity" ["sts:GetCallerIdentity"] "*"
  , statement
      "Route53RecordManagement"
      [ "route53:ChangeResourceRecordSets"
      , "route53:GetHostedZone"
      , "route53:ListResourceRecordSets"
      ]
      "arn:aws:route53:::hostedzone/*"
  , statement "Route53ChangePolling" ["route53:GetChange"] "arn:aws:route53:::change/*"
  ]

extraPolicyStatements :: PolicyTier -> [Value]
extraPolicyStatements policyTier =
  case policyTier of
    PolicyCore -> []
    PolicyFull ->
      [ statement
          "Route53HostedZoneLifecycle"
          route53HostedZoneLifecycleActions
          "*"
      , -- Sprint 7.5.c.v.d: compressed from explicit per-action list to
        -- service wildcard. The previous 24-action list pushed the
        -- inline-policy document over the 2048-byte AWS limit when the
        -- S3 SES capture-bucket grants were added. The operational user
        -- creates and destroys whole VPCs / subnets / security groups
        -- on the test substrate by design (per `aws-eks` and `aws-test`
        -- Pulumi stacks), so service-wide `ec2:*` is operationally
        -- equivalent to the prior list.
        statement
          "Ec2TestStackLifecycle"
          ["ec2:*"]
          "*"
      , -- Sprint 7.5.c.v.d follow-up (May 21, 2026): added the IAM
        -- customer-managed policy lifecycle actions
        -- (`iam:CreatePolicy`, `DeletePolicy`, `GetPolicy`,
        -- `ListPolicyVersions`, `DeletePolicyVersion`) the AWS Load
        -- Balancer Controller IRSA path needs. The `awsLbControllerPolicy`
        -- in `pulumi/aws-eks/Main.yaml` provisions a customer-managed
        -- policy and attaches it to the LB controller IRSA role; the
        -- prior policy granted role lifecycle only, so `iam:CreatePolicy`
        -- failed with AccessDenied on the `aws-eks` validation.
        statement
          "IamEksRoleLifecycle"
          iamEksRoleLifecycleActions
          "*"
      , -- Sprint 7.5.c.v.d: compressed from explicit per-action list to
        -- service wildcard. Same rationale as Ec2TestStackLifecycle —
        -- the operational user creates and destroys whole EKS clusters
        -- and node groups by design, so service-wide `eks:*` is the
        -- operational equivalent.
        statement
          "EksTestStackLifecycle"
          ["eks:*"]
          "*"
      , statement
          "SesCaptureBucketRead"
          [ "s3:GetBucketLocation"
          , "s3:ListBucket"
          ]
          "arn:aws:s3:::prodbox-ses-capture"
      , statement
          "SesCaptureObjectRead"
          ["s3:GetObject"]
          "arn:aws:s3:::prodbox-ses-capture/*"
      , -- Sprint 7.5.c.v.e: read-only SES grants for the Sprint 8.4
        -- prerequisite checks. `ses_sending_identity_verified` needs
        -- `ses:GetIdentityVerificationAttributes`; `ses_receive_rule_set_active`
        -- needs `ses:DescribeActiveReceiptRuleSet`. The read-only
        -- wildcards keep the harness within least-privilege bounds while
        -- covering any future read-only SES prereq additions.
        statement
          "SesReadOnly"
          sesReadOnlyActions
          "*"
      ]

route53HostedZoneLifecycleActions :: [String]
route53HostedZoneLifecycleActions =
  [ "route53:ChangeTagsForResource"
  , "route53:CreateHostedZone"
  , "route53:DeleteHostedZone"
  , "route53:ListHostedZones"
  , "route53:ListTagsForResource"
  ]

iamEksRoleLifecycleActions :: [String]
iamEksRoleLifecycleActions =
  [ "iam:AttachRolePolicy"
  , "iam:CreateOpenIDConnectProvider"
  , "iam:CreatePolicy"
  , "iam:CreatePolicyVersion"
  , "iam:CreateRole"
  , "iam:CreateServiceLinkedRole"
  , "iam:DeleteOpenIDConnectProvider"
  , "iam:DeletePolicy"
  , "iam:DeletePolicyVersion"
  , "iam:DeleteRole"
  , "iam:DetachRolePolicy"
  , "iam:GetOpenIDConnectProvider"
  , "iam:GetPolicy"
  , "iam:GetPolicyVersion"
  , "iam:GetRole"
  , "iam:GetRolePolicy"
  , "iam:ListAttachedRolePolicies"
  , "iam:ListEntitiesForPolicy"
  , "iam:ListInstanceProfilesForRole"
  , "iam:ListOpenIDConnectProviders"
  , "iam:ListPolicyVersions"
  , "iam:ListRolePolicies"
  , "iam:ListRoleTags"
  , "iam:PassRole"
  , "iam:TagOpenIDConnectProvider"
  , "iam:TagPolicy"
  , "iam:TagRole"
  , "iam:UntagOpenIDConnectProvider"
  , "iam:UntagPolicy"
  , "iam:UntagRole"
  , "iam:UpdateOpenIDConnectProviderThumbprint"
  ]

sesReadOnlyActions :: [String]
sesReadOnlyActions = ["ses:Describe*", "ses:Get*", "ses:List*"]

deploymentFullWildcardActions :: [String]
deploymentFullWildcardActions =
  route53HostedZoneLifecycleActions
    ++ ["ec2:*"]
    ++ iamEksRoleLifecycleActions
    ++ ["eks:*"]
    ++ sesReadOnlyActions

statement :: String -> [String] -> String -> Value
statement sid actions resourceArn =
  object
    [ "Sid" .= sid
    , "Effect" .= ("Allow" :: String)
    , "Action" .= actions
    , "Resource" .= resourceArn
    ]

statementWithResources :: String -> [String] -> [String] -> Value
statementWithResources sid actions resourceArns =
  object
    [ "Sid" .= sid
    , "Effect" .= ("Allow" :: String)
    , "Action" .= actions
    , "Resource" .= resourceArns
    ]

prettyConfig :: AesonPretty.Config
prettyConfig = AesonPretty.defConfig {AesonPretty.confIndent = AesonPretty.Spaces 2}

throwAws :: String -> IO a
throwAws = throwIO . AwsError

interactiveConfigSetupInput :: FilePath -> IO ConfigSetupInput
interactiveConfigSetupInput repoRoot = do
  requireInteractiveTty configSetupGuard
  writeOutputLine "Config setup writes `prodbox.dhall`, creates the operational IAM user,"
  writeOutputLine
    "and validates the result. The temporary admin credential entered below is not persisted."
  writeOutputLine ""
  accountReady <- promptConfirm "Do you already have an AWS account?" True
  unless accountReady showAwsAccountGuidance
  credentials <- promptAdminCredentialsWithRegionChoice repoRoot
  zone <- promptHostedZoneChoice repoRoot credentials
  let zoneName = hostedZoneChoiceName zone
  writeOutputLine ("The supported public hostname is fixed: " ++ Text.unpack supportedPublicHostname)
  demoTtl <- promptInt "Demo DNS TTL seconds" 60
  showAcmeProviderGuidance
  acmeEmailRaw <- promptText "ACME notification email (certificate expiry notices)" Nothing
  eabKeyIdRaw <- promptText "ZeroSSL EAB key ID (from ZeroSSL Developer settings)" Nothing
  eabHmacKeyRaw <- promptSecret "ZeroSSL EAB HMAC key (hidden input)"
  let acmeServerValue = zeroSslAcmeServer
  showPolicyTierGuidance
  policyIndex <-
    promptNumberedChoice "Choose the operational IAM policy tier number" ["full", "core"] 0
  devMode <- promptConfirm "Enable dev mode? (recommended for local or single-node work)" True
  bootstrapOverrideRaw <-
    promptText
      "Bootstrap public IP override (optional; leave blank unless public-edge auto-detection is wrong)"
      Nothing
  pulumiEnableDnsBootstrap <-
    promptConfirm
      "Enable Pulumi DNS bootstrap? (recommended; creates or reconciles the initial demo Route 53 record)"
      True
  advertisementModeIndex <-
    promptNumberedChoice "Choose the MetalLB advertisement mode number" ["l2", "bgp"] 0
  bgpPeersRaw <-
    if advertisementModeIndex == 1
      then promptBgpPeers
      else pure Nothing
  envoyGatewayControllerReplicas <- promptInt "Envoy Gateway controller replicas" 1
  envoyGatewayDataPlaneReplicas <- promptInt "Envoy Gateway data-plane replicas" 1
  apiReplicas <- promptInt "Public API replicas" 2
  websocketReplicas <- promptInt "Public WebSocket replicas" 2
  manualPvHostRootRaw <-
    promptText "Manual PV host root (host path reserved for retained PV contents)" (Just ".data")
  validateConfigSetupInput
    credentials
    (hostedZoneChoiceId zone)
    zoneName
    (Text.unpack supportedPublicHostname)
    demoTtl
    acmeEmailRaw
    acmeServerValue
    eabKeyIdRaw
    eabHmacKeyRaw
    devMode
    bootstrapOverrideRaw
    pulumiEnableDnsBootstrap
    (if advertisementModeIndex == 0 then "l2" else "bgp")
    bgpPeersRaw
    envoyGatewayControllerReplicas
    envoyGatewayDataPlaneReplicas
    apiReplicas
    websocketReplicas
    manualPvHostRootRaw
    (if policyIndex == 0 then PolicyFull else PolicyCore)

interactiveAwsSetupInput :: FilePath -> PolicyTier -> IO AwsSetupInput
interactiveAwsSetupInput repoRoot policyTier = do
  requireInteractiveTty awsSetupGuard
  writeOutputLine "AWS setup creates or refreshes the dedicated `prodbox` IAM user, writes"
  writeOutputLine "operational `aws.*` credentials, and can request baseline service quotas."
  writeOutputLine ""
  credentials <- promptAdminCredentialsWithRegionChoice repoRoot
  AwsSetupInput <$> validateAdminCredentialsInput credentials <*> pure policyTier

-- | Sprint 7.7 control-flow refactor: the file-based residue check
-- runs **before** the credential prompt so operators never paste an
-- admin key into a teardown that was about to refuse. The "nothing to
-- do" short-circuit covers the common steady state where the operator
-- ran @prodbox aws teardown@ "just in case" but the IAM user and
-- Pulumi stacks are already absent.
--
-- Return shape:
--
--   * @Left refusalMessage@ — the run is refused before any prompt
--     fires. Caller prints the message verbatim and exits non-zero.
--   * @Right Nothing@ — nothing to do (no residue, no operational
--     @aws.*@). Caller emits a one-line "nothing to do" notice and
--     exits zero.
--   * @Right (Just input)@ — proceed: prompt fired, admin credentials
--     captured, downstream 'applyAwsTeardown' will handle the IAM
--     delete + @aws.*@ clear under the requested 'PulumiResiduePolicy'.
interactiveAwsTeardownInput
  :: FilePath
  -> AwsTeardownLongLivedPreflight
  -> AwsTeardownFlags
  -> IO (Either String (Maybe AwsTeardownInput))
interactiveAwsTeardownInput repoRoot longLivedPreflight flags = do
  requireInteractiveTty awsTeardownGuard
  let policy = teardownResiduePolicy flags
  -- Sprint 4.26: the deferred Sprint 4.11 consolidation. On the default
  -- operator path ('RefuseOnAnyResidue') the long-lived class
  -- ('aws-ses' + the retained 'public-edge-tls' certificate) refuses the
  -- teardown the same way per-run residue does, via the injected
  -- 'noLiveLongLivedPulumiStacks' precondition. '--destroy-pulumi-residue'
  -- and '--allow-pulumi-residue' deliberately skip this gate (the former
  -- destroys the residue, the latter is an operator-acknowledged orphan).
  -- The HARNESS path never reaches here (it calls 'applyAwsTeardown'
  -- directly under a Bypass* policy), so Sprint 7.9's aws-ses relaxation
  -- for the harness postflight is preserved.
  longLivedRefusal <-
    if policy == RefuseOnAnyResidue
      then either Just (const Nothing) <$> longLivedPreflight repoRoot
      else pure Nothing
  case longLivedRefusal of
    Just narrative -> pure (Left narrative)
    Nothing -> interactiveAwsTeardownInputAfterLongLived repoRoot policy

interactiveAwsTeardownInputAfterLongLived
  :: FilePath -> PulumiResiduePolicy -> IO (Either String (Maybe AwsTeardownInput))
interactiveAwsTeardownInputAfterLongLived repoRoot policy = do
  -- Step 1: file-based residue check — no credentials needed.
  residue <- checkPulumiResidueBeforeTeardown repoRoot
  -- Step 2: decide based on residue + policy. Skip the credential
  -- prompt entirely on refusal and on the nothing-to-do path.
  case (residue, policy) of
    (live@(_ : _), RefuseOnAnyResidue) ->
      pure (Left (renderPulumiResidueRefusal live))
    _ -> do
      configForCheck <- loadConfigForWrite repoRoot
      operationalConfiguredResult <- operationalCredentialsConfiguredFromVault repoRoot configForCheck
      let operationalConfigured = either (const True) id operationalConfiguredResult
      case (null residue, operationalConfigured, policy) of
        (True, False, _) ->
          -- Nothing to do regardless of policy: no residue and no
          -- operational identity to clean up.
          pure (Right Nothing)
        (False, False, DestroyPulumiResidueFirst) ->
          -- The destroy subprocesses inherit operational `aws.*` from
          -- the dhall config; an empty aws.* would make every
          -- `prodbox aws stack <stack> destroy --yes` fail fast. Refuse
          -- with an actionable message rather than prompting for the
          -- admin key (the admin key only powers the subsequent IAM
          -- delete, not the destroy step).
          pure
            ( Left
                ( "AWS teardown --destroy-pulumi-residue requires populated "
                    ++ "operational `aws.*` (the destroy subprocesses inherit "
                    ++ "them from prodbox.dhall). Run `prodbox aws "
                    ++ "setup` first to populate, or run each `prodbox aws stack "
                    ++ "<stack> destroy --yes` manually with credentials you "
                    ++ "provide."
                )
            )
        _ -> do
          -- Proceed to prompt. Print the standard guidance plus, when
          -- DestroyPulumiResidueFirst is selected and residue exists,
          -- a preview of the destroy plan including the long-lived
          -- aws-ses warning.
          writeOutputLine "AWS teardown deletes the dedicated `prodbox` IAM user and clears operational"
          writeOutputLine
            "`aws.*` credentials from Dhall. The temporary admin credential entered below is not kept."
          writeOutputLine ""
          when
            (policy == DestroyPulumiResidueFirst && not (null residue))
            (writeDestroyResiduePreview residue)
          credentials <- promptAdminCredentials =<< currentRegionDefault repoRoot
          pure
            ( Right
                ( Just
                    AwsTeardownInput
                      { awsTeardownAdminCredentials = credentials
                      , awsTeardownResiduePolicy = policy
                      }
                )
            )

-- | Print a preview of the @DestroyPulumiResidueFirst@ plan before the
-- credential prompt fires so the operator sees what will run.
writeDestroyResiduePreview :: [(String, String)] -> IO ()
writeDestroyResiduePreview residue = do
  writeOutputLine "Pulumi residue destroy plan (--destroy-pulumi-residue):"
  mapM_
    (\(stackName, cmd) -> writeOutputLine ("  - " ++ stackName ++ " → " ++ cmd))
    (pulumiDestroyPlanForResidue residue)
  when
    (any (\(n, _) -> n == "aws-ses") residue)
    ( writeOutputLine
        ( "  ! aws-ses is long-lived cross-substrate shared infrastructure; "
            ++ "destroying it triggers SES re-verify + ~24h S3 bucket cooldown."
        )
    )
  writeOutputLine ""

interactiveAwsCheckQuotasInput :: FilePath -> IO AwsCheckQuotasInput
interactiveAwsCheckQuotasInput repoRoot = do
  requireInteractiveTty awsCheckQuotasGuard
  writeOutputLine "AWS quota inspection reads the supported Service Quotas targets without changing"
  writeOutputLine "the Dhall config or creating IAM users."
  writeOutputLine ""
  credentials <- promptAdminCredentialsWithRegionChoice repoRoot
  AwsCheckQuotasInput <$> validateAdminCredentialsInput credentials

interactiveAwsRequestQuotasInput :: FilePath -> PolicyTier -> IO AwsRequestQuotasInput
interactiveAwsRequestQuotasInput repoRoot policyTier = do
  requireInteractiveTty awsRequestQuotasGuard
  writeOutputLine "AWS quota requests submit increases only for supported targets that are still"
  writeOutputLine "below the required threshold."
  writeOutputLine ""
  credentials <- promptAdminCredentialsWithRegionChoice repoRoot
  AwsRequestQuotasInput <$> validateAdminCredentialsInput credentials <*> pure policyTier

showAwsAccountGuidance :: IO ()
showAwsAccountGuidance = do
  writeOutputLine "AWS account guidance:"
  writeOutputLine "1. Sign up at https://aws.amazon.com and choose the Free Tier."
  writeOutputLine "2. Add a payment method; AWS requires it even for Free Tier usage."
  writeOutputLine "3. Complete identity verification and keep the Basic (free) support plan."
  writeOutputLine "4. Create one temporary admin access key from a temporary admin IAM user."
  writeOutputLine "5. Use that key only for onboarding, then delete it after `prodbox config setup`."
  writeOutputLine "Free Tier notes: 750 hours/month of t2.micro or t3.micro for 12 months,"
  writeOutputLine "5 GiB of S3 standard storage, and Route 53 usage billed separately."
  writeOutputLine ""

showRegionChoiceGuidance :: IO ()
showRegionChoiceGuidance = do
  writeOutputLine "AWS region guidance:"
  writeOutputLine "Choose the region that should own EC2-based validation and quota targets."
  writeOutputLine "Route 53 hosted zones are selected separately in the next step."
  writeOutputLine ""

showHostedZoneChoiceGuidance :: IO ()
showHostedZoneChoiceGuidance = do
  writeOutputLine "Route 53 hosted zone guidance:"
  writeOutputLine
    ("Choose the public hosted zone that owns " ++ Text.unpack supportedPublicHostname ++ ".")
  writeOutputLine "If the desired zone is missing, open AWS console -> Route 53 -> Hosted zones,"
  writeOutputLine "create or delegate the zone, then rerun this command."
  writeOutputLine ""

showAcmeProviderGuidance :: IO ()
showAcmeProviderGuidance = do
  writeOutputLine "ACME provider guidance (ZeroSSL):"
  writeOutputLine "Open https://app.zerossl.com -> Developer -> EAB Credentials, then copy the"
  writeOutputLine "EAB Key ID and HMAC key. Both are required for ZeroSSL ACME issuance."
  writeOutputLine ""

showPolicyTierGuidance :: IO ()
showPolicyTierGuidance = do
  writeOutputLine "Operational IAM policy tier guidance:"
  writeOutputLine
    "1. full (recommended): Route 53, EC2 HA validation, and quota-management permissions."
  writeOutputLine "2. core: Route 53 runtime permissions only."
  writeOutputLine ""

promptBgpPeers :: IO (Maybe [MetallbBgpPeer])
promptBgpPeers = do
  peerCount <- promptInt "BGP peer count" 1
  peers <- mapM promptBgpPeer [1 .. peerCount]
  pure (Just peers)
 where
  promptBgpPeer :: Int -> IO MetallbBgpPeer
  promptBgpPeer index = do
    peerNameRaw <- promptText ("BGP peer " ++ show index ++ " name") (Just ("peer-" ++ show index))
    peerAddressRaw <- promptText ("BGP peer " ++ show index ++ " address") Nothing
    peerAsn <- promptInt ("BGP peer " ++ show index ++ " ASN") 64501
    myAsn <- promptInt ("Local ASN for BGP peer " ++ show index) 64500
    multiHop <- promptConfirm ("Enable eBGP multihop for peer " ++ show index ++ "?") False
    pure
      MetallbBgpPeer
        { peer_name = Text.pack (trim peerNameRaw)
        , peer_address = Text.pack (trim peerAddressRaw)
        , peer_asn = fromIntegral peerAsn
        , my_asn = fromIntegral myAsn
        , ebgp_multi_hop = Just multiHop
        }

promptAdminCredentialsWithRegionChoice :: FilePath -> IO Credentials
promptAdminCredentialsWithRegionChoice repoRoot = do
  initialCredentials <- promptAdminCredentials =<< currentRegionDefault repoRoot
  selectedRegion <- promptRegionChoice repoRoot initialCredentials
  pure initialCredentials {region = selectedRegion}

runAwsIamHarnessSetup :: FilePath -> PolicyTier -> IO String
runAwsIamHarnessSetup repoRoot policyTier = do
  credentials <- loadHarnessAdminCredentials repoRoot
  existingIdentity <- probeConfiguredOperationalIdentity repoRoot
  eksIamOrphanCleanup <- cleanupAwsEksIamOrphans repoRoot credentials
  preflightTeardownResult <-
    applyAwsTeardown
      repoRoot
      AwsTeardownInput
        { awsTeardownAdminCredentials = credentials
        , -- Sprint 7.5.c.v.c: harness preflight uses
          -- BypassAllResidueForHarnessRefresh because it is paired with
          -- an immediate re-materialization of aws.* from
          -- aws_admin_for_test_simulation.* in the same function call
          -- (applyAwsSetupWithFederatedFallback below). Neither per-run
          -- nor long-lived residue strands anything across that gap.
          -- Refusing on aws-ses live here would block every harness run
          -- because aws-ses is the intended long-lived steady state.
          awsTeardownResiduePolicy = BypassAllResidueForHarnessRefresh
        }
  preflightTeardown <- case preflightTeardownResult of
    Left err ->
      throwAws
        ( "AWS IAM harness preflight teardown unexpectedly refused with "
            ++ "BypassAllResidueForHarnessRefresh: "
            ++ err
        )
    Right value -> pure value
  preflightAssociatedCleanup <-
    case existingIdentity of
      OperationalIdentityIamUser userName
        | userName /= prodboxIamUserName ->
            Just <$> cleanupIamUserResidue repoRoot credentials userName
      _ -> pure Nothing
  preflightConfigCleared <- operationalCredentialsClearedAtPreflight repoRoot credentials
  unless
    preflightConfigCleared
    ( throwAws
        "AWS IAM harness preflight cleanup did not clear operational aws.* credentials from prodbox.dhall."
    )
  result <-
    applyAwsSetupWithFederatedFallback
      repoRoot
      AwsSetupInput
        { awsSetupAdminCredentials = credentials
        , awsSetupPolicyTierInput = policyTier
        }
  -- Sprint 7.18: after operational @aws.*@ is materialized, seed the ZeroSSL
  -- ACME external-account-binding into Vault (@secret/acme/eab@) from the
  -- optional @acme_eab@ block of @test-secrets.dhall@, mirroring the @aws.*@
  -- materialization above. This is the non-interactive analog of the
  -- interactive @prodbox config setup@ EAB prompt, so the canonical suite's
  -- public edge (real ZeroSSL certs -> cert-manager DNS01) can come up without
  -- a TTY. The harness preflight runs on the home @test all@ path too — the
  -- canonical validation set includes @aws-iam@ and @keycloak-invite@, which
  -- always engage the harness regardless of substrate
  -- ('Prodbox.TestPlan.derivedTier'). Absent or empty fixture EAB is a no-op.
  -- 'seedAcmeEabFromTestSecrets' (Prodbox.Vault.Host) is also invoked from the
  -- edge/ACME reconcile immediately before the in-cluster EAB materializer Job
  -- is applied (the load-bearing call); this harness-preflight invocation is
  -- belt-and-suspenders for the non-substrate harness path.
  seedAcmeEabFromTestSecrets repoRoot
  pure
    ( renderAwsIamHarnessSetupReport
        existingIdentity
        eksIamOrphanCleanup
        preflightTeardown
        preflightAssociatedCleanup
        preflightConfigCleared
        result
    )

runAwsIamHarnessInspect :: FilePath -> IO String
runAwsIamHarnessInspect repoRoot = do
  config <- loadConfigForWrite repoRoot
  credentialsResult <- resolveAwsCredentialsRefFromHostVault repoRoot "aws" (aws config)
  case credentialsResult of
    Left err ->
      throwAws
        ( "AWS IAM harness inspection requires populated operational aws.* \
          \credentials in Vault: "
            ++ err
        )
    Right credentials ->
      if not (operationalCredentialsConfigured credentials)
        then throwAws "AWS IAM harness inspection requires populated operational aws.* credentials."
        else do
          identity <- probeOperationalIdentity repoRoot credentials
          case identity of
            OperationalCredentialsMissing ->
              throwAws "AWS IAM harness inspection did not find populated operational aws.* credentials."
            OperationalIdentityProbeFailed err ->
              throwAws
                ( "AWS IAM harness inspection failed to validate operational aws.* credentials via `aws sts get-caller-identity`: "
                    ++ err
                )
            OperationalIdentityNonUserArn arn ->
              throwAws
                ( "AWS IAM harness inspection expected an IAM user identity for operational aws.* credentials but received ARN `"
                    ++ Text.unpack arn
                    ++ "`."
                )
            OperationalIdentityIamUser userName ->
              pure
                ( unlines
                    [ "IAM_USER=" ++ Text.unpack userName
                    , "IAM_PRINCIPAL=iam-user"
                    , "CONFIG_PATH=" ++ canonicalTier0ConfigDisplayPath repoRoot
                    ]
                )
            OperationalIdentityFederatedUser userName ->
              pure
                ( unlines
                    [ "IAM_USER=" ++ Text.unpack userName
                    , "IAM_PRINCIPAL=federated-user"
                    , "CONFIG_PATH=" ++ canonicalTier0ConfigDisplayPath repoRoot
                    ]
                )

runAwsIamHarnessTeardown :: FilePath -> IO String
runAwsIamHarnessTeardown repoRoot = do
  credentials <- loadHarnessAdminCredentials repoRoot
  teardownResult <-
    applyAwsTeardown
      repoRoot
      AwsTeardownInput
        { awsTeardownAdminCredentials = credentials
        , -- Sprint 7.34: BypassPerRunResidueForHarnessRefresh (narrowed from
          -- Sprint 7.9's BypassAllResidueForHarnessRefresh). Clearing
          -- operational aws.* still cannot strand aws-ses (admin-credentialed
          -- against the long-lived S3 backend post-Sprint-4.10) and proceeds
          -- unconditionally; per-run stacks are destroyed separately by
          -- awsPostflightDestroyActions (which retains aws-ses). The 7.9 fix is
          -- retained, but the all-residue scope structurally bypassed the
          -- long-lived protection; the per-run scope restores it, so the
          -- postflight is structurally unable to authorize destroying aws-ses /
          -- public-edge-tls. The choice is the pure
          -- 'harnessPostflightResiduePolicy' SSoT so it is unit-testable
          -- without IO.
          awsTeardownResiduePolicy = harnessPostflightResiduePolicy
        }
  result <- case teardownResult of
    Left err ->
      -- Sprint 7.9: with BypassAllResidueForHarnessRefresh the teardown no
      -- longer refuses on long-lived Pulumi residue (aws-ses is
      -- admin-managed; see the policy comment above). The only remaining
      -- refusal sources are the Sprint 7.8 operational fail-closed gate
      -- (AWS IAM unreachable, so the operational user's live state cannot
      -- be observed and "cannot observe" is never treated as "destroyed")
      -- or a failed managed-resource reconcile. Surface the underlying
      -- message rather than a stale "destroy aws-ses first" instruction.
      throwAws
        ( "AWS IAM harness postflight teardown refused. The operational "
            ++ "aws.* credentials and the operational `prodbox` IAM user "
            ++ "were NOT torn down. This is the Sprint 7.8 fail-closed gate "
            ++ "(AWS IAM unreachable, or a managed-resource reconcile "
            ++ "failure) — not a long-lived Pulumi residue refusal, which "
            ++ "Sprint 7.9 removed from the postflight. Resolve AWS "
            ++ "connectivity / admin credentials and re-run `prodbox aws "
            ++ "teardown`. Underlying refusal message:\n"
            ++ err
        )
    Right value -> pure value
  configCleared <- operationalCredentialsCleared repoRoot
  unless
    configCleared
    ( throwAws
        "AWS IAM harness teardown did not clear operational aws.* credentials from prodbox.dhall."
    )
  -- Sprint 7.20: teardown-completeness guard. After 'applyAwsTeardown'
  -- destroys the operational IAM user + keys (and clears the Vault
  -- credential, re-checked just above), this asserts the harness left NO
  -- residue behind: the operational `prodbox` IAM user + its access keys
  -- are GONE from AWS (queried via the admin credentials through the same
  -- 'operationalIamUserExists' / 'listOperationalAccessKeyIds' probes the
  -- destroy used), AND the Vault credential at `secret/gateway/gateway/aws`
  -- reads back CLEARED (via 'operationalCredentialsCleared'). The decision
  -- core is the pure 'residueFromProbe' classifier; a residual user, a
  -- residual key, or a still-populated Vault cred aborts LOUD with
  -- 'renderResidueError' naming exactly what leaked. This EXTENDS (does not
  -- weaken) the Vault-clear refusal above. The live exercise of this guard
  -- is the 🧪 Live-proof axis (Standard O) — unit tests cover the pure
  -- classifier without live AWS.
  assertOperationalTeardownComplete repoRoot credentials
  pure (renderAwsTeardownResult result ++ "POST_RUN_OPERATIONAL_CONFIG_CLEARED=true\n")

-- | Sprint 7.16: acquire the EPHEMERAL admin AWS credential for the IAM
-- harness setup/teardown flows. The Route 53 / ACME bootstrap fields are still
-- validated from @prodbox.dhall@ (they belong to the production config),
-- but the admin credential itself comes from the unified acquisition cascade:
-- a populated @aws_admin_for_test_simulation@ in @test-secrets.dhall@ (the
-- harness simulating the prompt) → an interactive TTY prompt → fail loud.
loadHarnessAdminCredentials :: FilePath -> IO Credentials
loadHarnessAdminCredentials repoRoot = do
  configResult <- loadConfigFile repoRoot
  case configResult of
    Left err -> throwAws err
    Right config ->
      case validateAwsBootstrapConfig config of
        Left err -> throwAws err
        Right () -> do
          credentialsResult <- acquireAdminAwsCredentials repoRoot
          case credentialsResult of
            Left err ->
              throwAws
                ( "Native IAM validation requires an ephemeral admin AWS \
                  \credential (from test-secrets.dhall's \
                  \aws_admin_for_test_simulation block, or the interactive \
                  \prompt): "
                    ++ err
                )
            Right credentials ->
              if harnessAdminCredentialsConfigured credentials
                then validateAdminCredentialsInput credentials
                else
                  throwAws
                    "Native IAM validation requires the acquired admin AWS credential to have a non-empty access key id, secret access key, and region."

harnessAdminCredentialsConfigured :: Credentials -> Bool
harnessAdminCredentialsConfigured credentials =
  not (Text.null (Text.strip (access_key_id credentials)))
    && not (Text.null (Text.strip (secret_access_key credentials)))
    && not (Text.null (Text.strip (region credentials)))

promptRegionChoice :: FilePath -> Credentials -> IO Text
promptRegionChoice repoRoot credentials = do
  regions <- listAwsRegions repoRoot credentials
  when (null regions) (throwAws "No AWS regions were returned by `aws ec2 describe-regions`")
  showRegionChoiceGuidance
  writeOutputLine "Available AWS regions:"
  mapM_ printRegionChoice (zip [1 :: Int ..] regions)
  let defaultIndex = maybe 0 id (findIndex ((== region credentials) . regionChoiceName) regions)
  selectedIndex <-
    promptNumberedChoice
      "Choose the AWS region number for prodbox operations"
      (map (Text.unpack . regionChoiceName) regions)
      defaultIndex
  case safeIndex selectedIndex regions of
    Just choice -> pure (regionChoiceName choice)
    Nothing -> throwAws "Internal error: AWS region selection produced an out-of-range index"
 where
  printRegionChoice (index, choice) =
    writeOutputLine
      ( show index
          ++ ". "
          ++ Text.unpack (regionChoiceName choice)
          ++ " ("
          ++ Text.unpack (regionChoiceOptInStatus choice)
          ++ ")"
      )

promptHostedZoneChoice :: FilePath -> Credentials -> IO HostedZoneChoice
promptHostedZoneChoice repoRoot credentials = do
  zones <- listHostedZones repoRoot credentials
  when (null zones) $ do
    writeOutputLine "No hosted zones were found in Route 53."
    writeOutputLine "Create one in the Route 53 console or delegate an existing domain, then rerun."
    throwAws "No Route 53 hosted zones are available"
  showHostedZoneChoiceGuidance
  writeOutputLine "Available Route 53 hosted zones:"
  mapM_ printZoneChoice (zip [1 :: Int ..] zones)
  selectedIndex <-
    promptNumberedChoice
      "Choose the public hosted zone number for prodbox DNS"
      (map (Text.unpack . hostedZoneChoiceName) zones)
      0
  case safeIndex selectedIndex zones of
    Just choice -> pure choice
    Nothing -> throwAws "Internal error: hosted zone selection produced an out-of-range index"
 where
  printZoneChoice (index, choice) =
    writeOutputLine
      ( show index
          ++ ". "
          ++ Text.unpack (hostedZoneChoiceName choice)
          ++ " ("
          ++ Text.unpack (hostedZoneChoiceId choice)
          ++ ")"
      )

promptText :: String -> Maybe String -> IO String
promptText message maybeDefault = do
  writeOutput (message ++ defaultSuffix maybeDefault ++ ": ")
  hFlush stdout
  input <- readPromptLine message
  pure $
    case (trim input, maybeDefault) of
      ("", Just defaultValue) -> defaultValue
      (value, _) -> value
 where
  defaultSuffix = maybe "" (\defaultValue -> " [" ++ defaultValue ++ "]")

promptSecret :: String -> IO String
promptSecret message = do
  terminal <- hIsTerminalDevice stdin
  writeOutput (message ++ ": ")
  hFlush stdout
  if terminal
    then do
      originalEcho <- hGetEcho stdin
      value <- bracket_ (hSetEcho stdin False) (hSetEcho stdin originalEcho) (readPromptLine message)
      writeOutputLine ""
      pure (trim value)
    else trim <$> readPromptLine message

promptInt :: String -> Int -> IO Int
promptInt message defaultValue = do
  rawValue <- promptText message (Just (show defaultValue))
  case reads rawValue of
    [(parsed, "")] -> pure parsed
    _ -> do
      writeOutputLine "Enter a whole number."
      promptInt message defaultValue

promptConfirm :: String -> Bool -> IO Bool
promptConfirm message defaultValue = do
  let suffix = if defaultValue then " [Y/n]" else " [y/N]"
  writeOutput (message ++ suffix ++ ": ")
  hFlush stdout
  response <- fmap (map toLower . trim) (readPromptLine message)
  case response of
    "" -> pure defaultValue
    "y" -> pure True
    "yes" -> pure True
    "n" -> pure False
    "no" -> pure False
    _ -> do
      writeOutputLine "Enter yes or no."
      promptConfirm message defaultValue

readPromptLine :: String -> IO String
readPromptLine message = do
  lineResult <- try getLine :: IO (Either IOException String)
  case lineResult of
    Right line -> pure line
    Left err
      | isEOFError err ->
          throwAws
            ( "Input ended while reading `"
                ++ message
                ++ "`. Re-run the command interactively with a temporary admin AWS credential."
            )
      | otherwise ->
          throwAws
            ( "Failed to read input for `"
                ++ message
                ++ "`: "
                ++ show err
            )

promptNumberedChoice :: String -> [String] -> Int -> IO Int
promptNumberedChoice promptMessage options defaultIndex = do
  rawChoice <- promptText promptMessage (Just (show (defaultIndex + 1)))
  case reads rawChoice of
    [(selectedNumber, "")] ->
      let selectedIndex = selectedNumber - 1
       in if selectedIndex >= 0 && selectedIndex < length options
            then pure selectedIndex
            else do
              writeOutputLine "Selected option is out of range."
              promptNumberedChoice promptMessage options defaultIndex
    _ -> do
      writeOutputLine "Enter the number shown beside the option."
      promptNumberedChoice promptMessage options defaultIndex

safeIndex :: Int -> [a] -> Maybe a
safeIndex _ [] = Nothing
safeIndex 0 (x : _) = Just x
safeIndex n (_ : xs)
  | n > 0 = safeIndex (n - 1) xs
  | otherwise = Nothing

validateConfigSetupInput
  :: Credentials
  -> Text
  -> Text
  -> String
  -> Int
  -> String
  -> Text
  -> String
  -> String
  -> Bool
  -> String
  -> Bool
  -> String
  -> Maybe [MetallbBgpPeer]
  -> Int
  -> Int
  -> Int
  -> Int
  -> String
  -> PolicyTier
  -> IO ConfigSetupInput
validateConfigSetupInput adminCredentials zoneId zoneName demoFqdnRaw demoTtl acmeEmailRaw acmeServer eabKeyIdRaw eabHmacKeyRaw devMode bootstrapOverrideRaw pulumiEnableDnsBootstrap advertisementModeRaw bgpPeersRaw envoyGatewayControllerReplicasRaw envoyGatewayDataPlaneReplicasRaw apiReplicasRaw websocketReplicasRaw manualPvHostRootRaw policyTier = do
  normalizedAdminCredentials <- validateAdminCredentialsInput adminCredentials
  let normalizedZoneId = Text.strip zoneId
      normalizedDemoFqdn = normalizeFqdn (Text.pack demoFqdnRaw)
      normalizedAcmeEmail = Text.strip (Text.pack acmeEmailRaw)
      normalizedEabKeyId = normalizeOptionalText (Text.pack eabKeyIdRaw)
      normalizedEabHmacKey = normalizeOptionalText (Text.pack eabHmacKeyRaw)
      normalizedBootstrapOverride = normalizeOptionalText (Text.pack bootstrapOverrideRaw)
      normalizedAdvertisementMode = normalizeOptionalText (Text.toLower (Text.strip (Text.pack advertisementModeRaw)))
      normalizedManualPvHostRoot = Text.strip (Text.pack manualPvHostRootRaw)
      normalizedDeployment =
        DeploymentSection
          { dev_mode = devMode
          , bootstrap_public_ip_override = normalizedBootstrapOverride
          , pulumi_enable_dns_bootstrap = pulumiEnableDnsBootstrap
          , public_edge_advertisement_mode = normalizedAdvertisementMode
          , public_edge_bgp_peers = bgpPeersRaw
          , envoy_gateway_controller_scaling =
              fixedScalingPolicyBySubstrate (fromIntegral envoyGatewayControllerReplicasRaw)
          , envoy_gateway_data_plane_scaling =
              fixedScalingPolicyBySubstrate (fromIntegral envoyGatewayDataPlaneReplicasRaw)
          , api_scaling = fixedScalingPolicyBySubstrate (fromIntegral apiReplicasRaw)
          , websocket_scaling = fixedScalingPolicyBySubstrate (fromIntegral websocketReplicasRaw)
          }
  unless (isValidRoute53ZoneId normalizedZoneId) $
    throwAws "Route 53 zone ID must look like a hosted-zone ID (for example Z1234)"
  unless (isValidFqdn normalizedDemoFqdn) $
    throwAws "demo_fqdn must be a valid fully qualified domain name"
  unless (Text.toLower normalizedDemoFqdn == Text.toLower supportedPublicHostname) $
    throwAws ("demo_fqdn must be " ++ Text.unpack supportedPublicHostname)
  either throwAws pure (validateHostedZoneAlignment normalizedDemoFqdn zoneName)
  when (demoTtl < 30 || demoTtl > 86400) (throwAws "demo_ttl must be between 30 and 86400 seconds")
  unless
    (hasValidEmailShape normalizedAcmeEmail)
    (throwAws "acme_email must be a valid email address")
  unless
    ("https://" `Text.isPrefixOf` Text.toLower acmeServer)
    (throwAws "acme_server must be an https:// URL")
  when ((normalizedEabKeyId == Nothing) /= (normalizedEabHmacKey == Nothing)) $
    throwAws "acme_eab_key_id and acme_eab_hmac_key must either both be set or both be empty"
  case normalizedAdvertisementMode of
    Nothing -> throwAws "public_edge_advertisement_mode must be l2 or bgp"
    Just _ -> either throwAws pure (validatePublicEdgeDeployment normalizedDeployment)
  pure
    ConfigSetupInput
      { configSetupAdminCredentialsInput = normalizedAdminCredentials
      , configSetupRoute53ZoneIdInput = normalizedZoneId
      , configSetupDemoFqdnInput = normalizedDemoFqdn
      , configSetupDemoTtlInput = fromIntegral demoTtl
      , configSetupAcmeEmailInput = normalizedAcmeEmail
      , configSetupAcmeServerInput = Text.strip acmeServer
      , configSetupAcmeEabKeyIdInput = normalizedEabKeyId
      , configSetupAcmeEabHmacKeyInput = normalizedEabHmacKey
      , configSetupDevModeInput = devMode
      , configSetupBootstrapPublicIpOverrideInput = normalizedBootstrapOverride
      , configSetupPulumiEnableDnsBootstrapInput = pulumiEnableDnsBootstrap
      , configSetupPublicEdgeAdvertisementModeInput = normalizedAdvertisementMode
      , configSetupPublicEdgeBgpPeersInput = bgpPeersRaw
      , configSetupEnvoyGatewayControllerScalingInput =
          fixedScalingPolicyBySubstrate (fromIntegral envoyGatewayControllerReplicasRaw)
      , configSetupEnvoyGatewayDataPlaneScalingInput =
          fixedScalingPolicyBySubstrate (fromIntegral envoyGatewayDataPlaneReplicasRaw)
      , configSetupApiScalingInput = fixedScalingPolicyBySubstrate (fromIntegral apiReplicasRaw)
      , configSetupWebsocketScalingInput = fixedScalingPolicyBySubstrate (fromIntegral websocketReplicasRaw)
      , configSetupManualPvHostRootInput = normalizedManualPvHostRoot
      , configSetupPolicyTierInput = policyTier
      }

applyAwsSetup :: FilePath -> AwsSetupInput -> IO IamSetupResult
applyAwsSetup = applyAwsSetupWithFallbackMode False

applyAwsSetupWithFederatedFallback :: FilePath -> AwsSetupInput -> IO IamSetupResult
applyAwsSetupWithFederatedFallback = applyAwsSetupWithFallbackMode True

applyAwsSetupWithFallbackMode :: Bool -> FilePath -> AwsSetupInput -> IO IamSetupResult
applyAwsSetupWithFallbackMode allowFederatedFallback repoRoot input = do
  (newAccessKeyId, newSecretAccessKey, quotaStatuses) <-
    ensureOperationalIamUser repoRoot (awsSetupAdminCredentials input) (awsSetupPolicyTierInput input)
  currentConfig <- loadConfigForWrite repoRoot
  ensureConfiguredAwsSesLeaseRole
    repoRoot
    (awsSetupAdminCredentials input)
    (awsSetupPolicyTierInput input)
    currentConfig
  (operationalCredentials, credentialSource) <-
    operationalCredentialsAfterReadiness
      allowFederatedFallback
      repoRoot
      (awsSetupAdminCredentials input)
      (awsSetupPolicyTierInput input)
      (nonEmptyText (zone_id (route53 currentConfig)))
      newAccessKeyId
      newSecretAccessKey
  writeOperationalAwsVaultCredentials repoRoot operationalCredentials
  let updatedConfig =
        currentConfig
          { aws =
              (aws currentConfig)
                { awsCredentialRegion = region operationalCredentials
                }
          }
  writeProjectConfigParameters repoRoot updatedConfig
  validationResult <- validateAndLoadSettings repoRoot
  case validationResult of
    Left err ->
      throwAws
        ( "Operational IAM user was created, but the updated config did not validate. "
            ++ "Complete the remaining config fields with `prodbox config setup` and rerun. "
            ++ "Detail: "
            ++ err
        )
    Right _ ->
      pure
        IamSetupResult
          { iamSetupUserName = prodboxIamUserName
          , iamSetupPolicyTier = awsSetupPolicyTierInput input
          , iamSetupAccessKeyId = access_key_id operationalCredentials
          , iamSetupCredentialSource = credentialSource
          , iamSetupQuotaStatuses = quotaStatuses
          , iamSetupDhallPath = canonicalTier0ConfigDisplayPath repoRoot
          }

applyAwsTeardown :: FilePath -> AwsTeardownInput -> IO (Either String IamTeardownResult)
applyAwsTeardown repoRoot input = do
  residue <- checkPulumiResidueBeforeTeardown repoRoot
  -- Partition kept symmetric (_perRunResidue is computed but only
  -- inspected through the policy logic below; the partition exists so
  -- any future stack added per `substrates.md → Resource Lifecycle
  -- Classes` forces a deliberate per-run vs long-lived classification
  -- via 'perRunStackNames' / 'longLivedResourceNames').
  let (_perRunResidue, longLivedResidue) = partitionResidueByLifecycle residue
  case awsTeardownResiduePolicy input of
    AcceptOrphanResidue -> runTeardown
    BypassAllResidueForHarnessRefresh -> runTeardown
    -- Sprint 7.34: the narrowed postflight policy clears operational @aws.*@
    -- unconditionally (per-run residue is destroyed separately by
    -- 'awsPostflightDestroyActions', so it never strands @aws.*@ — the Sprint
    -- 7.9 stranding fix is retained). It is behaviourally identical to
    -- 'BypassAllResidueForHarnessRefresh' for the @aws.*@ clear, but it is
    -- PER-RUN-SCOPED: it does not bypass the long-lived protection
    -- ('residuePolicyBypassesLongLivedProtection' is 'False'), so the postflight
    -- is structurally unable to authorize destroying the retained @aws-ses@ /
    -- @public-edge-tls@ stacks.
    BypassPerRunResidueForHarnessRefresh -> runTeardown
    RefuseOnAnyResidue
      | null residue -> runTeardown
      | otherwise -> pure (Left (renderPulumiResidueRefusal residue))
    BypassPerRunResidueOnly
      | null longLivedResidue -> runTeardown
      | otherwise -> pure (Left (renderPulumiResidueLongLivedRefusal longLivedResidue))
    DestroyPulumiResidueFirst
      | null residue -> runTeardown
      | otherwise -> do
          let destroyPlan = pulumiDestroyPlanForResidue residue
          destroyExit <- dispatchPulumiDestroysForResidue repoRoot destroyPlan
          case destroyExit of
            Left err -> pure (Left err)
            Right () -> runTeardown
 where
  adminCreds = awsTeardownAdminCredentials input

  -- Reconcile the three 'Operational'-class managed resources (the SES lease
  -- role, operational @prodbox@ IAM user, and operational @aws.*@ config
  -- block) toward absent through the managed-resource registry, instead of
  -- the previous inline delete sequence. Behavior is preserved for the
  -- present and already-absent cases (same keys + inline policy + user
  -- deleted, same @aws.*@ clear). The NEW soundness improvement is the
  -- fail-closed gate: if either operational resource's residue is
  -- 'ResidueUnreachable' (AWS IAM cannot be observed), teardown refuses
  -- rather than treating "cannot observe" as "destroyed"
  -- (@lifecycle_reconciliation_doctrine.md § 3.1@). 'reconcileAbsent'
  -- deliberately skips 'ResidueUnreachable' for cascade graceful
  -- degradation, so this gate is required here for the operational class.
  runTeardown :: IO (Either String IamTeardownResult)
  runTeardown = do
    operationalPairs <- discoverOperationalResidue repoRoot adminCreds
    let unreachable =
          [ resourceName resource
          | (resource, status) <- operationalPairs
          , ResidueStatus.isResidueUnreachable status
          ]
    if not (null unreachable)
      then
        pure
          ( Left
              ( "AWS operational teardown refused: cannot observe the live state of "
                  ++ intercalate ", " unreachable
                  ++ " (AWS IAM unreachable). Teardown will not proceed, because "
                  ++ "\"cannot observe\" is never treated as \"destroyed\" — that "
                  ++ "would strand the operational IAM user. Resolve AWS connectivity "
                  ++ "/ admin credentials and re-run `prodbox aws teardown`."
              )
          )
      else do
        -- Capture the keys that existed BEFORE the reconcile destroys them
        -- (read-only) and whether the IAM user was present, so the result
        -- record reflects what was torn down even though the destroy is now
        -- driven through 'reconcileAbsent'.
        deletedAccessKeys <- listOperationalAccessKeyIds repoRoot adminCreds
        let userWasPresent =
              any
                ( \(resource, status) ->
                    resourceName resource == "operational-iam-user"
                      && ResidueStatus.isResiduePresent status
                )
                operationalPairs
        reconcileExit <- reconcileAbsent repoRoot operationalPairs
        case reconcileExit of
          ExitFailure code ->
            pure
              ( Left
                  ( "AWS operational teardown failed: the managed-resource "
                      ++ "reconcile exited with code "
                      ++ show code
                      ++ " while destroying the operational IAM user / clearing "
                      ++ "aws.* config."
                  )
              )
          ExitSuccess ->
            pure
              ( Right
                  IamTeardownResult
                    { iamTeardownUserName = prodboxIamUserName
                    , iamTeardownDeletedAccessKeys = deletedAccessKeys
                    , iamTeardownUserDeleted = userWasPresent
                    , iamTeardownDhallPath = canonicalTier0ConfigDisplayPath repoRoot
                    }
              )

-- | Sprint 7.8: pure mapping from the 'operationalIamUserExists' probe
-- result to a typed 'ResidueStatus' for the @operational-iam-user@
-- managed resource. 'Right True' → present (with @iam:get-user@
-- evidence); 'Right False' → absent; 'Left' (any AWS error observing
-- the user) → unreachable, so the teardown gate refuses rather than
-- presuming the user is gone. Unit-testable, no IO.
operationalIamUserResidueFromExists :: Either String Bool -> ResidueStatus.ResidueStatus
operationalIamUserResidueFromExists existsResult = case existsResult of
  Right True ->
    ResidueStatus.ResiduePresent
      ResidueStatus.ResidueDetails
        { ResidueStatus.residueEvidence = "iam:get-user " ++ Text.unpack prodboxIamUserName
        , ResidueStatus.residueStackName = "operational-iam-user"
        }
  Right False -> ResidueStatus.ResidueAbsent
  Left err -> ResidueStatus.ResidueUnreachable (ResidueStatus.ResidueQueryFailed err)

-- | Sprint 7.8: pure mapping from the configured @aws.access_key_id@ to
-- a typed 'ResidueStatus' for the @operational-aws-config@ managed
-- resource. A non-empty (after strip) key means the operational
-- credential block is still populated (present); empty means already
-- cleared (absent). There is no unreachable case — the config is read
-- locally. Unit-testable, no IO.
operationalAwsConfigResidueFromKey :: Text -> ResidueStatus.ResidueStatus
operationalAwsConfigResidueFromKey accessKeyId
  | Text.null (Text.strip accessKeyId) = ResidueStatus.ResidueAbsent
  | otherwise =
      ResidueStatus.ResiduePresent
        ResidueStatus.ResidueDetails
          { ResidueStatus.residueEvidence = "aws.access_key_id set in prodbox.dhall"
          , ResidueStatus.residueStackName = "operational-aws-config"
          }

-- | The three 'Operational'-class managed resources, with
-- their idempotent destroy closures over the admin credentials. The
-- canonical 'resourceName's MUST match the
-- 'Prodbox.Lifecycle.ResourceClass' SSoT
-- (@operational-aws-ses-lease-role@, @operational-iam-user@,
-- @operational-aws-config@). Registry order is dependency order:
-- the lease role is deleted before its trusted operational user.
--
-- * @operational-aws-ses-lease-role@: delete the fixed role and inline
--   policy through its typed, idempotent owner interpreter.
-- * @operational-iam-user@: delete every operational access key, delete
--   the inline user policy if present, then delete the user if present.
-- * @operational-aws-config@: clear the operational @aws.*@ block in
--   @prodbox.dhall@ (region preserved, falling back to the admin
--   region).
operationalManagedResources :: Credentials -> [ManagedResource]
operationalManagedResources adminCreds =
  [ ManagedResource
      { resourceName = "operational-aws-ses-lease-role"
      , resourceClass = ResourceClass.Operational
      , resourceEnsureCommand = Just "prodbox aws setup"
      , resourceEnsurePresent = Nothing
      , resourceDestroyCommand = "prodbox aws teardown"
      , resourceDestroy = \repoRoot ->
          deleteAwsSesLeaseRoleForTeardown repoRoot adminCreds
      }
  , ManagedResource
      { resourceName = "operational-iam-user"
      , resourceClass = ResourceClass.Operational
      , resourceEnsureCommand = Nothing
      , resourceEnsurePresent = Nothing
      , resourceDestroyCommand = "prodbox aws teardown"
      , resourceDestroy = \repoRoot -> do
          _ <- deleteExistingOperationalKeys repoRoot adminCreds
          deleteUserPolicyIfPresent repoRoot adminCreds
          _ <- deleteOperationalUserIfPresent repoRoot adminCreds
          pure ExitSuccess
      }
  , ManagedResource
      { resourceName = "operational-aws-config"
      , resourceClass = ResourceClass.Operational
      , resourceEnsureCommand = Nothing
      , resourceEnsurePresent = Nothing
      , resourceDestroyCommand = "prodbox aws teardown"
      , resourceDestroy = \repoRoot -> clearOperationalAwsConfig repoRoot adminCreds
      }
  ]

-- | Load the best authoritative policy scope available for observing or
-- deleting the fixed role. The resource identity (account + fixed role name)
-- does not depend on the policy scope. When an initial or damaged config lacks
-- the public zone/bucket fields, a valid sentinel scope lets the typed role
-- interpreter authoritatively distinguish ABSENT from PRESENT/DRIFTED and
-- delete the same fixed role; it is never used by the ensure path.
loadAwsSesLeaseRoleObservationScope
  :: FilePath
  -> Credentials
  -> IO AwsSesLeaseRole.AwsSesLeaseRolePolicyScope
loadAwsSesLeaseRoleObservationScope repoRoot adminCreds = do
  accountId <- awsCallerAccountId repoRoot adminCreds
  configResult <- loadConfigFile repoRoot
  case configResult of
    Right config ->
      case configuredAwsSesLeaseRoleScope accountId config of
        Right (Just scope) -> pure scope
        Right Nothing -> fallback accountId
        Left _ -> fallback accountId
    Left _ -> fallback accountId
 where
  fallback accountId =
    case AwsSesLeaseRole.mkAwsSesLeaseRolePolicyScope
      accountId
      "PRODBOXOBSERVATION"
      "prodbox-lease-observation"
      Nothing of
      Left err ->
        throwAws
          ( "Cannot build the bounded observation scope for the AWS SES lease role: "
              ++ show err
          )
      Right scope -> pure scope

deleteAwsSesLeaseRoleForTeardown :: FilePath -> Credentials -> IO ExitCode
deleteAwsSesLeaseRoleForTeardown repoRoot adminCreds = do
  scope <- loadAwsSesLeaseRoleObservationScope repoRoot adminCreds
  result <- AwsSesLeaseRole.deleteAwsSesLeaseRole repoRoot adminCreds scope
  case result of
    Left err ->
      throwAws
        ( "Failed to delete the operational AWS SES lease role: "
            ++ show err
        )
    Right () -> pure ExitSuccess

awsSesLeaseRoleResidueFromObservation
  :: AwsSesLeaseRole.AwsSesLeaseRoleObservation
  -> ResidueStatus.ResidueStatus
awsSesLeaseRoleResidueFromObservation observation = case observation of
  AwsSesLeaseRole.AwsSesLeaseRoleAbsent -> ResidueStatus.ResidueAbsent
  AwsSesLeaseRole.AwsSesLeaseRolePresent -> present "iam:get-role confirmed present"
  AwsSesLeaseRole.AwsSesLeaseRoleDrifted drift ->
    present ("iam:get-role confirmed drift: " ++ show drift)
  AwsSesLeaseRole.AwsSesLeaseRoleUnobservable err ->
    ResidueStatus.ResidueUnreachable
      (ResidueStatus.ResidueQueryFailed (show err))
 where
  present evidence =
    ResidueStatus.ResiduePresent
      ResidueStatus.ResidueDetails
        { ResidueStatus.residueEvidence = evidence
        , ResidueStatus.residueStackName = "operational-aws-ses-lease-role"
        }

-- | Sprint 7.8: clear the operational @aws.*@ credential block in
-- Vault (factored out of the previous inline
-- @runTeardown@ body so it can serve as the @operational-aws-config@
-- managed resource's destroy action). Idempotent: writing empty
-- credentials over already-empty ones is a no-op write. The Dhall
-- config keeps its SecretRef targets and preserves the region, falling
-- back to the admin credential's region when the config region is blank.
-- Returns 'ExitSuccess'.
clearOperationalAwsConfig :: FilePath -> Credentials -> IO ExitCode
clearOperationalAwsConfig repoRoot adminCreds = do
  currentConfig <- loadConfigForWrite repoRoot
  let currentRegion =
        if Text.null (Text.strip (awsCredentialRegion (aws currentConfig)))
          then region adminCreds
          else awsCredentialRegion (aws currentConfig)
      emptyOperationalCredentials =
        Credentials
          { access_key_id = ""
          , secret_access_key = ""
          , session_token = Nothing
          , region = currentRegion
          }
      updatedConfig =
        currentConfig
          { aws =
              (aws currentConfig)
                { awsCredentialRegion = currentRegion
                }
          }
  writeOperationalAwsVaultCredentials repoRoot emptyOperationalCredentials
  writeProjectConfigParameters repoRoot updatedConfig
  pure ExitSuccess

-- | Discover the live 'ResidueStatus' of all three
-- 'operationalManagedResources', paired in dependency/registry order. The
-- lease role is observed through its typed owner interpreter; the IAM-user
-- status comes from 'operationalIamUserExists' piped through
-- 'operationalIamUserResidueFromExists'; the @aws.*@-config status from
-- the configured @aws.access_key_id@ via
-- 'operationalAwsConfigResidueFromKey' after resolving the SecretRef
-- from Vault (a failed config load is treated
-- as unreachable so the fail-closed gate refuses rather than presuming
-- the block is clear).
discoverOperationalResidue
  :: FilePath -> Credentials -> IO [(ManagedResource, ResidueStatus.ResidueStatus)]
discoverOperationalResidue repoRoot adminCreds = do
  roleScope <- loadAwsSesLeaseRoleObservationScope repoRoot adminCreds
  roleObservation <-
    AwsSesLeaseRole.observeAwsSesLeaseRole repoRoot adminCreds roleScope
  let roleStatus = awsSesLeaseRoleResidueFromObservation roleObservation
  iamUserExists <- operationalIamUserExists repoRoot adminCreds
  let iamUserStatus = operationalIamUserResidueFromExists iamUserExists
  configResult <- loadConfigFile repoRoot
  rawAwsConfigStatus <-
    case configResult of
      Left err -> pure (ResidueStatus.ResidueUnreachable (ResidueStatus.ResidueQueryFailed err))
      Right config -> do
        credentialsResult <- resolveAwsCredentialsRefFromHostVault repoRoot "aws" (aws config)
        pure (operationalAwsConfigResidueFromCredentialsResult credentialsResult)
  -- Sprint 7.24: the operational @aws.*@ block is a @SecretRef.Vault@ (Sprint
  -- 7.14), so observing it resolves the reference from host Vault. At harness
  -- \*preflight* the cluster is not up yet, so Vault is unreachable and the
  -- observation returns 'ResidueUnreachable'. The fail-closed gate
  -- (lifecycle_reconciliation_doctrine.md §3.1) exists to avoid stranding the
  -- operational IAM USER — and that user is observed authoritatively via the
  -- admin credential ('operationalIamUserExists'), which is independent of
  -- Vault. When the user is CONFIRMED ABSENT, the aws-config block is a
  -- credential for a user that no longer exists, so a Vault-unreachable read of
  -- it carries no stranding risk: refine it to Absent so a clean-machine
  -- preflight is not deadlocked on a Vault that only comes up later in the run.
  let awsConfigStatus = refineAwsConfigResidueAgainstIamUser iamUserStatus rawAwsConfigStatus
  pure
    ( zip
        (operationalManagedResources adminCreds)
        [roleStatus, iamUserStatus, awsConfigStatus]
    )

-- | Sprint 7.8: read-only listing of the operational IAM user's
-- access-key IDs, factored from 'deleteExistingOperationalKeys' so
-- 'applyAwsTeardown' can record the keys that existed BEFORE the
-- registry reconcile destroys them (preserving the
-- 'iamTeardownDeletedAccessKeys' result field). Returns @[]@ when the
-- user does not exist.
listOperationalAccessKeyIds :: FilePath -> Credentials -> IO [Text]
listOperationalAccessKeyIds repoRoot adminCredentials = do
  -- Sprint 7.20 (P4): this probe runs inside the teardown-completeness guard;
  -- a transient throttle / service-unavailable must not be misread as residue
  -- or as a hard failure. Retry transient API errors with backoff; permanent
  -- errors (including the `NoSuchEntity` that means "gone") fall through to the
  -- classification below unchanged.
  listKeysOutput <-
    runAwsCliCompletedRetryingTransient
      repoRoot
      adminCredentials
      [ "iam"
      , "list-access-keys"
      , "--user-name"
      , Text.unpack prodboxIamUserName
      ]
  if processExitCode listKeysOutput == ExitSuccess
    then do
      listPayloadValue <-
        liftAwsEither (decodeJsonPayload "list-access-keys" (processStdout listKeysOutput))
      listPayloadObject <- liftAwsEither (requireObject "list-access-keys" listPayloadValue)
      accessKeysArray <-
        liftAwsEither (requireArrayField "list-access-keys" "AccessKeyMetadata" listPayloadObject)
      forM (Vector.toList accessKeysArray) $ \item -> do
        metadataObject <- liftAwsEither (requireObject "AccessKeyMetadata" item)
        liftAwsEither (requireTextField "AccessKeyMetadata" "AccessKeyId" metadataObject)
    else case awsErrorCode (errorDetail listKeysOutput) of
      Just "NoSuchEntity" -> pure []
      _ -> throwAws ("aws iam list-access-keys failed: " ++ errorDetail listKeysOutput)

-- | Sprint 7.20: the PURE teardown-completeness classifier. Given the
-- post-teardown AWS-side ('IamProbe') and Vault-side ('VaultProbe')
-- observations, decide whether the harness teardown was complete.
--
-- A run is COMPLETE (@Right ()@) only when ALL of:
--
-- * the operational IAM user is gone from AWS,
-- * no access keys remain attached to it, AND
-- * the Vault operational credential reads back CLEARED.
--
-- Any residue — user present OR keys present OR Vault cred populated —
-- yields a 'Left' 'ResidueError' naming exactly what leaked, so the
-- effectful wrapper can abort LOUD. This is the unit-testable decision
-- core of the guard; the live AWS/Vault queries live in
-- 'assertOperationalTeardownComplete' around it (the 🧪 Live-proof axis).
residueFromProbe :: IamProbe -> VaultProbe -> Either ResidueError ()
residueFromProbe iamProbe vaultProbe =
  let residue =
        ResidueError
          { residueUserLeaked = iamProbeUserPresent iamProbe
          , residueLeakedKeys = iamProbeAccessKeyIds iamProbe
          , residueVaultPopulated = vaultProbe == VaultCredsPopulated
          }
   in if residueErrorIsEmpty residue
        then Right ()
        else Left residue

-- | Sprint 7.20: pure PASS predicate for a 'ResidueError' — no user, no
-- leaked keys, Vault cleared. Factored so 'residueFromProbe' and any
-- future caller share one definition of "complete".
residueErrorIsEmpty :: ResidueError -> Bool
residueErrorIsEmpty residue =
  not (residueUserLeaked residue)
    && null (residueLeakedKeys residue)
    && not (residueVaultPopulated residue)

-- | Sprint 7.20: render a 'ResidueError' into the loud, operator-actionable
-- abort narrative. Names each leaked surface explicitly (IAM user, access
-- keys with their IDs, Vault credential) so the operator knows precisely
-- what the harness teardown failed to remove. Pure; unit-testable.
renderResidueError :: ResidueError -> String
renderResidueError residue =
  intercalate
    "\n"
    ( "AWS IAM harness teardown-completeness guard FAILED: the postflight teardown left residue behind."
        : map ("  - " ++) leaks
        ++ [ "Re-run `prodbox aws teardown` (its destroy paths are idempotent) to clear the leaked"
           , "operational state, then confirm the guard passes."
           ]
    )
 where
  leaks =
    concat
      [ [ "the operational `"
            ++ Text.unpack prodboxIamUserName
            ++ "` IAM user still EXISTS in AWS (expected: deleted)"
        | residueUserLeaked residue
        ]
      , [ "the operational `"
            ++ Text.unpack prodboxIamUserName
            ++ "` IAM user still has "
            ++ show (length (residueLeakedKeys residue))
            ++ " access key(s) attached: "
            ++ intercalate ", " (map Text.unpack (residueLeakedKeys residue))
            ++ " (expected: all deleted)"
        | not (null (residueLeakedKeys residue))
        ]
      , [ "the operational Vault credential at `secret/gateway/gateway/aws` "
            ++ "still reads back POPULATED (expected: cleared)"
        | residueVaultPopulated residue
        ]
      ]

-- | Sprint 7.20: the EFFECTFUL wrapper of the teardown-completeness guard.
-- Runs AFTER 'applyAwsTeardown' destroys the SES lease role, operational IAM
-- user + keys, and clears the Vault credential, then asserts the harness left NO
-- residue:
--
--   (a) the fixed SES lease role is gone from AWS;
--   (b) the operational @prodbox@ IAM user + its access keys are gone
--       from AWS — queried with the admin credentials through the same
--       'operationalIamUserExists' / 'listOperationalAccessKeyIds' probes
--       the destroy path used; and
--   (c) the Vault operational credential at @secret/gateway/gateway/aws@
--       is cleared, reusing 'operationalCredentialsCleared'.
--
-- The two observations are unified into one 'IamProbe' / 'VaultProbe'
-- pair and handed to the pure 'residueFromProbe' classifier; a 'Left'
-- aborts LOUD via 'throwAws' with 'renderResidueError'. The IAM existence
-- probe is fail-closed — if AWS IAM cannot be observed, the underlying
-- 'throwAws' surfaces the error rather than presuming the user is gone.
--
-- Note (Vault clear semantics): "cleared" means the credential block
-- reads back empty, NOT a true KV delete. The harness clears by writing
-- empty values, so the guard checks CLEARED rather than DELETED. A true
-- KV delete of @secret/gateway/gateway/aws@ is an optional future
-- refinement and is intentionally NOT performed here.
assertOperationalTeardownComplete :: FilePath -> Credentials -> IO ()
assertOperationalTeardownComplete repoRoot adminCreds = do
  assertAwsSesLeaseRoleAbsent repoRoot adminCreds
  iamProbe <- probeOperationalIamResidue repoRoot adminCreds
  configCleared <- operationalCredentialsCleared repoRoot
  let vaultProbe = if configCleared then VaultCredsCleared else VaultCredsPopulated
  case residueFromProbe iamProbe vaultProbe of
    Right () -> pure ()
    Left residue -> throwAws (renderResidueError residue)

assertAwsSesLeaseRoleAbsent :: FilePath -> Credentials -> IO ()
assertAwsSesLeaseRoleAbsent repoRoot adminCreds = do
  scope <- loadAwsSesLeaseRoleObservationScope repoRoot adminCreds
  observation <-
    AwsSesLeaseRole.observeAwsSesLeaseRole repoRoot adminCreds scope
  case observation of
    AwsSesLeaseRole.AwsSesLeaseRoleAbsent -> pure ()
    AwsSesLeaseRole.AwsSesLeaseRolePresent -> leaked "present"
    AwsSesLeaseRole.AwsSesLeaseRoleDrifted drift ->
      leaked ("present and drifted: " ++ show drift)
    AwsSesLeaseRole.AwsSesLeaseRoleUnobservable err ->
      throwAws
        ( "AWS IAM harness teardown-completeness guard FAILED: cannot re-observe "
            ++ "the operational AWS SES lease role after teardown: "
            ++ show err
        )
 where
  leaked detail =
    throwAws
      ( "AWS IAM harness teardown-completeness guard FAILED: the operational "
          ++ "AWS SES lease role still exists after teardown ("
          ++ detail
          ++ "). Re-run `prodbox aws teardown`; its destroy path is idempotent."
      )

-- | Sprint 7.20: effectful adapter that turns the existing live IAM
-- probes into a pure 'IamProbe'. Reuses 'operationalIamUserExists' for
-- the user fact (failing loud — fail-closed — on any non-@NoSuchEntity@
-- error so "cannot observe" is never silently read as "gone") and
-- 'listOperationalAccessKeyIds' for the remaining-keys fact. When the user
-- is absent, no key listing is attempted (the probe returns @[]@ for a
-- @NoSuchEntity@ user anyway, but skipping the call avoids a redundant
-- AWS round trip).
probeOperationalIamResidue :: FilePath -> Credentials -> IO IamProbe
probeOperationalIamResidue repoRoot adminCreds = do
  userExistsResult <- operationalIamUserExists repoRoot adminCreds
  userPresent <- either throwAws pure userExistsResult
  remainingKeys <-
    if userPresent
      then listOperationalAccessKeyIds repoRoot adminCreds
      else pure []
  pure
    IamProbe
      { iamProbeUserPresent = userPresent
      , iamProbeAccessKeyIds = remainingKeys
      }

-- | Sprint 7.7 — destroy-first dispatch helper. Invokes
-- @prodbox aws stack \<stack> destroy --yes@ for each stack in the plan,
-- in canonical order. Stops at first failure and returns its
-- subprocess error. The destroy subprocesses inherit the existing
-- operational @aws.*@ from the dhall config — they do NOT consume the
-- admin credential passed into 'applyAwsTeardown'.
--
-- For 'aws-ses' specifically, emits a stderr warning before invoking
-- its destroy so operators see the SES re-verify + S3 bucket cooldown
-- cost they are accepting.
dispatchPulumiDestroysForResidue
  :: FilePath -> [(String, String)] -> IO (Either String ())
dispatchPulumiDestroysForResidue repoRoot plan = go plan
 where
  binaryPath = canonicalOperatorBinaryPath repoRoot
  go :: [(String, String)] -> IO (Either String ())
  go [] = pure (Right ())
  go ((stackName, _destroyCmd) : rest) = do
    when
      (stackName == "aws-ses")
      ( writeDiagnosticLine
          ( "`aws-ses` is long-lived cross-substrate shared infrastructure. "
              ++ "Destroying it now will trigger a 5-30 min SES domain identity + DKIM "
              ++ "re-verification on next reprovision, and the S3 capture bucket "
              ++ "cannot be re-created for ~24 hours. Proceeding because "
              ++ "`--destroy-pulumi-residue` was set."
          )
      )
    let cliArgs = pulumiDestroyArgsForStack stackName
        spec =
          Subprocess
            { subprocessPath = binaryPath
            , subprocessArguments = cliArgs
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Just repoRoot
            }
    runResult <- runSubprocessStreaming spec
    case runResult of
      Failure err ->
        pure
          ( Left
              ( "failed to start `prodbox "
                  ++ unwords cliArgs
                  ++ "` for "
                  ++ stackName
                  ++ ": "
                  ++ err
              )
          )
      Success ExitSuccess -> go rest
      Success (ExitFailure code) ->
        pure
          ( Left
              ( "`prodbox "
                  ++ unwords cliArgs
                  ++ "` exited with code "
                  ++ show code
                  ++ " while destroying "
                  ++ stackName
              )
          )

  pulumiDestroyArgsForStack :: String -> [String]
  pulumiDestroyArgsForStack stackName =
    case stackName of
      "aws-eks" -> ["aws", "stack", "eks", "destroy", "--yes"]
      "aws-eks-subzone" -> ["aws", "stack", "aws-subzone", "destroy", "--yes"]
      "aws-test" -> ["aws", "stack", "test", "destroy", "--yes"]
      "aws-ses" -> ["aws", "stack", "aws-ses", "destroy", "--yes"]
      other -> ["aws", "stack", other, "destroy", "--yes"]

-- | Sprint 7.6 refuse-path generalized to typed Pulumi-stack residue
-- queries per Sprint 4.16. Returns the list of live stacks paired with
-- the canonical destroy command operators should run to clean them up.
-- An empty list means it is safe to delete the operational IAM user.
--
-- Sprint 4.26: the canonical @(stack-name, destroy-command)@ list is now
-- wholly registry-derived through 'pairPerRunResidue' / 'pairAwsSesResidue'
-- + 'residueGateRefusalList', retiring the parallel hand-maintained
-- @categorizePulumiResidue@ classifier the registry subsumes. The IO half
-- reaches into the in-cluster MinIO backend (via one shared port-forward
-- across the three per-run stacks) and the operator-account S3 backend
-- (admin credentials) so the residue listing reflects what is actually in
-- the Pulumi backends, not stale file-existence approximations.
--
-- Both per-run and long-lived 'ResidueUnreachable' count as blocking
-- residue for this teardown gate (Sprint 4.19/4.20): "cannot read the
-- Pulumi state backend" is not a confirmation that the AWS resources are
-- gone, so @prodbox aws teardown@ must refuse rather than delete the
-- operational IAM user and strand unreadable stacks. 'residueGateRefusalList'
-- encodes that via 'ResidueStatus.residueBlocksTeardownGate' ("present OR
-- unreachable → block"). (The @--cascade@ path keeps its own
-- graceful-degradation handling in
-- 'Prodbox.Lifecycle.ResourceRegistry.resourcesToDestroy'.)
checkPulumiResidueBeforeTeardown :: FilePath -> IO [(String, String)]
checkPulumiResidueBeforeTeardown repoRoot = do
  perRun <- queryPerRunResidueStatuses repoRoot
  ses <- queryAwsSesResidueStatus repoRoot
  pure
    ( residueGateRefusalList
        ( pairPerRunResidue
            (perRunAwsEksTest perRun)
            (perRunAwsEksSubzone perRun)
            (perRunAwsTest perRun)
            ++ pairAwsSesResidue ses
        )
    )

renderPulumiResidueRefusal :: [(String, String)] -> String
renderPulumiResidueRefusal residue =
  unlines
    ( [ "AWS teardown refused: Pulumi-managed AWS stacks still have live resources."
      , ""
      , "Deleting the operational IAM user now would strand these stacks from"
      , "the supported destroy surface (every `prodbox aws stack <stack> destroy`"
      , "fails fast when operational `aws.*` is empty)."
      , ""
      , "Run the canonical destroy command for each stack below first, then"
      , "re-run `prodbox aws teardown`:"
      , ""
      ]
        ++ map (\(name, cmd) -> "  - " ++ name ++ " → " ++ cmd) residue
        ++ [ ""
           , "Or re-run with `--destroy-pulumi-residue` to destroy these stacks"
           , "automatically before the IAM teardown proceeds (Sprint 7.7)."
           , ""
           , "If you must delete the IAM user anyway (recovery scenarios),"
           , "re-run with `--allow-pulumi-residue` to bypass this check."
           ]
    )

-- | Sprint 7.7 — refusal renderer for the harness-internal
-- 'BypassPerRunResidueOnly' policy. Lists only the long-lived stacks
-- that block the teardown (per-run stacks are intentionally not
-- mentioned because 'awsPostflightDestroyActions' handles them
-- separately). Frames the recovery as "destroy the long-lived stack
-- via its canonical command, then re-run" since the harness has no
-- analog of @--destroy-pulumi-residue@.
renderPulumiResidueLongLivedRefusal :: [(String, String)] -> String
renderPulumiResidueLongLivedRefusal longLived =
  unlines
    ( [ "AWS teardown refused: long-lived cross-substrate shared Pulumi stacks"
      , "still have live resources."
      , ""
      , "The test harness will not clear operational `aws.*` while these stacks"
      , "are alive — doing so would strand them from the supported destroy"
      , "surface (every `prodbox aws stack <stack> destroy` fails fast when"
      , "operational `aws.*` is empty)."
      , ""
      , "Run the canonical destroy command for each stack below first, then"
      , "re-run the test that triggered this teardown:"
      , ""
      ]
        ++ map (\(name, cmd) -> "  - " ++ name ++ " → " ++ cmd) longLived
    )

applyAwsCheckQuotas :: FilePath -> AwsCheckQuotasInput -> IO [QuotaStatus]
applyAwsCheckQuotas repoRoot input =
  mapM
    (\spec -> ensureServiceQuota repoRoot (awsCheckQuotasAdminCredentials input) spec False)
    fullQuotaSpecs

applyAwsRegionQuotaPreflight
  :: FilePath -> AwsCheckQuotasInput -> IO (Either StorageCapacityRefusal ())
applyAwsRegionQuotaPreflight repoRoot input =
  awsRegionQuotaPreflightFromStatuses <$> applyAwsCheckQuotas repoRoot input

observeAwsSpotPrice :: FilePath -> Credentials -> SpotPriceRequest -> IO SpotObservation
observeAwsSpotPrice repoRoot credentials request = do
  result <-
    try
      ( do
          environment <- operationalAwsEnvironment credentials
          captureSubprocessResult
            Subprocess
              { subprocessPath = "aws"
              , subprocessArguments = awsSpotPriceHistoryArgs request
              , subprocessEnvironment = Just environment
              , subprocessWorkingDirectory = Just repoRoot
              }
      )
      :: IO (Either SomeException (Result ProcessOutput))
  pure $ case result of
    Left err ->
      SpotUnobservable
        (UnobservableReason (Text.pack ("aws spot price observation failed: " ++ displayException err)))
    Right (Failure err) ->
      SpotUnobservable (UnobservableReason (Text.pack ("aws spot price observation failed: " ++ err)))
    Right (Success output) ->
      spotObservationFromAwsSpotPriceOutput output

awsSpotPriceHistoryArgs :: SpotPriceRequest -> [String]
awsSpotPriceHistoryArgs request =
  [ "ec2"
  , "describe-spot-price-history"
  , "--instance-types"
  , Text.unpack (spotPriceInstanceType request)
  , "--product-descriptions"
  , Text.unpack (spotPriceProductDescription request)
  , "--max-results"
  , "1"
  , "--output"
  , "json"
  ]

spotObservationFromAwsSpotPriceOutput :: ProcessOutput -> SpotObservation
spotObservationFromAwsSpotPriceOutput output =
  case requireCommandSuccess "aws ec2 describe-spot-price-history" output of
    Left err -> SpotUnobservable (UnobservableReason (Text.pack err))
    Right payload -> spotObservationFromAwsSpotPriceHistory payload

spotObservationFromAwsSpotPriceHistory :: String -> SpotObservation
spotObservationFromAwsSpotPriceHistory payload =
  case decodeJsonPayload "aws ec2 describe-spot-price-history" payload >>= parseSpotPriceHistory of
    Left err -> SpotUnobservable (UnobservableReason (Text.pack err))
    Right observation -> observation

parseSpotPriceHistory :: Value -> Either String SpotObservation
parseSpotPriceHistory value = do
  rootObject <- requireObject "aws ec2 describe-spot-price-history" value
  history <- requireArrayField "aws ec2 describe-spot-price-history" "SpotPriceHistory" rootObject
  case Vector.toList history of
    [] -> Left "aws ec2 describe-spot-price-history returned no spot price history"
    firstEntry : _ -> do
      entryObject <- requireObject "SpotPriceHistory[0]" firstEntry
      price <- requireSpotPriceField "SpotPriceHistory[0]" entryObject
      pure (SpotObserved price)

requireSpotPriceField :: String -> Object -> Either String UsdPerHour
requireSpotPriceField context objectValue =
  case KeyMap.lookup (Key.fromString "SpotPrice") objectValue of
    Just (String priceText) ->
      case parseUsdPerHour priceText of
        Left (UnobservableReason reason) -> Left (Text.unpack reason)
        Right price -> Right price
    Just (Number priceNumber) ->
      case parseUsdPerHour (Text.pack (show (realToFrac priceNumber :: Double))) of
        Left (UnobservableReason reason) -> Left (Text.unpack reason)
        Right price -> Right price
    _ -> Left (context ++ " missing required SpotPrice field")

awsRegionQuotaPreflightFromStatuses :: [QuotaStatus] -> Either StorageCapacityRefusal ()
awsRegionQuotaPreflightFromStatuses statuses =
  regionQuotaPreflight (map quotaStatusRegionObservation statuses)

quotaStatusRegionObservation :: QuotaStatus -> AwsRegionQuotaObservation
quotaStatusRegionObservation status =
  AwsRegionQuotaObservation
    { regionQuotaName = quotaStatusDisplayName status
    , regionQuotaCurrentValue = quotaStatusCurrentValue status
    , regionQuotaTargetValue = quotaStatusTargetValue status
    , regionQuotaMeetsTarget = quotaStatusMeetsTarget status
    }

applyAwsRequestQuotas :: FilePath -> AwsRequestQuotasInput -> IO [QuotaStatus]
applyAwsRequestQuotas repoRoot input =
  mapM
    (\spec -> ensureServiceQuota repoRoot (awsRequestQuotasAdminCredentials input) spec True)
    (quotaSpecsForTier (awsRequestQuotasPolicyTierInput input))

-- | The single pure builder that interprets a 'ConfigSetupInput' into the
-- updated non-secret 'ConfigFile' — the @demoInit@ analog (Sprint 1.50). Both
-- production @config setup@ ('applyConfigSetup') and the test harness
-- ('Prodbox.TestRunner', Sprint 5.10) construct config through this ONE
-- function, so the harness drives the same reconcile / IAM flows against a
-- config it generated, not a fixture it carries (config_doctrine.md §0, "The
-- test harness generates its run config"). Sensitive fields are never written
-- here — they remain @SecretRef.Vault@ pointers in @currentConfig@; the region
-- comes from the input's admin credential.
configFromSetupInput :: ConfigFile -> ConfigSetupInput -> ConfigFile
configFromSetupInput currentConfig input =
  currentConfig
    { aws =
        (aws currentConfig)
          { awsCredentialRegion = region (configSetupAdminCredentialsInput input)
          }
    , route53 = Route53Section {zone_id = configSetupRoute53ZoneIdInput input}
    , domain =
        DomainSection
          { demo_fqdn = configSetupDemoFqdnInput input
          , demo_ttl = configSetupDemoTtlInput input
          , -- Sprint 2.35: `config setup` does not prompt for cert scopes; preserve
            -- whatever the operator already configured (empty = just the served host).
            cert_scopes = cert_scopes (domain currentConfig)
          }
    , acme =
        (acme currentConfig)
          { email = configSetupAcmeEmailInput input
          , server = configSetupAcmeServerInput input
          }
    , deployment =
        DeploymentSection
          { dev_mode = configSetupDevModeInput input
          , bootstrap_public_ip_override = configSetupBootstrapPublicIpOverrideInput input
          , pulumi_enable_dns_bootstrap = configSetupPulumiEnableDnsBootstrapInput input
          , public_edge_advertisement_mode = configSetupPublicEdgeAdvertisementModeInput input
          , public_edge_bgp_peers = configSetupPublicEdgeBgpPeersInput input
          , envoy_gateway_controller_scaling = configSetupEnvoyGatewayControllerScalingInput input
          , envoy_gateway_data_plane_scaling = configSetupEnvoyGatewayDataPlaneScalingInput input
          , api_scaling = configSetupApiScalingInput input
          , websocket_scaling = configSetupWebsocketScalingInput input
          }
    , storage = StorageSection {manual_pv_host_root = configSetupManualPvHostRootInput input}
    }

-- | The ACME registration email the harness bakes into the generated config
-- (Sprint 5.10) — the operator's contact, used non-interactively in place of
-- the @prodbox config setup@ ACME-email prompt. Not a secret.
harnessAcmeEmail :: Text
harnessAcmeEmail = "matthewnowak@gmail.com"

-- | Assemble a 'ConfigSetupInput' non-interactively for the test harness — the
-- no-prompt analog of 'interactiveConfigSetupInput' (Sprint 5.10, the
-- @demoTestConfig@ idiom). The cleartext @route53.zone_id@ and the ACME EAB come
-- from @test-secrets.dhall@ (the one file where cleartext operator ids are
-- allowed); @acme.email@ is the baked operator default; every other knob is
-- carried over from the current (generated-skeleton) config, whose defaults
-- already match @config setup@.
harnessConfigSetupInput
  :: FilePath -> ConfigFile -> PolicyTier -> IO (Either String ConfigSetupInput)
harnessConfigSetupInput repoRoot currentConfig policyTier = do
  secretsResult <- loadTestSecrets repoRoot
  case secretsResult of
    Nothing ->
      pure (Left "harness config regeneration requires test-secrets.dhall (absent).")
    Just (Left err) ->
      pure (Left ("harness config regeneration failed to decode test-secrets.dhall: " ++ err))
    Just (Right secrets) -> do
      credentialsResult <- acquireAdminAwsCredentials repoRoot
      pure $ case credentialsResult of
        Left err -> Left err
        Right credentials ->
          Right
            ConfigSetupInput
              { configSetupAdminCredentialsInput = credentials
              , configSetupRoute53ZoneIdInput =
                  harnessPreferNonEmpty (route53_zone_id secrets) (zone_id (route53 currentConfig))
              , configSetupDemoFqdnInput = demo_fqdn (domain currentConfig)
              , configSetupDemoTtlInput = demo_ttl (domain currentConfig)
              , configSetupAcmeEmailInput = harnessAcmeEmail
              , configSetupAcmeServerInput = zeroSslAcmeServer
              , configSetupAcmeEabKeyIdInput = key_id <$> acme_eab secrets
              , configSetupAcmeEabHmacKeyInput = hmac_key <$> acme_eab secrets
              , configSetupDevModeInput = dev_mode (deployment currentConfig)
              , configSetupBootstrapPublicIpOverrideInput =
                  bootstrap_public_ip_override (deployment currentConfig)
              , configSetupPulumiEnableDnsBootstrapInput =
                  pulumi_enable_dns_bootstrap (deployment currentConfig)
              , configSetupPublicEdgeAdvertisementModeInput =
                  public_edge_advertisement_mode (deployment currentConfig)
              , configSetupPublicEdgeBgpPeersInput =
                  public_edge_bgp_peers (deployment currentConfig)
              , configSetupEnvoyGatewayControllerScalingInput =
                  envoy_gateway_controller_scaling (deployment currentConfig)
              , configSetupEnvoyGatewayDataPlaneScalingInput =
                  envoy_gateway_data_plane_scaling (deployment currentConfig)
              , configSetupApiScalingInput = api_scaling (deployment currentConfig)
              , configSetupWebsocketScalingInput = websocket_scaling (deployment currentConfig)
              , configSetupManualPvHostRootInput = manual_pv_host_root (storage currentConfig)
              , configSetupPolicyTierInput = policyTier
              }

-- | Test-harness preflight (Sprint 5.10): regenerate the binary-sibling
-- @prodbox.dhall@ from @test-secrets.dhall@ + baked defaults through the shared
-- 'configFromSetupInput' builder, so @prodbox test all@ runs from a freshly
-- generated skeleton without an interactive @config setup@. Only regenerates
-- when the operator fields are empty — it refuses to clobber a populated real
-- config (the @demoTestConfig@ "generate only your own run config" rule). Runs
-- before the managed AWS IAM harness validates the bootstrap config.
-- | Sprint 5.10 follow-up: prefer the @test-secrets.dhall@-supplied operator id,
-- but fall back to the value already in the config when test-secrets leaves it
-- empty — so the harness regen fills empty operator fields without clobbering a
-- populated one with a blank. (A real @test-secrets.dhall@ supplies non-empty
-- values, so this is identity for `test all`; it matters for the in-process CLI
-- tests, whose fixture config carries a `route53.zone_id` the fake test-secrets
-- leaves empty.)
harnessPreferNonEmpty :: Text.Text -> Text.Text -> Text.Text
harnessPreferNonEmpty fromSecrets fromConfig =
  if Text.null (Text.strip fromSecrets) then fromConfig else fromSecrets

regenerateConfigFromTestSecrets :: FilePath -> PolicyTier -> IO (Either String ())
regenerateConfigFromTestSecrets repoRoot policyTier = do
  currentConfig <- loadConfigForWrite repoRoot
  let zoneSet = not (Text.null (Text.strip (zone_id (route53 currentConfig))))
      emailSet = not (Text.null (Text.strip (email (acme currentConfig))))
      sesSet = not (Text.null (Text.strip (sender_domain (ses currentConfig))))
      backendSet =
        not (Text.null (Text.strip (psbBucketName (pulumi_state_backend currentConfig))))
  if zoneSet && emailSet && sesSet && backendSet
    then pure (Right ())
    else do
      secretsResult <- loadTestSecrets repoRoot
      case secretsResult of
        Nothing ->
          pure (Left "harness config regeneration requires test-secrets.dhall (absent).")
        Just (Left err) ->
          pure (Left ("harness config regeneration failed to decode test-secrets.dhall: " ++ err))
        Just (Right secrets) -> do
          inputResult <- harnessConfigSetupInput repoRoot currentConfig policyTier
          case inputResult of
            Left err -> pure (Left err)
            Right input -> do
              -- `config setup` does not author the `ses.*` block, so the shared
              -- `configFromSetupInput` builder leaves it untouched; the harness
              -- injects it directly from `test-secrets.dhall` (Sprint 5.10
              -- follow-up) so the keycloak-invite SES stack provisions.
              let built = configFromSetupInput currentConfig input
                  withSes =
                    built
                      { ses =
                          SesSection
                            { sender_domain =
                                harnessPreferNonEmpty (ses_sender_domain secrets) (sender_domain (ses built))
                            , receive_subdomain =
                                harnessPreferNonEmpty (ses_receive_subdomain secrets) (receive_subdomain (ses built))
                            , capture_bucket =
                                harnessPreferNonEmpty (ses_capture_bucket secrets) (capture_bucket (ses built))
                            }
                      , pulumi_state_backend =
                          (pulumi_state_backend built)
                            { psbBucketName =
                                harnessPreferNonEmpty
                                  (pulumi_state_backend_bucket_name secrets)
                                  (psbBucketName (pulumi_state_backend built))
                            , psbRegion =
                                harnessPreferNonEmpty
                                  (pulumi_state_backend_region secrets)
                                  (psbRegion (pulumi_state_backend built))
                            }
                      }
              writeProjectConfigParameters repoRoot withSes
              pure (Right ())

applyConfigSetup :: FilePath -> ConfigSetupInput -> IO ConfigSetupResult
applyConfigSetup repoRoot input = do
  let adminCredentials = configSetupAdminCredentialsInput input
  (newAccessKeyId, newSecretAccessKey, quotaStatuses) <-
    ensureOperationalIamUser repoRoot adminCredentials (configSetupPolicyTierInput input)
  waitForOperationalCredentialsReady
    repoRoot
    adminCredentials
    (Just (configSetupRoute53ZoneIdInput input))
    newAccessKeyId
    newSecretAccessKey
  currentConfig <- loadConfigForWrite repoRoot
  let operationalCredentials =
        Credentials
          { access_key_id = newAccessKeyId
          , secret_access_key = newSecretAccessKey
          , session_token = Nothing
          , region = region adminCredentials
          }
  writeOperationalAwsVaultCredentials repoRoot operationalCredentials
  -- Sprint 7.15: the prompted ZeroSSL EAB key ID + HMAC key are written to
  -- Vault (@secret/acme/eab@, fields @key_id@ / @hmac_key@), mirroring the
  -- operational AWS credentials above. They are never persisted into
  -- @prodbox.dhall@; the config keeps the @SecretRef.Vault@ references.
  writeAcmeEabVaultCredentials
    repoRoot
    (configSetupAcmeEabKeyIdInput input)
    (configSetupAcmeEabHmacKeyInput input)
  let updatedConfig = configFromSetupInput currentConfig input
  installOperationalIamPolicyForConfig
    repoRoot
    adminCredentials
    (configSetupPolicyTierInput input)
    updatedConfig
  ensureConfiguredAwsSesLeaseRole
    repoRoot
    adminCredentials
    (configSetupPolicyTierInput input)
    updatedConfig
  writeProjectConfigParameters repoRoot updatedConfig
  validationResult <- validateAndLoadSettings repoRoot
  case validationResult of
    Left err -> throwAws err
    Right _ ->
      pure
        ConfigSetupResult
          { configSetupRegion = region adminCredentials
          , configSetupRoute53ZoneId = configSetupRoute53ZoneIdInput input
          , configSetupDemoFqdn = configSetupDemoFqdnInput input
          , configSetupPolicyTier = configSetupPolicyTierInput input
          , configSetupAccessKeyId = newAccessKeyId
          , configSetupQuotaStatuses = quotaStatuses
          , configSetupDhallPath = canonicalTier0ConfigDisplayPath repoRoot
          }

-- | Ensure the fixed SES lease role only when its public resource scope is
-- fully available. A freshly generated operator config intentionally starts
-- with an empty hosted zone and SES capture bucket, so initial @aws setup@
-- must remain usable and defer this role until @config setup@ (or a later
-- idempotent @aws setup@) has supplied both identifiers.
ensureConfiguredAwsSesLeaseRole
  :: FilePath -> Credentials -> PolicyTier -> ConfigFile -> IO ()
ensureConfiguredAwsSesLeaseRole repoRoot adminCredentials policyTier config =
  case policyTier of
    PolicyCore -> pure ()
    PolicyFull -> do
      accountId <- awsCallerAccountId repoRoot adminCredentials
      maybeScope <-
        either throwAws pure (configuredAwsSesLeaseRoleScope accountId config)
      case maybeScope of
        Nothing -> pure ()
        Just scope -> do
          result <-
            AwsSesLeaseRole.ensureAwsSesLeaseRole
              repoRoot
              adminCredentials
              scope
          case result of
            Left err ->
              throwAws
                ( "Failed to ensure the operational AWS SES lease role: "
                    ++ show err
                )
            Right () -> pure ()

configuredAwsSesLeaseRoleScope
  :: Text
  -> ConfigFile
  -> Either String (Maybe AwsSesLeaseRole.AwsSesLeaseRolePolicyScope)
configuredAwsSesLeaseRoleScope accountId config =
  let hostedZoneId = Text.strip (zone_id (route53 config))
      captureBucket = Text.strip (capture_bucket (ses config))
      legacyStateBucket = nonEmptyText (psbBucketName (pulumi_state_backend config))
   in if Text.null hostedZoneId || Text.null captureBucket
        then Right Nothing
        else case AwsSesLeaseRole.mkAwsSesLeaseRolePolicyScope
          accountId
          hostedZoneId
          captureBucket
          legacyStateBucket of
          Left err ->
            Left
              ( "Invalid AWS SES lease-role policy scope in prodbox.dhall: "
                  ++ show err
              )
          Right scope -> Right (Just scope)

ensureOperationalIamUser :: FilePath -> Credentials -> PolicyTier -> IO (Text, Text, [QuotaStatus])
ensureOperationalIamUser repoRoot adminCredentials policyTier = do
  createUserOutput <-
    runAwsCliCompleted
      repoRoot
      adminCredentials
      [ "iam"
      , "create-user"
      , "--user-name"
      , Text.unpack prodboxIamUserName
      ]
  when
    ( processExitCode createUserOutput /= ExitSuccess
        && awsErrorCode (errorDetail createUserOutput) /= Just "EntityAlreadyExists"
    )
    $ throwAws ("aws iam create-user failed: " ++ errorDetail createUserOutput)

  currentConfig <- loadConfigForWrite repoRoot
  installOperationalIamPolicyForConfig
    repoRoot
    adminCredentials
    policyTier
    currentConfig

  accessKeys <- listOperationalAccessKeys repoRoot adminCredentials
  mapM_ (deleteOperationalAccessKey repoRoot adminCredentials) accessKeys

  createAccessKeyOutput <-
    runAwsCliCompleted
      repoRoot
      adminCredentials
      [ "iam"
      , "create-access-key"
      , "--user-name"
      , Text.unpack prodboxIamUserName
      ]
  accessKeyPayloadText <-
    liftAwsEither (requireCommandSuccess "aws iam create-access-key" createAccessKeyOutput)
  accessKeyValue <- liftAwsEither (decodeJsonPayload "aws iam create-access-key" accessKeyPayloadText)
  accessKeyObject <- liftAwsEither (requireObject "create-access-key" accessKeyValue)
  nestedAccessKey <-
    liftAwsEither (requireObjectField "create-access-key" "AccessKey" accessKeyObject)
  newAccessKeyId <- liftAwsEither (requireTextField "AccessKey" "AccessKeyId" nestedAccessKey)
  newSecretKey <- liftAwsEither (requireTextField "AccessKey" "SecretAccessKey" nestedAccessKey)
  quotaStatuses <-
    mapM (\spec -> ensureServiceQuota repoRoot adminCredentials spec True) baselineQuotaSpecs
  pure (newAccessKeyId, newSecretKey, quotaStatuses)

-- | Idempotently install the account/config-qualified operational policy
-- without rotating access keys. @config setup@ calls this again after
-- constructing its updated config so a newly supplied capture bucket is in
-- force before the SES lease role becomes usable.
installOperationalIamPolicyForConfig
  :: FilePath -> Credentials -> PolicyTier -> ConfigFile -> IO ()
installOperationalIamPolicyForConfig repoRoot adminCredentials policyTier config = do
  accountId <- awsCallerAccountId repoRoot adminCredentials
  let configuredCaptureBucket = nonEmptyText (capture_bucket (ses config))
  installedPolicy <-
    case buildIamPolicyDocumentForAccountAndCaptureBucket
      accountId
      configuredCaptureBucket
      policyTier of
      Left err ->
        throwAws
          ( "Cannot build the account-scoped operational IAM policy: "
              ++ show err
          )
      Right policy -> pure policy
  putUserPolicyOutput <-
    runAwsCliCompleted
      repoRoot
      adminCredentials
      [ "iam"
      , "put-user-policy"
      , "--user-name"
      , Text.unpack prodboxIamUserName
      , "--policy-name"
      , Text.unpack prodboxIamInlinePolicyName
      , "--policy-document"
      , -- AWS inline user-policy documents are capped at 2,048 bytes.
        BL8.unpack (encode installedPolicy)
      ]
  _ <-
    liftAwsEither
      (requireCommandSuccess "aws iam put-user-policy" putUserPolicyOutput)
  pure ()

waitForOperationalCredentialsReady :: FilePath -> Credentials -> Maybe Text -> Text -> Text -> IO ()
waitForOperationalCredentialsReady repoRoot adminCredentials maybeRoute53ZoneId newAccessKeyId newSecretAccessKey =
  waitForOperationalCredentialsValueReady repoRoot maybeRoute53ZoneId operationalCredentials
 where
  operationalCredentials =
    Credentials
      { access_key_id = newAccessKeyId
      , secret_access_key = newSecretAccessKey
      , session_token = Nothing
      , region = region adminCredentials
      }

operationalCredentialsAfterReadiness
  :: Bool
  -> FilePath
  -> Credentials
  -> PolicyTier
  -> Maybe Text
  -> Text
  -> Text
  -> IO (Credentials, Text)
operationalCredentialsAfterReadiness
  allowFederatedFallback
  repoRoot
  adminCredentials
  policyTier
  maybeRoute53ZoneId
  newAccessKeyId
  newSecretAccessKey =
    if allowFederatedFallback
      then do
        federatedCredentials <- createFederatedOperationalCredentials repoRoot adminCredentials policyTier
        waitForOperationalCredentialsValueReady repoRoot maybeRoute53ZoneId federatedCredentials
        waitForOperationalCredentialsValueReady repoRoot maybeRoute53ZoneId operationalCredentials
        pure (operationalCredentials, "iam-user")
      else do
        waitForOperationalCredentialsValueReady repoRoot maybeRoute53ZoneId operationalCredentials
        pure (operationalCredentials, "iam-user")
   where
    operationalCredentials =
      Credentials
        { access_key_id = newAccessKeyId
        , secret_access_key = newSecretAccessKey
        , session_token = Nothing
        , region = region adminCredentials
        }

waitForOperationalCredentialsValueReady :: FilePath -> Maybe Text -> Credentials -> IO ()
waitForOperationalCredentialsValueReady repoRoot maybeRoute53ZoneId operationalCredentials = do
  environment <- operationalAwsEnvironment operationalCredentials
  waitForOperationalAwsProbe
    repoRoot
    environment
    "STS validation"
    ["sts", "get-caller-identity"]
  case maybeRoute53ZoneId of
    Nothing -> pure ()
    Just route53ZoneId ->
      waitForOperationalAwsProbeWithStability
        route53CredentialReadyAttempts
        route53CredentialReadyConsecutiveSuccesses
        route53CredentialRetryDelayMicros
        repoRoot
        environment
        "Route 53 hosted-zone validation"
        ["route53", "get-hosted-zone", "--id", Text.unpack route53ZoneId]

createFederatedOperationalCredentials :: FilePath -> Credentials -> PolicyTier -> IO Credentials
createFederatedOperationalCredentials repoRoot adminCredentials policyTier = do
  federatedOutput <-
    runAwsCliCompleted
      repoRoot
      adminCredentials
      [ "sts"
      , "get-federation-token"
      , "--name"
      , Text.unpack prodboxIamUserName
      , "--duration-seconds"
      , "3600"
      , "--policy"
      , BL8.unpack (encode (buildFederatedSessionPolicyDocument policyTier))
      ]
  federatedPayloadText <-
    liftAwsEither (requireCommandSuccess "aws sts get-federation-token" federatedOutput)
  federatedValue <-
    liftAwsEither (decodeJsonPayload "aws sts get-federation-token" federatedPayloadText)
  federatedObject <- liftAwsEither (requireObject "get-federation-token" federatedValue)
  credentialsObject <-
    liftAwsEither (requireObjectField "get-federation-token" "Credentials" federatedObject)
  newAccessKeyId <- liftAwsEither (requireTextField "Credentials" "AccessKeyId" credentialsObject)
  newSecretKey <- liftAwsEither (requireTextField "Credentials" "SecretAccessKey" credentialsObject)
  newSessionToken <- liftAwsEither (requireTextField "Credentials" "SessionToken" credentialsObject)
  pure
    Credentials
      { access_key_id = newAccessKeyId
      , secret_access_key = newSecretKey
      , session_token = Just newSessionToken
      , region = region adminCredentials
      }

waitForOperationalAwsProbe :: FilePath -> [(String, String)] -> String -> [String] -> IO ()
waitForOperationalAwsProbe repoRoot environment label arguments =
  waitForOperationalAwsProbeWithStability
    operationalCredentialReadyAttempts
    1
    operationalCredentialRetryDelayMicros
    repoRoot
    environment
    label
    arguments

waitForOperationalAwsProbeWithStability
  :: Int -> Int -> Int -> FilePath -> [(String, String)] -> String -> [String] -> IO ()
waitForOperationalAwsProbeWithStability maxAttempts requiredSuccesses retryDelay repoRoot environment label arguments =
  go maxAttempts 0 (label ++ " did not return a result")
 where
  go attemptsRemaining consecutiveSuccesses lastError = do
    output <-
      runAwsCliCompletedWithEnvironment
        repoRoot
        environment
        arguments
    case processExitCode output of
      ExitSuccess
        | consecutiveSuccesses + 1 >= max 1 requiredSuccesses -> pure ()
        | attemptsRemaining <= 1 ->
            throwAws
              ( "Generated operational AWS credentials did not remain stable via "
                  ++ "`aws "
                  ++ unwords arguments
                  ++ "`."
              )
        | otherwise -> do
            threadDelay retryDelay
            go (attemptsRemaining - 1) (consecutiveSuccesses + 1) lastError
      ExitFailure _ ->
        let nextError =
              if errorDetail output == "command failed"
                then lastError
                else errorDetail output
         in if attemptsRemaining <= 1
              then
                throwAws
                  ( "Generated operational AWS credentials failed validation via "
                      ++ "`aws "
                      ++ unwords arguments
                      ++ "`: "
                      ++ nextError
                  )
              else do
                threadDelay retryDelay
                go (attemptsRemaining - 1) 0 nextError

nonEmptyText :: Text -> Maybe Text
nonEmptyText value =
  let stripped = Text.strip value
   in if Text.null stripped then Nothing else Just stripped

ensureServiceQuota :: FilePath -> Credentials -> QuotaSpec -> Bool -> IO QuotaStatus
ensureServiceQuota repoRoot adminCredentials spec requestIfNeeded = do
  primaryOutput <-
    runAwsCliCompleted
      repoRoot
      adminCredentials
      [ "service-quotas"
      , "get-service-quota"
      , "--service-code"
      , Text.unpack (quotaServiceCode spec)
      , "--quota-code"
      , Text.unpack (quotaCode spec)
      ]
  (quotaObject, sourceLabel) <-
    if processExitCode primaryOutput == ExitSuccess
      then do
        value <-
          liftAwsEither
            (decodeJsonPayload (Text.unpack (quotaDisplayName spec)) (processStdout primaryOutput))
        payload <- liftAwsEither (requireObject (Text.unpack (quotaDisplayName spec)) value)
        quotaPayload <-
          liftAwsEither (requireObjectField (Text.unpack (quotaDisplayName spec)) "Quota" payload)
        pure (quotaPayload, "current")
      else do
        fallbackOutput <-
          runAwsCliCompleted
            repoRoot
            adminCredentials
            [ "service-quotas"
            , "get-aws-default-service-quota"
            , "--service-code"
            , Text.unpack (quotaServiceCode spec)
            , "--quota-code"
            , Text.unpack (quotaCode spec)
            ]
        fallbackPayloadText <-
          liftAwsEither (requireCommandSuccess (Text.unpack (quotaDisplayName spec)) fallbackOutput)
        value <- liftAwsEither (decodeJsonPayload (Text.unpack (quotaDisplayName spec)) fallbackPayloadText)
        payload <- liftAwsEither (requireObject (Text.unpack (quotaDisplayName spec)) value)
        quotaPayload <-
          liftAwsEither (requireObjectField (Text.unpack (quotaDisplayName spec)) "Quota" payload)
        pure (quotaPayload, "default")
  currentValue <-
    liftAwsEither (requireNumberField (Text.unpack (quotaDisplayName spec)) "Value" quotaObject)
  let meetsTarget = currentValue >= quotaTargetValue spec
      baseStatus =
        QuotaStatus
          { quotaStatusDisplayName = quotaDisplayName spec
          , quotaStatusServiceCode = quotaServiceCode spec
          , quotaStatusQuotaCode = quotaCode spec
          , quotaStatusCurrentValue = currentValue
          , quotaStatusTargetValue = quotaTargetValue spec
          , quotaStatusSource = sourceLabel
          , quotaStatusMeetsTarget = meetsTarget
          , quotaStatusRequestStatus = Nothing
          , quotaStatusNote = Nothing
          }
  if meetsTarget || not requestIfNeeded
    then pure baseStatus
    else do
      requestOutput <-
        runAwsCliCompleted
          repoRoot
          adminCredentials
          [ "service-quotas"
          , "request-service-quota-increase"
          , "--service-code"
          , Text.unpack (quotaServiceCode spec)
          , "--quota-code"
          , Text.unpack (quotaCode spec)
          , "--desired-value"
          , formatDouble (quotaTargetValue spec)
          ]
      if processExitCode requestOutput /= ExitSuccess
        then
          pure
            baseStatus
              { quotaStatusRequestStatus = Just "error"
              , quotaStatusNote = Just (Text.pack (errorDetail requestOutput))
              }
        else do
          requestValue <-
            liftAwsEither
              (decodeJsonPayload (Text.unpack (quotaDisplayName spec)) (processStdout requestOutput))
          requestPayload <- liftAwsEither (requireObject (Text.unpack (quotaDisplayName spec)) requestValue)
          requestedQuota <-
            liftAwsEither
              (requireObjectField (Text.unpack (quotaDisplayName spec)) "RequestedQuota" requestPayload)
          requestStatus <-
            liftAwsEither (requireTextField (Text.unpack (quotaDisplayName spec)) "Status" requestedQuota)
          pure baseStatus {quotaStatusRequestStatus = Just requestStatus}

listAwsRegions :: FilePath -> Credentials -> IO [RegionChoice]
listAwsRegions repoRoot adminCredentials = do
  payload <-
    decodeJsonCommand
      repoRoot
      adminCredentials
      ["ec2", "describe-regions"]
      "aws ec2 describe-regions"
  rootObject <- liftAwsEither (requireObject "describe-regions" payload)
  regionsArray <- liftAwsEither (requireArrayField "describe-regions" "Regions" rootObject)
  mapM parseRegionChoice (Vector.toList regionsArray)

listHostedZones :: FilePath -> Credentials -> IO [HostedZoneChoice]
listHostedZones repoRoot adminCredentials = do
  payload <-
    decodeJsonCommand
      repoRoot
      adminCredentials
      ["route53", "list-hosted-zones"]
      "aws route53 list-hosted-zones"
  rootObject <- liftAwsEither (requireObject "list-hosted-zones" payload)
  zonesArray <- liftAwsEither (requireArrayField "list-hosted-zones" "HostedZones" rootObject)
  mapM parseHostedZoneChoice (Vector.toList zonesArray)

parseRegionChoice :: Value -> IO RegionChoice
parseRegionChoice value = do
  regionObject <- liftAwsEither (requireObject "describe-regions" value)
  regionNameValue <- liftAwsEither (requireTextField "describe-regions" "RegionName" regionObject)
  pure
    RegionChoice
      { regionChoiceName = regionNameValue
      , regionChoiceOptInStatus =
          maybe "opt-in-not-required" id (optionalTextField "OptInStatus" regionObject)
      }

parseHostedZoneChoice :: Value -> IO HostedZoneChoice
parseHostedZoneChoice value = do
  zoneObject <- liftAwsEither (requireObject "list-hosted-zones" value)
  zoneIdValue <- liftAwsEither (requireTextField "list-hosted-zones" "Id" zoneObject)
  zoneNameValue <- liftAwsEither (requireTextField "list-hosted-zones" "Name" zoneObject)
  pure
    HostedZoneChoice
      { hostedZoneChoiceId = Text.replace "/hostedzone/" "" zoneIdValue
      , hostedZoneChoiceName = Text.dropWhileEnd (== '.') zoneNameValue
      }

cleanupAwsEksIamOrphans :: FilePath -> Credentials -> IO EksIamOrphanCleanupResult
cleanupAwsEksIamOrphans repoRoot adminCredentials = do
  perRunResidue <- queryPerRunResidueStatuses repoRoot
  let eksStatus = perRunAwsEksTest perRunResidue
  if not (ResidueStatus.isResidueAbsent eksStatus)
    then
      pure
        EksIamOrphanCleanupResult
          { eksIamOrphanCleanupSkippedReason =
              Just
                ( Text.pack
                    ( "aws-eks-test Pulumi state is "
                        ++ ResidueStatus.renderResidueStatus eksStatus
                    )
                )
          , eksIamOrphanCleanupDeletedPolicies = []
          , eksIamOrphanCleanupDeletedRoles = []
          }
    else do
      accountIdValue <- awsCallerAccountId repoRoot adminCredentials
      let policyArnValue = awsEksFixedIamPolicyArn accountIdValue
      policyDeleted <-
        deleteManagedPolicyIfPresent
          repoRoot
          adminCredentials
          policyArnValue
          awsEksFixedIamRoleNames
      deletedRoles <-
        fmap concat $
          forM awsEksFixedIamRoleNames $
            \roleName -> do
              deleted <- deleteRoleIfPresent repoRoot adminCredentials roleName
              pure [roleName | deleted]
      pure
        EksIamOrphanCleanupResult
          { eksIamOrphanCleanupSkippedReason = Nothing
          , eksIamOrphanCleanupDeletedPolicies =
              [awsEksFixedIamPolicyName | policyDeleted]
          , eksIamOrphanCleanupDeletedRoles = deletedRoles
          }

awsCallerAccountId :: FilePath -> Credentials -> IO Text
awsCallerAccountId repoRoot adminCredentials = do
  payload <-
    decodeJsonCommand
      repoRoot
      adminCredentials
      ["sts", "get-caller-identity"]
      "aws sts get-caller-identity"
  payloadObject <- liftAwsEither (requireObject "aws sts get-caller-identity" payload)
  liftAwsEither (requireTextField "aws sts get-caller-identity" "Account" payloadObject)

awsEksFixedIamPolicyArn :: Text -> Text
awsEksFixedIamPolicyArn accountIdValue =
  "arn:aws:iam::" <> accountIdValue <> ":policy/" <> awsEksFixedIamPolicyName

deleteManagedPolicyIfPresent :: FilePath -> Credentials -> Text -> [Text] -> IO Bool
deleteManagedPolicyIfPresent repoRoot adminCredentials policyArnValue allowedRoleNames = do
  entities <- listPolicyEntitiesIfPresent repoRoot adminCredentials policyArnValue
  case entities of
    Nothing -> pure False
    Just (attachedRoles, attachedUsers, attachedGroups) -> do
      let unexpectedRoles = filter (`notElem` allowedRoleNames) attachedRoles
          unexpected =
            map (("role/" <>) . Text.unpack) unexpectedRoles
              ++ map (("user/" <>) . Text.unpack) attachedUsers
              ++ map (("group/" <>) . Text.unpack) attachedGroups
      unless (null unexpected) $
        throwAws
          ( "Refusing to delete fixed-name aws-eks IAM policy "
              ++ Text.unpack policyArnValue
              ++ " because it is attached outside the harness-owned role set: "
              ++ intercalate ", " unexpected
          )
      mapM_
        (\roleName -> detachRolePolicyIfPresent repoRoot adminCredentials roleName policyArnValue)
        attachedRoles
      deletePolicyIfPresent repoRoot adminCredentials policyArnValue

listPolicyEntitiesIfPresent
  :: FilePath -> Credentials -> Text -> IO (Maybe ([Text], [Text], [Text]))
listPolicyEntitiesIfPresent repoRoot adminCredentials policyArnValue = do
  output <-
    runAwsCliCompleted
      repoRoot
      adminCredentials
      [ "iam"
      , "list-entities-for-policy"
      , "--policy-arn"
      , Text.unpack policyArnValue
      ]
  case processExitCode output of
    ExitFailure _ ->
      case awsErrorCode (errorDetail output) of
        Just "NoSuchEntity" -> pure Nothing
        _ -> throwAws ("aws iam list-entities-for-policy failed: " ++ errorDetail output)
    ExitSuccess -> do
      payload <- liftAwsEither (decodeJsonPayload "list-entities-for-policy" (processStdout output))
      payloadObject <- liftAwsEither (requireObject "list-entities-for-policy" payload)
      roles <-
        liftAwsEither (requireEntityNames "list-entities-for-policy" "PolicyRoles" "RoleName" payloadObject)
      users <-
        liftAwsEither (requireEntityNames "list-entities-for-policy" "PolicyUsers" "UserName" payloadObject)
      groups <-
        liftAwsEither
          (requireEntityNames "list-entities-for-policy" "PolicyGroups" "GroupName" payloadObject)
      pure (Just (roles, users, groups))

requireEntityNames :: String -> String -> String -> Object -> Either String [Text]
requireEntityNames context fieldName entityNameField objectValue = do
  entities <- requireArrayField context fieldName objectValue
  forM (Vector.toList entities) $ \entityValue -> do
    entityObject <- requireObject (context ++ "." ++ fieldName) entityValue
    requireTextField (context ++ "." ++ fieldName) entityNameField entityObject

detachRolePolicyIfPresent :: FilePath -> Credentials -> Text -> Text -> IO ()
detachRolePolicyIfPresent repoRoot adminCredentials roleName policyArnValue = do
  output <-
    runAwsCliCompleted
      repoRoot
      adminCredentials
      [ "iam"
      , "detach-role-policy"
      , "--role-name"
      , Text.unpack roleName
      , "--policy-arn"
      , Text.unpack policyArnValue
      ]
  when
    ( processExitCode output /= ExitSuccess
        && awsErrorCode (errorDetail output) /= Just "NoSuchEntity"
    )
    $ throwAws ("aws iam detach-role-policy failed: " ++ errorDetail output)

deletePolicyIfPresent :: FilePath -> Credentials -> Text -> IO Bool
deletePolicyIfPresent repoRoot adminCredentials policyArnValue = do
  output <-
    runAwsCliCompleted
      repoRoot
      adminCredentials
      [ "iam"
      , "delete-policy"
      , "--policy-arn"
      , Text.unpack policyArnValue
      ]
  case processExitCode output of
    ExitSuccess -> pure True
    ExitFailure _ ->
      case awsErrorCode (errorDetail output) of
        Just "NoSuchEntity" -> pure False
        _ -> throwAws ("aws iam delete-policy failed: " ++ errorDetail output)

deleteRoleIfPresent :: FilePath -> Credentials -> Text -> IO Bool
deleteRoleIfPresent repoRoot adminCredentials roleName = do
  present <- roleExists repoRoot adminCredentials roleName
  if not present
    then pure False
    else do
      attachedPolicyArns <- listAttachedRolePolicies repoRoot adminCredentials roleName
      mapM_
        (\policyArnValue -> detachRolePolicyIfPresent repoRoot adminCredentials roleName policyArnValue)
        attachedPolicyArns
      inlinePolicyNames <- listRoleInlinePolicies repoRoot adminCredentials roleName
      mapM_
        (\policyName -> deleteRolePolicyIfPresent repoRoot adminCredentials roleName policyName)
        inlinePolicyNames
      deleteRoleOutput <-
        runAwsCliCompleted
          repoRoot
          adminCredentials
          [ "iam"
          , "delete-role"
          , "--role-name"
          , Text.unpack roleName
          ]
      case processExitCode deleteRoleOutput of
        ExitSuccess -> pure True
        ExitFailure _ ->
          case awsErrorCode (errorDetail deleteRoleOutput) of
            Just "NoSuchEntity" -> pure False
            _ -> throwAws ("aws iam delete-role failed: " ++ errorDetail deleteRoleOutput)

roleExists :: FilePath -> Credentials -> Text -> IO Bool
roleExists repoRoot adminCredentials roleName = do
  output <-
    runAwsCliCompleted
      repoRoot
      adminCredentials
      [ "iam"
      , "get-role"
      , "--role-name"
      , Text.unpack roleName
      ]
  case processExitCode output of
    ExitSuccess -> pure True
    ExitFailure _ ->
      case awsErrorCode (errorDetail output) of
        Just "NoSuchEntity" -> pure False
        _ -> throwAws ("aws iam get-role failed: " ++ errorDetail output)

listAttachedRolePolicies :: FilePath -> Credentials -> Text -> IO [Text]
listAttachedRolePolicies repoRoot adminCredentials roleName = do
  output <-
    runAwsCliCompleted
      repoRoot
      adminCredentials
      [ "iam"
      , "list-attached-role-policies"
      , "--role-name"
      , Text.unpack roleName
      ]
  payloadText <- liftAwsEither (requireCommandSuccess "aws iam list-attached-role-policies" output)
  payload <- liftAwsEither (decodeJsonPayload "list-attached-role-policies" payloadText)
  payloadObject <- liftAwsEither (requireObject "list-attached-role-policies" payload)
  attachedPolicies <-
    liftAwsEither (requireArrayField "list-attached-role-policies" "AttachedPolicies" payloadObject)
  forM (Vector.toList attachedPolicies) $ \policyValue -> do
    policyObject <- liftAwsEither (requireObject "AttachedPolicies" policyValue)
    liftAwsEither (requireTextField "AttachedPolicies" "PolicyArn" policyObject)

listRoleInlinePolicies :: FilePath -> Credentials -> Text -> IO [Text]
listRoleInlinePolicies repoRoot adminCredentials roleName = do
  output <-
    runAwsCliCompleted
      repoRoot
      adminCredentials
      [ "iam"
      , "list-role-policies"
      , "--role-name"
      , Text.unpack roleName
      ]
  payloadText <- liftAwsEither (requireCommandSuccess "aws iam list-role-policies" output)
  payload <- liftAwsEither (decodeJsonPayload "list-role-policies" payloadText)
  payloadObject <- liftAwsEither (requireObject "list-role-policies" payload)
  liftAwsEither (requireTextArrayField "list-role-policies" "PolicyNames" payloadObject)

requireTextArrayField :: String -> String -> Object -> Either String [Text]
requireTextArrayField context fieldName objectValue = do
  values <- requireArrayField context fieldName objectValue
  mapM (requireTextArrayItem context fieldName) (Vector.toList values)

requireTextArrayItem :: String -> String -> Value -> Either String Text
requireTextArrayItem context fieldName value =
  case value of
    String textValue -> Right textValue
    _ -> Left (context ++ "." ++ fieldName ++ " contains a non-string value")

deleteRolePolicyIfPresent :: FilePath -> Credentials -> Text -> Text -> IO ()
deleteRolePolicyIfPresent repoRoot adminCredentials roleName policyName = do
  output <-
    runAwsCliCompleted
      repoRoot
      adminCredentials
      [ "iam"
      , "delete-role-policy"
      , "--role-name"
      , Text.unpack roleName
      , "--policy-name"
      , Text.unpack policyName
      ]
  when
    ( processExitCode output /= ExitSuccess
        && awsErrorCode (errorDetail output) /= Just "NoSuchEntity"
    )
    $ throwAws ("aws iam delete-role-policy failed: " ++ errorDetail output)

listOperationalAccessKeys :: FilePath -> Credentials -> IO [Text]
listOperationalAccessKeys repoRoot adminCredentials =
  listUserAccessKeys repoRoot adminCredentials prodboxIamUserName

listUserAccessKeys :: FilePath -> Credentials -> Text -> IO [Text]
listUserAccessKeys repoRoot adminCredentials userName = do
  listKeysOutput <-
    runAwsCliCompleted
      repoRoot
      adminCredentials
      [ "iam"
      , "list-access-keys"
      , "--user-name"
      , Text.unpack userName
      ]
  listPayloadText <- liftAwsEither (requireCommandSuccess "aws iam list-access-keys" listKeysOutput)
  listPayloadValue <- liftAwsEither (decodeJsonPayload "list-access-keys" listPayloadText)
  listPayloadObject <- liftAwsEither (requireObject "list-access-keys" listPayloadValue)
  accessKeysArray <-
    liftAwsEither (requireArrayField "list-access-keys" "AccessKeyMetadata" listPayloadObject)
  forM (Vector.toList accessKeysArray) $ \item -> do
    metadataObject <- liftAwsEither (requireObject "AccessKeyMetadata" item)
    liftAwsEither (requireTextField "AccessKeyMetadata" "AccessKeyId" metadataObject)

deleteExistingOperationalKeys :: FilePath -> Credentials -> IO [Text]
deleteExistingOperationalKeys repoRoot adminCredentials =
  deleteExistingUserKeys repoRoot adminCredentials prodboxIamUserName

deleteExistingUserKeys :: FilePath -> Credentials -> Text -> IO [Text]
deleteExistingUserKeys repoRoot adminCredentials userName = do
  listKeysOutput <-
    runAwsCliCompleted
      repoRoot
      adminCredentials
      [ "iam"
      , "list-access-keys"
      , "--user-name"
      , Text.unpack userName
      ]
  if processExitCode listKeysOutput == ExitSuccess
    then do
      listPayloadValue <-
        liftAwsEither (decodeJsonPayload "list-access-keys" (processStdout listKeysOutput))
      listPayloadObject <- liftAwsEither (requireObject "list-access-keys" listPayloadValue)
      accessKeysArray <-
        liftAwsEither (requireArrayField "list-access-keys" "AccessKeyMetadata" listPayloadObject)
      forM (Vector.toList accessKeysArray) $ \item -> do
        metadataObject <- liftAwsEither (requireObject "AccessKeyMetadata" item)
        accessKeyIdValue <-
          liftAwsEither (requireTextField "AccessKeyMetadata" "AccessKeyId" metadataObject)
        deleteUserAccessKey repoRoot adminCredentials userName accessKeyIdValue
        pure accessKeyIdValue
    else case awsErrorCode (errorDetail listKeysOutput) of
      Just "NoSuchEntity" -> pure []
      _ -> throwAws ("aws iam list-access-keys failed: " ++ errorDetail listKeysOutput)

deleteOperationalAccessKey :: FilePath -> Credentials -> Text -> IO ()
deleteOperationalAccessKey repoRoot adminCredentials accessKeyIdValue =
  deleteUserAccessKey repoRoot adminCredentials prodboxIamUserName accessKeyIdValue

deleteUserAccessKey :: FilePath -> Credentials -> Text -> Text -> IO ()
deleteUserAccessKey repoRoot adminCredentials userName accessKeyIdValue = do
  deleteKeyOutput <-
    runAwsCliCompleted
      repoRoot
      adminCredentials
      [ "iam"
      , "delete-access-key"
      , "--user-name"
      , Text.unpack userName
      , "--access-key-id"
      , Text.unpack accessKeyIdValue
      ]
  _ <-
    liftAwsEither
      (requireCommandSuccess ("aws iam delete-access-key " ++ Text.unpack accessKeyIdValue) deleteKeyOutput)
  pure ()

deleteUserPolicyIfPresent :: FilePath -> Credentials -> IO ()
deleteUserPolicyIfPresent repoRoot adminCredentials =
  deleteNamedUserPolicyIfPresent repoRoot adminCredentials prodboxIamUserName

deleteNamedUserPolicyIfPresent :: FilePath -> Credentials -> Text -> IO ()
deleteNamedUserPolicyIfPresent repoRoot adminCredentials userName = do
  deletePolicyOutput <-
    runAwsCliCompleted
      repoRoot
      adminCredentials
      [ "iam"
      , "delete-user-policy"
      , "--user-name"
      , Text.unpack userName
      , "--policy-name"
      , Text.unpack prodboxIamInlinePolicyName
      ]
  when
    ( processExitCode deletePolicyOutput /= ExitSuccess
        && awsErrorCode (errorDetail deletePolicyOutput) /= Just "NoSuchEntity"
    )
    $ throwAws ("aws iam delete-user-policy failed: " ++ errorDetail deletePolicyOutput)

deleteOperationalUserIfPresent :: FilePath -> Credentials -> IO Bool
deleteOperationalUserIfPresent repoRoot adminCredentials =
  deleteUserIfPresent repoRoot adminCredentials prodboxIamUserName

-- | Sprint 4.11: predicate-library probe. Returns 'Right True' when
-- the dedicated operational IAM user @prodbox@ exists; 'Right False'
-- when it does not; 'Left' on any other AWS error. Idempotent.
operationalIamUserExists :: FilePath -> Credentials -> IO (Either String Bool)
operationalIamUserExists repoRoot adminCredentials = do
  -- Sprint 7.20 (P4): same as 'listOperationalAccessKeyIds' — retry transient
  -- API errors so a throttle does not surface as a spurious teardown-guard
  -- failure; `NoSuchEntity` (gone) and other permanent errors are unchanged.
  result <-
    runAwsCliCompletedRetryingTransient
      repoRoot
      adminCredentials
      [ "iam"
      , "get-user"
      , "--user-name"
      , Text.unpack prodboxIamUserName
      ]
  pure $ case processExitCode result of
    ExitSuccess -> Right True
    ExitFailure _ ->
      case awsErrorCode (errorDetail result) of
        Just "NoSuchEntity" -> Right False
        _ -> Left ("aws iam get-user failed: " ++ errorDetail result)

-- | Sprint 4.11: predicate-library probe for the bootstrap DNS
-- record that @prodbox cluster reconcile@ writes to the operator's
-- Route 53 hosted zone. Returns 'Right True' when the record set
-- exists, 'Right False' when no matching record set is present, and
-- 'Left' on any other AWS error.
--
-- The bootstrap record name is the configured public FQDN
-- (e.g. @test.resolvefintech.com@) on the configured parent hosted
-- zone. The function reads the parent zone id from the supplied
-- repo-root config.
operationalBootstrapDnsRecordExists
  :: FilePath -> Credentials -> IO (Either String Bool)
operationalBootstrapDnsRecordExists repoRoot adminCredentials = do
  configResult <- loadConfigFile repoRoot
  case configResult of
    Left err -> pure (Left err)
    Right config -> do
      let zoneIdValue = Text.strip (zone_id (route53 config))
          fqdnValue = Text.unpack supportedPublicHostname
      if Text.null zoneIdValue
        then pure (Right False)
        else do
          result <-
            runAwsCliCompleted
              repoRoot
              adminCredentials
              [ "route53"
              , "list-resource-record-sets"
              , "--hosted-zone-id"
              , Text.unpack zoneIdValue
              , "--query"
              , "ResourceRecordSets[?Name == '" ++ fqdnValue ++ ".' && Type == 'A']"
              , "--output"
              , "json"
              ]
          pure $ case processExitCode result of
            ExitFailure _ ->
              Left ("aws route53 list-resource-record-sets failed: " ++ errorDetail result)
            ExitSuccess ->
              let payload = trimWhitespace (processStdout result)
               in Right (not (null payload) && payload /= "[]" && payload /= "null")
 where
  trimWhitespace =
    dropWhile (`elem` (" \t\r\n" :: String))
      . reverse
      . dropWhile (`elem` (" \t\r\n" :: String))
      . reverse

deleteUserIfPresent :: FilePath -> Credentials -> Text -> IO Bool
deleteUserIfPresent repoRoot adminCredentials userName = do
  deleteUserOutput <-
    runAwsCliCompleted
      repoRoot
      adminCredentials
      [ "iam"
      , "delete-user"
      , "--user-name"
      , Text.unpack userName
      ]
  case processExitCode deleteUserOutput of
    ExitSuccess -> pure True
    ExitFailure _ ->
      case awsErrorCode (errorDetail deleteUserOutput) of
        Just "NoSuchEntity" -> pure False
        _ -> throwAws ("aws iam delete-user failed: " ++ errorDetail deleteUserOutput)

cleanupIamUserResidue :: FilePath -> Credentials -> Text -> IO IamUserCleanupResult
cleanupIamUserResidue repoRoot adminCredentials userName = do
  deletedAccessKeys <- deleteExistingUserKeys repoRoot adminCredentials userName
  deleteNamedUserPolicyIfPresent repoRoot adminCredentials userName
  userDeleted <- deleteUserIfPresent repoRoot adminCredentials userName
  pure
    IamUserCleanupResult
      { iamUserCleanupUserName = userName
      , iamUserCleanupDeletedAccessKeys = deletedAccessKeys
      , iamUserCleanupUserDeleted = userDeleted
      }

probeConfiguredOperationalIdentity :: FilePath -> IO OperationalIdentityProbe
probeConfiguredOperationalIdentity repoRoot = do
  config <- loadConfigForWrite repoRoot
  credentialsResult <- resolveAwsCredentialsRefFromHostVault repoRoot "aws" (aws config)
  case credentialsResult of
    Left err
      | operationalCredentialsAbsentError err -> pure OperationalCredentialsMissing
      | otherwise -> pure (OperationalIdentityProbeFailed err)
    Right credentials -> probeOperationalIdentity repoRoot credentials

probeOperationalIdentity :: FilePath -> Credentials -> IO OperationalIdentityProbe
probeOperationalIdentity repoRoot credentials =
  if not (operationalCredentialsConfigured credentials)
    then pure OperationalCredentialsMissing
    else do
      environment <- operationalAwsEnvironment credentials
      stsOutput <-
        runAwsCliCompletedWithEnvironment
          repoRoot
          environment
          ["sts", "get-caller-identity"]
      case processExitCode stsOutput of
        ExitFailure _ ->
          pure (OperationalIdentityProbeFailed (errorDetail stsOutput))
        ExitSuccess -> do
          payload <- liftAwsEither (decodeJsonPayload "aws sts get-caller-identity" (processStdout stsOutput))
          payloadObject <- liftAwsEither (requireObject "aws sts get-caller-identity" payload)
          arn <- liftAwsEither (requireTextField "aws sts get-caller-identity" "Arn" payloadObject)
          pure $
            case operationalIdentityFromArn arn of
              Just identity -> identity
              Nothing -> OperationalIdentityNonUserArn arn

operationalCredentialsConfigured :: Credentials -> Bool
operationalCredentialsConfigured credentials =
  not (Text.null (Text.strip (access_key_id credentials)))
    && not (Text.null (Text.strip (secret_access_key credentials)))
    && not (Text.null (Text.strip (region credentials)))

operationalCredentialsCleared :: FilePath -> IO Bool
operationalCredentialsCleared repoRoot = do
  config <- loadConfigForWrite repoRoot
  credentialsResult <- resolveAwsCredentialsRefFromHostVault repoRoot "aws" (aws config)
  pure $
    case credentialsResult of
      Left err -> operationalCredentialsAbsentError err
      Right credentials -> not (operationalCredentialsConfigured credentials)

-- | Sprint 7.24: the preflight-resilient counterpart of
-- 'operationalCredentialsCleared'. The harness setup runs its
-- clear-before-mint cleanup at *preflight*, which on a clean machine is
-- BEFORE the cluster (hence host Vault) is up — so resolving the operational
-- @aws.*@ @SecretRef.Vault@ can fail with a Vault-connection error (not the
-- "missing/empty" that means "configured-but-cleared"). That ONE case is
-- deferred to the Vault-independent operational-IAM-user observation (admin
-- credential): if the user is confirmed ABSENT, the operational credentials
-- reference a user that no longer exists and are moot, so they are treated as
-- cleared. Every Vault-reachable case is identical to
-- 'operationalCredentialsCleared'; the postflight teardown guards keep the
-- strict check, since they run after the cluster lifecycle (Vault up).
operationalCredentialsClearedAtPreflight :: FilePath -> Credentials -> IO Bool
operationalCredentialsClearedAtPreflight repoRoot adminCreds = do
  config <- loadConfigForWrite repoRoot
  credentialsResult <- resolveAwsCredentialsRefFromHostVault repoRoot "aws" (aws config)
  iamUserExists <- operationalIamUserExists repoRoot adminCreds
  pure (operationalCredentialsClearedDecision credentialsResult iamUserExists)

-- | Sprint 7.24: the pure decision core of
-- 'operationalCredentialsClearedAtPreflight'. Given the Vault-resolved
-- operational @aws.*@ result and the operational-IAM-user existence probe,
-- decide whether the operational credentials are cleared. @Right@ → cleared iff
-- not configured. @Left "missing/empty"@ → cleared. @Left@ (any other error,
-- e.g. host Vault unreachable) → cleared ONLY when the IAM user is confirmed
-- absent (@Right False@); otherwise NOT cleared, preserving fail-closed.
-- Unit-testable, no IO.
operationalCredentialsClearedDecision :: Either String Credentials -> Either String Bool -> Bool
operationalCredentialsClearedDecision credentialsResult iamUserExistsResult =
  case credentialsResult of
    Right credentials -> not (operationalCredentialsConfigured credentials)
    Left err
      | operationalCredentialsAbsentError err -> True
      | otherwise -> iamUserExistsResult == Right False

operationalCredentialsConfiguredFromVault :: FilePath -> ConfigFile -> IO (Either String Bool)
operationalCredentialsConfiguredFromVault repoRoot config = do
  credentialsResult <- resolveAwsCredentialsRefFromHostVault repoRoot "aws" (aws config)
  pure $ operationalCredentialsConfiguredResult credentialsResult

operationalCredentialsConfiguredResult :: Either String Credentials -> Either String Bool
operationalCredentialsConfiguredResult credentialsResult =
  case credentialsResult of
    Left err
      | operationalCredentialsAbsentError err -> Right False
      | otherwise -> Left err
    Right credentials -> Right (operationalCredentialsConfigured credentials)

operationalAwsConfigResidueFromCredentialsResult
  :: Either String Credentials -> ResidueStatus.ResidueStatus
operationalAwsConfigResidueFromCredentialsResult credentialsResult =
  case credentialsResult of
    Left err
      | operationalCredentialsAbsentError err -> ResidueStatus.ResidueAbsent
      | otherwise -> ResidueStatus.ResidueUnreachable (ResidueStatus.ResidueQueryFailed err)
    Right credentials -> operationalAwsConfigResidueFromKey (access_key_id credentials)

-- | Sprint 7.24: refine the @operational-aws-config@ residue against the
-- @operational-iam-user@ residue before the teardown fail-closed gate.
--
-- The aws-config block is the Vault-stored credential FOR the operational IAM
-- user. The fail-closed gate (lifecycle_reconciliation_doctrine.md §3.1) exists
-- so a resource that "cannot be observed" is never presumed gone — its purpose
-- here is to avoid stranding the operational IAM USER. That user is observed
-- authoritatively through the admin credential, which does not depend on Vault.
--
-- So: when the IAM user is CONFIRMED ABSENT and the aws-config could only be
-- read as 'ResidueUnreachable' (host Vault down at preflight), downgrade the
-- aws-config to 'ResidueAbsent' — there is no user to strand, hence no
-- stranding risk. In EVERY other case (user Present, user itself Unreachable,
-- or aws-config Present/Absent) the raw aws-config status is preserved, so the
-- gate still fails closed exactly as before. Pure; unit-testable.
refineAwsConfigResidueAgainstIamUser
  :: ResidueStatus.ResidueStatus
  -- ^ the operational IAM user residue (admin-credential observation)
  -> ResidueStatus.ResidueStatus
  -- ^ the raw operational aws-config residue (Vault-resolved reference)
  -> ResidueStatus.ResidueStatus
refineAwsConfigResidueAgainstIamUser iamUserStatus rawAwsConfigStatus =
  case (iamUserStatus, rawAwsConfigStatus) of
    (ResidueStatus.ResidueAbsent, ResidueStatus.ResidueUnreachable _) ->
      ResidueStatus.ResidueAbsent
    _ -> rawAwsConfigStatus

operationalCredentialsAbsentError :: String -> Bool
operationalCredentialsAbsentError err =
  any (`Text.isInfixOf` rendered) ["missing", "empty"]
 where
  rendered = Text.toLower (Text.pack err)

writeOperationalAwsVaultCredentials :: FilePath -> Credentials -> IO ()
writeOperationalAwsVaultCredentials repoRoot credentials = do
  result <-
    writeOperatorSecretViaDaemonOrHost
      repoRoot
      "gateway/gateway/aws"
      (operationalAwsVaultFields credentials)
  case result of
    Left err -> throwAws err
    Right () -> pure ()

-- | Sprint 1.44: persist an operator-minted secret, preferring the in-cluster
-- gateway daemon over a host root-token direct Vault write.
--
-- The canonical path is @POST /v1/secret/<logical>@ on the daemon's
-- loopback-restricted NodePort, authenticated by an operator-injected
-- Kubernetes JWT that the daemon exchanges for a Vault token under the narrow
-- @prodbox-operator-write@ role (operator decision 2026-06-19). The host falls
-- back to its own root-token Vault write only when no operator service-account
-- token can be minted yet, or when the unit/integration host-vault seam is
-- active. Once the operator JWT exists, a daemon rejection or transport failure
-- is authoritative and does not bypass to a host root-token write. Scope is
-- exactly the two host-minted operator secrets: the ACME EAB
-- (@secret/acme/eab@) and the minted operational @aws.*@
-- (@secret/gateway/gateway/aws@).
writeOperatorSecretViaDaemonOrHost
  :: FilePath -> Text -> Map.Map Text Text -> IO (Either String ())
writeOperatorSecretViaDaemonOrHost repoRoot logical fields = do
  daemonAttempt <- attemptOperatorDaemonWrite repoRoot logical fields
  case daemonAttempt of
    Just result -> pure result
    Nothing -> writeHostVaultKvObject repoRoot "secret" logical fields

-- | Try the daemon-mediated operator write. Returns @Nothing@ to signal "fall
-- back to the host write" only when the explicit host-Vault test seam is active
-- or no operator JWT can be minted yet; @Just@ when the daemon definitively
-- accepted or rejected the write.
attemptOperatorDaemonWrite
  :: FilePath -> Text -> Map.Map Text Text -> IO (Maybe (Either String ()))
attemptOperatorDaemonWrite repoRoot logical fields = do
  testSeamDir <- lookupEnv "PRODBOX_TEST_HOST_VAULT_KV_DIR"
  testSeam <- lookupEnv "PRODBOX_TEST_HOST_VAULT_KV"
  if any seamActive [testSeamDir, testSeam]
    then pure Nothing
    else do
      jwtResult <- mintOperatorWriteJwt repoRoot
      case jwtResult of
        Nothing -> pure Nothing
        Just jwt -> do
          let endpoint = GatewayClient.hostLoopbackGatewayEndpoint defaultGatewayNodePort
          writeResult <-
            GatewayClient.writeOperatorSecret endpoint jwt (Text.unpack logical) fields
          case writeResult of
            Right () -> do
              writeDiagnosticLine
                ( "operator secret secret/"
                    ++ Text.unpack logical
                    ++ " written via the gateway daemon (prodbox-operator-write role)."
                )
              pure (Just (Right ()))
            Left err ->
              pure
                ( Just
                    ( Left
                        ( "gateway-daemon operator write for secret/"
                            ++ Text.unpack logical
                            ++ " failed: "
                            ++ GatewayClient.renderGatewayError err
                        )
                    )
                )
 where
  seamActive = maybe False (not . null)

-- | Mint a short-lived Kubernetes service-account token for the
-- @prodbox-operator-write@ SA in the @gateway@ namespace (the operator-injected
-- JWT the daemon exchanges for a Vault write token). Returns @Nothing@ when
-- @kubectl@ or the SA is unavailable, so the caller falls back to the host
-- write.
mintOperatorWriteJwt :: FilePath -> IO (Maybe Text)
mintOperatorWriteJwt repoRoot = do
  outputResult <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "create"
            , "token"
            , "prodbox-operator-write"
            , "--namespace"
            , "gateway"
            , "--duration"
            , "5m"
            ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $ case outputResult of
    Success output
      | processExitCode output == ExitSuccess ->
          let token = Text.strip (Text.pack (processStdout output))
           in if Text.null token then Nothing else Just token
    _ -> Nothing

operationalAwsVaultFields :: Credentials -> Map.Map Text Text
operationalAwsVaultFields credentials =
  Map.fromList
    [ ("access_key_id", access_key_id credentials)
    , ("secret_access_key", secret_access_key credentials)
    , ("session_token", maybe "" id (session_token credentials))
    , ("region", region credentials)
    ]

-- | Sprint 7.15: write the ZeroSSL external-account-binding material to Vault
-- at @secret/acme/eab@ so the config can reference it through
-- @SecretRef.Vault@ rather than persisting plaintext. When both fields are
-- absent (a non-ZeroSSL server with no EAB), nothing is written.
writeAcmeEabVaultCredentials :: FilePath -> Maybe Text -> Maybe Text -> IO ()
writeAcmeEabVaultCredentials repoRoot maybeKeyId maybeHmacKey =
  case (maybeKeyId, maybeHmacKey) of
    (Nothing, Nothing) -> pure ()
    _ -> do
      result <-
        writeOperatorSecretViaDaemonOrHost
          repoRoot
          "acme/eab"
          ( Map.fromList
              [ ("key_id", maybe "" id maybeKeyId)
              , ("hmac_key", maybe "" id maybeHmacKey)
              ]
          )
      case result of
        Left err -> throwAws err
        Right () -> pure ()

operationalIdentityFromArn :: Text -> Maybe OperationalIdentityProbe
operationalIdentityFromArn arn = do
  resource <- case reverse (Text.splitOn ":" arn) of
    resourceValue : _ -> Just resourceValue
    [] -> Nothing
  case Text.stripPrefix "user/" resource of
    Just userResource ->
      OperationalIdentityIamUser <$> finalPathSegment userResource
    Nothing ->
      case Text.stripPrefix "federated-user/" resource of
        Just federatedResource ->
          OperationalIdentityFederatedUser <$> finalPathSegment federatedResource
        Nothing -> Nothing

finalPathSegment :: Text -> Maybe Text
finalPathSegment value =
  case reverse (filter (/= "") (Text.splitOn "/" value)) of
    segment : _ -> Just segment
    [] -> Nothing

quotaSpecsForTier :: PolicyTier -> [QuotaSpec]
quotaSpecsForTier policyTier =
  case policyTier of
    PolicyCore -> baselineQuotaSpecs
    PolicyFull -> fullQuotaSpecs

renderAwsSetupResult :: IamSetupResult -> String
renderAwsSetupResult result =
  unlines
    [ "IAM_USER=" ++ Text.unpack (iamSetupUserName result)
    , "POLICY_TIER=" ++ renderPolicyTier (iamSetupPolicyTier result)
    , "CREDENTIAL_SOURCE=" ++ Text.unpack (iamSetupCredentialSource result)
    , "AWS_ACCESS_KEY_ID=" ++ Text.unpack (iamSetupAccessKeyId result)
    , "CONFIG_PATH=" ++ iamSetupDhallPath result
    , "QUOTA_REQUESTS_SUBMITTED=" ++ show (length (filter quotaRequested (iamSetupQuotaStatuses result)))
    ]

renderAwsTeardownResult :: IamTeardownResult -> String
renderAwsTeardownResult result =
  unlines
    [ "IAM_USER=" ++ Text.unpack (iamTeardownUserName result)
    , "USER_DELETED=" ++ map toLower (show (iamTeardownUserDeleted result))
    , "DELETED_ACCESS_KEYS=" ++ show (length (iamTeardownDeletedAccessKeys result))
    , "CONFIG_PATH=" ++ iamTeardownDhallPath result
    ]

renderAwsIamHarnessSetupReport
  :: OperationalIdentityProbe
  -> EksIamOrphanCleanupResult
  -> IamTeardownResult
  -> Maybe IamUserCleanupResult
  -> Bool
  -> IamSetupResult
  -> String
renderAwsIamHarnessSetupReport identityProbe eksIamOrphanCleanup preflightTeardown preflightAssociatedCleanup preflightConfigCleared setupResult =
  concat
    [ renderOperationalIdentityProbe identityProbe
    , renderEksIamOrphanCleanup eksIamOrphanCleanup
    , renderAwsTeardownResult preflightTeardown
    , renderAssociatedCleanup preflightAssociatedCleanup
    , "PREFLIGHT_OPERATIONAL_CONFIG_CLEARED="
        ++ map toLower (show preflightConfigCleared)
        ++ "\n"
    , renderAwsSetupResult setupResult
    ]
 where
  renderAssociatedCleanup :: Maybe IamUserCleanupResult -> String
  renderAssociatedCleanup Nothing = "PREEXISTING_ASSOCIATED_USER_DELETED=false\n"
  renderAssociatedCleanup (Just cleanupResult) =
    unlines
      [ "PREEXISTING_ASSOCIATED_USER=" ++ Text.unpack (iamUserCleanupUserName cleanupResult)
      , "PREEXISTING_ASSOCIATED_USER_DELETED="
          ++ map toLower (show (iamUserCleanupUserDeleted cleanupResult))
      , "PREEXISTING_ASSOCIATED_USER_DELETED_ACCESS_KEYS="
          ++ show (length (iamUserCleanupDeletedAccessKeys cleanupResult))
      ]

  renderEksIamOrphanCleanup :: EksIamOrphanCleanupResult -> String
  renderEksIamOrphanCleanup cleanup =
    case eksIamOrphanCleanupSkippedReason cleanup of
      Just reasonValue ->
        unlines
          [ "PREFLIGHT_EKS_IAM_ORPHAN_CLEANUP=skipped"
          , "PREFLIGHT_EKS_IAM_ORPHAN_CLEANUP_SKIP_REASON=" ++ Text.unpack reasonValue
          , "PREFLIGHT_EKS_IAM_ORPHAN_POLICIES_DELETED=0"
          , "PREFLIGHT_EKS_IAM_ORPHAN_ROLES_DELETED=0"
          ]
      Nothing ->
        unlines
          [ "PREFLIGHT_EKS_IAM_ORPHAN_CLEANUP=ran"
          , "PREFLIGHT_EKS_IAM_ORPHAN_POLICIES_DELETED="
              ++ show (length (eksIamOrphanCleanupDeletedPolicies cleanup))
          , "PREFLIGHT_EKS_IAM_ORPHAN_ROLES_DELETED="
              ++ show (length (eksIamOrphanCleanupDeletedRoles cleanup))
          ]

renderOperationalIdentityProbe :: OperationalIdentityProbe -> String
renderOperationalIdentityProbe probe =
  case probe of
    OperationalCredentialsMissing ->
      "PREEXISTING_OPERATIONAL_USER=\nPREEXISTING_OPERATIONAL_PROBE=missing\n"
    OperationalIdentityProbeFailed err ->
      unlines
        [ "PREEXISTING_OPERATIONAL_USER="
        , "PREEXISTING_OPERATIONAL_PROBE=error"
        , "PREEXISTING_OPERATIONAL_PROBE_DETAIL=" ++ err
        ]
    OperationalIdentityNonUserArn arn ->
      unlines
        [ "PREEXISTING_OPERATIONAL_USER="
        , "PREEXISTING_OPERATIONAL_PROBE=non-user"
        , "PREEXISTING_OPERATIONAL_ARN=" ++ Text.unpack arn
        ]
    OperationalIdentityIamUser userName ->
      unlines
        [ "PREEXISTING_OPERATIONAL_USER=" ++ Text.unpack userName
        , "PREEXISTING_OPERATIONAL_PROBE=iam-user"
        ]
    OperationalIdentityFederatedUser userName ->
      unlines
        [ "PREEXISTING_OPERATIONAL_USER=" ++ Text.unpack userName
        , "PREEXISTING_OPERATIONAL_PROBE=federated-user"
        ]

renderConfigSetupResult :: ConfigSetupResult -> String
renderConfigSetupResult result =
  unlines
    [ "AWS_REGION=" ++ Text.unpack (configSetupRegion result)
    , "ROUTE53_ZONE_ID=" ++ Text.unpack (configSetupRoute53ZoneId result)
    , "DEMO_FQDN=" ++ Text.unpack (configSetupDemoFqdn result)
    , "POLICY_TIER=" ++ renderPolicyTier (configSetupPolicyTier result)
    , "AWS_ACCESS_KEY_ID=" ++ Text.unpack (configSetupAccessKeyId result)
    , "CONFIG_PATH=" ++ configSetupDhallPath result
    , "QUOTA_REQUESTS_SUBMITTED="
        ++ show (length (filter quotaRequested (configSetupQuotaStatuses result)))
    , "POST_SETUP_GUIDANCE=Delete the temporary admin access key you used for setup; prodbox now owns a dedicated IAM user for normal operations."
    ]

validateHostedZoneAlignment :: Text -> Text -> Either String ()
validateHostedZoneAlignment fqdn zoneName
  | normalizedZone == "" = Left "selected Route 53 hosted zone name must not be empty"
  | lowerFqdn == lowerZone = Right ()
  | ("." <> lowerZone) `Text.isSuffixOf` lowerFqdn = Right ()
  | otherwise =
      Left
        ( Text.unpack fqdn
            ++ " does not belong to the selected Route 53 hosted zone "
            ++ Text.unpack zoneName
        )
 where
  lowerFqdn = Text.toLower (Text.strip fqdn)
  lowerZone = Text.toLower (Text.strip zoneName)
  normalizedZone = Text.unpack lowerZone

renderQuotaTable :: String -> [QuotaStatus] -> String
renderQuotaTable title statuses =
  unlines
    ([title, renderRow widths headerRow, renderSeparator widths] ++ map (renderRow widths) bodyRows)
 where
  headerRow = ["Quota", "Current", "Target", "Meets Target", "Request Status", "Note"]
  bodyRows = map quotaStatusRow statuses
  widths = map maximum (transpose (map (map length) (headerRow : bodyRows)))
  renderRow columnWidths columns = intercalate " | " (zipWith padRight columnWidths columns)
  renderSeparator columnWidths = intercalate "-+-" (map (`replicate` '-') columnWidths)
  padRight width value = value ++ replicate (width - length value) ' '

quotaStatusRow :: QuotaStatus -> [String]
quotaStatusRow status =
  [ Text.unpack (quotaStatusDisplayName status)
  , formatDouble (quotaStatusCurrentValue status)
  , formatDouble (quotaStatusTargetValue status)
  , if quotaStatusMeetsTarget status then "yes" else "no"
  , maybe "" Text.unpack (quotaStatusRequestStatus status)
  , maybe "" Text.unpack (quotaStatusNote status)
  ]

quotaRequested :: QuotaStatus -> Bool
quotaRequested status =
  case quotaStatusRequestStatus status of
    Nothing -> False
    Just value -> Text.strip value /= ""

renderPolicyTier :: PolicyTier -> String
renderPolicyTier policyTier =
  case policyTier of
    PolicyCore -> "core"
    PolicyFull -> "full"

currentRegionDefault :: FilePath -> IO Text
currentRegionDefault repoRoot = do
  config <- loadConfigForWrite repoRoot
  let configuredRegion = Text.strip (awsCredentialRegion (aws config))
  pure (if Text.null configuredRegion then defaultAwsRegion else configuredRegion)

loadConfigForWrite :: FilePath -> IO ConfigFile
loadConfigForWrite repoRoot = do
  tier0Path <- resolveTier0ConfigPath repoRoot
  tier0Exists <- doesFileExist tier0Path
  if tier0Exists
    then do
      configResult <- loadConfigFile repoRoot
      case configResult of
        Left err -> throwAws err
        Right config -> pure config
    else pure defaultConfigFile

-- | Sprint 1.42 Part B: author the operator's non-secret config into the Tier-0
-- @prodbox.dhall@'s @parameters@ block (preserving the established
-- @context@/@witness@), replacing the retired @prodbox-config.dhall@ writer.
writeProjectConfigParameters :: FilePath -> ConfigFile -> IO ()
writeProjectConfigParameters repoRoot config = do
  result <- Tier0.writeOperatorParametersToTier0 repoRoot config
  either throwAws pure result

-- | Admin/operational AWS CLI subprocess environment. Delegates to the
-- single canonical PATH/HOME/LANG-preserving builder
-- 'awsCliSubprocessEnvironment' (Sprint 1.30 consolidation): there is
-- exactly one AWS-CLI environment builder and everything else calls it.
adminAwsEnvironment :: Credentials -> IO [(String, String)]
adminAwsEnvironment = awsCliSubprocessEnvironment

-- LEGACY-ESCAPE[shared-operational-aws-credential]: the single shared
-- operational aws.* identity minted by the suite-level IAM harness is projected
-- into every AWS subprocess environment through this seam. Registered in
-- Prodbox.Legacy.EscapeRegistry; replaced by per-role IAM/Vault generations
-- (Sprints 3.26/4.49/8.11).
operationalAwsEnvironment :: Credentials -> IO [(String, String)]
operationalAwsEnvironment = adminAwsEnvironment

runAwsCliCompleted :: FilePath -> Credentials -> [String] -> IO ProcessOutput
runAwsCliCompleted repoRoot adminCredentials arguments = do
  environment <- adminAwsEnvironment adminCredentials
  runAwsCliCompletedWithEnvironment repoRoot environment arguments

runAwsCliCompletedWithEnvironment :: FilePath -> [(String, String)] -> [String] -> IO ProcessOutput
runAwsCliCompletedWithEnvironment repoRoot environment arguments = do
  outputResult <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments = arguments ++ ["--output", "json"]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just repoRoot
        }
  case outputResult of
    Failure err -> throwAws err
    Success output -> pure output

decodeJsonCommand :: FilePath -> Credentials -> [String] -> String -> IO Value
decodeJsonCommand repoRoot adminCredentials arguments commandLabel = do
  output <- runAwsCliCompleted repoRoot adminCredentials arguments
  payloadText <- liftAwsEither (requireCommandSuccess commandLabel output)
  liftAwsEither (decodeJsonPayload commandLabel payloadText)

liftAwsEither :: Either String a -> IO a
liftAwsEither = either throwAws pure

requireCommandSuccess :: String -> ProcessOutput -> Either String String
requireCommandSuccess commandLabel output =
  case processExitCode output of
    ExitSuccess -> Right (processStdout output)
    ExitFailure _ -> Left (commandLabel ++ " failed: " ++ errorDetail output)

decodeJsonPayload :: String -> String -> Either String Value
decodeJsonPayload context payloadText =
  case eitherDecode (BL8.pack payloadText) of
    Left err -> Left (context ++ " returned invalid JSON: " ++ err)
    Right value -> Right value

requireObject :: String -> Value -> Either String Object
requireObject context value =
  case value of
    Object objectValue -> Right objectValue
    _ -> Left (context ++ " must be a JSON object")

requireArrayField :: String -> String -> Object -> Either String Array
requireArrayField context fieldName objectValue =
  case KeyMap.lookup (Key.fromString fieldName) objectValue of
    Just (Array arrayValue) -> Right arrayValue
    _ -> Left (context ++ " missing required array field " ++ fieldName)

requireObjectField :: String -> String -> Object -> Either String Object
requireObjectField context fieldName objectValue =
  case KeyMap.lookup (Key.fromString fieldName) objectValue of
    Just (Object nestedObject) -> Right nestedObject
    _ -> Left (context ++ " missing required object field " ++ fieldName)

requireTextField :: String -> String -> Object -> Either String Text
requireTextField context fieldName objectValue =
  case KeyMap.lookup (Key.fromString fieldName) objectValue of
    Just (String textValue) | Text.strip textValue /= "" -> Right textValue
    _ -> Left (context ++ " missing required string field " ++ fieldName)

optionalTextField :: String -> Object -> Maybe Text
optionalTextField fieldName objectValue =
  case KeyMap.lookup (Key.fromString fieldName) objectValue of
    Just (String textValue) | Text.strip textValue /= "" -> Just textValue
    _ -> Nothing

requireNumberField :: String -> String -> Object -> Either String Double
requireNumberField context fieldName objectValue =
  case KeyMap.lookup (Key.fromString fieldName) objectValue of
    Just (Number numericValue) -> Right (realToFrac numericValue)
    _ -> Left (context ++ " missing required numeric field " ++ fieldName)

normalizeOptionalText :: Text -> Maybe Text
normalizeOptionalText value =
  let trimmed = Text.strip value
   in if Text.null trimmed then Nothing else Just trimmed

normalizeFqdn :: Text -> Text
normalizeFqdn = Text.dropWhileEnd (== '.') . Text.strip

isValidRoute53ZoneId :: Text -> Bool
isValidRoute53ZoneId value =
  case Text.uncons value of
    Just ('Z', rest) -> not (Text.null rest) && Text.all isUpperAlphaNum rest
    _ -> False
 where
  isUpperAlphaNum character = isAlphaNum character && (not (character >= 'a' && character <= 'z'))

isValidFqdn :: Text -> Bool
isValidFqdn value =
  let labels = Text.splitOn "." value
   in Text.length value >= 1
        && Text.length value <= 253
        && length labels >= 2
        && all validLabel labels
        && validTopLevel (last labels)
 where
  validLabel label =
    let size = Text.length label
     in size >= 1
          && size <= 63
          && Text.head label /= '-'
          && Text.last label /= '-'
          && Text.all validFqdnChar label
  validTopLevel label =
    let size = Text.length label
     in size >= 2 && size <= 63 && Text.all isAsciiLetter label
  validFqdnChar character = isAsciiLetter character || isDigit character || character == '-'
  isAsciiLetter character = isAsciiLower character || isAsciiUpper character
  isDigit character = character >= '0' && character <= '9'

hasValidEmailShape :: Text -> Bool
hasValidEmailShape value =
  let (localPart, remainder) = Text.breakOn "@" value
   in case Text.uncons remainder of
        Just ('@', domainPart) -> not (Text.null localPart) && Text.any (== '.') domainPart
        _ -> False

trim :: String -> String
trim = dropWhileEnd isSpace . dropWhile isSpace
 where
  dropWhileEnd predicate = reverse . dropWhile predicate . reverse

formatDouble :: Double -> String
formatDouble value =
  if fromInteger (round value) == value
    then show (round value :: Integer)
    else show value

errorDetail :: ProcessOutput -> String
errorDetail output =
  let stderrText = trim (processStderr output)
      stdoutText = trim (processStdout output)
   in if stderrText /= "" then stderrText else if stdoutText /= "" then stdoutText else "command failed"

awsErrorCode :: String -> Maybe String
awsErrorCode message = do
  suffix <- stripPrefix "An error occurred (" =<< findSubstring "An error occurred (" message
  let code = takeWhile (/= ')') suffix
  if code == "" then Nothing else Just code
 where
  findSubstring needle haystack =
    case breakOn needle haystack of
      Just (_, rest) -> Just rest
      Nothing -> Nothing
  stripPrefix prefix textValue =
    if prefix `isPrefixOf` textValue
      then Just (drop (length prefix) textValue)
      else Nothing
  breakOn needle haystack =
    search "" haystack
   where
    search _ [] = Nothing
    search prefixRemaining remaining@(character : rest)
      | needle `isPrefixOf` remaining = Just (reverse prefixRemaining, remaining)
      | otherwise = search (character : prefixRemaining) rest

-- | Sprint 7.20 (P4): pure classifier — is an AWS error code a TRANSIENT
-- API failure worth retrying with backoff (throttling / service-unavailable),
-- as opposed to a permanent failure (e.g. @NoSuchEntity@, @AccessDenied@) that
-- must be rethrown immediately? Conservative on purpose: only the well-known
-- AWS transient codes match, so a genuine permanent error (including the
-- @NoSuchEntity@ that means "gone") is never spuriously retried.
--
-- This handles GENUINE transient API errors only. Per the adversarial review,
-- the IAM eventual-consistency concern was REFUTED — there is deliberately NO
-- post-delete consistency wait here.
awsErrorCodeIsTransient :: Maybe String -> Bool
awsErrorCodeIsTransient = maybe False (`elem` transientCodes)
 where
  transientCodes =
    [ "Throttling"
    , "ThrottlingException"
    , "ThrottledException"
    , "RequestLimitExceeded"
    , "TooManyRequestsException"
    , "RequestThrottled"
    , "ServiceUnavailable"
    , "ServiceUnavailableException"
    , "ServiceFailure"
    , "InternalError"
    , "InternalFailure"
    , "RequestTimeout"
    ]

-- | Sprint 7.20 (P4): run an AWS CLI command, retrying with exponential backoff
-- on a TRANSIENT-coded failure. A success or a PERMANENT-coded failure returns
-- immediately (so the caller's existing @NoSuchEntity@ / @Left@ handling is
-- unchanged); only a transient throttle / service-unavailable triggers a retry,
-- and the LAST output is returned once the attempt budget is exhausted (so a
-- persistently throttling endpoint still surfaces its real error to the caller
-- rather than being silently swallowed).
runAwsCliCompletedRetryingTransient :: FilePath -> Credentials -> [String] -> IO ProcessOutput
runAwsCliCompletedRetryingTransient repoRoot adminCredentials arguments =
  go iamProbeMaxAttempts 0
 where
  go attemptsRemaining attemptIndex = do
    output <- runAwsCliCompleted repoRoot adminCredentials arguments
    case processExitCode output of
      ExitSuccess -> pure output
      ExitFailure _
        | attemptsRemaining > 1
        , awsErrorCodeIsTransient (awsErrorCode (errorDetail output)) -> do
            threadDelay (iamProbeBackoffMicros attemptIndex)
            go (attemptsRemaining - 1) (attemptIndex + 1)
        | otherwise -> pure output

-- | Attempt budget for the transient-retry IAM probes. Five attempts (one
-- initial + four retries) absorbs a brief throttle window without masking a
-- persistent failure.
iamProbeMaxAttempts :: Int
iamProbeMaxAttempts = 5

-- | Exponential backoff schedule for the transient-retry IAM probes: 500ms,
-- 1s, 2s, 4s, capped at 8s.
iamProbeBackoffMicros :: Int -> Int
iamProbeBackoffMicros attemptIndex =
  min (8 * second) (500 * milli * (2 ^ max 0 attemptIndex))
 where
  second = 1000000
  milli = 1000
