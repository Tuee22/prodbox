{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Aws
  ( AwsSetupInput (..)
  , AwsTeardownInput (..)
  , ConfigSetupInput (..)
  , buildIamPolicyDocument
  , buildIamPolicyJson
  , renderAwsSetupPlan
  , renderAwsTeardownPlan
  , renderConfigSetupPlan
  , runAwsCommand
  , runAwsIamHarnessInspect
  , runAwsIamHarnessSetup
  , runAwsIamHarnessTeardown
  , runInteractiveConfigSetup
  , runInteractiveConfigSetupWithPlan
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception
  ( Exception
  , IOException
  , SomeException
  , bracket_
  , displayException
  , throwIO
  , try
  )
import Control.Monad (forM, unless, when)
import Data.Aeson
  ( Array
  , Object
  , Value (..)
  , eitherDecode
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
  , transpose
  )
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Numeric.Natural (Natural)
import Prodbox.AwsEnvironment
  ( overlayAwsCredentials
  )
import Prodbox.CLI.Command
  ( AwsCommand (..)
  , Plan (..)
  , PlanOptions (..)
  , PolicyTier (..)
  , buildPlan
  , runPlanWithOptions
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
  ( CommandSpec (..)
  , ProcessOutput (..)
  , captureCommand
  )
import System.Directory
  ( doesFileExist
  , findExecutable
  )
import System.Environment (getEnvironment)
import System.Exit
  ( ExitCode (ExitFailure, ExitSuccess)
  )
import System.FilePath
  ( takeDirectory
  , takeFileName
  )
import System.IO
  ( hFlush
  , hGetEcho
  , hIsTerminalDevice
  , hPutStrLn
  , hSetEcho
  , stderr
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
  }
  deriving (Eq, Show)

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

runAwsCommand :: FilePath -> AwsCommand -> IO ExitCode
runAwsCommand repoRoot command = do
  result <- try (executeAwsCommand repoRoot command) :: IO (Either SomeException ExitCode)
  case result of
    Left err -> do
      hPutStrLn stderr (displayException err)
      pure (ExitFailure 1)
    Right exitCode -> pure exitCode

runInteractiveConfigSetup :: FilePath -> IO ExitCode
runInteractiveConfigSetup repoRoot = do
  runInteractiveConfigSetupWithPlan repoRoot (PlanOptions False Nothing)

runInteractiveConfigSetupWithPlan :: FilePath -> PlanOptions -> IO ExitCode
runInteractiveConfigSetupWithPlan repoRoot planOptions = do
  result <- try (executeConfigSetup repoRoot planOptions) :: IO (Either SomeException ExitCode)
  case result of
    Left err -> do
      hPutStrLn stderr (displayException err)
      pure (ExitFailure 1)
    Right exitCode -> pure exitCode

executeAwsCommand :: FilePath -> AwsCommand -> IO ExitCode
executeAwsCommand repoRoot command =
  case command of
    AwsPolicy policyTier -> do
      putStr (buildIamPolicyJson policyTier)
      pure ExitSuccess
    AwsSetup policyTier planOptions -> do
      input <- interactiveAwsSetupInput repoRoot policyTier
      runPlanWithOptions
        planOptions
        (buildAwsSetupExecutionPlan repoRoot input)
        $ \plannedInput -> do
          result <- applyAwsSetup repoRoot plannedInput
          putStr (renderAwsSetupResult result)
          pure ExitSuccess
    AwsTeardown planOptions -> do
      input <- interactiveAwsTeardownInput repoRoot
      runPlanWithOptions
        planOptions
        (buildAwsTeardownExecutionPlan repoRoot input)
        $ \plannedInput -> do
          result <- applyAwsTeardown repoRoot plannedInput
          putStr (renderAwsTeardownResult result)
          pure ExitSuccess
    AwsCheckQuotas -> do
      input <- interactiveAwsCheckQuotasInput repoRoot
      statuses <- applyAwsCheckQuotas repoRoot input
      putStr (renderQuotaTable "Supported AWS Quotas" statuses)
      pure ExitSuccess
    AwsRequestQuotas policyTier -> do
      input <- interactiveAwsRequestQuotasInput repoRoot policyTier
      statuses <- applyAwsRequestQuotas repoRoot input
      putStr (renderQuotaTable "Requested AWS Quotas" statuses)
      pure ExitSuccess

executeConfigSetup :: FilePath -> PlanOptions -> IO ExitCode
executeConfigSetup repoRoot planOptions = do
  input <- interactiveConfigSetupInput repoRoot
  runPlanWithOptions
    planOptions
    (buildConfigSetupExecutionPlan repoRoot input)
    $ \plannedInput -> do
      result <- applyConfigSetup repoRoot plannedInput
      putStr (renderConfigSetupResult result)
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
          [ "route53:CreateHostedZone"
          , "route53:DeleteHostedZone"
          , "route53:ListHostedZones"
          ]
          "*"
      , statement
          "Ec2HaTestStackLifecycle"
          [ "ec2:AssociateRouteTable"
          , "ec2:AttachInternetGateway"
          , "ec2:AuthorizeSecurityGroupEgress"
          , "ec2:AuthorizeSecurityGroupIngress"
          , "ec2:CreateInternetGateway"
          , "ec2:CreateRoute"
          , "ec2:CreateRouteTable"
          , "ec2:CreateSecurityGroup"
          , "ec2:CreateSubnet"
          , "ec2:CreateTags"
          , "ec2:CreateVpc"
          , "ec2:DeleteInternetGateway"
          , "ec2:DeleteRoute"
          , "ec2:DeleteRouteTable"
          , "ec2:DeleteSecurityGroup"
          , "ec2:DeleteSubnet"
          , "ec2:DeleteTags"
          , "ec2:DeleteVpc"
          , "ec2:Describe*"
          , "ec2:DetachInternetGateway"
          , "ec2:DisassociateRouteTable"
          , "ec2:ModifySubnetAttribute"
          , "ec2:ModifyVpcAttribute"
          , "ec2:RunInstances"
          , "ec2:RevokeSecurityGroupEgress"
          , "ec2:RevokeSecurityGroupIngress"
          , "ec2:TerminateInstances"
          ]
          "*"
      , statement
          "IamEksRoleLifecycle"
          [ "iam:AttachRolePolicy"
          , "iam:CreateRole"
          , "iam:CreateServiceLinkedRole"
          , "iam:DeleteRole"
          , "iam:DetachRolePolicy"
          , "iam:GetRole"
          , "iam:GetRolePolicy"
          , "iam:ListAttachedRolePolicies"
          , "iam:ListInstanceProfilesForRole"
          , "iam:ListRolePolicies"
          , "iam:ListRoleTags"
          , "iam:PassRole"
          , "iam:TagRole"
          , "iam:UntagRole"
          ]
          "*"
      , statement
          "EksTestStackLifecycle"
          [ "eks:CreateCluster"
          , "eks:CreateNodegroup"
          , "eks:DeleteCluster"
          , "eks:DeleteNodegroup"
          , "eks:Describe*"
          , "eks:List*"
          , "eks:TagResource"
          , "eks:UntagResource"
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
  putStrLn "Config setup writes `prodbox-config.dhall`, creates the operational IAM user,"
  putStrLn "and validates the result. The elevated credential entered below is not persisted."
  putStrLn ""
  accountReady <- promptConfirm "Do you already have an AWS account?" True
  unless accountReady showAwsAccountGuidance
  credentials <- promptAdminCredentialsWithRegionChoice repoRoot
  zone <- promptHostedZoneChoice repoRoot credentials
  let zoneName = hostedZoneChoiceName zone
  putStrLn ("The supported public hostname is fixed: " ++ Text.unpack supportedPublicHostname)
  demoTtl <- promptInt "Demo DNS TTL seconds" 60
  showAcmeProviderGuidance
  providerIndex <-
    promptNumberedChoice "Choose the ACME provider number" ["ZeroSSL", "Let's Encrypt"] 0
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
  putStrLn "AWS setup creates or refreshes the dedicated `prodbox` IAM user, writes"
  putStrLn "operational `aws.*` credentials, and can request baseline service quotas."
  putStrLn ""
  credentials <- promptAdminCredentialsWithRegionChoice repoRoot
  AwsSetupInput <$> validateAdminCredentialsInput credentials <*> pure policyTier

interactiveAwsTeardownInput :: FilePath -> IO AwsTeardownInput
interactiveAwsTeardownInput repoRoot = do
  putStrLn "AWS teardown deletes the dedicated `prodbox` IAM user and clears operational"
  putStrLn "`aws.*` credentials from Dhall. The elevated credential entered below is not kept."
  putStrLn ""
  credentials <- promptAdminCredentials =<< currentRegionDefault repoRoot
  pure (AwsTeardownInput credentials)

interactiveAwsCheckQuotasInput :: FilePath -> IO AwsCheckQuotasInput
interactiveAwsCheckQuotasInput repoRoot = do
  putStrLn "AWS quota inspection reads the supported Service Quotas targets without changing"
  putStrLn "the Dhall config or creating IAM users."
  putStrLn ""
  credentials <- promptAdminCredentialsWithRegionChoice repoRoot
  AwsCheckQuotasInput <$> validateAdminCredentialsInput credentials

interactiveAwsRequestQuotasInput :: FilePath -> PolicyTier -> IO AwsRequestQuotasInput
interactiveAwsRequestQuotasInput repoRoot policyTier = do
  putStrLn "AWS quota requests submit increases only for supported targets that are still"
  putStrLn "below the required threshold."
  putStrLn ""
  credentials <- promptAdminCredentialsWithRegionChoice repoRoot
  AwsRequestQuotasInput <$> validateAdminCredentialsInput credentials <*> pure policyTier

showAwsAccountGuidance :: IO ()
showAwsAccountGuidance = do
  putStrLn "AWS account guidance:"
  putStrLn "1. Sign up at https://aws.amazon.com and choose the Free Tier."
  putStrLn "2. Add a payment method; AWS requires it even for Free Tier usage."
  putStrLn "3. Complete identity verification and keep the Basic (free) support plan."
  putStrLn "4. Create one temporary elevated access key from a temporary admin IAM user."
  putStrLn "5. Use that key only for onboarding, then delete it after `prodbox config setup`."
  putStrLn "Free Tier notes: 750 hours/month of t2.micro or t3.micro for 12 months,"
  putStrLn "5 GiB of S3 standard storage, and Route 53 usage billed separately."
  putStrLn ""

showAdminCredentialsGuidance :: IO ()
showAdminCredentialsGuidance = do
  putStrLn "Temporary elevated AWS credential guidance:"
  putStrLn "1. Sign in to the AWS console with an identity that can manage IAM users, access keys,"
  putStrLn "   Route 53 hosted zones, and Service Quotas."
  putStrLn "2. Create one temporary access key on a temporary admin IAM user:"
  putStrLn "   IAM -> Users -> <temporary admin user> -> Security credentials -> Create access key."
  putStrLn "3. Paste the access key ID and secret below. If AWS gave you temporary STS"
  putStrLn "   credentials, also paste the session token; otherwise leave it blank."
  putStrLn "4. `prodbox` never persists this elevated key. Delete it in the AWS console after"
  putStrLn "   the command completes."
  putStrLn ""

showRegionChoiceGuidance :: IO ()
showRegionChoiceGuidance = do
  putStrLn "AWS region guidance:"
  putStrLn "Choose the region that should own EC2-based validation and quota targets."
  putStrLn "Route 53 hosted zones are selected separately in the next step."
  putStrLn ""

showHostedZoneChoiceGuidance :: IO ()
showHostedZoneChoiceGuidance = do
  putStrLn "Route 53 hosted zone guidance:"
  putStrLn ("Choose the public hosted zone that owns " ++ Text.unpack supportedPublicHostname ++ ".")
  putStrLn "If the desired zone is missing, open AWS console -> Route 53 -> Hosted zones,"
  putStrLn "create or delegate the zone, then rerun this command."
  putStrLn ""

showAcmeProviderGuidance :: IO ()
showAcmeProviderGuidance = do
  putStrLn "ACME provider guidance:"
  putStrLn "1. ZeroSSL (recommended): open https://app.zerossl.com -> Developer -> EAB"
  putStrLn "   Credentials, then copy the EAB Key ID and HMAC key."
  putStrLn "2. Let's Encrypt: no account or EAB credentials are required; you only need"
  putStrLn "   the notification email below."
  putStrLn ""

showPolicyTierGuidance :: IO ()
showPolicyTierGuidance = do
  putStrLn "Operational IAM policy tier guidance:"
  putStrLn "1. full (recommended): Route 53, EC2 HA validation, and quota-management permissions."
  putStrLn "2. core: Route 53 runtime permissions only."
  putStrLn ""

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
    Text.pack . trim <$> promptText "Elevated AWS access key ID (from the AWS console)" Nothing
  secretAccessKey <- Text.pack . trim <$> promptSecret "Elevated AWS secret access key (hidden input)"
  sessionTokenRaw <-
    promptText "Elevated AWS session token (optional; STS/session credentials only)" Nothing
  regionRaw <-
    promptText
      "AWS region for elevated operations (you can change it after regions are listed)"
      (Just (Text.unpack defaultRegion))
  validateAdminCredentialsInput
    Credentials
      { access_key_id = accessKeyId
      , secret_access_key = secretAccessKey
      , session_token = normalizeOptionalText (Text.pack sessionTokenRaw)
      , region = Text.pack (trim regionRaw)
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
  preflightTeardown <-
    applyAwsTeardown
      repoRoot
      AwsTeardownInput
        { awsTeardownAdminCredentials = credentials
        }
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
    applyAwsSetup
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
                , "CONFIG_PATH=" ++ configDhallPath (canonicalConfigPaths repoRoot)
                ]
            )

runAwsIamHarnessTeardown :: FilePath -> IO String
runAwsIamHarnessTeardown repoRoot = do
  credentials <- loadHarnessAdminCredentials repoRoot
  result <-
    applyAwsTeardown
      repoRoot
      AwsTeardownInput
        { awsTeardownAdminCredentials = credentials
        }
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
  putStrLn "Available AWS regions:"
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
    putStrLn
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
    putStrLn "No hosted zones were found in Route 53."
    putStrLn "Create one in the Route 53 console or delegate an existing domain, then rerun."
    throwAws "No Route 53 hosted zones are available"
  showHostedZoneChoiceGuidance
  putStrLn "Available Route 53 hosted zones:"
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
    putStrLn
      ( show index
          ++ ". "
          ++ Text.unpack (hostedZoneChoiceName choice)
          ++ " ("
          ++ Text.unpack (hostedZoneChoiceId choice)
          ++ ")"
      )

promptText :: String -> Maybe String -> IO String
promptText message maybeDefault = do
  putStr (message ++ defaultSuffix maybeDefault ++ ": ")
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
  putStr (message ++ ": ")
  hFlush stdout
  if terminal
    then do
      originalEcho <- hGetEcho stdin
      value <- bracket_ (hSetEcho stdin False) (hSetEcho stdin originalEcho) (readPromptLine message)
      putStrLn ""
      pure (trim value)
    else trim <$> readPromptLine message

promptInt :: String -> Int -> IO Int
promptInt message defaultValue = do
  rawValue <- promptText message (Just (show defaultValue))
  case reads rawValue of
    [(parsed, "")] -> pure parsed
    _ -> do
      putStrLn "Enter a whole number."
      promptInt message defaultValue

promptConfirm :: String -> Bool -> IO Bool
promptConfirm message defaultValue = do
  let suffix = if defaultValue then " [Y/n]" else " [y/N]"
  putStr (message ++ suffix ++ ": ")
  hFlush stdout
  response <- fmap (map toLower . trim) (readPromptLine message)
  case response of
    "" -> pure defaultValue
    "y" -> pure True
    "yes" -> pure True
    "n" -> pure False
    "no" -> pure False
    _ -> do
      putStrLn "Enter yes or no."
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
                ++ "`. Re-run the command interactively with a temporary elevated AWS credential."
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
              putStrLn "Selected option is out of range."
              promptNumberedChoice promptMessage options defaultIndex
    _ -> do
      putStrLn "Enter the number shown beside the option."
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
applyAwsSetup repoRoot input = do
  (newAccessKeyId, newSecretAccessKey, quotaStatuses) <-
    ensureOperationalIamUser repoRoot (awsSetupAdminCredentials input) (awsSetupPolicyTierInput input)
  waitForOperationalCredentialsReady
    repoRoot
    (awsSetupAdminCredentials input)
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
                , region = region (awsSetupAdminCredentials input)
                }
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
          , iamSetupAccessKeyId = newAccessKeyId
          , iamSetupQuotaStatuses = quotaStatuses
          , iamSetupDhallPath = configDhallPath paths
          }

applyAwsTeardown :: FilePath -> AwsTeardownInput -> IO IamTeardownResult
applyAwsTeardown repoRoot input = do
  deletedAccessKeys <- deleteExistingOperationalKeys repoRoot (awsTeardownAdminCredentials input)
  deleteUserPolicyIfPresent repoRoot (awsTeardownAdminCredentials input)
  userDeleted <- deleteOperationalUserIfPresent repoRoot (awsTeardownAdminCredentials input)
  currentConfig <- loadConfigForWrite repoRoot
  let currentRegion =
        if Text.null (Text.strip (region (aws currentConfig)))
          then region (awsTeardownAdminCredentials input)
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
  pure
    IamTeardownResult
      { iamTeardownUserName = prodboxIamUserName
      , iamTeardownDeletedAccessKeys = deletedAccessKeys
      , iamTeardownUserDeleted = userDeleted
      , iamTeardownDhallPath = configDhallPath paths
      }

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
  waitForOperationalCredentialsReady repoRoot adminCredentials newAccessKeyId newSecretAccessKey
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
      , buildIamPolicyJson policyTier
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

waitForOperationalCredentialsReady :: FilePath -> Credentials -> Text -> Text -> IO ()
waitForOperationalCredentialsReady repoRoot adminCredentials newAccessKeyId newSecretAccessKey =
  go operationalCredentialReadyAttempts "STS validation did not return a result"
 where
  operationalCredentials =
    Credentials
      { access_key_id = newAccessKeyId
      , secret_access_key = newSecretAccessKey
      , session_token = Nothing
      , region = region adminCredentials
      }
  go attemptsRemaining lastError = do
    environment <- operationalAwsEnvironment operationalCredentials
    stsOutput <-
      runAwsCliCompletedWithEnvironment
        repoRoot
        environment
        ["sts", "get-caller-identity"]
    case processExitCode stsOutput of
      ExitSuccess -> pure ()
      ExitFailure _ ->
        let nextError =
              if errorDetail stsOutput == "command failed"
                then lastError
                else errorDetail stsOutput
         in if attemptsRemaining <= 1
              then
                throwAws
                  ( "Generated operational AWS credentials failed validation via "
                      ++ "`aws sts get-caller-identity`: "
                      ++ nextError
                  )
              else do
                threadDelay operationalCredentialRetryDelayMicros
                go (attemptsRemaining - 1) nextError

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
            case iamUserNameFromArn arn of
              Just userName -> OperationalIdentityIamUser userName
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

iamUserNameFromArn :: Text -> Maybe Text
iamUserNameFromArn arn = do
  resource <- case reverse (Text.splitOn ":" arn) of
    resourceValue : _ -> Just resourceValue
    [] -> Nothing
  resourceSuffix <- Text.stripPrefix "user/" resource
  case reverse (filter (/= "") (Text.splitOn "/" resourceSuffix)) of
    userName : _ -> Just userName
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
    , "POST_SETUP_GUIDANCE=Delete the temporary elevated access key you used for setup; prodbox now owns a dedicated IAM user for normal operations."
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
writeConfigFile path config = do
  maybeDhall <- findExecutable "dhall"
  case maybeDhall of
    Nothing ->
      throwAws
        "The `dhall` CLI is required to freeze `prodbox-config.dhall` after writing it."
    Just _ -> do
      writeFile path (renderConfigDhall config)
      freezeResult <-
        captureCommand
          CommandSpec
            { commandPath = "dhall"
            , commandArguments = ["freeze", "--all", "--inplace", takeFileName path]
            , commandEnvironment = Nothing
            , commandWorkingDirectory = Just (freezeWorkingDirectory path)
            }
      case freezeResult of
        Failure err ->
          throwAws ("Failed to freeze `" ++ path ++ "` after writing it: " ++ err)
        Success output ->
          case processExitCode output of
            ExitSuccess -> pure ()
            ExitFailure _ ->
              throwAws
                ( "Failed to freeze `"
                    ++ path
                    ++ "` after writing it: "
                    ++ errorDetail output
                )
 where
  freezeWorkingDirectory configPath =
    let directory = takeDirectory configPath
     in if directory == "" then "." else directory

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
    captureCommand
      CommandSpec
        { commandPath = "aws"
        , commandArguments = arguments ++ ["--output", "json"]
        , commandEnvironment = Just environment
        , commandWorkingDirectory = Just repoRoot
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
