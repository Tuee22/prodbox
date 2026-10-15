{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The one codec for the STS caller-identity evidence the Provider emits and
-- the host reads back.
--
-- The Provider renders @sts-identity:<arn>@ from @sts get-caller-identity@.
-- The operator identity probe and the EKS client-auth admission each parse it
-- again. The marker used to be spelled at three sites and two of them split
-- the ARN by hand; one counted the leading @arn@ field as the partition, so it
-- refused every well-formed ARN. This module owns the marker, the evidence
-- bound, the renderer, and the parser, so a fixture cannot drift from the
-- production renderer.
module Prodbox.Aws.StsIdentity
  ( StsIdentity (..)
  , StsPrincipal (..)
  , stsIdentityEvidencePrefix
  , stsIdentityEvidenceArnBound
  , renderStsIdentityEvidence
  , stsIdentityEvidenceArn
  , parseStsIdentityEvidence
  , parseStsIdentityArn
  )
where

import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as Text

-- | The kind of caller an identity ARN names. Names are the final path
-- segment, which is what the operator-facing probe reports.
data StsPrincipal
  = StsIamUser !Text
  | StsFederatedUser !Text
  | -- | Role name, then session name.
    StsAssumedRole !Text !Text
  | StsRoot
  | -- | Any other resource, kept verbatim.
    StsOtherPrincipal !Text
  deriving stock (Eq, Show)

data StsIdentity = StsIdentity
  { stsIdentityPartition :: !Text
  , stsIdentityService :: !Text
  , stsIdentityAccount :: !Text
  , stsIdentityPrincipal :: !StsPrincipal
  }
  deriving stock (Eq, Show)

-- | Wire marker of the Provider's identity evidence. Frozen: live transcripts
-- and the Authority's retained evidence already contain it.
stsIdentityEvidencePrefix :: Text
stsIdentityEvidencePrefix = "sts-identity:"

-- | Longest ARN the Provider will put into identity evidence.
stsIdentityEvidenceArnBound :: Int
stsIdentityEvidenceArnBound = 2048

-- | Render the evidence for a caller ARN. Only absence and the bound are
-- refused here, exactly as before the codec was shared; shape is the parser's
-- concern.
renderStsIdentityEvidence :: Text -> Either Text Text
renderStsIdentityEvidence arn
  | Text.null (Text.strip arn) || Text.length arn > stsIdentityEvidenceArnBound =
      Left "STS identity ARN is absent or exceeds the evidence bound"
  | otherwise = Right (stsIdentityEvidencePrefix <> arn)

-- | The raw ARN carried by identity evidence, for callers that report it
-- verbatim when it is not a shape they act on.
stsIdentityEvidenceArn :: Text -> Maybe Text
stsIdentityEvidenceArn = Text.stripPrefix stsIdentityEvidencePrefix

parseStsIdentityEvidence :: Text -> Maybe StsIdentity
parseStsIdentityEvidence evidence =
  stsIdentityEvidenceArn evidence >>= parseStsIdentityArn

-- | Parse an @arn:<partition>:<iam|sts>:<region>:<account>:<resource>@
-- caller ARN. The region field is empty for these services and is not
-- inspected. The account must be exactly twelve ASCII digits.
parseStsIdentityArn :: Text -> Maybe StsIdentity
parseStsIdentityArn arn =
  case Text.splitOn ":" arn of
    "arn" : partition : service : _region : account : resourceParts
      | partition `elem` ["aws", "aws-cn", "aws-us-gov"]
      , service `elem` ["iam", "sts"]
      , Text.length account == 12 && Text.all isDigit account
      , resource <- Text.intercalate ":" resourceParts
      , not (Text.null resource) ->
          Just
            StsIdentity
              { stsIdentityPartition = partition
              , stsIdentityService = service
              , stsIdentityAccount = account
              , stsIdentityPrincipal = classifyResource resource
              }
    _ -> Nothing

classifyResource :: Text -> StsPrincipal
classifyResource resource
  | resource == "root" = StsRoot
  | Just rest <- Text.stripPrefix "user/" resource = named StsIamUser rest
  | Just rest <- Text.stripPrefix "federated-user/" resource = named StsFederatedUser rest
  | Just rest <- Text.stripPrefix "assumed-role/" resource =
      case segments rest of
        [role, session] -> StsAssumedRole role session
        _ -> StsOtherPrincipal resource
  | otherwise = StsOtherPrincipal resource
 where
  named constructor rest = case reverse (segments rest) of
    segment : _ -> constructor segment
    [] -> StsOtherPrincipal resource
  segments = filter (not . Text.null) . Text.splitOn "/"
