{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The bounded legacy-adoption plan-and-apply lane.
--
-- The observer, the planner, the permit admission and the receipt repository
-- all existed before this module and none of them had a caller.  They were
-- caller-less because the authorization half had no surface: the doctrine
-- requires an explicit admin permit over the exact rendered plan digest,
-- receipt-committed and independently read back before any cleanup mutation,
-- and nothing minted one.  This module is that surface's engine, and
-- "Prodbox.ControlPlane.LegacyAdoptionCompositionRoot" supplies its production
-- sources.
--
-- __Two passes, one digest.__  'renderLegacyAdoptionCandidatePlan' observes and
-- renders; 'applyConfirmedLegacyAdoption' observes and renders /again/ and then
-- confirms against the digest the operator typed.  The second observation is
-- the point rather than a cost: a plan re-rendered after the provider facts
-- changed is a different plan, its digest differs, and the confirmation refuses
-- the one the operator was never shown.  Carrying the first pass's plan forward
-- instead would authorize a document nobody re-checked against the world.
--
-- __Discovery never widens.__  Every observation goes through the closed
-- read-only intent vocabulary at the adoption dispatch purpose, and the planner
-- refuses a missing, extra, duplicated, partial, unobservable or ambiguous
-- family rather than adopting a shorter one.  This module adds no arm that
-- could soften any of those.
--
-- __Where the lane stops.__  It ends at an independently read-back
-- 'AdoptedCleanupOwnership', which is cleanup-only ownership and has no
-- type-level path into a create.  Consuming its identity allowlist into a
-- destroy belongs to the single-writer cutover; this lane issues no mutation
-- and holds no capability that could.
module Prodbox.Lifecycle.Teardown.LegacyAdoptionLane
  ( AdoptableLegacyStack (..)
  , adoptableLegacyStackKey
  , adoptableLegacyStackName
  , LegacyAdoptionSources (..)
  , LegacyAdoptionRequest (..)
  , RenderedLegacyAdoptionPlan (..)
  , LegacyAdoptionLaneError (..)
  , renderLegacyAdoptionLaneError
  , renderLegacyAdoptionCandidatePlan
  , applyConfirmedLegacyAdoption
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.LegacyAdoptionManifestRepository
  ( AdoptedCleanupOwnership
  , LegacyAdoptionManifestRepository
  , LegacyAdoptionManifestRepositoryError
  , commitAndReadBackConfirmedLegacyAdoptionManifest
  )
import Prodbox.Lifecycle.Authority.AdminAction (PermitFreshness)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork (ProviderStackConfig)
import Prodbox.Lifecycle.Teardown.LegacyAdoptionObserver
  ( LegacyAdoptionObservationError
  , LegacyAdoptionProviderObserver
  , observeAndPlanLegacyAdoption
  )
import Prodbox.Lifecycle.Teardown.LegacyAdoptionPlan
  ( AdminLegacyAdoptionPermitRefusal
  , AdminLegacyAdoptionPermitRequest
  , LegacyAdoptionConfirmationRefusal
  , LegacyAdoptionPlan
  , LegacyAdoptionPlanEntry
  , admitAdminLegacyAdoptionPermit
  , confirmLegacyAdoptionPlan
  , legacyAdoptionPlanDigestOf
  , legacyAdoptionPlanEntries
  , renderLegacyAdoptionPlan
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.OwnershipManifest
  ( LegacyAdoptionPlanDigest
  )

-- | The per-run registered stacks a bounded adoption may recover.
--
-- Closed on purpose, and the omission is the point: the retained long-lived
-- @aws-ses@ stack is not here.  Adopting it would produce a cleanup-only
-- ownership record for the one stack nothing may reap, and a per-run adoption
-- of the stack a per-run sweep must never touch is the same category error the
-- run-scoped provider tag deliberately keeps @aws-ses@ out of.
data AdoptableLegacyStack
  = AdoptAwsEks
  | AdoptAwsEksSubzone
  | AdoptAwsTest
  deriving (Bounded, Enum, Eq, Ord, Show)

adoptableLegacyStackKey :: AdoptableLegacyStack -> RegisteredResourceKey
adoptableLegacyStackKey stack = case stack of
  AdoptAwsEks -> AwsEksKey
  AdoptAwsEksSubzone -> AwsEksSubzoneKey
  AdoptAwsTest -> AwsTestKey

-- | The operator-facing stack name, matching the @prodbox aws stack@ group
-- this adoption is reached through.
adoptableLegacyStackName :: AdoptableLegacyStack -> Text
adoptableLegacyStackName stack = case stack of
  AdoptAwsEks -> "eks"
  AdoptAwsEksSubzone -> "aws-subzone"
  AdoptAwsTest -> "test"

-- | The three seams the lane needs, injected together.
--
-- Freshness is an observation rather than a clock read inside the admission,
-- for the same reason the long-lived aggregate permit takes one: the admission
-- fold stays pure and the interpreter owns the authority clock.
data LegacyAdoptionSources m = LegacyAdoptionSources
  { legacyAdoptionObserver :: !(LegacyAdoptionProviderObserver m)
  , legacyAdoptionRepository :: !(LegacyAdoptionManifestRepository m)
  , observeLegacyAdoptionPermitFreshness :: !(m PermitFreshness)
  }

-- | What one adoption is about: the registered stack, the exact scope its
-- family is observed under, the observation revision the dispatch key derived,
-- and the stack's Provider configuration.
data LegacyAdoptionRequest = LegacyAdoptionRequest
  { legacyAdoptionRequestStackKey :: !RegisteredResourceKey
  , legacyAdoptionRequestScope :: !ObservationEvidenceScope
  , legacyAdoptionRequestRevision :: !ObservationRevision
  , legacyAdoptionRequestProviderConfig :: !ProviderStackConfig
  }

-- | The document an operator is shown and the digest they confirm, together
-- with the entries so a caller can render them without re-parsing the
-- document.  The digest is taken over the document rather than over a summary
-- of it, so confirming the digest confirms those bytes.
data RenderedLegacyAdoptionPlan = RenderedLegacyAdoptionPlan
  { renderedLegacyAdoptionStackKey :: !RegisteredResourceKey
  , renderedLegacyAdoptionDocument :: !Text
  , renderedLegacyAdoptionDigest :: !LegacyAdoptionPlanDigest
  , renderedLegacyAdoptionEntries :: ![LegacyAdoptionPlanEntry]
  }
  deriving (Eq, Show)

-- | Every way the lane can refuse, in the order the lane runs.
data LegacyAdoptionLaneError
  = LegacyAdoptionLaneObservationRefused !LegacyAdoptionObservationError
  | LegacyAdoptionLanePermitRefused !AdminLegacyAdoptionPermitRefusal
  | LegacyAdoptionLaneConfirmationRefused !LegacyAdoptionConfirmationRefusal
  | LegacyAdoptionLaneReceiptRefused !LegacyAdoptionManifestRepositoryError
  deriving (Eq, Show)

renderLegacyAdoptionLaneError :: LegacyAdoptionLaneError -> Text
renderLegacyAdoptionLaneError err = case err of
  LegacyAdoptionLaneObservationRefused detail ->
    "legacy adoption observation refused: " <> Text.pack (show detail)
  LegacyAdoptionLanePermitRefused detail ->
    "legacy adoption permit refused: " <> Text.pack (show detail)
  LegacyAdoptionLaneConfirmationRefused detail ->
    "legacy adoption confirmation refused: " <> Text.pack (show detail)
  LegacyAdoptionLaneReceiptRefused detail ->
    "legacy adoption receipt refused: " <> Text.pack (show detail)

-- | Observe the closed family and render the candidate plan.  No permit, no
-- commit, and no mutation: this is the document half of the protocol.
renderLegacyAdoptionCandidatePlan
  :: (Monad m)
  => LegacyAdoptionSources m
  -> CleanupSurfaceWitness surface
  -> LegacyAdoptionRequest
  -> m (Either LegacyAdoptionLaneError RenderedLegacyAdoptionPlan)
renderLegacyAdoptionCandidatePlan sources surface request = do
  planned <- observeAndPlan sources surface request
  pure $ case planned of
    Left err -> Left (LegacyAdoptionLaneObservationRefused err)
    Right plan ->
      Right
        RenderedLegacyAdoptionPlan
          { renderedLegacyAdoptionStackKey = legacyAdoptionRequestStackKey request
          , renderedLegacyAdoptionDocument = renderLegacyAdoptionPlan plan
          , renderedLegacyAdoptionDigest = legacyAdoptionPlanDigestOf plan
          , renderedLegacyAdoptionEntries = legacyAdoptionPlanEntries plan
          }

-- | Re-observe, re-render, admit the operator's permit, confirm it against the
-- plan this pass produced, then receipt-commit and independently read back.
--
-- The permit request is the operator's submission and carries the digest they
-- confirmed; it is not authorization until 'admitAdminLegacyAdoptionPermit'
-- accepts it and 'confirmLegacyAdoptionPlan' binds it to these exact bytes.
applyConfirmedLegacyAdoption
  :: (Monad m)
  => LegacyAdoptionSources m
  -> CleanupSurfaceWitness surface
  -> LegacyAdoptionRequest
  -> AdminLegacyAdoptionPermitRequest
  -> m (Either LegacyAdoptionLaneError AdoptedCleanupOwnership)
applyConfirmedLegacyAdoption sources surface request permitRequest = do
  planned <- observeAndPlan sources surface request
  case planned of
    Left err -> pure (Left (LegacyAdoptionLaneObservationRefused err))
    Right plan -> do
      freshness <- observeLegacyAdoptionPermitFreshness sources
      case admitAdminLegacyAdoptionPermit freshness permitRequest of
        Left err -> pure (Left (LegacyAdoptionLanePermitRefused err))
        Right permit -> case confirmLegacyAdoptionPlan permit plan of
          Left err -> pure (Left (LegacyAdoptionLaneConfirmationRefused err))
          Right confirmed -> do
            committed <-
              commitAndReadBackConfirmedLegacyAdoptionManifest
                (legacyAdoptionRepository sources)
                surface
                confirmed
            pure (either (Left . LegacyAdoptionLaneReceiptRefused) Right committed)

observeAndPlan
  :: (Monad m)
  => LegacyAdoptionSources m
  -> CleanupSurfaceWitness surface
  -> LegacyAdoptionRequest
  -> m (Either LegacyAdoptionObservationError (LegacyAdoptionPlan surface))
observeAndPlan sources surface request =
  observeAndPlanLegacyAdoption
    surface
    (legacyAdoptionRequestStackKey request)
    (legacyAdoptionRequestScope request)
    (legacyAdoptionRequestRevision request)
    (legacyAdoptionRequestProviderConfig request)
    (legacyAdoptionObserver sources)
