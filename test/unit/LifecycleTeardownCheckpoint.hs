{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownCheckpoint
  ( lifecycleTeardownCheckpointSuite
  )
where

import Control.Monad (forM_, void)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.Teardown.CapabilityCustody.Universe
  ( CapabilityDisposition (CapabilityDischargedByAbsence)
  , CustodialCapability (CheckpointCapability)
  , CustodyIndex (CustodyRetire)
  , DependantAbsenceProof (DependantAbsenceProof)
  )
import Prodbox.Lifecycle.Teardown.Checkpoint
import Prodbox.Lifecycle.Teardown.Execution
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownCheckpointSuite :: SuiteBuilder ()
lifecycleTeardownCheckpointSuite =
  describe "Sprint 4.85 checkpoint restore and retirement proof boundary" $ do
    it "mints restored-primary authority only from exact operation-bound read-back" $ do
      let request = expectRight (mkCheckpointRestoreRequest restoreOperation AwsEksKey scope backup)
          verified =
            expectRight
              ( confirmRestoredCheckpoint
                  request
                  (CheckpointRestoreReadBack restoreOperation restoredPrimary)
              )
      checkpointRestoreStackKey request `shouldBe` AwsEksKey
      checkpointRestoreBackupVersion request `shouldBe` checkpointVersion
      verifiedRestoredPrimaryOperationId verified `shouldBe` restoreOperation
      verifiedRestoredPrimaryStackKey verified `shouldBe` AwsEksKey
      verifiedRestoredPrimaryVersion verified `shouldBe` checkpointVersion

    it "rejects an unavailable or non-backup restore source" $ do
      mkCheckpointRestoreRequest restoreOperation AwsEksKey scope restoredPrimary
        `shouldBe` Left (CheckpointRestoreBackupCopyInvalid PrimaryCheckpointCopy)
      let unavailable =
            backup
              { checkpointObservationResult =
                  CheckpointUnobservable (ObservationFailure "backup unavailable" :| [])
              }
      mkCheckpointRestoreRequest restoreOperation AwsEksKey scope unavailable
        `shouldBe` Left
          ( CheckpointRestoreBackupUnavailable
              (CheckpointUnobservable (ObservationFailure "backup unavailable" :| []))
          )

    it "rejects wrong operation, copy, scope, key, and restored version" $ do
      let request = expectRight (mkCheckpointRestoreRequest restoreOperation AwsEksKey scope backup)
          otherScope = mkScope (DurableObservationRunScope "other-run") Cascade
          wrongKey = restoredPrimary {checkpointObservationStackKey = AwsTestKey}
          wrongCopy = restoredPrimary {checkpointObservationCopy = BackupCheckpointCopy}
          wrongVersion =
            restoredPrimary
              { checkpointObservationResult =
                  CheckpointPresent (CheckpointVersion "sha256:other")
              }
          wrongBoundScope =
            restoredPrimary {checkpointObservationEvidenceScope = otherScope}
      confirmRestoredCheckpoint request (CheckpointRestoreReadBack otherOperation restoredPrimary)
        `shouldBe` Left
          (CheckpointRestoreReadBackOperationMismatch restoreOperation otherOperation)
      confirmRestoredCheckpoint request (CheckpointRestoreReadBack restoreOperation wrongKey)
        `shouldBe` Left (CheckpointRestorePrimaryKeyMismatch AwsEksKey AwsTestKey)
      confirmRestoredCheckpoint request (CheckpointRestoreReadBack restoreOperation wrongCopy)
        `shouldBe` Left (CheckpointRestorePrimaryCopyInvalid BackupCheckpointCopy)
      confirmRestoredCheckpoint request (CheckpointRestoreReadBack restoreOperation wrongBoundScope)
        `shouldBe` Left (CheckpointRestorePrimaryScopeMismatch scope otherScope)
      confirmRestoredCheckpoint request (CheckpointRestoreReadBack restoreOperation wrongVersion)
        `shouldBe` Left
          ( CheckpointRestorePrimaryVersionMismatch
              checkpointVersion
              (CheckpointVersion "sha256:other")
          )

    it "separates restore attempts from exact recovery read-back evidence" $ do
      let noMutation =
            expectRight
              ( mkCheckpointRestoreNoMutationOutcome
                  restoreOperation
                  AwsEksKey
                  scope
                  pair
              )
          absentPrimary =
            primary {checkpointObservationResult = CheckpointAbsent}
          restoreRequiredPair =
            expectRight
              (mkCheckpointPairObservation AwsEksKey scope absentPrimary backup)
          noCheckpointPair =
            expectRight
              ( mkCheckpointPairObservation
                  AwsEksKey
                  scope
                  absentPrimary
                  backup {checkpointObservationResult = CheckpointAbsent}
              )
          partialPrimaryResult =
            CheckpointPartial (ObservationFailure "primary inventory incomplete" :| [])
          incompletePair =
            expectRight
              ( mkCheckpointPairObservation
                  AwsEksKey
                  scope
                  primary {checkpointObservationResult = partialPrimaryResult}
                  backup {checkpointObservationResult = CheckpointAbsent}
              )
      checkpointRestoreOutcomeDisposition noMutation
        `shouldBe` CheckpointRestorePrimaryAlreadyAvailable
      mkCheckpointRestoreNoMutationOutcome
        restoreOperation
        AwsEksKey
        scope
        restoreRequiredPair
        `shouldBe` Left (CheckpointRestoreMutationRequired checkpointVersion)

      let request = expectRight (mkCheckpointRestoreRequest restoreOperation AwsEksKey scope backup)
          responseLost = recordCheckpointRestoreAttempt request CheckpointRestoreResponseLost
      checkpointRestoreOutcomeDisposition responseLost
        `shouldBe` CheckpointRestoreMutationAttempted CheckpointRestoreResponseLost

      let recovered =
            expectRight
              ( confirmCheckpointRecoveryReadBack
                  restoreOperation
                  AwsEksKey
                  scope
                  pair
              )
          unavailable =
            expectRight
              ( confirmCheckpointRecoveryReadBack
                  restoreOperation
                  AwsEksKey
                  scope
                  noCheckpointPair
              )
      checkpointRecoveryDisposition recovered
        `shouldBe` CheckpointRecoveryPrimaryAvailable primaryProvenance checkpointVersion
      checkpointRecoveryDisposition unavailable
        `shouldBe` CheckpointRecoveryNoUsableCheckpoint CheckpointAbsent CheckpointAbsent
      confirmCheckpointRecoveryReadBack
        restoreOperation
        AwsEksKey
        scope
        restoreRequiredPair
        `shouldBe` Left
          (CheckpointRestorePrimaryNotRecovered checkpointVersion CheckpointAbsent)
      mkCheckpointRestoreNoMutationOutcome
        restoreOperation
        AwsEksKey
        scope
        incompletePair
        `shouldBe` Left
          ( CheckpointRestoreRecoveryIncomplete
              PrimaryCheckpointCopy
              partialPrimaryResult
          )
      confirmCheckpointRecoveryReadBack
        restoreOperation
        AwsEksKey
        scope
        incompletePair
        `shouldBe` Left
          ( CheckpointRestoreRecoveryIncomplete
              PrimaryCheckpointCopy
              partialPrimaryResult
          )

    it "skips restore only from exact stack absence, even with stale checkpoint material" $ do
      let backupOnlyPair =
            expectRight
              ( mkCheckpointPairObservation
                  AwsEksKey
                  scope
                  primary {checkpointObservationResult = CheckpointAbsent}
                  backup
              )
          notRequired =
            expectRight
              ( mkCheckpointRestoreNotRequiredOutcome
                  restoreOperation
                  AwsEksKey
                  scope
                  exactAbsent
              )
          noRestoreReadBack =
            expectRight
              ( confirmCheckpointNoRestoreReadBack
                  restoreOperation
                  AwsEksKey
                  scope
                  exactAbsent
              )
      mkCheckpointRestoreNoMutationOutcome
        restoreOperation
        AwsEksKey
        scope
        backupOnlyPair
        `shouldBe` Left (CheckpointRestoreMutationRequired checkpointVersion)
      checkpointRestoreOutcomeDisposition notRequired
        `shouldBe` CheckpointRestoreResourceAlreadyAbsent absenceEvidence
      checkpointRecoveryDisposition noRestoreReadBack
        `shouldBe` CheckpointRecoveryRestoreNotRequired absenceEvidence
      mkCheckpointRestoreNotRequiredOutcome
        restoreOperation
        AwsEksKey
        scope
        exactPresent
        `shouldBe` Left (CheckpointRestoreResourceNotAbsent presentInventory)

    it "refuses cross-key and cross-scope exact-absence no-restore evidence" $ do
      let otherRun = DurableObservationRunScope "cleanup-run/other"
          otherScope = mkScope otherRun Cascade
          wrongKey = exactAbsent {exactObservationResourceKey = AwsTestKey}
          wrongScope = exactAbsent {exactObservationEvidenceScope = otherScope}
          outcomeFor observation =
            mkCheckpointRestoreNotRequiredOutcome
              restoreOperation
              AwsEksKey
              scope
              observation
          readBackFor observation =
            confirmCheckpointNoRestoreReadBack
              restoreOperation
              AwsEksKey
              scope
              observation
      forM_
        [ void (outcomeFor wrongKey)
        , void (readBackFor wrongKey)
        ]
        $ \result ->
          result
            `shouldBe` Left
              ( CheckpointRestoreAbsenceBindingInvalid
                  (ObservationUnexpectedKey AwsTestKey)
              )
      forM_
        [ void (outcomeFor wrongScope)
        , void (readBackFor wrongScope)
        ]
        $ \result ->
          result
            `shouldBe` Left
              ( CheckpointRestoreAbsenceBindingInvalid
                  ( ObservationDurableRunScopeMismatch
                      AwsEksKey
                      fixtureRunScope
                      otherRun
                  )
              )
      confirmCheckpointNoRestoreReadBack
        restoreOperation
        AwsEksKey
        scope
        exactPresent
        `shouldBe` Left (CheckpointRestoreResourceNotAbsent presentInventory)

    it "authorizes retirement only after exact provider absence" $ do
      let authorization =
            expectRight
              ( authorizeCheckpointRetirement
                  retirementOperation
                  RetireActiveCheckpointReference
                  scope
                  eksCheckpointDischarged
                  exactAbsent
                  pair
              )
      checkpointRetirementOperationId authorization `shouldBe` retirementOperation
      checkpointRetirementStackKey authorization `shouldBe` AwsEksKey
      checkpointRetirementPolicy authorization
        `shouldBe` RetireActiveCheckpointReference
      authorizeCheckpointRetirement
        retirementOperation
        RetireActiveCheckpointReference
        scope
        eksCheckpointDischarged
        exactPresent
        pair
        `shouldBe` Left (CheckpointRetirementResourceNotAbsent presentInventory)

    it "refuses a retirement whose discharge names another capability" $ do
      -- Sprint 4.89: retiring the reference ends this run's custody of the
      -- capability that made the stack's resources destroyable, so the
      -- authorization consumes a discharge rather than producing one. There is
      -- no destroy constructor, so a caller holding a checkpoint and nothing
      -- else has nothing to pass here at all; what this measures is that the
      -- discharge it did pass is about this checkpoint.
      authorizeCheckpointRetirement
        retirementOperation
        RetireActiveCheckpointReference
        scope
        foreignCheckpointDischarged
        exactAbsent
        pair
        `shouldBe` Left
          ( CheckpointRetirementCustodyForeign
              (CheckpointCapability AwsEksKey)
              (CheckpointCapability AwsTestKey)
          )

    it "refuses retirement when either checkpoint copy inventory is unknown" $ do
      let damagedBackup =
            backup
              { checkpointObservationResult =
                  CheckpointPartial (ObservationFailure "short read" :| [])
              }
          damagedPair = expectRight (mkCheckpointPairObservation AwsEksKey scope primary damagedBackup)
      authorizeCheckpointRetirement
        retirementOperation
        RetireActiveCheckpointReference
        scope
        eksCheckpointDischarged
        exactAbsent
        damagedPair
        `shouldBe` Left
          ( CheckpointRetirementCheckpointInventoryIncomplete
              BackupCheckpointCopy
              (CheckpointPartial (ObservationFailure "short read" :| []))
          )

    it "requires read-back of the exact logically retired aggregate reference" $ do
      let authorization =
            expectRight
              ( authorizeCheckpointRetirement
                  retirementOperation
                  RetireActiveCheckpointReference
                  scope
                  eksCheckpointDischarged
                  exactAbsent
                  pair
              )
          evidence =
            expectRight
              (confirmCheckpointRetirement authorization retiredObservation)
      checkpointRetirementEvidenceOperationId evidence `shouldBe` retirementOperation
      checkpointRetirementEvidenceStackKey evidence `shouldBe` AwsEksKey
      checkpointRetirementEvidenceScope evidence `shouldBe` scope
      confirmCheckpointRetirement
        authorization
        retiredObservation
          { checkpointRetirementObservationReferenceDisposition =
              CheckpointReferenceStillCurrent checkpointVersion
          }
        `shouldBe` Left
          ( CheckpointRetirementDispositionMismatch
              (CheckpointReferenceRetired checkpointVersion)
              (CheckpointReferenceStillCurrent checkpointVersion)
          )

    it "binds retirement attempts to exact-absence authorization without minting evidence" $ do
      let authorization =
            expectRight
              ( authorizeCheckpointRetirement
                  retirementOperation
                  RetireActiveCheckpointReference
                  scope
                  eksCheckpointDischarged
                  exactAbsent
                  pair
              )
          outcome =
            recordCheckpointRetirementAttempt
              authorization
              CheckpointRetirementResponseLost
      checkpointRetirementOutcomeOperationId outcome `shouldBe` retirementOperation
      checkpointRetirementOutcomeStackKey outcome `shouldBe` AwsEksKey
      checkpointRetirementOutcomeScope outcome `shouldBe` scope
      checkpointRetirementOutcomeAttempt outcome
        `shouldBe` CheckpointRetirementResponseLost

    it "binds logical-retirement read-back to both custody provenances" $ do
      let authorization =
            expectRight
              ( authorizeCheckpointRetirement
                  retirementOperation
                  RetireActiveCheckpointReference
                  scope
                  eksCheckpointDischarged
                  exactAbsent
                  pair
              )
      confirmCheckpointRetirement authorization retiredObservation
        `shouldSatisfy` isRight
      confirmCheckpointRetirement
        authorization
        retiredObservation
          { checkpointRetirementObservationBackupProvenance =
              CheckpointProvenance "wrong-backup"
          }
        `shouldBe` Left
          ( CheckpointRetirementProvenanceMismatch
              BackupCheckpointCopy
              backupProvenance
              (CheckpointProvenance "wrong-backup")
          )

    it "keeps stack, lifecycle surface, and registry revision exact" $ do
      mkCheckpointRestoreRequest restoreOperation AwsEbsPerRunTestKey scope backup
        `shouldBe` Left
          (CheckpointRestoreTargetIsNotStack AwsEbsPerRunTestKey VolumeFamily)
      let explicitLongLivedScope = mkScope fixtureRunScope ExplicitLongLived
      mkCheckpointRestoreRequest
        restoreOperation
        AwsEksKey
        explicitLongLivedScope
        backup {checkpointObservationEvidenceScope = explicitLongLivedScope}
        `shouldBe` Left
          (CheckpointRestoreTargetNotAllowed AwsEksKey ExplicitLongLived)
      let staleScope =
            mkObservationEvidenceScope
              Cascade
              (RegistryRevision "lifecycle-registry/stale")
              fixtureRunScope
              fixtureFoundation
              (Just fixtureAwsScope)
              ReconcileDesiredAbsent
      mkCheckpointRestoreRequest
        restoreOperation
        AwsEksKey
        staleScope
        backup {checkpointObservationEvidenceScope = staleScope}
        `shouldBe` Left
          ( CheckpointRestoreScopeRevisionMismatch
              lifecycleRegistryRevision
              (RegistryRevision "lifecycle-registry/stale")
          )

    it "accepts only opaque checkpoint results at the compiled execution boundary" $ do
      let compiled = compiledCascade
          compiledScope = compiledDesiredAbsenceObservationScope compiled
          (target, restorePlan) = stackOperationPlan isRestore compiled
          (_, recoveryPlan) = stackOperationPlan isRecoveryReadBack compiled
          (_, retirementPlan) = stackOperationPlan isRetirement compiled
          (_, retirementReadBackPlan) =
            stackOperationPlan isRetirementReadBack compiled
          restoreOperationId = cleanupNodeOperationId restorePlan
          retirementOperationId = cleanupNodeOperationId retirementPlan
          boundPrimary = primary {checkpointObservationEvidenceScope = compiledScope}
          boundBackup = backup {checkpointObservationEvidenceScope = compiledScope}
          boundPair =
            expectRight
              ( mkCheckpointPairObservation
                  AwsEksKey
                  compiledScope
                  boundPrimary
                  boundBackup
              )
          request =
            expectRight
              ( mkCheckpointRestoreRequest
                  restoreOperationId
                  AwsEksKey
                  compiledScope
                  boundBackup
              )
          lostRestore =
            recordCheckpointRestoreAttempt request CheckpointRestoreResponseLost
          recovered =
            expectRight
              ( confirmCheckpointRecoveryReadBack
                  restoreOperationId
                  AwsEksKey
                  compiledScope
                  boundPair
              )
          recoveredWrongOperation =
            expectRight
              ( confirmCheckpointRecoveryReadBack
                  otherOperation
                  AwsEksKey
                  compiledScope
                  boundPair
              )
          boundAbsent = exactObservationAt compiledScope (ExactResourceAbsent absenceEvidence)
          noRestore =
            expectRight
              ( mkCheckpointRestoreNotRequiredOutcome
                  restoreOperationId
                  AwsEksKey
                  compiledScope
                  boundAbsent
              )
          noRestoreReadBack =
            expectRight
              ( confirmCheckpointNoRestoreReadBack
                  restoreOperationId
                  AwsEksKey
                  compiledScope
                  boundAbsent
              )
          retirementAuthorization =
            expectRight
              ( authorizeCheckpointRetirement
                  retirementOperationId
                  RetireActiveCheckpointReference
                  compiledScope
                  eksCheckpointDischarged
                  boundAbsent
                  boundPair
              )
          lostRetirement =
            recordCheckpointRetirementAttempt
              retirementAuthorization
              CheckpointRetirementResponseLost
          retirementEvidence =
            expectRight
              ( confirmCheckpointRetirement
                  retirementAuthorization
                  (retirementObservationAt retirementOperationId compiledScope)
              )
      registeredTargetKey target `shouldBe` AwsEksKey
      executeResult compiled restorePlan (FixedCheckpointRestore lostRestore)
        `shouldBe` CleanupNodeEffectUnconfirmed "checkpoint restore response lost"
      executeResult compiled restorePlan (FixedCheckpointRestore noRestore)
        `shouldBe` CleanupNodeSucceeded
      executeResult compiled recoveryPlan (FixedCheckpointRecovery recovered)
        `shouldBe` CleanupNodeSucceeded
      executeResult compiled recoveryPlan (FixedCheckpointRecovery noRestoreReadBack)
        `shouldBe` CleanupNodeSucceeded
      executeResult compiled retirementPlan (FixedCheckpointRetirement lostRetirement)
        `shouldBe` CleanupNodeEffectUnconfirmed "checkpoint retirement response lost"
      executeResult
        compiled
        retirementReadBackPlan
        (FixedCheckpointRetirementReadBack retirementEvidence)
        `shouldBe` CleanupNodeSucceeded
      executeResult compiled restorePlan (FixedGenericMutation TeardownMutationApplied)
        `shouldBe` wrongResultKind
      executeResult compiled retirementPlan (FixedGenericMutation TeardownMutationApplied)
        `shouldBe` wrongResultKind
      executeResult compiled recoveryPlan (FixedCheckpointRecovery recoveredWrongOperation)
        `shouldBe` bindingMismatch

scope :: ObservationEvidenceScope
scope = mkScope fixtureRunScope Cascade

mkScope :: DurableObservationRunScope -> CleanupSurface -> ObservationEvidenceScope
mkScope runScope surface =
  mkObservationEvidenceScope
    surface
    lifecycleRegistryRevision
    runScope
    fixtureFoundation
    (Just fixtureAwsScope)
    ReconcileDesiredAbsent

fixtureRunScope :: DurableObservationRunScope
fixtureRunScope = DurableObservationRunScope "cleanup-run/checkpoint"

fixtureFoundation :: LinuxRke2FoundationId
fixtureFoundation = LinuxRke2FoundationId "home-linux-rke2"

fixtureAwsScope :: AwsScope
fixtureAwsScope =
  AwsScope (AwsAccountId "111122223333") (AwsRegion "ca-central-1")

checkpointVersion :: CheckpointVersion
checkpointVersion = CheckpointVersion "sha256:checkpoint-v7"

primaryProvenance :: CheckpointProvenance
primaryProvenance = CheckpointProvenance "primary/minio/sha256-v7"

backupProvenance :: CheckpointProvenance
backupProvenance = CheckpointProvenance "backup/s3/sha256-v7"

primary :: CheckpointObservation
primary =
  CheckpointObservation
    { checkpointObservationStackKey = AwsEksKey
    , checkpointObservationCopy = PrimaryCheckpointCopy
    , checkpointObservationProvenance = primaryProvenance
    , checkpointObservationEvidenceScope = scope
    , checkpointObservationResult = CheckpointPresent checkpointVersion
    }

backup :: CheckpointObservation
backup =
  CheckpointObservation
    { checkpointObservationStackKey = AwsEksKey
    , checkpointObservationCopy = BackupCheckpointCopy
    , checkpointObservationProvenance = backupProvenance
    , checkpointObservationEvidenceScope = scope
    , checkpointObservationResult = CheckpointPresent checkpointVersion
    }

restoredPrimary :: CheckpointObservation
restoredPrimary = primary

pair :: CheckpointPairObservation
pair = expectRight (mkCheckpointPairObservation AwsEksKey scope primary backup)

presentInventory :: ExactObservationResult
presentInventory =
  ExactResourcePresent
    (ExactResourceInventory (ObservedResourceIdentity "eks-cluster-arn:fixture" :| []))

exactPresent :: ExactResourceObservation
exactPresent = exactObservation presentInventory

exactAbsent :: ExactResourceObservation
exactAbsent = exactObservation (ExactResourceAbsent (AbsenceEvidence "eks-not-found"))

exactObservation :: ExactObservationResult -> ExactResourceObservation
exactObservation = exactObservationAt scope

exactObservationAt
  :: ObservationEvidenceScope
  -> ExactObservationResult
  -> ExactResourceObservation
exactObservationAt observationScope result =
  exactResourceObservationFor
    (mustIdentity AwsEksKey)
    (ObservationRevision 11)
    observationScope
    result

retiredObservation :: CheckpointRetirementObservation
retiredObservation = retirementObservationAt retirementOperation scope

retirementObservationAt
  :: CleanupOperationId
  -> ObservationEvidenceScope
  -> CheckpointRetirementObservation
retirementObservationAt operationId observationScope =
  CheckpointRetirementObservation
    { checkpointRetirementObservationOperationId = operationId
    , checkpointRetirementObservationStackKey = AwsEksKey
    , checkpointRetirementObservationScope = observationScope
    , checkpointRetirementObservationPrimaryProvenance = primaryProvenance
    , checkpointRetirementObservationBackupProvenance = backupProvenance
    , checkpointRetirementObservationReferenceDisposition =
        CheckpointReferenceRetired checkpointVersion
    }

data FixedResult
  = FixedCheckpointRestore !CheckpointRestoreOutcome
  | FixedCheckpointRecovery !CheckpointRecoveryReadBackEvidence
  | FixedCheckpointRetirement !CheckpointRetirementOutcome
  | FixedCheckpointRetirementReadBack !CheckpointRetirementEvidence
  | FixedGenericMutation !TeardownMutationResult

newtype FixedEffects value = FixedEffects
  { runFixedEffects :: FixedResult -> value
  }

instance Functor FixedEffects where
  fmap function (FixedEffects action) =
    FixedEffects (function . action)

instance Applicative FixedEffects where
  pure value = FixedEffects (const value)
  FixedEffects function <*> FixedEffects action =
    FixedEffects $ \fixed -> function fixed (action fixed)

instance Monad FixedEffects where
  FixedEffects action >>= continue =
    FixedEffects $ \fixed ->
      runFixedEffects (continue (action fixed)) fixed

instance LifecycleTeardownEffects FixedEffects where
  executeLifecycleTeardownOperation _ _ =
    FixedEffects fixedTeardownResult
   where
    fixedTeardownResult fixed = case fixed of
      FixedCheckpointRestore outcome -> TeardownCheckpointRestore outcome
      FixedCheckpointRecovery evidence ->
        TeardownCheckpointRecoveryReadBack evidence
      FixedCheckpointRetirement outcome -> TeardownCheckpointRetirement outcome
      FixedCheckpointRetirementReadBack evidence ->
        TeardownCheckpointRetirementReadBack evidence
      FixedGenericMutation mutation -> TeardownMutationAttempt mutation

executeResult
  :: CompiledDesiredAbsenceProgram surface
  -> CleanupNodePlan
  -> FixedResult
  -> CleanupNodeOutcome
executeResult compiled plan result =
  runFixedEffects (runCompiledTeardownNode compiled plan) result

stackOperationPlan
  :: (TeardownOperation surface -> Bool)
  -> CompiledDesiredAbsenceProgram surface
  -> (RegisteredTargetBinding, CleanupNodePlan)
stackOperationPlan predicate compiled =
  case [ (target, plan)
       | plan <- cleanupGraphNodes (compiledDesiredAbsenceGraph compiled)
       , Just operation <- [compiledOperationForNode (cleanupNodeId plan) compiled]
       , predicate operation
       , Just target <- [operationTarget operation]
       , registeredTargetKey target == AwsEksKey
       ] of
    [matched] -> matched
    matches -> error ("expected one stack operation plan, got " ++ show (length matches))

operationTarget :: TeardownOperation surface -> Maybe RegisteredTargetBinding
operationTarget operation = case operation of
  ObserveStackCheckpointPair target -> Just target
  ReconcileStackCheckpointRestore target -> Just target
  ReadBackStackCheckpointRecovery target -> Just target
  RetireStackCheckpointPair target -> Just target
  ReadBackStackCheckpointRetirement target -> Just target
  _ -> Nothing

isRestore :: TeardownOperation surface -> Bool
isRestore operation = case operation of
  ReconcileStackCheckpointRestore _ -> True
  _ -> False

isRecoveryReadBack :: TeardownOperation surface -> Bool
isRecoveryReadBack operation = case operation of
  ReadBackStackCheckpointRecovery _ -> True
  _ -> False

isRetirement :: TeardownOperation surface -> Bool
isRetirement operation = case operation of
  RetireStackCheckpointPair _ -> True
  _ -> False

isRetirementReadBack :: TeardownOperation surface -> Bool
isRetirementReadBack operation = case operation of
  ReadBackStackCheckpointRetirement _ -> True
  _ -> False

compiledCascade :: CompiledDesiredAbsenceProgram 'Cascade
compiledCascade =
  expectRight
    ( compileDesiredAbsenceGraph
        fixtureCleanupRunId
        fixtureFoundation
        (Just fixtureAwsScope)
        CascadeSurface
    )

fixtureCleanupRunId :: CleanupRunId
fixtureCleanupRunId =
  case mkCleanupRunId "cleanup-run/checkpoint" of
    Left err -> error (show err)
    Right runId -> runId

absenceEvidence :: AbsenceEvidence
absenceEvidence = AbsenceEvidence "eks-not-found"

bindingMismatch :: CleanupNodeOutcome
bindingMismatch = CleanupNodeFailed "lifecycle observation binding mismatch"

wrongResultKind :: CleanupNodeOutcome
wrongResultKind =
  CleanupNodeFailed "lifecycle interpreter returned the wrong result kind"

restoreOperation :: CleanupOperationId
restoreOperation = mustOperation "cleanup-run/checkpoint/restore-primary"

retirementOperation :: CleanupOperationId
retirementOperation = mustOperation "cleanup-run/checkpoint/retire-pair"

otherOperation :: CleanupOperationId
otherOperation = mustOperation "cleanup-run/checkpoint/other"

mustOperation :: String -> CleanupOperationId
mustOperation raw =
  case mkCleanupOperationId (fromString raw) of
    Left err -> error (show err)
    Right operation -> operation

mustIdentity :: RegisteredResourceKey -> RegisteredIdentity
mustIdentity key = case lookupRegisteredIdentity key of
  Nothing -> error ("missing registered identity: " ++ show key)
  Just identity -> identity

expectRight :: (Show err) => Either err value -> value
expectRight result = case result of
  Left err -> error (show err)
  Right value -> value

isRight :: Either left right -> Bool
isRight result = case result of
  Right _ -> True
  Left _ -> False

fromString :: String -> Text.Text
fromString = Text.pack

-- | Sprint 4.89: the discharge the retirement path consumes.
--
-- Retiring the reference ends this run's custody of the capability that made
-- the stack's resources destroyable, so the authorization takes the discharge
-- rather than producing one.  The suite's own case below measures that a
-- discharge naming another capability is refused.
eksCheckpointDischarged :: CapabilityDisposition 'CustodyRetire
eksCheckpointDischarged =
  CapabilityDischargedByAbsence
    (CheckpointCapability AwsEksKey)
    (DependantAbsenceProof [AwsEksKey])

-- | A discharge for a different stack's checkpoint.
foreignCheckpointDischarged :: CapabilityDisposition 'CustodyRetire
foreignCheckpointDischarged =
  CapabilityDischargedByAbsence
    (CheckpointCapability AwsTestKey)
    (DependantAbsenceProof [AwsTestKey])
