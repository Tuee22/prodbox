{-# LANGUAGE OverloadedStrings #-}

-- | Native Haskell HTTP client wrapping 'Network.HTTP.Client' and
-- 'Network.HTTP.Client.TLS'. Replaces the legacy curl subprocess pattern
-- on the host side per Sprint 2.17 and the secret-derivation doctrine
-- (@documents/engineering/secret_derivation_doctrine.md@).
module Prodbox.Http.Client
  ( HttpError (..)
  , HttpConfig (..)
  , defaultHttpConfig
  , httpGetText
  , httpGetJson
  , httpGetJsonWithHeaders
  , httpPostJsonResponseJson
  , httpPostJsonWithHeaders
  , httpRequestNoBody
  , renderHttpError
  )
where

import Control.Exception (Exception, SomeException, try)
import Data.Aeson (FromJSON, ToJSON, eitherDecode, encode)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Network.HTTP.Client
  ( HttpException (..)
  , HttpExceptionContent (..)
  , Manager
  , Request
  , RequestBody (..)
  , Response
  , httpLbs
  , method
  , newManager
  , parseRequest
  , requestBody
  , requestHeaders
  , responseBody
  , responseStatus
  , responseTimeout
  , responseTimeoutMicro
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Header (Header)
import Network.HTTP.Types.Method (Method)
import Network.HTTP.Types.Status (statusCode)

-- | Errors that surface from an HTTP request through this module.
data HttpError
  = HttpConnectionFailure String
  | HttpTimeout String
  | HttpStatus Int String
  | HttpDecode String
  deriving (Eq, Show)

instance Exception HttpError

-- | Per-call configuration. 'httpRequestTimeoutMicros' is enforced via
-- 'responseTimeout' on the 'Request' before sending.
data HttpConfig = HttpConfig
  { httpRequestTimeoutMicros :: Int
  }
  deriving (Eq, Show)

-- | Default: 10 second timeout, mirroring the legacy @curl --max-time 10@
-- pattern used by the pre-Sprint-2.17 fetch-public-ip call sites.
defaultHttpConfig :: HttpConfig
defaultHttpConfig =
  HttpConfig {httpRequestTimeoutMicros = 10 * 1000 * 1000}

-- | Render an 'HttpError' as the single-line operator-facing string used by
-- the legacy curl call sites.
renderHttpError :: HttpError -> String
renderHttpError httpErr = case httpErr of
  HttpConnectionFailure msg -> "HTTP connection failure: " ++ msg
  HttpTimeout msg -> "HTTP timeout: " ++ msg
  HttpStatus code body ->
    "HTTP " ++ show code ++ " response: " ++ truncateBody body
  HttpDecode msg -> "HTTP response decode error: " ++ msg
 where
  truncateBody body
    | length body > 200 = take 200 body ++ "…"
    | otherwise = body

-- | Internal manager shared across calls. Created on first use. The
-- module-local 'IORef' is intentional and limited to this module so the
-- manager-singleton pattern remains the only allowed use of mutable
-- state under @src/Prodbox/Http/@.
withManager :: (Manager -> IO a) -> IO a
withManager action = do
  -- The TLS manager handles both http:// and https:// URLs and reuses
  -- connections per-host. Construction is cheap enough to do per call;
  -- the per-call cost is dwarfed by the network round-trip. If profiling
  -- shows manager-construction in the hot path, lift to a shared
  -- IORef-cached singleton at that point.
  manager <- newManager tlsManagerSettings
  action manager

-- | Execute an HTTP request and return the parsed 'Response', translating
-- exceptions into 'HttpError'.
runRequest :: HttpConfig -> Request -> IO (Either HttpError (Response BL.ByteString))
runRequest config requestWithoutTimeout = do
  let request =
        requestWithoutTimeout
          { responseTimeout = responseTimeoutMicro (httpRequestTimeoutMicros config)
          }
  result <- try (withManager (\mgr -> httpLbs request mgr))
  pure $ case result of
    Right response -> Right response
    Left (HttpExceptionRequest _ content) -> Left (translateExceptionContent content)
    Left (InvalidUrlException url reason) ->
      Left (HttpConnectionFailure ("invalid URL " ++ url ++ ": " ++ reason))

-- | Translate an 'HttpExceptionContent' into an 'HttpError'. The
-- 'ConnectionTimeout' / 'ResponseTimeout' arms map to 'HttpTimeout'; all
-- other failure modes map to 'HttpConnectionFailure'.
translateExceptionContent :: HttpExceptionContent -> HttpError
translateExceptionContent content = case content of
  ConnectionTimeout -> HttpTimeout "connection timeout"
  ResponseTimeout -> HttpTimeout "response timeout"
  StatusCodeException response body ->
    HttpStatus
      (statusCode (responseStatus response))
      (BL8.unpack (BL.fromStrict body))
  _ -> HttpConnectionFailure (renderExceptionContent content)

renderExceptionContent :: HttpExceptionContent -> String
renderExceptionContent = show

-- | GET the URL and return the response body as text. Non-2xx status is
-- reported through 'HttpError'.
httpGetText :: HttpConfig -> String -> IO (Either HttpError String)
httpGetText config url = do
  requestResult <- try (parseRequest url) :: IO (Either SomeException Request)
  case requestResult of
    Left ex -> pure (Left (HttpConnectionFailure (show ex)))
    Right request -> do
      result <- runRequest config request
      pure $ case result of
        Left err -> Left err
        Right response ->
          let status = statusCode (responseStatus response)
              body = BL8.unpack (responseBody response)
           in if status >= 200 && status < 300
                then Right body
                else Left (HttpStatus status body)

-- | GET the URL, decode the JSON response body into the requested type.
httpGetJson :: (FromJSON a) => HttpConfig -> String -> IO (Either HttpError a)
httpGetJson config url = do
  textResult <- httpGetText config url
  pure $ case textResult of
    Left err -> Left err
    Right body -> case eitherDecode (BL8.pack body) of
      Left err -> Left (HttpDecode err)
      Right value -> Right value

-- | POST a JSON payload and decode the JSON response body.
httpPostJsonResponseJson
  :: (ToJSON a, FromJSON b)
  => HttpConfig
  -> String
  -> a
  -> IO (Either HttpError b)
httpPostJsonResponseJson config url payload = do
  requestResult <- try (parseRequest url) :: IO (Either SomeException Request)
  case requestResult of
    Left ex -> pure (Left (HttpConnectionFailure (show ex)))
    Right baseRequest -> do
      let request =
            baseRequest
              { method = "POST"
              , requestBody = RequestBodyLBS (encode payload)
              , requestHeaders =
                  [ ("Content-Type", "application/json")
                  , ("Accept", "application/json")
                  ]
              }
      result <- runRequest config request
      pure $ case result of
        Left err -> Left err
        Right response ->
          let status = statusCode (responseStatus response)
              body = BL8.unpack (responseBody response)
           in if status >= 200 && status < 300
                then case eitherDecode (BL8.pack body) of
                  Left err -> Left (HttpDecode err)
                  Right value -> Right value
                else Left (HttpStatus status body)

-- | Send a request with an explicit method, extra request headers, and an
-- optional JSON-encoded body, returning the raw @(status, body)@ pair. The
-- shared engine the header-bearing helpers below build on — used by the
-- authenticated Vault surface (@X-Vault-Token@ + KV / Transit / @sys\/seal@).
sendRequestRaw
  :: HttpConfig
  -> Method
  -> [Header]
  -> String
  -> Maybe BL.ByteString
  -> IO (Either HttpError (Int, BL.ByteString))
sendRequestRaw config httpMethod extraHeaders url maybeBody = do
  requestResult <- try (parseRequest url) :: IO (Either SomeException Request)
  case requestResult of
    Left ex -> pure (Left (HttpConnectionFailure (show ex)))
    Right baseRequest -> do
      let request =
            baseRequest
              { method = httpMethod
              , requestHeaders =
                  ("Accept", "application/json")
                    : maybe [] (const [("Content-Type", "application/json")]) maybeBody
                    ++ extraHeaders
              , requestBody = maybe (requestBody baseRequest) RequestBodyLBS maybeBody
              }
      result <- runRequest config request
      pure $ case result of
        Left err -> Left err
        Right response ->
          Right (statusCode (responseStatus response), responseBody response)

-- | Decode a @(status, body)@ pair: any 2xx decodes the JSON body, anything
-- else becomes an 'HttpStatus'.
decodeJsonResponse :: (FromJSON a) => (Int, BL.ByteString) -> Either HttpError a
decodeJsonResponse (status, body)
  | status >= 200 && status < 300 =
      case eitherDecode body of
        Left err -> Left (HttpDecode err)
        Right value -> Right value
  | otherwise = Left (HttpStatus status (BL8.unpack body))

-- | GET with extra request headers (e.g. @X-Vault-Token@), decode JSON.
httpGetJsonWithHeaders
  :: (FromJSON a) => HttpConfig -> [Header] -> String -> IO (Either HttpError a)
httpGetJsonWithHeaders config extraHeaders url = do
  result <- sendRequestRaw config "GET" extraHeaders url Nothing
  pure (result >>= decodeJsonResponse)

-- | POST a JSON payload with extra request headers, decode the JSON response.
httpPostJsonWithHeaders
  :: (ToJSON a, FromJSON b)
  => HttpConfig
  -> [Header]
  -> String
  -> a
  -> IO (Either HttpError b)
httpPostJsonWithHeaders config extraHeaders url payload = do
  result <- sendRequestRaw config "POST" extraHeaders url (Just (encode payload))
  pure (result >>= decodeJsonResponse)

-- | Send a bodyless request (e.g. @PUT \/v1\/sys\/seal@) with extra headers;
-- any 2xx (including 204 No Content) is success and the response body is
-- ignored.
httpRequestNoBody
  :: HttpConfig -> Method -> [Header] -> String -> IO (Either HttpError ())
httpRequestNoBody config httpMethod extraHeaders url = do
  result <- sendRequestRaw config httpMethod extraHeaders url Nothing
  pure $ case result of
    Left err -> Left err
    Right (status, body)
      | status >= 200 && status < 300 -> Right ()
      | otherwise -> Left (HttpStatus status (BL8.unpack body))
