{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Minimal native loopback stand-in for the operation-owned kubectl child.
-- No Kubernetes/AWS connection or credential is consumed by this fixture.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (forever, when)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Network.Socket
import Network.Socket.ByteString (recv, sendAll)
import System.Environment (getArgs, getEnv)
import System.IO (hClose, hFlush, stdout)
import Text.Read (readMaybe)

main :: IO ()
main = withSocketsDo $ do
  arguments <- getArgs
  port <- case [ number
               | argument <- arguments
               , ':' `elem` argument
               , Just number <- [readMaybe (takeWhile (/= ':') argument) :: Maybe Int]
               ] of
    [number] -> pure number
    _ -> fail "fixture requires one forwarded port"
  directory <- getEnv "FIXTURE_AUTHORITY_CHANNEL_ROOT"
  scenario <- readFile (directory <> "/authority-channel-case")
  bracket (socket AF_INET Stream defaultProtocol) close $ \listener -> do
    setSocketOption listener ReuseAddr 1
    bind listener (SockAddrInet (fromIntegral port) (tupleToHostAddress (127, 0, 0, 1)))
    listen listener 8
    writeFile (directory <> "/authority-channel-port") (show port)
    let acknowledgement selectedPort = "Forwarding from 127.0.0.1:" <> show selectedPort <> " -> 8600\n"
    case scenario of
      "startup-missing" -> hClose stdout
      "startup-wrong-port" -> putStr (acknowledgement (port + 1)) >> hFlush stdout
      "startup-partial" -> putStr "Forwarding from " >> hFlush stdout >> hClose stdout
      _ -> putStr (acknowledgement port) >> hFlush stdout
    forever $ bracket (fst <$> accept listener) close $ \connection -> do
      bytes <- headers connection BS.empty
      let post = "POST " `BS.isPrefixOf` bytes
      when ("GET " `BS.isPrefixOf` bytes) $
        writeFile (directory <> "/authority-channel-probe-started") "observed"
      when post $ do
        writeFile (directory <> "/authority-channel-http-started") "observed"
        when (scenario `elem` ["join-http", "cancel-http"]) (threadDelay 1000000)
        writeFile (directory <> "/authority-channel-http-finished") "observed"
      sendAll connection "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"

headers :: Socket -> BS.ByteString -> IO BS.ByteString
headers connection previous
  | "\r\n\r\n" `BS.isInfixOf` previous = pure previous
  | BS.length previous >= 65536 = fail "fixture header bound"
  | otherwise = do
      bytes <- recv connection 4096
      if BS.null bytes
        then fail ("fixture EOF: " <> B8.unpack previous)
        else headers connection (previous <> bytes)
