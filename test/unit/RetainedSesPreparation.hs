{-# LANGUAGE OverloadedStrings #-}

module RetainedSesPreparation
  ( retainedSesPreparationSuite
  )
where

import Control.Monad (forM_)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (elemIndex)
import Prodbox.Lifecycle.CheckpointAuthority
  ( checkpointAuthorityClusterId
  , mkLongLivedCheckpointAuthority
  , mkTargetClusterSecretSink
  , targetSecretSinkIdentity
  )
import Prodbox.Substrate (Substrate (..))
import Prodbox.TestPlan
  ( NativeValidation (..)
  , retainedSesRequirementForValidations
  )
import Prodbox.TestRestore
  ( RestoreChart (..)
  , RestoreCyclePlan (..)
  , RestoreCycleStep (..)
  , RetainedSesPreparationInputs (..)
  , RetainedSesPreparationInterpreter (..)
  , RetainedSesPreparationPlan
  , RetainedSesPreparationPrecondition (..)
  , RetainedSesPreparationStep (..)
  , RetainedSesRequirement (..)
  , buildRestoreCyclePlan
  , retainedSesPreparationPrecondition
  , retainedSesPreparationTrace
  , runRetainedSesPreparationWith
  )
import TestSupport

retainedSesPreparationSuite :: SuiteBuilder ()
retainedSesPreparationSuite =
  describe "Sprint 5.17 capability-derived retained SES preparation" $ do
    it "derives SES solely from invite membership and normalizes duplicates" $ do
      retainedSesRequirementForValidations [] `shouldBe` SesNotRequired
      retainedSesRequirementForValidations [ValidationChartsApi] `shouldBe` SesNotRequired
      retainedSesRequirementForValidations [ValidationKeycloakInvite] `shouldBe` SesRequired
      retainedSesRequirementForValidations
        [ValidationChartsApi, ValidationKeycloakInvite, ValidationKeycloakInvite]
        `shouldBe` SesRequired

    it "nests the explicit target readiness precondition and exact transaction semantics" $ do
      let homePreparation = requiredPreparationPlan SubstrateHomeLocal
          awsPreparation = requiredPreparationPlan SubstrateAws
      homePreparation `shouldBe` awsPreparation
      retainedSesPreparationPrecondition homePreparation
        `shouldBe` RetainedSesGatewayObjectStoreReady
      retainedSesPreparationTrace homePreparation
        `shouldBe` [ RetainedSesAcquire
                   , RetainedSesReconcile
                   , RetainedSesAwaitReady
                   , RetainedSesSyncTarget
                   , RetainedSesRelease
                   ]

    it "places one nested preparation after gateway reconcile and before dependent charts" $ do
      forM_ [SubstrateHomeLocal, SubstrateAws] $ \substrate -> do
        let steps = restoreCycleSteps (buildRestoreCyclePlan substrate SesRequired)
            preparationIndex = elemIndex True (map isPreparationStep steps)
        length (filter isPreparationStep steps) `shouldBe` 1
        elemIndex (RestoreReconcileChart RestoreChartGateway) steps
          `shouldSatisfy` (`indexPrecedes` preparationIndex)
        preparationIndex
          `shouldSatisfy` (`indexPrecedes` elemIndex (RestoreReconcileChart RestoreChartVscode) steps)
      restoreCycleSteps (buildRestoreCyclePlan SubstrateHomeLocal SesNotRequired)
        `shouldSatisfy` (not . any isPreparationStep)

    it "keeps retained authority and selected secret sink explicitly distinct" $ do
      checkpointAuthorityClusterId (retainedSesCheckpointAuthority preparationInputs)
        `shouldBe` "home-control"
      targetSecretSinkIdentity (retainedSesTargetSecretSink preparationInputs)
        `shouldBe` "aws-eks"

    it "checks readiness then invokes one registered atomic ensure with exact plan and inputs" $ do
      let restorePlan = buildRestoreCyclePlan SubstrateAws SesRequired
          nestedPlan = requiredPreparationPlan SubstrateAws
      (result, events) <- runFakeRestore restorePlan FakeSuccess
      result `shouldBe` Right ()
      readinessEvents events
        `shouldBe` [(RetainedSesGatewayObjectStoreReady, preparationInputs)]
      ensureEvents events `shouldBe` [(nestedPlan, preparationInputs)]
      events `shouldSatisfy` dependentChartsRan
      events `shouldSatisfy` retainedResourceWasNeverDestroyed

    it "fails closed on target readiness and never invokes the registered ensure" $ do
      (result, events) <- runFakeRestore requiredHomePlan FakeReadinessFailure
      result `shouldBe` Left ReadinessFailed
      readinessEvents events
        `shouldBe` [(RetainedSesGatewayObjectStoreReady, preparationInputs)]
      ensureEvents events `shouldBe` []
      events `shouldSatisfy` dependentChartsDidNotRun
      events `shouldSatisfy` retainedResourceWasNeverDestroyed

    it "blocks dependent charts when the one registered atomic ensure fails" $ do
      let nestedPlan = requiredPreparationPlan SubstrateHomeLocal
      (result, events) <- runFakeRestore requiredHomePlan FakeEnsureFailure
      result `shouldBe` Left EnsureFailed
      readinessEvents events
        `shouldBe` [(RetainedSesGatewayObjectStoreReady, preparationInputs)]
      ensureEvents events `shouldBe` [(nestedPlan, preparationInputs)]
      events `shouldSatisfy` dependentChartsDidNotRun
      events `shouldSatisfy` retainedResourceWasNeverDestroyed

    it "does not run readiness or ensure for validations without the SES capability" $ do
      (result, events) <-
        runFakeRestore
          (buildRestoreCyclePlan SubstrateHomeLocal SesNotRequired)
          FakeEnsureFailure
      result `shouldBe` Right ()
      readinessEvents events `shouldBe` []
      ensureEvents events `shouldBe` []
      events `shouldSatisfy` dependentChartsRan
      events `shouldSatisfy` retainedResourceWasNeverDestroyed

requiredHomePlan :: RestoreCyclePlan
requiredHomePlan = buildRestoreCyclePlan SubstrateHomeLocal SesRequired

requiredPreparationPlan :: Substrate -> RetainedSesPreparationPlan
requiredPreparationPlan substrate =
  case [ preparationPlan
       | RestorePrepareRetainedSes preparationPlan <-
           restoreCycleSteps (buildRestoreCyclePlan substrate SesRequired)
       ] of
    [preparationPlan] -> preparationPlan
    observed ->
      error
        ( "expected exactly one retained SES preparation plan, observed "
            ++ show observed
        )

preparationInputs :: RetainedSesPreparationInputs
preparationInputs =
  RetainedSesPreparationInputs
    { retainedSesCheckpointAuthority =
        expectRight
          ( mkLongLivedCheckpointAuthority
              "home-control"
              "https://gateway.home.example.test"
              "prodbox-state"
              "lifecycle"
              "transit/prodbox"
          )
    , retainedSesTargetSecretSink =
        expectRight
          ( mkTargetClusterSecretSink
              "aws-eks"
              "https://gateway.aws.example.test"
              "secret"
              "keycloak/smtp"
          )
    }

data FakeScenario
  = FakeSuccess
  | FakeReadinessFailure
  | FakeEnsureFailure
  deriving (Eq, Show)

data FakeFailure
  = ReadinessFailed
  | EnsureFailed
  deriving (Eq, Show)

data FakeEvent
  = FakeRestoreStep !RestoreCycleStep
  | FakeReadiness
      !RetainedSesPreparationPrecondition
      !RetainedSesPreparationInputs
  | FakeEnsure
      !RetainedSesPreparationPlan
      !RetainedSesPreparationInputs
  | FakeDestroyRetainedSes
  deriving (Eq, Show)

runFakeRestore
  :: RestoreCyclePlan
  -> FakeScenario
  -> IO (Either FakeFailure (), [FakeEvent])
runFakeRestore restorePlan scenario = do
  eventsRef <- newIORef []
  let append event = modifyIORef' eventsRef (++ [event])
      interpreter =
        RetainedSesPreparationInterpreter
          { checkRetainedSesPreparationPrecondition =
              \precondition inputs -> do
                append (FakeReadiness precondition inputs)
                pure $
                  case scenario of
                    FakeReadinessFailure -> Left ReadinessFailed
                    _ -> Right ()
          , runRegisteredRetainedSesEnsure =
              \preparationPlan inputs -> do
                append (FakeEnsure preparationPlan inputs)
                pure $
                  case scenario of
                    FakeEnsureFailure -> Left EnsureFailed
                    _ -> Right ()
          }
      runSteps [] = pure (Right ())
      runSteps (restoreStep : remainingSteps) = do
        append (FakeRestoreStep restoreStep)
        case restoreStep of
          RestorePrepareRetainedSes preparationPlan -> do
            preparationResult <-
              runRetainedSesPreparationWith
                interpreter
                preparationPlan
                preparationInputs
            case preparationResult of
              Left failure -> pure (Left failure)
              Right () -> runSteps remainingSteps
          _ -> runSteps remainingSteps
  result <- runSteps (restoreCycleSteps restorePlan)
  events <- readIORef eventsRef
  pure (result, events)

readinessEvents
  :: [FakeEvent]
  -> [(RetainedSesPreparationPrecondition, RetainedSesPreparationInputs)]
readinessEvents events =
  [(precondition, inputs) | FakeReadiness precondition inputs <- events]

ensureEvents
  :: [FakeEvent]
  -> [(RetainedSesPreparationPlan, RetainedSesPreparationInputs)]
ensureEvents events =
  [(preparationPlan, inputs) | FakeEnsure preparationPlan inputs <- events]

dependentChartsRan :: [FakeEvent] -> Bool
dependentChartsRan =
  elem (FakeRestoreStep (RestoreReconcileChart RestoreChartVscode))

dependentChartsDidNotRun :: [FakeEvent] -> Bool
dependentChartsDidNotRun = not . dependentChartsRan

retainedResourceWasNeverDestroyed :: [FakeEvent] -> Bool
retainedResourceWasNeverDestroyed = notElem FakeDestroyRetainedSes

isPreparationStep :: RestoreCycleStep -> Bool
isPreparationStep restoreStep =
  case restoreStep of
    RestorePrepareRetainedSes _ -> True
    _ -> False

indexPrecedes :: Maybe Int -> Maybe Int -> Bool
indexPrecedes (Just left) (Just right) = left < right
indexPrecedes _ _ = False

expectRight :: (Show err) => Either err value -> value
expectRight result =
  case result of
    Right value -> value
    Left err -> error ("invalid retained SES preparation fixture: " ++ show err)
