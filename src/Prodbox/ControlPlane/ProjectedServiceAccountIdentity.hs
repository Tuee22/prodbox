{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Secret-free identity claims from a bound Kubernetes projected token.
-- Vault remains responsible for authenticating the JWT; this decoder binds
-- the authenticated token to the exact Pod and ServiceAccount identities
-- already attested and signed by the lifecycle Authority.
module Prodbox.ControlPlane.ProjectedServiceAccountIdentity
  ( ProjectedServiceAccountIdentity
  , ProjectedServiceAccountIdentityError (..)
  , decodeProjectedServiceAccountIdentity
  , projectedServiceAccountIdentityMatches
  , projectedServiceAccountIdentityMatchesPodUid
  , projectedServiceAccountIdentityServiceAccountUid
  )
where

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), eitherDecodeStrict', withObject, (.:))
import Data.ByteString.Base64.URL qualified as Base64Url
import Data.Char (isControl, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding

data ProjectedServiceAccountIdentity = ProjectedServiceAccountIdentity
  { projectedNamespace :: !Text
  , projectedPodName :: !Text
  , projectedPodUid :: !Text
  , projectedServiceAccountName :: !Text
  , projectedServiceAccountUid :: !Text
  }
  deriving stock (Eq, Show)

data ProjectedServiceAccountIdentityError
  = ProjectedServiceAccountJwtShapeInvalid
  | ProjectedServiceAccountPayloadInvalid
  | ProjectedServiceAccountClaimsInvalid
  deriving stock (Eq, Show)

data ProjectedServiceAccountClaims = ProjectedServiceAccountClaims
  { claimsSubject :: !Text
  , claimsNamespace :: !Text
  , claimsPodName :: !Text
  , claimsPodUid :: !Text
  , claimsServiceAccountName :: !Text
  , claimsServiceAccountUid :: !Text
  }

instance FromJSON ProjectedServiceAccountClaims where
  parseJSON = withObject "ProjectedServiceAccountClaims" $ \root -> do
    kubernetes <- root .: "kubernetes.io"
    pod <- kubernetes .: "pod"
    serviceAccount <- kubernetes .: "serviceaccount"
    ProjectedServiceAccountClaims
      <$> root .: "sub"
      <*> kubernetes .: "namespace"
      <*> pod .: "name"
      <*> pod .: "uid"
      <*> serviceAccount .: "name"
      <*> serviceAccount .: "uid"

decodeProjectedServiceAccountIdentity
  :: Text
  -> Either ProjectedServiceAccountIdentityError ProjectedServiceAccountIdentity
decodeProjectedServiceAccountIdentity rawJwt = do
  payload <- case Text.splitOn "." rawJwt of
    [_header, encodedPayload, _signature] -> decodePayload encodedPayload
    _ -> Left ProjectedServiceAccountJwtShapeInvalid
  claims <-
    case eitherDecodeStrict' payload of
      Left _ -> Left ProjectedServiceAccountPayloadInvalid
      Right value -> Right value
  namespace <- validateIdentity (claimsNamespace claims)
  podName <- validateIdentity (claimsPodName claims)
  podUid <- validateIdentity (claimsPodUid claims)
  serviceAccountName <- validateIdentity (claimsServiceAccountName claims)
  serviceAccountUid <- validateIdentity (claimsServiceAccountUid claims)
  unless
    ( claimsSubject claims
        == "system:serviceaccount:" <> namespace <> ":" <> serviceAccountName
    )
    (Left ProjectedServiceAccountClaimsInvalid)
  pure
    ProjectedServiceAccountIdentity
      { projectedNamespace = namespace
      , projectedPodName = podName
      , projectedPodUid = podUid
      , projectedServiceAccountName = serviceAccountName
      , projectedServiceAccountUid = serviceAccountUid
      }
 where
  decodePayload encoded =
    case Base64Url.decode (TextEncoding.encodeUtf8 (padBase64Url encoded)) of
      Left _ -> Left ProjectedServiceAccountPayloadInvalid
      Right payload -> Right payload

projectedServiceAccountIdentityMatches
  :: Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> ProjectedServiceAccountIdentity
  -> Bool
projectedServiceAccountIdentityMatches namespace podName podUid serviceAccountName serviceAccountUid identity =
  projectedNamespace identity == namespace
    && projectedPodName identity == podName
    && projectedPodUid identity == podUid
    && projectedServiceAccountName identity == serviceAccountName
    && projectedServiceAccountUid identity == serviceAccountUid

projectedServiceAccountIdentityMatchesPodUid
  :: Text
  -> Text
  -> Text
  -> ProjectedServiceAccountIdentity
  -> Bool
projectedServiceAccountIdentityMatchesPodUid namespace podUid serviceAccountName identity =
  projectedNamespace identity == namespace
    && projectedPodUid identity == podUid
    && projectedServiceAccountName identity == serviceAccountName

projectedServiceAccountIdentityServiceAccountUid
  :: ProjectedServiceAccountIdentity -> Text
projectedServiceAccountIdentityServiceAccountUid = projectedServiceAccountUid

validateIdentity
  :: Text -> Either ProjectedServiceAccountIdentityError Text
validateIdentity raw
  | Text.null value = Left ProjectedServiceAccountClaimsInvalid
  | value /= raw = Left ProjectedServiceAccountClaimsInvalid
  | Text.length value > 256 = Left ProjectedServiceAccountClaimsInvalid
  | Text.any (\character -> isControl character || isSpace character) value =
      Left ProjectedServiceAccountClaimsInvalid
  | otherwise = Right value
 where
  value = Text.strip raw

padBase64Url :: Text -> Text
padBase64Url value = value <> Text.replicate paddingLength "="
 where
  paddingLength = case Text.length value `mod` 4 of
    0 -> 0
    2 -> 2
    3 -> 1
    _ -> 0
