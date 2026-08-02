{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}

-- | Pure construction and attestation rules for permit-created, one-shot
-- credential workloads.  A ready Pod is insufficient: UID, immutable image,
-- ServiceAccount, ingress schema, permit, plan cursor, deadline, and heartbeat
-- all have to match one durable intent.
module Prodbox.Lifecycle.CredentialProvisioner.Kubernetes
  ( CredentialProvisionerJobUid
  , CredentialProvisionerPodUid
  , CredentialProvisionerServiceAccountUid
  , CredentialProvisionerImageDigest
  , CredentialProvisionerServiceAccount
  , CredentialProvisionerWorkloadError (..)
  , mkCredentialProvisionerJobUid
  , credentialProvisionerJobUidText
  , mkCredentialProvisionerPodUid
  , credentialProvisionerPodUidText
  , mkCredentialProvisionerServiceAccountUid
  , credentialProvisionerServiceAccountUidText
  , mkCredentialProvisionerImageDigest
  , credentialProvisionerImageDigestText
  , credentialProvisionerServiceAccountText
  , credentialProvisionerAwsServiceAccount
  , credentialProvisionerExternalEabServiceAccount
  , CredentialProvisionerJobIntent
  , mkCredentialProvisionerJobIntent
  , mkExternalCredentialProvisionerJobIntent
  , credentialProvisionerJobName
  , credentialProvisionerIntentImageDigest
  , credentialProvisionerIntentServiceAccount
  , credentialProvisionerIntentSchema
  , credentialProvisionerIntentPermitId
  , credentialProvisionerIntentRequestDigest
  , credentialProvisionerIntentPlanBinding
  , credentialProvisionerIntentDeadline
  , RawCredentialProvisionerPodObservation (..)
  , CredentialProvisionerJobAttestation
  , CredentialProvisionerAttestationError (..)
  , attestCredentialProvisionerPod
  , credentialProvisionerAttestedJobUid
  , credentialProvisionerAttestedPodUid
  , credentialProvisionerAttestedServiceAccountUid
  , CredentialProvisionerCleanupState (..)
  , CredentialProvisionerCleanupEvent (..)
  , CredentialProvisionerCleanupRefusal (..)
  , stepCredentialProvisionerCleanup
  )
where

import Data.Char (isAsciiLower, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( FirstReconcilePermitBinding
  , OperatorMaterialIngressSchema (..)
  , OperatorMaterialPermit
  , OperatorMaterialPermitId
  , SOperatorMaterialIngressSchema (..)
  , operatorMaterialPermitDeadline
  , operatorMaterialPermitId
  , operatorMaterialPermitIdText
  , operatorMaterialPermitPlanBinding
  , operatorMaterialPermitRequest
  , operatorMaterialPermitRequestDigest
  , operatorMaterialRequestSchema
  )
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)
import Prodbox.Lifecycle.TargetCommitIntent (TargetValueDigest)

newtype CredentialProvisionerJobUid = CredentialProvisionerJobUid Text
  deriving (Eq, Ord, Show)

newtype CredentialProvisionerPodUid = CredentialProvisionerPodUid Text
  deriving (Eq, Ord, Show)

newtype CredentialProvisionerServiceAccountUid = CredentialProvisionerServiceAccountUid Text
  deriving (Eq, Ord, Show)

newtype CredentialProvisionerImageDigest = CredentialProvisionerImageDigest Text
  deriving (Eq, Ord, Show)

newtype CredentialProvisionerServiceAccount = CredentialProvisionerServiceAccount Text
  deriving (Eq, Ord, Show)

data CredentialProvisionerWorkloadError
  = CredentialProvisionerWorkloadFieldEmpty !Text
  | CredentialProvisionerWorkloadFieldTooLong !Text !Int !Int
  | CredentialProvisionerImageDigestInvalid !Text
  deriving (Eq, Show)

mkCredentialProvisionerJobUid
  :: Text -> Either CredentialProvisionerWorkloadError CredentialProvisionerJobUid
mkCredentialProvisionerJobUid raw =
  CredentialProvisionerJobUid <$> validateField "Job UID" 256 raw

credentialProvisionerJobUidText :: CredentialProvisionerJobUid -> Text
credentialProvisionerJobUidText (CredentialProvisionerJobUid value) = value

mkCredentialProvisionerPodUid
  :: Text -> Either CredentialProvisionerWorkloadError CredentialProvisionerPodUid
mkCredentialProvisionerPodUid raw =
  CredentialProvisionerPodUid <$> validateField "Pod UID" 256 raw

credentialProvisionerPodUidText :: CredentialProvisionerPodUid -> Text
credentialProvisionerPodUidText (CredentialProvisionerPodUid value) = value

mkCredentialProvisionerServiceAccountUid
  :: Text
  -> Either CredentialProvisionerWorkloadError CredentialProvisionerServiceAccountUid
mkCredentialProvisionerServiceAccountUid raw =
  CredentialProvisionerServiceAccountUid
    <$> validateField "ServiceAccount UID" 256 raw

credentialProvisionerServiceAccountUidText
  :: CredentialProvisionerServiceAccountUid -> Text
credentialProvisionerServiceAccountUidText
  (CredentialProvisionerServiceAccountUid value) = value

mkCredentialProvisionerImageDigest
  :: Text
  -> Either CredentialProvisionerWorkloadError CredentialProvisionerImageDigest
mkCredentialProvisionerImageDigest raw = do
  value <- validateField "image digest" 256 raw
  if Text.isPrefixOf "sha256:" value
    && Text.length value == 71
    && Text.all isLowerHex (Text.drop 7 value)
    then Right (CredentialProvisionerImageDigest value)
    else Left (CredentialProvisionerImageDigestInvalid value)
 where
  isLowerHex character = isDigit character || character `elem` ['a' .. 'f']

credentialProvisionerImageDigestText :: CredentialProvisionerImageDigest -> Text
credentialProvisionerImageDigestText (CredentialProvisionerImageDigest value) = value

credentialProvisionerServiceAccountText :: CredentialProvisionerServiceAccount -> Text
credentialProvisionerServiceAccountText (CredentialProvisionerServiceAccount value) = value

credentialProvisionerAwsServiceAccount :: CredentialProvisionerServiceAccount
credentialProvisionerAwsServiceAccount =
  CredentialProvisionerServiceAccount "prodbox-credential-provisioner"

credentialProvisionerExternalEabServiceAccount :: CredentialProvisionerServiceAccount
credentialProvisionerExternalEabServiceAccount =
  CredentialProvisionerServiceAccount "prodbox-external-material-ingress"

data
  CredentialProvisionerJobIntent
    (schema :: OperatorMaterialIngressSchema)
  = CredentialProvisionerJobIntent
  { internalCredentialProvisionerIntentJobName :: !Text
  , internalCredentialProvisionerIntentImageDigest :: !CredentialProvisionerImageDigest
  , internalCredentialProvisionerIntentServiceAccount :: !CredentialProvisionerServiceAccount
  , internalCredentialProvisionerIntentSchema :: !(SOperatorMaterialIngressSchema schema)
  , internalCredentialProvisionerIntentPermitId :: !OperatorMaterialPermitId
  , internalCredentialProvisionerIntentRequestDigest :: !TargetValueDigest
  , internalCredentialProvisionerIntentPlanBinding :: !(Maybe FirstReconcilePermitBinding)
  , internalCredentialProvisionerIntentDeadline :: !AuthorityTime
  }

deriving instance Eq (CredentialProvisionerJobIntent schema)
deriving instance Show (CredentialProvisionerJobIntent schema)

mkCredentialProvisionerJobIntent
  :: CredentialProvisionerImageDigest
  -> OperatorMaterialPermit schema
  -> CredentialProvisionerJobIntent schema
mkCredentialProvisionerJobIntent imageDigest permit =
  CredentialProvisionerJobIntent
    { internalCredentialProvisionerIntentJobName =
        jobNameForPermit
          (operatorMaterialRequestSchema request)
          (operatorMaterialPermitId permit)
    , internalCredentialProvisionerIntentImageDigest = imageDigest
    , internalCredentialProvisionerIntentServiceAccount =
        serviceAccountForSchema (operatorMaterialRequestSchema request)
    , internalCredentialProvisionerIntentSchema = operatorMaterialRequestSchema request
    , internalCredentialProvisionerIntentPermitId = operatorMaterialPermitId permit
    , internalCredentialProvisionerIntentRequestDigest = operatorMaterialPermitRequestDigest permit
    , internalCredentialProvisionerIntentPlanBinding = operatorMaterialPermitPlanBinding permit
    , internalCredentialProvisionerIntentDeadline = operatorMaterialPermitDeadline permit
    }
 where
  request = operatorMaterialPermitRequest permit

-- | Construct the EAB Job intent after the Authority has durably committed
-- the secret-free request but before it signs the final Pod-UID-bound delivery
-- permit.  This is deliberately schema-specific and cannot form an AWS-admin
-- workload.
mkExternalCredentialProvisionerJobIntent
  :: CredentialProvisionerImageDigest
  -> OperatorMaterialPermitId
  -> TargetValueDigest
  -> AuthorityTime
  -> CredentialProvisionerJobIntent 'ExternalAcmeEabIngress
mkExternalCredentialProvisionerJobIntent imageDigest permitId requestDigest deadline =
  CredentialProvisionerJobIntent
    { internalCredentialProvisionerIntentJobName =
        jobNameForPermit SExternalAcmeEabIngress permitId
    , internalCredentialProvisionerIntentImageDigest = imageDigest
    , internalCredentialProvisionerIntentServiceAccount =
        credentialProvisionerExternalEabServiceAccount
    , internalCredentialProvisionerIntentSchema = SExternalAcmeEabIngress
    , internalCredentialProvisionerIntentPermitId = permitId
    , internalCredentialProvisionerIntentRequestDigest = requestDigest
    , internalCredentialProvisionerIntentPlanBinding = Nothing
    , internalCredentialProvisionerIntentDeadline = deadline
    }

credentialProvisionerJobName :: CredentialProvisionerJobIntent schema -> Text
credentialProvisionerJobName = internalCredentialProvisionerIntentJobName

credentialProvisionerIntentImageDigest
  :: CredentialProvisionerJobIntent schema -> CredentialProvisionerImageDigest
credentialProvisionerIntentImageDigest = internalCredentialProvisionerIntentImageDigest

credentialProvisionerIntentServiceAccount
  :: CredentialProvisionerJobIntent schema -> CredentialProvisionerServiceAccount
credentialProvisionerIntentServiceAccount = internalCredentialProvisionerIntentServiceAccount

credentialProvisionerIntentSchema
  :: CredentialProvisionerJobIntent schema -> SOperatorMaterialIngressSchema schema
credentialProvisionerIntentSchema = internalCredentialProvisionerIntentSchema

credentialProvisionerIntentPermitId
  :: CredentialProvisionerJobIntent schema -> OperatorMaterialPermitId
credentialProvisionerIntentPermitId = internalCredentialProvisionerIntentPermitId

credentialProvisionerIntentRequestDigest
  :: CredentialProvisionerJobIntent schema -> TargetValueDigest
credentialProvisionerIntentRequestDigest = internalCredentialProvisionerIntentRequestDigest

credentialProvisionerIntentPlanBinding
  :: CredentialProvisionerJobIntent schema -> Maybe FirstReconcilePermitBinding
credentialProvisionerIntentPlanBinding = internalCredentialProvisionerIntentPlanBinding

credentialProvisionerIntentDeadline
  :: CredentialProvisionerJobIntent schema -> AuthorityTime
credentialProvisionerIntentDeadline = internalCredentialProvisionerIntentDeadline

data RawCredentialProvisionerPodObservation = RawCredentialProvisionerPodObservation
  { rawCredentialProvisionerJobName :: !Text
  , rawCredentialProvisionerJobUid :: !Text
  , rawCredentialProvisionerPodUid :: !Text
  , rawCredentialProvisionerImageDigest :: !Text
  , rawCredentialProvisionerServiceAccount :: !Text
  , rawCredentialProvisionerServiceAccountUid :: !Text
  , rawCredentialProvisionerSchema :: !OperatorMaterialIngressSchema
  , rawCredentialProvisionerPermitId :: !Text
  , rawCredentialProvisionerRequestDigest :: !TargetValueDigest
  , rawCredentialProvisionerPlanBinding :: !(Maybe FirstReconcilePermitBinding)
  , rawCredentialProvisionerDeadline :: !AuthorityTime
  , rawCredentialProvisionerHeartbeat :: !AuthorityTime
  , rawCredentialProvisionerPhase :: !Text
  , rawCredentialProvisionerContainerReady :: !Bool
  , rawCredentialProvisionerRestartCount :: !Natural
  , rawCredentialProvisionerDeletionTimestamp :: !(Maybe Text)
  }
  deriving (Eq, Show)

data
  CredentialProvisionerJobAttestation
    (schema :: OperatorMaterialIngressSchema)
  = CredentialProvisionerJobAttestation
  { internalCredentialProvisionerAttestedJobUid :: !CredentialProvisionerJobUid
  , internalCredentialProvisionerAttestedPodUid :: !CredentialProvisionerPodUid
  , internalCredentialProvisionerAttestedServiceAccountUid
      :: !CredentialProvisionerServiceAccountUid
  , internalCredentialProvisionerAttestedIntent :: !(CredentialProvisionerJobIntent schema)
  , internalCredentialProvisionerAttestedHeartbeat :: !AuthorityTime
  }
  deriving (Eq, Show)

data CredentialProvisionerAttestationError
  = CredentialProvisionerJobNameMismatch
  | CredentialProvisionerJobUidInvalid !CredentialProvisionerWorkloadError
  | CredentialProvisionerPodUidInvalid !CredentialProvisionerWorkloadError
  | CredentialProvisionerImageMismatch
  | CredentialProvisionerServiceAccountMismatch
  | CredentialProvisionerServiceAccountUidInvalid !CredentialProvisionerWorkloadError
  | CredentialProvisionerIngressSchemaMismatch
  | CredentialProvisionerPermitMismatch
  | CredentialProvisionerRequestDigestMismatch
  | CredentialProvisionerPlanBindingMismatch
  | CredentialProvisionerDeadlineMismatch
  | CredentialProvisionerDeadlineExpired
  | CredentialProvisionerHeartbeatFromFuture
  | CredentialProvisionerHeartbeatStale
  | CredentialProvisionerPodNotRunning
  | CredentialProvisionerContainerNotReady
  | CredentialProvisionerPodRestarted
  | CredentialProvisionerPodDeleting
  deriving (Eq, Show)

attestCredentialProvisionerPod
  :: AuthorityTime
  -> Natural
  -> CredentialProvisionerJobIntent schema
  -> RawCredentialProvisionerPodObservation
  -> Either
       CredentialProvisionerAttestationError
       (CredentialProvisionerJobAttestation schema)
attestCredentialProvisionerPod now maximumHeartbeatAge intent observed = do
  unlessEqual
    (rawCredentialProvisionerJobName observed)
    (internalCredentialProvisionerIntentJobName intent)
    CredentialProvisionerJobNameMismatch
  jobUid <-
    either
      (Left . CredentialProvisionerJobUidInvalid)
      Right
      (mkCredentialProvisionerJobUid (rawCredentialProvisionerJobUid observed))
  podUid <-
    either
      (Left . CredentialProvisionerPodUidInvalid)
      Right
      (mkCredentialProvisionerPodUid (rawCredentialProvisionerPodUid observed))
  imageDigest <-
    either
      (const (Left CredentialProvisionerImageMismatch))
      Right
      (mkCredentialProvisionerImageDigest (rawCredentialProvisionerImageDigest observed))
  unlessEqual
    imageDigest
    (internalCredentialProvisionerIntentImageDigest intent)
    CredentialProvisionerImageMismatch
  unlessEqual
    (CredentialProvisionerServiceAccount (rawCredentialProvisionerServiceAccount observed))
    (internalCredentialProvisionerIntentServiceAccount intent)
    CredentialProvisionerServiceAccountMismatch
  serviceAccountUid <-
    either
      (Left . CredentialProvisionerServiceAccountUidInvalid)
      Right
      ( mkCredentialProvisionerServiceAccountUid
          (rawCredentialProvisionerServiceAccountUid observed)
      )
  unlessEqual
    (rawCredentialProvisionerSchema observed)
    (schemaValue (internalCredentialProvisionerIntentSchema intent))
    CredentialProvisionerIngressSchemaMismatch
  unlessEqual
    (rawCredentialProvisionerPermitId observed)
    (operatorMaterialPermitIdText (internalCredentialProvisionerIntentPermitId intent))
    CredentialProvisionerPermitMismatch
  unlessEqual
    (rawCredentialProvisionerRequestDigest observed)
    (internalCredentialProvisionerIntentRequestDigest intent)
    CredentialProvisionerRequestDigestMismatch
  unlessEqual
    (rawCredentialProvisionerPlanBinding observed)
    (internalCredentialProvisionerIntentPlanBinding intent)
    CredentialProvisionerPlanBindingMismatch
  unlessEqual
    (rawCredentialProvisionerDeadline observed)
    (internalCredentialProvisionerIntentDeadline intent)
    CredentialProvisionerDeadlineMismatch
  if authorityTimeMicros now >= authorityTimeMicros (internalCredentialProvisionerIntentDeadline intent)
    then Left CredentialProvisionerDeadlineExpired
    else Right ()
  if authorityTimeMicros (rawCredentialProvisionerHeartbeat observed) > authorityTimeMicros now
    then Left CredentialProvisionerHeartbeatFromFuture
    else Right ()
  if authorityTimeMicros now - authorityTimeMicros (rawCredentialProvisionerHeartbeat observed)
    > maximumHeartbeatAge
    then Left CredentialProvisionerHeartbeatStale
    else Right ()
  unlessEqual
    (rawCredentialProvisionerPhase observed)
    "Running"
    CredentialProvisionerPodNotRunning
  if rawCredentialProvisionerContainerReady observed
    then Right ()
    else Left CredentialProvisionerContainerNotReady
  unlessEqual
    (rawCredentialProvisionerRestartCount observed)
    0
    CredentialProvisionerPodRestarted
  case rawCredentialProvisionerDeletionTimestamp observed of
    Nothing -> Right ()
    Just _ -> Left CredentialProvisionerPodDeleting
  pure
    CredentialProvisionerJobAttestation
      { internalCredentialProvisionerAttestedJobUid = jobUid
      , internalCredentialProvisionerAttestedPodUid = podUid
      , internalCredentialProvisionerAttestedServiceAccountUid = serviceAccountUid
      , internalCredentialProvisionerAttestedIntent = intent
      , internalCredentialProvisionerAttestedHeartbeat = rawCredentialProvisionerHeartbeat observed
      }

credentialProvisionerAttestedJobUid
  :: CredentialProvisionerJobAttestation schema -> CredentialProvisionerJobUid
credentialProvisionerAttestedJobUid = internalCredentialProvisionerAttestedJobUid

credentialProvisionerAttestedPodUid
  :: CredentialProvisionerJobAttestation schema -> CredentialProvisionerPodUid
credentialProvisionerAttestedPodUid = internalCredentialProvisionerAttestedPodUid

credentialProvisionerAttestedServiceAccountUid
  :: CredentialProvisionerJobAttestation schema
  -> CredentialProvisionerServiceAccountUid
credentialProvisionerAttestedServiceAccountUid =
  internalCredentialProvisionerAttestedServiceAccountUid

data CredentialProvisionerCleanupState
  = CredentialProvisionerSessionActive
  | CredentialProvisionerSessionRevoked
  | CredentialProvisionerJobDeletionRequested
  | CredentialProvisionerPodAbsent
  deriving (Eq, Show)

data CredentialProvisionerCleanupEvent
  = ObserveProvisionerSessionRevoked
  | ObserveProvisionerJobDeleteAccepted
  | ObserveProvisionerPodAbsent
  deriving (Eq, Show)

data CredentialProvisionerCleanupRefusal
  = CredentialProvisionerSessionMustBeRevokedFirst
  | CredentialProvisionerJobDeleteMustPrecedeAbsence
  | CredentialProvisionerCleanupAlreadyComplete
  deriving (Eq, Show)

stepCredentialProvisionerCleanup
  :: CredentialProvisionerCleanupState
  -> CredentialProvisionerCleanupEvent
  -> Either CredentialProvisionerCleanupRefusal CredentialProvisionerCleanupState
stepCredentialProvisionerCleanup state event = case (state, event) of
  (CredentialProvisionerSessionActive, ObserveProvisionerSessionRevoked) ->
    Right CredentialProvisionerSessionRevoked
  (CredentialProvisionerSessionRevoked, ObserveProvisionerJobDeleteAccepted) ->
    Right CredentialProvisionerJobDeletionRequested
  (CredentialProvisionerJobDeletionRequested, ObserveProvisionerPodAbsent) ->
    Right CredentialProvisionerPodAbsent
  (CredentialProvisionerPodAbsent, _) -> Left CredentialProvisionerCleanupAlreadyComplete
  (_, ObserveProvisionerSessionRevoked) -> Left CredentialProvisionerSessionMustBeRevokedFirst
  (CredentialProvisionerSessionActive, _) -> Left CredentialProvisionerSessionMustBeRevokedFirst
  (_, ObserveProvisionerJobDeleteAccepted) -> Left CredentialProvisionerSessionMustBeRevokedFirst
  (_, ObserveProvisionerPodAbsent) -> Left CredentialProvisionerJobDeleteMustPrecedeAbsence

serviceAccountForSchema
  :: SOperatorMaterialIngressSchema schema -> CredentialProvisionerServiceAccount
serviceAccountForSchema schema = case schema of
  SAwsAdminProvisioningIngress -> credentialProvisionerAwsServiceAccount
  SExternalAcmeEabIngress -> credentialProvisionerExternalEabServiceAccount

schemaValue
  :: SOperatorMaterialIngressSchema schema -> OperatorMaterialIngressSchema
schemaValue schema = case schema of
  SAwsAdminProvisioningIngress -> AwsAdminProvisioningIngress
  SExternalAcmeEabIngress -> ExternalAcmeEabIngress

jobNameForPermit
  :: SOperatorMaterialIngressSchema schema -> OperatorMaterialPermitId -> Text
jobNameForPermit schema permitId =
  prefix <> Text.take 32 suffix
 where
  prefix = case schema of
    SAwsAdminProvisioningIngress -> "credential-provisioner-"
    SExternalAcmeEabIngress -> "external-material-ingress-"
  suffix =
    Text.map
      (\character -> if validDnsCharacter character then character else '-')
      (Text.toLower (operatorMaterialPermitIdText permitId))
  validDnsCharacter character = isAsciiLower character || isDigit character || character == '-'

validateField
  :: Text -> Int -> Text -> Either CredentialProvisionerWorkloadError Text
validateField label maximumLength raw
  | Text.null value = Left (CredentialProvisionerWorkloadFieldEmpty label)
  | Text.length value > maximumLength =
      Left
        (CredentialProvisionerWorkloadFieldTooLong label (Text.length value) maximumLength)
  | otherwise = Right value
 where
  value = Text.strip raw

unlessEqual :: (Eq a) => a -> a -> error -> Either error ()
unlessEqual actual expected err
  | actual == expected = Right ()
  | otherwise = Left err
