{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NamedFieldPuns #-}

-- | Pure crash-safe custody folds for root and child Vault initialization.
--
-- The folds deliberately distinguish "effect requested", "effect returned",
-- "object written", and "authoritative read-back" phases.  A caller can stop
-- after any event, supply a fresh durable observation to the restart helpers,
-- and obtain the only safe next plan.  No function in this module performs
-- cryptography, Vault I/O, or object-store I/O.
module Prodbox.Bootstrap.Broker.Custody
  ( -- * Cancellation shared by custody folds
    CancellationReason
  , mkCancellationReason
  , renderCancellationReason
  , CustodyDisposition (..)

    -- * Root initialization
  , RootInitPhase (..)
  , RootInitState (..)
  , RootInitCommand (..)
  , RootInitEvent (..)
  , RootInitPlan (..)
  , RootInitDurableObservation (..)
  , RootInitError (..)
  , RootInitInvariantViolation (..)
  , newRootInitState
  , decideRootInit
  , evolveRootInit
  , applyRootInitCommand
  , planRootInit
  , resumeRootInitFromObservation
  , restartRootInit
  , rootInitInvariantViolations
  , rootInitIsComplete
  , rootInitIsAmbiguous

    -- * Child initialization custody
  , ChildCustodyPhase (..)
  , ChildCustodyState (..)
  , ChildCustodyCommand (..)
  , ChildCustodyEvent (..)
  , ChildCustodyPlan (..)
  , ChildCustodyDurableObservation (..)
  , ChildCustodyError (..)
  , ChildCustodyInvariantViolation (..)
  , newChildCustodyState
  , decideChildCustody
  , evolveChildCustody
  , applyChildCustodyCommand
  , planChildCustody
  , resumeChildCustodyFromObservation
  , restartChildCustody
  , childCustodyInvariantViolations
  , childCustodyIsComplete

    -- * One-time child recovery delivery
  , ChildRecoveryPhase (..)
  , ChildRecoveryState (..)
  , ChildRecoveryCommand (..)
  , ChildRecoveryEvent (..)
  , ChildRecoveryPlan (..)
  , ChildRecoveryError (..)
  , ChildRecoveryInvariantViolation (..)
  , newChildRecoveryState
  , decideChildRecovery
  , evolveChildRecovery
  , applyChildRecoveryCommand
  , planChildRecovery
  , restartChildRecovery
  , childRecoveryInvariantViolations
  , childRecoveryIsComplete
  )
where

import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Types

newtype CancellationReason = CancellationReason Text
  deriving stock (Eq, Ord)

instance Show CancellationReason where
  show _ = "CancellationReason <redacted>"

mkCancellationReason :: Text -> Either String CancellationReason
mkCancellationReason raw
  | Text.null value = Left "cancellation reason must not be empty"
  | Text.length value > 256 = Left "cancellation reason exceeds 256 characters"
  | otherwise = Right (CancellationReason value)
 where
  value = Text.strip raw

renderCancellationReason :: CancellationReason -> Text
renderCancellationReason (CancellationReason value) = value

data CustodyDisposition
  = CustodyRunning
  | CustodyCancellationRequested !CancellationReason
  deriving stock (Eq)

instance Show CustodyDisposition where
  show disposition =
    case disposition of
      CustodyRunning -> "CustodyRunning"
      CustodyCancellationRequested _ -> "CustodyCancellationRequested <redacted>"

-- Root initialization -------------------------------------------------------

data RootInitPhase
  = RootInitPristine !PristineStorageProof
  | RootPreparedWritePending !PreparedInitEnvelope
  | RootPreparedWritten !PreparedInitEnvelope
  | RootPreparedReadBack !PreparedInitEnvelope
  | RootInitCallPending !PreparedInitEnvelope
  | RootInitCallInFlight !PreparedInitEnvelope
  | RootEncryptedResponseCapturePending !PreparedInitEnvelope !EncryptedInitResponseReceipt
  | RootEncryptedResponseWritten !PreparedInitEnvelope !EncryptedInitResponseReceipt
  | RootEncryptedResponseReadBack !PreparedInitEnvelope !EncryptedInitResponseReceipt
  | RootFinalBundlePromotionPending
      !PreparedInitEnvelope
      !EncryptedInitResponseReceipt
      !FinalUnlockBundle
  | RootFinalBundlePromoted
      !PreparedInitEnvelope
      !EncryptedInitResponseReceipt
      !FinalUnlockBundle
  | RootFinalBundleReadBack
      !PreparedInitEnvelope
      !EncryptedInitResponseReceipt
      !FinalUnlockBundle
  | RootPreparedDeletionPending !PreparedInitEnvelope !FinalUnlockBundle
  | RootPreparedDeleted !PreparedInitEnvelope !FinalUnlockBundle
  | RootPreparedAbsent !FinalUnlockBundle
  | RootRecoveryCustodyAcknowledgementPending !FinalUnlockBundle
  | RootRecoveryCustodyDurable !FinalUnlockBundle !RecoveryCustodyReceipt
  | RootInitializationAmbiguous !InitAmbiguity
  deriving stock (Eq)

instance Show RootInitPhase where
  show = rootInitPhaseName

data RootInitState = RootInitState
  { rootInitStateBinding :: !RootInitBinding
  , rootInitStateDisposition :: !CustodyDisposition
  , rootInitStatePhase :: !RootInitPhase
  }
  deriving stock (Eq)

instance Show RootInitState where
  show state =
    "RootInitState {binding = "
      ++ show (rootInitStateBinding state)
      ++ ", disposition = "
      ++ show (rootInitStateDisposition state)
      ++ ", phase = "
      ++ rootInitPhaseName (rootInitStatePhase state)
      ++ "}"

data RootInitCommand
  = PrepareRootInitEnvelope !PreparedInitEnvelope
  | RecordPreparedInitWrite
  | ConfirmPreparedInitReadBack !PreparedInitEnvelope
  | ArmRootVaultInitCall
  | RecordRootVaultInitCallStarted
  | CaptureEncryptedInitResponse !EncryptedInitResponseReceipt
  | RecordEncryptedInitResponseWrite
  | ConfirmEncryptedInitResponseReadBack !EncryptedInitResponseReceipt
  | PrepareFinalUnlockBundle !FinalUnlockBundle
  | RecordFinalUnlockBundlePromotion
  | ConfirmFinalUnlockBundleReadBack !FinalUnlockBundle
  | ArmPreparedInitDeletion
  | RecordPreparedInitDeletion
  | ConfirmPreparedInitAbsence
  | ArmRecoveryCustodyAcknowledgement
  | ConfirmRecoveryCustody !RecoveryCustodyReceipt
  | MarkRootInitAppliedWithoutDurableResponse
  | CancelRootInitialization !CancellationReason
  | ResetAmbiguousRootInitialization !PristineResetProof
  deriving stock (Eq)

instance Show RootInitCommand where
  show = rootInitCommandName

data RootInitEvent
  = RootInitEnvelopePrepared !PreparedInitEnvelope
  | RootPreparedInitWriteRecorded
  | RootPreparedInitReadBackConfirmed !PreparedInitEnvelope
  | RootVaultInitCallArmed
  | RootVaultInitCallStarted
  | RootEncryptedInitResponseCaptured !EncryptedInitResponseReceipt
  | RootEncryptedInitResponseWriteRecorded
  | RootEncryptedInitResponseReadBackConfirmed !EncryptedInitResponseReceipt
  | RootFinalUnlockBundlePrepared !FinalUnlockBundle
  | RootFinalUnlockBundlePromotionRecorded
  | RootFinalUnlockBundleReadBackConfirmed !FinalUnlockBundle
  | RootPreparedInitDeletionArmed
  | RootPreparedInitDeletionRecorded
  | RootPreparedInitAbsenceConfirmed
  | RootRecoveryCustodyAcknowledgementArmed
  | RootRecoveryCustodyConfirmed !RecoveryCustodyReceipt
  | RootInitializationMarkedAmbiguous
  | RootInitializationCancellationLatched !CancellationReason
  | RootInitializationResetToPristine !PristineResetProof
  deriving stock (Eq)

instance Show RootInitEvent where
  show = rootInitEventName

-- | The next boundary effect.  A plan containing an artifact exposes only its
-- redacted wrapper; no secret bytes can be rendered by 'Show'.
data RootInitPlan
  = RootPlanGenerateAndSealPreparedEnvelope !PristineStorageProof
  | RootPlanWritePreparedEnvelope !PreparedInitEnvelope
  | RootPlanReadBackPreparedEnvelope !PreparedInitEnvelope
  | RootPlanArmVaultInitCall !PreparedInitEnvelope
  | RootPlanCallVaultInit !PreparedInitEnvelope
  | RootPlanAwaitVaultInitResponse !RootInitBinding
  | RootPlanWriteEncryptedResponse !EncryptedInitResponseReceipt
  | RootPlanReadBackEncryptedResponse !EncryptedInitResponseReceipt
  | RootPlanDecryptSharesAndSealFinalBundle !EncryptedInitResponseReceipt
  | RootPlanPromoteFinalBundle !FinalUnlockBundle
  | RootPlanReadBackFinalBundle !FinalUnlockBundle
  | RootPlanDeletePreparedEnvelope !PreparedInitEnvelope
  | RootPlanReadBackPreparedAbsence !RootInitBinding
  | RootPlanAcknowledgeRecoveryCustody !FinalUnlockBundle
  | RootPlanAmbiguityRequiresPristineReset !InitAmbiguity
  | RootPlanCancellationLatched !String
  | RootPlanComplete !RecoveryCustodyReceipt
  deriving stock (Eq)

instance Show RootInitPlan where
  show plan =
    case plan of
      RootPlanGenerateAndSealPreparedEnvelope _ -> "RootPlanGenerateAndSealPreparedEnvelope"
      RootPlanWritePreparedEnvelope _ -> "RootPlanWritePreparedEnvelope <redacted>"
      RootPlanReadBackPreparedEnvelope _ -> "RootPlanReadBackPreparedEnvelope"
      RootPlanArmVaultInitCall _ -> "RootPlanArmVaultInitCall"
      RootPlanCallVaultInit _ -> "RootPlanCallVaultInit"
      RootPlanAwaitVaultInitResponse _ -> "RootPlanAwaitVaultInitResponse"
      RootPlanWriteEncryptedResponse _ -> "RootPlanWriteEncryptedResponse <redacted>"
      RootPlanReadBackEncryptedResponse _ -> "RootPlanReadBackEncryptedResponse"
      RootPlanDecryptSharesAndSealFinalBundle _ ->
        "RootPlanDecryptSharesAndSealFinalBundle <redacted>"
      RootPlanPromoteFinalBundle _ -> "RootPlanPromoteFinalBundle <redacted>"
      RootPlanReadBackFinalBundle _ -> "RootPlanReadBackFinalBundle"
      RootPlanDeletePreparedEnvelope _ -> "RootPlanDeletePreparedEnvelope"
      RootPlanReadBackPreparedAbsence _ -> "RootPlanReadBackPreparedAbsence"
      RootPlanAcknowledgeRecoveryCustody _ -> "RootPlanAcknowledgeRecoveryCustody"
      RootPlanAmbiguityRequiresPristineReset _ ->
        "RootPlanAmbiguityRequiresPristineReset"
      RootPlanCancellationLatched phase ->
        "RootPlanCancellationLatched {phase = " ++ phase ++ "}"
      RootPlanComplete _ -> "RootPlanComplete"

-- | Authoritative facts reconstructed after process loss.  Written-but-not-
-- read-back phases are absent: restart must re-observe the store and choose one
-- of these durable prefixes.
data RootInitDurableObservation
  = RootObservedPristine !PristineStorageProof
  | RootObservedPreparedVaultUninitialized !PreparedInitEnvelope
  | RootObservedPreparedVaultInitializedWithoutResponse !PreparedInitEnvelope
  | RootObservedEncryptedResponse
      !PreparedInitEnvelope
      !EncryptedInitResponseReceipt
  | RootObservedFinalBundlePreparedPresent
      !PreparedInitEnvelope
      !EncryptedInitResponseReceipt
      !FinalUnlockBundle
  | RootObservedFinalBundlePreparedAbsent !FinalUnlockBundle
  | RootObservedRecoveryCustody !FinalUnlockBundle !RecoveryCustodyReceipt
  deriving stock (Eq)

instance Show RootInitDurableObservation where
  show observation =
    case observation of
      RootObservedPristine _ -> "RootObservedPristine"
      RootObservedPreparedVaultUninitialized _ ->
        "RootObservedPreparedVaultUninitialized"
      RootObservedPreparedVaultInitializedWithoutResponse _ ->
        "RootObservedPreparedVaultInitializedWithoutResponse"
      RootObservedEncryptedResponse _ _ -> "RootObservedEncryptedResponse <redacted>"
      RootObservedFinalBundlePreparedPresent {} ->
        "RootObservedFinalBundlePreparedPresent <redacted>"
      RootObservedFinalBundlePreparedAbsent _ ->
        "RootObservedFinalBundlePreparedAbsent <redacted>"
      RootObservedRecoveryCustody _ _ -> "RootObservedRecoveryCustody"

data RootInitError
  = RootInitPhaseRefusal !String !String
  | RootInitCancellationRefusal !String
  | RootInitBindingMismatch !RootInitBinding !RootInitBinding
  | RootInitPreparedReadBackMismatch
  | RootInitEncryptedResponseMismatch
  | RootInitFinalBundleMismatch
  | RootInitRecoveryCustodyMismatch
  | RootInitResetProofMismatch
  | RootInitResetDidNotAdvanceBinding
  | RootInitResetOnlyFromAmbiguity
  | RootInitEstablishedGenerationResetRefused
  | RootInitObservationRegression !Natural !Natural
  | RootInitInvariantFailure ![RootInitInvariantViolation]
  deriving stock (Eq, Show)

data RootInitInvariantViolation
  = RootPhaseBindingDiffers !RootInitBinding !RootInitBinding
  | RootPreparedResponseBindingDiffers
  | RootPreparedResponseSchemaDiffers
  | RootPreparedResponseRecoveryFingerprintDiffers
  | RootPreparedResponseBurnFingerprintDiffers
  | RootResponseFinalBindingDiffers
  | RootResponseFinalSchemaDiffers
  | RootResponseFinalShareCountDiffers !Natural !Natural
  | RootFinalCustodyBindingDiffers
  | RootFinalCustodyDigestDiffers
  deriving stock (Eq, Show)

newRootInitState :: PristineStorageProof -> RootInitState
newRootInitState proof =
  RootInitState
    { rootInitStateBinding = pristineStorageBinding proof
    , rootInitStateDisposition = CustodyRunning
    , rootInitStatePhase = RootInitPristine proof
    }

decideRootInit
  :: RootInitState -> RootInitCommand -> Either RootInitError RootInitEvent
decideRootInit state command = do
  event <- rootInitEventForCommand command
  _ <- evolveRootInit state event
  pure event

evolveRootInit
  :: RootInitState -> RootInitEvent -> Either RootInitError RootInitState
evolveRootInit state event = do
  requireRootEventAllowedByDisposition state event
  evolved <- evolveRootInitPhase state event
  validateRootInitState evolved

applyRootInitCommand
  :: RootInitState -> RootInitCommand -> Either RootInitError RootInitState
applyRootInitCommand state command = do
  event <- decideRootInit state command
  evolveRootInit state event

planRootInit :: RootInitState -> RootInitPlan
planRootInit state
  | cancellationStopsNewInit state =
      RootPlanCancellationLatched (rootInitPhaseName (rootInitStatePhase state))
  | otherwise =
      case rootInitStatePhase state of
        RootInitPristine proof -> RootPlanGenerateAndSealPreparedEnvelope proof
        RootPreparedWritePending prepared -> RootPlanWritePreparedEnvelope prepared
        RootPreparedWritten prepared -> RootPlanReadBackPreparedEnvelope prepared
        RootPreparedReadBack prepared -> RootPlanArmVaultInitCall prepared
        RootInitCallPending prepared -> RootPlanCallVaultInit prepared
        RootInitCallInFlight prepared ->
          RootPlanAwaitVaultInitResponse (preparedInitBinding prepared)
        RootEncryptedResponseCapturePending _ receipt ->
          RootPlanWriteEncryptedResponse receipt
        RootEncryptedResponseWritten _ receipt ->
          RootPlanReadBackEncryptedResponse receipt
        RootEncryptedResponseReadBack _ receipt ->
          RootPlanDecryptSharesAndSealFinalBundle receipt
        RootFinalBundlePromotionPending _ _ bundle -> RootPlanPromoteFinalBundle bundle
        RootFinalBundlePromoted _ _ bundle -> RootPlanReadBackFinalBundle bundle
        RootFinalBundleReadBack prepared _ _ -> RootPlanDeletePreparedEnvelope prepared
        RootPreparedDeletionPending prepared _ -> RootPlanDeletePreparedEnvelope prepared
        RootPreparedDeleted _ bundle ->
          RootPlanReadBackPreparedAbsence (finalUnlockBundleBinding bundle)
        RootPreparedAbsent bundle -> RootPlanAcknowledgeRecoveryCustody bundle
        RootRecoveryCustodyAcknowledgementPending bundle ->
          RootPlanAcknowledgeRecoveryCustody bundle
        RootRecoveryCustodyDurable _ receipt -> RootPlanComplete receipt
        RootInitializationAmbiguous ambiguity ->
          RootPlanAmbiguityRequiresPristineReset ambiguity

resumeRootInitFromObservation
  :: RootInitDurableObservation -> Either RootInitError RootInitState
resumeRootInitFromObservation observation =
  validateRootInitState
    RootInitState
      { rootInitStateBinding = rootObservationBinding observation
      , rootInitStateDisposition = CustodyRunning
      , rootInitStatePhase = rootPhaseFromObservation observation
      }

restartRootInit
  :: RootInitState
  -> RootInitDurableObservation
  -> Either RootInitError RootInitState
restartRootInit current observation = do
  requireSameRootBinding
    (rootInitStateBinding current)
    (rootObservationBinding observation)
  let committedRank = rootCommittedRank (rootInitStatePhase current)
      observedRank = rootObservationRank observation
  if observedRank < committedRank
    then Left (RootInitObservationRegression committedRank observedRank)
    else resumeRootInitFromObservation observation

rootInitInvariantViolations :: RootInitState -> [RootInitInvariantViolation]
rootInitInvariantViolations state =
  phaseBindingViolations
    ++ phaseRelationshipViolations (rootInitStatePhase state)
 where
  expected = rootInitStateBinding state
  actual = rootPhaseBinding (rootInitStatePhase state)
  phaseBindingViolations =
    [ RootPhaseBindingDiffers expected actual
    | expected /= actual
    ]

rootInitIsComplete :: RootInitState -> Bool
rootInitIsComplete state =
  case rootInitStatePhase state of
    RootRecoveryCustodyDurable _ _ -> True
    _ -> False

rootInitIsAmbiguous :: RootInitState -> Bool
rootInitIsAmbiguous state =
  case rootInitStatePhase state of
    RootInitializationAmbiguous _ -> True
    _ -> False

rootInitEventForCommand :: RootInitCommand -> Either RootInitError RootInitEvent
rootInitEventForCommand command =
  Right $ case command of
    PrepareRootInitEnvelope prepared -> RootInitEnvelopePrepared prepared
    RecordPreparedInitWrite -> RootPreparedInitWriteRecorded
    ConfirmPreparedInitReadBack prepared -> RootPreparedInitReadBackConfirmed prepared
    ArmRootVaultInitCall -> RootVaultInitCallArmed
    RecordRootVaultInitCallStarted -> RootVaultInitCallStarted
    CaptureEncryptedInitResponse receipt -> RootEncryptedInitResponseCaptured receipt
    RecordEncryptedInitResponseWrite -> RootEncryptedInitResponseWriteRecorded
    ConfirmEncryptedInitResponseReadBack receipt ->
      RootEncryptedInitResponseReadBackConfirmed receipt
    PrepareFinalUnlockBundle bundle -> RootFinalUnlockBundlePrepared bundle
    RecordFinalUnlockBundlePromotion -> RootFinalUnlockBundlePromotionRecorded
    ConfirmFinalUnlockBundleReadBack bundle ->
      RootFinalUnlockBundleReadBackConfirmed bundle
    ArmPreparedInitDeletion -> RootPreparedInitDeletionArmed
    RecordPreparedInitDeletion -> RootPreparedInitDeletionRecorded
    ConfirmPreparedInitAbsence -> RootPreparedInitAbsenceConfirmed
    ArmRecoveryCustodyAcknowledgement -> RootRecoveryCustodyAcknowledgementArmed
    ConfirmRecoveryCustody receipt -> RootRecoveryCustodyConfirmed receipt
    MarkRootInitAppliedWithoutDurableResponse -> RootInitializationMarkedAmbiguous
    CancelRootInitialization reason -> RootInitializationCancellationLatched reason
    ResetAmbiguousRootInitialization proof -> RootInitializationResetToPristine proof

evolveRootInitPhase
  :: RootInitState -> RootInitEvent -> Either RootInitError RootInitState
evolveRootInitPhase state event =
  case (rootInitStatePhase state, event) of
    (RootInitPristine proof, RootInitEnvelopePrepared prepared) -> do
      requireSameRootBinding (pristineStorageBinding proof) (preparedInitBinding prepared)
      withPhase state (RootPreparedWritePending prepared)
    (RootPreparedWritePending prepared, RootPreparedInitWriteRecorded) ->
      withPhase state (RootPreparedWritten prepared)
    (RootPreparedWritten prepared, RootPreparedInitReadBackConfirmed observed)
      | observed == prepared -> withPhase state (RootPreparedReadBack observed)
      | otherwise -> Left RootInitPreparedReadBackMismatch
    (RootPreparedReadBack prepared, RootVaultInitCallArmed) ->
      withPhase state (RootInitCallPending prepared)
    (RootInitCallPending prepared, RootVaultInitCallStarted) ->
      withPhase state (RootInitCallInFlight prepared)
    (RootInitCallInFlight prepared, RootEncryptedInitResponseCaptured receipt) -> do
      requirePreparedResponseMatch prepared receipt
      withPhase state (RootEncryptedResponseCapturePending prepared receipt)
    (RootEncryptedResponseCapturePending prepared receipt, RootEncryptedInitResponseWriteRecorded) ->
      withPhase state (RootEncryptedResponseWritten prepared receipt)
    (RootEncryptedResponseWritten prepared receipt, RootEncryptedInitResponseReadBackConfirmed observed)
      | observed == receipt ->
          withPhase state (RootEncryptedResponseReadBack prepared observed)
      | otherwise -> Left RootInitEncryptedResponseMismatch
    (RootEncryptedResponseReadBack prepared receipt, RootFinalUnlockBundlePrepared bundle) -> do
      requireResponseFinalMatch receipt bundle
      withPhase state (RootFinalBundlePromotionPending prepared receipt bundle)
    (RootFinalBundlePromotionPending prepared receipt bundle, RootFinalUnlockBundlePromotionRecorded) ->
      withPhase state (RootFinalBundlePromoted prepared receipt bundle)
    (RootFinalBundlePromoted prepared receipt bundle, RootFinalUnlockBundleReadBackConfirmed observed)
      | observed == bundle ->
          withPhase state (RootFinalBundleReadBack prepared receipt observed)
      | otherwise -> Left RootInitFinalBundleMismatch
    (RootFinalBundleReadBack prepared _ bundle, RootPreparedInitDeletionArmed) ->
      withPhase state (RootPreparedDeletionPending prepared bundle)
    (RootPreparedDeletionPending prepared bundle, RootPreparedInitDeletionRecorded) ->
      withPhase state (RootPreparedDeleted prepared bundle)
    (RootPreparedDeleted _ bundle, RootPreparedInitAbsenceConfirmed) ->
      withPhase state (RootPreparedAbsent bundle)
    (RootPreparedAbsent bundle, RootRecoveryCustodyAcknowledgementArmed) ->
      withPhase state (RootRecoveryCustodyAcknowledgementPending bundle)
    (RootRecoveryCustodyAcknowledgementPending bundle, RootRecoveryCustodyConfirmed receipt) -> do
      requireFinalCustodyMatch bundle receipt
      withPhase state (RootRecoveryCustodyDurable bundle receipt)
    (phase, RootInitializationMarkedAmbiguous) ->
      case preparedForAmbiguity phase of
        Nothing -> phaseRefusal phase event
        Just prepared -> withPhase state (RootInitializationAmbiguous (mkInitAmbiguity prepared))
    (_, RootInitializationCancellationLatched reason) ->
      Right state {rootInitStateDisposition = CustodyCancellationRequested reason}
    (RootInitializationAmbiguous ambiguity, RootInitializationResetToPristine proof) -> do
      if resetAmbiguousBinding proof /= ambiguousInitBinding ambiguity
        then Left RootInitResetProofMismatch
        else
          if pristineStorageBinding (resetReplacementPristine proof) == ambiguousInitBinding ambiguity
            then Left RootInitResetDidNotAdvanceBinding
            else
              Right
                (newRootInitState (resetReplacementPristine proof))
    (RootRecoveryCustodyDurable _ _, RootInitializationResetToPristine _) ->
      Left RootInitEstablishedGenerationResetRefused
    (_, RootInitializationResetToPristine _) -> Left RootInitResetOnlyFromAmbiguity
    (phase, _) -> phaseRefusal phase event

withPhase :: RootInitState -> RootInitPhase -> Either RootInitError RootInitState
withPhase state phase =
  Right state {rootInitStatePhase = phase}

phaseRefusal :: RootInitPhase -> RootInitEvent -> Either RootInitError value
phaseRefusal phase event =
  Left (RootInitPhaseRefusal (rootInitPhaseName phase) (rootInitEventName event))

requireRootEventAllowedByDisposition
  :: RootInitState -> RootInitEvent -> Either RootInitError ()
requireRootEventAllowedByDisposition state event =
  case rootInitStateDisposition state of
    CustodyRunning -> Right ()
    CustodyCancellationRequested _
      | rootEventIsSafetyTail event -> Right ()
      | otherwise -> Left (RootInitCancellationRefusal (rootInitEventName event))

rootEventIsSafetyTail :: RootInitEvent -> Bool
rootEventIsSafetyTail event =
  case event of
    RootEncryptedInitResponseCaptured _ -> True
    RootEncryptedInitResponseWriteRecorded -> True
    RootEncryptedInitResponseReadBackConfirmed _ -> True
    RootFinalUnlockBundlePrepared _ -> True
    RootFinalUnlockBundlePromotionRecorded -> True
    RootFinalUnlockBundleReadBackConfirmed _ -> True
    RootPreparedInitDeletionArmed -> True
    RootPreparedInitDeletionRecorded -> True
    RootPreparedInitAbsenceConfirmed -> True
    RootRecoveryCustodyAcknowledgementArmed -> True
    RootRecoveryCustodyConfirmed _ -> True
    RootInitializationMarkedAmbiguous -> True
    RootInitializationCancellationLatched _ -> True
    RootInitializationResetToPristine _ -> False
    RootInitEnvelopePrepared _ -> False
    RootPreparedInitWriteRecorded -> False
    RootPreparedInitReadBackConfirmed _ -> False
    RootVaultInitCallArmed -> False
    RootVaultInitCallStarted -> False

cancellationStopsNewInit :: RootInitState -> Bool
cancellationStopsNewInit state =
  case rootInitStateDisposition state of
    CustodyRunning -> False
    CustodyCancellationRequested _ ->
      case rootInitStatePhase state of
        RootInitPristine _ -> True
        RootPreparedWritePending _ -> True
        RootPreparedWritten _ -> True
        RootPreparedReadBack _ -> True
        RootInitCallPending _ -> True
        RootInitializationAmbiguous _ -> True
        _ -> False

preparedForAmbiguity :: RootInitPhase -> Maybe PreparedInitEnvelope
preparedForAmbiguity phase =
  case phase of
    RootInitCallInFlight prepared -> Just prepared
    RootEncryptedResponseCapturePending prepared _ -> Just prepared
    _ -> Nothing

validateRootInitState :: RootInitState -> Either RootInitError RootInitState
validateRootInitState state =
  case rootInitInvariantViolations state of
    [] -> Right state
    violations -> Left (RootInitInvariantFailure violations)

requireSameRootBinding
  :: RootInitBinding -> RootInitBinding -> Either RootInitError ()
requireSameRootBinding expected actual
  | expected == actual = Right ()
  | otherwise = Left (RootInitBindingMismatch expected actual)

requirePreparedResponseMatch
  :: PreparedInitEnvelope
  -> EncryptedInitResponseReceipt
  -> Either RootInitError ()
requirePreparedResponseMatch prepared receipt =
  case preparedResponseViolations prepared receipt of
    [] -> Right ()
    _ -> Left RootInitEncryptedResponseMismatch

requireResponseFinalMatch
  :: EncryptedInitResponseReceipt -> FinalUnlockBundle -> Either RootInitError ()
requireResponseFinalMatch receipt bundle =
  case responseFinalViolations receipt bundle of
    [] -> Right ()
    _ -> Left RootInitFinalBundleMismatch

requireFinalCustodyMatch
  :: FinalUnlockBundle -> RecoveryCustodyReceipt -> Either RootInitError ()
requireFinalCustodyMatch bundle receipt =
  case finalCustodyViolations bundle receipt of
    [] -> Right ()
    _ -> Left RootInitRecoveryCustodyMismatch

phaseRelationshipViolations :: RootInitPhase -> [RootInitInvariantViolation]
phaseRelationshipViolations phase =
  case phase of
    RootEncryptedResponseCapturePending prepared receipt ->
      preparedResponseViolations prepared receipt
    RootEncryptedResponseWritten prepared receipt ->
      preparedResponseViolations prepared receipt
    RootEncryptedResponseReadBack prepared receipt ->
      preparedResponseViolations prepared receipt
    RootFinalBundlePromotionPending prepared receipt bundle ->
      preparedResponseViolations prepared receipt
        ++ responseFinalViolations receipt bundle
    RootFinalBundlePromoted prepared receipt bundle ->
      preparedResponseViolations prepared receipt
        ++ responseFinalViolations receipt bundle
    RootFinalBundleReadBack prepared receipt bundle ->
      preparedResponseViolations prepared receipt
        ++ responseFinalViolations receipt bundle
    RootPreparedDeletionPending prepared bundle ->
      requirePreparedFinalBinding prepared bundle
    RootPreparedDeleted prepared bundle ->
      requirePreparedFinalBinding prepared bundle
    RootRecoveryCustodyDurable bundle receipt ->
      finalCustodyViolations bundle receipt
    _ -> []

preparedResponseViolations
  :: PreparedInitEnvelope
  -> EncryptedInitResponseReceipt
  -> [RootInitInvariantViolation]
preparedResponseViolations prepared receipt =
  [ RootPreparedResponseBindingDiffers
  | preparedInitBinding prepared /= encryptedResponseBinding receipt
  ]
    ++ [ RootPreparedResponseSchemaDiffers
       | preparedInitSchemaVersion prepared /= encryptedResponseSchemaVersion receipt
       ]
    ++ [ RootPreparedResponseRecoveryFingerprintDiffers
       | preparedInitRecoveryFingerprint prepared
           /= encryptedResponseRecoveryFingerprint receipt
       ]
    ++ [ RootPreparedResponseBurnFingerprintDiffers
       | preparedInitBurnFingerprint prepared /= encryptedResponseBurnFingerprint receipt
       ]

responseFinalViolations
  :: EncryptedInitResponseReceipt -> FinalUnlockBundle -> [RootInitInvariantViolation]
responseFinalViolations receipt bundle =
  [ RootResponseFinalBindingDiffers
  | encryptedResponseBinding receipt /= finalUnlockBundleBinding bundle
  ]
    ++ [ RootResponseFinalSchemaDiffers
       | encryptedResponseSchemaVersion receipt /= finalUnlockBundleSchemaVersion bundle
       ]
    ++ [ RootResponseFinalShareCountDiffers encryptedCount finalCount
       | encryptedCount /= finalCount
       ]
 where
  encryptedCount = fromIntegral (length (encryptedResponseShares receipt))
  finalCount = finalUnlockBundleShareCount bundle

requirePreparedFinalBinding
  :: PreparedInitEnvelope -> FinalUnlockBundle -> [RootInitInvariantViolation]
requirePreparedFinalBinding prepared bundle =
  [ RootResponseFinalBindingDiffers
  | preparedInitBinding prepared /= finalUnlockBundleBinding bundle
  ]
    ++ [ RootResponseFinalSchemaDiffers
       | preparedInitSchemaVersion prepared /= finalUnlockBundleSchemaVersion bundle
       ]

finalCustodyViolations
  :: FinalUnlockBundle -> RecoveryCustodyReceipt -> [RootInitInvariantViolation]
finalCustodyViolations bundle receipt =
  [ RootFinalCustodyBindingDiffers
  | finalUnlockBundleBinding bundle /= recoveryCustodyBinding receipt
  ]
    ++ [ RootFinalCustodyDigestDiffers
       | finalUnlockBundleDigest bundle /= recoveryCustodyFinalBundleDigest receipt
       ]

rootPhaseBinding :: RootInitPhase -> RootInitBinding
rootPhaseBinding phase =
  case phase of
    RootInitPristine proof -> pristineStorageBinding proof
    RootPreparedWritePending prepared -> preparedInitBinding prepared
    RootPreparedWritten prepared -> preparedInitBinding prepared
    RootPreparedReadBack prepared -> preparedInitBinding prepared
    RootInitCallPending prepared -> preparedInitBinding prepared
    RootInitCallInFlight prepared -> preparedInitBinding prepared
    RootEncryptedResponseCapturePending prepared _ -> preparedInitBinding prepared
    RootEncryptedResponseWritten prepared _ -> preparedInitBinding prepared
    RootEncryptedResponseReadBack prepared _ -> preparedInitBinding prepared
    RootFinalBundlePromotionPending prepared _ _ -> preparedInitBinding prepared
    RootFinalBundlePromoted prepared _ _ -> preparedInitBinding prepared
    RootFinalBundleReadBack prepared _ _ -> preparedInitBinding prepared
    RootPreparedDeletionPending prepared _ -> preparedInitBinding prepared
    RootPreparedDeleted prepared _ -> preparedInitBinding prepared
    RootPreparedAbsent bundle -> finalUnlockBundleBinding bundle
    RootRecoveryCustodyAcknowledgementPending bundle -> finalUnlockBundleBinding bundle
    RootRecoveryCustodyDurable bundle _ -> finalUnlockBundleBinding bundle
    RootInitializationAmbiguous ambiguity -> ambiguousInitBinding ambiguity

rootCommittedRank :: RootInitPhase -> Natural
rootCommittedRank phase =
  case phase of
    RootInitPristine _ -> 0
    RootPreparedWritePending _ -> 0
    RootPreparedWritten _ -> 0
    RootPreparedReadBack _ -> 1
    RootInitCallPending _ -> 1
    RootInitCallInFlight _ -> 1
    RootEncryptedResponseCapturePending _ _ -> 1
    RootEncryptedResponseWritten _ _ -> 1
    RootEncryptedResponseReadBack _ _ -> 2
    RootFinalBundlePromotionPending {} -> 2
    RootFinalBundlePromoted {} -> 2
    RootFinalBundleReadBack {} -> 3
    RootPreparedDeletionPending _ _ -> 3
    RootPreparedDeleted _ _ -> 3
    RootPreparedAbsent _ -> 4
    RootRecoveryCustodyAcknowledgementPending _ -> 4
    RootRecoveryCustodyDurable _ _ -> 5
    RootInitializationAmbiguous _ -> 1

rootObservationBinding :: RootInitDurableObservation -> RootInitBinding
rootObservationBinding observation =
  case observation of
    RootObservedPristine proof -> pristineStorageBinding proof
    RootObservedPreparedVaultUninitialized prepared -> preparedInitBinding prepared
    RootObservedPreparedVaultInitializedWithoutResponse prepared -> preparedInitBinding prepared
    RootObservedEncryptedResponse prepared _ -> preparedInitBinding prepared
    RootObservedFinalBundlePreparedPresent prepared _ _ -> preparedInitBinding prepared
    RootObservedFinalBundlePreparedAbsent bundle -> finalUnlockBundleBinding bundle
    RootObservedRecoveryCustody bundle _ -> finalUnlockBundleBinding bundle

rootObservationRank :: RootInitDurableObservation -> Natural
rootObservationRank observation =
  case observation of
    RootObservedPristine _ -> 0
    RootObservedPreparedVaultUninitialized _ -> 1
    RootObservedPreparedVaultInitializedWithoutResponse _ -> 1
    RootObservedEncryptedResponse _ _ -> 2
    RootObservedFinalBundlePreparedPresent {} -> 3
    RootObservedFinalBundlePreparedAbsent _ -> 4
    RootObservedRecoveryCustody _ _ -> 5

rootPhaseFromObservation :: RootInitDurableObservation -> RootInitPhase
rootPhaseFromObservation observation =
  case observation of
    RootObservedPristine proof -> RootInitPristine proof
    RootObservedPreparedVaultUninitialized prepared -> RootPreparedReadBack prepared
    RootObservedPreparedVaultInitializedWithoutResponse prepared ->
      RootInitializationAmbiguous (mkInitAmbiguity prepared)
    RootObservedEncryptedResponse prepared receipt ->
      RootEncryptedResponseReadBack prepared receipt
    RootObservedFinalBundlePreparedPresent prepared receipt bundle ->
      RootFinalBundleReadBack prepared receipt bundle
    RootObservedFinalBundlePreparedAbsent bundle -> RootPreparedAbsent bundle
    RootObservedRecoveryCustody bundle receipt ->
      RootRecoveryCustodyDurable bundle receipt

rootInitPhaseName :: RootInitPhase -> String
rootInitPhaseName phase =
  case phase of
    RootInitPristine _ -> "RootInitPristine"
    RootPreparedWritePending _ -> "RootPreparedWritePending"
    RootPreparedWritten _ -> "RootPreparedWritten"
    RootPreparedReadBack _ -> "RootPreparedReadBack"
    RootInitCallPending _ -> "RootInitCallPending"
    RootInitCallInFlight _ -> "RootInitCallInFlight"
    RootEncryptedResponseCapturePending _ _ -> "RootEncryptedResponseCapturePending"
    RootEncryptedResponseWritten _ _ -> "RootEncryptedResponseWritten"
    RootEncryptedResponseReadBack _ _ -> "RootEncryptedResponseReadBack"
    RootFinalBundlePromotionPending {} -> "RootFinalBundlePromotionPending"
    RootFinalBundlePromoted {} -> "RootFinalBundlePromoted"
    RootFinalBundleReadBack {} -> "RootFinalBundleReadBack"
    RootPreparedDeletionPending _ _ -> "RootPreparedDeletionPending"
    RootPreparedDeleted _ _ -> "RootPreparedDeleted"
    RootPreparedAbsent _ -> "RootPreparedAbsent"
    RootRecoveryCustodyAcknowledgementPending _ ->
      "RootRecoveryCustodyAcknowledgementPending"
    RootRecoveryCustodyDurable _ _ -> "RootRecoveryCustodyDurable"
    RootInitializationAmbiguous _ -> "RootInitializationAmbiguous"

rootInitCommandName :: RootInitCommand -> String
rootInitCommandName command =
  case command of
    PrepareRootInitEnvelope _ -> "PrepareRootInitEnvelope <redacted>"
    RecordPreparedInitWrite -> "RecordPreparedInitWrite"
    ConfirmPreparedInitReadBack _ -> "ConfirmPreparedInitReadBack"
    ArmRootVaultInitCall -> "ArmRootVaultInitCall"
    RecordRootVaultInitCallStarted -> "RecordRootVaultInitCallStarted"
    CaptureEncryptedInitResponse _ -> "CaptureEncryptedInitResponse <redacted>"
    RecordEncryptedInitResponseWrite -> "RecordEncryptedInitResponseWrite"
    ConfirmEncryptedInitResponseReadBack _ ->
      "ConfirmEncryptedInitResponseReadBack"
    PrepareFinalUnlockBundle _ -> "PrepareFinalUnlockBundle <redacted>"
    RecordFinalUnlockBundlePromotion -> "RecordFinalUnlockBundlePromotion"
    ConfirmFinalUnlockBundleReadBack _ -> "ConfirmFinalUnlockBundleReadBack"
    ArmPreparedInitDeletion -> "ArmPreparedInitDeletion"
    RecordPreparedInitDeletion -> "RecordPreparedInitDeletion"
    ConfirmPreparedInitAbsence -> "ConfirmPreparedInitAbsence"
    ArmRecoveryCustodyAcknowledgement -> "ArmRecoveryCustodyAcknowledgement"
    ConfirmRecoveryCustody _ -> "ConfirmRecoveryCustody"
    MarkRootInitAppliedWithoutDurableResponse ->
      "MarkRootInitAppliedWithoutDurableResponse"
    CancelRootInitialization _ -> "CancelRootInitialization <redacted>"
    ResetAmbiguousRootInitialization _ -> "ResetAmbiguousRootInitialization"

rootInitEventName :: RootInitEvent -> String
rootInitEventName event =
  case event of
    RootInitEnvelopePrepared _ -> "RootInitEnvelopePrepared"
    RootPreparedInitWriteRecorded -> "RootPreparedInitWriteRecorded"
    RootPreparedInitReadBackConfirmed _ -> "RootPreparedInitReadBackConfirmed"
    RootVaultInitCallArmed -> "RootVaultInitCallArmed"
    RootVaultInitCallStarted -> "RootVaultInitCallStarted"
    RootEncryptedInitResponseCaptured _ -> "RootEncryptedInitResponseCaptured"
    RootEncryptedInitResponseWriteRecorded -> "RootEncryptedInitResponseWriteRecorded"
    RootEncryptedInitResponseReadBackConfirmed _ ->
      "RootEncryptedInitResponseReadBackConfirmed"
    RootFinalUnlockBundlePrepared _ -> "RootFinalUnlockBundlePrepared"
    RootFinalUnlockBundlePromotionRecorded -> "RootFinalUnlockBundlePromotionRecorded"
    RootFinalUnlockBundleReadBackConfirmed _ ->
      "RootFinalUnlockBundleReadBackConfirmed"
    RootPreparedInitDeletionArmed -> "RootPreparedInitDeletionArmed"
    RootPreparedInitDeletionRecorded -> "RootPreparedInitDeletionRecorded"
    RootPreparedInitAbsenceConfirmed -> "RootPreparedInitAbsenceConfirmed"
    RootRecoveryCustodyAcknowledgementArmed ->
      "RootRecoveryCustodyAcknowledgementArmed"
    RootRecoveryCustodyConfirmed _ -> "RootRecoveryCustodyConfirmed"
    RootInitializationMarkedAmbiguous -> "RootInitializationMarkedAmbiguous"
    RootInitializationCancellationLatched _ ->
      "RootInitializationCancellationLatched"
    RootInitializationResetToPristine _ -> "RootInitializationResetToPristine"

-- Child initialization custody ---------------------------------------------

data ChildCustodyPhase
  = ChildAwaitingEncryptedReceipt !ChildCustodyBinding
  | ChildLocalReceiptWritePending !ChildEncryptedReceipt
  | ChildLocalReceiptWritten !ChildEncryptedReceipt
  | ChildLocalReceiptReadBack !ChildEncryptedReceipt
  | ChildParentGenerationCasPending !ChildEncryptedReceipt
  | ChildParentCustodyReadBack !ChildEncryptedReceipt !ParentCustodyAcknowledgement
  | ChildLocalReceiptDeletionPending !ParentCustodyAcknowledgement
  | ChildLocalReceiptDeleted !ParentCustodyAcknowledgement
  | ChildLocalReceiptAbsent !ParentCustodyAcknowledgement
  | ChildRecoveryCustodyDurable !ParentCustodyAcknowledgement
  deriving stock (Eq)

instance Show ChildCustodyPhase where
  show = childCustodyPhaseName

data ChildCustodyState = ChildCustodyState
  { childCustodyStateBinding :: !ChildCustodyBinding
  , childCustodyStateDisposition :: !CustodyDisposition
  , childCustodyStatePhase :: !ChildCustodyPhase
  }
  deriving stock (Eq)

instance Show ChildCustodyState where
  show state =
    "ChildCustodyState {binding = "
      ++ show (childCustodyStateBinding state)
      ++ ", disposition = "
      ++ show (childCustodyStateDisposition state)
      ++ ", phase = "
      ++ childCustodyPhaseName (childCustodyStatePhase state)
      ++ "}"

data ChildCustodyCommand
  = CaptureChildEncryptedReceipt !ChildEncryptedReceipt
  | RecordChildLocalReceiptWrite
  | ConfirmChildLocalReceiptReadBack !ChildEncryptedReceipt
  | ArmChildParentGenerationCas
  | ConfirmParentCustodyReadBack !ParentCustodyAcknowledgement
  | ArmChildLocalReceiptDeletion
  | RecordChildLocalReceiptDeletion
  | ConfirmChildLocalReceiptAbsence
  | ConfirmChildRecoveryCustodyDurable
  | CancelChildCustody !CancellationReason
  deriving stock (Eq)

instance Show ChildCustodyCommand where
  show command =
    case command of
      CaptureChildEncryptedReceipt _ -> "CaptureChildEncryptedReceipt <redacted>"
      RecordChildLocalReceiptWrite -> "RecordChildLocalReceiptWrite"
      ConfirmChildLocalReceiptReadBack _ -> "ConfirmChildLocalReceiptReadBack"
      ArmChildParentGenerationCas -> "ArmChildParentGenerationCas"
      ConfirmParentCustodyReadBack _ -> "ConfirmParentCustodyReadBack"
      ArmChildLocalReceiptDeletion -> "ArmChildLocalReceiptDeletion"
      RecordChildLocalReceiptDeletion -> "RecordChildLocalReceiptDeletion"
      ConfirmChildLocalReceiptAbsence -> "ConfirmChildLocalReceiptAbsence"
      ConfirmChildRecoveryCustodyDurable -> "ConfirmChildRecoveryCustodyDurable"
      CancelChildCustody _ -> "CancelChildCustody <redacted>"

data ChildCustodyEvent
  = ChildEncryptedReceiptCaptured !ChildEncryptedReceipt
  | ChildLocalReceiptWriteRecorded
  | ChildLocalReceiptReadBackConfirmed !ChildEncryptedReceipt
  | ChildParentGenerationCasArmed
  | ChildParentCustodyReadBackConfirmed !ParentCustodyAcknowledgement
  | ChildLocalReceiptDeletionArmed
  | ChildLocalReceiptDeletionRecorded
  | ChildLocalReceiptAbsenceConfirmed
  | ChildRecoveryCustodyMarkedDurable
  | ChildCustodyCancellationLatched !CancellationReason
  deriving stock (Eq)

instance Show ChildCustodyEvent where
  show event =
    case event of
      ChildEncryptedReceiptCaptured _ -> "ChildEncryptedReceiptCaptured <redacted>"
      ChildLocalReceiptWriteRecorded -> "ChildLocalReceiptWriteRecorded"
      ChildLocalReceiptReadBackConfirmed _ -> "ChildLocalReceiptReadBackConfirmed"
      ChildParentGenerationCasArmed -> "ChildParentGenerationCasArmed"
      ChildParentCustodyReadBackConfirmed _ -> "ChildParentCustodyReadBackConfirmed"
      ChildLocalReceiptDeletionArmed -> "ChildLocalReceiptDeletionArmed"
      ChildLocalReceiptDeletionRecorded -> "ChildLocalReceiptDeletionRecorded"
      ChildLocalReceiptAbsenceConfirmed -> "ChildLocalReceiptAbsenceConfirmed"
      ChildRecoveryCustodyMarkedDurable -> "ChildRecoveryCustodyMarkedDurable"
      ChildCustodyCancellationLatched _ -> "ChildCustodyCancellationLatched"

data ChildCustodyPlan
  = ChildPlanAwaitEncryptedInitResponse !ChildCustodyBinding
  | ChildPlanWriteLocalEncryptedReceipt !ChildEncryptedReceipt
  | ChildPlanReadBackLocalEncryptedReceipt !ChildEncryptedReceipt
  | ChildPlanArmParentGenerationCas !ChildEncryptedReceipt
  | ChildPlanParentGenerationCas !ChildEncryptedReceipt
  | ChildPlanDeleteLocalEncryptedReceipt !ParentCustodyAcknowledgement
  | ChildPlanReadBackLocalReceiptAbsence !ParentCustodyAcknowledgement
  | ChildPlanMarkCustodyDurable !ParentCustodyAcknowledgement
  | ChildPlanCancellationLatched !String
  | ChildPlanCustodyComplete !ParentCustodyAcknowledgement
  deriving stock (Eq)

instance Show ChildCustodyPlan where
  show plan =
    case plan of
      ChildPlanAwaitEncryptedInitResponse _ -> "ChildPlanAwaitEncryptedInitResponse"
      ChildPlanWriteLocalEncryptedReceipt _ ->
        "ChildPlanWriteLocalEncryptedReceipt <redacted>"
      ChildPlanReadBackLocalEncryptedReceipt _ ->
        "ChildPlanReadBackLocalEncryptedReceipt"
      ChildPlanArmParentGenerationCas _ -> "ChildPlanArmParentGenerationCas"
      ChildPlanParentGenerationCas _ -> "ChildPlanParentGenerationCas <redacted>"
      ChildPlanDeleteLocalEncryptedReceipt _ -> "ChildPlanDeleteLocalEncryptedReceipt"
      ChildPlanReadBackLocalReceiptAbsence _ ->
        "ChildPlanReadBackLocalReceiptAbsence"
      ChildPlanMarkCustodyDurable _ -> "ChildPlanMarkCustodyDurable"
      ChildPlanCancellationLatched phase ->
        "ChildPlanCancellationLatched {phase = " ++ phase ++ "}"
      ChildPlanCustodyComplete _ -> "ChildPlanCustodyComplete"

data ChildCustodyDurableObservation
  = ChildObservedNoLocalReceipt !ChildCustodyBinding
  | ChildObservedLocalEncryptedReceipt !ChildEncryptedReceipt
  | ChildObservedParentCustody
      !ChildEncryptedReceipt
      !ParentCustodyAcknowledgement
  | ChildObservedParentCustodyLocalReceiptAbsent !ParentCustodyAcknowledgement
  | ChildObservedRecoveryCustodyDurable !ParentCustodyAcknowledgement
  deriving stock (Eq)

instance Show ChildCustodyDurableObservation where
  show observation =
    case observation of
      ChildObservedNoLocalReceipt _ -> "ChildObservedNoLocalReceipt"
      ChildObservedLocalEncryptedReceipt _ ->
        "ChildObservedLocalEncryptedReceipt <redacted>"
      ChildObservedParentCustody _ _ -> "ChildObservedParentCustody <redacted>"
      ChildObservedParentCustodyLocalReceiptAbsent _ ->
        "ChildObservedParentCustodyLocalReceiptAbsent"
      ChildObservedRecoveryCustodyDurable _ ->
        "ChildObservedRecoveryCustodyDurable"

data ChildCustodyError
  = ChildCustodyPhaseRefusal !String !String
  | ChildCustodyCancellationRefusal !String
  | ChildCustodyBindingMismatch !ChildCustodyBinding !ChildCustodyBinding
  | ChildCustodyLocalReadBackMismatch
  | ChildCustodyParentAcknowledgementMismatch
  | ChildCustodyObservationRegression !Natural !Natural
  | ChildCustodyInvariantFailure ![ChildCustodyInvariantViolation]
  deriving stock (Eq, Show)

data ChildCustodyInvariantViolation
  = ChildPhaseBindingDiffers !ChildCustodyBinding !ChildCustodyBinding
  | ChildParentAcknowledgementBindingDiffers
  | ChildParentAcknowledgementDigestDiffers
  deriving stock (Eq, Show)

newChildCustodyState :: ChildCustodyBinding -> ChildCustodyState
newChildCustodyState binding =
  ChildCustodyState
    { childCustodyStateBinding = binding
    , childCustodyStateDisposition = CustodyRunning
    , childCustodyStatePhase = ChildAwaitingEncryptedReceipt binding
    }

decideChildCustody
  :: ChildCustodyState
  -> ChildCustodyCommand
  -> Either ChildCustodyError ChildCustodyEvent
decideChildCustody state command = do
  let event = childCustodyEventForCommand command
  _ <- evolveChildCustody state event
  pure event

evolveChildCustody
  :: ChildCustodyState
  -> ChildCustodyEvent
  -> Either ChildCustodyError ChildCustodyState
evolveChildCustody state event = do
  requireChildEventAllowedByDisposition state event
  evolved <- evolveChildCustodyPhase state event
  validateChildCustodyState evolved

applyChildCustodyCommand
  :: ChildCustodyState
  -> ChildCustodyCommand
  -> Either ChildCustodyError ChildCustodyState
applyChildCustodyCommand state command = do
  event <- decideChildCustody state command
  evolveChildCustody state event

planChildCustody :: ChildCustodyState -> ChildCustodyPlan
planChildCustody state
  | childCancellationStopsNewDelivery state =
      ChildPlanCancellationLatched (childCustodyPhaseName (childCustodyStatePhase state))
  | otherwise =
      case childCustodyStatePhase state of
        ChildAwaitingEncryptedReceipt binding -> ChildPlanAwaitEncryptedInitResponse binding
        ChildLocalReceiptWritePending receipt ->
          ChildPlanWriteLocalEncryptedReceipt receipt
        ChildLocalReceiptWritten receipt ->
          ChildPlanReadBackLocalEncryptedReceipt receipt
        ChildLocalReceiptReadBack receipt -> ChildPlanArmParentGenerationCas receipt
        ChildParentGenerationCasPending receipt -> ChildPlanParentGenerationCas receipt
        ChildParentCustodyReadBack _ acknowledgement ->
          ChildPlanDeleteLocalEncryptedReceipt acknowledgement
        ChildLocalReceiptDeletionPending acknowledgement ->
          ChildPlanDeleteLocalEncryptedReceipt acknowledgement
        ChildLocalReceiptDeleted acknowledgement ->
          ChildPlanReadBackLocalReceiptAbsence acknowledgement
        ChildLocalReceiptAbsent acknowledgement ->
          ChildPlanMarkCustodyDurable acknowledgement
        ChildRecoveryCustodyDurable acknowledgement ->
          ChildPlanCustodyComplete acknowledgement

resumeChildCustodyFromObservation
  :: ChildCustodyDurableObservation
  -> Either ChildCustodyError ChildCustodyState
resumeChildCustodyFromObservation observation =
  validateChildCustodyState
    ChildCustodyState
      { childCustodyStateBinding = childObservationBinding observation
      , childCustodyStateDisposition = CustodyRunning
      , childCustodyStatePhase = childPhaseFromObservation observation
      }

restartChildCustody
  :: ChildCustodyState
  -> ChildCustodyDurableObservation
  -> Either ChildCustodyError ChildCustodyState
restartChildCustody current observation = do
  requireSameChildBinding
    (childCustodyStateBinding current)
    (childObservationBinding observation)
  let committedRank = childCommittedRank (childCustodyStatePhase current)
      observedRank = childObservationRank observation
  if observedRank < committedRank
    then Left (ChildCustodyObservationRegression committedRank observedRank)
    else resumeChildCustodyFromObservation observation

childCustodyInvariantViolations
  :: ChildCustodyState -> [ChildCustodyInvariantViolation]
childCustodyInvariantViolations state =
  [ ChildPhaseBindingDiffers expected actual
  | expected /= actual
  ]
    ++ childPhaseRelationshipViolations (childCustodyStatePhase state)
 where
  expected = childCustodyStateBinding state
  actual = childPhaseBinding (childCustodyStatePhase state)

childCustodyIsComplete :: ChildCustodyState -> Bool
childCustodyIsComplete state =
  case childCustodyStatePhase state of
    ChildRecoveryCustodyDurable _ -> True
    _ -> False

childCustodyEventForCommand :: ChildCustodyCommand -> ChildCustodyEvent
childCustodyEventForCommand command =
  case command of
    CaptureChildEncryptedReceipt receipt -> ChildEncryptedReceiptCaptured receipt
    RecordChildLocalReceiptWrite -> ChildLocalReceiptWriteRecorded
    ConfirmChildLocalReceiptReadBack receipt ->
      ChildLocalReceiptReadBackConfirmed receipt
    ArmChildParentGenerationCas -> ChildParentGenerationCasArmed
    ConfirmParentCustodyReadBack acknowledgement ->
      ChildParentCustodyReadBackConfirmed acknowledgement
    ArmChildLocalReceiptDeletion -> ChildLocalReceiptDeletionArmed
    RecordChildLocalReceiptDeletion -> ChildLocalReceiptDeletionRecorded
    ConfirmChildLocalReceiptAbsence -> ChildLocalReceiptAbsenceConfirmed
    ConfirmChildRecoveryCustodyDurable -> ChildRecoveryCustodyMarkedDurable
    CancelChildCustody reason -> ChildCustodyCancellationLatched reason

evolveChildCustodyPhase
  :: ChildCustodyState
  -> ChildCustodyEvent
  -> Either ChildCustodyError ChildCustodyState
evolveChildCustodyPhase state event =
  case (childCustodyStatePhase state, event) of
    (ChildAwaitingEncryptedReceipt binding, ChildEncryptedReceiptCaptured receipt) -> do
      requireSameChildBinding binding (childEncryptedReceiptBinding receipt)
      childWithPhase state (ChildLocalReceiptWritePending receipt)
    (ChildLocalReceiptWritePending receipt, ChildLocalReceiptWriteRecorded) ->
      childWithPhase state (ChildLocalReceiptWritten receipt)
    (ChildLocalReceiptWritten receipt, ChildLocalReceiptReadBackConfirmed observed)
      | receipt == observed -> childWithPhase state (ChildLocalReceiptReadBack observed)
      | otherwise -> Left ChildCustodyLocalReadBackMismatch
    (ChildLocalReceiptReadBack receipt, ChildParentGenerationCasArmed) ->
      childWithPhase state (ChildParentGenerationCasPending receipt)
    (ChildParentGenerationCasPending receipt, ChildParentCustodyReadBackConfirmed acknowledgement) -> do
      requireParentAcknowledgement receipt acknowledgement
      childWithPhase state (ChildParentCustodyReadBack receipt acknowledgement)
    (ChildParentCustodyReadBack _ acknowledgement, ChildLocalReceiptDeletionArmed) ->
      childWithPhase state (ChildLocalReceiptDeletionPending acknowledgement)
    (ChildLocalReceiptDeletionPending acknowledgement, ChildLocalReceiptDeletionRecorded) ->
      childWithPhase state (ChildLocalReceiptDeleted acknowledgement)
    (ChildLocalReceiptDeleted acknowledgement, ChildLocalReceiptAbsenceConfirmed) ->
      childWithPhase state (ChildLocalReceiptAbsent acknowledgement)
    (ChildLocalReceiptAbsent acknowledgement, ChildRecoveryCustodyMarkedDurable) ->
      childWithPhase state (ChildRecoveryCustodyDurable acknowledgement)
    (_, ChildCustodyCancellationLatched reason) ->
      Right state {childCustodyStateDisposition = CustodyCancellationRequested reason}
    (phase, _) ->
      Left
        ( ChildCustodyPhaseRefusal
            (childCustodyPhaseName phase)
            (show event)
        )

childWithPhase
  :: ChildCustodyState
  -> ChildCustodyPhase
  -> Either ChildCustodyError ChildCustodyState
childWithPhase state phase = Right state {childCustodyStatePhase = phase}

requireChildEventAllowedByDisposition
  :: ChildCustodyState -> ChildCustodyEvent -> Either ChildCustodyError ()
requireChildEventAllowedByDisposition state event =
  case childCustodyStateDisposition state of
    CustodyRunning -> Right ()
    CustodyCancellationRequested _
      | childEventIsSafetyTail event -> Right ()
      | otherwise -> Left (ChildCustodyCancellationRefusal (show event))

childEventIsSafetyTail :: ChildCustodyEvent -> Bool
childEventIsSafetyTail event =
  case event of
    ChildEncryptedReceiptCaptured _ -> True
    ChildLocalReceiptWriteRecorded -> True
    ChildLocalReceiptReadBackConfirmed _ -> True
    ChildParentCustodyReadBackConfirmed _ -> True
    ChildLocalReceiptDeletionArmed -> True
    ChildLocalReceiptDeletionRecorded -> True
    ChildLocalReceiptAbsenceConfirmed -> True
    ChildRecoveryCustodyMarkedDurable -> True
    ChildCustodyCancellationLatched _ -> True
    ChildParentGenerationCasArmed -> False

childCancellationStopsNewDelivery :: ChildCustodyState -> Bool
childCancellationStopsNewDelivery state =
  case childCustodyStateDisposition state of
    CustodyRunning -> False
    CustodyCancellationRequested _ ->
      case childCustodyStatePhase state of
        ChildAwaitingEncryptedReceipt _ -> True
        ChildLocalReceiptReadBack _ -> True
        _ -> False

validateChildCustodyState
  :: ChildCustodyState -> Either ChildCustodyError ChildCustodyState
validateChildCustodyState state =
  case childCustodyInvariantViolations state of
    [] -> Right state
    violations -> Left (ChildCustodyInvariantFailure violations)

requireSameChildBinding
  :: ChildCustodyBinding -> ChildCustodyBinding -> Either ChildCustodyError ()
requireSameChildBinding expected actual
  | expected == actual = Right ()
  | otherwise = Left (ChildCustodyBindingMismatch expected actual)

requireParentAcknowledgement
  :: ChildEncryptedReceipt
  -> ParentCustodyAcknowledgement
  -> Either ChildCustodyError ()
requireParentAcknowledgement receipt acknowledgement
  | parentCustodyAcknowledgedBinding acknowledgement
      /= childEncryptedReceiptBinding receipt =
      Left ChildCustodyParentAcknowledgementMismatch
  | parentCustodyAcknowledgedReceiptDigest acknowledgement
      /= childEncryptedReceiptDigest receipt =
      Left ChildCustodyParentAcknowledgementMismatch
  | otherwise = Right ()

childPhaseRelationshipViolations
  :: ChildCustodyPhase -> [ChildCustodyInvariantViolation]
childPhaseRelationshipViolations phase =
  case phase of
    ChildParentCustodyReadBack receipt acknowledgement ->
      parentAcknowledgementViolations receipt acknowledgement
    _ -> []

parentAcknowledgementViolations
  :: ChildEncryptedReceipt
  -> ParentCustodyAcknowledgement
  -> [ChildCustodyInvariantViolation]
parentAcknowledgementViolations receipt acknowledgement =
  [ ChildParentAcknowledgementBindingDiffers
  | parentCustodyAcknowledgedBinding acknowledgement
      /= childEncryptedReceiptBinding receipt
  ]
    ++ [ ChildParentAcknowledgementDigestDiffers
       | parentCustodyAcknowledgedReceiptDigest acknowledgement
           /= childEncryptedReceiptDigest receipt
       ]

childPhaseBinding :: ChildCustodyPhase -> ChildCustodyBinding
childPhaseBinding phase =
  case phase of
    ChildAwaitingEncryptedReceipt binding -> binding
    ChildLocalReceiptWritePending receipt -> childEncryptedReceiptBinding receipt
    ChildLocalReceiptWritten receipt -> childEncryptedReceiptBinding receipt
    ChildLocalReceiptReadBack receipt -> childEncryptedReceiptBinding receipt
    ChildParentGenerationCasPending receipt -> childEncryptedReceiptBinding receipt
    ChildParentCustodyReadBack receipt _ -> childEncryptedReceiptBinding receipt
    ChildLocalReceiptDeletionPending acknowledgement ->
      parentCustodyAcknowledgedBinding acknowledgement
    ChildLocalReceiptDeleted acknowledgement ->
      parentCustodyAcknowledgedBinding acknowledgement
    ChildLocalReceiptAbsent acknowledgement ->
      parentCustodyAcknowledgedBinding acknowledgement
    ChildRecoveryCustodyDurable acknowledgement ->
      parentCustodyAcknowledgedBinding acknowledgement

childCommittedRank :: ChildCustodyPhase -> Natural
childCommittedRank phase =
  case phase of
    ChildAwaitingEncryptedReceipt _ -> 0
    ChildLocalReceiptWritePending _ -> 0
    ChildLocalReceiptWritten _ -> 0
    ChildLocalReceiptReadBack _ -> 1
    ChildParentGenerationCasPending _ -> 1
    ChildParentCustodyReadBack _ _ -> 2
    ChildLocalReceiptDeletionPending _ -> 2
    ChildLocalReceiptDeleted _ -> 2
    ChildLocalReceiptAbsent _ -> 3
    ChildRecoveryCustodyDurable _ -> 4

childObservationBinding
  :: ChildCustodyDurableObservation -> ChildCustodyBinding
childObservationBinding observation =
  case observation of
    ChildObservedNoLocalReceipt binding -> binding
    ChildObservedLocalEncryptedReceipt receipt -> childEncryptedReceiptBinding receipt
    ChildObservedParentCustody receipt _ -> childEncryptedReceiptBinding receipt
    ChildObservedParentCustodyLocalReceiptAbsent acknowledgement ->
      parentCustodyAcknowledgedBinding acknowledgement
    ChildObservedRecoveryCustodyDurable acknowledgement ->
      parentCustodyAcknowledgedBinding acknowledgement

childObservationRank :: ChildCustodyDurableObservation -> Natural
childObservationRank observation =
  case observation of
    ChildObservedNoLocalReceipt _ -> 0
    ChildObservedLocalEncryptedReceipt _ -> 1
    ChildObservedParentCustody _ _ -> 2
    ChildObservedParentCustodyLocalReceiptAbsent _ -> 3
    ChildObservedRecoveryCustodyDurable _ -> 4

childPhaseFromObservation :: ChildCustodyDurableObservation -> ChildCustodyPhase
childPhaseFromObservation observation =
  case observation of
    ChildObservedNoLocalReceipt binding -> ChildAwaitingEncryptedReceipt binding
    ChildObservedLocalEncryptedReceipt receipt -> ChildLocalReceiptReadBack receipt
    ChildObservedParentCustody receipt acknowledgement ->
      ChildParentCustodyReadBack receipt acknowledgement
    ChildObservedParentCustodyLocalReceiptAbsent acknowledgement ->
      ChildLocalReceiptAbsent acknowledgement
    ChildObservedRecoveryCustodyDurable acknowledgement ->
      ChildRecoveryCustodyDurable acknowledgement

childCustodyPhaseName :: ChildCustodyPhase -> String
childCustodyPhaseName phase =
  case phase of
    ChildAwaitingEncryptedReceipt _ -> "ChildAwaitingEncryptedReceipt"
    ChildLocalReceiptWritePending _ -> "ChildLocalReceiptWritePending"
    ChildLocalReceiptWritten _ -> "ChildLocalReceiptWritten"
    ChildLocalReceiptReadBack _ -> "ChildLocalReceiptReadBack"
    ChildParentGenerationCasPending _ -> "ChildParentGenerationCasPending"
    ChildParentCustodyReadBack _ _ -> "ChildParentCustodyReadBack"
    ChildLocalReceiptDeletionPending _ -> "ChildLocalReceiptDeletionPending"
    ChildLocalReceiptDeleted _ -> "ChildLocalReceiptDeleted"
    ChildLocalReceiptAbsent _ -> "ChildLocalReceiptAbsent"
    ChildRecoveryCustodyDurable _ -> "ChildRecoveryCustodyDurable"

-- One-time child recovery delivery -----------------------------------------

data ChildRecoveryPhase
  = ChildRecoveryAvailable !ChildCustodyBinding
  | ChildRecoveryDeliveryPrepared !ChildRecoveryDelivery
  | ChildRecoveryDeliveryConsumeArmed !ChildRecoveryDelivery
  | ChildRecoveryDeliveryConsumeInFlight !ChildRecoveryDelivery
  | ChildRecoveryDeliveryConsumed !ChildRecoveryDelivery
  | ChildRecoveryCancelIncompleteGenerateRoot !ChildRecoveryDelivery
  | ChildRecoveryInventoryStaleAccessors !ChildRecoveryDelivery
  | ChildRecoveryRevokeStaleAccessors
      !ChildRecoveryDelivery
      !RootAccessorInventory
      ![RootPolicyAccessor]
  | ChildRecoveryStableAbsencePending
      !ChildRecoveryDelivery
      !RootAccessorInventory
  | ChildRecoveryGenerateRootPending
      !ChildRecoveryDelivery
      !AccessorAbsenceAttestation
  | ChildRecoveryGenerateRootInFlight
      !ChildRecoveryDelivery
      !AccessorAbsenceAttestation
  | ChildRecoveryRootAccessorJournalPending
      !ChildRecoveryDelivery
      !RootPolicyAccessor
  | ChildRecoveryRootAccessorJournaled !ChildRecoveryDelivery !RootPolicyAccessor
  | ChildRecoveryRepairMutationPending
      !ChildRecoveryDelivery
      !RootPolicyAccessor
  | ChildRecoveryRepairApplied
      !ChildRecoveryDelivery
      !RootPolicyAccessor
  | ChildRecoveryRepairReadBack
      !ChildRecoveryDelivery
      !RootPolicyAccessor
      !ChildRecoveryRepairReceipt
  | ChildRecoveryRootRevocationPending
      !ChildRecoveryDelivery
      !RootPolicyAccessor
      !(Maybe ChildRecoveryRepairReceipt)
  | ChildRecoveryRootRevoked
      !ChildRecoveryDelivery
      !RootPolicyAccessor
      !(Maybe ChildRecoveryRepairReceipt)
  | ChildRecoveryRootAbsencePending
      !ChildRecoveryDelivery
      !RootPolicyAccessor
      !(Maybe ChildRecoveryRepairReceipt)
  | ChildRecoveryDeliveryRevoked
      !ChildRecoveryDelivery
      !RootPolicyAccessor
      !ChildRecoveryRepairReceipt
      !AccessorAbsenceAttestation
  deriving stock (Eq)

instance Show ChildRecoveryPhase where
  show phase =
    case phase of
      ChildRecoveryAvailable _ -> "ChildRecoveryAvailable"
      ChildRecoveryDeliveryPrepared _ -> "ChildRecoveryDeliveryPrepared <redacted>"
      ChildRecoveryDeliveryConsumeArmed _ ->
        "ChildRecoveryDeliveryConsumeArmed <redacted>"
      ChildRecoveryDeliveryConsumeInFlight _ ->
        "ChildRecoveryDeliveryConsumeInFlight <redacted>"
      ChildRecoveryDeliveryConsumed _ -> "ChildRecoveryDeliveryConsumed <redacted>"
      ChildRecoveryCancelIncompleteGenerateRoot _ ->
        "ChildRecoveryCancelIncompleteGenerateRoot <redacted>"
      ChildRecoveryInventoryStaleAccessors _ ->
        "ChildRecoveryInventoryStaleAccessors <redacted>"
      ChildRecoveryRevokeStaleAccessors {} ->
        "ChildRecoveryRevokeStaleAccessors <redacted>"
      ChildRecoveryStableAbsencePending {} ->
        "ChildRecoveryStableAbsencePending <redacted>"
      ChildRecoveryGenerateRootPending {} ->
        "ChildRecoveryGenerateRootPending <redacted>"
      ChildRecoveryGenerateRootInFlight {} ->
        "ChildRecoveryGenerateRootInFlight <redacted>"
      ChildRecoveryRootAccessorJournalPending {} ->
        "ChildRecoveryRootAccessorJournalPending <redacted>"
      ChildRecoveryRootAccessorJournaled _ _ ->
        "ChildRecoveryRootAccessorJournaled <redacted>"
      ChildRecoveryRepairMutationPending {} ->
        "ChildRecoveryRepairMutationPending <redacted>"
      ChildRecoveryRepairApplied {} ->
        "ChildRecoveryRepairApplied <redacted>"
      ChildRecoveryRepairReadBack {} ->
        "ChildRecoveryRepairReadBack <redacted>"
      ChildRecoveryRootRevocationPending {} ->
        "ChildRecoveryRootRevocationPending <redacted>"
      ChildRecoveryRootRevoked {} ->
        "ChildRecoveryRootRevoked <redacted>"
      ChildRecoveryRootAbsencePending {} ->
        "ChildRecoveryRootAbsencePending <redacted>"
      ChildRecoveryDeliveryRevoked {} ->
        "ChildRecoveryDeliveryRevoked <redacted>"

data ChildRecoveryState = ChildRecoveryState
  { childRecoveryStateBinding :: !ChildCustodyBinding
  , childRecoveryStateDisposition :: !CustodyDisposition
  , childRecoveryStatePhase :: !ChildRecoveryPhase
  }
  deriving stock (Eq)

instance Show ChildRecoveryState where
  show state =
    "ChildRecoveryState {binding = "
      ++ show (childRecoveryStateBinding state)
      ++ ", disposition = "
      ++ show (childRecoveryStateDisposition state)
      ++ ", phase = "
      ++ show (childRecoveryStatePhase state)
      ++ "}"

data ChildRecoveryCommand
  = PrepareChildRecoveryDelivery !ChildRecoveryDelivery
  | ArmChildRecoveryDeliveryConsume
  | RecordChildRecoveryDeliveryConsumeStarted
  | ConfirmChildRecoveryDeliveryConsumed !ChildRecoveryConsumptionObservation
  | ArmChildRecoveryOrphanCleanup
  | ConfirmChildRecoveryIncompleteGenerateRootCancelled
  | ConfirmChildRecoveryRootAccessorInventory !RootAccessorInventory
  | ConfirmChildRecoveryStaleRootAccessorRevoked !RootPolicyAccessor
  | ConfirmChildRecoveryStableRootAccessorAbsence !AccessorAbsenceAttestation
  | RecordChildRecoveryRootGenerationStarted
  | CaptureChildRecoveryRootAccessor !RootPolicyAccessor
  | ConfirmChildRecoveryRootAccessorJournaled !RootPolicyAccessor
  | ArmChildRecoveryRepair
  | RecordChildRecoveryRepairApplied
  | ConfirmChildRecoveryRepairReadBack !ChildRecoveryRepairReceipt
  | ArmChildRecoveryRootRevocation
  | ConfirmChildRecoveryRootRevoked
  | ArmChildRecoveryRootAccessorAbsenceCheck
  | ConfirmChildRecoveryRootAccessorAbsent !AccessorAbsenceAttestation
  | CancelChildRecovery !CancellationReason
  deriving stock (Eq)

instance Show ChildRecoveryCommand where
  show command =
    case command of
      PrepareChildRecoveryDelivery _ -> "PrepareChildRecoveryDelivery <redacted>"
      ArmChildRecoveryDeliveryConsume -> "ArmChildRecoveryDeliveryConsume"
      RecordChildRecoveryDeliveryConsumeStarted ->
        "RecordChildRecoveryDeliveryConsumeStarted"
      ConfirmChildRecoveryDeliveryConsumed _ ->
        "ConfirmChildRecoveryDeliveryConsumed"
      ArmChildRecoveryOrphanCleanup -> "ArmChildRecoveryOrphanCleanup"
      ConfirmChildRecoveryIncompleteGenerateRootCancelled ->
        "ConfirmChildRecoveryIncompleteGenerateRootCancelled"
      ConfirmChildRecoveryRootAccessorInventory _ ->
        "ConfirmChildRecoveryRootAccessorInventory"
      ConfirmChildRecoveryStaleRootAccessorRevoked _ ->
        "ConfirmChildRecoveryStaleRootAccessorRevoked"
      ConfirmChildRecoveryStableRootAccessorAbsence _ ->
        "ConfirmChildRecoveryStableRootAccessorAbsence"
      RecordChildRecoveryRootGenerationStarted ->
        "RecordChildRecoveryRootGenerationStarted"
      CaptureChildRecoveryRootAccessor _ -> "CaptureChildRecoveryRootAccessor"
      ConfirmChildRecoveryRootAccessorJournaled _ ->
        "ConfirmChildRecoveryRootAccessorJournaled"
      ArmChildRecoveryRepair -> "ArmChildRecoveryRepair"
      RecordChildRecoveryRepairApplied -> "RecordChildRecoveryRepairApplied"
      ConfirmChildRecoveryRepairReadBack _ ->
        "ConfirmChildRecoveryRepairReadBack"
      ArmChildRecoveryRootRevocation -> "ArmChildRecoveryRootRevocation"
      ConfirmChildRecoveryRootRevoked -> "ConfirmChildRecoveryRootRevoked"
      ArmChildRecoveryRootAccessorAbsenceCheck ->
        "ArmChildRecoveryRootAccessorAbsenceCheck"
      ConfirmChildRecoveryRootAccessorAbsent _ ->
        "ConfirmChildRecoveryRootAccessorAbsent"
      CancelChildRecovery _ -> "CancelChildRecovery <redacted>"

data ChildRecoveryEvent
  = ChildRecoveryDeliveryWasPrepared !ChildRecoveryDelivery
  | ChildRecoveryDeliveryConsumeWasArmed
  | ChildRecoveryDeliveryConsumeWasStarted
  | ChildRecoveryDeliveryConsumptionWasConfirmed
      !ChildRecoveryConsumptionObservation
  | ChildRecoveryOrphanCleanupArmed
  | ChildRecoveryIncompleteGenerateRootCancelled
  | ChildRecoveryRootAccessorInventoryConfirmed !RootAccessorInventory
  | ChildRecoveryStaleRootAccessorRevoked !RootPolicyAccessor
  | ChildRecoveryStableRootAccessorAbsenceConfirmed !AccessorAbsenceAttestation
  | ChildRecoveryRootGenerationStarted
  | ChildRecoveryRootAccessorCaptured !RootPolicyAccessor
  | ChildRecoveryRootAccessorWasJournaled !RootPolicyAccessor
  | ChildRecoveryRepairArmed
  | ChildRecoveryRepairWasApplied
  | ChildRecoveryRepairReadBackConfirmed !ChildRecoveryRepairReceipt
  | ChildRecoveryRootRevocationArmed
  | ChildRecoveryRootWasRevoked
  | ChildRecoveryRootAccessorAbsenceCheckArmed
  | ChildRecoveryRootAccessorAbsenceWasConfirmed !AccessorAbsenceAttestation
  | ChildRecoveryDeliveryWasResumed
  | ChildRecoveryCancellationLatched !CancellationReason
  deriving stock (Eq)

instance Show ChildRecoveryEvent where
  show event =
    case event of
      ChildRecoveryDeliveryWasPrepared _ ->
        "ChildRecoveryDeliveryWasPrepared <redacted>"
      ChildRecoveryDeliveryConsumeWasArmed ->
        "ChildRecoveryDeliveryConsumeWasArmed"
      ChildRecoveryDeliveryConsumeWasStarted ->
        "ChildRecoveryDeliveryConsumeWasStarted"
      ChildRecoveryDeliveryConsumptionWasConfirmed _ ->
        "ChildRecoveryDeliveryConsumptionWasConfirmed"
      ChildRecoveryOrphanCleanupArmed -> "ChildRecoveryOrphanCleanupArmed"
      ChildRecoveryIncompleteGenerateRootCancelled ->
        "ChildRecoveryIncompleteGenerateRootCancelled"
      ChildRecoveryRootAccessorInventoryConfirmed _ ->
        "ChildRecoveryRootAccessorInventoryConfirmed"
      ChildRecoveryStaleRootAccessorRevoked _ ->
        "ChildRecoveryStaleRootAccessorRevoked"
      ChildRecoveryStableRootAccessorAbsenceConfirmed _ ->
        "ChildRecoveryStableRootAccessorAbsenceConfirmed"
      ChildRecoveryRootGenerationStarted -> "ChildRecoveryRootGenerationStarted"
      ChildRecoveryRootAccessorCaptured _ ->
        "ChildRecoveryRootAccessorCaptured"
      ChildRecoveryRootAccessorWasJournaled _ ->
        "ChildRecoveryRootAccessorWasJournaled"
      ChildRecoveryRepairArmed -> "ChildRecoveryRepairArmed"
      ChildRecoveryRepairWasApplied -> "ChildRecoveryRepairWasApplied"
      ChildRecoveryRepairReadBackConfirmed _ ->
        "ChildRecoveryRepairReadBackConfirmed"
      ChildRecoveryRootRevocationArmed -> "ChildRecoveryRootRevocationArmed"
      ChildRecoveryRootWasRevoked -> "ChildRecoveryRootWasRevoked"
      ChildRecoveryRootAccessorAbsenceCheckArmed ->
        "ChildRecoveryRootAccessorAbsenceCheckArmed"
      ChildRecoveryRootAccessorAbsenceWasConfirmed _ ->
        "ChildRecoveryRootAccessorAbsenceWasConfirmed"
      ChildRecoveryDeliveryWasResumed -> "ChildRecoveryDeliveryWasResumed"
      ChildRecoveryCancellationLatched _ -> "ChildRecoveryCancellationLatched"

data ChildRecoveryPlan
  = ChildRecoveryPlanAwaitDelivery !ChildCustodyBinding
  | ChildRecoveryPlanArmDeliveryConsume !ChildRecoveryDelivery
  | ChildRecoveryPlanStartDeliveryConsume !ChildRecoveryDelivery
  | ChildRecoveryPlanReconcileDeliveryConsume !ChildRecoveryDelivery
  | ChildRecoveryPlanArmOrphanCleanup !ChildRecoveryDelivery
  | ChildRecoveryPlanCancelIncompleteGenerateRoot !ChildRecoveryDelivery
  | ChildRecoveryPlanInventoryStaleRootAccessors !ChildRecoveryDelivery
  | ChildRecoveryPlanRevokeStaleRootAccessor
      !ChildRecoveryDelivery
      !RootPolicyAccessor
  | ChildRecoveryPlanProveStableRootAccessorAbsence
      !ChildRecoveryDelivery
      !RootAccessorInventory
  | ChildRecoveryPlanGenerateShortLivedRoot !ChildRecoveryDelivery
  | ChildRecoveryPlanAwaitGeneratedRootAccessor !ChildRecoveryDelivery
  | ChildRecoveryPlanJournalRootAccessor
      !ChildRecoveryDelivery
      !RootPolicyAccessor
  | ChildRecoveryPlanArmRepair !ChildRecoveryDelivery !RootPolicyAccessor
  | ChildRecoveryPlanApplyRepair !ChildRecoveryDelivery !RootPolicyAccessor
  | ChildRecoveryPlanReadBackRepair !ChildRecoveryDelivery !RootPolicyAccessor
  | ChildRecoveryPlanArmRootRevocation
      !ChildRecoveryDelivery
      !RootPolicyAccessor
  | ChildRecoveryPlanRevokeRootAccessor
      !ChildRecoveryDelivery
      !RootPolicyAccessor
  | ChildRecoveryPlanArmRootAccessorAbsenceCheck
      !ChildRecoveryDelivery
      !RootPolicyAccessor
  | ChildRecoveryPlanProveRootAccessorAbsent
      !ChildRecoveryDelivery
      !RootPolicyAccessor
  | ChildRecoveryPlanCancellationLatched !String
  | ChildRecoveryPlanComplete
      !ChildRecoveryDelivery
      !ChildRecoveryRepairReceipt
      !AccessorAbsenceAttestation
  deriving stock (Eq)

instance Show ChildRecoveryPlan where
  show plan =
    case plan of
      ChildRecoveryPlanAwaitDelivery _ -> "ChildRecoveryPlanAwaitDelivery"
      ChildRecoveryPlanArmDeliveryConsume _ ->
        "ChildRecoveryPlanArmDeliveryConsume <redacted>"
      ChildRecoveryPlanStartDeliveryConsume _ ->
        "ChildRecoveryPlanStartDeliveryConsume <redacted>"
      ChildRecoveryPlanReconcileDeliveryConsume _ ->
        "ChildRecoveryPlanReconcileDeliveryConsume <redacted>"
      ChildRecoveryPlanArmOrphanCleanup _ ->
        "ChildRecoveryPlanArmOrphanCleanup"
      ChildRecoveryPlanCancelIncompleteGenerateRoot _ ->
        "ChildRecoveryPlanCancelIncompleteGenerateRoot"
      ChildRecoveryPlanInventoryStaleRootAccessors _ ->
        "ChildRecoveryPlanInventoryStaleRootAccessors"
      ChildRecoveryPlanRevokeStaleRootAccessor _ _ ->
        "ChildRecoveryPlanRevokeStaleRootAccessor"
      ChildRecoveryPlanProveStableRootAccessorAbsence _ _ ->
        "ChildRecoveryPlanProveStableRootAccessorAbsence"
      ChildRecoveryPlanGenerateShortLivedRoot _ ->
        "ChildRecoveryPlanGenerateShortLivedRoot"
      ChildRecoveryPlanAwaitGeneratedRootAccessor _ ->
        "ChildRecoveryPlanAwaitGeneratedRootAccessor"
      ChildRecoveryPlanJournalRootAccessor _ _ ->
        "ChildRecoveryPlanJournalRootAccessor"
      ChildRecoveryPlanArmRepair _ _ -> "ChildRecoveryPlanArmRepair"
      ChildRecoveryPlanApplyRepair _ _ -> "ChildRecoveryPlanApplyRepair"
      ChildRecoveryPlanReadBackRepair _ _ -> "ChildRecoveryPlanReadBackRepair"
      ChildRecoveryPlanArmRootRevocation _ _ ->
        "ChildRecoveryPlanArmRootRevocation"
      ChildRecoveryPlanRevokeRootAccessor _ _ ->
        "ChildRecoveryPlanRevokeRootAccessor"
      ChildRecoveryPlanArmRootAccessorAbsenceCheck _ _ ->
        "ChildRecoveryPlanArmRootAccessorAbsenceCheck"
      ChildRecoveryPlanProveRootAccessorAbsent _ _ ->
        "ChildRecoveryPlanProveRootAccessorAbsent"
      ChildRecoveryPlanCancellationLatched phase ->
        "ChildRecoveryPlanCancellationLatched {phase = " ++ phase ++ "}"
      ChildRecoveryPlanComplete {} -> "ChildRecoveryPlanComplete"

data ChildRecoveryError
  = ChildRecoveryPhaseRefusal !String !String
  | ChildRecoveryCancellationRefusal !String
  | ChildRecoveryChildConflict !ChildId !ChildId
  | ChildRecoveryGenerationConflict !CustodyGeneration !CustodyGeneration
  | ChildRecoveryStorageGenerationConflict
      !VaultStorageGeneration
      !VaultStorageGeneration
  | ChildRecoveryTransactionConflict
      !BootstrapTransactionId
      !BootstrapTransactionId
  | ChildRecoveryNonceConflict !DeliveryNonce !DeliveryNonce
  | ChildRecoveryAttestationConflict !ChildAttestation !ChildAttestation
  | ChildRecoveryPayloadConflict !ArtifactDigest !ArtifactDigest
  | ChildRecoveryConsumptionObservationMismatch
  | ChildRecoveryAccessorInventoryMismatch
  | ChildRecoveryStaleAccessorOrderMismatch
  | ChildRecoveryStableAccessorAbsenceMismatch
  | ChildRecoveryAccessorJournalMismatch
  | ChildRecoveryRepairReadBackMismatch
  | ChildRecoveryAccessorAbsenceMismatch
  | ChildRecoveryCancellationNotRequested
  | ChildRecoveryInvariantFailure ![ChildRecoveryInvariantViolation]
  deriving stock (Eq, Show)

data ChildRecoveryInvariantViolation
  = ChildRecoveryPhaseBindingDiffers
      !ChildCustodyBinding
      !ChildCustodyBinding
  | ChildRecoveryInventoryGenerationDiffers
      !VaultStorageGeneration
      !VaultStorageGeneration
  | ChildRecoveryInventoryNotCanonical
  | ChildRecoveryRemainingAccessorNotInventoried !RootPolicyAccessor
  | ChildRecoveryRepairReceiptDiffers
  | ChildRecoveryAccessorAbsenceDiffers !RootPolicyAccessor
  deriving stock (Eq, Show)

newChildRecoveryState :: ChildCustodyBinding -> ChildRecoveryState
newChildRecoveryState binding =
  ChildRecoveryState
    { childRecoveryStateBinding = binding
    , childRecoveryStateDisposition = CustodyRunning
    , childRecoveryStatePhase = ChildRecoveryAvailable binding
    }

decideChildRecovery
  :: ChildRecoveryState
  -> ChildRecoveryCommand
  -> Either ChildRecoveryError ChildRecoveryEvent
decideChildRecovery state command = do
  event <- childRecoveryEventForCommand state command
  _ <- evolveChildRecovery state event
  pure event

evolveChildRecovery
  :: ChildRecoveryState
  -> ChildRecoveryEvent
  -> Either ChildRecoveryError ChildRecoveryState
evolveChildRecovery state event = do
  requireChildRecoveryEventAllowed state event
  evolved <- case (childRecoveryStatePhase state, event) of
    (ChildRecoveryAvailable binding, ChildRecoveryDeliveryWasPrepared delivery) -> do
      requireDeliveryBinding binding delivery
      Right state {childRecoveryStatePhase = ChildRecoveryDeliveryPrepared delivery}
    (ChildRecoveryDeliveryPrepared delivery, ChildRecoveryDeliveryConsumeWasArmed) ->
      Right
        state
          { childRecoveryStatePhase =
              ChildRecoveryDeliveryConsumeArmed delivery
          }
    ( ChildRecoveryDeliveryConsumeArmed delivery
      , ChildRecoveryDeliveryConsumeWasStarted
      ) ->
        Right
          state
            { childRecoveryStatePhase =
                ChildRecoveryDeliveryConsumeInFlight delivery
            }
    ( ChildRecoveryDeliveryConsumeInFlight delivery
      , ChildRecoveryDeliveryConsumptionWasConfirmed observation
      ) -> do
        requireRecoveryConsumptionObservation
          delivery
          ChildRecoveryConsumptionApplied
          observation
        Right state {childRecoveryStatePhase = ChildRecoveryDeliveryConsumed delivery}
    (ChildRecoveryDeliveryConsumed delivery, ChildRecoveryOrphanCleanupArmed) ->
      Right
        state
          { childRecoveryStatePhase =
              ChildRecoveryCancelIncompleteGenerateRoot delivery
          }
    ( ChildRecoveryCancelIncompleteGenerateRoot delivery
      , ChildRecoveryIncompleteGenerateRootCancelled
      ) ->
        Right
          state
            { childRecoveryStatePhase =
                ChildRecoveryInventoryStaleAccessors delivery
            }
    ( ChildRecoveryGenerateRootInFlight delivery _
      , ChildRecoveryIncompleteGenerateRootCancelled
      ) ->
        Right
          state
            { childRecoveryStatePhase =
                ChildRecoveryInventoryStaleAccessors delivery
            }
    ( ChildRecoveryInventoryStaleAccessors delivery
      , ChildRecoveryRootAccessorInventoryConfirmed inventory
      ) -> do
        requireRecoveryAccessorInventory delivery inventory
        case rootAccessorInventoryAccessors inventory of
          [] ->
            Right
              state
                { childRecoveryStatePhase =
                    ChildRecoveryStableAbsencePending delivery inventory
                }
          accessors ->
            Right
              state
                { childRecoveryStatePhase =
                    ChildRecoveryRevokeStaleAccessors delivery inventory accessors
                }
    ( ChildRecoveryRevokeStaleAccessors delivery inventory (expected : remaining)
      , ChildRecoveryStaleRootAccessorRevoked actual
      )
        | actual == expected ->
            if null remaining
              then
                Right
                  state
                    { childRecoveryStatePhase =
                        ChildRecoveryStableAbsencePending delivery inventory
                    }
              else
                Right
                  state
                    { childRecoveryStatePhase =
                        ChildRecoveryRevokeStaleAccessors delivery inventory remaining
                    }
        | otherwise -> Left ChildRecoveryStaleAccessorOrderMismatch
    ( ChildRecoveryStableAbsencePending delivery inventory
      , ChildRecoveryStableRootAccessorAbsenceConfirmed absence
      ) -> do
        requireRecoveryStableAbsence inventory absence
        Right
          state
            { childRecoveryStatePhase =
                ChildRecoveryGenerateRootPending delivery absence
            }
    ( ChildRecoveryGenerateRootPending delivery absence
      , ChildRecoveryRootGenerationStarted
      ) ->
        Right
          state
            { childRecoveryStatePhase =
                ChildRecoveryGenerateRootInFlight delivery absence
            }
    ( ChildRecoveryGenerateRootInFlight delivery _
      , ChildRecoveryRootAccessorCaptured accessor
      ) ->
        Right
          state
            { childRecoveryStatePhase =
                ChildRecoveryRootAccessorJournalPending delivery accessor
            }
    ( ChildRecoveryRootAccessorJournalPending delivery expected
      , ChildRecoveryRootAccessorWasJournaled actual
      )
        | actual == expected ->
            Right
              state
                { childRecoveryStatePhase =
                    ChildRecoveryRootAccessorJournaled delivery actual
                }
        | otherwise -> Left ChildRecoveryAccessorJournalMismatch
    (ChildRecoveryRootAccessorJournaled delivery accessor, ChildRecoveryRepairArmed) ->
      Right
        state
          { childRecoveryStatePhase =
              ChildRecoveryRepairMutationPending delivery accessor
          }
    (ChildRecoveryRepairMutationPending delivery accessor, ChildRecoveryRepairWasApplied) ->
      Right
        state
          { childRecoveryStatePhase =
              ChildRecoveryRepairApplied delivery accessor
          }
    ( ChildRecoveryRepairApplied delivery accessor
      , ChildRecoveryRepairReadBackConfirmed receipt
      ) -> do
        requireRecoveryRepairReceipt delivery receipt
        Right
          state
            { childRecoveryStatePhase =
                ChildRecoveryRepairReadBack delivery accessor receipt
            }
    (ChildRecoveryRepairReadBack delivery accessor receipt, ChildRecoveryRootRevocationArmed) ->
      Right
        state
          { childRecoveryStatePhase =
              ChildRecoveryRootRevocationPending delivery accessor (Just receipt)
          }
    (ChildRecoveryRootAccessorJournaled delivery accessor, ChildRecoveryRootRevocationArmed) -> do
      requireChildRecoveryCancellation state
      Right
        state
          { childRecoveryStatePhase =
              ChildRecoveryRootRevocationPending delivery accessor Nothing
          }
    (ChildRecoveryRepairMutationPending delivery accessor, ChildRecoveryRootRevocationArmed) -> do
      requireChildRecoveryCancellation state
      Right
        state
          { childRecoveryStatePhase =
              ChildRecoveryRootRevocationPending delivery accessor Nothing
          }
    (ChildRecoveryRepairApplied delivery accessor, ChildRecoveryRootRevocationArmed) -> do
      requireChildRecoveryCancellation state
      Right
        state
          { childRecoveryStatePhase =
              ChildRecoveryRootRevocationPending delivery accessor Nothing
          }
    ( ChildRecoveryRootRevocationPending delivery accessor receipt
      , ChildRecoveryRootWasRevoked
      ) ->
        Right
          state
            { childRecoveryStatePhase =
                ChildRecoveryRootRevoked delivery accessor receipt
            }
    ( ChildRecoveryRootRevoked delivery accessor receipt
      , ChildRecoveryRootAccessorAbsenceCheckArmed
      ) ->
        Right
          state
            { childRecoveryStatePhase =
                ChildRecoveryRootAbsencePending delivery accessor receipt
            }
    ( ChildRecoveryRootAbsencePending delivery accessor receipt
      , ChildRecoveryRootAccessorAbsenceWasConfirmed absence
      ) -> do
        requireRecoveryAccessorAbsence
          (childCustodyStorageGeneration (childRecoveryDeliveryBinding delivery))
          accessor
          absence
        case receipt of
          Just repairReceipt ->
            Right
              state
                { childRecoveryStatePhase =
                    ChildRecoveryDeliveryRevoked
                      delivery
                      accessor
                      repairReceipt
                      absence
                }
          Nothing ->
            Right
              state
                { childRecoveryStatePhase =
                    ChildRecoveryGenerateRootPending delivery absence
                }
    (_, ChildRecoveryDeliveryWasResumed) -> Right state
    (_, ChildRecoveryCancellationLatched reason) ->
      Right state {childRecoveryStateDisposition = CustodyCancellationRequested reason}
    (phase, _) -> Left (ChildRecoveryPhaseRefusal (show phase) (show event))
  validateChildRecoveryState evolved

applyChildRecoveryCommand
  :: ChildRecoveryState
  -> ChildRecoveryCommand
  -> Either ChildRecoveryError ChildRecoveryState
applyChildRecoveryCommand state command = do
  event <- decideChildRecovery state command
  evolveChildRecovery state event

planChildRecovery :: ChildRecoveryState -> ChildRecoveryPlan
planChildRecovery state =
  case childRecoveryStateDisposition state of
    CustodyRunning -> planRunningChildRecovery (childRecoveryStatePhase state)
    CustodyCancellationRequested _ ->
      planCancellingChildRecovery (childRecoveryStatePhase state)

-- | Restart preserves the exact delivery nonce.  Once consumed, an unfinished
-- operation returns to orphan cleanup before another generate-root attempt;
-- this closes the crash window between token generation and accessor journal.
restartChildRecovery :: ChildRecoveryState -> ChildRecoveryState
restartChildRecovery state =
  state
    { childRecoveryStateDisposition = CustodyRunning
    , childRecoveryStatePhase = restartedPhase (childRecoveryStatePhase state)
    }

childRecoveryInvariantViolations
  :: ChildRecoveryState -> [ChildRecoveryInvariantViolation]
childRecoveryInvariantViolations state =
  [ ChildRecoveryPhaseBindingDiffers expected actual
  | expected /= actual
  ]
    ++ childRecoveryPhaseRelationshipViolations (childRecoveryStatePhase state)
 where
  expected = childRecoveryStateBinding state
  actual = childRecoveryPhaseBinding (childRecoveryStatePhase state)

childRecoveryIsComplete :: ChildRecoveryState -> Bool
childRecoveryIsComplete state =
  case childRecoveryStatePhase state of
    ChildRecoveryDeliveryRevoked {} -> True
    _ -> False

childRecoveryEventForCommand
  :: ChildRecoveryState
  -> ChildRecoveryCommand
  -> Either ChildRecoveryError ChildRecoveryEvent
childRecoveryEventForCommand state command =
  case command of
    PrepareChildRecoveryDelivery delivery ->
      case childRecoveryCurrentDelivery (childRecoveryStatePhase state) of
        Nothing -> do
          requireDeliveryBinding (childRecoveryStateBinding state) delivery
          Right (ChildRecoveryDeliveryWasPrepared delivery)
        Just current -> do
          requireExactDelivery current delivery
          Right ChildRecoveryDeliveryWasResumed
    ArmChildRecoveryDeliveryConsume ->
      Right ChildRecoveryDeliveryConsumeWasArmed
    RecordChildRecoveryDeliveryConsumeStarted ->
      Right ChildRecoveryDeliveryConsumeWasStarted
    ConfirmChildRecoveryDeliveryConsumed observation ->
      Right (ChildRecoveryDeliveryConsumptionWasConfirmed observation)
    ArmChildRecoveryOrphanCleanup -> Right ChildRecoveryOrphanCleanupArmed
    ConfirmChildRecoveryIncompleteGenerateRootCancelled ->
      Right ChildRecoveryIncompleteGenerateRootCancelled
    ConfirmChildRecoveryRootAccessorInventory inventory ->
      Right (ChildRecoveryRootAccessorInventoryConfirmed inventory)
    ConfirmChildRecoveryStaleRootAccessorRevoked accessor ->
      Right (ChildRecoveryStaleRootAccessorRevoked accessor)
    ConfirmChildRecoveryStableRootAccessorAbsence absence ->
      Right (ChildRecoveryStableRootAccessorAbsenceConfirmed absence)
    RecordChildRecoveryRootGenerationStarted ->
      Right ChildRecoveryRootGenerationStarted
    CaptureChildRecoveryRootAccessor accessor ->
      Right (ChildRecoveryRootAccessorCaptured accessor)
    ConfirmChildRecoveryRootAccessorJournaled accessor ->
      Right (ChildRecoveryRootAccessorWasJournaled accessor)
    ArmChildRecoveryRepair -> Right ChildRecoveryRepairArmed
    RecordChildRecoveryRepairApplied -> Right ChildRecoveryRepairWasApplied
    ConfirmChildRecoveryRepairReadBack receipt ->
      Right (ChildRecoveryRepairReadBackConfirmed receipt)
    ArmChildRecoveryRootRevocation -> Right ChildRecoveryRootRevocationArmed
    ConfirmChildRecoveryRootRevoked -> Right ChildRecoveryRootWasRevoked
    ArmChildRecoveryRootAccessorAbsenceCheck ->
      Right ChildRecoveryRootAccessorAbsenceCheckArmed
    ConfirmChildRecoveryRootAccessorAbsent absence ->
      Right (ChildRecoveryRootAccessorAbsenceWasConfirmed absence)
    CancelChildRecovery reason -> Right (ChildRecoveryCancellationLatched reason)

requireChildRecoveryEventAllowed
  :: ChildRecoveryState -> ChildRecoveryEvent -> Either ChildRecoveryError ()
requireChildRecoveryEventAllowed state event =
  case childRecoveryStateDisposition state of
    CustodyRunning -> Right ()
    CustodyCancellationRequested _
      | recoveryEventIsSafetyTail event -> Right ()
      | otherwise -> Left (ChildRecoveryCancellationRefusal (show event))

recoveryEventIsSafetyTail :: ChildRecoveryEvent -> Bool
recoveryEventIsSafetyTail event =
  case event of
    ChildRecoveryDeliveryWasPrepared _ -> True
    ChildRecoveryDeliveryConsumptionWasConfirmed _ -> True
    ChildRecoveryOrphanCleanupArmed -> True
    ChildRecoveryIncompleteGenerateRootCancelled -> True
    ChildRecoveryRootAccessorInventoryConfirmed _ -> True
    ChildRecoveryStaleRootAccessorRevoked _ -> True
    ChildRecoveryStableRootAccessorAbsenceConfirmed _ -> True
    ChildRecoveryRootAccessorCaptured _ -> True
    ChildRecoveryRootAccessorWasJournaled _ -> True
    ChildRecoveryRepairWasApplied -> True
    ChildRecoveryRepairReadBackConfirmed _ -> True
    ChildRecoveryRootRevocationArmed -> True
    ChildRecoveryRootWasRevoked -> True
    ChildRecoveryRootAccessorAbsenceCheckArmed -> True
    ChildRecoveryRootAccessorAbsenceWasConfirmed _ -> True
    ChildRecoveryDeliveryWasResumed -> True
    ChildRecoveryCancellationLatched _ -> True
    ChildRecoveryDeliveryConsumeWasArmed -> False
    ChildRecoveryDeliveryConsumeWasStarted -> False
    ChildRecoveryRootGenerationStarted -> False
    ChildRecoveryRepairArmed -> False

childRecoveryCurrentDelivery
  :: ChildRecoveryPhase -> Maybe ChildRecoveryDelivery
childRecoveryCurrentDelivery phase =
  case phase of
    ChildRecoveryAvailable _ -> Nothing
    ChildRecoveryDeliveryPrepared delivery -> Just delivery
    ChildRecoveryDeliveryConsumeArmed delivery -> Just delivery
    ChildRecoveryDeliveryConsumeInFlight delivery -> Just delivery
    ChildRecoveryDeliveryConsumed delivery -> Just delivery
    ChildRecoveryCancelIncompleteGenerateRoot delivery -> Just delivery
    ChildRecoveryInventoryStaleAccessors delivery -> Just delivery
    ChildRecoveryRevokeStaleAccessors delivery _ _ -> Just delivery
    ChildRecoveryStableAbsencePending delivery _ -> Just delivery
    ChildRecoveryGenerateRootPending delivery _ -> Just delivery
    ChildRecoveryGenerateRootInFlight delivery _ -> Just delivery
    ChildRecoveryRootAccessorJournalPending delivery _ -> Just delivery
    ChildRecoveryRootAccessorJournaled delivery _ -> Just delivery
    ChildRecoveryRepairMutationPending delivery _ -> Just delivery
    ChildRecoveryRepairApplied delivery _ -> Just delivery
    ChildRecoveryRepairReadBack delivery _ _ -> Just delivery
    ChildRecoveryRootRevocationPending delivery _ _ -> Just delivery
    ChildRecoveryRootRevoked delivery _ _ -> Just delivery
    ChildRecoveryRootAbsencePending delivery _ _ -> Just delivery
    ChildRecoveryDeliveryRevoked delivery _ _ _ -> Just delivery

planRunningChildRecovery :: ChildRecoveryPhase -> ChildRecoveryPlan
planRunningChildRecovery phase =
  case phase of
    ChildRecoveryAvailable binding -> ChildRecoveryPlanAwaitDelivery binding
    ChildRecoveryDeliveryPrepared delivery ->
      ChildRecoveryPlanArmDeliveryConsume delivery
    ChildRecoveryDeliveryConsumeArmed delivery ->
      ChildRecoveryPlanStartDeliveryConsume delivery
    ChildRecoveryDeliveryConsumeInFlight delivery ->
      ChildRecoveryPlanReconcileDeliveryConsume delivery
    ChildRecoveryDeliveryConsumed delivery ->
      ChildRecoveryPlanArmOrphanCleanup delivery
    ChildRecoveryCancelIncompleteGenerateRoot delivery ->
      ChildRecoveryPlanCancelIncompleteGenerateRoot delivery
    ChildRecoveryInventoryStaleAccessors delivery ->
      ChildRecoveryPlanInventoryStaleRootAccessors delivery
    ChildRecoveryRevokeStaleAccessors delivery inventory remaining ->
      planChildRecoveryStaleCleanup delivery inventory remaining
    ChildRecoveryStableAbsencePending delivery inventory ->
      ChildRecoveryPlanProveStableRootAccessorAbsence delivery inventory
    ChildRecoveryGenerateRootPending delivery _ ->
      ChildRecoveryPlanGenerateShortLivedRoot delivery
    ChildRecoveryGenerateRootInFlight delivery _ ->
      ChildRecoveryPlanAwaitGeneratedRootAccessor delivery
    ChildRecoveryRootAccessorJournalPending delivery accessor ->
      ChildRecoveryPlanJournalRootAccessor delivery accessor
    ChildRecoveryRootAccessorJournaled delivery accessor ->
      ChildRecoveryPlanArmRepair delivery accessor
    ChildRecoveryRepairMutationPending delivery accessor ->
      ChildRecoveryPlanApplyRepair delivery accessor
    ChildRecoveryRepairApplied delivery accessor ->
      ChildRecoveryPlanReadBackRepair delivery accessor
    ChildRecoveryRepairReadBack delivery accessor _ ->
      ChildRecoveryPlanArmRootRevocation delivery accessor
    ChildRecoveryRootRevocationPending delivery accessor _ ->
      ChildRecoveryPlanRevokeRootAccessor delivery accessor
    ChildRecoveryRootRevoked delivery accessor _ ->
      ChildRecoveryPlanArmRootAccessorAbsenceCheck delivery accessor
    ChildRecoveryRootAbsencePending delivery accessor _ ->
      ChildRecoveryPlanProveRootAccessorAbsent delivery accessor
    ChildRecoveryDeliveryRevoked delivery _ receipt absence ->
      ChildRecoveryPlanComplete delivery receipt absence

planCancellingChildRecovery :: ChildRecoveryPhase -> ChildRecoveryPlan
planCancellingChildRecovery phase =
  case phase of
    ChildRecoveryAvailable _ -> cancellationLatched
    ChildRecoveryDeliveryPrepared _ -> cancellationLatched
    ChildRecoveryDeliveryConsumeArmed _ -> cancellationLatched
    ChildRecoveryDeliveryConsumeInFlight delivery ->
      ChildRecoveryPlanReconcileDeliveryConsume delivery
    ChildRecoveryDeliveryConsumed delivery ->
      ChildRecoveryPlanArmOrphanCleanup delivery
    ChildRecoveryCancelIncompleteGenerateRoot delivery ->
      ChildRecoveryPlanCancelIncompleteGenerateRoot delivery
    ChildRecoveryInventoryStaleAccessors delivery ->
      ChildRecoveryPlanInventoryStaleRootAccessors delivery
    ChildRecoveryRevokeStaleAccessors delivery inventory remaining ->
      planChildRecoveryStaleCleanup delivery inventory remaining
    ChildRecoveryStableAbsencePending delivery inventory ->
      ChildRecoveryPlanProveStableRootAccessorAbsence delivery inventory
    ChildRecoveryGenerateRootPending _ _ -> cancellationLatched
    ChildRecoveryGenerateRootInFlight delivery _ ->
      ChildRecoveryPlanCancelIncompleteGenerateRoot delivery
    ChildRecoveryRootAccessorJournalPending delivery accessor ->
      ChildRecoveryPlanJournalRootAccessor delivery accessor
    ChildRecoveryRootAccessorJournaled delivery accessor ->
      ChildRecoveryPlanArmRootRevocation delivery accessor
    ChildRecoveryRepairMutationPending delivery accessor ->
      ChildRecoveryPlanArmRootRevocation delivery accessor
    ChildRecoveryRepairApplied delivery accessor ->
      ChildRecoveryPlanArmRootRevocation delivery accessor
    ChildRecoveryRepairReadBack delivery accessor _ ->
      ChildRecoveryPlanArmRootRevocation delivery accessor
    ChildRecoveryRootRevocationPending delivery accessor _ ->
      ChildRecoveryPlanRevokeRootAccessor delivery accessor
    ChildRecoveryRootRevoked delivery accessor _ ->
      ChildRecoveryPlanArmRootAccessorAbsenceCheck delivery accessor
    ChildRecoveryRootAbsencePending delivery accessor _ ->
      ChildRecoveryPlanProveRootAccessorAbsent delivery accessor
    ChildRecoveryDeliveryRevoked delivery _ receipt absence ->
      ChildRecoveryPlanComplete delivery receipt absence
 where
  cancellationLatched = ChildRecoveryPlanCancellationLatched (show phase)

planChildRecoveryStaleCleanup
  :: ChildRecoveryDelivery
  -> RootAccessorInventory
  -> [RootPolicyAccessor]
  -> ChildRecoveryPlan
planChildRecoveryStaleCleanup delivery inventory remaining =
  case remaining of
    accessor : _ ->
      ChildRecoveryPlanRevokeStaleRootAccessor delivery accessor
    [] -> ChildRecoveryPlanProveStableRootAccessorAbsence delivery inventory

restartedPhase :: ChildRecoveryPhase -> ChildRecoveryPhase
restartedPhase phase =
  case phase of
    ChildRecoveryAvailable binding -> ChildRecoveryAvailable binding
    ChildRecoveryDeliveryPrepared delivery ->
      ChildRecoveryDeliveryPrepared delivery
    ChildRecoveryDeliveryConsumeArmed delivery ->
      ChildRecoveryDeliveryConsumeArmed delivery
    ChildRecoveryDeliveryConsumeInFlight delivery ->
      ChildRecoveryDeliveryConsumeInFlight delivery
    ChildRecoveryDeliveryRevoked delivery accessor receipt absence ->
      ChildRecoveryDeliveryRevoked delivery accessor receipt absence
    _ ->
      case childRecoveryCurrentDelivery phase of
        Just delivery -> ChildRecoveryDeliveryConsumed delivery
        Nothing -> phase

validateChildRecoveryState
  :: ChildRecoveryState -> Either ChildRecoveryError ChildRecoveryState
validateChildRecoveryState state =
  case childRecoveryInvariantViolations state of
    [] -> Right state
    violations -> Left (ChildRecoveryInvariantFailure violations)

childRecoveryPhaseBinding :: ChildRecoveryPhase -> ChildCustodyBinding
childRecoveryPhaseBinding phase =
  case phase of
    ChildRecoveryAvailable binding -> binding
    ChildRecoveryDeliveryPrepared delivery -> childRecoveryDeliveryBinding delivery
    ChildRecoveryDeliveryConsumeArmed delivery -> childRecoveryDeliveryBinding delivery
    ChildRecoveryDeliveryConsumeInFlight delivery ->
      childRecoveryDeliveryBinding delivery
    ChildRecoveryDeliveryConsumed delivery -> childRecoveryDeliveryBinding delivery
    ChildRecoveryCancelIncompleteGenerateRoot delivery ->
      childRecoveryDeliveryBinding delivery
    ChildRecoveryInventoryStaleAccessors delivery ->
      childRecoveryDeliveryBinding delivery
    ChildRecoveryRevokeStaleAccessors delivery _ _ ->
      childRecoveryDeliveryBinding delivery
    ChildRecoveryStableAbsencePending delivery _ ->
      childRecoveryDeliveryBinding delivery
    ChildRecoveryGenerateRootPending delivery _ ->
      childRecoveryDeliveryBinding delivery
    ChildRecoveryGenerateRootInFlight delivery _ ->
      childRecoveryDeliveryBinding delivery
    ChildRecoveryRootAccessorJournalPending delivery _ ->
      childRecoveryDeliveryBinding delivery
    ChildRecoveryRootAccessorJournaled delivery _ ->
      childRecoveryDeliveryBinding delivery
    ChildRecoveryRepairMutationPending delivery _ ->
      childRecoveryDeliveryBinding delivery
    ChildRecoveryRepairApplied delivery _ ->
      childRecoveryDeliveryBinding delivery
    ChildRecoveryRepairReadBack delivery _ _ ->
      childRecoveryDeliveryBinding delivery
    ChildRecoveryRootRevocationPending delivery _ _ ->
      childRecoveryDeliveryBinding delivery
    ChildRecoveryRootRevoked delivery _ _ ->
      childRecoveryDeliveryBinding delivery
    ChildRecoveryRootAbsencePending delivery _ _ ->
      childRecoveryDeliveryBinding delivery
    ChildRecoveryDeliveryRevoked delivery _ _ _ ->
      childRecoveryDeliveryBinding delivery

childRecoveryPhaseRelationshipViolations
  :: ChildRecoveryPhase -> [ChildRecoveryInvariantViolation]
childRecoveryPhaseRelationshipViolations phase =
  case phase of
    ChildRecoveryRevokeStaleAccessors delivery inventory remaining ->
      recoveryInventoryViolations delivery inventory
        ++ [ ChildRecoveryRemainingAccessorNotInventoried accessor
           | accessor <- remaining
           , accessor `notElem` rootAccessorInventoryAccessors inventory
           ]
        ++ [ ChildRecoveryInventoryNotCanonical
           | remaining /= sort (nub remaining)
           ]
    ChildRecoveryStableAbsencePending delivery inventory ->
      recoveryInventoryViolations delivery inventory
    ChildRecoveryGenerateRootPending delivery absence ->
      recoveryAbsenceGenerationViolations delivery absence
    ChildRecoveryGenerateRootInFlight delivery absence ->
      recoveryAbsenceGenerationViolations delivery absence
    ChildRecoveryRepairReadBack delivery _ receipt ->
      [ChildRecoveryRepairReceiptDiffers | not (repairReceiptMatches delivery receipt)]
    ChildRecoveryRootRevocationPending delivery _ receipt ->
      maybe [] (repairReceiptViolations delivery) receipt
    ChildRecoveryRootRevoked delivery _ receipt ->
      maybe [] (repairReceiptViolations delivery) receipt
    ChildRecoveryRootAbsencePending delivery _ receipt ->
      maybe [] (repairReceiptViolations delivery) receipt
    ChildRecoveryDeliveryRevoked delivery accessor receipt absence ->
      repairReceiptViolations delivery receipt
        ++ recoveryAccessorAbsenceViolations delivery accessor absence
    _ -> []

recoveryInventoryViolations
  :: ChildRecoveryDelivery
  -> RootAccessorInventory
  -> [ChildRecoveryInvariantViolation]
recoveryInventoryViolations delivery inventory =
  [ ChildRecoveryInventoryGenerationDiffers expected actual
  | actual /= expected
  ]
    ++ [ChildRecoveryInventoryNotCanonical | not (recoveryInventoryIsCanonical inventory)]
 where
  expected =
    childCustodyStorageGeneration (childRecoveryDeliveryBinding delivery)
  actual = rootAccessorInventoryGeneration inventory

recoveryAbsenceGenerationViolations
  :: ChildRecoveryDelivery
  -> AccessorAbsenceAttestation
  -> [ChildRecoveryInvariantViolation]
recoveryAbsenceGenerationViolations delivery =
  recoveryInventoryViolations delivery . accessorAbsenceInventory

repairReceiptViolations
  :: ChildRecoveryDelivery
  -> ChildRecoveryRepairReceipt
  -> [ChildRecoveryInvariantViolation]
repairReceiptViolations delivery receipt =
  [ChildRecoveryRepairReceiptDiffers | not (repairReceiptMatches delivery receipt)]

recoveryAccessorAbsenceViolations
  :: ChildRecoveryDelivery
  -> RootPolicyAccessor
  -> AccessorAbsenceAttestation
  -> [ChildRecoveryInvariantViolation]
recoveryAccessorAbsenceViolations delivery accessor absence =
  recoveryAbsenceGenerationViolations delivery absence
    ++ [ ChildRecoveryAccessorAbsenceDiffers accessor
       | rootAccessorInventoryAccessors (accessorAbsenceInventory absence)
           /= [accessor]
       ]

recoveryInventoryIsCanonical :: RootAccessorInventory -> Bool
recoveryInventoryIsCanonical inventory =
  length accessors <= 64 && accessors == sort (nub accessors)
 where
  accessors = rootAccessorInventoryAccessors inventory

requireRecoveryAccessorInventory
  :: ChildRecoveryDelivery
  -> RootAccessorInventory
  -> Either ChildRecoveryError ()
requireRecoveryAccessorInventory delivery inventory
  | null (recoveryInventoryViolations delivery inventory) = Right ()
  | otherwise = Left ChildRecoveryAccessorInventoryMismatch

requireRecoveryStableAbsence
  :: RootAccessorInventory
  -> AccessorAbsenceAttestation
  -> Either ChildRecoveryError ()
requireRecoveryStableAbsence inventory absence
  | accessorAbsenceInventory absence == inventory = Right ()
  | otherwise = Left ChildRecoveryStableAccessorAbsenceMismatch

requireRecoveryConsumptionObservation
  :: ChildRecoveryDelivery
  -> ChildRecoveryConsumptionStatus
  -> ChildRecoveryConsumptionObservation
  -> Either ChildRecoveryError ()
requireRecoveryConsumptionObservation delivery status observation
  | childRecoveryConsumptionObservationMatches delivery status observation = Right ()
  | otherwise = Left ChildRecoveryConsumptionObservationMismatch

requireRecoveryRepairReceipt
  :: ChildRecoveryDelivery
  -> ChildRecoveryRepairReceipt
  -> Either ChildRecoveryError ()
requireRecoveryRepairReceipt delivery receipt
  | repairReceiptMatches delivery receipt = Right ()
  | otherwise = Left ChildRecoveryRepairReadBackMismatch

repairReceiptMatches
  :: ChildRecoveryDelivery -> ChildRecoveryRepairReceipt -> Bool
repairReceiptMatches delivery receipt =
  childRecoveryRepairBinding receipt == childRecoveryDeliveryBinding delivery
    && childRecoveryRepairNonce receipt == childRecoveryDeliveryNonce delivery
    && childRecoveryRepairAttestation receipt
      == childRecoveryDeliveryAttestation delivery
    && childRecoveryRepairDeliveryDigest receipt
      == childRecoveryDeliveryDigest delivery

requireChildRecoveryCancellation
  :: ChildRecoveryState -> Either ChildRecoveryError ()
requireChildRecoveryCancellation state =
  case childRecoveryStateDisposition state of
    CustodyCancellationRequested _ -> Right ()
    CustodyRunning -> Left ChildRecoveryCancellationNotRequested

requireDeliveryBinding
  :: ChildCustodyBinding
  -> ChildRecoveryDelivery
  -> Either ChildRecoveryError ()
requireDeliveryBinding expected delivery =
  compareChildBindings expected (childRecoveryDeliveryBinding delivery)

requireExactDelivery
  :: ChildRecoveryDelivery
  -> ChildRecoveryDelivery
  -> Either ChildRecoveryError ()
requireExactDelivery expected actual = do
  compareChildBindings
    (childRecoveryDeliveryBinding expected)
    (childRecoveryDeliveryBinding actual)
  if childRecoveryDeliveryNonce expected /= childRecoveryDeliveryNonce actual
    then
      Left
        ( ChildRecoveryNonceConflict
            (childRecoveryDeliveryNonce expected)
            (childRecoveryDeliveryNonce actual)
        )
    else
      if childRecoveryDeliveryAttestation expected
        /= childRecoveryDeliveryAttestation actual
        then
          Left
            ( ChildRecoveryAttestationConflict
                (childRecoveryDeliveryAttestation expected)
                (childRecoveryDeliveryAttestation actual)
            )
        else
          if childRecoveryDeliveryPayload expected
            /= childRecoveryDeliveryPayload actual
            || childRecoveryDeliveryDigest expected
              /= childRecoveryDeliveryDigest actual
            then
              Left
                ( ChildRecoveryPayloadConflict
                    (childRecoveryDeliveryDigest expected)
                    (childRecoveryDeliveryDigest actual)
                )
            else Right ()

compareChildBindings
  :: ChildCustodyBinding
  -> ChildCustodyBinding
  -> Either ChildRecoveryError ()
compareChildBindings expected actual
  | childCustodyChildId expected /= childCustodyChildId actual =
      Left
        ( ChildRecoveryChildConflict
            (childCustodyChildId expected)
            (childCustodyChildId actual)
        )
  | childCustodyGeneration expected /= childCustodyGeneration actual =
      Left
        ( ChildRecoveryGenerationConflict
            (childCustodyGeneration expected)
            (childCustodyGeneration actual)
        )
  | childCustodyStorageGeneration expected
      /= childCustodyStorageGeneration actual =
      Left
        ( ChildRecoveryStorageGenerationConflict
            (childCustodyStorageGeneration expected)
            (childCustodyStorageGeneration actual)
        )
  | childCustodyTransactionId expected /= childCustodyTransactionId actual =
      Left
        ( ChildRecoveryTransactionConflict
            (childCustodyTransactionId expected)
            (childCustodyTransactionId actual)
        )
  | otherwise = Right ()

requireRecoveryAccessorAbsence
  :: VaultStorageGeneration
  -> RootPolicyAccessor
  -> AccessorAbsenceAttestation
  -> Either ChildRecoveryError ()
requireRecoveryAccessorAbsence generation accessor absence
  | rootAccessorInventoryGeneration inventory /= generation =
      Left ChildRecoveryAccessorAbsenceMismatch
  | rootAccessorInventoryAccessors inventory /= [accessor] =
      Left ChildRecoveryAccessorAbsenceMismatch
  | otherwise = Right ()
 where
  inventory = accessorAbsenceInventory absence
