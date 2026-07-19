{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 1.62 deliverable 3 (shared wire): the one signer + sender seam +
-- outcome classifier shared by the four native AWS service clients. The pure
-- core ('signAwsRequest'\/'buildSignedRequest'\/'classifyOutcome'\/
-- 'renderFormBody'\/'parseServiceFault') is unit-tested against fakes; the sole
-- I\/O is 'httpSend' (the only toucher of the shared TLS manager) and
-- 'performAwsRequest'.
--
-- The load-bearing correctness property is the ambiguity gate in
-- 'classifyOutcome': a transport failure on a MUTATING op whose bytes may have
-- reached AWS becomes 'AwsAmbiguousOutcome', never a false success or a false
-- "not sent". Unknown dispatch phases default to 'PossiblySent' (the safe
-- direction).
module Prodbox.Aws.Native.Wire
  ( -- * Error algebra
    AwsClientError (..)
  , AmbiguityCause (..)
  , AwsServiceFault (..)
  , Idempotency (..)
  , AwsErrorFormat (..)

    -- * Request / endpoint model
  , AwsScope (..)
  , AwsEndpoint (..)
  , AwsTimestamp (..)
  , awsTimestampFromUtc
  , SignedHttpRequest (..)
  , HttpOutcome (..)
  , TransportFailure (..)
  , DispatchPhase (..)
  , NativeAwsSender
  , formContentType

    -- * Pure core
  , signAwsRequest
  , buildSignedRequest
  , classifyOutcome
  , renderFormBody
  , parseServiceFault

    -- * IO
  , httpSend
  , performAwsRequest
  )
where

import Control.Exception (SomeException, fromException, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.CaseInsensitive qualified as CI
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8)
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Network.HTTP.Client
  ( HttpException (..)
  , HttpExceptionContent (..)
  , Request (..)
  , RequestBody (RequestBodyBS)
  , Response
  , httpLbs
  , parseRequest
  , responseBody
  , responseHeaders
  , responseStatus
  )
import Network.HTTP.Types.Header (Header)
import Network.HTTP.Types.Status (statusCode)
import Prodbox.Aws.Native.Xml (extractFirst)
import Prodbox.Aws.SigV4
  ( SigV4Credentials
  , SigV4Request (..)
  , SigV4Scope (..)
  , canonicalQueryString
  , canonicalUri
  , hexSha256
  , sigV4AuthorizationHeader
  , uriEncode
  )
import Prodbox.Http.Client (sharedTlsManager)

-- | Whether an operation may be blindly retried after an unconfirmed transport
-- failure. Exactly one native op is 'Mutating' (@iam:CreateAccessKey@); all
-- others are 'Idempotent'.
data Idempotency = Idempotent | Mutating
  deriving (Eq, Show)

data AwsErrorFormat = XmlErrorFormat | JsonErrorFormat
  deriving (Eq, Show)

data AwsScope = AwsScope
  { awsScopeRegion :: !ByteString
  , awsScopeService :: !ByteString
  }
  deriving (Eq, Show)

data AwsEndpoint = AwsEndpoint
  { awsEndpointBaseUrl :: !String
  , awsEndpointHost :: !ByteString
  }
  deriving (Eq, Show)

data AwsTimestamp = AwsTimestamp
  { awsAmzDate :: !ByteString
  , awsDateStamp :: !ByteString
  }
  deriving (Eq, Show)

awsTimestampFromUtc :: UTCTime -> AwsTimestamp
awsTimestampFromUtc t =
  AwsTimestamp
    { awsAmzDate = BS8.pack (formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" t)
    , awsDateStamp = BS8.pack (formatTime defaultTimeLocale "%Y%m%d" t)
    }

data SignedHttpRequest = SignedHttpRequest
  { shrMethod :: !ByteString
  , shrUrl :: !String
  , shrHeaders :: ![(ByteString, ByteString)]
  , shrBody :: !ByteString
  }
  deriving (Eq, Show)

data HttpOutcome = HttpOutcome
  { httpStatus :: !Int
  , httpHeaders :: ![Header]
  , httpBody :: !ByteString
  }
  deriving (Eq, Show)

data DispatchPhase = DefinitelyNotSent | PossiblySent
  deriving (Eq, Show)

data TransportFailure = TransportFailure
  { transportDetail :: !String
  , transportPhase :: !DispatchPhase
  }
  deriving (Eq, Show)

-- | The injected send seam. The production 'httpSend' is the sole reference to
-- the shared TLS manager; fakes implement this to drive the pure pipeline.
type NativeAwsSender = SignedHttpRequest -> IO (Either TransportFailure HttpOutcome)

data AwsServiceFault = AwsServiceFault
  { awsFaultHttpStatus :: !Int
  , awsFaultCode :: !Text
  , awsFaultMessage :: !Text
  , awsFaultRequestId :: !(Maybe Text)
  }
  deriving (Eq, Show)

data AwsClientError
  = -- | Pure encode\/sign failure; request NOT dispatched. Safe.
    AwsSigningError !String
  | -- | Transport failure, NO confirmed mutation; retry-safe.
    AwsTransportError !String
  | -- | Well-formed non-2xx AWS error; atomic reject, NO partial mutation.
    AwsServiceError !AwsServiceFault
  | -- | 2xx body unparsable for an op with NO unrepeatable side effect.
    AwsResponseParseFailure !String
  | -- | The ONLY "may/did mutate, outcome unusable\/unconfirmed" constructor.
    AwsAmbiguousOutcome !AmbiguityCause
  deriving (Eq, Show)

data AmbiguityCause
  = AmbiguousDispatchFailure {ambiguousOperation :: !Text, ambiguousDetail :: !String}
  | AmbiguousLostResult {ambiguousOperation :: !Text, ambiguousDetail :: !String}
  deriving (Eq, Show)

-- | Assemble the signed header set (query\/REST\/JSON). @x-amz-security-token@
-- (when present), the content-type, and any @x-amz-target@ are folded into the
-- signed set, not merely sent.
signAwsRequest
  :: SigV4Credentials
  -> Maybe ByteString
  -> AwsScope
  -> ByteString
  -> AwsTimestamp
  -> ByteString
  -> ByteString
  -> [(ByteString, ByteString)]
  -> ByteString
  -> [(ByteString, ByteString)]
  -> [(ByteString, ByteString)]
signAwsRequest creds mToken scope hostHeader ts method rawPath rawQuery body extra =
  ("Authorization", authorization) : baseHeaders
 where
  payloadHash = hexSha256 body
  tokenHeaders = maybe [] (\t -> [("x-amz-security-token", t)]) mToken
  baseHeaders =
    [("host", hostHeader), ("x-amz-date", awsAmzDate ts)] ++ tokenHeaders ++ extra
  sigScope =
    SigV4Scope
      { sigV4DateStamp = awsDateStamp ts
      , sigV4Region = awsScopeRegion scope
      , sigV4Service = awsScopeService scope
      }
  request =
    SigV4Request
      { sigV4Method = method
      , sigV4Path = rawPath
      , sigV4Query = rawQuery
      , sigV4Headers = baseHeaders
      , sigV4PayloadHashHex = payloadHash
      }
  authorization = sigV4AuthorizationHeader creds sigScope (awsAmzDate ts) request

buildSignedRequest
  :: SigV4Credentials
  -> Maybe ByteString
  -> AwsScope
  -> AwsEndpoint
  -> AwsTimestamp
  -> ByteString
  -> ByteString
  -> [(ByteString, ByteString)]
  -> ByteString
  -> [(ByteString, ByteString)]
  -> SignedHttpRequest
buildSignedRequest creds mToken scope endpoint ts method rawPath rawQuery body extra =
  SignedHttpRequest
    { shrMethod = method
    , shrUrl =
        awsEndpointBaseUrl endpoint
          <> BS8.unpack (canonicalUri rawPath)
          <> querySuffix
    , shrHeaders =
        signAwsRequest creds mToken scope (awsEndpointHost endpoint) ts method rawPath rawQuery body extra
    , shrBody = body
    }
 where
  querySuffix
    | null rawQuery = ""
    | otherwise = "?" <> BS8.unpack (canonicalQueryString rawQuery)

-- | The total ambiguity gate. A mutating op whose bytes may have been dispatched
-- becomes ambiguous; everything else maps to a safe, retryable\/atomic outcome.
classifyOutcome
  :: Text
  -> Idempotency
  -> AwsErrorFormat
  -> Either TransportFailure HttpOutcome
  -> Either AwsClientError ByteString
classifyOutcome label idem fmt result = case result of
  Left (TransportFailure detail phase)
    | idem == Mutating && phase == PossiblySent ->
        Left (AwsAmbiguousOutcome (AmbiguousDispatchFailure label detail))
    | otherwise -> Left (AwsTransportError detail)
  Right (HttpOutcome status headers body)
    | status >= 200 && status < 300 -> Right body
    | otherwise -> Left (AwsServiceError (parseServiceFault fmt status headers body))

renderFormBody :: [(ByteString, ByteString)] -> ByteString
renderFormBody pairs =
  BS8.intercalate "&" [uriEncode True key <> "=" <> uriEncode True value | (key, value) <- pairs]

formContentType :: [(ByteString, ByteString)]
formContentType = [("content-type", "application/x-www-form-urlencoded; charset=utf-8")]

parseServiceFault :: AwsErrorFormat -> Int -> [Header] -> ByteString -> AwsServiceFault
parseServiceFault XmlErrorFormat status _ body =
  AwsServiceFault
    status
    (maybe "" decodeUtf8 (extractFirst "<Code>" "</Code>" body))
    (maybe "" decodeUtf8 (extractFirst "<Message>" "</Message>" body))
    (decodeUtf8 <$> extractFirst "<RequestId>" "</RequestId>" body)
parseServiceFault JsonErrorFormat status headers body =
  AwsServiceFault
    status
    (maybe "" (Text.takeWhileEnd (/= '#')) (jsonField "__type" body))
    (maybe "" id (jsonField "message" body `orElse` jsonField "Message" body))
    (requestIdHeader headers)

orElse :: Maybe a -> Maybe a -> Maybe a
orElse (Just x) _ = Just x
orElse Nothing y = y

jsonField :: Text -> ByteString -> Maybe Text
jsonField field body = case Aeson.decodeStrict body of
  Just (Aeson.Object obj) -> case KeyMap.lookup (Key.fromText field) obj of
    Just (Aeson.String value) -> Just value
    _ -> Nothing
  _ -> Nothing

requestIdHeader :: [Header] -> Maybe Text
requestIdHeader headers = decodeUtf8 <$> lookup (CI.mk "x-amzn-RequestId") headers

-- | The production sender: the sole reference to the shared TLS manager.
httpSend :: NativeAwsSender
httpSend request = do
  parsed <- try (parseRequest (shrUrl request)) :: IO (Either SomeException Request)
  case parsed of
    Left ex -> pure (Left (TransportFailure (show ex) DefinitelyNotSent))
    Right base -> do
      let prepared =
            base
              { method = shrMethod request
              , requestHeaders = [(CI.mk key, value) | (key, value) <- shrHeaders request]
              , requestBody = RequestBodyBS (shrBody request)
              }
      outcome <-
        try (httpLbs prepared sharedTlsManager) :: IO (Either SomeException (Response BL.ByteString))
      pure $ case outcome of
        Right response ->
          Right
            ( HttpOutcome
                (statusCode (responseStatus response))
                (responseHeaders response)
                (BL.toStrict (responseBody response))
            )
        Left ex -> Left (TransportFailure (show ex) (dispatchPhaseOf ex))

-- | Conservative exception→phase mapping. Only unambiguously pre-connection
-- failures are 'DefinitelyNotSent'; every other arm (including a non-HTTP
-- exception) defaults to 'PossiblySent', so a mutating op never falsely reads as
-- "not sent".
dispatchPhaseOf :: SomeException -> DispatchPhase
dispatchPhaseOf ex = case fromException ex of
  Just (InvalidUrlException _ _) -> DefinitelyNotSent
  Just (HttpExceptionRequest _ content) -> case content of
    ConnectionFailure _ -> DefinitelyNotSent
    ConnectionTimeout -> DefinitelyNotSent
    InternalException _ -> PossiblySent
    _ -> PossiblySent
  Nothing -> PossiblySent

performAwsRequest
  :: NativeAwsSender
  -> (AwsTimestamp -> SignedHttpRequest)
  -> Text
  -> Idempotency
  -> AwsErrorFormat
  -> IO (Either AwsClientError ByteString)
performAwsRequest sender build label idem fmt = do
  now <- getCurrentTime
  outcome <- sender (build (awsTimestampFromUtc now))
  pure (classifyOutcome label idem fmt outcome)
