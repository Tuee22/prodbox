{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 5.29: the DNS01 challenge record is a registered managed resource,
-- removed by an always-run cleanup node, and proven absent by an exact
-- read-back.
module Dns01ChallengeSuite (dns01ChallengeSuite) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDependency (..)
  , CleanupDependencyKind (..)
  , CleanupNodeOutcome (..)
  , cleanupGraphNodes
  , cleanupNodeDependencies
  , cleanupNodeId
  , mkCleanupNodeId
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.Dns01Challenge
import Prodbox.Lifecycle.DnsRecord
import Prodbox.Lifecycle.ResourceClass (LifecycleClass (..))
import Prodbox.Lifecycle.ResourceRegistry (ManagedResource (..))
import Prodbox.Test.ManagedCleanupPlan
  ( ManagedCleanupEdge (..)
  , compileManagedCleanupPlan
  , managedCleanupGraph
  , runManagedCleanupNode
  )
import System.Exit (ExitCode (..))
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

    it "registers the challenge as a managed resource whose destroy reads back" $ do
      calls <- newIORef ([] :: [Text])
      let resource =
            dns01ChallengeManagedResource
              homeIntent
              (\_ -> modifyIORef' calls (++ ["delete-owner"]) >> pure (Right ()))
              (\_ -> modifyIORef' calls (++ ["read-back"]) >> pure DnsRecordMissing)
      resourceName resource `shouldBe` "_acme-challenge.prodbox.example.com"
      resourceClass resource `shouldBe` LongLived
      resourceDestroy resource "/tmp" `shouldReturn` ExitSuccess
      -- The read-back runs after the delete, always: a delete that lost its
      -- response and a delete that worked are indistinguishable from the call.
      readIORef calls `shouldReturn` ["delete-owner", "read-back"]

    it "fails the destroy when the record survives or cannot be observed" $ do
      let destroyWith deleted observed =
            resourceDestroy
              ( dns01ChallengeManagedResource
                  homeIntent
                  (\_ -> pure deleted)
                  (\_ -> pure observed)
              )
              "/tmp"
      destroyWith (Right ()) (DnsRecordObserved challengeSet) `shouldReturn` ExitFailure 1
      destroyWith (Right ()) (DnsRecordUnobservable "api down") `shouldReturn` ExitFailure 1
      -- A delete that reported failure but whose read-back proves absence is a
      -- success: absence is the postcondition, not the delete's exit code.
      destroyWith (Left "delete rejected") DnsRecordMissing `shouldReturn` ExitSuccess
      -- And a delete that reported success but cannot be read back is not.
      destroyWith (Left "delete rejected") (DnsRecordUnobservable "api down")
        `shouldReturn` ExitFailure 1

    it "renders a cleanup node that follows issuance on attempt, not on success" $ do
      let runId = accepted (mkCleanupRunId "dns01-run")
          challengeResource =
            dns01ChallengeManagedResource
              homeIntent
              (\_ -> pure (Right ()))
              (\_ -> pure DnsRecordMissing)
          issuance =
            ManagedResource
              { resourceName = issuanceNodeName
              , resourceClass = PerRun
              , resourceEnsureCommand = Nothing
              , resourceEnsurePresent = Nothing
              , resourceDestroyCommand = "fixture issuance destroy"
              , resourceDestroyCapability =
                  resourceDestroyCapability challengeResource
              , resourceDestroy = \_ -> pure ExitSuccess
              }
          edge = dns01ChallengeCleanupEdge issuanceNodeName homeIntent
          compiled =
            accepted
              ( compileManagedCleanupPlan
                  runId
                  [issuance, challengeResource]
                  [edge]
              )
          nodes = cleanupGraphNodes (managedCleanupGraph compiled)
      managedCleanupPredecessor edge `shouldBe` issuanceNodeName
      -- The always-run kind is the deliverable: `CleanupRequiresSuccess` would
      -- be precisely wrong, because the failure case is the one that leaves a
      -- challenge record behind.
      managedCleanupDependencyKind edge `shouldBe` CleanupRequiresAttempt

      let challengeNodeId = accepted (mkCleanupNodeId "managed/_acme-challenge.prodbox.example.com")
          issuanceNodeId = accepted (mkCleanupNodeId (Text.pack ("managed/" <> issuanceNodeName)))
      map cleanupNodeId nodes `shouldBe` [issuanceNodeId, challengeNodeId]
      -- The registration is present in the rendered plan BEFORE the node that
      -- reaches issuance runs — asserted on the plan, not on a live run.
      concatMap cleanupNodeDependencies (filter ((== challengeNodeId) . cleanupNodeId) nodes)
        `shouldBe` [ CleanupDependency
                       { cleanupDependencyNode = issuanceNodeId
                       , cleanupDependencyKind = CleanupRequiresAttempt
                       }
                   ]

    it "runs the deletion node after a failed issuance and surfaces its own failure" $ do
      let runId = accepted (mkCleanupRunId "dns01-failure-run")
          challengeResource =
            dns01ChallengeManagedResource
              homeIntent
              (\_ -> pure (Right ()))
              (\_ -> pure (DnsRecordUnobservable "zone unreachable"))
          compiled = accepted (compileManagedCleanupPlan runId [challengeResource] [])
      case cleanupGraphNodes (managedCleanupGraph compiled) of
        [node] -> do
          outcome <- runManagedCleanupNode "/tmp" compiled node
          -- The node's own failure is reported rather than swallowed, so the
          -- run accumulates it instead of reporting a clean teardown while a
          -- challenge record survives in the operator's parent zone.
          outcome `shouldSatisfy` isFailure
        other -> expectationFailure ("unexpected cleanup nodes: " <> show other)

issuanceNodeName :: String
issuanceNodeName = "public-edge-issuance"

isFailure :: CleanupNodeOutcome -> Bool
isFailure outcome = case outcome of
  CleanupNodeFailed _ -> True
  CleanupNodeEffectUnconfirmed _ -> True
  CleanupNodeSucceeded -> False

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
