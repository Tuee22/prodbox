-- | Sprint 4.89: the capability-custody boundary.
--
-- Two AWS resources were stranded by one event: both depended on capabilities
-- inside the retained store, and the store was destroyed while they existed.
-- What these cases measure is that ending custody now requires a value nobody
-- can build from a capability alone, that the set a capability reaches is
-- derived from the compiled registries rather than authored, and that a
-- registry which declares no family for what a capability reaches reports that
-- rather than an empty set.
--
-- The eliminators, the derived set, the release, and the boundary all stay
-- Cabal-hidden, so this suite reads booleans — the same shape the
-- cascade-evidence boundary already uses for the same reason.
module LifecycleTeardownCapabilityCustody
  ( lifecycleTeardownCapabilityCustodySuite
  )
where

import Prodbox.Lifecycle.LiveResidue
  ( fixedCheckpointAbsenceDischargeRegression
  )
import Prodbox.Lifecycle.Teardown.CapabilityCustody
import TestSupport

lifecycleTeardownCapabilityCustodySuite :: SuiteBuilder ()
lifecycleTeardownCapabilityCustodySuite =
  describe "Sprint 4.89 custodial capability disposition" $ do
    it "closes the disposition universe with no destroy constructor" $ do
      regression <- fixedCapabilityCustodyRegression
      -- Four retire arms and one hold arm, counted so a sixth fails the build.
      -- There is deliberately no arm whose meaning is destruction without a
      -- discharge: a caller holding a capability and nothing else has nothing
      -- to pass.
      capabilityCustodyUniverseClosed regression `shouldBe` True
      capabilityCustodyDischargeMandatory regression `shouldBe` True

    it "derives what a capability reaches from the compiled registries" $ do
      regression <- fixedCapabilityCustodyRegression
      -- A checkpoint reaches more than its own stack, so a derivation that
      -- returned only the stack would read as a complete answer without being
      -- one.
      capabilityCustodyDependantsDerived regression `shouldBe` True

    it "reports an undeclared family as underivable rather than as empty" $ do
      regression <- fixedCapabilityCustodyRegression
      -- No capability derives an empty set. An empty derived set discharges
      -- trivially, which is the exact failure that stranded the EKS node role:
      -- the registry declares three stack descriptors and two volume families
      -- and no IAM family, so no destroy granularity reaches an IAM role.
      capabilityCustodyUnderivableNotEmpty regression `shouldBe` True

    it "measures the derivation gate against its own defect" $ do
      regression <- fixedCapabilityCustodyRegression
      -- Remove one derivation source and the rule fails; restore it and the
      -- rule passes. Measuring the rule's shape instead would pass over a
      -- source that silently stopped contributing.
      capabilityCustodyGateMeasuredAgainstDefect regression `shouldBe` True

    it "refuses an undisposed, foreign, or duplicated capability" $ do
      regression <- fixedCapabilityCustodyRegression
      capabilityCustodyReleaseRefusalsExact regression `shouldBe` True

    it "answers a checkpoint's four arms as a custody question" $ do
      regression <- fixedCapabilityCustodyRegression
      -- Absent and empty are a lost capability; corrupt stays unobservable,
      -- because a blob that cannot be parsed may still be the capability;
      -- present is held. The residue classifier answers `ResidueAbsent` for the
      -- first two and is right to — "is there a stack to destroy" and "does this
      -- run still hold what makes it destroyable" are different questions, and
      -- reading the first answer as the second is what stranded two AWS
      -- resources.
      capabilityCustodyCheckpointArmsExact regression `shouldBe` True

    it "discharges by absence only from a provider observation" $
      -- The absence discharge is constructible only from provider-observed
      -- absence of every derived dependant. A checkpoint-layer absence — the
      -- exact answer a lost capability produces — is refused by the layer rule,
      -- an unobserved dependant is refused because a missing answer is not an
      -- absent resource, a still-present resource is refused, and an underivable
      -- dependant set cannot be discharged at all.
      --
      -- The fixture lives beside the residue observer rather than beside the
      -- discharge, because an observation records which authority answered and
      -- may be minted only where the observation is made: a fixture minting one
      -- inside the custody boundary would be a consumer asserting the layer,
      -- which is exactly the move that stranded the resources.
      fixedCheckpointAbsenceDischargeRegression `shouldBe` True

    it "shows the destructive boundary the same arguments under any lift" $ do
      regression <- fixedCapabilityCustodyRegression
      -- One fixed program under two carriers. The boundary's argument type
      -- mentions no `m` and the multiset is computed before dispatch, so the
      -- lift observes the identical value and has no arm through which to
      -- introduce a disposition it was not handed.
      capabilityCustodyLiftInvariant regression `shouldBe` True

    it "discharges a retirement from the absences the run already read back" $ do
      regression <- fixedCapabilityCustodyRegression
      -- Sprint 4.89: the same absence rule, reached through the second
      -- currency. A `ReadBackRegisteredTargetAbsent` node succeeds only when
      -- its exact observation is bound to that target and reports the resource
      -- absent at the registered identity's own authority, so "this run's
      -- read-back for that key succeeded" is a provider-observed absence.
      --
      -- A checkpoint reaches more than its own stack, so a run that read back
      -- only the stack is refused as unobserved rather than discharged — which
      -- is exactly what the retirement path used to do with the one read-back it
      -- performed and the ones it discarded.
      capabilityCustodyRunReadBackDischargeExact regression `shouldBe` True

    it "admits inertness only from a zero-length checkpoint object" $ do
      regression <- fixedCapabilityCustodyRegression
      -- A zero-length object names no stack state, so the capability authorises
      -- nothing. A corrupt blob may still be the capability and a present one
      -- names resources; neither is inert, and calling either one inert is the
      -- invention this constructor exists to refuse.
      capabilityCustodyInertnessOnlyFromEmptiness regression `shouldBe` True

    it "retires a reference as a rotation onto what the Authority retains" $ do
      regression <- fixedCapabilityCustodyRegression
      -- Retiring a reference records it in the Lifecycle Authority's retained
      -- set and clears the live slot, and the retained reference still names
      -- the backup copy's version. The capability moved rather than ceased, so
      -- the disposition names the successor and the successor reaches exactly
      -- what the live reference reached.
      capabilityCustodyRetirementRotatesOntoRetained regression `shouldBe` True

    it "reads a revocation as inertness and never as destruction" $ do
      regression <- fixedCapabilityCustodyRegression
      -- Sprint 4.89: a revocation read-back proves the family's keys no longer
      -- authenticate, so the capability authorises nothing and a run may stop
      -- holding it. It claims nothing about the IAM principal or the resources
      -- the permissions reached.
      --
      -- That distinction is the audited SES defect stated as a type: the
      -- retained SMTP principal exists with zero access keys because a
      -- decommission deleted keys, then policy, then user inside a
      -- short-circuiting sequence. The keys' absence made the capability inert,
      -- and inert is not destroyed — destroying the identity alongside it is a
      -- joint destruction, which is a different constructor and the operation
      -- Sprint `7.36` executes.
      capabilityCustodyRevocationIsInertnessOnly regression `shouldBe` True
