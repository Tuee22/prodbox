{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Total desired-absence decision for a registered stack.  Provider truth,
-- checkpoint copies, and ownership manifests remain distinct inputs; no
-- cluster-wide audit or runtime tag can enter this fold.
module Prodbox.Lifecycle.Teardown.Decision
  ( StackCleanupAuthority (..)
  , StackDecisionRefusal (..)
  , StackDesiredAbsenceDecision (..)
  , StackDecisionBindingError (..)
  , decideStackDesiredAbsence
  )
where

import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.OwnershipManifest
import Prodbox.Lifecycle.Teardown.Registry

data StackCleanupAuthority
  = VerifiedPrimaryCheckpoint
      !CheckpointProvenance
      !CheckpointVersion
  | VerifiedBackupCheckpoint
      !CheckpointProvenance
      !CheckpointVersion
  | VerifiedOwnershipManifest
      !OwnershipManifestProvenance
      !OwnershipManifestVersion
      ![ObservedResourceIdentity]
  deriving (Eq, Show)

data StackDecisionRefusal
  = StackExactObservationPartial
      !PartialEvidence
      !(NonEmpty ObservationFailure)
  | StackExactObservationUnobservable !(NonEmpty ObservationFailure)
  | StackPrimaryCheckpointAbsent
  | StackPrimaryCheckpointPartial !(NonEmpty ObservationFailure)
  | StackPrimaryCheckpointUnobservable !(NonEmpty ObservationFailure)
  | StackBackupCheckpointAbsent
  | StackBackupCheckpointPartial !(NonEmpty ObservationFailure)
  | StackBackupCheckpointUnobservable !(NonEmpty ObservationFailure)
  | StackOwnershipManifestAbsent
  | StackOwnershipManifestPartial !(NonEmpty ObservationFailure)
  | StackOwnershipManifestUnobservable !(NonEmpty ObservationFailure)
  | StackOwnershipManifestPresentWithoutCompleteEvidence
  | StackOwnershipManifestEntryMissing !RegisteredResourceKey
  deriving (Eq, Show)

-- | Sprint 4.97: the decision is indexed by the cleanup surface its evidence was
-- taken under, and every destroy arm carries the exact inventory the observation
-- reported rather than leaving each adapter to re-derive it.
--
-- The index is not a label the caller chooses. 'decideStackDesiredAbsence'
-- refuses with 'StackDecisionSurfaceMismatch' unless the witness it was handed
-- agrees with the surface the evidence scope itself carries — because an index
-- the caller picks proves nothing about the evidence, which is the failure this
-- sprint family exists to stop repeating.
--
-- __The retirement authorization the doctrine's decision table names is not
-- here, deliberately (Sprint @4.97@).__ Retirement runs on a different node:
-- @retireAwsStackCheckpointReference@ re-observes the absence and the
-- checkpoint pair itself and never consults this decision, so a payload minted
-- on this arm would be read by nothing. A value that exists only to look like a
-- proof is the exact shape [Pure FP Standards
-- § 7.1](../../../../documents/engineering/pure_fp_standards.md) names, and
-- adding one inside the sprint that repairs that shape would be self-defeating.
-- The payload lands with the conversion that consumes it.
data StackDesiredAbsenceDecision (surface :: CleanupSurface)
  = StackAlreadyAbsent
      !RegisteredResourceKey
      !(AbsenceEvidence 'ProviderApi)
  | StackDestroyFromVerifiedPrimary
      !RegisteredResourceKey
      !ExactResourceInventory
      !StackCleanupAuthority
  | StackRestoreBackupThenDestroy
      !RegisteredResourceKey
      !ExactResourceInventory
      !StackCleanupAuthority
  | StackDestroyFromVerifiedManifest
      !RegisteredResourceKey
      !ExactResourceInventory
      !StackCleanupAuthority
  | StackDesiredAbsenceRefused
      !RegisteredResourceKey
      !(NonEmpty StackDecisionRefusal)
  deriving (Eq, Show)

data StackDecisionBindingError
  = StackDecisionKeyNotSelected !RegisteredResourceKey
  | StackDecisionKeyUnregistered !RegisteredResourceKey
  | StackDecisionResourceIsNotStack !RegisteredResourceKey !ResourceKind
  | StackDecisionCheckpointKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | StackDecisionManifestKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | StackDecisionCheckpointScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | StackDecisionManifestScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | -- | Sprint 4.97: the surface witness the caller supplied disagreed with the
    -- surface the exact observation's own evidence scope was minted under.
    -- Expected (from the witness) first, actual (from the scope) second.
    StackDecisionSurfaceMismatch
      !CleanupSurface
      !CleanupSurface
  | StackDecisionCheckpointPairInvalid !CheckpointPairError
  deriving (Eq, Show)

decideStackDesiredAbsence
  :: CleanupSurfaceWitness surface
  -> RegisteredResourceKey
  -> CompleteObservationSet
  -> CheckpointPairObservation
  -> OwnershipManifestDecisionEvidence
  -> Either StackDecisionBindingError (StackDesiredAbsenceDecision surface)
decideStackDesiredAbsence surface stackKey observations checkpointPair manifest = do
  identity <- case lookupRegisteredIdentity stackKey of
    Nothing -> Left (StackDecisionKeyUnregistered stackKey)
    Just registered -> Right registered
  if registeredIdentityKind identity == Stack
    then Right ()
    else
      Left
        ( StackDecisionResourceIsNotStack
            stackKey
            (registeredIdentityKind identity)
        )
  exact <- case find ((== stackKey) . exactObservationResourceKey) exactObservations of
    Nothing -> Left (StackDecisionKeyNotSelected stackKey)
    Just observation -> Right observation
  if checkpointPairStackKey checkpointPair == stackKey
    then Right ()
    else
      Left
        ( StackDecisionCheckpointKeyMismatch
            stackKey
            (checkpointPairStackKey checkpointPair)
        )
  if ownershipManifestDecisionStackKey manifest == stackKey
    then Right ()
    else
      Left
        ( StackDecisionManifestKeyMismatch
            stackKey
            (ownershipManifestDecisionStackKey manifest)
        )
  let expectedScope = exactObservationEvidenceScope exact
      expectedSurface = cleanupSurfaceFromWitness surface
  -- Sprint 4.97: the index is checked, not assumed. The exact observation's
  -- scope already names the surface it was taken under, and the checkpoint pair
  -- and the manifest are pinned to that same scope below, so one comparison
  -- here binds the whole evidence set to the witness.
  if evidenceCleanupSurface expectedScope == expectedSurface
    then Right ()
    else
      Left
        ( StackDecisionSurfaceMismatch
            expectedSurface
            (evidenceCleanupSurface expectedScope)
        )
  if checkpointPairEvidenceScope checkpointPair == expectedScope
    then Right ()
    else
      Left
        ( StackDecisionCheckpointScopeMismatch
            expectedScope
            (checkpointPairEvidenceScope checkpointPair)
        )
  if ownershipManifestDecisionScope manifest == expectedScope
    then Right ()
    else
      Left
        ( StackDecisionManifestScopeMismatch
            expectedScope
            (ownershipManifestDecisionScope manifest)
        )
  validatedCheckpointPair <-
    case mkCheckpointPairObservation
      stackKey
      expectedScope
      (primaryCheckpointObservation checkpointPair)
      (backupCheckpointObservation checkpointPair) of
      Left err -> Left (StackDecisionCheckpointPairInvalid err)
      Right validated -> Right validated
  pure (decideExact surface exact validatedCheckpointPair manifest)
 where
  exactObservations = completeObservationSetObservations observations

-- | Private. The surface witness is taken only to fix this function's result
-- index to the one 'decideStackDesiredAbsence' already checked against the
-- evidence scope; there is no other way to reach a 'StackDesiredAbsenceDecision'
-- at a chosen surface, because this helper is not exported.
decideExact
  :: CleanupSurfaceWitness surface
  -> ExactResourceObservation
  -> CheckpointPairObservation
  -> OwnershipManifestDecisionEvidence
  -> StackDesiredAbsenceDecision surface
decideExact _surface exact checkpointPair manifest =
  case exactObservationResult exact of
    ExactResourceAbsent evidence -> StackAlreadyAbsent stackKey evidence
    ExactResourcePartial partial failures ->
      StackDesiredAbsenceRefused
        stackKey
        (StackExactObservationPartial partial failures :| [])
    ExactResourceUnobservable failures ->
      StackDesiredAbsenceRefused
        stackKey
        (StackExactObservationUnobservable failures :| [])
    ExactResourcePresent inventory -> decidePresent inventory
 where
  stackKey = exactObservationResourceKey exact
  primary = primaryCheckpointObservation checkpointPair
  backup = backupCheckpointObservation checkpointPair

  decidePresent inventory = case primaryCheckpointAuthority primary of
    Right (provenance, version) ->
      StackDestroyFromVerifiedPrimary
        stackKey
        inventory
        (VerifiedPrimaryCheckpoint provenance version)
    Left primaryRefusal -> case backupCheckpointAuthority backup of
      Right (provenance, version) ->
        StackRestoreBackupThenDestroy
          stackKey
          inventory
          (VerifiedBackupCheckpoint provenance version)
      Left backupRefusal -> case manifestAuthority stackKey manifest of
        Right (provenance, version, identities) ->
          StackDestroyFromVerifiedManifest
            stackKey
            inventory
            (VerifiedOwnershipManifest provenance version identities)
        Left manifestRefusal ->
          StackDesiredAbsenceRefused
            stackKey
            ( primaryRefusal
                :| [ backupRefusal
                   , manifestRefusal
                   ]
            )

primaryCheckpointAuthority
  :: CheckpointObservation
  -> Either
       StackDecisionRefusal
       (CheckpointProvenance, CheckpointVersion)
primaryCheckpointAuthority observation = case checkpointObservationResult observation of
  CheckpointPresent version ->
    Right (checkpointObservationProvenance observation, version)
  CheckpointAbsent -> Left StackPrimaryCheckpointAbsent
  CheckpointPartial failures -> Left (StackPrimaryCheckpointPartial failures)
  CheckpointUnobservable failures ->
    Left (StackPrimaryCheckpointUnobservable failures)

backupCheckpointAuthority
  :: CheckpointObservation
  -> Either
       StackDecisionRefusal
       (CheckpointProvenance, CheckpointVersion)
backupCheckpointAuthority observation = case checkpointObservationResult observation of
  CheckpointPresent version ->
    Right (checkpointObservationProvenance observation, version)
  CheckpointAbsent -> Left StackBackupCheckpointAbsent
  CheckpointPartial failures -> Left (StackBackupCheckpointPartial failures)
  CheckpointUnobservable failures ->
    Left (StackBackupCheckpointUnobservable failures)

manifestAuthority
  :: RegisteredResourceKey
  -> OwnershipManifestDecisionEvidence
  -> Either
       StackDecisionRefusal
       (OwnershipManifestProvenance, OwnershipManifestVersion, [ObservedResourceIdentity])
-- The purpose is deliberately not discriminated here. Both a create's
-- write-ahead record and a confirmed legacy-adoption receipt are cleanup
-- authority for a destroy -- that is what the adoption protocol exists to
-- supply -- and the direction that must refuse is the other one, which
-- 'Prodbox.ControlPlane.RegisteredStackCreationSubmitter.proveWriteAheadOwnership'
-- owns.
manifestAuthority key evidence = case ownershipManifestDecisionView evidence of
  OwnershipManifestDecisionComplete _purpose provenance version ->
    case ownershipManifestDecisionEntryIdentities key evidence of
      Nothing -> Left (StackOwnershipManifestEntryMissing key)
      Just identities -> Right (provenance, version, identities)
  OwnershipManifestDecisionObservation observation ->
    case ownershipManifestResult observation of
      OwnershipManifestPresent _ ->
        Left StackOwnershipManifestPresentWithoutCompleteEvidence
      OwnershipManifestAbsent -> Left StackOwnershipManifestAbsent
      OwnershipManifestPartial failures ->
        Left (StackOwnershipManifestPartial failures)
      OwnershipManifestUnobservable failures ->
        Left (StackOwnershipManifestUnobservable failures)
