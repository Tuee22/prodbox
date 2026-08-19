{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Native IAM/S3 execution for a verified AWS-admin permit.  The caller must
-- first durably prepare the exact selected Target outbox; that observation is
-- threaded linearly into delivery, so the worker cannot choose a cluster,
-- Agent, target, generation, or receipt digest at execution time.
module Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( PreparedCredentialTargetObservation
  , mkPreparedCredentialTargetObservation
  , preparedCredentialTargetOwnerNonce
  , preparedCredentialTargetFence
  , preparedCredentialTargetSelectedAgent
  , preparedCredentialTargetId
  , preparedCredentialTargetGeneration
  , preparedCredentialTargetRequestDigest
  , preparedCredentialTargetReceiptDigest
  , preparedCredentialTargetPlanBinding
  , preparedCredentialTargetDeadline
  , AwsAdminIamBoundary
  , mkAwsAdminIamBoundary
  , productionAwsAdminIamBoundary
  , AwsAdminDeliveryBoundary (..)
  , mkAwsAdminDeliveryBoundary
  , AwsAdminExecutionJournalBoundary
  , mkAwsAdminExecutionJournalBoundary
  , AwsAdminWorkerReceipt
  , AwsAdminWorkerReceiptKind (..)
  , awsAdminWorkerReceiptKind
  , awsAdminWorkerReceiptPermitId
  , awsAdminWorkerReceiptRequestDigest
  , awsAdminWorkerReceiptTarget
  , awsAdminWorkerReceiptGeneration
  , awsAdminWorkerReceiptTargetReadBack
  , encodeAwsAdminWorkerReceipt
  , decodeAwsAdminWorkerReceipt
  , validateAwsAdminWorkerReceiptForPermit
  , executeAwsAdminPermit
  , AwsAdminExecutionError (..)
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (foldM, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl, isSpace)
import Data.List (sort)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16, Word8)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity (..)
  , TargetSecretId (..)
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( TargetWorkerReceipt
  , decodeTargetWorkerReceipt
  , encodeTargetWorkerReceipt
  , targetWorkerReceiptGeneration
  , targetWorkerReceiptTarget
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecutionJournal
  ( AwsAdminExecutionEvent (..)
  , AwsAdminExecutionJournal
  , AwsAdminExecutionPhase (..)
  , awsAdminExecutionJournalPermit
  , awsAdminExecutionJournalPhase
  , stepAwsAdminExecutionJournal
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( SignedAwsAdminPermit
  , awsAdminPermitIntentAction
  , awsAdminPermitIntentCredentialClass
  , awsAdminPermitIntentDeadline
  , awsAdminPermitIntentGeneration
  , awsAdminPermitIntentIamParameters
  , awsAdminPermitIntentPermitId
  , awsAdminPermitIntentPlanBinding
  , awsAdminPermitIntentPreparedTarget
  , awsAdminPermitIntentRequestDigest
  , credentialIamParametersRegion
  , signedAwsAdminPermitIntent
  )
import Prodbox.Lifecycle.CredentialProvisioner.Execution
  ( AccessKeyInventoryObservation (..)
  , AwsAccessKeyCreateResult (..)
  , CredentialRevocationRefusal (..)
  , ProvisionedAccessKeyId
  , RevokedIdentityObservation (..)
  , RevokedTargetObservation (..)
  , decideCredentialRevocationReadBack
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (..)
  , OperatorMaterialAction (..)
  , OperatorMaterialIngressSchema (AwsAdminProvisioningIngress)
  , awsCredentialDescriptor
  , awsCredentialDescriptorTarget
  , operatorMaterialPermitIdText
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
  ( ProductionIamSession
  , createProductionAccessKey
  , deleteProductionAccessKey
  , destroyProductionIamIdentity
  , ensureProductionIamPrerequisites
  , observeProductionAccessKeyInventory
  , observeProductionIamIdentityAbsent
  , waitProductionIamVisibilityGrace
  )
import Prodbox.Lifecycle.CredentialProvisioner.TargetMaterial
  ( CreatedAwsAccessKey
  , ProvisionedTargetMaterial
  , TargetMaterialValueError
  , deriveSesSmtpSource
  , mkAwsCredentialMaterial
  )
import Prodbox.Lifecycle.Lease (authorityTimeMicros)
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  , credentialGenerationValue
  , mkCredentialGeneration
  , mkTargetValueDigest
  , targetValueDigestText
  )

data AwsAdminIamBoundary m = AwsAdminIamBoundary
  { internalEnsureIamPrerequisites :: m (Either Text ())
  , internalObserveIamKeys :: m AccessKeyInventoryObservation
  , internalDeleteIamKey :: ProvisionedAccessKeyId -> m (Either Text ())
  , internalCreateIamKey :: m AwsAccessKeyCreateResult
  , internalDestroyIamIdentity :: m (Either Text ())
  , internalObserveIamIdentityAbsent :: m (Either Text Bool)
  , internalWaitIamVisibilityGrace :: m (Either Text ())
  }

mkAwsAdminIamBoundary
  :: m (Either Text ())
  -> m AccessKeyInventoryObservation
  -> (ProvisionedAccessKeyId -> m (Either Text ()))
  -> m AwsAccessKeyCreateResult
  -> m (Either Text ())
  -> m (Either Text Bool)
  -> m (Either Text ())
  -> AwsAdminIamBoundary m
mkAwsAdminIamBoundary = AwsAdminIamBoundary

productionAwsAdminIamBoundary :: ProductionIamSession -> AwsAdminIamBoundary IO
productionAwsAdminIamBoundary session =
  AwsAdminIamBoundary
    { internalEnsureIamPrerequisites =
        either (Left . boundedShow) Right <$> ensureProductionIamPrerequisites session
    , internalObserveIamKeys = observeProductionAccessKeyInventory session
    , internalDeleteIamKey = deleteProductionAccessKey session
    , internalCreateIamKey = createProductionAccessKey session
    , internalDestroyIamIdentity =
        either (Left . boundedShow) Right <$> destroyProductionIamIdentity session
    , internalObserveIamIdentityAbsent = do
        result <- observeProductionIamIdentityAbsent session
        pure $ case result of
          Left err -> Left (boundedShow err)
          Right () -> Right True
    , internalWaitIamVisibilityGrace = waitProductionIamVisibilityGrace
    }

data AwsAdminDeliveryBoundary m = AwsAdminDeliveryBoundary
  { internalDeliverCredentialTarget
      :: PreparedCredentialTargetObservation
      -> SignedAwsAdminPermit
      -> ProvisionedTargetMaterial 'AwsAdminProvisioningIngress
      -> m (Either Text TargetWorkerReceipt)
  , internalRevokeCredentialTarget
      :: PreparedCredentialTargetObservation
      -> SignedAwsAdminPermit
      -> m (Either Text Text)
  , internalObserveCredentialTarget
      :: PreparedCredentialTargetObservation
      -> SignedAwsAdminPermit
      -> m (Either Text (Maybe TargetWorkerReceipt))
  }

mkAwsAdminDeliveryBoundary
  :: ( PreparedCredentialTargetObservation
       -> SignedAwsAdminPermit
       -> ProvisionedTargetMaterial 'AwsAdminProvisioningIngress
       -> m (Either Text TargetWorkerReceipt)
     )
  -> ( PreparedCredentialTargetObservation
       -> SignedAwsAdminPermit
       -> m (Either Text Text)
     )
  -> ( PreparedCredentialTargetObservation
       -> SignedAwsAdminPermit
       -> m (Either Text (Maybe TargetWorkerReceipt))
     )
  -> AwsAdminDeliveryBoundary m
mkAwsAdminDeliveryBoundary = AwsAdminDeliveryBoundary

data AwsAdminExecutionJournalBoundary m = AwsAdminExecutionJournalBoundary
  { internalReadExecutionJournal
      :: m (Either Text AwsAdminExecutionJournal)
  , internalCommitExecutionJournal
      :: AwsAdminExecutionJournal
      -> AwsAdminExecutionJournal
      -> m (Either Text AwsAdminExecutionJournal)
  }

mkAwsAdminExecutionJournalBoundary
  :: m (Either Text AwsAdminExecutionJournal)
  -> ( AwsAdminExecutionJournal
       -> AwsAdminExecutionJournal
       -> m (Either Text AwsAdminExecutionJournal)
     )
  -> AwsAdminExecutionJournalBoundary m
mkAwsAdminExecutionJournalBoundary = AwsAdminExecutionJournalBoundary

data AwsAdminWorkerReceiptKind
  = AwsAdminInstalled
  | AwsAdminRevoked
  deriving stock (Eq, Show, Enum, Bounded)

data AwsAdminWorkerReceipt = AwsAdminWorkerReceipt
  { internalAwsAdminWorkerReceiptKind :: !AwsAdminWorkerReceiptKind
  , internalAwsAdminWorkerReceiptPermitId :: !Text
  , internalAwsAdminWorkerReceiptRequestDigest :: !TargetValueDigest
  , internalAwsAdminWorkerReceiptTarget :: !TargetSecretId
  , internalAwsAdminWorkerReceiptGeneration :: !CredentialGeneration
  , internalAwsAdminWorkerReceiptTargetReadBack :: !ByteString
  }
  deriving stock (Eq, Show)

data WireAwsAdminWorkerReceipt = WireAwsAdminWorkerReceipt
  { wireWorkerReceiptVersion :: !Word16
  , wireWorkerReceiptKind :: !Word8
  , wireWorkerReceiptPermitId :: !Text
  , wireWorkerReceiptRequestDigest :: !Text
  , wireWorkerReceiptTarget :: !TargetSecretId
  , wireWorkerReceiptGeneration :: !Natural
  , wireWorkerReceiptTargetReadBack :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

awsAdminWorkerReceiptVersion :: Word16
awsAdminWorkerReceiptVersion = 1

awsAdminWorkerReceiptMaximumBytes :: Int
awsAdminWorkerReceiptMaximumBytes = 32 * 1024

awsAdminWorkerReceiptKind :: AwsAdminWorkerReceipt -> AwsAdminWorkerReceiptKind
awsAdminWorkerReceiptKind = internalAwsAdminWorkerReceiptKind

awsAdminWorkerReceiptPermitId :: AwsAdminWorkerReceipt -> Text
awsAdminWorkerReceiptPermitId = internalAwsAdminWorkerReceiptPermitId

awsAdminWorkerReceiptRequestDigest :: AwsAdminWorkerReceipt -> TargetValueDigest
awsAdminWorkerReceiptRequestDigest = internalAwsAdminWorkerReceiptRequestDigest

awsAdminWorkerReceiptTarget :: AwsAdminWorkerReceipt -> TargetSecretId
awsAdminWorkerReceiptTarget = internalAwsAdminWorkerReceiptTarget

awsAdminWorkerReceiptGeneration :: AwsAdminWorkerReceipt -> CredentialGeneration
awsAdminWorkerReceiptGeneration = internalAwsAdminWorkerReceiptGeneration

awsAdminWorkerReceiptTargetReadBack :: AwsAdminWorkerReceipt -> ByteString
awsAdminWorkerReceiptTargetReadBack = internalAwsAdminWorkerReceiptTargetReadBack

encodeAwsAdminWorkerReceipt :: AwsAdminWorkerReceipt -> ByteString
encodeAwsAdminWorkerReceipt = LazyByteString.toStrict . serialise . receiptToWire

decodeAwsAdminWorkerReceipt
  :: ByteString -> Either AwsAdminExecutionError AwsAdminWorkerReceipt
decodeAwsAdminWorkerReceipt bytes = do
  when
    (ByteString.length bytes > awsAdminWorkerReceiptMaximumBytes)
    ( Left
        ( AwsAdminWorkerReceiptTooLarge
            (ByteString.length bytes)
            awsAdminWorkerReceiptMaximumBytes
        )
    )
  wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
    Left _ -> Left AwsAdminWorkerReceiptDecodeFailed
    Right value -> Right value
  unless
    (wireWorkerReceiptVersion wire == awsAdminWorkerReceiptVersion)
    (Left (AwsAdminWorkerReceiptUnsupportedVersion (wireWorkerReceiptVersion wire)))
  receipt <- receiptFromWire wire
  unless
    (encodeAwsAdminWorkerReceipt receipt == bytes)
    (Left AwsAdminWorkerReceiptNonCanonical)
  pure receipt

executeAwsAdminPermit
  :: (Monad m)
  => AwsAdminExecutionJournalBoundary m
  -> AwsAdminIamBoundary m
  -> AwsAdminDeliveryBoundary m
  -> SignedAwsAdminPermit
  -> m (Either AwsAdminExecutionError AwsAdminWorkerReceipt)
executeAwsAdminPermit journalBoundary iam delivery permit = do
  observed <- internalReadExecutionJournal journalBoundary
  case observed of
    Left detail -> pure (Left (AwsAdminExecutionJournalUnavailable detail))
    Right journal
      | awsAdminExecutionJournalPermit journal /= permit ->
          pure (Left AwsAdminExecutionJournalPermitMismatch)
      | otherwise -> driveExecution (32 :: Int) journal
 where
  intent = signedAwsAdminPermitIntent permit
  prepared = awsAdminPermitIntentPreparedTarget intent
  expectedTarget = targetForClass (awsAdminPermitIntentCredentialClass intent)

  driveExecution remaining journal
    | remaining <= 0 = pure (Left AwsAdminExecutionTransitionLimitReached)
    | otherwise = case validatePreparedTarget permit expectedTarget prepared of
        Left err -> pure (Left err)
        Right () -> case awsAdminExecutionJournalPhase journal of
          AwsAdminExecutionComplete receiptBytes ->
            pure $ do
              receipt <- decodeAwsAdminWorkerReceipt receiptBytes
              validateWorkerReceiptForPermit permit prepared receipt
              Right receipt
          AwsAdminExecutionIntentCommitted recoveryUsed ->
            case awsAdminPermitIntentAction intent of
              RevokeOperatorMaterial -> do
                result <- revokeIdentity iam delivery permit prepared
                case result of
                  Left err -> pure (Left err)
                  Right receipt -> completeJournal remaining journal receipt
              action -> do
                prerequisites <- internalEnsureIamPrerequisites iam
                case prerequisites of
                  Left detail -> pure (Left (AwsAdminIamPrerequisiteFailed detail))
                  Right () -> do
                    inventory <- observeKeys iam
                    case inventory of
                      Left err -> pure (Left err)
                      Right keys -> case action of
                        InstallOperatorMaterial
                          | null keys -> prepareAttempt remaining journal [] recoveryUsed
                          | recoveryUsed -> requireCleanup remaining journal recoveryUsed
                          | otherwise -> pure (Left AwsAdminInstallRequiresEmptyInventory)
                        RotateOperatorMaterial
                          | recoveryUsed && null keys ->
                              prepareAttempt remaining journal [] recoveryUsed
                          | not recoveryUsed && length keys <= 1 ->
                              prepareAttempt remaining journal keys recoveryUsed
                          | otherwise -> requireCleanup remaining journal recoveryUsed
          AwsAdminExecutionCreateAttemptPrepared predecessors recoveryUsed ->
            resumePreparedAttempt remaining journal predecessors recoveryUsed
          AwsAdminExecutionKeyCreated keyId predecessors recoveryUsed ->
            resolveCreatedKey remaining journal keyId predecessors recoveryUsed Nothing
          AwsAdminExecutionTargetCommitted keyId predecessors targetReceipt _ ->
            finishCommittedTarget remaining journal keyId predecessors targetReceipt
          AwsAdminExecutionCleanupRequired recoveryUsed -> do
            cleaned <- cleanAndProveStableAbsence iam cleanupRoundMaximum
            case cleaned of
              Left err -> pure (Left err)
              Right () -> do
                next <- commitJournalEvent journal (CommitAwsAdminStableCleanup recoveryUsed)
                either (pure . Left) (driveExecution (remaining - 1)) next
          AwsAdminExecutionCleanupProven recoveryUsed
            | recoveryUsed -> pure (Left AwsAdminRecoveryRemintAmbiguous)
            | otherwise -> do
                next <- commitJournalEvent journal RestartAwsAdminAfterCleanup
                either (pure . Left) (driveExecution (remaining - 1)) next

  prepareAttempt remaining journal predecessors recoveryUsed = do
    next <-
      commitJournalEvent
        journal
        (CommitAwsAdminCreateAttempt predecessors recoveryUsed)
    either (pure . Left) (driveExecution (remaining - 1)) next

  resumePreparedAttempt remaining journal predecessors recoveryUsed = do
    first <- observeKeys iam
    case first of
      Left err -> pure (Left err)
      Right keys
        | keys == sort predecessors -> do
            waited <- internalWaitIamVisibilityGrace iam
            case waited of
              Left detail -> pure (Left (AwsAdminVisibilityWaitFailed detail))
              Right () -> do
                stable <- observeKeys iam
                case stable of
                  Left err -> pure (Left err)
                  Right confirmed
                    | confirmed == sort predecessors ->
                        createForPreparedAttempt remaining journal predecessors recoveryUsed
                    | otherwise ->
                        classifyPreparedInventory remaining journal predecessors recoveryUsed confirmed
        | otherwise ->
            classifyPreparedInventory remaining journal predecessors recoveryUsed keys

  classifyPreparedInventory remaining journal predecessors recoveryUsed keys =
    case [key | key <- keys, key `notElem` predecessors] of
      [created]
        | all (`elem` keys) predecessors
            && length keys == length predecessors + 1 -> do
            next <-
              commitJournalEvent
                journal
                (CommitAwsAdminCreatedKey created predecessors recoveryUsed)
            either (pure . Left) (driveExecution (remaining - 1)) next
      _ -> requireCleanup remaining journal recoveryUsed

  createForPreparedAttempt remaining journal predecessors recoveryUsed = do
    created <- internalCreateIamKey iam
    case created of
      AwsAccessKeyCreateFailed detail -> pure (Left (AwsAdminCreateKeyFailed detail))
      AwsAccessKeyCreateResponseLost -> requireCleanup remaining journal recoveryUsed
      AwsAccessKeyCreated keyId material
        | keyId `elem` predecessors -> requireCleanup remaining journal recoveryUsed
        | otherwise -> do
            next <-
              commitJournalEvent
                journal
                (CommitAwsAdminCreatedKey keyId predecessors recoveryUsed)
            case next of
              Left err -> pure (Left err)
              Right createdJournal ->
                resolveCreatedKey
                  (remaining - 1)
                  createdJournal
                  keyId
                  predecessors
                  recoveryUsed
                  (Just material)

  resolveCreatedKey remaining journal keyId predecessors recoveryUsed maybeMaterial = do
    observedTarget <- internalObserveCredentialTarget delivery prepared permit
    case observedTarget of
      Left detail -> pure (Left (AwsAdminTargetObservationUnobservable detail))
      Right (Just targetReceipt) -> commitObservedTarget targetReceipt
      Right Nothing -> case maybeMaterial of
        Nothing -> requireCleanup remaining journal recoveryUsed
        Just material -> case materialForPermit permit material of
          Left err -> requireCleanupAfter (AwsAdminMaterialInvalid err)
          Right targetMaterial -> do
            delivered <-
              internalDeliverCredentialTarget delivery prepared permit targetMaterial
            case delivered of
              Right targetReceipt -> commitObservedTarget targetReceipt
              Left deliveryDetail -> do
                readBack <- internalObserveCredentialTarget delivery prepared permit
                case readBack of
                  Left detail ->
                    pure
                      ( Left
                          ( AwsAdminTargetObservationUnobservable
                              (Text.take 128 deliveryDetail <> "; " <> Text.take 128 detail)
                          )
                      )
                  Right (Just targetReceipt) -> commitObservedTarget targetReceipt
                  Right Nothing -> requireCleanupAfter (AwsAdminTargetDeliveryFailed deliveryDetail)
   where
    commitObservedTarget targetReceipt = case validateTargetReceipt permit prepared targetReceipt of
      Left err -> requireCleanupAfter err
      Right () -> do
        next <-
          commitJournalEvent
            journal
            ( CommitAwsAdminTargetReceipt
                keyId
                predecessors
                targetReceipt
                recoveryUsed
            )
        either (pure . Left) (driveExecution (remaining - 1)) next
    requireCleanupAfter _ = requireCleanup remaining journal recoveryUsed

  finishCommittedTarget remaining journal keyId predecessors targetReceipt = do
    deleted <- deletePredecessors keyId predecessors
    case deleted of
      Left err -> pure (Left err)
      Right () -> do
        observed <- observeExpectedKeys iam [keyId]
        case observed of
          Left err -> pure (Left err)
          Right () ->
            completeJournal remaining journal (installedReceipt permit prepared targetReceipt)

  deletePredecessors keyId =
    foldM
      (deletePredecessor keyId)
      (Right ())
  deletePredecessor keyId result predecessor = case result of
    Left err -> pure (Left err)
    Right ()
      | predecessor == keyId -> pure (Right ())
      | otherwise -> do
          deleted <- internalDeleteIamKey iam predecessor
          pure (either (Left . AwsAdminDeleteKeyFailed) Right deleted)

  requireCleanup remaining journal recoveryUsed = do
    next <-
      commitJournalEvent journal (RequireAwsAdminStableCleanup recoveryUsed)
    either (pure . Left) (driveExecution (remaining - 1)) next

  completeJournal remaining journal receipt = do
    next <-
      commitJournalEvent
        journal
        (CompleteAwsAdminExecution (encodeAwsAdminWorkerReceipt receipt))
    either (pure . Left) (driveExecution (remaining - 1)) next

  commitJournalEvent journal event = case stepAwsAdminExecutionJournal event journal of
    Left err -> pure (Left (AwsAdminExecutionJournalTransitionRejected (Text.pack (show err))))
    Right expected -> do
      committed <-
        internalCommitExecutionJournal journalBoundary journal expected
      pure $ case committed of
        Left detail -> Left (AwsAdminExecutionJournalCommitFailed detail)
        Right readBack
          | readBack == expected -> Right readBack
          | otherwise -> Left AwsAdminExecutionJournalReadBackMismatch

-- | Revoke one credential identity, reading __both__ absences back.
--
-- Sprint 4.85 (2026-08-18): the revoke response used to be the only evidence
-- that the target generation was gone.  @internalRevokeCredentialTarget@
-- returns the worker's own claim about work it just performed, and a claim is
-- not a read-back — which is what
-- @CanonicalTargetRevocationReadBackUnavailable@ named.  The target is now
-- re-observed through the same boundary the delivery path already uses to
-- distinguish present from absent, and a still-present generation is a
-- refusal rather than a successful revocation.
--
-- The two absences are then bound by 'mkOperatorMaterialRevocationReadBack',
-- the smart constructor the pure provisioner algebra already uses, so
-- \"revocation read-back\" has one definition across both paths instead of one
-- per path.  It refuses unless the external identity and the target generation
-- are __both__ independently observed absent, so neither half can stand in for
-- the other.
--
-- Ordering is deliberate: the target generation is revoked and read back
-- before the IAM identity is destroyed.  A run that fails in between leaves an
-- identity with no usable material rather than material with no identity to
-- revoke it under.
revokeIdentity
  :: (Monad m)
  => AwsAdminIamBoundary m
  -> AwsAdminDeliveryBoundary m
  -> SignedAwsAdminPermit
  -> PreparedCredentialTargetObservation
  -> m (Either AwsAdminExecutionError AwsAdminWorkerReceipt)
revokeIdentity iam delivery permit prepared = do
  targetResult <- internalRevokeCredentialTarget delivery prepared permit
  case targetResult of
    Left detail -> pure (Left (AwsAdminTargetRevocationFailed detail))
    Right evidence -> do
      observedTarget <- internalObserveCredentialTarget delivery prepared permit
      case observedTarget of
        Left detail ->
          pure
            ( decide
                evidence
                RevokedTargetUnobservable
                RevokedIdentityNotReached
                (Just detail)
            )
        Right (Just _) ->
          pure
            ( decide
                evidence
                RevokedTargetStillPresent
                RevokedIdentityNotReached
                Nothing
            )
        Right Nothing -> do
          destroyed <- internalDestroyIamIdentity iam
          case destroyed of
            Left detail -> pure (Left (AwsAdminIdentityDestroyFailed detail))
            Right () -> do
              absent <- internalObserveIamIdentityAbsent iam
              pure $ case absent of
                Left detail ->
                  decide
                    evidence
                    RevokedTargetAbsent
                    RevokedIdentityUnobservable
                    (Just detail)
                Right False ->
                  decide
                    evidence
                    RevokedTargetAbsent
                    RevokedIdentityStillPresent
                    Nothing
                Right True ->
                  decide evidence RevokedTargetAbsent RevokedIdentityAbsent Nothing
 where
  -- Both outcomes come from the canonical decision rather than from local
  -- guards, so this path and the pure provisioner algebra cannot drift apart
  -- about what a revocation read-back is.
  decide evidence targetObservation identityObservation detail =
    case decideCredentialRevocationReadBack
      (awsCredentialDescriptorTarget (awsCredentialDescriptor credentialClass))
      (preparedCredentialTargetGeneration prepared)
      targetObservation
      identityObservation of
      Left refusal -> Left (revocationRefusalError refusal detail)
      Right _ ->
        Right
          AwsAdminWorkerReceipt
            { internalAwsAdminWorkerReceiptKind = AwsAdminRevoked
            , internalAwsAdminWorkerReceiptPermitId = permitIdText permit
            , internalAwsAdminWorkerReceiptRequestDigest = permitRequestDigest permit
            , internalAwsAdminWorkerReceiptTarget = preparedCredentialTargetId prepared
            , internalAwsAdminWorkerReceiptGeneration =
                preparedCredentialTargetGeneration prepared
            , internalAwsAdminWorkerReceiptTargetReadBack =
                LazyByteString.toStrict (serialise evidence)
            }

  credentialClass =
    awsAdminPermitIntentCredentialClass (signedAwsAdminPermitIntent permit)

-- | Total over the canonical refusals.  The optional detail is the boundary
-- text for the two unobservable arms; the others carry no boundary message
-- because nothing failed to answer.
revocationRefusalError
  :: CredentialRevocationRefusal -> Maybe Text -> AwsAdminExecutionError
revocationRefusalError refusal detail = case refusal of
  RevocationTargetUnobservable ->
    AwsAdminTargetRevocationUnobservable (fromMaybe "" detail)
  RevocationTargetStillPresent -> AwsAdminTargetGenerationStillPresent
  RevocationIdentityNotReached -> AwsAdminTargetGenerationStillPresent
  RevocationIdentityUnobservable ->
    AwsAdminIdentityAbsenceUnobservable (fromMaybe "" detail)
  RevocationIdentityStillPresent -> AwsAdminIdentityStillPresent
  RevocationNotBound -> AwsAdminRevocationNotReadBack

materialForPermit
  :: SignedAwsAdminPermit
  -> CreatedAwsAccessKey
  -> Either
       TargetMaterialValueError
       (ProvisionedTargetMaterial 'AwsAdminProvisioningIngress)
materialForPermit permit created = case credentialClass of
  SesSmtpRetainedCustodyCredential -> deriveSesSmtpSource region generation created
  _ -> mkAwsCredentialMaterial credentialClass region generation created
 where
  intent = signedAwsAdminPermitIntent permit
  credentialClass = awsAdminPermitIntentCredentialClass intent
  generation = awsAdminPermitIntentGeneration intent
  region = credentialIamParametersRegion (awsAdminPermitIntentIamParameters intent)

validatePreparedTarget
  :: SignedAwsAdminPermit
  -> TargetSecretId
  -> PreparedCredentialTargetObservation
  -> Either AwsAdminExecutionError ()
validatePreparedTarget permit expectedTarget prepared = do
  unless
    ( prepared == awsAdminPermitIntentPreparedTarget intent
        && preparedCredentialTargetId prepared == expectedTarget
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
    (Left AwsAdminPreparedTargetMismatch)
 where
  intent = signedAwsAdminPermitIntent permit

validateTargetReceipt
  :: SignedAwsAdminPermit
  -> PreparedCredentialTargetObservation
  -> TargetWorkerReceipt
  -> Either AwsAdminExecutionError ()
validateTargetReceipt _ prepared receipt =
  unless
    ( targetWorkerReceiptTarget receipt == preparedCredentialTargetId prepared
        && targetWorkerReceiptGeneration receipt
          == preparedCredentialTargetGeneration prepared
    )
    (Left AwsAdminTargetReceiptMismatch)

installedReceipt
  :: SignedAwsAdminPermit
  -> PreparedCredentialTargetObservation
  -> TargetWorkerReceipt
  -> AwsAdminWorkerReceipt
installedReceipt permit prepared targetReceipt =
  AwsAdminWorkerReceipt
    { internalAwsAdminWorkerReceiptKind = AwsAdminInstalled
    , internalAwsAdminWorkerReceiptPermitId = permitIdText permit
    , internalAwsAdminWorkerReceiptRequestDigest = permitRequestDigest permit
    , internalAwsAdminWorkerReceiptTarget = preparedCredentialTargetId prepared
    , internalAwsAdminWorkerReceiptGeneration = preparedCredentialTargetGeneration prepared
    , internalAwsAdminWorkerReceiptTargetReadBack = encodeTargetWorkerReceipt targetReceipt
    }

validateWorkerReceiptForPermit
  :: SignedAwsAdminPermit
  -> PreparedCredentialTargetObservation
  -> AwsAdminWorkerReceipt
  -> Either AwsAdminExecutionError ()
validateWorkerReceiptForPermit permit prepared receipt = do
  unless
    ( awsAdminWorkerReceiptPermitId receipt == permitIdText permit
        && awsAdminWorkerReceiptRequestDigest receipt == permitRequestDigest permit
        && awsAdminWorkerReceiptTarget receipt == preparedCredentialTargetId prepared
        && awsAdminWorkerReceiptGeneration receipt
          == preparedCredentialTargetGeneration prepared
        && not (ByteString.null (awsAdminWorkerReceiptTargetReadBack receipt))
    )
    (Left AwsAdminWorkerReceiptInvalid)
  case awsAdminWorkerReceiptKind receipt of
    AwsAdminInstalled -> do
      targetReceipt <-
        either
          (const (Left AwsAdminWorkerReceiptInvalid))
          Right
          (decodeTargetWorkerReceipt (awsAdminWorkerReceiptTargetReadBack receipt))
      validateTargetReceipt permit prepared targetReceipt
    AwsAdminRevoked -> pure ()

-- | Authority-side terminal validation.  The exact prepared outbox is part of
-- the signed permit, so a worker cannot substitute a caller-supplied target
-- observation while committing its receipt.
validateAwsAdminWorkerReceiptForPermit
  :: SignedAwsAdminPermit
  -> AwsAdminWorkerReceipt
  -> Either AwsAdminExecutionError ()
validateAwsAdminWorkerReceiptForPermit permit =
  validateWorkerReceiptForPermit permit prepared
 where
  prepared =
    awsAdminPermitIntentPreparedTarget (signedAwsAdminPermitIntent permit)

cleanAndProveStableAbsence
  :: (Monad m)
  => AwsAdminIamBoundary m
  -> Int
  -> m (Either AwsAdminExecutionError ())
cleanAndProveStableAbsence iam rounds
  | rounds <= 0 = pure (Left AwsAdminStableAbsenceNotProven)
  | otherwise = do
      observed <- observeKeys iam
      case observed of
        Left err -> pure (Left err)
        Right keys -> do
          deleted <- deleteAll keys
          case deleted of
            Left err -> pure (Left err)
            Right () -> do
              waited <- internalWaitIamVisibilityGrace iam
              case waited of
                Left detail -> pure (Left (AwsAdminVisibilityWaitFailed detail))
                Right () -> do
                  next <- observeKeys iam
                  case next of
                    Left err -> pure (Left err)
                    Right [] -> pure (Right ())
                    Right _ -> cleanAndProveStableAbsence iam (rounds - 1)
 where
  deleteAll =
    foldM
      deleteOne
      (Right ())
  deleteOne result key = case result of
    Left err -> pure (Left err)
    Right () -> do
      deleted <- internalDeleteIamKey iam key
      pure (either (Left . AwsAdminDeleteKeyFailed) Right deleted)

observeExpectedKeys
  :: (Monad m)
  => AwsAdminIamBoundary m
  -> [ProvisionedAccessKeyId]
  -> m (Either AwsAdminExecutionError ())
observeExpectedKeys iam expected = do
  observed <- observeKeys iam
  pure $ do
    actual <- observed
    unless (actual == sort expected) (Left AwsAdminCreatedKeyNotReadBack)

observeKeys
  :: (Monad m)
  => AwsAdminIamBoundary m
  -> m (Either AwsAdminExecutionError [ProvisionedAccessKeyId])
observeKeys iam = do
  observed <- internalObserveIamKeys iam
  pure $ case observed of
    AccessKeyInventoryObserved keys -> Right (sort keys)
    AccessKeyInventoryUnobservable detail -> Left (AwsAdminInventoryUnobservable detail)
    AccessKeyInventoryOverBound count -> Left (AwsAdminInventoryOverBound count)

targetForClass :: AwsCredentialClass -> TargetSecretId
targetForClass credentialClass = case credentialClass of
  LifecycleProviderCredential -> TargetAwsCredential AwsLifecycleProvider
  AuthorityBackupStoreCredential -> TargetAwsCredential AwsAuthorityBackupStore
  TlsRetentionStoreCredential -> TargetAwsCredential AwsTlsRetentionStore
  GatewayDnsCredential -> TargetAwsCredential AwsGatewayDns
  HomeCertManagerDns01Credential -> TargetAwsCredential AwsHomeCertManagerDns01
  AwsRunCertManagerDns01Credential -> TargetAwsCredential AwsRunCertManagerDns01
  SesSmtpRetainedCustodyCredential -> TargetSesSmtp

permitIdText :: SignedAwsAdminPermit -> Text
permitIdText =
  operatorMaterialPermitIdText
    . awsAdminPermitIntentPermitId
    . signedAwsAdminPermitIntent

permitRequestDigest :: SignedAwsAdminPermit -> TargetValueDigest
permitRequestDigest =
  awsAdminPermitIntentRequestDigest . signedAwsAdminPermitIntent

receiptToWire :: AwsAdminWorkerReceipt -> WireAwsAdminWorkerReceipt
receiptToWire receipt =
  WireAwsAdminWorkerReceipt
    { wireWorkerReceiptVersion = awsAdminWorkerReceiptVersion
    , wireWorkerReceiptKind = fromIntegral (fromEnum (awsAdminWorkerReceiptKind receipt) + 1)
    , wireWorkerReceiptPermitId = awsAdminWorkerReceiptPermitId receipt
    , wireWorkerReceiptRequestDigest =
        targetValueDigestText (awsAdminWorkerReceiptRequestDigest receipt)
    , wireWorkerReceiptTarget = awsAdminWorkerReceiptTarget receipt
    , wireWorkerReceiptGeneration =
        credentialGenerationValue (awsAdminWorkerReceiptGeneration receipt)
    , wireWorkerReceiptTargetReadBack = awsAdminWorkerReceiptTargetReadBack receipt
    }

receiptFromWire
  :: WireAwsAdminWorkerReceipt -> Either AwsAdminExecutionError AwsAdminWorkerReceipt
receiptFromWire wire = do
  kind <- case wireWorkerReceiptKind wire of
    1 -> Right AwsAdminInstalled
    2 -> Right AwsAdminRevoked
    _ -> Left AwsAdminWorkerReceiptInvalid
  permitId <- validateIdentity "permit-id" 160 (wireWorkerReceiptPermitId wire)
  requestDigest <-
    either
      (const (Left AwsAdminWorkerReceiptInvalid))
      Right
      (mkTargetValueDigest (wireWorkerReceiptRequestDigest wire))
  generation <-
    either
      (const (Left AwsAdminWorkerReceiptInvalid))
      Right
      (mkCredentialGeneration (wireWorkerReceiptGeneration wire))
  when
    (ByteString.null (wireWorkerReceiptTargetReadBack wire))
    (Left AwsAdminWorkerReceiptInvalid)
  case kind of
    AwsAdminInstalled -> do
      targetReceipt <-
        either
          (const (Left AwsAdminWorkerReceiptInvalid))
          Right
          (decodeTargetWorkerReceipt (wireWorkerReceiptTargetReadBack wire))
      unless
        ( targetWorkerReceiptTarget targetReceipt == wireWorkerReceiptTarget wire
            && targetWorkerReceiptGeneration targetReceipt == generation
        )
        (Left AwsAdminWorkerReceiptInvalid)
    AwsAdminRevoked -> pure ()
  pure
    AwsAdminWorkerReceipt
      { internalAwsAdminWorkerReceiptKind = kind
      , internalAwsAdminWorkerReceiptPermitId = permitId
      , internalAwsAdminWorkerReceiptRequestDigest = requestDigest
      , internalAwsAdminWorkerReceiptTarget = wireWorkerReceiptTarget wire
      , internalAwsAdminWorkerReceiptGeneration = generation
      , internalAwsAdminWorkerReceiptTargetReadBack = wireWorkerReceiptTargetReadBack wire
      }

cleanupRoundMaximum :: Int
cleanupRoundMaximum = 4

validateIdentity
  :: Text -> Int -> Text -> Either AwsAdminExecutionError Text
validateIdentity _ maximumLength raw
  | Text.null value = Left AwsAdminPreparedTargetInvalid
  | Text.length value > maximumLength = Left AwsAdminPreparedTargetInvalid
  | Text.any (\character -> isControl character || isSpace character) value =
      Left AwsAdminPreparedTargetInvalid
  | otherwise = Right value
 where
  value = Text.strip raw

boundedShow :: (Show value) => value -> Text
boundedShow = Text.take 256 . Text.pack . show

data AwsAdminExecutionError
  = AwsAdminPreparedTargetInvalid
  | AwsAdminPreparedTargetMismatch
  | AwsAdminPrepareTargetFailed !Text
  | AwsAdminExecutionJournalUnavailable !Text
  | AwsAdminExecutionJournalPermitMismatch
  | AwsAdminExecutionJournalTransitionRejected !Text
  | AwsAdminExecutionJournalCommitFailed !Text
  | AwsAdminExecutionJournalReadBackMismatch
  | AwsAdminExecutionTransitionLimitReached
  | AwsAdminIamPrerequisiteFailed !Text
  | AwsAdminInventoryUnobservable !Text
  | AwsAdminInventoryOverBound !Int
  | AwsAdminInstallRequiresEmptyInventory
  | AwsAdminDeleteKeyFailed !Text
  | AwsAdminCreateKeyFailed !Text
  | AwsAdminCreatedKeyNotReadBack
  | AwsAdminVisibilityWaitFailed !Text
  | AwsAdminStableAbsenceNotProven
  | AwsAdminRecoveryRemintAmbiguous
  | AwsAdminMaterialInvalid !TargetMaterialValueError
  | AwsAdminTargetDeliveryFailed !Text
  | AwsAdminTargetObservationUnobservable !Text
  | AwsAdminTargetReceiptMismatch
  | AwsAdminTargetRevocationFailed !Text
  | -- | Sprint 4.85: the revoked target generation could not be re-observed,
    -- so the revocation has no independent read-back.
    AwsAdminTargetRevocationUnobservable !Text
  | -- | Sprint 4.85: the target generation is still present after a revoke
    -- the worker reported as applied.
    AwsAdminTargetGenerationStillPresent
  | -- | Sprint 4.85: both absences were observed but the canonical revocation
    -- read-back refused to bind them.  Unreachable while both are @True@;
    -- mapped rather than assumed so the binding stays load-bearing.
    AwsAdminRevocationNotReadBack
  | AwsAdminIdentityDestroyFailed !Text
  | AwsAdminIdentityAbsenceUnobservable !Text
  | AwsAdminIdentityStillPresent
  | AwsAdminWorkerReceiptTooLarge !Int !Int
  | AwsAdminWorkerReceiptDecodeFailed
  | AwsAdminWorkerReceiptUnsupportedVersion !Word16
  | AwsAdminWorkerReceiptNonCanonical
  | AwsAdminWorkerReceiptInvalid
  deriving stock (Eq, Show)
