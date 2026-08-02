{-# LANGUAGE OverloadedStrings #-}

-- | Native Haskell HTTP client wrapping 'Network.HTTP.Client' and
-- 'Network.HTTP.Client.TLS'. Replaces the legacy curl subprocess pattern
-- on the host side per Sprint 2.17 and the secret-derivation doctrine
-- (@documents/engineering/secret_derivation_doctrine.md@).
module Prodbox.Http.Client
  ( HttpError (..)
  , HttpBoundedError (..)
  , HttpConfig (..)
  , sharedTlsManager
  , defaultHttpConfig
  , httpGetText
  , httpGetJson
  , httpGetJsonWithHeaders
  , httpPostJsonResponseJson
  , httpPostJsonWithHeaders
  , httpPostJsonNoResponse
  , httpRequestRaw
  , httpRequestRawBounded
  , httpRequestNoBody
  , renderHttpError
  )
where

import Control.Exception (Exception, SomeException, try)
import Data.Aeson (FromJSON, ToJSON, eitherDecode, encode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Network.HTTP.Client
  ( BodyReader
  , HttpException (..)
  , HttpExceptionContent (..)
  , Manager
  , Request
  , RequestBody (..)
  , Response
  , brRead
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
  , withResponse
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Header (Header)
import Network.HTTP.Types.Method (Method)
import Network.HTTP.Types.Status (statusCode)
import System.IO.Unsafe (unsafePerformIO)

-- | Errors that surface from an HTTP request through this module.
data HttpError
  = HttpConnectionFailure String
  | HttpTimeout String
  | HttpStatus Int String
  | HttpDecode String
  deriving (Eq, Show)

instance Exception HttpError

-- | Error from a response whose body is consumed under an allocation bound.
-- Transport failures retain the shared 'HttpError' taxonomy; crossing the
-- bound is distinct and reports the first observed size beyond the ceiling.
data HttpBoundedError
  = HttpBoundedTransport !HttpError
  | HttpBoundedResponseTooLarge !Int !Int
  deriving (Eq, Show)

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

-- | The one process-wide TLS 'Manager', constructed exactly once (Sprint
-- 1.64). @http-client@ 'Manager's are designed for concurrent reuse and pool
-- connections per host, so a single shared manager is both correct and the
-- point of this singleton: counterexample @LCPC-2026-07-11@ traced a gateway
-- hot-path CPU driver to the per-call @newManager@ construction (a fresh TLS
-- context and connection pool on every request). The @unsafePerformIO@ +
-- @NOINLINE@ idiom is the standard way to create such a value once; it lives
-- only here, outside every daemon-runtime module, and the shared @Manager@ is
-- immutable after construction.
{-# NOINLINE sharedTlsManager #-}
sharedTlsManager :: Manager
sharedTlsManager = unsafePerformIO (newManager tlsManagerSettings)

-- | Run an action against the shared TLS 'Manager'. The TLS manager handles
-- both @http://@ and @https://@ URLs and reuses connections per host.
withManager :: (Manager -> IO a) -> IO a
withManager action = action sharedTlsManager

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

-- | Send one request through the shared manager and retain the exact status and
-- response bytes.  This is the bounded-protocol substrate used by services
-- whose wire format is not JSON (for example the canonical-CBOR lifecycle
-- control-plane endpoints).  Status interpretation and response-size bounds
-- remain with the typed service client; transport errors stay normalized here.
httpRequestRaw
  :: HttpConfig
  -> Method
  -> [Header]
  -> String
  -> Maybe BL.ByteString
  -> IO (Either HttpError (Int, BL.ByteString))
httpRequestRaw = sendRequestRaw

-- | Send one request and stream its response body into memory only while the
-- caller-supplied bound holds.  Unlike checking the size after 'httpLbs', this
-- stops consuming as soon as a chunk crosses the ceiling, so an untrusted peer
-- cannot force an unbounded lazy response allocation before the typed protocol
-- client gets to validate it.
httpRequestRawBounded
  :: HttpConfig
  -> Int
  -> Method
  -> [Header]
  -> String
  -> Maybe BL.ByteString
  -> IO (Either HttpBoundedError (Int, BS.ByteString))
httpRequestRawBounded config maximumBytes httpMethod extraHeaders url maybeBody
  | maximumBytes < 0 = pure (Left (HttpBoundedResponseTooLarge 0 maximumBytes))
  | otherwise = do
      requestResult <- try (parseRequest url) :: IO (Either SomeException Request)
      case requestResult of
        Left ex ->
          pure
            (Left (HttpBoundedTransport (HttpConnectionFailure (show ex))))
        Right baseRequest -> do
          let requestWithoutTimeout =
                baseRequest
                  { method = httpMethod
                  , requestHeaders = extraHeaders
                  , requestBody = maybe (requestBody baseRequest) RequestBodyLBS maybeBody
                  }
              request =
                requestWithoutTimeout
                  { responseTimeout = responseTimeoutMicro (httpRequestTimeoutMicros config)
                  }
          result <-
            try
              ( withManager $ \manager ->
                  withResponse request manager $ \response -> do
                    boundedBody <- readBoundedBody maximumBytes (responseBody response)
                    pure (statusCode (responseStatus response), boundedBody)
              )
          pure $ case result of
            Left (HttpExceptionRequest _ content) ->
              Left (HttpBoundedTransport (translateExceptionContent content))
            Left (InvalidUrlException invalidUrl reason) ->
              Left
                ( HttpBoundedTransport
                    (HttpConnectionFailure ("invalid URL " ++ invalidUrl ++ ": " ++ reason))
                )
            Right (_status, Left observedBytes) ->
              Left (HttpBoundedResponseTooLarge observedBytes maximumBytes)
            Right (status, Right body) -> Right (status, body)

readBoundedBody
  :: Int
  -> BodyReader
  -> IO (Either Int BS.ByteString)
readBoundedBody maximumBytes = go 0 []
 where
  go observed chunks reader = do
    chunk <- brRead reader
    if BS.null chunk
      then pure (Right (BS.concat (reverse chunks)))
      else do
        let nextObserved = observed + BS.length chunk
        if nextObserved > maximumBytes
          then pure (Left nextObserved)
          else go nextObserved (chunk : chunks) reader

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

-- | POST a JSON payload with extra request headers and ignore the response
-- body. Any 2xx (including Vault's common 204 No Content) is success.
httpPostJsonNoResponse
  :: (ToJSON a)
  => HttpConfig
  -> [Header]
  -> String
  -> a
  -> IO (Either HttpError ())
httpPostJsonNoResponse config extraHeaders url payload = do
  result <- sendRequestRaw config "POST" extraHeaders url (Just (encode payload))
  pure $ case result of
    Left err -> Left err
    Right (status, body)
      | status >= 200 && status < 300 -> Right ()
      | otherwise -> Left (HttpStatus status (BL8.unpack body))

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
