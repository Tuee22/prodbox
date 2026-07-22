{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Exhaustive pure crash/cancellation matrix for Sprint 2.33 custody.
module BootstrapBrokerCustody
  ( bootstrapBrokerCustodySuite
  )
where

import Control.Monad (forM_)
import Data.Bifunctor (first)
import Data.ByteString.Char8 qualified as ByteString
import Data.Either (isLeft, isRight)
import Data.IORef
  ( modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Custody
import Prodbox.Bootstrap.Broker.Fence
import Prodbox.Bootstrap.Broker.Model
import Prodbox.Bootstrap.Broker.PgpBoundary qualified as Pgp
import Prodbox.Bootstrap.Broker.Request
  ( RequestDigest
  , mkRequestDigest
  , mkSecretPayload
  )
import Prodbox.Bootstrap.Broker.Types
import Prodbox.ControlPlane.AuthorityClock
  ( AuthorityClockObservation (..)
  , clockUncertaintyFromMicros
  )
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , MonotonicInstant
  , deadlineFromInstant
  , monotonicInstantFromMicros
  )
import Prodbox.Lifecycle.Lease
  ( OwnerNonce
  , authorityTimeFromMicros
  , mkOwnerNonce
  )
import TestSupport

bootstrapBrokerCustodySuite :: SuiteBuilder ()
bootstrapBrokerCustodySuite = do
  rootInitializationSuite
  rootSessionSuite
  generatedRootBoundarySuite
  provisionerSealAndHandoffSuite
  childCustodySuite
  childRecoverySuite
  productProjectionSuite

data Fixture = Fixture
  { fixturePristine :: !PristineStorageProof
  , fixturePrepared :: !PreparedInitEnvelope
  , fixtureEncryptedResponse :: !EncryptedInitResponseReceipt
  , fixtureFinalPayload :: !FinalUnlockBundlePayload
  , fixtureFinalBundle :: !FinalUnlockBundle
  , fixtureRecoveryCustody :: !RecoveryCustodyReceipt
  , fixtureOtherPristine :: !PristineStorageProof
  , fixtureOtherPrepared :: !PreparedInitEnvelope
  , fixtureOtherEncryptedResponse :: !EncryptedInitResponseReceipt
  , fixtureOtherFinalBundle :: !FinalUnlockBundle
  , fixtureResetProof :: !PristineResetProof
  , fixtureCancellation :: !CancellationReason
  , fixtureSessionId :: !RootSessionId
  , fixtureReplacementSessionId :: !RootSessionId
  , fixtureAccessorA :: !RootPolicyAccessor
  , fixtureAccessorB :: !RootPolicyAccessor
  , fixtureCurrentAccessor :: !RootPolicyAccessor
  , fixtureEmptyInventory :: !RootAccessorInventory
  , fixtureStaleInventory :: !RootAccessorInventory
  , fixtureCurrentInventory :: !RootAccessorInventory
  , fixtureOtherGenerationInventory :: !RootAccessorInventory
  , fixtureEmptyAbsence :: !AccessorAbsenceAttestation
  , fixtureStaleAbsence :: !AccessorAbsenceAttestation
  , fixtureCurrentAbsence :: !AccessorAbsenceAttestation
  , fixtureBaselineReadBack :: !BaselineReadBackReceipt
  , fixtureProvisionerLogin :: !ProvisionerLoginReceipt
  , fixtureHandoffReceipt :: !PostUnsealHandoffReceipt
  , fixtureChildBinding :: !ChildCustodyBinding
  , fixtureOtherChildBinding :: !ChildCustodyBinding
  , fixtureOtherCustodyGenerationBinding :: !ChildCustodyBinding
  , fixtureOtherStorageGenerationBinding :: !ChildCustodyBinding
  , fixtureOtherTransactionBinding :: !ChildCustodyBinding
  , fixtureChildEncryptedReceipt :: !ChildEncryptedReceipt
  , fixtureParentAcknowledgement :: !ParentCustodyAcknowledgement
  , fixtureChildDelivery :: !ChildRecoveryDelivery
  , fixtureOtherNonceDelivery :: !ChildRecoveryDelivery
  , fixtureOtherAttestationDelivery :: !ChildRecoveryDelivery
  , fixtureOtherPayloadDelivery :: !ChildRecoveryDelivery
  , fixtureChildRepairReadBack :: !ChildRecoveryRepairReceipt
  , fixtureDigestA :: !ArtifactDigest
  , fixtureDigestB :: !ArtifactDigest
  }

withFixture :: (Fixture -> Expectation) -> Expectation
withFixture assertion =
  case buildFixture of
    Left err -> expectationFailure ("invalid custody test fixture: " ++ err)
    Right value -> assertion value

buildFixture :: Either String Fixture
buildFixture = do
  transaction <- bootstrapEither (mkBootstrapTransactionId "tx-root-a")
  otherTransaction <- bootstrapEither (mkBootstrapTransactionId "tx-root-b")
  generation <- bootstrapEither (mkVaultStorageGeneration "storage-a")
  otherGeneration <- bootstrapEither (mkVaultStorageGeneration "storage-b")
  schema <- bootstrapEither (mkBootstrapSchemaVersion 1)
  digestA <- digest 'a'
  digestB <- digest 'b'
  digestC <- digest 'c'
  digestD <- digest 'd'
  digestE <- digest 'e'
  recoveryFingerprint <-
    bootstrapEither (mkRecoveryRecipientFingerprint (Text.replicate 64 "a"))
  burnFingerprint <-
    bootstrapEither (mkBurnRecipientFingerprint (Text.replicate 40 "b"))
  sealedPrivateKey <-
    bootstrapEither
      (mkSealedRecoveryRecipientPrivateKey (ByteString.pack "sealed-private-key"))
  encryptedShare <-
    bootstrapEither (mkPgpEncryptedShare (ByteString.pack "encrypted-share"))
  burnCiphertext <-
    bootstrapEither
      (mkBurnTokenCiphertext (ByteString.pack "burn-token-ciphertext"))
  recoveredShare <-
    bootstrapEither (mkRecoveredUnsealShare (ByteString.pack "recovered-share"))
  bundleCiphertext <-
    bootstrapEither
      (mkPasswordAeadCiphertext (ByteString.pack "bundle-ciphertext"))
  childPayload <-
    bootstrapEither
      (mkEncryptedChildRecoveryPayload (ByteString.pack "child-recovery-payload"))
  otherChildPayload <-
    bootstrapEither
      (mkEncryptedChildRecoveryPayload (ByteString.pack "other-child-payload"))

  recipientCommitment <-
    bootstrapEither
      ( mkInitRecipientCommitment
          3
          2
          (replicate 3 "cmVjb3ZlcnktcHVibGljLWtleQ==")
          recoveryFingerprint
          burnFingerprint
          digestE
      )
  let binding = RootInitBinding transaction generation
      otherBinding = RootInitBinding otherTransaction otherGeneration
      pristine = mkPristineStorageProof binding digestA
      otherPristine = mkPristineStorageProof otherBinding digestB
      prepared =
        mkPreparedInitEnvelope
          pristine
          schema
          sealedPrivateKey
          recipientCommitment
          digestB
      otherPrepared =
        mkPreparedInitEnvelope
          otherPristine
          schema
          sealedPrivateKey
          recipientCommitment
          digestC
  encryptedResponse <-
    bootstrapEither
      ( mkEncryptedInitResponseReceipt
          prepared
          (replicate 3 encryptedShare)
          burnCiphertext
          digestC
      )
  otherEncryptedResponse <-
    bootstrapEither
      ( mkEncryptedInitResponseReceipt
          otherPrepared
          (replicate 3 encryptedShare)
          burnCiphertext
          digestD
      )
  payload <-
    bootstrapEither
      (mkFinalUnlockBundlePayload encryptedResponse (replicate 3 recoveredShare))
  otherPayload <-
    bootstrapEither
      (mkFinalUnlockBundlePayload otherEncryptedResponse (replicate 3 recoveredShare))
  let finalBundle = mkFinalUnlockBundle payload bundleCiphertext digestD
      otherFinalBundle = mkFinalUnlockBundle otherPayload bundleCiphertext digestE
      recoveryCustody = mkRecoveryCustodyReceipt finalBundle digestE
      ambiguity = mkInitAmbiguity prepared
      establishedAbsence = mkEstablishedStateAbsence binding digestA
      durableResponseAbsence = mkDurableInitResponseAbsence binding digestB
      baselineAbsence = mkBaselineStateAbsence binding digestC
  resetProof <-
    bootstrapEither
      ( mkPristineResetProof
          ambiguity
          otherPristine
          establishedAbsence
          durableResponseAbsence
          baselineAbsence
      )
  cancellation <- mkCancellationReason "operator requested cancellation"
  sessionId <- bootstrapEither (mkRootSessionId "root-session-a")
  replacementSessionId <- bootstrapEither (mkRootSessionId "root-session-b")
  accessorA <- bootstrapEither (mkRootPolicyAccessor "accessor-a")
  accessorB <- bootstrapEither (mkRootPolicyAccessor "accessor-b")
  currentAccessor <- bootstrapEither (mkRootPolicyAccessor "accessor-current")
  emptyInventory <- bootstrapEither (mkRootAccessorInventory generation [])
  staleInventory <-
    bootstrapEither (mkRootAccessorInventory generation [accessorB, accessorA])
  currentInventory <-
    bootstrapEither (mkRootAccessorInventory generation [currentAccessor])
  otherGenerationInventory <-
    bootstrapEither (mkRootAccessorInventory otherGeneration [currentAccessor])
  let emptyAbsence = mkAccessorAbsenceAttestation emptyInventory digestA
      staleAbsence = mkAccessorAbsenceAttestation staleInventory digestB
      currentAbsence = mkAccessorAbsenceAttestation currentInventory digestC
  baselineReadBack <-
    bootstrapEither
      ( mkBaselineReadBackReceipt
          sessionId
          generation
          requiredRootBaselineTargets
          digestD
      )
  provisionerAccessor <-
    bootstrapEither (mkProvisionerAccessor "provisioner-accessor")
  provisionerLogin <-
    bootstrapEither (mkProvisionerLoginReceipt generation provisionerAccessor 300)
  let handoffReceipt =
        mkPostUnsealHandoffReceipt
          generation
          PostUnsealLifecycleAuthority
          digestE

  childId <- bootstrapEither (mkChildId "child-a")
  otherChildId <- bootstrapEither (mkChildId "child-b")
  custodyGeneration <- bootstrapEither (mkCustodyGeneration 1)
  otherCustodyGeneration <- bootstrapEither (mkCustodyGeneration 2)
  let childBinding =
        ChildCustodyBinding childId generation custodyGeneration transaction
      otherChildBinding =
        ChildCustodyBinding otherChildId generation custodyGeneration transaction
      otherCustodyGenerationBinding =
        ChildCustodyBinding childId generation otherCustodyGeneration transaction
      otherStorageGenerationBinding =
        ChildCustodyBinding childId otherGeneration custodyGeneration transaction
      otherTransactionBinding =
        ChildCustodyBinding childId generation custodyGeneration otherTransaction
  childEncryptedReceipt <-
    bootstrapEither
      ( mkChildEncryptedReceipt
          childBinding
          [encryptedShare]
          burnCiphertext
          digestA
      )
  let parentAcknowledgement =
        mkParentCustodyAcknowledgement childEncryptedReceipt digestB
  nonce <- bootstrapEither (mkDeliveryNonce "delivery-a")
  otherNonce <- bootstrapEither (mkDeliveryNonce "delivery-b")
  let attestation = mkChildAttestation digestA
      otherAttestation = mkChildAttestation digestB
      childDelivery =
        mkChildRecoveryDelivery childBinding nonce attestation childPayload digestC
      otherNonceDelivery =
        mkChildRecoveryDelivery childBinding otherNonce attestation childPayload digestC
      otherAttestationDelivery =
        mkChildRecoveryDelivery childBinding nonce otherAttestation childPayload digestC
      otherPayloadDelivery =
        mkChildRecoveryDelivery childBinding nonce attestation otherChildPayload digestD
      childRepairReadBack = mkChildRecoveryRepairReceipt childDelivery digestE

  pure
    Fixture
      { fixturePristine = pristine
      , fixturePrepared = prepared
      , fixtureEncryptedResponse = encryptedResponse
      , fixtureFinalPayload = payload
      , fixtureFinalBundle = finalBundle
      , fixtureRecoveryCustody = recoveryCustody
      , fixtureOtherPristine = otherPristine
      , fixtureOtherPrepared = otherPrepared
      , fixtureOtherEncryptedResponse = otherEncryptedResponse
      , fixtureOtherFinalBundle = otherFinalBundle
      , fixtureResetProof = resetProof
      , fixtureCancellation = cancellation
      , fixtureSessionId = sessionId
      , fixtureReplacementSessionId = replacementSessionId
      , fixtureAccessorA = accessorA
      , fixtureAccessorB = accessorB
      , fixtureCurrentAccessor = currentAccessor
      , fixtureEmptyInventory = emptyInventory
      , fixtureStaleInventory = staleInventory
      , fixtureCurrentInventory = currentInventory
      , fixtureOtherGenerationInventory = otherGenerationInventory
      , fixtureEmptyAbsence = emptyAbsence
      , fixtureStaleAbsence = staleAbsence
      , fixtureCurrentAbsence = currentAbsence
      , fixtureBaselineReadBack = baselineReadBack
      , fixtureProvisionerLogin = provisionerLogin
      , fixtureHandoffReceipt = handoffReceipt
      , fixtureChildBinding = childBinding
      , fixtureOtherChildBinding = otherChildBinding
      , fixtureOtherCustodyGenerationBinding = otherCustodyGenerationBinding
      , fixtureOtherStorageGenerationBinding = otherStorageGenerationBinding
      , fixtureOtherTransactionBinding = otherTransactionBinding
      , fixtureChildEncryptedReceipt = childEncryptedReceipt
      , fixtureParentAcknowledgement = parentAcknowledgement
      , fixtureChildDelivery = childDelivery
      , fixtureOtherNonceDelivery = otherNonceDelivery
      , fixtureOtherAttestationDelivery = otherAttestationDelivery
      , fixtureOtherPayloadDelivery = otherPayloadDelivery
      , fixtureChildRepairReadBack = childRepairReadBack
      , fixtureDigestA = digestA
      , fixtureDigestB = digestB
      }

bootstrapEither :: (Show err) => Either err value -> Either String value
bootstrapEither = first show

digest :: Char -> Either String ArtifactDigest
digest character =
  bootstrapEither (mkArtifactDigest (Text.replicate 64 (Text.singleton character)))

commandPrefixes
  :: (state -> command -> Either err state)
  -> state
  -> [command]
  -> Either err [state]
commandPrefixes apply initial commands = go [initial] initial commands
 where
  go reversed _ [] = Right (reverse reversed)
  go reversed current (command : remaining) = do
    next <- apply current command
    go (next : reversed) next remaining

expectRight :: (Show err) => Either err value -> (value -> Expectation) -> Expectation
expectRight result assertion =
  case result of
    Left err -> expectationFailure ("expected Right, received " ++ show err)
    Right value -> assertion value

expectLeftWhere
  :: (Show err)
  => Either err value
  -> (err -> Bool)
  -> Expectation
expectLeftWhere result predicate =
  case result of
    Left err -> err `shouldSatisfy` predicate
    Right _ -> expectationFailure "expected typed refusal, received Right"

firstValue :: String -> [value] -> Either String value
firstValue description values =
  case values of
    [] -> Left (description ++ " unexpectedly had no states")
    value : _ -> Right value

-- Root initialization ------------------------------------------------------

rootInitializationSuite :: SuiteBuilder ()
rootInitializationSuite =
  describe "Sprint 2.33 root initialization custody crash matrix" $ do
    it "commits the exact validated init recipient array, count, threshold, and key pins" $
      withFixture $ \fixture -> do
        let prepared = fixturePrepared fixture
            commitment = preparedInitRecipientCommitment prepared
            recoveryFingerprint = initRecipientRecoveryFingerprint commitment
            burnFingerprint = initRecipientBurnFingerprint commitment
            burnDigest = initRecipientBurnPublicKeyDigest commitment
            publicKey = "cmVjb3ZlcnktcHVibGljLWtleQ=="
        initRecipientShareCount commitment `shouldBe` 3
        initRecipientThreshold commitment `shouldBe` 2
        initRecipientRecoveryPublicKeysBase64 commitment
          `shouldBe` replicate 3 publicKey
        preparedInitPristineObservationDigest prepared
          `shouldBe` pristineStorageObservationDigest (fixturePristine fixture)
        Text.length
          (renderArtifactDigest (initRecipientRecoveryPublicKeysDigest commitment))
          `shouldBe` 64
        mkInitRecipientCommitment
          0
          0
          []
          recoveryFingerprint
          burnFingerprint
          burnDigest
          `shouldBe` Left BootstrapInitShareCountMustBePositive
        mkInitRecipientCommitment
          3
          4
          (replicate 3 publicKey)
          recoveryFingerprint
          burnFingerprint
          burnDigest
          `shouldBe` Left (BootstrapInitThresholdExceedsShareCount 4 3)
        mkInitRecipientCommitment
          3
          2
          (replicate 2 publicKey)
          recoveryFingerprint
          burnFingerprint
          burnDigest
          `shouldBe` Left (BootstrapInitRecipientCountMismatch 3 2)
        mkInitRecipientCommitment
          2
          1
          [publicKey, "b3RoZXItcHVibGljLWtleQ=="]
          recoveryFingerprint
          burnFingerprint
          burnDigest
          `shouldBe` Left BootstrapInitRecoveryRecipientsDiffer
        mkInitRecipientCommitment
          1
          1
          ["not canonical base64"]
          recoveryFingerprint
          burnFingerprint
          burnDigest
          `shouldBe` Left (BootstrapInitRecipientPublicKeyInvalid 0)

    it "requires the exact committed ciphertext count and carries count/threshold into final custody" $
      withFixture $ \fixture -> do
        let prepared = fixturePrepared fixture
            receipt = fixtureEncryptedResponse fixture
            shares = encryptedResponseShares receipt
        mkEncryptedInitResponseReceipt
          prepared
          (drop 1 shares)
          (encryptedResponseBurnToken receipt)
          (encryptedResponseReceiptDigest receipt)
          `shouldBe` Left (BootstrapEncryptedShareCountMismatch 3 2)
        finalUnlockBundleShareCount (fixtureFinalBundle fixture) `shouldBe` 3
        finalUnlockBundleThreshold (fixtureFinalBundle fixture) `shouldBe` 2

    it "walks every command prefix with the exact next plan and no invariant violation" $
      withFixture $ \fixture ->
        expectRight (rootInitPrefixes fixture) $ \states -> do
          length states `shouldBe` length (rootInitExpectedPlans fixture)
          forM_
            (zip3 [(0 :: Int) ..] states (rootInitExpectedPlans fixture))
            $ \(_index, state, expectedPlan) -> do
              rootInitInvariantViolations state `shouldBe` []
              planRootInit state `shouldBe` expectedPlan
          rootInitIsComplete (last states) `shouldBe` True

    it "restarts every command prefix from an authoritative durable observation" $
      withFixture $ \fixture ->
        expectRight (rootInitPrefixes fixture) $ \states -> do
          let observations = rootInitRestartObservations fixture
          length observations `shouldBe` length states
          forM_ (zip states observations) $ \(state, observation) ->
            expectRight (restartRootInit state observation) $ \resumed ->
              rootInitInvariantViolations resumed `shouldBe` []

    it "projects every durable observation to its only safe recovery plan" $
      withFixture $ \fixture -> do
        let cases = rootObservationPlanCases fixture
        forM_ cases $ \(_label, observation, expectedPlan) ->
          expectRight (resumeRootInitFromObservation observation) $ \resumed -> do
            rootInitInvariantViolations resumed `shouldBe` []
            planRootInit resumed `shouldBe` expectedPlan

    it "refuses corrupt or cross-generation artifacts at every read-back boundary" $
      withFixture $ \fixture ->
        expectRight (rootInitPrefixes fixture) $ \states -> do
          let prepared = fixturePrepared fixture
              otherPrepared = fixtureOtherPrepared fixture
              otherResponse = fixtureOtherEncryptedResponse fixture
              otherBundle = fixtureOtherFinalBundle fixture
              wrongCustody =
                mkRecoveryCustodyReceipt otherBundle (fixtureDigestA fixture)
              cases =
                [ (1, PrepareRootInitEnvelope otherPrepared)
                , (2, ConfirmPreparedInitReadBack otherPrepared)
                , (5, CaptureEncryptedInitResponse otherResponse)
                , (7, ConfirmEncryptedInitResponseReadBack otherResponse)
                , (8, PrepareFinalUnlockBundle otherBundle)
                , (10, ConfirmFinalUnlockBundleReadBack otherBundle)
                , (15, ConfirmRecoveryCustody wrongCustody)
                ]
          -- Index 1 is already past preparation; exercise the initial binding
          -- refusal separately against the pristine prefix.
          expectRight (firstValue "root-init prefix" states) $ \initial ->
            applyRootInitCommand
              initial
              (PrepareRootInitEnvelope otherPrepared)
              `shouldSatisfy` isLeft
          forM_ (drop 1 cases) $ \(index, command) ->
            applyRootInitCommand (states !! index) command `shouldSatisfy` isLeft
          let corruptObservation =
                RootObservedFinalBundlePreparedPresent
                  prepared
                  otherResponse
                  (fixtureFinalBundle fixture)
          resumeRootInitFromObservation corruptObservation `shouldSatisfy` isLeft

    it "enters explicit applied-without-response ambiguity and permits only an advancing pristine reset" $
      withFixture $ \fixture ->
        expectRight (rootInitPrefixes fixture) $ \states -> do
          let inFlight = states !! 5
          expectRight
            (applyRootInitCommand inFlight MarkRootInitAppliedWithoutDurableResponse)
            $ \ambiguous -> do
              rootInitIsAmbiguous ambiguous `shouldBe` True
              planRootInit ambiguous
                `shouldBe` RootPlanAmbiguityRequiresPristineReset
                  (mkInitAmbiguity (fixturePrepared fixture))
              expectRight
                ( applyRootInitCommand
                    ambiguous
                    (ResetAmbiguousRootInitialization (fixtureResetProof fixture))
                )
                $ \reset ->
                  rootInitStateBinding reset
                    `shouldBe` pristineStorageBinding (fixtureOtherPristine fixture)
              let ambiguityEvidence = mkInitAmbiguity (fixturePrepared fixture)
                  binding = ambiguousInitBinding ambiguityEvidence
                  otherBinding =
                    pristineStorageBinding (fixtureOtherPristine fixture)
                  sameGenerationReplacement =
                    mkPristineStorageProof
                      ( RootInitBinding
                          (rootInitTransactionId otherBinding)
                          (rootInitStorageGeneration binding)
                      )
                      (fixtureDigestB fixture)
                  establishedAbsence =
                    mkEstablishedStateAbsence binding (fixtureDigestA fixture)
                  responseAbsence =
                    mkDurableInitResponseAbsence binding (fixtureDigestA fixture)
                  baselineAbsence =
                    mkBaselineStateAbsence binding (fixtureDigestB fixture)
              mkPristineResetProof
                ambiguityEvidence
                (fixturePristine fixture)
                establishedAbsence
                responseAbsence
                baselineAbsence
                `shouldBe` Left BootstrapResetReplacementMustAdvance
              mkPristineResetProof
                ambiguityEvidence
                sameGenerationReplacement
                establishedAbsence
                responseAbsence
                baselineAbsence
                `shouldBe` Left BootstrapResetReplacementMustAdvance
              mkPristineResetProof
                ambiguityEvidence
                (fixtureOtherPristine fixture)
                (mkEstablishedStateAbsence otherBinding (fixtureDigestA fixture))
                responseAbsence
                baselineAbsence
                `shouldBe` Left (BootstrapResetAbsenceBindingMismatch "established state")

    it "refuses established reset, cross-binding restart, and durable-prefix regression" $
      withFixture $ \fixture ->
        expectRight (rootInitPrefixes fixture) $ \states -> do
          let complete = last states
              reset = ResetAmbiguousRootInitialization (fixtureResetProof fixture)
          applyRootInitCommand complete reset
            `shouldBe` Left RootInitEstablishedGenerationResetRefused
          restartRootInit
            complete
            (RootObservedPristine (fixtureOtherPristine fixture))
            `shouldSatisfy` isLeft
          restartRootInit
            complete
            (RootObservedPristine (fixturePristine fixture))
            `shouldBe` Left (RootInitObservationRegression 5 0)

    it "latches cancellation at every phase and admits only the safety tail" $
      withFixture $ \fixture ->
        expectRight (rootInitPrefixes fixture) $ \states -> do
          let commands = rootInitCommands fixture
              safetyTail =
                [False, False, False, False, False]
                  ++ replicate 11 True
          length commands `shouldBe` length safetyTail
          forM_
            (zip3 [(0 :: Int) ..] states (safetyTail ++ [False]))
            $ \(index, state, nextIsSafetyTail) ->
              expectRight
                ( applyRootInitCommand
                    state
                    (CancelRootInitialization (fixtureCancellation fixture))
                )
                $ \cancelled -> do
                  let remainingCommands = drop index commands
                  case remainingCommands of
                    next : _ ->
                      isRight (applyRootInitCommand cancelled next)
                        `shouldBe` nextIsSafetyTail
                    [] -> rootInitIsComplete cancelled `shouldBe` True
          expectRight (firstValue "root-init prefix" states) $ \initial -> do
            let earlyCancelled =
                  applyRootInitCommand
                    initial
                    (CancelRootInitialization (fixtureCancellation fixture))
            expectRight earlyCancelled $ \cancelled ->
              planRootInit cancelled
                `shouldBe` RootPlanCancellationLatched "RootInitPristine"

    it "keeps an in-flight response on the cancellation safety tail and blocks ambiguous reset" $
      withFixture $ \fixture ->
        expectRight (rootInitPrefixes fixture) $ \states -> do
          let inFlight = states !! 5
          expectRight
            ( applyRootInitCommand
                inFlight
                (CancelRootInitialization (fixtureCancellation fixture))
            )
            $ \cancelled -> do
              planRootInit cancelled
                `shouldBe` RootPlanAwaitVaultInitResponse
                  (preparedInitBinding (fixturePrepared fixture))
              applyRootInitCommand
                cancelled
                (CaptureEncryptedInitResponse (fixtureEncryptedResponse fixture))
                `shouldSatisfy` isRight
          expectRight
            (applyRootInitCommand inFlight MarkRootInitAppliedWithoutDurableResponse)
            $ \ambiguous ->
              expectRight
                ( applyRootInitCommand
                    ambiguous
                    (CancelRootInitialization (fixtureCancellation fixture))
                )
                $ \cancelledAmbiguous -> do
                  planRootInit cancelledAmbiguous
                    `shouldBe` RootPlanCancellationLatched
                      "RootInitializationAmbiguous"
                  applyRootInitCommand
                    cancelledAmbiguous
                    (ResetAmbiguousRootInitialization (fixtureResetProof fixture))
                    `shouldSatisfy` isLeft

rootInitCommands :: Fixture -> [RootInitCommand]
rootInitCommands Fixture {fixturePrepared, fixtureEncryptedResponse, fixtureFinalBundle, fixtureRecoveryCustody} =
  [ PrepareRootInitEnvelope fixturePrepared
  , RecordPreparedInitWrite
  , ConfirmPreparedInitReadBack fixturePrepared
  , ArmRootVaultInitCall
  , RecordRootVaultInitCallStarted
  , CaptureEncryptedInitResponse fixtureEncryptedResponse
  , RecordEncryptedInitResponseWrite
  , ConfirmEncryptedInitResponseReadBack fixtureEncryptedResponse
  , PrepareFinalUnlockBundle fixtureFinalBundle
  , RecordFinalUnlockBundlePromotion
  , ConfirmFinalUnlockBundleReadBack fixtureFinalBundle
  , ArmPreparedInitDeletion
  , RecordPreparedInitDeletion
  , ConfirmPreparedInitAbsence
  , ArmRecoveryCustodyAcknowledgement
  , ConfirmRecoveryCustody fixtureRecoveryCustody
  ]

rootInitPrefixes :: Fixture -> Either RootInitError [RootInitState]
rootInitPrefixes fixture =
  commandPrefixes
    applyRootInitCommand
    (newRootInitState (fixturePristine fixture))
    (rootInitCommands fixture)

rootInitExpectedPlans :: Fixture -> [RootInitPlan]
rootInitExpectedPlans
  Fixture
    { fixturePristine
    , fixturePrepared
    , fixtureEncryptedResponse
    , fixtureFinalBundle
    , fixtureRecoveryCustody
    } =
    [ RootPlanGenerateAndSealPreparedEnvelope fixturePristine
    , RootPlanWritePreparedEnvelope fixturePrepared
    , RootPlanReadBackPreparedEnvelope fixturePrepared
    , RootPlanArmVaultInitCall fixturePrepared
    , RootPlanCallVaultInit fixturePrepared
    , RootPlanAwaitVaultInitResponse (preparedInitBinding fixturePrepared)
    , RootPlanWriteEncryptedResponse fixtureEncryptedResponse
    , RootPlanReadBackEncryptedResponse fixtureEncryptedResponse
    , RootPlanDecryptSharesAndSealFinalBundle fixtureEncryptedResponse
    , RootPlanPromoteFinalBundle fixtureFinalBundle
    , RootPlanReadBackFinalBundle fixtureFinalBundle
    , RootPlanDeletePreparedEnvelope fixturePrepared
    , RootPlanDeletePreparedEnvelope fixturePrepared
    , RootPlanReadBackPreparedAbsence (finalUnlockBundleBinding fixtureFinalBundle)
    , RootPlanAcknowledgeRecoveryCustody fixtureFinalBundle
    , RootPlanAcknowledgeRecoveryCustody fixtureFinalBundle
    , RootPlanComplete fixtureRecoveryCustody
    ]

rootInitRestartObservations :: Fixture -> [RootInitDurableObservation]
rootInitRestartObservations
  Fixture
    { fixturePristine
    , fixturePrepared
    , fixtureEncryptedResponse
    , fixtureFinalBundle
    , fixtureRecoveryCustody
    } =
    [ RootObservedPristine fixturePristine
    , RootObservedPristine fixturePristine
    , RootObservedPreparedVaultUninitialized fixturePrepared
    , RootObservedPreparedVaultUninitialized fixturePrepared
    , RootObservedPreparedVaultUninitialized fixturePrepared
    , RootObservedPreparedVaultUninitialized fixturePrepared
    , RootObservedPreparedVaultInitializedWithoutResponse fixturePrepared
    , RootObservedEncryptedResponse fixturePrepared fixtureEncryptedResponse
    , RootObservedEncryptedResponse fixturePrepared fixtureEncryptedResponse
    , RootObservedEncryptedResponse fixturePrepared fixtureEncryptedResponse
    , RootObservedFinalBundlePreparedPresent
        fixturePrepared
        fixtureEncryptedResponse
        fixtureFinalBundle
    , RootObservedFinalBundlePreparedPresent
        fixturePrepared
        fixtureEncryptedResponse
        fixtureFinalBundle
    , RootObservedFinalBundlePreparedPresent
        fixturePrepared
        fixtureEncryptedResponse
        fixtureFinalBundle
    , RootObservedFinalBundlePreparedPresent
        fixturePrepared
        fixtureEncryptedResponse
        fixtureFinalBundle
    , RootObservedFinalBundlePreparedAbsent fixtureFinalBundle
    , RootObservedFinalBundlePreparedAbsent fixtureFinalBundle
    , RootObservedRecoveryCustody fixtureFinalBundle fixtureRecoveryCustody
    ]

rootObservationPlanCases
  :: Fixture -> [(String, RootInitDurableObservation, RootInitPlan)]
rootObservationPlanCases
  Fixture
    { fixturePristine
    , fixturePrepared
    , fixtureEncryptedResponse
    , fixtureFinalBundle
    , fixtureRecoveryCustody
    } =
    [
      ( "pristine"
      , RootObservedPristine fixturePristine
      , RootPlanGenerateAndSealPreparedEnvelope fixturePristine
      )
    ,
      ( "prepared and uninitialized"
      , RootObservedPreparedVaultUninitialized fixturePrepared
      , RootPlanArmVaultInitCall fixturePrepared
      )
    ,
      ( "initialized without response"
      , RootObservedPreparedVaultInitializedWithoutResponse fixturePrepared
      , RootPlanAmbiguityRequiresPristineReset (mkInitAmbiguity fixturePrepared)
      )
    ,
      ( "encrypted response"
      , RootObservedEncryptedResponse fixturePrepared fixtureEncryptedResponse
      , RootPlanDecryptSharesAndSealFinalBundle fixtureEncryptedResponse
      )
    ,
      ( "final bundle with prepared envelope"
      , RootObservedFinalBundlePreparedPresent
          fixturePrepared
          fixtureEncryptedResponse
          fixtureFinalBundle
      , RootPlanDeletePreparedEnvelope fixturePrepared
      )
    ,
      ( "final bundle with prepared envelope absent"
      , RootObservedFinalBundlePreparedAbsent fixtureFinalBundle
      , RootPlanAcknowledgeRecoveryCustody fixtureFinalBundle
      )
    ,
      ( "recovery custody durable"
      , RootObservedRecoveryCustody fixtureFinalBundle fixtureRecoveryCustody
      , RootPlanComplete fixtureRecoveryCustody
      )
    ]

-- Short-lived root baseline session ---------------------------------------

rootSessionSuite :: SuiteBuilder ()
rootSessionSuite =
  describe "Sprint 2.33 short-lived root session crash matrix" $ do
    it "runs orphan cleanup, non-empty stale revocation, baseline read-back, revoke, and absence" $
      withFixture $ \fixture ->
        expectRight (rootSessionPrefixes fixture) $ \states -> do
          length states `shouldBe` length (rootSessionExpectedPlans fixture)
          forM_
            (zip states (rootSessionExpectedPlans fixture))
            $ \(state, expectedPlan) -> do
              rootSessionInvariantViolations state `shouldBe` []
              planRootSession state `shouldBe` expectedPlan
          rootSessionIsComplete (last states) `shouldBe` True

    it "revokes stale accessors in canonical order and refuses inventory or absence mismatch" $
      withFixture $ \fixture ->
        expectRight (rootSessionPrefixes fixture) $ \states -> do
          applyRootSessionCommand
            (states !! 1)
            (ConfirmRootAccessorInventory (fixtureOtherGenerationInventory fixture))
            `shouldSatisfy` isLeft
          applyRootSessionCommand
            (states !! 2)
            (ConfirmStaleRootAccessorRevoked (fixtureAccessorB fixture))
            `shouldBe` Left RootSessionStaleAccessorOrderMismatch
          applyRootSessionCommand
            (states !! 4)
            (ConfirmStableRootAccessorAbsence (fixtureEmptyAbsence fixture))
            `shouldBe` Left RootSessionStableAbsenceMismatch
          applyRootSessionCommand
            (states !! 7)
            (ConfirmGeneratedRootAccessorJournaled (fixtureAccessorA fixture))
            `shouldBe` Left RootSessionAccessorJournalMismatch

    it "requires exact session, generation, target set, and current-accessor absence" $
      withFixture $ \fixture ->
        expectRight (rootSessionPrefixes fixture) $ \states -> do
          let baseline = fixtureBaselineReadBack fixture
              generation = baselineReadBackStorageGeneration baseline
              otherGeneration =
                rootAccessorInventoryGeneration
                  (fixtureOtherGenerationInventory fixture)
              digestValue = baselineReadBackDigest baseline
          requiredRootBaselineTargets
            `shouldSatisfy` (elem BaselineTokenAccessorAuditorPolicy)
          requiredRootBaselineTargets
            `shouldSatisfy` (elem BaselineTokenAccessorAuditorRole)
          mkBaselineReadBackReceipt
            (baselineReadBackSessionId baseline)
            generation
            (drop 1 requiredRootBaselineTargets)
            digestValue
            `shouldSatisfy` isLeft
          expectRight
            ( mkBaselineReadBackReceipt
                (fixtureReplacementSessionId fixture)
                generation
                requiredRootBaselineTargets
                digestValue
            )
            $ \wrongSession ->
              expectRight
                ( mkBaselineReadBackReceipt
                    (baselineReadBackSessionId baseline)
                    otherGeneration
                    requiredRootBaselineTargets
                    digestValue
                )
                $ \wrongGeneration -> do
                  forM_ [wrongSession, wrongGeneration] $ \receipt ->
                    applyRootSessionCommand
                      (states !! 10)
                      (ConfirmAllowlistedBaselineReadBack receipt)
                      `shouldBe` Left RootSessionBaselineReadBackMismatch
                  applyRootSessionCommand
                    (states !! 14)
                    (ConfirmCurrentRootAccessorAbsent (fixtureStaleAbsence fixture))
                    `shouldBe` Left RootSessionCurrentAccessorAbsenceMismatch

    it "restarts every unfinished prefix with a new identity through orphan cleanup" $
      withFixture $ \fixture ->
        expectRight (rootSessionPrefixes fixture) $ \states -> do
          forM_ (init states) $ \state ->
            expectRight
              (restartRootSession (fixtureReplacementSessionId fixture) state)
              $ \restarted -> do
                rootSessionBindingId (rootSessionStateBinding restarted)
                  `shouldBe` fixtureReplacementSessionId fixture
                rootSessionStatePhase restarted
                  `shouldBe` RootSessionCancelIncompleteGenerateRoot
                rootSessionInvariantViolations restarted `shouldBe` []
          restartRootSession (fixtureSessionId fixture) (states !! 6)
            `shouldBe` Left RootSessionRestartMustAdvanceSessionId
          restartRootSession
            (fixtureReplacementSessionId fixture)
            (last states)
            `shouldBe` Right (last states)

    it "cancels before generation cleanly and cancels an in-flight generation through inventory" $
      withFixture $ \fixture ->
        expectRight (rootSessionPrefixes fixture) $ \states -> do
          expectRight (cancelRootSession fixture (states !! 5)) $ \cancelled -> do
            planRootSession cancelled
              `shouldBe` RootSessionPlanFinishCancellation
                (fixtureStaleAbsence fixture)
            expectRight
              (applyRootSessionCommand cancelled FinishRootSessionCancellation)
              $ \finished -> do
                rootSessionIsCancelledClean finished `shouldBe` True
                rootSessionIsComplete finished `shouldBe` False
          expectRight (cancelRootSession fixture (states !! 6)) $ \cancelled -> do
            planRootSession cancelled
              `shouldBe` RootSessionPlanCancelIncompleteGenerateRoot
                (rootSessionStateBinding cancelled)
            expectRight
              ( applyRootSessionCommand
                  cancelled
                  ConfirmIncompleteGenerateRootCancelled
              )
              $ \cleaning ->
                rootSessionStatePhase cleaning
                  `shouldBe` RootSessionInventoryStaleAccessors

    it "journals a returned accessor under cancellation, then revokes and proves it absent" $
      withFixture $ \fixture ->
        expectRight (rootSessionPrefixes fixture) $ \states -> do
          expectRight (cancelRootSession fixture (states !! 7)) $ \cancelled -> do
            planRootSession cancelled
              `shouldBe` RootSessionPlanJournalGeneratedAccessor
                (rootSessionStateBinding cancelled)
                (fixtureCurrentAccessor fixture)
            expectRight
              ( applyRootSessionCommand
                  cancelled
                  ( ConfirmGeneratedRootAccessorJournaled
                      (fixtureCurrentAccessor fixture)
                  )
              )
              $ \journaled ->
                expectRight
                  (applyRootSessionCommand journaled ArmCurrentRootSessionRevocation)
                  $ \armed ->
                    expectRight
                      (applyRootSessionCommand armed ConfirmCurrentRootSessionRevoked)
                      $ \revoked ->
                        expectRight
                          ( applyRootSessionCommand
                              revoked
                              ArmCurrentRootAccessorAbsenceCheck
                          )
                          $ \absencePending ->
                            expectRight
                              ( applyRootSessionCommand
                                  absencePending
                                  ( ConfirmCurrentRootAccessorAbsent
                                      (fixtureCurrentAbsence fixture)
                                  )
                              )
                              $ \finished -> do
                                rootSessionIsCancelledClean finished `shouldBe` True
                                rootSessionInvariantViolations finished `shouldBe` []

    it "preserves cancellation across restart and completes a read-back baseline safety tail" $
      withFixture $ \fixture ->
        expectRight (rootSessionPrefixes fixture) $ \states -> do
          expectRight (cancelRootSession fixture (states !! 6)) $ \cancelled ->
            expectRight
              ( restartRootSession
                  (fixtureReplacementSessionId fixture)
                  cancelled
              )
              $ \restarted -> do
                rootSessionStateDisposition restarted
                  `shouldBe` rootSessionStateDisposition cancelled
                planRootSession restarted
                  `shouldBe` RootSessionPlanCancelIncompleteGenerateRoot
                    (rootSessionStateBinding restarted)
          expectRight (cancelRootSession fixture (states !! 11)) $ \cancelled ->
            expectRight
              (applyRootSessionCommand cancelled ArmCurrentRootSessionRevocation)
              $ \armed ->
                expectRight
                  (applyRootSessionCommand armed ConfirmCurrentRootSessionRevoked)
                  $ \revoked ->
                    expectRight
                      (applyRootSessionCommand revoked ArmCurrentRootAccessorAbsenceCheck)
                      $ \absencePending ->
                        expectRight
                          ( applyRootSessionCommand
                              absencePending
                              ( ConfirmCurrentRootAccessorAbsent
                                  (fixtureCurrentAbsence fixture)
                              )
                          )
                          $ \complete -> rootSessionIsComplete complete `shouldBe` True

rootSessionCommands :: Fixture -> [RootSessionCommand]
rootSessionCommands
  Fixture
    { fixtureStaleInventory
    , fixtureAccessorA
    , fixtureAccessorB
    , fixtureStaleAbsence
    , fixtureCurrentAccessor
    , fixtureBaselineReadBack
    , fixtureCurrentAbsence
    } =
    [ ConfirmIncompleteGenerateRootCancelled
    , ConfirmRootAccessorInventory fixtureStaleInventory
    , ConfirmStaleRootAccessorRevoked fixtureAccessorA
    , ConfirmStaleRootAccessorRevoked fixtureAccessorB
    , ConfirmStableRootAccessorAbsence fixtureStaleAbsence
    , RecordShortLivedRootGenerationStarted
    , CaptureGeneratedRootAccessor fixtureCurrentAccessor
    , ConfirmGeneratedRootAccessorJournaled fixtureCurrentAccessor
    , ArmAllowlistedBaselineMutation
    , RecordAllowlistedBaselineApplied
    , ConfirmAllowlistedBaselineReadBack fixtureBaselineReadBack
    , ArmCurrentRootSessionRevocation
    , ConfirmCurrentRootSessionRevoked
    , ArmCurrentRootAccessorAbsenceCheck
    , ConfirmCurrentRootAccessorAbsent fixtureCurrentAbsence
    ]

rootSessionPrefixes :: Fixture -> Either RootSessionError [RootSessionState]
rootSessionPrefixes fixture =
  commandPrefixes
    applyRootSessionCommand
    ( newRootSessionState
        (fixtureSessionId fixture)
        (fixtureRecoveryCustody fixture)
    )
    (rootSessionCommands fixture)

rootSessionExpectedPlans :: Fixture -> [RootSessionPlan]
rootSessionExpectedPlans
  Fixture
    { fixtureRecoveryCustody
    , fixtureSessionId
    , fixtureReplacementSessionId = _
    , fixtureStaleInventory
    , fixtureAccessorA
    , fixtureAccessorB
    , fixtureStaleAbsence = _
    , fixtureCurrentAccessor
    , fixtureBaselineReadBack
    , fixtureCurrentAbsence
    } =
    let binding = mkRootSessionBinding fixtureSessionId fixtureRecoveryCustody
        completion =
          RootSessionCompletion
            { completedRootSessionBinding = binding
            , completedRootBaselineReadBack = fixtureBaselineReadBack
            , completedRootAccessorAbsence = fixtureCurrentAbsence
            }
     in [ RootSessionPlanCancelIncompleteGenerateRoot binding
        , RootSessionPlanInventoryStaleAccessors
            (rootSessionStorageGeneration binding)
        , RootSessionPlanRevokeStaleAccessor fixtureAccessorA
        , RootSessionPlanRevokeStaleAccessor fixtureAccessorB
        , RootSessionPlanProveStableAccessorAbsence fixtureStaleInventory
        , RootSessionPlanGenerateShortLivedRoot binding
        , RootSessionPlanAwaitGeneratedRootAccessor binding
        , RootSessionPlanJournalGeneratedAccessor binding fixtureCurrentAccessor
        , RootSessionPlanArmAllowlistedBaseline fixtureCurrentAccessor
        , RootSessionPlanApplyAllowlistedBaseline fixtureCurrentAccessor
        , RootSessionPlanReadBackAllowlistedBaseline fixtureCurrentAccessor
        , RootSessionPlanArmCurrentRevocation fixtureCurrentAccessor
        , RootSessionPlanRevokeCurrentAccessor fixtureCurrentAccessor
        , RootSessionPlanArmCurrentAccessorAbsenceCheck fixtureCurrentAccessor
        , RootSessionPlanProveCurrentAccessorAbsent fixtureCurrentAccessor
        , RootSessionPlanComplete completion
        ]

cancelRootSession
  :: Fixture -> RootSessionState -> Either RootSessionError RootSessionState
cancelRootSession fixture state =
  applyRootSessionCommand state (CancelRootSession (fixtureCancellation fixture))

-- Scoped generated-root PGP boundaries -------------------------------------

generatedRootBoundarySuite :: SuiteBuilder ()
generatedRootBoundarySuite =
  describe "Sprint 2.33 scoped generated-root primitive boundaries" $ do
    it "exports no generated-token, raw-runner, or plaintext-session eliminator" $ do
      moduleSource <-
        readFile "src/Prodbox/Bootstrap/Broker/PgpBoundary.hs"
      let publicSurface =
            unlines (takeWhile (/= "where") (lines moduleSource))
      forM_
        [ "GeneratedRootSessionToken"
        , "GeneratedChildRecoverySessionToken"
        , "GeneratedRootActionBoundary"
        , "GeneratedChildRecoveryActionBoundary"
        , "withGeneratedRootSession"
        , "withGeneratedChildRecoverySession"
        , "withDecryptedGeneratedRootSession"
        , "withDecryptedGeneratedChildRecoverySession"
        , "runGeneratedRootAction"
        , "runGeneratedChildRecoveryAction"
        , "primitiveWithGeneratedRootRecipient"
        , "primitiveWithGeneratedChildRecoveryRecipient"
        ]
        (publicSurface `shouldNotContain`)

    it "owns the exact closed root action order and refuses a post-revoke action" $
      withFixture $ \fixture -> do
        let binding = fixtureRootSessionBinding fixture
            fence = canonicalGeneratedRootFence fixture
            originatingPermit = generatedPermit fence BootstrapVaultSubmitGenerateRootShare
            ciphertext =
              mustBoundaryRight
                (Pgp.mkGeneratedRootCiphertext rootGeneratedCiphertextBytes)
            workflow = rootWorkflow fixture fence Nothing
        actions <- newIORef []
        postRevoke <- newIORef Nothing
        closed <- newIORef []
        result <-
          Pgp.withGeneratedRootRecipientFromPrimitive
            ( rootPrimitiveBoundaryRecording
                fixture
                (\new -> modifyIORef' actions (++ new))
                (writeIORef postRevoke . Just)
                (\new -> modifyIORef' closed (++ new))
            )
            $ \publicKey runWorkflow -> do
              Pgp.generatedRootPublicKeyBase64 publicKey
                `shouldBe` generatedPublicKeyBase64
              runWorkflow binding originatingPermit ciphertext workflow
                >>= (`shouldBe` Right (Right rootWorkflowCheckpoints))
        result `shouldBe` Right ()
        readIORef actions `shouldReturn` Pgp.allGeneratedRootActionKinds
        readIORef postRevoke
          `shouldReturn` Just (Left Pgp.PgpGeneratedRootSessionClosed)
        readIORef closed `shouldReturn` [True]

    it "rejects every changed root action fence field before the primitive action" $
      withFixture $ \fixture -> do
        let binding = fixtureRootSessionBinding fixture
            fence = canonicalGeneratedRootFence fixture
            originatingPermit = generatedPermit fence BootstrapVaultSubmitGenerateRootShare
            ciphertext =
              mustBoundaryRight
                (Pgp.mkGeneratedRootCiphertext rootGeneratedCiphertextBytes)
        forM_ (rootFenceMismatchCases fixture) $ \(permit, expectedRefusal) -> do
          actions <- newIORef []
          let workflow =
                (rootWorkflow fixture fence Nothing)
                  { Pgp.rootWorkflowAuthorize = \effect ->
                      pure
                        ( Right
                            ( if effect == BootstrapVaultObserveGeneratedRootAccessor
                                then permit
                                else generatedPermit fence effect
                            )
                        )
                  }
          mismatch <-
            Pgp.withGeneratedRootRecipientFromPrimitive
              ( rootPrimitiveBoundaryRecording
                  fixture
                  (\new -> modifyIORef' actions (++ new))
                  (const (pure ()))
                  (const (pure ()))
              )
              ( \_ runWorkflow ->
                  runWorkflow binding originatingPermit ciphertext workflow
              )
          (mismatch >>= id) `shouldBe` Left expectedRefusal
          readIORef actions `shouldReturn` []

    it "unwinds every post-action hook failure and a fresh run restarts at Observe" $
      withFixture $ \fixture ->
        forM_ rootHookFailureCases $ \(failedHook, expectedPrefix) -> do
          let binding = fixtureRootSessionBinding fixture
              fence = canonicalGeneratedRootFence fixture
              originatingPermit =
                generatedPermit fence BootstrapVaultSubmitGenerateRootShare
              ciphertext =
                mustBoundaryRight
                  (Pgp.mkGeneratedRootCiphertext rootGeneratedCiphertextBytes)
          actions <- newIORef []
          closed <- newIORef []
          let primitive =
                rootPrimitiveBoundaryRecording
                  fixture
                  (\new -> modifyIORef' actions (++ new))
                  (const (pure ()))
                  (\new -> modifyIORef' closed (++ new))
              run workflow = do
                outcome <-
                  Pgp.withGeneratedRootRecipientFromPrimitive primitive $ \_ runWorkflow ->
                    runWorkflow binding originatingPermit ciphertext workflow
                pure (outcome >>= id)
          run (rootWorkflow fixture fence (Just failedHook))
            >>= (`shouldBe` Right (Left failedHook))
          readIORef actions `shouldReturn` expectedPrefix
          readIORef closed `shouldReturn` [True]

          writeIORef actions []
          run (rootWorkflow fixture fence Nothing)
            >>= (`shouldBe` Right (Right rootWorkflowCheckpoints))
          readIORef actions `shouldReturn` Pgp.allGeneratedRootActionKinds
          readIORef closed `shouldReturn` [True, True]

    it "owns the exact closed child-recovery action order and refuses post-revoke use" $
      withFixture $ \fixture -> do
        let delivery = fixtureChildDelivery fixture
            fence = canonicalGeneratedRootFence fixture
            originatingPermit = generatedPermit fence BootstrapVaultSubmitGenerateRootShare
            ciphertext =
              mustBoundaryRight
                ( Pgp.mkGeneratedChildRecoveryCiphertext
                    childGeneratedCiphertextBytes
                )
            workflow = childRecoveryWorkflow fixture fence
        actions <- newIORef []
        postRevoke <- newIORef Nothing
        result <-
          Pgp.withGeneratedChildRecoveryRecipientFromPrimitive
            ( childPrimitiveBoundaryRecording
                fixture
                (\new -> modifyIORef' actions (++ new))
                (writeIORef postRevoke . Just)
            )
            $ \publicKey runWorkflow -> do
              Pgp.generatedChildRecoveryPublicKeyBase64 publicKey
                `shouldBe` generatedPublicKeyBase64
              runWorkflow delivery originatingPermit ciphertext workflow
                >>= (`shouldBe` Right (Right childWorkflowCheckpoints))
        result `shouldBe` Right ()
        readIORef actions
          `shouldReturn` Pgp.allGeneratedChildRecoveryActionKinds
        readIORef postRevoke
          `shouldReturn` Just (Left Pgp.PgpGeneratedChildRecoverySessionClosed)

    it "unwinds every child post-action hook failure and restarts at Observe" $
      withFixture $ \fixture ->
        forM_ childHookFailureCases $ \(failedHook, expectedPrefix) -> do
          let delivery = fixtureChildDelivery fixture
              fence = canonicalGeneratedRootFence fixture
              originatingPermit =
                generatedPermit fence BootstrapVaultSubmitGenerateRootShare
              ciphertext =
                mustBoundaryRight
                  ( Pgp.mkGeneratedChildRecoveryCiphertext
                      childGeneratedCiphertextBytes
                  )
          actions <- newIORef []
          let primitive =
                childPrimitiveBoundaryRecording
                  fixture
                  (\new -> modifyIORef' actions (++ new))
                  (const (pure ()))
              run workflow = do
                outcome <-
                  Pgp.withGeneratedChildRecoveryRecipientFromPrimitive primitive $ \_ runWorkflow ->
                    runWorkflow delivery originatingPermit ciphertext workflow
                pure (outcome >>= id)
          run (childRecoveryWorkflowWithFailure fixture fence (Just failedHook))
            >>= (`shouldBe` Right (Left failedHook))
          readIORef actions `shouldReturn` expectedPrefix

          writeIORef actions []
          run (childRecoveryWorkflow fixture fence)
            >>= (`shouldBe` Right (Right childWorkflowCheckpoints))
          readIORef actions
            `shouldReturn` Pgp.allGeneratedChildRecoveryActionKinds

    it "passes the exact SecretPayload bytes only to the custody primitive" $
      withFixture $ \fixture -> do
        let boundary =
              Pgp.mkPgpBoundary
                exactSecretCustodyPrimitive
                (rootPrimitiveBoundary fixture)
                (childPrimitiveBoundary fixture)
            exactSecret =
              mustBoundaryRight
                (mkSecretPayload 64 exactPrimitivePasswordBytes)
            wrongSecret =
              mustBoundaryRight
                (mkSecretPayload 64 "wrong-password")
        exact <-
          Pgp.sealFinalUnlockPayload
            boundary
            exactSecret
            (fixtureFinalPayload fixture)
        case exact of
          Left refusal -> expectationFailure (show refusal)
          Right (ciphertext, _) -> do
            show ciphertext `shouldContain` "<redacted:"
            show ciphertext `shouldNotContain` "sealed-final-bundle"
        Pgp.sealFinalUnlockPayload
          boundary
          wrongSecret
          (fixtureFinalPayload fixture)
          >>= (`shouldBe` Left Pgp.PgpPasswordAeadFailed)

generatedPublicKeyBase64 :: Text.Text
generatedPublicKeyBase64 = "cHVibGljLWtleQ=="

rootGeneratedCiphertextBytes :: ByteString.ByteString
rootGeneratedCiphertextBytes = "root-generated-ciphertext"

childGeneratedCiphertextBytes :: ByteString.ByteString
childGeneratedCiphertextBytes = "child-generated-ciphertext"

exactPrimitivePasswordBytes :: ByteString.ByteString
exactPrimitivePasswordBytes = "exact-worker-password"

rootWorkflowCheckpoints :: [Text.Text]
rootWorkflowCheckpoints =
  [ "after-accessor"
  , "after-apply"
  , "after-read-back"
  , "after-revoke"
  ]

rootHookFailureCases
  :: [(Text.Text, [Pgp.GeneratedRootActionKind])]
rootHookFailureCases =
  [ ("after-accessor", take 1 Pgp.allGeneratedRootActionKinds)
  , ("after-apply", take 2 Pgp.allGeneratedRootActionKinds)
  , ("after-read-back", take 3 Pgp.allGeneratedRootActionKinds)
  , ("after-revoke", Pgp.allGeneratedRootActionKinds)
  ]

rootWorkflow
  :: Fixture
  -> BootstrapSessionFence
  -> Maybe Text.Text
  -> Pgp.GeneratedRootWorkflow IO Text.Text [Text.Text] [Text.Text]
rootWorkflow fixture fence failedHook =
  Pgp.GeneratedRootWorkflow
    { Pgp.rootWorkflowInitialState = []
    , Pgp.rootWorkflowAuthorize =
        \effect -> pure (Right (generatedPermit fence effect))
    , Pgp.rootWorkflowAfterAccessor = \state accessor ->
        if accessor == fixtureCurrentAccessor fixture
          then workflowCheckpoint failedHook "after-accessor" state
          else pure (Left "unexpected-root-accessor")
    , Pgp.rootWorkflowAfterApply =
        workflowCheckpoint failedHook "after-apply"
    , Pgp.rootWorkflowAfterReadBack = \state receipt ->
        if receipt == fixtureBaselineReadBack fixture
          then workflowCheckpoint failedHook "after-read-back" state
          else pure (Left "unexpected-root-read-back")
    , Pgp.rootWorkflowAfterRevoke =
        workflowCheckpoint failedHook "after-revoke"
    }

childWorkflowCheckpoints :: [Text.Text]
childWorkflowCheckpoints = rootWorkflowCheckpoints

childHookFailureCases
  :: [(Text.Text, [Pgp.GeneratedChildRecoveryActionKind])]
childHookFailureCases =
  [ ("after-accessor", take 1 Pgp.allGeneratedChildRecoveryActionKinds)
  , ("after-apply", take 2 Pgp.allGeneratedChildRecoveryActionKinds)
  , ("after-read-back", take 3 Pgp.allGeneratedChildRecoveryActionKinds)
  , ("after-revoke", Pgp.allGeneratedChildRecoveryActionKinds)
  ]

childRecoveryWorkflow
  :: Fixture
  -> BootstrapSessionFence
  -> Pgp.GeneratedChildRecoveryWorkflow
       IO
       Text.Text
       [Text.Text]
       [Text.Text]
childRecoveryWorkflow fixture fence =
  childRecoveryWorkflowWithFailure fixture fence Nothing

childRecoveryWorkflowWithFailure
  :: Fixture
  -> BootstrapSessionFence
  -> Maybe Text.Text
  -> Pgp.GeneratedChildRecoveryWorkflow
       IO
       Text.Text
       [Text.Text]
       [Text.Text]
childRecoveryWorkflowWithFailure fixture fence failedHook =
  Pgp.GeneratedChildRecoveryWorkflow
    { Pgp.childWorkflowInitialState = []
    , Pgp.childWorkflowAuthorize =
        \effect -> pure (Right (generatedPermit fence effect))
    , Pgp.childWorkflowAfterAccessor = \state accessor ->
        if accessor == fixtureCurrentAccessor fixture
          then workflowCheckpoint failedHook "after-accessor" state
          else pure (Left "unexpected-child-accessor")
    , Pgp.childWorkflowAfterApply =
        workflowCheckpoint failedHook "after-apply"
    , Pgp.childWorkflowAfterReadBack = \state receipt ->
        if receipt == fixtureChildRepairReadBack fixture
          then workflowCheckpoint failedHook "after-read-back" state
          else pure (Left "unexpected-child-read-back")
    , Pgp.childWorkflowAfterRevoke =
        workflowCheckpoint failedHook "after-revoke"
    }

workflowCheckpoint
  :: Maybe Text.Text
  -> Text.Text
  -> [Text.Text]
  -> IO (Either Text.Text [Text.Text])
workflowCheckpoint failedHook checkpoint state =
  pure
    ( if failedHook == Just checkpoint
        then Left checkpoint
        else Right (state ++ [checkpoint])
    )

rootPrimitiveBoundary :: Fixture -> Pgp.GeneratedRootPrimitiveBoundary IO
rootPrimitiveBoundary fixture =
  rootPrimitiveBoundaryRecording
    fixture
    (const (pure ()))
    (const (pure ()))
    (const (pure ()))

rootPrimitiveBoundaryRecording
  :: Fixture
  -> ([Pgp.GeneratedRootActionKind] -> IO ())
  -> (Either Pgp.PgpBoundaryError () -> IO ())
  -> ([Bool] -> IO ())
  -> Pgp.GeneratedRootPrimitiveBoundary IO
rootPrimitiveBoundaryRecording fixture recordActions recordPostRevoke recordClosed =
  Pgp.mkGeneratedRootPrimitiveBoundary $ \consume ->
    consume generatedPublicKeyBase64 $ \ciphertextBytes continue ->
      if ciphertextBytes /= rootGeneratedCiphertextBytes
        then pure (Left Pgp.PgpGeneratedRootCiphertextRejected)
        else do
          alive <- newIORef True
          let runRaw
                :: forall actionResult
                 . Pgp.GeneratedRootAction actionResult
                -> IO (Either Pgp.PgpBoundaryError actionResult)
              runRaw action = do
                sessionAlive <- readIORef alive
                if not sessionAlive
                  then pure (Left Pgp.PgpGeneratedRootSessionClosed)
                  else do
                    recordActions [Pgp.generatedRootActionKind action]
                    outcome <- interpretGeneratedRootAction fixture action
                    case (action, outcome) of
                      (Pgp.GeneratedRootRevokeAccessor {}, Right ()) -> do
                        writeIORef alive False
                        runRaw action >>= recordPostRevoke
                        pure (Right ())
                      _ -> pure outcome
          outcome <- continue runRaw
          writeIORef alive False
          readIORef alive >>= recordClosed . pure . not
          pure outcome

childPrimitiveBoundary
  :: Fixture -> Pgp.GeneratedChildRecoveryPrimitiveBoundary IO
childPrimitiveBoundary fixture =
  childPrimitiveBoundaryRecording
    fixture
    (const (pure ()))
    (const (pure ()))

childPrimitiveBoundaryRecording
  :: Fixture
  -> ([Pgp.GeneratedChildRecoveryActionKind] -> IO ())
  -> (Either Pgp.PgpBoundaryError () -> IO ())
  -> Pgp.GeneratedChildRecoveryPrimitiveBoundary IO
childPrimitiveBoundaryRecording fixture recordActions recordPostRevoke =
  Pgp.mkGeneratedChildRecoveryPrimitiveBoundary $ \consume ->
    consume generatedPublicKeyBase64 $ \ciphertextBytes continue ->
      if ciphertextBytes /= childGeneratedCiphertextBytes
        then pure (Left Pgp.PgpGeneratedChildRecoveryCiphertextRejected)
        else do
          alive <- newIORef True
          let runRaw
                :: forall actionResult
                 . Pgp.GeneratedChildRecoveryAction actionResult
                -> IO (Either Pgp.PgpBoundaryError actionResult)
              runRaw action = do
                sessionAlive <- readIORef alive
                if not sessionAlive
                  then pure (Left Pgp.PgpGeneratedChildRecoverySessionClosed)
                  else do
                    recordActions [Pgp.generatedChildRecoveryActionKind action]
                    outcome <- interpretGeneratedChildRecoveryAction fixture action
                    case (action, outcome) of
                      (Pgp.GeneratedChildRecoveryRevokeAccessor {}, Right ()) -> do
                        writeIORef alive False
                        runRaw action >>= recordPostRevoke
                        pure (Right ())
                      _ -> pure outcome
          outcome <- continue runRaw
          writeIORef alive False
          pure outcome

interpretGeneratedRootAction
  :: Fixture
  -> Pgp.GeneratedRootAction result
  -> IO (Either Pgp.PgpBoundaryError result)
interpretGeneratedRootAction fixture action =
  pure $ case action of
    Pgp.GeneratedRootObserveAccessor {} ->
      Right (fixtureCurrentAccessor fixture)
    Pgp.GeneratedRootApplyAllowlistedBaseline {} -> Right ()
    Pgp.GeneratedRootReadBackAllowlistedBaseline {} ->
      Right (fixtureBaselineReadBack fixture)
    Pgp.GeneratedRootRevokeAccessor {} -> Right ()

interpretGeneratedChildRecoveryAction
  :: Fixture
  -> Pgp.GeneratedChildRecoveryAction result
  -> IO (Either Pgp.PgpBoundaryError result)
interpretGeneratedChildRecoveryAction fixture action =
  pure $ case action of
    Pgp.GeneratedChildRecoveryObserveAccessor {} ->
      Right (fixtureCurrentAccessor fixture)
    Pgp.GeneratedChildRecoveryApplyAllowlistedRepair {} -> Right ()
    Pgp.GeneratedChildRecoveryReadBackAllowlistedRepair {} ->
      Right (fixtureChildRepairReadBack fixture)
    Pgp.GeneratedChildRecoveryRevokeAccessor {} -> Right ()

exactSecretCustodyPrimitive :: Pgp.PgpCustodyPrimitiveBoundary IO
exactSecretCustodyPrimitive =
  Pgp.PgpCustodyPrimitiveBoundary
    { Pgp.primitiveVerifyCompiledBurnRecipient =
        \_ -> pure (Left Pgp.PgpCompiledBurnRecipientMismatch)
    , Pgp.primitivePrepareRecoveryRecipient =
        \_ _ _ _ _ _ _ -> pure (Left Pgp.PgpRecipientGenerationFailed)
    , Pgp.primitiveResumePreparedInitRecipients =
        \_ _ _ -> pure (Left Pgp.PgpRecipientGenerationFailed)
    , Pgp.primitiveDecryptRecoveryShares =
        \_ _ _ -> pure (Left Pgp.PgpEncryptedShareRejected)
    , Pgp.primitiveSealFinalUnlockPayload = \secretBytes _ ->
        pure
          ( if secretBytes == exactPrimitivePasswordBytes
              then Right "sealed-final-bundle"
              else Left Pgp.PgpPasswordAeadFailed
          )
    }

fixtureRootSessionBinding :: Fixture -> RootSessionBinding
fixtureRootSessionBinding fixture =
  mkRootSessionBinding
    (fixtureSessionId fixture)
    (fixtureRecoveryCustody fixture)

rootFenceMismatchCases
  :: Fixture -> [(BootstrapVaultEffectPermit, Pgp.PgpBoundaryError)]
rootFenceMismatchCases fixture =
  [ mismatch
      (testFence fixture 2 testOwnerA (fixtureDigestA fixture) testRequestA canonicalStorage 1000)
      Pgp.PgpGeneratedRootActionFenceIdentityMismatch
  , mismatch
      (testFence fixture 1 testOwnerB (fixtureDigestA fixture) testRequestA canonicalStorage 1000)
      Pgp.PgpGeneratedRootActionFenceIdentityMismatch
  , mismatch
      (testFence fixture 1 testOwnerA (fixtureDigestB fixture) testRequestA canonicalStorage 1000)
      Pgp.PgpGeneratedRootActionFenceIdentityMismatch
  , mismatch
      (testFence fixture 1 testOwnerA (fixtureDigestA fixture) testRequestB canonicalStorage 1000)
      Pgp.PgpGeneratedRootActionFenceIdentityMismatch
  , mismatch
      (testFence fixture 1 testOwnerA (fixtureDigestA fixture) testRequestA alternateStorage 1000)
      Pgp.PgpGeneratedRootActionGenerationMismatch
  , mismatch
      (testFence fixture 1 testOwnerA (fixtureDigestA fixture) testRequestA canonicalStorage 1100)
      Pgp.PgpGeneratedRootActionFenceIdentityMismatch
  ]
 where
  canonicalStorage =
    rootSessionStorageGeneration (fixtureRootSessionBinding fixture)
  alternateStorage =
    childCustodyStorageGeneration (fixtureOtherStorageGenerationBinding fixture)
  mismatch fence refusal =
    ( generatedPermit fence BootstrapVaultObserveGeneratedRootAccessor
    , refusal
    )

canonicalGeneratedRootFence :: Fixture -> BootstrapSessionFence
canonicalGeneratedRootFence fixture =
  testFence
    fixture
    1
    testOwnerA
    (fixtureDigestA fixture)
    testRequestA
    (rootSessionStorageGeneration (fixtureRootSessionBinding fixture))
    1000

testFence
  :: Fixture
  -> Natural
  -> OwnerNonce
  -> ArtifactDigest
  -> RequestDigest
  -> VaultStorageGeneration
  -> Natural
  -> BootstrapSessionFence
testFence _ generation owner actionDigest requestDigest storageGeneration operationDeadline =
  mustBoundaryRight
    ( reloadBootstrapSessionFence
        generation
        owner
        actionDigest
        requestDigest
        storageGeneration
        operationDeadline
    )

generatedPermit
  :: BootstrapSessionFence
  -> BootstrapVaultEffect
  -> BootstrapVaultEffectPermit
generatedPermit fence effect =
  mustBoundaryRight
    ( authorizeBootstrapVaultEffect
        generatedTestNow
        generatedRequestDeadline
        generatedAuthorityNow
        fence
        (BootstrapFenceStoreHeld fence)
        ( BootstrapLeaseObserved
            (bootstrapLeaseBindingForFence fence)
            generatedLeaseDeadline
            "generated-root-test-rv"
        )
        effect
    )

generatedTestNow :: MonotonicInstant
generatedTestNow = monotonicInstantFromMicros 10

generatedRequestDeadline :: Deadline
generatedRequestDeadline = deadlineFromInstant (monotonicInstantFromMicros 5000)

generatedLeaseDeadline :: Deadline
generatedLeaseDeadline = deadlineFromInstant (monotonicInstantFromMicros 800)

generatedAuthorityNow :: AuthorityClockObservation
generatedAuthorityNow =
  AuthorityTimeTrusted
    (authorityTimeFromMicros 100)
    (clockUncertaintyFromMicros 0)

testOwnerA :: OwnerNonce
testOwnerA = mustBoundaryRight (mkOwnerNonce "generated-owner-a")

testOwnerB :: OwnerNonce
testOwnerB = mustBoundaryRight (mkOwnerNonce "generated-owner-b")

testRequestA :: RequestDigest
testRequestA =
  mustBoundaryRight (mkRequestDigest (Text.replicate 64 "a"))

testRequestB :: RequestDigest
testRequestB =
  mustBoundaryRight (mkRequestDigest (Text.replicate 64 "b"))

mustBoundaryRight :: (Show err) => Either err value -> value
mustBoundaryRight = either (error . show) id

-- Provisioner, seal observation, and handoff --------------------------------

provisionerSealAndHandoffSuite :: SuiteBuilder ()
provisionerSealAndHandoffSuite =
  describe "Sprint 2.33 provisioner, seal, and observed handoff" $ do
    it "permits normal provisioner login only from completed root-session evidence" $
      withFixture $ \fixture ->
        withRootCompletion fixture $ \completion -> do
          let initial = newProvisionerSessionState completion
              generation =
                rootSessionStorageGeneration
                  (completedRootSessionBinding completion)
          planProvisionerSession initial
            `shouldBe` ProvisionerPlanArmLogin generation
          expectRight
            (applyProvisionerSessionCommand initial ArmProvisionerLogin)
            $ \pending -> do
              planProvisionerSession pending
                `shouldBe` ProvisionerPlanLogin generation
              expectRight
                ( applyProvisionerSessionCommand
                    pending
                    (ConfirmProvisionerLogin (fixtureProvisionerLogin fixture))
                )
                $ \loggedIn -> do
                  provisionerSessionIsReady loggedIn `shouldBe` True
                  planProvisionerSession loggedIn
                    `shouldBe` ProvisionerPlanReady
                      (fixtureProvisionerLogin fixture)
                  provisionerSessionPhase (restartProvisionerSession loggedIn)
                    `shouldBe` ProvisionerLoggedOut
                  expectRight
                    ( applyProvisionerSessionCommand
                        loggedIn
                        InvalidateProvisionerLogin
                    )
                    $ \invalidated ->
                      provisionerSessionIsReady invalidated `shouldBe` False

    it "refuses a provisioner receipt from another storage generation" $
      withFixture $ \fixture ->
        withRootCompletion fixture $ \completion -> do
          let initial = newProvisionerSessionState completion
              receipt = fixtureProvisionerLogin fixture
          expectRight
            ( mkProvisionerLoginReceipt
                ( rootAccessorInventoryGeneration
                    (fixtureOtherGenerationInventory fixture)
                )
                (provisionerLoginAccessor receipt)
                (provisionerLoginLeaseSeconds receipt)
            )
            $ \wrongReceipt ->
              expectRight
                (applyProvisionerSessionCommand initial ArmProvisionerLogin)
                $ \pending ->
                  applyProvisionerSessionCommand
                    pending
                    (ConfirmProvisionerLogin wrongReceipt)
                    `shouldSatisfy` isLeft

    it "bounds provisioner sessions to one hour" $
      withFixture $ \fixture -> do
        let receipt = fixtureProvisionerLogin fixture
            generation = provisionerLoginStorageGeneration receipt
            accessor = provisionerLoginAccessor receipt
        mkProvisionerLoginReceipt generation accessor 0
          `shouldBe` Left BootstrapProvisionerLeaseMustBePositive
        mkProvisionerLoginReceipt generation accessor 3600
          `shouldSatisfy` isRight
        mkProvisionerLoginReceipt generation accessor 3601
          `shouldBe` Left (BootstrapProvisionerLeaseTooLong 3600 3601)

    it "folds empty, initialized-sealed, and unsealed observations for one exact generation" $
      withFixture $ \fixture -> do
        let generation =
              rootInitStorageGeneration
                (pristineStorageBinding (fixturePristine fixture))
            initial = newVaultSealState generation
            observations =
              [ (ObserveVaultStorageEmpty generation, VaultStorageObservedEmpty)
              ,
                ( ObserveVaultInitializedSealed generation
                , VaultObservedInitializedSealed
                )
              ,
                ( ObserveVaultInitializedUnsealed generation
                , VaultObservedInitializedUnsealed
                )
              ]
        forM_ observations $ \(observation, expectedPhase) ->
          expectRight (observeVaultSeal initial observation) $ \observed -> do
            vaultSealPhase observed `shouldBe` expectedPhase
            vaultSealIsUnsealed observed
              `shouldBe` (expectedPhase == VaultObservedInitializedUnsealed)

    it "refuses seal-generation mismatch and established-to-empty regression" $
      withFixture $ \fixture -> do
        let generation =
              rootInitStorageGeneration
                (pristineStorageBinding (fixturePristine fixture))
            otherGeneration =
              rootInitStorageGeneration
                (pristineStorageBinding (fixtureOtherPristine fixture))
            initial = newVaultSealState generation
        observeVaultSeal initial (ObserveVaultInitializedSealed otherGeneration)
          `shouldSatisfy` isLeft
        expectRight
          (observeVaultSeal initial (ObserveVaultInitializedSealed generation))
          $ \sealed -> do
            observeVaultSeal sealed (ObserveVaultStorageEmpty generation)
              `shouldBe` Left VaultSealEstablishedStorageResetRefused
            expectRight
              (observeVaultSeal sealed (ObserveVaultInitializedUnsealed generation))
              $ \unsealed -> do
                vaultSealIsUnsealed unsealed `shouldBe` True
                expectRight
                  (observeVaultSeal unsealed (ObserveVaultInitializedSealed generation))
                  $ \resealed ->
                    vaultSealPhase resealed `shouldBe` VaultObservedInitializedSealed

    it "makes post-unseal handoff an observation-only arm/observe/complete fold" $
      withFixture $ \fixture -> do
        let generation =
              rootInitStorageGeneration
                (pristineStorageBinding (fixturePristine fixture))
            initial = newPostUnsealHandoffState generation
        planPostUnsealHandoff initial
          `shouldBe` PostUnsealHandoffPlanArmObservation generation
        expectRight
          ( applyPostUnsealHandoffCommand
              initial
              ArmPostUnsealHandoffObservation
          )
          $ \pending -> do
            planPostUnsealHandoff pending
              `shouldBe` PostUnsealHandoffPlanObserveConsumer
                generation
                PostUnsealLifecycleAuthority
            expectRight
              ( applyPostUnsealHandoffCommand
                  pending
                  ( ConfirmPostUnsealHandoffObserved
                      (fixtureHandoffReceipt fixture)
                  )
              )
              $ \observed -> do
                postUnsealHandoffIsObserved observed `shouldBe` True
                planPostUnsealHandoff observed
                  `shouldBe` PostUnsealHandoffPlanComplete
                    (fixtureHandoffReceipt fixture)

    it "refuses handoff evidence from another storage generation" $
      withFixture $ \fixture -> do
        let generation =
              rootInitStorageGeneration
                (pristineStorageBinding (fixturePristine fixture))
            otherGeneration =
              rootInitStorageGeneration
                (pristineStorageBinding (fixtureOtherPristine fixture))
            wrongReceipt =
              mkPostUnsealHandoffReceipt
                otherGeneration
                (postUnsealHandoffConsumer (fixtureHandoffReceipt fixture))
                (postUnsealHandoffObservationDigest (fixtureHandoffReceipt fixture))
            initial = newPostUnsealHandoffState generation
        expectRight
          ( applyPostUnsealHandoffCommand
              initial
              ArmPostUnsealHandoffObservation
          )
          $ \pending ->
            applyPostUnsealHandoffCommand
              pending
              (ConfirmPostUnsealHandoffObserved wrongReceipt)
              `shouldSatisfy` isLeft

withRootCompletion :: Fixture -> (RootSessionCompletion -> Expectation) -> Expectation
withRootCompletion fixture assertion =
  expectRight (rootSessionPrefixes fixture) $ \states -> do
    let sessionCompletion = rootSessionCompletion (last states)
    case sessionCompletion of
      Nothing -> expectationFailure "root session fixture did not complete"
      Just completion -> assertion completion

-- Child initialization custody --------------------------------------------

childCustodySuite :: SuiteBuilder ()
childCustodySuite =
  describe "Sprint 2.33 child encrypted-receipt custody crash matrix" $ do
    it "walks receipt write/read-back, parent generation CAS, acknowledgment, and local absence" $
      withFixture $ \fixture ->
        expectRight (childCustodyPrefixes fixture) $ \states -> do
          length states `shouldBe` length (childCustodyExpectedPlans fixture)
          forM_
            (zip states (childCustodyExpectedPlans fixture))
            $ \(state, expectedPlan) -> do
              childCustodyInvariantViolations state `shouldBe` []
              planChildCustody state `shouldBe` expectedPlan
          childCustodyIsComplete (last states) `shouldBe` True

    it "restores each authoritative child-custody durable prefix" $
      withFixture $ \fixture -> do
        let cases = childCustodyObservationPlanCases fixture
        forM_ cases $ \(_label, observation, expectedPlan) ->
          expectRight (resumeChildCustodyFromObservation observation) $ \resumed -> do
            childCustodyInvariantViolations resumed `shouldBe` []
            planChildCustody resumed `shouldBe` expectedPlan

    it "refuses binding, local read-back, and parent acknowledgment mismatch" $
      withFixture $ \fixture ->
        expectRight (childCustodyPrefixes fixture) $ \states -> do
          let receipt = fixtureChildEncryptedReceipt fixture
              wrongBindingReceipt =
                receipt
                  { childEncryptedReceiptBinding = fixtureOtherChildBinding fixture
                  }
              wrongDigestReceipt =
                receipt
                  { childEncryptedReceiptDigest = fixtureDigestB fixture
                  }
              acknowledgement = fixtureParentAcknowledgement fixture
              wrongBindingAcknowledgement =
                acknowledgement
                  { parentCustodyAcknowledgedBinding =
                      fixtureOtherChildBinding fixture
                  }
              wrongDigestAcknowledgement =
                acknowledgement
                  { parentCustodyAcknowledgedReceiptDigest = fixtureDigestB fixture
                  }
          expectRight (firstValue "child-custody prefix" states) $ \initial ->
            applyChildCustodyCommand
              initial
              (CaptureChildEncryptedReceipt wrongBindingReceipt)
              `shouldSatisfy` isLeft
          applyChildCustodyCommand
            (states !! 2)
            (ConfirmChildLocalReceiptReadBack wrongDigestReceipt)
            `shouldBe` Left ChildCustodyLocalReadBackMismatch
          forM_
            [wrongBindingAcknowledgement, wrongDigestAcknowledgement]
            $ \wrong ->
              applyChildCustodyCommand
                (states !! 4)
                (ConfirmParentCustodyReadBack wrong)
                `shouldBe` Left ChildCustodyParentAcknowledgementMismatch
          resumeChildCustodyFromObservation
            ( ChildObservedParentCustody
                receipt
                wrongDigestAcknowledgement
            )
            `shouldSatisfy` isLeft

    it "refuses cross-binding restart and child durable-prefix regression" $
      withFixture $ \fixture ->
        expectRight (childCustodyPrefixes fixture) $ \states -> do
          restartChildCustody
            (last states)
            (ChildObservedNoLocalReceipt (fixtureChildBinding fixture))
            `shouldBe` Left (ChildCustodyObservationRegression 4 0)
          restartChildCustody
            (states !! 3)
            (ChildObservedNoLocalReceipt (fixtureOtherChildBinding fixture))
            `shouldSatisfy` isLeft

    it
      "latches cancellation at every phase while preserving captured-response and parent-CAS safety tails"
      $ withFixture
      $ \fixture ->
        expectRight (childCustodyPrefixes fixture) $ \states -> do
          let commands = childCustodyCommands fixture
              nextEventAllowed =
                [True, True, True, False, True, True, True, True, True]
              expectedPlans = childCustodyCancellationPlans fixture
          length states `shouldBe` length expectedPlans
          forM_
            (zip3 [(0 :: Int) ..] states expectedPlans)
            $ \(index, state, expectedPlan) ->
              expectRight
                ( applyChildCustodyCommand
                    state
                    (CancelChildCustody (fixtureCancellation fixture))
                )
                $ \cancelled -> do
                  planChildCustody cancelled `shouldBe` expectedPlan
                  case drop index commands of
                    next : _ ->
                      isRight (applyChildCustodyCommand cancelled next)
                        `shouldBe` (nextEventAllowed !! index)
                    [] -> childCustodyIsComplete cancelled `shouldBe` True

childCustodyCommands :: Fixture -> [ChildCustodyCommand]
childCustodyCommands Fixture {fixtureChildEncryptedReceipt, fixtureParentAcknowledgement} =
  [ CaptureChildEncryptedReceipt fixtureChildEncryptedReceipt
  , RecordChildLocalReceiptWrite
  , ConfirmChildLocalReceiptReadBack fixtureChildEncryptedReceipt
  , ArmChildParentGenerationCas
  , ConfirmParentCustodyReadBack fixtureParentAcknowledgement
  , ArmChildLocalReceiptDeletion
  , RecordChildLocalReceiptDeletion
  , ConfirmChildLocalReceiptAbsence
  , ConfirmChildRecoveryCustodyDurable
  ]

childCustodyPrefixes :: Fixture -> Either ChildCustodyError [ChildCustodyState]
childCustodyPrefixes fixture =
  commandPrefixes
    applyChildCustodyCommand
    (newChildCustodyState (fixtureChildBinding fixture))
    (childCustodyCommands fixture)

childCustodyExpectedPlans :: Fixture -> [ChildCustodyPlan]
childCustodyExpectedPlans Fixture {fixtureChildBinding, fixtureChildEncryptedReceipt, fixtureParentAcknowledgement} =
  [ ChildPlanAwaitEncryptedInitResponse fixtureChildBinding
  , ChildPlanWriteLocalEncryptedReceipt fixtureChildEncryptedReceipt
  , ChildPlanReadBackLocalEncryptedReceipt fixtureChildEncryptedReceipt
  , ChildPlanArmParentGenerationCas fixtureChildEncryptedReceipt
  , ChildPlanParentGenerationCas fixtureChildEncryptedReceipt
  , ChildPlanDeleteLocalEncryptedReceipt fixtureParentAcknowledgement
  , ChildPlanDeleteLocalEncryptedReceipt fixtureParentAcknowledgement
  , ChildPlanReadBackLocalReceiptAbsence fixtureParentAcknowledgement
  , ChildPlanMarkCustodyDurable fixtureParentAcknowledgement
  , ChildPlanCustodyComplete fixtureParentAcknowledgement
  ]

childCustodyCancellationPlans :: Fixture -> [ChildCustodyPlan]
childCustodyCancellationPlans Fixture {fixtureChildEncryptedReceipt, fixtureParentAcknowledgement} =
  [ ChildPlanCancellationLatched "ChildAwaitingEncryptedReceipt"
  , ChildPlanWriteLocalEncryptedReceipt fixtureChildEncryptedReceipt
  , ChildPlanReadBackLocalEncryptedReceipt fixtureChildEncryptedReceipt
  , ChildPlanCancellationLatched "ChildLocalReceiptReadBack"
  , ChildPlanParentGenerationCas fixtureChildEncryptedReceipt
  , ChildPlanDeleteLocalEncryptedReceipt fixtureParentAcknowledgement
  , ChildPlanDeleteLocalEncryptedReceipt fixtureParentAcknowledgement
  , ChildPlanReadBackLocalReceiptAbsence fixtureParentAcknowledgement
  , ChildPlanMarkCustodyDurable fixtureParentAcknowledgement
  , ChildPlanCustodyComplete fixtureParentAcknowledgement
  ]

childCustodyObservationPlanCases
  :: Fixture
  -> [(String, ChildCustodyDurableObservation, ChildCustodyPlan)]
childCustodyObservationPlanCases Fixture {fixtureChildBinding, fixtureChildEncryptedReceipt, fixtureParentAcknowledgement} =
  [
    ( "no local receipt"
    , ChildObservedNoLocalReceipt fixtureChildBinding
    , ChildPlanAwaitEncryptedInitResponse fixtureChildBinding
    )
  ,
    ( "local encrypted receipt"
    , ChildObservedLocalEncryptedReceipt fixtureChildEncryptedReceipt
    , ChildPlanArmParentGenerationCas fixtureChildEncryptedReceipt
    )
  ,
    ( "parent custody"
    , ChildObservedParentCustody
        fixtureChildEncryptedReceipt
        fixtureParentAcknowledgement
    , ChildPlanDeleteLocalEncryptedReceipt fixtureParentAcknowledgement
    )
  ,
    ( "parent custody and local absence"
    , ChildObservedParentCustodyLocalReceiptAbsent fixtureParentAcknowledgement
    , ChildPlanMarkCustodyDurable fixtureParentAcknowledgement
    )
  ,
    ( "custody durable"
    , ChildObservedRecoveryCustodyDurable fixtureParentAcknowledgement
    , ChildPlanCustodyComplete fixtureParentAcknowledgement
    )
  ]

-- One-time child recovery --------------------------------------------------

childRecoverySuite :: SuiteBuilder ()
childRecoverySuite =
  describe "Sprint 2.33 one-time child recovery crash matrix" $ do
    it "walks every nonce, orphan-cleanup, generate, repair, revoke, and absence prefix" $
      withFixture $ \fixture ->
        expectRight (childRecoveryPrefixes fixture) $ \states -> do
          length states `shouldBe` length (childRecoveryExpectedPlans fixture)
          forM_
            (zip states (childRecoveryExpectedPlans fixture))
            $ \(state, expectedPlan) -> do
              childRecoveryInvariantViolations state `shouldBe` []
              planChildRecovery state `shouldBe` expectedPlan
          childRecoveryIsComplete (last states) `shouldBe` True

    it "resumes an exact nonce and requires the durable arm/in-flight consume prefix" $
      withFixture $ \fixture ->
        expectRight (childRecoveryPrefixes fixture) $ \states -> do
          forM_ (drop 1 states) $ \state ->
            applyChildRecoveryCommand
              state
              (PrepareChildRecoveryDelivery (fixtureChildDelivery fixture))
              `shouldBe` Right state
          planChildRecovery (states !! 1)
            `shouldBe` ChildRecoveryPlanArmDeliveryConsume
              (fixtureChildDelivery fixture)
          planChildRecovery (states !! 2)
            `shouldBe` ChildRecoveryPlanStartDeliveryConsume
              (fixtureChildDelivery fixture)
          planChildRecovery (states !! 3)
            `shouldBe` ChildRecoveryPlanReconcileDeliveryConsume
              (fixtureChildDelivery fixture)

    it "refuses different nonce, attestation, payload, child, generation, storage, or transaction" $
      withFixture $ \fixture ->
        expectRight (childRecoveryPrefixes fixture) $ \states -> do
          let prepared = states !! 1
              delivery = fixtureChildDelivery fixture
              sameDigestOtherPayload =
                (fixtureOtherPayloadDelivery fixture)
                  { childRecoveryDeliveryDigest =
                      childRecoveryDeliveryDigest delivery
                  }
              bindingCases =
                [
                  ( childDeliveryWithBinding
                      delivery
                      (fixtureOtherChildBinding fixture)
                  , isChildConflict
                  )
                ,
                  ( childDeliveryWithBinding
                      delivery
                      (fixtureOtherCustodyGenerationBinding fixture)
                  , isCustodyGenerationConflict
                  )
                ,
                  ( childDeliveryWithBinding
                      delivery
                      (fixtureOtherStorageGenerationBinding fixture)
                  , isStorageGenerationConflict
                  )
                ,
                  ( childDeliveryWithBinding
                      delivery
                      (fixtureOtherTransactionBinding fixture)
                  , isTransactionConflict
                  )
                ]
          expectLeftWhere
            ( applyChildRecoveryCommand
                prepared
                ( PrepareChildRecoveryDelivery
                    (fixtureOtherNonceDelivery fixture)
                )
            )
            isNonceConflict
          expectLeftWhere
            ( applyChildRecoveryCommand
                prepared
                ( PrepareChildRecoveryDelivery
                    (fixtureOtherAttestationDelivery fixture)
                )
            )
            isAttestationConflict
          expectLeftWhere
            ( applyChildRecoveryCommand
                prepared
                ( PrepareChildRecoveryDelivery
                    (fixtureOtherPayloadDelivery fixture)
                )
            )
            isPayloadConflict
          expectLeftWhere
            ( applyChildRecoveryCommand
                prepared
                (PrepareChildRecoveryDelivery sameDigestOtherPayload)
            )
            isPayloadConflict
          forM_ bindingCases $ \(conflictingDelivery, predicate) ->
            expectLeftWhere
              ( applyChildRecoveryCommand
                  prepared
                  (PrepareChildRecoveryDelivery conflictingDelivery)
              )
              predicate

    it "refuses stale-cleanup order, inventory, journal, repair, and accessor-absence mismatch" $
      withFixture $ \fixture ->
        expectRight (childRecoveryPrefixes fixture) $ \states -> do
          applyChildRecoveryCommand
            (states !! 6)
            ( ConfirmChildRecoveryRootAccessorInventory
                (fixtureOtherGenerationInventory fixture)
            )
            `shouldBe` Left ChildRecoveryAccessorInventoryMismatch
          applyChildRecoveryCommand
            (states !! 7)
            ( ConfirmChildRecoveryStaleRootAccessorRevoked
                (fixtureAccessorB fixture)
            )
            `shouldBe` Left ChildRecoveryStaleAccessorOrderMismatch
          applyChildRecoveryCommand
            (states !! 9)
            ( ConfirmChildRecoveryStableRootAccessorAbsence
                (fixtureEmptyAbsence fixture)
            )
            `shouldBe` Left ChildRecoveryStableAccessorAbsenceMismatch
          applyChildRecoveryCommand
            (states !! 12)
            ( ConfirmChildRecoveryRootAccessorJournaled
                (fixtureAccessorA fixture)
            )
            `shouldBe` Left ChildRecoveryAccessorJournalMismatch
          let wrongRepair =
                (fixtureChildRepairReadBack fixture)
                  { childRecoveryRepairDeliveryDigest = fixtureDigestA fixture
                  }
          applyChildRecoveryCommand
            (states !! 15)
            (ConfirmChildRecoveryRepairReadBack wrongRepair)
            `shouldBe` Left ChildRecoveryRepairReadBackMismatch
          applyChildRecoveryCommand
            (states !! 19)
            ( ConfirmChildRecoveryRootAccessorAbsent
                (fixtureStaleAbsence fixture)
            )
            `shouldBe` Left ChildRecoveryAccessorAbsenceMismatch

    it "restarts every consumed unfinished prefix through exact-nonce orphan cleanup" $
      withFixture $ \fixture ->
        expectRight (childRecoveryPrefixes fixture) $ \states -> do
          expectRight (firstValue "child-recovery prefix" states) $ \initial -> do
            restartChildRecovery initial `shouldBe` initial
            restartChildRecovery (states !! 1) `shouldBe` (states !! 1)
            restartChildRecovery (states !! 2) `shouldBe` (states !! 2)
            restartChildRecovery (states !! 3) `shouldBe` (states !! 3)
            forM_ (take 16 (drop 4 states)) $ \state -> do
              let restarted = restartChildRecovery state
              childRecoveryStateDisposition restarted `shouldBe` CustodyRunning
              childRecoveryStatePhase restarted
                `shouldBe` ChildRecoveryDeliveryConsumed
                  (fixtureChildDelivery fixture)
              childRecoveryInvariantViolations restarted `shouldBe` []
            restartChildRecovery (last states) `shouldBe` last states

    it "cancels at every prefix without consuming a new delivery or leaking a known accessor" $
      withFixture $ \fixture ->
        expectRight (childRecoveryPrefixes fixture) $ \states -> do
          let expectedPlans = childRecoveryCancellationPlans fixture
          length states `shouldBe` length expectedPlans
          forM_ (zip states expectedPlans) $ \(state, expectedPlan) ->
            expectRight
              ( applyChildRecoveryCommand
                  state
                  (CancelChildRecovery (fixtureCancellation fixture))
              )
              $ \cancelled ->
                planChildRecovery cancelled `shouldBe` expectedPlan
          expectRight
            ( applyChildRecoveryCommand
                (states !! 1)
                (CancelChildRecovery (fixtureCancellation fixture))
            )
            $ \cancelledPrepared ->
              applyChildRecoveryCommand
                cancelledPrepared
                ArmChildRecoveryDeliveryConsume
                `shouldSatisfy` isLeft

    it "journals and revokes a returned accessor on cancellation, then resumes the same nonce" $
      withFixture $ \fixture ->
        expectRight (childRecoveryPrefixes fixture) $ \states ->
          expectRight
            ( applyChildRecoveryCommand
                (states !! 12)
                (CancelChildRecovery (fixtureCancellation fixture))
            )
            $ \cancelledPendingJournal ->
              expectRight
                ( applyChildRecoveryCommand
                    cancelledPendingJournal
                    ( ConfirmChildRecoveryRootAccessorJournaled
                        (fixtureCurrentAccessor fixture)
                    )
                )
                $ \journaled ->
                  expectRight
                    (applyChildRecoveryCommand journaled ArmChildRecoveryRootRevocation)
                    $ \revocationPending ->
                      expectRight
                        ( applyChildRecoveryCommand
                            revocationPending
                            ConfirmChildRecoveryRootRevoked
                        )
                        $ \revoked ->
                          expectRight
                            ( applyChildRecoveryCommand
                                revoked
                                ArmChildRecoveryRootAccessorAbsenceCheck
                            )
                            $ \absencePending ->
                              expectRight
                                ( applyChildRecoveryCommand
                                    absencePending
                                    ( ConfirmChildRecoveryRootAccessorAbsent
                                        (fixtureCurrentAbsence fixture)
                                    )
                                )
                                $ \paused -> do
                                  childRecoveryIsComplete paused `shouldBe` False
                                  planChildRecovery paused
                                    `shouldBe` ChildRecoveryPlanCancellationLatched
                                      ( show
                                          ( ChildRecoveryGenerateRootPending
                                              (fixtureChildDelivery fixture)
                                              (fixtureCurrentAbsence fixture)
                                          )
                                      )
                                  childRecoveryStatePhase (restartChildRecovery paused)
                                    `shouldBe` ChildRecoveryDeliveryConsumed
                                      (fixtureChildDelivery fixture)

    it "finishes revocation and delivery acknowledgment after repair read-back despite cancellation" $
      withFixture $ \fixture ->
        expectRight (childRecoveryPrefixes fixture) $ \states ->
          expectRight
            ( applyChildRecoveryCommand
                (states !! 16)
                (CancelChildRecovery (fixtureCancellation fixture))
            )
            $ \cancelled ->
              expectRight
                (applyChildRecoveryCommand cancelled ArmChildRecoveryRootRevocation)
                $ \revocationPending ->
                  expectRight
                    ( applyChildRecoveryCommand
                        revocationPending
                        ConfirmChildRecoveryRootRevoked
                    )
                    $ \revoked ->
                      expectRight
                        ( applyChildRecoveryCommand
                            revoked
                            ArmChildRecoveryRootAccessorAbsenceCheck
                        )
                        $ \absencePending ->
                          expectRight
                            ( applyChildRecoveryCommand
                                absencePending
                                ( ConfirmChildRecoveryRootAccessorAbsent
                                    (fixtureCurrentAbsence fixture)
                                )
                            )
                            $ \complete -> do
                              childRecoveryIsComplete complete `shouldBe` True
                              childRecoveryInvariantViolations complete `shouldBe` []

childRecoveryCommands :: Fixture -> [ChildRecoveryCommand]
childRecoveryCommands
  Fixture
    { fixtureChildDelivery
    , fixtureStaleInventory
    , fixtureAccessorA
    , fixtureAccessorB
    , fixtureStaleAbsence
    , fixtureCurrentAccessor
    , fixtureChildRepairReadBack
    , fixtureCurrentAbsence
    } =
    [ PrepareChildRecoveryDelivery fixtureChildDelivery
    , ArmChildRecoveryDeliveryConsume
    , RecordChildRecoveryDeliveryConsumeStarted
    , ConfirmChildRecoveryDeliveryConsumed
        ( mkChildRecoveryConsumptionObservation
            fixtureChildDelivery
            ChildRecoveryConsumptionApplied
            (childRecoveryDeliveryDigest fixtureChildDelivery)
        )
    , ArmChildRecoveryOrphanCleanup
    , ConfirmChildRecoveryIncompleteGenerateRootCancelled
    , ConfirmChildRecoveryRootAccessorInventory fixtureStaleInventory
    , ConfirmChildRecoveryStaleRootAccessorRevoked fixtureAccessorA
    , ConfirmChildRecoveryStaleRootAccessorRevoked fixtureAccessorB
    , ConfirmChildRecoveryStableRootAccessorAbsence fixtureStaleAbsence
    , RecordChildRecoveryRootGenerationStarted
    , CaptureChildRecoveryRootAccessor fixtureCurrentAccessor
    , ConfirmChildRecoveryRootAccessorJournaled fixtureCurrentAccessor
    , ArmChildRecoveryRepair
    , RecordChildRecoveryRepairApplied
    , ConfirmChildRecoveryRepairReadBack fixtureChildRepairReadBack
    , ArmChildRecoveryRootRevocation
    , ConfirmChildRecoveryRootRevoked
    , ArmChildRecoveryRootAccessorAbsenceCheck
    , ConfirmChildRecoveryRootAccessorAbsent fixtureCurrentAbsence
    ]

childRecoveryPrefixes
  :: Fixture -> Either ChildRecoveryError [ChildRecoveryState]
childRecoveryPrefixes fixture =
  commandPrefixes
    applyChildRecoveryCommand
    (newChildRecoveryState (fixtureChildBinding fixture))
    (childRecoveryCommands fixture)

childRecoveryExpectedPlans :: Fixture -> [ChildRecoveryPlan]
childRecoveryExpectedPlans
  Fixture
    { fixtureChildBinding
    , fixtureChildDelivery
    , fixtureStaleInventory
    , fixtureAccessorA
    , fixtureAccessorB
    , fixtureCurrentAccessor
    , fixtureChildRepairReadBack
    , fixtureCurrentAbsence
    } =
    [ ChildRecoveryPlanAwaitDelivery fixtureChildBinding
    , ChildRecoveryPlanArmDeliveryConsume fixtureChildDelivery
    , ChildRecoveryPlanStartDeliveryConsume fixtureChildDelivery
    , ChildRecoveryPlanReconcileDeliveryConsume fixtureChildDelivery
    , ChildRecoveryPlanArmOrphanCleanup fixtureChildDelivery
    , ChildRecoveryPlanCancelIncompleteGenerateRoot fixtureChildDelivery
    , ChildRecoveryPlanInventoryStaleRootAccessors fixtureChildDelivery
    , ChildRecoveryPlanRevokeStaleRootAccessor
        fixtureChildDelivery
        fixtureAccessorA
    , ChildRecoveryPlanRevokeStaleRootAccessor
        fixtureChildDelivery
        fixtureAccessorB
    , ChildRecoveryPlanProveStableRootAccessorAbsence
        fixtureChildDelivery
        fixtureStaleInventory
    , ChildRecoveryPlanGenerateShortLivedRoot fixtureChildDelivery
    , ChildRecoveryPlanAwaitGeneratedRootAccessor fixtureChildDelivery
    , ChildRecoveryPlanJournalRootAccessor
        fixtureChildDelivery
        fixtureCurrentAccessor
    , ChildRecoveryPlanArmRepair fixtureChildDelivery fixtureCurrentAccessor
    , ChildRecoveryPlanApplyRepair fixtureChildDelivery fixtureCurrentAccessor
    , ChildRecoveryPlanReadBackRepair fixtureChildDelivery fixtureCurrentAccessor
    , ChildRecoveryPlanArmRootRevocation
        fixtureChildDelivery
        fixtureCurrentAccessor
    , ChildRecoveryPlanRevokeRootAccessor
        fixtureChildDelivery
        fixtureCurrentAccessor
    , ChildRecoveryPlanArmRootAccessorAbsenceCheck
        fixtureChildDelivery
        fixtureCurrentAccessor
    , ChildRecoveryPlanProveRootAccessorAbsent
        fixtureChildDelivery
        fixtureCurrentAccessor
    , ChildRecoveryPlanComplete
        fixtureChildDelivery
        fixtureChildRepairReadBack
        fixtureCurrentAbsence
    ]

childRecoveryCancellationPlans :: Fixture -> [ChildRecoveryPlan]
childRecoveryCancellationPlans
  Fixture
    { fixtureChildDelivery
    , fixtureStaleInventory
    , fixtureAccessorA
    , fixtureAccessorB
    , fixtureCurrentAccessor
    , fixtureChildRepairReadBack
    , fixtureCurrentAbsence
    } =
    [ ChildRecoveryPlanCancellationLatched "ChildRecoveryAvailable"
    , ChildRecoveryPlanCancellationLatched
        "ChildRecoveryDeliveryPrepared <redacted>"
    , ChildRecoveryPlanCancellationLatched
        "ChildRecoveryDeliveryConsumeArmed <redacted>"
    , ChildRecoveryPlanReconcileDeliveryConsume fixtureChildDelivery
    , ChildRecoveryPlanArmOrphanCleanup fixtureChildDelivery
    , ChildRecoveryPlanCancelIncompleteGenerateRoot fixtureChildDelivery
    , ChildRecoveryPlanInventoryStaleRootAccessors fixtureChildDelivery
    , ChildRecoveryPlanRevokeStaleRootAccessor
        fixtureChildDelivery
        fixtureAccessorA
    , ChildRecoveryPlanRevokeStaleRootAccessor
        fixtureChildDelivery
        fixtureAccessorB
    , ChildRecoveryPlanProveStableRootAccessorAbsence
        fixtureChildDelivery
        fixtureStaleInventory
    , ChildRecoveryPlanCancellationLatched
        "ChildRecoveryGenerateRootPending <redacted>"
    , ChildRecoveryPlanCancelIncompleteGenerateRoot fixtureChildDelivery
    , ChildRecoveryPlanJournalRootAccessor
        fixtureChildDelivery
        fixtureCurrentAccessor
    , ChildRecoveryPlanArmRootRevocation
        fixtureChildDelivery
        fixtureCurrentAccessor
    , ChildRecoveryPlanArmRootRevocation
        fixtureChildDelivery
        fixtureCurrentAccessor
    , ChildRecoveryPlanArmRootRevocation
        fixtureChildDelivery
        fixtureCurrentAccessor
    , ChildRecoveryPlanArmRootRevocation
        fixtureChildDelivery
        fixtureCurrentAccessor
    , ChildRecoveryPlanRevokeRootAccessor
        fixtureChildDelivery
        fixtureCurrentAccessor
    , ChildRecoveryPlanArmRootAccessorAbsenceCheck
        fixtureChildDelivery
        fixtureCurrentAccessor
    , ChildRecoveryPlanProveRootAccessorAbsent
        fixtureChildDelivery
        fixtureCurrentAccessor
    , ChildRecoveryPlanComplete
        fixtureChildDelivery
        fixtureChildRepairReadBack
        fixtureCurrentAbsence
    ]

childDeliveryWithBinding
  :: ChildRecoveryDelivery -> ChildCustodyBinding -> ChildRecoveryDelivery
childDeliveryWithBinding delivery binding =
  delivery {childRecoveryDeliveryBinding = binding}

isChildConflict :: ChildRecoveryError -> Bool
isChildConflict errorValue =
  case errorValue of
    ChildRecoveryChildConflict _ _ -> True
    _ -> False

isCustodyGenerationConflict :: ChildRecoveryError -> Bool
isCustodyGenerationConflict errorValue =
  case errorValue of
    ChildRecoveryGenerationConflict _ _ -> True
    _ -> False

isStorageGenerationConflict :: ChildRecoveryError -> Bool
isStorageGenerationConflict errorValue =
  case errorValue of
    ChildRecoveryStorageGenerationConflict _ _ -> True
    _ -> False

isTransactionConflict :: ChildRecoveryError -> Bool
isTransactionConflict errorValue =
  case errorValue of
    ChildRecoveryTransactionConflict _ _ -> True
    _ -> False

isNonceConflict :: ChildRecoveryError -> Bool
isNonceConflict errorValue =
  case errorValue of
    ChildRecoveryNonceConflict _ _ -> True
    _ -> False

isAttestationConflict :: ChildRecoveryError -> Bool
isAttestationConflict errorValue =
  case errorValue of
    ChildRecoveryAttestationConflict _ _ -> True
    _ -> False

isPayloadConflict :: ChildRecoveryError -> Bool
isPayloadConflict errorValue =
  case errorValue of
    ChildRecoveryPayloadConflict _ _ -> True
    _ -> False

-- Product projection -------------------------------------------------------

productProjectionSuite :: SuiteBuilder ()
productProjectionSuite =
  describe "Sprint 2.33 bounded Bootstrap Broker product projection" $ do
    it "orders root custody, unseal, root session, provisioner, and observed handoff" $
      withFixture $ \fixture ->
        withProjectionParts fixture $ \parts -> do
          let initialRoot =
                newRootInitState (fixturePristine fixture)
              initialSeal =
                newVaultSealState
                  ( rootInitStorageGeneration
                      (pristineStorageBinding (fixturePristine fixture))
                  )
          expectRight (mkBootstrapProjection initialRoot initialSeal) $ \projection ->
            planBootstrapProjection projection
              `shouldBe` BootstrapProjectionPlanRootInit
                (planRootInit initialRoot)
          planBootstrapProjection (partsRootCompleteSealed parts)
            `shouldBe` BootstrapProjectionPlanObserveVaultSeal
              (vaultSealStorageGeneration (partsSealUnsealed parts))
          planBootstrapProjection (partsRootCompleteUnsealed parts)
            `shouldBe` BootstrapProjectionPlanStartRootSession
              (fixtureRecoveryCustody fixture)
          let withActiveRoot =
                (partsRootCompleteUnsealed parts)
                  { bootstrapProjectionRootSession =
                      Just (partsRootSessionInitial parts)
                  }
          planBootstrapProjection withActiveRoot
            `shouldBe` BootstrapProjectionPlanRootSession
              (planRootSession (partsRootSessionInitial parts))
          let withClosedRoot =
                (partsRootCompleteUnsealed parts)
                  { bootstrapProjectionRootSession =
                      Just (partsRootSessionComplete parts)
                  }
          planBootstrapProjection withClosedRoot
            `shouldBe` BootstrapProjectionPlanStartProvisioner
              (partsRootCompletion parts)
          let withLoggedOutProvisioner =
                withClosedRoot
                  { bootstrapProjectionProvisioner =
                      Just (partsProvisionerInitial parts)
                  }
          planBootstrapProjection withLoggedOutProvisioner
            `shouldBe` BootstrapProjectionPlanProvisioner
              (planProvisionerSession (partsProvisionerInitial parts))
          let readyForHandoff =
                withClosedRoot
                  { bootstrapProjectionProvisioner =
                      Just (partsProvisionerLoggedIn parts)
                  }
          planBootstrapProjection readyForHandoff
            `shouldBe` BootstrapProjectionPlanHandoff
              (planPostUnsealHandoff (bootstrapProjectionHandoff readyForHandoff))
          planBootstrapProjection
            ( readyForHandoff
                { bootstrapProjectionHandoff = partsHandoffPending parts
                }
            )
            `shouldBe` BootstrapProjectionPlanHandoff
              (planPostUnsealHandoff (partsHandoffPending parts))
          planBootstrapProjection (partsCompleteProjection parts)
            `shouldBe` BootstrapProjectionPlanComplete
              (fixtureHandoffReceipt fixture)
          bootstrapProjectionIsComplete (partsCompleteProjection parts)
            `shouldBe` True

    it "rejects seal, handoff, and child storage-generation disagreement" $
      withFixture $ \fixture ->
        withProjectionParts fixture $ \parts -> do
          let complete = partsCompleteProjection parts
              otherGeneration =
                rootInitStorageGeneration
                  (pristineStorageBinding (fixtureOtherPristine fixture))
              wrongSeal =
                complete
                  { bootstrapProjectionVaultSeal =
                      newVaultSealState otherGeneration
                  }
              wrongHandoff =
                complete
                  { bootstrapProjectionHandoff =
                      newPostUnsealHandoffState otherGeneration
                  }
              wrongChildCustody =
                complete
                  { bootstrapProjectionChildCustody =
                      Just
                        ( newChildCustodyState
                            (fixtureOtherStorageGenerationBinding fixture)
                        )
                  }
              wrongChildRecovery =
                complete
                  { bootstrapProjectionChildRecovery =
                      Just
                        ( newChildRecoveryState
                            (fixtureOtherStorageGenerationBinding fixture)
                        )
                  }
          bootstrapProjectionInvariantViolations wrongSeal
            `shouldContain` [BootstrapProjectionSealGenerationDiffers]
          bootstrapProjectionInvariantViolations wrongHandoff
            `shouldContain` [BootstrapProjectionHandoffGenerationDiffers]
          bootstrapProjectionInvariantViolations wrongChildCustody
            `shouldContain` [BootstrapProjectionChildCustodyGenerationDiffers]
          bootstrapProjectionInvariantViolations wrongChildRecovery
            `shouldContain` [BootstrapProjectionChildRecoveryGenerationDiffers]

    it "rejects root authority before custody and provisioner authority before baseline" $
      withFixture $ \fixture ->
        withProjectionParts fixture $ \parts -> do
          let generation = vaultSealStorageGeneration (partsSealUnsealed parts)
              incompleteProjection =
                BootstrapProjection
                  { bootstrapProjectionRootInit =
                      newRootInitState (fixturePristine fixture)
                  , bootstrapProjectionVaultSeal = partsSealUnsealed parts
                  , bootstrapProjectionRootSession =
                      Just (partsRootSessionInitial parts)
                  , bootstrapProjectionProvisioner = Nothing
                  , bootstrapProjectionChildCustody = Nothing
                  , bootstrapProjectionChildRecovery = Nothing
                  , bootstrapProjectionHandoff =
                      newPostUnsealHandoffState generation
                  }
              provisionerTooEarly =
                (partsRootCompleteUnsealed parts)
                  { bootstrapProjectionProvisioner =
                      Just (partsProvisionerInitial parts)
                  }
          bootstrapProjectionInvariantViolations incompleteProjection
            `shouldContain` [BootstrapProjectionRootSessionBeforeCustody]
          bootstrapProjectionInvariantViolations provisionerTooEarly
            `shouldContain` [BootstrapProjectionProvisionerBeforeBaseline]

    it "rejects root/child and child/child concurrent mutation authority" $
      withFixture $ \fixture ->
        withProjectionParts fixture $ \parts -> do
          let rootAndChild =
                (partsRootCompleteUnsealed parts)
                  { bootstrapProjectionRootSession =
                      Just (partsRootSessionInitial parts)
                  , bootstrapProjectionChildCustody =
                      Just (newChildCustodyState (fixtureChildBinding fixture))
                  }
              bothChildren =
                (partsRootCompleteUnsealed parts)
                  { bootstrapProjectionChildCustody =
                      Just (newChildCustodyState (fixtureChildBinding fixture))
                  , bootstrapProjectionChildRecovery =
                      Just (newChildRecoveryState (fixtureChildBinding fixture))
                  }
          bootstrapProjectionInvariantViolations rootAndChild
            `shouldContain` [BootstrapProjectionConcurrentRootAndChildAuthority]
          bootstrapProjectionInvariantViolations bothChildren
            `shouldContain` [BootstrapProjectionConcurrentChildMutations]
          planBootstrapProjection bothChildren `shouldSatisfy` isInvalidProjectionPlan

    it "refuses to arm or accept handoff before unseal, baseline, and provisioner login" $
      withFixture $ \fixture ->
        withProjectionParts fixture $ \parts -> do
          let handoffPendingBeforePrerequisites =
                (partsRootCompleteSealed parts)
                  { bootstrapProjectionHandoff = partsHandoffPending parts
                  }
              violations =
                bootstrapProjectionInvariantViolations
                  handoffPendingBeforePrerequisites
          violations `shouldContain` [BootstrapProjectionHandoffBeforeUnseal]
          violations `shouldContain` [BootstrapProjectionHandoffBeforeBaseline]
          violations
            `shouldContain` [BootstrapProjectionHandoffBeforeProvisionerLogin]

data ProjectionParts = ProjectionParts
  { partsRootCompleteSealed :: !BootstrapProjection
  , partsRootCompleteUnsealed :: !BootstrapProjection
  , partsSealUnsealed :: !VaultSealState
  , partsRootSessionInitial :: !RootSessionState
  , partsRootSessionComplete :: !RootSessionState
  , partsRootCompletion :: !RootSessionCompletion
  , partsProvisionerInitial :: !ProvisionerSessionState
  , partsProvisionerLoggedIn :: !ProvisionerSessionState
  , partsHandoffPending :: !PostUnsealHandoffState
  , partsCompleteProjection :: !BootstrapProjection
  }

withProjectionParts :: Fixture -> (ProjectionParts -> Expectation) -> Expectation
withProjectionParts fixture assertion =
  case buildProjectionParts fixture of
    Left err -> expectationFailure ("invalid product-projection fixture: " ++ err)
    Right parts -> assertion parts

buildProjectionParts :: Fixture -> Either String ProjectionParts
buildProjectionParts fixture = do
  rootStates <- first show (rootInitPrefixes fixture)
  rootSessionStates <- first show (rootSessionPrefixes fixture)
  rootSessionInitial <- firstValue "root-session prefix" rootSessionStates
  let rootComplete = last rootStates
      rootSessionCompleteState = last rootSessionStates
  completion <-
    maybe
      (Left "root session did not expose completion evidence")
      Right
      (rootSessionCompletion rootSessionCompleteState)
  let generation =
        rootInitStorageGeneration (rootInitStateBinding rootComplete)
      sealInitial = newVaultSealState generation
  sealSealed <-
    first
      show
      (observeVaultSeal sealInitial (ObserveVaultInitializedSealed generation))
  sealUnsealed <-
    first
      show
      (observeVaultSeal sealSealed (ObserveVaultInitializedUnsealed generation))
  rootCompleteSealed <-
    first show (mkBootstrapProjection rootComplete sealSealed)
  rootCompleteUnsealed <-
    first show (mkBootstrapProjection rootComplete sealUnsealed)
  let provisionerInitial = newProvisionerSessionState completion
  provisionerPending <-
    first
      show
      (applyProvisionerSessionCommand provisionerInitial ArmProvisionerLogin)
  provisionerLoggedIn <-
    first
      show
      ( applyProvisionerSessionCommand
          provisionerPending
          (ConfirmProvisionerLogin (fixtureProvisionerLogin fixture))
      )
  let handoffInitial = newPostUnsealHandoffState generation
  handoffPending <-
    first
      show
      ( applyPostUnsealHandoffCommand
          handoffInitial
          ArmPostUnsealHandoffObservation
      )
  handoffObserved <-
    first
      show
      ( applyPostUnsealHandoffCommand
          handoffPending
          (ConfirmPostUnsealHandoffObserved (fixtureHandoffReceipt fixture))
      )
  let completeProjection =
        rootCompleteUnsealed
          { bootstrapProjectionRootSession = Just rootSessionCompleteState
          , bootstrapProjectionProvisioner = Just provisionerLoggedIn
          , bootstrapProjectionHandoff = handoffObserved
          }
  pure
    ProjectionParts
      { partsRootCompleteSealed = rootCompleteSealed
      , partsRootCompleteUnsealed = rootCompleteUnsealed
      , partsSealUnsealed = sealUnsealed
      , partsRootSessionInitial = rootSessionInitial
      , partsRootSessionComplete = rootSessionCompleteState
      , partsRootCompletion = completion
      , partsProvisionerInitial = provisionerInitial
      , partsProvisionerLoggedIn = provisionerLoggedIn
      , partsHandoffPending = handoffPending
      , partsCompleteProjection = completeProjection
      }

isInvalidProjectionPlan :: BootstrapProjectionPlan -> Bool
isInvalidProjectionPlan plan =
  case plan of
    BootstrapProjectionPlanInvalid _ -> True
    _ -> False
