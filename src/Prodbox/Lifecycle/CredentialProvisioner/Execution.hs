{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Bounded one-shot Credential Provisioner interpreter.
--
-- The durable operation/create intent is persisted before the first AWS
-- inventory call.  An ambiguous create is never retried blindly: the finite
-- (maximum-two) inventory is deleted, observed absent twice across the
-- injected provider visibility grace, and reminted at most once.  Completion
-- additionally requires direct Agent handoff/read-back, durable receipt
-- commit, ingress-session revocation, Job deletion, and positive Pod absence.
module Prodbox.Lifecycle.CredentialProvisioner.Execution
  ( OperatorMaterialIngressFrame
  , OperatorMaterialIngressFrameError (..)
  , withAwsAdminIngressFrame
  , encodeExternalAcmeEabIngressFrame
  , withExternalAcmeEabIngressFrame
  , consumeExternalAcmeEabIngressFrame
  , consumeAwsAdminIngressFrame
  , ProvisionerIngressSession
  , mkProvisionerIngressSession
  , ProvisionedAccessKeyId
  , mkProvisionedAccessKeyId
  , provisionedAccessKeyIdText
  , AccessKeyInventoryObservation (..)
  , observedAccessKeyInventory
  , AwsAccessKeyCreateResult (..)
  , OperatorMaterialRevocationReadBack
  , mkOperatorMaterialRevocationReadBack
  , operatorMaterialRevocationTarget
  , operatorMaterialRevocationGeneration
  , RevokedTargetObservation (..)
  , RevokedIdentityObservation (..)
  , CredentialRevocationRefusal (..)
  , decideCredentialRevocationReadBack
  , credentialRevocationReadBackDecisionTable
  , canonicalTargetRevocationReadBackProtocolExists
  , CredentialProvisionerResult (..)
  , CredentialProvisionerBoundary
  , mkCredentialProvisionerBoundary
  , CredentialProvisionerExecutionError (..)
  , GenesisBackupEstablishmentInput
  , genesisBackupEstablishmentPlan
  , genesisBackupEstablishmentTargetReceipt
  , GenesisBackupProvisioningResult
  , genesisBackupProvisioningTargetGenerationReceipt
  , genesisBackupProvisioningEstablishmentInput
  , runGenesisBackupProvisioner
  , runAwsOperatorMaterialProvisioner
  , runExternalAcmeEabProvisioner
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (foldM, unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.Lifecycle.Authority.Genesis
  ( GenesisPlan
  , TargetAgentGenerationReceipt (..)
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (..)
  , CredentialTarget (AuthorityBackupStoreTarget, LifecycleProviderTarget)
  , GenesisBackupPermit
  , GenesisBackupPermitError
  , OperatorMaterialAction (..)
  , OperatorMaterialIngressSchema (..)
  , OperatorMaterialPermit
  , OperatorMaterialRequest
  , genesisBackupPermitBindingDigest
  , genesisBackupPermitGenesisPlan
  , operatorMaterialPermitRequest
  , operatorMaterialRequestAction
  , operatorMaterialRequestAwsClass
  , operatorMaterialRequestGeneration
  , operatorMaterialRequestTarget
  , validateGenesisBackupPermit
  , withGenesisBackupOperatorPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.TargetMaterial
  ( CreatedAwsAccessKey
  , ProvisionedTargetMaterial
  , TargetMaterialClient
  , TargetMaterialClientError
  , TargetMaterialReceipt
  , TargetMaterialValueError (..)
  , createdAwsAccessKeyIdText
  , deriveSesSmtpSource
  , handoffTargetMaterialWithReadBack
  , mkAcmeEabSource
  , mkAwsCredentialMaterial
  , mkTargetMaterialHandoff
  , targetMaterialReceiptGeneration
  , targetMaterialReceiptReadBackVersion
  , targetMaterialReceiptTarget
  )
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , credentialGenerationValue
  , mkCredentialGeneration
  , targetValueDigestText
  )

-- | Opaque secret-bearing ingress.  There is no 'Show', 'Eq', serialization,
-- or byte accessor.  Its only construction is continuation-scoped below.
data
  OperatorMaterialIngressFrame
    (schema :: OperatorMaterialIngressSchema)
  where
  AwsAdminIngressFrame
    :: !ByteString
    -> OperatorMaterialIngressFrame 'AwsAdminProvisioningIngress
  ExternalAcmeEabIngressFrame
    :: !Text
    -> !Text
    -> OperatorMaterialIngressFrame 'ExternalAcmeEabIngress

data OperatorMaterialIngressFrameError
  = OperatorMaterialIngressFrameEmpty
  | OperatorMaterialIngressFrameTooLarge !Int !Int
  | OperatorMaterialIngressFrameDecodeFailed
  | OperatorMaterialIngressFrameUnsupportedVersion !Word16
  | OperatorMaterialIngressFrameFieldInvalid !TargetMaterialValueError
  | OperatorMaterialIngressFrameNonCanonical
  deriving (Eq, Show)

withAwsAdminIngressFrame
  :: ByteString
  -> (OperatorMaterialIngressFrame 'AwsAdminProvisioningIngress -> result)
  -> Either OperatorMaterialIngressFrameError result
withAwsAdminIngressFrame bytes useFrame
  | ByteString.null bytes = Left OperatorMaterialIngressFrameEmpty
  | ByteString.length bytes > awsAdminFrameMaximumBytes =
      Left
        ( OperatorMaterialIngressFrameTooLarge
            (ByteString.length bytes)
            awsAdminFrameMaximumBytes
        )
  | otherwise = Right (useFrame (AwsAdminIngressFrame bytes))

-- | Exact AWS SDK/session bootstrap eliminator.  Keeping it callback-scoped
-- prevents the pure request/permit layer from ever receiving the bytes.
consumeAwsAdminIngressFrame
  :: OperatorMaterialIngressFrame 'AwsAdminProvisioningIngress
  -> (ByteString -> result)
  -> result
consumeAwsAdminIngressFrame (AwsAdminIngressFrame bytes) consume = consume bytes

data WireExternalAcmeEabFrame = WireExternalAcmeEabFrame
  { wireExternalEabVersion :: !Word16
  , wireExternalEabKeyId :: !Text
  , wireExternalEabHmacKey :: !Text
  }
  deriving (Eq, Show, Generic, Serialise)

-- | Canonical host-to-worker payload.  The result must be written only to the
-- attested worker's stdin; it is never a request to the Lifecycle Authority or
-- Target Agent.
encodeExternalAcmeEabIngressFrame
  :: Text -> Text -> Either OperatorMaterialIngressFrameError ByteString
encodeExternalAcmeEabIngressFrame keyId hmacKey = do
  case mkAcmeEabSource keyId hmacKey dummyGeneration of
    Left err -> Left (OperatorMaterialIngressFrameFieldInvalid err)
    Right _ ->
      Right
        ( LazyByteString.toStrict
            ( serialise
                WireExternalAcmeEabFrame
                  { wireExternalEabVersion = externalEabFrameCodecVersion
                  , wireExternalEabKeyId = keyId
                  , wireExternalEabHmacKey = hmacKey
                  }
            )
        )

withExternalAcmeEabIngressFrame
  :: ByteString
  -> (OperatorMaterialIngressFrame 'ExternalAcmeEabIngress -> result)
  -> Either OperatorMaterialIngressFrameError result
withExternalAcmeEabIngressFrame bytes useFrame
  | ByteString.null bytes = Left OperatorMaterialIngressFrameEmpty
  | ByteString.length bytes > externalEabFrameMaximumBytes =
      Left
        ( OperatorMaterialIngressFrameTooLarge
            (ByteString.length bytes)
            externalEabFrameMaximumBytes
        )
  | otherwise = do
      wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left OperatorMaterialIngressFrameDecodeFailed
        Right value -> Right value
      unless
        (wireExternalEabVersion wire == externalEabFrameCodecVersion)
        (Left (OperatorMaterialIngressFrameUnsupportedVersion (wireExternalEabVersion wire)))
      let canonical = LazyByteString.toStrict (serialise wire)
      unless (canonical == bytes) (Left OperatorMaterialIngressFrameNonCanonical)
      -- Reuse the closed payload validator without retaining a material value.
      case mkAcmeEabSource (wireExternalEabKeyId wire) (wireExternalEabHmacKey wire) dummyGeneration of
        Left err -> Left (OperatorMaterialIngressFrameFieldInvalid err)
        Right _ ->
          Right
            ( useFrame
                ( ExternalAcmeEabIngressFrame
                    (wireExternalEabKeyId wire)
                    (wireExternalEabHmacKey wire)
                )
            )

-- | Continuation-scoped worker eliminator.  No accessor returns either
-- plaintext field, and the frame itself has no 'Show', 'Eq', or serialization
-- instance.
consumeExternalAcmeEabIngressFrame
  :: OperatorMaterialIngressFrame 'ExternalAcmeEabIngress
  -> (Text -> Text -> result)
  -> result
consumeExternalAcmeEabIngressFrame (ExternalAcmeEabIngressFrame keyId hmacKey) consume =
  consume keyId hmacKey

awsAdminFrameMaximumBytes :: Int
awsAdminFrameMaximumBytes = 16 * 1024

externalEabFrameMaximumBytes :: Int
externalEabFrameMaximumBytes = 8 * 1024

externalEabFrameCodecVersion :: Word16
externalEabFrameCodecVersion = 1

-- Validation only requires a positive generation.  This value never escapes
-- and is replaced with the request generation during execution.
dummyGeneration :: CredentialGeneration
dummyGeneration =
  case mkCredentialGeneration 1 of
    Left _ -> error "positive credential generation invariant violated"
    Right generation -> generation

newtype
  ProvisionerIngressSession
    (schema :: OperatorMaterialIngressSchema)
  = ProvisionerIngressSession Text

mkProvisionerIngressSession
  :: Text -> Either CredentialProvisionerExecutionError (ProvisionerIngressSession schema)
mkProvisionerIngressSession raw
  | Text.null value = Left CredentialProvisionerSessionIdentityInvalid
  | Text.length value > 512 = Left CredentialProvisionerSessionIdentityInvalid
  | otherwise = Right (ProvisionerIngressSession value)
 where
  value = Text.strip raw

newtype ProvisionedAccessKeyId = ProvisionedAccessKeyId Text
  deriving (Eq, Ord, Show)

mkProvisionedAccessKeyId
  :: Text -> Either CredentialProvisionerExecutionError ProvisionedAccessKeyId
mkProvisionedAccessKeyId raw
  | Text.null value = Left CredentialProvisionerAccessKeyIdInvalid
  | Text.length value > 256 = Left CredentialProvisionerAccessKeyIdInvalid
  | Text.any (not . safe) value = Left CredentialProvisionerAccessKeyIdInvalid
  | otherwise = Right (ProvisionedAccessKeyId value)
 where
  value = Text.strip raw
  safe character =
    isAsciiLower character || isAsciiUpper character || isDigit character

provisionedAccessKeyIdText :: ProvisionedAccessKeyId -> Text
provisionedAccessKeyIdText (ProvisionedAccessKeyId value) = value

data AccessKeyInventoryObservation
  = AccessKeyInventoryObserved ![ProvisionedAccessKeyId]
  | AccessKeyInventoryUnobservable !Text
  | AccessKeyInventoryOverBound !Int
  deriving (Eq, Show)

observedAccessKeyInventory
  :: [ProvisionedAccessKeyId] -> AccessKeyInventoryObservation
observedAccessKeyInventory keys
  | length unique > iamAccessKeyMaximum = AccessKeyInventoryOverBound (length unique)
  | otherwise = AccessKeyInventoryObserved unique
 where
  unique = sort (nub keys)

iamAccessKeyMaximum :: Int
iamAccessKeyMaximum = 2

data AwsAccessKeyCreateResult
  = AwsAccessKeyCreated !ProvisionedAccessKeyId !CreatedAwsAccessKey
  | AwsAccessKeyCreateResponseLost
  | AwsAccessKeyCreateFailed !Text

data OperatorMaterialRevocationReadBack = OperatorMaterialRevocationReadBack
  { internalOperatorMaterialRevocationTarget :: !CredentialTarget
  , internalOperatorMaterialRevocationGeneration :: !CredentialGeneration
  , internalOperatorMaterialRevocationExternalIdentityAbsent :: !Bool
  , internalOperatorMaterialRevocationTargetGenerationAbsent :: !Bool
  }
  deriving (Eq, Show)

mkOperatorMaterialRevocationReadBack
  :: CredentialTarget
  -> CredentialGeneration
  -> Bool
  -> Bool
  -> Either CredentialProvisionerExecutionError OperatorMaterialRevocationReadBack
mkOperatorMaterialRevocationReadBack target generation externalAbsent targetAbsent
  | externalAbsent && targetAbsent =
      Right
        OperatorMaterialRevocationReadBack
          { internalOperatorMaterialRevocationTarget = target
          , internalOperatorMaterialRevocationGeneration = generation
          , internalOperatorMaterialRevocationExternalIdentityAbsent = True
          , internalOperatorMaterialRevocationTargetGenerationAbsent = True
          }
  | otherwise = Left CredentialProvisionerRevocationNotReadBack

-- | What re-observing the revoked target generation found.
--
-- Sprint 4.85: a revoke response is the worker's own claim about work it just
-- performed.  Independent absence is a separate observation, and the three
-- answers are kept distinct so an unobservable target can never be read as an
-- absent one.
data RevokedTargetObservation
  = RevokedTargetUnobservable
  | RevokedTargetStillPresent
  | RevokedTargetAbsent
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | What re-observing the external identity found after the destroy.
--
-- 'RevokedIdentityNotReached' is a real answer: the identity step is not
-- attempted while the target generation is unobservable or still present, and
-- the decision below has to be total over that case rather than pretending an
-- unattempted step was an unobservable one.
data RevokedIdentityObservation
  = RevokedIdentityNotReached
  | RevokedIdentityUnobservable
  | RevokedIdentityStillPresent
  | RevokedIdentityAbsent
  deriving (Bounded, Enum, Eq, Ord, Show)

data CredentialRevocationRefusal
  = RevocationTargetUnobservable
  | RevocationTargetStillPresent
  | RevocationIdentityNotReached
  | RevocationIdentityUnobservable
  | RevocationIdentityStillPresent
  | -- | Both absences were observed but the canonical binder refused.
    -- Unreachable while both are @True@; named rather than assumed so the
    -- binding below stays load-bearing.
    RevocationNotBound
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | The canonical target revocation read-back decision.
--
-- This is the protocol @CanonicalTargetRevocationReadBackUnavailable@ named as
-- missing: before it, the only production revocation path took the revoke
-- response as evidence that the target generation was gone, so an applied-but-
-- unconfirmed revoke and a confirmed one were the same value.  Both the fenced
-- Admin-worker path and this module's pure algebra now decide through one
-- function over one closed observation product, and the read-back is minted
-- only from two independent absences.
decideCredentialRevocationReadBack
  :: CredentialTarget
  -> CredentialGeneration
  -> RevokedTargetObservation
  -> RevokedIdentityObservation
  -> Either CredentialRevocationRefusal OperatorMaterialRevocationReadBack
decideCredentialRevocationReadBack target generation targetObservation identityObservation =
  case targetObservation of
    RevokedTargetUnobservable -> Left RevocationTargetUnobservable
    RevokedTargetStillPresent -> Left RevocationTargetStillPresent
    RevokedTargetAbsent -> case identityObservation of
      RevokedIdentityNotReached -> Left RevocationIdentityNotReached
      RevokedIdentityUnobservable -> Left RevocationIdentityUnobservable
      RevokedIdentityStillPresent -> Left RevocationIdentityStillPresent
      RevokedIdentityAbsent ->
        either
          (const (Left RevocationNotBound))
          Right
          (mkOperatorMaterialRevocationReadBack target generation True True)

-- | Every observation pair and whether the canonical decision mints a
-- read-back for it.  Enumerable, so the protocol's discrimination is a
-- measurement rather than a claim.
credentialRevocationReadBackDecisionTable
  :: CredentialTarget
  -> CredentialGeneration
  -> [((RevokedTargetObservation, RevokedIdentityObservation), Bool)]
credentialRevocationReadBackDecisionTable target generation =
  [ ( (targetObservation, identityObservation)
    , either
        (const False)
        (const True)
        ( decideCredentialRevocationReadBack
            target
            generation
            targetObservation
            identityObservation
        )
    )
  | targetObservation <- [minBound .. maxBound]
  , identityObservation <- [minBound .. maxBound]
  ]

-- | Does a canonical target revocation read-back protocol exist?
--
-- True exactly when the decision admits one observation pair out of the twelve
-- — both absences independently observed — so a protocol that had drifted into
-- accepting an unobservable or still-present target stops satisfying it.
canonicalTargetRevocationReadBackProtocolExists :: Bool
canonicalTargetRevocationReadBackProtocolExists =
  [pair | (pair, minted) <- table, minted]
    == [(RevokedTargetAbsent, RevokedIdentityAbsent)]
 where
  table =
    credentialRevocationReadBackDecisionTable
      LifecycleProviderTarget
      dummyGeneration

operatorMaterialRevocationTarget
  :: OperatorMaterialRevocationReadBack -> CredentialTarget
operatorMaterialRevocationTarget = internalOperatorMaterialRevocationTarget

operatorMaterialRevocationGeneration
  :: OperatorMaterialRevocationReadBack -> CredentialGeneration
operatorMaterialRevocationGeneration = internalOperatorMaterialRevocationGeneration

data CredentialProvisionerResult
  = CredentialProvisionerInstalled !TargetMaterialReceipt
  | CredentialProvisionerRevoked !OperatorMaterialRevocationReadBack
  deriving (Eq, Show)

-- | Secret-free input to the Authority Backup Adapter after the initial
-- credential generation has been committed and read back by the home Target
-- Agent.  Only the genesis entry below can construct it.
data GenesisBackupEstablishmentInput = GenesisBackupEstablishmentInput
  { internalGenesisBackupEstablishmentPlan :: !GenesisPlan
  , internalGenesisBackupEstablishmentTargetReceipt :: !TargetMaterialReceipt
  }
  deriving (Eq, Show)

genesisBackupEstablishmentPlan :: GenesisBackupEstablishmentInput -> GenesisPlan
genesisBackupEstablishmentPlan = internalGenesisBackupEstablishmentPlan

genesisBackupEstablishmentTargetReceipt
  :: GenesisBackupEstablishmentInput -> TargetMaterialReceipt
genesisBackupEstablishmentTargetReceipt = internalGenesisBackupEstablishmentTargetReceipt

data GenesisBackupProvisioningResult = GenesisBackupProvisioningResult
  { internalGenesisBackupProvisioningTargetGenerationReceipt
      :: !TargetAgentGenerationReceipt
  , internalGenesisBackupProvisioningEstablishmentInput
      :: !GenesisBackupEstablishmentInput
  }
  deriving (Eq, Show)

genesisBackupProvisioningTargetGenerationReceipt
  :: GenesisBackupProvisioningResult -> TargetAgentGenerationReceipt
genesisBackupProvisioningTargetGenerationReceipt =
  internalGenesisBackupProvisioningTargetGenerationReceipt

genesisBackupProvisioningEstablishmentInput
  :: GenesisBackupProvisioningResult -> GenesisBackupEstablishmentInput
genesisBackupProvisioningEstablishmentInput =
  internalGenesisBackupProvisioningEstablishmentInput

-- | All AWS callbacks are instantiated for the exact descriptor named by the
-- permit.  They therefore accept neither an IAM principal nor policy name.
data CredentialProvisionerBoundary m = CredentialProvisionerBoundary
  { internalBeginAwsIngressSession
      :: OperatorMaterialIngressFrame 'AwsAdminProvisioningIngress
      -> m
           ( Either
               Text
               (ProvisionerIngressSession 'AwsAdminProvisioningIngress)
           )
  , internalBeginExternalEabIngressSession
      :: OperatorMaterialIngressFrame 'ExternalAcmeEabIngress
      -> m
           ( Either
               Text
               (ProvisionerIngressSession 'ExternalAcmeEabIngress)
           )
  , internalPersistAwsCreateIntent
      :: OperatorMaterialPermit 'AwsAdminProvisioningIngress
      -> m (Either Text ())
  , internalObserveAccessKeyInventory
      :: ProvisionerIngressSession 'AwsAdminProvisioningIngress
      -> m AccessKeyInventoryObservation
  , internalDeleteAccessKey
      :: ProvisionerIngressSession 'AwsAdminProvisioningIngress
      -> ProvisionedAccessKeyId
      -> m (Either Text ())
  , internalWaitProviderVisibilityGrace :: m (Either Text ())
  , internalCreateAccessKey
      :: ProvisionerIngressSession 'AwsAdminProvisioningIngress
      -> m AwsAccessKeyCreateResult
  , internalRevokeAwsTarget
      :: ProvisionerIngressSession 'AwsAdminProvisioningIngress
      -> OperatorMaterialPermit 'AwsAdminProvisioningIngress
      -> m (Either Text OperatorMaterialRevocationReadBack)
  , internalRevokeExternalEabTarget
      :: ProvisionerIngressSession 'ExternalAcmeEabIngress
      -> OperatorMaterialPermit 'ExternalAcmeEabIngress
      -> m (Either Text OperatorMaterialRevocationReadBack)
  , internalCommitTargetReceipt :: TargetMaterialReceipt -> m (Either Text ())
  , internalCommitRevocationReceipt
      :: OperatorMaterialRevocationReadBack
      -> m (Either Text ())
  , internalRevokeAwsIngressSession
      :: ProvisionerIngressSession 'AwsAdminProvisioningIngress
      -> m (Either Text ())
  , internalRevokeExternalEabIngressSession
      :: ProvisionerIngressSession 'ExternalAcmeEabIngress
      -> m (Either Text ())
  , internalDeleteProvisionerJob :: m (Either Text ())
  , internalObserveProvisionerPodAbsent :: m (Either Text Bool)
  }

mkCredentialProvisionerBoundary
  :: ( OperatorMaterialIngressFrame 'AwsAdminProvisioningIngress
       -> m (Either Text (ProvisionerIngressSession 'AwsAdminProvisioningIngress))
     )
  -> ( OperatorMaterialIngressFrame 'ExternalAcmeEabIngress
       -> m (Either Text (ProvisionerIngressSession 'ExternalAcmeEabIngress))
     )
  -> (OperatorMaterialPermit 'AwsAdminProvisioningIngress -> m (Either Text ()))
  -> ( ProvisionerIngressSession 'AwsAdminProvisioningIngress
       -> m AccessKeyInventoryObservation
     )
  -> ( ProvisionerIngressSession 'AwsAdminProvisioningIngress
       -> ProvisionedAccessKeyId
       -> m (Either Text ())
     )
  -> m (Either Text ())
  -> ( ProvisionerIngressSession 'AwsAdminProvisioningIngress
       -> m AwsAccessKeyCreateResult
     )
  -> ( ProvisionerIngressSession 'AwsAdminProvisioningIngress
       -> OperatorMaterialPermit 'AwsAdminProvisioningIngress
       -> m (Either Text OperatorMaterialRevocationReadBack)
     )
  -> ( ProvisionerIngressSession 'ExternalAcmeEabIngress
       -> OperatorMaterialPermit 'ExternalAcmeEabIngress
       -> m (Either Text OperatorMaterialRevocationReadBack)
     )
  -> (TargetMaterialReceipt -> m (Either Text ()))
  -> (OperatorMaterialRevocationReadBack -> m (Either Text ()))
  -> ( ProvisionerIngressSession 'AwsAdminProvisioningIngress
       -> m (Either Text ())
     )
  -> ( ProvisionerIngressSession 'ExternalAcmeEabIngress
       -> m (Either Text ())
     )
  -> m (Either Text ())
  -> m (Either Text Bool)
  -> CredentialProvisionerBoundary m
mkCredentialProvisionerBoundary = CredentialProvisionerBoundary

data CredentialProvisionerExecutionError
  = CredentialProvisionerSessionIdentityInvalid
  | CredentialProvisionerAccessKeyIdInvalid
  | CredentialProvisionerIngressSessionFailed !Text
  | CredentialProvisionerIntentPersistFailed !Text
  | CredentialProvisionerInventoryUnobservable !Text
  | CredentialProvisionerInventoryOverBound !Int
  | CredentialProvisionerDeleteFailed !ProvisionedAccessKeyId !Text
  | CredentialProvisionerVisibilityWaitFailed !Text
  | CredentialProvisionerStableAbsenceNotProven
  | CredentialProvisionerInstallRequiresEmptyInventory
  | CredentialProvisionerRotationRequiresRetirementProtocol
  | CredentialProvisionerCreateFailed !Text
  | CredentialProvisionerCreatedAccessKeyIdMismatch
  | CredentialProvisionerCreatedAccessKeyNotReadBack
  | CredentialProvisionerRecoveryRemintAmbiguous
  | CredentialProvisionerRequestClassMissing
  | CredentialProvisionerMaterialInvalid !TargetMaterialValueError
  | CredentialProvisionerHandoffInvalid !TargetMaterialValueError
  | CredentialProvisionerTargetClientFailed !TargetMaterialClientError
  | CredentialProvisionerReceiptMismatch
  | CredentialProvisionerReceiptCommitFailed !Text
  | CredentialProvisionerRevocationFailed !Text
  | CredentialProvisionerRevocationNotReadBack
  | CredentialProvisionerSessionRevokeFailed !Text
  | CredentialProvisionerJobDeleteFailed !Text
  | CredentialProvisionerPodAbsenceUnobservable !Text
  | CredentialProvisionerPodStillPresent
  | CredentialProvisionerGenesisPermitInvalid !GenesisBackupPermitError
  | CredentialProvisionerUnexpectedGenesisRevocation
  deriving (Eq, Show)

-- | The sole initial Authority-backup install path.  It validates the opaque
-- genesis permit before opening ingress, then delegates to the same persisted-
-- intent, bounded-inventory, lost-response recovery, direct Target-Agent
-- handoff/read-back, receipt commit, session revoke, Job delete, and Pod-
-- absence interpreter used by ordinary AWS material.  The exceptional normal
-- permit is continuation-scoped and never returned to the caller.
runGenesisBackupProvisioner
  :: (Monad m)
  => CredentialProvisionerBoundary m
  -> TargetMaterialClient m
  -> Text
  -> AuthorityTime
  -> GenesisBackupPermit
  -> OperatorMaterialIngressFrame 'AwsAdminProvisioningIngress
  -> m (Either CredentialProvisionerExecutionError GenesisBackupProvisioningResult)
runGenesisBackupProvisioner boundary targetClient region now permit frame =
  case validateGenesisBackupPermit now permit of
    Left err -> do
      cleanup <- cleanupWorkload boundary Nothing Nothing
      pure
        ( mergeGenesisCleanup
            (Left (CredentialProvisionerGenesisPermitInvalid err))
            cleanup
        )
    Right () ->
      withGenesisBackupOperatorPermit permit $ \operatorPermit -> do
        provisioned <-
          runAwsOperatorMaterialProvisioner
            boundary
            targetClient
            region
            operatorPermit
            frame
        pure $ case provisioned of
          Left err -> Left err
          Right (CredentialProvisionerRevoked _) ->
            Left CredentialProvisionerUnexpectedGenesisRevocation
          Right (CredentialProvisionerInstalled receipt)
            | targetMaterialReceiptTarget receipt /= AuthorityBackupStoreTarget ->
                Left CredentialProvisionerReceiptMismatch
            | otherwise ->
                let generationReceipt = genesisGenerationReceipt permit receipt
                 in Right
                      GenesisBackupProvisioningResult
                        { internalGenesisBackupProvisioningTargetGenerationReceipt =
                            generationReceipt
                        , internalGenesisBackupProvisioningEstablishmentInput =
                            GenesisBackupEstablishmentInput
                              { internalGenesisBackupEstablishmentPlan =
                                  genesisBackupPermitGenesisPlan permit
                              , internalGenesisBackupEstablishmentTargetReceipt = receipt
                              }
                        }

genesisGenerationReceipt
  :: GenesisBackupPermit
  -> TargetMaterialReceipt
  -> TargetAgentGenerationReceipt
genesisGenerationReceipt permit receipt =
  TargetAgentGenerationReceipt
    ( Text.intercalate
        ":"
        [ "authority-backup-store"
        , Text.pack
            (show (credentialGenerationValue (targetMaterialReceiptGeneration receipt)))
        , Text.pack (show (targetMaterialReceiptReadBackVersion receipt))
        , targetValueDigestText (genesisBackupPermitBindingDigest permit)
        ]
    )

mergeGenesisCleanup
  :: Either CredentialProvisionerExecutionError GenesisBackupProvisioningResult
  -> Either CredentialProvisionerExecutionError ()
  -> Either CredentialProvisionerExecutionError GenesisBackupProvisioningResult
mergeGenesisCleanup mainResult cleanup = case cleanup of
  Left cleanupError -> Left cleanupError
  Right () -> mainResult

runAwsOperatorMaterialProvisioner
  :: (Monad m)
  => CredentialProvisionerBoundary m
  -> TargetMaterialClient m
  -> Text
  -> OperatorMaterialPermit 'AwsAdminProvisioningIngress
  -> OperatorMaterialIngressFrame 'AwsAdminProvisioningIngress
  -> m (Either CredentialProvisionerExecutionError CredentialProvisionerResult)
runAwsOperatorMaterialProvisioner boundary targetClient region permit frame = do
  opened <- internalBeginAwsIngressSession boundary frame
  case opened of
    Left detail -> do
      cleanup <- cleanupWorkload boundary Nothing Nothing
      pure (mergeCleanup (Left (CredentialProvisionerIngressSessionFailed detail)) cleanup)
    Right session -> do
      mainResult <- runAwsWithSession boundary targetClient region permit session
      cleanup <- cleanupWorkload boundary (Just session) Nothing
      pure (mergeCleanup mainResult cleanup)

runExternalAcmeEabProvisioner
  :: (Monad m)
  => CredentialProvisionerBoundary m
  -> TargetMaterialClient m
  -> OperatorMaterialPermit 'ExternalAcmeEabIngress
  -> OperatorMaterialIngressFrame 'ExternalAcmeEabIngress
  -> m (Either CredentialProvisionerExecutionError CredentialProvisionerResult)
runExternalAcmeEabProvisioner boundary targetClient permit frame = do
  opened <- internalBeginExternalEabIngressSession boundary frame
  case opened of
    Left detail -> do
      cleanup <- cleanupWorkload boundary Nothing Nothing
      pure (mergeCleanup (Left (CredentialProvisionerIngressSessionFailed detail)) cleanup)
    Right session -> do
      mainResult <- case operatorMaterialRequestAction request of
        RevokeOperatorMaterial -> do
          revoked <- internalRevokeExternalEabTarget boundary session permit
          commitRevocation boundary request revoked
        InstallOperatorMaterial -> installExternal session
        RotateOperatorMaterial -> installExternal session
      cleanup <- cleanupWorkload boundary Nothing (Just session)
      pure (mergeCleanup mainResult cleanup)
 where
  request = operatorMaterialPermitRequest permit
  installExternal _session = case frame of
    ExternalAcmeEabIngressFrame keyId hmacKey ->
      case mkAcmeEabSource keyId hmacKey (operatorMaterialRequestGeneration request) of
        Left err -> pure (Left (CredentialProvisionerMaterialInvalid err))
        Right material -> deliverAndCommit boundary targetClient permit material

runAwsWithSession
  :: (Monad m)
  => CredentialProvisionerBoundary m
  -> TargetMaterialClient m
  -> Text
  -> OperatorMaterialPermit 'AwsAdminProvisioningIngress
  -> ProvisionerIngressSession 'AwsAdminProvisioningIngress
  -> m (Either CredentialProvisionerExecutionError CredentialProvisionerResult)
runAwsWithSession boundary targetClient region permit session = do
  case operatorMaterialRequestAction request of
    RevokeOperatorMaterial -> do
      revoked <- internalRevokeAwsTarget boundary session permit
      commitRevocation boundary request revoked
    -- Rotation needs a committed-current key binding plus post-delivery
    -- retirement ordering.  Until that protocol is installed it is
    -- unrepresentable at this interpreter boundary; an install must prove the
    -- dedicated principal's finite inventory is already empty and may never
    -- delete a live generation to make room.
    RotateOperatorMaterial ->
      pure (Left CredentialProvisionerRotationRequiresRetirementProtocol)
    InstallOperatorMaterial -> do
      persisted <- internalPersistAwsCreateIntent boundary permit
      case persisted of
        Left detail -> pure (Left (CredentialProvisionerIntentPersistFailed detail))
        Right () -> do
          empty <- proveStableEmptyInventory boundary session
          case empty of
            Left err -> pure (Left err)
            Right () -> createAndDeliver False
 where
  request = operatorMaterialPermitRequest permit
  createAndDeliver isRecovery = do
    created <- internalCreateAccessKey boundary session
    case created of
      AwsAccessKeyCreateFailed detail ->
        pure (Left (CredentialProvisionerCreateFailed detail))
      AwsAccessKeyCreated keyId createdKey
        | provisionedAccessKeyIdText keyId /= createdAwsAccessKeyIdText createdKey ->
            pure (Left CredentialProvisionerCreatedAccessKeyIdMismatch)
        | otherwise -> do
            confirmed <- observeCreatedKey boundary session keyId
            case confirmed of
              Left err -> pure (Left err)
              Right () ->
                case targetMaterialForRequest region request createdKey of
                  Left err -> pure (Left (CredentialProvisionerMaterialInvalid err))
                  Right material -> deliverAndCommit boundary targetClient permit material
      AwsAccessKeyCreateResponseLost
        | isRecovery -> pure (Left CredentialProvisionerRecoveryRemintAmbiguous)
        | otherwise -> do
            recovered <-
              cleanAndProveStableAbsence boundary session stableCleanupRoundMaximum
            case recovered of
              Left err -> pure (Left err)
              Right () -> createAndDeliver True

targetMaterialForRequest
  :: Text
  -> OperatorMaterialRequest 'AwsAdminProvisioningIngress
  -> CreatedAwsAccessKey
  -> Either
       TargetMaterialValueError
       (ProvisionedTargetMaterial 'AwsAdminProvisioningIngress)
targetMaterialForRequest region request created =
  case operatorMaterialRequestAwsClass request of
    Nothing -> Left TargetMaterialClassMismatch
    Just SesSmtpRetainedCustodyCredential ->
      deriveSesSmtpSource region generation created
    Just credentialClass ->
      mkAwsCredentialMaterial credentialClass region generation created
 where
  generation = operatorMaterialRequestGeneration request

cleanAndProveStableAbsence
  :: (Monad m)
  => CredentialProvisionerBoundary m
  -> ProvisionerIngressSession 'AwsAdminProvisioningIngress
  -> Int
  -> m (Either CredentialProvisionerExecutionError ())
cleanAndProveStableAbsence boundary session roundsRemaining
  | roundsRemaining <= 0 = pure (Left CredentialProvisionerStableAbsenceNotProven)
  | otherwise = do
      firstObservation <- internalObserveAccessKeyInventory boundary session
      case inventoryKeys firstObservation of
        Left err -> pure (Left err)
        Right keys -> do
          deleted <- deleteAll keys
          case deleted of
            Left err -> pure (Left err)
            Right () -> do
              waited <- internalWaitProviderVisibilityGrace boundary
              case waited of
                Left detail -> pure (Left (CredentialProvisionerVisibilityWaitFailed detail))
                Right () -> do
                  secondObservation <- internalObserveAccessKeyInventory boundary session
                  case inventoryKeys secondObservation of
                    Left err -> pure (Left err)
                    Right []
                      | null keys -> pure (Right ())
                      | otherwise ->
                          cleanAndProveStableAbsence boundary session (roundsRemaining - 1)
                    Right remaining -> do
                      deletedRemaining <- deleteAll remaining
                      case deletedRemaining of
                        Left err -> pure (Left err)
                        Right () ->
                          cleanAndProveStableAbsence boundary session (roundsRemaining - 1)
 where
  deleteAll keys =
    foldM
      deleteOne
      (Right ())
      keys
  deleteOne result keyId = case result of
    Left err -> pure (Left err)
    Right () -> do
      deleted <- internalDeleteAccessKey boundary session keyId
      pure $ case deleted of
        Left detail -> Left (CredentialProvisionerDeleteFailed keyId detail)
        Right () -> Right ()

proveStableEmptyInventory
  :: (Monad m)
  => CredentialProvisionerBoundary m
  -> ProvisionerIngressSession 'AwsAdminProvisioningIngress
  -> m (Either CredentialProvisionerExecutionError ())
proveStableEmptyInventory boundary session = do
  first <- internalObserveAccessKeyInventory boundary session
  case inventoryKeys first of
    Left err -> pure (Left err)
    Right [] -> do
      waited <- internalWaitProviderVisibilityGrace boundary
      case waited of
        Left detail -> pure (Left (CredentialProvisionerVisibilityWaitFailed detail))
        Right () -> do
          second <- internalObserveAccessKeyInventory boundary session
          pure $ case inventoryKeys second of
            Left err -> Left err
            Right [] -> Right ()
            Right _ -> Left CredentialProvisionerInstallRequiresEmptyInventory
    Right _ -> pure (Left CredentialProvisionerInstallRequiresEmptyInventory)

observeCreatedKey
  :: (Monad m)
  => CredentialProvisionerBoundary m
  -> ProvisionerIngressSession 'AwsAdminProvisioningIngress
  -> ProvisionedAccessKeyId
  -> m (Either CredentialProvisionerExecutionError ())
observeCreatedKey boundary session expected = do
  observed <- internalObserveAccessKeyInventory boundary session
  pure $ case inventoryKeys observed of
    Left err -> Left err
    Right [actual]
      | actual == expected -> Right ()
    Right _ -> Left CredentialProvisionerCreatedAccessKeyNotReadBack

stableCleanupRoundMaximum :: Int
stableCleanupRoundMaximum = 4

inventoryKeys
  :: AccessKeyInventoryObservation
  -> Either CredentialProvisionerExecutionError [ProvisionedAccessKeyId]
inventoryKeys observation = case observation of
  AccessKeyInventoryObserved keys -> Right keys
  AccessKeyInventoryUnobservable detail ->
    Left (CredentialProvisionerInventoryUnobservable detail)
  AccessKeyInventoryOverBound count ->
    Left (CredentialProvisionerInventoryOverBound count)

deliverAndCommit
  :: (Monad m)
  => CredentialProvisionerBoundary m
  -> TargetMaterialClient m
  -> OperatorMaterialPermit schema
  -> ProvisionedTargetMaterial schema
  -> m (Either CredentialProvisionerExecutionError CredentialProvisionerResult)
deliverAndCommit boundary targetClient permit material =
  case mkTargetMaterialHandoff permit material of
    Left err -> pure (Left (CredentialProvisionerHandoffInvalid err))
    Right handoff -> do
      delivered <- handoffTargetMaterialWithReadBack targetClient handoff
      case delivered of
        Left err -> pure (Left (CredentialProvisionerTargetClientFailed err))
        Right receipt
          | targetMaterialReceiptTarget receipt /= operatorMaterialRequestTarget request
              || targetMaterialReceiptGeneration receipt
                /= operatorMaterialRequestGeneration request ->
              pure (Left CredentialProvisionerReceiptMismatch)
          | otherwise -> do
              committed <- internalCommitTargetReceipt boundary receipt
              pure $ case committed of
                Left detail -> Left (CredentialProvisionerReceiptCommitFailed detail)
                Right () -> Right (CredentialProvisionerInstalled receipt)
 where
  request = operatorMaterialPermitRequest permit

commitRevocation
  :: (Monad m)
  => CredentialProvisionerBoundary m
  -> OperatorMaterialRequest schema
  -> Either Text OperatorMaterialRevocationReadBack
  -> m (Either CredentialProvisionerExecutionError CredentialProvisionerResult)
commitRevocation boundary request revoked = case revoked of
  Left detail -> pure (Left (CredentialProvisionerRevocationFailed detail))
  Right receipt
    | operatorMaterialRevocationTarget receipt /= operatorMaterialRequestTarget request
        || operatorMaterialRevocationGeneration receipt
          /= operatorMaterialRequestGeneration request ->
        pure (Left CredentialProvisionerReceiptMismatch)
    | otherwise -> do
        committed <- internalCommitRevocationReceipt boundary receipt
        pure $ case committed of
          Left detail -> Left (CredentialProvisionerReceiptCommitFailed detail)
          Right () -> Right (CredentialProvisionerRevoked receipt)

cleanupWorkload
  :: (Monad m)
  => CredentialProvisionerBoundary m
  -> Maybe (ProvisionerIngressSession 'AwsAdminProvisioningIngress)
  -> Maybe (ProvisionerIngressSession 'ExternalAcmeEabIngress)
  -> m (Either CredentialProvisionerExecutionError ())
cleanupWorkload boundary awsSession externalSession = do
  revoked <- case (awsSession, externalSession) of
    (Just session, Nothing) -> internalRevokeAwsIngressSession boundary session
    (Nothing, Just session) -> internalRevokeExternalEabIngressSession boundary session
    (Nothing, Nothing) -> pure (Right ())
    (Just _, Just _) -> pure (Left "multiple ingress sessions are impossible")
  case revoked of
    Left detail -> pure (Left (CredentialProvisionerSessionRevokeFailed detail))
    Right () -> do
      deleted <- internalDeleteProvisionerJob boundary
      case deleted of
        Left detail -> pure (Left (CredentialProvisionerJobDeleteFailed detail))
        Right () -> do
          absent <- internalObserveProvisionerPodAbsent boundary
          pure $ case absent of
            Left detail -> Left (CredentialProvisionerPodAbsenceUnobservable detail)
            Right False -> Left CredentialProvisionerPodStillPresent
            Right True -> Right ()

mergeCleanup
  :: Either CredentialProvisionerExecutionError CredentialProvisionerResult
  -> Either CredentialProvisionerExecutionError ()
  -> Either CredentialProvisionerExecutionError CredentialProvisionerResult
mergeCleanup mainResult cleanup = case cleanup of
  Left cleanupError -> Left cleanupError
  Right () -> mainResult
