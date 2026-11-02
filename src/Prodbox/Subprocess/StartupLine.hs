{-# LANGUAGE ImportQualifiedPost #-}

-- | A bounded first-line protocol. The reader publishes only its status;
-- child bytes and partial lines never become a startup receipt.
module Prodbox.Subprocess.StartupLine
  ( StartupLineExpectation
  , StartupLineError (..)
  , StartupLineStatus (..)
  , StartupLineMatcher
  , mkStartupLineExpectation
  , startupLineReserveBytes
  , startupLineMaximumLength
  , beginStartupLine
  , feedStartupLineByte
  , startupLineStatus
  , finishStartupLine
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Maybe (isJust)
import Data.Word (Word8)

data StartupLineExpectation = StartupLineExpectation !ByteString !(Maybe ByteString)

data StartupLineError
  = StartupLinePatternCountInvalid
  | StartupLinePatternInvalid
  | StartupLinePatternTooLong
  | StartupLinePatternDuplicate
  deriving (Eq, Show)

data StartupLineStatus
  = StartupLineUnconfigured
  | StartupLinePending
  | StartupLineAccepted
  | StartupLineRejected
  | StartupLineIncomplete
  | StartupLineReadFailed
  | StartupLineExceeded
  deriving (Eq, Show)

data StartupLineMatcher
  = MatchingStartupLine !StartupLineExpectation !Int !Bool !Bool
  | AcceptedStartupLine
  | RejectedStartupLine

-- Expected bytes, matcher and publication state are funded in the transport
-- half of the existing other-heap reserve before the child can be launched.
startupLineReserveBytes :: Integer
startupLineReserveBytes = 4096

mkStartupLineExpectation :: [ByteString] -> Either StartupLineError StartupLineExpectation
mkStartupLineExpectation patterns = case patterns of
  [first] -> validate first >> pure (StartupLineExpectation first Nothing)
  [first, second] -> do
    validate first
    validate second
    if first == second
      then Left StartupLinePatternDuplicate
      else pure (StartupLineExpectation first (Just second))
  _ -> Left StartupLinePatternCountInvalid
 where
  validate bytes
    | BS.length bytes > 256 = Left StartupLinePatternTooLong
    | BS.null bytes || BS.any (\byte -> byte < 32 || byte > 126) bytes =
        Left StartupLinePatternInvalid
    | otherwise = Right ()

startupLineMaximumLength :: StartupLineExpectation -> Int
startupLineMaximumLength (StartupLineExpectation first second) =
  max (BS.length first) (maybe 0 BS.length second)

beginStartupLine :: StartupLineExpectation -> StartupLineMatcher
beginStartupLine expected@(StartupLineExpectation _ second) =
  MatchingStartupLine expected 0 True (isJust second)

feedStartupLineByte :: StartupLineMatcher -> Word8 -> StartupLineMatcher
feedStartupLineByte matcher byte = case matcher of
  AcceptedStartupLine -> AcceptedStartupLine
  RejectedStartupLine -> RejectedStartupLine
  MatchingStartupLine expected@(StartupLineExpectation first second) position firstLive secondLive
    | byte == 10 ->
        if firstLive && position == BS.length first
          || secondLive && maybe False ((== position) . BS.length) second
          then AcceptedStartupLine
          else RejectedStartupLine
    | otherwise ->
        let firstMatches = firstLive && matches first
            secondMatches = secondLive && maybe False matches second
         in if firstMatches || secondMatches
              then MatchingStartupLine expected (position + 1) firstMatches secondMatches
              else RejectedStartupLine
   where
    matches bytes = position < BS.length bytes && BS.index bytes position == byte

startupLineStatus :: StartupLineMatcher -> StartupLineStatus
startupLineStatus matcher = case matcher of
  MatchingStartupLine {} -> StartupLinePending
  AcceptedStartupLine -> StartupLineAccepted
  RejectedStartupLine -> StartupLineRejected

finishStartupLine :: StartupLineMatcher -> StartupLineStatus
finishStartupLine matcher = case matcher of
  MatchingStartupLine {} -> StartupLineIncomplete
  AcceptedStartupLine -> StartupLineAccepted
  RejectedStartupLine -> StartupLineRejected
