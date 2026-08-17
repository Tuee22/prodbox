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

    -- Sprint 2.47: the acquire path asked this as a Bool, folding all three
    -- AttemptDeadlineRefusal arms into "expired". Two of them mean *cannot
    -- determine*. Both still refuse today, so the pair below is behaviour-
    -- preserving -- it is pinned because the distinction becomes safety-critical
    -- the moment a positive expiry authorises a retirement, and an unreadable
    -- clock must never authorise one.
    it "distinguishes a positively expired predecessor from one whose clock cannot be read" $ do
      let expired =
            fenceAt 1 alternateOwner canonicalAction alternateRequest canonicalStorage 100
      classifyPredecessorLiveness monoNow requestDeadline trustedNow expired
        `shouldBe` PredecessorExpired
      case classifyPredecessorLiveness
        monoNow
        requestDeadline
        (AuthorityTimeUnobservable (ClockUnreadable "clock source unavailable"))
        expired of
        PredecessorLivenessUnobservable _ -> pure ()
        other ->
          expectationFailure
            ("an unreadable clock must not read as expiry, got: " ++ show other)

    -- The measurement that scoped this sprint: the acquire path CANNOT reach a
    -- liveness-unobservable predecessor, because it derives the *request's*
    -- attempt deadline from the same clock observation before it reads the
    -- store. An untrusted clock therefore refuses at the request, never at the
    -- predecessor. This is why no new refusal constructor was added -- it would
    -- have been unreachable, which is the arm Sprint 4.78 deleted rather than
    -- re-worded. The classifier keeps its third arm because
    -- `decideBootstrapFenceRetire` reaches it on a path that does not pre-check
    -- the request.
    it "refuses on the request's own clock before a predecessor's liveness is ever classified" $ do
      let expired =
            fenceAt 1 alternateOwner canonicalAction alternateRequest canonicalStorage 100
      case decideBootstrapFenceAcquire
        monoNow
        requestDeadline
        (AuthorityTimeUnobservable (ClockUnreadable "clock source unavailable"))
        (acquireRequestFor canonicalFence)
        (BootstrapFenceStoreHeld expired) of
        BootstrapFenceAcquireRefused (BootstrapFenceAcquireDeadlineRefused _) -> pure ()
        other ->
          expectationFailure
            ("an untrusted clock must refuse at the request deadline, got: " ++ show other)

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

    -- Sprint 2.48: the compensating release for the second defect Sprint 2.47's
    -- live proof measured -- `acquireFence` CASed its fence and then abandoned
    -- it when `ensureLease` failed, so one Lease fault cost a generation and
    -- refused every successor `BootstrapFenceAcquireOverlap` until the
    -- operation deadline elapsed. Measured across five consecutive bring-ups on
    -- 2026-08-14, not inferred.
    it "releases a freshly acquired fence and burns its generation rather than reusing it" $ do
      let acquired =
            fenceAt 5 canonicalOwner canonicalAction canonicalRequest canonicalStorage 5_000
          release = abandonFreshlyAcquiredFence acquired
          vacant = BootstrapFenceStoreVacant 5
      -- exact-value CAS: it can never clobber a fence this call did not write
      fenceRetireExpectedFence release `shouldBe` acquired
      -- the floor is the released generation itself, so the successor allocates
      -- 6. A floor of 4 would let a successor re-mint generation 5, and the
      -- whole fence scheme rests on that never happening.
      fenceRetireVacantGenerationFloor release `shouldBe` 5
      confirmBootstrapFenceRetireCas
        release
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
            `shouldBe` 6
        decision -> expectationFailure ("expected successor CAS plan, got " ++ show decision)

    it "cannot release a fence other than the exact one it was given" $ do
      let acquired =
            fenceAt 5 canonicalOwner canonicalAction canonicalRequest canonicalStorage 5_000
          someoneElse =
            fenceAt 5 alternateOwner canonicalAction alternateRequest canonicalStorage 5_000
          release = abandonFreshlyAcquiredFence acquired
      -- The store CAS compares the whole value, so a fence that differs in any
      -- field conflicts rather than being vacated -- which is what makes the
      -- compensation safe without observing an owner.
      fenceRetireExpectedFence release `shouldNotBe` someoneElse
      confirmBootstrapFenceRetireCas
        release
        (BootstrapFenceRetireCasConflict (BootstrapFenceStoreHeld someoneElse))
        `shouldSatisfy` isLeft
      confirmBootstrapFenceRetireCas
        release
        (BootstrapFenceRetireCasAppliedReadBack (BootstrapFenceStoreVacant 4))
        `shouldSatisfy` isLeft

    -- Sprint 2.47: the adapter that gave `decideBootstrapFenceRetire` its first
    -- production producer. It exists because a held `BootstrapSessionFence`
    -- carries three of the seven fields a `SecretWorkerCleanupBinding` needs,
    -- so the retire path could never be wired to the binding-keyed observer.
    it "adapts a generation-scoped worker observation into the exact cleanup fact" $ do
      let held = fenceAt 4 alternateOwner canonicalAction alternateRequest canonicalStorage 50
          heldGeneration = bootstrapFenceGeneration held
      bootstrapFenceOwnerCleanupFromWorkerObservation
        held
        (BootstrapFenceOwnerWorkerAbsent heldGeneration canonicalReceiptDigest)
        `shouldBe` BootstrapFenceOwnerAbsent held canonicalReceiptDigest
      bootstrapFenceOwnerCleanupFromWorkerObservation
        held
        (BootstrapFenceOwnerWorkerPresent heldGeneration)
        `shouldBe` BootstrapFenceOwnerStillPresent held
      bootstrapFenceOwnerCleanupFromWorkerObservation
        held
        (BootstrapFenceOwnerWorkerUnobservable "worker API down")
        `shouldBe` BootstrapFenceOwnerCleanupUnobservable "worker API down"

    -- The safety case, and the reason the observation carries a generation at
    -- all: an answer about generation G' is not an answer about generation G,
    -- in EITHER direction. An absence claim about someone else's worker must
    -- never authorize this fence's takeover, and a presence claim about someone
    -- else's worker must not be reported as this owner still holding.
    it "never lets a worker observation about another generation authorize this takeover" $ do
      let held = fenceAt 4 alternateOwner canonicalAction alternateRequest canonicalStorage 50
          otherGeneration = generation 9
          expired =
            decideBootstrapFenceRetire
              monoNow
              requestDeadline
              trustedNow
              held
              BootstrapLeaseMissing
      forM_
        [ BootstrapFenceOwnerWorkerAbsent otherGeneration canonicalReceiptDigest
        , BootstrapFenceOwnerWorkerPresent otherGeneration
        ]
        $ \observation -> do
          let cleanup = bootstrapFenceOwnerCleanupFromWorkerObservation held observation
          cleanup `shouldSatisfy` isCleanupUnobservable
          expired cleanup `shouldSatisfy` isLeft

    -- The sequence Sprint 2.47 wired into `acquireFence`, asserted end to end as
    -- pure decisions. Before it, `decideBootstrapFenceRetire` had zero
    -- production callers while its store half was fully wired, so a fence
    -- abandoned by a failed bring-up refused every later acquisition forever --
    -- and `cluster delete --cascade` preserves the object by design.
    it "acquires after retiring a positively expired predecessor, in one bounded pass" $ do
      let abandoned =
            fenceAt 4 alternateOwner canonicalAction alternateRequest canonicalStorage 50
          successor = acquireRequestFor canonicalFence
          firstAttempt =
            decideBootstrapFenceAcquire
              monoNow
              requestDeadline
              trustedNow
              successor
              (BootstrapFenceStoreHeld abandoned)
      -- The refusal the operator host actually reported, five bring-ups running.
      firstAttempt
        `shouldBe` BootstrapFenceAcquireRefused
          (BootstrapFenceAcquireExpiredPredecessor abandoned)
      let retirement =
            mustRight
              ( decideBootstrapFenceRetire
                  monoNow
                  requestDeadline
                  trustedNow
                  abandoned
                  BootstrapLeaseMissing
                  ( bootstrapFenceOwnerCleanupFromWorkerObservation
                      abandoned
                      ( BootstrapFenceOwnerWorkerAbsent
                          (bootstrapFenceGeneration abandoned)
                          canonicalReceiptDigest
                      )
                  )
              )
          vacated =
            mustRight
              ( confirmBootstrapFenceRetireCas
                  retirement
                  (BootstrapFenceRetireCasAppliedReadBack (BootstrapFenceStoreVacant 4))
              )
      -- The successor re-decides against the confirmed post-retirement
      -- read-back, not a fresh store read, and allocates floor + 1 exactly once.
      case decideBootstrapFenceAcquire monoNow requestDeadline trustedNow successor vacated of
        BootstrapFenceAcquireCas plan -> do
          fenceCasExpectedGenerationFloor plan `shouldBe` 4
          bootstrapFenceGenerationValue
            (bootstrapFenceGeneration (fenceCasProposedFence plan))
            `shouldBe` 5
          bootstrapFenceOwnerNonce (fenceCasProposedFence plan) `shouldBe` canonicalOwner
        decision -> expectationFailure ("expected successor CAS plan, got " ++ show decision)

    -- The refusal arm must still refuse: a permissive branch proves nothing on
    -- its own. A live worker for the same generation blocks the retirement, so
    -- the successor is left with the original expired-predecessor refusal.
    it "still refuses when the expired predecessor's worker is live or unreadable" $ do
      let abandoned =
            fenceAt 4 alternateOwner canonicalAction alternateRequest canonicalStorage 50
          heldGeneration = bootstrapFenceGeneration abandoned
      forM_
        [ BootstrapFenceOwnerWorkerPresent heldGeneration
        , BootstrapFenceOwnerWorkerUnobservable "worker Pod fence-owner GET returned a non-success status"
        ]
        $ \observation ->
          decideBootstrapFenceRetire
            monoNow
            requestDeadline
            trustedNow
            abandoned
            BootstrapLeaseMissing
            (bootstrapFenceOwnerCleanupFromWorkerObservation abandoned observation)
            `shouldSatisfy` isLeft

    -- Sprint 2.49 regression. An already-expired Lease is encoded as a deadline
    -- AT the instant it was observed, and `deadlineExpired now limit` is
    -- `now >= limit`. So the instant handed to the retire decision must not
    -- predate the observation, or a Lease that expired hours ago reads as still
    -- live and the fence can never be retired. This was latent from Sprint 2.47
    -- and unreachable until Sprint 2.48 made the Lease creatable at all --
    -- before that every retirement saw `BootstrapLeaseMissing` and
    -- short-circuited.
    it "reads a Lease expired at the observation instant as expired, not as still live" $ do
      let expired =
            fenceAt 1 alternateOwner canonicalAction alternateRequest canonicalStorage 50
          observedAt = monotonicInstantFromMicros 400
          -- exactly how bootstrapLeaseFromResponse encodes an expired Lease
          staleLease =
            BootstrapLeaseObserved
              (bootstrapLeaseBindingForFence expired)
              (deadlineFromInstant observedAt)
              "stale-resource-version"
          retireAt now =
            decideBootstrapFenceRetire
              now
              requestDeadline
              trustedNow
              expired
              staleLease
              (BootstrapFenceOwnerAbsent expired canonicalReceiptDigest)
      -- sampled at or after the observation: expired, so retirement proceeds
      retireAt observedAt `shouldSatisfy` isRight
      retireAt (monotonicInstantFromMicros 401) `shouldSatisfy` isRight
      -- sampled before it: the defect -- the Lease reads as still live
      case retireAt (monotonicInstantFromMicros 399) of
        Left (BootstrapFenceRetireLeaseStillLive _) -> pure ()
        other ->
          expectationFailure
            ("an instant predating the observation must read the Lease as live, got: " ++ show other)

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

isCleanupUnobservable :: BootstrapFenceOwnerCleanupObservation -> Bool
isCleanupUnobservable observation = case observation of
  BootstrapFenceOwnerCleanupUnobservable _ -> True
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
  SecretWorkerCompleteGeneratedRoot -> BootstrapVaultSubmitGenerateRootShare

outcomeFor :: SecretWorkerOperation -> SecretWorkerOutcome
outcomeFor operation = case operation of
  SecretWorkerPrepareInitialization -> SecretWorkerInitialized
  SecretWorkerResumeInitialization -> SecretWorkerInitialized
  SecretWorkerInitialize -> SecretWorkerInitialized
  SecretWorkerFinalizeInitialization -> SecretWorkerInitialized
  SecretWorkerUnseal -> SecretWorkerUnsealed
  SecretWorkerRotateUnlockBundle -> SecretWorkerUnlockBundleRotated
  SecretWorkerRotateTransitKey -> SecretWorkerTransitKeyRotated
  SecretWorkerCompleteGeneratedRoot -> SecretWorkerGeneratedRootCompleted

digestOf :: Char -> ArtifactDigest
digestOf character = mustRight (mkArtifactDigest (Text.replicate 64 (Text.singleton character)))

requestDigestOf :: Char -> RequestDigest
requestDigestOf character =
  mustRight (mkRequestDigest (Text.replicate 64 (Text.singleton character)))

secretSentinel :: String
secretSentinel = "super-secret-worker-password"

mustRight :: (Show error) => Either error value -> value
mustRight = either (error . show) id
