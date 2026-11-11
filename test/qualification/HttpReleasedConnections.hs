{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- Native release and TLS-dispatch controls. The whole-fixture QA watchdog
-- excludes a cold-start performance claim; per-case deadlines remain explicit.
module Main (main) where

import Control.Concurrent (MVar, newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.Async (cancel, withAsync)
import Control.Exception (bracket, bracketOnError)
import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.Maybe (isJust, isNothing)
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as Socket
import Prodbox.Http.Client
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit

withPeer :: ByteString -> ((String, MVar (), MVar ()) -> IO value) -> IO value
withPeer response action = bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure value
    _ -> fail "fixture did not bind an IPv4 socket"
  sent <- newEmptyMVar
  ended <- newEmptyMVar
  let serve = bracket (fst <$> Socket.accept listener) Socket.close $ \peer -> do
        headers peer Bytes.empty
        Socket.sendAll peer response
        putMVar sent ()
        drain peer ended
  withAsync serve $ \_ -> do
    outcome <- timeout 30000000 (action ("http://127.0.0.1:" <> show port <> "/probe", sent, ended))
    maybe (fail "loopback fixture exceeded its QA watchdog") pure outcome
 where
  open = bracketOnError (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \listener -> do
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen listener 1
    pure listener
  headers peer accumulated
    | "\r\n\r\n" `Bytes.isInfixOf` accumulated = pure ()
    | Bytes.length accumulated >= 8192 = fail "fixture request headers exceeded 8 KiB"
    | otherwise = do
        chunk <- Socket.recv peer 4096
        unless (Bytes.length chunk > 0) (fail "fixture request ended before its headers")
        headers peer (accumulated <> chunk)
  drain peer ended = do
    chunk <- Socket.recv peer 4096
    if Bytes.null chunk then putMVar ended () else drain peer ended

closed :: MVar () -> IO ()
closed ended = do
  observed <- timeout 300000 (readMVar ended)
  assertBool "completed bounded request retained its peer connection" (isJust observed)

healthy :: ByteString
healthy = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"

request :: Int -> String -> IO (Either HttpBoundedError (Int, ByteString))
request limit endpoint = httpRequestRawBoundedNoIdle (HttpConfig 1000000) limit "GET" [] endpoint Nothing

expect :: (Int, ByteString) -> IO (Either HttpBoundedError (Int, ByteString)) -> IO ()
expect expected action = action >>= either (fail . show) (@?= expected)

main :: IO ()
main =
  defaultMain $
    testGroup
      "bounded HTTP released connections"
      [ testCase "complete response closes its connection" $ withPeer healthy $ \(url, _, ended) -> do
          expect (200, "ok") (request 2 url)
          closed ended
      , testCase "bodyless response closes its connection" $
          withPeer "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n" $ \(url, _, ended) -> do
            expect (204, "") (request 0 url)
            closed ended
      , testCase "redirect is returned without following and closes its connection" $
          withPeer "HTTP/1.1 302 Found\r\nLocation: https://unused.invalid/\r\nContent-Length: 0\r\n\r\n" $ \(url, _, ended) -> do
            expect (302, "") (request 2 url)
            closed ended
      , testCase "over-limit complete response refuses and closes its connection" $ withPeer healthy $ \(url, _, ended) -> do
          answer <- request 1 url
          case answer of
            Left (HttpBoundedResponseTooLarge _ 1) -> pure ()
            _ -> assertFailure "body ceiling changed"
          closed ended
      , testCase "original outer timeout closes an incomplete response" $
          withPeer "HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\nx" $ \(url, _, ended) -> do
            answer <- timeout 100000 (request 20 url)
            assertBool "incomplete response escaped the original outer deadline" (isNothing answer)
            closed ended
      , testCase "cancellation closes an incomplete response" $
          withPeer "HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\nx" $ \(url, sent, ended) -> do
            withAsync (request 20 url) $ \client -> do
              readMVar sent
              cancel client
            closed ended
      , testCase "the default client retains healthy connection reuse" $ withPeer healthy $ \(url, _, ended) -> do
          expect (200, "ok") (httpRequestRawBounded (HttpConfig 1000000) 2 "GET" [] url Nothing)
          observed <- timeout 50000 (readMVar ended)
          assertBool "default shared pooling changed" (isNothing observed)
      , testCase "fresh endpoint keys do not retain released connections" $
          forM_ [1 :: Int .. 8] $ \_ -> withPeer healthy $ \(url, _, ended) -> do
            expect (200, "ok") (request 2 url)
            closed ended
      , testCase "HTTPS still reaches the native TLS handshake" $ withTlsPeer $ \(url, observed) -> do
          result <- httpRequestRawBoundedNoIdle (HttpConfig 1000000) 20 "GET" [] url Nothing
          firstByte <- readMVar observed
          firstByte @?= 22
          case result of
            Left (HttpBoundedTransport _) -> pure ()
            _ -> assertFailure "fixture's closed TLS handshake was accepted"
      ]

-- The peer observes a ClientHello and then closes. No server certificate or
-- credential is supplied, and no TLS record bytes are retained or logged.
withTlsPeer :: ((String, MVar Word) -> IO value) -> IO value
withTlsPeer action = bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure value
    _ -> fail "fixture did not bind an IPv4 TLS probe"
  observed <- newEmptyMVar
  let serve = bracket (fst <$> Socket.accept listener) Socket.close $ \peer -> do
        hello <- Socket.recv peer 4096
        unless (Bytes.length hello > 0) (fail "TLS probe received no handshake")
        putMVar observed (fromIntegral (Bytes.head hello))
  withAsync serve $ \_ -> do
    result <- timeout 30000000 (action ("https://127.0.0.1:" <> show port <> "/probe", observed))
    maybe (fail "TLS probe exceeded its QA watchdog") pure result
 where
  open = bracketOnError (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \listener -> do
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen listener 1
    pure listener
