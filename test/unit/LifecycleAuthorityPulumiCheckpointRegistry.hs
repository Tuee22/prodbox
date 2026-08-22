{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthorityPulumiCheckpointRegistry
  ( lifecycleAuthorityPulumiCheckpointRegistrySuite
  )
where

import Control.Monad (foldM)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerService)
  )
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , AuthorityAdmissionCommand (..)
  , AuthorityRegisteredSubmissionDecision (..)
  , authorityCheckpointOperationRef
  , authorityCheckpointOperationStatus
  , initialCleanInstallAuthorityWithRegisteredClients
  , observeRegisteredAuthoritySubmission
  , stepAuthorityAdmission
  , stepAuthorityCheckpointPermit
  , stepAuthorityCheckpointPublication
  , stepRegisteredAuthoritySubmission
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( RegisteredClientGeneration
  , RegisteredSubmissionDecision (..)
  , RegisteredSubmissionObservation (..)
  , clientPrincipalForCaller
  , mkClientSubmissionKey
  , mkRegisteredClientGeneration
  , mkRegisteredClientSlot
  , mkRegisteredClientSpec
  , mkRegisteredClientTable
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityGenesisCommand (..)
  , BackupReceipt (..)
  , GenesisPlan (..)
  , TargetAgentGenerationReceipt (..)
  , authorityEpochGenesis
  )
import Prodbox.Lifecycle.Authority.PulumiCheckpointRegistry
import Prodbox.Lifecycle.Authority.Submission
  ( ClientId (..)
  , ClientSequence (..)
  , OperationId (..)
  , RequestDigest (..)
  , SubmissionStatus (StatusExpired, StatusSettled)
  , TerminalOutcome (OperationCompletedOutcome)
  )
import Prodbox.Lifecycle.PulumiCheckpoint
import Prodbox.Lifecycle.Teardown.CapabilityCustody.Universe
  ( CustodyDispositionKind (DispositionDischargedByAbsence)
  , CustodyDispositionRecord (..)
  , renderedCheckpointCapability
  )
import Prodbox.Runtime.Role (RuntimeRole (ProviderWorkerRuntime))
import TestSupport

lifecycleAuthorityPulumiCheckpointRegistrySuite :: SuiteBuilder ()
lifecycleAuthorityPulumiCheckpointRegistrySuite =
  describe "Sprint 4.50 aggregate Pulumi checkpoint registry" $ do
    it "refuses a retirement no disposition was ever stated for" $ do
      -- Sprint 4.89: the Lifecycle Authority cannot observe AWS and so cannot
      -- check the proof a disposition carries. What it refuses is a retirement
      -- for which none was stated, which is the failure that stranded two AWS
      -- resources.
      --
      -- An aggregate written before this sprint carries no disposition map at
      -- all. It still decodes — a durable Authority must survive the upgrade —
      -- and every retirement permit inside it refuses rather than defaulting to
      -- a permissive answer.
      let regression = fixedAuthorityCheckpointSerialiseRegression
      authorityCheckpointLegacyAggregateDecodes regression `shouldBe` True
      authorityCheckpointLegacyRetirementRefused regression `shouldBe` True
      authorityCheckpointDispositionRoundTrips regression `shouldBe` True

    it "starts with exactly the closed stack inventory and no checkpoint" $ do
      validateAuthorityPulumiCheckpoints initialAuthorityPulumiCheckpoints
        `shouldBe` Right ()
      mapM_
        ( \registered ->
            observeAuthorityPulumiCheckpoint
              registered
              initialAuthorityPulumiCheckpoints
              `shouldBe` Nothing
        )
        registeredPulumiCheckpoints

    it "requires an exact operation/stack/kind permit before publication" $ do
      registered <- checkpointRegistration "aws-test"
      other <- checkpointRegistration "aws-ses"
      operation <- checkpointOperation "operation-1"
      reference <- checkpointReference "primary-1" "backup-1" checkpointOne
      applyCheckpointPublication
        operation
        registered
        reference
        initialAuthorityPulumiCheckpoints
        `shouldBe` Right
          ( CheckpointMutationRefusedUnknownOperation
          , initialAuthorityPulumiCheckpoints
          )
      (registeredDecision, permitted) <-
        accepted
          ( registerCheckpointOperationPermit
              operation
              registered
              PublishCheckpoint
              Nothing
              Nothing
              initialAuthorityPulumiCheckpoints
          )
      registeredDecision `shouldBe` CheckpointPermitRegistered
      fmap
        fst
        ( registerCheckpointOperationPermit
            operation
            registered
            PublishCheckpoint
            Nothing
            Nothing
            permitted
        )
        `shouldBe` Right CheckpointPermitAlreadyRegistered
      fmap
        fst
        ( registerCheckpointOperationPermit
            operation
            other
            PublishCheckpoint
            Nothing
            Nothing
            permitted
        )
        `shouldBe` Right CheckpointPermitRefusedOperationReuse
      fmap fst (applyCheckpointPublication operation other reference permitted)
        `shouldBe` Right CheckpointMutationRefusedBinding

    it "lets the aggregate mint only the canonical ref of an admitted in-flight operation" $ do
      registered <- checkpointRegistration "aws-test"
      let caller = CallerService ProviderWorkerRuntime
          generation = acceptedPure (mkRegisteredClientGeneration 1)
          submissionKey = acceptedPure (mkClientSubmissionKey "checkpoint-request")
          initial = openedRegisteredAuthority caller generation
          client = ClientId "registered-slot/1/generation/1"
          sequenceNumber = ClientSequence 1
          digest = RequestDigest "checkpoint-request-digest"
          fabricated =
            OperationId
              authorityEpochGenesis
              client
              sequenceNumber
              digest
      fmap
        fst
        ( stepAuthorityCheckpointPermit
            caller
            generation
            fabricated
            registered
            PublishCheckpoint
            Nothing
            Nothing
            initial
        )
        `shouldBe` Right CheckpointPermitRefusedSubmissionUnknown
      (submitDecision, admitted) <-
        accepted
          ( stepRegisteredAuthoritySubmission
              initial
              caller
              generation
              submissionKey
              digest
          )
      operation <- acceptedRegistered submitDecision
      _ <- accepted (authorityCheckpointOperationRef operation)
      let forgedDigest = operation {operationIdDigest = RequestDigest "forged"}
      fmap
        fst
        ( stepAuthorityCheckpointPermit
            caller
            generation
            forgedDigest
            registered
            PublishCheckpoint
            Nothing
            Nothing
            admitted
        )
        `shouldBe` Right CheckpointPermitRefusedSubmissionBinding
      (permitDecision, permitted) <-
        accepted
          ( stepAuthorityCheckpointPermit
              caller
              generation
              operation
              registered
              PublishCheckpoint
              Nothing
              Nothing
              admitted
          )
      permitDecision `shouldBe` CheckpointPermitRegistered
      reference <- checkpointReference "primary-1" "backup-1" checkpointOne
      fmap
        fst
        ( stepAuthorityCheckpointPublication
            caller
            generation
            operation
            registered
            reference
            permitted
        )
        `shouldBe` Right CheckpointMutationApplied
      (_, published) <-
        accepted
          ( stepAuthorityCheckpointPublication
              caller
              generation
              operation
              registered
              reference
              permitted
          )
      authorityCheckpointOperationStatus caller generation operation published
        `shouldBe` Right (StatusSettled OperationCompletedOutcome)

    it "promotes only a read-back reference and makes exact response-loss replay idempotent" $ do
      registered <- checkpointRegistration "aws-test"
      operation <- checkpointOperation "operation-1"
      reference <- checkpointReference "primary-1" "backup-1" checkpointOne
      (_, permitted) <-
        accepted
          ( registerCheckpointOperationPermit
              operation
              registered
              PublishCheckpoint
              Nothing
              Nothing
              initialAuthorityPulumiCheckpoints
          )
      (decision, published) <-
        accepted
          (applyCheckpointPublication operation registered reference permitted)
      decision `shouldBe` CheckpointMutationApplied
      observeAuthorityPulumiCheckpoint registered published
        `shouldBe` Just reference
      fmap
        fst
        (applyCheckpointPublication operation registered reference published)
        `shouldBe` Right CheckpointMutationAlreadyApplied
      otherReference <- checkpointReference "primary-2" "backup-2" checkpointTwo
      fmap
        fst
        (applyCheckpointPublication operation registered otherReference published)
        `shouldBe` Right CheckpointMutationRefusedReplayConflict

    it "settles, compacts, and recovers retained capacity without reviving the old key" $ do
      registered <- checkpointRegistration "aws-test"
      reference <- checkpointReference "primary-1" "backup-1" checkpointOne
      let caller = CallerService ProviderWorkerRuntime
          generation = acceptedPure (mkRegisteredClientGeneration 1)
          keyOne = acceptedPure (mkClientSubmissionKey "checkpoint-one")
          keyTwo = acceptedPure (mkClientSubmissionKey "checkpoint-two")
          digestOne = RequestDigest "checkpoint-one-digest"
          digestTwo = RequestDigest "checkpoint-two-digest"
          initial = openedRegisteredAuthority caller generation
      (firstDecision, firstAdmitted) <-
        accepted
          ( stepRegisteredAuthoritySubmission
              initial
              caller
              generation
              keyOne
              digestOne
          )
      firstOperation <- acceptedRegistered firstDecision
      (_, firstPermitted) <-
        accepted
          ( stepAuthorityCheckpointPermit
              caller
              generation
              firstOperation
              registered
              PublishCheckpoint
              Nothing
              Nothing
              firstAdmitted
          )
      (_, firstPublished) <-
        accepted
          ( stepAuthorityCheckpointPublication
              caller
              generation
              firstOperation
              registered
              reference
              firstPermitted
          )
      authorityCheckpointOperationStatus caller generation firstOperation firstPublished
        `shouldBe` Right (StatusSettled OperationCompletedOutcome)
      (secondDecision, secondAdmitted) <-
        accepted
          ( stepRegisteredAuthoritySubmission
              firstPublished
              caller
              generation
              keyTwo
              digestTwo
          )
      secondOperation <- acceptedRegistered secondDecision
      operationIdSequence secondOperation `shouldBe` ClientSequence 2
      observeRegisteredAuthoritySubmission
        secondAdmitted
        caller
        generation
        keyOne
        `shouldBe` Right (RegisteredSubmissionObserved firstOperation StatusExpired)

    it "fences successor publication and retirement on the observed predecessor digest" $ do
      registered <- checkpointRegistration "aws-test"
      firstOperation <- checkpointOperation "operation-1"
      secondOperation <- checkpointOperation "operation-2"
      retireOperation <- checkpointOperation "operation-3"
      firstReference <- checkpointReference "primary-1" "backup-1" checkpointOne
      secondReference <- checkpointReference "primary-2" "backup-2" checkpointTwo
      (_, firstPermit) <-
        accepted
          ( registerCheckpointOperationPermit
              firstOperation
              registered
              PublishCheckpoint
              Nothing
              Nothing
              initialAuthorityPulumiCheckpoints
          )
      (_, firstPublished) <-
        accepted
          ( applyCheckpointPublication
              firstOperation
              registered
              firstReference
              firstPermit
          )
      fmap
        fst
        ( registerCheckpointOperationPermit
            secondOperation
            registered
            PublishCheckpoint
            Nothing
            Nothing
            firstPublished
        )
        `shouldBe` Right
          (CheckpointPermitRefusedCurrentDigest (Just firstReference))
      (_, secondPermit) <-
        accepted
          ( registerCheckpointOperationPermit
              secondOperation
              registered
              PublishCheckpoint
              (Just (verifiedPulumiCheckpointDigest firstReference))
              Nothing
              firstPublished
          )
      (_, secondPublished) <-
        accepted
          ( applyCheckpointPublication
              secondOperation
              registered
              secondReference
              secondPermit
          )
      (_, retirePermit) <-
        accepted
          ( registerCheckpointOperationPermit
              retireOperation
              registered
              RetireCheckpoint
              (Just (verifiedPulumiCheckpointDigest secondReference))
              (Just (fixtureRetirementDispositionFor registered))
              secondPublished
          )
      (retiredDecision, retired) <-
        accepted
          (applyCheckpointRetirement retireOperation registered retirePermit)
      retiredDecision `shouldBe` CheckpointMutationApplied
      observeAuthorityPulumiCheckpoint registered retired `shouldBe` Nothing
      fmap fst (applyCheckpointRetirement retireOperation registered retired)
        `shouldBe` Right CheckpointMutationAlreadyApplied

    it
      "retains applied restore and retirement references until an explicit read-back acknowledgement exists"
      $ do
        registered <- checkpointRegistration "aws-test"
        publishOperation <- checkpointOperation "retain-publication"
        restoreOperation <- checkpointOperation "retain-restore"
        retirementOperation <- checkpointOperation "retain-retirement"
        predecessor <- checkpointReference "primary-1" "backup-1" checkpointOne
        restoredReference <- checkpointReference "primary-restored" "backup-1" checkpointOne
        (_, publishPermit) <-
          accepted
            ( registerCheckpointOperationPermit
                publishOperation
                registered
                PublishCheckpoint
                Nothing
                Nothing
                initialAuthorityPulumiCheckpoints
            )
        (_, published) <-
          accepted
            ( applyCheckpointPublication
                publishOperation
                registered
                predecessor
                publishPermit
            )
        (_, restorePermit) <-
          accepted
            ( registerCheckpointOperationPermit
                restoreOperation
                registered
                RestoreCheckpoint
                (Just (verifiedPulumiCheckpointDigest predecessor))
                Nothing
                published
            )
        (_, restored) <-
          accepted
            ( applyCheckpointRestore
                restoreOperation
                registered
                predecessor
                restoredReference
                restorePermit
            )
        compactTerminalCheckpointOperation restoreOperation restored
          `shouldBe` Right (False, restored)
        (_, retirementPermit) <-
          accepted
            ( registerCheckpointOperationPermit
                retirementOperation
                registered
                RetireCheckpoint
                (Just (verifiedPulumiCheckpointDigest restoredReference))
                (Just (fixtureRetirementDispositionFor registered))
                restored
            )
        (_, retired) <-
          accepted
            (applyCheckpointRetirement retirementOperation registered retirementPermit)
        compactTerminalCheckpointOperation retirementOperation retired
          `shouldBe` Right (False, retired)

    it "refuses a backup digest mismatch and whitespace-bearing receipt versions" $ do
      checkpoint <- checkpointFixture checkpointOne
      let ciphertextDigest = Text.replicate 64 "a"
      mkVerifiedPulumiCheckpointRef
        (canonicalPulumiCheckpointDigest checkpoint)
        ciphertextDigest
        "primary-1"
        "not-the-checkpoint-digest"
        "backup-1"
        `shouldBe` Left
          ( VerifiedCheckpointBackupDigestMismatch
              ciphertextDigest
              "not-the-checkpoint-digest"
          )
      mkVerifiedPulumiCheckpointRef
        (canonicalPulumiCheckpointDigest checkpoint)
        ciphertextDigest
        "primary version"
        ciphertextDigest
        "backup-1"
        `shouldBe` Left
          (VerifiedCheckpointPrimaryVersionInvalid "primary version")

    it "fails closed at the compiled operation-history capacity" $ do
      registered <- checkpointRegistration "aws-test"
      full <-
        foldM
          (registerOne registered)
          initialAuthorityPulumiCheckpoints
          [1 .. authorityPulumiCheckpointOperationCapacity]
      overflow <- checkpointOperation "operation-overflow"
      fmap
        fst
        ( registerCheckpointOperationPermit
            overflow
            registered
            PublishCheckpoint
            Nothing
            Nothing
            full
        )
        `shouldBe` Right CheckpointPermitRefusedCapacity

registerOne
  :: RegisteredPulumiCheckpoint
  -> AuthorityPulumiCheckpoints
  -> Natural
  -> IO AuthorityPulumiCheckpoints
registerOne registered registry index = do
  operation <- checkpointOperation ("operation-" <> Text.pack (show index))
  (decision, next) <-
    accepted
      ( registerCheckpointOperationPermit
          operation
          registered
          PublishCheckpoint
          Nothing
          Nothing
          registry
      )
  decision `shouldBe` CheckpointPermitRegistered
  pure next

checkpointReference
  :: Text.Text
  -> Text.Text
  -> Text.Text
  -> IO VerifiedPulumiCheckpointRef
checkpointReference primary backup bytes = do
  checkpoint <- checkpointFixture bytes
  let ciphertextDigest =
        Text.replicate
          64
          (if bytes == checkpointOne then "a" else "b")
  accepted
    ( mkVerifiedPulumiCheckpointRef
        (canonicalPulumiCheckpointDigest checkpoint)
        ciphertextDigest
        primary
        ciphertextDigest
        backup
    )

checkpointFixture :: Text.Text -> IO CanonicalPulumiCheckpoint
checkpointFixture bytes =
  accepted
    ( decodeCanonicalPulumiCheckpoint
        (Set.singleton PulumiFileBackendCheckpoint)
        pulumiCheckpointMaximumBytes
        (TextEncoding.encodeUtf8 bytes)
    )

checkpointRegistration :: Text.Text -> IO RegisteredPulumiCheckpoint
checkpointRegistration = accepted . registeredPulumiCheckpointByName

openedRegisteredAuthority
  :: CallerPrincipal
  -> RegisteredClientGeneration
  -> AuthorityAdmissionAggregate
openedRegisteredAuthority caller generation =
  foldl
    (\aggregate command -> snd (stepAuthorityAdmission aggregate command))
    initial
    [ ApplyAuthorityGenesis
        (BeginGenesisEstablishment (GenesisPlan "checkpoint-genesis" "backup-prefix"))
    , ApplyAuthorityGenesis
        (ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "target-generation-1"))
    , ApplyAuthorityGenesis
        (ObserveBackupReceipt (BackupReceipt "backup-receipt-1"))
    ]
 where
  principal = clientPrincipalForCaller caller
  slot = acceptedPure (mkRegisteredClientSlot 1)
  spec = acceptedPure (mkRegisteredClientSpec principal slot generation 4)
  table = acceptedPure (mkRegisteredClientTable 1 [spec])
  initial =
    acceptedPure
      (initialCleanInstallAuthorityWithRegisteredClients 1 1 table)

acceptedRegistered
  :: AuthorityRegisteredSubmissionDecision -> IO OperationId
acceptedRegistered decision = case decision of
  AuthorityRegisteredSubmissionDecided
    (RegisteredSubmissionAccepted operation) -> pure operation
  other -> fail ("unexpected registered submission: " <> show other)

acceptedPure :: (Show err) => Either err value -> value
acceptedPure result = case result of
  Left err -> error (show err)
  Right value -> value

checkpointOperation :: Text.Text -> IO PulumiCheckpointOperationRef
checkpointOperation = accepted . mkPulumiCheckpointOperationRef

checkpointOne :: Text.Text
checkpointOne = "{\"version\":3,\"checkpoint\":{\"sequence\":1}}"

checkpointTwo :: Text.Text
checkpointTwo = "{\"version\":3,\"checkpoint\":{\"sequence\":2}}"

accepted :: (Show err) => Either err value -> IO value
accepted result = case result of
  Left err -> fail (show err)
  Right value -> pure value

-- | Sprint 4.89: the disposition a retirement states for the checkpoint it
-- retires.  The Authority cannot check the proof; what it refuses is a
-- retirement for which none was stated.
fixtureRetirementDispositionFor
  :: RegisteredPulumiCheckpoint -> CustodyDispositionRecord
fixtureRetirementDispositionFor registered =
  CustodyDispositionRecord
    { custodyDispositionCapability =
        renderedCheckpointCapability (registeredPulumiCheckpointName registered)
    , custodyDispositionKind = DispositionDischargedByAbsence
    , custodyDispositionDetail = "fixture discharge"
    , custodyDispositionDependants =
        [registeredPulumiCheckpointName registered]
    }
