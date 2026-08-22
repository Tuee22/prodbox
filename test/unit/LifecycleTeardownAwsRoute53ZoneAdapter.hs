{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownAwsRoute53ZoneAdapter
  ( lifecycleTeardownAwsRoute53ZoneAdapterSuite
  )
where

import Data.Text (Text)
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.OwnedResourceTags (dnsValidationHostedZoneNamePrefix)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , providerIntentCoordinate
  )
import Prodbox.Lifecycle.Teardown.AwsRoute53ZoneAdapter
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.RegisteredTargetExecutor
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownAwsRoute53ZoneAdapterSuite :: SuiteBuilder ()
lifecycleTeardownAwsRoute53ZoneAdapterSuite =
  describe "Sprint 7.36 exact validation hosted-zone ProviderIntent adapter" $ do
    it "registers the family only alongside its executor" $ do
      -- The pairing rule this sprint carries: registering a descriptor compiles
      -- a mandatory absence read-back, and a surface that mints completion
      -- asserts every such read-back succeeded. Before this adapter the zone was
      -- exempted from the typed registry for exactly that reason.
      registeredTargetExecutorFor AwsDnsValidationZoneKey
        `shouldBe` Right ValidationHostedZoneFamilyExecutor
      lookupRegisteredIdentity AwsDnsValidationZoneKey `shouldSatisfy` isJustIdentity

    it "derives the family from the registry rather than from a caller" $ do
      let cascade = requestFor CascadeSurface cascadeScope
      awsValidationZoneObservationRequestScope cascade `shouldBe` cascadeScope
      -- The intent carries the registered prefix, and the creator, the sweep,
      -- and the registry all read that one constant.
      awsValidationZoneObservationRequestProviderIntent cascade
        `shouldBe` ObserveValidationHostedZones dnsValidationHostedZoneNamePrefix

    it "reads an empty family as absent and a listed zone as present" $ do
      let cascade = requestFor CascadeSurface cascadeScope
          absent = decode cascade dnsValidationHostedZoneNamePrefix
          present =
            decode
              cascade
              ( dnsValidationHostedZoneNamePrefix
                  <> "\nZ1234 prodbox-dns-aws-abc.example.test."
              )
      exactObservationResult absent `shouldSatisfy` isExactAbsent
      exactObservationResult present `shouldSatisfy` isExactPresent

    it "never turns an unobtainable listing into an absence" $ do
      -- The doctrine rule this family is most exposed to: a leaked billable
      -- zone that cannot be listed must not read as swept.
      let cascade = requestFor CascadeSurface cascadeScope
          unobservable =
            mustRight
              ( decodeExactAwsValidationZoneObservation
                  cascade
                  (Left "route53 list-hosted-zones was refused")
              )
      exactObservationResult unobservable `shouldSatisfy` isExactUnobservable
      -- An answer about another family is unobservable too, rather than being
      -- read as this family's absence.
      let foreign' =
            mustRight
              ( decodeExactAwsValidationZoneObservation
                  cascade
                  (observedResult cascade "prodbox-other-family-\n")
              )
      exactObservationResult foreign' `shouldSatisfy` isExactUnobservable

    it "refuses a response bound to another intent" $ do
      let cascade = requestFor CascadeSurface cascadeScope
          otherCoordinate =
            providerIntentCoordinate (ObserveValidationHostedZones "other-")
      decodeExactAwsValidationZoneObservation
        cascade
        (Right (ProviderIntentExecutionObserved otherCoordinate "other-\n"))
        `shouldSatisfy` isLeftResult

    it "authorizes a reap only from a positive observation" $ do
      let cascade = requestFor CascadeSurface cascadeScope
          absent = decode cascade dnsValidationHostedZoneNamePrefix
          present =
            decode
              cascade
              (dnsValidationHostedZoneNamePrefix <> "\nZ1234 zone.example.test.")
      -- Absence needs no mutation at all.
      fmap
        (fmap awsValidationZoneReapProviderIntent)
        (authorizeExactAwsValidationZoneReap cascade absent)
        `shouldBe` Right Nothing
      fmap
        (fmap awsValidationZoneReapProviderIntent)
        (authorizeExactAwsValidationZoneReap cascade present)
        `shouldBe` Right
          (Just (ReapValidationHostedZones dnsValidationHostedZoneNamePrefix))

    it "closes the family only on a separate exact read-back" $ do
      let cascade = requestFor CascadeSurface cascadeScope
      -- A reaper return value is not absence; only the read-back closes it.
      confirmExactAwsValidationZoneAbsence
        cascade
        (observedResult cascade (dnsValidationHostedZoneNamePrefix <> "\nZ1 z."))
        `shouldSatisfy` isLeftResult
      confirmExactAwsValidationZoneAbsence
        cascade
        (observedResult cascade dnsValidationHostedZoneNamePrefix)
        `shouldSatisfy` isRightResult

    it "parses the family line and its zone identities" $ do
      parseValidationZoneObservation "" `shouldSatisfy` isLeftResult
      parseValidationZoneObservation "prodbox-dns-aws-"
        `shouldBe` Right ("prodbox-dns-aws-", [])
      parseValidationZoneObservation "prodbox-dns-aws-\nZ1 a.\n\nZ2 b."
        `shouldBe` Right ("prodbox-dns-aws-", ["Z1 a.", "Z2 b."])

requestFor
  :: CleanupSurfaceWitness surface
  -> ObservationEvidenceScope
  -> ExactAwsValidationZoneObservationRequest
requestFor surface scope =
  mustRight
    (mkExactAwsValidationZoneObservationRequest surface initialRevision scope)

decode
  :: ExactAwsValidationZoneObservationRequest
  -> Text
  -> ExactResourceObservation
decode request evidence =
  mustRight
    ( decodeExactAwsValidationZoneObservation
        request
        (observedResult request evidence)
    )

observedResult
  :: ExactAwsValidationZoneObservationRequest
  -> Text
  -> Either Text ProviderIntentExecutionResult
observedResult request evidence =
  Right
    ( ProviderIntentExecutionObserved
        ( providerIntentCoordinate
            (awsValidationZoneObservationRequestProviderIntent request)
        )
        evidence
    )

initialRevision :: ObservationRevision
initialRevision = ObservationRevision 1

cascadeScope :: ObservationEvidenceScope
cascadeScope =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope "aws-route53-zone-adapter-run")
    (LinuxRke2FoundationId "home-rke2")
    (Just (AwsScope (AwsAccountId "123456789012") (AwsRegion "us-east-1")))
    ReconcileDesiredAbsent

isExactAbsent :: ExactObservationResult -> Bool
isExactAbsent result = case result of
  ExactResourceAbsent _ -> True
  _ -> False

isExactPresent :: ExactObservationResult -> Bool
isExactPresent result = case result of
  ExactResourcePresent _ -> True
  _ -> False

isExactUnobservable :: ExactObservationResult -> Bool
isExactUnobservable result = case result of
  ExactResourceUnobservable _ -> True
  _ -> False

isJustIdentity :: Maybe RegisteredIdentity -> Bool
isJustIdentity = maybe False (const True)

isLeftResult :: Either left right -> Bool
isLeftResult result = case result of
  Left _ -> True
  Right _ -> False

isRightResult :: Either left right -> Bool
isRightResult result = case result of
  Right _ -> True
  Left _ -> False

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error ("expected Right, got " <> show err)
