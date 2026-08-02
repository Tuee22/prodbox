{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.62 deliverable 3 (Service Quotas): native
-- @RequestServiceQuotaIncrease@ / @GetServiceQuota@ /
-- @GetRequestedServiceQuotaChange@ (JSON protocol, @X-Amz-Target@ header).
-- Request bodies are rendered as explicit fixed-key-order ByteStrings so the
-- signed payload is deterministic; responses decode order-independently via
-- @aeson@.
--
-- Downstream (NOTE, not 1.62 work): replaces @Aws.hs@'s @ensureServiceQuota@ CLI
-- site.
module Prodbox.Aws.Native.ServiceQuotas
  ( QuotaIncreaseRequest (..)
  , RequestStatus (..)
  , RequestedQuotaChange (..)
  , RequestedQuotaChangeHistoryItem (..)
  , ServiceQuotaValue (..)
  , ServiceQuotasClient (..)
  , newServiceQuotasClient
  , serviceQuotasEndpoint
  , serviceQuotasScope
  , quotaTarget
  , renderQuotaIncreaseBody
  , renderGetServiceQuotaBody
  , renderGetRequestedChangeBody
  , renderListRequestedChangeHistoryBody
  , parseRequestedQuotaChange
  , parseRequestedQuotaChangeHistoryPage
  , parseServiceQuota
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Aws.CredentialHandle
  ( CredentialHandle
  , credentialHandleRegion
  , credentialHandleSecurityToken
  , toSigV4Credentials
  )
import Prodbox.Aws.Native.Wire
  ( AwsClientError (AwsResponseParseFailure)
  , AwsEndpoint (AwsEndpoint)
  , AwsErrorFormat (JsonErrorFormat)
  , AwsScope (AwsScope)
  , AwsTimestamp
  , Idempotency (Idempotent, Mutating)
  , NativeAwsSender
  , SignedHttpRequest
  , buildSignedRequest
  , performAwsRequest
  )

data QuotaIncreaseRequest = QuotaIncreaseRequest
  { quotaReqServiceCode :: !Text
  , quotaReqQuotaCode :: !Text
  , quotaReqDesiredValue :: !Double
  }
  deriving (Eq, Show)

data RequestStatus
  = QuotaPending
  | QuotaCaseOpened
  | QuotaApproved
  | QuotaDenied
  | QuotaOther !Text
  deriving (Eq, Show)

data RequestedQuotaChange = RequestedQuotaChange
  { requestedChangeId :: !Text
  , requestedChangeStatus :: !RequestStatus
  }
  deriving (Eq, Show)

-- | Authoritative per-quota history member.  AWS does not accept a client
-- token for @RequestServiceQuotaIncrease@, so recovery must match all of the
-- provider-authored identity fields plus the desired value and attempt-time
-- window rather than inventing an idempotency token.
data RequestedQuotaChangeHistoryItem = RequestedQuotaChangeHistoryItem
  { requestedHistoryId :: !Text
  , requestedHistoryServiceCode :: !Text
  , requestedHistoryQuotaCode :: !Text
  , requestedHistoryDesiredValue :: !Double
  , requestedHistoryStatus :: !RequestStatus
  , requestedHistoryCreatedEpochSeconds :: !Double
  , requestedHistoryLastUpdatedEpochSeconds :: !Double
  }
  deriving (Eq, Show)

data ServiceQuotaValue = ServiceQuotaValue
  { serviceQuotaCode :: !Text
  , serviceQuotaValue :: !Double
  }
  deriving (Eq, Show)

data ServiceQuotasClient = ServiceQuotasClient
  { requestServiceQuotaIncrease
      :: QuotaIncreaseRequest
      -> IO (Either AwsClientError RequestedQuotaChange)
  , getServiceQuota :: Text -> Text -> IO (Either AwsClientError ServiceQuotaValue)
  , getRequestedServiceQuotaChange :: Text -> IO (Either AwsClientError RequestedQuotaChange)
  , listRequestedServiceQuotaChangeHistoryByQuota
      :: Text
      -> Text
      -> IO (Either AwsClientError [RequestedQuotaChangeHistoryItem])
  }

newServiceQuotasClient :: CredentialHandle origin -> NativeAwsSender -> ServiceQuotasClient
newServiceQuotasClient handle sender =
  ServiceQuotasClient
    { requestServiceQuotaIncrease = runRequestIncrease handle sender
    , getServiceQuota = runGetServiceQuota handle sender
    , getRequestedServiceQuotaChange = runGetRequestedChange handle sender
    , listRequestedServiceQuotaChangeHistoryByQuota = runListRequestedChangeHistory handle sender
    }

serviceQuotasEndpoint :: ByteString -> AwsEndpoint
serviceQuotasEndpoint region =
  AwsEndpoint
    ("https://servicequotas." <> BS8.unpack region <> ".amazonaws.com")
    ("servicequotas." <> region <> ".amazonaws.com")

serviceQuotasScope :: ByteString -> AwsScope
serviceQuotasScope region = AwsScope region "servicequotas"

quotaTarget :: ByteString -> ByteString
quotaTarget operation = "ServiceQuotasV20190624." <> operation

jsonHeaders :: ByteString -> [(ByteString, ByteString)]
jsonHeaders target =
  [("content-type", "application/x-amz-json-1.1"), ("x-amz-target", target)]

renderQuotaIncreaseBody :: QuotaIncreaseRequest -> ByteString
renderQuotaIncreaseBody req =
  "{\"ServiceCode\":"
    <> jsonString (quotaReqServiceCode req)
    <> ",\"QuotaCode\":"
    <> jsonString (quotaReqQuotaCode req)
    <> ",\"DesiredValue\":"
    <> BS8.pack (show (quotaReqDesiredValue req))
    <> "}"

renderGetServiceQuotaBody :: Text -> Text -> ByteString
renderGetServiceQuotaBody serviceCode quotaCode =
  "{\"ServiceCode\":"
    <> jsonString serviceCode
    <> ",\"QuotaCode\":"
    <> jsonString quotaCode
    <> "}"

renderGetRequestedChangeBody :: Text -> ByteString
renderGetRequestedChangeBody requestId =
  "{\"RequestId\":" <> jsonString requestId <> "}"

renderListRequestedChangeHistoryBody :: Text -> Text -> Maybe Text -> ByteString
renderListRequestedChangeHistoryBody serviceCode quotaCode nextToken =
  "{\"ServiceCode\":"
    <> jsonString serviceCode
    <> ",\"QuotaCode\":"
    <> jsonString quotaCode
    <> ",\"MaxResults\":100"
    <> maybe "" (\token -> ",\"NextToken\":" <> jsonString token) nextToken
    <> "}"

jsonString :: Text -> ByteString
jsonString = BL.toStrict . Aeson.encode

parseRequestedQuotaChange :: ByteString -> Either String RequestedQuotaChange
parseRequestedQuotaChange body = do
  root <- decodeObject body
  requested <- lookupObject "RequestedQuota" root
  changeId <- lookupText "Id" requested
  status <- lookupText "Status" requested
  pure (RequestedQuotaChange changeId (parseRequestStatus status))

parseRequestedQuotaChangeHistoryPage
  :: ByteString
  -> Either String ([RequestedQuotaChangeHistoryItem], Maybe Text)
parseRequestedQuotaChangeHistoryPage body = do
  root <- decodeObject body
  requested <- lookupArray "RequestedQuotas" root
  items <- traverse parseHistoryItem requested
  nextToken <- lookupOptionalText "NextToken" root
  pure (items, normalizeToken nextToken)
 where
  parseHistoryItem value = case value of
    Aeson.Object item ->
      RequestedQuotaChangeHistoryItem
        <$> lookupText "Id" item
        <*> lookupText "ServiceCode" item
        <*> lookupText "QuotaCode" item
        <*> lookupNumber "DesiredValue" item
        <*> (parseRequestStatus <$> lookupText "Status" item)
        <*> lookupNumber "Created" item
        <*> lookupNumber "LastUpdated" item
    _ -> Left "ServiceQuotas: history member is not a JSON object"
  normalizeToken value = case Text.strip <$> value of
    Just token | not (Text.null token) -> Just token
    _ -> Nothing

parseServiceQuota :: ByteString -> Either String ServiceQuotaValue
parseServiceQuota body = do
  root <- decodeObject body
  quota <- lookupObject "Quota" root
  code <- lookupText "QuotaCode" quota
  value <- lookupNumber "Value" quota
  pure (ServiceQuotaValue code value)

parseRequestStatus :: Text -> RequestStatus
parseRequestStatus status = case status of
  "PENDING" -> QuotaPending
  "CASE_OPENED" -> QuotaCaseOpened
  "APPROVED" -> QuotaApproved
  "DENIED" -> QuotaDenied
  other -> QuotaOther other

decodeObject :: ByteString -> Either String Aeson.Object
decodeObject body = case Aeson.decodeStrict body of
  Just (Aeson.Object obj) -> Right obj
  _ -> Left "ServiceQuotas: response is not a JSON object"

lookupObject :: Text -> Aeson.Object -> Either String Aeson.Object
lookupObject field obj = case KeyMap.lookup (Key.fromText field) obj of
  Just (Aeson.Object nested) -> Right nested
  _ -> Left ("ServiceQuotas: missing object field " ++ show field)

lookupText :: Text -> Aeson.Object -> Either String Text
lookupText field obj = case KeyMap.lookup (Key.fromText field) obj of
  Just (Aeson.String value) -> Right value
  _ -> Left ("ServiceQuotas: missing string field " ++ show field)

lookupNumber :: Text -> Aeson.Object -> Either String Double
lookupNumber field obj = case KeyMap.lookup (Key.fromText field) obj of
  Just (Aeson.Number value) -> Right (toRealFloat value)
  _ -> Left ("ServiceQuotas: missing numeric field " ++ show field)

lookupArray :: Text -> Aeson.Object -> Either String [Aeson.Value]
lookupArray field obj = case KeyMap.lookup (Key.fromText field) obj of
  Just (Aeson.Array values) -> Right (foldr (:) [] values)
  _ -> Left ("ServiceQuotas: missing array field " ++ show field)

lookupOptionalText :: Text -> Aeson.Object -> Either String (Maybe Text)
lookupOptionalText field obj = case KeyMap.lookup (Key.fromText field) obj of
  Nothing -> Right Nothing
  Just Aeson.Null -> Right Nothing
  Just (Aeson.String value) -> Right (Just value)
  _ -> Left ("ServiceQuotas: invalid optional string field " ++ show field)

signQuota
  :: CredentialHandle origin -> ByteString -> ByteString -> AwsTimestamp -> SignedHttpRequest
signQuota handle target body ts =
  buildSignedRequest
    (toSigV4Credentials handle)
    (credentialHandleSecurityToken handle)
    (serviceQuotasScope region)
    (serviceQuotasEndpoint region)
    ts
    "POST"
    "/"
    []
    body
    (jsonHeaders target)
 where
  region = credentialHandleRegion handle

runRequestIncrease
  :: CredentialHandle origin
  -> NativeAwsSender
  -> QuotaIncreaseRequest
  -> IO (Either AwsClientError RequestedQuotaChange)
runRequestIncrease handle sender req = do
  raw <-
    performAwsRequest
      sender
      (signQuota handle (quotaTarget "RequestServiceQuotaIncrease") (renderQuotaIncreaseBody req))
      "servicequotas:RequestServiceQuotaIncrease"
      Mutating
      JsonErrorFormat
  pure (raw >>= first AwsResponseParseFailure . parseRequestedQuotaChange)

runGetServiceQuota
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> Text
  -> IO (Either AwsClientError ServiceQuotaValue)
runGetServiceQuota handle sender serviceCode quotaCode = do
  raw <-
    performAwsRequest
      sender
      (signQuota handle (quotaTarget "GetServiceQuota") (renderGetServiceQuotaBody serviceCode quotaCode))
      "servicequotas:GetServiceQuota"
      Idempotent
      JsonErrorFormat
  pure (raw >>= first AwsResponseParseFailure . parseServiceQuota)

runGetRequestedChange
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> IO (Either AwsClientError RequestedQuotaChange)
runGetRequestedChange handle sender requestId = do
  raw <-
    performAwsRequest
      sender
      ( signQuota
          handle
          (quotaTarget "GetRequestedServiceQuotaChange")
          (renderGetRequestedChangeBody requestId)
      )
      "servicequotas:GetRequestedServiceQuotaChange"
      Idempotent
      JsonErrorFormat
  pure (raw >>= first AwsResponseParseFailure . parseRequestedQuotaChange)

runListRequestedChangeHistory
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> Text
  -> IO (Either AwsClientError [RequestedQuotaChangeHistoryItem])
runListRequestedChangeHistory handle sender serviceCode quotaCode =
  go 0 [] Nothing []
 where
  maximumPages = 100 :: Int
  go page seen token accumulated
    | page >= maximumPages =
        pure (Left (AwsResponseParseFailure "ServiceQuotas: history page limit exceeded"))
    | maybe False (`elem` seen) token =
        pure (Left (AwsResponseParseFailure "ServiceQuotas: repeated history next token"))
    | otherwise = do
        raw <-
          performAwsRequest
            sender
            ( signQuota
                handle
                (quotaTarget "ListRequestedServiceQuotaChangeHistoryByQuota")
                (renderListRequestedChangeHistoryBody serviceCode quotaCode token)
            )
            "servicequotas:ListRequestedServiceQuotaChangeHistoryByQuota"
            Idempotent
            JsonErrorFormat
        case raw >>= first AwsResponseParseFailure . parseRequestedQuotaChangeHistoryPage of
          Left err -> pure (Left err)
          Right (items, Nothing) -> pure (Right (accumulated <> items))
          Right (items, Just next) ->
            go (page + 1) (maybe seen (: seen) token) (Just next) (accumulated <> items)
