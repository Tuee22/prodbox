{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A bounded, single-client stream around the connected read interpreter.
-- The caller must establish an isolated process/channel, bound and settle its
-- worker, and separately provide mutation admission and recovery.
module Prodbox.Control.KindDockerReadProtocol
  ( KindDockerProtocolOutcome (..)
  , KindDockerClientFailure (..)
  , serveKindDockerReads
  , serveKindDockerReadsWhile
  , serveKindDockerRequestsWhile
  , exchangeKindDockerRead
  , exchangeSerializedKindDockerRead
  , KindDockerRequest (..)
  , exchangeSerializedKindDockerRequest
  , exchangeKindDockerRequest
  , serveKindDockerInputRequestsWhile
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, finally, mask, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types qualified as AesonTypes
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.Char (isAscii, isPrint)
import Data.Word (Word32, Word8)
import Foreign.C.Error (eAGAIN, eINTR, eWOULDBLOCK, getErrno, throwErrnoIfMinus1_)
import Foreign.C.Types (CInt (..))
import Prodbox.Control.DockerConnectedInfo (DockerSession)
import Prodbox.Control.KindDockerReadGate
  ( KindDockerReadGate
  , KindDockerReply (..)
  , closeKindDockerReadGate
  , runConnectedKindDockerReply
  )
import Prodbox.Control.KindKubeconfigYaml (decodeBoundedYamlValue)
import System.IO (Handle, SeekMode (AbsoluteSeek), hFlush)
import System.Posix.Files
  ( FileStatus
  , fileMode
  , fileOwner
  , fileSize
  , getFdStatus
  , isRegularFile
  , linkCount
  , setFdSize
  )
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (Fd (..), UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

foreign import capi "sys/file.h value LOCK_EX" exclusiveLock :: CInt
foreign import capi "sys/file.h value LOCK_NB" nonBlockingLock :: CInt
foreign import capi "sys/file.h value LOCK_UN" unlock :: CInt
foreign import capi "sys/file.h flock" lockFile :: CInt -> CInt -> IO CInt

data KindDockerProtocolOutcome
  = KindDockerProtocolPeerClosed
  | KindDockerProtocolMalformed
  | KindDockerProtocolRejected
  | KindDockerProtocolEndpointChanged
  deriving (Eq, Show)

data KindDockerClientFailure
  = KindDockerClientInvalidRequest
  | KindDockerClientInvalidReply
  | KindDockerClientTransport
  | KindDockerClientInvalidLock
  | KindDockerClientLockFailure
  | KindDockerClientTimedOut
  | KindDockerClientUnsettled
  deriving (Eq, Show)

-- Payload bytes are transient and never rendered in errors or operation logs.
data KindDockerRequest = KindDockerRequest ![String] !BS.ByteString
  deriving (Eq)

-- | Serialize a single exchange with an independently opened lock descriptor.
-- Every client must independently open and verify the same lock inode; shared
-- open-file descriptions do not exclude one another. An in-flight marker is
-- synced before sending and cleared only after a successful reply. A timeout
-- is unconfirmed: the caller must close the channel and settle its peer before
-- any retry or recovery of the marker.
exchangeSerializedKindDockerRead
  :: Int -> Fd -> Handle -> Handle -> [String] -> IO (Either KindDockerClientFailure KindDockerReply)
exchangeSerializedKindDockerRead limit descriptor input output argv =
  exchangeSerializedKindDockerRequest limit descriptor input output (KindDockerRequest argv BS.empty)

exchangeSerializedKindDockerRequest
  :: Int
  -> Fd
  -> Handle
  -> Handle
  -> KindDockerRequest
  -> IO (Either KindDockerClientFailure KindDockerReply)
exchangeSerializedKindDockerRequest limit descriptor input output request
  | limit <= 0 || limit > 180000000 = pure (Left KindDockerClientInvalidLock)
  | otherwise = do
      attempted <- try $ do
        owner <- getEffectiveUserID
        status <- getFdStatus descriptor
        if not (validLockStatus owner status)
          then pure (Just (Left KindDockerClientInvalidLock))
          else timeout limit $ mask $ \restore -> do
            acquired <- acquire restore
            if not acquired
              then pure (Left KindDockerClientLockFailure)
              else exchangeUnderLock restore `finally` release
      pure $ case attempted of
        Left (_ :: IOException) -> Left KindDockerClientLockFailure
        Right Nothing -> Left KindDockerClientTimedOut
        Right (Just result) -> result
 where
  Fd number = descriptor
  acquire restore = do
    result <- lockFile number (exclusiveLock .|. nonBlockingLock)
    if result == 0
      then pure True
      else do
        cause <- getErrno
        if cause == eAGAIN || cause == eWOULDBLOCK || cause == eINTR
          then restore (threadDelay 10000) >> acquire restore
          else pure False
  exchangeUnderLock restore = do
    owner <- getEffectiveUserID
    status <- getFdStatus descriptor
    if not (validLockStatus owner status)
      then pure (Left KindDockerClientInvalidLock)
      else
        if fileSize status /= 0
          then pure (Left KindDockerClientUnsettled)
          else do
            _ <- Posix.fdSeek descriptor AbsoluteSeek 0
            count <- PosixBytes.fdWrite descriptor (BS8.pack "!")
            if count /= 1
              then pure (Left KindDockerClientLockFailure)
              else do
                fileSynchronise descriptor
                result <- restore (exchangeKindDockerRequest input output request)
                case result of
                  Right reply | kindDockerReplyExit reply == 0 -> do
                    finalStatus <- getFdStatus descriptor
                    if validLockStatus owner finalStatus && fileSize finalStatus == 1
                      then do
                        setFdSize descriptor 0
                        fileSynchronise descriptor
                        pure result
                      else pure (Left KindDockerClientInvalidLock)
                  _ -> pure result
  release = throwErrnoIfMinus1_ "unlock kind Docker client" (lockFile number unlock)

validLockStatus :: UserID -> FileStatus -> Bool
validLockStatus owner status =
  isRegularFile status
    && fileOwner status == owner
    && fileMode status .&. 0o077 == 0
    && linkCount status == 1

-- | Exchange one request on an exclusively held framed stream. The caller
-- must impose a deadline and settle the other endpoint; this function does
-- not authenticate the peer or authorize any effects.
exchangeKindDockerRead
  :: Handle -> Handle -> [String] -> IO (Either KindDockerClientFailure KindDockerReply)
exchangeKindDockerRead input output argv =
  exchangeKindDockerRequest input output (KindDockerRequest argv BS.empty)

exchangeKindDockerRequest
  :: Handle -> Handle -> KindDockerRequest -> IO (Either KindDockerClientFailure KindDockerReply)
exchangeKindDockerRequest input output (KindDockerRequest argv payload)
  | not (validArguments argv)
      || BS.length payload > 65536
      || BS.length request > (if BS.null payload then 16384 else 110000) =
      pure (Left KindDockerClientInvalidRequest)
  | otherwise = do
      result <- try $ do
        BS.hPut output (encodeLength (BS.length request))
        BS.hPut output request
        hFlush output
        header <- readExactly input 4
        case header of
          Just bytes | BS.length bytes == 4 -> do
            let declared = decodeLength bytes
            if declared == 0 || declared > 131072
              then pure Nothing
              else do
                let size = fromIntegral declared
                body <- readExactly input size
                case body of
                  Just replyBytes | BS.length replyBytes == size -> decodeReply replyBytes
                  _ -> pure Nothing
          _ -> pure Nothing
      pure $ case result of
        Left (_ :: IOException) -> Left KindDockerClientTransport
        Right Nothing -> Left KindDockerClientInvalidReply
        Right (Just reply) -> Right reply
 where
  request =
    BL.toStrict $
      if BS.null payload
        then Aeson.encode argv
        else
          Aeson.encode
            (Aeson.object ["argv" Aeson..= argv, "input" Aeson..= BS8.unpack (Base64.encode payload)])

decodeReply :: BS.ByteString -> IO (Maybe KindDockerReply)
decodeReply payload = do
  checked <- decodeBoundedYamlValue payload
  pure $ case (Aeson.eitherDecodeStrict' payload, checked) of
    (Right value, Right valid) | value == valid -> either (const Nothing) Just (AesonTypes.parseEither parseReply value)
    _ -> Nothing
 where
  parseReply = Aeson.withObject "kind Docker reply" $ \object -> do
    code <- object Aeson..: "exit"
    output <- object Aeson..: "stdout"
    failure <- object Aeson..: "stderr"
    let validText text =
          all
            (\character -> isAscii character && (isPrint character || character `elem` ("\n\r\t" :: String)))
            text
    if KeyMap.size object /= 3
      || not ((code == 0 && null failure) || (code == 1 && null output && not (null failure)))
      || not (validText output && validText failure)
      then fail "invalid kind Docker reply"
      else pure (KindDockerReply code (BS8.pack output) (BS8.pack failure))

-- | Read four-byte big-endian lengths followed by JSON arrays of arguments;
-- emit framed JSON replies. EOF, malformed input, any refused/failed request,
-- and any exception close the gate. No endpoint, timeout, authentication or
-- resource cleanup is provided by this function.
serveKindDockerReads
  :: KindDockerReadGate -> DockerSession -> String -> Handle -> Handle -> IO KindDockerProtocolOutcome
serveKindDockerReads = serveKindDockerReadsWhile (pure True)

-- | Recheck an independently held endpoint before and after each read. A
-- failed recheck stops the stream without returning a possibly stale reply.
-- It is still the caller's responsibility to exclude concurrent writers.
serveKindDockerReadsWhile
  :: IO Bool
  -> KindDockerReadGate
  -> DockerSession
  -> String
  -> Handle
  -> Handle
  -> IO KindDockerProtocolOutcome
serveKindDockerReadsWhile endpointStable gate session daemon input output =
  serveKindDockerRequestsWhile
    endpointStable
    (runConnectedKindDockerReply gate session daemon)
    (closeKindDockerReadGate gate)
    input
    output

-- | Framing and endpoint rechecks shared by a caller-supplied request
-- interpreter. The caller owns serialization, admission, and effect recovery.
-- A nonzero reply terminates the stream and cleanup runs on every exit.
serveKindDockerRequestsWhile
  :: IO Bool
  -> ([String] -> IO KindDockerReply)
  -> IO ()
  -> Handle
  -> Handle
  -> IO KindDockerProtocolOutcome
serveKindDockerRequestsWhile endpointStable interpret closeGate input output =
  serveKindDockerInputRequestsWhile endpointStable withoutInput closeGate input output
 where
  withoutInput (KindDockerRequest argv payload)
    | BS.null payload = interpret argv
    | otherwise = pure (KindDockerReply 1 BS.empty "kind request refused\n")

serveKindDockerInputRequestsWhile
  :: IO Bool
  -> (KindDockerRequest -> IO KindDockerReply)
  -> IO ()
  -> Handle
  -> Handle
  -> IO KindDockerProtocolOutcome
serveKindDockerInputRequestsWhile endpointStable interpret closeGate input output =
  loop `finally` closeGate
 where
  loop = do
    stable <- endpointStable
    if not stable then pure KindDockerProtocolEndpointChanged else readFrame
  readFrame = do
    header <- readExactly input 4
    case header of
      Nothing -> pure KindDockerProtocolPeerClosed
      Just bytes | BS.length bytes /= 4 -> pure KindDockerProtocolMalformed
      Just bytes -> do
        let declared = decodeLength bytes
        if declared == 0 || declared > 110000
          then pure KindDockerProtocolMalformed
          else do
            let size = fromIntegral declared
            body <- readExactly input size
            case body of
              Nothing -> pure KindDockerProtocolMalformed
              Just payload | BS.length payload /= size -> pure KindDockerProtocolMalformed
              Just payload -> do
                parsed <- decodeRequest payload
                case parsed of
                  Nothing -> pure KindDockerProtocolMalformed
                  Just request@(KindDockerRequest argv requestInput)
                    | not (validArguments argv) || BS.length requestInput > 65536 -> pure KindDockerProtocolMalformed
                    | otherwise -> do
                        before <- endpointStable
                        if not before
                          then pure KindDockerProtocolEndpointChanged
                          else do
                            reply <- interpret request
                            after <- endpointStable
                            if not after
                              then pure KindDockerProtocolEndpointChanged
                              else do
                                let encoded = encodeReply reply
                                if BS.length encoded > 131072
                                  then pure KindDockerProtocolMalformed
                                  else do
                                    BS.hPut output (encodeLength (BS.length encoded))
                                    BS.hPut output encoded
                                    hFlush output
                                    if kindDockerReplyExit reply == 0 then loop else pure KindDockerProtocolRejected

decodeRequest :: BS.ByteString -> IO (Maybe KindDockerRequest)
decodeRequest payload = do
  checked <- decodeBoundedYamlValue payload
  pure $ case (Aeson.eitherDecodeStrict' payload, checked) of
    (Right value, Right valid) | value == valid -> either (const Nothing) Just (AesonTypes.parseEither parseRequest value)
    _ -> Nothing
 where
  parseRequest value@(Aeson.Array _)
    | BS.length payload <= 16384 = (`KindDockerRequest` BS.empty) <$> Aeson.parseJSON value
    | otherwise = fail "oversized argument request"
  parseRequest value =
    Aeson.withObject
      "kind Docker request"
      ( \object -> do
          argv <- object Aeson..: "argv"
          encoded <- object Aeson..: "input"
          let wire = BS8.pack encoded
          case Base64.decode wire of
            Right bytes
              | KeyMap.size object == 2
                  && not (BS.null bytes)
                  && BS.length bytes <= 65536
                  && all isAscii encoded
                  && Base64.encode bytes == wire ->
                  pure (KindDockerRequest argv bytes)
            _ -> fail "invalid input request"
      )
      value

-- The pinned kind provider's node request has 38 arguments with the standard
-- mounts and ports. Framing and per-argument limits still bound the payload;
-- transport acceptance does not grant the read gate permission to run it.
validArguments :: [String] -> Bool
validArguments argv =
  not (null argv)
    && length argv <= 64
    && all (\argument -> length argument <= 4096 && '\0' `notElem` argument) argv

readExactly :: Handle -> Int -> IO (Maybe BS.ByteString)
readExactly handle count = go [] 0
 where
  go chunks total
    | total == count = pure (Just (BS.concat (reverse chunks)))
    | otherwise = do
        chunk <- BS.hGetSome handle (count - total)
        if BS.null chunk
          then pure (if total == 0 then Nothing else Just (BS.concat (reverse chunks)))
          else go (chunk : chunks) (total + BS.length chunk)

decodeLength :: BS.ByteString -> Word32
decodeLength = BS.foldl' (\number byte -> (number `shiftL` 8) + fromIntegral byte) (0 :: Word32)

encodeLength :: Int -> BS.ByteString
encodeLength number = BS.pack [part 24, part 16, part 8, part 0]
 where
  value = fromIntegral number :: Word32
  part shift = fromIntegral ((value `shiftR` shift) .&. 255) :: Word8

encodeReply :: KindDockerReply -> BS.ByteString
encodeReply reply =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "exit" Aeson..= kindDockerReplyExit reply
        , "stdout" Aeson..= BS8.unpack (kindDockerReplyStdout reply)
        , "stderr" Aeson..= BS8.unpack (kindDockerReplyStderr reply)
        ]
