{-# LANGUAGE OverloadedStrings #-}

-- | Pure authority construction for gateway Route 53 writes.
--
-- A DNS write is representable only after credential, continuity, and claim
-- observations agree on the current generations and fence. The resulting
-- authority owns a sealed AWS environment built from no ambient base.
module Prodbox.Gateway.DnsAuthority
  ( CredentialGeneration
  , mkCredentialGeneration
  , credentialGenerationValue
  , CredentialReloadDecision (..)
  , decideCredentialReload
  , DnsCredentialField (..)
  , DnsCredentialInput (..)
  , DnsAwsCredentials
  , mkDnsAwsCredentials
  , CredentialObservation (..)
  , CredentialUnavailableReason (..)
  , ContinuityFence
  , mkContinuityFence
  , continuityFenceEpoch
  , continuityFenceSequence
  , continuityFenceHash
  , ContinuityObservation (..)
  , ContinuityUnavailableReason (..)
  , CurrentDnsClaim
  , mkCurrentDnsClaim
  , DnsClaimObservation (..)
  , ClaimUnavailableReason (..)
  , DnsWriteAuthorized
  , authorizeDnsWrite
  , authorizedDnsNodeId
  , authorizedCredentialGeneration
  , authorizedContinuityFence
  , dnsWriteAwsEnvironment
  , DnsWriteRequest
  , mkDnsWriteRequest
  , DnsWriteAction
  , authorizeDnsWriteRequest
  , dnsWriteActionZoneId
  , dnsWriteActionFqdn
  , dnsWriteActionTtl
  , dnsWriteActionRegion
  , dnsWriteActionIpv4
  , dnsWriteActionAwsEnvironment
  , DnsAuthorityError (..)
  )
where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)

newtype CredentialGeneration = CredentialGeneration Natural
  deriving (Eq, Ord, Show)

data CredentialReloadDecision
  = CredentialGenerationUnchanged
  | CredentialGenerationRestartRequired
      CredentialGeneration
      CredentialGeneration
  deriving (Eq, Show)

data DnsCredentialField
  = DnsAccessKeyId
  | DnsSecretAccessKey
  | DnsSessionToken
  | DnsRegion
  deriving (Bounded, Enum, Eq, Show)

data DnsCredentialInput = DnsCredentialInput
  { dnsCredentialAccessKeyId :: Text
  , dnsCredentialSecretAccessKey :: Text
  , dnsCredentialSessionToken :: Maybe Text
  , dnsCredentialRegion :: Text
  }
  deriving (Eq)

instance Show DnsCredentialInput where
  show input =
    "DnsCredentialInput { access_key_id = "
      ++ show (dnsCredentialAccessKeyId input)
      ++ ", secret_access_key = <redacted>, session_token = <redacted>, region = "
      ++ show (dnsCredentialRegion input)
      ++ " }"

data DnsAwsCredentials = DnsAwsCredentials
  { validatedDnsAccessKeyId :: Text
  , validatedDnsSecretAccessKey :: Text
  , validatedDnsSessionToken :: Maybe Text
  , validatedDnsRegion :: Text
  }
  deriving (Eq)

instance Show DnsAwsCredentials where
  show _ = "DnsAwsCredentials <redacted>"

data CredentialUnavailableReason
  = CredentialObjectAbsent
  | CredentialObjectInvalid DnsAuthorityError
  | CredentialObjectUnobservable Text
  deriving (Eq, Show)

data CredentialObservation
  = CredentialsAbsent CredentialGeneration
  | CredentialsInvalid CredentialGeneration DnsAuthorityError
  | CredentialsUnobservable Text
  | CredentialsReady CredentialGeneration DnsAwsCredentials
  deriving (Eq, Show)

data ContinuityFence = ContinuityFence
  { validatedContinuityEpoch :: Natural
  , validatedContinuitySequence :: Natural
  , validatedContinuityHash :: Text
  }
  deriving (Eq, Ord, Show)

data ContinuityUnavailableReason
  = ContinuityObjectAbsent
  | ContinuityObjectCorrupt Text
  | ContinuityObjectUnobservable Text
  deriving (Eq, Show)

data ContinuityObservation
  = ContinuityAbsent
  | ContinuityCorrupt Text
  | ContinuityUnobservable Text
  | ContinuityReady ContinuityFence
  deriving (Eq, Show)

data CurrentDnsClaim = CurrentDnsClaim
  { validatedClaimNodeId :: Text
  , validatedClaimCredentialGeneration :: CredentialGeneration
  , validatedClaimContinuityFence :: ContinuityFence
  }
  deriving (Eq, Show)

data ClaimUnavailableReason
  = ClaimAbsent
  | ClaimYielded
  | ClaimStale
  | ClaimUnobservable Text
  deriving (Eq, Show)

data DnsClaimObservation
  = DnsClaimAbsent
  | DnsClaimYielded
  | DnsClaimStale CurrentDnsClaim
  | DnsClaimUnobservable Text
  | DnsClaimCurrent CurrentDnsClaim
  deriving (Eq, Show)

data DnsWriteAuthorized = DnsWriteAuthorized
  { validatedAuthorizedNodeId :: Text
  , validatedAuthorizedCredentialGeneration :: CredentialGeneration
  , validatedAuthorizedContinuityFence :: ContinuityFence
  , validatedAuthorizedCredentials :: DnsAwsCredentials
  }
  deriving (Eq)

data DnsWriteRequest = DnsWriteRequest
  { validatedRequestZoneId :: Text
  , validatedRequestFqdn :: Text
  , validatedRequestTtl :: Natural
  , validatedRequestRegion :: Text
  , validatedRequestIpv4 :: Text
  }
  deriving (Eq, Show)

data DnsWriteAction = DnsWriteAction
  { validatedActionAuthority :: DnsWriteAuthorized
  , validatedActionRequest :: DnsWriteRequest
  }
  deriving (Eq)

instance Show DnsWriteAction where
  show action =
    "DnsWriteAction { authority = "
      ++ show (validatedActionAuthority action)
      ++ ", request = "
      ++ show (validatedActionRequest action)
      ++ " }"

instance Show DnsWriteAuthorized where
  show authority =
    "DnsWriteAuthorized { node_id = "
      ++ show (validatedAuthorizedNodeId authority)
      ++ ", credential_generation = "
      ++ show (validatedAuthorizedCredentialGeneration authority)
      ++ ", continuity_fence = "
      ++ show (validatedAuthorizedContinuityFence authority)
      ++ " }"

data DnsAuthorityError
  = CredentialGenerationMustBePositive
  | DnsCredentialFieldMustNotBeEmpty DnsCredentialField
  | ContinuityEpochMustBePositive
  | ContinuityHashMustNotBeEmpty
  | DnsClaimNodeIdMustNotBeEmpty
  | CredentialsNotReady CredentialUnavailableReason
  | ContinuityNotReady ContinuityUnavailableReason
  | DnsClaimNotCurrent ClaimUnavailableReason
  | DnsClaimNodeMismatch
      { expectedDnsClaimNode :: Text
      , observedDnsClaimNode :: Text
      }
  | DnsClaimCredentialGenerationMismatch
      { readyCredentialGeneration :: Natural
      , claimCredentialGeneration :: Natural
      }
  | DnsClaimContinuityFenceMismatch
  | DnsWriteZoneIdInvalid
  | DnsWriteFqdnInvalid
  | DnsWriteTtlInvalid Natural
  | DnsWriteRegionInvalid
  | DnsWriteIpv4Invalid
  | DnsWriteRequestRegionMismatch
  deriving (Eq, Show)

mkCredentialGeneration
  :: Natural -> Either DnsAuthorityError CredentialGeneration
mkCredentialGeneration generation
  | generation > 0 = Right (CredentialGeneration generation)
  | otherwise = Left CredentialGenerationMustBePositive

credentialGenerationValue :: CredentialGeneration -> Natural
credentialGenerationValue (CredentialGeneration generation) = generation

decideCredentialReload
  :: CredentialGeneration
  -> CredentialGeneration
  -> CredentialReloadDecision
decideCredentialReload current observed
  | current == observed = CredentialGenerationUnchanged
  | otherwise = CredentialGenerationRestartRequired current observed

mkDnsAwsCredentials
  :: DnsCredentialInput -> Either DnsAuthorityError DnsAwsCredentials
mkDnsAwsCredentials input = do
  accessKey <- requireCredentialField DnsAccessKeyId (dnsCredentialAccessKeyId input)
  secretKey <- requireCredentialField DnsSecretAccessKey (dnsCredentialSecretAccessKey input)
  sessionToken <-
    case dnsCredentialSessionToken input of
      Nothing -> Right Nothing
      Just value -> Just <$> requireCredentialField DnsSessionToken value
  region <- requireCredentialField DnsRegion (dnsCredentialRegion input)
  Right
    DnsAwsCredentials
      { validatedDnsAccessKeyId = accessKey
      , validatedDnsSecretAccessKey = secretKey
      , validatedDnsSessionToken = sessionToken
      , validatedDnsRegion = region
      }

mkContinuityFence
  :: Natural -> Natural -> Text -> Either DnsAuthorityError ContinuityFence
mkContinuityFence epoch sequenceNumber hashText
  | epoch == 0 = Left ContinuityEpochMustBePositive
  | Text.null (Text.strip hashText) = Left ContinuityHashMustNotBeEmpty
  | otherwise =
      Right
        ContinuityFence
          { validatedContinuityEpoch = epoch
          , validatedContinuitySequence = sequenceNumber
          , validatedContinuityHash = Text.strip hashText
          }

continuityFenceEpoch :: ContinuityFence -> Natural
continuityFenceEpoch = validatedContinuityEpoch

continuityFenceSequence :: ContinuityFence -> Natural
continuityFenceSequence = validatedContinuitySequence

continuityFenceHash :: ContinuityFence -> Text
continuityFenceHash = validatedContinuityHash

mkCurrentDnsClaim
  :: Text
  -> CredentialGeneration
  -> ContinuityFence
  -> Either DnsAuthorityError CurrentDnsClaim
mkCurrentDnsClaim nodeId generation fence
  | Text.null (Text.strip nodeId) = Left DnsClaimNodeIdMustNotBeEmpty
  | otherwise =
      Right
        CurrentDnsClaim
          { validatedClaimNodeId = Text.strip nodeId
          , validatedClaimCredentialGeneration = generation
          , validatedClaimContinuityFence = fence
          }

-- | Construct write authority only when all three external observations agree.
authorizeDnsWrite
  :: Text
  -> CredentialObservation
  -> ContinuityObservation
  -> DnsClaimObservation
  -> Either DnsAuthorityError DnsWriteAuthorized
authorizeDnsWrite localNodeId credentialObservation continuityObservation claimObservation = do
  (generation, credentials) <- requireReadyCredentials credentialObservation
  fence <- requireReadyContinuity continuityObservation
  claim <- requireCurrentClaim claimObservation
  let expectedNodeId = Text.strip localNodeId
      observedNodeId = validatedClaimNodeId claim
  if Text.null expectedNodeId
    then Left DnsClaimNodeIdMustNotBeEmpty
    else Right ()
  if observedNodeId == expectedNodeId
    then Right ()
    else
      Left
        DnsClaimNodeMismatch
          { expectedDnsClaimNode = expectedNodeId
          , observedDnsClaimNode = observedNodeId
          }
  if validatedClaimCredentialGeneration claim == generation
    then Right ()
    else
      Left
        DnsClaimCredentialGenerationMismatch
          { readyCredentialGeneration = credentialGenerationValue generation
          , claimCredentialGeneration =
              credentialGenerationValue (validatedClaimCredentialGeneration claim)
          }
  if validatedClaimContinuityFence claim == fence
    then Right ()
    else Left DnsClaimContinuityFenceMismatch
  Right
    DnsWriteAuthorized
      { validatedAuthorizedNodeId = expectedNodeId
      , validatedAuthorizedCredentialGeneration = generation
      , validatedAuthorizedContinuityFence = fence
      , validatedAuthorizedCredentials = credentials
      }

authorizedDnsNodeId :: DnsWriteAuthorized -> Text
authorizedDnsNodeId = validatedAuthorizedNodeId

authorizedCredentialGeneration :: DnsWriteAuthorized -> CredentialGeneration
authorizedCredentialGeneration = validatedAuthorizedCredentialGeneration

authorizedContinuityFence :: DnsWriteAuthorized -> ContinuityFence
authorizedContinuityFence = validatedAuthorizedContinuityFence

-- | Build the complete AWS environment from an empty base. Profile/config
-- discovery and instance/container metadata are disabled explicitly; ambient
-- AWS variables can never survive because no parent environment is accepted.
dnsWriteAwsEnvironment :: DnsWriteAuthorized -> [(String, String)]
dnsWriteAwsEnvironment authority =
  sessionEntries
    ++ [ ("AWS_ACCESS_KEY_ID", Text.unpack (validatedDnsAccessKeyId credentials))
       , ("AWS_SECRET_ACCESS_KEY", Text.unpack (validatedDnsSecretAccessKey credentials))
       , ("AWS_REGION", Text.unpack (validatedDnsRegion credentials))
       , ("AWS_DEFAULT_REGION", Text.unpack (validatedDnsRegion credentials))
       , ("AWS_EC2_METADATA_DISABLED", "true")
       , ("AWS_SHARED_CREDENTIALS_FILE", "/dev/null")
       , ("AWS_CONFIG_FILE", "/dev/null")
       , ("AWS_SDK_LOAD_CONFIG", "0")
       , ("AWS_PAGER", "")
       ]
 where
  credentials = validatedAuthorizedCredentials authority
  sessionEntries =
    case validatedDnsSessionToken credentials of
      Nothing -> []
      Just token -> [("AWS_SESSION_TOKEN", Text.unpack token)]

mkDnsWriteRequest
  :: Text
  -> Text
  -> Natural
  -> Text
  -> Text
  -> Either DnsAuthorityError DnsWriteRequest
mkDnsWriteRequest zoneId fqdn ttl region ipv4 = do
  let normalizedZone = Text.strip zoneId
      normalizedFqdn = Text.toLower (Text.dropWhileEnd (== '.') (Text.strip fqdn))
      normalizedRegion = Text.strip region
      normalizedIpv4 = Text.strip ipv4
  if validZoneId normalizedZone then Right () else Left DnsWriteZoneIdInvalid
  if validFqdn normalizedFqdn then Right () else Left DnsWriteFqdnInvalid
  if ttl > 0 && ttl <= 2147483647 then Right () else Left (DnsWriteTtlInvalid ttl)
  if validRegion normalizedRegion then Right () else Left DnsWriteRegionInvalid
  if validIpv4 normalizedIpv4 then Right () else Left DnsWriteIpv4Invalid
  Right
    DnsWriteRequest
      { validatedRequestZoneId = normalizedZone
      , validatedRequestFqdn = normalizedFqdn
      , validatedRequestTtl = ttl
      , validatedRequestRegion = normalizedRegion
      , validatedRequestIpv4 = normalizedIpv4
      }

authorizeDnsWriteRequest
  :: DnsWriteAuthorized
  -> DnsWriteRequest
  -> Either DnsAuthorityError DnsWriteAction
authorizeDnsWriteRequest authority request = do
  if validatedRequestRegion request
    == validatedDnsRegion (validatedAuthorizedCredentials authority)
    then Right ()
    else Left DnsWriteRequestRegionMismatch
  Right
    DnsWriteAction
      { validatedActionAuthority = authority
      , validatedActionRequest = request
      }

dnsWriteActionZoneId :: DnsWriteAction -> Text
dnsWriteActionZoneId = validatedRequestZoneId . validatedActionRequest

dnsWriteActionFqdn :: DnsWriteAction -> Text
dnsWriteActionFqdn = validatedRequestFqdn . validatedActionRequest

dnsWriteActionTtl :: DnsWriteAction -> Natural
dnsWriteActionTtl = validatedRequestTtl . validatedActionRequest

dnsWriteActionRegion :: DnsWriteAction -> Text
dnsWriteActionRegion = validatedRequestRegion . validatedActionRequest

dnsWriteActionIpv4 :: DnsWriteAction -> Text
dnsWriteActionIpv4 = validatedRequestIpv4 . validatedActionRequest

dnsWriteActionAwsEnvironment :: DnsWriteAction -> [(String, String)]
dnsWriteActionAwsEnvironment = dnsWriteAwsEnvironment . validatedActionAuthority

validZoneId :: Text -> Bool
validZoneId value =
  let size = Text.length value
   in size > 0
        && size <= 64
        && Text.all isAsciiAlphaNumeric value

validRegion :: Text -> Bool
validRegion value =
  let size = Text.length value
   in size > 0
        && size <= 64
        && Text.all
          (\character -> isAsciiAlphaNumeric character || character == '-')
          value

validFqdn :: Text -> Bool
validFqdn value =
  let labels = Text.splitOn "." value
   in Text.length value > 0
        && Text.length value <= 253
        && all validDnsLabel labels

validDnsLabel :: Text -> Bool
validDnsLabel label =
  let size = Text.length label
   in size > 0
        && size <= 63
        && Text.head label /= '-'
        && Text.last label /= '-'
        && Text.all
          (\character -> isAsciiAlphaNumeric character || character == '-')
          label

validIpv4 :: Text -> Bool
validIpv4 value =
  case traverse parseOctet (Text.splitOn "." value) of
    Just [_first, _second, _third, _fourth] -> True
    _ -> False
 where
  parseOctet raw
    | Text.null raw || not (Text.all isDigit raw) = Nothing
    | otherwise =
        case reads (Text.unpack raw) of
          [(number, "")]
            | number >= (0 :: Int) && number <= 255 -> Just number
          _ -> Nothing

isAsciiAlphaNumeric :: Char -> Bool
isAsciiAlphaNumeric character =
  isAsciiLower character || isAsciiUpper character || isDigit character

requireCredentialField
  :: DnsCredentialField -> Text -> Either DnsAuthorityError Text
requireCredentialField field value
  | Text.null (Text.strip value) = Left (DnsCredentialFieldMustNotBeEmpty field)
  | otherwise = Right (Text.strip value)

requireReadyCredentials
  :: CredentialObservation
  -> Either DnsAuthorityError (CredentialGeneration, DnsAwsCredentials)
requireReadyCredentials observation =
  case observation of
    CredentialsAbsent _ -> Left (CredentialsNotReady CredentialObjectAbsent)
    CredentialsInvalid _ err ->
      Left (CredentialsNotReady (CredentialObjectInvalid err))
    CredentialsUnobservable detail ->
      Left (CredentialsNotReady (CredentialObjectUnobservable detail))
    CredentialsReady generation credentials -> Right (generation, credentials)

requireReadyContinuity
  :: ContinuityObservation -> Either DnsAuthorityError ContinuityFence
requireReadyContinuity observation =
  case observation of
    ContinuityAbsent -> Left (ContinuityNotReady ContinuityObjectAbsent)
    ContinuityCorrupt detail ->
      Left (ContinuityNotReady (ContinuityObjectCorrupt detail))
    ContinuityUnobservable detail ->
      Left (ContinuityNotReady (ContinuityObjectUnobservable detail))
    ContinuityReady fence -> Right fence

requireCurrentClaim
  :: DnsClaimObservation -> Either DnsAuthorityError CurrentDnsClaim
requireCurrentClaim observation =
  case observation of
    DnsClaimAbsent -> Left (DnsClaimNotCurrent ClaimAbsent)
    DnsClaimYielded -> Left (DnsClaimNotCurrent ClaimYielded)
    DnsClaimStale _ -> Left (DnsClaimNotCurrent ClaimStale)
    DnsClaimUnobservable detail ->
      Left (DnsClaimNotCurrent (ClaimUnobservable detail))
    DnsClaimCurrent claim -> Right claim
