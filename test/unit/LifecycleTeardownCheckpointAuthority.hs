{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownCheckpointAuthority
  ( lifecycleTeardownCheckpointAuthoritySuite
  )
where

import Data.Functor.Identity (Identity (runIdentity))
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ControlPlane.AuthorityOperationClient
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.Authority.PulumiCheckpointRegistry
import Prodbox.Lifecycle.Authority.Submission
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.PulumiCheckpoint
import Prodbox.Lifecycle.Teardown.CheckpointAuthority
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownCheckpointAuthoritySuite :: SuiteBuilder ()
lifecycleTeardownCheckpointAuthoritySuite =
  describe "Sprint 4.85 exact cleanup checkpoint Authority admission" $ do
    it "uses one stable key while binding each exact reference in the request digest" $ do
      let first = prepare referenceOne scope operationId CheckpointPrimaryRestore
          second = prepare referenceTwo scope operationId CheckpointPrimaryRestore
      checkpointAuthoritySubmissionKey first
        `shouldBe` checkpointAuthoritySubmissionKey second
      checkpointAuthorityRequestDigest first
        `shouldNotBe` checkpointAuthorityRequestDigest second

    it "length-prefixes raw scope fields so slash-delimited tuples cannot collide" $ do
      let first = prepare referenceOne delimiterScopeOne operationId CheckpointPrimaryRestore
          second = prepare referenceOne delimiterScopeTwo operationId CheckpointPrimaryRestore
      checkpointAuthoritySubmissionKey first
        `shouldNotBe` checkpointAuthoritySubmissionKey second
      checkpointAuthorityRequestDigest first
        `shouldNotBe` checkpointAuthorityRequestDigest second

    it "length-prefixes checkpoint versions before hashing the exact request" $ do
      let first = prepare delimiterReferenceOne scope operationId CheckpointPrimaryRestore
          second = prepare delimiterReferenceTwo scope operationId CheckpointPrimaryRestore
      checkpointAuthoritySubmissionKey first
        `shouldBe` checkpointAuthoritySubmissionKey second
      checkpointAuthorityRequestDigest first
        `shouldNotBe` checkpointAuthorityRequestDigest second

    it "recovers the exact Authority operation by stable key and seals it only after reference binding" $ do
      let prepared = prepare referenceOne scope operationId CheckpointPrimaryRestore
          operation = operationFor (checkpointAuthorityRequestDigest prepared)
          observed =
            runIdentity
              ( observeCheckpointAuthorityOperation
                  (observingClient operation StatusInFlight)
                  operationId
                  AwsEksKey
                  scope
                  CheckpointPrimaryRestore
              )
          recovered = mustRight observed
          bound = mustRight (bindObservedCheckpointAuthorityOperation recovered (Just referenceOne))
      observedCheckpointAuthorityOperationId recovered `shouldBe` operation
      observedCheckpointAuthorityOperationStatus recovered `shouldBe` StatusInFlight
      checkpointAuthorityOperationId bound `shouldBe` Just operation
      checkpointAuthorityExpectedReference bound `shouldBe` Just referenceOne
      checkpointAuthorityRequestDigest bound
        `shouldBe` checkpointAuthorityRequestDigest prepared

    it "refuses wrong reference, key, scope, and purpose bindings after recovery" $ do
      let prepared = prepare referenceOne scope operationId CheckpointPrimaryRestore
          operation = operationFor (checkpointAuthorityRequestDigest prepared)
          recover selectedKey selectedScope selectedPurpose =
            mustRight
              ( runIdentity
                  ( observeCheckpointAuthorityOperation
                      (observingClient operation statusSettledCompleted)
                      operationId
                      selectedKey
                      selectedScope
                      selectedPurpose
                  )
              )
          bindings =
            [ bindObservedCheckpointAuthorityOperation
                (recover AwsEksKey scope CheckpointPrimaryRestore)
                (Just referenceTwo)
            , bindObservedCheckpointAuthorityOperation
                (recover AwsEksSubzoneKey scope CheckpointPrimaryRestore)
                (Just referenceOne)
            , bindObservedCheckpointAuthorityOperation
                (recover AwsEksKey otherScope CheckpointPrimaryRestore)
                (Just referenceOne)
            , bindObservedCheckpointAuthorityOperation
                (recover AwsEksKey scope CheckpointReferenceRetirement)
                (Just referenceOne)
            ]
      bindings `shouldSatisfy` all isDigestMismatch

    it "reports a missing stable reservation instead of allocating a fresh operation" $ do
      runIdentity
        ( observeCheckpointAuthorityOperation
            unknownClient
            operationId
            AwsEksKey
            scope
            CheckpointPrimaryRestore
        )
        `shouldSatisfy` isUnknown

    it "submits accepted and duplicate retries under the same key and exact digest" $ do
      let accepted =
            runIdentity
              ( admitCheckpointAuthorityOperation
                  acceptingClient
                  operationId
                  AwsEksKey
                  scope
                  CheckpointPrimaryRestore
                  (Just referenceOne)
              )
          duplicate =
            runIdentity
              ( admitCheckpointAuthorityOperation
                  duplicateClient
                  operationId
                  AwsEksKey
                  scope
                  CheckpointPrimaryRestore
                  (Just referenceOne)
              )
      fmap checkpointAuthorityOperationId accepted
        `shouldBe` fmap checkpointAuthorityOperationId duplicate
      fmap checkpointAuthoritySubmissionKey accepted
        `shouldBe` fmap checkpointAuthoritySubmissionKey duplicate

prepare
  :: VerifiedPulumiCheckpointRef
  -> ObservationEvidenceScope
  -> CleanupOperationId
  -> CheckpointAuthorityPurpose
  -> CheckpointAuthorityOperation
prepare reference selectedScope selectedOperation purpose =
  mustRight
    ( prepareCheckpointAuthorityOperation
        selectedOperation
        AwsEksKey
        selectedScope
        purpose
        (Just reference)
    )

observingClient
  :: OperationId
  -> SubmissionStatus
  -> AuthorityOperationClient Identity
observingClient operation status =
  AuthorityOperationClient
    { submitAuthorityOperation = \_ _ -> error "submit is not used"
    , observeAuthorityOperation =
        \_ -> pure (Right (Just (AuthorityOperationObservation operation status)))
    }

unknownClient :: AuthorityOperationClient Identity
unknownClient =
  AuthorityOperationClient
    { submitAuthorityOperation = \_ _ -> error "submit is not used"
    , observeAuthorityOperation = \_ -> pure (Right Nothing)
    }

acceptingClient :: AuthorityOperationClient Identity
acceptingClient = admissionClient AuthorityOperationAdmissionAccepted

duplicateClient :: AuthorityOperationClient Identity
duplicateClient = admissionClient AuthorityOperationAdmissionDuplicate

admissionClient
  :: (OperationId -> AuthorityOperationAdmission)
  -> AuthorityOperationClient Identity
admissionClient admitted =
  AuthorityOperationClient
    { submitAuthorityOperation =
        \_ digest -> pure (Right (admitted (operationFor digest)))
    , observeAuthorityOperation = \_ -> error "observe is not used"
    }

operationFor :: RequestDigest -> OperationId
operationFor =
  OperationId
    authorityEpochGenesis
    (ClientId "checkpoint-authority-test")
    (ClientSequence 1)

statusSettledCompleted :: SubmissionStatus
statusSettledCompleted = StatusSettled OperationCompletedOutcome

isDigestMismatch :: Either CheckpointAuthorityError value -> Bool
isDigestMismatch result = case result of
  Left CheckpointAuthorityObservedDigestMismatch {} -> True
  _ -> False

isUnknown :: Either CheckpointAuthorityError value -> Bool
isUnknown result = case result of
  Left CheckpointAuthorityOperationUnknown {} -> True
  _ -> False

operationId :: CleanupOperationId
operationId = mustRight (mkCleanupOperationId "cascade/aws-eks/checkpoint-restore")

scope :: ObservationEvidenceScope
scope = scopeWith "checkpoint-run" "local-rke2-foundation"

otherScope :: ObservationEvidenceScope
otherScope = scopeWith "other-run" "local-rke2-foundation"

delimiterScopeOne :: ObservationEvidenceScope
delimiterScopeOne = scopeWith "a/b" "c"

delimiterScopeTwo :: ObservationEvidenceScope
delimiterScopeTwo = scopeWith "a" "b/c"

scopeWith :: Text.Text -> Text.Text -> ObservationEvidenceScope
scopeWith runScope foundation =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope runScope)
    (LinuxRke2FoundationId foundation)
    (Just (AwsScope (AwsAccountId "123456789012") (AwsRegion (fixtureAwsRegion FixtureUsEast1))))
    ReconcileDesiredAbsent

referenceOne :: VerifiedPulumiCheckpointRef
referenceOne = checkpointReference "primary-v1" "backup-v1"

referenceTwo :: VerifiedPulumiCheckpointRef
referenceTwo = checkpointReference "primary-v2" "backup-v2"

delimiterReferenceOne :: VerifiedPulumiCheckpointRef
delimiterReferenceOne = checkpointReference "a/b" "c"

delimiterReferenceTwo :: VerifiedPulumiCheckpointRef
delimiterReferenceTwo = checkpointReference "a" "b/c"

checkpointReference :: Text.Text -> Text.Text -> VerifiedPulumiCheckpointRef
checkpointReference primaryVersion backupVersion =
  mustRight
    ( mkVerifiedPulumiCheckpointRef
        (canonicalPulumiCheckpointDigest checkpoint)
        ciphertextDigest
        primaryVersion
        ciphertextDigest
        backupVersion
    )

checkpoint :: CanonicalPulumiCheckpoint
checkpoint =
  mustRight
    ( decodeCanonicalPulumiCheckpoint
        (Set.singleton PulumiFileBackendCheckpoint)
        pulumiCheckpointMaximumBytes
        (TextEncoding.encodeUtf8 "{\"version\":3,\"checkpoint\":{\"sequence\":1}}")
    )

ciphertextDigest :: Text.Text
ciphertextDigest = Text.replicate 64 "a"

mustRight :: (Show errorValue) => Either errorValue value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
