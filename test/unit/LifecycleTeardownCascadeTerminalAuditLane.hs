{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.36: the production lane that fences, audits, records, and — only
-- over a clean verdict — revokes.
--
-- Every route this lane drives existed and none of them had a production
-- caller, so the properties worth measuring are about /what runs/ rather than
-- about the transitions, which the epoch's own suite already pins. These cases
-- count effects: the two destructive halves are not attempted at all when the
-- audit did not come back clean, nothing is attempted when the fence or the
-- record refused, and the ordered submissions are the three the Authority
-- admits, in the one order it admits them.
module LifecycleTeardownCascadeTerminalAuditLane
  ( lifecycleTeardownCascadeTerminalAuditLaneSuite
  )
where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityControlPayload (..)
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKey
  , mkClientSubmissionKey
  )
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
  ( CascadeAuditFreezeBinding
  , CascadeTerminalAuditVerdict (..)
  , mkCascadeAuditFreezeBinding
  )
import Prodbox.Lifecycle.AwsInventory
  ( AwsResourceCoordinate (AwsResourceCoordinate)
  , AwsResourceType (AwsResourceType)
  , AwsTag (AwsTag)
  , AwsTagRow (..)
  , mkArn
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDigest
  , CleanupNodeId
  , CleanupOperationId
  , CleanupRunId
  , mkCleanupAttemptId
  , mkCleanupDigest
  , mkCleanupNodeId
  , mkCleanupOperationId
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.CredentialProvisioner.JointIamDisposition
  ( IamMemberObservation (IamMemberAbsent)
  , JointIamDispositionAuthorization
  , JointIamDispositionComplete
  , disposeJointIamFamily
  , jointIamDispositionFamily
  , mkJointIamDispositionAuthorization
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (LifecycleProviderCredential)
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionTargetGeneration
  , mkDecommissionTargetGeneration
  )
import Prodbox.Lifecycle.Decommission.TargetTombstone
  ( TargetGenerationTombstoneCommand (..)
  , TargetGenerationTombstoneResult (..)
  )
import Prodbox.Lifecycle.Teardown.CascadeCredentialRevocation
  ( CascadeCredentialRevocationBoundary (..)
  , CascadeCredentialRevocationRefusal (..)
  , retainedTargetGenerationRevocationDigest
  , revokeCascadeProviderCredential
  )
import Prodbox.Lifecycle.Teardown.CascadeTerminalAudit
  ( CascadeTerminalAuditBoundary (..)
  )
import Prodbox.Lifecycle.Teardown.CascadeTerminalAuditLane
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , compileDesiredAbsenceGraph
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (AwsAccountId)
  , AwsRegion (AwsRegion)
  , AwsScope (AwsScope)
  , CleanupSurface (Cascade)
  , CleanupSurfaceWitness (CascadeSurface)
  , LinuxRke2FoundationId (LinuxRke2FoundationId)
  , ObservationFailure (ObservationFailure)
  , ObservationRevision (ObservationRevision)
  )
import Prodbox.Lifecycle.Teardown.RetainedInventory
  ( RetainedNameBinding
  , mkRetainedNameBinding
  )
import TestSupport

lifecycleTeardownCascadeTerminalAuditLaneSuite :: SuiteBuilder ()
lifecycleTeardownCascadeTerminalAuditLaneSuite =
  describe "Sprint 7.36 cascade terminal-audit production lane" $ do
    describe "the ordered lane" $ do
      it "fences, records, and revokes over a clean audit" $ do
        fixture <- newLaneFixture cleanAudit
        outcome <- runLane fixture
        case outcome of
          Left refusal ->
            expectationFailure ("lane refused: " <> show refusal)
          Right result -> do
            cascadeTerminalAuditLaneVerdict result
              `shouldBe` CascadeTerminalAuditReceiptClean
            submissions <- readIORef (laneSubmissions fixture)
            submissions `shouldBe` [FreezeSubmission, RecordSubmission, RevokeSubmission]
            iam <- readIORef (laneIamDisposals fixture)
            iam `shouldBe` 1
            target <- readIORef (laneTombstones fixture)
            target `shouldBe` 1

      -- The safety property this lane exists to hold. An escape means the
      -- credential is exactly what a retry or an investigation runs as, so it
      -- is not merely left un-revoked — the destroy is never attempted.
      it "records an escape and destroys nothing" $ do
        fixture <- newLaneFixture escapedAudit
        outcome <- runLane fixture
        case outcome of
          Left refusal ->
            expectationFailure ("lane refused: " <> show refusal)
          Right result -> do
            cascadeTerminalAuditLaneVerdict result
              `shouldBe` CascadeTerminalAuditReceiptEscaped 1
            submissions <- readIORef (laneSubmissions fixture)
            submissions `shouldBe` [FreezeSubmission, RecordSubmission]
            iam <- readIORef (laneIamDisposals fixture)
            iam `shouldBe` 0
            target <- readIORef (laneTombstones fixture)
            target `shouldBe` 0

      -- A blind spot is a different fact from an escape and licenses the same
      -- restraint: "found nothing among the things I asked about" is not "there
      -- is nothing" when part of the question was never put.
      it "records a blind spot and destroys nothing" $ do
        fixture <- newLaneFixture unobservableAudit
        outcome <- runLane fixture
        case outcome of
          Left refusal ->
            expectationFailure ("lane refused: " <> show refusal)
          Right result -> do
            -- Every query in the catalog went unanswered, so the blind-spot
            -- count is the catalog's own size rather than a number this test
            -- pins independently of it.
            queries <- readIORef (laneQueriesIssued fixture)
            queries `shouldSatisfy` (> 0)
            cascadeTerminalAuditLaneVerdict result
              `shouldBe` CascadeTerminalAuditReceiptUnobservable
                (fromIntegral queries)
            iam <- readIORef (laneIamDisposals fixture)
            iam `shouldBe` 0

      it "takes no audit when the fence refuses" $ do
        fixture <- newLaneFixture cleanAudit
        outcome <- runLaneRefusing fixture FreezeSubmission
        outcome `shouldSatisfy` isFreezeRefused
        queries <- readIORef (laneQueriesIssued fixture)
        queries `shouldBe` 0
        iam <- readIORef (laneIamDisposals fixture)
        iam `shouldBe` 0

      -- The record is what a revocation is entitled to rely on, so a verdict
      -- that is not durable licenses nothing.
      it "destroys nothing when the record refuses" $ do
        fixture <- newLaneFixture cleanAudit
        outcome <- runLaneRefusing fixture RecordSubmission
        outcome `shouldSatisfy` isRecordRefused
        iam <- readIORef (laneIamDisposals fixture)
        iam `shouldBe` 0

    describe "the two-sided revocation proof" $ do
      -- The IAM identity is what grants. Destroying it first means any surviving
      -- copy of the material is already inert; the reverse order removes the
      -- record of a credential whose grant still stands.
      it "leaves the retained material alone when the IAM family is not gone" $ do
        fixture <- newLaneFixture cleanAudit
        revoked <-
          revokeCascadeProviderCredential
            (failingIamRevocationBoundary fixture)
            freezeBinding
            jointAuthorization
            tombstoneCommand
        revoked `shouldSatisfy` isIamNotDisposed
        target <- readIORef (laneTombstones fixture)
        target `shouldBe` 0

      it "submits nothing when the retained Target generation survives" $ do
        fixture <- newLaneFixture cleanAudit
        revoked <-
          revokeCascadeProviderCredential
            (survivingTargetRevocationBoundary fixture)
            freezeBinding
            jointAuthorization
            tombstoneCommand
        revoked `shouldSatisfy` isTargetNotRevoked
        submissions <- readIORef (laneSubmissions fixture)
        submissions `shouldBe` []

      -- A retry that finds the work already done proved the same absence by a
      -- different route, and the digest says which — so it cannot be mistaken
      -- for the run that performed the destroy.
      it "digests an already-absent proof differently from a destroy" $
        retainedTargetGenerationRevocationDigest
          tombstoneCommand
          "already-absent"
          `shouldNotBe` retainedTargetGenerationRevocationDigest
            tombstoneCommand
            "destroyed-and-read-back"

      it "digests a different retained coordinate differently" $
        retainedTargetGenerationRevocationDigest tombstoneCommand "already-absent"
          `shouldNotBe` retainedTargetGenerationRevocationDigest
            tombstoneCommand {targetTombstoneReference = "other-target"}
            "already-absent"
 where
  isFreezeRefused outcome = case outcome of
    Left (CascadeAuditLaneFreezeRefused _) -> True
    _ -> False

  isRecordRefused outcome = case outcome of
    Left (CascadeAuditLaneRecordRefused _) -> True
    _ -> False

  isIamNotDisposed outcome = case outcome of
    Left (CascadeRevocationIamFamilyNotDisposed _) -> True
    _ -> False

  isTargetNotRevoked outcome = case outcome of
    Left (CascadeRevocationTargetGenerationNotRevoked _) -> True
    _ -> False

-- ---------------------------------------------------------------------------
-- The fixture
-- ---------------------------------------------------------------------------

-- | Which of the three routes one submission took, recorded in order.
data LaneSubmission
  = FreezeSubmission
  | RecordSubmission
  | RevokeSubmission
  deriving (Eq, Show)

data LaneFixture = LaneFixture
  { laneSubmissions :: !(IORef [LaneSubmission])
  , laneIamDisposals :: !(IORef Word)
  , laneTombstones :: !(IORef Word)
  , laneQueriesIssued :: !(IORef Word)
  , laneAuditAnswer :: !(Either ObservationFailure [AwsTagRow])
  }

newLaneFixture :: Either ObservationFailure [AwsTagRow] -> IO LaneFixture
newLaneFixture answer = do
  submissions <- newIORef []
  iam <- newIORef 0
  tombstones <- newIORef 0
  queries <- newIORef 0
  pure
    LaneFixture
      { laneSubmissions = submissions
      , laneIamDisposals = iam
      , laneTombstones = tombstones
      , laneQueriesIssued = queries
      , laneAuditAnswer = answer
      }

runLane
  :: LaneFixture
  -> IO
       ( Either
           CascadeTerminalAuditLaneRefusal
           CascadeTerminalAuditLaneOutcome
       )
runLane fixture = runLaneWith fixture (const True)

runLaneRefusing
  :: LaneFixture
  -> LaneSubmission
  -> IO
       ( Either
           CascadeTerminalAuditLaneRefusal
           CascadeTerminalAuditLaneOutcome
       )
runLaneRefusing fixture refused = runLaneWith fixture (/= refused)

runLaneWith
  :: LaneFixture
  -> (LaneSubmission -> Bool)
  -> IO
       ( Either
           CascadeTerminalAuditLaneRefusal
           CascadeTerminalAuditLaneOutcome
       )
runLaneWith fixture admits =
  runCascadeTerminalAuditLane
    (laneBoundary fixture admits)
    freezeBinding
    retainedBinding
    compiledCascade
    (ObservationRevision 1)
    jointAuthorization
    tombstoneCommand

laneBoundary
  :: LaneFixture
  -> (LaneSubmission -> Bool)
  -> CascadeTerminalAuditLaneBoundary IO
laneBoundary fixture admits =
  CascadeTerminalAuditLaneBoundary
    { cascadeAuditLaneSubmitControl = submit fixture admits
    , cascadeAuditLaneQueries =
        CascadeTerminalAuditBoundary $ \_query -> do
          modifyIORef' (laneQueriesIssued fixture) (+ 1)
          pure (laneAuditAnswer fixture)
    , cascadeAuditLaneRevocation = revocationBoundary fixture admits
    }

submit
  :: LaneFixture
  -> (LaneSubmission -> Bool)
  -> AuthorityControlPayload
  -> IO (Either Text Text)
submit fixture admits payload = case laneSubmissionFor payload of
  Nothing -> pure (Left "unexpected control payload")
  Just submission
    | admits submission -> do
        modifyIORef' (laneSubmissions fixture) (++ [submission])
        pure (Right "applied")
    | otherwise -> pure (Left "refused")

laneSubmissionFor :: AuthorityControlPayload -> Maybe LaneSubmission
laneSubmissionFor payload = case payload of
  AuthorityControlFreezeProviderAdmissionForCascadeAudit _ ->
    Just FreezeSubmission
  AuthorityControlRecordCascadeTerminalAuditReceipt _ _ -> Just RecordSubmission
  AuthorityControlRevokeCascadeProviderCredential _ _ -> Just RevokeSubmission
  _ -> Nothing

revocationBoundary
  :: LaneFixture
  -> (LaneSubmission -> Bool)
  -> CascadeCredentialRevocationBoundary IO
revocationBoundary fixture admits =
  CascadeCredentialRevocationBoundary
    { cascadeRevocationDisposeIamFamily = \authorization -> do
        modifyIORef' (laneIamDisposals fixture) (+ 1)
        pure (disposeAbsentFamily authorization)
    , cascadeRevocationTombstoneTargetGeneration = \_command -> do
        modifyIORef' (laneTombstones fixture) (+ 1)
        pure TargetGenerationDestroyedAndReadBack
    , cascadeRevocationSubmitControl = submit fixture admits
    }

failingIamRevocationBoundary
  :: LaneFixture -> CascadeCredentialRevocationBoundary IO
failingIamRevocationBoundary fixture =
  (revocationBoundary fixture (const True))
    { cascadeRevocationDisposeIamFamily = \_authorization ->
        pure (Left "one access key is still present")
    }

survivingTargetRevocationBoundary
  :: LaneFixture -> CascadeCredentialRevocationBoundary IO
survivingTargetRevocationBoundary fixture =
  (revocationBoundary fixture (const True))
    { cascadeRevocationTombstoneTargetGeneration = \_command -> do
        modifyIORef' (laneTombstones fixture) (+ 1)
        pure TargetGenerationPresent
    }

-- | The completion a real destroy mints: every family member independently
-- absent.
disposeAbsentFamily
  :: JointIamDispositionAuthorization
  -> Either Text JointIamDispositionComplete
disposeAbsentFamily authorization =
  either
    (Left . const "joint disposition refused")
    Right
    ( disposeJointIamFamily
        authorization
        [ (member, IamMemberAbsent)
        | member <- jointIamDispositionFamily authorization
        ]
    )

-- ---------------------------------------------------------------------------
-- Fixed values
-- ---------------------------------------------------------------------------

cleanAudit :: Either ObservationFailure [AwsTagRow]
cleanAudit = Right []

escapedAudit :: Either ObservationFailure [AwsTagRow]
escapedAudit =
  Right
    [ AwsTagRow
        { awsTagRowArn =
            mustRight
              ( mkArn
                  "arn:aws:ec2:us-east-1:123456789012:instance/i-0escapee"
              )
        , awsTagRowScope = auditScope
        , awsTagRowResourceType = AwsResourceType "ec2:instance"
        , awsTagRowCoordinate = AwsResourceCoordinate "i-0escapee"
        , awsTagRowTag = Just (AwsTag "prodbox:owner" "prodbox")
        }
    ]

unobservableAudit :: Either ObservationFailure [AwsTagRow]
unobservableAudit = Left (ObservationFailure "tagging api unreachable")

auditScope :: AwsScope
auditScope = AwsScope (AwsAccountId "123456789012") (AwsRegion "us-east-1")

compiledCascade :: CompiledDesiredAbsenceProgram 'Cascade
compiledCascade =
  mustRight
    ( compileDesiredAbsenceGraph
        cascadeRunId
        (LinuxRke2FoundationId "home-rke2")
        (Just auditScope)
        CascadeSurface
    )

retainedBinding :: RetainedNameBinding
retainedBinding =
  mustRight
    ( mkRetainedNameBinding
        "prodbox-pulumi-state"
        "prodbox-ses-capture"
        "example.test"
        "prodbox-eks-run"
    )

freezeBinding :: CascadeAuditFreezeBinding
freezeBinding =
  mustRight
    ( mkCascadeAuditFreezeBinding
        cascadeRunId
        descriptorDigest
        graphDigest
        scopeDigest
        cascadeNodeId
        cascadeOperationId
        cascadeAttemptId
        [cascadeSubmissionKey]
    )

cascadeRunId :: CleanupRunId
cascadeRunId = mustRight (mkCleanupRunId "cascade-terminal-audit-lane")

descriptorDigest :: CleanupDigest
descriptorDigest = mustRight (mkCleanupDigest (replicateHex 'a'))

graphDigest :: CleanupDigest
graphDigest = mustRight (mkCleanupDigest (replicateHex 'b'))

scopeDigest :: Text
scopeDigest = replicateHex 'c'

replicateHex :: Char -> Text
replicateHex = Text.replicate 64 . Text.singleton

cascadeNodeId :: CleanupNodeId
cascadeNodeId = mustRight (mkCleanupNodeId "cascade-terminal-audit")

cascadeOperationId :: CleanupOperationId
cascadeOperationId = mustRight (mkCleanupOperationId "cascade-terminal-audit-op")

cascadeAttemptId :: CleanupAttemptId
cascadeAttemptId = mustRight (mkCleanupAttemptId "cascade-terminal-audit-attempt")

cascadeSubmissionKey :: ClientSubmissionKey
cascadeSubmissionKey =
  mustRight (mkClientSubmissionKey "cascade-terminal-audit-query")

jointAuthorization :: JointIamDispositionAuthorization
jointAuthorization =
  mustRight (mkJointIamDispositionAuthorization LifecycleProviderCredential Nothing)

tombstoneCommand :: TargetGenerationTombstoneCommand
tombstoneCommand =
  TargetGenerationTombstoneCommand
    { targetTombstoneReference = "lifecycle-provider"
    , targetTombstoneGeneration = providerTargetGeneration
    }

providerTargetGeneration :: DecommissionTargetGeneration
providerTargetGeneration = mustRight (mkDecommissionTargetGeneration 1)

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
