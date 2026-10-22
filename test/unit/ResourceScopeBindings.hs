{-# LANGUAGE OverloadedStrings #-}

module ResourceScopeBindings (resourceScopeBindingsSuite) where

import Data.Either (isLeft)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Prodbox.Capacity.Dns01CleanupBudget
import Prodbox.Lifecycle.DnsRecord (mkHostedZoneId)
import Prodbox.Lifecycle.Teardown.ResourceScopeBindings
import Prodbox.Settings.Coordinate (mkS3BucketName)
import TestSupport

resourceScopeBindingsSuite :: SuiteBuilder ()
resourceScopeBindingsSuite = describe "Sprint 5.53 durable cleanup resource bindings" $ do
  it "keeps the home parent zone distinct from other cleanup coordinates" $ do
    let scope = must (mkHomeDns01Scope zone ("auth.example.test" :| []))
        bindings = mkResourceScopeBindings (Just scope) Nothing
    homeDns01HostedZone scope `shouldBe` zone
    homeDns01RecordNames scope `shouldBe` ("_acme-challenge.auth.example.test." :| [])
    resourceScopeHomeDns01 bindings `shouldBe` Just scope
    resourceScopeInviteMail bindings `shouldBe` Nothing
  it "derives the same exact challenge name for a wildcard and its base domain" $ do
    let scope = must (mkHomeDns01Scope zone ("*.example.test" :| ["example.test", "auth.example.test"]))
    homeDns01RecordNames scope
      `shouldBe` ("_acme-challenge.auth.example.test." :| ["_acme-challenge.example.test."])
  it "normalizes exact record names without admitting another record family" $ do
    let scope = must (mkHomeDns01ScopeForRecords zone ("_acme-challenge.AUTH.EXAMPLE.TEST" :| []))
    homeDns01RecordNames scope `shouldBe` ("_acme-challenge.auth.example.test." :| [])
    mapM_
      (\record -> mkHomeDns01ScopeForRecords zone (record :| []) `shouldSatisfy` isLeft)
      [ "auth.example.test"
      , "_acme-challenge."
      , "_acme-challenge.*.example.test"
      , "_acme-challenge.auth.example.test\n"
      ]
  it "bounds home names by the shared evidence row cardinality before cleanup admission" $ do
    let names =
          [ Text.pack ("host" <> show index <> ".example.test") | index <- [1 .. dns01CleanupMaximumRecordNames]
          ]
    case names of
      first : rest -> do
        mkHomeDns01Scope zone (first :| rest) `shouldSatisfy` (not . isLeft)
        mkHomeDns01Scope zone (first :| (rest <> ["overflow.example.test"]))
          `shouldBe` Left
            (HomeDns01RecordSetTooLarge (dns01CleanupMaximumRecordNames + 1) dns01CleanupMaximumRecordNames)
      [] -> expectationFailure "DNS01 budget has no record slots"
  it "does not allow an exact recipient binding to match another invitation" $ do
    let scope = must (mkInviteMailScope bucket (ExactInviteRecipient "test-abc123@receive.example.test"))
    inviteMailBucket scope `shouldBe` bucket
    inviteMailRecipientMatches scope "test-abc123@receive.example.test" `shouldBe` True
    inviteMailRecipientMatches scope "test-def456@receive.example.test" `shouldBe` False
    inviteMailRecipientMatches scope "test-abc123@other.example.test" `shouldBe` False
  it "limits a whole-family selector to hexadecimal validation recipients in its exact receive domain" $ do
    let scope = must (mkInviteMailScope bucket (ValidationInviteDomain "receive.example.test"))
    inviteMailRecipientMatches scope "test-abc123@receive.example.test" `shouldBe` True
    inviteMailRecipientMatches scope "test-123456@receive.example.test" `shouldBe` True
    mapM_
      (\recipient -> inviteMailRecipientMatches scope recipient `shouldBe` False)
      [ "operator@receive.example.test"
      , "test-bob@receive.example.test"
      , "test-abc123@receive.example.test.evil"
      , "test-abc123@other.example.test"
      ]
  it "refuses malformed recipients and foreign protocol material" $
    mapM_
      (\recipient -> mkInviteMailScope bucket (ExactInviteRecipient recipient) `shouldSatisfy` isLeft)
      [ ""
      , "test-@receive.example.test"
      , "test-abc123@@receive.example.test"
      , "test-ABC123@receive.example.test"
      , "test-abc123@https://receive.example.test"
      , "test-abc123@receive.example.test\n"
      ]
  it "keeps both bound families together without changing their coordinates" $ do
    let home = must (mkHomeDns01Scope zone ("auth.example.test" :| []))
        mail = must (mkInviteMailScope bucket (ExactInviteRecipient "test-abc123@receive.example.test"))
        bindings = mkResourceScopeBindings (Just home) (Just mail)
    resourceScopeHomeDns01 bindings `shouldBe` Just home
    resourceScopeInviteMail bindings `shouldBe` Just mail
    emptyResourceScopeBindings `shouldBe` mkResourceScopeBindings Nothing Nothing
 where
  zone = must (mkHostedZoneId "Z0123456789ABCDEFGHIJ")
  bucket = must (mkS3BucketName "fixture-capture-mail")

must :: (Show error) => Either error value -> value
must = either (error . show) id
