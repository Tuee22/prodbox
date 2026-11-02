{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- Test-only, same-process relay. The real daemon sees this fixture's UID/PID;
-- the production connection still observes the real bus and pinned manager.
module SystemdSubmissionProxy
  ( SubmissionFault (..)
  , SubmissionProxy
  , withSubmissionProxy
  , awaitSubmissionRequest
  , awaitSubmissionReply
  , releaseSubmissionRequest
  , awaitSubmissionProxyClosed
  ) where

import Control.Concurrent (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async qualified as Async
import Control.Exception (IOException, bracket, finally, onException)
import Control.Monad (guard, unless, void, when)
import Data.Bits (shiftL)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Word (Word32, Word64, Word8)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.IO.Exception (ioe_errno)
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as Network
import System.Directory (removeFile)
import System.IO.Error (catchIOError)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

data SubmissionFault = QueueBeforeManager | QueueThenCloseSender | WithholdManagerReply
  deriving (Eq, Show)

data SubmissionProxy
  = SubmissionProxy
      !Word64
      !SubmissionFault
      !(MVar Word32)
      !(MVar ())
      !(MVar ())
      !(MVar ())
      !(IORef (Maybe Word32))

withSubmissionProxy
  :: Word64
  -> FilePath
  -> SubmissionFault
  -> (SubmissionProxy -> FilePath -> IO value)
  -> IO value
withSubmissionProxy ending path fault action = bracket acquire release $ \(listener, upstream) -> do
  proxy <-
    SubmissionProxy ending fault
      <$> newEmptyMVar
      <*> newEmptyMVar
      <*> newEmptyMVar
      <*> newEmptyMVar
      <*> newIORef Nothing
  let serve = bracket (within proxy (Socket.accept listener)) (Socket.close . fst) $ \(client, _) ->
        Async.race_ (clientMessages proxy client upstream) (serverMessages proxy upstream client)
      retire = Socket.close upstream `finally` markClosed proxy
  Async.withAsync ((serve `catchIOError` disconnected proxy) `finally` retire) $ \worker -> do
    Async.link worker
    action proxy path `finally` Async.cancel worker
 where
  acquire = do
    unless (length path < 108 && '\0' `notElem` path) (fail "submission proxy path refused")
    listener <- Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol
    Socket.bind listener (Socket.SockAddrUnix path)
      `onException` Socket.close listener
    Socket.listen listener 1
      `onException` (Socket.close listener >> removeFile path)
    upstream <-
      Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol
        `onException` (Socket.close listener >> removeFile path)
    uid <- getEffectiveUserID
    withinEnd
      ending
      (Socket.connect upstream (Socket.SockAddrUnix ("/run/user/" <> show uid <> "/bus")))
      `onException` (Socket.close upstream >> Socket.close listener >> removeFile path)
    pure (listener, upstream)
  release (listener, upstream) =
    Socket.close listener `finally` (Socket.close upstream `finally` removeFile path)

markClosed :: SubmissionProxy -> IO ()
markClosed (SubmissionProxy _ _ _ _ _ closed _) = void (tryPutMVar closed ())

disconnected :: SubmissionProxy -> IOException -> IO ()
disconnected (SubmissionProxy _ _ _ _ _ _ serial) cause = do
  submitted <- readIORef serial
  if submitted /= Nothing && ioe_errno cause `elem` [Just 32, Just 104]
    then pure ()
    else ioError cause

awaitSubmissionRequest :: SubmissionProxy -> IO Word32
awaitSubmissionRequest proxy@(SubmissionProxy _ _ request _ _ _ _) = within proxy (readMVar request)

awaitSubmissionReply :: SubmissionProxy -> IO ()
awaitSubmissionReply proxy@(SubmissionProxy _ _ _ _ reply _ _) = within proxy (readMVar reply)

releaseSubmissionRequest :: SubmissionProxy -> IO ()
releaseSubmissionRequest (SubmissionProxy _ _ _ release _ _ _) = putMVar release ()

awaitSubmissionProxyClosed :: SubmissionProxy -> IO ()
awaitSubmissionProxyClosed proxy@(SubmissionProxy _ _ _ _ _ closed _) = within proxy (readMVar closed)

within :: SubmissionProxy -> IO value -> IO value
within (SubmissionProxy ending _ _ _ _ _ _) = withinEnd ending

withinEnd :: Word64 -> IO value -> IO value
withinEnd ending action = do
  now <- getMonotonicTimeNSec
  when (now >= ending) (fail "submission proxy original deadline reached")
  let micros = (ending - now) `div` 1000
  when
    (micros == 0 || toInteger micros > toInteger (maxBound :: Int))
    (fail "submission proxy budget refused")
  result <- timeout (fromIntegral micros) action
  maybe (fail "submission proxy original deadline reached") pure result

clientMessages :: SubmissionProxy -> Socket.Socket -> Socket.Socket -> IO ()
clientMessages proxy@(SubmissionProxy _ fault requested release replied _ serial) client upstream =
  authentication BS.empty
 where
  authentication buffer = receiveLine proxy client buffer $ \line rest -> do
    within proxy (Network.sendAll upstream line)
    if line == "BEGIN\r\n"
      then binaryMessages proxy client rest $ \frame -> do
        fields <- maybe (fail "submission proxy header refused") pure (headerFields frame)
        if lookup 3 fields == Just (HeaderString "StartTransientUnit")
          then do
            identifier <- maybe (fail "submission proxy serial refused") pure (word32 frame 8)
            prior <- readIORef serial
            unless (prior == Nothing && identifier > 0) (fail "submission proxy repeated submission")
            writeIORef serial (Just identifier)
            void (tryPutMVar requested identifier)
            when (fault /= WithholdManagerReply) (within proxy (takeMVar release))
            within proxy (Network.sendAll upstream frame)
            -- The positive queued-effect schedule keeps daemon credentials live
            -- until the real reply. Closing here instead can make authorization
            -- refuse before materializing any unit; that distinct failed
            -- startup expectation is retained in the qualification evidence.
            when (fault == QueueBeforeManager) (within proxy (readMVar replied))
          else within proxy (Network.sendAll upstream frame)
      else authentication rest

serverMessages :: SubmissionProxy -> Socket.Socket -> Socket.Socket -> IO ()
serverMessages proxy@(SubmissionProxy _ fault _ _ replied _ serial) upstream client =
  authentication BS.empty
 where
  authentication buffer
    | BS.null buffer = do
        chunk <- within proxy (Network.recv upstream 4096)
        unless (BS.null chunk) (authentication chunk)
    | BS.head buffer `elem` [66, 108] = binaryMessages proxy upstream buffer forward
    | otherwise = receiveLine proxy upstream buffer $ \line rest -> within proxy (Network.sendAll client line) >> authentication rest
  forward frame = do
    fields <- maybe (fail "submission proxy reply header refused") pure (headerFields frame)
    expected <- readIORef serial
    let matching = case (expected, lookup 5 fields) of
          (Just value, Just (HeaderWord reply)) -> value == reply
          _ -> False
    if matching
      then do
        unless
          (fault == QueueThenCloseSender || BS.index frame 1 == 2)
          (fail "native manager refused the authored submission")
        void (tryPutMVar replied ())
      else within proxy (Network.sendAll client frame)

receiveLine
  :: SubmissionProxy
  -> Socket.Socket
  -> ByteString
  -> (ByteString -> ByteString -> IO ())
  -> IO ()
receiveLine proxy socket buffer action = do
  let (prefix, suffix) = BS.breakSubstring "\r\n" buffer
  if BS.null suffix
    then do
      when (BS.length buffer > 8192) (fail "submission proxy authentication ceiling")
      chunk <- within proxy (Network.recv socket 4096)
      if BS.null chunk
        then unless (BS.null buffer) (fail "submission proxy partial authentication")
        else receiveLine proxy socket (buffer <> chunk) action
    else action (prefix <> "\r\n") (BS.drop 2 suffix)

binaryMessages
  :: SubmissionProxy -> Socket.Socket -> ByteString -> (ByteString -> IO ()) -> IO ()
binaryMessages proxy socket initial action = loop initial
 where
  loop buffer
    | BS.length buffer < 16 = more buffer
    | otherwise = do
        amount <- maybe (fail "submission proxy frame refused") pure (frameLength buffer)
        if BS.length buffer < amount
          then more buffer
          else do
            let (frame, rest) = BS.splitAt amount buffer
            action frame
            loop rest
  more buffer = do
    when (BS.length buffer > 131072) (fail "submission proxy frame ceiling")
    chunk <- within proxy (Network.recv socket 4096)
    if BS.null chunk
      then unless (BS.null buffer) (fail "submission proxy partial frame")
      else loop (buffer <> chunk)

frameLength :: ByteString -> Maybe Int
frameLength bytes = do
  guard (BS.length bytes >= 16 && BS.index bytes 3 == 1 && BS.index bytes 1 `elem` [1, 2, 3, 4])
  body <- word32 bytes 4
  fields <- word32 bytes 12
  let total = align 8 (16 + toInteger fields) + toInteger body
  guard (total <= 131072)
  pure (fromInteger total)

data HeaderValue = HeaderString !ByteString | HeaderWord !Word32
  deriving (Eq)

-- Only standard header types used by the real daemon/manager are admitted.
-- No message body is decoded, recorded or interpreted by the relay.
headerFields :: ByteString -> Maybe [(Word8, HeaderValue)]
headerFields bytes = do
  amount <- word32 bytes 12
  let ending = 16 + fromIntegral amount
      go position
        | position == ending = Just []
        | otherwise = do
            let offset = align 8 position
            guard (offset + 4 <= ending)
            let code = BS.index bytes offset
                signature = BS.index bytes (offset + 2)
            guard (BS.index bytes (offset + 1) == 1 && BS.index bytes (offset + 3) == 0)
            let value = align 4 (offset + 4)
            (decoded, next) <- case signature of
              117 -> do
                guard (code `elem` [5, 9] && value + 4 <= ending)
                number <- word32 bytes value
                pure (HeaderWord number, value + 4)
              115 -> string code value ending
              111 -> string code value ending
              103 -> do
                guard (code == 8 && offset + 5 <= ending)
                let size = fromIntegral (BS.index bytes (offset + 4))
                    next = offset + 6 + size
                guard (next <= ending && BS.index bytes (next - 1) == 0)
                pure (HeaderString (BS.take size (BS.drop (offset + 5) bytes)), next)
              _ -> Nothing
            rest <- go next
            guard (code `notElem` map fst rest)
            pure ((code, decoded) : rest)
      string code value limit = do
        guard (code `elem` [1, 2, 3, 4, 6, 7] && value + 4 <= limit)
        size <- word32 bytes value
        let next = toInteger value + 5 + toInteger size
        guard (next <= toInteger limit && BS.index bytes (fromInteger next - 1) == 0)
        pure (HeaderString (BS.take (fromIntegral size) (BS.drop (value + 4) bytes)), fromInteger next)
  guard (ending <= BS.length bytes)
  go 16

word32 :: ByteString -> Int -> Maybe Word32
word32 bytes offset = do
  guard (offset >= 0 && offset + 4 <= BS.length bytes && BS.length bytes >= 16)
  let raw = BS.unpack (BS.take 4 (BS.drop offset bytes))
  ordered <- case BS.index bytes 0 of
    108 -> Just raw
    66 -> Just (reverse raw)
    _ -> Nothing
  pure (sum [fromIntegral byte `shiftL` shift | (byte, shift) <- zip ordered [0, 8, 16, 24]])

align :: (Integral value) => value -> value -> value
align boundary value = ((value + boundary - 1) `div` boundary) * boundary
