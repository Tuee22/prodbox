{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Canonical Transit-signed authorization for the one-shot AWS-admin
-- Credential Provisioner.  The permit binds the closed credential program,
-- exact request/first-reconcile cursor (or exceptional backup freeze), the
-- observed Job and Pod identities, immutable image, ServiceAccount, and an
-- absolute deadline.  No administrator credential is representable here.
module Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( CredentialIamParameters
  , mkLifecycleProviderIamParameters
  , mkAuthorityBackupIamParameters
  , mkTlsRetentionIamParameters
  , mkGatewayDnsIamParameters
  , mkHomeDns01IamParameters
  , mkAwsRunDns01IamParameters
  , mkSesSmtpIamParameters
  , credentialIamParametersClass
  , credentialIamParametersRegion
  , credentialIamParametersSesIdentity
  , credentialIamParametersProgram
  , BackupRepairFrozenBinding
  , mkBackupRepairFrozenBinding
  , backupRepairFrozenAuthorityEpoch
  , backupRepairFrozenPlanDigest
  , backupRepairFrozenObservationDigest
  , backupRepairFrozenLostGeneration
  , BackupRepairFrozenPermit
  , mkBackupRepairFrozenPermit
  , AwsAdminPermitIntent
  , AwsAdminPermitKind (..)
  , mkNormalAwsAdminPermitIntent
  , mkGenesisAwsAdminPermitIntent
  , mkBackupRepairAwsAdminPermitIntent
  , awsAdminPermitIntentKind
  , awsAdminPermitIntentPermitId
  , awsAdminPermitIntentRequestDigest
  , awsAdminPermitIntentPlanBinding
  , awsAdminPermitIntentDeadline
  , awsAdminPermitIntentCredentialClass
  , awsAdminPermitIntentAction
  , awsAdminPermitIntentOperationId
  , awsAdminPermitIntentGeneration
  , awsAdminPermitIntentIamParameters
  , awsAdminPermitIntentImageDigest
  , awsAdminPermitIntentAuthorityScope
  , awsAdminPermitIntentAuthorityEndpoint
  , awsAdminPermitIntentPreparedTarget
  , awsAdminPermitIntentTarget
  , awsAdminGenesisKindMatches
  , bindAwsAdminPermitIntentPreparedTarget
  , rebindAwsAdminPermitIntentPreparedTarget
  , awsAdminPreparedTargetReceiptDigest
  , encodeAwsAdminPermitIntent
  , decodeAwsAdminPermitIntent
  , awsAdminJobNameForPermit
  , AwsAdminJobBinding
  , mkAwsAdminJobBinding
  , awsAdminJobName
  , awsAdminJobUid
  , awsAdminJobPodName
  , awsAdminJobPodUid
  , awsAdminJobImageDigest
  , awsAdminJobServiceAccount
  , awsAdminJobServiceAccountUid
  , awsAdminJobHeartbeat
  , encodeAwsAdminJobBinding
  , decodeAwsAdminJobBinding
  , awsAdminWorkerServiceAccount
  , SignedAwsAdminPermit
  , SignedNormalOperatorMaterialPermit
  , SignedGenesisBackupPermit
  , SignedBackupRepairFrozenPermit
  , SomeSignedAwsAdminPermit (..)
  , withSomeSignedAwsAdminPermit
  , awsAdminPermitSigningPayload
  , mkSomeSignedAwsAdminPermit
  , mkSignedNormalOperatorMaterialPermit
  , mkSignedGenesisBackupPermit
  , mkSignedBackupRepairFrozenPermit
  , verifySignedAwsAdminPermit
  , encodeSignedAwsAdminPermit
  , decodeSignedAwsAdminPermit
  , signedAwsAdminPermitIntent
  , signedAwsAdminPermitBinding
  , signedAwsAdminPermitSignerGeneration
  , AwsAdminPermitError (..)
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower, isControl, isDigit, isSpace)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16, Word8)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity (..)
  , TargetSecretId (..)
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetAgentIdentity
  , mkTargetAgentIdentity
  , targetAgentIdentityText
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( GenesisPlan (..)
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (..)
  , FirstReconcilePermitBinding
  , FirstReconcilePlanMember
  , GenesisBackupPermit
  , OperatorMaterialAction (..)
  , OperatorMaterialIngressSchema (AwsAdminProvisioningIngress)
  , OperatorMaterialOperationId
  , OperatorMaterialPermit
  , OperatorMaterialPermitId
  , awsCredentialDescriptor
  , awsOperatorMaterialRequestDigest
  , firstReconcilePermitMemberDigest
  , firstReconcilePermitMemberIndex
  , firstReconcilePermitPlanDigest
  , firstReconcilePermitPriorReceiptDigest
  , firstReconcilePlanMemberDigest
  , firstReconcilePlanMemberIndex
  , genesisBackupPermitBindingDigest
  , mkFirstReconcilePermitBinding
  , mkOperatorMaterialOperationId
  , mkOperatorMaterialPermitId
  , operatorMaterialOperationIdText
  , operatorMaterialPermitDeadline
  , operatorMaterialPermitId
  , operatorMaterialPermitIdText
  , operatorMaterialPermitPlanBinding
  , operatorMaterialPermitRequest
  , operatorMaterialPermitRequestDigest
  , operatorMaterialRequestAction
  , operatorMaterialRequestAwsClass
  , operatorMaterialRequestGeneration
  , operatorMaterialRequestOperationId
  , withGenesisBackupOperatorPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTarget
  ( PreparedCredentialTargetObservation
  , mkPreparedCredentialTargetObservation
  , preparedCredentialTargetDeadline
  , preparedCredentialTargetFence
  , preparedCredentialTargetGeneration
  , preparedCredentialTargetId
  , preparedCredentialTargetOwnerNonce
  , preparedCredentialTargetPlanBinding
  , preparedCredentialTargetReceiptDigest
  , preparedCredentialTargetRequestDigest
  , preparedCredentialTargetSelectedAgent
  )
import Prodbox.Lifecycle.CredentialProvisioner.ProductionIam
  ( CredentialIamProgram
  , ProductionIamError
  , mkAuthorityBackupIamProgram
  , mkAwsRunDns01IamProgram
  , mkGatewayDnsIamProgram
  , mkHomeDns01IamProgram
  , mkLifecycleProviderIamProgram
  , mkSesSmtpIamProgram
  , mkTlsRetentionIamProgram
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  , authorityTimeMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  , credentialGenerationValue
  , mkCredentialGeneration
  , mkTargetValueDigest
  , sha256TargetValueDigest
  , targetValueDigestText
  )

-- | Exact non-secret parameter vocabulary for all seven registered programs.
-- Constructors stay private so every value has already passed the production
-- IAM/S3 program validator.
data CredentialIamParameters
  = LifecycleProviderIamParameters !Text !Text !Text
  | AuthorityBackupIamParameters !Text !Text ![Text]
  | TlsRetentionIamParameters !Text !Text ![Text]
  | GatewayDnsIamParameters !Text !Text
  | HomeDns01IamParameters !Text !Text
  | AwsRunDns01IamParameters !Text !Text
  | SesSmtpIamParameters !Text !Text !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkLifecycleProviderIamParameters
  :: Text -> Text -> Text -> Either ProductionIamError CredentialIamParameters
mkLifecycleProviderIamParameters region accountId roleName = do
  _ <- mkLifecycleProviderIamProgram region accountId roleName
  pure
    ( LifecycleProviderIamParameters
        (Text.strip region)
        (Text.strip accountId)
        (Text.strip roleName)
    )

mkAuthorityBackupIamParameters
  :: Text -> Text -> [Text] -> Either ProductionIamError CredentialIamParameters
mkAuthorityBackupIamParameters region bucket prefixes = do
  _ <- mkAuthorityBackupIamProgram region bucket prefixes
  pure
    ( AuthorityBackupIamParameters
        (Text.strip region)
        (Text.strip bucket)
        (sort (Text.strip <$> prefixes))
    )

mkTlsRetentionIamParameters
  :: Text -> Text -> [Text] -> Either ProductionIamError CredentialIamParameters
mkTlsRetentionIamParameters region bucket prefixes = do
  _ <- mkTlsRetentionIamProgram region bucket prefixes
  pure
    ( TlsRetentionIamParameters
        (Text.strip region)
        (Text.strip bucket)
        (sort (Text.strip <$> prefixes))
    )

mkGatewayDnsIamParameters
  :: Text -> Text -> Either ProductionIamError CredentialIamParameters
mkGatewayDnsIamParameters region zoneId = do
  _ <- mkGatewayDnsIamProgram region zoneId
  pure (GatewayDnsIamParameters (Text.strip region) (normalizeZoneId zoneId))

mkHomeDns01IamParameters
  :: Text -> Text -> Either ProductionIamError CredentialIamParameters
mkHomeDns01IamParameters region zoneId = do
  _ <- mkHomeDns01IamProgram region zoneId
  pure (HomeDns01IamParameters (Text.strip region) (normalizeZoneId zoneId))

mkAwsRunDns01IamParameters
  :: Text -> Text -> Either ProductionIamError CredentialIamParameters
mkAwsRunDns01IamParameters region zoneId = do
  _ <- mkAwsRunDns01IamProgram region zoneId
  pure (AwsRunDns01IamParameters (Text.strip region) (normalizeZoneId zoneId))

mkSesSmtpIamParameters
  :: Text -> Text -> Text -> Either ProductionIamError CredentialIamParameters
mkSesSmtpIamParameters region accountId identity = do
  _ <- mkSesSmtpIamProgram region accountId identity
  pure
    ( SesSmtpIamParameters
        (Text.strip region)
        (Text.strip accountId)
        (Text.strip identity)
    )

credentialIamParametersClass :: CredentialIamParameters -> AwsCredentialClass
credentialIamParametersClass parameters = case parameters of
  LifecycleProviderIamParameters {} -> LifecycleProviderCredential
  AuthorityBackupIamParameters {} -> AuthorityBackupStoreCredential
  TlsRetentionIamParameters {} -> TlsRetentionStoreCredential
  GatewayDnsIamParameters {} -> GatewayDnsCredential
  HomeDns01IamParameters {} -> HomeCertManagerDns01Credential
  AwsRunDns01IamParameters {} -> AwsRunCertManagerDns01Credential
  SesSmtpIamParameters {} -> SesSmtpRetainedCustodyCredential

credentialIamParametersRegion :: CredentialIamParameters -> Text
credentialIamParametersRegion parameters = case parameters of
  LifecycleProviderIamParameters region _ _ -> region
  AuthorityBackupIamParameters region _ _ -> region
  TlsRetentionIamParameters region _ _ -> region
  GatewayDnsIamParameters region _ -> region
  HomeDns01IamParameters region _ -> region
  AwsRunDns01IamParameters region _ -> region
  SesSmtpIamParameters region _ _ -> region

credentialIamParametersSesIdentity :: CredentialIamParameters -> Maybe Text
credentialIamParametersSesIdentity parameters = case parameters of
  SesSmtpIamParameters _ _ identity -> Just identity
  _ -> Nothing

credentialIamParametersProgram
  :: CredentialIamParameters -> Either ProductionIamError CredentialIamProgram
credentialIamParametersProgram parameters = case parameters of
  LifecycleProviderIamParameters region accountId roleName ->
    mkLifecycleProviderIamProgram region accountId roleName
  AuthorityBackupIamParameters region bucket prefixes ->
    mkAuthorityBackupIamProgram region bucket prefixes
  TlsRetentionIamParameters region bucket prefixes ->
    mkTlsRetentionIamProgram region bucket prefixes
  GatewayDnsIamParameters region zoneId -> mkGatewayDnsIamProgram region zoneId
  HomeDns01IamParameters region zoneId -> mkHomeDns01IamProgram region zoneId
  AwsRunDns01IamParameters region zoneId -> mkAwsRunDns01IamProgram region zoneId
  SesSmtpIamParameters region accountId identity ->
    mkSesSmtpIamProgram region accountId identity

normalizeZoneId :: Text -> Text
normalizeZoneId raw =
  Text.dropWhile
    (== '/')
    (maybe value id (Text.stripPrefix "/hostedzone/" value))
 where
  value = Text.strip raw

data BackupRepairFrozenBinding = BackupRepairFrozenBinding
  { internalBackupRepairFrozenAuthorityEpoch :: !Natural
  , internalBackupRepairFrozenPlanDigest :: !TargetValueDigest
  , internalBackupRepairFrozenObservationDigest :: !TargetValueDigest
  , internalBackupRepairFrozenLostGeneration :: !CredentialGeneration
  }
  deriving stock (Eq, Show)

mkBackupRepairFrozenBinding
  :: Natural
  -> TargetValueDigest
  -> TargetValueDigest
  -> CredentialGeneration
  -> Either AwsAdminPermitError BackupRepairFrozenBinding
mkBackupRepairFrozenBinding epoch planDigest observationDigest generation = do
  when (epoch == 0) (Left AwsAdminPermitRepairBindingInvalid)
  pure
    BackupRepairFrozenBinding
      { internalBackupRepairFrozenAuthorityEpoch = epoch
      , internalBackupRepairFrozenPlanDigest = planDigest
      , internalBackupRepairFrozenObservationDigest = observationDigest
      , internalBackupRepairFrozenLostGeneration = generation
      }

backupRepairFrozenAuthorityEpoch :: BackupRepairFrozenBinding -> Natural
backupRepairFrozenAuthorityEpoch = internalBackupRepairFrozenAuthorityEpoch

backupRepairFrozenPlanDigest :: BackupRepairFrozenBinding -> TargetValueDigest
backupRepairFrozenPlanDigest = internalBackupRepairFrozenPlanDigest

backupRepairFrozenObservationDigest :: BackupRepairFrozenBinding -> TargetValueDigest
backupRepairFrozenObservationDigest = internalBackupRepairFrozenObservationDigest

backupRepairFrozenLostGeneration :: BackupRepairFrozenBinding -> CredentialGeneration
backupRepairFrozenLostGeneration = internalBackupRepairFrozenLostGeneration

data BackupRepairFrozenPermit = BackupRepairFrozenPermit
  { internalBackupRepairFrozenBinding :: !BackupRepairFrozenBinding
  , internalBackupRepairOperatorPermit
      :: !(OperatorMaterialPermit 'AwsAdminProvisioningIngress)
  }
  deriving stock (Eq, Show)

mkBackupRepairFrozenPermit
  :: BackupRepairFrozenBinding
  -> OperatorMaterialPermit 'AwsAdminProvisioningIngress
  -> Either AwsAdminPermitError BackupRepairFrozenPermit
mkBackupRepairFrozenPermit binding permit = do
  let request = operatorMaterialPermitRequest permit
  unless
    ( operatorMaterialRequestAwsClass request == Just AuthorityBackupStoreCredential
        && operatorMaterialRequestAction request == RotateOperatorMaterial
        && operatorMaterialPermitPlanBinding permit == Nothing
    )
    (Left AwsAdminPermitRepairRequestInvalid)
  pure (BackupRepairFrozenPermit binding permit)

data AwsAdminPermitKind
  = NormalOperatorMaterialKind
  | GenesisBackupKind !TargetValueDigest
  | BackupRepairFrozenKind !BackupRepairFrozenBinding
  deriving stock (Eq, Show)

data AwsAdminPermitIntent = AwsAdminPermitIntent
  { internalAwsAdminIntentKind :: !AwsAdminPermitKind
  , internalAwsAdminIntentPermitId :: !OperatorMaterialPermitId
  , internalAwsAdminIntentCredentialClass :: !AwsCredentialClass
  , internalAwsAdminIntentAction :: !OperatorMaterialAction
  , internalAwsAdminIntentOperationId :: !OperatorMaterialOperationId
  , internalAwsAdminIntentGeneration :: !CredentialGeneration
  , internalAwsAdminIntentRequestDigest :: !TargetValueDigest
  , internalAwsAdminIntentPlanBinding :: !(Maybe FirstReconcilePermitBinding)
  , internalAwsAdminIntentDeadline :: !AuthorityTime
  , internalAwsAdminIntentIamParameters :: !CredentialIamParameters
  , internalAwsAdminIntentImageDigest :: !Text
  , internalAwsAdminIntentAuthorityScope :: !Text
  , internalAwsAdminIntentAuthorityEndpoint :: !Text
  , internalAwsAdminIntentPreparedTarget :: !PreparedCredentialTargetObservation
  }
  deriving stock (Eq, Show)

mkNormalAwsAdminPermitIntent
  :: OperatorMaterialPermit 'AwsAdminProvisioningIngress
  -> CredentialIamParameters
  -> Text
  -> Text
  -> Text
  -> PreparedCredentialTargetObservation
  -> Either AwsAdminPermitError AwsAdminPermitIntent
mkNormalAwsAdminPermitIntent permit parameters imageDigest authorityScope authorityEndpoint prepared =
  intentFromOperatorPermit
    NormalOperatorMaterialKind
    permit
    parameters
    imageDigest
    authorityScope
    authorityEndpoint
    prepared

mkGenesisAwsAdminPermitIntent
  :: GenesisBackupPermit
  -> CredentialIamParameters
  -> Text
  -> Text
  -> Text
  -> PreparedCredentialTargetObservation
  -> Either AwsAdminPermitError AwsAdminPermitIntent
mkGenesisAwsAdminPermitIntent genesis parameters imageDigest authorityScope authorityEndpoint prepared =
  withGenesisBackupOperatorPermit genesis $ \permit ->
    intentFromOperatorPermit
      (GenesisBackupKind (genesisBackupPermitBindingDigest genesis))
      permit
      parameters
      imageDigest
      authorityScope
      authorityEndpoint
      prepared

mkBackupRepairAwsAdminPermitIntent
  :: BackupRepairFrozenPermit
  -> CredentialIamParameters
  -> Text
  -> Text
  -> Text
  -> PreparedCredentialTargetObservation
  -> Either AwsAdminPermitError AwsAdminPermitIntent
mkBackupRepairAwsAdminPermitIntent repair parameters imageDigest authorityScope authorityEndpoint prepared =
  intentFromOperatorPermit
    (BackupRepairFrozenKind (internalBackupRepairFrozenBinding repair))
    (internalBackupRepairOperatorPermit repair)
    parameters
    imageDigest
    authorityScope
    authorityEndpoint
    prepared

intentFromOperatorPermit
  :: AwsAdminPermitKind
  -> OperatorMaterialPermit 'AwsAdminProvisioningIngress
  -> CredentialIamParameters
  -> Text
  -> Text
  -> Text
  -> PreparedCredentialTargetObservation
  -> Either AwsAdminPermitError AwsAdminPermitIntent
intentFromOperatorPermit kind permit parameters rawImageDigest rawAuthorityScope rawAuthorityEndpoint prepared = do
  credentialClass <-
    maybe (Left AwsAdminPermitRequestInvalid) Right (operatorMaterialRequestAwsClass request)
  unless
    (credentialClass == credentialIamParametersClass parameters)
    (Left AwsAdminPermitIamClassMismatch)
  let digest =
        awsOperatorMaterialRequestDigest
          credentialClass
          (operatorMaterialRequestAction request)
          (operatorMaterialRequestOperationId request)
          (operatorMaterialRequestGeneration request)
  unless
    (digest == operatorMaterialPermitRequestDigest permit)
    (Left AwsAdminPermitRequestDigestMismatch)
  validateKindRequest kind credentialClass (operatorMaterialRequestAction request)
  imageDigest <- validateImageDigest rawImageDigest
  authorityScope <- validateField "authority-scope" 256 rawAuthorityScope
  authorityEndpoint <- validateAuthorityEndpoint rawAuthorityEndpoint
  let intent =
        AwsAdminPermitIntent
          { internalAwsAdminIntentKind = kind
          , internalAwsAdminIntentPermitId = operatorMaterialPermitId permit
          , internalAwsAdminIntentCredentialClass = credentialClass
          , internalAwsAdminIntentAction = operatorMaterialRequestAction request
          , internalAwsAdminIntentOperationId = operatorMaterialRequestOperationId request
          , internalAwsAdminIntentGeneration = operatorMaterialRequestGeneration request
          , internalAwsAdminIntentRequestDigest = digest
          , internalAwsAdminIntentPlanBinding = operatorMaterialPermitPlanBinding permit
          , internalAwsAdminIntentDeadline = operatorMaterialPermitDeadline permit
          , internalAwsAdminIntentIamParameters = parameters
          , internalAwsAdminIntentImageDigest = imageDigest
          , internalAwsAdminIntentAuthorityScope = authorityScope
          , internalAwsAdminIntentAuthorityEndpoint = authorityEndpoint
          , internalAwsAdminIntentPreparedTarget = prepared
          }
  validateIntent intent
  pure intent
 where
  request = operatorMaterialPermitRequest permit

validateKindRequest
  :: AwsAdminPermitKind
  -> AwsCredentialClass
  -> OperatorMaterialAction
  -> Either AwsAdminPermitError ()
validateKindRequest kind credentialClass action = case kind of
  NormalOperatorMaterialKind ->
    when
      (credentialClass == AuthorityBackupStoreCredential && action == InstallOperatorMaterial)
      (Left AwsAdminPermitKindMismatch)
  GenesisBackupKind _ ->
    unless
      (credentialClass == AuthorityBackupStoreCredential && action == InstallOperatorMaterial)
      (Left AwsAdminPermitKindMismatch)
  BackupRepairFrozenKind _ ->
    unless
      (credentialClass == AuthorityBackupStoreCredential && action == RotateOperatorMaterial)
      (Left AwsAdminPermitKindMismatch)

awsAdminPermitIntentKind :: AwsAdminPermitIntent -> AwsAdminPermitKind
awsAdminPermitIntentKind = internalAwsAdminIntentKind

awsAdminPermitIntentPermitId :: AwsAdminPermitIntent -> OperatorMaterialPermitId
awsAdminPermitIntentPermitId = internalAwsAdminIntentPermitId

awsAdminPermitIntentRequestDigest :: AwsAdminPermitIntent -> TargetValueDigest
awsAdminPermitIntentRequestDigest = internalAwsAdminIntentRequestDigest

awsAdminPermitIntentPlanBinding
  :: AwsAdminPermitIntent -> Maybe FirstReconcilePermitBinding
awsAdminPermitIntentPlanBinding = internalAwsAdminIntentPlanBinding

awsAdminPermitIntentDeadline :: AwsAdminPermitIntent -> AuthorityTime
awsAdminPermitIntentDeadline = internalAwsAdminIntentDeadline

awsAdminPermitIntentCredentialClass :: AwsAdminPermitIntent -> AwsCredentialClass
awsAdminPermitIntentCredentialClass = internalAwsAdminIntentCredentialClass

awsAdminPermitIntentAction :: AwsAdminPermitIntent -> OperatorMaterialAction
awsAdminPermitIntentAction = internalAwsAdminIntentAction

awsAdminPermitIntentOperationId :: AwsAdminPermitIntent -> OperatorMaterialOperationId
awsAdminPermitIntentOperationId = internalAwsAdminIntentOperationId

awsAdminPermitIntentGeneration :: AwsAdminPermitIntent -> CredentialGeneration
awsAdminPermitIntentGeneration = internalAwsAdminIntentGeneration

awsAdminPermitIntentIamParameters :: AwsAdminPermitIntent -> CredentialIamParameters
awsAdminPermitIntentIamParameters = internalAwsAdminIntentIamParameters

awsAdminPermitIntentImageDigest :: AwsAdminPermitIntent -> Text
awsAdminPermitIntentImageDigest = internalAwsAdminIntentImageDigest

awsAdminPermitIntentAuthorityScope :: AwsAdminPermitIntent -> Text
awsAdminPermitIntentAuthorityScope = internalAwsAdminIntentAuthorityScope

awsAdminPermitIntentAuthorityEndpoint :: AwsAdminPermitIntent -> Text
awsAdminPermitIntentAuthorityEndpoint = internalAwsAdminIntentAuthorityEndpoint

awsAdminPermitIntentPreparedTarget
  :: AwsAdminPermitIntent -> PreparedCredentialTargetObservation
awsAdminPermitIntentPreparedTarget = internalAwsAdminIntentPreparedTarget

awsAdminPermitIntentTarget :: AwsAdminPermitIntent -> TargetSecretId
awsAdminPermitIntentTarget = targetForClass . awsAdminPermitIntentCredentialClass

-- | Check the exceptional genesis kind against the exact retained genesis
-- plan and first-reconcile member.  The kind digest deliberately binds the
-- request and deadline but no raw credential material.
awsAdminGenesisKindMatches
  :: GenesisPlan
  -> FirstReconcilePlanMember
  -> AwsAdminPermitIntent
  -> Bool
awsAdminGenesisKindMatches genesisPlan member intent =
  case awsAdminPermitIntentKind intent of
    GenesisBackupKind actual -> actual == genesisKindDigest genesisPlan member intent
    _ -> False

-- | Authority-only canonicalization of a caller draft.  The retained
-- admission state and first-reconcile journal choose the plan cursor,
-- deadline, owner/fence, and exact registered Agent.  The resulting prepared
-- observation is constructed here so its receipt digest is calculated from
-- the same canonical intent that is subsequently validated and signed.
bindAwsAdminPermitIntentPreparedTarget
  :: Maybe (GenesisPlan, FirstReconcilePlanMember)
  -> Maybe FirstReconcilePermitBinding
  -> AuthorityTime
  -> Text
  -> Natural
  -> TargetAgentIdentity
  -> AwsAdminPermitIntent
  -> Either AwsAdminPermitError AwsAdminPermitIntent
bindAwsAdminPermitIntentPreparedTarget genesisContext planBinding deadline ownerNonce fence selectedAgent draft = do
  canonicalKind <- case awsAdminPermitIntentKind draft of
    NormalOperatorMaterialKind -> do
      unless (genesisContext == Nothing) (Left AwsAdminPermitKindMismatch)
      pure NormalOperatorMaterialKind
    GenesisBackupKind _ -> case genesisContext of
      Nothing -> Left AwsAdminPermitKindMismatch
      Just (genesisPlan, member) ->
        pure (GenesisBackupKind (genesisKindDigest genesisPlan member core))
    BackupRepairFrozenKind repair -> do
      unless (genesisContext == Nothing) (Left AwsAdminPermitKindMismatch)
      pure (BackupRepairFrozenKind repair)
  let canonicalCore = core {internalAwsAdminIntentKind = canonicalKind}
      receiptDigest =
        awsAdminPreparedTargetReceiptDigest
          ownerNonce
          fence
          selectedAgent
          canonicalCore
  prepared <-
    first
      (const AwsAdminPermitPreparedTargetMismatch)
      ( mkPreparedCredentialTargetObservation
          ownerNonce
          fence
          selectedAgent
          (awsAdminPermitIntentTarget canonicalCore)
          (awsAdminPermitIntentGeneration canonicalCore)
          (awsAdminPermitIntentRequestDigest canonicalCore)
          receiptDigest
          planBinding
          deadline
      )
  let canonical =
        canonicalCore
          { internalAwsAdminIntentPreparedTarget = prepared
          }
  validateIntent canonical
  pure canonical
 where
  core =
    draft
      { internalAwsAdminIntentPlanBinding = planBinding
      , internalAwsAdminIntentDeadline = deadline
      }

genesisKindDigest
  :: GenesisPlan
  -> FirstReconcilePlanMember
  -> AwsAdminPermitIntent
  -> TargetValueDigest
genesisKindDigest genesisPlan member intent =
  sha256TargetValueDigest
    ( TextEncoding.encodeUtf8
        ( Text.intercalate
            "|"
            [ genesisPlanDigest genesisPlan
            , genesisPlanBackupStoreCoordinate genesisPlan
            , Text.pack
                (show (awsCredentialDescriptor AuthorityBackupStoreCredential))
            , Text.pack (show (firstReconcilePlanMemberIndex member))
            , targetValueDigestText (firstReconcilePlanMemberDigest member)
            , targetValueDigestText (awsAdminPermitIntentRequestDigest intent)
            , Text.pack
                ( show
                    (authorityTimeMicros (awsAdminPermitIntentDeadline intent))
                )
            ]
        )
    )

-- | Replace the caller's non-authoritative prepared-target draft with the
-- exact CAS/read-back observation produced by the Lifecycle Authority.  The
-- complete intent is validated again, so the replacement cannot change the
-- request, generation, plan cursor, target, or deadline.
rebindAwsAdminPermitIntentPreparedTarget
  :: PreparedCredentialTargetObservation
  -> AwsAdminPermitIntent
  -> Either AwsAdminPermitError AwsAdminPermitIntent
rebindAwsAdminPermitIntentPreparedTarget prepared intent = do
  let rebound =
        intent
          { internalAwsAdminIntentPreparedTarget = prepared
          }
  validateIntent rebound
  pure rebound

data AwsAdminPreparedTargetReceiptEnvelope = AwsAdminPreparedTargetReceiptEnvelope
  { wirePreparedReceiptDomain :: !Text
  , wirePreparedReceiptVersion :: !Word16
  , wirePreparedReceiptKind :: !WirePermitKind
  , wirePreparedReceiptPermitId :: !Text
  , wirePreparedReceiptCredentialClass :: !Word8
  , wirePreparedReceiptAction :: !Word8
  , wirePreparedReceiptOperationId :: !Text
  , wirePreparedReceiptGeneration :: !Natural
  , wirePreparedReceiptRequestDigest :: !Text
  , wirePreparedReceiptPlanBinding :: !(Maybe WirePlanBinding)
  , wirePreparedReceiptDeadlineMicros :: !Natural
  , wirePreparedReceiptIamParameters :: !CredentialIamParameters
  , wirePreparedReceiptImageDigest :: !Text
  , wirePreparedReceiptAuthorityScope :: !Text
  , wirePreparedReceiptAuthorityEndpoint :: !Text
  , wirePreparedReceiptOwnerNonce :: !Text
  , wirePreparedReceiptFence :: !Natural
  , wirePreparedReceiptSelectedAgent :: !Text
  , wirePreparedReceiptTarget :: !TargetSecretId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Digest of the Authority-derived prepared-target receipt.  The envelope
-- deliberately excludes the caller-carried prepared-target draft and binds
-- every other canonical intent field plus the Authority-selected owner,
-- fence, Agent, and closed target.
awsAdminPreparedTargetReceiptDigest
  :: Text
  -> Natural
  -> TargetAgentIdentity
  -> AwsAdminPermitIntent
  -> TargetValueDigest
awsAdminPreparedTargetReceiptDigest ownerNonce fence selectedAgent intent =
  sha256TargetValueDigest
    ( LazyByteString.toStrict
        ( serialise
            AwsAdminPreparedTargetReceiptEnvelope
              { wirePreparedReceiptDomain =
                  "prodbox-aws-admin-prepared-target-receipt-v1"
              , wirePreparedReceiptVersion = 1
              , wirePreparedReceiptKind =
                  kindToWire (awsAdminPermitIntentKind intent)
              , wirePreparedReceiptPermitId =
                  operatorMaterialPermitIdText
                    (awsAdminPermitIntentPermitId intent)
              , wirePreparedReceiptCredentialClass =
                  fromIntegral
                    (fromEnum (awsAdminPermitIntentCredentialClass intent) + 1)
              , wirePreparedReceiptAction =
                  fromIntegral (fromEnum (awsAdminPermitIntentAction intent) + 1)
              , wirePreparedReceiptOperationId =
                  operatorMaterialOperationIdText
                    (awsAdminPermitIntentOperationId intent)
              , wirePreparedReceiptGeneration =
                  credentialGenerationValue
                    (awsAdminPermitIntentGeneration intent)
              , wirePreparedReceiptRequestDigest =
                  targetValueDigestText
                    (awsAdminPermitIntentRequestDigest intent)
              , wirePreparedReceiptPlanBinding =
                  planBindingToWire <$> awsAdminPermitIntentPlanBinding intent
              , wirePreparedReceiptDeadlineMicros =
                  authorityTimeMicros (awsAdminPermitIntentDeadline intent)
              , wirePreparedReceiptIamParameters =
                  awsAdminPermitIntentIamParameters intent
              , wirePreparedReceiptImageDigest =
                  awsAdminPermitIntentImageDigest intent
              , wirePreparedReceiptAuthorityScope =
                  awsAdminPermitIntentAuthorityScope intent
              , wirePreparedReceiptAuthorityEndpoint =
                  awsAdminPermitIntentAuthorityEndpoint intent
              , wirePreparedReceiptOwnerNonce = ownerNonce
              , wirePreparedReceiptFence = fence
              , wirePreparedReceiptSelectedAgent =
                  targetAgentIdentityText selectedAgent
              , wirePreparedReceiptTarget = awsAdminPermitIntentTarget intent
              }
        )
    )

awsAdminWorkerServiceAccount :: Text
awsAdminWorkerServiceAccount = "prodbox-credential-provisioner"

awsAdminJobNameForPermit :: OperatorMaterialPermitId -> Text
awsAdminJobNameForPermit permitId =
  "credential-provisioner-" <> Text.take 32 suffix
 where
  suffix = Text.map sanitize (Text.toLower (operatorMaterialPermitIdText permitId))
  sanitize character
    | isAsciiLower character || isDigit character || character == '-' = character
    | otherwise = '-'

data AwsAdminJobBinding = AwsAdminJobBinding
  { internalAwsAdminJobName :: !Text
  , internalAwsAdminJobUid :: !Text
  , internalAwsAdminJobPodName :: !Text
  , internalAwsAdminJobPodUid :: !Text
  , internalAwsAdminJobImageDigest :: !Text
  , internalAwsAdminJobServiceAccount :: !Text
  , internalAwsAdminJobServiceAccountUid :: !Text
  , internalAwsAdminJobHeartbeatMicros :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkAwsAdminJobBinding
  :: AwsAdminPermitIntent
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> AuthorityTime
  -> Either AwsAdminPermitError AwsAdminJobBinding
mkAwsAdminJobBinding intent jobName jobUid podName podUid imageDigest serviceAccount serviceAccountUid heartbeat = do
  validJob <- validateField "job-name" 63 jobName
  validJobUid <- validateField "job-uid" 256 jobUid
  validPodName <- validateField "pod-name" 253 podName
  validPodUid <- validateField "pod-uid" 256 podUid
  validImage <- validateImageDigest imageDigest
  validServiceAccount <- validateField "service-account" 253 serviceAccount
  validServiceAccountUid <- validateField "service-account-uid" 256 serviceAccountUid
  let heartbeatMicros = authorityTimeMicros heartbeat
  unless
    ( validJob == awsAdminJobNameForPermit (awsAdminPermitIntentPermitId intent)
        && validImage == awsAdminPermitIntentImageDigest intent
        && validServiceAccount == awsAdminWorkerServiceAccount
        && heartbeatMicros > 0
        && heartbeatMicros < authorityTimeMicros (awsAdminPermitIntentDeadline intent)
    )
    (Left AwsAdminPermitJobBindingMismatch)
  pure
    AwsAdminJobBinding
      { internalAwsAdminJobName = validJob
      , internalAwsAdminJobUid = validJobUid
      , internalAwsAdminJobPodName = validPodName
      , internalAwsAdminJobPodUid = validPodUid
      , internalAwsAdminJobImageDigest = validImage
      , internalAwsAdminJobServiceAccount = validServiceAccount
      , internalAwsAdminJobServiceAccountUid = validServiceAccountUid
      , internalAwsAdminJobHeartbeatMicros = heartbeatMicros
      }

awsAdminJobName :: AwsAdminJobBinding -> Text
awsAdminJobName = internalAwsAdminJobName

awsAdminJobUid :: AwsAdminJobBinding -> Text
awsAdminJobUid = internalAwsAdminJobUid

awsAdminJobPodName :: AwsAdminJobBinding -> Text
awsAdminJobPodName = internalAwsAdminJobPodName

awsAdminJobPodUid :: AwsAdminJobBinding -> Text
awsAdminJobPodUid = internalAwsAdminJobPodUid

awsAdminJobImageDigest :: AwsAdminJobBinding -> Text
awsAdminJobImageDigest = internalAwsAdminJobImageDigest

awsAdminJobServiceAccount :: AwsAdminJobBinding -> Text
awsAdminJobServiceAccount = internalAwsAdminJobServiceAccount

awsAdminJobServiceAccountUid :: AwsAdminJobBinding -> Text
awsAdminJobServiceAccountUid = internalAwsAdminJobServiceAccountUid

awsAdminJobHeartbeat :: AwsAdminJobBinding -> AuthorityTime
awsAdminJobHeartbeat = authorityTimeFromMicros . internalAwsAdminJobHeartbeatMicros

data WirePlanBinding = WirePlanBinding
  { wirePlanDigest :: !Text
  , wirePlanMemberIndex :: !Natural
  , wirePlanMemberDigest :: !Text
  , wirePlanPriorReceiptDigest :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WireRepairBinding = WireRepairBinding
  { wireRepairAuthorityEpoch :: !Natural
  , wireRepairPlanDigest :: !Text
  , wireRepairObservationDigest :: !Text
  , wireRepairLostGeneration :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WirePermitKind
  = WireNormalPermit
  | WireGenesisPermit !Text
  | WireBackupRepairFrozenPermit !WireRepairBinding
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WirePreparedCredentialTarget = WirePreparedCredentialTarget
  { wirePreparedOwnerNonce :: !Text
  , wirePreparedFence :: !Natural
  , wirePreparedSelectedAgent :: !Text
  , wirePreparedTarget :: !TargetSecretId
  , wirePreparedGeneration :: !Natural
  , wirePreparedRequestDigest :: !Text
  , wirePreparedReceiptDigest :: !Text
  , wirePreparedPlanBinding :: !(Maybe WirePlanBinding)
  , wirePreparedDeadlineMicros :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WireAwsAdminIntent = WireAwsAdminIntent
  { wireIntentKind :: !WirePermitKind
  , wireIntentPermitId :: !Text
  , wireIntentCredentialClass :: !Word8
  , wireIntentAction :: !Word8
  , wireIntentOperationId :: !Text
  , wireIntentGeneration :: !Natural
  , wireIntentRequestDigest :: !Text
  , wireIntentPlanBinding :: !(Maybe WirePlanBinding)
  , wireIntentDeadlineMicros :: !Natural
  , wireIntentIamParameters :: !CredentialIamParameters
  , wireIntentImageDigest :: !Text
  , wireIntentAuthorityScope :: !Text
  , wireIntentAuthorityEndpoint :: !Text
  , wireIntentPreparedTarget :: !WirePreparedCredentialTarget
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AwsAdminSigningEnvelope = AwsAdminSigningEnvelope
  { wireSigningDomain :: !Text
  , wireSigningVersion :: !Word16
  , wireSigningSignerGeneration :: !Natural
  , wireSigningIntent :: !WireAwsAdminIntent
  , wireSigningJobBinding :: !AwsAdminJobBinding
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WireSignedAwsAdminPermit = WireSignedAwsAdminPermit
  { wireSignedVersion :: !Word16
  , wireSignedSignerGeneration :: !Natural
  , wireSignedIntent :: !WireAwsAdminIntent
  , wireSignedJobBinding :: !AwsAdminJobBinding
  , wireSignedSignature :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data SignedAwsAdminPermit = SignedAwsAdminPermit
  { internalSignedAwsAdminSignerGeneration :: !Natural
  , internalSignedAwsAdminIntent :: !AwsAdminPermitIntent
  , internalSignedAwsAdminBinding :: !AwsAdminJobBinding
  , internalSignedAwsAdminSignature :: !ByteString
  }
  deriving stock (Eq, Show)

newtype SignedNormalOperatorMaterialPermit = SignedNormalOperatorMaterialPermit SignedAwsAdminPermit
  deriving stock (Eq, Show)

newtype SignedGenesisBackupPermit = SignedGenesisBackupPermit SignedAwsAdminPermit
  deriving stock (Eq, Show)

newtype SignedBackupRepairFrozenPermit = SignedBackupRepairFrozenPermit SignedAwsAdminPermit
  deriving stock (Eq, Show)

data SomeSignedAwsAdminPermit
  = SomeSignedNormalOperatorMaterialPermit !SignedNormalOperatorMaterialPermit
  | SomeSignedGenesisBackupPermit !SignedGenesisBackupPermit
  | SomeSignedBackupRepairFrozenPermit !SignedBackupRepairFrozenPermit
  deriving stock (Eq, Show)

withSomeSignedAwsAdminPermit
  :: SomeSignedAwsAdminPermit
  -> (SignedAwsAdminPermit -> result)
  -> result
withSomeSignedAwsAdminPermit somePermit consume = case somePermit of
  SomeSignedNormalOperatorMaterialPermit (SignedNormalOperatorMaterialPermit permit) ->
    consume permit
  SomeSignedGenesisBackupPermit (SignedGenesisBackupPermit permit) -> consume permit
  SomeSignedBackupRepairFrozenPermit (SignedBackupRepairFrozenPermit permit) ->
    consume permit

awsAdminPermitVersion :: Word16
awsAdminPermitVersion = 4

awsAdminPermitMaximumBytes :: Int
awsAdminPermitMaximumBytes = 64 * 1024

awsAdminPermitSigningPayload
  :: Natural -> AwsAdminPermitIntent -> AwsAdminJobBinding -> ByteString
awsAdminPermitSigningPayload signerGeneration intent binding =
  LazyByteString.toStrict
    ( serialise
        AwsAdminSigningEnvelope
          { wireSigningDomain = "prodbox-credential-provisioner-aws-admin-permit-v1"
          , wireSigningVersion = awsAdminPermitVersion
          , wireSigningSignerGeneration = signerGeneration
          , wireSigningIntent = intentToWire intent
          , wireSigningJobBinding = binding
          }
    )

-- | Canonical secret-free intent bytes used by the Authority's durable
-- prepare/attestation journal before a signed permit exists.
encodeAwsAdminPermitIntent :: AwsAdminPermitIntent -> ByteString
encodeAwsAdminPermitIntent = LazyByteString.toStrict . serialise . intentToWire

decodeAwsAdminPermitIntent
  :: ByteString -> Either AwsAdminPermitError AwsAdminPermitIntent
decodeAwsAdminPermitIntent bytes = do
  when
    (ByteString.length bytes > awsAdminPermitMaximumBytes)
    (Left (AwsAdminPermitTooLarge (ByteString.length bytes) awsAdminPermitMaximumBytes))
  wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
    Left _ -> Left AwsAdminPermitDecodeFailed
    Right value -> Right value
  intent <- intentFromWire wire
  unless (encodeAwsAdminPermitIntent intent == bytes) (Left AwsAdminPermitNonCanonical)
  pure intent

-- | Canonical attested binding bytes. Decoding is relative to the
-- already-committed intent, so a binding for another operation cannot be
-- reclassified as this operation's attestation.
encodeAwsAdminJobBinding :: AwsAdminJobBinding -> ByteString
encodeAwsAdminJobBinding = LazyByteString.toStrict . serialise

decodeAwsAdminJobBinding
  :: AwsAdminPermitIntent
  -> ByteString
  -> Either AwsAdminPermitError AwsAdminJobBinding
decodeAwsAdminJobBinding intent bytes = do
  when
    (ByteString.length bytes > awsAdminPermitMaximumBytes)
    (Left (AwsAdminPermitTooLarge (ByteString.length bytes) awsAdminPermitMaximumBytes))
  binding <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
    Left _ -> Left AwsAdminPermitDecodeFailed
    Right value -> Right value
  validateJobBinding intent binding
  unless (encodeAwsAdminJobBinding binding == bytes) (Left AwsAdminPermitNonCanonical)
  pure binding

mkSignedNormalOperatorMaterialPermit
  :: Natural
  -> AwsAdminPermitIntent
  -> AwsAdminJobBinding
  -> ByteString
  -> Either AwsAdminPermitError SignedNormalOperatorMaterialPermit
mkSignedNormalOperatorMaterialPermit generation intent binding signature = do
  unless
    (awsAdminPermitIntentKind intent == NormalOperatorMaterialKind)
    (Left AwsAdminPermitKindMismatch)
  SignedNormalOperatorMaterialPermit
    <$> mkSignedAwsAdminPermit generation intent binding signature

mkSignedGenesisBackupPermit
  :: Natural
  -> AwsAdminPermitIntent
  -> AwsAdminJobBinding
  -> ByteString
  -> Either AwsAdminPermitError SignedGenesisBackupPermit
mkSignedGenesisBackupPermit generation intent binding signature = do
  case awsAdminPermitIntentKind intent of
    GenesisBackupKind _ -> pure ()
    _ -> Left AwsAdminPermitKindMismatch
  SignedGenesisBackupPermit
    <$> mkSignedAwsAdminPermit generation intent binding signature

mkSignedBackupRepairFrozenPermit
  :: Natural
  -> AwsAdminPermitIntent
  -> AwsAdminJobBinding
  -> ByteString
  -> Either AwsAdminPermitError SignedBackupRepairFrozenPermit
mkSignedBackupRepairFrozenPermit generation intent binding signature = do
  case awsAdminPermitIntentKind intent of
    BackupRepairFrozenKind _ -> pure ()
    _ -> Left AwsAdminPermitKindMismatch
  SignedBackupRepairFrozenPermit
    <$> mkSignedAwsAdminPermit generation intent binding signature

-- | Construct the mode-indexed existential used by the Authority coordinator.
-- The underlying permit remains abstract, while the intent kind selects the
-- only wrapper that can be returned.
mkSomeSignedAwsAdminPermit
  :: Natural
  -> AwsAdminPermitIntent
  -> AwsAdminJobBinding
  -> ByteString
  -> Either AwsAdminPermitError SomeSignedAwsAdminPermit
mkSomeSignedAwsAdminPermit generation intent binding signature = do
  permit <- mkSignedAwsAdminPermit generation intent binding signature
  pure $ case awsAdminPermitIntentKind intent of
    NormalOperatorMaterialKind ->
      SomeSignedNormalOperatorMaterialPermit
        (SignedNormalOperatorMaterialPermit permit)
    GenesisBackupKind _ ->
      SomeSignedGenesisBackupPermit (SignedGenesisBackupPermit permit)
    BackupRepairFrozenKind _ ->
      SomeSignedBackupRepairFrozenPermit (SignedBackupRepairFrozenPermit permit)

mkSignedAwsAdminPermit
  :: Natural
  -> AwsAdminPermitIntent
  -> AwsAdminJobBinding
  -> ByteString
  -> Either AwsAdminPermitError SignedAwsAdminPermit
mkSignedAwsAdminPermit signerGeneration intent binding signature = do
  when (signerGeneration == 0) (Left AwsAdminPermitSignerGenerationInvalid)
  validateIntent intent
  validateJobBinding intent binding
  when (ByteString.null signature) (Left AwsAdminPermitSignatureEmpty)
  when (ByteString.length signature > 512) (Left AwsAdminPermitSignatureInvalid)
  pure
    SignedAwsAdminPermit
      { internalSignedAwsAdminSignerGeneration = signerGeneration
      , internalSignedAwsAdminIntent = intent
      , internalSignedAwsAdminBinding = binding
      , internalSignedAwsAdminSignature = signature
      }

verifySignedAwsAdminPermit
  :: ByteString
  -> Natural
  -> AuthorityTime
  -> SignedAwsAdminPermit
  -> Either AwsAdminPermitError ()
verifySignedAwsAdminPermit publicBytes expectedSignerGeneration now permit = do
  validateSignedPermit permit
  unless
    (signedAwsAdminPermitSignerGeneration permit == expectedSignerGeneration)
    (Left AwsAdminPermitSignerGenerationMismatch)
  when
    (authorityTimeMicros now >= authorityTimeMicros (awsAdminPermitIntentDeadline intent))
    (Left AwsAdminPermitExpired)
  publicKey <- case Ed25519.publicKey publicBytes of
    CryptoFailed _ -> Left AwsAdminPermitPublicKeyInvalid
    CryptoPassed value -> Right value
  signature <- case Ed25519.signature (internalSignedAwsAdminSignature permit) of
    CryptoFailed _ -> Left AwsAdminPermitSignatureInvalid
    CryptoPassed value -> Right value
  unless
    ( Ed25519.verify
        publicKey
        ( awsAdminPermitSigningPayload
            (signedAwsAdminPermitSignerGeneration permit)
            intent
            (signedAwsAdminPermitBinding permit)
        )
        signature
    )
    (Left AwsAdminPermitSignatureInvalid)
 where
  intent = signedAwsAdminPermitIntent permit

encodeSignedAwsAdminPermit :: SignedAwsAdminPermit -> ByteString
encodeSignedAwsAdminPermit permit =
  LazyByteString.toStrict
    ( serialise
        WireSignedAwsAdminPermit
          { wireSignedVersion = awsAdminPermitVersion
          , wireSignedSignerGeneration = signedAwsAdminPermitSignerGeneration permit
          , wireSignedIntent = intentToWire (signedAwsAdminPermitIntent permit)
          , wireSignedJobBinding = signedAwsAdminPermitBinding permit
          , wireSignedSignature = internalSignedAwsAdminSignature permit
          }
    )

decodeSignedAwsAdminPermit
  :: ByteString -> Either AwsAdminPermitError SomeSignedAwsAdminPermit
decodeSignedAwsAdminPermit bytes = do
  when
    (ByteString.length bytes > awsAdminPermitMaximumBytes)
    (Left (AwsAdminPermitTooLarge (ByteString.length bytes) awsAdminPermitMaximumBytes))
  wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
    Left _ -> Left AwsAdminPermitDecodeFailed
    Right value -> Right value
  unless
    (wireSignedVersion wire == awsAdminPermitVersion)
    (Left (AwsAdminPermitUnsupportedVersion (wireSignedVersion wire)))
  unless
    (LazyByteString.toStrict (serialise wire) == bytes)
    (Left AwsAdminPermitNonCanonical)
  intent <- intentFromWire (wireSignedIntent wire)
  mkSomeSignedAwsAdminPermit
    (wireSignedSignerGeneration wire)
    intent
    (wireSignedJobBinding wire)
    (wireSignedSignature wire)

signedAwsAdminPermitIntent :: SignedAwsAdminPermit -> AwsAdminPermitIntent
signedAwsAdminPermitIntent = internalSignedAwsAdminIntent

signedAwsAdminPermitBinding :: SignedAwsAdminPermit -> AwsAdminJobBinding
signedAwsAdminPermitBinding = internalSignedAwsAdminBinding

signedAwsAdminPermitSignerGeneration :: SignedAwsAdminPermit -> Natural
signedAwsAdminPermitSignerGeneration = internalSignedAwsAdminSignerGeneration

validateSignedPermit :: SignedAwsAdminPermit -> Either AwsAdminPermitError ()
validateSignedPermit permit = do
  when
    (signedAwsAdminPermitSignerGeneration permit == 0)
    (Left AwsAdminPermitSignerGenerationInvalid)
  validateIntent (signedAwsAdminPermitIntent permit)
  validateJobBinding
    (signedAwsAdminPermitIntent permit)
    (signedAwsAdminPermitBinding permit)
  when
    (ByteString.null (internalSignedAwsAdminSignature permit))
    (Left AwsAdminPermitSignatureEmpty)
  when
    (ByteString.length (internalSignedAwsAdminSignature permit) > 512)
    (Left AwsAdminPermitSignatureInvalid)

validateIntent :: AwsAdminPermitIntent -> Either AwsAdminPermitError ()
validateIntent intent = do
  canonicalImage <- validateImageDigest (awsAdminPermitIntentImageDigest intent)
  unless
    (canonicalImage == awsAdminPermitIntentImageDigest intent)
    (Left (AwsAdminPermitFieldInvalid "image-digest"))
  canonicalScope <- validateField "authority-scope" 256 (awsAdminPermitIntentAuthorityScope intent)
  unless
    (canonicalScope == awsAdminPermitIntentAuthorityScope intent)
    (Left (AwsAdminPermitFieldInvalid "authority-scope"))
  canonicalEndpoint <- validateAuthorityEndpoint (awsAdminPermitIntentAuthorityEndpoint intent)
  unless
    (canonicalEndpoint == awsAdminPermitIntentAuthorityEndpoint intent)
    (Left (AwsAdminPermitFieldInvalid "authority-endpoint"))
  let expectedDigest =
        awsOperatorMaterialRequestDigest
          (awsAdminPermitIntentCredentialClass intent)
          (awsAdminPermitIntentAction intent)
          (awsAdminPermitIntentOperationId intent)
          (awsAdminPermitIntentGeneration intent)
  unless
    (expectedDigest == awsAdminPermitIntentRequestDigest intent)
    (Left AwsAdminPermitRequestDigestMismatch)
  unless
    ( credentialIamParametersClass (awsAdminPermitIntentIamParameters intent)
        == awsAdminPermitIntentCredentialClass intent
    )
    (Left AwsAdminPermitIamClassMismatch)
  _ <-
    either
      (const (Left AwsAdminPermitIamParametersInvalid))
      Right
      (credentialIamParametersProgram (awsAdminPermitIntentIamParameters intent))
  validateKindRequest
    (awsAdminPermitIntentKind intent)
    (awsAdminPermitIntentCredentialClass intent)
    (awsAdminPermitIntentAction intent)
  validateKindPlanBinding intent
  validatePreparedTargetBinding intent

validatePreparedTargetBinding
  :: AwsAdminPermitIntent -> Either AwsAdminPermitError ()
validatePreparedTargetBinding intent =
  unless
    ( preparedCredentialTargetId prepared
        == targetForClass (awsAdminPermitIntentCredentialClass intent)
        && preparedCredentialTargetGeneration prepared
          == awsAdminPermitIntentGeneration intent
        && preparedCredentialTargetRequestDigest prepared
          == awsAdminPermitIntentRequestDigest intent
        && preparedCredentialTargetPlanBinding prepared
          == awsAdminPermitIntentPlanBinding intent
        && authorityTimeMicros (preparedCredentialTargetDeadline prepared)
          == authorityTimeMicros (awsAdminPermitIntentDeadline intent)
        && preparedCredentialTargetFence prepared > 0
    )
    (Left AwsAdminPermitPreparedTargetMismatch)
 where
  prepared = awsAdminPermitIntentPreparedTarget intent

validateKindPlanBinding :: AwsAdminPermitIntent -> Either AwsAdminPermitError ()
validateKindPlanBinding intent = case awsAdminPermitIntentKind intent of
  NormalOperatorMaterialKind -> pure ()
  GenesisBackupKind _ ->
    case awsAdminPermitIntentPlanBinding intent of
      Just binding
        | firstReconcilePermitMemberIndex binding == 0 -> pure ()
      _ -> Left AwsAdminPermitPlanBindingMismatch
  BackupRepairFrozenKind repair -> do
    unless
      (awsAdminPermitIntentPlanBinding intent == Nothing)
      (Left AwsAdminPermitPlanBindingMismatch)
    when
      (backupRepairFrozenAuthorityEpoch repair == 0)
      (Left AwsAdminPermitRepairBindingInvalid)

validateJobBinding
  :: AwsAdminPermitIntent -> AwsAdminJobBinding -> Either AwsAdminPermitError ()
validateJobBinding intent binding = do
  rebuilt <-
    mkAwsAdminJobBinding
      intent
      (awsAdminJobName binding)
      (awsAdminJobUid binding)
      (awsAdminJobPodName binding)
      (awsAdminJobPodUid binding)
      (awsAdminJobImageDigest binding)
      (awsAdminJobServiceAccount binding)
      (awsAdminJobServiceAccountUid binding)
      (awsAdminJobHeartbeat binding)
  unless (rebuilt == binding) (Left AwsAdminPermitJobBindingMismatch)

intentToWire :: AwsAdminPermitIntent -> WireAwsAdminIntent
intentToWire intent =
  WireAwsAdminIntent
    { wireIntentKind = kindToWire (awsAdminPermitIntentKind intent)
    , wireIntentPermitId =
        operatorMaterialPermitIdText (awsAdminPermitIntentPermitId intent)
    , wireIntentCredentialClass =
        fromIntegral (fromEnum (awsAdminPermitIntentCredentialClass intent) + 1)
    , wireIntentAction = fromIntegral (fromEnum (awsAdminPermitIntentAction intent) + 1)
    , wireIntentOperationId =
        operatorMaterialOperationIdText (awsAdminPermitIntentOperationId intent)
    , wireIntentGeneration =
        credentialGenerationValue (awsAdminPermitIntentGeneration intent)
    , wireIntentRequestDigest =
        targetValueDigestText (awsAdminPermitIntentRequestDigest intent)
    , wireIntentPlanBinding = planBindingToWire <$> awsAdminPermitIntentPlanBinding intent
    , wireIntentDeadlineMicros = authorityTimeMicros (awsAdminPermitIntentDeadline intent)
    , wireIntentIamParameters = awsAdminPermitIntentIamParameters intent
    , wireIntentImageDigest = awsAdminPermitIntentImageDigest intent
    , wireIntentAuthorityScope = awsAdminPermitIntentAuthorityScope intent
    , wireIntentAuthorityEndpoint = awsAdminPermitIntentAuthorityEndpoint intent
    , wireIntentPreparedTarget =
        preparedTargetToWire (awsAdminPermitIntentPreparedTarget intent)
    }

intentFromWire :: WireAwsAdminIntent -> Either AwsAdminPermitError AwsAdminPermitIntent
intentFromWire wire = do
  kind <- kindFromWire (wireIntentKind wire)
  permitId <- mapInvalid (mkOperatorMaterialPermitId (wireIntentPermitId wire))
  credentialClass <- enumFromTag (wireIntentCredentialClass wire)
  action <- enumFromTag (wireIntentAction wire)
  operationId <- mapInvalid (mkOperatorMaterialOperationId (wireIntentOperationId wire))
  generation <- mapInvalid (mkCredentialGeneration (wireIntentGeneration wire))
  requestDigest <- mapInvalid (mkTargetValueDigest (wireIntentRequestDigest wire))
  planBinding <- traverse planBindingFromWire (wireIntentPlanBinding wire)
  imageDigest <- validateImageDigest (wireIntentImageDigest wire)
  authorityScope <- validateField "authority-scope" 256 (wireIntentAuthorityScope wire)
  authorityEndpoint <- validateAuthorityEndpoint (wireIntentAuthorityEndpoint wire)
  preparedTarget <- preparedTargetFromWire (wireIntentPreparedTarget wire)
  let intent =
        AwsAdminPermitIntent
          { internalAwsAdminIntentKind = kind
          , internalAwsAdminIntentPermitId = permitId
          , internalAwsAdminIntentCredentialClass = credentialClass
          , internalAwsAdminIntentAction = action
          , internalAwsAdminIntentOperationId = operationId
          , internalAwsAdminIntentGeneration = generation
          , internalAwsAdminIntentRequestDigest = requestDigest
          , internalAwsAdminIntentPlanBinding = planBinding
          , internalAwsAdminIntentDeadline =
              authorityTimeFromMicros (wireIntentDeadlineMicros wire)
          , internalAwsAdminIntentIamParameters = wireIntentIamParameters wire
          , internalAwsAdminIntentImageDigest = imageDigest
          , internalAwsAdminIntentAuthorityScope = authorityScope
          , internalAwsAdminIntentAuthorityEndpoint = authorityEndpoint
          , internalAwsAdminIntentPreparedTarget = preparedTarget
          }
  validateIntent intent
  unless (intentToWire intent == wire) (Left AwsAdminPermitNonCanonical)
  pure intent

kindToWire :: AwsAdminPermitKind -> WirePermitKind
kindToWire kind = case kind of
  NormalOperatorMaterialKind -> WireNormalPermit
  GenesisBackupKind digest -> WireGenesisPermit (targetValueDigestText digest)
  BackupRepairFrozenKind binding ->
    WireBackupRepairFrozenPermit
      WireRepairBinding
        { wireRepairAuthorityEpoch = backupRepairFrozenAuthorityEpoch binding
        , wireRepairPlanDigest = targetValueDigestText (backupRepairFrozenPlanDigest binding)
        , wireRepairObservationDigest =
            targetValueDigestText (backupRepairFrozenObservationDigest binding)
        , wireRepairLostGeneration =
            credentialGenerationValue (backupRepairFrozenLostGeneration binding)
        }

kindFromWire :: WirePermitKind -> Either AwsAdminPermitError AwsAdminPermitKind
kindFromWire wire = case wire of
  WireNormalPermit -> Right NormalOperatorMaterialKind
  WireGenesisPermit rawDigest -> GenesisBackupKind <$> mapInvalid (mkTargetValueDigest rawDigest)
  WireBackupRepairFrozenPermit repair -> do
    planDigest <- mapInvalid (mkTargetValueDigest (wireRepairPlanDigest repair))
    observationDigest <-
      mapInvalid (mkTargetValueDigest (wireRepairObservationDigest repair))
    generation <- mapInvalid (mkCredentialGeneration (wireRepairLostGeneration repair))
    BackupRepairFrozenKind
      <$> mkBackupRepairFrozenBinding
        (wireRepairAuthorityEpoch repair)
        planDigest
        observationDigest
        generation

planBindingToWire :: FirstReconcilePermitBinding -> WirePlanBinding
planBindingToWire binding =
  WirePlanBinding
    { wirePlanDigest = targetValueDigestText (firstReconcilePermitPlanDigest binding)
    , wirePlanMemberIndex = firstReconcilePermitMemberIndex binding
    , wirePlanMemberDigest =
        targetValueDigestText (firstReconcilePermitMemberDigest binding)
    , wirePlanPriorReceiptDigest =
        targetValueDigestText <$> firstReconcilePermitPriorReceiptDigest binding
    }

planBindingFromWire
  :: WirePlanBinding -> Either AwsAdminPermitError FirstReconcilePermitBinding
planBindingFromWire wire = do
  planDigest <- mapInvalid (mkTargetValueDigest (wirePlanDigest wire))
  memberDigest <- mapInvalid (mkTargetValueDigest (wirePlanMemberDigest wire))
  priorDigest <- traverse (mapInvalid . mkTargetValueDigest) (wirePlanPriorReceiptDigest wire)
  pure
    ( mkFirstReconcilePermitBinding
        planDigest
        (wirePlanMemberIndex wire)
        memberDigest
        priorDigest
    )

preparedTargetToWire
  :: PreparedCredentialTargetObservation -> WirePreparedCredentialTarget
preparedTargetToWire prepared =
  WirePreparedCredentialTarget
    { wirePreparedOwnerNonce = preparedCredentialTargetOwnerNonce prepared
    , wirePreparedFence = preparedCredentialTargetFence prepared
    , wirePreparedSelectedAgent =
        targetAgentIdentityText (preparedCredentialTargetSelectedAgent prepared)
    , wirePreparedTarget = preparedCredentialTargetId prepared
    , wirePreparedGeneration =
        credentialGenerationValue (preparedCredentialTargetGeneration prepared)
    , wirePreparedRequestDigest =
        targetValueDigestText (preparedCredentialTargetRequestDigest prepared)
    , wirePreparedReceiptDigest =
        targetValueDigestText (preparedCredentialTargetReceiptDigest prepared)
    , wirePreparedPlanBinding =
        planBindingToWire <$> preparedCredentialTargetPlanBinding prepared
    , wirePreparedDeadlineMicros =
        authorityTimeMicros (preparedCredentialTargetDeadline prepared)
    }

preparedTargetFromWire
  :: WirePreparedCredentialTarget
  -> Either AwsAdminPermitError PreparedCredentialTargetObservation
preparedTargetFromWire wire = do
  agent <- mapInvalid (mkTargetAgentIdentity (wirePreparedSelectedAgent wire))
  generation <- mapInvalid (mkCredentialGeneration (wirePreparedGeneration wire))
  requestDigest <- mapInvalid (mkTargetValueDigest (wirePreparedRequestDigest wire))
  receiptDigest <- mapInvalid (mkTargetValueDigest (wirePreparedReceiptDigest wire))
  planBinding <- traverse planBindingFromWire (wirePreparedPlanBinding wire)
  prepared <-
    mapInvalid
      ( mkPreparedCredentialTargetObservation
          (wirePreparedOwnerNonce wire)
          (wirePreparedFence wire)
          agent
          (wirePreparedTarget wire)
          generation
          requestDigest
          receiptDigest
          planBinding
          (authorityTimeFromMicros (wirePreparedDeadlineMicros wire))
      )
  unless (preparedTargetToWire prepared == wire) (Left AwsAdminPermitNonCanonical)
  pure prepared

targetForClass :: AwsCredentialClass -> TargetSecretId
targetForClass credentialClass = case credentialClass of
  LifecycleProviderCredential -> TargetAwsCredential AwsLifecycleProvider
  AuthorityBackupStoreCredential -> TargetAwsCredential AwsAuthorityBackupStore
  TlsRetentionStoreCredential -> TargetAwsCredential AwsTlsRetentionStore
  GatewayDnsCredential -> TargetAwsCredential AwsGatewayDns
  HomeCertManagerDns01Credential -> TargetAwsCredential AwsHomeCertManagerDns01
  AwsRunCertManagerDns01Credential -> TargetAwsCredential AwsRunCertManagerDns01
  SesSmtpRetainedCustodyCredential -> TargetSesSmtp

enumFromTag :: (Enum a, Bounded a) => Word8 -> Either AwsAdminPermitError a
enumFromTag tag
  | tag == 0 || numeric > fromEnum (maxBound `asTypeOf` result) =
      Left AwsAdminPermitRequestInvalid
  | otherwise = Right result
 where
  numeric = fromIntegral tag - 1
  result = toEnum numeric

mapInvalid :: Either error value -> Either AwsAdminPermitError value
mapInvalid = either (const (Left AwsAdminPermitRequestInvalid)) Right

validateField :: Text -> Int -> Text -> Either AwsAdminPermitError Text
validateField label maximumLength raw
  | Text.null value = Left (AwsAdminPermitFieldInvalid label)
  | Text.length value > maximumLength = Left (AwsAdminPermitFieldInvalid label)
  | Text.any (\character -> isControl character || isSpace character) value =
      Left (AwsAdminPermitFieldInvalid label)
  | otherwise = Right value
 where
  value = Text.strip raw

validateAuthorityEndpoint :: Text -> Either AwsAdminPermitError Text
validateAuthorityEndpoint raw = do
  value <- validateField "authority-endpoint" 2048 raw
  let canonical = Text.dropWhileEnd (== '/') value
      authority =
        case Text.stripPrefix "http://" canonical of
          Just candidate -> Just candidate
          Nothing -> Text.stripPrefix "https://" canonical
  case authority of
    Just candidate
      | not (Text.null candidate)
          && not (Text.any (`elem` ("/?#@" :: String)) candidate) ->
          Right canonical
    _ -> Left (AwsAdminPermitFieldInvalid "authority-endpoint")

validateImageDigest :: Text -> Either AwsAdminPermitError Text
validateImageDigest raw = do
  value <- validateField "image-digest" 71 raw
  unless
    ( Text.length value == 71
        && Text.isPrefixOf "sha256:" value
        && Text.all isLowerHex (Text.drop 7 value)
    )
    (Left (AwsAdminPermitFieldInvalid "image-digest"))
  pure value
 where
  isLowerHex character = isDigit character || character `elem` ['a' .. 'f']

data AwsAdminPermitError
  = AwsAdminPermitRequestInvalid
  | AwsAdminPermitRequestDigestMismatch
  | AwsAdminPermitIamClassMismatch
  | AwsAdminPermitIamParametersInvalid
  | AwsAdminPermitKindMismatch
  | AwsAdminPermitPlanBindingMismatch
  | AwsAdminPermitRepairBindingInvalid
  | AwsAdminPermitRepairRequestInvalid
  | AwsAdminPermitJobBindingMismatch
  | AwsAdminPermitPreparedTargetMismatch
  | AwsAdminPermitFieldInvalid !Text
  | AwsAdminPermitSignerGenerationInvalid
  | AwsAdminPermitSignerGenerationMismatch
  | AwsAdminPermitSignatureEmpty
  | AwsAdminPermitSignatureInvalid
  | AwsAdminPermitPublicKeyInvalid
  | AwsAdminPermitExpired
  | AwsAdminPermitTooLarge !Int !Int
  | AwsAdminPermitDecodeFailed
  | AwsAdminPermitUnsupportedVersion !Word16
  | AwsAdminPermitNonCanonical
  deriving stock (Eq, Show)
