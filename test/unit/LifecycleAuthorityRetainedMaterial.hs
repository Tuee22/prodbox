{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthorityRetainedMaterial
  ( lifecycleAuthorityRetainedMaterialSuite
  )
where

import Data.ByteString qualified as ByteString
import Data.Either (isLeft)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.RetainedMaterialDeliveryCoordinator
  ( RetainedMaterialDeliveryRequest (..)
  , coordinateRetainedMaterialDelivery
  , ensureRetainedMaterialCurrentSource
  )
import Prodbox.ControlPlane.RetainedMaterialDeliveryProduction
  ( retainedTargetIntentReceiptDigest
  )
import Prodbox.ControlPlane.RetainedMaterialRepository
  ( RetainedMaterialRepository (..)
  , RetainedMaterialSnapshot (..)
  , applyRetainedMaterialCommand
  )
import Prodbox.ControlPlane.TargetIntentAuthority
  ( TargetIntentIssueRequest (..)
  )
import Prodbox.ControlPlane.TargetIntentAuthorityProduction
  ( selectRetainedAcmeEabDeliveryIntent
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId (TargetAcmeEab)
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( mkTargetAgentIdentity
  )
import Prodbox.Lifecycle.Authority.RetainedMaterial
import Prodbox.Lifecycle.CheckpointAuthority
  ( mkLongLivedCheckpointAuthority
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  , mkCredentialGeneration
  , mkTargetValueDigest
  , targetValueDigestText
  )
import TestSupport

lifecycleAuthorityRetainedMaterialSuite :: SuiteBuilder ()
lifecycleAuthorityRetainedMaterialSuite =
  describe "Sprint 4.50 retained operator-material custody" $ do
    it "constructs only retained custody and cross-cluster delivery coordinates" $ do
      let authority =
            must
              ( mkLongLivedCheckpointAuthority
                  "home"
                  "authority-state"
                  "control-plane"
                  "transit"
              )
          target =
            must
              (mkRetainedMaterialTarget SRetainedAcmeEabMaterial "aws-run")
          smtpTarget =
            must
              (mkRetainedMaterialTarget SRetainedSesSmtpMaterial "home")
          smtp = must (retainedCustodyCoordinate authority SRetainedSesSmtpMaterial)
          eab = must (retainedCustodyCoordinate authority SRetainedAcmeEabMaterial)
          outbox =
            must
              ( retainedDeliveryOutboxCoordinate
                  authority
                  SRetainedAcmeEabMaterial
                  target
              )
      retainedMaterialCoordinateLogicalName smtp
        `shouldBe` "retained-material/custody/ses-smtp-source"
      retainedMaterialCoordinateLogicalName eab
        `shouldBe` "retained-material/custody/acme-eab-source"
      retainedMaterialCoordinateLogicalName outbox
        `shouldBe` "retained-material/delivery/acme-eab-source/aws-run"
      retainedMaterialTargetSecretPath target `shouldBe` "secret/acme/eab"
      retainedMaterialTargetSecretPath smtpTarget `shouldBe` "secret/keycloak/smtp"

    it "projects the prepared custody-receipt digest without substituting worker material" $ do
      let exactAttestation = ref (targetValueDigestText digestA)
          exactDelivery =
            mkRetainedDeliveryIntent
              deliveryOperation1
              sourceReceipt1
              target1
              generation1
              exactAttestation
              digestB
              deadline
      retainedTargetIntentReceiptDigest exactDelivery `shouldBe` Right digestA
      retainedTargetIntentReceiptDigest delivery1 `shouldSatisfy` isLeft

    it "recovers the Target-intent deadline from the exact pending delivery successor" $ do
      let agent =
            must
              ( mkTargetAgentIdentity
                  ("home@sha256:" <> hexDigest 'f')
              )
          request =
            TargetIntentIssueRequest
              { targetIntentIssueTarget = TargetAcmeEab
              , targetIntentIssueExpectedAgentIdentity = agent
              , targetIntentIssueExpectedGeneration = generation1
              , targetIntentIssueExpectedReceiptDigest = digestA
              , targetIntentIssueOperationId = "delivery-op-1"
              , targetIntentIssueActionIndex = 0
              , targetIntentIssueIdempotencyKey = "delivery-op-1"
              }
          freshDeadline = authorityTimeFromMicros 9000
          delivery =
            mkRetainedDeliveryIntent
              deliveryOperation1
              sourceReceipt1
              target1
              generation1
              (ref (targetValueDigestText digestA))
              digestB
              freshDeadline
      fmap
        retainedDeliveryDeadline
        ( selectRetainedAcmeEabDeliveryIntent
            agent
            request
            sourceReceipt1
            [delivery]
        )
        `shouldBe` Right freshDeadline
      selectRetainedAcmeEabDeliveryIntent
        agent
        request
        sourceReceipt2
        [delivery]
        `shouldSatisfy` isLeft
      selectRetainedAcmeEabDeliveryIntent
        agent
        request
        sourceReceipt1
        []
        `shouldSatisfy` isLeft

    it "commits one exact generation and makes response-loss replay idempotent" $ do
      let (begin, begun) =
            stepRetainedMaterial
              initialRetainedMaterialAggregate
              (BeginRetainedMaterialSeal now seal1)
      begin `shouldBe` RetainedSealBegun seal1
      decideRetainedMaterial begun (BeginRetainedMaterialSeal now seal1)
        `shouldBe` RetainedSealAlreadyBegun seal1
      let (committed, current) =
            stepRetainedMaterial begun (ObserveRetainedMaterialSeal source1)
      committed `shouldBe` RetainedSealCommitted source1 Nothing grace1
      retainedMaterialCurrent current `shouldBe` Just source1
      retainedMaterialPendingSeal current `shouldBe` Nothing
      decideRetainedMaterial current (ObserveRetainedMaterialSeal source1)
        `shouldBe` RetainedSealAlreadyCommitted source1
      retainedMaterialInvariantViolations current `shouldBe` []

    it "accepts delivery only from an exact present current custody receipt" $ do
      let current = committedSource seal1 source1 initialRetainedMaterialAggregate
          refused expected observation =
            decideRetainedMaterial
              current
              (BeginRetainedMaterialDelivery observation now delivery1)
              `shouldBe` RetainedMaterialRefused expected
      refused RetainedDeliveryCustodyAbsent (RetainedCustodyPositivelyAbsent absenceRef)
      refused RetainedDeliveryCustodyCorrupt (RetainedCustodyCorrupt "bad envelope")
      refused
        RetainedDeliveryCustodyDigestMismatch
        (RetainedCustodyDigestMismatch digestA digestB)
      refused RetainedDeliveryCustodyUnobservable (RetainedCustodyUnobservable "Vault unavailable")
      refused
        RetainedDeliverySourceMismatch
        (RetainedCustodyPresent source2)
      decideRetainedMaterial
        current
        (BeginRetainedMaterialDelivery (RetainedCustodyPresent source1) now delivery1)
        `shouldBe` RetainedDeliveryBegun delivery1

    it "treats a later metadata observation time as the same retained source identity" $ do
      let current = committedSource seal1 source1 initialRetainedMaterialAggregate
          reobserved =
            must
              ( mkRetainedMaterialSource
                  generation1
                  operation1
                  sourceReceipt1
                  digestA
                  commitment1
                  1
                  (authorityTimeFromMicros 150)
              )
      decideRetainedMaterial
        current
        (BeginRetainedMaterialDelivery (RetainedCustodyPresent reobserved) now delivery1)
        `shouldBe` RetainedDeliveryBegun delivery1

    it "commits target read-back once and refuses a same-operation mismatch" $ do
      let current = committedSource seal1 source1 initialRetainedMaterialAggregate
          (_, pending) =
            stepRetainedMaterial
              current
              (BeginRetainedMaterialDelivery (RetainedCustodyPresent source1) now delivery1)
      decideRetainedMaterial pending (ObserveRetainedMaterialDelivery mismatchedDeliveryReceipt)
        `shouldBe` RetainedMaterialRefused RetainedDeliveryReceiptMismatch
      let (decision, completed) =
            stepRetainedMaterial pending (ObserveRetainedMaterialDelivery deliveryReceipt1)
      decision `shouldBe` RetainedDeliveryCommitted deliveryReceipt1
      retainedMaterialPendingDeliveries completed `shouldBe` []
      retainedMaterialCompletedDeliveries completed `shouldBe` [deliveryReceipt1]
      decideRetainedMaterial
        completed
        (BeginRetainedMaterialDelivery (RetainedCustodyPresent source1) now delivery1)
        `shouldBe` RetainedDeliveryAlreadyCompleted deliveryReceipt1

    it "expires only a pending delivery strictly after its absolute deadline" $ do
      let current = committedSource seal1 source1 initialRetainedMaterialAggregate
          (_, pending) =
            stepRetainedMaterial
              current
              (BeginRetainedMaterialDelivery (RetainedCustodyPresent source1) now delivery1)
      decideRetainedMaterial
        pending
        (ExpireRetainedMaterialDelivery deliveryOperation1 deadline)
        `shouldBe` RetainedMaterialRefused RetainedDeliveryExpiryActive
      let (expired, cleared) =
            stepRetainedMaterial
              pending
              (ExpireRetainedMaterialDelivery deliveryOperation1 afterDeadline)
      expired `shouldBe` RetainedDeliveryExpired deliveryOperation1
      retainedMaterialPendingDeliveries cleared `shouldBe` []
      decideRetainedMaterial
        cleared
        (ExpireRetainedMaterialDelivery deliveryOperation1 afterDeadline)
        `shouldBe` RetainedMaterialRefused RetainedDeliveryExpiryNotPending

    it "atomically replaces an expired delivery with its exact deterministic successor" $ do
      let current = committedSource seal1 source1 initialRetainedMaterialAggregate
          (_, pending) =
            stepRetainedMaterial
              current
              (BeginRetainedMaterialDelivery (RetainedCustodyPresent source1) now delivery1)
      decideRetainedMaterial
        pending
        (ReplaceExpiredRetainedMaterialDelivery deliveryOperation1 deadline deliverySuccessor1)
        `shouldBe` RetainedMaterialRefused RetainedDeliveryExpiryActive
      decideRetainedMaterial
        pending
        (ReplaceExpiredRetainedMaterialDelivery deliveryOperation1 afterDeadline delivery1)
        `shouldBe` RetainedMaterialRefused RetainedDeliverySuccessorMismatch
      let (replaced, successorPending) =
            stepRetainedMaterial
              pending
              ( ReplaceExpiredRetainedMaterialDelivery
                  deliveryOperation1
                  afterDeadline
                  deliverySuccessor1
              )
      replaced `shouldBe` RetainedDeliveryReplaced deliveryOperation1 deliverySuccessor1
      retainedMaterialPendingDeliveries successorPending `shouldBe` [deliverySuccessor1]
      decideRetainedMaterial
        successorPending
        ( ReplaceExpiredRetainedMaterialDelivery
            deliveryOperation1
            afterDeadline
            deliverySuccessor1
        )
        `shouldBe` RetainedDeliveryAlreadyReplaced deliverySuccessor1

    it "coordinates one successor and resumes it without rerunning the expired effect" $ do
      let current = committedSource seal1 source1 initialRetainedMaterialAggregate
          (_, pending) =
            stepRetainedMaterial
              current
              (BeginRetainedMaterialDelivery (RetainedCustodyPresent source1) now delivery1)
      state <- newIORef (0 :: Int, pending)
      runs <- newIORef (0 :: Int)
      let repository = ioRefRepository state
          request =
            RetainedMaterialDeliveryRequest
              { retainedDeliveryRequestOperationId = deliveryOperation1
              , retainedDeliveryRequestTarget = target1
              , retainedDeliveryRequestGeneration = generation1
              , retainedDeliveryRequestAttestationRef = attestation1
              , retainedDeliveryRequestDeadline = deadline
              }
          observe _ = pure (Right Nothing)
          run _ _ = modifyIORef' runs (+ 1) >> pure (Left "stop-after-successor")
      coordinateRetainedMaterialDelivery
        repository
        afterDeadline
        source1
        request
        observe
        run
        `shouldReturn` Left "stop-after-successor"
      (_, successorPending) <- readIORef state
      case retainedMaterialPendingDeliveries successorPending of
        [successor] -> do
          retainedDeliveryOperationId successor
            `shouldBe` retainedDeliverySuccessorOperationId deliveryOperation1
          retainedDeliveryDeadline successor
            `shouldBe` authorityTimeFromMicros (201 + 5 * 60 * 1000000)
        other -> expectationFailure ("expected one successor, got " ++ show other)
      readIORef runs `shouldReturn` 1
      coordinateRetainedMaterialDelivery
        repository
        afterDeadline
        source1
        request
        observe
        run
        `shouldReturn` Left "retained delivery remains pending until its absolute deadline"
      readIORef runs `shouldReturn` 1

    it "executes the exact successor after recovering an applied replacement response loss" $ do
      let current = committedSource seal1 source1 initialRetainedMaterialAggregate
          (_, pending) =
            stepRetainedMaterial
              current
              (BeginRetainedMaterialDelivery (RetainedCustodyPresent source1) now delivery1)
      state <- newIORef (0 :: Int, pending)
      loseWriteResponse <- newIORef True
      runs <- newIORef (0 :: Int)
      let repository =
            (ioRefRepository state)
              { compareAndSwapRetainedMaterial = \expected aggregate -> do
                  (revision, _) <- readIORef state
                  if expected /= Just revision
                    then pure (Left "conflict")
                    else do
                      writeIORef state (revision + 1, aggregate)
                      lose <- readIORef loseWriteResponse
                      writeIORef loseWriteResponse False
                      pure (if lose then Left "replacement response lost" else Right ())
              }
          request =
            RetainedMaterialDeliveryRequest
              { retainedDeliveryRequestOperationId = deliveryOperation1
              , retainedDeliveryRequestTarget = target1
              , retainedDeliveryRequestGeneration = generation1
              , retainedDeliveryRequestAttestationRef = attestation1
              , retainedDeliveryRequestDeadline = deadline
              }
      coordinateRetainedMaterialDelivery
        repository
        afterDeadline
        source1
        request
        (\_ -> pure (Right Nothing))
        (\_ _ -> modifyIORef' runs (+ 1) >> pure (Left "stop-after-recovered-successor"))
        `shouldReturn` Left "stop-after-recovered-successor"
      readIORef runs `shouldReturn` 1
      (_, successorPending) <- readIORef state
      fmap retainedDeliveryOperationId (retainedMaterialPendingDeliveries successorPending)
        `shouldBe` [retainedDeliverySuccessorOperationId deliveryOperation1]

    it "corrects only the exact legacy source receipt and replays the correction" $ do
      let legacyCurrent =
            committedSource legacySeal1 legacySource1 initialRetainedMaterialAggregate
          (corrected, current) =
            stepRetainedMaterial
              legacyCurrent
              (ObserveLegacyRetainedMaterialSourceReceiptCorrection source1)
      corrected `shouldBe` RetainedLegacySourceReceiptCorrected legacySource1 source1
      retainedMaterialCurrent current `shouldBe` Just source1
      decideRetainedMaterial
        current
        (ObserveLegacyRetainedMaterialSourceReceiptCorrection source1)
        `shouldBe` RetainedLegacySourceReceiptAlreadyCorrected source1
      decideRetainedMaterial
        legacyCurrent
        (ObserveLegacyRetainedMaterialSourceReceiptCorrection source2)
        `shouldBe` RetainedMaterialRefused RetainedLegacySourceReceiptCorrectionMismatch
      let (_, legacyPending) =
            stepRetainedMaterial
              legacyCurrent
              (BeginRetainedMaterialDelivery (RetainedCustodyPresent legacySource1) now legacyDelivery1)
          (_, legacyCompleted) =
            stepRetainedMaterial legacyPending (ObserveRetainedMaterialDelivery legacyDeliveryReceipt1)
      decideRetainedMaterial
        legacyCompleted
        (ObserveLegacyRetainedMaterialSourceReceiptCorrection source1)
        `shouldBe` RetainedMaterialRefused RetainedLegacySourceReceiptCorrectionHasCompletedDelivery

    it "recovers a lost legacy correction response and succeeds the expired delivery once" $ do
      let legacyCurrent =
            committedSource legacySeal1 legacySource1 initialRetainedMaterialAggregate
          (_, legacyPending) =
            stepRetainedMaterial
              legacyCurrent
              (BeginRetainedMaterialDelivery (RetainedCustodyPresent legacySource1) now legacyDelivery1)
      state <- newIORef (0 :: Int, legacyPending)
      loseCorrectionResponse <- newIORef True
      runs <- newIORef (0 :: Int)
      let repository =
            (ioRefRepository state)
              { compareAndSwapRetainedMaterial = \expected aggregate -> do
                  (revision, _) <- readIORef state
                  if expected /= Just revision
                    then pure (Left "conflict")
                    else do
                      writeIORef state (revision + 1, aggregate)
                      lose <- readIORef loseCorrectionResponse
                      writeIORef loseCorrectionResponse False
                      pure (if lose then Left "correction response lost" else Right ())
              }
          request =
            RetainedMaterialDeliveryRequest
              { retainedDeliveryRequestOperationId = deliveryOperation1
              , retainedDeliveryRequestTarget = target1
              , retainedDeliveryRequestGeneration = generation1
              , retainedDeliveryRequestAttestationRef = attestation1
              , retainedDeliveryRequestDeadline = deadline
              }
          run _ _ = modifyIORef' runs (+ 1) >> pure (Left "stop-after-corrected-successor")
      coordinateRetainedMaterialDelivery
        repository
        afterDeadline
        source1
        request
        (\_ -> pure (Right Nothing))
        run
        `shouldReturn` Left "stop-after-corrected-successor"
      (_, successorPending) <- readIORef state
      retainedMaterialCurrent successorPending `shouldBe` Just source1
      case retainedMaterialPendingDeliveries successorPending of
        [successor] -> do
          retainedDeliveryOperationId successor
            `shouldBe` retainedDeliverySuccessorOperationId deliveryOperation1
          retainedDeliverySourceReceipt successor `shouldBe` sourceReceipt1
        other -> expectationFailure ("expected one corrected successor, got " ++ show other)
      readIORef runs `shouldReturn` 1
      coordinateRetainedMaterialDelivery
        repository
        afterDeadline
        source1
        request
        (\_ -> pure (Right Nothing))
        run
        `shouldReturn` Left "retained delivery remains pending until its absolute deadline"
      readIORef runs `shouldReturn` 1

    it "retains a rotated predecessor through grace and pending delivery recovery" $ do
      let current1 = committedSource seal1 source1 initialRetainedMaterialAggregate
          (_, deliveryPending) =
            stepRetainedMaterial
              current1
              (BeginRetainedMaterialDelivery (RetainedCustodyPresent source1) now delivery1)
          current2 = committedSource seal2 source2 deliveryPending
      retainedMaterialCurrent current2 `shouldBe` Just source2
      retainedMaterialSuperseded current2 `shouldBe` [source1]
      decideRetainedMaterial
        current2
        (BeginSupersededMaterialRetirement sourceReceipt1 beforeGrace2)
        `shouldBe` RetainedMaterialRefused RetainedSupersededGraceActive
      decideRetainedMaterial
        current2
        (BeginSupersededMaterialRetirement sourceReceipt1 afterGrace2)
        `shouldBe` RetainedMaterialRefused RetainedSupersededHasDependants
      let (_, deliveryComplete) =
            stepRetainedMaterial current2 (ObserveRetainedMaterialDelivery deliveryReceipt1)
          (retirement, retirementPending) =
            stepRetainedMaterial
              deliveryComplete
              (BeginSupersededMaterialRetirement sourceReceipt1 afterGrace2)
      retirement `shouldBe` RetainedSupersededRetirementBegun sourceReceipt1
      let (retired, finalState) =
            stepRetainedMaterial
              retirementPending
              (ObserveSupersededMaterialAbsence sourceReceipt1 absenceRef)
      retired `shouldBe` RetainedSupersededRetired sourceReceipt1 absenceRef
      retainedMaterialSuperseded finalState `shouldBe` []
      retainedMaterialCurrent finalState `shouldBe` Just source2

    it "refuses expired work and non-successor seal generations" $ do
      decideRetainedMaterial
        initialRetainedMaterialAggregate
        (BeginRetainedMaterialSeal afterDeadline seal1)
        `shouldBe` RetainedMaterialRefused RetainedSealDeadlineExpired
      decideRetainedMaterial
        initialRetainedMaterialAggregate
        (BeginRetainedMaterialSeal now seal2)
        `shouldBe` RetainedMaterialRefused RetainedSealGenerationNotNext
      let current = committedSource seal1 source1 initialRetainedMaterialAggregate
      decideRetainedMaterial
        current
        (BeginRetainedMaterialDelivery (RetainedCustodyPresent source1) afterDeadline delivery1)
        `shouldBe` RetainedMaterialRefused RetainedDeliveryDeadlineExpired

    it "round-trips durable state canonically and rejects a cross-schema decode" $ do
      let current1 = committedSource seal1 source1 initialRetainedMaterialAggregate
          (_, pending) =
            stepRetainedMaterial
              current1
              (BeginRetainedMaterialDelivery (RetainedCustodyPresent source1) now delivery1)
          aggregate = committedSource seal2 source2 pending
          encoded =
            must
              ( encodeRetainedMaterialAggregate
                  SRetainedAcmeEabMaterial
                  aggregate
              )
      decodeRetainedMaterialAggregate SRetainedAcmeEabMaterial encoded
        `shouldBe` Right aggregate
      decodeRetainedMaterialAggregate SRetainedSesSmtpMaterial encoded
        `shouldBe` Left (RetainedMaterialCodecSchemaMismatch 0 1)
      decodeRetainedMaterialAggregate
        SRetainedAcmeEabMaterial
        (ByteString.replicate (retainedMaterialMaximumEncodedBytes + 1) 0)
        `shouldBe` Left
          ( RetainedMaterialCodecTooLarge
              (retainedMaterialMaximumEncodedBytes + 1)
              retainedMaterialMaximumEncodedBytes
          )

    it "persists an accepted aggregate transition once and performs no CAS for replay" $ do
      state <- newIORef (0 :: Int, initialRetainedMaterialAggregate)
      writes <- newIORef (0 :: Int)
      let repository =
            RetainedMaterialRepository
              { readRetainedMaterialSnapshot = do
                  (revision, aggregate) <- readIORef state
                  pure (Right (RetainedMaterialSnapshot (Just revision) aggregate))
              , compareAndSwapRetainedMaterial = \expected aggregate -> do
                  (revision, _) <- readIORef state
                  if expected == Just revision
                    then do
                      writeIORef state (revision + 1, aggregate)
                      modifyIORef' writes (+ 1)
                      pure (Right ())
                    else pure (Left "conflict")
              }
      applyRetainedMaterialCommand repository (BeginRetainedMaterialSeal now seal1)
        `shouldReturn` Right (RetainedSealBegun seal1)
      applyRetainedMaterialCommand repository (BeginRetainedMaterialSeal now seal1)
        `shouldReturn` Right (RetainedSealAlreadyBegun seal1)
      readIORef writes `shouldReturn` 1

    it "rotates the source catalog under a fresh deadline after the ingress deadline expired" $ do
      state <- newIORef (0 :: Int, committedSource seal1 source1 initialRetainedMaterialAggregate)
      let repository =
            RetainedMaterialRepository
              { readRetainedMaterialSnapshot = do
                  (revision, aggregate) <- readIORef state
                  pure (Right (RetainedMaterialSnapshot (Just revision) aggregate))
              , compareAndSwapRetainedMaterial = \expected aggregate -> do
                  (revision, _) <- readIORef state
                  if expected == Just revision
                    then writeIORef state (revision + 1, aggregate) >> pure (Right ())
                    else pure (Left "conflict")
              }
      ensureRetainedMaterialCurrentSource repository afterDeadline source2
        `shouldReturn` Right ()
      (_, aggregate) <- readIORef state
      retainedMaterialCurrent aggregate `shouldBe` Just source2

committedSource
  :: RetainedSealIntent schema
  -> RetainedMaterialSource schema
  -> RetainedMaterialAggregate schema
  -> RetainedMaterialAggregate schema
committedSource intent source aggregate =
  let (_, begun) =
        stepRetainedMaterial aggregate (BeginRetainedMaterialSeal now intent)
      (_, committed) =
        stepRetainedMaterial begun (ObserveRetainedMaterialSeal source)
   in committed

ioRefRepository
  :: IORef (Int, RetainedMaterialAggregate schema)
  -> RetainedMaterialRepository schema IO Int
ioRefRepository state =
  RetainedMaterialRepository
    { readRetainedMaterialSnapshot = do
        (revision, aggregate) <- readIORef state
        pure (Right (RetainedMaterialSnapshot (Just revision) aggregate))
    , compareAndSwapRetainedMaterial = \expected aggregate -> do
        (revision, _) <- readIORef state
        if expected == Just revision
          then writeIORef state (revision + 1, aggregate) >> pure (Right ())
          else pure (Left "conflict")
    }

seal1 :: RetainedSealIntent 'RetainedAcmeEabMaterial
seal1 =
  must
    ( mkRetainedSealIntent
        operation1
        generation1
        permit1
        digestA
        deadline
        grace1
    )

seal2 :: RetainedSealIntent 'RetainedAcmeEabMaterial
seal2 =
  must
    ( mkRetainedSealIntent
        operation2
        generation2
        permit2
        digestB
        deadline
        grace2
    )

legacySeal1 :: RetainedSealIntent 'RetainedAcmeEabMaterial
legacySeal1 =
  must
    ( mkRetainedSealIntent
        operation1
        generation1
        operation1
        digestA
        deadline
        grace1
    )

source1 :: RetainedMaterialSource 'RetainedAcmeEabMaterial
source1 =
  must
    ( mkRetainedMaterialSource
        generation1
        operation1
        sourceReceipt1
        digestA
        commitment1
        1
        now
    )

source2 :: RetainedMaterialSource 'RetainedAcmeEabMaterial
source2 =
  must
    ( mkRetainedMaterialSource
        generation2
        operation2
        sourceReceipt2
        digestB
        commitment2
        2
        now
    )

legacySource1 :: RetainedMaterialSource 'RetainedAcmeEabMaterial
legacySource1 =
  must
    ( mkRetainedMaterialSource
        generation1
        operation1
        operation1
        digestA
        commitment1
        1
        now
    )

delivery1 :: RetainedDeliveryIntent 'RetainedAcmeEabMaterial
delivery1 =
  mkRetainedDeliveryIntent
    deliveryOperation1
    sourceReceipt1
    target1
    generation1
    attestation1
    digestC
    deadline

legacyDelivery1 :: RetainedDeliveryIntent 'RetainedAcmeEabMaterial
legacyDelivery1 =
  mkRetainedDeliveryIntent
    deliveryOperation1
    operation1
    target1
    generation1
    attestation1
    digestC
    deadline

legacyDeliveryReceipt1 :: RetainedDeliveryReceipt 'RetainedAcmeEabMaterial
legacyDeliveryReceipt1 =
  must
    ( mkRetainedDeliveryReceipt
        deliveryOperation1
        operation1
        target1
        generation1
        9
        targetCommitment1
    )

deliverySuccessor1 :: RetainedDeliveryIntent 'RetainedAcmeEabMaterial
deliverySuccessor1 =
  mkRetainedDeliveryIntent
    (retainedDeliverySuccessorOperationId deliveryOperation1)
    sourceReceipt1
    target1
    generation1
    attestation1
    digestB
    (authorityTimeFromMicros 500)

deliveryReceipt1 :: RetainedDeliveryReceipt 'RetainedAcmeEabMaterial
deliveryReceipt1 =
  must
    ( mkRetainedDeliveryReceipt
        deliveryOperation1
        sourceReceipt1
        target1
        generation1
        9
        targetCommitment1
    )

mismatchedDeliveryReceipt :: RetainedDeliveryReceipt 'RetainedAcmeEabMaterial
mismatchedDeliveryReceipt =
  must
    ( mkRetainedDeliveryReceipt
        deliveryOperation1
        sourceReceipt1
        target2
        generation1
        9
        targetCommitment1
    )

generation1, generation2 :: CredentialGeneration
generation1 = must (mkCredentialGeneration 1)
generation2 = must (mkCredentialGeneration 2)

digestA, digestB, digestC :: TargetValueDigest
digestA = must (mkTargetValueDigest (hexDigest 'a'))
digestB = must (mkTargetValueDigest (hexDigest 'b'))
digestC = must (mkTargetValueDigest (hexDigest 'c'))

operation1, operation2, deliveryOperation1, permit1, permit2 :: RetainedMaterialRef
sourceReceipt1, sourceReceipt2, commitment1, commitment2 :: RetainedMaterialRef
targetCommitment1, attestation1, absenceRef :: RetainedMaterialRef
operation1 = ref "seal-op-1"
operation2 = ref "seal-op-2"
deliveryOperation1 = ref "delivery-op-1"
permit1 = ref "permit-1"
permit2 = ref "permit-2"
sourceReceipt1 = ref "source-receipt-1"
sourceReceipt2 = ref "source-receipt-2"
commitment1 = ref "commitment-1"
commitment2 = ref "commitment-2"
targetCommitment1 = ref "target-commitment-1"
attestation1 = ref "attestation-1"
absenceRef = ref "absence-readback-1"

target1, target2 :: RetainedMaterialTarget 'RetainedAcmeEabMaterial
target1 = must (mkRetainedMaterialTarget SRetainedAcmeEabMaterial "home")
target2 = must (mkRetainedMaterialTarget SRetainedAcmeEabMaterial "aws")

now, deadline, afterDeadline, grace1, grace2, beforeGrace2, afterGrace2 :: AuthorityTime
now = authorityTimeFromMicros 100
deadline = authorityTimeFromMicros 200
afterDeadline = authorityTimeFromMicros 201
grace1 = authorityTimeFromMicros 300
grace2 = authorityTimeFromMicros 400
beforeGrace2 = authorityTimeFromMicros 399
afterGrace2 = authorityTimeFromMicros 401

ref :: Text -> RetainedMaterialRef
ref value = must (mkRetainedMaterialRef value)

hexDigest :: Char -> Text
hexDigest character = Text.replicate 64 (Text.singleton character)

must :: (Show error) => Either error value -> value
must result = case result of
  Left err -> error (show err)
  Right value -> value
