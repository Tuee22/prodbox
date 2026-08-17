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
  deriving (Eq, Show)

data StackDesiredAbsenceDecision
  = StackAlreadyAbsent !RegisteredResourceKey !AbsenceEvidence
  | StackDestroyFromVerifiedPrimary
      !RegisteredResourceKey
      !StackCleanupAuthority
  | StackRestoreBackupThenDestroy
      !RegisteredResourceKey
      !StackCleanupAuthority
  | StackDestroyFromVerifiedManifest
      !RegisteredResourceKey
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
  | StackDecisionCheckpointPairInvalid !CheckpointPairError
  deriving (Eq, Show)

decideStackDesiredAbsence
  :: RegisteredResourceKey
  -> CompleteObservationSet
  -> CheckpointPairObservation
  -> OwnershipManifestDecisionEvidence
  -> Either StackDecisionBindingError StackDesiredAbsenceDecision
decideStackDesiredAbsence stackKey observations checkpointPair manifest = do
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
  pure (decideExact exact validatedCheckpointPair manifest)
 where
  exactObservations = completeObservationSetObservations observations

decideExact
  :: ExactResourceObservation
  -> CheckpointPairObservation
  -> OwnershipManifestDecisionEvidence
  -> StackDesiredAbsenceDecision
decideExact exact checkpointPair manifest =
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
    ExactResourcePresent _ -> decidePresent
 where
  stackKey = exactObservationResourceKey exact
  primary = primaryCheckpointObservation checkpointPair
  backup = backupCheckpointObservation checkpointPair

  decidePresent = case primaryCheckpointAuthority primary of
    Right (provenance, version) ->
      StackDestroyFromVerifiedPrimary
        stackKey
        (VerifiedPrimaryCheckpoint provenance version)
    Left primaryRefusal -> case backupCheckpointAuthority backup of
      Right (provenance, version) ->
        StackRestoreBackupThenDestroy
          stackKey
          (VerifiedBackupCheckpoint provenance version)
      Left backupRefusal -> case manifestAuthority manifest of
        Right (provenance, version) ->
          StackDestroyFromVerifiedManifest
            stackKey
            (VerifiedOwnershipManifest provenance version)
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
  :: OwnershipManifestDecisionEvidence
  -> Either
       StackDecisionRefusal
       (OwnershipManifestProvenance, OwnershipManifestVersion)
manifestAuthority evidence = case ownershipManifestDecisionView evidence of
  OwnershipManifestDecisionComplete provenance version ->
    Right
      ( provenance
      , version
      )
  OwnershipManifestDecisionObservation observation ->
    case ownershipManifestResult observation of
      OwnershipManifestPresent _ ->
        Left StackOwnershipManifestPresentWithoutCompleteEvidence
      OwnershipManifestAbsent -> Left StackOwnershipManifestAbsent
      OwnershipManifestPartial failures ->
        Left (StackOwnershipManifestPartial failures)
      OwnershipManifestUnobservable failures ->
        Left (StackOwnershipManifestUnobservable failures)
