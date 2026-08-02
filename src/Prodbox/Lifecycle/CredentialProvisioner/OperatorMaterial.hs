{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}

-- | Closed, secret-free credential-provisioning requests and first-reconcile
-- sequencing.  The schema index prevents an AWS administrator frame from
-- being accepted by the external ACME/EAB ingress (and vice versa).
module Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( OperatorMaterialIngressSchema (..)
  , SOperatorMaterialIngressSchema (..)
  , SomeOperatorMaterialRequest (..)
  , OperatorMaterialAction (..)
  , AwsCredentialClass (..)
  , CredentialLifetime (..)
  , CredentialTarget (..)
  , CredentialPermission (..)
  , AwsCredentialDescriptor (..)
  , managedAwsCredentialInventory
  , awsCredentialDescriptor
  , OperatorMaterialOperationId
  , mkOperatorMaterialOperationId
  , operatorMaterialOperationIdText
  , OperatorMaterialRequest
  , OperatorMaterialRequestError (..)
  , mkAwsOperatorMaterialRequest
  , mkExternalAcmeEabRequest
  , operatorMaterialRequestSchema
  , operatorMaterialRequestAction
  , operatorMaterialRequestOperationId
  , operatorMaterialRequestGeneration
  , operatorMaterialRequestAwsClass
  , operatorMaterialRequestTarget
  , operatorMaterialRequestDigest
  , awsOperatorMaterialRequestDigest
  , encodeOperatorMaterialRequest
  , decodeOperatorMaterialRequest
  , OperatorMaterialPermitId
  , mkOperatorMaterialPermitId
  , operatorMaterialPermitIdText
  , OperatorMaterialPermit
  , FirstReconcilePermitBinding
  , mkFirstReconcilePermitBinding
  , firstReconcilePermitPlanDigest
  , firstReconcilePermitMemberIndex
  , firstReconcilePermitMemberDigest
  , firstReconcilePermitPriorReceiptDigest
  , OperatorMaterialPermitError (..)
  , mkOperatorMaterialPermit
  , operatorMaterialPermitId
  , operatorMaterialPermitRequest
  , operatorMaterialPermitRequestDigest
  , operatorMaterialPermitDeadline
  , operatorMaterialPermitPlanBinding
  , operatorMaterialPermitSignature
  , validateOperatorMaterialPermit
  , validateFirstReconcileOperatorMaterialPermit
  , GenesisBackupPermit
  , GenesisBackupPermitError (..)
  , mkGenesisBackupPermit
  , genesisBackupPermitGenesisPlan
  , genesisBackupPermitDescriptor
  , genesisBackupPermitDeadline
  , genesisBackupPermitFirstReconcileMember
  , genesisBackupPermitBindingDigest
  , validateGenesisBackupPermit
  , withGenesisBackupOperatorPermit
  , FirstReconcilePlanAction (..)
  , FirstReconcilePlanMember
  , firstReconcilePlanMemberIndex
  , firstReconcilePlanMemberAction
  , firstReconcilePlanMemberTarget
  , firstReconcilePlanMemberDigest
  , FirstReconcileProvisioningPlan
  , FirstReconcilePlanError (..)
  , mkFirstReconcileProvisioningPlan
  , defaultFirstReconcileProvisioningPlan
  , firstReconcilePlanDigest
  , firstReconcilePlanDeadline
  , firstReconcilePlanMembers
  , firstReconcilePlanMaximumCount
  , FirstReconcileReceipt
  , mkFirstReconcileReceipt
  , firstReconcileReceiptMemberIndex
  , firstReconcileReceiptMemberDigest
  , firstReconcileReceiptReadBackVersion
  , firstReconcileReceiptCommitment
  , firstReconcileReceiptDigest
  , FirstReconcileCursor
  , initialFirstReconcileCursor
  , nextFirstReconcileMember
  , firstReconcilePriorReceiptDigest
  , advanceFirstReconcileCursor
  , bindPermitToNextFirstReconcileMember
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16, Word8)
import GHC.Generics (Generic)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.Authority.Genesis
  ( GenesisPlan (..)
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  , credentialGenerationValue
  , mkCredentialGeneration
  , mkTargetValueDigest
  , targetValueDigestText
  )

data OperatorMaterialIngressSchema
  = AwsAdminProvisioningIngress
  | ExternalAcmeEabIngress
  deriving (Eq, Ord, Show)

data
  SOperatorMaterialIngressSchema
    (schema :: OperatorMaterialIngressSchema)
  where
  SAwsAdminProvisioningIngress
    :: SOperatorMaterialIngressSchema 'AwsAdminProvisioningIngress
  SExternalAcmeEabIngress
    :: SOperatorMaterialIngressSchema 'ExternalAcmeEabIngress

deriving instance Show (SOperatorMaterialIngressSchema schema)
deriving instance Eq (SOperatorMaterialIngressSchema schema)

data OperatorMaterialAction
  = InstallOperatorMaterial
  | RotateOperatorMaterial
  | RevokeOperatorMaterial
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Every AWS credential family has a distinct identity, policy, generation,
-- target, and cleanup node.  No constructor represents the removed shared
-- Gateway credential.
data AwsCredentialClass
  = LifecycleProviderCredential
  | AuthorityBackupStoreCredential
  | TlsRetentionStoreCredential
  | GatewayDnsCredential
  | HomeCertManagerDns01Credential
  | AwsRunCertManagerDns01Credential
  | SesSmtpRetainedCustodyCredential
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (Serialise)

data CredentialLifetime
  = OperationalCredential
  | LongLivedCredential
  | RunScopedCredential
  | RetainedCustodyCredential
  deriving (Eq, Ord, Show)

-- | Closed Target-Agent destinations.  Deliberately not a mount/path pair.
data CredentialTarget
  = LifecycleProviderTarget
  | AuthorityBackupStoreTarget
  | TlsRetentionStoreTarget
  | GatewayDnsTarget
  | HomeCertManagerDns01Target
  | AwsRunCertManagerDns01Target
  | RetainedHomeSesSmtpSourceTarget
  | RetainedHomeAcmeEabSourceTarget
  deriving (Eq, Ord, Show)

-- | Symbolic, exact permissions.  There is no generic action/resource string
-- and consequently no wildcard escape in the registry.
data CredentialPermission
  = AssumeRegisteredProviderRole
  | ReadWriteAuthorityBackupPrefix
  | ReadWriteTlsRetentionPrefixes
  | ChangeRegisteredGatewayRecord
  | ChangeHomeDns01TxtRecords
  | ChangeAwsRunDns01TxtRecords
  | SendEmailFromRegisteredSesIdentity
  deriving (Eq, Ord, Show)

data AwsCredentialDescriptor = AwsCredentialDescriptor
  { awsCredentialDescriptorClass :: !AwsCredentialClass
  , awsCredentialDescriptorPrincipal :: !Text
  , awsCredentialDescriptorPolicy :: !Text
  , awsCredentialDescriptorLifetime :: !CredentialLifetime
  , awsCredentialDescriptorTarget :: !CredentialTarget
  , awsCredentialDescriptorPermissions :: ![CredentialPermission]
  , awsCredentialDescriptorMaximumAccessKeys :: !Natural
  }
  deriving (Eq, Show)

managedAwsCredentialInventory :: [AwsCredentialDescriptor]
managedAwsCredentialInventory = awsCredentialDescriptor <$> [minBound .. maxBound]

awsCredentialDescriptor :: AwsCredentialClass -> AwsCredentialDescriptor
awsCredentialDescriptor credentialClass = case credentialClass of
  LifecycleProviderCredential ->
    descriptor
      "prodbox-lifecycle-provider"
      "prodbox-lifecycle-provider"
      OperationalCredential
      LifecycleProviderTarget
      [AssumeRegisteredProviderRole]
  AuthorityBackupStoreCredential ->
    descriptor
      "prodbox-authority-backup-store"
      "prodbox-authority-backup-store"
      LongLivedCredential
      AuthorityBackupStoreTarget
      [ReadWriteAuthorityBackupPrefix]
  TlsRetentionStoreCredential ->
    descriptor
      "prodbox-tls-retention-store"
      "prodbox-tls-retention-store"
      LongLivedCredential
      TlsRetentionStoreTarget
      [ReadWriteTlsRetentionPrefixes]
  GatewayDnsCredential ->
    descriptor
      "prodbox-gateway-dns"
      "prodbox-gateway-dns"
      LongLivedCredential
      GatewayDnsTarget
      [ChangeRegisteredGatewayRecord]
  HomeCertManagerDns01Credential ->
    descriptor
      "prodbox-cert-manager-home-dns01"
      "prodbox-cert-manager-home-dns01"
      LongLivedCredential
      HomeCertManagerDns01Target
      [ChangeHomeDns01TxtRecords]
  AwsRunCertManagerDns01Credential ->
    descriptor
      "prodbox-cert-manager-aws-dns01"
      "prodbox-cert-manager-aws-dns01"
      RunScopedCredential
      AwsRunCertManagerDns01Target
      [ChangeAwsRunDns01TxtRecords]
  SesSmtpRetainedCustodyCredential ->
    descriptor
      "prodbox-ses-smtp"
      "prodbox-ses-smtp-send"
      RetainedCustodyCredential
      RetainedHomeSesSmtpSourceTarget
      [SendEmailFromRegisteredSesIdentity]
 where
  descriptor principal policy lifetime target permissions =
    AwsCredentialDescriptor
      { awsCredentialDescriptorClass = credentialClass
      , awsCredentialDescriptorPrincipal = principal
      , awsCredentialDescriptorPolicy = policy
      , awsCredentialDescriptorLifetime = lifetime
      , awsCredentialDescriptorTarget = target
      , awsCredentialDescriptorPermissions = permissions
      , awsCredentialDescriptorMaximumAccessKeys = 2
      }

newtype OperatorMaterialOperationId = OperatorMaterialOperationId Text
  deriving (Eq, Ord, Show)

mkOperatorMaterialOperationId
  :: Text -> Either OperatorMaterialRequestError OperatorMaterialOperationId
mkOperatorMaterialOperationId raw =
  OperatorMaterialOperationId <$> validateIdentifier "operation ID" 160 raw

operatorMaterialOperationIdText :: OperatorMaterialOperationId -> Text
operatorMaterialOperationIdText (OperatorMaterialOperationId value) = value

data
  OperatorMaterialRequest
    (schema :: OperatorMaterialIngressSchema)
  where
  AwsOperatorMaterialRequest
    :: !AwsCredentialClass
    -> !OperatorMaterialAction
    -> !OperatorMaterialOperationId
    -> !CredentialGeneration
    -> OperatorMaterialRequest 'AwsAdminProvisioningIngress
  ExternalAcmeEabRequest
    :: !OperatorMaterialAction
    -> !OperatorMaterialOperationId
    -> !CredentialGeneration
    -> OperatorMaterialRequest 'ExternalAcmeEabIngress

deriving instance Eq (OperatorMaterialRequest schema)
deriving instance Show (OperatorMaterialRequest schema)

data SomeOperatorMaterialRequest where
  SomeOperatorMaterialRequest
    :: SOperatorMaterialIngressSchema schema
    -> OperatorMaterialRequest schema
    -> SomeOperatorMaterialRequest

deriving instance Show SomeOperatorMaterialRequest

data OperatorMaterialRequestError
  = OperatorMaterialIdentifierEmpty !Text
  | OperatorMaterialIdentifierTooLong !Text !Int !Int
  | OperatorMaterialIdentifierUnsafe !Text !Char
  | AuthorityBackupInstallRequiresGenesisPermit
  | AuthorityBackupRevocationRequiresDecommission
  | OperatorMaterialRequestTooLarge !Int !Int
  | OperatorMaterialRequestDecodeFailed
  | OperatorMaterialRequestUnsupportedVersion !Word16
  | OperatorMaterialRequestUnknownSchema !Word8
  | OperatorMaterialRequestUnknownClass !Word8
  | OperatorMaterialRequestUnknownAction !Word8
  | OperatorMaterialRequestInvalidGeneration
  | OperatorMaterialRequestNonCanonical
  deriving (Eq, Show)

mkAwsOperatorMaterialRequest
  :: AwsCredentialClass
  -> OperatorMaterialAction
  -> OperatorMaterialOperationId
  -> CredentialGeneration
  -> Either OperatorMaterialRequestError (OperatorMaterialRequest 'AwsAdminProvisioningIngress)
mkAwsOperatorMaterialRequest credentialClass action operationId generation = do
  case (credentialClass, action) of
    (AuthorityBackupStoreCredential, InstallOperatorMaterial) ->
      Left AuthorityBackupInstallRequiresGenesisPermit
    (AuthorityBackupStoreCredential, RevokeOperatorMaterial) ->
      Left AuthorityBackupRevocationRequiresDecommission
    _ -> Right ()
  pure (AwsOperatorMaterialRequest credentialClass action operationId generation)

mkExternalAcmeEabRequest
  :: OperatorMaterialAction
  -> OperatorMaterialOperationId
  -> CredentialGeneration
  -> OperatorMaterialRequest 'ExternalAcmeEabIngress
mkExternalAcmeEabRequest = ExternalAcmeEabRequest

operatorMaterialRequestSchema
  :: OperatorMaterialRequest schema
  -> SOperatorMaterialIngressSchema schema
operatorMaterialRequestSchema request = case request of
  AwsOperatorMaterialRequest {} -> SAwsAdminProvisioningIngress
  ExternalAcmeEabRequest {} -> SExternalAcmeEabIngress

operatorMaterialRequestAction
  :: OperatorMaterialRequest schema -> OperatorMaterialAction
operatorMaterialRequestAction request = case request of
  AwsOperatorMaterialRequest _ action _ _ -> action
  ExternalAcmeEabRequest action _ _ -> action

operatorMaterialRequestOperationId
  :: OperatorMaterialRequest schema -> OperatorMaterialOperationId
operatorMaterialRequestOperationId request = case request of
  AwsOperatorMaterialRequest _ _ operationId _ -> operationId
  ExternalAcmeEabRequest _ operationId _ -> operationId

operatorMaterialRequestGeneration
  :: OperatorMaterialRequest schema -> CredentialGeneration
operatorMaterialRequestGeneration request = case request of
  AwsOperatorMaterialRequest _ _ _ generation -> generation
  ExternalAcmeEabRequest _ _ generation -> generation

operatorMaterialRequestAwsClass
  :: OperatorMaterialRequest schema -> Maybe AwsCredentialClass
operatorMaterialRequestAwsClass request = case request of
  AwsOperatorMaterialRequest credentialClass _ _ _ -> Just credentialClass
  ExternalAcmeEabRequest {} -> Nothing

operatorMaterialRequestTarget
  :: OperatorMaterialRequest schema -> CredentialTarget
operatorMaterialRequestTarget request = case request of
  AwsOperatorMaterialRequest credentialClass _ _ _ ->
    awsCredentialDescriptorTarget (awsCredentialDescriptor credentialClass)
  ExternalAcmeEabRequest {} -> RetainedHomeAcmeEabSourceTarget

data WireOperatorMaterialRequest = WireOperatorMaterialRequest
  { wireRequestVersion :: !Word16
  , wireRequestSchema :: !Word8
  , wireRequestClass :: !(Maybe Word8)
  , wireRequestAction :: !Word8
  , wireRequestOperationId :: !Text
  , wireRequestGeneration :: !Natural
  }
  deriving (Eq, Show, Generic, Serialise)

operatorMaterialRequestCodecVersion :: Word16
operatorMaterialRequestCodecVersion = 1

operatorMaterialRequestMaximumEncodedBytes :: Int
operatorMaterialRequestMaximumEncodedBytes = 4096

encodeOperatorMaterialRequest :: OperatorMaterialRequest schema -> ByteString
encodeOperatorMaterialRequest =
  LazyByteString.toStrict . serialise . requestToWire

decodeOperatorMaterialRequest
  :: ByteString -> Either OperatorMaterialRequestError SomeOperatorMaterialRequest
decodeOperatorMaterialRequest bytes
  | ByteString.length bytes > operatorMaterialRequestMaximumEncodedBytes =
      Left
        ( OperatorMaterialRequestTooLarge
            (ByteString.length bytes)
            operatorMaterialRequestMaximumEncodedBytes
        )
  | otherwise = do
      wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left OperatorMaterialRequestDecodeFailed
        Right decoded -> Right decoded
      unless
        (wireRequestVersion wire == operatorMaterialRequestCodecVersion)
        (Left (OperatorMaterialRequestUnsupportedVersion (wireRequestVersion wire)))
      decoded <- requestFromWire wire
      let canonical = case decoded of
            SomeOperatorMaterialRequest _ request -> encodeOperatorMaterialRequest request
      unless (canonical == bytes) (Left OperatorMaterialRequestNonCanonical)
      pure decoded

operatorMaterialRequestDigest
  :: OperatorMaterialRequest schema -> TargetValueDigest
operatorMaterialRequestDigest = sha256Digest . encodeOperatorMaterialRequest

-- | Compute the canonical request digest from the closed AWS request fields.
-- This deliberately does not construct a normal request: the exceptional
-- Authority-backup genesis path needs to bind the same request bytes while
-- keeping its otherwise-forbidden install constructor private.
awsOperatorMaterialRequestDigest
  :: AwsCredentialClass
  -> OperatorMaterialAction
  -> OperatorMaterialOperationId
  -> CredentialGeneration
  -> TargetValueDigest
awsOperatorMaterialRequestDigest credentialClass action operationId generation =
  sha256Digest
    ( LazyByteString.toStrict
        ( serialise
            WireOperatorMaterialRequest
              { wireRequestVersion = operatorMaterialRequestCodecVersion
              , wireRequestSchema = 1
              , wireRequestClass = Just (fromIntegral (fromEnum credentialClass + 1))
              , wireRequestAction = fromIntegral (fromEnum action + 1)
              , wireRequestOperationId = operatorMaterialOperationIdText operationId
              , wireRequestGeneration = credentialGenerationValue generation
              }
        )
    )

requestToWire :: OperatorMaterialRequest schema -> WireOperatorMaterialRequest
requestToWire request = case request of
  AwsOperatorMaterialRequest credentialClass action operationId generation ->
    WireOperatorMaterialRequest
      operatorMaterialRequestCodecVersion
      1
      (Just (fromIntegral (fromEnum credentialClass + 1)))
      (fromIntegral (fromEnum action + 1))
      (operatorMaterialOperationIdText operationId)
      (credentialGenerationValue generation)
  ExternalAcmeEabRequest action operationId generation ->
    WireOperatorMaterialRequest
      operatorMaterialRequestCodecVersion
      2
      Nothing
      (fromIntegral (fromEnum action + 1))
      (operatorMaterialOperationIdText operationId)
      (credentialGenerationValue generation)

requestFromWire
  :: WireOperatorMaterialRequest
  -> Either OperatorMaterialRequestError SomeOperatorMaterialRequest
requestFromWire wire = do
  action <- actionFromWire (wireRequestAction wire)
  operationId <- mkOperatorMaterialOperationId (wireRequestOperationId wire)
  generation <-
    if wireRequestGeneration wire == 0
      then Left OperatorMaterialRequestInvalidGeneration
      else Right (generationFromPositive (wireRequestGeneration wire))
  case (wireRequestSchema wire, wireRequestClass wire) of
    (1, Just classTag) -> do
      credentialClass <- credentialClassFromWire classTag
      request <- mkAwsOperatorMaterialRequest credentialClass action operationId generation
      pure (SomeOperatorMaterialRequest SAwsAdminProvisioningIngress request)
    (2, Nothing) ->
      pure
        ( SomeOperatorMaterialRequest
            SExternalAcmeEabIngress
            (mkExternalAcmeEabRequest action operationId generation)
        )
    (1, Nothing) -> Left (OperatorMaterialRequestUnknownClass 0)
    (schemaTag, _) -> Left (OperatorMaterialRequestUnknownSchema schemaTag)

-- The validation immediately above proves positivity.  Keeping this helper
-- local avoids exposing an unsafe public constructor.
generationFromPositive :: Natural -> CredentialGeneration
generationFromPositive value =
  case mkCredentialGeneration value of
    Left _ -> error "positive credential generation invariant violated"
    Right generation -> generation

actionFromWire
  :: Word8 -> Either OperatorMaterialRequestError OperatorMaterialAction
actionFromWire tag
  | tag == 0 || numeric > fromEnum (maxBound :: OperatorMaterialAction) =
      Left (OperatorMaterialRequestUnknownAction tag)
  | otherwise = Right (toEnum numeric)
 where
  numeric = fromIntegral tag - 1

credentialClassFromWire
  :: Word8 -> Either OperatorMaterialRequestError AwsCredentialClass
credentialClassFromWire tag
  | tag == 0 || numeric > fromEnum (maxBound :: AwsCredentialClass) =
      Left (OperatorMaterialRequestUnknownClass tag)
  | otherwise = Right (toEnum numeric)
 where
  numeric = fromIntegral tag - 1

newtype OperatorMaterialPermitId = OperatorMaterialPermitId Text
  deriving (Eq, Ord, Show)

mkOperatorMaterialPermitId
  :: Text -> Either OperatorMaterialPermitError OperatorMaterialPermitId
mkOperatorMaterialPermitId raw =
  case validateIdentifier "permit ID" 160 raw of
    Left err -> Left (OperatorMaterialPermitIdentifierInvalid err)
    Right value -> Right (OperatorMaterialPermitId value)

operatorMaterialPermitIdText :: OperatorMaterialPermitId -> Text
operatorMaterialPermitIdText (OperatorMaterialPermitId value) = value

data FirstReconcilePermitBinding = FirstReconcilePermitBinding
  { firstReconcilePermitPlanDigest :: !TargetValueDigest
  , firstReconcilePermitMemberIndex :: !Natural
  , firstReconcilePermitMemberDigest :: !TargetValueDigest
  , firstReconcilePermitPriorReceiptDigest :: !(Maybe TargetValueDigest)
  }
  deriving (Eq, Show)

mkFirstReconcilePermitBinding
  :: TargetValueDigest
  -> Natural
  -> TargetValueDigest
  -> Maybe TargetValueDigest
  -> FirstReconcilePermitBinding
mkFirstReconcilePermitBinding = FirstReconcilePermitBinding

data OperatorMaterialPermit schema = OperatorMaterialPermit
  { internalOperatorMaterialPermitId :: !OperatorMaterialPermitId
  , internalOperatorMaterialPermitRequest :: !(OperatorMaterialRequest schema)
  , internalOperatorMaterialPermitRequestDigest :: !TargetValueDigest
  , internalOperatorMaterialPermitDeadline :: !AuthorityTime
  , internalOperatorMaterialPermitPlanBinding :: !(Maybe FirstReconcilePermitBinding)
  , internalOperatorMaterialPermitSignature :: !ByteString
  }

deriving instance Eq (OperatorMaterialPermit schema)
deriving instance Show (OperatorMaterialPermit schema)

data OperatorMaterialPermitError
  = OperatorMaterialPermitIdentifierInvalid !OperatorMaterialRequestError
  | OperatorMaterialPermitSignatureEmpty
  | OperatorMaterialPermitSignatureTooLarge !Int !Int
  | OperatorMaterialPermitExpired
  | OperatorMaterialPermitRequestDigestMismatch
  | OperatorMaterialPermitPlanMismatch
  | OperatorMaterialPermitNotNextMember
  | OperatorMaterialPermitPriorReceiptMismatch
  deriving (Eq, Show)

mkOperatorMaterialPermit
  :: OperatorMaterialPermitId
  -> OperatorMaterialRequest schema
  -> AuthorityTime
  -> Maybe FirstReconcilePermitBinding
  -> ByteString
  -> Either OperatorMaterialPermitError (OperatorMaterialPermit schema)
mkOperatorMaterialPermit permitId request deadline planBinding signature
  | ByteString.null signature = Left OperatorMaterialPermitSignatureEmpty
  | ByteString.length signature > maximumSignatureBytes =
      Left
        ( OperatorMaterialPermitSignatureTooLarge
            (ByteString.length signature)
            maximumSignatureBytes
        )
  | otherwise =
      Right
        OperatorMaterialPermit
          { internalOperatorMaterialPermitId = permitId
          , internalOperatorMaterialPermitRequest = request
          , internalOperatorMaterialPermitRequestDigest = operatorMaterialRequestDigest request
          , internalOperatorMaterialPermitDeadline = deadline
          , internalOperatorMaterialPermitPlanBinding = planBinding
          , internalOperatorMaterialPermitSignature = signature
          }
 where
  maximumSignatureBytes = 512

operatorMaterialPermitId
  :: OperatorMaterialPermit schema -> OperatorMaterialPermitId
operatorMaterialPermitId = internalOperatorMaterialPermitId

operatorMaterialPermitRequest
  :: OperatorMaterialPermit schema -> OperatorMaterialRequest schema
operatorMaterialPermitRequest = internalOperatorMaterialPermitRequest

operatorMaterialPermitRequestDigest
  :: OperatorMaterialPermit schema -> TargetValueDigest
operatorMaterialPermitRequestDigest = internalOperatorMaterialPermitRequestDigest

operatorMaterialPermitDeadline
  :: OperatorMaterialPermit schema -> AuthorityTime
operatorMaterialPermitDeadline = internalOperatorMaterialPermitDeadline

operatorMaterialPermitPlanBinding
  :: OperatorMaterialPermit schema -> Maybe FirstReconcilePermitBinding
operatorMaterialPermitPlanBinding = internalOperatorMaterialPermitPlanBinding

operatorMaterialPermitSignature
  :: OperatorMaterialPermit schema -> ByteString
operatorMaterialPermitSignature = internalOperatorMaterialPermitSignature

validateOperatorMaterialPermit
  :: AuthorityTime
  -> OperatorMaterialPermit schema
  -> Either OperatorMaterialPermitError ()
validateOperatorMaterialPermit now permit
  | authorityTimeMicros now >= authorityTimeMicros (operatorMaterialPermitDeadline permit) =
      Left OperatorMaterialPermitExpired
  | operatorMaterialPermitRequestDigest permit
      /= operatorMaterialRequestDigest (operatorMaterialPermitRequest permit) =
      Left OperatorMaterialPermitRequestDigestMismatch
  | otherwise = Right ()

validateFirstReconcileOperatorMaterialPermit
  :: AuthorityTime
  -> FirstReconcileProvisioningPlan
  -> FirstReconcileCursor
  -> OperatorMaterialPermit 'AwsAdminProvisioningIngress
  -> Either OperatorMaterialPermitError ()
validateFirstReconcileOperatorMaterialPermit now plan cursor permit = do
  validateOperatorMaterialPermit now permit
  actual <-
    maybe
      (Left OperatorMaterialPermitPlanMismatch)
      Right
      (operatorMaterialPermitPlanBinding permit)
  next <-
    either
      (const (Left OperatorMaterialPermitNotNextMember))
      Right
      (nextFirstReconcileMember plan cursor)
  member <- maybe (Left OperatorMaterialPermitNotNextMember) Right next
  unless
    ( firstReconcilePermitPlanDigest actual == firstReconcilePlanDigest plan
        && firstReconcilePermitMemberIndex actual
          == firstReconcilePlanMemberIndex member
        && firstReconcilePermitMemberDigest actual
          == firstReconcilePlanMemberDigest member
    )
    (Left OperatorMaterialPermitPlanMismatch)
  unless
    ( firstReconcilePermitPriorReceiptDigest actual
        == firstReconcilePriorReceiptDigest cursor
    )
    (Left OperatorMaterialPermitPriorReceiptMismatch)
  case firstReconcilePlanMemberAction member of
    EstablishAuthorityBackupMember -> Left OperatorMaterialPermitNotNextMember
    ProvisionAwsCredentialMember expectedClass ->
      unless
        (operatorMaterialRequestAwsClass (operatorMaterialPermitRequest permit) == Just expectedClass)
        (Left OperatorMaterialPermitNotNextMember)

-- | The one exceptional pre-normal-admission credential permit.  Its
-- constructor is private: callers can obtain one only by binding the exact
-- deterministic Authority genesis plan to member zero of the finite first-
-- reconcile plan and to the compiled Authority-backup descriptor.  It is not
-- interchangeable with a normal 'OperatorMaterialPermit'.
data GenesisBackupPermit = GenesisBackupPermit
  { internalGenesisBackupPermitGenesisPlan :: !GenesisPlan
  , internalGenesisBackupPermitDescriptor :: !AwsCredentialDescriptor
  , internalGenesisBackupPermitFirstReconcileMember :: !FirstReconcilePlanMember
  , internalGenesisBackupPermitBindingDigest :: !TargetValueDigest
  , internalGenesisBackupPermitOperatorPermit
      :: !(OperatorMaterialPermit 'AwsAdminProvisioningIngress)
  }
  deriving (Eq, Show)

data GenesisBackupPermitError
  = GenesisBackupPlanInvalid
  | GenesisBackupFirstReconcilePlanInvalid !FirstReconcilePlanError
  | GenesisBackupNotFirstReconcileMember
  | GenesisBackupDeadlineMismatch
  | GenesisBackupPermitInvalid !OperatorMaterialPermitError
  | GenesisBackupDescriptorMismatch
  | GenesisBackupRequestMismatch
  deriving (Eq, Show)

-- | Smart-construct the initial Authority-backup install permit.  The normal
-- request constructor deliberately rejects this action; only this genesis
-- constructor can form it.
mkGenesisBackupPermit
  :: GenesisPlan
  -> FirstReconcileProvisioningPlan
  -> FirstReconcileCursor
  -> OperatorMaterialPermitId
  -> OperatorMaterialOperationId
  -> CredentialGeneration
  -> AuthorityTime
  -> ByteString
  -> Either GenesisBackupPermitError GenesisBackupPermit
mkGenesisBackupPermit genesisPlan firstPlan cursor permitId operationId generation deadline signature = do
  unless
    ( validGenesisText (genesisPlanDigest genesisPlan)
        && validGenesisText (genesisPlanBackupStoreCoordinate genesisPlan)
    )
    (Left GenesisBackupPlanInvalid)
  unless
    (authorityTimeMicros deadline == authorityTimeMicros (firstReconcilePlanDeadline firstPlan))
    (Left GenesisBackupDeadlineMismatch)
  next <-
    either
      (Left . GenesisBackupFirstReconcilePlanInvalid)
      Right
      (nextFirstReconcileMember firstPlan cursor)
  member <- maybe (Left GenesisBackupNotFirstReconcileMember) Right next
  unless
    ( firstReconcilePlanMemberIndex member == 0
        && firstReconcilePlanMemberAction member == EstablishAuthorityBackupMember
        && firstReconcilePlanMemberTarget member == AuthorityBackupStoreTarget
        && firstReconcilePriorReceiptDigest cursor == Nothing
    )
    (Left GenesisBackupNotFirstReconcileMember)
  let descriptor = awsCredentialDescriptor AuthorityBackupStoreCredential
      request =
        AwsOperatorMaterialRequest
          AuthorityBackupStoreCredential
          InstallOperatorMaterial
          operationId
          generation
      binding =
        FirstReconcilePermitBinding
          { firstReconcilePermitPlanDigest = firstReconcilePlanDigest firstPlan
          , firstReconcilePermitMemberIndex = firstReconcilePlanMemberIndex member
          , firstReconcilePermitMemberDigest = firstReconcilePlanMemberDigest member
          , firstReconcilePermitPriorReceiptDigest = Nothing
          }
  operatorPermit <-
    either
      (Left . GenesisBackupPermitInvalid)
      Right
      (mkOperatorMaterialPermit permitId request deadline (Just binding) signature)
  let bindingDigest = genesisBindingDigest genesisPlan descriptor member operatorPermit
  pure
    GenesisBackupPermit
      { internalGenesisBackupPermitGenesisPlan = genesisPlan
      , internalGenesisBackupPermitDescriptor = descriptor
      , internalGenesisBackupPermitFirstReconcileMember = member
      , internalGenesisBackupPermitBindingDigest = bindingDigest
      , internalGenesisBackupPermitOperatorPermit = operatorPermit
      }
 where
  validGenesisText value =
    let normalized = Text.strip value
     in not (Text.null normalized) && Text.length normalized <= 4096

genesisBackupPermitGenesisPlan :: GenesisBackupPermit -> GenesisPlan
genesisBackupPermitGenesisPlan = internalGenesisBackupPermitGenesisPlan

genesisBackupPermitDescriptor :: GenesisBackupPermit -> AwsCredentialDescriptor
genesisBackupPermitDescriptor = internalGenesisBackupPermitDescriptor

genesisBackupPermitDeadline :: GenesisBackupPermit -> AuthorityTime
genesisBackupPermitDeadline =
  operatorMaterialPermitDeadline . internalGenesisBackupPermitOperatorPermit

genesisBackupPermitFirstReconcileMember
  :: GenesisBackupPermit -> FirstReconcilePlanMember
genesisBackupPermitFirstReconcileMember =
  internalGenesisBackupPermitFirstReconcileMember

genesisBackupPermitBindingDigest :: GenesisBackupPermit -> TargetValueDigest
genesisBackupPermitBindingDigest = internalGenesisBackupPermitBindingDigest

-- | Re-check the time-dependent portion and every closed binding before the
-- one-shot Job is allowed to acquire an AWS session.
validateGenesisBackupPermit
  :: AuthorityTime
  -> GenesisBackupPermit
  -> Either GenesisBackupPermitError ()
validateGenesisBackupPermit now permit = do
  either
    (Left . GenesisBackupPermitInvalid)
    Right
    (validateOperatorMaterialPermit now operatorPermit)
  unless
    ( internalGenesisBackupPermitDescriptor permit
        == awsCredentialDescriptor AuthorityBackupStoreCredential
    )
    (Left GenesisBackupDescriptorMismatch)
  unless
    ( firstReconcilePlanMemberIndex member == 0
        && firstReconcilePlanMemberAction member == EstablishAuthorityBackupMember
        && firstReconcilePlanMemberTarget member == AuthorityBackupStoreTarget
    )
    (Left GenesisBackupNotFirstReconcileMember)
  unless
    ( operatorMaterialRequestAwsClass request == Just AuthorityBackupStoreCredential
        && operatorMaterialRequestAction request == InstallOperatorMaterial
        && operatorMaterialRequestTarget request == AuthorityBackupStoreTarget
    )
    (Left GenesisBackupRequestMismatch)
  unless
    ( internalGenesisBackupPermitBindingDigest permit
        == genesisBindingDigest
          (internalGenesisBackupPermitGenesisPlan permit)
          (internalGenesisBackupPermitDescriptor permit)
          member
          operatorPermit
    )
    (Left GenesisBackupRequestMismatch)
 where
  operatorPermit = internalGenesisBackupPermitOperatorPermit permit
  request = operatorMaterialPermitRequest operatorPermit
  member = internalGenesisBackupPermitFirstReconcileMember permit

-- | Continuation-scoped eliminator used only by the genesis execution entry;
-- the exceptional underlying request cannot escape as a reusable normal
-- permit value.
withGenesisBackupOperatorPermit
  :: GenesisBackupPermit
  -> (OperatorMaterialPermit 'AwsAdminProvisioningIngress -> result)
  -> result
withGenesisBackupOperatorPermit permit consume =
  consume (internalGenesisBackupPermitOperatorPermit permit)

genesisBindingDigest
  :: GenesisPlan
  -> AwsCredentialDescriptor
  -> FirstReconcilePlanMember
  -> OperatorMaterialPermit 'AwsAdminProvisioningIngress
  -> TargetValueDigest
genesisBindingDigest genesisPlan descriptor member operatorPermit =
  sha256Digest
    ( TextEncoding.encodeUtf8
        ( Text.intercalate
            "|"
            [ genesisPlanDigest genesisPlan
            , genesisPlanBackupStoreCoordinate genesisPlan
            , Text.pack (show descriptor)
            , Text.pack (show (firstReconcilePlanMemberIndex member))
            , targetValueDigestText (firstReconcilePlanMemberDigest member)
            , targetValueDigestText (operatorMaterialPermitRequestDigest operatorPermit)
            , Text.pack (show (authorityTimeMicros (operatorMaterialPermitDeadline operatorPermit)))
            ]
        )
    )

data FirstReconcilePlanAction
  = EstablishAuthorityBackupMember
  | ProvisionAwsCredentialMember !AwsCredentialClass
  deriving (Eq, Ord, Show)

data FirstReconcilePlanMember = FirstReconcilePlanMember
  { firstReconcilePlanMemberIndex :: !Natural
  , firstReconcilePlanMemberAction :: !FirstReconcilePlanAction
  , firstReconcilePlanMemberTarget :: !CredentialTarget
  , firstReconcilePlanMemberDigest :: !TargetValueDigest
  }
  deriving (Eq, Show)

data FirstReconcileProvisioningPlan = FirstReconcileProvisioningPlan
  { internalFirstReconcilePlanDigest :: !TargetValueDigest
  , internalFirstReconcilePlanDeadline :: !AuthorityTime
  , internalFirstReconcilePlanMembers :: ![FirstReconcilePlanMember]
  , internalFirstReconcilePlanMaximumCount :: !Natural
  }
  deriving (Eq, Show)

data FirstReconcilePlanError
  = FirstReconcilePlanEmpty
  | FirstReconcilePlanTooLarge !Int !Int
  | FirstReconcilePlanMustBeginWithAuthorityBackup
  | FirstReconcilePlanDuplicateAction !FirstReconcilePlanAction
  | FirstReconcileReceiptWrongMember
  | FirstReconcileReceiptDigestInvalid
  | FirstReconcilePlanAlreadyComplete
  | FirstReconcileRequestClassMismatch
  deriving (Eq, Show)

mkFirstReconcileProvisioningPlan
  :: AuthorityTime
  -> [FirstReconcilePlanAction]
  -> Either FirstReconcilePlanError FirstReconcileProvisioningPlan
mkFirstReconcileProvisioningPlan deadline actions = do
  firstAction <- case actions of
    [] -> Left FirstReconcilePlanEmpty
    first : _ -> Right first
  when
    (length actions > firstReconcileHardMaximum)
    (Left (FirstReconcilePlanTooLarge (length actions) firstReconcileHardMaximum))
  unless
    (firstAction == EstablishAuthorityBackupMember)
    (Left FirstReconcilePlanMustBeginWithAuthorityBackup)
  case firstDuplicate actions of
    Just duplicate -> Left (FirstReconcilePlanDuplicateAction duplicate)
    Nothing -> Right ()
  let members = zipWith (planMember deadline) [0 ..] actions
      digest = sha256Digest (encodePlan deadline members)
  pure
    FirstReconcileProvisioningPlan
      { internalFirstReconcilePlanDigest = digest
      , internalFirstReconcilePlanDeadline = deadline
      , internalFirstReconcilePlanMembers = members
      , internalFirstReconcilePlanMaximumCount = fromIntegral (length members)
      }

defaultFirstReconcileProvisioningPlan
  :: AuthorityTime -> FirstReconcileProvisioningPlan
defaultFirstReconcileProvisioningPlan deadline =
  case mkFirstReconcileProvisioningPlan deadline defaultActions of
    Left err -> error ("invalid compiled first-reconcile plan: " <> show err)
    Right plan -> plan
 where
  defaultActions =
    [ EstablishAuthorityBackupMember
    , ProvisionAwsCredentialMember LifecycleProviderCredential
    , ProvisionAwsCredentialMember TlsRetentionStoreCredential
    , ProvisionAwsCredentialMember GatewayDnsCredential
    , ProvisionAwsCredentialMember HomeCertManagerDns01Credential
    ]

firstReconcileHardMaximum :: Int
firstReconcileHardMaximum = 8

firstReconcilePlanDigest :: FirstReconcileProvisioningPlan -> TargetValueDigest
firstReconcilePlanDigest = internalFirstReconcilePlanDigest

firstReconcilePlanDeadline :: FirstReconcileProvisioningPlan -> AuthorityTime
firstReconcilePlanDeadline = internalFirstReconcilePlanDeadline

firstReconcilePlanMembers
  :: FirstReconcileProvisioningPlan -> [FirstReconcilePlanMember]
firstReconcilePlanMembers = internalFirstReconcilePlanMembers

firstReconcilePlanMaximumCount :: FirstReconcileProvisioningPlan -> Natural
firstReconcilePlanMaximumCount = internalFirstReconcilePlanMaximumCount

data FirstReconcileReceipt = FirstReconcileReceipt
  { internalFirstReconcileReceiptMemberIndex :: !Natural
  , internalFirstReconcileReceiptMemberDigest :: !TargetValueDigest
  , internalFirstReconcileReceiptReadBackVersion :: !Text
  , internalFirstReconcileReceiptCommitment :: !Text
  , internalFirstReconcileReceiptDigest :: !TargetValueDigest
  }
  deriving (Eq, Show)

mkFirstReconcileReceipt
  :: FirstReconcilePlanMember
  -> Text
  -> Text
  -> Either FirstReconcilePlanError FirstReconcileReceipt
mkFirstReconcileReceipt member readBackVersion commitment
  | Text.null (Text.strip readBackVersion) || Text.null (Text.strip commitment) =
      Left FirstReconcileReceiptDigestInvalid
  | otherwise =
      Right
        FirstReconcileReceipt
          { internalFirstReconcileReceiptMemberIndex = firstReconcilePlanMemberIndex member
          , internalFirstReconcileReceiptMemberDigest = firstReconcilePlanMemberDigest member
          , internalFirstReconcileReceiptReadBackVersion = Text.strip readBackVersion
          , internalFirstReconcileReceiptCommitment = Text.strip commitment
          , internalFirstReconcileReceiptDigest =
              sha256Digest
                ( TextEncoding.encodeUtf8
                    ( Text.intercalate
                        ":"
                        [ Text.pack (show (firstReconcilePlanMemberIndex member))
                        , targetValueDigestText (firstReconcilePlanMemberDigest member)
                        , Text.strip readBackVersion
                        , Text.strip commitment
                        ]
                    )
                )
          }

firstReconcileReceiptMemberIndex :: FirstReconcileReceipt -> Natural
firstReconcileReceiptMemberIndex = internalFirstReconcileReceiptMemberIndex

firstReconcileReceiptMemberDigest :: FirstReconcileReceipt -> TargetValueDigest
firstReconcileReceiptMemberDigest = internalFirstReconcileReceiptMemberDigest

firstReconcileReceiptReadBackVersion :: FirstReconcileReceipt -> Text
firstReconcileReceiptReadBackVersion = internalFirstReconcileReceiptReadBackVersion

firstReconcileReceiptCommitment :: FirstReconcileReceipt -> Text
firstReconcileReceiptCommitment = internalFirstReconcileReceiptCommitment

firstReconcileReceiptDigest :: FirstReconcileReceipt -> TargetValueDigest
firstReconcileReceiptDigest = internalFirstReconcileReceiptDigest

data FirstReconcileCursor = FirstReconcileCursor
  { internalFirstReconcileCursorPlanDigest :: !TargetValueDigest
  , internalFirstReconcileCursorNextIndex :: !Natural
  , internalFirstReconcileCursorPriorReceipt :: !(Maybe TargetValueDigest)
  }
  deriving (Eq, Show)

initialFirstReconcileCursor
  :: FirstReconcileProvisioningPlan -> FirstReconcileCursor
initialFirstReconcileCursor plan =
  FirstReconcileCursor
    { internalFirstReconcileCursorPlanDigest = firstReconcilePlanDigest plan
    , internalFirstReconcileCursorNextIndex = 0
    , internalFirstReconcileCursorPriorReceipt = Nothing
    }

nextFirstReconcileMember
  :: FirstReconcileProvisioningPlan
  -> FirstReconcileCursor
  -> Either FirstReconcilePlanError (Maybe FirstReconcilePlanMember)
nextFirstReconcileMember plan cursor
  | internalFirstReconcileCursorPlanDigest cursor /= firstReconcilePlanDigest plan =
      Left FirstReconcileReceiptWrongMember
  | otherwise =
      Right
        (lookupByIndex (internalFirstReconcileCursorNextIndex cursor) (firstReconcilePlanMembers plan))

firstReconcilePriorReceiptDigest
  :: FirstReconcileCursor -> Maybe TargetValueDigest
firstReconcilePriorReceiptDigest = internalFirstReconcileCursorPriorReceipt

advanceFirstReconcileCursor
  :: FirstReconcileProvisioningPlan
  -> FirstReconcileCursor
  -> FirstReconcileReceipt
  -> Either FirstReconcilePlanError FirstReconcileCursor
advanceFirstReconcileCursor plan cursor receipt = do
  next <- nextFirstReconcileMember plan cursor
  member <- maybe (Left FirstReconcilePlanAlreadyComplete) Right next
  unless
    ( firstReconcileReceiptMemberIndex receipt == firstReconcilePlanMemberIndex member
        && firstReconcileReceiptMemberDigest receipt == firstReconcilePlanMemberDigest member
    )
    (Left FirstReconcileReceiptWrongMember)
  pure
    cursor
      { internalFirstReconcileCursorNextIndex = firstReconcilePlanMemberIndex member + 1
      , internalFirstReconcileCursorPriorReceipt = Just (firstReconcileReceiptDigest receipt)
      }

bindPermitToNextFirstReconcileMember
  :: FirstReconcileProvisioningPlan
  -> FirstReconcileCursor
  -> OperatorMaterialRequest 'AwsAdminProvisioningIngress
  -> Either FirstReconcilePlanError FirstReconcilePermitBinding
bindPermitToNextFirstReconcileMember plan cursor request = do
  next <- nextFirstReconcileMember plan cursor
  member <- maybe (Left FirstReconcilePlanAlreadyComplete) Right next
  case firstReconcilePlanMemberAction member of
    EstablishAuthorityBackupMember -> Left FirstReconcileRequestClassMismatch
    ProvisionAwsCredentialMember expectedClass ->
      unless
        (operatorMaterialRequestAwsClass request == Just expectedClass)
        (Left FirstReconcileRequestClassMismatch)
  pure
    FirstReconcilePermitBinding
      { firstReconcilePermitPlanDigest = firstReconcilePlanDigest plan
      , firstReconcilePermitMemberIndex = firstReconcilePlanMemberIndex member
      , firstReconcilePermitMemberDigest = firstReconcilePlanMemberDigest member
      , firstReconcilePermitPriorReceiptDigest = firstReconcilePriorReceiptDigest cursor
      }

planMember
  :: AuthorityTime -> Natural -> FirstReconcilePlanAction -> FirstReconcilePlanMember
planMember deadline index action =
  FirstReconcilePlanMember
    { firstReconcilePlanMemberIndex = index
    , firstReconcilePlanMemberAction = action
    , firstReconcilePlanMemberTarget = actionTarget action
    , firstReconcilePlanMemberDigest =
        sha256Digest
          ( TextEncoding.encodeUtf8
              ( Text.intercalate
                  ":"
                  [ Text.pack (show (authorityTimeMicros deadline))
                  , Text.pack (show index)
                  , Text.pack (show action)
                  , Text.pack (show (actionTarget action))
                  ]
              )
          )
    }

actionTarget :: FirstReconcilePlanAction -> CredentialTarget
actionTarget action = case action of
  EstablishAuthorityBackupMember -> AuthorityBackupStoreTarget
  ProvisionAwsCredentialMember credentialClass ->
    awsCredentialDescriptorTarget (awsCredentialDescriptor credentialClass)

encodePlan :: AuthorityTime -> [FirstReconcilePlanMember] -> ByteString
encodePlan deadline members =
  TextEncoding.encodeUtf8
    ( Text.intercalate
        "|"
        ( Text.pack (show (authorityTimeMicros deadline))
            : [ Text.intercalate
                  ":"
                  [ Text.pack (show (firstReconcilePlanMemberIndex member))
                  , Text.pack (show (firstReconcilePlanMemberAction member))
                  , targetValueDigestText (firstReconcilePlanMemberDigest member)
                  ]
              | member <- members
              ]
        )
    )

lookupByIndex :: Natural -> [FirstReconcilePlanMember] -> Maybe FirstReconcilePlanMember
lookupByIndex wanted = go
 where
  go [] = Nothing
  go (member : rest)
    | firstReconcilePlanMemberIndex member == wanted = Just member
    | otherwise = go rest

firstDuplicate :: (Eq a) => [a] -> Maybe a
firstDuplicate values = go values
 where
  go [] = Nothing
  go (value : rest)
    | value `elem` rest = Just value
    | otherwise = go rest

validateIdentifier
  :: Text -> Int -> Text -> Either OperatorMaterialRequestError Text
validateIdentifier label maximumLength raw
  | Text.null value = Left (OperatorMaterialIdentifierEmpty label)
  | Text.length value > maximumLength =
      Left (OperatorMaterialIdentifierTooLong label (Text.length value) maximumLength)
  | Just unsafe <- Text.find (not . safeIdentifierCharacter) value =
      Left (OperatorMaterialIdentifierUnsafe label unsafe)
  | otherwise = Right value
 where
  value = Text.strip raw

safeIdentifierCharacter :: Char -> Bool
safeIdentifierCharacter character =
  isAsciiLower character
    || isAsciiUpper character
    || isDigit character
    || character `elem` ("-_.:/" :: String)

sha256Digest :: ByteString -> TargetValueDigest
sha256Digest bytes =
  case mkTargetValueDigest rendered of
    Left _ -> error "SHA-256 rendering invariant violated"
    Right digest -> digest
 where
  rendered = Text.pack (concatMap renderByte (ByteString.unpack (SHA256.hash bytes)))
  renderByte byte
    | byte < 16 = '0' : showHex byte ""
    | otherwise = showHex byte ""
