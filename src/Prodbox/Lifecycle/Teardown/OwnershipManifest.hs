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
  , projectRegisteredOwnershipEdge
  , WriteAheadManifestIntent
  , mkWriteAheadManifestIntent
  , initialWriteAheadManifestWrite
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
  , bindObservedDurableWriteAheadOwnershipManifestForCleanup
  , DurableWriteAheadOwnershipManifestError (..)
  , maximumDurableWriteAheadOwnershipManifestBytes
  , OwnershipManifestDecisionEvidence
  , OwnershipManifestDecisionView (..)
  , ownershipManifestObservationOnly
  , ownershipManifestDecisionView
  , ownershipManifestDecisionStackKey
  , ownershipManifestDecisionScope
  , LegacyAdoptionPlanDigest
  , legacyAdoptionPlanDigestText
  , OwnershipManifestError (..)
  )
where

import Data.List (nub, sort, sortOn)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Aws.SigV4 (hexSha256)
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
  , captureDurableCompleteOwnershipManifest
  , captureDurableWriteAheadOwnershipManifestInternal
  , completeOwnershipManifestDigest
  , completeOwnershipManifestLegacyPlanDigest
  , completeOwnershipManifestProvenance
  , completeOwnershipManifestPurpose
  , completeOwnershipManifestScope
  , completeOwnershipManifestStackKey
  , completeOwnershipManifestVersion
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
  , observedDurableWriteAheadOwnershipManifestProvenance
  , observedDurableWriteAheadOwnershipManifestValue
  , observedDurableWriteAheadOwnershipManifestVersion
  , ownershipManifestDigestText
  )
import Prodbox.Lifecycle.Teardown.Registry

data OwnershipManifestPurpose
  = WriteAheadOwnership
  | LegacyAdoptionOwnership CleanupSurface

data OwnershipManifestEntry = OwnershipManifestEntry
  { ownershipManifestEntryKey :: !RegisteredResourceKey
  , ownershipManifestEntryCoordinateDigest :: !ManagedResourceCoordinateDigest
  , ownershipManifestEntryObservedIdentities :: ![ObservedResourceIdentity]
  }
  deriving (Eq, Ord, Show)

data RegisteredOwnershipEdge = RegisteredOwnershipEdge
  { internalOwnershipEdgeStackKey :: !RegisteredResourceKey
  , internalOwnershipEdgeResourceKey :: !RegisteredResourceKey
  }
  deriving (Eq, Show)

ownershipEdgeStackKey :: RegisteredOwnershipEdge -> RegisteredResourceKey
ownershipEdgeStackKey = internalOwnershipEdgeStackKey

ownershipEdgeResourceKey :: RegisteredOwnershipEdge -> RegisteredResourceKey
ownershipEdgeResourceKey = internalOwnershipEdgeResourceKey

registeredOwnershipEdges :: [RegisteredOwnershipEdge]
registeredOwnershipEdges =
  [ RegisteredOwnershipEdge AwsTestKey AwsEbsPerRunTestKey
  ]

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
    ValidatedCompleteOwnershipManifest
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
    -> OwnershipManifestDecisionEvidence

-- | Read-only projection of decision evidence.  The complete branch exposes
-- only the provenance/version facts consumed by the decision algebra; it
-- cannot be converted back into cleanup authority.
data OwnershipManifestDecisionView
  = OwnershipManifestDecisionObservation !OwnershipManifestObservation
  | OwnershipManifestDecisionComplete
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
  ValidatedCompleteOwnershipManifest manifest ->
    OwnershipManifestDecisionComplete
      (completeOwnershipManifestProvenance manifest)
      (completeOwnershipManifestVersion manifest)

ownershipManifestDecisionStackKey
  :: OwnershipManifestDecisionEvidence -> RegisteredResourceKey
ownershipManifestDecisionStackKey evidence = case evidence of
  OwnershipManifestObservationOnly observation -> ownershipManifestStackKey observation
  ValidatedCompleteOwnershipManifest manifest -> completeOwnershipManifestStackKey manifest

ownershipManifestDecisionScope
  :: OwnershipManifestDecisionEvidence -> ObservationEvidenceScope
ownershipManifestDecisionScope evidence = case evidence of
  OwnershipManifestObservationOnly observation -> ownershipManifestEvidenceScope observation
  ValidatedCompleteOwnershipManifest manifest -> completeOwnershipManifestScope manifest

data OwnershipManifestError
  = OwnershipManifestKeyUnregistered !RegisteredResourceKey
  | OwnershipManifestResourceIsNotStack !RegisteredResourceKey !ResourceKind
  | OwnershipManifestTargetNotAllowed !RegisteredResourceKey !CleanupSurface
  | OwnershipManifestScopeSurfaceMismatch !CleanupSurface !CleanupSurface
  | OwnershipManifestScopeOperationMismatch !LifecycleOperation !LifecycleOperation
  | OwnershipManifestRegistryRevisionMismatch !RegistryRevision !RegistryRevision
  | OwnershipManifestAwsScopeMissing
  | OwnershipEdgeNotRegistered !RegisteredResourceKey !RegisteredResourceKey
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

sameDurableManifestScope
  :: ObservationEvidenceScope -> ObservationEvidenceScope -> Bool
sameDurableManifestScope left right =
  evidenceCleanupSurface left == evidenceCleanupSurface right
    && evidenceRegistryRevision left == evidenceRegistryRevision right
    && evidenceDurableRunScope left == evidenceDurableRunScope right
    && evidenceLinuxRke2Foundation left == evidenceLinuxRke2Foundation right
    && evidenceAwsScope left == evidenceAwsScope right

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
  canonical =
    [ "ownership-manifest/v1"
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
    , renderScope (manifestBindingScope binding)
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

renderScope :: ObservationEvidenceScope -> Text
renderScope scope =
  Text.intercalate
    "/"
    [ renderSurface (evidenceCleanupSurface scope)
    , renderRegistryRevision (evidenceRegistryRevision scope)
    , renderRunScope (evidenceDurableRunScope scope)
    , renderFoundation (evidenceLinuxRke2Foundation scope)
    , maybe "no-aws" renderAwsScope (evidenceAwsScope scope)
    ]

renderSurface :: CleanupSurface -> Text
renderSurface surface = case surface of
  LocalOnly -> "local-only"
  Cascade -> "cascade"
  ExplicitPerRun -> "explicit-per-run"
  OperationalTeardown -> "operational"
  ExplicitLongLived -> "explicit-long-lived"
  TotalDecommission -> "total-decommission"

renderRegistryRevision :: RegistryRevision -> Text
renderRegistryRevision (RegistryRevision revision) = revision

renderRunScope :: DurableObservationRunScope -> Text
renderRunScope (DurableObservationRunScope runScope) = runScope

renderFoundation :: LinuxRke2FoundationId -> Text
renderFoundation (LinuxRke2FoundationId foundation) = foundation

renderAwsScope :: AwsScope -> Text
renderAwsScope (AwsScope (AwsAccountId accountId) (AwsRegion region)) =
  accountId <> "/" <> region

hashText :: Text -> Text
hashText = TextEncoding.decodeUtf8 . hexSha256 . TextEncoding.encodeUtf8
