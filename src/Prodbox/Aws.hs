{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Prodbox.Aws
  ( AwsSetupInput (..)
  , AwsTeardownInput (..)
  , ConfigSetupInput (..)
  , PulumiResiduePolicy (..)
  , SessionTokenPromptShape (..)
  , adminAwsEnvironment
  , applyAwsTeardown
  , buildIamPolicyDocument
  , buildIamPolicyJson
  , categorizePulumiResidue
  , checkPulumiResidueBeforeTeardown
  , harnessPostflightResiduePolicy
  , longLivedStackNames
  , operationalAwsConfigResidueFromKey
  , operationalBootstrapDnsRecordExists
  , operationalIamUserExists
  , operationalIamUserResidueFromExists
  , operationalManagedResources
  , partitionResidueByLifecycle
  , perRunStackNames
  , promptAdminCredentialsWithRegionChoice
  , prodboxIamUserName
  , pulumiDestroyPlanForResidue
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
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Numeric.Natural (Natural)
import Prodbox.AwsEnvironment
  ( overlayAwsCredentials
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
import Prodbox.Error (fatalError)
import Prodbox.Lifecycle.LiveResidue
  ( PerRunResidueStatuses (..)
  , queryAwsSesResidueStatus
  , queryPerRunResidueStatuses
  )
import Prodbox.Lifecycle.ResidueStatus qualified as ResidueStatus
import Prodbox.Lifecycle.ResourceClass qualified as ResourceClass
import Prodbox.Lifecycle.ResourceRegistry
  ( ManagedResource (..)
  , reconcileAbsent
  )
import Prodbox.Repo
  ( ConfigPaths (..)
  , canonicalConfigPaths
  )
import Prodbox.Result (Result (..))
import Prodbox.Settings
  ( AcmeSection (..)
  , ConfigFile (..)
  , Credentials (..)
  , DeploymentSection (..)
  , DomainSection (..)
  , MetallbBgpPeer (..)
  , Route53Section (..)
  , StorageSection (..)
  , defaultConfigFile
  , loadConfigFile
  , renderConfigDhall
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
import System.Directory
  ( doesFileExist
  , findExecutable
  )
import System.Environment (getEnvironment)
import System.Exit
  ( ExitCode (ExitFailure, ExitSuccess)
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

-- | Sprint 7.7 — pure helper for auto-detecting whether the operator's
-- pasted AWS access-key ID needs a session-token follow-up prompt.
--
-- * @AKIA…@ — long-lived IAM user key created via IAM console. No
--   session token; skip the prompt.
-- * @ASIA…@ — STS-derived temporary credentials (IAM Identity Center,
--   @aws sts get-session-token@, @aws sts assume-role@, EC2 instance
--   metadata). Session token is required; prompt as a hidden field.
-- * any other prefix (rare: @AGPA@, @AROA@, etc., or empty input) —
--   fall back to an optional prompt with an explanatory hint so the
--   operator is never silently forced into the wrong shape.
data SessionTokenPromptShape
  = SkipPrompt
  | PromptRequiredHidden
  | PromptOptionalWithHint
  deriving (Eq, Show)

-- | Sprint 7.7 — auto-detect the prompt shape from the access-key prefix.
-- Extracted as a pure helper so unit tests can cover the AKIA / ASIA /
-- unknown branches without exercising IO.
sessionTokenPromptShape :: Text -> SessionTokenPromptShape
sessionTokenPromptShape accessKeyId
  | "AKIA" `Text.isPrefixOf` accessKeyId = SkipPrompt
  | "ASIA" `Text.isPrefixOf` accessKeyId = PromptRequiredHidden
  | otherwise = PromptOptionalWithHint

-- | Per-run Pulumi stack names per
-- @DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes@. These
-- stacks are auto-managed by the test runner's
-- 'awsPostflightDestroyActions' and may safely be bypassed by the
-- harness-internal 'BypassPerRunResidueOnly' policy.
-- Sprint 4.20: derived from the managed-resource registry facts in
-- 'Prodbox.Lifecycle.ResourceClass' so this list cannot drift from the
-- single source of truth (the per-run Pulumi stacks are exactly the
-- 'PerRun'-class entries).
perRunStackNames :: [String]
perRunStackNames = ResourceClass.resourceNamesOfClass ResourceClass.PerRun

-- | Long-lived cross-substrate shared Pulumi stack names per
-- @DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes@. These
-- are retained by design; the harness must NEVER bypass residue refusal
-- for them. Sprint 4.20: derived from the registry facts.
longLivedStackNames :: [String]
longLivedStackNames = ResourceClass.resourceNamesOfClass ResourceClass.LongLived

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
-- It is 'BypassAllResidueForHarnessRefresh' (not the Sprint 7.7
-- 'BypassPerRunResidueOnly'): post-Sprint-4.10 the long-lived @aws-ses@
-- stack is admin-credentialed (@aws_admin_for_test_simulation.*@ + the
-- long-lived S3 state backend), so clearing operational @aws.*@ cannot
-- strand it from its destroy surface. The postflight therefore bypasses
-- both per-run AND long-lived residue and clears @aws.*@ unconditionally,
-- matching the preflight ('runAwsIamHarnessSetup', Sprint 7.5.c.v.c).
-- This supersedes the Sprint 7.7 postflight refusal and the Sprint
-- 7.5.c.v.c decision to keep the postflight on 'BypassPerRunResidueOnly'.
harnessPostflightResiduePolicy :: PulumiResiduePolicy
harnessPostflightResiduePolicy = BypassAllResidueForHarnessRefresh

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
  , configSetupEnvoyGatewayControllerReplicasInput :: Maybe Natural
  , configSetupEnvoyGatewayDataPlaneReplicasInput :: Maybe Natural
  , configSetupApiReplicasInput :: Maybe Natural
  , configSetupWebsocketReplicasInput :: Maybe Natural
  , configSetupManualPvHostRootInput :: Text
  , configSetupPolicyTierInput :: PolicyTier
  }
  deriving (Eq, Show)

defaultAwsRegion :: Text
defaultAwsRegion = "us-east-1"

zeroSslAcmeServer :: Text
zeroSslAcmeServer = "https://acme.zerossl.com/v2/DV90"

letsEncryptAcmeServer :: Text
letsEncryptAcmeServer = "https://acme-v02.api.letsencrypt.org/directory"

prodboxIamUserName :: Text
prodboxIamUserName = "prodbox"

prodboxIamInlinePolicyName :: Text
prodboxIamInlinePolicyName = "prodbox-inline"

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
      PolicyFull -> ["sts:GetCallerIdentity", "route53:*", "ec2:*", "eks:*", "iam:*"]

runAwsCommand :: FilePath -> AwsCommand -> IO ExitCode
runAwsCommand repoRoot command = do
  result <- try (executeAwsCommand repoRoot command) :: IO (Either SomeException ExitCode)
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

executeAwsCommand :: FilePath -> AwsCommand -> IO ExitCode
executeAwsCommand repoRoot command =
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
      decision <- interactiveAwsTeardownInput repoRoot flags
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
    , "CONFIG_PATH=" ++ configDhallPath (canonicalConfigPaths repoRoot)
    , "POLICY_TIER=" ++ renderPolicyTier (awsSetupPolicyTierInput input)
    , "ACCESS_KEY_ID=" ++ Text.unpack (access_key_id (awsSetupAdminCredentials input))
    ]

renderAwsTeardownPlan :: FilePath -> AwsTeardownInput -> String
renderAwsTeardownPlan repoRoot input =
  unlines
    [ "AWS_TEARDOWN_PLAN"
    , "CONFIG_PATH=" ++ configDhallPath (canonicalConfigPaths repoRoot)
    , "ACCESS_KEY_ID=" ++ Text.unpack (access_key_id (awsTeardownAdminCredentials input))
    ]

renderConfigSetupPlan :: FilePath -> ConfigSetupInput -> String
renderConfigSetupPlan repoRoot input =
  unlines
    [ "CONFIG_SETUP_PLAN"
    , "CONFIG_PATH=" ++ configDhallPath (canonicalConfigPaths repoRoot)
    , "ZONE_ID=" ++ Text.unpack (configSetupRoute53ZoneIdInput input)
    , "PUBLIC_HOST=" ++ Text.unpack (configSetupDemoFqdnInput input)
    , "POLICY_TIER=" ++ renderPolicyTier (configSetupPolicyTierInput input)
    ]

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
          [ "route53:ChangeTagsForResource"
          , "route53:CreateHostedZone"
          , "route53:DeleteHostedZone"
          , "route53:ListHostedZones"
          , "route53:ListTagsForResource"
          ]
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
          [ "ses:Describe*"
          , "ses:Get*"
          , "ses:List*"
          ]
          "*"
      ]

statement :: String -> [String] -> String -> Value
statement sid actions resourceArn =
  object
    [ "Sid" .= sid
    , "Effect" .= ("Allow" :: String)
    , "Action" .= actions
    , "Resource" .= resourceArn
    ]

prettyConfig :: AesonPretty.Config
prettyConfig = AesonPretty.defConfig {AesonPretty.confIndent = AesonPretty.Spaces 2}

throwAws :: String -> IO a
throwAws = throwIO . AwsError

ensureAwsCliAvailable :: IO ()
ensureAwsCliAvailable = do
  maybeAws <- findExecutable "aws"
  case maybeAws of
    Nothing -> throwAws "The AWS CLI is required for interactive setup flows"
    Just _ -> pure ()

interactiveConfigSetupInput :: FilePath -> IO ConfigSetupInput
interactiveConfigSetupInput repoRoot = do
  requireInteractiveTty configSetupGuard
  writeOutputLine "Config setup writes `prodbox-config.dhall`, creates the operational IAM user,"
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
  providerIndex <-
    promptNumberedChoice "Choose the ACME provider number" ["ZeroSSL", "Let's Encrypt"] 1
  acmeEmailRaw <- promptText "ACME notification email (certificate expiry notices)" Nothing
  (acmeServerValue, eabKeyIdRaw, eabHmacKeyRaw) <-
    case providerIndex of
      0 -> do
        keyId <- promptText "ZeroSSL EAB key ID (from ZeroSSL Developer settings)" Nothing
        hmacKey <- promptSecret "ZeroSSL EAB HMAC key (hidden input)"
        pure (zeroSslAcmeServer, keyId, hmacKey)
      _ -> pure (letsEncryptAcmeServer, "", "")
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
  :: FilePath -> AwsTeardownFlags -> IO (Either String (Maybe AwsTeardownInput))
interactiveAwsTeardownInput repoRoot flags = do
  requireInteractiveTty awsTeardownGuard
  -- Step 1: file-based residue check — no credentials needed.
  residue <- checkPulumiResidueBeforeTeardown repoRoot
  let policy = teardownResiduePolicy flags
  -- Step 2: decide based on residue + policy. Skip the credential
  -- prompt entirely on refusal and on the nothing-to-do path.
  case (residue, policy) of
    (live@(_ : _), RefuseOnAnyResidue) ->
      pure (Left (renderPulumiResidueRefusal live))
    _ -> do
      configForCheck <- loadConfigForWrite repoRoot
      let operationalConfigured = operationalCredentialsConfigured (aws configForCheck)
      case (null residue, operationalConfigured, policy) of
        (True, False, _) ->
          -- Nothing to do regardless of policy: no residue and no
          -- operational identity to clean up.
          pure (Right Nothing)
        (False, False, DestroyPulumiResidueFirst) ->
          -- The destroy subprocesses inherit operational `aws.*` from
          -- the dhall config; an empty aws.* would make every
          -- `prodbox pulumi <stack>-destroy --yes` fail fast. Refuse
          -- with an actionable message rather than prompting for the
          -- admin key (the admin key only powers the subsequent IAM
          -- delete, not the destroy step).
          pure
            ( Left
                ( "AWS teardown --destroy-pulumi-residue requires populated "
                    ++ "operational `aws.*` (the destroy subprocesses inherit "
                    ++ "them from prodbox-config.dhall). Run `prodbox aws "
                    ++ "setup` first to populate, or run each `prodbox pulumi "
                    ++ "<stack>-destroy --yes` manually with credentials you "
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

showAdminCredentialsGuidance :: IO ()
showAdminCredentialsGuidance = do
  writeOutputLine "Temporary admin AWS credential guidance:"
  writeOutputLine
    "1. Sign in with an identity that can manage IAM users, access keys, Route 53"
  writeOutputLine "   hosted zones, and Service Quotas. Two credential shapes are supported:"
  writeOutputLine
    "   a. Long-lived IAM user key (AKIA…): IAM console -> Users -> <temporary admin user>"
  writeOutputLine "      -> Security credentials -> Create access key. No session token."
  writeOutputLine
    "   b. STS-derived temporary key (ASIA…): IAM Identity Center \"Access keys\" panel,"
  writeOutputLine
    "      or `aws sts get-session-token` / `aws sts assume-role`. Includes a session"
  writeOutputLine "      token; paste it when prompted."
  writeOutputLine
    "2. Paste the access key ID and secret below. `prodbox` auto-detects the shape from"
  writeOutputLine
    "   the access-key prefix and only asks for a session token when needed (ASIA…)."
  writeOutputLine "3. `prodbox` never persists this temporary admin key. Delete it after the"
  writeOutputLine "   command completes."
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
  writeOutputLine "ACME provider guidance:"
  writeOutputLine "1. ZeroSSL: open https://app.zerossl.com -> Developer -> EAB"
  writeOutputLine "   Credentials, then copy the EAB Key ID and HMAC key."
  writeOutputLine "2. Let's Encrypt (recommended): no account or EAB credentials are required;"
  writeOutputLine "   you only need the notification email below."
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

promptAdminCredentials :: Text -> IO Credentials
promptAdminCredentials defaultRegion = do
  ensureAwsCliAvailable
  showAdminCredentialsGuidance
  accessKeyId <-
    Text.pack . trim
      <$> promptText "Temporary admin AWS access key ID (from the AWS console or IAM Identity Center)" Nothing
  secretAccessKey <-
    Text.pack . trim
      <$> promptSecret "Temporary admin AWS secret access key (hidden input)"
  -- Sprint 7.7 auto-detect: AKIA… skips the session-token prompt
  -- entirely; ASIA… makes it a required hidden field; any other
  -- prefix falls back to an optional prompt with an explanatory hint.
  sessionToken <- promptSessionTokenForKey accessKeyId
  regionRaw <-
    promptText
      "AWS region for admin operations (you can change it after regions are listed)"
      (Just (Text.unpack defaultRegion))
  validateAdminCredentialsInput
    Credentials
      { access_key_id = accessKeyId
      , secret_access_key = secretAccessKey
      , session_token = sessionToken
      , region = Text.pack (trim regionRaw)
      }

-- | Sprint 7.7 — IO wrapper around 'sessionTokenPromptShape'. The pure
-- helper lives next to its tests; this function exists so
-- 'promptAdminCredentials' has a single clean call.
promptSessionTokenForKey :: Text -> IO (Maybe Text)
promptSessionTokenForKey accessKeyId =
  case sessionTokenPromptShape accessKeyId of
    SkipPrompt -> pure Nothing
    PromptRequiredHidden -> do
      raw <-
        promptSecret
          "AWS session token (required for STS-derived keys, hidden input)"
      pure (Just (Text.pack (trim raw)))
    PromptOptionalWithHint -> do
      writeOutputLine
        ( "  Access key prefix not recognized (AKIA/ASIA); if this came from "
            ++ "STS / Identity Center, paste the matching session token, "
            ++ "otherwise press Enter."
        )
      raw <- promptText "AWS session token (leave blank for long-lived IAM user keys)" Nothing
      pure (normalizeOptionalText (Text.pack raw))

promptAdminCredentialsWithRegionChoice :: FilePath -> IO Credentials
promptAdminCredentialsWithRegionChoice repoRoot = do
  initialCredentials <- promptAdminCredentials =<< currentRegionDefault repoRoot
  selectedRegion <- promptRegionChoice repoRoot initialCredentials
  pure initialCredentials {region = selectedRegion}

runAwsIamHarnessSetup :: FilePath -> PolicyTier -> IO String
runAwsIamHarnessSetup repoRoot policyTier = do
  credentials <- loadHarnessAdminCredentials repoRoot
  existingIdentity <- probeConfiguredOperationalIdentity repoRoot
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
  preflightConfigCleared <- operationalCredentialsCleared repoRoot
  unless
    preflightConfigCleared
    ( throwAws
        "AWS IAM harness preflight cleanup did not clear operational aws.* credentials from prodbox-config.dhall."
    )
  result <-
    applyAwsSetupWithFederatedFallback
      repoRoot
      AwsSetupInput
        { awsSetupAdminCredentials = credentials
        , awsSetupPolicyTierInput = policyTier
        }
  pure
    ( renderAwsIamHarnessSetupReport
        existingIdentity
        preflightTeardown
        preflightAssociatedCleanup
        preflightConfigCleared
        result
    )

runAwsIamHarnessInspect :: FilePath -> IO String
runAwsIamHarnessInspect repoRoot = do
  config <- loadConfigForWrite repoRoot
  if not (operationalCredentialsConfigured (aws config))
    then throwAws "AWS IAM harness inspection requires populated operational aws.* credentials."
    else do
      identity <- probeOperationalIdentity repoRoot (aws config)
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
                , "CONFIG_PATH=" ++ configDhallPath (canonicalConfigPaths repoRoot)
                ]
            )
        OperationalIdentityFederatedUser userName ->
          pure
            ( unlines
                [ "IAM_USER=" ++ Text.unpack userName
                , "IAM_PRINCIPAL=federated-user"
                , "CONFIG_PATH=" ++ configDhallPath (canonicalConfigPaths repoRoot)
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
        , -- Sprint 7.9: BypassAllResidueForHarnessRefresh (was
          -- BypassPerRunResidueOnly from Sprint 7.7). Post-Sprint-4.10,
          -- the long-lived aws-ses stack is admin-managed: its resources
          -- (ensureAwsSesStackResources / destroyAwsSesStackStatus)
          -- authenticate via pulumiSesAdminBaseEnv / loadAdminAwsCredentials
          -- (aws_admin_for_test_simulation.*) against the long-lived S3
          -- state backend, never operational aws.*. So clearing operational
          -- aws.* here can no longer strand aws-ses from its destroy
          -- surface, and the old long-lived refusal (correct pre-4.10, when
          -- aws-ses was operationally credentialed) is now stale. Per-run
          -- stacks are destroyed separately by awsPostflightDestroyActions
          -- before this teardown runs. Therefore the postflight bypasses
          -- ALL residue and clears aws.* unconditionally, matching the
          -- preflight (Sprint 7.5.c.v.c). This supersedes the Sprint 7.7
          -- postflight refusal and the Sprint 7.5.c.v.c decision to keep
          -- the postflight on BypassPerRunResidueOnly. The policy is named
          -- in 'harnessPostflightResiduePolicy' as a pure SSoT so the
          -- choice is unit-testable without IO.
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
        "AWS IAM harness teardown did not clear operational aws.* credentials from prodbox-config.dhall."
    )
  pure (renderAwsTeardownResult result ++ "POST_RUN_OPERATIONAL_CONFIG_CLEARED=true\n")

loadHarnessAdminCredentials :: FilePath -> IO Credentials
loadHarnessAdminCredentials repoRoot = do
  configResult <- loadConfigFile repoRoot
  case configResult of
    Left err -> throwAws err
    Right config ->
      case validateAwsBootstrapConfig config of
        Left err -> throwAws err
        Right () -> do
          let credentials = aws_admin_for_test_simulation config
          if harnessAdminCredentialsConfigured credentials
            then validateAdminCredentialsInput credentials
            else
              throwAws
                "Native IAM validation requires aws_admin_for_test_simulation.access_key_id, aws_admin_for_test_simulation.secret_access_key, and aws_admin_for_test_simulation.region in prodbox-config.dhall."

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

validateAdminCredentials :: Credentials -> Either String Credentials
validateAdminCredentials credentials = do
  let normalized =
        Credentials
          { access_key_id = Text.strip (access_key_id credentials)
          , secret_access_key = Text.strip (secret_access_key credentials)
          , session_token = normalizeOptionalText =<< session_token credentials
          , region = Text.strip (region credentials)
          }
  if Text.null (access_key_id normalized)
    then Left "Admin AWS access key ID is required"
    else pure ()
  if Text.null (secret_access_key normalized)
    then Left "Admin AWS secret access key is required"
    else pure ()
  if Text.null (region normalized)
    then Left "Admin AWS region is required"
    else pure ()
  pure normalized

validateAdminCredentialsInput :: Credentials -> IO Credentials
validateAdminCredentialsInput credentials =
  either throwAws pure (validateAdminCredentials credentials)

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
          , envoy_gateway_controller_replicas = Just (fromIntegral envoyGatewayControllerReplicasRaw)
          , envoy_gateway_data_plane_replicas = Just (fromIntegral envoyGatewayDataPlaneReplicasRaw)
          , api_replicas = Just (fromIntegral apiReplicasRaw)
          , websocket_replicas = Just (fromIntegral websocketReplicasRaw)
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
      , configSetupEnvoyGatewayControllerReplicasInput =
          Just (fromIntegral envoyGatewayControllerReplicasRaw)
      , configSetupEnvoyGatewayDataPlaneReplicasInput = Just (fromIntegral envoyGatewayDataPlaneReplicasRaw)
      , configSetupApiReplicasInput = Just (fromIntegral apiReplicasRaw)
      , configSetupWebsocketReplicasInput = Just (fromIntegral websocketReplicasRaw)
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
  (operationalCredentials, credentialSource) <-
    operationalCredentialsAfterReadiness
      allowFederatedFallback
      repoRoot
      (awsSetupAdminCredentials input)
      (awsSetupPolicyTierInput input)
      (nonEmptyText (zone_id (route53 currentConfig)))
      newAccessKeyId
      newSecretAccessKey
  let updatedConfig =
        currentConfig
          { aws = operationalCredentials
          }
      paths = canonicalConfigPaths repoRoot
  writeConfigFile (configDhallPath paths) updatedConfig
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
          , iamSetupDhallPath = configDhallPath paths
          }

applyAwsTeardown :: FilePath -> AwsTeardownInput -> IO (Either String IamTeardownResult)
applyAwsTeardown repoRoot input = do
  residue <- checkPulumiResidueBeforeTeardown repoRoot
  -- Partition kept symmetric (_perRunResidue is computed but only
  -- inspected through the policy logic below; the partition exists so
  -- any future stack added per `substrates.md → Resource Lifecycle
  -- Classes` forces a deliberate per-run vs long-lived classification
  -- via 'perRunStackNames' / 'longLivedStackNames').
  let (_perRunResidue, longLivedResidue) = partitionResidueByLifecycle residue
  case awsTeardownResiduePolicy input of
    AcceptOrphanResidue -> runTeardown
    BypassAllResidueForHarnessRefresh -> runTeardown
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

  -- Sprint 7.8: reconcile the two 'Operational'-class managed resources
  -- (the operational @prodbox@ IAM user and the operational @aws.*@ config
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
                    , iamTeardownDhallPath = configDhallPath (canonicalConfigPaths repoRoot)
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
          { ResidueStatus.residueEvidence = "aws.access_key_id set in prodbox-config.dhall"
          , ResidueStatus.residueStackName = "operational-aws-config"
          }

-- | Sprint 7.8: the two 'Operational'-class managed resources, with
-- their idempotent destroy closures over the admin credentials. The
-- canonical 'resourceName's MUST match the
-- 'Prodbox.Lifecycle.ResourceClass' SSoT
-- (@operational-iam-user@, @operational-aws-config@). The destroy
-- actions are exactly the inline delete / clear logic that
-- @prodbox aws teardown@ ran before this sprint, so wiring them in is
-- behavior-preserving:
--
-- * @operational-iam-user@: delete every operational access key, delete
--   the inline user policy if present, then delete the user if present.
-- * @operational-aws-config@: clear the operational @aws.*@ block in
--   @prodbox-config.dhall@ (region preserved, falling back to the admin
--   region).
operationalManagedResources :: Credentials -> [ManagedResource]
operationalManagedResources adminCreds =
  [ ManagedResource
      { resourceName = "operational-iam-user"
      , resourceClass = ResourceClass.Operational
      , resourceDestroy = \repoRoot -> do
          _ <- deleteExistingOperationalKeys repoRoot adminCreds
          deleteUserPolicyIfPresent repoRoot adminCreds
          _ <- deleteOperationalUserIfPresent repoRoot adminCreds
          pure ExitSuccess
      }
  , ManagedResource
      { resourceName = "operational-aws-config"
      , resourceClass = ResourceClass.Operational
      , resourceDestroy = \repoRoot -> clearOperationalAwsConfig repoRoot adminCreds
      }
  ]

-- | Sprint 7.8: clear the operational @aws.*@ credential block in
-- @prodbox-config.dhall@ (factored out of the previous inline
-- @runTeardown@ body so it can serve as the @operational-aws-config@
-- managed resource's destroy action). Idempotent: writing empty
-- credentials over already-empty ones is a no-op write. The region is
-- preserved from the current config, falling back to the admin
-- credential's region when the config region is blank. Returns
-- 'ExitSuccess'.
clearOperationalAwsConfig :: FilePath -> Credentials -> IO ExitCode
clearOperationalAwsConfig repoRoot adminCreds = do
  currentConfig <- loadConfigForWrite repoRoot
  let currentRegion =
        if Text.null (Text.strip (region (aws currentConfig)))
          then region adminCreds
          else region (aws currentConfig)
      updatedConfig =
        currentConfig
          { aws =
              Credentials
                { access_key_id = ""
                , secret_access_key = ""
                , session_token = Nothing
                , region = currentRegion
                }
          }
      paths = canonicalConfigPaths repoRoot
  writeConfigFile (configDhallPath paths) updatedConfig
  pure ExitSuccess

-- | Sprint 7.8: discover the live 'ResidueStatus' of each of the two
-- 'operationalManagedResources', paired in registry order. The IAM-user
-- status comes from 'operationalIamUserExists' piped through
-- 'operationalIamUserResidueFromExists'; the @aws.*@-config status from
-- the configured @aws.access_key_id@ via
-- 'operationalAwsConfigResidueFromKey' (a failed config load is treated
-- as unreachable so the fail-closed gate refuses rather than presuming
-- the block is clear).
discoverOperationalResidue
  :: FilePath -> Credentials -> IO [(ManagedResource, ResidueStatus.ResidueStatus)]
discoverOperationalResidue repoRoot adminCreds = do
  iamUserExists <- operationalIamUserExists repoRoot adminCreds
  configResult <- loadConfigFile repoRoot
  let iamUserStatus = operationalIamUserResidueFromExists iamUserExists
      awsConfigStatus = case configResult of
        Left err -> ResidueStatus.ResidueUnreachable (ResidueStatus.ResidueQueryFailed err)
        Right config -> operationalAwsConfigResidueFromKey (access_key_id (aws config))
  pure (zip (operationalManagedResources adminCreds) [iamUserStatus, awsConfigStatus])

-- | Sprint 7.8: read-only listing of the operational IAM user's
-- access-key IDs, factored from 'deleteExistingOperationalKeys' so
-- 'applyAwsTeardown' can record the keys that existed BEFORE the
-- registry reconcile destroys them (preserving the
-- 'iamTeardownDeletedAccessKeys' result field). Returns @[]@ when the
-- user does not exist.
listOperationalAccessKeyIds :: FilePath -> Credentials -> IO [Text]
listOperationalAccessKeyIds repoRoot adminCredentials = do
  listKeysOutput <-
    runAwsCliCompleted
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

-- | Sprint 7.7 — destroy-first dispatch helper. Invokes
-- @prodbox pulumi \<stack>-destroy --yes@ for each stack in the plan,
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
      "aws-eks" -> ["pulumi", "eks-destroy", "--yes"]
      "aws-eks-subzone" -> ["pulumi", "aws-subzone-destroy", "--yes"]
      "aws-test" -> ["pulumi", "test-destroy", "--yes"]
      "aws-ses" -> ["pulumi", "aws-ses-destroy", "--yes"]
      other -> ["pulumi", other ++ "-destroy", "--yes"]

-- | Sprint 7.6 refuse-path generalized to typed Pulumi-stack residue
-- queries per Sprint 4.16. Returns the list of live stacks paired with
-- the canonical destroy command operators should run to clean them up.
-- An empty list means it is safe to delete the operational IAM user.
--
-- Implementation note: this is the IO wrapper around the pure
-- 'categorizePulumiResidue' helper. The IO half reaches into the
-- in-cluster MinIO backend (via one shared port-forward across the
-- three per-run stacks) and the operator-account S3 backend (admin
-- credentials) so the residue listing reflects what is actually in
-- the Pulumi backends, not stale file-existence approximations.
checkPulumiResidueBeforeTeardown :: FilePath -> IO [(String, String)]
checkPulumiResidueBeforeTeardown repoRoot = do
  perRun <- queryPerRunResidueStatuses repoRoot
  ses <- queryAwsSesResidueStatus repoRoot
  pure (categorizePulumiResidue perRun ses)

-- | Pure categorization of the four 'ResidueStatus' values into the
-- canonical @(stack-name, destroy-command)@ list the refuse-path
-- consumes. Exposed for unit testing because the IO query is hard to
-- exercise without a live cluster.
--
-- Sprint 4.19/4.20: both per-run and long-lived 'ResidueUnreachable'
-- count as blocking residue for this teardown gate. "Cannot read the
-- Pulumi state backend" is not a confirmation that the AWS resources
-- are gone, so @prodbox aws teardown@ must refuse rather than delete
-- the operational IAM user and strand unreadable stacks. The single
-- soundness combinator 'ResidueStatus.residueBlocksTeardownGate'
-- (Sprint 4.20, superseding the per-class
-- @isResiduePresentOrUnknown*@ booleans) encodes "present OR unreachable
-- → block." (The @--cascade@ path keeps its own graceful-degradation
-- handling in 'Prodbox.Lifecycle.ResourceRegistry.resourcesToDestroy'.)
categorizePulumiResidue
  :: PerRunResidueStatuses -> ResidueStatus.ResidueStatus -> [(String, String)]
categorizePulumiResidue perRun sesStatus =
  [ ("aws-eks", "prodbox pulumi eks-destroy --yes")
  | ResidueStatus.residueBlocksTeardownGate (perRunAwsEksTest perRun)
  ]
    ++ [ ("aws-eks-subzone", "prodbox pulumi aws-subzone-destroy --yes")
       | ResidueStatus.residueBlocksTeardownGate (perRunAwsEksSubzone perRun)
       ]
    ++ [ ("aws-test", "prodbox pulumi test-destroy --yes")
       | ResidueStatus.residueBlocksTeardownGate (perRunAwsTest perRun)
       ]
    ++ [ ("aws-ses", "prodbox pulumi aws-ses-destroy --yes")
       | ResidueStatus.residueBlocksTeardownGate sesStatus
       ]

renderPulumiResidueRefusal :: [(String, String)] -> String
renderPulumiResidueRefusal residue =
  unlines
    ( [ "AWS teardown refused: Pulumi-managed AWS stacks still have live resources."
      , ""
      , "Deleting the operational IAM user now would strand these stacks from"
      , "the supported destroy surface (every `prodbox pulumi <stack>-destroy`"
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
      , "surface (every `prodbox pulumi <stack>-destroy` fails fast when"
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

applyAwsRequestQuotas :: FilePath -> AwsRequestQuotasInput -> IO [QuotaStatus]
applyAwsRequestQuotas repoRoot input =
  mapM
    (\spec -> ensureServiceQuota repoRoot (awsRequestQuotasAdminCredentials input) spec True)
    (quotaSpecsForTier (awsRequestQuotasPolicyTierInput input))

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
  let updatedConfig =
        currentConfig
          { aws =
              Credentials
                { access_key_id = newAccessKeyId
                , secret_access_key = newSecretAccessKey
                , session_token = Nothing
                , region = region adminCredentials
                }
          , route53 = Route53Section {zone_id = configSetupRoute53ZoneIdInput input}
          , domain =
              DomainSection
                { demo_fqdn = configSetupDemoFqdnInput input
                , demo_ttl = configSetupDemoTtlInput input
                }
          , acme =
              AcmeSection
                { email = configSetupAcmeEmailInput input
                , server = configSetupAcmeServerInput input
                , eab_key_id = configSetupAcmeEabKeyIdInput input
                , eab_hmac_key = configSetupAcmeEabHmacKeyInput input
                }
          , deployment =
              DeploymentSection
                { dev_mode = configSetupDevModeInput input
                , bootstrap_public_ip_override = configSetupBootstrapPublicIpOverrideInput input
                , pulumi_enable_dns_bootstrap = configSetupPulumiEnableDnsBootstrapInput input
                , public_edge_advertisement_mode = configSetupPublicEdgeAdvertisementModeInput input
                , public_edge_bgp_peers = configSetupPublicEdgeBgpPeersInput input
                , envoy_gateway_controller_replicas = configSetupEnvoyGatewayControllerReplicasInput input
                , envoy_gateway_data_plane_replicas = configSetupEnvoyGatewayDataPlaneReplicasInput input
                , api_replicas = configSetupApiReplicasInput input
                , websocket_replicas = configSetupWebsocketReplicasInput input
                }
          , storage = StorageSection {manual_pv_host_root = configSetupManualPvHostRootInput input}
          }
      paths = canonicalConfigPaths repoRoot
  writeConfigFile (configDhallPath paths) updatedConfig
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
          , configSetupDhallPath = configDhallPath paths
          }

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

  accessKeys <- listOperationalAccessKeys repoRoot adminCredentials
  mapM_ (deleteOperationalAccessKey repoRoot adminCredentials) accessKeys

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
      , -- AWS inline user-policy documents are capped at 2048 bytes
        -- including whitespace. Compact-encode to stay well under the
        -- limit; the pretty form is reserved for operator-facing
        -- `prodbox aws policy` rendering.
        BL8.unpack (encode (buildIamPolicyDocument policyTier))
      ]
  _ <- liftAwsEither (requireCommandSuccess "aws iam put-user-policy" putUserPolicyOutput)

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
  result <-
    runAwsCliCompleted
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
-- record that @prodbox rke2 reconcile@ writes to the operator's
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
  probeOperationalIdentity repoRoot (aws config)

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
  let credentials = aws config
  pure
    ( Text.null (Text.strip (access_key_id credentials))
        && Text.null (Text.strip (secret_access_key credentials))
        && session_token credentials == Nothing
    )

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
  -> IamTeardownResult
  -> Maybe IamUserCleanupResult
  -> Bool
  -> IamSetupResult
  -> String
renderAwsIamHarnessSetupReport identityProbe preflightTeardown preflightAssociatedCleanup preflightConfigCleared setupResult =
  concat
    [ renderOperationalIdentityProbe identityProbe
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
  let configuredRegion = Text.strip (region (aws config))
  pure (if Text.null configuredRegion then defaultAwsRegion else configuredRegion)

loadConfigForWrite :: FilePath -> IO ConfigFile
loadConfigForWrite repoRoot = do
  let paths = canonicalConfigPaths repoRoot
  dhallExists <- doesFileExist (configDhallPath paths)
  if dhallExists
    then do
      configResult <- loadConfigFile repoRoot
      case configResult of
        Left err -> throwAws err
        Right config -> pure config
    else pure defaultConfigFile

writeConfigFile :: FilePath -> ConfigFile -> IO ()
writeConfigFile path config = writeFile path (renderConfigDhall config)

subprocessBaseEnvironment :: IO [(String, String)]
subprocessBaseEnvironment = do
  environment <- getEnvironment
  let keep key = maybe [] (\value -> [(key, value)]) (lookup key environment)
  pure (concatMap keep ["PATH", "HOME", "LANG", "TERM", "USER"])

adminAwsEnvironment :: Credentials -> IO [(String, String)]
adminAwsEnvironment credentials = do
  base <- subprocessBaseEnvironment
  pure (overlayAwsCredentials base credentials)

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
