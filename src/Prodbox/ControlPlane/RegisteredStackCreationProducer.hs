{-# LANGUAGE OverloadedStrings #-}

-- | The production producer of a registered stack's lifecycle generation.
--
-- Sprint @4.84@ landed the run-invariant generation identity, its durable slot,
-- and the ordinal succession a producer needs to pick a cycle.  What was
-- missing was a production path that actually reserves a cycle and writes the
-- record: the generation existed and was proven, but every admitted create
-- still wrote only the surface-and-run-keyed creation binding, which a later
-- cleanup run cannot address.
--
-- This module is that path.  One admitted create produces, in order:
--
--   1. an exact observation of the admitted create operation, read back from
--      the Authority's own admission aggregate rather than taken from the
--      request;
--   2. an Authority-read-back Provider AWS-scope proof, so the account and
--      region in the generation key are ones the Provider Worker observed under
--      an admitted operation — never ones the caller asserted;
--   3. a reserved cycle, idempotent in the admitted create operation, so a
--      retried create cannot burn a second ordinal;
--   4. the committed generation record at its run-invariant slot, settled by
--      independent read-back; and
--   5. the existing creation binding, which stays in place until the cutover
--      deletes it.
--
-- The generation is committed __before__ the creation binding.  The two records
-- answer different questions — "which cycle of this stack is current" versus
-- "which run and surface created it" — and only the first is addressable by a
-- later cleanup run.  Committing it first means a create that fails midway
-- leaves the addressable record present and the run-scoped one absent, which is
-- recoverable; the reverse leaves a stack whose cycle no later run can name.
module Prodbox.ControlPlane.RegisteredStackCreationProducer
  ( RegisteredStackCreationBoundary (..)
  , lifecycleAuthorityRegisteredStackCreationBoundary
  , RegisteredStackCreation
  , registeredStackCreationGeneration
  , registeredStackCreationReservation
  , registeredStackCreationBinding
  , RegisteredStackCreationError (..)
  , renderRegisteredStackCreationError
  , commitRegisteredStackCreation
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository
  )
import Prodbox.ControlPlane.AwsStackCreationBindingRepository
  ( AwsStackCreationBindingError
  , AwsStackCreationBindingRepository
  , AwsStackCreationCommitResult (..)
  , ObservedAwsStackCreationOperation
  , commitAwsStackCreationBindingAttempt
  , observeAuthorityAwsStackCreationOperation
  )
import Prodbox.ControlPlane.ProviderAwsScopeReceipt
  ( AuthorityProviderAwsScopeReader
  , ProviderAwsScopeReceiptError
  , readBackVerifiedAuthorityProviderAwsScope
  )
import Prodbox.ControlPlane.RegisteredStackGenerationRepository
  ( CommittedRegisteredStackGeneration
  , RegisteredStackGenerationError (RegisteredStackGenerationRecordInvalid)
  , RegisteredStackGenerationRepository
  , ReservedStackGeneration (..)
  , StackGenerationCursorRepository
  , commitRegisteredStackGenerationWithRepair
  , renderRegisteredStackGenerationError
  , reserveNextStackGeneration
  )
import Prodbox.Lifecycle.Authority.Submission (OperationId)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork (ProviderRevision)
import Prodbox.Lifecycle.Teardown.Model
  ( ObservationEvidenceScope
  , evidenceCleanupSurface
  , evidenceDurableRunScope
  , evidenceLinuxRke2Foundation
  )
import Prodbox.Lifecycle.Teardown.StackGeneration
  ( ProvenProviderAwsSession
  , establishRegisteredStackGeneration
  , providerAwsSessionFromAuthorityProof
  )

-- | Everything the producer is allowed to touch.  Assembled by
-- 'lifecycleAuthorityRegisteredStackCreationBoundary' from the Authority's own
-- admission aggregate and retained repositories; there is no field through
-- which a caller could supply an account, a region, or a cycle.
data RegisteredStackCreationBoundary m = RegisteredStackCreationBoundary
  { registeredStackCreationObserveCreate
      :: ProviderRevision
      -> OperationId
      -> m
           ( Either
               AwsStackCreationBindingError
               ObservedAwsStackCreationOperation
           )
  , registeredStackCreationProveScope
      :: OperationId
      -> m (Either ProviderAwsScopeReceiptError ProvenProviderAwsSession)
  -- ^ Prove the AWS scope of one admitted observation operation.  Production
  -- binds this to the Authority's own read-back
  -- ('lifecycleAuthorityRegisteredStackCreationBoundary'); the field exists so
  -- the producer can also be driven from a Provider-side proof without an
  -- Authority aggregate.  Neither form lets a caller state an account.
  , registeredStackCreationCursors :: StackGenerationCursorRepository m
  , registeredStackCreationGenerations :: RegisteredStackGenerationRepository m
  , registeredStackCreationBindings :: AwsStackCreationBindingRepository m
  }

lifecycleAuthorityRegisteredStackCreationBoundary
  :: (Monad m)
  => AuthorityAdmissionRepository m revision
  -> AuthorityProviderAwsScopeReader m
  -> StackGenerationCursorRepository m
  -> RegisteredStackGenerationRepository m
  -> AwsStackCreationBindingRepository m
  -> RegisteredStackCreationBoundary m
lifecycleAuthorityRegisteredStackCreationBoundary
  admissionRepository
  scopeReader
  cursors
  generations
  bindings =
    RegisteredStackCreationBoundary
      { registeredStackCreationObserveCreate =
          observeAuthorityAwsStackCreationOperation admissionRepository
      , registeredStackCreationProveScope =
          fmap (fmap providerAwsSessionFromAuthorityProof)
            . readBackVerifiedAuthorityProviderAwsScope scopeReader
      , registeredStackCreationCursors = cursors
      , registeredStackCreationGenerations = generations
      , registeredStackCreationBindings = bindings
      }

-- | The complete outcome of one admitted registered-stack creation.
-- Constructor private: a caller cannot assemble one from parts it did not
-- obtain from the producer.
data RegisteredStackCreation = RegisteredStackCreation
  { internalCreationGeneration :: !CommittedRegisteredStackGeneration
  , internalCreationReservation :: !ReservedStackGeneration
  , internalCreationBinding :: !AwsStackCreationCommitResult
  }

registeredStackCreationGeneration
  :: RegisteredStackCreation -> CommittedRegisteredStackGeneration
registeredStackCreationGeneration = internalCreationGeneration

registeredStackCreationReservation
  :: RegisteredStackCreation -> ReservedStackGeneration
registeredStackCreationReservation = internalCreationReservation

registeredStackCreationBinding
  :: RegisteredStackCreation -> AwsStackCreationCommitResult
registeredStackCreationBinding = internalCreationBinding

data RegisteredStackCreationError
  = -- | The admitted create operation could not be observed, or is not an
    -- exact registered-stack reconcile.
    RegisteredStackCreationOperationUnobservable !AwsStackCreationBindingError
  | -- | The Provider AWS-scope proof could not be read back from the Authority
    -- aggregate.  Creation refuses rather than falling back to the account and
    -- region the request asserted.
    RegisteredStackCreationScopeUnproven !ProviderAwsScopeReceiptError
  | -- | Reservation or the generation commit refused.
    RegisteredStackCreationGenerationRefused !RegisteredStackGenerationError
  | -- | The generation is committed but the run-scoped creation binding is
    -- not, so the creation is incomplete.  Carries the binding disposition.
    RegisteredStackCreationBindingIncomplete !AwsStackCreationCommitResult
  deriving (Eq, Show)

renderRegisteredStackCreationError :: RegisteredStackCreationError -> Text
renderRegisteredStackCreationError err = case err of
  RegisteredStackCreationOperationUnobservable detail ->
    "the admitted registered-stack create could not be observed: "
      <> Text.pack (show detail)
  RegisteredStackCreationScopeUnproven detail ->
    "no Provider AWS-scope proof was retained for this creation: "
      <> Text.pack (show detail)
  RegisteredStackCreationGenerationRefused detail ->
    "the registered-stack generation refused: "
      <> renderRegisteredStackGenerationError detail
  RegisteredStackCreationBindingIncomplete disposition ->
    "the registered-stack generation was committed but its run-scoped creation \
    \binding was not: "
      <> Text.pack (show disposition)

-- | Reserve, establish, and commit the generation for one admitted create, then
-- commit the run-scoped creation binding.
--
-- @providerScopeOperation@ names the admitted @ObserveProviderAwsScope@
-- operation whose retained receipt carries the account and region.  It is a
-- separate operation from the create, which is why the caller must name it;
-- what the caller cannot do is state its content, because the receipt is read
-- back from the Authority aggregate and verified there.
commitRegisteredStackCreation
  :: (Monad m)
  => RegisteredStackCreationBoundary m
  -> OperationId
  -- ^ the admitted create operation
  -> OperationId
  -- ^ the admitted Provider AWS-scope observation operation
  -> ProviderRevision
  -> ObservationEvidenceScope
  -> m (Either RegisteredStackCreationError RegisteredStackCreation)
commitRegisteredStackCreation
  boundary
  createOperation
  providerScopeOperation
  currentRevision
  creationScope = do
    observedResult <-
      registeredStackCreationObserveCreate
        boundary
        currentRevision
        createOperation
    case observedResult of
      Left err -> pure (Left (RegisteredStackCreationOperationUnobservable err))
      Right observed -> do
        scopeResult <-
          registeredStackCreationProveScope boundary providerScopeOperation
        case scopeResult of
          Left err -> pure (Left (RegisteredStackCreationScopeUnproven err))
          Right session -> withProvenScope observed session
   where
    foundation = evidenceLinuxRke2Foundation creationScope

    withProvenScope observed session = do
      reserved <-
        reserveNextStackGeneration
          (registeredStackCreationCursors boundary)
          observed
          session
          foundation
      case reserved of
        Left err -> pure (Left (RegisteredStackCreationGenerationRefused err))
        Right reservation ->
          case establishRegisteredStackGeneration
            observed
            session
            foundation
            (evidenceDurableRunScope creationScope)
            (evidenceCleanupSurface creationScope)
            (reservedStackGenerationOrdinal reservation) of
            Left err ->
              pure
                ( Left
                    ( RegisteredStackCreationGenerationRefused
                        (RegisteredStackGenerationRecordInvalid err)
                    )
                )
            Right generation -> do
              committed <-
                commitRegisteredStackGenerationWithRepair
                  (registeredStackCreationGenerations boundary)
                  generation
              case committed of
                Left err ->
                  pure (Left (RegisteredStackCreationGenerationRefused err))
                Right durable -> do
                  binding <-
                    commitAwsStackCreationBindingAttempt
                      (registeredStackCreationBindings boundary)
                      observed
                      creationScope
                  pure (bindingOutcome durable reservation binding)

    bindingOutcome durable reservation binding = case binding of
      Left err -> Left (RegisteredStackCreationOperationUnobservable err)
      Right disposition
        | committedBinding disposition ->
            Right
              RegisteredStackCreation
                { internalCreationGeneration = durable
                , internalCreationReservation = reservation
                , internalCreationBinding = disposition
                }
        | otherwise ->
            Left (RegisteredStackCreationBindingIncomplete disposition)

    committedBinding disposition = case disposition of
      AwsStackCreationCommitCreated -> True
      AwsStackCreationCommitExactReplay -> True
      AwsStackCreationCommitConflict -> False
      AwsStackCreationCommitResponseLost {} -> False
      AwsStackCreationCommitUnavailable {} -> False
