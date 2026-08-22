{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownLegacyAdoptionPlan
  ( lifecycleTeardownLegacyAdoptionPlanSuite
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.Authority.AdminAction
  ( PermitFreshness (PermitExpired, PermitFresh)
  , RunnerRole (AdminActionRunner, ProviderWorker)
  )
import Prodbox.Lifecycle.Teardown.LegacyAdoptionPlan
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.OwnershipManifest
  ( LegacyAdoptionPlanDigest
  , legacyAdoptionPlanDigestText
  )
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownLegacyAdoptionPlanSuite :: SuiteBuilder ()
lifecycleTeardownLegacyAdoptionPlanSuite =
  describe "Sprint 7.36 bounded legacy-adoption planner" $ do
    it "derives the closed family from the registry rather than from discovery" $ do
      -- The eks stack owns its per-run EBS family through the registered
      -- ownership edge; the other two stacks own only themselves. Nothing here
      -- is a name-prefix sweep or a tag query.
      legacyAdoptionExpectedFamily AwsEksKey
        `shouldBe` [AwsEksKey, AwsEbsPerRunTestKey]
      legacyAdoptionExpectedFamily AwsTestKey `shouldBe` [AwsTestKey]

    it "plans only over a complete observation of that family" $ do
      let plan = mustPlan (observationsFor [(AwsEksKey, ["arn:eks"]), (AwsEbsPerRunTestKey, ["vol-1"])])
      legacyAdoptionPlanStackKey plan `shouldBe` AwsEksKey
      legacyAdoptionPlanSurface plan `shouldBe` ExplicitPerRun
      map legacyAdoptionEntryKey (legacyAdoptionPlanEntries plan)
        `shouldBe` [AwsEksKey, AwsEbsPerRunTestKey]
      map legacyAdoptionEntryIdentities (legacyAdoptionPlanEntries plan)
        `shouldBe` [[ObservedResourceIdentity "arn:eks"], [ObservedResourceIdentity "vol-1"]]

    it "records an observed-empty family rather than omitting it" $ do
      -- "Nothing recorded" and "recorded as empty" are different states, and a
      -- later cleanup must be able to tell them apart.
      let plan = mustPlan (observationsFor [(AwsEksKey, ["arn:eks"]), (AwsEbsPerRunTestKey, [])])
      map legacyAdoptionEntryIdentities (legacyAdoptionPlanEntries plan)
        `shouldBe` [[ObservedResourceIdentity "arn:eks"], []]
      renderLegacyAdoptionPlan plan `shouldContainText` "observed-empty"

    it "refuses a family member nothing was observed for" $ do
      planFor (observationsFor [(AwsEksKey, ["arn:eks"])])
        `shouldBe` Left (LegacyAdoptionCandidatesMissing [AwsEbsPerRunTestKey])

    it "refuses an observation outside the closed family" $ do
      -- Discovery may not widen the family it is discovering.
      planFor
        ( observationsFor
            [ (AwsEksKey, ["arn:eks"])
            , (AwsEbsPerRunTestKey, ["vol-1"])
            , (AwsTestKey, ["arn:test"])
            ]
        )
        `shouldBe` Left (LegacyAdoptionCandidatesExtra [AwsTestKey])

    it "refuses two observations for one registered key" $ do
      planFor
        ( observationsFor
            [ (AwsEksKey, ["arn:eks"])
            , (AwsEbsPerRunTestKey, ["vol-1"])
            , (AwsEbsPerRunTestKey, ["vol-2"])
            ]
        )
        `shouldBe` Left (LegacyAdoptionCandidatesDuplicated [AwsEbsPerRunTestKey])

    it "refuses a partial or unobservable family rather than planning a smaller one" $ do
      planFor
        [ presentObservation AwsEksKey ["arn:eks"]
        , unobservableObservation AwsEbsPerRunTestKey
        ]
        `shouldBe` Left (LegacyAdoptionCandidatesUnobservable [AwsEbsPerRunTestKey])

    it "refuses one identity claimed by two registered keys" $ do
      -- Adopting it would put one resource under two owners with two destroy
      -- orders.
      planFor (observationsFor [(AwsEksKey, ["shared-arn"]), (AwsEbsPerRunTestKey, ["shared-arn"])])
        `shouldBe` Left
          (LegacyAdoptionIdentitiesAmbiguous [ObservedResourceIdentity "shared-arn"])

    it "refuses a scope that names no AWS account or the wrong operation" $ do
      planLegacyAdoption
        ExplicitPerRunSurface
        AwsEksKey
        (scopeWith Nothing ReconcileDesiredAbsent)
        (observationsFor [(AwsEksKey, ["arn:eks"]), (AwsEbsPerRunTestKey, ["vol-1"])])
        `shouldBe` Left LegacyAdoptionAwsScopeMissing
      planLegacyAdoption
        ExplicitPerRunSurface
        AwsEksKey
        (scopeWith (Just awsScope) ReconcileDesiredPresent)
        (observationsFor [(AwsEksKey, ["arn:eks"]), (AwsEbsPerRunTestKey, ["vol-1"])])
        `shouldBe` Left (LegacyAdoptionOperationInvalid ReconcileDesiredPresent)

    it "digests exactly the document it renders, and a changed fact changes it" $ do
      let plan = mustPlan (observationsFor [(AwsEksKey, ["arn:eks"]), (AwsEbsPerRunTestKey, ["vol-1"])])
          other = mustPlan (observationsFor [(AwsEksKey, ["arn:eks"]), (AwsEbsPerRunTestKey, ["vol-2"])])
      renderLegacyAdoptionPlan plan `shouldContainText` "legacy-adoption-plan/v1"
      renderLegacyAdoptionPlan plan `shouldContainText` "vol-1"
      legacyAdoptionPlanDigestOf plan `shouldNotBe` legacyAdoptionPlanDigestOf other
      -- The digest is a hash rather than a rendering of the plan, so the
      -- confirmation an operator gives is over a fixed-width value.
      Text.length (legacyAdoptionPlanDigestText (legacyAdoptionPlanDigestOf plan))
        `shouldBe` 64

    it "admits a permit only for the admin audience, fresh, nonced, and naming a plan" $ do
      let digest = legacyAdoptionPlanDigestOf samplePlan
      admitAdminLegacyAdoptionPermit
        PermitFresh
        (permitRequest ProviderWorker digest "nonce-1")
        `shouldBe` Left (AdminLegacyPermitWrongAudience ProviderWorker)
      admitAdminLegacyAdoptionPermit
        PermitExpired
        (permitRequest AdminActionRunner digest "nonce-1")
        `shouldBe` Left AdminLegacyPermitExpired
      admitAdminLegacyAdoptionPermit
        PermitFresh
        (permitRequest AdminActionRunner digest "")
        `shouldBe` Left AdminLegacyPermitNonceMissing
      fmap
        adminLegacyAdoptionPermitPlanDigest
        (admitAdminLegacyAdoptionPermit PermitFresh (permitRequest AdminActionRunner digest "nonce-1"))
        `shouldBe` Right digest

    it "confirms only the exact plan the permit names" $ do
      -- A plan re-rendered after the provider facts changed is a different
      -- plan, and the operator confirmed the earlier one.
      let other = mustPlan (observationsFor [(AwsEksKey, ["arn:eks"]), (AwsEbsPerRunTestKey, ["vol-2"])])
          permit = mustPermit (legacyAdoptionPlanDigestOf samplePlan)
      fmap confirmedLegacyAdoptionPlanDigest (confirmLegacyAdoptionPlan permit samplePlan)
        `shouldBe` Right (legacyAdoptionPlanDigestOf samplePlan)
      confirmLegacyAdoptionPlan permit other
        `shouldBe` Left
          ( LegacyAdoptionConfirmationDigestMismatch
              (legacyAdoptionPlanDigestOf other)
              (legacyAdoptionPlanDigestOf samplePlan)
          )

    it "refuses a permit issued for another stack's adoption" $ do
      let permit =
            mustRight
              ( admitAdminLegacyAdoptionPermit
                  PermitFresh
                  AdminLegacyAdoptionPermitRequest
                    { adminLegacyPermitRequestAudience = AdminActionRunner
                    , adminLegacyPermitRequestStackKey = AwsTestKey
                    , adminLegacyPermitRequestPlanDigest =
                        legacyAdoptionPlanDigestOf samplePlan
                    , adminLegacyPermitRequestNonce = "nonce-1"
                    }
              )
      confirmLegacyAdoptionPlan permit samplePlan
        `shouldBe` Left
          (LegacyAdoptionConfirmationStackMismatch AwsEksKey AwsTestKey)

samplePlan :: LegacyAdoptionPlan 'ExplicitPerRun
samplePlan =
  mustPlan (observationsFor [(AwsEksKey, ["arn:eks"]), (AwsEbsPerRunTestKey, ["vol-1"])])

permitRequest
  :: RunnerRole -> LegacyAdoptionPlanDigest -> Text -> AdminLegacyAdoptionPermitRequest
permitRequest audience digest nonce =
  AdminLegacyAdoptionPermitRequest
    { adminLegacyPermitRequestAudience = audience
    , adminLegacyPermitRequestStackKey = AwsEksKey
    , adminLegacyPermitRequestPlanDigest = digest
    , adminLegacyPermitRequestNonce = nonce
    }

mustPermit :: LegacyAdoptionPlanDigest -> AdminLegacyAdoptionPermit
mustPermit digest =
  mustRight
    (admitAdminLegacyAdoptionPermit PermitFresh (permitRequest AdminActionRunner digest "nonce-1"))

planFor
  :: [ExactResourceObservation]
  -> Either LegacyAdoptionRefusal (LegacyAdoptionPlan 'ExplicitPerRun)
planFor = planLegacyAdoption ExplicitPerRunSurface AwsEksKey perRunScope

mustPlan :: [ExactResourceObservation] -> LegacyAdoptionPlan 'ExplicitPerRun
mustPlan = mustRight . planFor

observationsFor :: [(RegisteredResourceKey, [Text])] -> [ExactResourceObservation]
observationsFor rows = [presentObservation key identities | (key, identities) <- rows]

presentObservation :: RegisteredResourceKey -> [Text] -> ExactResourceObservation
presentObservation key identities =
  observationFor key $ case identities of
    [] -> ExactResourceAbsent (AbsenceEvidence "fixture observed an empty family")
    first : remaining ->
      ExactResourcePresent
        ( ExactResourceInventory
            (ObservedResourceIdentity first :| map ObservedResourceIdentity remaining)
        )

unobservableObservation :: RegisteredResourceKey -> ExactResourceObservation
unobservableObservation key =
  observationFor
    key
    (ExactResourceUnobservable (ObservationFailure "fixture could not observe" :| []))

observationFor
  :: RegisteredResourceKey -> ExactObservationResult -> ExactResourceObservation
observationFor key result =
  exactResourceObservationFor
    (mustIdentity key)
    (ObservationRevision 1)
    perRunScope
    result

mustIdentity :: RegisteredResourceKey -> RegisteredIdentity
mustIdentity key = case lookupRegisteredIdentity key of
  Just identity -> identity
  Nothing -> error ("unregistered fixture key " <> show key)

perRunScope :: ObservationEvidenceScope
perRunScope = scopeWith (Just awsScope) ReconcileDesiredAbsent

scopeWith :: Maybe AwsScope -> LifecycleOperation -> ObservationEvidenceScope
scopeWith maybeAwsScope operation =
  mkObservationEvidenceScope
    ExplicitPerRun
    lifecycleRegistryRevision
    (DurableObservationRunScope "legacy-adoption-plan-run")
    (LinuxRke2FoundationId "home-rke2")
    maybeAwsScope
    operation

awsScope :: AwsScope
awsScope = AwsScope (AwsAccountId "123456789012") (AwsRegion "ca-central-1")

shouldContainText :: Text -> Text -> Expectation
shouldContainText haystack needle =
  Text.isInfixOf needle haystack `shouldBe` True

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error ("expected Right, got " <> show err)
