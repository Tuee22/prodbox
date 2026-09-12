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

      let isNotReaderOperation (SomeTeardownOperation operation) = case operation of
            CommitAwsStackReaderBundle _ -> False
            ReadBackAwsStackReaderBundle _ -> False
            _ -> True
      operationsFor AwsEbsPerRunTestKey
        `shouldSatisfy` all isNotReaderOperation

    it "surfaces a declining interpreter's own cause rather than a generic failure" $ do
      -- Sprint 4.94 narrowed what these two cases can claim, and the record says
      -- so rather than leaving the names to overstate it. They used to drive a
      -- fixture that answered a generic mutation attempt for every operation,
      -- and the outcome they asserted was the executor refusing that pairing.
      -- The pairing is no longer representable — an interpreter handed a
      -- stack-reader operation cannot return a mutation attempt — so what these
      -- exercise now is the remaining half: a declining interpreter's typed
      -- cause reaches the caller through both the commit and the read-back node.
      let direct =
            runGenericEffects
              (runCompiledTeardownNode fixtureCompiled commitPlan)
          generic =
            runGenericEffects
              (runCompiledTeardownNode fixtureCompiled readBackPlan)
      direct `shouldSatisfy` isFailed
      generic `shouldSatisfy` isFailed

    it "rejects cross-operation commit evidence" $
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

-- | Sprint 4.94: the fixture declines every operation.  It used to answer with
-- a generic mutation attempt, which is how both cases below reached a failed
-- outcome; that pairing is no longer representable, and an answer cannot be
-- given without constructing the operation's own result.
instance LifecycleTeardownEffects GenericEffects where
  executeLifecycleTeardownOperation _ _ =
    pure (TeardownNodeRefused "fixture answers no lifecycle operation")

isFailed :: CleanupNodeOutcome -> Bool
isFailed outcome = case outcome of
  CleanupNodeFailed _ -> True
  _ -> False

operationsFor :: RegisteredResourceKey -> [SomeTeardownOperation 'Cascade]
operationsFor key =
  [ operation
  | (_, operation) <- compiledDesiredAbsenceOperations fixtureCompiled
  , operationKey operation == Just key
  ]

operationKey :: SomeTeardownOperation surface -> Maybe RegisteredResourceKey
operationKey (SomeTeardownOperation operation) = case operation of
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

planFor :: TeardownOperation 'Cascade result -> CleanupNodePlan
planFor wanted = case matching of
  [plan] -> plan
  _ -> error ("expected one fixture plan for " <> show wanted)
 where
  matching =
    [ plan
    | plan <- cleanupGraphNodes (compiledDesiredAbsenceGraph fixtureCompiled)
    , compiledOperationForNode (cleanupNodeId plan) fixtureCompiled
        == Just (SomeTeardownOperation wanted)
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
        SomeTeardownOperation (ObserveRegisteredTarget candidate)
          | registeredTargetKey candidate == key -> [candidate]
        SomeTeardownOperation _ -> []
    ]

fixtureCompiled :: CompiledDesiredAbsenceProgram 'Cascade
fixtureCompiled =
  mustRight
    ( compileDesiredAbsenceGraph
        fixtureRunId
        (LinuxRke2FoundationId "home-rke2")
        (Just (AwsScope (AwsAccountId "123456789012") (AwsRegion (fixtureAwsRegion FixtureUsEast1))))
        Nothing
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
