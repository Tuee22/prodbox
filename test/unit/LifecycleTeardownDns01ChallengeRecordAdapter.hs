{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownDns01ChallengeRecordAdapter
  ( lifecycleTeardownDns01ChallengeRecordAdapterSuite
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.CleanupRun (mkCleanupRunId)
import Prodbox.Lifecycle.DnsRecord (HostedZoneId, mkHostedZoneId)
import Prodbox.Lifecycle.OwnedResourceTags (dns01ChallengeRecordNamePrefix)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , providerIntentCoordinate
  )
import Prodbox.Lifecycle.Teardown.Dns01ChallengeOwnerDeleteInterpreter
import Prodbox.Lifecycle.Teardown.Dns01ChallengeRecordAdapter
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.RegisteredTargetExecutor
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownDns01ChallengeRecordAdapterSuite :: SuiteBuilder ()
lifecycleTeardownDns01ChallengeRecordAdapterSuite =
  describe "Sprint 7.36 registered DNS01 challenge record family" $ do
    it "registers the family only alongside its executor" $ do
      -- The same pairing rule the two 2026-08-21 adapters carry: registering a
      -- descriptor compiles a mandatory absence read-back, and a surface that
      -- mints completion asserts every such read-back succeeded.
      registeredTargetExecutorFor AwsDns01ChallengeRecordKey
        `shouldBe` Right Dns01ChallengeRecordFamilyExecutor
      lookupRegisteredIdentity AwsDns01ChallengeRecordKey
        `shouldSatisfy` isJustIdentity

    it "has no provider reap intent at all, which is the contract" $ do
      -- Every other registered executor's mutation is a ProviderIntent. This
      -- one's is a Kubernetes owner delete, so the Provider capability set is
      -- deliberately observation-only for this family: there is no constructor
      -- a caller could reach for to delete the record directly.
      let cascade = requestFor CascadeSurface cascadeScope
      dns01ChallengeObservationRequestProviderIntent cascade
        `shouldBe` ObserveDns01ChallengeRecords
          "Z0123456789ABCDEFGHIJ"
          dns01ChallengeRecordNamePrefix

    it "refuses a run that named no DNS hosted zone" $ do
      -- The refusal is the deliverable. A challenge record swept in the wrong
      -- zone is either a no-op that reads as absence, or a deletion in an
      -- operator's parent zone.
      mkExactDns01ChallengeObservationRequest
        CascadeSurface
        initialRevision
        zonelessScope
        `shouldBe` Left Dns01ChallengeHostedZoneMissing

    it "derives the exact provider observation from the Sprint 7.38 compiled cascade scope" $ do
      let compiled =
            mustRight
              ( compileDesiredAbsenceGraph
                  (mustRight (mkCleanupRunId "dns01-compiled-cascade"))
                  (LinuxRke2FoundationId "home-rke2")
                  ( Just
                      ( AwsScope
                          (AwsAccountId "123456789012")
                          (AwsRegion (fixtureAwsRegion FixtureUsEast1))
                      )
                  )
                  (Just challengeZone)
                  CascadeSurface
              )
          request =
            mustRight
              ( mkExactDns01ChallengeObservationRequest
                  CascadeSurface
                  initialRevision
                  (compiledDesiredAbsenceObservationScope compiled)
              )
      dns01ChallengeObservationRequestProviderIntent request
        `shouldBe` ObserveDns01ChallengeRecords
          "Z0123456789ABCDEFGHIJ"
          dns01ChallengeRecordNamePrefix

    it "reads an empty family as absent and a listed record as present" $ do
      let cascade = requestFor CascadeSurface cascadeScope
          absent = decode cascade familyLine
          present = decode cascade (familyLine <> "\n" <> challengeRecord)
      exactObservationResult absent `shouldSatisfy` isExactAbsent
      exactObservationResult present `shouldSatisfy` isExactPresent

    it "never turns an unobtainable scan into an absence" $ do
      let cascade = requestFor CascadeSurface cascadeScope
          unobservable =
            mustRight
              ( decodeExactDns01ChallengeObservation
                  cascade
                  (Left "route53 list-resource-record-sets was refused")
              )
      exactObservationResult unobservable `shouldSatisfy` isExactUnobservable
      -- An answer for another zone is unobservable rather than this zone's
      -- absence, which is the shape a cross-zone scan would otherwise take.
      let otherZone =
            mustRight
              ( decodeExactDns01ChallengeObservation
                  cascade
                  (observedResult cascade "ZOTHERZONE _acme-challenge.\n")
              )
      exactObservationResult otherZone `shouldSatisfy` isExactUnobservable

    it "refuses a response bound to another intent" $ do
      let cascade = requestFor CascadeSurface cascadeScope
          otherCoordinate =
            providerIntentCoordinate
              (ObserveDns01ChallengeRecords "ZOTHERZONE" dns01ChallengeRecordNamePrefix)
      decodeExactDns01ChallengeObservation
        cascade
        (Right (ProviderIntentExecutionObserved otherCoordinate familyLine))
        `shouldSatisfy` isLeftResult

    it "authorizes the Kubernetes owner delete only from a positive observation" $ do
      let cascade = requestFor CascadeSurface cascadeScope
          absent = decode cascade familyLine
          present = decode cascade (familyLine <> "\n" <> challengeRecord)
      fmap
        (fmap dns01ChallengeOwnerDeleteRecordNamePrefix)
        (authorizeExactDns01ChallengeOwnerDelete cascade absent)
        `shouldBe` Right Nothing
      fmap
        (fmap dns01ChallengeOwnerDeleteObservedRecords)
        (authorizeExactDns01ChallengeOwnerDelete cascade present)
        `shouldBe` Right (Just (challengeRecord :| []))

    it "closes the family only on a separate exact read-back" $ do
      -- Load-bearing rather than ceremonial here: cert-manager removes the
      -- record asynchronously through a finalizer after its object is gone, so
      -- a successful owner delete genuinely is not absence yet.
      let cascade = requestFor CascadeSurface cascadeScope
      confirmExactDns01ChallengeAbsence
        cascade
        (observedResult cascade (familyLine <> "\n" <> challengeRecord))
        `shouldSatisfy` isLeftResult
      confirmExactDns01ChallengeAbsence
        cascade
        (observedResult cascade familyLine)
        `shouldSatisfy` isRightResult

    it "parses the family line and its record names" $ do
      parseDns01ChallengeObservation "" `shouldSatisfy` isLeftResult
      parseDns01ChallengeObservation familyLine `shouldBe` Right (familyLine, [])
      parseDns01ChallengeObservation (familyLine <> "\n_acme-challenge.a.\n\n_acme-challenge.b.")
        `shouldBe` Right (familyLine, ["_acme-challenge.a.", "_acme-challenge.b."])

    it "joins observed records to owners through the one prefix constant" $ do
      -- Route 53 answers with a trailing dot and cert-manager's spec.dnsName
      -- carries none. An unnormalized comparison would find no owner for every
      -- record, which would report every family as orphaned.
      dns01ChallengeOwnerRecordName (owner "cert-manager" "chal-1" "app.example.test")
        `shouldBe` "_acme-challenge.app.example.test."
      dns01ChallengeOwnerRecordName (owner "cert-manager" "chal-2" "App.Example.Test.")
        `shouldBe` "_acme-challenge.app.example.test."

    it "selects only the owners the observation named, and reports the rest orphaned" $ do
      let observed =
            "_acme-challenge.app.example.test." :| ["_acme-challenge.gone.example.test."]
          owners =
            [ owner "cert-manager" "chal-1" "app.example.test"
            , owner "cert-manager" "chal-other" "unrelated.example.test"
            ]
          selection = selectDns01ChallengeOwnersToDelete observed owners
      map dns01ChallengeOwnerName (dns01ChallengeOwnersToDelete selection)
        `shouldBe` ["chal-1"]
      -- A record whose owner is already gone cannot be removed by an owner
      -- delete, and saying so is the only honest answer: reporting the delete
      -- as applied would send the read-back looking for an absence nothing was
      -- going to produce.
      dns01ChallengeOrphanedRecords selection
        `shouldBe` ["_acme-challenge.gone.example.test."]

    it "makes a malformed owner row unusable rather than shortening the owner set" $ do
      -- A dropped row reads as an orphaned record, which is a different fact
      -- with a different remedy.
      parseDns01ChallengeOwners "cert-manager|chal-1|app.example.test"
        `shouldBe` Right [owner "cert-manager" "chal-1" "app.example.test"]
      parseDns01ChallengeOwners "cert-manager|chal-1" `shouldSatisfy` isLeftResult
      parseDns01ChallengeOwners "cert-manager||app.example.test"
        `shouldSatisfy` isLeftResult

owner :: Text -> Text -> Text -> Dns01ChallengeOwner
owner namespace name dnsName =
  Dns01ChallengeOwner
    { dns01ChallengeOwnerNamespace = namespace
    , dns01ChallengeOwnerName = name
    , dns01ChallengeOwnerDnsName = dnsName
    }

familyLine :: Text
familyLine = "Z0123456789ABCDEFGHIJ " <> dns01ChallengeRecordNamePrefix

challengeRecord :: Text
challengeRecord = "_acme-challenge.app.example.test."

requestFor
  :: CleanupSurfaceWitness surface
  -> ObservationEvidenceScope
  -> ExactDns01ChallengeObservationRequest
requestFor surface scope =
  mustRight
    (mkExactDns01ChallengeObservationRequest surface initialRevision scope)

decode
  :: ExactDns01ChallengeObservationRequest
  -> Text
  -> ExactResourceObservation
decode request evidence =
  mustRight
    ( decodeExactDns01ChallengeObservation
        request
        (observedResult request evidence)
    )

observedResult
  :: ExactDns01ChallengeObservationRequest
  -> Text
  -> Either Text ProviderIntentExecutionResult
observedResult request evidence =
  Right
    ( ProviderIntentExecutionObserved
        ( providerIntentCoordinate
            (dns01ChallengeObservationRequestProviderIntent request)
        )
        evidence
    )

initialRevision :: ObservationRevision
initialRevision = ObservationRevision 1

challengeZone :: HostedZoneId
challengeZone = mustRight (mkHostedZoneId "Z0123456789ABCDEFGHIJ")

cascadeScope :: ObservationEvidenceScope
cascadeScope =
  mkObservationEvidenceScopeWithDnsZone
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope "dns01-challenge-adapter-run")
    (LinuxRke2FoundationId "home-rke2")
    (Just (AwsScope (AwsAccountId "123456789012") (AwsRegion (fixtureAwsRegion FixtureUsEast1))))
    challengeZone
    ReconcileDesiredAbsent

zonelessScope :: ObservationEvidenceScope
zonelessScope =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope "dns01-challenge-adapter-run")
    (LinuxRke2FoundationId "home-rke2")
    (Just (AwsScope (AwsAccountId "123456789012") (AwsRegion (fixtureAwsRegion FixtureUsEast1))))
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
