{-# LANGUAGE ImportQualifiedPost #-}

-- | Native UDP transport for one RFC 10049 query. Signed replies and locally
-- bounded waits do not establish a trustworthy server or elapsed clock.
module Prodbox.ControlPlane.Roughtime.Udp (queryRoughtimeUdp) where

import Control.Exception (IOException, bracket, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Word (Word16)
import Network.Socket
  ( AddrInfo (..)
  , AddrInfoFlag (AI_NUMERICSERV)
  , SocketType (Datagram)
  , close
  , connect
  , defaultHints
  , getAddrInfo
  , socket
  )
import Network.Socket.ByteString qualified as Socket
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Deadline (Deadline)
import Prodbox.ControlPlane.Roughtime (RoughtimeError, RoughtimeReading, queryRoughtimeOnce)
import Prodbox.ControlPlane.SignedTimeBounds
  ( ElapsedClockSample
  , TimeScaleMovementBound
  )

-- Only an untrusted signed reading: server accuracy and clock assumptions
-- require separate proof. The enclosing query bounds interruptible local wait.
queryRoughtimeUdp
  :: IO ElapsedClockSample
  -> Deadline
  -> ByteString
  -> Natural
  -> TimeScaleMovementBound
  -> String
  -> Word16
  -> IO (Either RoughtimeError RoughtimeReading)
queryRoughtimeUdp elapsed deadline root slowdown movement host port =
  queryRoughtimeOnce elapsed deadline root slowdown movement (exchangeUdp host port)

exchangeUdp :: String -> Word16 -> ByteString -> IO ByteString
exchangeUdp host port request
  | null host || length host > 253 || port == 0 || '\0' `elem` host =
      ioError (userError "invalid Roughtime endpoint")
  | otherwise = do
      addresses <-
        getAddrInfo
          (Just defaultHints {addrSocketType = Datagram, addrFlags = [AI_NUMERICSERV]})
          (Just host)
          (Just (show port))
      tryAddresses addresses
 where
  tryAddresses [] = ioError (userError "Roughtime UDP endpoint unavailable")
  tryAddresses (address : rest) = do
    result <-
      try (bracket (socket (addrFamily address) Datagram (addrProtocol address)) close (exchange address))
        :: IO (Either IOException ByteString)
    case result of
      Left _ -> tryAddresses rest
      Right reply -> pure reply
  exchange address peer = do
    connect peer (addrAddress address)
    sent <- Socket.send peer request
    if sent /= ByteString.length request
      then ioError (userError "Roughtime datagram write incomplete")
      else Socket.recv peer (ByteString.length request + 1)
