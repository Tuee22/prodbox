{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed, secret-free wire and durable state for one Admin Action Runner.
-- The only three executable actions are inherited from the Authority's
-- 'AdminAction' sum.  A permit is useful only after the Authority has obtained
-- an exact backup receipt for its core, observed one immutable Job Pod, and
-- signed the resulting Pod-bound envelope.
module Prodbox.Lifecycle.AdminAction.Protocol
  ( AdminActionPermitCore
  , AdminActionProtocolError (..)
  , AdminActionPlan (..)
  , AdminDestroyAwsSesPlan (..)
  , AdminTargetGeneration (..)
  , AdminRetainedCustodyMember (..)
  , AdminLegacyBackendPlan (..)
  , adminLegacyAwsSesSourceCoordinate
  , adminLegacyAwsSesDestinationCoordinate
  , AdminQuotaRequest (..)
  , mkAdminActionPermitCore
  , adminActionPermitOperationId
  , adminActionPermitAuthorityScope
  , adminActionPermitAuthorityEndpoint
  , adminActionPermitAction
  , adminActionPermitPlan
  , adminActionPermitNonce
  , adminActionPermitDeadline
  , adminActionPermitImageDigest
  , adminActionPermitBackupPayload
  , adminActionPermitBackupDigest
  , AdminActionBackupReceipt
  , mkAdminActionBackupReceipt
  , adminActionBackupReceiptReference
  , adminActionBackupReceiptDigest
  , adminActionBackupReceiptVersion
  , AdminActionJobBinding
  , mkAdminActionJobBinding
  , adminActionJobName
  , adminActionJobUid
  , adminActionJobPodName
  , adminActionJobPodUid
  , adminActionJobImageDigest
  , adminActionJobServiceAccount
  , adminActionJobServiceAccountUid
  , adminActionJobHeartbeat
  , adminActionRunnerServiceAccount
  , adminActionJobNameFor
  , SignedAdminActionPermit
  , adminActionPermitSigningPayload
  , mkSignedAdminActionPermit
  , verifySignedAdminActionPermit
  , encodeSignedAdminActionPermit
  , decodeSignedAdminActionPermit
  , signedAdminActionPermitCore
  , signedAdminActionPermitBinding
  , signedAdminActionPermitBackupReceipt
  , signedAdminActionPermitSignerGeneration
  , AdminDestroyReadBack (..)
  , AdminTargetGenerationReadBack (..)
  , AdminLegacyMigrationReadBack (..)
  , AdminQuotaItemReadBack (..)
  , AdminActionReadBack (..)
  , AdminActionReceipt
  , mkAdminActionReceipt
  , adminActionReceiptOperationId
  , adminActionReceiptAction
  , adminActionReceiptPodUid
  , adminActionReceiptReadBack
  , adminActionReceiptDigest
  , encodeAdminActionReceipt
  , decodeAdminActionReceipt
  , verifyAdminActionReceiptForPermit
  , AdminActionExecutionState (..)
  , initialAdminActionExecutionState
  , commitAdminActionPrepared
  , commitAdminActionAuthorized
  , commitAdminActionReauthorized
  , commitAdminActionCompleted
  , adminActionExecutionStateCodec
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Control.Monad qualified
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import Crypto.Hash.SHA256 qualified as SHA256
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower, isDigit, isSpace)
import Data.Foldable (traverse_)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.Authority.AdminAction
  ( AdminAction (..)
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCodec (..)
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  , authorityTimeMicros
  )

data AdminTargetGeneration = AdminTargetGeneration
  { adminTargetGenerationTargetId :: !Text
  , adminTargetGenerationEndpoint :: !Text
  , adminTargetGenerationValue :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminRetainedCustodyMember = AdminRetainedCustodyMember
  { adminRetainedCustodyTargetId :: !Text
  , adminRetainedCustodyEndpoint :: !Text
  , adminRetainedCustodyCoordinate :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminDestroyAwsSesPlan = AdminDestroyAwsSesPlan
  { adminDestroyConsumerReceiptDigest :: !Text
  , adminDestroyProviderRequestIdentity :: !Text
  , adminDestroyProviderAbsenceReceiptDigest :: !Text
  , adminDestroyProviderCoordinate :: !Text
  , adminDestroySmtpIamUser :: !Text
  , adminDestroySmtpIamPolicy :: !Text
  , adminDestroySmtpAccessKeyInventory :: ![Text]
  , adminDestroyTargetGenerations :: ![AdminTargetGeneration]
  , adminDestroyRetainedCustody :: !AdminRetainedCustodyMember
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminLegacyBackendPlan = AdminLegacyBackendPlan
  { adminLegacyAuthorityScope :: !Text
  , adminLegacyAuthorityEndpoint :: !Text
  , adminLegacySourceCoordinate :: !Text
  , adminLegacyDestinationCoordinate :: !Text
  , adminLegacySourceDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

adminLegacyAwsSesSourceCoordinate :: Text
adminLegacyAwsSesSourceCoordinate = "legacy-pulumi/aws-ses"

adminLegacyAwsSesDestinationCoordinate :: Text
adminLegacyAwsSesDestinationCoordinate = "authority-pulumi/aws-ses"

data AdminQuotaRequest = AdminQuotaRequest
  { adminQuotaRequestAuthorityScope :: !Text
  , adminQuotaRequestAuthorityEndpoint :: !Text
  , adminQuotaRequestServiceCode :: !Text
  , adminQuotaRequestCode :: !Text
  , adminQuotaRequestRegion :: !Text
  , adminQuotaRequestDesiredValue :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminActionPlan
  = AdminDestroyAwsSesPlanAction !AdminDestroyAwsSesPlan
  | AdminMigrateLegacyBackendPlanAction !AdminLegacyBackendPlan
  | AdminReconcileQuotaPlanAction ![AdminQuotaRequest]
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminActionPermitCore = AdminActionPermitCore
  { internalAdminActionOperationId :: !Text
  , internalAdminActionAuthorityScope :: !Text
  , internalAdminActionAuthorityEndpoint :: !Text
  , internalAdminActionPlan :: !AdminActionPlan
  , internalAdminActionNonce :: !Text
  , internalAdminActionDeadlineMicros :: !Natural
  , internalAdminActionImageDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminActionProtocolError
  = AdminActionFieldInvalid !Text
  | AdminActionDeadlineInvalid
  | AdminActionImageDigestInvalid
  | AdminActionBackupDigestMismatch
  | AdminActionBackupVersionInvalid
  | AdminActionJobBindingMismatch
  | AdminActionSignatureEmpty
  | AdminActionSignatureInvalid
  | AdminActionPublicKeyInvalid
  | AdminActionPermitExpired
  | AdminActionUnsupportedVersion !Word16
  | AdminActionWireTooLarge !Int !Int
  | AdminActionWireDecodeFailed
  | AdminActionWireNonCanonical
  | AdminActionReadBackInvalid
  | AdminActionReceiptMismatch
  | AdminActionStateConflict
  deriving stock (Eq, Show)

mkAdminActionPermitCore
  :: Text
  -> Text
  -> Text
  -> AdminActionPlan
  -> Text
  -> AuthorityTime
  -> Text
  -> Either AdminActionProtocolError AdminActionPermitCore
mkAdminActionPermitCore operationId authorityScope authorityEndpoint plan nonce deadline imageDigest = do
  validOperation <- validateOperationId operationId
  validAuthorityScope <- validateField "authority-scope" 256 authorityScope
  validateEndpoint "authority-endpoint" authorityEndpoint
  validatePlan plan
  validNonce <- validateField "nonce" 128 nonce
  validImage <- validateImageDigest imageDigest
  when (authorityTimeMicros deadline == 0) (Left AdminActionDeadlineInvalid)
  pure
    AdminActionPermitCore
      { internalAdminActionOperationId = validOperation
      , internalAdminActionAuthorityScope = validAuthorityScope
      , internalAdminActionAuthorityEndpoint = authorityEndpoint
      , internalAdminActionPlan = plan
      , internalAdminActionNonce = validNonce
      , internalAdminActionDeadlineMicros = authorityTimeMicros deadline
      , internalAdminActionImageDigest = validImage
      }

adminActionPermitOperationId :: AdminActionPermitCore -> Text
adminActionPermitOperationId = internalAdminActionOperationId

adminActionPermitAuthorityScope :: AdminActionPermitCore -> Text
adminActionPermitAuthorityScope = internalAdminActionAuthorityScope

adminActionPermitAuthorityEndpoint :: AdminActionPermitCore -> Text
adminActionPermitAuthorityEndpoint = internalAdminActionAuthorityEndpoint

adminActionPermitAction :: AdminActionPermitCore -> AdminAction
adminActionPermitAction = actionForPlan . internalAdminActionPlan

adminActionPermitPlan :: AdminActionPermitCore -> AdminActionPlan
adminActionPermitPlan = internalAdminActionPlan

adminActionPermitNonce :: AdminActionPermitCore -> Text
adminActionPermitNonce = internalAdminActionNonce

adminActionPermitDeadline :: AdminActionPermitCore -> AuthorityTime
adminActionPermitDeadline = authorityTimeFromMicros . internalAdminActionDeadlineMicros

adminActionPermitImageDigest :: AdminActionPermitCore -> Text
adminActionPermitImageDigest = internalAdminActionImageDigest

data AdminActionBackupEnvelope = AdminActionBackupEnvelope
  { adminActionBackupDomain :: !Text
  , adminActionBackupVersion :: !Word16
  , adminActionBackupCore :: !AdminActionPermitCore
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

adminActionPermitBackupPayload :: AdminActionPermitCore -> ByteString
adminActionPermitBackupPayload core =
  LazyByteString.toStrict
    ( serialise
        AdminActionBackupEnvelope
          { adminActionBackupDomain = "prodbox-admin-action-backup-v1"
          , adminActionBackupVersion = protocolVersion
          , adminActionBackupCore = core
          }
    )

adminActionPermitBackupDigest :: AdminActionPermitCore -> Text
adminActionPermitBackupDigest = sha256Text . adminActionPermitBackupPayload

data AdminActionBackupReceipt = AdminActionBackupReceipt
  { internalAdminBackupReference :: !Text
  , internalAdminBackupDigest :: !Text
  , internalAdminBackupVersion :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkAdminActionBackupReceipt
  :: AdminActionPermitCore
  -> Text
  -> Text
  -> Text
  -> Either AdminActionProtocolError AdminActionBackupReceipt
mkAdminActionBackupReceipt core reference digest version = do
  validReference <- validateField "backup-reference" 512 reference
  unless (digest == adminActionPermitBackupDigest core) (Left AdminActionBackupDigestMismatch)
  validVersion <-
    first (const AdminActionBackupVersionInvalid) (validateField "backup-version" 512 version)
  pure (AdminActionBackupReceipt validReference digest validVersion)

adminActionBackupReceiptReference :: AdminActionBackupReceipt -> Text
adminActionBackupReceiptReference = internalAdminBackupReference

adminActionBackupReceiptDigest :: AdminActionBackupReceipt -> Text
adminActionBackupReceiptDigest = internalAdminBackupDigest

adminActionBackupReceiptVersion :: AdminActionBackupReceipt -> Text
adminActionBackupReceiptVersion = internalAdminBackupVersion

adminActionRunnerServiceAccount :: Text
adminActionRunnerServiceAccount = "prodbox-admin-action-runner"

adminActionJobNameFor :: AdminActionPermitCore -> Text
adminActionJobNameFor core =
  "admin-action-" <> Text.take 40 (sanitizeDns (adminActionPermitOperationId core))

data AdminActionJobBinding = AdminActionJobBinding
  { internalAdminJobName :: !Text
  , internalAdminJobUid :: !Text
  , internalAdminJobPodName :: !Text
  , internalAdminJobPodUid :: !Text
  , internalAdminJobImageDigest :: !Text
  , internalAdminJobServiceAccount :: !Text
  , internalAdminJobServiceAccountUid :: !Text
  , internalAdminJobHeartbeatMicros :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkAdminActionJobBinding
  :: AdminActionPermitCore
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> AuthorityTime
  -> Either AdminActionProtocolError AdminActionJobBinding
mkAdminActionJobBinding core jobName jobUid podName podUid imageDigest serviceAccount serviceAccountUid heartbeat = do
  validJob <- validateField "job-name" 63 jobName
  validJobUid <- validateField "job-uid" 256 jobUid
  validPod <- validateField "pod-name" 253 podName
  validUid <- validateField "pod-uid" 256 podUid
  validImage <- validateImageDigest imageDigest
  validServiceAccount <- validateField "service-account" 253 serviceAccount
  validServiceAccountUid <- validateField "service-account-uid" 256 serviceAccountUid
  let heartbeatMicros = authorityTimeMicros heartbeat
  unless
    ( validJob == adminActionJobNameFor core
        && validImage == adminActionPermitImageDigest core
        && validServiceAccount == adminActionRunnerServiceAccount
        && heartbeatMicros > 0
        && heartbeatMicros < authorityTimeMicros (adminActionPermitDeadline core)
    )
    (Left AdminActionJobBindingMismatch)
  pure
    AdminActionJobBinding
      { internalAdminJobName = validJob
      , internalAdminJobUid = validJobUid
      , internalAdminJobPodName = validPod
      , internalAdminJobPodUid = validUid
      , internalAdminJobImageDigest = validImage
      , internalAdminJobServiceAccount = validServiceAccount
      , internalAdminJobServiceAccountUid = validServiceAccountUid
      , internalAdminJobHeartbeatMicros = heartbeatMicros
      }

adminActionJobName :: AdminActionJobBinding -> Text
adminActionJobName = internalAdminJobName

adminActionJobUid :: AdminActionJobBinding -> Text
adminActionJobUid = internalAdminJobUid

adminActionJobPodName :: AdminActionJobBinding -> Text
adminActionJobPodName = internalAdminJobPodName

adminActionJobPodUid :: AdminActionJobBinding -> Text
adminActionJobPodUid = internalAdminJobPodUid

adminActionJobImageDigest :: AdminActionJobBinding -> Text
adminActionJobImageDigest = internalAdminJobImageDigest

adminActionJobServiceAccount :: AdminActionJobBinding -> Text
adminActionJobServiceAccount = internalAdminJobServiceAccount

adminActionJobServiceAccountUid :: AdminActionJobBinding -> Text
adminActionJobServiceAccountUid = internalAdminJobServiceAccountUid

adminActionJobHeartbeat :: AdminActionJobBinding -> AuthorityTime
adminActionJobHeartbeat = authorityTimeFromMicros . internalAdminJobHeartbeatMicros

data AdminActionSigningEnvelope = AdminActionSigningEnvelope
  { adminActionSigningDomain :: !Text
  , adminActionSigningVersion :: !Word16
  , adminActionSigningSignerGeneration :: !Natural
  , adminActionSigningCore :: !AdminActionPermitCore
  , adminActionSigningBackupReceipt :: !AdminActionBackupReceipt
  , adminActionSigningJobBinding :: !AdminActionJobBinding
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data SignedAdminActionPermit = SignedAdminActionPermit
  { internalSignedAdminVersion :: !Word16
  , internalSignedAdminSignerGeneration :: !Natural
  , internalSignedAdminCore :: !AdminActionPermitCore
  , internalSignedAdminBackupReceipt :: !AdminActionBackupReceipt
  , internalSignedAdminJobBinding :: !AdminActionJobBinding
  , internalSignedAdminSignature :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

adminActionPermitSigningPayload
  :: Natural
  -> AdminActionPermitCore
  -> AdminActionBackupReceipt
  -> AdminActionJobBinding
  -> ByteString
adminActionPermitSigningPayload signerGeneration core backup binding =
  LazyByteString.toStrict
    ( serialise
        AdminActionSigningEnvelope
          { adminActionSigningDomain = "prodbox-admin-action-permit-v1"
          , adminActionSigningVersion = protocolVersion
          , adminActionSigningSignerGeneration = signerGeneration
          , adminActionSigningCore = core
          , adminActionSigningBackupReceipt = backup
          , adminActionSigningJobBinding = binding
          }
    )

mkSignedAdminActionPermit
  :: Natural
  -> AdminActionPermitCore
  -> AdminActionBackupReceipt
  -> AdminActionJobBinding
  -> ByteString
  -> Either AdminActionProtocolError SignedAdminActionPermit
mkSignedAdminActionPermit signerGeneration core backup binding signature = do
  when (signerGeneration == 0) (Left AdminActionSignatureInvalid)
  validateCore core
  validateBackup core backup
  validateBinding core binding
  when (ByteString.null signature) (Left AdminActionSignatureEmpty)
  when (ByteString.length signature > 512) (Left AdminActionSignatureInvalid)
  pure
    SignedAdminActionPermit
      { internalSignedAdminVersion = protocolVersion
      , internalSignedAdminSignerGeneration = signerGeneration
      , internalSignedAdminCore = core
      , internalSignedAdminBackupReceipt = backup
      , internalSignedAdminJobBinding = binding
      , internalSignedAdminSignature = signature
      }

verifySignedAdminActionPermit
  :: ByteString
  -> AuthorityTime
  -> SignedAdminActionPermit
  -> Either AdminActionProtocolError ()
verifySignedAdminActionPermit publicBytes now permit = do
  validateSigned permit
  when
    (authorityTimeMicros now >= authorityTimeMicros (adminActionPermitDeadline core))
    (Left AdminActionPermitExpired)
  publicKey <- case Ed25519.publicKey publicBytes of
    CryptoFailed _ -> Left AdminActionPublicKeyInvalid
    CryptoPassed value -> Right value
  signature <- case Ed25519.signature (internalSignedAdminSignature permit) of
    CryptoFailed _ -> Left AdminActionSignatureInvalid
    CryptoPassed value -> Right value
  unless
    ( Ed25519.verify
        publicKey
        ( adminActionPermitSigningPayload
            (internalSignedAdminSignerGeneration permit)
            core
            backup
            binding
        )
        signature
    )
    (Left AdminActionSignatureInvalid)
 where
  core = internalSignedAdminCore permit
  backup = internalSignedAdminBackupReceipt permit
  binding = internalSignedAdminJobBinding permit

encodeSignedAdminActionPermit :: SignedAdminActionPermit -> ByteString
encodeSignedAdminActionPermit = LazyByteString.toStrict . serialise

decodeSignedAdminActionPermit
  :: ByteString -> Either AdminActionProtocolError SignedAdminActionPermit
decodeSignedAdminActionPermit bytes = do
  permit <- decodeCanonical maximumPermitBytes bytes
  when
    (internalSignedAdminVersion permit /= protocolVersion)
    (Left (AdminActionUnsupportedVersion (internalSignedAdminVersion permit)))
  validateSigned permit
  pure permit

signedAdminActionPermitCore :: SignedAdminActionPermit -> AdminActionPermitCore
signedAdminActionPermitCore = internalSignedAdminCore

signedAdminActionPermitBinding :: SignedAdminActionPermit -> AdminActionJobBinding
signedAdminActionPermitBinding = internalSignedAdminJobBinding

signedAdminActionPermitBackupReceipt :: SignedAdminActionPermit -> AdminActionBackupReceipt
signedAdminActionPermitBackupReceipt = internalSignedAdminBackupReceipt

signedAdminActionPermitSignerGeneration :: SignedAdminActionPermit -> Natural
signedAdminActionPermitSignerGeneration = internalSignedAdminSignerGeneration

data AdminDestroyReadBack = AdminDestroyReadBack
  { adminDestroyConsumersAbsent :: !Text
  , adminDestroyProviderAbsent :: !Text
  , adminDestroySmtpIamAbsent :: !Text
  , adminDestroyTargetGenerationsAbsent :: ![AdminTargetGenerationReadBack]
  , adminDestroyRetainedCustodyAbsent :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminTargetGenerationReadBack = AdminTargetGenerationReadBack
  { adminTargetReadBackTargetId :: !Text
  , adminTargetReadBackGeneration :: !Natural
  , adminTargetReadBackAbsenceEvidence :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminLegacyMigrationReadBack = AdminLegacyMigrationReadBack
  { adminLegacyReadBackSourceCoordinate :: !Text
  , adminLegacyReadBackDestinationCoordinate :: !Text
  , adminLegacyImportReference :: !Text
  , adminLegacyCompatibilityEvidence :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminQuotaItemReadBack = AdminQuotaItemReadBack
  { adminQuotaServiceCode :: !Text
  , adminQuotaCode :: !Text
  , adminQuotaRegion :: !Text
  , adminQuotaDesiredValue :: !Text
  , adminQuotaAttemptIdentity :: !Text
  , adminQuotaProviderRequestIdentity :: !Text
  , adminQuotaStatus :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminActionReadBack
  = AdminDestroyAwsSesReadBack !AdminDestroyReadBack
  | AdminMigrateLegacyBackendReadBack !AdminLegacyMigrationReadBack
  | AdminReconcileQuotaReadBack ![AdminQuotaItemReadBack]
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminActionReceipt = AdminActionReceipt
  { internalAdminReceiptVersion :: !Word16
  , internalAdminReceiptOperationId :: !Text
  , internalAdminReceiptAction :: !AdminAction
  , internalAdminReceiptPodUid :: !Text
  , internalAdminReceiptReadBack :: !AdminActionReadBack
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkAdminActionReceipt
  :: SignedAdminActionPermit
  -> AdminActionReadBack
  -> Either AdminActionProtocolError AdminActionReceipt
mkAdminActionReceipt permit readBack = do
  validateSigned permit
  validateReadBackForPlan (adminActionPermitPlan core) readBack
  pure
    AdminActionReceipt
      { internalAdminReceiptVersion = protocolVersion
      , internalAdminReceiptOperationId = adminActionPermitOperationId core
      , internalAdminReceiptAction = adminActionPermitAction core
      , internalAdminReceiptPodUid = adminActionJobPodUid binding
      , internalAdminReceiptReadBack = readBack
      }
 where
  core = signedAdminActionPermitCore permit
  binding = signedAdminActionPermitBinding permit

adminActionReceiptOperationId :: AdminActionReceipt -> Text
adminActionReceiptOperationId = internalAdminReceiptOperationId

adminActionReceiptAction :: AdminActionReceipt -> AdminAction
adminActionReceiptAction = internalAdminReceiptAction

adminActionReceiptPodUid :: AdminActionReceipt -> Text
adminActionReceiptPodUid = internalAdminReceiptPodUid

adminActionReceiptReadBack :: AdminActionReceipt -> AdminActionReadBack
adminActionReceiptReadBack = internalAdminReceiptReadBack

adminActionReceiptDigest :: AdminActionReceipt -> Text
adminActionReceiptDigest = sha256Text . encodeAdminActionReceipt

encodeAdminActionReceipt :: AdminActionReceipt -> ByteString
encodeAdminActionReceipt = LazyByteString.toStrict . serialise

decodeAdminActionReceipt
  :: ByteString -> Either AdminActionProtocolError AdminActionReceipt
decodeAdminActionReceipt bytes = do
  receipt <- decodeCanonical maximumReceiptBytes bytes
  when
    (internalAdminReceiptVersion receipt /= protocolVersion)
    (Left (AdminActionUnsupportedVersion (internalAdminReceiptVersion receipt)))
  _ <- validateField "receipt-operation-id" 128 (internalAdminReceiptOperationId receipt)
  _ <- validateField "receipt-pod-uid" 256 (internalAdminReceiptPodUid receipt)
  validateReadBack (internalAdminReceiptAction receipt) (internalAdminReceiptReadBack receipt)
  pure receipt

verifyAdminActionReceiptForPermit
  :: SignedAdminActionPermit
  -> AdminActionReceipt
  -> Either AdminActionProtocolError ()
verifyAdminActionReceiptForPermit = validateReceiptMatches

data AdminActionExecutionState
  = AdminActionExecutionIdle
  | AdminActionExecutionPrepared !AdminActionPermitCore !AdminActionBackupReceipt
  | AdminActionExecutionAuthorized !SignedAdminActionPermit
  | AdminActionExecutionCompleted !SignedAdminActionPermit !AdminActionReceipt
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

initialAdminActionExecutionState :: AdminActionExecutionState
initialAdminActionExecutionState = AdminActionExecutionIdle

commitAdminActionPrepared
  :: AdminActionPermitCore
  -> AdminActionBackupReceipt
  -> AdminActionExecutionState
  -> Either AdminActionProtocolError AdminActionExecutionState
commitAdminActionPrepared core backup state = do
  validateCore core
  validateBackup core backup
  case state of
    AdminActionExecutionIdle -> Right (AdminActionExecutionPrepared core backup)
    AdminActionExecutionPrepared existing existingBackup
      | existing == core && existingBackup == backup -> Right state
    _ -> Left AdminActionStateConflict

commitAdminActionAuthorized
  :: SignedAdminActionPermit
  -> AdminActionExecutionState
  -> Either AdminActionProtocolError AdminActionExecutionState
commitAdminActionAuthorized permit state = do
  validateSigned permit
  case state of
    AdminActionExecutionPrepared core backup
      | core == signedAdminActionPermitCore permit
          && backup == signedAdminActionPermitBackupReceipt permit ->
          Right (AdminActionExecutionAuthorized permit)
    AdminActionExecutionAuthorized existing
      | existing == permit -> Right state
    _ -> Left AdminActionStateConflict

-- | Replace a prior, now-absent Job/Pod attempt with a newly attested exact
-- binding while retaining the same backup-bound operation.  Kubernetes Job
-- name uniqueness and the coordinator's positive old-binding absence proof
-- serialize this transition; the Runner's retained per-role session fence is
-- the independent login/session serialization point.
commitAdminActionReauthorized
  :: SignedAdminActionPermit
  -> AdminActionExecutionState
  -> Either AdminActionProtocolError AdminActionExecutionState
commitAdminActionReauthorized permit state = do
  validateSigned permit
  case state of
    AdminActionExecutionAuthorized existing
      | signedAdminActionPermitCore existing == signedAdminActionPermitCore permit
          && signedAdminActionPermitBackupReceipt existing
            == signedAdminActionPermitBackupReceipt permit ->
          Right (AdminActionExecutionAuthorized permit)
    _ -> Left AdminActionStateConflict

commitAdminActionCompleted
  :: AdminActionReceipt
  -> AdminActionExecutionState
  -> Either AdminActionProtocolError AdminActionExecutionState
commitAdminActionCompleted receipt state = case state of
  AdminActionExecutionAuthorized permit -> do
    validateReceiptMatches permit receipt
    Right (AdminActionExecutionCompleted permit receipt)
  AdminActionExecutionCompleted permit existing
    | existing == receipt -> do
        validateReceiptMatches permit receipt
        Right state
  _ -> Left AdminActionStateConflict

adminActionExecutionStateCodec :: Int -> ModelBCodec AdminActionExecutionState
adminActionExecutionStateCodec maximumBytes =
  ModelBCodec
    { encodeModelBValue = \state -> do
        first show (validateState state)
        let bytes = LazyByteString.toStrict (serialise (protocolVersion, state))
        if ByteString.length bytes > maximumBytes
          then Left (show (AdminActionWireTooLarge (ByteString.length bytes) maximumBytes))
          else Right bytes
    , decodeModelBValue = \bytes -> first show $ do
        (version, state) <- decodeCanonical maximumBytes bytes
        when (version /= protocolVersion) (Left (AdminActionUnsupportedVersion version))
        validateState state
        pure state
    }

validateState :: AdminActionExecutionState -> Either AdminActionProtocolError ()
validateState state = case state of
  AdminActionExecutionIdle -> Right ()
  AdminActionExecutionPrepared core backup -> validateCore core >> validateBackup core backup
  AdminActionExecutionAuthorized permit -> validateSigned permit
  AdminActionExecutionCompleted permit receipt ->
    validateSigned permit >> validateReceiptMatches permit receipt

validateReceiptMatches
  :: SignedAdminActionPermit
  -> AdminActionReceipt
  -> Either AdminActionProtocolError ()
validateReceiptMatches permit receipt = do
  decoded <- decodeAdminActionReceipt (encodeAdminActionReceipt receipt)
  let core = signedAdminActionPermitCore permit
      binding = signedAdminActionPermitBinding permit
  validateReadBackForPlan
    (adminActionPermitPlan core)
    (adminActionReceiptReadBack receipt)
  unless
    ( decoded == receipt
        && adminActionReceiptOperationId receipt == adminActionPermitOperationId core
        && adminActionReceiptAction receipt == adminActionPermitAction core
        && adminActionReceiptPodUid receipt == adminActionJobPodUid binding
    )
    (Left AdminActionReceiptMismatch)

validateSigned :: SignedAdminActionPermit -> Either AdminActionProtocolError ()
validateSigned permit = do
  when
    (internalSignedAdminVersion permit /= protocolVersion)
    (Left (AdminActionUnsupportedVersion (internalSignedAdminVersion permit)))
  validateCore core
  validateBackup core (internalSignedAdminBackupReceipt permit)
  validateBinding core (internalSignedAdminJobBinding permit)
  when (internalSignedAdminSignerGeneration permit == 0) (Left AdminActionSignatureInvalid)
  when (ByteString.null (internalSignedAdminSignature permit)) (Left AdminActionSignatureEmpty)
  when
    (ByteString.length (internalSignedAdminSignature permit) > 512)
    (Left AdminActionSignatureInvalid)
 where
  core = internalSignedAdminCore permit

validateCore :: AdminActionPermitCore -> Either AdminActionProtocolError ()
validateCore core = do
  rebuilt <-
    mkAdminActionPermitCore
      (internalAdminActionOperationId core)
      (internalAdminActionAuthorityScope core)
      (internalAdminActionAuthorityEndpoint core)
      (internalAdminActionPlan core)
      (internalAdminActionNonce core)
      (authorityTimeFromMicros (internalAdminActionDeadlineMicros core))
      (internalAdminActionImageDigest core)
  unless (rebuilt == core) (Left AdminActionStateConflict)

validateBackup
  :: AdminActionPermitCore
  -> AdminActionBackupReceipt
  -> Either AdminActionProtocolError ()
validateBackup core backup = do
  rebuilt <-
    mkAdminActionBackupReceipt
      core
      (internalAdminBackupReference backup)
      (internalAdminBackupDigest backup)
      (internalAdminBackupVersion backup)
  unless (rebuilt == backup) (Left AdminActionBackupDigestMismatch)

validateBinding
  :: AdminActionPermitCore
  -> AdminActionJobBinding
  -> Either AdminActionProtocolError ()
validateBinding core binding = do
  rebuilt <-
    mkAdminActionJobBinding
      core
      (internalAdminJobName binding)
      (internalAdminJobUid binding)
      (internalAdminJobPodName binding)
      (internalAdminJobPodUid binding)
      (internalAdminJobImageDigest binding)
      (internalAdminJobServiceAccount binding)
      (internalAdminJobServiceAccountUid binding)
      (authorityTimeFromMicros (internalAdminJobHeartbeatMicros binding))
  unless (rebuilt == binding) (Left AdminActionJobBindingMismatch)

actionForPlan :: AdminActionPlan -> AdminAction
actionForPlan plan = case plan of
  AdminDestroyAwsSesPlanAction _ -> DestroyAwsSes
  AdminMigrateLegacyBackendPlanAction _ -> MigrateLegacyBackend
  AdminReconcileQuotaPlanAction _ -> ReconcileQuota

validatePlan :: AdminActionPlan -> Either AdminActionProtocolError ()
validatePlan plan = case plan of
  AdminDestroyAwsSesPlanAction value -> do
    let custody = adminDestroyRetainedCustody value
    validateDigest "consumer-receipt-digest" (adminDestroyConsumerReceiptDigest value)
    _ <- validateField "provider-request-identity" 128 (adminDestroyProviderRequestIdentity value)
    validateDigest "provider-absence-receipt-digest" (adminDestroyProviderAbsenceReceiptDigest value)
    providerCoordinate <-
      validateField "provider-coordinate" 128 (adminDestroyProviderCoordinate value)
    smtpUser <- validateField "smtp-iam-user" 128 (adminDestroySmtpIamUser value)
    smtpPolicy <- validateField "smtp-iam-policy" 128 (adminDestroySmtpIamPolicy value)
    _ <-
      validateField
        "retained-custody-coordinate"
        256
        (adminRetainedCustodyCoordinate custody)
    unless (providerCoordinate == "aws-ses/provider") invalid
    unless (smtpUser == "prodbox-ses-smtp") invalid
    unless (smtpPolicy == "prodbox-ses-smtp-policy") invalid
    unless
      ( adminRetainedCustodyCoordinate custody
          == "target-agent/retained-home/ses-smtp-source"
      )
      invalid
    let keyInventory = adminDestroySmtpAccessKeyInventory value
        targets = adminDestroyTargetGenerations value
        targetCoordinates =
          fmap
            ( \target ->
                ( adminTargetGenerationTargetId target
                , adminTargetGenerationEndpoint target
                , adminTargetGenerationValue target
                )
            )
            targets
    when (length keyInventory > 2 || nub keyInventory /= keyInventory) invalid
    traverse_ (validateFieldDiscard "smtp-access-key-id" 128) keyInventory
    when (null targets || length targets > 64 || nub targetCoordinates /= targetCoordinates) invalid
    traverse_ validateTarget targets
    custodyTarget <-
      validateField "retained-custody-target-id" 256 (adminRetainedCustodyTargetId custody)
    validatePlanEndpoint "retained-custody-endpoint" (adminRetainedCustodyEndpoint custody)
    unless (custodyTarget `elem` fmap adminTargetGenerationTargetId targets) invalid
  AdminMigrateLegacyBackendPlanAction value -> do
    _ <- validateField "legacy-authority-scope" 256 (adminLegacyAuthorityScope value)
    validatePlanEndpoint "legacy-authority-endpoint" (adminLegacyAuthorityEndpoint value)
    source <- validateField "legacy-source-coordinate" 512 (adminLegacySourceCoordinate value)
    destination <-
      validateField "legacy-destination-coordinate" 512 (adminLegacyDestinationCoordinate value)
    validateDigest "legacy-source-digest" (adminLegacySourceDigest value)
    unless
      ( source == adminLegacyAwsSesSourceCoordinate
          && destination == adminLegacyAwsSesDestinationCoordinate
      )
      invalid
  AdminReconcileQuotaPlanAction requests -> do
    when (null requests || length requests > 64) invalid
    traverse_ validateQuotaRequest requests
    let authorityBindings =
          fmap
            (\request -> (adminQuotaRequestAuthorityScope request, adminQuotaRequestAuthorityEndpoint request))
            requests
    when (length (nub authorityBindings) /= 1) invalid
    let identities = fmap quotaRequestCoordinate requests
    when (nub identities /= identities) invalid
 where
  invalid = Left AdminActionReadBackInvalid
  validateTarget target = do
    _ <- validateField "target-id" 256 (adminTargetGenerationTargetId target)
    validatePlanEndpoint "target-endpoint" (adminTargetGenerationEndpoint target)
    when (adminTargetGenerationValue target == 0) invalid
  validateQuotaRequest request = do
    _ <- validateField "quota-authority-scope" 256 (adminQuotaRequestAuthorityScope request)
    validatePlanEndpoint "quota-authority-endpoint" (adminQuotaRequestAuthorityEndpoint request)
    traverse_
      (\(label, maximumLength, field) -> validateFieldDiscard label maximumLength field)
      [ ("quota-service-code", 64, adminQuotaRequestServiceCode request)
      , ("quota-code", 64, adminQuotaRequestCode request)
      , ("quota-region", 64, adminQuotaRequestRegion request)
      , ("quota-desired-value", 64, adminQuotaRequestDesiredValue request)
      ]
  quotaRequestCoordinate request =
    ( adminQuotaRequestServiceCode request
    , adminQuotaRequestCode request
    , adminQuotaRequestRegion request
    )
  validatePlanEndpoint label endpoint = do
    value <- validateField label 2048 endpoint
    unless
      (Text.isPrefixOf "http://" value || Text.isPrefixOf "https://" value)
      invalid

validateFieldDiscard
  :: Text -> Int -> Text -> Either AdminActionProtocolError ()
validateFieldDiscard label maximumLength value =
  Control.Monad.void (validateField label maximumLength value)

validateDigest :: Text -> Text -> Either AdminActionProtocolError ()
validateDigest label value = do
  digest <- validateField label 64 value
  unless
    (Text.length digest == 64 && Text.all (\c -> isDigit c || c `elem` ['a' .. 'f']) digest)
    (Left (AdminActionFieldInvalid label))

validateReadBackForPlan
  :: AdminActionPlan
  -> AdminActionReadBack
  -> Either AdminActionProtocolError ()
validateReadBackForPlan plan readBack = do
  validateReadBack (actionForPlan plan) readBack
  case (plan, readBack) of
    (AdminDestroyAwsSesPlanAction expected, AdminDestroyAwsSesReadBack actual) -> do
      unless
        ( adminDestroyConsumersAbsent actual == adminDestroyConsumerReceiptDigest expected
            && adminDestroyProviderAbsent actual == adminDestroyProviderAbsenceReceiptDigest expected
            && fmap targetReadBackCoordinate (adminDestroyTargetGenerationsAbsent actual)
              == fmap targetCoordinate (adminDestroyTargetGenerations expected)
        )
        invalid
    (AdminMigrateLegacyBackendPlanAction expected, AdminMigrateLegacyBackendReadBack actual) ->
      unless
        ( adminLegacyReadBackSourceCoordinate actual == adminLegacySourceCoordinate expected
            && adminLegacyReadBackDestinationCoordinate actual == adminLegacyDestinationCoordinate expected
        )
        invalid
    (AdminReconcileQuotaPlanAction expected, AdminReconcileQuotaReadBack actual) ->
      unless (length expected == length actual && and (zipWith quotaMatches expected actual)) invalid
    _ -> invalid
 where
  invalid = Left AdminActionReadBackInvalid
  targetCoordinate target =
    (adminTargetGenerationTargetId target, adminTargetGenerationValue target)
  targetReadBackCoordinate target =
    (adminTargetReadBackTargetId target, adminTargetReadBackGeneration target)
  quotaMatches request result =
    adminQuotaServiceCode result == adminQuotaRequestServiceCode request
      && adminQuotaCode result == adminQuotaRequestCode request
      && adminQuotaRegion result == adminQuotaRequestRegion request
      && adminQuotaDesiredValue result == adminQuotaRequestDesiredValue request

validateReadBack
  :: AdminAction
  -> AdminActionReadBack
  -> Either AdminActionProtocolError ()
validateReadBack action readBack = case (action, readBack) of
  (DestroyAwsSes, AdminDestroyAwsSesReadBack value) -> do
    traverse_
      boundedEvidence
      [ adminDestroyConsumersAbsent value
      , adminDestroyProviderAbsent value
      , adminDestroySmtpIamAbsent value
      , adminDestroyRetainedCustodyAbsent value
      ]
    when (length (adminDestroyTargetGenerationsAbsent value) > 64) invalid
    traverse_ validateTargetReadBack (adminDestroyTargetGenerationsAbsent value)
  (MigrateLegacyBackend, AdminMigrateLegacyBackendReadBack value) ->
    boundedEvidence (adminLegacyReadBackSourceCoordinate value)
      >> boundedEvidence (adminLegacyReadBackDestinationCoordinate value)
      >> boundedEvidence (adminLegacyImportReference value)
      >> boundedEvidence (adminLegacyCompatibilityEvidence value)
  (ReconcileQuota, AdminReconcileQuotaReadBack items) -> do
    when (null items || length items > 64) invalid
    traverse_ validateQuota items
  _ -> invalid
 where
  invalid = Left AdminActionReadBackInvalid
  boundedEvidence value =
    if Text.null (Text.strip value) || Text.length value > 4096
      then invalid
      else Right ()
  validateQuota item =
    traverse_
      boundedEvidence
      [ adminQuotaServiceCode item
      , adminQuotaCode item
      , adminQuotaRegion item
      , adminQuotaDesiredValue item
      , adminQuotaAttemptIdentity item
      , adminQuotaProviderRequestIdentity item
      , adminQuotaStatus item
      ]
  validateTargetReadBack item = do
    boundedEvidence (adminTargetReadBackTargetId item)
    when (adminTargetReadBackGeneration item == 0) invalid
    boundedEvidence (adminTargetReadBackAbsenceEvidence item)

decodeCanonical
  :: (Serialise value)
  => Int
  -> ByteString
  -> Either AdminActionProtocolError value
decodeCanonical maximumBytes bytes
  | ByteString.length bytes > maximumBytes =
      Left (AdminActionWireTooLarge (ByteString.length bytes) maximumBytes)
  | otherwise = do
      value <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left AdminActionWireDecodeFailed
        Right decoded -> Right decoded
      unless
        (LazyByteString.toStrict (serialise value) == bytes)
        (Left AdminActionWireNonCanonical)
      pure value

validateField :: Text -> Int -> Text -> Either AdminActionProtocolError Text
validateField label maximumLength raw
  | Text.null value = invalid
  | Text.length value > maximumLength = invalid
  | Text.any (\character -> character < '\x20' || character == '\x7f' || isSpace character) value =
      invalid
  | otherwise = Right value
 where
  value = Text.strip raw
  invalid = Left (AdminActionFieldInvalid label)

validateEndpoint :: Text -> Text -> Either AdminActionProtocolError ()
validateEndpoint label endpoint = do
  value <- validateField label 2048 endpoint
  unless
    (Text.isPrefixOf "http://" value || Text.isPrefixOf "https://" value)
    (Left (AdminActionFieldInvalid label))

validateImageDigest :: Text -> Either AdminActionProtocolError Text
validateImageDigest raw = do
  value <- validateField "image-digest" 71 raw
  if Text.length value == 71
    && Text.isPrefixOf "sha256:" value
    && Text.all (\c -> isDigit c || c `elem` ['a' .. 'f']) (Text.drop 7 value)
    then Right value
    else Left AdminActionImageDigestInvalid

validateOperationId :: Text -> Either AdminActionProtocolError Text
validateOperationId raw = do
  value <- validateField "operation-id" 63 raw
  let isAlphaNumeric character = isAsciiLower character || isDigit character
  if Text.all (\character -> isAlphaNumeric character || character == '-') value
    && maybe False isAlphaNumeric (Text.find (const True) value)
    && maybe False isAlphaNumeric (Text.find (const True) (Text.reverse value))
    then Right value
    else Left (AdminActionFieldInvalid "operation-id")

sanitizeDns :: Text -> Text
sanitizeDns =
  Text.dropAround (== '-')
    . Text.map
      ( \character -> if isAsciiLower character || isDigit character || character == '-' then character else '-'
      )
    . Text.toLower

sha256Text :: ByteString -> Text
sha256Text = Text.pack . concatMap byteHex . ByteString.unpack . SHA256.hash
 where
  byteHex byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

protocolVersion :: Word16
protocolVersion = 2

maximumPermitBytes :: Int
maximumPermitBytes = 64 * 1024

maximumReceiptBytes :: Int
maximumReceiptBytes = 128 * 1024
