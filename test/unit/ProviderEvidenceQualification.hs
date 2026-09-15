{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.99: the two-sided table for
-- @PROVIDER-EVIDENCE-CONTROL-CHARACTER-UNSETTLEABLE-2026-09-13@.
--
-- Standard P requires work opened by a counterexample to carry a reproducer
-- whose superseded and replacement results both stay auditable after the legacy
-- code is deleted. This sprint deletes all six encoders, so the superseded bytes
-- are frozen here as literals rather than produced by calling anything — by the
-- time this matters, there is nothing left to call.
--
-- The refusal is never restated. Each case asks
-- 'validateProviderIntentEvidence' with the producer's own intent and compares
-- against the wording that function publishes; a test that re-implemented the
-- character predicate would pass even if the rule were deleted.
module ProviderEvidenceQualification
  ( providerEvidenceQualificationSuite
  )
where

import Control.Monad (forM_)
import Data.Text (Text)
import Prodbox.Lifecycle.ProviderWorker.Evidence
  ( encodeProviderEvidence
  , providerEvidenceFamilyOwnBound
  , providerEvidenceText
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import TestSupport

-- | The frozen superseded rendering for each producer, with the intent it was
-- returned under.  These strings are the artifact; they are not regenerated.
supersededRenderings :: [(Text, ProviderIntent, Text)]
supersededRenderings =
  [
    ( "native-stack-family"
    , ObserveNativeStackFamily nativeRef nativeConfig
    , "prodbox-native-stack-family/v1\n\
      \binding|aws-test|123456789012|"
        <> fixtureAwsRegion FixtureUsEast1
        <> "|none\n\
           \resource|vpc/vpc-1\n"
    )
  ,
    ( "eks-iam-role-family"
    , ObserveEksIamRoleFamily "cluster-role" "cluster-policy"
    , "prodbox-eks-iam-family/v1\nrole|cluster-role|absent"
    )
  ,
    ( "owned-resource-tags"
    , ObserveOwnedResourceTags (ProviderOwnedTagKeyQuery "prodbox.io/managed-by")
    , "query\tkey\tprodbox.io/managed-by\n\
      \resource\tarn:aws:s3:::bucket\tprodbox.io/managed-by\tprodbox\n\
      \complete\t3"
    )
  ,
    ( "eks-lbc-family"
    , ObserveEksLoadBalancerControllerFamily "public-edge" "prodbox.io/managed-by"
    , "prodbox-eks-lbc-family/v1\nload-balancer|arn:aws:elasticloadbalancing:lb/public-edge"
    )
  ,
    ( "validation-hosted-zones"
    , ObserveValidationHostedZones "prodbox-dns-aws-"
    , "prodbox-dns-aws-\nZ1234 prodbox-dns-aws-abc.example.test."
    )
  ,
    ( "dns01-challenge-records"
    , ObserveDns01ChallengeRecords "Z0123456789ABCDEFGHIJ" "_acme-challenge."
    , "Z0123456789ABCDEFGHIJ _acme-challenge.\n_acme-challenge.app.example.test."
    )
  ]

-- | The replacement for each producer, rendered by the canonical encoder
-- against its own family.
replacementRenderings :: [(Text, ProviderIntent, Text)]
replacementRenderings =
  [ (label, intent, render family rows)
  | (label, intent, family, rows) <-
      [
        ( "native-stack-family"
        , ObserveNativeStackFamily nativeRef nativeConfig
        , nativeStackFamilyEvidenceFamily
        ,
          [ ["binding", "aws-test", "123456789012", fixtureAwsRegion FixtureUsEast1, "none"]
          , ["resource", "vpc/vpc-1"]
          ]
        )
      ,
        ( "eks-iam-role-family"
        , ObserveEksIamRoleFamily "cluster-role" "cluster-policy"
        , eksIamRoleFamilyEvidenceFamily
        , [["role", "cluster-role", "absent"]]
        )
      ,
        ( "owned-resource-tags"
        , ObserveOwnedResourceTags (ProviderOwnedTagKeyQuery "prodbox.io/managed-by")
        , ownedResourceTagEvidenceFamily
        ,
          [ ["query", "key", "prodbox.io/managed-by"]
          , ["complete", "3"]
          , ["resource", "arn:aws:s3:::bucket", "prodbox.io/managed-by", "prodbox"]
          ]
        )
      ,
        ( "eks-lbc-family"
        , ObserveEksLoadBalancerControllerFamily "public-edge" "prodbox.io/managed-by"
        , eksLoadBalancerControllerFamilyEvidenceFamily
        , [["load-balancer", "arn:aws:elasticloadbalancing:lb/public-edge"]]
        )
      ,
        ( "validation-hosted-zones"
        , ObserveValidationHostedZones "prodbox-dns-aws-"
        , validationHostedZoneEvidenceFamily
        ,
          [ ["family", "prodbox-dns-aws-"]
          , ["zone", "Z1234", "prodbox-dns-aws-abc.example.test."]
          ]
        )
      ,
        ( "dns01-challenge-records"
        , ObserveDns01ChallengeRecords "Z0123456789ABCDEFGHIJ" "_acme-challenge."
        , dns01ChallengeRecordEvidenceFamily
        ,
          [ ["family", "Z0123456789ABCDEFGHIJ", "_acme-challenge."]
          , ["record", "_acme-challenge.app.example.test."]
          ]
        )
      ]
  ]
 where
  render family rows =
    case encodeProviderEvidence (providerEvidenceFamilyOwnBound family) family rows of
      Right evidence -> providerEvidenceText evidence
      Left refusal -> error ("replacement refused: " <> show refusal)

providerEvidenceQualificationSuite :: SuiteBuilder ()
providerEvidenceQualificationSuite =
  describe "PROVIDER-EVIDENCE-CONTROL-CHARACTER-UNSETTLEABLE-2026-09-13" $ do
    it "refuses every frozen superseded rendering, each under its own intent" $ do
      -- The cause is compared against the wording the validator publishes, not
      -- re-derived: a test that re-implemented the character predicate would
      -- keep passing if the rule itself were deleted.
      forM_ supersededRenderings $ \(_, intent, superseded) ->
        validateProviderIntentEvidence intent superseded
          `shouldBe` Left "provider evidence carries a control character"

    it "admits every replacement rendering, each under its own intent" $ do
      forM_ replacementRenderings $ \(_, intent, replacement) ->
        validateProviderIntentEvidence intent replacement `shouldBe` Right replacement

    it "covers every producer on both sides" $ do
      map firstOf supersededRenderings `shouldBe` map firstOf replacementRenderings
      length supersededRenderings `shouldBe` 6
 where
  firstOf (label, _, _) = label

nativeRef :: ProviderNativeStackFamilyRef
nativeRef =
  expectRight
    ( mkProviderNativeStackFamilyRef
        (expectRight (mkProviderStackRef "aws-test"))
        "123456789012"
        (fixtureAwsRegion FixtureUsEast1)
        Nothing
    )

nativeConfig :: ProviderStackConfig
nativeConfig = expectRight (mkAwsTestProviderStackConfig "127.0.0.1/32")

expectRight :: (Show error) => Either error value -> value
expectRight result = case result of
  Right value -> value
  Left err -> error ("qualification fixture failed: " <> show err)
