{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE NamedFieldPuns #-}

-- | Pure Bootstrap Broker orchestration after encrypted recovery custody.
--
-- This module contains no Vault token type.  A generated root credential stays
-- inside the boundary interpreter; the durable model receives only its
-- non-secret accessor.  Restart always returns an unfinished root session to
-- orphan cleanup before another generate-root operation can begin.
module Prodbox.Bootstrap.Broker.Model
  ( -- * Short-lived root baseline sessions
    RootSessionBinding (..)
  , mkRootSessionBinding
  , rootSessionStorageGeneration
  , RootSessionCompletion (..)
  , RootSessionPhase (..)
  , RootSessionState (..)
  , RootSessionCommand (..)
  , RootSessionEvent (..)
  , RootSessionPlan (..)
  , RootSessionError (..)
  , RootSessionInvariantViolation (..)
  , newRootSessionState
  , decideRootSession
  , evolveRootSession
  , applyRootSessionCommand
  , planRootSession
  , restartRootSession
  , rootSessionInvariantViolations
  , rootSessionCompletion
  , rootSessionIsComplete
  , rootSessionIsCancelledClean

    -- * Normal provisioner login
  , ProvisionerSessionPhase (..)
  , ProvisionerSessionState (..)
  , ProvisionerSessionCommand (..)
  , ProvisionerSessionEvent (..)
  , ProvisionerSessionPlan (..)
  , ProvisionerSessionError (..)
  , newProvisionerSessionState
  , decideProvisionerSession
  , evolveProvisionerSession
  , applyProvisionerSessionCommand
  , planProvisionerSession
  , restartProvisionerSession
  , provisionerSessionIsReady

    -- * Flat Vault seal observation
  , VaultSealPhase (..)
  , VaultSealState (..)
  , VaultSealObservation (..)
  , VaultSealError (..)
  , newVaultSealState
  , observeVaultSeal
  , vaultSealIsUnsealed

    -- * Observation-only post-unseal handoff
  , PostUnsealHandoffPhase (..)
  , PostUnsealHandoffState (..)
  , PostUnsealHandoffCommand (..)
  , PostUnsealHandoffEvent (..)
  , PostUnsealHandoffPlan (..)
  , PostUnsealHandoffError (..)
  , newPostUnsealHandoffState
  , decidePostUnsealHandoff
  , evolvePostUnsealHandoff
  , applyPostUnsealHandoffCommand
  , planPostUnsealHandoff
  , postUnsealHandoffIsObserved

    -- * Product projection
  , BootstrapProjection (..)
  , BootstrapProjectionPlan (..)
  , BootstrapProjectionInvariantViolation (..)
  , mkBootstrapProjection
  , planBootstrapProjection
  , bootstrapProjectionInvariantViolations
  , bootstrapProjectionIsComplete
  )
where

import Data.List (nub, sort)
import Prodbox.Bootstrap.Broker.Custody
import Prodbox.Bootstrap.Broker.Types

-- Short-lived root baseline sessions ---------------------------------------

data RootSessionBinding = RootSessionBinding
  { rootSessionBindingId :: !RootSessionId
  , rootSessionBindingCustody :: !RecoveryCustodyReceipt
  }
  deriving stock (Eq, Show)

mkRootSessionBinding
  :: RootSessionId -> RecoveryCustodyReceipt -> RootSessionBinding
mkRootSessionBinding sessionId custody =
  RootSessionBinding
    { rootSessionBindingId = sessionId
    , rootSessionBindingCustody = custody
    }

rootSessionStorageGeneration :: RootSessionBinding -> VaultStorageGeneration
rootSessionStorageGeneration =
  rootInitStorageGeneration
    . recoveryCustodyBinding
    . rootSessionBindingCustody

data RootSessionCompletion = RootSessionCompletion
  { completedRootSessionBinding :: !RootSessionBinding
  , completedRootBaselineReadBack :: !BaselineReadBackReceipt
  , completedRootAccessorAbsence :: !AccessorAbsenceAttestation
  }
  deriving stock (Eq, Show)

-- | Every boundary where a crash changes the safe recovery action has its own
-- constructor.  In particular, accessor capture and accessor journaling are
-- distinct, as are baseline application/read-back and revocation/absence.
data RootSessionPhase
  = RootSessionCancelIncompleteGenerateRoot
  | RootSessionInventoryStaleAccessors
  | RootSessionRevokeStaleAccessors
      !RootAccessorInventory
      ![RootPolicyAccessor]
  | RootSessionStableAbsencePending !RootAccessorInventory
  | RootSessionGenerateRootPending !AccessorAbsenceAttestation
  | RootSessionGenerateRootInFlight !AccessorAbsenceAttestation
  | RootSessionAccessorJournalPending
      !AccessorAbsenceAttestation
      !RootPolicyAccessor
  | RootSessionAccessorJournaled !RootPolicyAccessor
  | RootSessionBaselineMutationPending !RootPolicyAccessor
  | RootSessionBaselineApplied !RootPolicyAccessor
  | RootSessionBaselineReadBack
      !RootPolicyAccessor
      !BaselineReadBackReceipt
  | RootSessionCurrentRevocationPending
      !RootPolicyAccessor
      !(Maybe BaselineReadBackReceipt)
  | RootSessionCurrentRevoked
      !RootPolicyAccessor
      !(Maybe BaselineReadBackReceipt)
  | RootSessionCurrentAbsencePending
      !RootPolicyAccessor
      !(Maybe BaselineReadBackReceipt)
  | RootSessionClosed
      !BaselineReadBackReceipt
      !AccessorAbsenceAttestation
  | RootSessionCancelledClean !AccessorAbsenceAttestation
  deriving stock (Eq)

instance Show RootSessionPhase where
  show = rootSessionPhaseName

data RootSessionState = RootSessionState
  { rootSessionStateBinding :: !RootSessionBinding
  , rootSessionStateDisposition :: !CustodyDisposition
  , rootSessionStatePhase :: !RootSessionPhase
  }
  deriving stock (Eq)

instance Show RootSessionState where
  show state =
    "RootSessionState {binding = "
      ++ show (rootSessionStateBinding state)
      ++ ", disposition = "
      ++ show (rootSessionStateDisposition state)
      ++ ", phase = "
      ++ rootSessionPhaseName (rootSessionStatePhase state)
      ++ "}"

data RootSessionCommand
  = ConfirmIncompleteGenerateRootCancelled
  | ConfirmRootAccessorInventory !RootAccessorInventory
  | ConfirmStaleRootAccessorRevoked !RootPolicyAccessor
  | ConfirmStableRootAccessorAbsence !AccessorAbsenceAttestation
  | RecordShortLivedRootGenerationStarted
  | CaptureGeneratedRootAccessor !RootPolicyAccessor
  | ConfirmGeneratedRootAccessorJournaled !RootPolicyAccessor
  | ArmAllowlistedBaselineMutation
  | RecordAllowlistedBaselineApplied
  | ConfirmAllowlistedBaselineReadBack !BaselineReadBackReceipt
  | ArmCurrentRootSessionRevocation
  | ConfirmCurrentRootSessionRevoked
  | ArmCurrentRootAccessorAbsenceCheck
  | ConfirmCurrentRootAccessorAbsent !AccessorAbsenceAttestation
  | FinishRootSessionCancellation
  | CancelRootSession !CancellationReason
  deriving stock (Eq)

instance Show RootSessionCommand where
  show command =
    case command of
      ConfirmIncompleteGenerateRootCancelled ->
        "ConfirmIncompleteGenerateRootCancelled"
      ConfirmRootAccessorInventory _ -> "ConfirmRootAccessorInventory"
      ConfirmStaleRootAccessorRevoked _ -> "ConfirmStaleRootAccessorRevoked"
      ConfirmStableRootAccessorAbsence _ ->
        "ConfirmStableRootAccessorAbsence"
      RecordShortLivedRootGenerationStarted ->
        "RecordShortLivedRootGenerationStarted"
      CaptureGeneratedRootAccessor _ -> "CaptureGeneratedRootAccessor"
      ConfirmGeneratedRootAccessorJournaled _ ->
        "ConfirmGeneratedRootAccessorJournaled"
      ArmAllowlistedBaselineMutation -> "ArmAllowlistedBaselineMutation"
      RecordAllowlistedBaselineApplied -> "RecordAllowlistedBaselineApplied"
      ConfirmAllowlistedBaselineReadBack _ ->
        "ConfirmAllowlistedBaselineReadBack"
      ArmCurrentRootSessionRevocation -> "ArmCurrentRootSessionRevocation"
      ConfirmCurrentRootSessionRevoked -> "ConfirmCurrentRootSessionRevoked"
      ArmCurrentRootAccessorAbsenceCheck ->
        "ArmCurrentRootAccessorAbsenceCheck"
      ConfirmCurrentRootAccessorAbsent _ ->
        "ConfirmCurrentRootAccessorAbsent"
      FinishRootSessionCancellation -> "FinishRootSessionCancellation"
      CancelRootSession _ -> "CancelRootSession <redacted>"

data RootSessionEvent
  = RootSessionIncompleteGenerateRootCancelled
  | RootSessionAccessorInventoryConfirmed !RootAccessorInventory
  | RootSessionStaleAccessorRevoked !RootPolicyAccessor
  | RootSessionStableAccessorAbsenceConfirmed !AccessorAbsenceAttestation
  | RootSessionShortLivedRootGenerationStarted
  | RootSessionGeneratedAccessorCaptured !RootPolicyAccessor
  | RootSessionGeneratedAccessorJournaled !RootPolicyAccessor
  | RootSessionAllowlistedBaselineArmed
  | RootSessionAllowlistedBaselineApplied
  | RootSessionAllowlistedBaselineReadBackConfirmed !BaselineReadBackReceipt
  | RootSessionCurrentRevocationArmed
  | RootSessionCurrentRevocationConfirmed
  | RootSessionCurrentAccessorAbsenceCheckArmed
  | RootSessionCurrentAccessorAbsenceConfirmed !AccessorAbsenceAttestation
  | RootSessionCancellationCompleted
  | RootSessionCancellationLatched !CancellationReason
  deriving stock (Eq)

instance Show RootSessionEvent where
  show event =
    case event of
      RootSessionIncompleteGenerateRootCancelled ->
        "RootSessionIncompleteGenerateRootCancelled"
      RootSessionAccessorInventoryConfirmed _ ->
        "RootSessionAccessorInventoryConfirmed"
      RootSessionStaleAccessorRevoked _ -> "RootSessionStaleAccessorRevoked"
      RootSessionStableAccessorAbsenceConfirmed _ ->
        "RootSessionStableAccessorAbsenceConfirmed"
      RootSessionShortLivedRootGenerationStarted ->
        "RootSessionShortLivedRootGenerationStarted"
      RootSessionGeneratedAccessorCaptured _ ->
        "RootSessionGeneratedAccessorCaptured"
      RootSessionGeneratedAccessorJournaled _ ->
        "RootSessionGeneratedAccessorJournaled"
      RootSessionAllowlistedBaselineArmed ->
        "RootSessionAllowlistedBaselineArmed"
      RootSessionAllowlistedBaselineApplied ->
        "RootSessionAllowlistedBaselineApplied"
      RootSessionAllowlistedBaselineReadBackConfirmed _ ->
        "RootSessionAllowlistedBaselineReadBackConfirmed"
      RootSessionCurrentRevocationArmed ->
        "RootSessionCurrentRevocationArmed"
      RootSessionCurrentRevocationConfirmed ->
        "RootSessionCurrentRevocationConfirmed"
      RootSessionCurrentAccessorAbsenceCheckArmed ->
        "RootSessionCurrentAccessorAbsenceCheckArmed"
      RootSessionCurrentAccessorAbsenceConfirmed _ ->
        "RootSessionCurrentAccessorAbsenceConfirmed"
      RootSessionCancellationCompleted -> "RootSessionCancellationCompleted"
      RootSessionCancellationLatched _ ->
        "RootSessionCancellationLatched <redacted>"

data RootSessionPlan
  = RootSessionPlanCancelIncompleteGenerateRoot !RootSessionBinding
  | RootSessionPlanInventoryStaleAccessors !VaultStorageGeneration
  | RootSessionPlanRevokeStaleAccessor !RootPolicyAccessor
  | RootSessionPlanProveStableAccessorAbsence !RootAccessorInventory
  | RootSessionPlanGenerateShortLivedRoot !RootSessionBinding
  | RootSessionPlanAwaitGeneratedRootAccessor !RootSessionBinding
  | RootSessionPlanJournalGeneratedAccessor
      !RootSessionBinding
      !RootPolicyAccessor
  | RootSessionPlanArmAllowlistedBaseline !RootPolicyAccessor
  | RootSessionPlanApplyAllowlistedBaseline !RootPolicyAccessor
  | RootSessionPlanReadBackAllowlistedBaseline !RootPolicyAccessor
  | RootSessionPlanArmCurrentRevocation !RootPolicyAccessor
  | RootSessionPlanRevokeCurrentAccessor !RootPolicyAccessor
  | RootSessionPlanArmCurrentAccessorAbsenceCheck !RootPolicyAccessor
  | RootSessionPlanProveCurrentAccessorAbsent !RootPolicyAccessor
  | RootSessionPlanFinishCancellation !AccessorAbsenceAttestation
  | RootSessionPlanComplete !RootSessionCompletion
  | RootSessionPlanCancelledClean !AccessorAbsenceAttestation
  deriving stock (Eq)

instance Show RootSessionPlan where
  show plan =
    case plan of
      RootSessionPlanCancelIncompleteGenerateRoot _ ->
        "RootSessionPlanCancelIncompleteGenerateRoot"
      RootSessionPlanInventoryStaleAccessors _ ->
        "RootSessionPlanInventoryStaleAccessors"
      RootSessionPlanRevokeStaleAccessor _ ->
        "RootSessionPlanRevokeStaleAccessor"
      RootSessionPlanProveStableAccessorAbsence _ ->
        "RootSessionPlanProveStableAccessorAbsence"
      RootSessionPlanGenerateShortLivedRoot _ ->
        "RootSessionPlanGenerateShortLivedRoot"
      RootSessionPlanAwaitGeneratedRootAccessor _ ->
        "RootSessionPlanAwaitGeneratedRootAccessor"
      RootSessionPlanJournalGeneratedAccessor _ _ ->
        "RootSessionPlanJournalGeneratedAccessor"
      RootSessionPlanArmAllowlistedBaseline _ ->
        "RootSessionPlanArmAllowlistedBaseline"
      RootSessionPlanApplyAllowlistedBaseline _ ->
        "RootSessionPlanApplyAllowlistedBaseline"
      RootSessionPlanReadBackAllowlistedBaseline _ ->
        "RootSessionPlanReadBackAllowlistedBaseline"
      RootSessionPlanArmCurrentRevocation _ ->
        "RootSessionPlanArmCurrentRevocation"
      RootSessionPlanRevokeCurrentAccessor _ ->
        "RootSessionPlanRevokeCurrentAccessor"
      RootSessionPlanArmCurrentAccessorAbsenceCheck _ ->
        "RootSessionPlanArmCurrentAccessorAbsenceCheck"
      RootSessionPlanProveCurrentAccessorAbsent _ ->
        "RootSessionPlanProveCurrentAccessorAbsent"
      RootSessionPlanFinishCancellation _ ->
        "RootSessionPlanFinishCancellation"
      RootSessionPlanComplete _ -> "RootSessionPlanComplete"
      RootSessionPlanCancelledClean _ -> "RootSessionPlanCancelledClean"

data RootSessionError
  = RootSessionPhaseRefusal !String !String
  | RootSessionCancellationRefusal !String
  | RootSessionAccessorInventoryMismatch
  | RootSessionStaleAccessorOrderMismatch
  | RootSessionStableAbsenceMismatch
  | RootSessionAccessorJournalMismatch
  | RootSessionBaselineReadBackMismatch
  | RootSessionCurrentAccessorAbsenceMismatch
  | RootSessionCancellationNotRequested
  | RootSessionRestartMustAdvanceSessionId
  | RootSessionInvariantFailure ![RootSessionInvariantViolation]
  deriving stock (Eq, Show)

data RootSessionInvariantViolation
  = RootSessionInventoryGenerationDiffers
      !VaultStorageGeneration
      !VaultStorageGeneration
  | RootSessionInventoryNotCanonical
  | RootSessionRemainingAccessorNotInventoried !RootPolicyAccessor
  | RootSessionStableAbsenceDiffers
  | RootSessionBaselineIdDiffers !RootSessionId !RootSessionId
  | RootSessionBaselineGenerationDiffers
      !VaultStorageGeneration
      !VaultStorageGeneration
  | RootSessionBaselineTargetsDiffer ![BaselineTarget]
  | RootSessionCurrentAbsenceDiffers !RootPolicyAccessor
  deriving stock (Eq, Show)

newRootSessionState
  :: RootSessionId -> RecoveryCustodyReceipt -> RootSessionState
newRootSessionState sessionId custody =
  RootSessionState
    { rootSessionStateBinding = mkRootSessionBinding sessionId custody
    , rootSessionStateDisposition = CustodyRunning
    , rootSessionStatePhase = RootSessionCancelIncompleteGenerateRoot
    }

decideRootSession
  :: RootSessionState
  -> RootSessionCommand
  -> Either RootSessionError RootSessionEvent
decideRootSession state command = do
  let event = rootSessionEventForCommand command
  _ <- evolveRootSession state event
  pure event

evolveRootSession
  :: RootSessionState
  -> RootSessionEvent
  -> Either RootSessionError RootSessionState
evolveRootSession state event = do
  requireRootSessionEventAllowed state event
  evolved <- evolveRootSessionPhase state event
  validateRootSessionState evolved

applyRootSessionCommand
  :: RootSessionState
  -> RootSessionCommand
  -> Either RootSessionError RootSessionState
applyRootSessionCommand state command = do
  event <- decideRootSession state command
  evolveRootSession state event

planRootSession :: RootSessionState -> RootSessionPlan
planRootSession state =
  case rootSessionStateDisposition state of
    CustodyRunning -> planRunningRootSession state
    CustodyCancellationRequested _ -> planCancellingRootSession state

-- | Restart never trusts a process-local generate-root outcome.  An unfinished
-- session receives a fresh session identity and begins again at cancellation
-- plus accessor inventory.  A terminal fold is already safe and is retained.
restartRootSession
  :: RootSessionId
  -> RootSessionState
  -> Either RootSessionError RootSessionState
restartRootSession replacementSessionId state
  | rootSessionIsComplete state || rootSessionIsCancelledClean state = Right state
  | replacementSessionId == rootSessionBindingId oldBinding =
      Left RootSessionRestartMustAdvanceSessionId
  | otherwise =
      validateRootSessionState
        RootSessionState
          { rootSessionStateBinding =
              mkRootSessionBinding
                replacementSessionId
                (rootSessionBindingCustody oldBinding)
          , rootSessionStateDisposition = rootSessionStateDisposition state
          , rootSessionStatePhase = RootSessionCancelIncompleteGenerateRoot
          }
 where
  oldBinding = rootSessionStateBinding state

rootSessionInvariantViolations
  :: RootSessionState -> [RootSessionInvariantViolation]
rootSessionInvariantViolations state =
  phaseInvariantViolations
    (rootSessionStateBinding state)
    (rootSessionStatePhase state)

rootSessionCompletion :: RootSessionState -> Maybe RootSessionCompletion
rootSessionCompletion state =
  case rootSessionStatePhase state of
    RootSessionClosed receipt absence ->
      Just
        RootSessionCompletion
          { completedRootSessionBinding = rootSessionStateBinding state
          , completedRootBaselineReadBack = receipt
          , completedRootAccessorAbsence = absence
          }
    _ -> Nothing

rootSessionIsComplete :: RootSessionState -> Bool
rootSessionIsComplete = maybe False (const True) . rootSessionCompletion

rootSessionIsCancelledClean :: RootSessionState -> Bool
rootSessionIsCancelledClean state =
  case rootSessionStatePhase state of
    RootSessionCancelledClean _ -> True
    _ -> False

rootSessionEventForCommand :: RootSessionCommand -> RootSessionEvent
rootSessionEventForCommand command =
  case command of
    ConfirmIncompleteGenerateRootCancelled ->
      RootSessionIncompleteGenerateRootCancelled
    ConfirmRootAccessorInventory inventory ->
      RootSessionAccessorInventoryConfirmed inventory
    ConfirmStaleRootAccessorRevoked accessor ->
      RootSessionStaleAccessorRevoked accessor
    ConfirmStableRootAccessorAbsence absence ->
      RootSessionStableAccessorAbsenceConfirmed absence
    RecordShortLivedRootGenerationStarted ->
      RootSessionShortLivedRootGenerationStarted
    CaptureGeneratedRootAccessor accessor ->
      RootSessionGeneratedAccessorCaptured accessor
    ConfirmGeneratedRootAccessorJournaled accessor ->
      RootSessionGeneratedAccessorJournaled accessor
    ArmAllowlistedBaselineMutation -> RootSessionAllowlistedBaselineArmed
    RecordAllowlistedBaselineApplied -> RootSessionAllowlistedBaselineApplied
    ConfirmAllowlistedBaselineReadBack receipt ->
      RootSessionAllowlistedBaselineReadBackConfirmed receipt
    ArmCurrentRootSessionRevocation -> RootSessionCurrentRevocationArmed
    ConfirmCurrentRootSessionRevoked -> RootSessionCurrentRevocationConfirmed
    ArmCurrentRootAccessorAbsenceCheck ->
      RootSessionCurrentAccessorAbsenceCheckArmed
    ConfirmCurrentRootAccessorAbsent absence ->
      RootSessionCurrentAccessorAbsenceConfirmed absence
    FinishRootSessionCancellation -> RootSessionCancellationCompleted
    CancelRootSession reason -> RootSessionCancellationLatched reason

evolveRootSessionPhase
  :: RootSessionState
  -> RootSessionEvent
  -> Either RootSessionError RootSessionState
evolveRootSessionPhase state event =
  case (rootSessionStatePhase state, event) of
    (RootSessionCancelIncompleteGenerateRoot, RootSessionIncompleteGenerateRootCancelled) ->
      withRootSessionPhase state RootSessionInventoryStaleAccessors
    (RootSessionGenerateRootInFlight _, RootSessionIncompleteGenerateRootCancelled) ->
      withRootSessionPhase state RootSessionInventoryStaleAccessors
    (RootSessionInventoryStaleAccessors, RootSessionAccessorInventoryConfirmed inventory) -> do
      requireRootAccessorInventory (rootSessionStateBinding state) inventory
      case rootAccessorInventoryAccessors inventory of
        [] -> withRootSessionPhase state (RootSessionStableAbsencePending inventory)
        accessors ->
          withRootSessionPhase
            state
            (RootSessionRevokeStaleAccessors inventory accessors)
    ( RootSessionRevokeStaleAccessors inventory (expected : remaining)
      , RootSessionStaleAccessorRevoked actual
      )
        | actual == expected ->
            if null remaining
              then withRootSessionPhase state (RootSessionStableAbsencePending inventory)
              else
                withRootSessionPhase
                  state
                  (RootSessionRevokeStaleAccessors inventory remaining)
        | otherwise -> Left RootSessionStaleAccessorOrderMismatch
    (RootSessionStableAbsencePending inventory, RootSessionStableAccessorAbsenceConfirmed absence) -> do
      requireExactAbsence inventory absence RootSessionStableAbsenceMismatch
      withRootSessionPhase state (RootSessionGenerateRootPending absence)
    (RootSessionGenerateRootPending absence, RootSessionShortLivedRootGenerationStarted) ->
      withRootSessionPhase state (RootSessionGenerateRootInFlight absence)
    (RootSessionGenerateRootInFlight absence, RootSessionGeneratedAccessorCaptured accessor) ->
      withRootSessionPhase
        state
        (RootSessionAccessorJournalPending absence accessor)
    (RootSessionAccessorJournalPending _ expected, RootSessionGeneratedAccessorJournaled actual)
      | actual == expected ->
          withRootSessionPhase state (RootSessionAccessorJournaled actual)
      | otherwise -> Left RootSessionAccessorJournalMismatch
    (RootSessionAccessorJournaled accessor, RootSessionAllowlistedBaselineArmed) ->
      withRootSessionPhase state (RootSessionBaselineMutationPending accessor)
    (RootSessionBaselineMutationPending accessor, RootSessionAllowlistedBaselineApplied) ->
      withRootSessionPhase state (RootSessionBaselineApplied accessor)
    (RootSessionBaselineApplied accessor, RootSessionAllowlistedBaselineReadBackConfirmed receipt) -> do
      requireBaselineReadBack (rootSessionStateBinding state) receipt
      withRootSessionPhase state (RootSessionBaselineReadBack accessor receipt)
    (RootSessionBaselineReadBack accessor receipt, RootSessionCurrentRevocationArmed) ->
      withRootSessionPhase
        state
        (RootSessionCurrentRevocationPending accessor (Just receipt))
    (RootSessionAccessorJournaled accessor, RootSessionCurrentRevocationArmed) -> do
      requireRootSessionCancellation state
      withRootSessionPhase
        state
        (RootSessionCurrentRevocationPending accessor Nothing)
    (RootSessionBaselineMutationPending accessor, RootSessionCurrentRevocationArmed) -> do
      requireRootSessionCancellation state
      withRootSessionPhase
        state
        (RootSessionCurrentRevocationPending accessor Nothing)
    (RootSessionBaselineApplied accessor, RootSessionCurrentRevocationArmed) -> do
      requireRootSessionCancellation state
      withRootSessionPhase
        state
        (RootSessionCurrentRevocationPending accessor Nothing)
    (RootSessionCurrentRevocationPending accessor receipt, RootSessionCurrentRevocationConfirmed) ->
      withRootSessionPhase state (RootSessionCurrentRevoked accessor receipt)
    (RootSessionCurrentRevoked accessor receipt, RootSessionCurrentAccessorAbsenceCheckArmed) ->
      withRootSessionPhase
        state
        (RootSessionCurrentAbsencePending accessor receipt)
    ( RootSessionCurrentAbsencePending accessor receipt
      , RootSessionCurrentAccessorAbsenceConfirmed absence
      ) -> do
        requireCurrentAccessorAbsence
          (rootSessionStateBinding state)
          accessor
          absence
        case receipt of
          Just baselineReceipt ->
            withRootSessionPhase
              state
              (RootSessionClosed baselineReceipt absence)
          Nothing -> withRootSessionPhase state (RootSessionCancelledClean absence)
    (RootSessionGenerateRootPending absence, RootSessionCancellationCompleted) -> do
      requireRootSessionCancellation state
      withRootSessionPhase state (RootSessionCancelledClean absence)
    (_, RootSessionCancellationLatched reason) ->
      Right state {rootSessionStateDisposition = CustodyCancellationRequested reason}
    (phase, _) ->
      Left
        ( RootSessionPhaseRefusal
            (rootSessionPhaseName phase)
            (show event)
        )

withRootSessionPhase
  :: RootSessionState
  -> RootSessionPhase
  -> Either RootSessionError RootSessionState
withRootSessionPhase state phase =
  Right state {rootSessionStatePhase = phase}

requireRootSessionEventAllowed
  :: RootSessionState -> RootSessionEvent -> Either RootSessionError ()
requireRootSessionEventAllowed state event =
  case rootSessionStateDisposition state of
    CustodyRunning -> Right ()
    CustodyCancellationRequested _
      | rootSessionEventIsSafetyTail event -> Right ()
      | otherwise -> Left (RootSessionCancellationRefusal (show event))

rootSessionEventIsSafetyTail :: RootSessionEvent -> Bool
rootSessionEventIsSafetyTail event =
  case event of
    RootSessionIncompleteGenerateRootCancelled -> True
    RootSessionAccessorInventoryConfirmed _ -> True
    RootSessionStaleAccessorRevoked _ -> True
    RootSessionStableAccessorAbsenceConfirmed _ -> True
    RootSessionGeneratedAccessorCaptured _ -> True
    RootSessionGeneratedAccessorJournaled _ -> True
    RootSessionAllowlistedBaselineApplied -> True
    RootSessionAllowlistedBaselineReadBackConfirmed _ -> True
    RootSessionCurrentRevocationArmed -> True
    RootSessionCurrentRevocationConfirmed -> True
    RootSessionCurrentAccessorAbsenceCheckArmed -> True
    RootSessionCurrentAccessorAbsenceConfirmed _ -> True
    RootSessionCancellationCompleted -> True
    RootSessionCancellationLatched _ -> True
    RootSessionShortLivedRootGenerationStarted -> False
    RootSessionAllowlistedBaselineArmed -> False

planRunningRootSession :: RootSessionState -> RootSessionPlan
planRunningRootSession state =
  case rootSessionStatePhase state of
    RootSessionCancelIncompleteGenerateRoot ->
      RootSessionPlanCancelIncompleteGenerateRoot binding
    RootSessionInventoryStaleAccessors ->
      RootSessionPlanInventoryStaleAccessors generation
    RootSessionRevokeStaleAccessors inventory remaining ->
      planStaleAccessorCleanup inventory remaining
    RootSessionStableAbsencePending inventory ->
      RootSessionPlanProveStableAccessorAbsence inventory
    RootSessionGenerateRootPending _ ->
      RootSessionPlanGenerateShortLivedRoot binding
    RootSessionGenerateRootInFlight _ ->
      RootSessionPlanAwaitGeneratedRootAccessor binding
    RootSessionAccessorJournalPending _ accessor ->
      RootSessionPlanJournalGeneratedAccessor binding accessor
    RootSessionAccessorJournaled accessor ->
      RootSessionPlanArmAllowlistedBaseline accessor
    RootSessionBaselineMutationPending accessor ->
      RootSessionPlanApplyAllowlistedBaseline accessor
    RootSessionBaselineApplied accessor ->
      RootSessionPlanReadBackAllowlistedBaseline accessor
    RootSessionBaselineReadBack accessor _ ->
      RootSessionPlanArmCurrentRevocation accessor
    RootSessionCurrentRevocationPending accessor _ ->
      RootSessionPlanRevokeCurrentAccessor accessor
    RootSessionCurrentRevoked accessor _ ->
      RootSessionPlanArmCurrentAccessorAbsenceCheck accessor
    RootSessionCurrentAbsencePending accessor _ ->
      RootSessionPlanProveCurrentAccessorAbsent accessor
    RootSessionClosed receipt absence ->
      RootSessionPlanComplete
        RootSessionCompletion
          { completedRootSessionBinding = binding
          , completedRootBaselineReadBack = receipt
          , completedRootAccessorAbsence = absence
          }
    RootSessionCancelledClean absence -> RootSessionPlanCancelledClean absence
 where
  binding = rootSessionStateBinding state
  generation = rootSessionStorageGeneration binding

planCancellingRootSession :: RootSessionState -> RootSessionPlan
planCancellingRootSession state =
  case rootSessionStatePhase state of
    RootSessionCancelIncompleteGenerateRoot ->
      RootSessionPlanCancelIncompleteGenerateRoot binding
    RootSessionInventoryStaleAccessors ->
      RootSessionPlanInventoryStaleAccessors generation
    RootSessionRevokeStaleAccessors inventory remaining ->
      planStaleAccessorCleanup inventory remaining
    RootSessionStableAbsencePending inventory ->
      RootSessionPlanProveStableAccessorAbsence inventory
    RootSessionGenerateRootPending absence ->
      RootSessionPlanFinishCancellation absence
    RootSessionGenerateRootInFlight _ ->
      RootSessionPlanCancelIncompleteGenerateRoot binding
    RootSessionAccessorJournalPending _ accessor ->
      RootSessionPlanJournalGeneratedAccessor binding accessor
    RootSessionAccessorJournaled accessor ->
      RootSessionPlanArmCurrentRevocation accessor
    RootSessionBaselineMutationPending accessor ->
      RootSessionPlanArmCurrentRevocation accessor
    RootSessionBaselineApplied accessor ->
      RootSessionPlanArmCurrentRevocation accessor
    RootSessionBaselineReadBack accessor _ ->
      RootSessionPlanArmCurrentRevocation accessor
    RootSessionCurrentRevocationPending accessor _ ->
      RootSessionPlanRevokeCurrentAccessor accessor
    RootSessionCurrentRevoked accessor _ ->
      RootSessionPlanArmCurrentAccessorAbsenceCheck accessor
    RootSessionCurrentAbsencePending accessor _ ->
      RootSessionPlanProveCurrentAccessorAbsent accessor
    RootSessionClosed receipt absence ->
      RootSessionPlanComplete
        RootSessionCompletion
          { completedRootSessionBinding = binding
          , completedRootBaselineReadBack = receipt
          , completedRootAccessorAbsence = absence
          }
    RootSessionCancelledClean absence -> RootSessionPlanCancelledClean absence
 where
  binding = rootSessionStateBinding state
  generation = rootSessionStorageGeneration binding

planStaleAccessorCleanup
  :: RootAccessorInventory -> [RootPolicyAccessor] -> RootSessionPlan
planStaleAccessorCleanup inventory remaining =
  case remaining of
    accessor : _ -> RootSessionPlanRevokeStaleAccessor accessor
    [] -> RootSessionPlanProveStableAccessorAbsence inventory

requireRootAccessorInventory
  :: RootSessionBinding
  -> RootAccessorInventory
  -> Either RootSessionError ()
requireRootAccessorInventory binding inventory
  | rootAccessorInventoryGeneration inventory /= rootSessionStorageGeneration binding =
      Left RootSessionAccessorInventoryMismatch
  | not (inventoryIsCanonical inventory) =
      Left RootSessionAccessorInventoryMismatch
  | otherwise = Right ()

inventoryIsCanonical :: RootAccessorInventory -> Bool
inventoryIsCanonical inventory =
  length accessors <= 64
    && accessors == sort (nub accessors)
 where
  accessors = rootAccessorInventoryAccessors inventory

requireExactAbsence
  :: RootAccessorInventory
  -> AccessorAbsenceAttestation
  -> RootSessionError
  -> Either RootSessionError ()
requireExactAbsence expected absence mismatch
  | accessorAbsenceInventory absence == expected = Right ()
  | otherwise = Left mismatch

requireBaselineReadBack
  :: RootSessionBinding
  -> BaselineReadBackReceipt
  -> Either RootSessionError ()
requireBaselineReadBack binding receipt
  | baselineReadBackSessionId receipt /= rootSessionBindingId binding =
      Left RootSessionBaselineReadBackMismatch
  | baselineReadBackStorageGeneration receipt /= rootSessionStorageGeneration binding =
      Left RootSessionBaselineReadBackMismatch
  | baselineReadBackTargets receipt /= requiredRootBaselineTargets =
      Left RootSessionBaselineReadBackMismatch
  | otherwise = Right ()

requireCurrentAccessorAbsence
  :: RootSessionBinding
  -> RootPolicyAccessor
  -> AccessorAbsenceAttestation
  -> Either RootSessionError ()
requireCurrentAccessorAbsence binding accessor absence
  | rootAccessorInventoryGeneration inventory /= rootSessionStorageGeneration binding =
      Left RootSessionCurrentAccessorAbsenceMismatch
  | rootAccessorInventoryAccessors inventory /= [accessor] =
      Left RootSessionCurrentAccessorAbsenceMismatch
  | otherwise = Right ()
 where
  inventory = accessorAbsenceInventory absence

requireRootSessionCancellation
  :: RootSessionState -> Either RootSessionError ()
requireRootSessionCancellation state =
  case rootSessionStateDisposition state of
    CustodyCancellationRequested _ -> Right ()
    CustodyRunning -> Left RootSessionCancellationNotRequested

validateRootSessionState
  :: RootSessionState -> Either RootSessionError RootSessionState
validateRootSessionState state =
  case rootSessionInvariantViolations state of
    [] -> Right state
    violations -> Left (RootSessionInvariantFailure violations)

phaseInvariantViolations
  :: RootSessionBinding
  -> RootSessionPhase
  -> [RootSessionInvariantViolation]
phaseInvariantViolations binding phase =
  case phase of
    RootSessionRevokeStaleAccessors inventory remaining ->
      inventoryViolations binding inventory
        ++ [ RootSessionRemainingAccessorNotInventoried accessor
           | accessor <- remaining
           , accessor `notElem` rootAccessorInventoryAccessors inventory
           ]
        ++ [ RootSessionInventoryNotCanonical
           | remaining /= sort (nub remaining)
           ]
    RootSessionStableAbsencePending inventory ->
      inventoryViolations binding inventory
    RootSessionGenerateRootPending absence ->
      absenceGenerationViolations binding absence
    RootSessionGenerateRootInFlight absence ->
      absenceGenerationViolations binding absence
    RootSessionAccessorJournalPending absence _ ->
      absenceGenerationViolations binding absence
    RootSessionBaselineReadBack _ receipt ->
      baselineViolations binding receipt
    RootSessionCurrentRevocationPending _ receipt ->
      maybe [] (baselineViolations binding) receipt
    RootSessionCurrentRevoked _ receipt ->
      maybe [] (baselineViolations binding) receipt
    RootSessionCurrentAbsencePending _ receipt ->
      maybe [] (baselineViolations binding) receipt
    RootSessionClosed receipt absence ->
      baselineViolations binding receipt
        ++ currentAbsenceViolations binding absence
    RootSessionCancelledClean absence ->
      absenceGenerationViolations binding absence
    RootSessionCancelIncompleteGenerateRoot -> []
    RootSessionInventoryStaleAccessors -> []
    RootSessionAccessorJournaled _ -> []
    RootSessionBaselineMutationPending _ -> []
    RootSessionBaselineApplied _ -> []

inventoryViolations
  :: RootSessionBinding
  -> RootAccessorInventory
  -> [RootSessionInvariantViolation]
inventoryViolations binding inventory =
  [ RootSessionInventoryGenerationDiffers expected actual
  | actual /= expected
  ]
    ++ [RootSessionInventoryNotCanonical | not (inventoryIsCanonical inventory)]
 where
  expected = rootSessionStorageGeneration binding
  actual = rootAccessorInventoryGeneration inventory

absenceGenerationViolations
  :: RootSessionBinding
  -> AccessorAbsenceAttestation
  -> [RootSessionInvariantViolation]
absenceGenerationViolations binding =
  inventoryViolations binding . accessorAbsenceInventory

baselineViolations
  :: RootSessionBinding
  -> BaselineReadBackReceipt
  -> [RootSessionInvariantViolation]
baselineViolations binding receipt =
  [ RootSessionBaselineIdDiffers expectedId actualId
  | actualId /= expectedId
  ]
    ++ [ RootSessionBaselineGenerationDiffers expectedGeneration actualGeneration
       | actualGeneration /= expectedGeneration
       ]
    ++ [ RootSessionBaselineTargetsDiffer (baselineReadBackTargets receipt)
       | baselineReadBackTargets receipt /= requiredRootBaselineTargets
       ]
 where
  expectedId = rootSessionBindingId binding
  actualId = baselineReadBackSessionId receipt
  expectedGeneration = rootSessionStorageGeneration binding
  actualGeneration = baselineReadBackStorageGeneration receipt

currentAbsenceViolations
  :: RootSessionBinding
  -> AccessorAbsenceAttestation
  -> [RootSessionInvariantViolation]
currentAbsenceViolations binding absence =
  absenceGenerationViolations binding absence
    ++ case rootAccessorInventoryAccessors (accessorAbsenceInventory absence) of
      [_] -> []
      accessors ->
        case accessors of
          accessor : _ -> [RootSessionCurrentAbsenceDiffers accessor]
          [] -> [RootSessionInventoryNotCanonical]

rootSessionPhaseName :: RootSessionPhase -> String
rootSessionPhaseName phase =
  case phase of
    RootSessionCancelIncompleteGenerateRoot ->
      "RootSessionCancelIncompleteGenerateRoot"
    RootSessionInventoryStaleAccessors -> "RootSessionInventoryStaleAccessors"
    RootSessionRevokeStaleAccessors _ _ -> "RootSessionRevokeStaleAccessors"
    RootSessionStableAbsencePending _ -> "RootSessionStableAbsencePending"
    RootSessionGenerateRootPending _ -> "RootSessionGenerateRootPending"
    RootSessionGenerateRootInFlight _ -> "RootSessionGenerateRootInFlight"
    RootSessionAccessorJournalPending _ _ ->
      "RootSessionAccessorJournalPending"
    RootSessionAccessorJournaled _ -> "RootSessionAccessorJournaled"
    RootSessionBaselineMutationPending _ ->
      "RootSessionBaselineMutationPending"
    RootSessionBaselineApplied _ -> "RootSessionBaselineApplied"
    RootSessionBaselineReadBack _ _ -> "RootSessionBaselineReadBack"
    RootSessionCurrentRevocationPending _ _ ->
      "RootSessionCurrentRevocationPending"
    RootSessionCurrentRevoked _ _ -> "RootSessionCurrentRevoked"
    RootSessionCurrentAbsencePending _ _ ->
      "RootSessionCurrentAbsencePending"
    RootSessionClosed _ _ -> "RootSessionClosed"
    RootSessionCancelledClean _ -> "RootSessionCancelledClean"

-- Normal provisioner login -------------------------------------------------

data ProvisionerSessionPhase
  = ProvisionerLoggedOut
  | ProvisionerLoginPending
  | ProvisionerLoggedIn !ProvisionerLoginReceipt
  deriving stock (Eq, Show)

data ProvisionerSessionState = ProvisionerSessionState
  { provisionerSessionRootCompletion :: !RootSessionCompletion
  , provisionerSessionPhase :: !ProvisionerSessionPhase
  }
  deriving stock (Eq, Show)

data ProvisionerSessionCommand
  = ArmProvisionerLogin
  | ConfirmProvisionerLogin !ProvisionerLoginReceipt
  | InvalidateProvisionerLogin
  deriving stock (Eq, Show)

data ProvisionerSessionEvent
  = ProvisionerLoginArmed
  | ProvisionerLoginConfirmed !ProvisionerLoginReceipt
  | ProvisionerLoginInvalidated
  deriving stock (Eq, Show)

data ProvisionerSessionPlan
  = ProvisionerPlanArmLogin !VaultStorageGeneration
  | ProvisionerPlanLogin !VaultStorageGeneration
  | ProvisionerPlanReady !ProvisionerLoginReceipt
  deriving stock (Eq, Show)

data ProvisionerSessionError
  = ProvisionerSessionPhaseRefusal
      !ProvisionerSessionPhase
      !ProvisionerSessionEvent
  | ProvisionerSessionGenerationMismatch
      !VaultStorageGeneration
      !VaultStorageGeneration
  deriving stock (Eq, Show)

newProvisionerSessionState
  :: RootSessionCompletion -> ProvisionerSessionState
newProvisionerSessionState completion =
  ProvisionerSessionState
    { provisionerSessionRootCompletion = completion
    , provisionerSessionPhase = ProvisionerLoggedOut
    }

decideProvisionerSession
  :: ProvisionerSessionState
  -> ProvisionerSessionCommand
  -> Either ProvisionerSessionError ProvisionerSessionEvent
decideProvisionerSession state command = do
  let event = provisionerEventForCommand command
  _ <- evolveProvisionerSession state event
  pure event

evolveProvisionerSession
  :: ProvisionerSessionState
  -> ProvisionerSessionEvent
  -> Either ProvisionerSessionError ProvisionerSessionState
evolveProvisionerSession state event =
  case (provisionerSessionPhase state, event) of
    (ProvisionerLoggedOut, ProvisionerLoginArmed) ->
      Right state {provisionerSessionPhase = ProvisionerLoginPending}
    (ProvisionerLoginPending, ProvisionerLoginConfirmed receipt) -> do
      requireProvisionerGeneration state receipt
      Right state {provisionerSessionPhase = ProvisionerLoggedIn receipt}
    (_, ProvisionerLoginInvalidated) ->
      Right state {provisionerSessionPhase = ProvisionerLoggedOut}
    (phase, _) -> Left (ProvisionerSessionPhaseRefusal phase event)

applyProvisionerSessionCommand
  :: ProvisionerSessionState
  -> ProvisionerSessionCommand
  -> Either ProvisionerSessionError ProvisionerSessionState
applyProvisionerSessionCommand state command = do
  event <- decideProvisionerSession state command
  evolveProvisionerSession state event

planProvisionerSession :: ProvisionerSessionState -> ProvisionerSessionPlan
planProvisionerSession state =
  case provisionerSessionPhase state of
    ProvisionerLoggedOut -> ProvisionerPlanArmLogin generation
    ProvisionerLoginPending -> ProvisionerPlanLogin generation
    ProvisionerLoggedIn receipt -> ProvisionerPlanReady receipt
 where
  generation = provisionerSessionGeneration state

restartProvisionerSession :: ProvisionerSessionState -> ProvisionerSessionState
restartProvisionerSession state =
  state {provisionerSessionPhase = ProvisionerLoggedOut}

provisionerSessionIsReady :: ProvisionerSessionState -> Bool
provisionerSessionIsReady state =
  case provisionerSessionPhase state of
    ProvisionerLoggedIn _ -> True
    _ -> False

provisionerEventForCommand
  :: ProvisionerSessionCommand -> ProvisionerSessionEvent
provisionerEventForCommand command =
  case command of
    ArmProvisionerLogin -> ProvisionerLoginArmed
    ConfirmProvisionerLogin receipt -> ProvisionerLoginConfirmed receipt
    InvalidateProvisionerLogin -> ProvisionerLoginInvalidated

requireProvisionerGeneration
  :: ProvisionerSessionState
  -> ProvisionerLoginReceipt
  -> Either ProvisionerSessionError ()
requireProvisionerGeneration state receipt
  | actual == expected = Right ()
  | otherwise = Left (ProvisionerSessionGenerationMismatch expected actual)
 where
  expected = provisionerSessionGeneration state
  actual = provisionerLoginStorageGeneration receipt

provisionerSessionGeneration
  :: ProvisionerSessionState -> VaultStorageGeneration
provisionerSessionGeneration =
  rootSessionStorageGeneration
    . completedRootSessionBinding
    . provisionerSessionRootCompletion

-- Flat Vault seal observation ---------------------------------------------

data VaultSealPhase
  = VaultSealUnobserved
  | VaultStorageObservedEmpty
  | VaultObservedInitializedSealed
  | VaultObservedInitializedUnsealed
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data VaultSealState = VaultSealState
  { vaultSealStorageGeneration :: !VaultStorageGeneration
  , vaultSealPhase :: !VaultSealPhase
  }
  deriving stock (Eq, Show)

data VaultSealObservation
  = ObserveVaultStorageEmpty !VaultStorageGeneration
  | ObserveVaultInitializedSealed !VaultStorageGeneration
  | ObserveVaultInitializedUnsealed !VaultStorageGeneration
  deriving stock (Eq, Show)

data VaultSealError
  = VaultSealGenerationMismatch
      !VaultStorageGeneration
      !VaultStorageGeneration
  | VaultSealEstablishedStorageResetRefused
  deriving stock (Eq, Show)

newVaultSealState :: VaultStorageGeneration -> VaultSealState
newVaultSealState generation =
  VaultSealState
    { vaultSealStorageGeneration = generation
    , vaultSealPhase = VaultSealUnobserved
    }

observeVaultSeal
  :: VaultSealState
  -> VaultSealObservation
  -> Either VaultSealError VaultSealState
observeVaultSeal state observation = do
  let observedGeneration = vaultSealObservationGeneration observation
  if observedGeneration /= vaultSealStorageGeneration state
    then
      Left
        ( VaultSealGenerationMismatch
            (vaultSealStorageGeneration state)
            observedGeneration
        )
    else case (vaultSealPhase state, observation) of
      (VaultObservedInitializedSealed, ObserveVaultStorageEmpty _) ->
        Left VaultSealEstablishedStorageResetRefused
      (VaultObservedInitializedUnsealed, ObserveVaultStorageEmpty _) ->
        Left VaultSealEstablishedStorageResetRefused
      (_, ObserveVaultStorageEmpty _) ->
        Right state {vaultSealPhase = VaultStorageObservedEmpty}
      (_, ObserveVaultInitializedSealed _) ->
        Right state {vaultSealPhase = VaultObservedInitializedSealed}
      (_, ObserveVaultInitializedUnsealed _) ->
        Right state {vaultSealPhase = VaultObservedInitializedUnsealed}

vaultSealIsUnsealed :: VaultSealState -> Bool
vaultSealIsUnsealed state =
  vaultSealPhase state == VaultObservedInitializedUnsealed

vaultSealObservationGeneration
  :: VaultSealObservation -> VaultStorageGeneration
vaultSealObservationGeneration observation =
  case observation of
    ObserveVaultStorageEmpty generation -> generation
    ObserveVaultInitializedSealed generation -> generation
    ObserveVaultInitializedUnsealed generation -> generation

-- Observation-only post-unseal handoff ------------------------------------

data PostUnsealHandoffPhase
  = PostUnsealHandoffWaiting
  | PostUnsealHandoffObservationPending
  | PostUnsealHandoffObserved !PostUnsealHandoffReceipt
  deriving stock (Eq, Show)

data PostUnsealHandoffState = PostUnsealHandoffState
  { postUnsealHandoffStateGeneration :: !VaultStorageGeneration
  , postUnsealHandoffStatePhase :: !PostUnsealHandoffPhase
  }
  deriving stock (Eq, Show)

data PostUnsealHandoffCommand
  = ArmPostUnsealHandoffObservation
  | ConfirmPostUnsealHandoffObserved !PostUnsealHandoffReceipt
  deriving stock (Eq, Show)

data PostUnsealHandoffEvent
  = PostUnsealHandoffObservationArmed
  | PostUnsealHandoffObservationConfirmed !PostUnsealHandoffReceipt
  deriving stock (Eq, Show)

-- | There is intentionally no plan that grants, writes, or transfers
-- authority.  The Broker may only observe that the named consumer is ready.
data PostUnsealHandoffPlan
  = PostUnsealHandoffPlanArmObservation !VaultStorageGeneration
  | PostUnsealHandoffPlanObserveConsumer
      !VaultStorageGeneration
      !PostUnsealConsumer
  | PostUnsealHandoffPlanComplete !PostUnsealHandoffReceipt
  deriving stock (Eq, Show)

data PostUnsealHandoffError
  = PostUnsealHandoffPhaseRefusal
      !PostUnsealHandoffPhase
      !PostUnsealHandoffEvent
  | PostUnsealHandoffGenerationMismatch
      !VaultStorageGeneration
      !VaultStorageGeneration
  deriving stock (Eq, Show)

newPostUnsealHandoffState
  :: VaultStorageGeneration -> PostUnsealHandoffState
newPostUnsealHandoffState generation =
  PostUnsealHandoffState
    { postUnsealHandoffStateGeneration = generation
    , postUnsealHandoffStatePhase = PostUnsealHandoffWaiting
    }

decidePostUnsealHandoff
  :: PostUnsealHandoffState
  -> PostUnsealHandoffCommand
  -> Either PostUnsealHandoffError PostUnsealHandoffEvent
decidePostUnsealHandoff state command = do
  let event = postUnsealHandoffEventForCommand command
  _ <- evolvePostUnsealHandoff state event
  pure event

evolvePostUnsealHandoff
  :: PostUnsealHandoffState
  -> PostUnsealHandoffEvent
  -> Either PostUnsealHandoffError PostUnsealHandoffState
evolvePostUnsealHandoff state event =
  case (postUnsealHandoffStatePhase state, event) of
    (PostUnsealHandoffWaiting, PostUnsealHandoffObservationArmed) ->
      Right state {postUnsealHandoffStatePhase = PostUnsealHandoffObservationPending}
    (PostUnsealHandoffObservationPending, PostUnsealHandoffObservationConfirmed receipt) -> do
      requireHandoffGeneration state receipt
      Right state {postUnsealHandoffStatePhase = PostUnsealHandoffObserved receipt}
    (phase, _) -> Left (PostUnsealHandoffPhaseRefusal phase event)

applyPostUnsealHandoffCommand
  :: PostUnsealHandoffState
  -> PostUnsealHandoffCommand
  -> Either PostUnsealHandoffError PostUnsealHandoffState
applyPostUnsealHandoffCommand state command = do
  event <- decidePostUnsealHandoff state command
  evolvePostUnsealHandoff state event

planPostUnsealHandoff :: PostUnsealHandoffState -> PostUnsealHandoffPlan
planPostUnsealHandoff state =
  case postUnsealHandoffStatePhase state of
    PostUnsealHandoffWaiting ->
      PostUnsealHandoffPlanArmObservation generation
    PostUnsealHandoffObservationPending ->
      PostUnsealHandoffPlanObserveConsumer
        generation
        PostUnsealLifecycleAuthority
    PostUnsealHandoffObserved receipt ->
      PostUnsealHandoffPlanComplete receipt
 where
  generation = postUnsealHandoffStateGeneration state

postUnsealHandoffIsObserved :: PostUnsealHandoffState -> Bool
postUnsealHandoffIsObserved state =
  case postUnsealHandoffStatePhase state of
    PostUnsealHandoffObserved _ -> True
    _ -> False

postUnsealHandoffEventForCommand
  :: PostUnsealHandoffCommand -> PostUnsealHandoffEvent
postUnsealHandoffEventForCommand command =
  case command of
    ArmPostUnsealHandoffObservation -> PostUnsealHandoffObservationArmed
    ConfirmPostUnsealHandoffObserved receipt ->
      PostUnsealHandoffObservationConfirmed receipt

requireHandoffGeneration
  :: PostUnsealHandoffState
  -> PostUnsealHandoffReceipt
  -> Either PostUnsealHandoffError ()
requireHandoffGeneration state receipt
  | actual == expected = Right ()
  | otherwise = Left (PostUnsealHandoffGenerationMismatch expected actual)
 where
  expected = postUnsealHandoffStateGeneration state
  actual = postUnsealHandoffGeneration receipt

-- Product projection -------------------------------------------------------

-- | One bounded active-operation projection.  Durable records for other
-- children remain in their owning stores; the Broker fold admits at most one
-- active child custody or recovery operation alongside the root lifecycle.
data BootstrapProjection = BootstrapProjection
  { bootstrapProjectionRootInit :: !RootInitState
  , bootstrapProjectionVaultSeal :: !VaultSealState
  , bootstrapProjectionRootSession :: !(Maybe RootSessionState)
  , bootstrapProjectionProvisioner :: !(Maybe ProvisionerSessionState)
  , bootstrapProjectionChildCustody :: !(Maybe ChildCustodyState)
  , bootstrapProjectionChildRecovery :: !(Maybe ChildRecoveryState)
  , bootstrapProjectionHandoff :: !PostUnsealHandoffState
  }
  deriving stock (Eq, Show)

data BootstrapProjectionPlan
  = BootstrapProjectionPlanInvalid
      ![BootstrapProjectionInvariantViolation]
  | BootstrapProjectionPlanRootInit !RootInitPlan
  | BootstrapProjectionPlanObserveVaultSeal !VaultStorageGeneration
  | BootstrapProjectionPlanChildCustody !ChildCustodyPlan
  | BootstrapProjectionPlanChildRecovery !ChildRecoveryPlan
  | BootstrapProjectionPlanStartRootSession !RecoveryCustodyReceipt
  | BootstrapProjectionPlanRootSession !RootSessionPlan
  | BootstrapProjectionPlanStartProvisioner !RootSessionCompletion
  | BootstrapProjectionPlanProvisioner !ProvisionerSessionPlan
  | BootstrapProjectionPlanHandoff !PostUnsealHandoffPlan
  | BootstrapProjectionPlanComplete !PostUnsealHandoffReceipt
  deriving stock (Eq, Show)

data BootstrapProjectionInvariantViolation
  = BootstrapProjectionSealGenerationDiffers
  | BootstrapProjectionHandoffGenerationDiffers
  | BootstrapProjectionRootSessionBeforeCustody
  | BootstrapProjectionRootSessionCustodyDiffers
  | BootstrapProjectionRootSessionInvariant
      !RootSessionInvariantViolation
  | BootstrapProjectionProvisionerBeforeBaseline
  | BootstrapProjectionProvisionerCompletionDiffers
  | BootstrapProjectionProvisionerGenerationDiffers
  | BootstrapProjectionChildCustodyGenerationDiffers
  | BootstrapProjectionChildRecoveryGenerationDiffers
  | BootstrapProjectionConcurrentChildMutations
  | BootstrapProjectionConcurrentRootAndChildAuthority
  | BootstrapProjectionHandoffBeforeUnseal
  | BootstrapProjectionHandoffBeforeBaseline
  | BootstrapProjectionHandoffBeforeProvisionerLogin
  | BootstrapProjectionHandoffReceiptGenerationDiffers
  deriving stock (Eq, Show)

mkBootstrapProjection
  :: RootInitState
  -> VaultSealState
  -> Either [BootstrapProjectionInvariantViolation] BootstrapProjection
mkBootstrapProjection rootInit sealState =
  validateBootstrapProjection
    BootstrapProjection
      { bootstrapProjectionRootInit = rootInit
      , bootstrapProjectionVaultSeal = sealState
      , bootstrapProjectionRootSession = Nothing
      , bootstrapProjectionProvisioner = Nothing
      , bootstrapProjectionChildCustody = Nothing
      , bootstrapProjectionChildRecovery = Nothing
      , bootstrapProjectionHandoff = newPostUnsealHandoffState generation
      }
 where
  generation = rootInitStorageGeneration (rootInitStateBinding rootInit)

planBootstrapProjection :: BootstrapProjection -> BootstrapProjectionPlan
planBootstrapProjection projection =
  case bootstrapProjectionInvariantViolations projection of
    violations@(_ : _) -> BootstrapProjectionPlanInvalid violations
    []
      | not (rootInitIsComplete rootInit) ->
          BootstrapProjectionPlanRootInit (planRootInit rootInit)
      | not (vaultSealIsUnsealed sealState) ->
          BootstrapProjectionPlanObserveVaultSeal generation
      | Just custody <- activeChildCustody projection ->
          BootstrapProjectionPlanChildCustody (planChildCustody custody)
      | Just recovery <- activeChildRecovery projection ->
          BootstrapProjectionPlanChildRecovery (planChildRecovery recovery)
      | otherwise -> planRootAndHandoff projection
 where
  rootInit = bootstrapProjectionRootInit projection
  sealState = bootstrapProjectionVaultSeal projection
  generation = rootInitStorageGeneration (rootInitStateBinding rootInit)

bootstrapProjectionInvariantViolations
  :: BootstrapProjection -> [BootstrapProjectionInvariantViolation]
bootstrapProjectionInvariantViolations projection =
  generationViolations
    ++ rootSessionViolations
    ++ provisionerViolations
    ++ childViolations
    ++ handoffViolations
 where
  rootInit = bootstrapProjectionRootInit projection
  rootGeneration = rootInitStorageGeneration (rootInitStateBinding rootInit)
  rootCustody = rootInitCustodyReceipt rootInit
  rootSession = bootstrapProjectionRootSession projection
  provisioner = bootstrapProjectionProvisioner projection
  handoff = bootstrapProjectionHandoff projection

  generationViolations =
    [ BootstrapProjectionSealGenerationDiffers
    | vaultSealStorageGeneration (bootstrapProjectionVaultSeal projection)
        /= rootGeneration
    ]
      ++ [ BootstrapProjectionHandoffGenerationDiffers
         | postUnsealHandoffStateGeneration handoff /= rootGeneration
         ]

  rootSessionViolations =
    case rootSession of
      Nothing -> []
      Just session ->
        [BootstrapProjectionRootSessionBeforeCustody | rootCustody == Nothing]
          ++ [ BootstrapProjectionRootSessionCustodyDiffers
             | Just custody <- [rootCustody]
             , rootSessionBindingCustody (rootSessionStateBinding session) /= custody
             ]
          ++ map
            BootstrapProjectionRootSessionInvariant
            (rootSessionInvariantViolations session)

  provisionerViolations =
    case provisioner of
      Nothing -> []
      Just session ->
        case rootSession >>= rootSessionCompletion of
          Nothing -> [BootstrapProjectionProvisionerBeforeBaseline]
          Just completion ->
            [ BootstrapProjectionProvisionerCompletionDiffers
            | provisionerSessionRootCompletion session /= completion
            ]
              ++ case provisionerSessionPhase session of
                ProvisionerLoggedIn receipt ->
                  [ BootstrapProjectionProvisionerGenerationDiffers
                  | provisionerLoginStorageGeneration receipt /= rootGeneration
                  ]
                _ -> []

  childViolations =
    [ BootstrapProjectionChildCustodyGenerationDiffers
    | Just custody <- [bootstrapProjectionChildCustody projection]
    , childCustodyStorageGeneration (childCustodyStateBinding custody)
        /= rootGeneration
    ]
      ++ [ BootstrapProjectionChildRecoveryGenerationDiffers
         | Just recovery <- [bootstrapProjectionChildRecovery projection]
         , childCustodyStorageGeneration (childRecoveryStateBinding recovery)
             /= rootGeneration
         ]
      ++ [ BootstrapProjectionConcurrentChildMutations
         | activeChildCustody projection /= Nothing
         , activeChildRecovery projection /= Nothing
         ]
      ++ [ BootstrapProjectionConcurrentRootAndChildAuthority
         | maybe False rootSessionIsActive rootSession
         , activeChildCustody projection /= Nothing
             || activeChildRecovery projection /= Nothing
         ]

  handoffViolations =
    case postUnsealHandoffStatePhase handoff of
      PostUnsealHandoffWaiting -> []
      phase ->
        [ BootstrapProjectionHandoffBeforeUnseal
        | not (vaultSealIsUnsealed (bootstrapProjectionVaultSeal projection))
        ]
          ++ [ BootstrapProjectionHandoffBeforeBaseline
             | maybe True (not . rootSessionIsComplete) rootSession
             ]
          ++ [ BootstrapProjectionHandoffBeforeProvisionerLogin
             | maybe True (not . provisionerSessionIsReady) provisioner
             ]
          ++ case phase of
            PostUnsealHandoffObserved receipt ->
              [ BootstrapProjectionHandoffReceiptGenerationDiffers
              | postUnsealHandoffGeneration receipt /= rootGeneration
              ]
            _ -> []

bootstrapProjectionIsComplete :: BootstrapProjection -> Bool
bootstrapProjectionIsComplete projection =
  null (bootstrapProjectionInvariantViolations projection)
    && postUnsealHandoffIsObserved (bootstrapProjectionHandoff projection)

validateBootstrapProjection
  :: BootstrapProjection
  -> Either [BootstrapProjectionInvariantViolation] BootstrapProjection
validateBootstrapProjection projection =
  case bootstrapProjectionInvariantViolations projection of
    [] -> Right projection
    violations -> Left violations

planRootAndHandoff :: BootstrapProjection -> BootstrapProjectionPlan
planRootAndHandoff projection =
  case bootstrapProjectionRootSession projection of
    Nothing -> startRootSession
    Just session
      | rootSessionIsCancelledClean session -> startRootSession
      | not (rootSessionIsComplete session) ->
          BootstrapProjectionPlanRootSession (planRootSession session)
      | otherwise ->
          case rootSessionCompletion session of
            Nothing -> startRootSession
            Just completion -> planProvisionerAndHandoff completion
 where
  startRootSession =
    case rootInitCustodyReceipt (bootstrapProjectionRootInit projection) of
      Just custody -> BootstrapProjectionPlanStartRootSession custody
      Nothing ->
        BootstrapProjectionPlanInvalid
          [BootstrapProjectionRootSessionBeforeCustody]

  planProvisionerAndHandoff completion =
    case bootstrapProjectionProvisioner projection of
      Nothing -> BootstrapProjectionPlanStartProvisioner completion
      Just provisioner
        | not (provisionerSessionIsReady provisioner) ->
            BootstrapProjectionPlanProvisioner
              (planProvisionerSession provisioner)
        | otherwise ->
            case planPostUnsealHandoff (bootstrapProjectionHandoff projection) of
              PostUnsealHandoffPlanComplete receipt ->
                BootstrapProjectionPlanComplete receipt
              plan -> BootstrapProjectionPlanHandoff plan

rootInitCustodyReceipt :: RootInitState -> Maybe RecoveryCustodyReceipt
rootInitCustodyReceipt state =
  case rootInitStatePhase state of
    RootRecoveryCustodyDurable _ receipt -> Just receipt
    _ -> Nothing

activeChildCustody :: BootstrapProjection -> Maybe ChildCustodyState
activeChildCustody projection =
  case bootstrapProjectionChildCustody projection of
    Just state | not (childCustodyIsComplete state) -> Just state
    _ -> Nothing

activeChildRecovery :: BootstrapProjection -> Maybe ChildRecoveryState
activeChildRecovery projection =
  case bootstrapProjectionChildRecovery projection of
    Just state | not (childRecoveryIsComplete state) -> Just state
    _ -> Nothing

rootSessionIsActive :: RootSessionState -> Bool
rootSessionIsActive state =
  not (rootSessionIsComplete state || rootSessionIsCancelledClean state)
