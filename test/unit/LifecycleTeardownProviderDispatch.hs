{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownProviderDispatch
  ( lifecycleTeardownProviderDispatchSuite
  )
where

import Data.IORef
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKeyError (ClientSubmissionKeyTooLong)
  , clientSubmissionKeyText
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupOperationId
  , mkCleanupOperationId
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderRevision
  , ProviderStackConfig
  , ProviderStackRef
  , mkAwsEksProviderStackConfig
  , mkProviderRevision
  , mkProviderStackRef
  , providerIntentCoordinate
  )
import Prodbox.Lifecycle.Teardown.ProviderDispatch
import Prodbox.Lifecycle.Teardown.RegisteredTargetResult
  ( RegisteredTargetMutationAttempt (..)
  )
import TestSupport

lifecycleTeardownProviderDispatchSuite :: SuiteBuilder ()
lifecycleTeardownProviderDispatchSuite =
  describe "Sprint 4.85 stable registered Provider dispatch" $ do
    it "derives deterministic, purpose-separated Authority submission keys" $ do
      let decision = keyFor ProviderDecisionObservation
          mutation = keyFor ProviderRegisteredMutation
          readBack = keyFor ProviderAbsenceReadBack
      providerDispatchKeyOperationId decision `shouldBe` operationId
      providerDispatchKeyPurpose decision `shouldBe` ProviderDecisionObservation
      map submissionText [decision, mutation, readBack]
        `shouldBe` [ operationText <> ":decision-observe"
                   , operationText <> ":mutate"
                   , operationText <> ":absence-readback"
                   ]
      keyFor ProviderDecisionObservation `shouldBe` decision
      length
        ( nub
            (map observationRevisionForProviderDispatchKey [decision, mutation, readBack])
        )
        `shouldBe` 3
      observationRevisionForProviderDispatchKey
        (keyFor ProviderDecisionObservation)
        `shouldBe` observationRevisionForProviderDispatchKey decision

    it "refuses a stable graph identity that cannot fit the Authority key bound" $ do
      let longOperation = mustRight (mkCleanupOperationId (Text.replicate 120 "x"))
          expectedLength = 120 + Text.length (":decision-observe" :: Text)
      mkProviderDispatchKey longOperation ProviderDecisionObservation
        `shouldBe` Left
          ( ProviderDispatchKeyInvalid
              (ClientSubmissionKeyTooLong expectedLength 128)
          )

    it "dispatches only exact read-only intents and reconstructs their coordinate" $ do
      trace <- newIORef []
      let boundary = recordingBoundary trace (TeardownProviderCompleted canonicalAbsent)
          request = ObserveRegisteredStack stackRef
      observed <-
        dispatchRegisteredProviderObservation
          boundary
          (keyFor ProviderDecisionObservation)
          request
      observed
        `shouldBe` Right
          ( ProviderIntentExecutionObserved
              (providerIntentCoordinate request)
              canonicalAbsent
          )
      readIORef trace
        `shouldReturn` [
                         ( operationText <> ":decision-observe"
                         , request
                         )
                       ]

    it "keeps observation transport inability unobservable" $ do
      let boundary = fixedBoundary (TeardownProviderUnavailable "authority response unavailable")
      observed <-
        dispatchRegisteredProviderObservation
          boundary
          (keyFor ProviderAbsenceReadBack)
          (ReadBackRegisteredStack stackRef)
      observed
        `shouldBe` Left
          ( ProviderDispatchObservationUnobservable
              "authority response unavailable"
          )

    it "rejects mutation intents at observation keys before dispatch" $ do
      calls <- newIORef (0 :: Int)
      let boundary =
            TeardownProviderBoundary $ \_ _ -> do
              modifyIORef' calls (+ 1)
              pure (TeardownProviderCompleted "unexpected")
          destroy = DestroyRegisteredStack stackRef providerRevision stackConfig
      dispatched <-
        dispatchRegisteredProviderObservation
          boundary
          (keyFor ProviderDecisionObservation)
          destroy
      dispatched
        `shouldBe` Left
          ( ProviderDispatchIntentPurposeMismatch
              ProviderDecisionObservation
              destroy
          )
      readIORef calls `shouldReturn` 0

    it "maps confirmed mutation dispatch to applied and transport loss to unconfirmed" $ do
      let destroy = DestroyRegisteredStack stackRef providerRevision stackConfig
          mutationKey = keyFor ProviderRegisteredMutation
      applied <-
        dispatchRegisteredProviderMutation
          (fixedBoundary (TeardownProviderCompleted "provider read-back satisfied"))
          mutationKey
          destroy
      lost <-
        dispatchRegisteredProviderMutation
          (fixedBoundary (TeardownProviderUnavailable "connection closed after submit"))
          mutationKey
          destroy
      applied `shouldBe` Right RegisteredTargetMutationApplied
      lost
        `shouldBe` Right
          (RegisteredTargetMutationResponseLost "connection closed after submit")

    it "admits only the two registered teardown mutation constructors" $ do
      let mutationKey = keyFor ProviderRegisteredMutation
          boundary = fixedBoundary (TeardownProviderCompleted "unused")
          forbidden = ReconcileRegisteredStack stackRef providerRevision stackConfig
      refused <- dispatchRegisteredProviderMutation boundary mutationKey forbidden
      refused
        `shouldBe` Left
          ( ProviderDispatchIntentPurposeMismatch
              ProviderRegisteredMutation
              forbidden
          )
      ebs <-
        dispatchRegisteredProviderMutation
          boundary
          mutationKey
          (ReapTestEbsVolumes "prodbox-test")
      ebs `shouldBe` Right RegisteredTargetMutationApplied

    it "keeps a definite Authority refusal distinct from response loss" $ do
      let destroy = DestroyRegisteredStack stackRef providerRevision stackConfig
          boundary = fixedBoundary (TeardownProviderRefused "generation fenced")
      mutation <-
        dispatchRegisteredProviderMutation
          boundary
          (keyFor ProviderRegisteredMutation)
          destroy
      observation <-
        dispatchRegisteredProviderObservation
          boundary
          (keyFor ProviderDecisionObservation)
          (ObserveRegisteredStack stackRef)
      mutation
        `shouldBe` Right (RegisteredTargetMutationRefused "generation fenced")
      observation
        `shouldBe` Left (ProviderDispatchObservationRefused "generation fenced")

    it "does not use a fresh Provider submission path" $ do
      source <- readFile "src/Prodbox/Lifecycle/Teardown/ProviderDispatch.hs"
      source `shouldNotContain` "dispatchHostProviderIntentFresh"
      source `shouldNotContain` "dispatchAuthenticatedProviderIntentFresh"
      source `shouldNotContain` "getPOSIXTime"

recordingBoundary
  :: IORef [(Text, ProviderIntent)]
  -> TeardownProviderBoundaryResult
  -> TeardownProviderBoundary IO
recordingBoundary trace result =
  TeardownProviderBoundary $ \dispatchKey intent -> do
    let submissionKey = providerDispatchSubmissionKey dispatchKey
    modifyIORef' trace (++ [(clientSubmissionKeyText submissionKey, intent)])
    pure result

fixedBoundary :: TeardownProviderBoundaryResult -> TeardownProviderBoundary IO
fixedBoundary result = TeardownProviderBoundary (\_ _ -> pure result)

keyFor :: ProviderDispatchPurpose -> ProviderDispatchKey
keyFor = mustRight . mkProviderDispatchKey operationId

submissionText :: ProviderDispatchKey -> Text
submissionText = clientSubmissionKeyText . providerDispatchSubmissionKey

operationId :: CleanupOperationId
operationId = mustRight (mkCleanupOperationId operationText)

operationText :: Text
operationText = "lifecycle-operation/0123456789abcdef"

stackRef :: ProviderStackRef
stackRef = mustRight (mkProviderStackRef "aws-eks")

providerRevision :: ProviderRevision
providerRevision = mustRight (mkProviderRevision 1)

stackConfig :: ProviderStackConfig
stackConfig = mustRight (mkAwsEksProviderStackConfig "127.0.0.1/32")

canonicalAbsent :: Text
canonicalAbsent = "registered stack is absent"

mustRight :: (Show error) => Either error value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error ("unexpected fixture failure: " ++ show err)
