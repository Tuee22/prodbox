{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownAwsStackReaderInterpreter
  ( lifecycleTeardownAwsStackReaderInterpreterSuite
  )
where

import Control.Monad (forM_)
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.Teardown.AwsStackReaderEvidence
import Prodbox.Lifecycle.Teardown.AwsStackReaderEvidence qualified as Evidence
import Prodbox.Lifecycle.Teardown.Execution
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Program
import TestSupport

lifecycleTeardownAwsStackReaderInterpreterSuite :: SuiteBuilder ()
lifecycleTeardownAwsStackReaderInterpreterSuite =
  describe "lifecycle AWS stack-reader graph seam" $ do
    it "places a stable commit/read-back pair after recovery for every stack" $ do
      forM_ stackKeys $ \key -> do
        let target = targetFor key
            commit = planFor (CommitAwsStackReaderBundle target)
            readBack = planFor (ReadBackAwsStackReaderBundle target)
            recovery = planFor (ReadBackStackCheckpointRecovery target)
            reconcile = planFor (ReconcileRegisteredTargetAbsent target)
        cleanupNodeDependencies commit
          `shouldBe` [ CleanupDependency
                         (cleanupNodeId recovery)
                         CleanupRequiresSuccess
                     ]
        cleanupNodeDependencies readBack
          `shouldBe` [ CleanupDependency
                         (cleanupNodeId commit)
                         CleanupRequiresAttempt
                     ]
        cleanupNodeDependencies reconcile
          `shouldContain` [ CleanupDependency
                              (cleanupNodeId readBack)
                              CleanupRequiresSuccess
                          ]
        cleanupNodeOperationId commit `shouldNotBe` cleanupNodeOperationId readBack
        cleanupNodeOperationId readBack `shouldNotBe` cleanupNodeOperationId reconcile

      operationsFor AwsEbsPerRunTestKey
        `shouldSatisfy` all
          ( \operation -> case operation of
              CommitAwsStackReaderBundle _ -> False
              ReadBackAwsStackReaderBundle _ -> False
              _ -> True
          )

    it "requires a durable recovery predecessor instead of accepting direct execution" $ do
      let direct =
            runGenericEffects
              (runCompiledTeardownNode fixtureCompiled commitPlan)
      direct `shouldSatisfy` isFailed

    it "rejects generic mutation results and cross-operation evidence" $ do
      let generic =
            runGenericEffects
              (runCompiledTeardownNode fixtureCompiled readBackPlan)
      generic `shouldSatisfy` isFailed
      mkAwsStackReaderCommitOutcome
        fixtureRunId
        fixtureGraphDigest
        (cleanupNodeOperationId commitPlan)
        fixtureCompletedAttempt
        (cleanupNodeOperationId commitPlan)
        fixtureTarget
        fixtureScope
        Evidence.AwsStackReaderCommitCreated
        `shouldBe` Left
          (AwsStackReaderEvidenceOperationCollision (cleanupNodeOperationId commitPlan))

    it "does not import the package-private repository implementation" $ do
      source <-
        readFile "test/unit/LifecycleTeardownAwsStackReaderInterpreter.hs"
      let internalModuleName =
            "Prodbox.ControlPlane.AwsStackReaderRepository."
              <> "Internal"
          authorityFactoryName =
            "lifecycleAuthority"
              <> "AwsStackReaderClient"
          completeConstructorName =
            "ValidatedComplete"
              <> "OwnershipManifest"
      source
        `shouldNotContain` internalModuleName
      source `shouldNotContain` authorityFactoryName
      source `shouldNotContain` completeConstructorName

newtype GenericEffects value = GenericEffects
  { runGenericEffects :: value
  }

instance Functor GenericEffects where
  fmap function (GenericEffects value) = GenericEffects (function value)

instance Applicative GenericEffects where
  pure = GenericEffects
  GenericEffects function <*> GenericEffects value =
    GenericEffects (function value)

instance Monad GenericEffects where
  GenericEffects value >>= continue = continue value

instance LifecycleTeardownEffects GenericEffects where
  executeLifecycleTeardownOperation _ _ =
    pure (TeardownMutationAttempt TeardownMutationApplied)

isFailed :: CleanupNodeOutcome -> Bool
isFailed outcome = case outcome of
  CleanupNodeFailed _ -> True
  _ -> False

operationsFor :: RegisteredResourceKey -> [TeardownOperation 'Cascade]
operationsFor key =
  [ operation
  | (_, operation) <- compiledDesiredAbsenceOperations fixtureCompiled
  , operationKey operation == Just key
  ]

operationKey :: TeardownOperation surface -> Maybe RegisteredResourceKey
operationKey operation = case operation of
  ObserveRegisteredTarget target -> Just (registeredTargetKey target)
  ObserveStackCheckpointPair target -> Just (registeredTargetKey target)
  ReconcileStackCheckpointRestore target -> Just (registeredTargetKey target)
  ReadBackStackCheckpointRecovery target -> Just (registeredTargetKey target)
  CommitAwsStackReaderBundle target -> Just (registeredTargetKey target)
  ReadBackAwsStackReaderBundle target -> Just (registeredTargetKey target)
  CommitEksDrainIntent target -> Just (registeredTargetKey target)
  ReadBackEksDrainIntent target -> Just (registeredTargetKey target)
  DrainEksKubernetesResources target -> Just (registeredTargetKey target)
  ReadBackEksKubernetesDrain target -> Just (registeredTargetKey target)
  ReconcileRegisteredTargetAbsent target -> Just (registeredTargetKey target)
  ReadBackRegisteredTargetAbsent target -> Just (registeredTargetKey target)
  RetireStackCheckpointPair target -> Just (registeredTargetKey target)
  ReadBackStackCheckpointRetirement target -> Just (registeredTargetKey target)
  _ -> Nothing

planFor :: TeardownOperation 'Cascade -> CleanupNodePlan
planFor wanted = case matching of
  [plan] -> plan
  _ -> error ("expected one fixture plan for " <> show wanted)
 where
  matching =
    [ plan
    | plan <- cleanupGraphNodes (compiledDesiredAbsenceGraph fixtureCompiled)
    , compiledOperationForNode (cleanupNodeId plan) fixtureCompiled == Just wanted
    ]

targetFor :: RegisteredResourceKey -> RegisteredTargetBinding
targetFor key = case matching of
  [target] -> target
  _ -> error ("expected one registered fixture target for " <> show key)
 where
  matching =
    [ target
    | (_, operation) <- compiledDesiredAbsenceOperations fixtureCompiled
    , target <- case operation of
        ObserveRegisteredTarget candidate
          | registeredTargetKey candidate == key -> [candidate]
        _ -> []
    ]

fixtureCompiled :: CompiledDesiredAbsenceProgram 'Cascade
fixtureCompiled =
  mustRight
    ( compileDesiredAbsenceGraph
        fixtureRunId
        (LinuxRke2FoundationId "home-rke2")
        (Just (AwsScope (AwsAccountId "123456789012") (AwsRegion "us-east-1")))
        CascadeSurface
    )

fixtureGraphDigest :: CleanupDigest
fixtureGraphDigest = cleanupGraphDigest (compiledDesiredAbsenceGraph fixtureCompiled)

fixtureScope :: ObservationEvidenceScope
fixtureScope = compiledDesiredAbsenceObservationScope fixtureCompiled

fixtureTarget :: RegisteredTargetBinding
fixtureTarget = targetFor AwsTestKey

commitPlan :: CleanupNodePlan
commitPlan = planFor (CommitAwsStackReaderBundle fixtureTarget)

readBackPlan :: CleanupNodePlan
readBackPlan = planFor (ReadBackAwsStackReaderBundle fixtureTarget)

fixtureRunId :: CleanupRunId
fixtureRunId = mustRight (mkCleanupRunId "aws-stack-reader-run")

fixtureCompletedAttempt :: CleanupAttemptId
fixtureCompletedAttempt = mustRight (mkCleanupAttemptId "completed-attempt")

stackKeys :: [RegisteredResourceKey]
stackKeys = [AwsEksKey, AwsEksSubzoneKey, AwsTestKey]

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
