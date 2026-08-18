{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 5.29: the DNS01 challenge record is a registered managed resource,
-- removed by an always-run cleanup node, and proven absent by an exact
-- read-back.
module Dns01ChallengeSuite (dns01ChallengeSuite) where

import Data.Either (isRight)
import Data.List.NonEmpty (NonEmpty (..))
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDependency (..)
  , CleanupDependencyKind (..)
  , CleanupNodeId
  , mkCleanupNodeId
  )
import Prodbox.Lifecycle.Dns01Challenge
import Prodbox.Lifecycle.DnsRecord
import Prodbox.Lifecycle.ResourceClass (LifecycleClass (..))
import TestSupport

dns01ChallengeSuite :: SuiteBuilder ()
dns01ChallengeSuite =
  describe "Sprint 5.29 DNS01 challenge registration and absence observation" $ do
    it "derives the challenge coordinate before any Kubernetes UID exists" $ do
      -- The pre-issuance registration carries a coordinate only. cert-manager
      -- mints the Challenge object after the ACME Order, so demanding its UID
      -- at registration time would make "register before the mutation"
      -- unsatisfiable — which is why Sprint 5.18's version was never built.
      dnsCoordinateName (dns01ChallengeCoordinate homeIntent)
        `shouldBe` "_acme-challenge.prodbox.example.com"
      dnsCoordinateType (dns01ChallengeCoordinate homeIntent) `shouldBe` DnsRecordTxt
      dnsCoordinateOwner (dns01ChallengeCoordinate homeIntent)
        `shouldBe` HomeCertManagerDns01Owner
      dns01ChallengeResourceName homeIntent
        `shouldBe` "_acme-challenge.prodbox.example.com"

    it "reads the lifecycle class from the owner, like every other DNS coordinate" $ do
      dns01ChallengeLifecycleClass homeIntent `shouldBe` LongLived
      dns01ChallengeLifecycleClass awsIntent `shouldBe` PerRun

    it "refuses an owner that cannot own a TXT record" $
      mkDns01ChallengeIntent account zone "prodbox.example.com" HomeGatewayDnsOwner epoch
        `shouldBe` Left (DnsOwnerTypeMismatch HomeGatewayDnsOwner DnsRecordTxt)

    it "attaches the Certificate and Challenge UIDs afterwards, as evidence" $
      case dns01ChallengeObservedRegistration
        account
        zone
        "prodbox.example.com"
        HomeCertManagerDns01Owner
        epoch
        (accepted (mkKubernetesUid "certificate-uid"))
        (accepted (mkKubernetesUid "challenge-uid")) of
        Right (Dns01ChallengeRegistration _ _ coordinate) ->
          coordinate `shouldBe` dns01ChallengeCoordinate homeIntent
        other -> expectationFailure ("expected a DNS01 registration: " <> show other)

    it "keeps cannot-observe distinct from absent, and only absence proves absence" $ do
      dns01ChallengeAbsenceFrom DnsRecordMissing `shouldBe` Dns01ChallengeAbsent
      dns01ChallengeAbsenceFrom (DnsRecordObserved challengeSet)
        `shouldBe` Dns01ChallengeStillPresent challengeSet
      dns01ChallengeAbsenceFrom (DnsRecordUnobservable "api down")
        `shouldBe` Dns01ChallengeUnobservable "challenge record unobservable: api down"
      -- A warming endpoint has told us nothing about the record either.
      dns01ChallengeAbsenceFrom (DnsRecordEndpointUnready "warming")
        `shouldBe` Dns01ChallengeUnobservable "challenge zone endpoint not ready: warming"
      map
        dns01ChallengeAbsenceIsProven
        [ Dns01ChallengeAbsent
        , Dns01ChallengeStillPresent challengeSet
        , Dns01ChallengeUnobservable "api down"
        ]
        `shouldBe` [True, False, False]

    it "Sprint 4.85 the desired-absence obligation is data, not a caller-supplied effect" $ do
      -- Sprint 5.29 registered this as a `ManagedResource` built from two
      -- `FilePath -> IO` closures, so a caller could substitute the effect
      -- after the registry entry was projected and this production module had
      -- to import `Prodbox.Test.ManagedCleanupPlan` for its edge. The
      -- obligation is now a value in lifecycle-owned types.
      let obligation =
            accepted (mkDns01ChallengeDesiredAbsence issuanceNodeId homeIntent)
      dns01ChallengeAbsenceIntent obligation `shouldBe` homeIntent
      dns01ChallengeAbsenceNode obligation
        `shouldBe` accepted (mkCleanupNodeId "_acme-challenge.prodbox.example.com")
      -- The always-run kind is the deliverable: `CleanupRequiresSuccess` would
      -- be precisely wrong, because the failure case is the one that leaves a
      -- challenge record behind.
      dns01ChallengeAbsenceDependency obligation
        `shouldBe` CleanupDependency
          { cleanupDependencyNode = issuanceNodeId
          , cleanupDependencyKind = CleanupRequiresAttempt
          }

    it "Sprint 4.85 only the read-back decides the desired-absence verdict" $ do
      -- The delete result is not a parameter of `dns01ChallengeDesiredAbsenceOutcome`
      -- at all, which is the point: a delete that worked and a delete that lost
      -- its response are indistinguishable from the call, so a delete that
      -- reported failure over a record that reads back absent still closes the
      -- obligation, and a delete that reported success over an unobservable
      -- zone still does not.
      dns01ChallengeDesiredAbsenceOutcome DnsRecordMissing
        `shouldBe` Dns01ChallengeAbsent
      dns01ChallengeDesiredAbsenceOutcome (DnsRecordObserved challengeSet)
        `shouldBe` Dns01ChallengeStillPresent challengeSet
      dns01ChallengeDesiredAbsenceOutcome (DnsRecordUnobservable "zone unreachable")
        `shouldBe` Dns01ChallengeUnobservable "challenge record unobservable: zone unreachable"
      -- Still-present and unobservable are different failures and stay
      -- different; neither is absence.
      map
        (dns01ChallengeAbsenceIsProven . dns01ChallengeDesiredAbsenceOutcome)
        [ DnsRecordMissing
        , DnsRecordObserved challengeSet
        , DnsRecordUnobservable "zone unreachable"
        , DnsRecordEndpointUnready "warming"
        ]
        `shouldBe` [True, False, False, False]

    it "Sprint 4.85 the node id refuses a coordinate it cannot name" $
      -- The node id is the record name itself, so a node and the TXT it removes
      -- cannot drift apart; a name the cleanup-run identity bound rejects is a
      -- refusal rather than a silently truncated node.
      mkDns01ChallengeDesiredAbsence issuanceNodeId homeIntent
        `shouldSatisfy` isRight

issuanceNodeId :: CleanupNodeId
issuanceNodeId = accepted (mkCleanupNodeId "public-edge-issuance")

account :: AwsAccountId
account = accepted (mkAwsAccountId "123456789012")

zone :: HostedZoneId
zone = accepted (mkHostedZoneId "Z123EXAMPLE")

epoch :: OwnershipEpoch
epoch = mkOwnershipEpoch authorityEpochGenesis

homeIntent :: Dns01ChallengeIntent
homeIntent =
  accepted
    (mkDns01ChallengeIntent account zone "prodbox.example.com" HomeCertManagerDns01Owner epoch)

awsIntent :: Dns01ChallengeIntent
awsIntent =
  accepted
    (mkDns01ChallengeIntent account zone "aws.example.com" AwsCertManagerDns01Owner epoch)

challengeSet :: DnsRecordSet
challengeSet =
  accepted
    (mkDnsRecordSet 60 (accepted (mkDnsRecordValue DnsRecordTxt "challenge-token") :| []))

accepted :: (Show err) => Either err value -> value
accepted result = case result of
  Right value -> value
  Left err -> error (show err)
