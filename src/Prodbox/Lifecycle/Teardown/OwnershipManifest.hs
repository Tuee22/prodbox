{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure ownership-manifest and bounded legacy-adoption proof boundaries.
-- Write-ahead and cleanup-only provenance remain distinct in the type index;
-- external observations stay flat and can enter authority only through the
-- exact binding and completeness checks in this module.
module Prodbox.Lifecycle.Teardown.OwnershipManifest
  ( OwnershipManifestPurpose (..)
  , OwnershipManifestPurposeValue (..)
  , OwnershipManifestDigest
  , ownershipManifestDigestText
  , OwnershipManifestEntry (..)
  , RegisteredOwnershipEdge
  , ownershipEdgeStackKey
  , ownershipEdgeResourceKey
  , registeredOwnershipEdges
  , controllerOwnedFamilies
  , registeredStackClusters
  , controllerOwnedFamiliesWithoutRegisteredStack
  , projectRegisteredOwnershipEdge
  , initialManifestEntries
  , WriteAheadManifestIntent
  , mkWriteAheadManifestIntent
  , initialWriteAheadManifestWrite
  , appendObservedIdentitiesToWriteAheadManifest
  , OwnershipManifestWrite
  , ownershipManifestWriteStackKey
  , ownershipManifestWriteScope
  , ownershipManifestWriteDigest
  , ownershipManifestWriteEntries
  , VerifiedOwnershipManifest
  , verifiedOwnershipManifestStackKey
  , verifiedOwnershipManifestScope
  , verifiedOwnershipManifestPurpose
  , verifiedOwnershipManifestVersion
  , verifiedOwnershipManifestProvenance
  , verifiedOwnershipManifestDigest
  , verifiedOwnershipManifestEntries
  , OwnershipManifestTarget
  , mkOwnershipManifestTarget
  , ownershipManifestTargetStackKey
  , ownershipManifestTargetScope
  , CompleteOwnershipManifest
  , completeOwnershipManifestStackKey
  , completeOwnershipManifestScope
  , completeOwnershipManifestPurpose
  , completeOwnershipManifestVersion
  , completeOwnershipManifestProvenance
  , completeOwnershipManifestDigest
  , completeOwnershipManifestLegacyPlanDigest
  , DurableCompleteOwnershipManifest
  , captureDurableCompleteOwnershipManifest
  , durableCompleteOwnershipManifestBytes
  , durableCompleteOwnershipManifestStackKey
  , durableCompleteOwnershipManifestScope
  , DurableCompleteOwnershipManifestError (..)
  , maximumDurableCompleteOwnershipManifestBytes
  , DurableWriteAheadOwnershipManifest
  , captureDurableWriteAheadOwnershipManifest
  , durableWriteAheadOwnershipManifestBytes
  , durableWriteAheadOwnershipManifestStackKey
  , durableWriteAheadOwnershipManifestScope
  , ObservedDurableWriteAheadOwnershipManifest
  , observedDurableWriteAheadOwnershipManifest
  , bindObservedDurableWriteAheadOwnershipManifestForCleanup
  , bindConfirmedLegacyAdoptionManifestForCleanup
  , ConfirmedLegacyAdoptionManifestWrite
  , confirmedLegacyAdoptionManifestWrite
  , confirmedLegacyAdoptionManifestWriteStackKey
  , confirmedLegacyAdoptionManifestWriteScope
  , confirmedLegacyAdoptionManifestWritePlanDigest
  , confirmedLegacyAdoptionManifestWriteReceiptBytes
  , completeConfirmedLegacyAdoptionManifestReadBack
  , DurableWriteAheadOwnershipManifestError (..)
  , maximumDurableWriteAheadOwnershipManifestBytes
  , OwnershipManifestDecisionEvidence
  , OwnershipManifestDecisionView (..)
  , ownershipManifestObservationOnly
  , ownershipManifestDecisionView
  , captureCompleteOwnershipManifestEvidence
  , restoreCompleteOwnershipManifestEvidence
  , ownershipManifestDecisionStackKey
  , ownershipManifestDecisionScope
  , ownershipManifestDecisionEntryIdentities
  , LegacyAdoptionPlanDigest
  , legacyAdoptionPlanDigestText
  , OwnershipManifestError (..)
  )
where

import Control.Monad (when)
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.List (nub, sort, sortOn)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Lifecycle.Teardown.LegacyAdoptionPlan
  ( ConfirmedLegacyAdoptionPlan
  , LegacyAdoptionPlanEntry (..)
  , confirmedLegacyAdoptionPlan
  , confirmedLegacyAdoptionPlanDigest
  , legacyAdoptionPlanEntries
  , legacyAdoptionPlanScope
  , legacyAdoptionPlanStackKey
  , legacyAdoptionPlanSurface
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.OwnershipManifest.Internal
  ( CompleteOwnershipManifest
  , DurableCompleteOwnershipManifest
  , DurableCompleteOwnershipManifestError (..)
  , DurableOwnershipManifestEntryValue (..)
  , DurableWriteAheadOwnershipManifest
  , DurableWriteAheadOwnershipManifestError (..)
  , LegacyAdoptionPlanDigest (..)
  , ObservedDurableWriteAheadOwnershipManifest
  , OwnershipManifestDigest (..)
  , OwnershipManifestPurposeValue (..)
  , RegisteredOwnershipEdge
  , SomeCompleteOwnershipManifest (..)
  , captureCompleteOwnershipManifestWithEntries
  , captureDurableCompleteOwnershipManifest
  , captureDurableWriteAheadOwnershipManifestInternal
  , completeOwnershipManifestDigest
  , completeOwnershipManifestLegacyPlanDigest
  , completeOwnershipManifestProvenance
  , completeOwnershipManifestPurpose
  , completeOwnershipManifestScope
  , completeOwnershipManifestStackKey
  , completeOwnershipManifestVersion
  , controllerOwnedFamilies
  , controllerOwnedFamiliesWithoutRegisteredStack
  , durableCompleteOwnershipManifestBytes
  , durableCompleteOwnershipManifestScope
  , durableCompleteOwnershipManifestStackKey
  , durableWriteAheadOwnershipManifestBytes
  , durableWriteAheadOwnershipManifestDigest
  , durableWriteAheadOwnershipManifestEntries
  , durableWriteAheadOwnershipManifestScope
  , durableWriteAheadOwnershipManifestStackKey
  , legacyAdoptionPlanDigestText
  , maximumDurableCompleteOwnershipManifestBytes
  , maximumDurableWriteAheadOwnershipManifestBytes
  , mkCompleteOwnershipManifestInternal
  , observedDurableWriteAheadOwnershipManifest
  , observedDurableWriteAheadOwnershipManifestProvenance
  , observedDurableWriteAheadOwnershipManifestValue
  , observedDurableWriteAheadOwnershipManifestVersion
  , ownershipEdgeResourceKey
  , ownershipEdgeStackKey
  , ownershipManifestDigestText
  , registeredOwnershipEdges
  , registeredStackClusters
  , restoreCompleteOwnershipManifestWithEntries
  )
import Prodbox.Lifecycle.Teardown.Registry
import Prodbox.Lifecycle.Teardown.ScopeCodec
  ( ObservationEvidenceScopeFields (ObservationEvidenceScopeFields)
  , observationEvidenceScopeFields
  , scopeIdentityText
  )

data OwnershipManifestPurpose
  = WriteAheadOwnership
  | LegacyAdoptionOwnership CleanupSurface

data OwnershipManifestEntry = OwnershipManifestEntry
  { ownershipManifestEntryKey :: !RegisteredResourceKey
  , ownershipManifestEntryCoordinateDigest :: !ManagedResourceCoordinateDigest
  , ownershipManifestEntryObservedIdentities :: ![ObservedResourceIdentity]
  }
  deriving (Eq, Ord, Show)

projectRegisteredOwnershipEdge
  :: RegisteredResourceKey
  -> RegisteredResourceKey
  -> Either OwnershipManifestError RegisteredOwnershipEdge
projectRegisteredOwnershipEdge stackKey resourceKey =
  case [ edge
       | edge <- registeredOwnershipEdges
       , ownershipEdgeStackKey edge == stackKey
       , ownershipEdgeResourceKey edge == resourceKey
       ] of
    [edge] -> Right edge
    _ -> Left (OwnershipEdgeNotRegistered stackKey resourceKey)

data ManifestBinding = ManifestBinding
  { manifestBindingStackKey :: !RegisteredResourceKey
  , manifestBindingSurface :: !CleanupSurface
  , manifestBindingScope :: !ObservationEvidenceScope
  , manifestBindingCoordinateDigest :: !ManagedResourceCoordinateDigest
  }
  deriving (Eq, Show)

data WriteAheadManifestIntent (surface :: CleanupSurface)
  = WriteAheadManifestIntent !ManifestBinding ![OwnershipManifestEntry]

mkWriteAheadManifestIntent
  :: CleanupSurfaceWitness surface
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> Either OwnershipManifestError (WriteAheadManifestIntent surface)
mkWriteAheadManifestIntent surface stackKey scope = do
  binding <- manifestBindingFor ReconcileDesiredPresent surface stackKey scope
  entries <- initialManifestEntries stackKey
  Right (WriteAheadManifestIntent binding entries)

data
  OwnershipManifestWrite
    (purpose :: OwnershipManifestPurpose)
    (surface :: CleanupSurface)
  = OwnershipManifestWrite
      !OwnershipManifestPurposeValue
      !ManifestBinding
      !OwnershipManifestDigest
      ![OwnershipManifestEntry]

ownershipManifestWriteStackKey
  :: OwnershipManifestWrite purpose surface -> RegisteredResourceKey
ownershipManifestWriteStackKey (OwnershipManifestWrite _ binding _ _) =
  manifestBindingStackKey binding

ownershipManifestWriteScope
  :: OwnershipManifestWrite purpose surface -> ObservationEvidenceScope
ownershipManifestWriteScope (OwnershipManifestWrite _ binding _ _) =
  manifestBindingScope binding

ownershipManifestWriteDigest
  :: OwnershipManifestWrite purpose surface -> OwnershipManifestDigest
ownershipManifestWriteDigest (OwnershipManifestWrite _ _ digest _) = digest

ownershipManifestWriteEntries
  :: OwnershipManifestWrite purpose surface -> [OwnershipManifestEntry]
ownershipManifestWriteEntries (OwnershipManifestWrite _ _ _ entries) = entries

initialWriteAheadManifestWrite
  :: WriteAheadManifestIntent surface
  -> OwnershipManifestWrite 'WriteAheadOwnership surface
initialWriteAheadManifestWrite (WriteAheadManifestIntent binding entries) =
  manifestWrite WriteAheadOwnershipValue binding entries

-- | Sprint 7.41: the manifest gains the exact identities the provider returned.
--
-- An append is a /narrowing/, never a new claim. The entry set is the one the
-- write-ahead record already committed — same keys, same coordinate digests,
-- in the same canonical order — and the only thing this adds is the observed
-- identity list on each entry. A key the intent never declared is refused
-- rather than added, because a create that reports having made something it
-- did not say it was about to make is the condition the write-ahead record
-- exists to make impossible, not a fact to record.
--
-- An append with nothing to append is also refused. A completion manifest with
-- no identity on any entry is byte-identical in shape to the write-ahead one
-- and would claim, to a later read-back, that the create returned and made
-- nothing — which is exactly the false reassurance the 2026-09-08 leak needed
-- somebody to believe.
appendObservedIdentitiesToWriteAheadManifest
  :: WriteAheadManifestIntent surface
  -> [(RegisteredResourceKey, [ObservedResourceIdentity])]
  -> Either OwnershipManifestError (OwnershipManifestWrite 'WriteAheadOwnership surface)
appendObservedIdentitiesToWriteAheadManifest
  (WriteAheadManifestIntent binding entries)
  observed = do
    mapM_ requireDeclared observedKeys
    when
      (all (null . snd) observed)
      (Left (OwnershipManifestAppendedIdentitiesEmpty declaredKeys))
    Right (manifestWrite WriteAheadOwnershipValue binding appended)
   where
    declaredKeys = map ownershipManifestEntryKey entries
    observedKeys = map fst observed

    requireDeclared key
      | key `elem` declaredKeys = Right ()
      | otherwise =
          Left (OwnershipManifestAppendedKeyUndeclared key declaredKeys)

    appended =
      [ entry
          { ownershipManifestEntryObservedIdentities =
              ownershipManifestEntryObservedIdentities entry
                ++ concat
                  [ identities
                  | (key, identities) <- observed
                  , key == ownershipManifestEntryKey entry
                  ]
          }
      | entry <- entries
      ]

captureDurableWriteAheadOwnershipManifest
  :: OwnershipManifestWrite 'WriteAheadOwnership surface
  -> Either
       DurableWriteAheadOwnershipManifestError
       DurableWriteAheadOwnershipManifest
captureDurableWriteAheadOwnershipManifest write =
  captureDurableWriteAheadOwnershipManifestInternal
    (ownershipManifestWriteStackKey write)
    (ownershipManifestWriteScope write)
    (ownershipManifestWriteDigest write)
    (map durableEntry (ownershipManifestWriteEntries write))
 where
  durableEntry entry =
    DurableOwnershipManifestEntryValue
      { durableOwnershipManifestEntryKey = ownershipManifestEntryKey entry
      , durableOwnershipManifestEntryCoordinateDigest =
          ownershipManifestEntryCoordinateDigest entry
      , durableOwnershipManifestEntryObservedIdentities =
          ownershipManifestEntryObservedIdentities entry
      }

data OwnershipManifestReadBackResult
  = OwnershipManifestReadBackPresent !OwnershipManifestVersion
  | OwnershipManifestReadBackAbsent
  | OwnershipManifestReadBackPartial !(NonEmpty ObservationFailure)
  | OwnershipManifestReadBackUnobservable !(NonEmpty ObservationFailure)
  deriving (Eq, Show)

data OwnershipManifestReadBackObservation = OwnershipManifestReadBackObservation
  { ownershipManifestReadBackPurpose :: !OwnershipManifestPurposeValue
  , ownershipManifestReadBackStackKey :: !RegisteredResourceKey
  , ownershipManifestReadBackScope :: !ObservationEvidenceScope
  , ownershipManifestReadBackProvenance :: !OwnershipManifestProvenance
  , ownershipManifestReadBackDigest :: !OwnershipManifestDigest
  , ownershipManifestReadBackEntries :: ![OwnershipManifestEntry]
  , ownershipManifestReadBackResult :: !OwnershipManifestReadBackResult
  }
  deriving (Eq, Show)

data
  VerifiedOwnershipManifest
    (purpose :: OwnershipManifestPurpose)
    (surface :: CleanupSurface)
  = VerifiedOwnershipManifestInternal
      !OwnershipManifestPurposeValue
      !ManifestBinding
      !OwnershipManifestProvenance
      !OwnershipManifestVersion
      !OwnershipManifestDigest
      ![OwnershipManifestEntry]
      !(Maybe LegacyAdoptionPlanDigest)

verifiedOwnershipManifestStackKey
  :: VerifiedOwnershipManifest purpose surface -> RegisteredResourceKey
verifiedOwnershipManifestStackKey
  (VerifiedOwnershipManifestInternal _ binding _ _ _ _ _) =
    manifestBindingStackKey binding

verifiedOwnershipManifestScope
  :: VerifiedOwnershipManifest purpose surface -> ObservationEvidenceScope
verifiedOwnershipManifestScope
  (VerifiedOwnershipManifestInternal _ binding _ _ _ _ _) =
    manifestBindingScope binding

verifiedOwnershipManifestPurpose
  :: VerifiedOwnershipManifest purpose surface -> OwnershipManifestPurposeValue
verifiedOwnershipManifestPurpose
  (VerifiedOwnershipManifestInternal purpose _ _ _ _ _ _) = purpose

verifiedOwnershipManifestVersion
  :: VerifiedOwnershipManifest purpose surface -> OwnershipManifestVersion
verifiedOwnershipManifestVersion
  (VerifiedOwnershipManifestInternal _ _ _ version _ _ _) = version

verifiedOwnershipManifestProvenance
  :: VerifiedOwnershipManifest purpose surface -> OwnershipManifestProvenance
verifiedOwnershipManifestProvenance
  (VerifiedOwnershipManifestInternal _ _ provenance _ _ _ _) = provenance

verifiedOwnershipManifestDigest
  :: VerifiedOwnershipManifest purpose surface -> OwnershipManifestDigest
verifiedOwnershipManifestDigest
  (VerifiedOwnershipManifestInternal _ _ _ _ digest _ _) = digest

verifiedOwnershipManifestEntries
  :: VerifiedOwnershipManifest purpose surface -> [OwnershipManifestEntry]
verifiedOwnershipManifestEntries
  (VerifiedOwnershipManifestInternal _ _ _ _ _ entries _) = entries

readBackWriteAheadOwnershipManifest
  :: OwnershipManifestWrite 'WriteAheadOwnership surface
  -> OwnershipManifestReadBackObservation
  -> Either
       OwnershipManifestError
       (VerifiedOwnershipManifest 'WriteAheadOwnership surface)
readBackWriteAheadOwnershipManifest write observation = do
  validateManifestReadBack write observation
  version <- manifestReadBackVersion observation
  let OwnershipManifestWrite _ binding digest entries = write
  Right
    ( VerifiedOwnershipManifestInternal
        WriteAheadOwnershipValue
        binding
        (ownershipManifestReadBackProvenance observation)
        version
        digest
        entries
        Nothing
    )

data OwnershipManifestTarget (surface :: CleanupSurface)
  = OwnershipManifestTarget
      !(CleanupSurfaceWitness surface)
      !ManifestBinding

mkOwnershipManifestTarget
  :: CleanupSurfaceWitness surface
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> Either OwnershipManifestError (OwnershipManifestTarget surface)
mkOwnershipManifestTarget surface stackKey scope = do
  binding <- manifestBindingFor ReconcileDesiredAbsent surface stackKey scope
  Right (OwnershipManifestTarget surface binding)

ownershipManifestTargetStackKey
  :: OwnershipManifestTarget surface -> RegisteredResourceKey
ownershipManifestTargetStackKey (OwnershipManifestTarget _ binding) =
  manifestBindingStackKey binding

ownershipManifestTargetScope
  :: OwnershipManifestTarget surface -> ObservationEvidenceScope
ownershipManifestTargetScope (OwnershipManifestTarget _ binding) =
  manifestBindingScope binding

bindOwnershipManifestForCleanup
  :: OwnershipManifestTarget surface
  -> VerifiedOwnershipManifest purpose surface
  -> Either OwnershipManifestError (CompleteOwnershipManifest surface)
bindOwnershipManifestForCleanup
  (OwnershipManifestTarget surface targetBinding)
  (VerifiedOwnershipManifestInternal purpose manifestBinding provenance version digest _ planDigest) = do
    if manifestBindingStackKey manifestBinding == manifestBindingStackKey targetBinding
      then Right ()
      else
        Left
          ( OwnershipCleanupStackMismatch
              (manifestBindingStackKey targetBinding)
              (manifestBindingStackKey manifestBinding)
          )
    if sameDurableManifestScope (manifestBindingScope targetBinding) (manifestBindingScope manifestBinding)
      then Right ()
      else
        Left
          ( OwnershipCleanupScopeMismatch
              (manifestBindingScope targetBinding)
              (manifestBindingScope manifestBinding)
          )
    if manifestBindingCoordinateDigest manifestBinding == manifestBindingCoordinateDigest targetBinding
      then Right ()
      else
        Left
          ( OwnershipCleanupCoordinateMismatch
              (manifestBindingCoordinateDigest targetBinding)
              (manifestBindingCoordinateDigest manifestBinding)
          )
    case purpose of
      WriteAheadOwnershipValue -> Right ()
      LegacyAdoptionOwnershipValue observedSurface ->
        Left
          ( OwnershipManifestLegacyCompleteUnsupported
              (manifestBindingSurface targetBinding)
              observedSurface
          )
    Right
      ( mkCompleteOwnershipManifestInternal
          surface
          (manifestBindingStackKey targetBinding)
          (manifestBindingScope targetBinding)
          purpose
          provenance
          version
          digest
          planDigest
      )

-- | Sprint 7.36: bind an /adopted/ manifest for cleanup.
--
-- 'bindOwnershipManifestForCleanup' refuses a legacy purpose outright, and that
-- refusal is right for it: a legacy manifest is built from provider observation
-- rather than written ahead of the create, so nothing in the write-ahead path
-- establishes that an operator ever agreed to it. This binder is the path that
-- does, and every additional check it makes is about that agreement.
--
-- The confirmed plan is the authorization. It cannot be forged from run state:
-- 'Prodbox.Lifecycle.Teardown.LegacyAdoptionPlan.planLegacyAdoption' produces a
-- plan only over a complete, unambiguous observation of the closed
-- registry-derived family, and only an admin permit naming that plan's exact
-- digest turns it into a confirmed one. So the manifest's plan digest is checked
-- against a value an operator confirmed rather than against one the run
-- computed for itself.
--
-- Three things must agree beyond the ordinary binding checks: the manifest's
-- purpose must be the legacy one for this surface (a write-ahead manifest has no
-- business here, and neither does a legacy manifest adopted onto another
-- surface), the manifest must actually carry a plan digest, and that digest must
-- equal the confirmed plan's. A manifest with no plan digest is the case worth
-- naming separately — it is an adoption that was never confirmed at all, which
-- is a different failure from one confirmed against a superseded plan.
bindConfirmedLegacyAdoptionManifestForCleanup
  :: OwnershipManifestTarget surface
  -> ConfirmedLegacyAdoptionPlan surface
  -> VerifiedOwnershipManifest purpose surface
  -> Either OwnershipManifestError (CompleteOwnershipManifest surface)
bindConfirmedLegacyAdoptionManifestForCleanup
  (OwnershipManifestTarget surface targetBinding)
  confirmed
  (VerifiedOwnershipManifestInternal purpose manifestBinding provenance version digest _ planDigest) = do
    if manifestBindingStackKey manifestBinding == manifestBindingStackKey targetBinding
      then Right ()
      else
        Left
          ( OwnershipCleanupStackMismatch
              (manifestBindingStackKey targetBinding)
              (manifestBindingStackKey manifestBinding)
          )
    if sameDurableManifestScope (manifestBindingScope targetBinding) (manifestBindingScope manifestBinding)
      then Right ()
      else
        Left
          ( OwnershipCleanupScopeMismatch
              (manifestBindingScope targetBinding)
              (manifestBindingScope manifestBinding)
          )
    if manifestBindingCoordinateDigest manifestBinding == manifestBindingCoordinateDigest targetBinding
      then Right ()
      else
        Left
          ( OwnershipCleanupCoordinateMismatch
              (manifestBindingCoordinateDigest targetBinding)
              (manifestBindingCoordinateDigest manifestBinding)
          )
    case purpose of
      WriteAheadOwnershipValue ->
        Left
          ( OwnershipManifestAdoptionPurposeRequired
              (manifestBindingSurface targetBinding)
          )
      LegacyAdoptionOwnershipValue observedSurface
        | observedSurface == manifestBindingSurface targetBinding -> Right ()
        | otherwise ->
            Left
              ( OwnershipManifestLegacyCompleteUnsupported
                  (manifestBindingSurface targetBinding)
                  observedSurface
              )
    if legacyAdoptionPlanStackKey plan == manifestBindingStackKey targetBinding
      then Right ()
      else
        Left
          ( OwnershipCleanupStackMismatch
              (manifestBindingStackKey targetBinding)
              (legacyAdoptionPlanStackKey plan)
          )
    case planDigest of
      Nothing -> Left OwnershipManifestAdoptionPlanDigestMissing
      Just observedPlanDigest
        | observedPlanDigest == confirmedDigest -> Right ()
        | otherwise ->
            Left
              ( OwnershipManifestAdoptionPlanDigestMismatch
                  confirmedDigest
                  observedPlanDigest
              )
    Right
      ( mkCompleteOwnershipManifestInternal
          surface
          (manifestBindingStackKey targetBinding)
          (manifestBindingScope targetBinding)
          purpose
          provenance
          version
          digest
          planDigest
      )
   where
    plan = confirmedLegacyAdoptionPlan confirmed
    confirmedDigest = confirmedLegacyAdoptionPlanDigest confirmed

-- | A confirmed legacy-adoption manifest prepared for durable receipt commit.
--
-- The wrapper is opaque and carries the exact confirmed plan beside the
-- manifest write.  Its receipt bytes are the bytes an effectful repository
-- must commit and independently read back before
-- 'completeConfirmedLegacyAdoptionManifestReadBack' can expose cleanup
-- evidence.  Discovery alone therefore still cannot authorize mutation.
data ConfirmedLegacyAdoptionManifestWrite (surface :: CleanupSurface)
  = ConfirmedLegacyAdoptionManifestWrite
      !(CleanupSurfaceWitness surface)
      !(ConfirmedLegacyAdoptionPlan surface)
      !(OwnershipManifestWrite ('LegacyAdoptionOwnership surface) surface)
      !ByteString.ByteString

confirmedLegacyAdoptionManifestWrite
  :: CleanupSurfaceWitness surface
  -> ConfirmedLegacyAdoptionPlan surface
  -> Either OwnershipManifestError (ConfirmedLegacyAdoptionManifestWrite surface)
confirmedLegacyAdoptionManifestWrite surface confirmed = do
  let plan = confirmedLegacyAdoptionPlan confirmed
      expectedSurface = cleanupSurfaceFromWitness surface
      actualSurface = legacyAdoptionPlanSurface plan
  if actualSurface == expectedSurface
    then Right ()
    else Left (OwnershipManifestScopeSurfaceMismatch expectedSurface actualSurface)
  binding <-
    manifestBindingFor
      ReconcileDesiredAbsent
      surface
      (legacyAdoptionPlanStackKey plan)
      (legacyAdoptionPlanScope plan)
  let entries = map adoptionEntry (legacyAdoptionPlanEntries plan)
      write =
        manifestWrite
          (LegacyAdoptionOwnershipValue expectedSurface)
          binding
          entries
      receiptBytes =
        TextEncoding.encodeUtf8
          ( Text.intercalate
              "\n"
              ( [ "confirmed-legacy-adoption-manifest/v1"
                , renderPurpose (LegacyAdoptionOwnershipValue expectedSurface)
                , renderManifestBinding binding
                , "plan "
                    <> legacyAdoptionPlanDigestText
                      (confirmedLegacyAdoptionPlanDigest confirmed)
                ]
                  ++ map renderManifestEntry (ownershipManifestWriteEntries write)
              )
          )
  Right
    ( ConfirmedLegacyAdoptionManifestWrite
        surface
        confirmed
        write
        receiptBytes
    )
 where
  adoptionEntry entry =
    OwnershipManifestEntry
      { ownershipManifestEntryKey = legacyAdoptionEntryKey entry
      , ownershipManifestEntryCoordinateDigest =
          legacyAdoptionEntryCoordinateDigest entry
      , ownershipManifestEntryObservedIdentities =
          legacyAdoptionEntryIdentities entry
      }

confirmedLegacyAdoptionManifestWriteStackKey
  :: ConfirmedLegacyAdoptionManifestWrite surface -> RegisteredResourceKey
confirmedLegacyAdoptionManifestWriteStackKey
  (ConfirmedLegacyAdoptionManifestWrite _ _ write _) =
    ownershipManifestWriteStackKey write

confirmedLegacyAdoptionManifestWriteScope
  :: ConfirmedLegacyAdoptionManifestWrite surface -> ObservationEvidenceScope
confirmedLegacyAdoptionManifestWriteScope
  (ConfirmedLegacyAdoptionManifestWrite _ _ write _) =
    ownershipManifestWriteScope write

confirmedLegacyAdoptionManifestWritePlanDigest
  :: ConfirmedLegacyAdoptionManifestWrite surface -> LegacyAdoptionPlanDigest
confirmedLegacyAdoptionManifestWritePlanDigest
  (ConfirmedLegacyAdoptionManifestWrite _ confirmed _ _) =
    confirmedLegacyAdoptionPlanDigest confirmed

confirmedLegacyAdoptionManifestWriteReceiptBytes
  :: ConfirmedLegacyAdoptionManifestWrite surface -> ByteString.ByteString
confirmedLegacyAdoptionManifestWriteReceiptBytes
  (ConfirmedLegacyAdoptionManifestWrite _ _ _ bytes) = bytes

-- | Promote an exact independently read-back confirmed-adoption receipt into
-- cleanup evidence.  The effectful repository owns byte equality and calls
-- this function only after its fresh read-back equals
-- 'confirmedLegacyAdoptionManifestWriteReceiptBytes'.  This function then
-- rechecks the typed plan/manifest binding and is the only positive minter for
-- the adoption path.
completeConfirmedLegacyAdoptionManifestReadBack
  :: OwnershipManifestProvenance
  -> OwnershipManifestVersion
  -> ConfirmedLegacyAdoptionManifestWrite surface
  -> Either OwnershipManifestError OwnershipManifestDecisionEvidence
completeConfirmedLegacyAdoptionManifestReadBack
  provenance
  version
  (ConfirmedLegacyAdoptionManifestWrite surface confirmed write _) = do
    let OwnershipManifestWrite purpose binding digest entries = write
        verified =
          VerifiedOwnershipManifestInternal
            purpose
            binding
            provenance
            version
            digest
            entries
            (Just (confirmedLegacyAdoptionPlanDigest confirmed))
    target <-
      mkOwnershipManifestTarget
        surface
        (ownershipManifestWriteStackKey write)
        (ownershipManifestWriteScope write)
    (\complete -> ValidatedCompleteOwnershipManifest complete entries)
      <$> bindConfirmedLegacyAdoptionManifestForCleanup target confirmed verified

bindObservedDurableWriteAheadOwnershipManifestForCleanup
  :: OwnershipManifestTarget surface
  -> ObservedDurableWriteAheadOwnershipManifest
  -> Either OwnershipManifestError OwnershipManifestDecisionEvidence
bindObservedDurableWriteAheadOwnershipManifestForCleanup
  target@(OwnershipManifestTarget surface _)
  observed = do
    let durable = observedDurableWriteAheadOwnershipManifestValue observed
        key = durableWriteAheadOwnershipManifestStackKey durable
        scope = durableWriteAheadOwnershipManifestScope durable
        entries = map ownershipEntry (durableWriteAheadOwnershipManifestEntries durable)
    expectedEntries <- initialManifestEntries key
    if entryShape entries == entryShape expectedEntries
      then Right ()
      else
        Left
          ( OwnershipManifestDurableEntrySetMismatch
              (map ownershipManifestEntryKey expectedEntries)
              (map ownershipManifestEntryKey entries)
          )
    binding <- manifestBindingFor ReconcileDesiredPresent surface key scope
    let write = manifestWrite WriteAheadOwnershipValue binding entries
        observation =
          OwnershipManifestReadBackObservation
            { ownershipManifestReadBackPurpose = WriteAheadOwnershipValue
            , ownershipManifestReadBackStackKey = key
            , ownershipManifestReadBackScope = scope
            , ownershipManifestReadBackProvenance =
                OwnershipManifestProvenance
                  (observedDurableWriteAheadOwnershipManifestProvenance observed)
            , ownershipManifestReadBackDigest =
                durableWriteAheadOwnershipManifestDigest durable
            , ownershipManifestReadBackEntries = entries
            , ownershipManifestReadBackResult =
                OwnershipManifestReadBackPresent
                  ( OwnershipManifestVersion
                      (observedDurableWriteAheadOwnershipManifestVersion observed)
                  )
            }
    verified <- readBackWriteAheadOwnershipManifest write observation
    (\complete -> ValidatedCompleteOwnershipManifest complete entries)
      <$> bindOwnershipManifestForCleanup target verified
   where
    ownershipEntry entry =
      OwnershipManifestEntry
        { ownershipManifestEntryKey = durableOwnershipManifestEntryKey entry
        , ownershipManifestEntryCoordinateDigest =
            durableOwnershipManifestEntryCoordinateDigest entry
        , ownershipManifestEntryObservedIdentities =
            durableOwnershipManifestEntryObservedIdentities entry
        }

    entryShape =
      map
        ( \entry ->
            ( ownershipManifestEntryKey entry
            , ownershipManifestEntryCoordinateDigest entry
            )
        )

data OwnershipManifestDecisionEvidence where
  OwnershipManifestObservationOnly
    :: !OwnershipManifestObservation
    -> OwnershipManifestDecisionEvidence
  ValidatedCompleteOwnershipManifest
    :: !(CompleteOwnershipManifest surface)
    -> ![OwnershipManifestEntry]
    -> OwnershipManifestDecisionEvidence

-- | Read-only projection of decision evidence.  The complete branch exposes
-- only the purpose and the provenance\/version facts consumed by the decision
-- algebra; it cannot be converted back into cleanup authority.
--
-- The purpose is carried because a reader that cannot see it cannot tell a
-- create's own record of what it was about to make from a cleanup-only
-- adoption receipt for resources somebody else made.  Both are complete
-- manifests and both read back identically here, so the create-side minter
-- 'Prodbox.ControlPlane.RegisteredStackCreationSubmitter.proveWriteAheadOwnership'
-- had no field to refuse on and would mint a write-ahead proof from an
-- adoption.
data OwnershipManifestDecisionView
  = OwnershipManifestDecisionObservation !OwnershipManifestObservation
  | OwnershipManifestDecisionComplete
      !OwnershipManifestPurposeValue
      !OwnershipManifestProvenance
      !OwnershipManifestVersion
  deriving (Eq, Show)

-- | Public construction is deliberately limited to the non-authorizing
-- observation branch.  In particular, Present remains insufficient to
-- authorize destruction.
ownershipManifestObservationOnly
  :: OwnershipManifestObservation -> OwnershipManifestDecisionEvidence
ownershipManifestObservationOnly = OwnershipManifestObservationOnly

ownershipManifestDecisionView
  :: OwnershipManifestDecisionEvidence -> OwnershipManifestDecisionView
ownershipManifestDecisionView evidence = case evidence of
  OwnershipManifestObservationOnly observation ->
    OwnershipManifestDecisionObservation observation
  ValidatedCompleteOwnershipManifest manifest _ ->
    OwnershipManifestDecisionComplete
      (completeOwnershipManifestPurpose manifest)
      (completeOwnershipManifestProvenance manifest)
      (completeOwnershipManifestVersion manifest)

ownershipManifestDecisionStackKey
  :: OwnershipManifestDecisionEvidence -> RegisteredResourceKey
ownershipManifestDecisionStackKey evidence = case evidence of
  OwnershipManifestObservationOnly observation -> ownershipManifestStackKey observation
  ValidatedCompleteOwnershipManifest manifest _ -> completeOwnershipManifestStackKey manifest

ownershipManifestDecisionScope
  :: OwnershipManifestDecisionEvidence -> ObservationEvidenceScope
ownershipManifestDecisionScope evidence = case evidence of
  OwnershipManifestObservationOnly observation -> ownershipManifestEvidenceScope observation
  ValidatedCompleteOwnershipManifest manifest _ -> completeOwnershipManifestScope manifest

-- | The exact identities receipt-committed for one registered family.
-- Observation-only evidence carries no mutation allowlist. A complete
-- manifest returns a value only when it contains exactly one entry for the
-- requested key; a malformed duplicate or omission therefore fails closed.
ownershipManifestDecisionEntryIdentities
  :: RegisteredResourceKey
  -> OwnershipManifestDecisionEvidence
  -> Maybe [ObservedResourceIdentity]
ownershipManifestDecisionEntryIdentities key evidence = case evidence of
  OwnershipManifestObservationOnly _ -> Nothing
  ValidatedCompleteOwnershipManifest _ entries -> case [ ownershipManifestEntryObservedIdentities entry
                                                       | entry <- entries
                                                       , ownershipManifestEntryKey entry == key
                                                       ] of
    [identities] -> Just identities
    _ -> Nothing

-- | Sprint 4.97: carry complete decision evidence across the stack-reader wire.
--
-- The wire refused this outright, so the decision's manifest authority was not
-- merely unreached but structurally undecidable: the one branch that can act on
-- AWS coordinates rather than on a checkpoint could never be constructed on the
-- far side, and the ladder could only refuse.
--
-- Observation-only evidence is refused here rather than encoded. It already has
-- a wire of its own, and admitting it through this one would let an observation
-- arrive claiming to be evidence that authorizes a destroy.
captureCompleteOwnershipManifestEvidence
  :: OwnershipManifestDecisionEvidence
  -> Either OwnershipManifestError ByteString.ByteString
captureCompleteOwnershipManifestEvidence evidence = case evidence of
  OwnershipManifestObservationOnly _ ->
    Left OwnershipManifestCompleteEvidenceRequired
  ValidatedCompleteOwnershipManifest complete entries ->
    first
      (OwnershipManifestCompleteEvidenceInvalid . Text.pack . show)
      (captureCompleteOwnershipManifestWithEntries complete (map durableEntry entries))
 where
  durableEntry entry =
    DurableOwnershipManifestEntryValue
      { durableOwnershipManifestEntryKey = ownershipManifestEntryKey entry
      , durableOwnershipManifestEntryCoordinateDigest =
          ownershipManifestEntryCoordinateDigest entry
      , durableOwnershipManifestEntryObservedIdentities =
          ownershipManifestEntryObservedIdentities entry
      }

restoreCompleteOwnershipManifestEvidence
  :: ByteString.ByteString
  -> Either OwnershipManifestError OwnershipManifestDecisionEvidence
restoreCompleteOwnershipManifestEvidence bytes = do
  (restored, entries) <-
    first
      (OwnershipManifestCompleteEvidenceInvalid . Text.pack . show)
      (restoreCompleteOwnershipManifestWithEntries bytes)
  pure (completeEvidence restored (map manifestEntry entries))
 where
  completeEvidence restored entries = case restored of
    SomeCompleteOwnershipManifest complete ->
      ValidatedCompleteOwnershipManifest complete entries

  manifestEntry entry =
    OwnershipManifestEntry
      { ownershipManifestEntryKey = durableOwnershipManifestEntryKey entry
      , ownershipManifestEntryCoordinateDigest =
          durableOwnershipManifestEntryCoordinateDigest entry
      , ownershipManifestEntryObservedIdentities =
          durableOwnershipManifestEntryObservedIdentities entry
      }

data OwnershipManifestError
  = OwnershipManifestKeyUnregistered !RegisteredResourceKey
  | OwnershipManifestResourceIsNotStack !RegisteredResourceKey !ResourceKind
  | OwnershipManifestTargetNotAllowed !RegisteredResourceKey !CleanupSurface
  | OwnershipManifestScopeSurfaceMismatch !CleanupSurface !CleanupSurface
  | OwnershipManifestScopeOperationMismatch !LifecycleOperation !LifecycleOperation
  | OwnershipManifestRegistryRevisionMismatch !RegistryRevision !RegistryRevision
  | OwnershipManifestAwsScopeMissing
  | OwnershipEdgeNotRegistered !RegisteredResourceKey !RegisteredResourceKey
  | -- | Sprint 7.41: the provider reported an identity for a resource the
    -- write-ahead record never declared.
    OwnershipManifestAppendedKeyUndeclared
      !RegisteredResourceKey
      ![RegisteredResourceKey]
  | -- | Sprint 7.41: an append that appends nothing.
    OwnershipManifestAppendedIdentitiesEmpty ![RegisteredResourceKey]
  | OwnershipManifestReadBackPurposeMismatch
      !OwnershipManifestPurposeValue
      !OwnershipManifestPurposeValue
  | OwnershipManifestReadBackStackMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | OwnershipManifestReadBackScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | OwnershipManifestReadBackDigestMismatch
      !OwnershipManifestDigest
      !OwnershipManifestDigest
  | OwnershipManifestReadBackEntriesMismatch
      ![OwnershipManifestEntry]
      ![OwnershipManifestEntry]
  | OwnershipManifestDurableEntrySetMismatch
      ![RegisteredResourceKey]
      ![RegisteredResourceKey]
  | OwnershipManifestReadBackAbsentError
  | OwnershipManifestReadBackPartialFailure !(NonEmpty ObservationFailure)
  | OwnershipManifestReadBackUnobservableFailure !(NonEmpty ObservationFailure)
  | OwnershipCleanupStackMismatch !RegisteredResourceKey !RegisteredResourceKey
  | OwnershipCleanupScopeMismatch !ObservationEvidenceScope !ObservationEvidenceScope
  | OwnershipCleanupCoordinateMismatch
      !ManagedResourceCoordinateDigest
      !ManagedResourceCoordinateDigest
  | OwnershipManifestLegacyCompleteUnsupported !CleanupSurface !CleanupSurface
  | -- | Sprint 7.36: a write-ahead manifest reached the adoption binder. The
    -- two provenances are not interchangeable: one is written before the create
    -- and one is reconstructed from observation afterwards.
    OwnershipManifestAdoptionPurposeRequired !CleanupSurface
  | -- | An adoption manifest carrying no plan digest was never confirmed at
    -- all, which is a different failure from one confirmed against a superseded
    -- plan.
    OwnershipManifestAdoptionPlanDigestMissing
  | -- | The manifest was confirmed against a different plan. This is the case
    -- the digest exists for: provider facts observed later are a different plan,
    -- and the operator agreed to the earlier one.
    OwnershipManifestAdoptionPlanDigestMismatch
      !LegacyAdoptionPlanDigest
      !LegacyAdoptionPlanDigest
  | -- | Sprint 4.97.  Complete decision evidence failed to capture or restore
    -- across a wire.  The detail is the durable codec's own refusal rendered,
    -- not a second vocabulary for the same rejections.
    OwnershipManifestCompleteEvidenceInvalid !Text
  | -- | Sprint 4.97.  Observation-only evidence was handed to the
    -- complete-evidence encoder.  The observation branch has its own wire, and
    -- routing it through this one would mean an observation could arrive
    -- claiming to be a manifest that authorizes destruction.
    OwnershipManifestCompleteEvidenceRequired
  deriving (Eq, Show)

manifestBindingFor
  :: LifecycleOperation
  -> CleanupSurfaceWitness surface
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> Either OwnershipManifestError ManifestBinding
manifestBindingFor expectedOperation surface stackKey scope = do
  identity <- registeredIdentity stackKey
  if registeredIdentityKind identity == Stack
    then Right ()
    else
      Left
        ( OwnershipManifestResourceIsNotStack
            stackKey
            (registeredIdentityKind identity)
        )
  case projectCleanupTarget surface identity of
    Right target
      | cleanupTargetKind target == Stack -> Right ()
    _ ->
      Left
        ( OwnershipManifestTargetNotAllowed
            stackKey
            (cleanupSurfaceFromWitness surface)
        )
  if evidenceCleanupSurface scope == cleanupSurfaceFromWitness surface
    then Right ()
    else
      Left
        ( OwnershipManifestScopeSurfaceMismatch
            (cleanupSurfaceFromWitness surface)
            (evidenceCleanupSurface scope)
        )
  if evidenceLifecycleOperation scope == expectedOperation
    then Right ()
    else
      Left
        ( OwnershipManifestScopeOperationMismatch
            expectedOperation
            (evidenceLifecycleOperation scope)
        )
  if evidenceRegistryRevision scope == lifecycleRegistryRevision
    then Right ()
    else
      Left
        ( OwnershipManifestRegistryRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision scope)
        )
  if evidenceAwsScope scope /= Nothing
    then Right ()
    else Left OwnershipManifestAwsScopeMissing
  Right
    ManifestBinding
      { manifestBindingStackKey = stackKey
      , manifestBindingSurface = cleanupSurfaceFromWitness surface
      , manifestBindingScope = scope
      , manifestBindingCoordinateDigest = registeredIdentityCoordinateDigest identity
      }

registeredIdentity
  :: RegisteredResourceKey -> Either OwnershipManifestError RegisteredIdentity
registeredIdentity key = case lookupRegisteredIdentity key of
  Nothing -> Left (OwnershipManifestKeyUnregistered key)
  Just identity -> Right identity

initialManifestEntries
  :: RegisteredResourceKey
  -> Either OwnershipManifestError [OwnershipManifestEntry]
initialManifestEntries stackKey =
  mapM entryForKey (stackKey : ownedKeys)
 where
  ownedKeys =
    [ ownershipEdgeResourceKey edge
    | edge <- registeredOwnershipEdges
    , ownershipEdgeStackKey edge == stackKey
    ]
  entryForKey key = do
    identity <- registeredIdentity key
    Right
      OwnershipManifestEntry
        { ownershipManifestEntryKey = key
        , ownershipManifestEntryCoordinateDigest = registeredIdentityCoordinateDigest identity
        , ownershipManifestEntryObservedIdentities = []
        }

manifestWrite
  :: OwnershipManifestPurposeValue
  -> ManifestBinding
  -> [OwnershipManifestEntry]
  -> OwnershipManifestWrite purpose surface
manifestWrite purpose binding rawEntries =
  OwnershipManifestWrite purpose binding digest entries
 where
  entries = canonicalManifestEntries rawEntries
  digest = digestManifestDocument purpose binding entries

validateManifestReadBack
  :: OwnershipManifestWrite purpose surface
  -> OwnershipManifestReadBackObservation
  -> Either OwnershipManifestError ()
validateManifestReadBack
  (OwnershipManifestWrite purpose binding digest entries)
  observation = do
    if ownershipManifestReadBackPurpose observation == purpose
      then Right ()
      else
        Left
          ( OwnershipManifestReadBackPurposeMismatch
              purpose
              (ownershipManifestReadBackPurpose observation)
          )
    if ownershipManifestReadBackStackKey observation == manifestBindingStackKey binding
      then Right ()
      else
        Left
          ( OwnershipManifestReadBackStackMismatch
              (manifestBindingStackKey binding)
              (ownershipManifestReadBackStackKey observation)
          )
    if ownershipManifestReadBackScope observation == manifestBindingScope binding
      then Right ()
      else
        Left
          ( OwnershipManifestReadBackScopeMismatch
              (manifestBindingScope binding)
              (ownershipManifestReadBackScope observation)
          )
    if ownershipManifestReadBackDigest observation == digest
      then Right ()
      else
        Left
          ( OwnershipManifestReadBackDigestMismatch
              digest
              (ownershipManifestReadBackDigest observation)
          )
    let observedEntries = ownershipManifestReadBackEntries observation
    if observedEntries == entries
      then Right ()
      else Left (OwnershipManifestReadBackEntriesMismatch entries observedEntries)

manifestReadBackVersion
  :: OwnershipManifestReadBackObservation
  -> Either OwnershipManifestError OwnershipManifestVersion
manifestReadBackVersion observation = case ownershipManifestReadBackResult observation of
  OwnershipManifestReadBackPresent version -> Right version
  OwnershipManifestReadBackAbsent -> Left OwnershipManifestReadBackAbsentError
  OwnershipManifestReadBackPartial failures ->
    Left (OwnershipManifestReadBackPartialFailure failures)
  OwnershipManifestReadBackUnobservable failures ->
    Left (OwnershipManifestReadBackUnobservableFailure failures)

-- | Whether a manifest read back for cleanup was written under this run's scope.
--
-- __Sprint 4.92: one field ignored, not two.__ This was a hand-rolled
-- conjunction over five of the scope's seven fields, and the two it left out
-- were not left out for the same reason. The run's retained DNS hosted zone was
-- simply forgotten, so a write-ahead manifest committed against one zone bound
-- for cleanup against another and the mismatch had no way to surface. The
-- comparison now destructures 'ObservationEvidenceScopeFields' positionally, so
-- a field added to the scope is a constructor-arity error here rather than a
-- seventh silent omission.
--
-- The lifecycle operation is the one field deliberately ignored, and it has to
-- be. A write-ahead manifest is written under 'ReconcileDesiredPresent' and read
-- back for cleanup under 'ReconcileDesiredAbsent' — the two scopes never agree
-- on it by construction, so comparing it would refuse every legitimate bind.
-- The operation each side must carry is not unchecked, though: 'manifestBindingFor'
-- fixes it when the binding is minted, which is the only place that knows which
-- side of the lifecycle it is on.
sameDurableManifestScope
  :: ObservationEvidenceScope -> ObservationEvidenceScope -> Bool
sameDurableManifestScope left right =
  sameFields
    (observationEvidenceScopeFields left)
    (observationEvidenceScopeFields right)
 where
  sameFields
    ( ObservationEvidenceScopeFields
        leftSurface
        leftRevision
        leftRunScope
        leftFoundation
        leftAwsScope
        leftDnsZone
        leftBindings
        _leftOperation
      )
    ( ObservationEvidenceScopeFields
        rightSurface
        rightRevision
        rightRunScope
        rightFoundation
        rightAwsScope
        rightDnsZone
        rightBindings
        _rightOperation
      ) =
      leftSurface == rightSurface
        && leftRevision == rightRevision
        && leftRunScope == rightRunScope
        && leftFoundation == rightFoundation
        && leftAwsScope == rightAwsScope
        && leftDnsZone == rightDnsZone
        && leftBindings == rightBindings

canonicalManifestEntries :: [OwnershipManifestEntry] -> [OwnershipManifestEntry]
canonicalManifestEntries =
  sortOn ownershipManifestEntryKey
    . map
      ( \entry ->
          entry
            { ownershipManifestEntryObservedIdentities =
                nub (sort (ownershipManifestEntryObservedIdentities entry))
            }
      )

digestManifestDocument
  :: OwnershipManifestPurposeValue
  -> ManifestBinding
  -> [OwnershipManifestEntry]
  -> OwnershipManifestDigest
digestManifestDocument purpose binding entries =
  OwnershipManifestDigest (hashText (Text.intercalate "\NUL" canonical))
 where
  -- Sprint 4.92: @v2@ because the binding's scope projection now carries the
  -- run's retained DNS hosted zone and its lifecycle operation, which @v1@
  -- dropped. Every manifest digest moves, and that is the point: a @v1@ digest
  -- was computed over a scope that could not distinguish two runs differing only
  -- in the zone they were compiled against.
  canonical =
    [ "ownership-manifest/v2"
    , renderPurpose purpose
    , renderManifestBinding binding
    ]
      ++ map renderManifestEntry entries

renderPurpose :: OwnershipManifestPurposeValue -> Text
renderPurpose purpose = case purpose of
  WriteAheadOwnershipValue -> "write-ahead"
  LegacyAdoptionOwnershipValue surface -> "legacy/" <> renderSurface surface

renderManifestBinding :: ManifestBinding -> Text
renderManifestBinding binding =
  Text.intercalate
    "/"
    [ registeredResourceKeyText (manifestBindingStackKey binding)
    , renderSurface (manifestBindingSurface binding)
    , managedResourceCoordinateDigestText (manifestBindingCoordinateDigest binding)
    , scopeIdentityText (manifestBindingScope binding)
    ]

renderManifestEntry :: OwnershipManifestEntry -> Text
renderManifestEntry entry =
  Text.intercalate
    "/"
    ( [ registeredResourceKeyText (ownershipManifestEntryKey entry)
      , managedResourceCoordinateDigestText (ownershipManifestEntryCoordinateDigest entry)
      ]
        ++ map renderObservedIdentity (ownershipManifestEntryObservedIdentities entry)
    )

renderObservedIdentity :: ObservedResourceIdentity -> Text
renderObservedIdentity (ObservedResourceIdentity identity) = identity

renderSurface :: CleanupSurface -> Text
renderSurface surface = case surface of
  LocalOnly -> "local-only"
  Cascade -> "cascade"
  ExplicitPerRun -> "explicit-per-run"
  OperationalTeardown -> "operational"
  ExplicitLongLived -> "explicit-long-lived"
  TotalDecommission -> "total-decommission"

hashText :: Text -> Text
hashText = TextEncoding.decodeUtf8 . hexSha256 . TextEncoding.encodeUtf8
