{-# LANGUAGE OverloadedStrings #-}

-- | The production consumer of a registered stack's lifecycle generation.
--
-- The 2026-08-15 counterexample's composition failure was a selection failure:
-- with every durable creation record keyed by the surface and run scope that
-- wrote it, a later cleanup run had no key with which to name the stack an
-- earlier run created, so selection fell back to whatever residue happened to
-- be visible — a global tag answer copied onto three per-stack observations.
--
-- This module is the replacement selection path.  A cleanup run presents only
-- facts it can prove: the registered key it intends to act on, the Authority's
-- own read-back of the Provider AWS-scope proof, its local foundation, and its
-- own run scope and cleanup surface.  From those the current cycle is reached
-- by two authoritative reads — the series cursor, then the generation record
-- the cursor's ordinal addresses — and by nothing else.  There is no parameter
-- through which visible residue, a creating run's scope, or a caller-asserted
-- account could enter.
--
-- Refusal is the default.  A series that was never opened, a store that cannot
-- be observed, a record found under a key that is not its own, and a surface
-- that may not select this registered identity are four distinct refusals, and
-- none of them degrade into "nothing is there".
module Prodbox.ControlPlane.RegisteredStackCleanupSelection
  ( RegisteredStackCleanupBoundary (..)
  , lifecycleAuthorityRegisteredStackCleanupBoundary
  , RegisteredStackCleanupError (..)
  , renderRegisteredStackCleanupError
  , selectRegisteredStackForCleanup
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProviderAwsScopeReceipt
  ( AuthorityProviderAwsScopeReader
  , ProviderAwsScopeReceiptError
  , readBackVerifiedAuthorityProviderAwsScope
  )
import Prodbox.ControlPlane.RegisteredStackGenerationRepository
  ( RegisteredStackGenerationError
  , RegisteredStackGenerationRepository
  , StackGenerationCursorRepository
  , renderRegisteredStackGenerationError
  , selectCurrentRegisteredStackGeneration
  )
import Prodbox.Lifecycle.Authority.Submission (OperationId)
import Prodbox.Lifecycle.Teardown.Model
  ( ObservationEvidenceScope
  , RegisteredResourceKey
  , evidenceCleanupSurface
  , evidenceDurableRunScope
  , evidenceLinuxRke2Foundation
  )
import Prodbox.Lifecycle.Teardown.StackGeneration
  ( ProvenProviderAwsSession
  , SelectedStackGeneration
  , providerAwsSessionFromAuthorityProof
  )

-- | Everything the cleanup selector is allowed to touch.
data RegisteredStackCleanupBoundary m = RegisteredStackCleanupBoundary
  { registeredStackCleanupProveScope
      :: OperationId
      -> m (Either ProviderAwsScopeReceiptError ProvenProviderAwsSession)
  -- ^ See the note on the producer's field of the same shape.
  , registeredStackCleanupCursors :: StackGenerationCursorRepository m
  , registeredStackCleanupGenerations :: RegisteredStackGenerationRepository m
  }

lifecycleAuthorityRegisteredStackCleanupBoundary
  :: (Monad m)
  => AuthorityProviderAwsScopeReader m
  -> StackGenerationCursorRepository m
  -> RegisteredStackGenerationRepository m
  -> RegisteredStackCleanupBoundary m
lifecycleAuthorityRegisteredStackCleanupBoundary scopeReader =
  RegisteredStackCleanupBoundary
    ( fmap (fmap providerAwsSessionFromAuthorityProof)
        . readBackVerifiedAuthorityProviderAwsScope scopeReader
    )

data RegisteredStackCleanupError
  = -- | The Provider AWS-scope proof could not be read back, so the account and
    -- region that address the series are unknown.  Cleanup refuses; it does not
    -- fall back to a configured or asserted scope.
    RegisteredStackCleanupScopeUnproven !ProviderAwsScopeReceiptError
  | -- | The cursor or the generation record refused.
    RegisteredStackCleanupGenerationRefused !RegisteredStackGenerationError
  deriving (Eq, Show)

renderRegisteredStackCleanupError :: RegisteredStackCleanupError -> Text
renderRegisteredStackCleanupError err = case err of
  RegisteredStackCleanupScopeUnproven detail ->
    "no Provider AWS-scope proof was retained for this cleanup run, so the \
    \registered stack's generation series cannot be addressed: "
      <> Text.pack (show detail)
  RegisteredStackCleanupGenerationRefused detail ->
    renderRegisteredStackGenerationError detail

-- | Select the current generation of one registered stack for cleanup.
--
-- @providerScopeOperation@ names the admitted @ObserveProviderAwsScope@
-- operation this cleanup run submitted.  It is deliberately this run's own
-- operation rather than the creating run's: the account and region it proves
-- are run-invariant facts, so a cleanup run reaches the same series key the
-- creating run used without ever learning anything about that run.
selectRegisteredStackForCleanup
  :: (Monad m)
  => RegisteredStackCleanupBoundary m
  -> RegisteredResourceKey
  -> OperationId
  -- ^ this run's admitted Provider AWS-scope observation operation
  -> ObservationEvidenceScope
  -> m (Either RegisteredStackCleanupError SelectedStackGeneration)
selectRegisteredStackForCleanup
  boundary
  resourceKey
  providerScopeOperation
  cleanupScope = do
    scopeResult <-
      registeredStackCleanupProveScope boundary providerScopeOperation
    case scopeResult of
      Left err -> pure (Left (RegisteredStackCleanupScopeUnproven err))
      Right session -> do
        selected <-
          selectCurrentRegisteredStackGeneration
            (registeredStackCleanupCursors boundary)
            (registeredStackCleanupGenerations boundary)
            resourceKey
            session
            (evidenceLinuxRke2Foundation cleanupScope)
            (evidenceDurableRunScope cleanupScope)
            (evidenceCleanupSurface cleanupScope)
        pure (either (Left . RegisteredStackCleanupGenerationRefused) Right selected)
