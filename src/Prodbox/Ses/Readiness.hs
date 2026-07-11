{-# LANGUAGE OverloadedStrings #-}

-- | Semantic readiness for the retained SES sending and capture path.
--
-- AWS command success is only transport evidence.  This module keeps the
-- read-only subprocess boundary separate from a pure classifier that proves
-- the exact configured identity, MX record, receipt rule, and S3 list/get
-- capability before SMTP materialization may begin.
module Prodbox.Ses.Readiness
  ( AwsSesReadinessExpectation (..)
  , AwsSesReadinessEnvironments (..)
  , AwsSesReadinessScope (..)
  , AwsSesReadinessProbe (..)
  , AwsSesReadinessComponent (..)
  , AwsSesReadinessReason (..)
  , AwsSesReadiness (..)
  , AwsSesReadinessObservation (..)
  , AwsSesProviderReadiness (..)
  , AwsSesPropagationPolicy
  , AwsSesPropagationPolicyError (..)
  , AwsSesReadinessPollFailure (..)
  , sesReceiveRuleSetName
  , sesReceiveRuleName
  , sesCaptureKeyPrefix
  , sesCaptureReadinessKey
  , sesInboundMxPriority
  , sesInboundMxTarget
  , mkAwsSesReadinessExpectation
  , mkAwsSesPropagationPolicy
  , canonicalAwsSesPropagationPolicy
  , awsSesPropagationWindowSeconds
  , awsSesReadinessProbeArguments
  , classifyAwsSesReadinessProbe
  , classifyAwsSesReadiness
  , providerThenSemanticReadiness
  , observeAwsSesReadinessWith
  , observeAwsSesReadiness
  , pollAwsSesReadinessWith
  , pollAwsSesReadiness
  , renderAwsSesReadiness
  , renderAwsSesReadinessPollFailure
  )
where

import Control.Concurrent (threadDelay)
import Data.Aeson
  ( FromJSON (..)
  , Value (..)
  , eitherDecode
  , withObject
  , (.:)
  , (.:?)
  )
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char
  ( isAsciiLower
  , isAsciiUpper
  , toLower
  )
import Data.List
  ( intercalate
  , isInfixOf
  )
import Data.List.NonEmpty
  ( NonEmpty (..)
  )
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

sesReceiveRuleSetName :: String
sesReceiveRuleSetName = "prodbox-receive-rule-set"

sesReceiveRuleName :: String
sesReceiveRuleName = "prodbox-capture-all-mail"

sesCaptureKeyPrefix :: String
sesCaptureKeyPrefix = "inbound/"

sesCaptureReadinessKey :: String
sesCaptureReadinessKey = sesCaptureKeyPrefix ++ ".prodbox-readiness-capability-probe"

sesInboundMxPriority :: Int
sesInboundMxPriority = 10

sesInboundMxTarget :: String -> String
sesInboundMxTarget region = "inbound-smtp." ++ region ++ ".amazonaws.com"

data AwsSesReadinessExpectation = AwsSesReadinessExpectation
  { awsSesExpectedSenderDomain :: !String
  , awsSesExpectedHostedZoneId :: !String
  , awsSesExpectedRegion :: !String
  , awsSesExpectedReceiveSubdomain :: !String
  , awsSesExpectedMxPriority :: !Int
  , awsSesExpectedMxTarget :: !String
  , awsSesExpectedRuleSetName :: !String
  , awsSesExpectedRuleName :: !String
  , awsSesExpectedCaptureBucket :: !String
  , awsSesExpectedCapturePrefix :: !String
  , awsSesExpectedCaptureReadinessKey :: !String
  }
  deriving (Eq, Show)

-- | Separate environments make the credential boundary explicit.  Control
-- plane probes run under the lease-scoped role.  Capture probes run under the
-- operational credential consumed later by 'Prodbox.Ses.Capture'.
data AwsSesReadinessEnvironments = AwsSesReadinessEnvironments
  { awsSesControlPlaneEnvironment :: ![(String, String)]
  , awsSesCaptureEnvironment :: ![(String, String)]
  }
  deriving (Eq, Show)

data AwsSesReadinessScope
  = AwsSesSendingReadiness
  | AwsSesReceivingReadiness
  | AwsSesCaptureReadiness
  | AwsSesCompleteReadiness
  deriving (Bounded, Enum, Eq, Show)

data AwsSesReadinessProbe
  = AwsSesEmailIdentityProbe
  | AwsSesReceiveMxProbe
  | AwsSesActiveReceiptRulesProbe
  | AwsSesCaptureListProbe
  | AwsSesCaptureGetProbe
  deriving (Bounded, Enum, Eq, Ord, Show)

data AwsSesReadinessComponent
  = AwsSesProviderPresenceComponent
  | AwsSesSendingIdentityComponent
  | AwsSesReceiveMxComponent
  | AwsSesReceiptRuleComponent
  | AwsSesCaptureListComponent
  | AwsSesCaptureGetComponent
  deriving (Bounded, Enum, Eq, Ord, Show)

data AwsSesReadinessReason = AwsSesReadinessReason
  { awsSesReadinessReasonComponent :: !AwsSesReadinessComponent
  , awsSesReadinessReasonDetail :: !String
  }
  deriving (Eq, Show)

data AwsSesReadiness
  = AwsSesReady
  | AwsSesPending !(NonEmpty AwsSesReadinessReason)
  | AwsSesFailed !(NonEmpty AwsSesReadinessReason)
  | AwsSesUnobservable !(NonEmpty AwsSesReadinessReason)
  deriving (Eq, Show)

newtype AwsSesReadinessObservation = AwsSesReadinessObservation
  { awsSesReadinessProbeResults :: [(AwsSesReadinessProbe, Result ProcessOutput)]
  }
  deriving (Eq, Show)

-- | One authoritative provider-inventory observation made before semantic
-- probes in every await-stage attempt.
data AwsSesProviderReadiness
  = AwsSesProviderReady
  | AwsSesProviderPending !String
  | AwsSesProviderUnobservable !String
  deriving (Eq, Show)

data AwsSesPropagationPolicy = AwsSesPropagationPolicy
  { awsSesPropagationAttempts :: !Int
  , awsSesPropagationDelayMicroseconds :: !Int
  }
  deriving (Eq, Show)

data AwsSesPropagationPolicyError
  = AwsSesPropagationAttemptsMustExceedOne !Int
  | AwsSesPropagationDelayMustBePositive !Int
  | AwsSesPropagationWindowOutsideBounds !Int
  deriving (Eq, Show)

data AwsSesReadinessPollFailure
  = AwsSesReadinessTimedOut !(NonEmpty AwsSesReadinessReason)
  | AwsSesReadinessTerminalFailure !(NonEmpty AwsSesReadinessReason)
  | AwsSesReadinessObservationFailure !(NonEmpty AwsSesReadinessReason)
  deriving (Eq, Show)

-- | Construct the exact desired projection.  Public DNS names and bucket
-- names are validated before they can become AWS CLI arguments.
mkAwsSesReadinessExpectation
  :: String
  -> String
  -> String
  -> String
  -> String
  -> Either String AwsSesReadinessExpectation
mkAwsSesReadinessExpectation senderDomain hostedZoneId region receiveSubdomain captureBucket = do
  sender <- validateFqdn "SES sender domain" senderDomain
  receiver <- validateFqdn "SES receive subdomain" receiveSubdomain
  zone <- validateHostedZoneId hostedZoneId
  validatedRegion <- validateRegion region
  bucket <- validateBucketName captureBucket
  if receiver == sender || not (("." ++ sender) `isSuffixOfString` receiver)
    then
      Left
        ( "SES receive subdomain `"
            ++ receiver
            ++ "` must be a strict subdomain of sender domain `"
            ++ sender
            ++ "`."
        )
    else
      Right
        AwsSesReadinessExpectation
          { awsSesExpectedSenderDomain = sender
          , awsSesExpectedHostedZoneId = zone
          , awsSesExpectedRegion = validatedRegion
          , awsSesExpectedReceiveSubdomain = receiver
          , awsSesExpectedMxPriority = sesInboundMxPriority
          , awsSesExpectedMxTarget = sesInboundMxTarget validatedRegion
          , awsSesExpectedRuleSetName = sesReceiveRuleSetName
          , awsSesExpectedRuleName = sesReceiveRuleName
          , awsSesExpectedCaptureBucket = bucket
          , awsSesExpectedCapturePrefix = sesCaptureKeyPrefix
          , awsSesExpectedCaptureReadinessKey = sesCaptureReadinessKey
          }

-- | The semantic propagation window is independently bounded to 5–30
-- minutes.  Production uses 20 minutes, leaving ten minutes inside the
-- enclosing 30-minute lease-readiness budget for provider/API call latency,
-- cancellation, and diagnostic overhead.
mkAwsSesPropagationPolicy
  :: Int -> Int -> Either AwsSesPropagationPolicyError AwsSesPropagationPolicy
mkAwsSesPropagationPolicy attempts delayMicroseconds
  | attempts <= 1 = Left (AwsSesPropagationAttemptsMustExceedOne attempts)
  | delayMicroseconds <= 0 = Left (AwsSesPropagationDelayMustBePositive delayMicroseconds)
  | windowSeconds < 300 || windowSeconds > 1800 =
      Left (AwsSesPropagationWindowOutsideBounds windowSeconds)
  | otherwise =
      Right
        AwsSesPropagationPolicy
          { awsSesPropagationAttempts = attempts
          , awsSesPropagationDelayMicroseconds = delayMicroseconds
          }
 where
  windowSeconds = ((attempts - 1) * delayMicroseconds) `div` 1000000

canonicalAwsSesPropagationPolicy :: AwsSesPropagationPolicy
canonicalAwsSesPropagationPolicy =
  case mkAwsSesPropagationPolicy 121 10000000 of
    Left err -> error ("invalid canonical AWS SES propagation policy: " ++ show err)
    Right policy -> policy

awsSesPropagationWindowSeconds :: AwsSesPropagationPolicy -> Int
awsSesPropagationWindowSeconds policy =
  ( (awsSesPropagationAttempts policy - 1)
      * awsSesPropagationDelayMicroseconds policy
  )
    `div` 1000000

awsSesReadinessProbeArguments
  :: AwsSesReadinessExpectation -> FilePath -> AwsSesReadinessProbe -> [String]
awsSesReadinessProbeArguments expectation captureDestination probe =
  case probe of
    AwsSesEmailIdentityProbe ->
      [ "sesv2"
      , "get-email-identity"
      , "--email-identity"
      , awsSesExpectedSenderDomain expectation
      , "--output"
      , "json"
      ]
    AwsSesReceiveMxProbe ->
      [ "route53"
      , "list-resource-record-sets"
      , "--hosted-zone-id"
      , awsSesExpectedHostedZoneId expectation
      , "--output"
      , "json"
      ]
    AwsSesActiveReceiptRulesProbe ->
      [ "ses"
      , "describe-active-receipt-rule-set"
      , "--output"
      , "json"
      ]
    AwsSesCaptureListProbe ->
      [ "s3api"
      , "list-objects-v2"
      , "--bucket"
      , awsSesExpectedCaptureBucket expectation
      , "--prefix"
      , awsSesExpectedCaptureReadinessKey expectation
      , "--max-keys"
      , "1"
      , "--output"
      , "json"
      ]
    AwsSesCaptureGetProbe ->
      [ "s3api"
      , "get-object"
      , "--bucket"
      , awsSesExpectedCaptureBucket expectation
      , "--key"
      , awsSesExpectedCaptureReadinessKey expectation
      , captureDestination
      , "--output"
      , "json"
      ]

classifyAwsSesReadinessProbe
  :: AwsSesReadinessExpectation
  -> AwsSesReadinessProbe
  -> Result ProcessOutput
  -> AwsSesReadiness
classifyAwsSesReadinessProbe expectation probe result =
  case result of
    Failure err ->
      unobservable probe ("failed to start aws CLI: " ++ err)
    Success output ->
      case processExitCode output of
        ExitFailure _ -> classifyCommandFailure probe output
        ExitSuccess -> classifySuccess expectation probe (processStdout output)

classifyAwsSesReadiness
  :: AwsSesReadinessExpectation
  -> AwsSesReadinessScope
  -> AwsSesReadinessObservation
  -> AwsSesReadiness
classifyAwsSesReadiness expectation scope observation =
  combineReadiness (map classifySelected (probesForScope scope))
 where
  classifySelected probe =
    case [result | (candidate, result) <- awsSesReadinessProbeResults observation, candidate == probe] of
      [result] -> classifyAwsSesReadinessProbe expectation probe result
      [] -> unobservable probe "readiness observation omitted this required probe"
      _ -> unobservable probe "readiness observation contained duplicate results for this probe"

-- | Production ordering seam: semantic reconnaissance is unreachable until
-- the complete provider inventory is visible.  Tests inject both actions and
-- therefore prove the same short-circuit used by every production poll.
providerThenSemanticReadiness
  :: (Monad m)
  => m AwsSesProviderReadiness
  -> m AwsSesReadiness
  -> m AwsSesReadiness
providerThenSemanticReadiness observeProvider observeSemantic = do
  provider <- observeProvider
  case provider of
    AwsSesProviderReady -> observeSemantic
    AwsSesProviderPending detail ->
      pure (AwsSesPending (providerReason detail :| []))
    AwsSesProviderUnobservable detail ->
      pure (AwsSesUnobservable (providerReason detail :| []))
 where
  providerReason detail =
    AwsSesReadinessReason
      { awsSesReadinessReasonComponent = AwsSesProviderPresenceComponent
      , awsSesReadinessReasonDetail = detail
      }

observeAwsSesReadinessWith
  :: (Subprocess -> IO (Result ProcessOutput))
  -> FilePath
  -> AwsSesReadinessEnvironments
  -> AwsSesReadinessExpectation
  -> AwsSesReadinessScope
  -> IO AwsSesReadinessObservation
observeAwsSesReadinessWith runCommand workingDirectory environments expectation scope =
  withSystemTempDirectory "prodbox-ses-readiness" $ \temporaryDirectory -> do
    let captureDestination = temporaryDirectory </> "capture-readiness-object"
    results <-
      mapM
        ( \probe -> do
            result <-
              runCommand
                Subprocess
                  { subprocessPath = "aws"
                  , subprocessArguments =
                      awsSesReadinessProbeArguments expectation captureDestination probe
                  , subprocessEnvironment = Just (environmentForProbe environments probe)
                  , subprocessWorkingDirectory = Just workingDirectory
                  }
            pure (probe, result)
        )
        (probesForScope scope)
    pure (AwsSesReadinessObservation results)

observeAwsSesReadiness
  :: FilePath
  -> AwsSesReadinessEnvironments
  -> AwsSesReadinessExpectation
  -> AwsSesReadinessScope
  -> IO AwsSesReadiness
observeAwsSesReadiness workingDirectory environments expectation scope = do
  observation <-
    observeAwsSesReadinessWith
      captureSubprocessResult
      workingDirectory
      environments
      expectation
      scope
  pure (classifyAwsSesReadiness expectation scope observation)

pollAwsSesReadinessWith
  :: (Monad m)
  => AwsSesPropagationPolicy
  -> (Int -> m ())
  -> m AwsSesReadiness
  -> m (Either AwsSesReadinessPollFailure ())
pollAwsSesReadinessWith policy wait observe =
  go (awsSesPropagationAttempts policy)
 where
  go attemptsRemaining = do
    readiness <- observe
    case readiness of
      AwsSesReady -> pure (Right ())
      AwsSesFailed reasons -> pure (Left (AwsSesReadinessTerminalFailure reasons))
      AwsSesUnobservable reasons -> pure (Left (AwsSesReadinessObservationFailure reasons))
      AwsSesPending reasons
        | attemptsRemaining > 1 -> do
            wait (awsSesPropagationDelayMicroseconds policy)
            go (attemptsRemaining - 1)
        | otherwise -> pure (Left (AwsSesReadinessTimedOut reasons))

pollAwsSesReadiness
  :: AwsSesPropagationPolicy
  -> IO AwsSesReadiness
  -> IO (Either AwsSesReadinessPollFailure ())
pollAwsSesReadiness policy = pollAwsSesReadinessWith policy threadDelay

renderAwsSesReadiness :: AwsSesReadiness -> String
renderAwsSesReadiness readiness =
  case readiness of
    AwsSesReady -> "Ready"
    AwsSesPending reasons -> "Pending: " ++ renderReasons reasons
    AwsSesFailed reasons -> "Failed: " ++ renderReasons reasons
    AwsSesUnobservable reasons -> "Unobservable: " ++ renderReasons reasons

renderAwsSesReadinessPollFailure :: AwsSesReadinessPollFailure -> String
renderAwsSesReadinessPollFailure failure =
  case failure of
    AwsSesReadinessTimedOut reasons ->
      "semantic SES readiness timed out; last Pending observation: " ++ renderReasons reasons
    AwsSesReadinessTerminalFailure reasons ->
      "semantic SES readiness Failed: " ++ renderReasons reasons
    AwsSesReadinessObservationFailure reasons ->
      "semantic SES readiness Unobservable: " ++ renderReasons reasons

data IdentityResponse = IdentityResponse
  { identityType :: !Text
  , identityVerifiedForSending :: !Bool
  , identityVerificationStatus :: !Text
  , identityDkimSigningEnabled :: !Bool
  , identityDkimStatus :: !Text
  , identityVerificationErrorType :: !(Maybe Text)
  }

instance FromJSON IdentityResponse where
  parseJSON =
    withObject "GetEmailIdentityResponse" $ \root -> do
      dkim <- root .: "DkimAttributes"
      verificationInfo <- root .:? "VerificationInfo"
      errorType <-
        case verificationInfo of
          Nothing -> pure Nothing
          Just value -> withObject "VerificationInfo" (.:? "ErrorType") value
      withObject
        "DkimAttributes"
        ( \dkimObject ->
            IdentityResponse
              <$> root .: "IdentityType"
              <*> root .: "VerifiedForSendingStatus"
              <*> root .: "VerificationStatus"
              <*> dkimObject .: "SigningEnabled"
              <*> dkimObject .: "Status"
              <*> pure errorType
        )
        dkim

data Route53Record = Route53Record
  { route53RecordName :: !Text
  , route53RecordType :: !Text
  , route53RecordValues :: !(Maybe [Text])
  }

instance FromJSON Route53Record where
  parseJSON =
    withObject "ResourceRecordSet" $ \entry -> do
      maybeResources <- entry .:? "ResourceRecords"
      values <-
        traverse
          ( mapM
              (withObject "ResourceRecord" (.: "Value"))
              . Vector.toList
          )
          maybeResources
      Route53Record
        <$> entry .: "Name"
        <*> entry .: "Type"
        <*> pure values

newtype Route53Response = Route53Response [Route53Record]

instance FromJSON Route53Response where
  parseJSON =
    withObject "ListResourceRecordSetsResponse" $ \root -> do
      records <- root .: "ResourceRecordSets"
      Route53Response <$> mapM parseJSON (Vector.toList records)

data ReceiptMetadata = ReceiptMetadata
  { receiptMetadataName :: !Text
  }

instance FromJSON ReceiptMetadata where
  parseJSON = withObject "ReceiptRuleSetMetadata" $ \entry -> ReceiptMetadata <$> entry .: "Name"

newtype ReceiptAction = ReceiptAction (Maybe ReceiptS3Action)

instance FromJSON ReceiptAction where
  parseJSON = withObject "ReceiptAction" $ \entry -> ReceiptAction <$> entry .:? "S3Action"

data ReceiptS3Action = ReceiptS3Action
  { receiptS3BucketName :: !Text
  , receiptS3ObjectKeyPrefix :: !Text
  }

instance FromJSON ReceiptS3Action where
  parseJSON =
    withObject "S3Action" $ \entry -> do
      objectKeyPrefix <- fromMaybe "" <$> entry .:? "ObjectKeyPrefix"
      ReceiptS3Action
        <$> entry .: "BucketName"
        <*> pure objectKeyPrefix

data ReceiptRule = ReceiptRule
  { receiptRuleName :: !Text
  , receiptRuleEnabled :: !Bool
  , receiptRuleRecipients :: ![Text]
  , receiptRuleActions :: ![ReceiptAction]
  }

instance FromJSON ReceiptRule where
  parseJSON =
    withObject "ReceiptRule" $ \entry -> do
      enabled <- fromMaybe False <$> entry .:? "Enabled"
      recipients <- fromMaybe [] <$> entry .:? "Recipients"
      actions <- fromMaybe [] <$> entry .:? "Actions"
      ReceiptRule
        <$> entry .: "Name"
        <*> pure enabled
        <*> pure recipients
        <*> pure actions

data ReceiptResponse = ReceiptResponse
  { receiptResponseMetadata :: !(Maybe ReceiptMetadata)
  , receiptResponseRules :: ![ReceiptRule]
  }

instance FromJSON ReceiptResponse where
  parseJSON =
    withObject "DescribeActiveReceiptRuleSetResponse" $ \root ->
      ReceiptResponse
        <$> root .:? "Metadata"
        <*> (fromMaybe [] <$> root .:? "Rules")

data ListObjectsResponse = ListObjectsResponse
  { listObjectsKeyCount :: !Int
  , listObjectsKeys :: ![Text]
  }

instance FromJSON ListObjectsResponse where
  parseJSON =
    withObject "ListObjectsV2Response" $ \root -> do
      contents <- fromMaybe [] <$> root .:? "Contents"
      keys <- mapM (withObject "S3Object" (.: "Key")) contents
      ListObjectsResponse
        <$> root .: "KeyCount"
        <*> pure keys

classifySuccess
  :: AwsSesReadinessExpectation -> AwsSesReadinessProbe -> String -> AwsSesReadiness
classifySuccess expectation probe stdout =
  case probe of
    AwsSesEmailIdentityProbe ->
      case eitherDecode (BL8.pack stdout) of
        Left err -> unobservable probe ("malformed get-email-identity JSON: " ++ err)
        Right response -> classifyIdentity expectation response
    AwsSesReceiveMxProbe ->
      case eitherDecode (BL8.pack stdout) of
        Left err -> unobservable probe ("malformed Route 53 record-set JSON: " ++ err)
        Right response -> classifyMx expectation response
    AwsSesActiveReceiptRulesProbe ->
      case eitherDecode (BL8.pack stdout) of
        Left err -> unobservable probe ("malformed active receipt-rule JSON: " ++ err)
        Right response -> classifyReceiptRules expectation response
    AwsSesCaptureListProbe ->
      case eitherDecode (BL8.pack stdout) of
        Left err -> unobservable probe ("malformed list-objects-v2 JSON: " ++ err)
        Right response -> classifyCaptureList expectation response
    AwsSesCaptureGetProbe ->
      case eitherDecode (BL8.pack stdout) :: Either String Value of
        Left err -> unobservable probe ("malformed get-object JSON: " ++ err)
        Right (Object _) -> AwsSesReady
        Right _ -> unobservable probe "get-object response was not a JSON object"

classifyIdentity :: AwsSesReadinessExpectation -> IdentityResponse -> AwsSesReadiness
classifyIdentity expectation response
  | identityType response /= "DOMAIN" =
      failed
        AwsSesEmailIdentityProbe
        ("IdentityType was " ++ show (identityType response) ++ ", expected DOMAIN")
  | not (identityDkimSigningEnabled response) =
      failed AwsSesEmailIdentityProbe "DkimAttributes.SigningEnabled was false"
  | verificationClass == StatusFailed =
      failed AwsSesEmailIdentityProbe (identityDetail expectation response)
  | dkimClass == StatusFailed =
      failed AwsSesEmailIdentityProbe (identityDetail expectation response)
  | verificationClass == StatusUnknown =
      unobservable AwsSesEmailIdentityProbe (identityDetail expectation response)
  | dkimClass == StatusUnknown =
      unobservable AwsSesEmailIdentityProbe (identityDetail expectation response)
  | verificationClass == StatusPending || dkimClass == StatusPending =
      pending AwsSesEmailIdentityProbe (identityDetail expectation response)
  | not (identityVerifiedForSending response) =
      failed AwsSesEmailIdentityProbe (identityDetail expectation response)
  | otherwise = AwsSesReady
 where
  verificationClass = classifySesStatus (identityVerificationStatus response)
  dkimClass = classifySesStatus (identityDkimStatus response)

identityDetail :: AwsSesReadinessExpectation -> IdentityResponse -> String
identityDetail expectation response =
  intercalate
    ", "
    ( [ "sender=" ++ awsSesExpectedSenderDomain expectation
      , "IdentityType=" ++ Text.unpack (identityType response)
      , "VerifiedForSendingStatus=" ++ show (identityVerifiedForSending response)
      , "VerificationStatus=" ++ Text.unpack (identityVerificationStatus response)
      , "Dkim.SigningEnabled=" ++ show (identityDkimSigningEnabled response)
      , "Dkim.Status=" ++ Text.unpack (identityDkimStatus response)
      ]
        ++ maybe
          []
          (\errorType -> ["VerificationInfo.ErrorType=" ++ Text.unpack errorType])
          (identityVerificationErrorType response)
    )

data SesStatusClass
  = StatusReady
  | StatusPending
  | StatusFailed
  | StatusUnknown
  deriving (Eq, Show)

classifySesStatus :: Text -> SesStatusClass
classifySesStatus status =
  case status of
    "SUCCESS" -> StatusReady
    "PENDING" -> StatusPending
    "TEMPORARY_FAILURE" -> StatusPending
    "FAILED" -> StatusFailed
    "NOT_STARTED" -> StatusFailed
    _ -> StatusUnknown

classifyMx :: AwsSesReadinessExpectation -> Route53Response -> AwsSesReadiness
classifyMx expectation (Route53Response records) =
  case (sameNameRecords, matchingRecords) of
    ([], _) ->
      pending
        AwsSesReceiveMxProbe
        ("MX record for " ++ awsSesExpectedReceiveSubdomain expectation ++ " is not visible")
    (_, []) ->
      failed
        AwsSesReceiveMxProbe
        ( "record sets for "
            ++ awsSesExpectedReceiveSubdomain expectation
            ++ " had types "
            ++ show (map (Text.unpack . route53RecordType) sameNameRecords)
            ++ ", expected MX"
        )
    (_, [record]) -> classifyExactMx expectation record
    (_, _) ->
      failed
        AwsSesReceiveMxProbe
        ("multiple MX record sets matched " ++ awsSesExpectedReceiveSubdomain expectation)
 where
  sameNameRecords =
    [ record
    | record <- records
    , normalizeDnsName (Text.unpack (route53RecordName record))
        == normalizeDnsName (awsSesExpectedReceiveSubdomain expectation)
    ]
  matchingRecords =
    [ record
    | record <- sameNameRecords
    , Text.toUpper (route53RecordType record) == "MX"
    ]

classifyExactMx :: AwsSesReadinessExpectation -> Route53Record -> AwsSesReadiness
classifyExactMx expectation record =
  case route53RecordValues record of
    Nothing -> unobservable AwsSesReceiveMxProbe "matching MX record omitted ResourceRecords"
    Just [rawValue] ->
      case words (Text.unpack rawValue) of
        [priorityText, target]
          | Just priority <- parseUnsignedInt priorityText ->
              if priority == awsSesExpectedMxPriority expectation
                && normalizeDnsName target == normalizeDnsName (awsSesExpectedMxTarget expectation)
                then AwsSesReady
                else
                  failed
                    AwsSesReceiveMxProbe
                    ( "MX value was `"
                        ++ Text.unpack rawValue
                        ++ "`, expected `"
                        ++ show (awsSesExpectedMxPriority expectation)
                        ++ " "
                        ++ awsSesExpectedMxTarget expectation
                        ++ "`"
                    )
        _ -> failed AwsSesReceiveMxProbe ("MX value was malformed: " ++ show rawValue)
    Just values ->
      failed
        AwsSesReceiveMxProbe
        ("MX record had " ++ show (length values) ++ " values; expected exactly one")

classifyReceiptRules :: AwsSesReadinessExpectation -> ReceiptResponse -> AwsSesReadiness
classifyReceiptRules expectation response =
  case receiptResponseMetadata response of
    Nothing
      | null (receiptResponseRules response) ->
          pending AwsSesActiveReceiptRulesProbe "no active SES receipt-rule set is visible"
      | otherwise ->
          unobservable AwsSesActiveReceiptRulesProbe "receipt rules were returned without active-set metadata"
    Just metadata
      | Text.unpack (receiptMetadataName metadata) /= awsSesExpectedRuleSetName expectation ->
          failed
            AwsSesActiveReceiptRulesProbe
            ( "active rule set was `"
                ++ Text.unpack (receiptMetadataName metadata)
                ++ "`, expected `"
                ++ awsSesExpectedRuleSetName expectation
                ++ "`"
            )
      | otherwise ->
          case matchingRules of
            [] ->
              pending
                AwsSesActiveReceiptRulesProbe
                ("capture rule `" ++ awsSesExpectedRuleName expectation ++ "` is not visible")
            [rule] -> classifyExactReceiptRule expectation rule
            _ ->
              failed
                AwsSesActiveReceiptRulesProbe
                ("multiple rules were named `" ++ awsSesExpectedRuleName expectation ++ "`")
 where
  matchingRules =
    [ rule
    | rule <- receiptResponseRules response
    , Text.unpack (receiptRuleName rule) == awsSesExpectedRuleName expectation
    ]

classifyExactReceiptRule :: AwsSesReadinessExpectation -> ReceiptRule -> AwsSesReadiness
classifyExactReceiptRule expectation rule
  | not (receiptRuleEnabled rule) =
      failed AwsSesActiveReceiptRulesProbe "capture receipt rule Enabled was false"
  | normalizedRecipients /= [normalizeDnsName (awsSesExpectedReceiveSubdomain expectation)] =
      failed
        AwsSesActiveReceiptRulesProbe
        ( "capture receipt-rule recipients were "
            ++ show (map Text.unpack (receiptRuleRecipients rule))
            ++ ", expected exactly ["
            ++ awsSesExpectedReceiveSubdomain expectation
            ++ "]"
        )
  | otherwise =
      case receiptRuleActions rule of
        [ReceiptAction (Just action)]
          | Text.unpack (receiptS3BucketName action) == awsSesExpectedCaptureBucket expectation
              && Text.unpack (receiptS3ObjectKeyPrefix action) == awsSesExpectedCapturePrefix expectation ->
              AwsSesReady
          | otherwise ->
              failed
                AwsSesActiveReceiptRulesProbe
                ( "S3 action was bucket="
                    ++ Text.unpack (receiptS3BucketName action)
                    ++ ", prefix="
                    ++ Text.unpack (receiptS3ObjectKeyPrefix action)
                    ++ "; expected bucket="
                    ++ awsSesExpectedCaptureBucket expectation
                    ++ ", prefix="
                    ++ awsSesExpectedCapturePrefix expectation
                )
        actions ->
          failed
            AwsSesActiveReceiptRulesProbe
            ("capture receipt rule had " ++ show (length actions) ++ " actions; expected exactly one S3 action")
 where
  normalizedRecipients = map (normalizeDnsName . Text.unpack) (receiptRuleRecipients rule)

classifyCaptureList :: AwsSesReadinessExpectation -> ListObjectsResponse -> AwsSesReadiness
classifyCaptureList expectation response
  | listObjectsKeyCount response /= length (listObjectsKeys response) =
      unobservable
        AwsSesCaptureListProbe
        "list-objects-v2 KeyCount did not match the number of returned Contents entries"
  | expectedKey `elem` map Text.unpack (listObjectsKeys response) = AwsSesReady
  | otherwise =
      pending
        AwsSesCaptureListProbe
        ("capture readiness object `" ++ expectedKey ++ "` is not visible to list-objects-v2")
 where
  expectedKey = awsSesExpectedCaptureReadinessKey expectation

classifyCommandFailure :: AwsSesReadinessProbe -> ProcessOutput -> AwsSesReadiness
classifyCommandFailure probe output
  | reportsPendingAbsence probe normalized = pending probe detail
  | otherwise = unobservable probe detail
 where
  detail = renderProcessDetail output
  normalized = map toLower detail

reportsPendingAbsence :: AwsSesReadinessProbe -> String -> Bool
reportsPendingAbsence probe detail =
  any (`isInfixOf` detail) markers
 where
  markers = case probe of
    AwsSesEmailIdentityProbe -> ["notfoundexception", "identitynotfound"]
    AwsSesReceiveMxProbe -> []
    AwsSesActiveReceiptRulesProbe -> ["rulesetdoesnotexist", "no active receipt rule set"]
    AwsSesCaptureListProbe -> ["nosuchbucket"]
    AwsSesCaptureGetProbe -> ["nosuchkey", "nosuchbucket"]

combineReadiness :: [AwsSesReadiness] -> AwsSesReadiness
combineReadiness readings =
  case concatReasons selectUnobservable readings of
    reasons@(_ : _) -> AwsSesUnobservable (NonEmpty.fromList reasons)
    [] ->
      case concatReasons selectFailed readings of
        reasons@(_ : _) -> AwsSesFailed (NonEmpty.fromList reasons)
        [] ->
          case concatReasons selectPending readings of
            reasons@(_ : _) -> AwsSesPending (NonEmpty.fromList reasons)
            [] -> AwsSesReady
 where
  selectUnobservable readiness = case readiness of
    AwsSesUnobservable reasons -> NonEmpty.toList reasons
    _ -> []
  selectFailed readiness = case readiness of
    AwsSesFailed reasons -> NonEmpty.toList reasons
    _ -> []
  selectPending readiness = case readiness of
    AwsSesPending reasons -> NonEmpty.toList reasons
    _ -> []

concatReasons
  :: (AwsSesReadiness -> [AwsSesReadinessReason]) -> [AwsSesReadiness] -> [AwsSesReadinessReason]
concatReasons select = concatMap select

pending :: AwsSesReadinessProbe -> String -> AwsSesReadiness
pending probe detail = AwsSesPending (reason probe detail :| [])

failed :: AwsSesReadinessProbe -> String -> AwsSesReadiness
failed probe detail = AwsSesFailed (reason probe detail :| [])

unobservable :: AwsSesReadinessProbe -> String -> AwsSesReadiness
unobservable probe detail = AwsSesUnobservable (reason probe detail :| [])

reason :: AwsSesReadinessProbe -> String -> AwsSesReadinessReason
reason probe detail =
  AwsSesReadinessReason
    { awsSesReadinessReasonComponent = componentForProbe probe
    , awsSesReadinessReasonDetail = detail
    }

componentForProbe :: AwsSesReadinessProbe -> AwsSesReadinessComponent
componentForProbe probe =
  case probe of
    AwsSesEmailIdentityProbe -> AwsSesSendingIdentityComponent
    AwsSesReceiveMxProbe -> AwsSesReceiveMxComponent
    AwsSesActiveReceiptRulesProbe -> AwsSesReceiptRuleComponent
    AwsSesCaptureListProbe -> AwsSesCaptureListComponent
    AwsSesCaptureGetProbe -> AwsSesCaptureGetComponent

probesForScope :: AwsSesReadinessScope -> [AwsSesReadinessProbe]
probesForScope scope =
  case scope of
    AwsSesSendingReadiness -> [AwsSesEmailIdentityProbe]
    AwsSesReceivingReadiness -> [AwsSesReceiveMxProbe, AwsSesActiveReceiptRulesProbe]
    AwsSesCaptureReadiness -> [AwsSesCaptureListProbe, AwsSesCaptureGetProbe]
    AwsSesCompleteReadiness -> [minBound .. maxBound]

environmentForProbe
  :: AwsSesReadinessEnvironments -> AwsSesReadinessProbe -> [(String, String)]
environmentForProbe environments probe =
  case probe of
    AwsSesCaptureListProbe -> awsSesCaptureEnvironment environments
    AwsSesCaptureGetProbe -> awsSesCaptureEnvironment environments
    _ -> awsSesControlPlaneEnvironment environments

renderReasons :: NonEmpty AwsSesReadinessReason -> String
renderReasons = intercalate "; " . map renderReason . NonEmpty.toList

renderReason :: AwsSesReadinessReason -> String
renderReason item =
  renderComponent (awsSesReadinessReasonComponent item)
    ++ " — "
    ++ awsSesReadinessReasonDetail item

renderComponent :: AwsSesReadinessComponent -> String
renderComponent component =
  case component of
    AwsSesProviderPresenceComponent -> "provider presence"
    AwsSesSendingIdentityComponent -> "sending identity/DKIM"
    AwsSesReceiveMxComponent -> "receive MX"
    AwsSesReceiptRuleComponent -> "active receipt rule"
    AwsSesCaptureListComponent -> "capture list capability"
    AwsSesCaptureGetComponent -> "capture get capability"

renderProcessDetail :: ProcessOutput -> String
renderProcessDetail output =
  case filter (not . null) [trim (processStderr output), trim (processStdout output)] of
    [] -> "aws CLI exited without output"
    messages -> intercalate " | " messages

trim :: String -> String
trim = Text.unpack . Text.strip . Text.pack

normalizeDnsName :: String -> String
normalizeDnsName = map toLower . dropTrailingDots . trim

dropTrailingDots :: String -> String
dropTrailingDots = reverse . dropWhile (== '.') . reverse

parseUnsignedInt :: String -> Maybe Int
parseUnsignedInt raw
  | null raw || any (not . isAsciiDigit) raw = Nothing
  | otherwise = Just (read raw)

validateFqdn :: String -> String -> Either String String
validateFqdn label raw
  | null value || length value > 253 = Left (label ++ " must contain 1–253 characters.")
  | not (all validLabel labels) = Left (label ++ " is not a valid FQDN: `" ++ raw ++ "`.")
  | otherwise = Right value
 where
  value = normalizeDnsName raw
  labels = splitOnDot value
  validLabel labelValue =
    case (labelValue, reverse labelValue) of
      (firstCharacter : _, lastCharacter : _) ->
        length labelValue <= 63
          && all validFqdnCharacter labelValue
          && validFqdnEdge firstCharacter
          && validFqdnEdge lastCharacter
      _ -> False
  validFqdnCharacter character = validFqdnEdge character || character == '-'
  validFqdnEdge character = isAsciiLower character || isAsciiDigit character

validateHostedZoneId :: String -> Either String String
validateHostedZoneId raw
  | null value || any (not . validCharacter) value =
      Left ("Route 53 hosted-zone id is invalid: `" ++ raw ++ "`.")
  | otherwise = Right value
 where
  stripped = trim raw
  value = fromMaybe stripped (stripPrefixString "/hostedzone/" stripped)
  validCharacter character =
    isAsciiLower character || isAsciiUpper character || isAsciiDigit character

validateRegion :: String -> Either String String
validateRegion raw
  | null value || any (not . validCharacter) value = Left ("AWS region is invalid: `" ++ raw ++ "`.")
  | otherwise = Right value
 where
  value = trim raw
  validCharacter character = isAsciiLower character || isAsciiDigit character || character == '-'

validateBucketName :: String -> Either String String
validateBucketName raw
  | length value < 3 || length value > 63 = Left "SES capture bucket must contain 3–63 characters."
  | any (not . validCharacter) value = Left ("SES capture bucket is invalid: `" ++ raw ++ "`.")
  | not (validBucketEdges value) = Left ("SES capture bucket is invalid: `" ++ raw ++ "`.")
  | any (`isInfixOf` value) ["..", ".-", "-."] =
      Left ("SES capture bucket is invalid: `" ++ raw ++ "`.")
  | looksLikeIpv4 value = Left "SES capture bucket must not be formatted as an IPv4 address."
  | otherwise = Right value
 where
  value = trim raw
  validCharacter character = validEdge character || character == '-' || character == '.'
  validEdge character = isAsciiLower character || isAsciiDigit character
  validBucketEdges bucketValue =
    case (bucketValue, reverse bucketValue) of
      (firstCharacter : _, lastCharacter : _) ->
        validEdge firstCharacter && validEdge lastCharacter
      _ -> False

looksLikeIpv4 :: String -> Bool
looksLikeIpv4 raw =
  case traverse parseOctet (splitOnDot raw) of
    Just [_, _, _, _] -> True
    _ -> False
 where
  parseOctet value
    | null value || length value > 3 || any (not . isAsciiDigit) value = Nothing
    | otherwise =
        let parsed = read value :: Int
         in if parsed <= 255 then Just parsed else Nothing

splitOnDot :: String -> [String]
splitOnDot input =
  case break (== '.') input of
    (segment, []) -> [segment]
    (segment, _ : remaining) -> segment : splitOnDot remaining

stripPrefixString :: String -> String -> Maybe String
stripPrefixString prefix value
  | prefix `isPrefixOfString` value = Just (drop (length prefix) value)
  | otherwise = Nothing

isPrefixOfString :: String -> String -> Bool
isPrefixOfString prefix value = take (length prefix) value == prefix

isSuffixOfString :: String -> String -> Bool
isSuffixOfString suffix value = reverse suffix `isPrefixOfString` reverse value

isAsciiDigit :: Char -> Bool
isAsciiDigit character = character >= '0' && character <= '9'
