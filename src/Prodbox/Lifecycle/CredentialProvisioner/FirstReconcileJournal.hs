{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Durable, receipt-ordered first-reconcile progress.
--
-- The Authority commits this value before advancing to the next credential
-- permit.  Recovery therefore resumes from the exact next member and prior
-- receipt digest instead of replaying an already-completed IAM mutation.  The
-- wire format contains no credential material: only the deterministic plan,
-- opaque target read-back commitments, and their digests are retained.
module Prodbox.Lifecycle.CredentialProvisioner.FirstReconcileJournal
  ( FirstReconcileJournal
  , FirstReconcileJournalError (..)
  , initialFirstReconcileJournal
  , firstReconcileJournalPlan
  , firstReconcileJournalCursor
  , firstReconcileJournalReceipts
  , firstReconcileJournalComplete
  , appendFirstReconcileReceipt
  , encodeFirstReconcileJournal
  , decodeFirstReconcileJournal
  , firstReconcileJournalCodec
  , FirstReconcileJournalStoreError (..)
  , FirstReconcileJournalStoreResult (..)
  , initializeFirstReconcileJournalStore
  , appendFirstReconcileJournalStore
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (foldM, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (find)
import Data.Text (Text)
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (..)
  , FirstReconcileCursor
  , FirstReconcilePlanAction (..)
  , FirstReconcilePlanError
  , FirstReconcileProvisioningPlan
  , FirstReconcileReceipt
  , advanceFirstReconcileCursor
  , firstReconcilePlanDeadline
  , firstReconcilePlanDigest
  , firstReconcilePlanMaximumCount
  , firstReconcilePlanMemberAction
  , firstReconcilePlanMemberDigest
  , firstReconcilePlanMemberIndex
  , firstReconcilePlanMembers
  , firstReconcileReceiptCommitment
  , firstReconcileReceiptDigest
  , firstReconcileReceiptMemberDigest
  , firstReconcileReceiptMemberIndex
  , firstReconcileReceiptReadBackVersion
  , initialFirstReconcileCursor
  , mkFirstReconcileProvisioningPlan
  , mkFirstReconcileReceipt
  , nextFirstReconcileMember
  )
import Prodbox.Lifecycle.Lease
  ( authorityTimeFromMicros
  , authorityTimeMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( targetValueDigestText
  )

data FirstReconcileJournal = FirstReconcileJournal
  { internalFirstReconcileJournalPlan :: !FirstReconcileProvisioningPlan
  , internalFirstReconcileJournalReceipts :: ![FirstReconcileReceipt]
  , internalFirstReconcileJournalCursor :: !FirstReconcileCursor
  }
  deriving stock (Eq, Show)

data FirstReconcileJournalError
  = FirstReconcileJournalReceiptRejected !FirstReconcilePlanError
  | FirstReconcileJournalReceiptConflict !Natural
  | FirstReconcileJournalTooLarge !Int !Int
  | FirstReconcileJournalDecodeFailed
  | FirstReconcileJournalUnsupportedVersion !Word16
  | FirstReconcileJournalNonCanonical
  | FirstReconcileJournalPlanDigestInvalid
  | FirstReconcileJournalReceiptDigestInvalid !Natural
  | FirstReconcileJournalReceiptCountInvalid !Int !Natural
  deriving stock (Eq, Show)

initialFirstReconcileJournal
  :: FirstReconcileProvisioningPlan -> FirstReconcileJournal
initialFirstReconcileJournal plan =
  FirstReconcileJournal
    { internalFirstReconcileJournalPlan = plan
    , internalFirstReconcileJournalReceipts = []
    , internalFirstReconcileJournalCursor = initialFirstReconcileCursor plan
    }

firstReconcileJournalPlan
  :: FirstReconcileJournal -> FirstReconcileProvisioningPlan
firstReconcileJournalPlan = internalFirstReconcileJournalPlan

firstReconcileJournalCursor :: FirstReconcileJournal -> FirstReconcileCursor
firstReconcileJournalCursor = internalFirstReconcileJournalCursor

firstReconcileJournalReceipts
  :: FirstReconcileJournal -> [FirstReconcileReceipt]
firstReconcileJournalReceipts = internalFirstReconcileJournalReceipts

firstReconcileJournalComplete :: FirstReconcileJournal -> Bool
firstReconcileJournalComplete journal =
  case nextFirstReconcileMember
    (firstReconcileJournalPlan journal)
    (firstReconcileJournalCursor journal) of
    Right Nothing -> True
    _ -> False

-- | Commit exactly the next receipt.  Exact replay is idempotent; a different
-- receipt for an already-occupied member is a permanent conflict.
appendFirstReconcileReceipt
  :: FirstReconcileReceipt
  -> FirstReconcileJournal
  -> Either FirstReconcileJournalError FirstReconcileJournal
appendFirstReconcileReceipt receipt journal =
  case find sameIndex (firstReconcileJournalReceipts journal) of
    Just existing
      | existing == receipt -> Right journal
      | otherwise ->
          Left
            ( FirstReconcileJournalReceiptConflict
                (firstReconcileReceiptMemberIndex receipt)
            )
    Nothing -> do
      nextCursor <-
        either
          (Left . FirstReconcileJournalReceiptRejected)
          Right
          ( advanceFirstReconcileCursor
              (firstReconcileJournalPlan journal)
              (firstReconcileJournalCursor journal)
              receipt
          )
      pure
        journal
          { internalFirstReconcileJournalReceipts =
              firstReconcileJournalReceipts journal ++ [receipt]
          , internalFirstReconcileJournalCursor = nextCursor
          }
 where
  sameIndex existing =
    firstReconcileReceiptMemberIndex existing
      == firstReconcileReceiptMemberIndex receipt

data WireFirstReconcileAction
  = WireEstablishAuthorityBackup
  | WireProvisionLifecycleProvider
  | WireProvisionAuthorityBackupStore
  | WireProvisionTlsRetentionStore
  | WireProvisionGatewayDns
  | WireProvisionHomeDns01
  | WireProvisionAwsRunDns01
  | WireProvisionSesSmtp
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WireFirstReconcileReceipt = WireFirstReconcileReceipt
  { wireReceiptMemberIndex :: !Natural
  , wireReceiptMemberDigest :: !Text
  , wireReceiptReadBackVersion :: !Text
  , wireReceiptCommitment :: !Text
  , wireReceiptDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WireFirstReconcileJournal = WireFirstReconcileJournal
  { wireJournalVersion :: !Word16
  , wireJournalDeadlineMicros :: !Natural
  , wireJournalActions :: ![WireFirstReconcileAction]
  , wireJournalPlanDigest :: !Text
  , wireJournalReceipts :: ![WireFirstReconcileReceipt]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

firstReconcileJournalVersion :: Word16
firstReconcileJournalVersion = 1

firstReconcileJournalMaximumBytes :: Int
firstReconcileJournalMaximumBytes = 32 * 1024

encodeFirstReconcileJournal :: FirstReconcileJournal -> ByteString
encodeFirstReconcileJournal =
  LazyByteString.toStrict . serialise . journalToWire

decodeFirstReconcileJournal
  :: ByteString -> Either FirstReconcileJournalError FirstReconcileJournal
decodeFirstReconcileJournal bytes
  | ByteString.length bytes > firstReconcileJournalMaximumBytes =
      Left
        ( FirstReconcileJournalTooLarge
            (ByteString.length bytes)
            firstReconcileJournalMaximumBytes
        )
  | otherwise = do
      wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left FirstReconcileJournalDecodeFailed
        Right value -> Right value
      unless
        (wireJournalVersion wire == firstReconcileJournalVersion)
        (Left (FirstReconcileJournalUnsupportedVersion (wireJournalVersion wire)))
      actions <- mapM actionFromWire (wireJournalActions wire)
      plan <-
        either
          (Left . FirstReconcileJournalReceiptRejected)
          Right
          ( mkFirstReconcileProvisioningPlan
              (authorityTimeFromMicros (wireJournalDeadlineMicros wire))
              actions
          )
      unless
        (targetValueDigestText (firstReconcilePlanDigest plan) == wireJournalPlanDigest wire)
        (Left FirstReconcileJournalPlanDigestInvalid)
      when
        ( fromIntegral (length (wireJournalReceipts wire))
            > firstReconcilePlanMaximumCount plan
        )
        ( Left
            ( FirstReconcileJournalReceiptCountInvalid
                (length (wireJournalReceipts wire))
                (firstReconcilePlanMaximumCount plan)
            )
        )
      journal <-
        foldM
          (appendWireReceipt plan)
          (initialFirstReconcileJournal plan)
          (wireJournalReceipts wire)
      unless
        (encodeFirstReconcileJournal journal == bytes)
        (Left FirstReconcileJournalNonCanonical)
      pure journal

firstReconcileJournalCodec :: ModelBCodec FirstReconcileJournal
firstReconcileJournalCodec =
  ModelBCodec
    { encodeModelBValue = Right . encodeFirstReconcileJournal
    , decodeModelBValue =
        either (Left . show) Right . decodeFirstReconcileJournal
    }

journalToWire :: FirstReconcileJournal -> WireFirstReconcileJournal
journalToWire journal =
  WireFirstReconcileJournal
    { wireJournalVersion = firstReconcileJournalVersion
    , wireJournalDeadlineMicros =
        authorityTimeMicros (firstReconcilePlanDeadline plan)
    , wireJournalActions =
        actionToWire . firstReconcilePlanMemberAction
          <$> firstReconcilePlanMembers plan
    , wireJournalPlanDigest = targetValueDigestText (firstReconcilePlanDigest plan)
    , wireJournalReceipts = receiptToWire <$> firstReconcileJournalReceipts journal
    }
 where
  plan = firstReconcileJournalPlan journal

receiptToWire :: FirstReconcileReceipt -> WireFirstReconcileReceipt
receiptToWire receipt =
  WireFirstReconcileReceipt
    { wireReceiptMemberIndex = firstReconcileReceiptMemberIndex receipt
    , wireReceiptMemberDigest =
        targetValueDigestText (firstReconcileReceiptMemberDigest receipt)
    , wireReceiptReadBackVersion = firstReconcileReceiptReadBackVersion receipt
    , wireReceiptCommitment = firstReconcileReceiptCommitment receipt
    , wireReceiptDigest = targetValueDigestText (firstReconcileReceiptDigest receipt)
    }

appendWireReceipt
  :: FirstReconcileProvisioningPlan
  -> FirstReconcileJournal
  -> WireFirstReconcileReceipt
  -> Either FirstReconcileJournalError FirstReconcileJournal
appendWireReceipt plan journal wire = do
  member <-
    maybe
      (Left (FirstReconcileJournalReceiptDigestInvalid (wireReceiptMemberIndex wire)))
      Right
      ( find
          ((== wireReceiptMemberIndex wire) . firstReconcilePlanMemberIndex)
          (firstReconcilePlanMembers plan)
      )
  unless
    ( targetValueDigestText (firstReconcilePlanMemberDigest member)
        == wireReceiptMemberDigest wire
    )
    (Left (FirstReconcileJournalReceiptDigestInvalid (wireReceiptMemberIndex wire)))
  receipt <-
    either
      (Left . FirstReconcileJournalReceiptRejected)
      Right
      ( mkFirstReconcileReceipt
          member
          (wireReceiptReadBackVersion wire)
          (wireReceiptCommitment wire)
      )
  unless
    (targetValueDigestText (firstReconcileReceiptDigest receipt) == wireReceiptDigest wire)
    (Left (FirstReconcileJournalReceiptDigestInvalid (wireReceiptMemberIndex wire)))
  appendFirstReconcileReceipt receipt journal

actionToWire :: FirstReconcilePlanAction -> WireFirstReconcileAction
actionToWire action = case action of
  EstablishAuthorityBackupMember -> WireEstablishAuthorityBackup
  ProvisionAwsCredentialMember credentialClass -> case credentialClass of
    LifecycleProviderCredential -> WireProvisionLifecycleProvider
    AuthorityBackupStoreCredential -> WireProvisionAuthorityBackupStore
    TlsRetentionStoreCredential -> WireProvisionTlsRetentionStore
    GatewayDnsCredential -> WireProvisionGatewayDns
    HomeCertManagerDns01Credential -> WireProvisionHomeDns01
    AwsRunCertManagerDns01Credential -> WireProvisionAwsRunDns01
    SesSmtpRetainedCustodyCredential -> WireProvisionSesSmtp

actionFromWire
  :: WireFirstReconcileAction
  -> Either FirstReconcileJournalError FirstReconcilePlanAction
actionFromWire action = Right $ case action of
  WireEstablishAuthorityBackup -> EstablishAuthorityBackupMember
  WireProvisionLifecycleProvider ->
    ProvisionAwsCredentialMember LifecycleProviderCredential
  WireProvisionAuthorityBackupStore ->
    ProvisionAwsCredentialMember AuthorityBackupStoreCredential
  WireProvisionTlsRetentionStore ->
    ProvisionAwsCredentialMember TlsRetentionStoreCredential
  WireProvisionGatewayDns -> ProvisionAwsCredentialMember GatewayDnsCredential
  WireProvisionHomeDns01 ->
    ProvisionAwsCredentialMember HomeCertManagerDns01Credential
  WireProvisionAwsRunDns01 ->
    ProvisionAwsCredentialMember AwsRunCertManagerDns01Credential
  WireProvisionSesSmtp ->
    ProvisionAwsCredentialMember SesSmtpRetainedCustodyCredential

data FirstReconcileJournalStoreError
  = FirstReconcileJournalStoreNotInitialized
  | FirstReconcileJournalStorePlanMismatch
  | FirstReconcileJournalStoreTransitionFailed !FirstReconcileJournalError
  | FirstReconcileJournalStoreCorrupt !Text
  | FirstReconcileJournalStoreEndpointUnready !Text
  | FirstReconcileJournalStoreUnobservable !Text
  | FirstReconcileJournalStoreConcurrentWrite
  deriving stock (Eq, Show)

data FirstReconcileJournalStoreResult
  = FirstReconcileJournalStoreApplied
      !ModelBObjectVersion
      !FirstReconcileJournal
  | FirstReconcileJournalStoreAlreadyCurrent !FirstReconcileJournal
  deriving stock (Eq, Show)

initializeFirstReconcileJournalStore
  :: (Monad m)
  => ModelBCasAdapter 'ClusterRetained m FirstReconcileJournal
  -> ModelBObjectCoordinate 'ClusterRetained
  -> FirstReconcileProvisioningPlan
  -> m (Either FirstReconcileJournalStoreError FirstReconcileJournalStoreResult)
initializeFirstReconcileJournalStore adapter coordinate plan = do
  observed <- modelBObserve adapter coordinate
  case observed of
    ModelBMissing ->
      writeJournal
        adapter
        (ModelBInitialize coordinate (initialFirstReconcileJournal plan))
    ModelBObserved _ existing
      | firstReconcilePlanDigest (firstReconcileJournalPlan existing)
          == firstReconcilePlanDigest plan ->
          pure (Right (FirstReconcileJournalStoreAlreadyCurrent existing))
      | otherwise -> pure (Left FirstReconcileJournalStorePlanMismatch)
    ModelBCorrupt detail -> pure (Left (FirstReconcileJournalStoreCorrupt detail))
    ModelBEndpointUnready detail ->
      pure (Left (FirstReconcileJournalStoreEndpointUnready detail))
    ModelBUnobservable detail ->
      pure (Left (FirstReconcileJournalStoreUnobservable detail))

appendFirstReconcileJournalStore
  :: (Monad m)
  => ModelBCasAdapter 'ClusterRetained m FirstReconcileJournal
  -> ModelBObjectCoordinate 'ClusterRetained
  -> FirstReconcileReceipt
  -> m (Either FirstReconcileJournalStoreError FirstReconcileJournalStoreResult)
appendFirstReconcileJournalStore adapter coordinate receipt = do
  observed <- modelBObserve adapter coordinate
  case observed of
    ModelBMissing -> pure (Left FirstReconcileJournalStoreNotInitialized)
    ModelBObserved version current ->
      case appendFirstReconcileReceipt receipt current of
        Left err ->
          pure (Left (FirstReconcileJournalStoreTransitionFailed err))
        Right next
          | next == current ->
              pure (Right (FirstReconcileJournalStoreAlreadyCurrent current))
          | otherwise ->
              writeJournal adapter (ModelBReplace coordinate version next)
    ModelBCorrupt detail -> pure (Left (FirstReconcileJournalStoreCorrupt detail))
    ModelBEndpointUnready detail ->
      pure (Left (FirstReconcileJournalStoreEndpointUnready detail))
    ModelBUnobservable detail ->
      pure (Left (FirstReconcileJournalStoreUnobservable detail))

writeJournal
  :: (Monad m)
  => ModelBCasAdapter 'ClusterRetained m FirstReconcileJournal
  -> ModelBCasRequest 'ClusterRetained FirstReconcileJournal
  -> m (Either FirstReconcileJournalStoreError FirstReconcileJournalStoreResult)
writeJournal adapter request = do
  result <- modelBCompareAndSwap adapter request
  pure $ case result of
    ModelBCasApplied version journal ->
      Right (FirstReconcileJournalStoreApplied version journal)
    ModelBCasConflict _ -> Left FirstReconcileJournalStoreConcurrentWrite
    ModelBCasRefusedCorrupt detail ->
      Left (FirstReconcileJournalStoreCorrupt detail)
    ModelBCasEndpointUnready detail ->
      Left (FirstReconcileJournalStoreEndpointUnready detail)
    ModelBCasUnobservable detail ->
      Left (FirstReconcileJournalStoreUnobservable detail)
