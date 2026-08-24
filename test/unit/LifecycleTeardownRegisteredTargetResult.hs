{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownRegisteredTargetResult
  ( lifecycleTeardownRegisteredTargetResultSuite
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupNodeOutcome (..)
  , CleanupNodePlan
  , CleanupOperationId
  , CleanupRunId
  , cleanupGraphNodes
  , cleanupNodeId
  , cleanupNodeOperationId
  , mkCleanupOperationId
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderRevision
  , mkProviderRevision
  , providerIntentCoordinate
  )
import Prodbox.Lifecycle.Teardown.AwsEbsAdapter
import Prodbox.Lifecycle.Teardown.AwsStackAdapter
import Prodbox.Lifecycle.Teardown.Decision
import Prodbox.Lifecycle.Teardown.Execution
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.RegisteredTargetResult
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownRegisteredTargetResultSuite :: SuiteBuilder ()
lifecycleTeardownRegisteredTargetResultSuite =
  describe "Sprint 4.85 registered-target reconcile result boundary" $ do
    it "mints exact already-absent results with all durable execution bindings" $ do
      let (target, plan) = targetAndPlan AwsEksKey compiled
          operationId = cleanupNodeOperationId plan
          observation = absentObservation AwsEksKey exactScope
          result =
            mustRight
              ( mkAlreadyAbsentRegisteredTargetReconcile
                  operationId
                  target
                  exactScope
                  observation
              )
      registeredTargetReconcileKey result `shouldBe` AwsEksKey
      registeredTargetReconcileCoordinateDigest result
        `shouldBe` registeredTargetCoordinateDigest target
      registeredTargetReconcileScope result `shouldBe` exactScope
      registeredTargetReconcileOperationId result `shouldBe` operationId
      registeredTargetReconcileDisposition result
        `shouldBe` RegisteredTargetConfirmedAlreadyAbsent absenceEvidence
      mkAlreadyAbsentRegisteredTargetReconcile
        operationId
        target
        exactScope
        observation
        `shouldBe` Right result

    it "refuses present, cross-key, and cross-scope absence observations" $ do
      let (target, plan) = targetAndPlan AwsEksKey compiled
          operationId = cleanupNodeOperationId plan
          present = presentObservation AwsEksKey exactScope
          otherKey = absentObservation AwsTestKey exactScope
          otherScope = absentObservation AwsEksKey alternateScope
      mkAlreadyAbsentRegisteredTargetReconcile
        operationId
        target
        exactScope
        present
        `shouldBe` Left
          (RegisteredTargetObservationNotAbsent (exactObservationResult present))
      mkAlreadyAbsentRegisteredTargetReconcile
        operationId
        target
        exactScope
        otherKey
        `shouldBe` Left
          ( RegisteredTargetObservationKeyMismatch
              AwsEksKey
              AwsTestKey
          )
      mkAlreadyAbsentRegisteredTargetReconcile
        operationId
        target
        exactScope
        otherScope
        `shouldBe` Left
          ( RegisteredTargetObservationScopeMismatch
              exactScope
              alternateScope
          )

    it "requires exact stack authorization for a typed stack mutation attempt" $ do
      let (target, plan) = targetAndPlan AwsTestKey compiled
          authorization = stackAuthorization AwsTestKey exactScope
          operationId = cleanupNodeOperationId plan
          result =
            mustRight
              ( mkAwsStackRegisteredTargetReconcile
                  operationId
                  target
                  exactScope
                  authorization
                  RegisteredTargetMutationApplied
              )
      registeredTargetReconcileDisposition result
        `shouldBe` RegisteredTargetAwsStackMutation RegisteredTargetMutationApplied
      let (otherTarget, _) = targetAndPlan AwsEksSubzoneKey compiled
      mkAwsStackRegisteredTargetReconcile
        operationId
        otherTarget
        exactScope
        authorization
        RegisteredTargetMutationApplied
        `shouldBe` Left
          ( RegisteredTargetStackAuthorizationKeyMismatch
              AwsEksSubzoneKey
              AwsTestKey
          )
      mkAwsStackRegisteredTargetReconcile
        operationId
        target
        alternateScope
        authorization
        RegisteredTargetMutationApplied
        `shouldBe` Left
          ( RegisteredTargetStackAuthorizationScopeMismatch
              alternateScope
              exactScope
          )

    it "accepts only the exact per-run EBS reaper authorization" $ do
      let (target, plan) = targetAndPlan AwsEbsPerRunTestKey compiled
          authorization = ebsAuthorization exactScope
          operationId = cleanupNodeOperationId plan
          result =
            mustRight
              ( mkAwsEbsRegisteredTargetReconcile
                  operationId
                  target
                  exactScope
                  authorization
                  (RegisteredTargetMutationResponseLost "provider response lost")
              )
      registeredTargetReconcileDisposition result
        `shouldBe` RegisteredTargetAwsEbsMutation
          (RegisteredTargetMutationResponseLost "provider response lost")
      let (stackTarget, _) = targetAndPlan AwsEksKey compiled
      mkAwsEbsRegisteredTargetReconcile
        operationId
        stackTarget
        exactScope
        authorization
        RegisteredTargetMutationApplied
        `shouldBe` Left (RegisteredTargetEbsPerRunKeyRequired AwsEksKey)
      let (retainedTarget, retainedPlan) =
            targetAndPlan AwsEbsProductionRetainedKey longLivedCompiled
      mkAwsEbsRegisteredTargetReconcile
        (cleanupNodeOperationId retainedPlan)
        retainedTarget
        longLivedScope
        authorization
        RegisteredTargetMutationApplied
        `shouldBe` Left
          (RegisteredTargetEbsPerRunKeyRequired AwsEbsProductionRetainedKey)

    it "validates all opaque bindings before accepting registered reconcile" $ do
      let (target, plan) = targetAndPlan AwsEksKey compiled
          operationId = cleanupNodeOperationId plan
          exactResult = alreadyAbsentResult operationId target exactScope
      executeResult compiled plan (FixedRegisteredResult exactResult)
        `shouldBe` CleanupNodeSucceeded

      let (_, otherPlan) = targetAndPlan AwsTestKey compiled
          crossKey =
            alreadyAbsentResult
              (cleanupNodeOperationId otherPlan)
              target
              exactScope
      executeResult compiled otherPlan (FixedRegisteredResult crossKey)
        `shouldBe` bindingMismatch

      let crossScope = alreadyAbsentResult operationId target alternateScope
      executeResult compiled plan (FixedRegisteredResult crossScope)
        `shouldBe` bindingMismatch

      let crossOperation =
            alreadyAbsentResult otherOperationId target exactScope
      executeResult compiled plan (FixedRegisteredResult crossOperation)
        `shouldBe` bindingMismatch

    it "keeps transport response loss unconfirmed and provider refusal failed" $ do
      let (target, plan) = targetAndPlan AwsTestKey compiled
          operationId = cleanupNodeOperationId plan
          authorization = stackAuthorization AwsTestKey exactScope
          resultFor attempt =
            mustRight
              ( mkAwsStackRegisteredTargetReconcile
                  operationId
                  target
                  exactScope
                  authorization
                  attempt
              )
      executeResult
        compiled
        plan
        ( FixedRegisteredResult
            (resultFor (RegisteredTargetMutationResponseLost "timeout after submit"))
        )
        `shouldBe` CleanupNodeEffectUnconfirmed "timeout after submit"
      executeResult
        compiled
        plan
        ( FixedRegisteredResult
            (resultFor (RegisteredTargetMutationRefused "authority refused"))
        )
        `shouldBe` CleanupNodeFailed "authority refused"

    it "lowers an exact interpreter refusal to failure without mutation authority" $ do
      let (target, plan) = targetAndPlan AwsEksKey compiled
          operationId = cleanupNodeOperationId plan
          refused =
            mustRight
              ( mkRefusedRegisteredTargetReconcile
                  operationId
                  target
                  exactScope
                  "EKS drain proof required"
              )
      registeredTargetReconcileDisposition refused
        `shouldBe` RegisteredTargetReconcileRefused "EKS drain proof required"
      executeResult compiled plan (FixedRegisteredResult refused)
        `shouldBe` CleanupNodeFailed "EKS drain proof required"

    it "never accepts a generic mutation result for registered reconcile" $ do
      let (_, plan) = targetAndPlan AwsEksKey compiled
      executeResult
        compiled
        plan
        (FixedGenericMutation (TeardownMutationApplied))
        `shouldBe` wrongResultKind
      executeResult
        compiled
        plan
        (FixedGenericMutation (TeardownMutationResponseLost "generic timeout"))
        `shouldBe` wrongResultKind

    it "keeps the reconcile capability opaque and free of effect callbacks" $ do
      source <-
        readFile
          "src/Prodbox/Lifecycle/Teardown/RegisteredTargetResult.hs"
      let moduleHeader = takeWhile (/= "where") (lines source)
      unlines moduleHeader
        `shouldNotContain` "RegisteredTargetReconcileResult (..)"
      source `shouldNotContain` "IO "
      source `shouldNotContain` "ProviderCaller"
      source `shouldNotContain` "ProviderProduction"
      source `shouldNotContain` "FilePath"

data FixedResult
  = FixedRegisteredResult !RegisteredTargetReconcileResult
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
      FixedRegisteredResult result ->
        TeardownRegisteredTargetReconcile result
      FixedGenericMutation mutation -> TeardownMutationAttempt mutation

executeResult
  :: CompiledDesiredAbsenceProgram surface
  -> CleanupNodePlan
  -> FixedResult
  -> CleanupNodeOutcome
executeResult compiledProgram plan fixed =
  runFixedEffects (runCompiledTeardownNode compiledProgram plan) fixed

targetAndPlan
  :: RegisteredResourceKey
  -> CompiledDesiredAbsenceProgram surface
  -> (RegisteredTargetBinding, CleanupNodePlan)
targetAndPlan key compiledProgram =
  case [ (target, plan)
       | plan <- cleanupGraphNodes (compiledDesiredAbsenceGraph compiledProgram)
       , Just (ReconcileRegisteredTargetAbsent target) <-
           [compiledOperationForNode (cleanupNodeId plan) compiledProgram]
       , registeredTargetKey target == key
       ] of
    [matched] -> matched
    matches ->
      error
        ( "expected one reconcile plan for "
            <> show key
            <> ", got "
            <> show (length matches)
        )

alreadyAbsentResult
  :: CleanupOperationId
  -> RegisteredTargetBinding
  -> ObservationEvidenceScope
  -> RegisteredTargetReconcileResult
alreadyAbsentResult operationId target scope =
  mustRight
    ( mkAlreadyAbsentRegisteredTargetReconcile
        operationId
        target
        scope
        (absentObservation (registeredTargetKey target) scope)
    )

absentObservation
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> ExactResourceObservation
absentObservation key scope =
  exactResourceObservationFor
    (mustIdentity key)
    observationRevision
    scope
    (ExactResourceAbsent absenceEvidence)

presentObservation
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> ExactResourceObservation
presentObservation key scope =
  exactResourceObservationFor
    (mustIdentity key)
    observationRevision
    scope
    ( ExactResourcePresent
        (ExactResourceInventory (ObservedResourceIdentity presentIdentity :| []))
    )

stackAuthorization
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> AwsStackDestroyAuthorization
stackAuthorization key scope =
  mustRight
    ( authorizeAwsStackDestroy
        providerRevision
        verified
        ( StackDestroyFromVerifiedPrimary
            key
            ( VerifiedPrimaryCheckpoint
                (CheckpointProvenance "primary://registered-target-result")
                (CheckpointVersion "primary-v1")
            )
        )
    )
 where
  request = mustRight (mkAwsStackObserveRequest key scope observationRevision)
  verified = case decodeAwsStackExecutionResult
    request
    ( ProviderIntentExecutionObserved
        (awsStackObservationRequestCoordinate request)
        presentIdentity
    ) of
    AwsStackObservationDecoded exact -> exact
    AwsStackObservationRejected refusal _ ->
      error ("expected verified stack observation, got " <> show refusal)

ebsAuthorization
  :: ObservationEvidenceScope -> ExactAwsEbsReapAuthorization
ebsAuthorization scope =
  case mustRight (authorizeExactAwsEbsReap request observation) of
    Just authorization -> authorization
    Nothing -> error "present EBS observation did not authorize its exact reaper"
 where
  request =
    mustRight
      (mkExactAwsEbsObservationRequest CascadeSurface observationRevision scope)
  intent = awsEbsObservationRequestProviderIntent request
  observation =
    mustRight
      ( decodeExactAwsEbsObservation
          request
          ( Right
              ( ProviderIntentExecutionObserved
                  (providerIntentCoordinate intent)
                  "prodbox-test-ebs-observation/v1:present:vol-01234567"
              )
          )
      )

mustIdentity :: RegisteredResourceKey -> RegisteredIdentity
mustIdentity key = case lookupRegisteredIdentity key of
  Just identity -> identity
  Nothing -> error ("registered identity missing: " <> show key)

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error ("expected Right, got " <> show err)

compiled :: CompiledDesiredAbsenceProgram 'Cascade
compiled =
  mustRight
    ( compileDesiredAbsenceGraph
        cleanupRunId
        foundation
        (Just awsScope)
        Nothing
        CascadeSurface
    )

longLivedCompiled :: CompiledDesiredAbsenceProgram 'ExplicitLongLived
longLivedCompiled =
  mustRight
    ( compileDesiredAbsenceGraph
        cleanupRunId
        foundation
        (Just awsScope)
        Nothing
        ExplicitLongLivedSurface
    )

exactScope :: ObservationEvidenceScope
exactScope = compiledDesiredAbsenceObservationScope compiled

longLivedScope :: ObservationEvidenceScope
longLivedScope = compiledDesiredAbsenceObservationScope longLivedCompiled

alternateScope :: ObservationEvidenceScope
alternateScope =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope "registered-target-result-alternate")
    foundation
    (Just awsScope)
    ReconcileDesiredAbsent

cleanupRunId :: CleanupRunId
cleanupRunId = mustRight (mkCleanupRunId "registered-target-result-run")

foundation :: LinuxRke2FoundationId
foundation = LinuxRke2FoundationId "home-rke2"

awsScope :: AwsScope
awsScope =
  AwsScope
    (AwsAccountId "123456789012")
    (AwsRegion (fixtureAwsRegion FixtureUsEast1))

observationRevision :: ObservationRevision
observationRevision = ObservationRevision 73

providerRevision :: ProviderRevision
providerRevision = mustRight (mkProviderRevision 17)

absenceEvidence :: AbsenceEvidence
absenceEvidence = AbsenceEvidence "registered resource is exactly absent"

presentIdentity :: Text.Text
presentIdentity = "sha256:" <> Text.replicate 64 "b"

otherOperationId :: CleanupOperationId
otherOperationId = mustRight (mkCleanupOperationId "unrelated-operation")

bindingMismatch :: CleanupNodeOutcome
bindingMismatch = CleanupNodeFailed "lifecycle observation binding mismatch"

wrongResultKind :: CleanupNodeOutcome
wrongResultKind =
  CleanupNodeFailed "lifecycle interpreter returned the wrong result kind"
