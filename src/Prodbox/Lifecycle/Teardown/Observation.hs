{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}

-- | Flat external observations and the exact-keyed completeness boundary.
-- Checkpoints, ownership manifests, and terminal audits are nominally
-- distinct from exact resource truth and have no conversion into it.
module Prodbox.Lifecycle.Teardown.Observation
  ( ObservedResourceIdentity (..)
  , AbsenceEvidence (..)
  , PartialEvidence (..)
  , ExactResourceInventory (..)
  , ExactObservationResult (..)
  , ExactResourceObservation (..)
  , exactResourceObservationFor
  , CompleteObservationSet
  , completeObservationSetKeys
  , completeObservationSetObservations
  , CompleteObservationSetError (..)
  , mkCompleteObservationSet
  , ObservationDecisionRefusal (..)
  , CompleteObservationDecision (..)
  , decideCompleteObservationSet
  , CheckpointCopy (..)
  , CheckpointProvenance (..)
  , CheckpointVersion (..)
  , CheckpointResult (..)
  , CheckpointObservation (..)
  , CheckpointPairObservation (..)
  , CheckpointPairError (..)
  , mkCheckpointPairObservation
  , OwnershipManifestProvenance (..)
  , OwnershipManifestVersion (..)
  , OwnershipManifestResult (..)
  , OwnershipManifestObservation (..)
  , TerminalAuditQueryDigest (..)
  , TerminalAuditRetainedSetDigest (..)
  , TerminalAuditScope
  , terminalAuditEvidenceScope
  , terminalAuditQueryDigest
  , terminalAuditRetainedSetDigest
  , TerminalAuditScopeError (..)
  , mkTerminalAuditScope
  , TerminalAuditResult (..)
  , TerminalAuditObservation (..)
  )
where

import Data.List (group, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Prodbox.Lifecycle.AwsInventory (AwsInventory, AwsResource)
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Registry

newtype ObservedResourceIdentity = ObservedResourceIdentity Text
  deriving (Eq, Ord, Show)

newtype AbsenceEvidence = AbsenceEvidence Text
  deriving (Eq, Ord, Show)

newtype PartialEvidence = PartialEvidence [ObservedResourceIdentity]
  deriving (Eq, Show)

newtype ExactResourceInventory
  = ExactResourceInventory (NonEmpty ObservedResourceIdentity)
  deriving (Eq, Show)

data ExactObservationResult
  = ExactResourceAbsent !AbsenceEvidence
  | ExactResourcePresent !ExactResourceInventory
  | ExactResourcePartial !PartialEvidence !(NonEmpty ObservationFailure)
  | ExactResourceUnobservable !(NonEmpty ObservationFailure)
  deriving (Eq, Show)

-- | One provider response bound to the exact registered identity it was asked
-- to observe.  Its constructor is intentionally public: external decoders may
-- produce malformed or stale bindings, and 'mkCompleteObservationSet' is the
-- sole admission boundary that validates them.
data ExactResourceObservation = ExactResourceObservation
  { exactObservationResourceKey :: !RegisteredResourceKey
  , exactObservationCoordinateDigest :: !ManagedResourceCoordinateDigest
  , exactObservationAuthority :: !ObservationAuthority
  , exactObservationRevision :: !ObservationRevision
  , exactObservationEvidenceScope :: !ObservationEvidenceScope
  , exactObservationResult :: !ExactObservationResult
  }
  deriving (Eq, Show)

exactResourceObservationFor
  :: RegisteredIdentity
  -> ObservationRevision
  -> ObservationEvidenceScope
  -> ExactObservationResult
  -> ExactResourceObservation
exactResourceObservationFor identity revision scope result =
  ExactResourceObservation
    { exactObservationResourceKey = registeredIdentityKey identity
    , exactObservationCoordinateDigest =
        registeredIdentityCoordinateDigest identity
    , exactObservationAuthority =
        registeredIdentityObservationAuthority identity
    , exactObservationRevision = revision
    , exactObservationEvidenceScope = scope
    , exactObservationResult = result
    }

-- | Opaque proof that every selected key has exactly one correctly bound
-- observation.  Partial and unobservable results remain valid members of this
-- structural proof; the decision fold refuses them separately.
data CompleteObservationSet = CompleteObservationSet
  { internalCompleteObservationKeys :: ![RegisteredResourceKey]
  , internalCompleteObservations :: !(Map RegisteredResourceKey ExactResourceObservation)
  }
  deriving (Eq, Show)

completeObservationSetKeys :: CompleteObservationSet -> [RegisteredResourceKey]
completeObservationSetKeys = internalCompleteObservationKeys

completeObservationSetObservations
  :: CompleteObservationSet -> [ExactResourceObservation]
completeObservationSetObservations complete =
  [ observation
  | key <- internalCompleteObservationKeys complete
  , Just observation <- [Map.lookup key (internalCompleteObservations complete)]
  ]

data CompleteObservationSetError
  = ObservationSetRegistryRevisionMismatch !RegistryRevision !RegistryRevision
  | ObservationSetOperationInvalid !LifecycleOperation
  | ObservationSelectionDuplicateKey !RegisteredResourceKey
  | ObservationSelectionUnregisteredKey !RegisteredResourceKey
  | ObservationSelectionNotAllowed !CleanupSelectionError
  | ObservationSelectionAwsScopeRequired !RegisteredResourceKey
  | ObservationDuplicateKey !RegisteredResourceKey
  | ObservationUnexpectedKey !RegisteredResourceKey
  | ObservationMissingKey !RegisteredResourceKey
  | ObservationCoordinateMismatch
      !RegisteredResourceKey
      !ManagedResourceCoordinateDigest
      !ManagedResourceCoordinateDigest
  | ObservationAuthorityMismatch
      !RegisteredResourceKey
      !ObservationAuthority
      !ObservationAuthority
  | ObservationSurfaceMismatch
      !RegisteredResourceKey
      !CleanupSurface
      !CleanupSurface
  | ObservationRegistryRevisionMismatch
      !RegisteredResourceKey
      !RegistryRevision
      !RegistryRevision
  | ObservationDurableRunScopeMismatch
      !RegisteredResourceKey
      !DurableObservationRunScope
      !DurableObservationRunScope
  | ObservationFoundationMismatch
      !RegisteredResourceKey
      !LinuxRke2FoundationId
      !LinuxRke2FoundationId
  | ObservationAwsScopeMismatch
      !RegisteredResourceKey
      !(Maybe AwsScope)
      !(Maybe AwsScope)
  | ObservationOperationMismatch
      !RegisteredResourceKey
      !LifecycleOperation
      !LifecycleOperation
  deriving (Eq, Show)

mkCompleteObservationSet
  :: ObservationEvidenceScope
  -> [RegisteredResourceKey]
  -> [ExactResourceObservation]
  -> Either CompleteObservationSetError CompleteObservationSet
mkCompleteObservationSet expectedScope selectedKeys observations = do
  validateExpectedScope expectedScope
  case duplicateValues selectedKeys of
    duplicateKey : _ -> Left (ObservationSelectionDuplicateKey duplicateKey)
    [] -> Right ()
  selectedIdentities <- mapM resolveSelection selectedKeys
  mapM_ (validateSelection expectedScope) selectedIdentities
  case duplicateValues (map exactObservationResourceKey observations) of
    duplicateKey : _ -> Left (ObservationDuplicateKey duplicateKey)
    [] -> Right ()
  mapM_ (rejectUnexpected selectedKeys) observations
  let observationsByKey =
        Map.fromList
          [ (exactObservationResourceKey observation, observation)
          | observation <- observations
          ]
  mapM_ (requireObservation observationsByKey) selectedKeys
  mapM_
    (validateObservationBinding expectedScope observationsByKey)
    selectedIdentities
  Right
    CompleteObservationSet
      { internalCompleteObservationKeys = selectedKeys
      , internalCompleteObservations = observationsByKey
      }

data ObservationDecisionRefusal
  = ExactObservationPartialRefusal
      !RegisteredResourceKey
      !PartialEvidence
      !(NonEmpty ObservationFailure)
  | ExactObservationUnobservableRefusal
      !RegisteredResourceKey
      !(NonEmpty ObservationFailure)
  deriving (Eq, Show)

data CompleteObservationDecision
  = AllSelectedResourcesAbsent
  | SelectedResourcesRequireCleanup !(NonEmpty RegisteredResourceKey)
  | CompleteObservationsRefused !(NonEmpty ObservationDecisionRefusal)
  deriving (Eq, Show)

decideCompleteObservationSet
  :: CompleteObservationSet -> CompleteObservationDecision
decideCompleteObservationSet complete =
  case NonEmpty.nonEmpty refusals of
    Just nonEmptyRefusals -> CompleteObservationsRefused nonEmptyRefusals
    Nothing -> case NonEmpty.nonEmpty presentKeys of
      Just nonEmptyPresent -> SelectedResourcesRequireCleanup nonEmptyPresent
      Nothing -> AllSelectedResourcesAbsent
 where
  observations = completeObservationSetObservations complete
  presentKeys =
    [ exactObservationResourceKey observation
    | observation <- observations
    , ExactResourcePresent _ <- [exactObservationResult observation]
    ]
  refusals = concatMap observationRefusals observations

  observationRefusals observation = case exactObservationResult observation of
    ExactResourcePartial partial failures ->
      [ ExactObservationPartialRefusal
          (exactObservationResourceKey observation)
          partial
          failures
      ]
    ExactResourceUnobservable failures ->
      [ ExactObservationUnobservableRefusal
          (exactObservationResourceKey observation)
          failures
      ]
    ExactResourceAbsent _ -> []
    ExactResourcePresent _ -> []

data CheckpointCopy
  = PrimaryCheckpointCopy
  | BackupCheckpointCopy
  deriving (Eq, Ord, Show)

newtype CheckpointProvenance = CheckpointProvenance Text
  deriving (Eq, Ord, Show)

newtype CheckpointVersion = CheckpointVersion Text
  deriving (Eq, Ord, Show)

data CheckpointResult
  = CheckpointAbsent
  | CheckpointPresent !CheckpointVersion
  | CheckpointPartial !(NonEmpty ObservationFailure)
  | CheckpointUnobservable !(NonEmpty ObservationFailure)
  deriving (Eq, Show)

data CheckpointObservation = CheckpointObservation
  { checkpointObservationStackKey :: !RegisteredResourceKey
  , checkpointObservationCopy :: !CheckpointCopy
  , checkpointObservationProvenance :: !CheckpointProvenance
  , checkpointObservationEvidenceScope :: !ObservationEvidenceScope
  , checkpointObservationResult :: !CheckpointResult
  }
  deriving (Eq, Show)

data CheckpointPairObservation = CheckpointPairObservation
  { checkpointPairStackKey :: !RegisteredResourceKey
  , checkpointPairEvidenceScope :: !ObservationEvidenceScope
  , primaryCheckpointObservation :: !CheckpointObservation
  , backupCheckpointObservation :: !CheckpointObservation
  }
  deriving (Eq, Show)

data CheckpointPairError
  = CheckpointPairUnregisteredKey !RegisteredResourceKey
  | CheckpointPairResourceIsNotStack !RegisteredResourceKey !ResourceKind
  | CheckpointPairKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
      !RegisteredResourceKey
  | CheckpointPairScopeMismatch
      !RegisteredResourceKey
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | CheckpointPairCopyMissing !CheckpointCopy
  deriving (Eq, Show)

mkCheckpointPairObservation
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> CheckpointObservation
  -> CheckpointObservation
  -> Either CheckpointPairError CheckpointPairObservation
mkCheckpointPairObservation stackKey expectedScope left right = do
  identity <- case lookupRegisteredIdentity stackKey of
    Nothing -> Left (CheckpointPairUnregisteredKey stackKey)
    Just registered -> Right registered
  if registeredIdentityKind identity == Stack
    then Right ()
    else
      Left
        ( CheckpointPairResourceIsNotStack
            stackKey
            (registeredIdentityKind identity)
        )
  mapM_ validateKey [left, right]
  mapM_ validateScope [left, right]
  case (checkpointObservationCopy left, checkpointObservationCopy right) of
    (PrimaryCheckpointCopy, BackupCheckpointCopy) -> build left right
    (BackupCheckpointCopy, PrimaryCheckpointCopy) -> build right left
    (PrimaryCheckpointCopy, PrimaryCheckpointCopy) ->
      Left (CheckpointPairCopyMissing BackupCheckpointCopy)
    (BackupCheckpointCopy, BackupCheckpointCopy) ->
      Left (CheckpointPairCopyMissing PrimaryCheckpointCopy)
 where
  validateKey observation
    | checkpointObservationStackKey observation == stackKey = Right ()
    | otherwise =
        Left
          ( CheckpointPairKeyMismatch
              stackKey
              (checkpointObservationStackKey left)
              (checkpointObservationStackKey right)
          )

  validateScope observation
    | checkpointObservationEvidenceScope observation == expectedScope = Right ()
    | otherwise =
        Left
          ( CheckpointPairScopeMismatch
              (checkpointObservationStackKey observation)
              expectedScope
              (checkpointObservationEvidenceScope observation)
          )

  build primary backup =
    Right
      CheckpointPairObservation
        { checkpointPairStackKey = stackKey
        , checkpointPairEvidenceScope = expectedScope
        , primaryCheckpointObservation = primary
        , backupCheckpointObservation = backup
        }

newtype OwnershipManifestProvenance = OwnershipManifestProvenance Text
  deriving (Eq, Ord, Show)

newtype OwnershipManifestVersion = OwnershipManifestVersion Text
  deriving (Eq, Ord, Show)

data OwnershipManifestResult
  = OwnershipManifestAbsent
  | OwnershipManifestPresent !OwnershipManifestVersion
  | OwnershipManifestPartial !(NonEmpty ObservationFailure)
  | OwnershipManifestUnobservable !(NonEmpty ObservationFailure)
  deriving (Eq, Show)

data OwnershipManifestObservation = OwnershipManifestObservation
  { ownershipManifestStackKey :: !RegisteredResourceKey
  , ownershipManifestProvenance :: !OwnershipManifestProvenance
  , ownershipManifestEvidenceScope :: !ObservationEvidenceScope
  , ownershipManifestResult :: !OwnershipManifestResult
  }
  deriving (Eq, Show)

newtype TerminalAuditQueryDigest = TerminalAuditQueryDigest Text
  deriving (Eq, Ord, Show)

newtype TerminalAuditRetainedSetDigest = TerminalAuditRetainedSetDigest Text
  deriving (Eq, Ord, Show)

data TerminalAuditScope (surface :: CleanupSurface) = TerminalAuditScope
  { internalTerminalAuditEvidenceScope :: !ObservationEvidenceScope
  , internalTerminalAuditQueryDigest :: !TerminalAuditQueryDigest
  , internalTerminalAuditRetainedSetDigest :: !TerminalAuditRetainedSetDigest
  }
  deriving (Eq, Show)

terminalAuditEvidenceScope
  :: TerminalAuditScope surface -> ObservationEvidenceScope
terminalAuditEvidenceScope = internalTerminalAuditEvidenceScope

terminalAuditQueryDigest :: TerminalAuditScope surface -> TerminalAuditQueryDigest
terminalAuditQueryDigest = internalTerminalAuditQueryDigest

terminalAuditRetainedSetDigest
  :: TerminalAuditScope surface -> TerminalAuditRetainedSetDigest
terminalAuditRetainedSetDigest = internalTerminalAuditRetainedSetDigest

data TerminalAuditScopeError
  = TerminalAuditSurfaceMismatch !CleanupSurface !CleanupSurface
  | TerminalAuditOperationMismatch !LifecycleOperation
  | TerminalAuditRegistryRevisionMismatch !RegistryRevision !RegistryRevision
  deriving (Eq, Show)

mkTerminalAuditScope
  :: CleanupSurfaceWitness surface
  -> ObservationEvidenceScope
  -> TerminalAuditQueryDigest
  -> TerminalAuditRetainedSetDigest
  -> Either TerminalAuditScopeError (TerminalAuditScope surface)
mkTerminalAuditScope surfaceWitness evidenceScope queryDigest retainedSetDigest
  | evidenceCleanupSurface evidenceScope /= expectedSurface =
      Left
        ( TerminalAuditSurfaceMismatch
            expectedSurface
            (evidenceCleanupSurface evidenceScope)
        )
  | evidenceLifecycleOperation evidenceScope /= RunTerminalEscapeAudit =
      Left
        ( TerminalAuditOperationMismatch
            (evidenceLifecycleOperation evidenceScope)
        )
  | evidenceRegistryRevision evidenceScope /= lifecycleRegistryRevision =
      Left
        ( TerminalAuditRegistryRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision evidenceScope)
        )
  | otherwise =
      Right
        TerminalAuditScope
          { internalTerminalAuditEvidenceScope = evidenceScope
          , internalTerminalAuditQueryDigest = queryDigest
          , internalTerminalAuditRetainedSetDigest = retainedSetDigest
          }
 where
  expectedSurface = cleanupSurfaceFromWitness surfaceWitness

data TerminalAuditResult
  = TerminalAuditConfirmedClean !AwsInventory
  | TerminalAuditFoundEscapes !AwsInventory !(NonEmpty AwsResource)
  | TerminalAuditUnobservable
      !AwsInventory
      !(NonEmpty ObservationFailure)
  deriving (Eq, Show)

data TerminalAuditObservation (surface :: CleanupSurface)
  = TerminalAuditObservation
  { terminalAuditScope :: !(TerminalAuditScope surface)
  , terminalAuditRevision :: !ObservationRevision
  , terminalAuditResult :: !TerminalAuditResult
  }
  deriving (Eq, Show)

validateExpectedScope
  :: ObservationEvidenceScope -> Either CompleteObservationSetError ()
validateExpectedScope scope
  | evidenceRegistryRevision scope /= lifecycleRegistryRevision =
      Left
        ( ObservationSetRegistryRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision scope)
        )
  | evidenceLifecycleOperation scope /= ReconcileDesiredAbsent =
      Left (ObservationSetOperationInvalid (evidenceLifecycleOperation scope))
  | otherwise = Right ()

resolveSelection
  :: RegisteredResourceKey
  -> Either CompleteObservationSetError RegisteredIdentity
resolveSelection key = case lookupRegisteredIdentity key of
  Nothing -> Left (ObservationSelectionUnregisteredKey key)
  Just identity -> Right identity

validateSelection
  :: ObservationEvidenceScope
  -> RegisteredIdentity
  -> Either CompleteObservationSetError ()
validateSelection scope identity
  | not (cleanupSurfaceAllows (evidenceCleanupSurface scope) identity) =
      Left
        ( ObservationSelectionNotAllowed
            (selectionError (evidenceCleanupSurface scope) identity)
        )
  | coordinateIsAws (registeredIdentityCoordinate identity)
      && evidenceAwsScope scope == Nothing =
      Left (ObservationSelectionAwsScopeRequired (registeredIdentityKey identity))
  | otherwise = Right ()

selectionError :: CleanupSurface -> RegisteredIdentity -> CleanupSelectionError
selectionError surface identity = case registeredIdentityLifecycleClass identity of
  Nothing -> LocalSubstrateNotAllowedOnSurface (registeredIdentityKey identity) surface
  Just lifecycle ->
    ManagedResourceNotAllowedOnSurface
      (registeredIdentityKey identity)
      lifecycle
      surface

rejectUnexpected
  :: [RegisteredResourceKey]
  -> ExactResourceObservation
  -> Either CompleteObservationSetError ()
rejectUnexpected selected observation
  | exactObservationResourceKey observation `elem` selected = Right ()
  | otherwise = Left (ObservationUnexpectedKey (exactObservationResourceKey observation))

requireObservation
  :: Map RegisteredResourceKey ExactResourceObservation
  -> RegisteredResourceKey
  -> Either CompleteObservationSetError ()
requireObservation observations key
  | Map.member key observations = Right ()
  | otherwise = Left (ObservationMissingKey key)

validateObservationBinding
  :: ObservationEvidenceScope
  -> Map RegisteredResourceKey ExactResourceObservation
  -> RegisteredIdentity
  -> Either CompleteObservationSetError ()
validateObservationBinding expectedScope observations identity =
  case Map.lookup key observations of
    Nothing -> Left (ObservationMissingKey key)
    Just observation
      | exactObservationCoordinateDigest observation /= expectedCoordinate ->
          Left
            ( ObservationCoordinateMismatch
                key
                expectedCoordinate
                (exactObservationCoordinateDigest observation)
            )
      | exactObservationAuthority observation /= expectedAuthority ->
          Left
            ( ObservationAuthorityMismatch
                key
                expectedAuthority
                (exactObservationAuthority observation)
            )
      | otherwise ->
          validateScopeBinding key expectedScope (exactObservationEvidenceScope observation)
 where
  key = registeredIdentityKey identity
  expectedCoordinate = registeredIdentityCoordinateDigest identity
  expectedAuthority = registeredIdentityObservationAuthority identity

validateScopeBinding
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> ObservationEvidenceScope
  -> Either CompleteObservationSetError ()
validateScopeBinding key expected actual
  | evidenceCleanupSurface actual /= evidenceCleanupSurface expected =
      Left
        ( ObservationSurfaceMismatch
            key
            (evidenceCleanupSurface expected)
            (evidenceCleanupSurface actual)
        )
  | evidenceRegistryRevision actual /= evidenceRegistryRevision expected =
      Left
        ( ObservationRegistryRevisionMismatch
            key
            (evidenceRegistryRevision expected)
            (evidenceRegistryRevision actual)
        )
  | evidenceDurableRunScope actual /= evidenceDurableRunScope expected =
      Left
        ( ObservationDurableRunScopeMismatch
            key
            (evidenceDurableRunScope expected)
            (evidenceDurableRunScope actual)
        )
  | evidenceLinuxRke2Foundation actual /= evidenceLinuxRke2Foundation expected =
      Left
        ( ObservationFoundationMismatch
            key
            (evidenceLinuxRke2Foundation expected)
            (evidenceLinuxRke2Foundation actual)
        )
  | evidenceAwsScope actual /= evidenceAwsScope expected =
      Left
        ( ObservationAwsScopeMismatch
            key
            (evidenceAwsScope expected)
            (evidenceAwsScope actual)
        )
  | evidenceLifecycleOperation actual /= evidenceLifecycleOperation expected =
      Left
        ( ObservationOperationMismatch
            key
            (evidenceLifecycleOperation expected)
            (evidenceLifecycleOperation actual)
        )
  | otherwise = Right ()

duplicateValues :: (Ord value) => [value] -> [value]
duplicateValues values =
  [ value
  | groupedValues@(value : _) <- group (sort values)
  , length groupedValues > 1
  ]
