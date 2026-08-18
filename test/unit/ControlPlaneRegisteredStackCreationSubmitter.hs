{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.84: the host-side lane that makes a registered stack's creation
-- addressable.
--
-- Every piece of the generation was proven before this lane existed and none of
-- it ran, because a submitter could not name the operation it had just
-- submitted.  These cases pin the two facts that make the lane correct: the
-- dispatch response now carries the admitted operation, and the foundation the
-- generation key is built on is run-invariant.
module ControlPlaneRegisteredStackCreationSubmitter
  ( controlPlaneRegisteredStackCreationSubmitterSuite
  )
where

import Codec.Serialise (deserialiseOrFail, serialise)
import Prodbox.ControlPlane.AuthorityProviderEndpoint
  ( ProviderDispatchPayload (..)
  , ProviderDispatchResponse (..)
  , providerDispatchFormatVersion
  )
import Prodbox.ControlPlane.AwsStackCreationBindingEndpoint
  ( AwsStackCreationEndpointResponseError (..)
  , AwsStackCreationWireAction (AwsStackCreationWireSelectForCleanup)
  , AwsStackCreationWireResponse (..)
  , awsStackCreationEndpointFormatVersion
  , awsStackCreationSelectWireRequest
  , awsStackCreationWireRequestAction
  , awsStackCreationWireRequestPayload
  , awsStackCreationWireRequestVersion
  , confirmAwsStackCreationSelectResponse
  )
import Prodbox.ControlPlane.RegisteredStackCreationSubmitter
  ( homeLinuxRke2FoundationId
  , registeredStackCleanupScope
  , registeredStackCreationRunScope
  , registeredStackCreationScope
  )
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.Authority.Submission
  ( ClientId (ClientId)
  , ClientSequence (ClientSequence)
  , OperationId (..)
  , RequestDigest (RequestDigest)
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (ObserveProviderAwsScope)
  )
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface (Cascade, ExplicitPerRun)
  , LifecycleOperation (ReconcileDesiredAbsent, ReconcileDesiredPresent)
  , RegisteredResourceKey (AwsTestKey)
  , evidenceAwsScope
  , evidenceCleanupSurface
  , evidenceDurableRunScope
  , evidenceLifecycleOperation
  , evidenceLinuxRke2Foundation
  , evidenceRegistryRevision
  )
import Prodbox.Lifecycle.Teardown.Registry (lifecycleRegistryRevision)
import TestSupport

controlPlaneRegisteredStackCreationSubmitterSuite :: SuiteBuilder ()
controlPlaneRegisteredStackCreationSubmitterSuite =
  describe "Sprint 4.84 registered-stack creation submitting lane" $ do
    describe "the dispatch response names the admitted operation" $ do
      -- An OperationId is (epoch, client, sequence, digest), and the epoch and
      -- sequence are assigned at admission. A submitter therefore cannot derive
      -- one; it has to be told, and the response used to discard it — which is
      -- the whole reason no production submitter could reach the
      -- generation-committing route.
      it "round-trips the operation through both settled arms" $ do
        roundTrip (ProviderDispatchCompleted admittedOperation "receipt")
          `shouldBe` Right (ProviderDispatchCompleted admittedOperation "receipt")
        roundTrip (ProviderDispatchAlreadyCompleted admittedOperation "retained")
          `shouldBe` Right (ProviderDispatchAlreadyCompleted admittedOperation "retained")

      it "keeps a refusal free of any operation, because none was admitted" $
        roundTrip (ProviderDispatchRefused "no")
          `shouldBe` Right (ProviderDispatchRefused "no")

      it "carries a format version on the request, so a shape change refuses" $
        providerDispatchVersion samplePayload `shouldBe` providerDispatchFormatVersion

    describe "the creation scope" $ do
      -- The foundation is part of the run-invariant generation *key*, so a
      -- later cleanup run has to compute the same value knowing nothing about
      -- the run that created the stack. Deriving it from the retained cluster
      -- id is what makes that hold.
      it "derives a run-invariant foundation from the retained cluster id" $ do
        homeLinuxRke2FoundationId "prodbox-home"
          `shouldBe` homeLinuxRke2FoundationId "prodbox-home"
        homeLinuxRke2FoundationId "prodbox-home"
          `shouldNotBe` homeLinuxRke2FoundationId "prodbox-other"

      -- The creating run scope is provenance the selector records and never
      -- matches on, so a per-invocation value is correct here and would be a
      -- defect in the key.
      it "gives each invocation its own creating run scope" $
        registeredStackCreationRunScope 1
          `shouldNotBe` registeredStackCreationRunScope 2

      it "keeps the foundation fixed while the run scope varies" $ do
        let first = scopeAt 1
            second = scopeAt 2
        evidenceLinuxRke2Foundation first
          `shouldBe` evidenceLinuxRke2Foundation second
        evidenceDurableRunScope first
          `shouldNotBe` evidenceDurableRunScope second

      -- The account and region enter the generation only through the Provider
      -- proof the Authority reads back. Offering a slot for them here would be
      -- offering a slot for an assertion.
      it "offers no AWS scope for a caller to assert" $
        evidenceAwsScope (scopeAt 1) `shouldBe` Nothing

      it "submits under the compiled registry revision and a present reconcile" $ do
        evidenceRegistryRevision (scopeAt 1) `shouldBe` lifecycleRegistryRevision
        evidenceCleanupSurface (scopeAt 1) `shouldBe` ExplicitPerRun
        evidenceLifecycleOperation (scopeAt 1) `shouldBe` ReconcileDesiredPresent

    describe "the cleanup selection request" $ do
      -- The consumer half. A cleanup run presents the registered key, its own
      -- admitted scope observation, and its own scope; the cycle is reached
      -- through the series cursor and nothing else.
      it "names the stack and the run's own scope observation, and no ordinal" $ do
        let request =
              awsStackCreationSelectWireRequest
                AwsTestKey
                admittedOperation
                (cleanupScopeAt 1)
        awsStackCreationWireRequestAction request
          `shouldBe` AwsStackCreationWireSelectForCleanup
        awsStackCreationWireRequestVersion request
          `shouldBe` awsStackCreationEndpointFormatVersion

      -- A cleanup run selects under the same foundation the creating run
      -- committed under, because both derive it from the retained cluster id.
      -- That identity is what makes selection across runs possible at all.
      it "selects under the same foundation the creating run committed under" $
        evidenceLinuxRke2Foundation (cleanupScopeAt 1)
          `shouldBe` evidenceLinuxRke2Foundation (scopeAt 9)

      it "selects under a desired-absent operation, not a present reconcile" $ do
        evidenceLifecycleOperation (cleanupScopeAt 1) `shouldBe` ReconcileDesiredAbsent
        evidenceCleanupSurface (cleanupScopeAt 1) `shouldBe` Cascade
        evidenceAwsScope (cleanupScopeAt 1) `shouldBe` Nothing

      -- The response is validated, not trusted: a reply echoing a different
      -- request is a mismatch, and a reply of another kind is a kind mismatch.
      it "refuses a response that echoes a different request" $ do
        let request =
              awsStackCreationSelectWireRequest
                AwsTestKey
                admittedOperation
                (cleanupScopeAt 1)
            response =
              AwsStackCreationWireSelected
                awsStackCreationEndpointFormatVersion
                "someone-else's-request"
                "record-bytes"
        confirmAwsStackCreationSelectResponse
          (awsStackCreationWireRequestPayload request)
          response
          `shouldSatisfy` isRequestMismatch

      it "refuses a commit-shaped response to a selection request" $
        confirmAwsStackCreationSelectResponse
          "payload"
          ( AwsStackCreationWireReadBackPresent
              awsStackCreationEndpointFormatVersion
              "identity"
              "binding"
          )
          `shouldSatisfy` isKindMismatch
 where
  scopeAt micros =
    registeredStackCreationScope
      (homeLinuxRke2FoundationId "prodbox-home")
      (registeredStackCreationRunScope micros)

  cleanupScopeAt micros =
    registeredStackCleanupScope
      Cascade
      (homeLinuxRke2FoundationId "prodbox-home")
      (registeredStackCreationRunScope micros)

  isRequestMismatch outcome = case outcome of
    Left (AwsStackCreationEndpointResponseRequestMismatch _ _) -> True
    _ -> False

  isKindMismatch outcome = case outcome of
    Left AwsStackCreationEndpointResponseKindMismatch -> True
    _ -> False

roundTrip
  :: ProviderDispatchResponse
  -> Either String ProviderDispatchResponse
roundTrip response =
  either (Left . show) Right (deserialiseOrFail (serialise response))

samplePayload :: ProviderDispatchPayload
samplePayload =
  ProviderDispatchPayload
    { providerDispatchVersion = providerDispatchFormatVersion
    , providerDispatchSubmissionKey = "submission-key"
    , providerDispatchIntent = ObserveProviderAwsScope
    }

admittedOperation :: OperationId
admittedOperation =
  OperationId
    { operationIdEpoch = authorityEpochGenesis
    , operationIdClient = ClientId "operator"
    , operationIdSequence = ClientSequence 7
    , operationIdDigest = RequestDigest "request-digest"
    }
