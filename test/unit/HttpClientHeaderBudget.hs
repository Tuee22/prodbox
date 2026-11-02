{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module HttpClientHeaderBudget (httpClientHeaderBudgetCases) where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, bracket, catch, fromException)
import Control.Monad (forM_, replicateM_)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Bytes8
import Data.List (isInfixOf, isPrefixOf)
import Data.Maybe (isJust)
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as Net
import Prodbox.Http.Client
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, (@?=))

data HeaderReply = HeaderReply
  { earlyHeaders :: [[Bytes.ByteString]]
  , finalHeaders :: [Bytes.ByteString]
  , continueCount :: Int
  }

httpClientHeaderBudgetCases :: [(String, Assertion)]
httpClientHeaderBudgetCases =
  [ ( "empty informational blocks " <> show count
    , expectReply (count <= 100) (HeaderReply (replicate count []) [] 0)
    )
  | count <- [0, 1, 99, 100, 101, 256]
  ]
    <> [ ( "aggregate informational fields " <> show count
         , expectReply (count + 2 <= 100) (HeaderReply (groups 49 (replicate count "X-Field: value")) [] 0)
         )
       | count <- [1, 97, 98, 99, 100, 101, 198]
       ]
    <> [ ( "one field per informational block " <> show count
         , expectReply (count + 2 <= 100) (HeaderReply (replicate count ["X-Field: value"]) [] 0)
         )
       | count <- [98, 99, 100, 101]
       ]
    <> [
         ( "complete final-header domain stays accepted"
         , expectReply True (HeaderReply [] (replicate 97 wideHeader) 0)
         )
       ,
         ( "complete combined-header domain stays accepted"
         , expectReply True (HeaderReply [replicate 49 wideHeader, replicate 49 wideHeader] [] 0)
         )
       ,
         ( "per-block parser refusal stays distinct"
         , expectReply False (HeaderReply [replicate 100 "X-Field: value"] [] 0)
         )
       , ("continue responses do not consume retained-hint slots", expectReply True (HeaderReply [] [] 101))
       ,
         ( "concurrent calls keep independent counters"
         , do
             (first, second) <-
               Async.concurrently
                 (request (HeaderReply [replicate 70 "X-Field: value"] [] 0))
                 (request (HeaderReply [replicate 70 "X-Field: value"] [] 0))
             first @?= Right (200, "ok")
             second @?= Right (200, "ok")
         )
       ,
         ( "a completed exchange does not spend its successor's budget"
         , replicateM_ 3 (expectReply True (HeaderReply (replicate 98 ["X-Field: value"]) [] 0))
         )
       , ("cancellation escapes both typed exception handlers", cancellationEscapes)
       ]
 where
  wideHeader = "X-Padding: " <> Bytes.replicate 4000 97

groups :: Int -> [value] -> [[value]]
groups _ [] = []
groups size values = let (prefix, remaining) = splitAt size values in prefix : groups size remaining

expectReply :: Bool -> HeaderReply -> Assertion
expectReply accepted reply = do
  observed <- request reply
  if accepted
    then observed @?= Right (200, "ok")
    else case observed of
      Right result -> assertFailure ("unfunded retained headers accepted: " <> show result)
      Left cause
        | any ((>= 100) . length) (earlyHeaders reply) ->
            assertBool ("wrong parser refusal: " <> show cause) ("TooManyHeaderFields" `isInfixOf` show cause)
        | otherwise ->
            assertBool
              ("wrong aggregate refusal: " <> show cause)
              ("HttpBoundedResponseHeadersTooLarge" `isPrefixOf` show cause)

request :: HeaderReply -> IO (Either HttpBoundedError (Int, Bytes.ByteString))
request reply =
  Socket.withSocketsDo $ bracket openListener Socket.close $ \listener -> do
    address <- Socket.getSocketName listener
    port <- case address of
      Socket.SockAddrInet value _ -> pure (fromIntegral value :: Int)
      _ -> assertFailure "header fixture requires IPv4"
    let serve = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
          receive connection Bytes.empty
          let send bytes = Net.sendAll connection bytes `catch` ignoreClosed
          replicateM_ (continueCount reply) (send "HTTP/1.1 100 Continue\r\n\r\n")
          forM_ (earlyHeaders reply) $ \headers -> send ("HTTP/1.1 103 Early Hints\r\n" <> encodeHeaders headers <> "\r\n")
          send
            ( "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n"
                <> encodeHeaders (finalHeaders reply)
                <> "\r\nok"
            )
    Async.withAsync serve $ \worker -> do
      Async.link worker
      httpRequestRawBounded
        (HttpConfig 2000000)
        2
        "GET"
        []
        ("http://127.0.0.1:" <> show port <> "/header-budget")
        Nothing
 where
  encodeHeaders = Bytes.concat . map (<> "\r\n")
  ignoreClosed :: IOException -> IO ()
  ignoreClosed _ = pure ()

openListener :: IO Socket.Socket
openListener = do
  listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
  Socket.setSocketOption listener Socket.ReuseAddr 1
  Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
  Socket.listen listener 2
  pure listener

cancellationEscapes :: Assertion
cancellationEscapes = Socket.withSocketsDo $ bracket openListener Socket.close $ \listener -> do
  ready <- newEmptyMVar
  stalled <- newEmptyMVar
  address <- Socket.getSocketName listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure (fromIntegral value :: Int)
    _ -> assertFailure "cancellation fixture requires IPv4"
  let serve = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
        receive connection Bytes.empty
        putMVar ready ()
        takeMVar stalled
  Async.withAsync serve $ \server -> do
    Async.link server
    Async.withAsync
      ( httpRequestRawBounded
          (HttpConfig 2000000)
          2
          "GET"
          []
          ("http://127.0.0.1:" <> show port <> "/cancel")
          Nothing
      )
      $ \caller -> do
        takeMVar ready
        Async.cancel caller
        outcome <- Async.waitCatch caller
        case outcome of
          Left cause ->
            assertBool "cancellation was changed" (isJust (fromException cause :: Maybe Async.AsyncCancelled))
          Right result -> assertFailure ("cancellation became a response: " <> show result)

receive :: Socket.Socket -> Bytes.ByteString -> IO ()
receive connection accumulated
  | Bytes.length accumulated > 4096 = assertFailure "header fixture request exceeded its own bound"
  | "\r\n\r\n" `Bytes.isInfixOf` accumulated = pure ()
  | otherwise = do
      chunk <- Net.recv connection 4096
      if Bytes.null chunk
        then assertFailure ("header fixture request EOF: " <> Bytes8.unpack accumulated)
        else receive connection (accumulated <> chunk)
