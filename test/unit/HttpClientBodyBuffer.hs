{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module HttpClientBodyBuffer (httpClientBodyBufferCases) where

import Control.Concurrent.Async qualified as Async
import Control.Exception (IOException, bracket, catch)
import Control.Monad (forM_, replicateM_)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Bytes8
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as Net
import Numeric (showHex)
import Prodbox.Http.Client
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, (@?=))

httpClientBodyBufferCases :: [(String, Assertion)]
httpClientBodyBufferCases =
  [
    ( "full two-MiB body with one-byte transfer chunks"
    , do
        observed <- fragmentedResponse
        case observed of
          Left cause -> assertFailure (show cause)
          Right (status, bytes) -> do
            status @?= 200
            Bytes.length bytes @?= 2 * 1048576
            assertBool "every decoded byte retained" (Bytes.all (== 120) bytes)
    )
  ]
    <> [ ( show (size, width, limit)
         , do
             observed <- response size width limit
             if size > limit
               then case observed of
                 Left (HttpBoundedResponseTooLarge actual actualLimit) -> do
                   actualLimit @?= limit
                   assertBool
                     "crossing is exact and remains within delivered body"
                     (actual > fromIntegral limit && actual <= fromIntegral size)
                 other -> assertFailure ("wrong crossing result: " <> show other)
               else case observed of
                 Left cause -> assertFailure (show cause)
                 Right (status, bytes) -> do
                   status @?= 200
                   Bytes.length bytes @?= size
                   assertBool "every byte retained" (Bytes.all (== 120) bytes)
         )
       | (size, width, limit) <-
           [ (0, 1, 0)
           , (1, 1, 0)
           , (1, 1, 1)
           , (1, 1, 2097152)
           , (32767, 1, 32767)
           , (32768, 4096, 32768)
           , (32769, 1, 32769)
           , (65537, 4096, 65537)
           , (65538, 1, 65537)
           , (65537, 65537, 65537)
           ]
       ]

fragmentedResponse :: IO (Either HttpBoundedError (Int, Bytes.ByteString))
fragmentedResponse = Socket.withSocketsDo $ bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure (fromIntegral value :: Int)
    _ -> assertFailure "fragment fixture requires IPv4"
  let serve = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
        receive connection Bytes.empty
        let send bytes = Net.sendAll connection bytes `catch` ignoreClosed
            block = Bytes.concat (replicate 8192 "1\r\nx\r\n")
        send "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        replicateM_ 256 (send block)
        send "0\r\n\r\n"
  Async.withAsync serve $ \worker -> do
    Async.link worker
    httpRequestRawBounded
      (HttpConfig 30000000)
      (2 * 1048576)
      "GET"
      []
      ("http://127.0.0.1:" <> show port <> "/fragments")
      Nothing
 where
  open = do
    listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen listener 2
    pure listener
  ignoreClosed :: IOException -> IO ()
  ignoreClosed _ = pure ()

receive :: Socket.Socket -> Bytes.ByteString -> IO ()
receive connection accumulated
  | Bytes.length accumulated > 4096 = assertFailure "fixture request too large"
  | "\r\n\r\n" `Bytes.isInfixOf` accumulated = pure ()
  | otherwise = do
      chunk <- Net.recv connection 4096
      if Bytes.null chunk then assertFailure "fixture EOF" else receive connection (accumulated <> chunk)

response :: Int -> Int -> Int -> IO (Either HttpBoundedError (Int, Bytes.ByteString))
response size width limit = Socket.withSocketsDo $ bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure (fromIntegral value :: Int)
    _ -> assertFailure "compatibility fixture requires IPv4"
  let serve = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
        receive connection Bytes.empty
        let send bytes = Net.sendAll connection bytes `catch` ignoreClosed
        send "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        forM_ (chunks width (Bytes.replicate size 120)) $ \piece ->
          send (Bytes8.pack (showHex (Bytes.length piece) "") <> "\r\n" <> piece <> "\r\n")
        send "0\r\n\r\n"
  Async.withAsync serve $ \worker -> do
    Async.link worker
    httpRequestRawBounded
      (HttpConfig 30000000)
      limit
      "GET"
      []
      ("http://127.0.0.1:" <> show port <> "/body")
      Nothing
 where
  open = do
    listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen listener 2
    pure listener
  ignoreClosed :: IOException -> IO ()
  ignoreClosed _ = pure ()

chunks :: Int -> Bytes.ByteString -> [Bytes.ByteString]
chunks width bytes
  | Bytes.null bytes = []
  | otherwise = let (prefix, suffix) = Bytes.splitAt width bytes in prefix : chunks width suffix
