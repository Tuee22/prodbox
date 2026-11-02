{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module HttpClientExchangePolicy (httpClientExchangePolicySuite) where

import Control.Concurrent.Async qualified as Async
import Control.Exception (IOException, bracket, catch)
import Control.Monad (forM_, forever, unless, void)
import Data.Aeson (Value, object, (.=))
import Data.Bifunctor (bimap)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isRight)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as Net
import Prodbox.ControlPlane.Server qualified as Server
import Prodbox.Http.Client
import Prodbox.Vault.Client (VaultAddress (..), vaultKubernetesLoginWithLease)

import TestSupport (SuiteBuilder, describe, it, shouldReturn)

data Probe
  = Direct
  | RedirectGet
  | RedirectPost
  | RedirectLogin
  | StaleReuse
  | GenericDirect
  | GenericRedirectGet
  | GenericStaleReuse
  deriving (Eq, Show)

httpClientExchangePolicySuite :: SuiteBuilder ()
httpClientExchangePolicySuite = describe "HTTP exchange policy"
  $ forM_
    [ Direct
    , RedirectGet
    , RedirectPost
    , RedirectLogin
    , StaleReuse
    , GenericDirect
    , GenericRedirectGet
    , GenericStaleReuse
    ]
  $ \selected ->
    it (show selected) (exercise selected `shouldReturn` expectedObservation selected)

expectedObservation :: Probe -> Value
expectedObservation selected = case selected of
  Direct -> expected 1 ["/start"] (status 200)
  RedirectGet -> expected 1 ["/start"] (status 302)
  RedirectPost -> expected 1 ["/start"] (status 307)
  RedirectLogin -> expected 1 ["/v1/auth/kubernetes/login"] (object ["login_accepted" .= False])
  StaleReuse -> stale
  GenericDirect -> expected 1 ["/start"] (status 200)
  GenericRedirectGet -> expected 2 ["/start", "/final"] (status 200)
  GenericStaleReuse -> stale
 where
  expected :: Int -> [String] -> Value -> Value
  expected requests paths result = object ["case" .= show selected, "result" .= result, "requests" .= requests, "paths" .= paths]
  status :: Int -> Value
  status value = object ["status" .= value]
  stale =
    expected
      2
      ["/stale", "/stale"]
      (object ["first_status" .= (200 :: Int), "second_status" .= (Nothing :: Maybe Int)])

fixturePort :: Socket.SockAddr -> IO Int
fixturePort address = case address of
  Socket.SockAddrInet value _ -> pure (fromIntegral value)
  _ -> fail "HTTP policy fixture requires IPv4"

exercise :: Probe -> IO Value
exercise selected = Socket.withSocketsDo $ bracket open Socket.close $ \listener -> do
  port <- fixturePort =<< Socket.getSocketName listener
  paths <- newIORef []
  let endpoint path = "http://127.0.0.1:" <> show port <> path
      request path method body
        | selected `elem` [GenericDirect, GenericRedirectGet, GenericStaleReuse] =
            bimap HttpBoundedTransport (fmap Lazy.toStrict)
              <$> httpRequestRaw
                (HttpConfig 1000000)
                method
                [("X-Fixture-Token", "synthetic-http-policy-token")]
                (endpoint path)
                body
        | otherwise =
            httpRequestRawBounded
              (HttpConfig 1000000)
              4096
              method
              [("X-Fixture-Token", "synthetic-http-policy-token")]
              (endpoint path)
              body
      serve = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
        requestPath <- observe paths =<< receive connection BS.empty
        case selected of
          stale | stale `elem` [StaleReuse, GenericStaleReuse] -> do
            ordinal <- length <$> readIORef paths
            if ordinal == 1
              then do
                respond connection 200 [] "keep-alive" "ok"
                _ <- observe paths =<< receive connection BS.empty
                -- The reused request reached the server, then lost its reply.
                -- Returning closes that connection; a hidden retry accepts a
                -- new connection and reaches the ordinary response below.
                pure ()
              else respond connection 200 [] "close" "ok"
          direct | direct `elem` [Direct, GenericDirect] -> respond connection 200 [] "close" "ok"
          _
            | requestPath == "/final" -> respond connection 200 [] "close" loginBody
            | otherwise ->
                respond
                  connection
                  (if selected `elem` [RedirectGet, GenericRedirectGet] then 302 else 307)
                  [("Location", Bytes.pack (endpoint "/final"))]
                  "close"
                  "move"
  Async.withAsync (forever serve) $ \worker -> do
    Async.link worker
    result <- case selected of
      RedirectLogin -> do
        response <-
          vaultKubernetesLoginWithLease
            (VaultAddress (Text.pack (endpoint "")))
            "kubernetes"
            "synthetic-role"
            "synthetic-jwt"
        pure (object ["login_accepted" .= isRight response])
      stale | stale `elem` [StaleReuse, GenericStaleReuse] -> do
        firstReply <- request "/stale" "POST" (Just "synthetic-input")
        unless (fmap fst firstReply == Right 200) (fail "stale control prefix failed")
        second <- request "/stale" "POST" (Just "synthetic-input")
        pure
          ( object
              ["first_status" .= (200 :: Int), "second_status" .= either (const Nothing) (Just . fst) second]
          )
      _ -> do
        let method = if selected == RedirectPost then "POST" else "GET"
        response <-
          request "/start" method (if selected == RedirectPost then Just "synthetic-input" else Nothing)
        pure (object ["status" .= either (const Nothing) (Just . fst) response])
    observed <- readIORef paths
    pure
      ( object
          ["case" .= show selected, "result" .= result, "requests" .= length observed, "paths" .= observed]
      )
 where
  open = do
    listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen listener 8
    pure listener
  loginBody =
    "{\"auth\":{\"client_token\":\"synthetic-http-policy-login\",\"lease_duration\":60,\"renewable\":false}}"

observe :: IORef [String] -> BS.ByteString -> IO String
observe paths raw = do
  request <- maybe (fail "invalid policy fixture request") pure (Server.parseControlPlaneRequest raw)
  let path = Server.parsedRequestPath request
  atomicModifyIORef' paths (\seen -> (seen <> [path], path))

receive :: Socket.Socket -> BS.ByteString -> IO BS.ByteString
receive connection accumulated
  | BS.length accumulated > 70000 = fail "HTTP policy fixture framing bound"
  | otherwise = case Server.inspectControlPlaneRequestFraming accumulated of
      Left cause -> fail (show cause)
      Right (Server.ControlPlaneFramingComplete raw) -> pure raw
      Right Server.ControlPlaneFramingIncomplete -> do
        chunk <- Net.recv connection 4096
        if BS.null chunk then fail "HTTP policy fixture EOF" else receive connection (accumulated <> chunk)

respond
  :: Socket.Socket -> Int -> [(BS.ByteString, BS.ByteString)] -> BS.ByteString -> BS.ByteString -> IO ()
respond connection status headers disposition body =
  void (Net.sendAll connection bytes) `catch` ignoreClosed
 where
  bytes =
    BS.concat
      ( [ "HTTP/1.1 " <> Bytes.pack (show status) <> " Fixture\r\n"
        , "Content-Length: " <> Bytes.pack (show (BS.length body)) <> "\r\n"
        , "Content-Type: application/json\r\n"
        , "Connection: " <> disposition <> "\r\n"
        ]
          <> map (\(name, value) -> name <> ": " <> value <> "\r\n") headers
          <> ["\r\n", body]
      )
  ignoreClosed :: IOException -> IO ()
  ignoreClosed _ = pure ()
