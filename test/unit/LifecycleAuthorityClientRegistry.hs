{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthorityClientRegistry
  ( lifecycleAuthorityClientRegistrySuite
  )
where

import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal (..))
import Prodbox.Lifecycle.Authority.ClientRegistry
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.Authority.Submission
  ( ClientId
  , ClientSequence (ClientSequence)
  , OperationId (..)
  , RequestDigest (RequestDigest)
  , SubmissionStatus (..)
  , compactClientTerminalsBelow
  , completeSubmission
  , emptySubmissionLedger
  )
import Prodbox.Runtime.Role (RuntimeRole (..))
import TestSupport

lifecycleAuthorityClientRegistrySuite :: SuiteBuilder ()
lifecycleAuthorityClientRegistrySuite =
  describe "Sprint 4.50 fixed Lifecycle Authority client registry" $ do
    it "rejects empty, control-bearing, and overlong principal/submission identities" $ do
      mkClientPrincipal "" `shouldBe` Left ClientPrincipalEmpty
      mkClientPrincipal "service/bad\nprincipal"
        `shouldBe` Left ClientPrincipalInvalidCharacter
      mkClientPrincipal (mconcat (replicate 129 "a"))
        `shouldBe` Left (ClientPrincipalTooLong 129 128)
      mkClientPrincipal "caller-selected"
        `shouldBe` Left (ClientPrincipalUnknown "caller-selected")
      mkClientSubmissionKey "" `shouldBe` Left ClientSubmissionKeyEmpty
      mkClientSubmissionKey "request key"
        `shouldBe` Left ClientSubmissionKeyInvalidCharacter

    it "rejects zero slots, generations, and reservation capacities" $ do
      mkRegisteredClientSlot 0 `shouldBe` Left RegisteredClientSlotMustBePositive
      mkRegisteredClientGeneration 0
        `shouldBe` Left RegisteredClientGenerationMustBePositive
      mkRegisteredClientSpec principal1 slot1 generation1 0
        `shouldBe` Left RegisteredClientReservationsMustBePositive

    it "constructs only a bounded table with unique principals and slots" $ do
      registeredClientTableSize table `shouldBe` 2
      registeredClientTableCapacity table `shouldBe` 2
      mkRegisteredClientTable 1 [spec1, spec2]
        `shouldBe` Left (RegisteredClientTableOverCapacity 2 1)
      mkRegisteredClientTable 2 [spec1, spec1]
        `shouldBe` Left (RegisteredClientPrincipalDuplicated principal1)
      let sameSlot = mustRight (mkRegisteredClientSpec principal2 slot1 generation1 4)
      mkRegisteredClientTable 2 [spec1, sameSlot]
        `shouldBe` Left (RegisteredClientSlotDuplicated slot1)

    it "refuses an unregistered authenticated principal without allocating state" $ do
      let ledger = emptySubmissionLedger 4
      reserve ledger table unknownCaller keyA digestA
        `shouldBe` (RegisteredSubmissionRefusedUnregistered, ledger, table)

    it "allocates the authority sequence and fixed slot/generation identity" $ do
      let (decision, ledger, nextTable) =
            reserve (emptySubmissionLedger 4) table caller1 keyA digestA
      decision
        `shouldBe` RegisteredSubmissionAccepted
          ( OperationId
              authorityEpochGenesis
              (registeredClientId spec1)
              sequence1
              digestA
          )
      observeRegisteredSubmission ledger nextTable caller1 generation1 keyA
        `shouldBe` RegisteredSubmissionObserved (acceptedOperation decision) StatusInFlight
      registeredClientReservationCount principal1 nextTable `shouldBe` Just 1

    it "returns the identical operation on exact submission-key replay" $ do
      let (accepted, ledger1, table1) =
            reserve (emptySubmissionLedger 4) table caller1 keyA digestA
          (duplicate, ledger2, table2) = reserve ledger1 table1 caller1 keyA digestA
      duplicate `shouldBe` duplicateOf accepted
      ledger2 `shouldBe` ledger1
      table2 `shouldBe` table1

    it "refuses a submission-key digest collision without mutating state" $ do
      let (_, ledger1, table1) =
            reserve (emptySubmissionLedger 4) table caller1 keyA digestA
      reserve ledger1 table1 caller1 keyA digestB
        `shouldBe` (RegisteredSubmissionRefusedDigestConflict, ledger1, table1)

    it "allocates monotone sequences independently of caller-chosen keys" $ do
      let (_, ledger1, table1) =
            reserve (emptySubmissionLedger 4) table caller1 keyB digestB
          (accepted, _, _) = reserve ledger1 table1 caller1 keyA digestA
      operationSequence accepted `shouldBe` sequence2

    it "enforces each registered client's reservation ceiling" $ do
      let oneReservationSpec = mustRight (mkRegisteredClientSpec principal1 slot1 generation1 1)
          oneReservationTable = mustRight (mkRegisteredClientTable 1 [oneReservationSpec])
          (_, ledger1, table1) =
            reserve (emptySubmissionLedger 4) oneReservationTable caller1 keyA digestA
      reserve ledger1 table1 caller1 keyB digestB
        `shouldBe` (RegisteredSubmissionRefusedReservationCapacity, ledger1, table1)

    it "preserves global live-submission capacity across client slots" $ do
      let (_, ledger1, table1) =
            reserve (emptySubmissionLedger 1) table caller1 keyA digestA
      reserve ledger1 table1 caller2 keyB digestB
        `shouldBe` (RegisteredSubmissionRefusedGlobalCapacity, ledger1, table1)

    it "fails closed when reservations and the submission ledger diverge" $ do
      let (_, _, table1) =
            reserve (emptySubmissionLedger 4) table caller1 keyA digestA
          emptyLedger = emptySubmissionLedger 4
      reserve emptyLedger table1 caller1 keyA digestA
        `shouldBe` (RegisteredSubmissionRefusedLedgerDiverged, emptyLedger, table1)
      validateRegisteredClientTable emptyLedger table1
        `shouldBe` Left
          (RegisteredClientReservationMissingFromLedger principal1 keyA)

    it "rejects stale signing generations without allocating or observing state" $ do
      let generation2 = mustRight (mkRegisteredClientGeneration 2)
          ledger = emptySubmissionLedger 4
      reserveRegisteredSubmission
        authorityEpochGenesis
        ledger
        table
        caller1
        generation2
        keyA
        digestA
        `shouldBe` ( RegisteredSubmissionRefusedGenerationMismatch generation1 generation2
                   , ledger
                   , table
                   )
      observeRegisteredSubmission ledger table caller1 generation2 keyA
        `shouldBe` RegisteredSubmissionObserveRefusedGenerationMismatch
          generation1
          generation2

    it "never revives a reservation after terminal compaction" $ do
      let (accepted, ledger1, table1) =
            reserve (emptySubmissionLedger 4) table caller1 keyA digestA
          (client, sequenceNumber) = operationCoordinates accepted
          settled = mustRight (completeSubmission client sequenceNumber ledger1)
          compacted = mustRight (compactClientTerminalsBelow client sequenceNumber settled)
      observeRegisteredSubmission compacted table1 caller1 generation1 keyA
        `shouldBe` RegisteredSubmissionObserved (acceptedOperation accepted) StatusExpired
      reserve compacted table1 caller1 keyA digestA
        `shouldBe` (RegisteredSubmissionRefusedExpired, compacted, table1)
 where
  reserve ledger registry caller key digest =
    reserveRegisteredSubmission
      authorityEpochGenesis
      ledger
      registry
      caller
      generation1
      key
      digest
  caller1 = CallerService ProviderWorkerRuntime
  caller2 = CallerOperatorCli
  unknownCaller = CallerTestHarness
  principal1 = clientPrincipalForCaller caller1
  principal2 = clientPrincipalForCaller caller2
  slot1 = mustRight (mkRegisteredClientSlot 1)
  slot2 = mustRight (mkRegisteredClientSlot 2)
  generation1 = mustRight (mkRegisteredClientGeneration 1)
  spec1 = mustRight (mkRegisteredClientSpec principal1 slot1 generation1 4)
  spec2 = mustRight (mkRegisteredClientSpec principal2 slot2 generation1 4)
  table = mustRight (mkRegisteredClientTable 2 [spec1, spec2])
  keyA = mustRight (mkClientSubmissionKey "request-a")
  keyB = mustRight (mkClientSubmissionKey "request-b")
  digestA = RequestDigest "digest-a"
  digestB = RequestDigest "digest-b"
  sequence1 = ClientSequence 1
  sequence2 = ClientSequence 2

mustRight :: (Show errorValue) => Either errorValue value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value

duplicateOf :: RegisteredSubmissionDecision -> RegisteredSubmissionDecision
duplicateOf decision = case decision of
  RegisteredSubmissionAccepted operationId -> RegisteredSubmissionDuplicate operationId
  other -> error ("expected accepted submission, got " <> show other)

acceptedOperation :: RegisteredSubmissionDecision -> OperationId
acceptedOperation decision = case decision of
  RegisteredSubmissionAccepted operationId -> operationId
  other -> error ("expected accepted submission, got " <> show other)

operationSequence :: RegisteredSubmissionDecision -> ClientSequence
operationSequence decision = case decision of
  RegisteredSubmissionAccepted operationId -> operationIdSequence operationId
  other -> error ("expected accepted submission, got " <> show other)

operationCoordinates :: RegisteredSubmissionDecision -> (ClientId, ClientSequence)
operationCoordinates decision = case decision of
  RegisteredSubmissionAccepted operationId ->
    (operationIdClient operationId, operationIdSequence operationId)
  other -> error ("expected accepted submission, got " <> show other)
