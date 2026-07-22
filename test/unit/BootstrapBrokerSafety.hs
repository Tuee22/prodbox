{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Focused exhaustive tables for the durable Bootstrap fence and the
-- attested, one-shot secret-worker protocol.
module BootstrapBrokerSafety
  ( bootstrapBrokerSafetySuite
  )
where

import Control.Monad (forM_)
import Data.Either (isLeft, isRight)
import Data.Functor.Identity (Identity (..))
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Fence
import Prodbox.Bootstrap.Broker.Program (BootstrapMutationReceipt (..))
import Prodbox.Bootstrap.Broker.Request
  ( RequestDigest
  , mkRequestDigest
  )
import Prodbox.Bootstrap.Broker.SecretWorker
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , VaultStorageGeneration
  , mkArtifactDigest
  , mkVaultStorageGeneration
  )
import Prodbox.ControlPlane.AuthorityClock
  ( AuthorityClockObservation (..)
  , ClockFailure (..)
  , clockUncertaintyFromMicros
  , operationDeadlineFromMicros
  , operationDeadlineMicros
  )
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , MonotonicInstant
  , deadlineFromInstant
  , deadlineInstant
  , monotonicInstantFromMicros
  , monotonicInstantMicros
  )
import Prodbox.Lifecycle.Lease
  ( OwnerNonce
  , authorityTimeFromMicros
  , mkOwnerNonce
  )
import TestSupport

bootstrapBrokerSafetySuite :: SuiteBuilder ()
bootstrapBrokerSafetySuite = do
  durableFenceSuite
  secretWorkerSuite

durableFenceSuite :: SuiteBuilder ()
durableFenceSuite =
  describe "Sprint 2.33 durable BootstrapSessionFence" $ do
    it "allocates exactly floor + 1 only from an observed vacant CAS record" $ do
      let request = acquireRequestFor canonicalFence
      case decideBootstrapFenceAcquire monoNow requestDeadline trustedNow request (BootstrapFenceStoreVacant 7) of
        BootstrapFenceAcquireCas plan -> do
          fenceCasExpectedGenerationFloor plan `shouldBe` 7
          bootstrapFenceGenerationValue
            (bootstrapFenceGeneration (fenceCasProposedFence plan))
            `shouldBe` 8
          bootstrapFenceOwnerNonce (fenceCasProposedFence plan)
            `shouldBe` canonicalOwner
        decision -> expectationFailure ("expected CAS plan, got " ++ show decision)

    it "confirms exact CAS read-back and response-lost exact conflicts" $ do
      let plan = vacantPlan 7
          proposed = fenceCasProposedFence plan
      confirmBootstrapFenceCas plan (BootstrapFenceCasAppliedReadBack proposed)
        `shouldBe` Right proposed
      confirmBootstrapFenceCas
        plan
        (BootstrapFenceCasConflict (BootstrapFenceStoreHeld proposed))
        `shouldBe` Right proposed

    it "refuses mismatched, conflicting, and unobservable CAS confirmation" $ do
      let plan = vacantPlan 7
      confirmBootstrapFenceCas
        plan
        (BootstrapFenceCasAppliedReadBack alternateOwnerFence)
        `shouldSatisfy` isLeft
      confirmBootstrapFenceCas
        plan
        (BootstrapFenceCasConflict (BootstrapFenceStoreVacant 8))
        `shouldSatisfy` isLeft
      confirmBootstrapFenceCas plan (BootstrapFenceCasUnobservable "store down")
        `shouldSatisfy` isLeft

    it "resumes an exact duplicate without minting a new generation" $
      decideBootstrapFenceAcquire
        monoNow
        requestDeadline
        trustedNow
        (acquireRequestFor canonicalFence)
        (BootstrapFenceStoreHeld canonicalFence)
        `shouldBe` BootstrapFenceAcquireResume canonicalFence

    it "refuses every overlapping owner/action/request/storage/deadline change" $ do
      let changedFences =
            [ alternateOwnerFence
            , fenceAt 1 canonicalOwner alternateAction canonicalRequest canonicalStorage 1_000
            , fenceAt 1 canonicalOwner canonicalAction alternateRequest canonicalStorage 1_000
            , fenceAt 1 canonicalOwner canonicalAction canonicalRequest alternateStorage 1_000
            , fenceAt 1 canonicalOwner canonicalAction canonicalRequest canonicalStorage 1_100
            ]
      forM_ changedFences $ \held ->
        decideBootstrapFenceAcquire
          monoNow
          requestDeadline
          trustedNow
          (acquireRequestFor canonicalFence)
          (BootstrapFenceStoreHeld held)
          `shouldBe` BootstrapFenceAcquireRefused (BootstrapFenceAcquireOverlap held)

    it "never takes over an expired predecessor implicitly" $ do
      let expired =
            fenceAt 1 alternateOwner canonicalAction alternateRequest canonicalStorage 100
      decideBootstrapFenceAcquire
        monoNow
        requestDeadline
        trustedNow
        (acquireRequestFor canonicalFence)
        (BootstrapFenceStoreHeld expired)
        `shouldBe` BootstrapFenceAcquireRefused
          (BootstrapFenceAcquireExpiredPredecessor expired)

    it "retires an expired owner only after exact Lease and cleanup absence, then advances generation" $ do
      let expired =
            fenceAt 1 alternateOwner canonicalAction alternateRequest canonicalStorage 50
          retirement =
            mustRight
              ( decideBootstrapFenceRetire
                  monoNow
                  requestDeadline
                  trustedNow
                  expired
                  BootstrapLeaseMissing
                  (BootstrapFenceOwnerAbsent expired canonicalReceiptDigest)
              )
          vacant = BootstrapFenceStoreVacant 1
      fenceRetireExpectedFence retirement `shouldBe` expired
      fenceRetireVacantGenerationFloor retirement `shouldBe` 1
      confirmBootstrapFenceRetireCas
        retirement
        (BootstrapFenceRetireCasAppliedReadBack vacant)
        `shouldBe` Right vacant
      case decideBootstrapFenceAcquire
        monoNow
        requestDeadline
        trustedNow
        (acquireRequestFor canonicalFence)
        vacant of
        BootstrapFenceAcquireCas plan ->
          bootstrapFenceGenerationValue
            (bootstrapFenceGeneration (fenceCasProposedFence plan))
            `shouldBe` 2
        decision -> expectationFailure ("expected successor CAS plan, got " ++ show decision)

    it "refuses expired-owner retirement without every exact cleanup fact" $ do
      let expired =
            fenceAt 1 alternateOwner canonicalAction alternateRequest canonicalStorage 50
          liveLease =
            BootstrapLeaseObserved
              (bootstrapLeaseBindingForFence expired)
              leaseDeadline
              "expired-owner-rv"
      decideBootstrapFenceRetire
        monoNow
        requestDeadline
        trustedNow
        canonicalFence
        BootstrapLeaseMissing
        (BootstrapFenceOwnerAbsent canonicalFence canonicalReceiptDigest)
        `shouldSatisfy` isLeft
      decideBootstrapFenceRetire
        monoNow
        requestDeadline
        trustedNow
        expired
        liveLease
        (BootstrapFenceOwnerAbsent expired canonicalReceiptDigest)
        `shouldSatisfy` isLeft
      forM_
        [ BootstrapFenceOwnerStillPresent expired
        , BootstrapFenceOwnerAbsent alternateOwnerFence canonicalReceiptDigest
        , BootstrapFenceOwnerCleanupUnobservable "cleanup API down"
        ]
        $ \cleanup ->
          decideBootstrapFenceRetire
            monoNow
            requestDeadline
            trustedNow
            expired
            BootstrapLeaseMissing
            cleanup
            `shouldSatisfy` isLeft

    it "requires an exact vacant-floor read-back for retirement" $ do
      let expired =
            fenceAt 1 alternateOwner canonicalAction alternateRequest canonicalStorage 50
          retirement =
            mustRight
              ( decideBootstrapFenceRetire
                  monoNow
                  requestDeadline
                  trustedNow
                  expired
                  BootstrapLeaseMissing
                  (BootstrapFenceOwnerAbsent expired canonicalReceiptDigest)
              )
      confirmBootstrapFenceRetireCas
        retirement
        (BootstrapFenceRetireCasAppliedReadBack (BootstrapFenceStoreVacant 2))
        `shouldSatisfy` isLeft
      confirmBootstrapFenceRetireCas
        retirement
        (BootstrapFenceRetireCasConflict (BootstrapFenceStoreHeld expired))
        `shouldSatisfy` isLeft
      confirmBootstrapFenceRetireCas
        retirement
        (BootstrapFenceRetireCasUnobservable "store down")
        `shouldSatisfy` isLeft

    it "refuses expired requests and an unobservable durable store" $ do
      decideBootstrapFenceAcquire
        monoNow
        (deadline 10)
        trustedNow
        (acquireRequestFor canonicalFence)
        (BootstrapFenceStoreVacant 0)
        `shouldBe` BootstrapFenceAcquireRefused
          BootstrapFenceAcquireRequestDeadlineExpired
      decideBootstrapFenceAcquire
        monoNow
        requestDeadline
        (trustedAt 1_000)
        (acquireRequestFor canonicalFence)
        (BootstrapFenceStoreVacant 0)
        `shouldSatisfy` acquireRefused
      decideBootstrapFenceAcquire
        monoNow
        requestDeadline
        trustedNow
        (acquireRequestFor canonicalFence)
        (BootstrapFenceStoreUnobservable "store down")
        `shouldBe` BootstrapFenceAcquireRefused
          (BootstrapFenceAcquireStoreUnobservable "store down")

    it "requires a fresh exact Lease binding and non-empty resourceVersion" $ do
      confirmBootstrapLease monoNow canonicalFence exactLease `shouldSatisfy` isRight
      confirmBootstrapLease monoNow canonicalFence BootstrapLeaseMissing
        `shouldBe` Left BootstrapLeaseNotFound
      confirmBootstrapLease
        monoNow
        canonicalFence
        (BootstrapLeaseUnobservable "api down")
        `shouldBe` Left (BootstrapLeaseObservationUnobservable "api down")
      confirmBootstrapLease
        monoNow
        canonicalFence
        (BootstrapLeaseObserved (bootstrapLeaseBindingForFence alternateOwnerFence) leaseDeadline "rv")
        `shouldSatisfy` isLeft
      confirmBootstrapLease
        monoNow
        canonicalFence
        (BootstrapLeaseObserved (bootstrapLeaseBindingForFence canonicalFence) (deadline 10) "rv")
        `shouldBe` Left BootstrapLeaseExpired
      confirmBootstrapLease
        monoNow
        canonicalFence
        (BootstrapLeaseObserved (bootstrapLeaseBindingForFence canonicalFence) leaseDeadline "")
        `shouldBe` Left BootstrapLeaseResourceVersionEmpty

    it "round-trips validated Lease metadata for the Kubernetes interpreter" $ do
      let binding =
            mustRight
              ( reloadBootstrapLeaseBinding
                  1
                  canonicalOwner
                  canonicalAction
                  canonicalRequest
                  canonicalStorage
                  (operationDeadlineFromMicros 1_000)
              )
      binding `shouldBe` bootstrapLeaseBindingForFence canonicalFence
      bootstrapFenceGenerationValue (bootstrapLeaseFenceGeneration binding)
        `shouldBe` 1
      bootstrapLeaseOwnerNonce binding `shouldBe` canonicalOwner
      bootstrapLeaseActionDigest binding `shouldBe` canonicalAction
      bootstrapLeaseRequestDigest binding `shouldBe` canonicalRequest
      bootstrapLeaseStorageGeneration binding `shouldBe` canonicalStorage
      operationDeadlineMicros (bootstrapLeaseOperationDeadline binding) `shouldBe` 1_000
      reloadBootstrapLeaseBinding
        0
        canonicalOwner
        canonicalAction
        canonicalRequest
        canonicalStorage
        (operationDeadlineFromMicros 1_000)
        `shouldSatisfy` isLeft

    it "authorizes the entire closed Vault-effect family after both fresh checks" $
      forM_ ([minBound .. maxBound] :: [BootstrapVaultEffect]) $ \effect -> do
        let result = fencePermitFor canonicalFence effect
        result `shouldSatisfy` isRight
        case result of
          Left refusal -> expectationFailure (show refusal)
          Right permit -> do
            vaultEffectPermitEffect permit `shouldBe` effect
            vaultEffectPermitFenceGeneration permit
              `shouldBe` bootstrapFenceGeneration canonicalFence

    it "authorizes every closed durable-store mutation with the same fresh fence and Lease" $
      forM_ ([minBound .. maxBound] :: [BootstrapStoreMutation]) $ \mutation -> do
        let result =
              authorizeBootstrapStoreMutation
                monoNow
                requestDeadline
                trustedNow
                canonicalFence
                (BootstrapFenceStoreHeld canonicalFence)
                exactLease
                mutation
        result `shouldSatisfy` isRight
        case result of
          Left refusal -> expectationFailure (show refusal)
          Right permit -> do
            storeMutationPermitMutation permit `shouldBe` mutation
            storeMutationPermitFenceGeneration permit
              `shouldBe` bootstrapFenceGeneration canonicalFence

    it "fails closed for missing, stale, or unobservable fence and Lease observations" $ do
      authorizeBootstrapVaultEffect
        monoNow
        requestDeadline
        trustedNow
        canonicalFence
        (BootstrapFenceStoreVacant 1)
        exactLease
        BootstrapVaultInitialize
        `shouldBe` Left (BootstrapFenceUseFenceLost 1)
      authorizeBootstrapVaultEffect
        monoNow
        requestDeadline
        trustedNow
        canonicalFence
        (BootstrapFenceStoreHeld alternateOwnerFence)
        exactLease
        BootstrapVaultInitialize
        `shouldSatisfy` isLeft
      authorizeBootstrapVaultEffect
        monoNow
        requestDeadline
        trustedNow
        canonicalFence
        (BootstrapFenceStoreUnobservable "store down")
        exactLease
        BootstrapVaultInitialize
        `shouldBe` Left (BootstrapFenceUseStoreUnobservable "store down")
      forM_
        [ BootstrapLeaseMissing
        , BootstrapLeaseUnobservable "lease down"
        , BootstrapLeaseObserved
            (bootstrapLeaseBindingForFence alternateOwnerFence)
            leaseDeadline
            "rv"
        , BootstrapLeaseObserved
            (bootstrapLeaseBindingForFence canonicalFence)
            (deadline 10)
            "rv"
        ]
        $ \leaseObservation ->
          authorizeBootstrapVaultEffect
            monoNow
            requestDeadline
            trustedNow
            canonicalFence
            (BootstrapFenceStoreHeld canonicalFence)
            leaseObservation
            BootstrapVaultInitialize
            `shouldSatisfy` isLeft

    it "fails closed for elapsed, regressed, and unobservable authority time" $ do
      let observations =
            [ trustedAt 1_000
            , AuthorityTimeRegressed
                (authorityTimeFromMicros 99)
                (authorityTimeFromMicros 100)
            , AuthorityTimeUnobservable (ClockUnreadable "clock down")
            ]
      forM_ observations $ \clockObservation ->
        authorizeBootstrapVaultEffect
          monoNow
          requestDeadline
          clockObservation
          canonicalFence
          (BootstrapFenceStoreHeld canonicalFence)
          exactLease
          BootstrapVaultInitialize
          `shouldSatisfy` isLeft
      authorizeBootstrapVaultEffect
        monoNow
        (deadline 10)
        trustedNow
        canonicalFence
        (BootstrapFenceStoreHeld canonicalFence)
        exactLease
        BootstrapVaultInitialize
        `shouldBe` Left BootstrapFenceUseRequestDeadlineExpired

    it "reloads the identical absolute deadline and downtime only shrinks a permit" $ do
      let reloaded =
            fenceAt
              (bootstrapFenceGenerationValue (bootstrapFenceGeneration canonicalFence))
              (bootstrapFenceOwnerNonce canonicalFence)
              (bootstrapFenceActionDigest canonicalFence)
              (bootstrapFenceRequestDigest canonicalFence)
              (bootstrapFenceStorageGeneration canonicalFence)
              (operationDeadlineMicros (bootstrapFenceOperationDeadline canonicalFence))
          firstPermit = mustRight (fencePermitAt trustedNow reloaded BootstrapVaultInitialize)
          restartedPermit = mustRight (fencePermitAt (trustedAt 500) reloaded BootstrapVaultInitialize)
      reloaded `shouldBe` canonicalFence
      operationDeadlineMicros (bootstrapFenceOperationDeadline reloaded) `shouldBe` 1_000
      deadlineMicros (vaultEffectPermitDeadline restartedPermit)
        `shouldSatisfy` (< deadlineMicros (vaultEffectPermitDeadline firstPermit))

secretWorkerSuite :: SuiteBuilder ()
secretWorkerSuite =
  describe "Sprint 2.33 attested one-shot Bootstrap secret worker" $ do
    it "validates opaque worker identities and immutable image digests" $ do
      mkWorkerPodUid "" `shouldSatisfy` isLeft
      mkWorkerServiceAccount "bad/account" `shouldSatisfy` isLeft
      mkWorkerSessionId "" `shouldSatisfy` isLeft
      mkWorkerSessionAccessor "" `shouldSatisfy` isLeft
      mkWorkerImageDigest (Text.replicate 64 "a") `shouldSatisfy` isLeft
      mkWorkerImageDigest ("sha256:" <> Text.replicate 64 "a") `shouldSatisfy` isRight

    it "keeps controller metadata secret-free" $ do
      let rendered = show canonicalWorkerRequest
      rendered `shouldNotContain` secretSentinel
      rendered `shouldNotContain` "SecretPayload"
      rendered `shouldNotContain` "ByteString"

    it "attests the exact Pod UID/image/SA/request/fence/deadline binding" $
      attestSecretWorker
        canonicalWorkerRequest
        (SecretWorkerAttestationObserved canonicalAttestation)
        `shouldSatisfy` isRight

    it "refuses missing and unobservable worker attestation" $ do
      attestSecretWorker canonicalWorkerRequest SecretWorkerAttestationMissing
        `shouldBe` Left SecretWorkerAttestationNotFound
      attestSecretWorker
        canonicalWorkerRequest
        (SecretWorkerAttestationUnobservable "pod API down")
        `shouldBe` Left
          (SecretWorkerAttestationObservationUnobservable "pod API down")

    it "refuses every changed attestation field" $ do
      let mismatches =
            [ canonicalAttestation {rawWorkerPodUid = alternatePodUid}
            , canonicalAttestation {rawWorkerImageDigest = alternateImageDigest}
            , canonicalAttestation {rawWorkerServiceAccount = alternateServiceAccount}
            , canonicalAttestation {rawWorkerSessionId = alternateSessionId}
            , canonicalAttestation
                { rawWorkerSessionAccessor = alternateSessionAccessor
                }
            , canonicalAttestation {rawWorkerOperation = SecretWorkerUnseal}
            , canonicalAttestation {rawWorkerFenceGeneration = generation 2}
            , canonicalAttestation {rawWorkerOwnerNonce = alternateOwner}
            , canonicalAttestation {rawWorkerActionDigest = alternateAction}
            , canonicalAttestation {rawWorkerRequestDigest = alternateRequest}
            , canonicalAttestation {rawWorkerStorageGeneration = alternateStorage}
            , canonicalAttestation
                { rawWorkerOperationDeadline = operationDeadlineFromMicros 1_001
                }
            ]
      forM_ mismatches $ \evidence ->
        attestSecretWorker
          canonicalWorkerRequest
          (SecretWorkerAttestationObserved evidence)
          `shouldSatisfy` isLeft

    it "binds a fresh fence permit to every exact worker field" $ do
      let attested = canonicalAttestedWorker
          result =
            authorizeSecretWorkerEffect
              monoNow
              attested
              (mustRight (fencePermitFor canonicalFence BootstrapVaultInitialize))
      result `shouldSatisfy` isRight
      case result of
        Left refusal -> expectationFailure (show refusal)
        Right permit -> do
          secretWorkerEffectPermitOperation permit `shouldBe` SecretWorkerInitialize
          deadlineMicros (secretWorkerEffectPermitDeadline permit) `shouldBe` 800

    it "refuses wrong effect and every changed fence-permit binding" $ do
      let attested = canonicalAttestedWorker
          changedPermits =
            [ mustRight (fencePermitFor canonicalFence BootstrapVaultSubmitUnsealShare)
            , mustRight
                ( fencePermitFor
                    (fenceAt 2 canonicalOwner canonicalAction canonicalRequest canonicalStorage 1_000)
                    BootstrapVaultInitialize
                )
            , mustRight (fencePermitFor alternateOwnerFence BootstrapVaultInitialize)
            , mustRight
                ( fencePermitFor
                    (fenceAt 1 canonicalOwner alternateAction canonicalRequest canonicalStorage 1_000)
                    BootstrapVaultInitialize
                )
            , mustRight
                ( fencePermitFor
                    (fenceAt 1 canonicalOwner canonicalAction alternateRequest canonicalStorage 1_000)
                    BootstrapVaultInitialize
                )
            , mustRight
                ( fencePermitFor
                    (fenceAt 1 canonicalOwner canonicalAction canonicalRequest alternateStorage 1_000)
                    BootstrapVaultInitialize
                )
            , mustRight
                ( fencePermitFor
                    (fenceAt 1 canonicalOwner canonicalAction canonicalRequest canonicalStorage 1_100)
                    BootstrapVaultInitialize
                )
            ]
      forM_ changedPermits $ \permit ->
        authorizeSecretWorkerEffect monoNow attested permit `shouldSatisfy` isLeft
      authorizeSecretWorkerEffect
        (monotonicInstantFromMicros 800)
        attested
        (mustRight (fencePermitFor canonicalFence BootstrapVaultInitialize))
        `shouldBe` Left SecretWorkerEffectDeadlineElapsed

    it "consumes the scoped ingress and accepts the typed outcome for every operation" $
      forM_ receiptTestOperations $ \operation -> do
        let request = workerRequestFor operation canonicalFence
            attested =
              mustRight
                (attestSecretWorker request (SecretWorkerAttestationObserved (attestationFor request)))
            permit =
              mustRight
                ( authorizeSecretWorkerEffect
                    monoNow
                    attested
                    (mustRight (fencePermitFor canonicalFence (effectFor operation)))
                )
            executed = executedWorker permit (receiptFor request (outcomeFor operation))
        captureSecretWorkerReceipt
          executed
          (receiptFor request (outcomeFor operation))
          (durableResultFor operation)
          `shouldSatisfy` isRight

    it "refuses every operation/outcome cross-pair that is not exact" $
      forM_ receiptTestOperations $ \operation -> do
        let request = workerRequestFor operation canonicalFence
            attested =
              mustRight
                (attestSecretWorker request (SecretWorkerAttestationObserved (attestationFor request)))
            permit =
              mustRight
                ( authorizeSecretWorkerEffect
                    monoNow
                    attested
                    (mustRight (fencePermitFor canonicalFence (effectFor operation)))
                )
        forM_ ([minBound .. maxBound] :: [SecretWorkerOutcome]) $ \outcome -> do
          if outcome == outcomeFor operation
            then
              captureSecretWorkerReceipt
                (executedWorker permit (receiptFor request outcome))
                (receiptFor request outcome)
                (durableResultFor operation)
                `shouldSatisfy` isRight
            else
              captureSecretWorkerReceipt
                (executedWorker permit (receiptFor request outcome))
                (receiptFor request outcome)
                (durableResultFor operation)
                `shouldSatisfy` isLeft

    it "refuses every stale raw worker-receipt binding before durability" $ do
      let permit =
            mustRight
              ( authorizeSecretWorkerEffect
                  monoNow
                  canonicalAttestedWorker
                  (mustRight (fencePermitFor canonicalFence BootstrapVaultInitialize))
              )
          receipt = receiptFor canonicalWorkerRequest SecretWorkerInitialized
          mismatches =
            [ receipt {rawWorkerReceiptOperation = SecretWorkerUnseal}
            , receipt {rawWorkerReceiptPodUid = alternatePodUid}
            , receipt {rawWorkerReceiptSessionId = alternateSessionId}
            , receipt {rawWorkerReceiptSessionAccessor = alternateSessionAccessor}
            , receipt {rawWorkerReceiptRequestDigest = alternateRequest}
            , receipt {rawWorkerReceiptStorageGeneration = alternateStorage}
            , receipt {rawWorkerReceiptFenceGeneration = generation 2}
            ]
      forM_ mismatches $ \observed ->
        captureSecretWorkerReceipt
          (executedWorker permit observed)
          observed
          (durableResultFor SecretWorkerInitialize)
          `shouldSatisfy` isLeft

    it "refuses a durable-result constructor from another worker operation" $ do
      let permit =
            mustRight
              ( authorizeSecretWorkerEffect
                  monoNow
                  canonicalAttestedWorker
                  (mustRight (fencePermitFor canonicalFence BootstrapVaultInitialize))
              )
          rawReceipt =
            receiptFor canonicalWorkerRequest SecretWorkerInitialized
      captureSecretWorkerReceipt
        (executedWorker permit rawReceipt)
        rawReceipt
        (durableResultFor SecretWorkerUnseal)
        `shouldBe` Left
          ( SecretWorkerResultOperationMismatch
              SecretWorkerInitialize
              SecretWorkerUnseal
          )

    it "returns a typed receipt containing only bound metadata and a receipt digest" $ do
      let receipt = capturedSecretWorkerReceipt canonicalCapturedWorker
          rendered = show receipt
      secretWorkerReceiptOperation receipt `shouldBe` SecretWorkerInitialize
      secretWorkerReceiptPodUid receipt `shouldBe` canonicalPodUid
      secretWorkerReceiptSessionId receipt `shouldBe` canonicalSessionId
      secretWorkerReceiptSessionAccessor receipt `shouldBe` canonicalSessionAccessor
      secretWorkerReceiptRequestDigest receipt `shouldBe` canonicalRequest
      secretWorkerReceiptStorageGeneration receipt `shouldBe` canonicalStorage
      secretWorkerReceiptFenceGeneration receipt `shouldBe` generation 1
      secretWorkerReceiptOutcome receipt `shouldBe` SecretWorkerInitialized
      secretWorkerReceiptDigest receipt `shouldBe` canonicalReceiptDigest
      rendered `shouldNotContain` secretSentinel

    it "requires revoke, zero exit, delete, and authoritative absence in order" $ do
      let binding = secretWorkerCleanupBinding (capturedSecretWorkerReceipt canonicalCapturedWorker)
          revoked =
            mustRight
              ( confirmSecretWorkerSessionRevoked
                  canonicalCapturedWorker
                  (SecretWorkerSessionRevoked binding)
              )
          exited =
            mustRight
              (confirmSecretWorkerExited revoked (SecretWorkerProcessExited binding 0))
          deleted =
            mustRight
              (confirmSecretWorkerDeleted exited (SecretWorkerPodDeleted binding))
      cleanupWorkerSessionId binding `shouldBe` canonicalSessionId
      cleanupWorkerSessionAccessor binding `shouldBe` canonicalSessionAccessor
      confirmSecretWorkerAbsent deleted (SecretWorkerPodAbsent binding)
        `shouldSatisfy` isRight
      confirmSecretWorkerSessionRevoked
        canonicalCapturedWorker
        (SecretWorkerPodDeleted binding)
        `shouldSatisfy` isLeft
      confirmSecretWorkerExited revoked (SecretWorkerProcessExited binding 9)
        `shouldBe` Left (SecretWorkerCleanupNonZeroExit 9)

    it "refuses stale cleanup identity, phase, and unobservability at every gate" $ do
      let binding = secretWorkerCleanupBinding (capturedSecretWorkerReceipt canonicalCapturedWorker)
          staleBinding = binding {cleanupWorkerPodUid = alternatePodUid}
          revoked =
            mustRight
              ( confirmSecretWorkerSessionRevoked
                  canonicalCapturedWorker
                  (SecretWorkerSessionRevoked binding)
              )
          exited =
            mustRight
              (confirmSecretWorkerExited revoked (SecretWorkerProcessExited binding 0))
          deleted =
            mustRight
              (confirmSecretWorkerDeleted exited (SecretWorkerPodDeleted binding))
      confirmSecretWorkerSessionRevoked
        canonicalCapturedWorker
        (SecretWorkerSessionRevoked staleBinding)
        `shouldSatisfy` isLeft
      confirmSecretWorkerExited revoked (SecretWorkerProcessExited staleBinding 0)
        `shouldSatisfy` isLeft
      confirmSecretWorkerDeleted exited (SecretWorkerPodDeleted staleBinding)
        `shouldSatisfy` isLeft
      confirmSecretWorkerAbsent deleted (SecretWorkerPodAbsent staleBinding)
        `shouldSatisfy` isLeft
      confirmSecretWorkerSessionRevoked
        canonicalCapturedWorker
        (SecretWorkerLifecycleUnobservable "api down")
        `shouldBe` Left (SecretWorkerCleanupObservationUnobservable "api down")

    it "never resumes a pre-receipt ingress after restart, disconnect, or Pod loss"
      $ forM_
        [ SecretWorkerControllerRestarted
        , SecretWorkerClientDisconnected
        , SecretWorkerPodLost
        ]
      $ \interruption ->
        decideSecretWorkerRecovery
          canonicalWorkerRequest
          interruption
          (noSecretWorkerReceipt canonicalWorkerRequest)
          `shouldBe` SecretWorkerRecoveryDestroyAndReprompt
            canonicalWorkerRequest
            interruption

    it "destroys and refuses invalid attestation, fence loss, or deadline expiry"
      $ forM_
        [ SecretWorkerAttestationInvalidated
        , SecretWorkerFenceLost
        , SecretWorkerDeadlineElapsed
        ]
      $ \interruption ->
        decideSecretWorkerRecovery
          canonicalWorkerRequest
          interruption
          (noSecretWorkerReceipt canonicalWorkerRequest)
          `shouldBe` SecretWorkerRecoveryDestroyAndRefuse interruption

    it "resumes only the next cleanup step from every durable receipt checkpoint" $ do
      let receipt = capturedSecretWorkerReceipt canonicalCapturedWorker
          binding = secretWorkerCleanupBinding receipt
          revoked =
            mustRight
              ( confirmSecretWorkerSessionRevoked
                  canonicalCapturedWorker
                  (SecretWorkerSessionRevoked binding)
              )
          exited =
            mustRight
              (confirmSecretWorkerExited revoked (SecretWorkerProcessExited binding 0))
          deleted =
            mustRight
              (confirmSecretWorkerDeleted exited (SecretWorkerPodDeleted binding))
          absent =
            mustRight
              (confirmSecretWorkerAbsent deleted (SecretWorkerPodAbsent binding))
          cases =
            [ (receiptCapturedCheckpoint canonicalCapturedWorker, SecretWorkerRecoveryRevokeSession receipt)
            , (sessionRevokedCheckpoint revoked, SecretWorkerRecoveryAwaitExit receipt)
            , (workerExitedCheckpoint exited, SecretWorkerRecoveryDeletePod receipt)
            , (workerDeletedCheckpoint deleted, SecretWorkerRecoveryObserveAbsence receipt)
            , (workerAbsentCheckpoint absent, SecretWorkerRecoveryComplete receipt)
            ]
      forM_ ([minBound .. maxBound] :: [SecretWorkerInterruption]) $ \interruption ->
        forM_ cases $ \(checkpoint, expected) ->
          decideSecretWorkerRecovery canonicalWorkerRequest interruption checkpoint
            `shouldBe` expected

    it "refuses unobservable or differently bound durable checkpoints" $ do
      decideSecretWorkerRecovery
        canonicalWorkerRequest
        SecretWorkerControllerRestarted
        (unobservableWorkerCheckpoint "store down")
        `shouldBe` SecretWorkerRecoveryRefused
          (SecretWorkerRecoveryCheckpointUnobservable "store down")
      decideSecretWorkerRecovery
        canonicalWorkerRequest
        SecretWorkerControllerRestarted
        (noSecretWorkerReceipt (workerRequestFor SecretWorkerUnseal canonicalFence))
        `shouldBe` SecretWorkerRecoveryRefused SecretWorkerRecoveryRequestMismatch

monoNow :: MonotonicInstant
monoNow = monotonicInstantFromMicros 10

requestDeadline :: Deadline
requestDeadline = deadline 5_000

leaseDeadline :: Deadline
leaseDeadline = deadline 800

deadline :: Natural -> Deadline
deadline = deadlineFromInstant . monotonicInstantFromMicros

deadlineMicros :: Deadline -> Natural
deadlineMicros = monotonicInstantMicros . deadlineInstant

trustedNow :: AuthorityClockObservation
trustedNow = trustedAt 100

trustedAt :: Natural -> AuthorityClockObservation
trustedAt micros =
  AuthorityTimeTrusted
    (authorityTimeFromMicros micros)
    (clockUncertaintyFromMicros 0)

canonicalOwner :: OwnerNonce
canonicalOwner = mustRight (mkOwnerNonce "owner-a")

alternateOwner :: OwnerNonce
alternateOwner = mustRight (mkOwnerNonce "owner-b")

canonicalAction :: ArtifactDigest
canonicalAction = digestOf 'a'

alternateAction :: ArtifactDigest
alternateAction = digestOf 'b'

canonicalReceiptDigest :: ArtifactDigest
canonicalReceiptDigest = digestOf 'c'

canonicalRequest :: RequestDigest
canonicalRequest = requestDigestOf 'd'

alternateRequest :: RequestDigest
alternateRequest = requestDigestOf 'e'

canonicalStorage :: VaultStorageGeneration
canonicalStorage = mustRight (mkVaultStorageGeneration "vault-pv-uid-a")

alternateStorage :: VaultStorageGeneration
alternateStorage = mustRight (mkVaultStorageGeneration "vault-pv-uid-b")

generation :: Natural -> BootstrapFenceGeneration
generation = mustRight . mkBootstrapFenceGeneration

canonicalFence :: BootstrapSessionFence
canonicalFence =
  fenceAt 1 canonicalOwner canonicalAction canonicalRequest canonicalStorage 1_000

alternateOwnerFence :: BootstrapSessionFence
alternateOwnerFence =
  fenceAt 1 alternateOwner canonicalAction canonicalRequest canonicalStorage 1_000

fenceAt
  :: Natural
  -> OwnerNonce
  -> ArtifactDigest
  -> RequestDigest
  -> VaultStorageGeneration
  -> Natural
  -> BootstrapSessionFence
fenceAt fenceGeneration owner actionDigest requestDigest storageGeneration operationDeadline =
  mustRight
    ( reloadBootstrapSessionFence
        fenceGeneration
        owner
        actionDigest
        requestDigest
        storageGeneration
        operationDeadline
    )

acquireRequestFor :: BootstrapSessionFence -> BootstrapFenceAcquireRequest
acquireRequestFor fence =
  mkBootstrapFenceAcquireRequest
    (bootstrapFenceOwnerNonce fence)
    (bootstrapFenceActionDigest fence)
    (bootstrapFenceRequestDigest fence)
    (bootstrapFenceStorageGeneration fence)
    (bootstrapFenceOperationDeadline fence)

vacantPlan :: Natural -> BootstrapFenceCasPlan
vacantPlan floorGeneration =
  case decideBootstrapFenceAcquire
    monoNow
    requestDeadline
    trustedNow
    (acquireRequestFor canonicalFence)
    (BootstrapFenceStoreVacant floorGeneration) of
    BootstrapFenceAcquireCas plan -> plan
    decision -> error ("expected fence CAS plan, got " ++ show decision)

exactLease :: BootstrapLeaseObservation
exactLease =
  BootstrapLeaseObserved
    (bootstrapLeaseBindingForFence canonicalFence)
    leaseDeadline
    "resource-version-1"

fencePermitFor
  :: BootstrapSessionFence
  -> BootstrapVaultEffect
  -> Either BootstrapFenceUseRefusal BootstrapVaultEffectPermit
fencePermitFor = fencePermitAt trustedNow

fencePermitAt
  :: AuthorityClockObservation
  -> BootstrapSessionFence
  -> BootstrapVaultEffect
  -> Either BootstrapFenceUseRefusal BootstrapVaultEffectPermit
fencePermitAt clockObservation fence effect =
  authorizeBootstrapVaultEffect
    monoNow
    requestDeadline
    clockObservation
    fence
    (BootstrapFenceStoreHeld fence)
    ( BootstrapLeaseObserved
        (bootstrapLeaseBindingForFence fence)
        leaseDeadline
        "resource-version-1"
    )
    effect

acquireRefused :: BootstrapFenceAcquireDecision -> Bool
acquireRefused decision = case decision of
  BootstrapFenceAcquireRefused _ -> True
  _ -> False

canonicalPodUid :: WorkerPodUid
canonicalPodUid = mustRight (mkWorkerPodUid "pod-uid-a")

alternatePodUid :: WorkerPodUid
alternatePodUid = mustRight (mkWorkerPodUid "pod-uid-b")

canonicalImageDigest :: WorkerImageDigest
canonicalImageDigest =
  mustRight (mkWorkerImageDigest ("sha256:" <> Text.replicate 64 "a"))

alternateImageDigest :: WorkerImageDigest
alternateImageDigest =
  mustRight (mkWorkerImageDigest ("sha256:" <> Text.replicate 64 "b"))

canonicalServiceAccount :: WorkerServiceAccount
canonicalServiceAccount = mustRight (mkWorkerServiceAccount "bootstrap-init-worker")

alternateServiceAccount :: WorkerServiceAccount
alternateServiceAccount = mustRight (mkWorkerServiceAccount "bootstrap-unseal-worker")

canonicalSessionId :: WorkerSessionId
canonicalSessionId = mustRight (mkWorkerSessionId "worker-session-a")

alternateSessionId :: WorkerSessionId
alternateSessionId = mustRight (mkWorkerSessionId "worker-session-b")

canonicalSessionAccessor :: WorkerSessionAccessor
canonicalSessionAccessor = mustRight (mkWorkerSessionAccessor "worker-accessor-a")

alternateSessionAccessor :: WorkerSessionAccessor
alternateSessionAccessor = mustRight (mkWorkerSessionAccessor "worker-accessor-b")

canonicalWorkerRequest :: SecretFreeWorkerRequest
canonicalWorkerRequest = workerRequestFor SecretWorkerInitialize canonicalFence

workerRequestFor
  :: SecretWorkerOperation
  -> BootstrapSessionFence
  -> SecretFreeWorkerRequest
workerRequestFor operation =
  mkSecretFreeWorkerRequest
    operation
    canonicalPodUid
    canonicalImageDigest
    canonicalServiceAccount
    canonicalSessionId
    canonicalSessionAccessor

canonicalAttestation :: RawSecretWorkerAttestation
canonicalAttestation = attestationFor canonicalWorkerRequest

attestationFor :: SecretFreeWorkerRequest -> RawSecretWorkerAttestation
attestationFor request =
  RawSecretWorkerAttestation
    { rawWorkerPodUid = secretWorkerRequestPodUid request
    , rawWorkerImageDigest = secretWorkerRequestImageDigest request
    , rawWorkerServiceAccount = secretWorkerRequestServiceAccount request
    , rawWorkerSessionId = secretWorkerRequestSessionId request
    , rawWorkerSessionAccessor = secretWorkerRequestSessionAccessor request
    , rawWorkerOperation = secretWorkerRequestOperation request
    , rawWorkerFenceGeneration = secretWorkerRequestFenceGeneration request
    , rawWorkerOwnerNonce = secretWorkerRequestOwnerNonce request
    , rawWorkerActionDigest = secretWorkerRequestActionDigest request
    , rawWorkerRequestDigest = secretWorkerRequestDigest request
    , rawWorkerStorageGeneration = secretWorkerRequestStorageGeneration request
    , rawWorkerOperationDeadline = secretWorkerRequestOperationDeadline request
    }

canonicalAttestedWorker :: AttestedSecretWorker
canonicalAttestedWorker =
  mustRight
    ( attestSecretWorker
        canonicalWorkerRequest
        (SecretWorkerAttestationObserved canonicalAttestation)
    )

canonicalCapturedWorker :: ReceiptCapturedSecretWorker
canonicalCapturedWorker =
  let permit =
        mustRight
          ( authorizeSecretWorkerEffect
              monoNow
              canonicalAttestedWorker
              (mustRight (fencePermitFor canonicalFence BootstrapVaultInitialize))
          )
      rawReceipt = receiptFor canonicalWorkerRequest SecretWorkerInitialized
      executed = executedWorker permit rawReceipt
   in mustRight
        ( captureSecretWorkerReceipt
            executed
            rawReceipt
            (durableResultFor SecretWorkerInitialize)
        )

receiptTestOperations :: [SecretWorkerOperation]
receiptTestOperations =
  [ SecretWorkerInitialize
  , SecretWorkerUnseal
  , SecretWorkerRotateUnlockBundle
  , SecretWorkerRotateTransitKey
  ]

executedWorker
  :: SecretWorkerEffectPermit
  -> RawSecretWorkerReceipt
  -> ExecutedSecretWorker
executedWorker permit rawReceipt =
  case runIdentity
    ( executeAuthorizedSecretWorker
        permit
        (testTransfer permit rawReceipt)
    ) of
    Right (executed, _, ()) -> executed
    Left () -> error "impossible secret-worker test execution refusal"

testTransfer
  :: SecretWorkerEffectPermit
  -> RawSecretWorkerReceipt
  -> RunningSecretWorker scope
  %1 -> Identity
          ( Either
              ()
              (ExecutedSecretWorker, RawSecretWorkerReceipt, ())
          )
testTransfer permit rawReceipt running =
  finishSecretWorkerExecution
    permit
    (pure (Right (rawReceipt, ())))
    running

durableResultFor :: SecretWorkerOperation -> SecretWorkerDurableResult
durableResultFor operation = case operation of
  SecretWorkerInitialize -> ambiguousInitializationWorkerResult
  SecretWorkerUnseal -> unsealWorkerResult mutationReceipt
  SecretWorkerRotateUnlockBundle -> unlockRotationWorkerResult mutationReceipt
  SecretWorkerRotateTransitKey -> transitRotationWorkerResult mutationReceipt
  _ -> error "test durable result requires an operation-specific encrypted fixture"
 where
  mutationReceipt =
    BootstrapMutationReceipt
      { bootstrapMutationDigest = canonicalAction
      , bootstrapMutationChanged = True
      }

receiptFor :: SecretFreeWorkerRequest -> SecretWorkerOutcome -> RawSecretWorkerReceipt
receiptFor request outcome =
  RawSecretWorkerReceipt
    { rawWorkerReceiptOperation = secretWorkerRequestOperation request
    , rawWorkerReceiptPodUid = secretWorkerRequestPodUid request
    , rawWorkerReceiptSessionId = secretWorkerRequestSessionId request
    , rawWorkerReceiptSessionAccessor = secretWorkerRequestSessionAccessor request
    , rawWorkerReceiptRequestDigest = secretWorkerRequestDigest request
    , rawWorkerReceiptStorageGeneration = secretWorkerRequestStorageGeneration request
    , rawWorkerReceiptFenceGeneration = secretWorkerRequestFenceGeneration request
    , rawWorkerReceiptOutcome = outcome
    , rawWorkerReceiptDigest = canonicalReceiptDigest
    }

effectFor :: SecretWorkerOperation -> BootstrapVaultEffect
effectFor operation = case operation of
  SecretWorkerPrepareInitialization -> BootstrapVaultInitialize
  SecretWorkerResumeInitialization -> BootstrapVaultInitialize
  SecretWorkerInitialize -> BootstrapVaultInitialize
  SecretWorkerFinalizeInitialization -> BootstrapVaultInitialize
  SecretWorkerUnseal -> BootstrapVaultSubmitUnsealShare
  SecretWorkerRotateUnlockBundle -> BootstrapVaultRotateUnlockBundle
  SecretWorkerRotateTransitKey -> BootstrapVaultRotateTransitKey

outcomeFor :: SecretWorkerOperation -> SecretWorkerOutcome
outcomeFor operation = case operation of
  SecretWorkerPrepareInitialization -> SecretWorkerInitialized
  SecretWorkerResumeInitialization -> SecretWorkerInitialized
  SecretWorkerInitialize -> SecretWorkerInitialized
  SecretWorkerFinalizeInitialization -> SecretWorkerInitialized
  SecretWorkerUnseal -> SecretWorkerUnsealed
  SecretWorkerRotateUnlockBundle -> SecretWorkerUnlockBundleRotated
  SecretWorkerRotateTransitKey -> SecretWorkerTransitKeyRotated

digestOf :: Char -> ArtifactDigest
digestOf character = mustRight (mkArtifactDigest (Text.replicate 64 (Text.singleton character)))

requestDigestOf :: Char -> RequestDigest
requestDigestOf character =
  mustRight (mkRequestDigest (Text.replicate 64 (Text.singleton character)))

secretSentinel :: String
secretSentinel = "super-secret-worker-password"

mustRight :: (Show error) => Either error value -> value
mustRight = either (error . show) id
