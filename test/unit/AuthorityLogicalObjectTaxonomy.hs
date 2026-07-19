{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.51 Increment B byte-compat pin. 'authorityLogicalObject' is the
-- single shared function the in-cluster gateway daemon AND the (future)
-- host-direct @'ClusterRetained'@ adapter both route retained-authority logical
-- names through, so a host-direct GET opens the exact envelope a daemon PUT
-- sealed. This taxonomy pins the exact stored-key namespace, AAD, and opaque-key
-- derivation for every retained coordinate family, so any drift in the encoding
-- (which would silently orphan every retained object, with no type error) fails
-- the build pre-cluster rather than surfacing only in a live host↔daemon run.
module AuthorityLogicalObjectTaxonomy
  ( authorityLogicalObjectTaxonomySuite
  )
where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Minio.EncryptedObject
  ( LogicalObject (LogicalLongLivedState, LogicalPulumiStack)
  , authorityLogicalObject
  , logicalObjectAad
  , logicalObjectName
  , opaqueObjectId
  )
import TestSupport

-- | A representative name from each retained coordinate family, paired with the
-- exact object-store key it must seal under.
retainedFamilies :: [(Text, Text)]
retainedFamilies =
  [
    ( "leases/123456789012/ca-central-1/aws-ses"
    , "long-lived-state/leases/123456789012/ca-central-1/aws-ses"
    )
  ,
    ( "target-commit-intents/123456789012/ca-central-1/aws-ses"
    , "long-lived-state/target-commit-intents/123456789012/ca-central-1/aws-ses"
    )
  ,
    ( "smtp-commit/123456789012/ca-central-1/aws-ses"
    , "long-lived-state/smtp-commit/123456789012/ca-central-1/aws-ses"
    )
  ]

sampleClusterId :: Text
sampleClusterId = "prodbox-home"

sampleHmacKey :: ByteString
sampleHmacKey = TextEncoding.encodeUtf8 "byte-compat-taxonomy-hmac-key"

authorityLogicalObjectTaxonomySuite :: SuiteBuilder ()
authorityLogicalObjectTaxonomySuite =
  describe "Sprint 4.51 authority logical-object byte-compat taxonomy" $ do
    it "routes a pulumi-stack authority name to LogicalPulumiStack under pulumi-stack/" $ do
      authorityLogicalObject "pulumi-stack/aws-ses" `shouldBe` LogicalPulumiStack "aws-ses"
      logicalObjectName (authorityLogicalObject "pulumi-stack/aws-ses") `shouldBe` "pulumi-stack/aws-ses"

    it "routes every retained coordinate family to LogicalLongLivedState under long-lived-state/" $
      mapM_ assertRetainedFamily retainedFamilies

    it "derives AAD as clusterId|<stored-key> for a retained coordinate" $ do
      let name = "leases/123456789012/ca-central-1/aws-ses"
          expectedKey = "long-lived-state/leases/123456789012/ca-central-1/aws-ses"
      logicalObjectAad sampleClusterId (authorityLogicalObject name)
        `shouldBe` TextEncoding.encodeUtf8 (sampleClusterId <> "|" <> expectedKey)

    it "derives the opaque key identically to a directly-constructed LogicalLongLivedState" $ do
      let name = "smtp-commit/123456789012/ca-central-1/aws-ses"
      opaqueObjectId sampleHmacKey (authorityLogicalObject name)
        `shouldBe` opaqueObjectId sampleHmacKey (LogicalLongLivedState name)

    it "derives the pulumi-stack opaque key identically to a directly-constructed LogicalPulumiStack" $
      opaqueObjectId sampleHmacKey (authorityLogicalObject "pulumi-stack/aws-ses")
        `shouldBe` opaqueObjectId sampleHmacKey (LogicalPulumiStack "aws-ses")

assertRetainedFamily :: (Text, Text) -> Expectation
assertRetainedFamily (name, expectedKey) = do
  authorityLogicalObject name `shouldBe` LogicalLongLivedState name
  logicalObjectName (authorityLogicalObject name) `shouldBe` expectedKey
