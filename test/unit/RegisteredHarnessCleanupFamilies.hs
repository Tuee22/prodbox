{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module RegisteredHarnessCleanupFamilies (registeredHarnessCleanupFamiliesSuite) where

import CleanupScopeFixtures
import Data.Either (isLeft)
import Prodbox.Capacity.SesCaptureCleanupBudget
import Prodbox.ControlPlane.ProviderWorkerExecution (ProviderIntentExecutionResult (..))
import Prodbox.Lifecycle.DnsRecord (mkHostedZoneId)
import Prodbox.Lifecycle.ProviderWorker.Evidence (encodeProviderEvidence, providerEvidenceText)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import Prodbox.Lifecycle.Teardown.Dns01ChallengeRecordAdapter
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry (lifecycleRegistryRevision)
import Prodbox.Lifecycle.Teardown.ResourceScopeBindings
import Prodbox.Lifecycle.Teardown.SesInviteMailAdapter
import TestSupport

registeredHarnessCleanupFamiliesSuite :: SuiteBuilder ()
registeredHarnessCleanupFamiliesSuite = describe "Sprint 5.53 registered harness cleanup families" $ do
  it "refuses a historical scope with no home binding before an observation can be made" $
    mkExactDns01ChallengeObservationRequestForKey
      ExplicitPerRunSurface
      HomeDns01ChallengeRecordKey
      revision
      unbound
      `shouldBe` Left Dns01ChallengeHomeBindingMissing
  it "selects the retained parent zone and exact names independently of the AWS subzone" $ do
    let request = homeRequest
    dns01ChallengeObservationRequestProviderIntent request
      `shouldBe` ObserveHomeDns01Records fixtureHomeDns01Scope
    evidenceAwsDnsZone scope `shouldSatisfy` (/= Just (homeDns01HostedZone fixtureHomeDns01Scope))
  it "never authorizes a home owner delete for another record name" $ do
    let response = homeResponse [["record", "_acme-challenge.foreign.example.test."]]
    observed <- mustIO (decodeExactDns01ChallengeObservation homeRequest (Right response))
    authorizeExactDns01ChallengeOwnerDelete homeRequest observed `shouldSatisfy` isLeft
  it "binds a present home record to the home owner-delete key and retained scope" $ do
    let response = homeResponse [["record", "_acme-challenge.auth.example.test."]]
    observed <- mustIO (decodeExactDns01ChallengeObservation homeRequest (Right response))
    authorization <- mustIO (authorizeExactDns01ChallengeOwnerDelete homeRequest observed)
    fmap dns01ChallengeOwnerDeleteResourceKey authorization `shouldBe` Just HomeDns01ChallengeRecordKey
    fmap dns01ChallengeOwnerDeleteScope authorization `shouldBe` Just scope
  it "closes home DNS01 only through a separate canonical empty read-back" $ do
    confirmExactDns01ChallengeAbsence homeRequest (Right (homeResponse []))
      `shouldSatisfy` (not . isLeft)
    confirmExactDns01ChallengeAbsence homeRequest (Left "provider unavailable")
      `shouldSatisfy` isLeft
  it "keeps the complete three-scan reaper inside the existing child-time budget" $ do
    maximumCleanupMailAwsChildCalls `shouldBe` 53
    (maximumCleanupMailAwsChildCalls * 30) `shouldSatisfy` (< (1800 :: Int))
  it "admits only bounded unique hexadecimal version identities in mail cleanup evidence" $ do
    let intent = ObserveSesInviteMailResidue fixtureInviteMailScope
        digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        canonical = must (renderInviteMailCleanupEvidence fixtureInviteMailScope [digest])
    validateProviderIntentEvidence intent canonical `shouldBe` Right canonical
    mapM_
      ( \identifiers -> renderInviteMailCleanupEvidence fixtureInviteMailScope identifiers `shouldSatisfy` isLeft
      )
      [ ["https://auth.example.test/action-token?key=secret"]
      , [digest, digest]
      , replicate (maximumCleanupMailVersions + 1) digest
      ]
  it "refuses raw invitation material before new cleanup evidence can be retained" $
    validateProviderIntentEvidence
      (ObserveSesInviteMailResidue fixtureInviteMailScope)
      "https://auth.example.test/action-token?key=fictional-one-time-secret"
      `shouldSatisfy` isLeft
  it "refuses a historical scope with no registered mail coordinates" $
    mkInviteMailCleanupRequest ExplicitPerRunSurface revision unbound
      `shouldBe` Left InviteMailCleanupBindingMissing
  it "selects the exact registered bucket and recipient for both mail halves" $ do
    inviteMailCleanupObservationIntent mailRequest
      `shouldBe` ObserveSesInviteMailResidue fixtureInviteMailScope
    observed <-
      mustIO
        ( decodeInviteMailCleanupObservation
            mailRequest
            ( Right
                (mailResponse [["version", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]])
            )
        )
    authorization <- mustIO (authorizeInviteMailCleanup mailRequest observed)
    fmap inviteMailCleanupReapIntent authorization
      `shouldBe` Just (ReapSesInviteMailResidue fixtureInviteMailScope)
    fmap inviteMailCleanupAuthorizationScope authorization `shouldBe` Just scope
  it "returns no mail mutation authorization after a complete empty read" $ do
    observed <- mustIO (decodeInviteMailCleanupObservation mailRequest (Right (mailResponse [])))
    authorizeInviteMailCleanup mailRequest observed `shouldBe` Right Nothing
    exactObservationResult observed `shouldSatisfy` isAbsent
  it "never launders an unreadable mail listing or a mutation result into absence" $ do
    observed <- mustIO (decodeInviteMailCleanupObservation mailRequest (Left "listing denied"))
    authorizeInviteMailCleanup mailRequest observed `shouldSatisfy` isLeft
    let intent = inviteMailCleanupObservationIntent mailRequest
    decodeInviteMailCleanupObservation
      mailRequest
      (Right (ProviderIntentExecutionApplied (providerIntentCoordinate intent) "acknowledged"))
      `shouldSatisfy` isLeft
 where
  homeRequest =
    must
      ( mkExactDns01ChallengeObservationRequestForKey
          ExplicitPerRunSurface
          HomeDns01ChallengeRecordKey
          revision
          scope
      )
  mailRequest = must (mkInviteMailCleanupRequest ExplicitPerRunSurface revision scope)
  homeResponse records =
    let intent = dns01ChallengeObservationRequestProviderIntent homeRequest
        evidence =
          providerEvidenceText
            ( must
                ( encodeProviderEvidence
                    (providerIntentEvidenceBound intent)
                    dns01ChallengeRecordEvidenceFamily
                    (["family", "ZPARENTEXAMPLE", providerIntentResourceKey intent] : records)
                )
            )
     in ProviderIntentExecutionObserved (providerIntentCoordinate intent) evidence
  mailResponse versions =
    let intent = inviteMailCleanupObservationIntent mailRequest
        evidence =
          providerEvidenceText
            ( must
                ( encodeProviderEvidence
                    (providerIntentEvidenceBound intent)
                    inviteMailCleanupEvidenceFamily
                    (["family", providerIntentResourceKey intent] : versions)
                )
            )
     in ProviderIntentExecutionObserved (providerIntentCoordinate intent) evidence
  isAbsent result = case result of
    ExactResourceAbsent _ -> True
    _ -> False

scope :: ObservationEvidenceScope
scope =
  mkObservationEvidenceScopeWithResourceBindings
    ExplicitPerRun
    lifecycleRegistryRevision
    (DurableObservationRunScope "fixture-family-run")
    (LinuxRke2FoundationId "fixture-home")
    (Just (AwsScope (AwsAccountId "123456789012") (AwsRegion (fixtureAwsRegion FixtureCaCentral1))))
    (Just (must (mkHostedZoneId "ZSUBZONEEXAMPLE")))
    (Just (mkResourceScopeBindings (Just fixtureHomeDns01Scope) (Just fixtureInviteMailScope)))
    ReconcileDesiredAbsent

unbound :: ObservationEvidenceScope
unbound =
  mkObservationEvidenceScope
    ExplicitPerRun
    lifecycleRegistryRevision
    (DurableObservationRunScope "fixture-family-run")
    (LinuxRke2FoundationId "fixture-home")
    (Just (AwsScope (AwsAccountId "123456789012") (AwsRegion (fixtureAwsRegion FixtureCaCentral1))))
    ReconcileDesiredAbsent

revision :: ObservationRevision
revision = ObservationRevision 1

must :: (Show error) => Either error value -> value
must = either (error . show) id

mustIO :: (Show error) => Either error value -> IO value
mustIO = either (fail . show) pure
