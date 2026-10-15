{-# LANGUAGE OverloadedStrings #-}

-- | The STS identity-evidence codec.
--
-- The EKS client-auth admission once parsed the evidence with a pattern that
-- counted the leading @arn@ field as the partition. It returned 'Nothing' for
-- every well-formed ARN, so no live EKS client-auth path could succeed. These
-- cases run over real caller-identity shapes, and the pre-fix pattern stays
-- below as a negative control so the defect remains demonstrated.
module StsIdentity
  ( stsIdentitySuite
  )
where

import Control.Monad (forM_)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Aws.StsIdentity
import TestSupport

fixtureAccount :: Text
fixtureAccount = "123456789012"

identityOf :: Text -> Text -> StsPrincipal -> StsIdentity
identityOf partition service = StsIdentity partition service fixtureAccount

realShapes :: [(String, Text, StsIdentity)]
realShapes =
  [
    ( "the Provider's own assumed-role session"
    , "arn:aws:sts::123456789012:assumed-role/prodbox-lifecycle-provider/prodbox-provider-worker"
    , identityOf "aws" "sts" (StsAssumedRole "prodbox-lifecycle-provider" "prodbox-provider-worker")
    )
  ,
    ( "an IAM user"
    , "arn:aws:iam::123456789012:user/prodbox"
    , identityOf "aws" "iam" (StsIamUser "prodbox")
    )
  ,
    ( "an IAM user under a path"
    , "arn:aws:iam::123456789012:user/division/team/alice"
    , identityOf "aws" "iam" (StsIamUser "alice")
    )
  ,
    ( "a federated user"
    , "arn:aws:sts::123456789012:federated-user/prodbox"
    , identityOf "aws" "sts" (StsFederatedUser "prodbox")
    )
  ,
    ( "the account root"
    , "arn:aws:iam::123456789012:root"
    , identityOf "aws" "iam" StsRoot
    )
  ,
    ( "an aws-cn user"
    , "arn:aws-cn:iam::123456789012:user/prodbox"
    , identityOf "aws-cn" "iam" (StsIamUser "prodbox")
    )
  ,
    ( "an aws-us-gov assumed role"
    , "arn:aws-us-gov:sts::123456789012:assumed-role/role/session"
    , identityOf "aws-us-gov" "sts" (StsAssumedRole "role" "session")
    )
  ]

-- | Shapes that name a caller prodbox does not act on, kept verbatim.
unactionedPrincipals :: [(String, Text, StsPrincipal)]
unactionedPrincipals =
  [ ("a user with no name", "arn:aws:iam::123456789012:user/", StsOtherPrincipal "user/")
  ,
    ( "a bare assumed role"
    , "arn:aws:sts::123456789012:assumed-role/role"
    , StsOtherPrincipal "assumed-role/role"
    )
  , ("an IAM role", "arn:aws:iam::123456789012:role/path/name", StsOtherPrincipal "role/path/name")
  ]

refusedShapes :: [(String, Text)]
refusedShapes =
  [ ("an empty string", "")
  , ("a bare arn prefix", "arn")
  , ("an eleven-digit account", "arn:aws:iam::12345678901:user/prodbox")
  , ("a thirteen-digit account", "arn:aws:iam::1234567890123:user/prodbox")
  , ("a non-digit account", "arn:aws:iam::12345678901a:user/prodbox")
  , ("an empty account", "arn:aws:iam:::user/prodbox")
  , ("an unknown partition", "arn:aws-example:iam::123456789012:user/prodbox")
  , ("a service that is neither iam nor sts", "arn:aws:s3::123456789012:user/prodbox")
  , ("an empty resource", "arn:aws:iam::123456789012:")
  , ("a truncated ARN", "arn:aws:iam::123456789012")
  , ("a missing arn prefix", "aws:iam::123456789012:user/prodbox")
  ]

-- | The pre-fix parse, verbatim. It is kept only as a negative control.
legacyAccountFromIdentityEvidence :: Text -> Maybe Text
legacyAccountFromIdentityEvidence evidence = do
  arn <- Text.stripPrefix "sts-identity:" evidence
  case Text.splitOn ":" arn of
    _partition : _service : _region : account : _resource
      | Text.length account == 12 && Text.all isAsciiDigit account -> Just account
    _ -> Nothing
 where
  isAsciiDigit character = character >= '0' && character <= '9'

stsIdentitySuite :: SuiteBuilder ()
stsIdentitySuite =
  describe "STS identity-evidence codec" $ do
    forM_ realShapes $ \(label, arn, expected) ->
      it ("parses " <> label) $
        parseStsIdentityArn arn `shouldBe` Just expected

    forM_ unactionedPrincipals $ \(label, arn, principal) ->
      it ("keeps " <> label <> " verbatim rather than guessing a name") $
        (stsIdentityPrincipal <$> parseStsIdentityArn arn) `shouldBe` Just principal

    forM_ refusedShapes $ \(label, arn) ->
      it ("refuses " <> label) $
        parseStsIdentityArn arn `shouldBe` Nothing

    it "round-trips every real shape through the production renderer" $
      forM_ realShapes $ \(_, arn, expected) -> do
        evidence <- case renderStsIdentityEvidence arn of
          Right rendered -> pure rendered
          Left err -> expectationFailure (Text.unpack err) >> pure ""
        parseStsIdentityEvidence evidence `shouldBe` Just expected

    it "keeps the marker and the bound byte-identical to the shipped wire text" $ do
      renderStsIdentityEvidence "arn:aws:iam::123456789012:user/prodbox"
        `shouldBe` Right "sts-identity:arn:aws:iam::123456789012:user/prodbox"
      stsIdentityEvidenceArnBound `shouldBe` 2048
      renderStsIdentityEvidence (Text.replicate 2048 "a")
        `shouldBe` Right ("sts-identity:" <> Text.replicate 2048 "a")
      forM_ ["", "   ", Text.replicate 2049 "a"] $ \refused ->
        renderStsIdentityEvidence refused
          `shouldBe` Left "STS identity ARN is absent or exceeds the evidence bound"

    it "refuses evidence that lacks the marker or carries only the marker" $ do
      parseStsIdentityEvidence "arn:aws:iam::123456789012:user/prodbox" `shouldBe` Nothing
      parseStsIdentityEvidence "sts-identity:" `shouldBe` Nothing
      stsIdentityEvidenceArn "sts-identity:anything" `shouldBe` Just "anything"
      stsIdentityEvidenceArn "anything" `shouldBe` Nothing

    it "negative control: the pre-fix parse refused every real shape" $
      forM_ realShapes $ \(_, arn, _) ->
        legacyAccountFromIdentityEvidence ("sts-identity:" <> arn) `shouldBe` Nothing

    it "returns the account for the very evidence the pre-fix parse refused" $
      forM_ realShapes $ \(_, arn, _) ->
        (stsIdentityAccount <$> parseStsIdentityEvidence ("sts-identity:" <> arn))
          `shouldBe` Just fixtureAccount
