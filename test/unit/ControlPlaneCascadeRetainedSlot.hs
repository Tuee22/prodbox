{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneCascadeRetainedSlot
  ( controlPlaneCascadeRetainedSlotSuite
  )
where

import Prodbox.ControlPlane.CascadeRetainedSlotClient
import Prodbox.ControlPlane.CascadeRetainedSlotEndpoint
import TestSupport

controlPlaneCascadeRetainedSlotSuite :: SuiteBuilder ()
controlPlaneCascadeRetainedSlotSuite =
  describe "Sprint 4.86 cascade retained-slot route" $ do
    it "admits exactly the three cascade slot namespaces" $ do
      -- The names are the ones the two repositories derive, so renaming a
      -- namespace fails here rather than silently leaving the host unable to
      -- reach its own slots.
      regression <- fixedCascadeRetainedSlotEndpointRegression
      cascadeRetainedSlotEndpointAdmitsExactlyTheCascadeNamespaces regression
        `shouldBe` True

    it "never reaches the object store for a name outside that namespace" $ do
      -- A generic "compare-and-swap any Authority object" route would put the
      -- admission projection and every credential namespace one logical name
      -- away from the host.
      regression <- fixedCascadeRetainedSlotEndpointRegression
      cascadeRetainedSlotEndpointForeignNameNoExecution regression
        `shouldBe` True

    it "refuses a cascade prefix carrying a non-canonical slot key" $ do
      regression <- fixedCascadeRetainedSlotEndpointRegression
      cascadeRetainedSlotEndpointMalformedSuffixNoExecution regression
        `shouldBe` True

    it "refuses a malformed request without executing" $ do
      regression <- fixedCascadeRetainedSlotEndpointRegression
      cascadeRetainedSlotEndpointMalformedNoExecution regression `shouldBe` True

    it "refuses an oversize request without executing" $ do
      regression <- fixedCascadeRetainedSlotEndpointRegression
      cascadeRetainedSlotEndpointOversizeNoExecution regression `shouldBe` True

    it "refuses an unsupported format version without executing" $ do
      regression <- fixedCascadeRetainedSlotEndpointRegression
      cascadeRetainedSlotEndpointUnsupportedVersionNoExecution regression
        `shouldBe` True

    it "refuses a slot value beyond the canonical bound without executing" $ do
      regression <- fixedCascadeRetainedSlotEndpointRegression
      cascadeRetainedSlotEndpointOversizeValueNoExecution regression
        `shouldBe` True

    it "carries the observed bytes on a conflict" $ do
      -- Telling an exact replay from a genuine disagreement is what the
      -- accept, commit, and grant protocols use the conflict arm for.
      regression <- fixedCascadeRetainedSlotEndpointRegression
      cascadeRetainedSlotEndpointConflictCarriesObservedBytes regression
        `shouldBe` True

    it "binds every response arm to the exact request digest and version" $ do
      regression <- fixedCascadeRetainedSlotEndpointRegression
      cascadeRetainedSlotEndpointAllArmsValidateRequestDigest regression
        `shouldBe` True

    it "refuses a foreign name on the host side before issuing a request" $ do
      -- The namespace is closed on both sides: a mistake in a caller never
      -- becomes a call.
      regression <- fixedCascadeRetainedSlotClientRegression
      cascadeRetainedSlotClientRefusesForeignNameUnissued regression
        `shouldBe` True

    it "refuses a replace without issuing a request" $ do
      regression <- fixedCascadeRetainedSlotClientRegression
      cascadeRetainedSlotClientRefusesReplaceUnissued regression `shouldBe` True

    it "refuses both guarded write arms without issuing a request" $ do
      regression <- fixedCascadeRetainedSlotClientRegression
      cascadeRetainedSlotClientRefusesGuardedUnissued regression `shouldBe` True

    it "reconstructs an applied value from the bytes the caller sent" $ do
      -- An initialize applies exactly the bytes it was given; believing an
      -- echoed value instead would let a corrupted response rewrite the
      -- caller's own record of what it wrote.
      regression <- fixedCascadeRetainedSlotClientRegression
      cascadeRetainedSlotClientAppliedEchoesRequestedValue regression
        `shouldBe` True

    it "reports a lost response as unobservable rather than as a refusal" $ do
      -- By the time the response is lost the request has been issued, so the
      -- write may well have landed.
      regression <- fixedCascadeRetainedSlotClientRegression
      cascadeRetainedSlotClientLostResponseUnobservable regression
        `shouldBe` True

    it "reports an unconfirmable response as unobservable" $ do
      regression <- fixedCascadeRetainedSlotClientRegression
      cascadeRetainedSlotClientStatusMismatchUnobservable regression
        `shouldBe` True

    it "round-trips missing and observed slots" $ do
      regression <- fixedCascadeRetainedSlotClientRegression
      cascadeRetainedSlotClientObservationRoundTrips regression `shouldBe` True
