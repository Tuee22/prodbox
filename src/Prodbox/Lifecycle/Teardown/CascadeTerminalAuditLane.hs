{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.36: the production lane that takes a cascade's terminal escape
-- audit and acts on it.
--
-- Every piece of this protocol existed and none of it ran.  The freeze
-- transition, the reservation, the audit kernel, its Provider query boundary,
-- the durable receipt, and the ordered revocation each landed with their own
-- proofs, and each was reachable only from a test: nothing in production issued
-- @AuthorityControlFreezeProviderAdmissionForCascadeAudit@,
-- @AuthorityControlRecordCascadeTerminalAuditReceipt@, or
-- @AuthorityControlRevokeCascadeProviderCredential@.  This module is the
-- composition that drives all three, in the one order the epoch admits.
--
-- __The order is enforced by the Authority, not by this module.__  The epoch
-- refuses a record with no fence, a revocation with no record, a revocation
-- under another binding, and a revocation over a verdict that is not clean.  A
-- caller therefore cannot reach revocation by composing these steps
-- differently; what this lane adds is that the steps are taken at all, and that
-- the two destructive halves are not even /attempted/ when the audit did not
-- come back clean.
--
-- __A verdict that is not clean still records.__  An escape or a blind spot is
-- exactly the result an operator needs durably, and it is also the result that
-- makes the credential worth keeping: the credential is what a retry or an
-- investigation runs as.  The lane therefore ends at the record for those two
-- verdicts and says so in its own outcome, rather than treating "did not
-- revoke" as a failure.
module Prodbox.Lifecycle.Teardown.CascadeTerminalAuditLane
  ( CascadeTerminalAuditLaneBoundary (..)
  , CascadeTerminalAuditLaneOutcome (..)
  , cascadeTerminalAuditLaneVerdict
  , CascadeTerminalAuditLaneRefusal (..)
  , renderCascadeTerminalAuditLaneRefusal
  , runCascadeTerminalAuditLane
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityControlPayload
      ( AuthorityControlFreezeProviderAdmissionForCascadeAudit
      , AuthorityControlRecordCascadeTerminalAuditReceipt
      )
  )
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
  ( CascadeAuditFreezeBinding
  , CascadeTerminalAuditVerdict (..)
  , ProviderAdmissionEpochError
  , cascadeTerminalAuditReceiptVerdict
  )
import Prodbox.Lifecycle.CredentialProvisioner.JointIamDisposition
  ( JointIamDispositionAuthorization
  )
import Prodbox.Lifecycle.Decommission.TargetTombstone
  ( TargetGenerationTombstoneCommand
  )
import Prodbox.Lifecycle.Teardown.CascadeCredentialRevocation
  ( CascadeCredentialRevocationBoundary (..)
  , CascadeCredentialRevocationRefusal
  , renderCascadeCredentialRevocationRefusal
  , revokeCascadeProviderCredential
  )
import Prodbox.Lifecycle.Teardown.CascadeTerminalAudit
  ( CascadeTerminalAuditBoundary
  , CascadeTerminalAuditRefusal
  , observeCascadeTerminalAudit
  , renderCascadeTerminalAuditRefusal
  )
import Prodbox.Lifecycle.Teardown.CascadeTerminalAuditAdapter
  ( cascadeTerminalAuditReceiptFor
  )
import Prodbox.Lifecycle.Teardown.Graph (CompiledDesiredAbsenceProgram)
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface (Cascade)
  , ObservationRevision
  )
import Prodbox.Lifecycle.Teardown.RetainedInventory (RetainedNameBinding)

-- | Everything the lane is allowed to touch.
--
-- The revocation half is a whole 'CascadeCredentialRevocationBoundary' rather
-- than two loose effects, so the lane cannot destroy an IAM family without also
-- being able to end the material and record the result.
data CascadeTerminalAuditLaneBoundary m = CascadeTerminalAuditLaneBoundary
  { cascadeAuditLaneSubmitControl
      :: AuthorityControlPayload -> m (Either Text Text)
  , cascadeAuditLaneQueries :: !(CascadeTerminalAuditBoundary m)
  -- ^ The audit's own Provider query boundary. In production this is
  -- @providerCascadeTerminalAuditBoundary@ over the dispatch that executes at
  -- the @ProviderTerminalAudit@ purpose.
  , cascadeAuditLaneRevocation
      :: !(CascadeCredentialRevocationBoundary m)
  }

-- | What one complete lane run produced.
--
-- Both arms are successes: the audit was taken and its verdict is durable. They
-- differ in whether that verdict licensed ending the credential, which is a
-- fact about the audit rather than about this run\'s health.
data CascadeTerminalAuditLaneOutcome
  = -- | The audit came back clean, the verdict is durable, and the cascade\'s
    -- Provider credential is gone on both sides. Carries the Authority\'s own
    -- summary of the revocation.
    CascadeAuditRecordedAndCredentialRevoked !Text
  | -- | The audit found an escape or could not see everything. The verdict is
    -- durable and the credential deliberately survives, because it is what a
    -- retry or an investigation runs as.
    CascadeAuditRecordedWithoutRevocation !CascadeTerminalAuditVerdict
  deriving (Eq, Show)

-- | The verdict a completed lane run recorded.
cascadeTerminalAuditLaneVerdict
  :: CascadeTerminalAuditLaneOutcome -> CascadeTerminalAuditVerdict
cascadeTerminalAuditLaneVerdict outcome = case outcome of
  CascadeAuditRecordedAndCredentialRevoked _ -> CascadeTerminalAuditReceiptClean
  CascadeAuditRecordedWithoutRevocation verdict -> verdict

data CascadeTerminalAuditLaneRefusal
  = -- | Provider admission could not be fenced, so the audit was never taken.
    -- Nothing is destroyed and the cascade is unchanged.
    CascadeAuditLaneFreezeRefused !Text
  | -- | The fence is in place and the audit could not be taken at all. The
    -- fence stays: lifting it here would admit fresh Provider work into a
    -- cascade whose terminal state is unknown.
    CascadeAuditLaneNotTaken !CascadeTerminalAuditRefusal
  | -- | The audit was taken and its observation could not become a receipt.
    CascadeAuditLaneReceiptInvalid !ProviderAdmissionEpochError
  | -- | The audit was taken and its verdict is not durable. Nothing is
    -- destroyed, because the record is what a revocation is entitled to rely
    -- on.
    CascadeAuditLaneRecordRefused !Text
  | -- | The verdict is clean and durable and the revocation refused. The audit
    -- result survives regardless of how far the revocation got.
    CascadeAuditLaneRevocationRefused !CascadeCredentialRevocationRefusal
  deriving (Eq, Show)

renderCascadeTerminalAuditLaneRefusal
  :: CascadeTerminalAuditLaneRefusal -> Text
renderCascadeTerminalAuditLaneRefusal refusal = case refusal of
  CascadeAuditLaneFreezeRefused detail ->
    "Provider admission could not be fenced for the cascade terminal audit, \
    \so no audit was taken: "
      <> detail
  CascadeAuditLaneNotTaken detail ->
    "the cascade terminal audit could not be taken: "
      <> Text.pack (renderCascadeTerminalAuditRefusal detail)
  CascadeAuditLaneReceiptInvalid detail ->
    "the cascade terminal audit was taken and could not become a durable \
    \receipt: "
      <> Text.pack (show detail)
  CascadeAuditLaneRecordRefused detail ->
    "the cascade terminal audit was taken and its verdict was not recorded, \
    \so nothing was revoked: "
      <> detail
  CascadeAuditLaneRevocationRefused detail ->
    "the cascade terminal audit is clean and durable and the Provider \
    \credential was not revoked: "
      <> renderCascadeCredentialRevocationRefusal detail

-- | Fence, audit, record, and — only over a clean verdict — revoke.
runCascadeTerminalAuditLane
  :: (Monad m)
  => CascadeTerminalAuditLaneBoundary m
  -> CascadeAuditFreezeBinding
  -> RetainedNameBinding
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> ObservationRevision
  -> JointIamDispositionAuthorization
  -> TargetGenerationTombstoneCommand
  -> m
       ( Either
           CascadeTerminalAuditLaneRefusal
           CascadeTerminalAuditLaneOutcome
       )
runCascadeTerminalAuditLane
  boundary
  binding
  retained
  compiled
  revision
  authorization
  command = do
    frozen <-
      cascadeAuditLaneSubmitControl
        boundary
        (AuthorityControlFreezeProviderAdmissionForCascadeAudit binding)
    case frozen of
      Left detail -> pure (Left (CascadeAuditLaneFreezeRefused detail))
      Right _ -> takeAudit
   where
    takeAudit = do
      observed <-
        observeCascadeTerminalAudit
          (cascadeAuditLaneQueries boundary)
          retained
          compiled
          revision
      case observed of
        Left detail -> pure (Left (CascadeAuditLaneNotTaken detail))
        Right observation -> case cascadeTerminalAuditReceiptFor observation of
          Left detail -> pure (Left (CascadeAuditLaneReceiptInvalid detail))
          Right receipt -> record receipt

    record receipt = do
      recorded <-
        cascadeAuditLaneSubmitControl
          boundary
          (AuthorityControlRecordCascadeTerminalAuditReceipt binding receipt)
      case recorded of
        Left detail -> pure (Left (CascadeAuditLaneRecordRefused detail))
        Right _ -> case cascadeTerminalAuditReceiptVerdict receipt of
          CascadeTerminalAuditReceiptClean -> revoke
          -- Not a failure, and deliberately not an attempt: destroying the
          -- credential here would remove what an investigation runs as.
          verdict ->
            pure (Right (CascadeAuditRecordedWithoutRevocation verdict))

    revoke = do
      revoked <-
        revokeCascadeProviderCredential
          (cascadeAuditLaneRevocation boundary)
          binding
          authorization
          command
      pure $ case revoked of
        Left detail -> Left (CascadeAuditLaneRevocationRefused detail)
        Right summary -> Right (CascadeAuditRecordedAndCredentialRevoked summary)
