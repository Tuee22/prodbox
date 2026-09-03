{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Production owner of the secret-free AWS-admin prepared-target outbox and
-- first-reconcile continuation.  Preparation derives every authority-owned
-- field from retained admission and journal observations, commits the exact
-- outbox by Model-B CAS, and reads it back before the permit authority may
-- prepare or sign anything.
module Prodbox.ControlPlane.AwsAdminPreparedTargetProduction
  ( FirstReconcileContinuation (..)
  , AwsAdminPreparedTargetLifecycle (..)
  , AwsAdminPrepareAuthorityPhase (..)
  , renderAwsAdminPrepareAuthorityPhaseDiagnostic
  , AwsAdminPreparedTargetOutboxDecision (..)
  , decideAwsAdminPreparedTargetOutbox
  , publishAwsAdminPreparedTarget
  , renderAwsAdminPreparedTargetOutboxDiagnostic
  , AwsAdminPreparedTargetPrepareCause (..)
  , AwsAdminPreparedTargetPrepareError
  , allAwsAdminPreparedTargetPrepareCauses
  , awsAdminPreparedTargetPrepareError
  , awsAdminPreparedTargetPrepareErrorCause
  , renderAwsAdminPreparedTargetPrepareCause
  , ensureGenesisFirstReconcileJournal
  , productionAwsAdminPreparedTargetLifecycle
  )
where

import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.CLI.Output (writeDiagnosticLine)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (readAuthorityAdmission)
  , AuthorityAdmissionSnapshot (authorityAdmissionSnapshotState)
  )
import Prodbox.ControlPlane.InClusterAuthorityStore
  ( InClusterAuthorityStore
  , inClusterAuthorityModelBCasAdapter
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetAgentIdentity
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( TargetWorkerReceipt
  , decodeTargetWorkerReceipt
  , targetWorkerReceiptCommitment
  , targetWorkerReceiptVaultVersion
  )
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , authorityAggregateAdmission
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityAdmissionState (..)
  , BackupRepairPermit (backupRepairPermitDigest)
  , BackupRepairProgress (backupRepairPermit)
  , GenesisPlan
  , GenesisProgress (genesisProgressPlan)
  , authorityEpochGenesis
  , authorityEpochValue
  , nextAuthorityEpoch
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (ModelBInitialize, ModelBReplace)
  , ModelBObjectCoordinate
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminAuthority
  ( AwsAdminAuthorizedRecoveryError
  , AwsAdminAuthorizedRecoveryProof
  , awsAdminPreparedRenewalBindingsMatch
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( AwsAdminWorkerReceipt
  , AwsAdminWorkerReceiptKind (AwsAdminInstalled)
  , awsAdminWorkerReceiptKind
  , awsAdminWorkerReceiptTargetReadBack
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminCleanupRecoveryProgram (..)
  , AwsAdminPermitIntent
  , AwsAdminPermitKind (..)
  , BackupRepairFrozenBinding
  , SignedAwsAdminPermit
  , awsAdminPermitIntentAction
  , awsAdminPermitIntentCredentialClass
  , awsAdminPermitIntentDeadline
  , awsAdminPermitIntentKind
  , awsAdminPermitIntentOperationId
  , awsAdminPermitIntentPlanBinding
  , awsAdminPermitIntentPreparedTarget
  , backupRepairFrozenAuthorityEpoch
  , backupRepairFrozenPlanDigest
  , bindAwsAdminPermitIntentPreparedTarget
  , signedAwsAdminPermitIntent
  )
import Prodbox.Lifecycle.CredentialProvisioner.FirstReconcileJournal
  ( FirstReconcileJournal
  , appendFirstReconcileJournalStore
  , appendFirstReconcileReceipt
  , firstReconcileJournalCodec
  , firstReconcileJournalCursor
  , firstReconcileJournalPlan
  , initialFirstReconcileJournal
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (AuthorityBackupStoreCredential)
  , FirstReconcilePermitBinding
  , FirstReconcilePlanAction (..)
  , FirstReconcilePlanMember
  , FirstReconcileReceipt
  , OperatorMaterialAction (InstallOperatorMaterial)
  , defaultFirstReconcileProvisioningPlan
  , firstReconcilePermitMemberDigest
  , firstReconcilePermitMemberIndex
  , firstReconcilePermitPlanDigest
  , firstReconcilePlanDeadline
  , firstReconcilePlanDigest
  , firstReconcilePlanMemberAction
  , firstReconcilePlanMemberDigest
  , firstReconcilePlanMemberIndex
  , firstReconcilePlanMembers
  , firstReconcilePriorReceiptDigest
  , mkFirstReconcilePermitBinding
  , mkFirstReconcileReceipt
  , nextFirstReconcileMember
  , operatorMaterialOperationIdText
  )
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTarget
  ( PreparedCredentialTargetObservation
  , preparedCredentialTargetDeadline
  , preparedCredentialTargetFence
  , preparedCredentialTargetGeneration
  , preparedCredentialTargetId
  , preparedCredentialTargetOwnerNonce
  , preparedCredentialTargetPlanBinding
  , preparedCredentialTargetRequestDigest
  )
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTargetOutbox
  ( PreparedCredentialTargetOutbox
  , mkPreparedCredentialTargetOutbox
  , preparedCredentialTargetOutboxCanonicalIntent
  , preparedCredentialTargetOutboxCodec
  , preparedCredentialTargetOutboxIsLegacy
  , preparedCredentialTargetOutboxObservation
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( targetValueDigestText
  )

-- | The endpoint consumes this complete lifecycle rather than a read-only
-- caller-supplied boundary.  Preparation returns the canonical intent whose
-- prepared observation was durably read back; completion advances the exact
-- receipt-ordered first-reconcile member when one is bound.
data AwsAdminPreparedTargetLifecycle m = AwsAdminPreparedTargetLifecycle
  { recordAwsAdminPrepareAuthorityPhase :: AwsAdminPrepareAuthorityPhase -> m ()
  , proveAwsAdminAuthorizedAttemptRecovery
      :: AuthorityTime
      -> SignedAwsAdminPermit
      -> m
           ( Either
               AwsAdminAuthorizedRecoveryError
               AwsAdminAuthorizedRecoveryProof
           )
  , prepareAndReadBackAwsAdminPreparedTarget
      :: Maybe (AuthorityTime, AwsAdminPermitIntent)
      -> AwsAdminPermitIntent
      -> m (Either AwsAdminPreparedTargetPrepareError AwsAdminPermitIntent)
  , reobserveRetainedAwsAdminPreparedTarget
      :: AwsAdminPermitIntent
      -> m (Either Text PreparedCredentialTargetObservation)
  , commitAwsAdminFirstReconcileReceipt
      :: SignedAwsAdminPermit
      -> AwsAdminWorkerReceipt
      -> m (Either Text ())
  , observeAwsAdminFirstReconcileContinuation
      :: m (Either Text (Maybe FirstReconcileContinuation))
  }

-- | Value-free retained Authority phase observed before prepared-target
-- publication. The production logger renders only this closed constructor;
-- no intent, binding, permit, receipt, or durable coordinate can escape.
data AwsAdminPrepareAuthorityPhase
  = AwsAdminPrepareAuthorityVacant
  | AwsAdminPrepareAuthorityPrepared
  | AwsAdminPrepareAuthorityAttested
  | AwsAdminPrepareAuthorityAuthorized
  | AwsAdminPrepareAuthorityCompleted
  deriving (Bounded, Enum, Eq, Show)

renderAwsAdminPrepareAuthorityPhaseDiagnostic :: AwsAdminPrepareAuthorityPhase -> Text
renderAwsAdminPrepareAuthorityPhaseDiagnostic phase =
  "aws-admin/prepare authority-phase=" <> case phase of
    AwsAdminPrepareAuthorityVacant -> "vacant"
    AwsAdminPrepareAuthorityPrepared -> "prepared"
    AwsAdminPrepareAuthorityAttested -> "attested"
    AwsAdminPrepareAuthorityAuthorized -> "authorized"
    AwsAdminPrepareAuthorityCompleted -> "completed"

-- | Closed, payload-free cause projected by the protected prepare endpoint.
-- Boundary detail remains on 'AwsAdminPreparedTargetPrepareError' for private
-- diagnosis and is never rendered into the authenticated response.
data AwsAdminPreparedTargetPrepareCause
  = AwsAdminPreparedTargetAuthorityTimeUnavailable
  | AwsAdminPreparedTargetInitialAdmissionUnavailable
  | AwsAdminPreparedTargetJournalMissing
  | AwsAdminPreparedTargetJournalCorrupt
  | AwsAdminPreparedTargetJournalEndpointUnready
  | AwsAdminPreparedTargetJournalUnobservable
  | AwsAdminPreparedTargetJournalPlanMismatch
  | AwsAdminPreparedTargetJournalCursorRejected
  | AwsAdminPreparedTargetJournalMemberMismatch
  | AwsAdminPreparedTargetAdmissionStateRejected
  | AwsAdminPreparedTargetDeadlineExpired
  | AwsAdminPreparedTargetIntentCanonicalizationRejected
  | AwsAdminPreparedTargetConfirmationAdmissionUnavailable
  | AwsAdminPreparedTargetAdmissionChanged
  | AwsAdminPreparedTargetCoordinateRejected
  | AwsAdminPreparedTargetOutboxMissing
  | AwsAdminPreparedTargetOutboxCorrupt
  | AwsAdminPreparedTargetOutboxEndpointUnready
  | AwsAdminPreparedTargetOutboxUnobservable
  | AwsAdminPreparedTargetOutboxDivergent
  deriving (Bounded, Enum, Eq, Show)

data AwsAdminPreparedTargetPrepareError = AwsAdminPreparedTargetPrepareError
  { awsAdminPreparedTargetPrepareErrorCause :: !AwsAdminPreparedTargetPrepareCause
  , awsAdminPreparedTargetPrepareErrorDetail :: !Text
  }
  deriving (Eq, Show)

allAwsAdminPreparedTargetPrepareCauses :: [AwsAdminPreparedTargetPrepareCause]
allAwsAdminPreparedTargetPrepareCauses = [minBound .. maxBound]

awsAdminPreparedTargetPrepareError
  :: AwsAdminPreparedTargetPrepareCause
  -> Text
  -> AwsAdminPreparedTargetPrepareError
awsAdminPreparedTargetPrepareError = AwsAdminPreparedTargetPrepareError

prepareFailure
  :: AwsAdminPreparedTargetPrepareCause
  -> Text
  -> AwsAdminPreparedTargetPrepareError
prepareFailure = awsAdminPreparedTargetPrepareError

renderAwsAdminPreparedTargetPrepareCause :: AwsAdminPreparedTargetPrepareCause -> Text
renderAwsAdminPreparedTargetPrepareCause cause = case cause of
  AwsAdminPreparedTargetAuthorityTimeUnavailable -> "authority-time"
  AwsAdminPreparedTargetInitialAdmissionUnavailable -> "admission/initial"
  AwsAdminPreparedTargetJournalMissing -> "first-reconcile-journal/missing"
  AwsAdminPreparedTargetJournalCorrupt -> "first-reconcile-journal/corrupt"
  AwsAdminPreparedTargetJournalEndpointUnready -> "first-reconcile-journal/endpoint-unready"
  AwsAdminPreparedTargetJournalUnobservable -> "first-reconcile-journal/unobservable"
  AwsAdminPreparedTargetJournalPlanMismatch -> "first-reconcile-journal/plan-mismatch"
  AwsAdminPreparedTargetJournalCursorRejected -> "first-reconcile-journal/cursor-rejected"
  AwsAdminPreparedTargetJournalMemberMismatch -> "first-reconcile-journal/member-mismatch"
  AwsAdminPreparedTargetAdmissionStateRejected -> "admission/state-rejected"
  AwsAdminPreparedTargetDeadlineExpired -> "deadline-expired"
  AwsAdminPreparedTargetIntentCanonicalizationRejected -> "intent-canonicalization"
  AwsAdminPreparedTargetConfirmationAdmissionUnavailable -> "admission/confirmation"
  AwsAdminPreparedTargetAdmissionChanged -> "admission/changed"
  AwsAdminPreparedTargetCoordinateRejected -> "outbox/coordinate-rejected"
  AwsAdminPreparedTargetOutboxMissing -> "outbox/missing"
  AwsAdminPreparedTargetOutboxCorrupt -> "outbox/corrupt"
  AwsAdminPreparedTargetOutboxEndpointUnready -> "outbox/endpoint-unready"
  AwsAdminPreparedTargetOutboxUnobservable -> "outbox/unobservable"
  AwsAdminPreparedTargetOutboxDivergent -> "outbox/divergent"

data FirstReconcileContinuation = FirstReconcileContinuation
  { firstReconcileContinuationClass :: !AwsCredentialClass
  , firstReconcileContinuationMemberIndex :: !Natural
  , firstReconcileContinuationMemberDigest :: !Text
  , firstReconcileContinuationDeadline :: !AuthorityTime
  }
  deriving (Eq, Show)

data PreparedAuthorityContext = PreparedAuthorityContext
  { preparedContextFence :: !Natural
  , preparedContextPlanBinding :: !(Maybe FirstReconcilePermitBinding)
  , preparedContextDeadline :: !AuthorityTime
  , preparedContextGenesis
      :: !(Maybe (GenesisPlan, FirstReconcilePlanMember))
  }

-- | Bind the production Lifecycle Authority store, admission aggregate,
-- first-reconcile journal, exact registered Target Agent rollout, and trusted
-- Authority clock into one closed producer/readback/completion capability.
productionAwsAdminPreparedTargetLifecycle
  :: InClusterAuthorityStore
  -> LongLivedCheckpointAuthority
  -> AuthorityAdmissionRepository IO revision
  -> ModelBObjectCoordinate 'ClusterRetained
  -> TargetAgentIdentity
  -> IO (Either Text AuthorityTime)
  -> ( AuthorityTime
       -> SignedAwsAdminPermit
       -> IO
            ( Either
                AwsAdminAuthorizedRecoveryError
                AwsAdminAuthorizedRecoveryProof
            )
     )
  -> AwsAdminPreparedTargetLifecycle IO
productionAwsAdminPreparedTargetLifecycle store authority admissionRepository journalCoordinate selectedAgent observeNow proveAuthorizedRecovery =
  AwsAdminPreparedTargetLifecycle
    { recordAwsAdminPrepareAuthorityPhase =
        writeDiagnosticLine . Text.unpack . renderAwsAdminPrepareAuthorityPhaseDiagnostic
    , proveAwsAdminAuthorizedAttemptRecovery = proveAuthorizedRecovery
    , prepareAndReadBackAwsAdminPreparedTarget = prepare
    , reobserveRetainedAwsAdminPreparedTarget = reobservePrepared
    , commitAwsAdminFirstReconcileReceipt = commitFirstReconcile
    , observeAwsAdminFirstReconcileContinuation = observeContinuation
    }
 where
  preparedAdapter =
    inClusterAuthorityModelBCasAdapter
      store
      authority
      preparedCredentialTargetOutboxCodec
  journalAdapter =
    inClusterAuthorityModelBCasAdapter
      store
      authority
      firstReconcileJournalCodec

  prepare renewal draft = do
    timeResult <- observeNow
    admissionResult <- readAdmissionAggregate admissionRepository
    case (timeResult, admissionResult) of
      (Left detail, _) ->
        pure
          ( Left
              ( prepareFailure
                  AwsAdminPreparedTargetAuthorityTimeUnavailable
                  detail
              )
          )
      (_, Left detail) ->
        pure
          ( Left
              ( prepareFailure
                  AwsAdminPreparedTargetInitialAdmissionUnavailable
                  detail
              )
          )
      (Right now, Right admission) -> do
        contextResult <-
          contextForIntent journalAdapter journalCoordinate admission draft
        case contextResult of
          Left detail -> pure (Left detail)
          Right context
            | authorityTimeMicros now
                >= authorityTimeMicros (preparedContextDeadline context) ->
                pure
                  ( Left
                      ( prepareFailure
                          AwsAdminPreparedTargetDeadlineExpired
                          "AWS-admin prepared-target deadline has expired"
                      )
                  )
            | otherwise -> do
                let owner =
                      "aws-admin-"
                        <> operatorMaterialOperationIdText
                          (awsAdminPermitIntentOperationId draft)
                case first
                  (Text.pack . show)
                  ( bindAwsAdminPermitIntentPreparedTarget
                      (preparedContextGenesis context)
                      (preparedContextPlanBinding context)
                      (preparedContextDeadline context)
                      owner
                      (preparedContextFence context)
                      selectedAgent
                      draft
                  ) of
                  Left detail ->
                    pure
                      ( Left
                          ( prepareFailure
                              AwsAdminPreparedTargetIntentCanonicalizationRejected
                              detail
                          )
                      )
                  Right canonical -> do
                    confirmedAdmission <- readAdmissionAggregate admissionRepository
                    case confirmedAdmission of
                      Left detail ->
                        pure
                          ( Left
                              ( prepareFailure
                                  AwsAdminPreparedTargetConfirmationAdmissionUnavailable
                                  detail
                              )
                          )
                      Right confirmed
                        | confirmed /= admission ->
                            pure
                              ( Left
                                  ( prepareFailure
                                      AwsAdminPreparedTargetAdmissionChanged
                                      "Authority admission changed during prepared-target derivation"
                                  )
                              )
                        | otherwise -> do
                            published <-
                              publishAwsAdminPreparedTarget
                                authority
                                preparedAdapter
                                renewal
                                canonical
                            pure (canonical <$ published)

  reobservePrepared intent =
    case preparedCoordinate authority intent of
      Left detail -> pure (Left detail)
      Right coordinate -> do
        observed <- modelBObserve preparedAdapter coordinate
        pure (preparedFromObservation observed)

  commitFirstReconcile permit receipt =
    let intent = signedAwsAdminPermitIntent permit
     in case awsAdminPermitIntentPlanBinding intent of
          Nothing -> pure (Right ())
          Just binding
            | awsAdminWorkerReceiptKind receipt /= AwsAdminInstalled ->
                pure (Left "first-reconcile completion requires an install receipt")
            | otherwise -> case decodeTargetWorkerReceipt (awsAdminWorkerReceiptTargetReadBack receipt) of
                Left err -> pure (Left ("target read-back receipt is invalid: " <> Text.pack (show err)))
                Right targetReceipt -> do
                  observed <- modelBObserve journalAdapter journalCoordinate
                  case observed of
                    ModelBObserved _ journal ->
                      case receiptForBinding binding journal targetReceipt of
                        Left detail -> pure (Left detail)
                        Right firstReceipt ->
                          appendAndConfirm journalAdapter journalCoordinate 8 firstReceipt
                    ModelBMissing -> pure (Left "first-reconcile journal is missing")
                    ModelBCorrupt detail -> pure (Left ("first-reconcile journal is corrupt: " <> detail))
                    ModelBEndpointUnready detail ->
                      pure (Left ("first-reconcile journal is not ready: " <> detail))
                    ModelBUnobservable detail ->
                      pure (Left ("first-reconcile journal is unobservable: " <> detail))

  observeContinuation = do
    admissionResult <- readAdmissionAggregate admissionRepository
    case admissionResult of
      Left detail -> pure (Left detail)
      Right aggregate -> case authorityAggregateAdmission aggregate of
        BackupEstablished {} -> do
          journalResult <- observeJournal journalAdapter journalCoordinate
          pure (journalResult >>= continuationFromJournal)
        _ -> pure (Left "first-reconcile continuation requires open backup admission")

readAdmissionAggregate
  :: AuthorityAdmissionRepository IO revision
  -> IO (Either Text AuthorityAdmissionAggregate)
readAdmissionAggregate repository = do
  observed <- readAuthorityAdmission repository
  pure
    ( authorityAdmissionSnapshotState
        <$> first
          ("Authority admission is unavailable: " <>)
          observed
    )

contextForIntent
  :: ModelBCasAdapter 'ClusterRetained IO FirstReconcileJournal
  -> ModelBObjectCoordinate 'ClusterRetained
  -> AuthorityAdmissionAggregate
  -> AwsAdminPermitIntent
  -> IO (Either AwsAdminPreparedTargetPrepareError PreparedAuthorityContext)
contextForIntent adapter coordinate aggregate intent =
  case (authorityAggregateAdmission aggregate, awsAdminPermitIntentKind intent) of
    (EstablishingBackup progress, genesisKind)
      | isGenesisBackupKind genesisKind -> do
          journalResult <-
            ensureGenesisFirstReconcileJournal
              adapter
              coordinate
              (awsAdminPermitIntentDeadline intent)
          pure $ do
            journal <- journalResult
            member <- currentJournalMember journal
            unless
              ( firstReconcilePlanMemberIndex member == 0
                  && firstReconcilePlanMemberAction member
                    == EstablishAuthorityBackupMember
                  && awsAdminPermitIntentCredentialClass intent
                    == AuthorityBackupStoreCredential
                  && awsAdminPermitIntentAction intent == InstallOperatorMaterial
              )
              ( Left
                  ( prepareFailure
                      AwsAdminPreparedTargetJournalMemberMismatch
                      "retained first-reconcile journal is not at genesis member zero"
                  )
              )
            pure
              PreparedAuthorityContext
                { preparedContextFence = authorityEpochValue authorityEpochGenesis
                , preparedContextPlanBinding = Just (bindingFor journal member)
                , preparedContextDeadline = awsAdminPermitIntentDeadline intent
                , preparedContextGenesis =
                    Just (genesisProgressPlan progress, member)
                }
    (BackupEstablished epoch _ _, normalKind)
      | isNormalOperatorMaterialKind normalKind -> do
          journalResult <- observeJournalForPrepare adapter coordinate
          pure $ do
            journalMaybe <- journalResult
            case journalMaybe of
              Nothing ->
                pure
                  PreparedAuthorityContext
                    { preparedContextFence = authorityEpochValue epoch
                    , preparedContextPlanBinding = Nothing
                    , preparedContextDeadline = awsAdminPermitIntentDeadline intent
                    , preparedContextGenesis = Nothing
                    }
              Just journal -> case nextFirstReconcileMember
                (firstReconcileJournalPlan journal)
                (firstReconcileJournalCursor journal) of
                Left err ->
                  Left
                    ( prepareFailure
                        AwsAdminPreparedTargetJournalCursorRejected
                        (Text.pack (show err))
                    )
                Right Nothing ->
                  pure
                    PreparedAuthorityContext
                      { preparedContextFence = authorityEpochValue epoch
                      , preparedContextPlanBinding = Nothing
                      , preparedContextDeadline = awsAdminPermitIntentDeadline intent
                      , preparedContextGenesis = Nothing
                      }
                Right (Just member) -> case firstReconcilePlanMemberAction member of
                  EstablishAuthorityBackupMember ->
                    Left
                      ( prepareFailure
                          AwsAdminPreparedTargetJournalMemberMismatch
                          "first-reconcile genesis receipt has not committed"
                      )
                  ProvisionAwsCredentialMember expectedClass -> do
                    unless
                      ( awsAdminPermitIntentCredentialClass intent == expectedClass
                          && awsAdminPermitIntentAction intent == InstallOperatorMaterial
                      )
                      ( Left
                          ( prepareFailure
                              AwsAdminPreparedTargetJournalMemberMismatch
                              "AWS-admin request is not the next first-reconcile member"
                          )
                      )
                    pure
                      PreparedAuthorityContext
                        { preparedContextFence = authorityEpochValue epoch
                        , preparedContextPlanBinding = Just (bindingFor journal member)
                        , preparedContextDeadline = awsAdminPermitIntentDeadline intent
                        , preparedContextGenesis = Nothing
                        }
    (BackupRepairFrozen epoch progress, repairKind)
      | Just repair <- backupRepairBindingForKind repairKind ->
          pure $ do
            retainedPermit <-
              maybe
                ( Left
                    ( prepareFailure
                        AwsAdminPreparedTargetAdmissionStateRejected
                        "backup repair is frozen without a retained repair permit"
                    )
                )
                Right
                (backupRepairPermit progress)
            unless
              ( backupRepairFrozenAuthorityEpoch repair == authorityEpochValue epoch
                  && targetValueDigestText (backupRepairFrozenPlanDigest repair)
                    == backupRepairPermitDigest retainedPermit
              )
              ( Left
                  ( prepareFailure
                      AwsAdminPreparedTargetAdmissionStateRejected
                      "AWS-admin backup-repair binding differs from retained admission"
                  )
              )
            pure
              PreparedAuthorityContext
                { preparedContextFence = authorityEpochValue (nextAuthorityEpoch epoch)
                , preparedContextPlanBinding = Nothing
                , preparedContextDeadline = awsAdminPermitIntentDeadline intent
                , preparedContextGenesis = Nothing
                }
    _ ->
      pure
        ( Left
            ( prepareFailure
                AwsAdminPreparedTargetAdmissionStateRejected
                "AWS-admin request is not admitted by retained Authority state"
            )
        )

isNormalOperatorMaterialKind :: AwsAdminPermitKind -> Bool
isNormalOperatorMaterialKind kind = case kind of
  NormalOperatorMaterialKind -> True
  CleanupRecoveryKind NormalOperatorMaterialCleanupProgram _ -> True
  _ -> False

isGenesisBackupKind :: AwsAdminPermitKind -> Bool
isGenesisBackupKind kind = case kind of
  GenesisBackupKind _ -> True
  CleanupRecoveryKind (GenesisBackupCleanupProgram _) _ -> True
  _ -> False

backupRepairBindingForKind
  :: AwsAdminPermitKind -> Maybe BackupRepairFrozenBinding
backupRepairBindingForKind kind = case kind of
  BackupRepairFrozenKind repair -> Just repair
  _ -> Nothing

-- | Initialize the genesis journal only after definitive absence.  Once a
-- journal exists, its deadline is Authority-owned: validate the compiled plan
-- against that retained deadline and adopt the journal byte-for-byte.
ensureGenesisFirstReconcileJournal
  :: ModelBCasAdapter 'ClusterRetained IO FirstReconcileJournal
  -> ModelBObjectCoordinate 'ClusterRetained
  -> AuthorityTime
  -> IO (Either AwsAdminPreparedTargetPrepareError FirstReconcileJournal)
ensureGenesisFirstReconcileJournal adapter coordinate deadline = do
  observed <- modelBObserve adapter coordinate
  case observed of
    ModelBMissing -> do
      let journal =
            initialFirstReconcileJournal
              (defaultFirstReconcileProvisioningPlan deadline)
      _ <- modelBCompareAndSwap adapter (ModelBInitialize coordinate journal)
      confirmed <- modelBObserve adapter coordinate
      pure (classifyGenesisJournalObservation confirmed)
    _ -> pure (classifyGenesisJournalObservation observed)

classifyGenesisJournalObservation
  :: ModelBObservation FirstReconcileJournal
  -> Either AwsAdminPreparedTargetPrepareError FirstReconcileJournal
classifyGenesisJournalObservation observed = case observed of
  ModelBObserved _ journal
    | retainedPlanIsCompiled journal -> Right journal
    | otherwise ->
        Left
          ( prepareFailure
              AwsAdminPreparedTargetJournalPlanMismatch
              "retained first-reconcile plan differs from the compiled topology"
          )
  ModelBMissing ->
    Left
      ( prepareFailure
          AwsAdminPreparedTargetJournalMissing
          "first-reconcile journal initialization was not read back"
      )
  ModelBCorrupt detail ->
    Left
      ( prepareFailure
          AwsAdminPreparedTargetJournalCorrupt
          detail
      )
  ModelBEndpointUnready detail ->
    Left
      ( prepareFailure
          AwsAdminPreparedTargetJournalEndpointUnready
          detail
      )
  ModelBUnobservable detail ->
    Left
      ( prepareFailure
          AwsAdminPreparedTargetJournalUnobservable
          detail
      )

retainedPlanIsCompiled :: FirstReconcileJournal -> Bool
retainedPlanIsCompiled journal =
  firstReconcilePlanDigest retainedPlan
    == firstReconcilePlanDigest
      (defaultFirstReconcileProvisioningPlan (firstReconcilePlanDeadline retainedPlan))
 where
  retainedPlan = firstReconcileJournalPlan journal

observeJournal
  :: ModelBCasAdapter 'ClusterRetained IO FirstReconcileJournal
  -> ModelBObjectCoordinate 'ClusterRetained
  -> IO (Either Text (Maybe FirstReconcileJournal))
observeJournal adapter coordinate = do
  observed <- modelBObserve adapter coordinate
  pure $ case observed of
    ModelBMissing -> Right Nothing
    ModelBObserved _ journal -> Right (Just journal)
    ModelBCorrupt detail -> Left ("first-reconcile journal is corrupt: " <> detail)
    ModelBEndpointUnready detail ->
      Left ("first-reconcile journal is not ready: " <> detail)
    ModelBUnobservable detail ->
      Left ("first-reconcile journal is unobservable: " <> detail)

observeJournalForPrepare
  :: ModelBCasAdapter 'ClusterRetained IO FirstReconcileJournal
  -> ModelBObjectCoordinate 'ClusterRetained
  -> IO (Either AwsAdminPreparedTargetPrepareError (Maybe FirstReconcileJournal))
observeJournalForPrepare adapter coordinate = do
  observed <- modelBObserve adapter coordinate
  pure $ case observed of
    ModelBMissing -> Right Nothing
    ModelBObserved _ journal -> Right (Just journal)
    ModelBCorrupt detail ->
      Left (prepareFailure AwsAdminPreparedTargetJournalCorrupt detail)
    ModelBEndpointUnready detail ->
      Left (prepareFailure AwsAdminPreparedTargetJournalEndpointUnready detail)
    ModelBUnobservable detail ->
      Left (prepareFailure AwsAdminPreparedTargetJournalUnobservable detail)

continuationFromJournal
  :: Maybe FirstReconcileJournal
  -> Either Text (Maybe FirstReconcileContinuation)
continuationFromJournal Nothing =
  Left "first-reconcile journal is missing after backup admission opened"
continuationFromJournal (Just journal) = do
  next <-
    first
      (("first-reconcile cursor is invalid: " <>) . Text.pack . show)
      ( nextFirstReconcileMember
          (firstReconcileJournalPlan journal)
          (firstReconcileJournalCursor journal)
      )
  traverse toContinuation next
 where
  toContinuation member = case firstReconcilePlanMemberAction member of
    EstablishAuthorityBackupMember ->
      Left "first-reconcile genesis member remains after backup admission opened"
    ProvisionAwsCredentialMember credentialClass ->
      Right
        FirstReconcileContinuation
          { firstReconcileContinuationClass = credentialClass
          , firstReconcileContinuationMemberIndex = firstReconcilePlanMemberIndex member
          , firstReconcileContinuationMemberDigest =
              targetValueDigestText (firstReconcilePlanMemberDigest member)
          , firstReconcileContinuationDeadline =
              firstReconcilePlanDeadline (firstReconcileJournalPlan journal)
          }

currentJournalMember
  :: FirstReconcileJournal
  -> Either AwsAdminPreparedTargetPrepareError FirstReconcilePlanMember
currentJournalMember journal = do
  next <-
    first
      ( prepareFailure AwsAdminPreparedTargetJournalCursorRejected
          . Text.pack
          . show
      )
      ( nextFirstReconcileMember
          (firstReconcileJournalPlan journal)
          (firstReconcileJournalCursor journal)
      )
  maybe
    ( Left
        ( prepareFailure
            AwsAdminPreparedTargetJournalMemberMismatch
            "first-reconcile journal is already complete"
        )
    )
    Right
    next

bindingFor
  :: FirstReconcileJournal
  -> FirstReconcilePlanMember
  -> FirstReconcilePermitBinding
bindingFor journal member =
  mkFirstReconcilePermitBinding
    (firstReconcilePlanDigest (firstReconcileJournalPlan journal))
    (firstReconcilePlanMemberIndex member)
    (firstReconcilePlanMemberDigest member)
    (firstReconcilePriorReceiptDigest (firstReconcileJournalCursor journal))

preparedCoordinate
  :: LongLivedCheckpointAuthority
  -> AwsAdminPermitIntent
  -> Either Text (ModelBObjectCoordinate 'ClusterRetained)
preparedCoordinate authority intent =
  first
    (Text.pack . show)
    ( mkClusterRetainedCoordinate
        authority
        ( "authority/aws-admin-prepared-targets/"
            <> operatorMaterialOperationIdText
              (awsAdminPermitIntentOperationId intent)
        )
    )

publishAwsAdminPreparedTarget
  :: LongLivedCheckpointAuthority
  -> ModelBCasAdapter 'ClusterRetained IO PreparedCredentialTargetOutbox
  -> Maybe (AuthorityTime, AwsAdminPermitIntent)
  -> AwsAdminPermitIntent
  -> IO (Either AwsAdminPreparedTargetPrepareError PreparedCredentialTargetObservation)
publishAwsAdminPreparedTarget authority adapter renewal intent =
  case mkPreparedCredentialTargetOutbox intent of
    Left detail ->
      pure
        ( Left
            ( prepareFailure
                AwsAdminPreparedTargetIntentCanonicalizationRejected
                (Text.pack (show detail))
            )
        )
    Right expected ->
      case preparedCoordinate authority intent of
        Left detail ->
          pure
            ( Left
                ( prepareFailure
                    AwsAdminPreparedTargetCoordinateRejected
                    detail
                )
            )
        Right coordinate -> do
          observed <- modelBObserve adapter coordinate
          case observed of
            ModelBMissing -> case renewal of
              Just _ ->
                pure
                  ( Left
                      ( prepareFailure
                          AwsAdminPreparedTargetOutboxMissing
                          "expired prepared-target renewal outbox is missing"
                      )
                  )
              Nothing -> do
                _ <-
                  modelBCompareAndSwap
                    adapter
                    (ModelBInitialize coordinate expected)
                confirmed <- modelBObserve adapter coordinate
                pure (confirmExact expected confirmed)
            ModelBObserved version existing ->
              case decideAwsAdminPreparedTargetOutbox renewal intent existing of
                AwsAdminPreparedTargetOutboxExact ->
                  pure (Right (preparedCredentialTargetOutboxObservation existing))
                AwsAdminPreparedTargetOutboxReplace -> do
                  _ <-
                    modelBCompareAndSwap
                      adapter
                      (ModelBReplace coordinate version expected)
                  confirmed <- modelBObserve adapter coordinate
                  pure (confirmExact expected confirmed)
                AwsAdminPreparedTargetOutboxReject ->
                  do
                    writeDiagnosticLine
                      (Text.unpack (renderAwsAdminPreparedTargetOutboxDiagnostic renewal existing))
                    pure
                      ( Left
                          ( prepareFailure
                              AwsAdminPreparedTargetOutboxDivergent
                              "AWS-admin prepared-target operation already has a divergent outbox"
                          )
                      )
            ModelBCorrupt detail ->
              pure (Left (prepareFailure AwsAdminPreparedTargetOutboxCorrupt detail))
            ModelBEndpointUnready detail ->
              pure (Left (prepareFailure AwsAdminPreparedTargetOutboxEndpointUnready detail))
            ModelBUnobservable detail ->
              pure (Left (prepareFailure AwsAdminPreparedTargetOutboxUnobservable detail))
 where
  confirmExact expected confirmed = case confirmed of
    ModelBObserved _ retained
      | retained == expected ->
          Right (preparedCredentialTargetOutboxObservation retained)
      | preparedCredentialTargetOutboxCanonicalIntent retained == Just intent ->
          Right (preparedCredentialTargetOutboxObservation retained)
      | otherwise ->
          Left
            ( prepareFailure
                AwsAdminPreparedTargetOutboxDivergent
                "AWS-admin prepared-target CAS read back a divergent outbox"
            )
    ModelBMissing ->
      Left
        ( prepareFailure
            AwsAdminPreparedTargetOutboxMissing
            "AWS-admin prepared-target outbox is missing"
        )
    ModelBCorrupt detail ->
      Left (prepareFailure AwsAdminPreparedTargetOutboxCorrupt detail)
    ModelBEndpointUnready detail ->
      Left (prepareFailure AwsAdminPreparedTargetOutboxEndpointUnready detail)
    ModelBUnobservable detail ->
      Left (prepareFailure AwsAdminPreparedTargetOutboxUnobservable detail)

data AwsAdminPreparedTargetOutboxDecision
  = AwsAdminPreparedTargetOutboxExact
  | AwsAdminPreparedTargetOutboxReplace
  | AwsAdminPreparedTargetOutboxReject
  deriving (Eq, Show)

decideAwsAdminPreparedTargetOutbox
  :: Maybe (AuthorityTime, AwsAdminPermitIntent)
  -> AwsAdminPermitIntent
  -> PreparedCredentialTargetOutbox
  -> AwsAdminPreparedTargetOutboxDecision
decideAwsAdminPreparedTargetOutbox renewal expected observed
  | preparedCredentialTargetOutboxCanonicalIntent observed == Just expected =
      AwsAdminPreparedTargetOutboxExact
  | preparedCredentialTargetOutboxIsLegacy observed
  , preparedCredentialTargetOutboxObservation observed
      == awsAdminPermitIntentPreparedTarget expected =
      AwsAdminPreparedTargetOutboxReplace
  | Just (_, retained) <- renewal
  , observedIsRetained retained observed =
      AwsAdminPreparedTargetOutboxReplace
  | Just (now, retained) <- renewal
  , expiredOutboxAhead now retained expected observed =
      AwsAdminPreparedTargetOutboxReplace
  | otherwise = AwsAdminPreparedTargetOutboxReject

observedIsRetained
  :: AwsAdminPermitIntent -> PreparedCredentialTargetOutbox -> Bool
observedIsRetained retained observed =
  case preparedCredentialTargetOutboxCanonicalIntent observed of
    Just canonical -> canonical == retained
    Nothing ->
      preparedCredentialTargetOutboxObservation observed
        == awsAdminPermitIntentPreparedTarget retained

expiredOutboxAhead
  :: AuthorityTime
  -> AwsAdminPermitIntent
  -> AwsAdminPermitIntent
  -> PreparedCredentialTargetOutbox
  -> Bool
expiredOutboxAhead now retainedIntent expectedIntent observedOutbox =
  preparedCredentialTargetOwnerNonce retained == preparedCredentialTargetOwnerNonce observed
    && preparedCredentialTargetFence retained == preparedCredentialTargetFence observed
    && preparedCredentialTargetId retained == preparedCredentialTargetId observed
    && preparedCredentialTargetGeneration retained == preparedCredentialTargetGeneration observed
    && preparedCredentialTargetRequestDigest retained == preparedCredentialTargetRequestDigest observed
    && preparedCredentialTargetPlanBinding retained == preparedCredentialTargetPlanBinding observed
    && authorityTimeMicros (preparedCredentialTargetDeadline retained)
      < authorityTimeMicros (preparedCredentialTargetDeadline observed)
    && authorityTimeMicros (preparedCredentialTargetDeadline observed) <= authorityTimeMicros now
    && canonicalBindingsMatch
 where
  retained = awsAdminPermitIntentPreparedTarget retainedIntent
  observed = preparedCredentialTargetOutboxObservation observedOutbox
  canonicalBindingsMatch =
    case preparedCredentialTargetOutboxCanonicalIntent observedOutbox of
      Nothing -> True
      Just canonical ->
        awsAdminPreparedRenewalBindingsMatch retainedIntent canonical
          || awsAdminPreparedRenewalBindingsMatch expectedIntent canonical

renderAwsAdminPreparedTargetOutboxDiagnostic
  :: Maybe (AuthorityTime, AwsAdminPermitIntent)
  -> PreparedCredentialTargetOutbox
  -> Text
renderAwsAdminPreparedTargetOutboxDiagnostic renewal observedOutbox =
  Text.intercalate
    " "
    ( [ "prepared-target/outbox/divergent"
      , "schema=" <> if preparedCredentialTargetOutboxIsLegacy observedOutbox then "legacy" else "current"
      ]
        <> renewalProjection
    )
 where
  observed = preparedCredentialTargetOutboxObservation observedOutbox
  renewalProjection = case renewal of
    Nothing -> ["renewal=absent"]
    Just (now, retainedIntent) ->
      let retained = awsAdminPermitIntentPreparedTarget retainedIntent
       in [ fieldMatch
              "owner"
              preparedCredentialTargetOwnerNonce
              retained
              observed
          , fieldMatch "fence" preparedCredentialTargetFence retained observed
          , fieldMatch "target" preparedCredentialTargetId retained observed
          , fieldMatch
              "generation"
              preparedCredentialTargetGeneration
              retained
              observed
          , fieldMatch
              "request"
              preparedCredentialTargetRequestDigest
              retained
              observed
          , fieldMatch
              "plan"
              preparedCredentialTargetPlanBinding
              retained
              observed
          , "deadline=" <> deadlineRelation now retained observed
          , "canonical-bindings=" <> canonicalBindingRelation retainedIntent observedOutbox
          ]
  fieldMatch label project retainedValue observedValue =
    label <> "=" <> matchText (project retainedValue == project observedValue)
  matchText matches = if matches then "match" else "mismatch"
  deadlineRelation now retainedValue observedValue
    | authorityTimeMicros (preparedCredentialTargetDeadline observedValue)
        <= authorityTimeMicros (preparedCredentialTargetDeadline retainedValue) =
        "not-forward"
    | authorityTimeMicros (preparedCredentialTargetDeadline observedValue)
        > authorityTimeMicros now =
        "forward-active"
    | otherwise = "forward-expired"
  canonicalBindingRelation retainedIntent candidateOutbox =
    case preparedCredentialTargetOutboxCanonicalIntent candidateOutbox of
      Nothing -> "legacy-unavailable"
      Just canonical ->
        matchText (awsAdminPreparedRenewalBindingsMatch retainedIntent canonical)

preparedFromObservation
  :: ModelBObservation PreparedCredentialTargetOutbox
  -> Either Text PreparedCredentialTargetObservation
preparedFromObservation observation = case observation of
  ModelBMissing -> Left "AWS-admin prepared-target outbox is missing"
  ModelBObserved _ outbox -> Right (preparedCredentialTargetOutboxObservation outbox)
  ModelBCorrupt detail -> Left ("AWS-admin prepared-target outbox is corrupt: " <> detail)
  ModelBEndpointUnready detail ->
    Left ("AWS-admin prepared-target outbox is not ready: " <> detail)
  ModelBUnobservable detail ->
    Left ("AWS-admin prepared-target outbox is unobservable: " <> detail)

receiptForBinding
  :: FirstReconcilePermitBinding
  -> FirstReconcileJournal
  -> TargetWorkerReceipt
  -> Either Text FirstReconcileReceipt
receiptForBinding binding journal targetReceipt = do
  let plan = firstReconcileJournalPlan journal
  unless
    (firstReconcilePermitPlanDigest binding == firstReconcilePlanDigest plan)
    (Left "first-reconcile permit plan digest differs from retained journal")
  member <-
    maybe
      (Left "first-reconcile permit member is absent from retained journal")
      Right
      ( find
          ( \candidate ->
              firstReconcilePlanMemberIndex candidate
                == firstReconcilePermitMemberIndex binding
                && firstReconcilePlanMemberDigest candidate
                  == firstReconcilePermitMemberDigest binding
          )
          (firstReconcilePlanMembers plan)
      )
  first
    (Text.pack . show)
    ( mkFirstReconcileReceipt
        member
        (Text.pack (show (targetWorkerReceiptVaultVersion targetReceipt)))
        (targetWorkerReceiptCommitment targetReceipt)
    )

appendAndConfirm
  :: ModelBCasAdapter 'ClusterRetained IO FirstReconcileJournal
  -> ModelBObjectCoordinate 'ClusterRetained
  -> Int
  -> FirstReconcileReceipt
  -> IO (Either Text ())
appendAndConfirm _ _ remaining _
  | remaining <= 0 = pure (Left "first-reconcile receipt CAS retry limit reached")
appendAndConfirm adapter coordinate remaining receipt = do
  _ <- appendFirstReconcileJournalStore adapter coordinate receipt
  observed <- modelBObserve adapter coordinate
  case observed of
    ModelBObserved _ journal -> case appendFirstReconcileReceipt receipt journal of
      Right replayed
        | replayed == journal -> pure (Right ())
        | otherwise -> appendAndConfirm adapter coordinate (remaining - 1) receipt
      Left err -> pure (Left ("first-reconcile receipt conflicts: " <> Text.pack (show err)))
    ModelBMissing -> pure (Left "first-reconcile journal disappeared during receipt commit")
    ModelBCorrupt detail -> pure (Left ("first-reconcile journal is corrupt: " <> detail))
    ModelBEndpointUnready detail ->
      pure (Left ("first-reconcile journal is not ready: " <> detail))
    ModelBUnobservable detail ->
      pure (Left ("first-reconcile journal is unobservable: " <> detail))
