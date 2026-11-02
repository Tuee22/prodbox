{-# LANGUAGE ImportQualifiedPost #-}

-- | Wire identifiers, not process ownership or permission to mutate a unit.
module Prodbox.Subprocess.SystemdIdentity
  ( InvocationId
  , invocationIdFromBytes
  , invocationIdBytes
  , InvocationObservation (..)
  , invocationObservationFromBytes
  , InvocationPath
  , invocationPathFromReply
  , invocationPathText
  , invocationPathId
  , HostExecutionKey
  , hostExecutionKeyFromText
  , hostExecutionKeyText
  , HostExecutionWindow
  , hostExecutionWindow
  , hostExecutionOuterEnd
  , hostExecutionWorkEnd
  , hostExecutionHardEnd
  , hostExecutionStopEnd
  , hostExecutionFinishEnd
  , HostControllerKind (..)
  , hostControllerKindEntrypoint
  , hostControllerKindSliceName
  , hostControllerKindPrefix
  , hostControllerUnitName
  , hostControllerSliceName
  , hostControllerRuntimeDirectoryName
  , hostControllerDescription
  , HostManagerDomain
  , hostManagerDomain
  , hostManagerBootId
  , hostManagerBusId
  , hostManagerUniqueName
  , hostManagerUserId
  , hostManagerProcessId
  , hostManagerStartTicks
  , HostBusUniqueName
  , hostBusUniqueName
  , hostBusUniqueNameText
  )
where

import Control.Monad (guard)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.Char (chr, isAsciiLower, isAsciiUpper, isDigit)
import Data.List (isInfixOf, isSuffixOf, stripPrefix)
import Data.Word (Word32, Word64, Word8)

newtype HostBusUniqueName = HostBusUniqueName String
  deriving (Eq, Show)

hostBusUniqueName :: String -> Maybe HostBusUniqueName
hostBusUniqueName name = do
  guard (length (take 256 name) <= 255)
  case name of
    ':' : first : rest -> do
      guard (first /= '.' && not ("." `isSuffixOf` name))
      guard
        ( '.' `elem` (first : rest)
            && all uniqueCharacter (first : rest)
            && not (".." `isInfixOf` (first : rest))
        )
    _ -> Nothing
  pure (HostBusUniqueName name)
 where
  uniqueCharacter c = isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` "_.-"

hostBusUniqueNameText :: HostBusUniqueName -> String
hostBusUniqueNameText (HostBusUniqueName name) = name

-- Bounded provenance data. Parsing it supplies no live observation, process
-- ownership or permission to use a different manager/monotonic-clock domain.
data HostManagerDomain = HostManagerDomain !String !String !String !Word32 !Word32 !Word64
  deriving (Eq, Show)

hostManagerDomain
  :: String -> String -> String -> Word32 -> Word32 -> Word64 -> Maybe HostManagerDomain
hostManagerDomain boot bus name user pid started = do
  guard (length (take 37 boot) == 36)
  guard
    ( and
        [if index `elem` [8, 13, 18, 23] then c == '-' else hex c | (index, c) <- zip [0 :: Int ..] boot]
    )
  guard (any (`notElem` "0-") boot)
  guard (length (take 33 bus) == 32 && all hex bus && any (/= '0') bus)
  _ <- hostBusUniqueName name
  guard (pid > 0 && pid <= 2147483647 && started > 0 && started < maxBound)
  pure (HostManagerDomain boot bus name user pid started)
 where
  hex c = c >= '0' && c <= '9' || c >= 'a' && c <= 'f'

hostManagerBootId, hostManagerBusId, hostManagerUniqueName :: HostManagerDomain -> String
hostManagerBootId (HostManagerDomain value _ _ _ _ _) = value
hostManagerBusId (HostManagerDomain _ value _ _ _ _) = value
hostManagerUniqueName (HostManagerDomain _ _ value _ _ _) = value

hostManagerUserId, hostManagerProcessId :: HostManagerDomain -> Word32
hostManagerUserId (HostManagerDomain _ _ _ value _ _) = value
hostManagerProcessId (HostManagerDomain _ _ _ _ value _) = value

hostManagerStartTicks :: HostManagerDomain -> Word64
hostManagerStartTicks (HostManagerDomain _ _ _ _ _ value) = value

-- A registered caller supplies a recoverable key; it is not generated anew
-- after an uncertain request. This wire value alone grants no admission.
newtype HostExecutionKey = HostExecutionKey String
  deriving (Eq, Show)

hostExecutionKeyFromText :: String -> Maybe HostExecutionKey
hostExecutionKeyFromText value
  | length (take 65 value) == 64
      && all (\c -> c >= '0' && c <= '9' || c >= 'a' && c <= 'f') value =
      Just (HostExecutionKey value)
  | otherwise = Nothing

hostExecutionKeyText :: HostExecutionKey -> String
hostExecutionKeyText (HostExecutionKey value) = value

-- All five clocks are absolute monotonic nanoseconds. A child call borrows
-- this window; it cannot renew the alarm or its cleanup/reader reserves.
data HostExecutionWindow = HostExecutionWindow !Word64 !Word64 !Word64 !Word64 !Word64
  deriving (Eq, Show)

hostExecutionWindow :: Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Maybe HostExecutionWindow
hostExecutionWindow outer work hard stop finish
  | 0 < work && work < hard && hard < stop && stop < finish && finish < outer && outer < maxBound =
      Just (HostExecutionWindow outer work hard stop finish)
  | otherwise = Nothing

hostExecutionOuterEnd
  , hostExecutionWorkEnd
  , hostExecutionHardEnd
  , hostExecutionStopEnd
  , hostExecutionFinishEnd
    :: HostExecutionWindow -> Word64
hostExecutionOuterEnd (HostExecutionWindow value _ _ _ _) = value
hostExecutionWorkEnd (HostExecutionWindow _ value _ _ _) = value
hostExecutionHardEnd (HostExecutionWindow _ _ value _ _) = value
hostExecutionStopEnd (HostExecutionWindow _ _ _ value _) = value
hostExecutionFinishEnd (HostExecutionWindow _ _ _ _ value) = value

-- Closed program identity, not physical placement or Authority admission.
data HostControllerKind = RpcBirthController | OrdinaryCascadeController
  deriving (Eq, Show)

hostControllerKindEntrypoint :: HostControllerKind -> String
hostControllerKindEntrypoint kind = case kind of
  RpcBirthController -> "internal-rpc-birth-controller"
  OrdinaryCascadeController -> "internal-cascade-controller"

hostControllerKindSliceName :: HostControllerKind -> String
hostControllerKindSliceName kind = case kind of
  RpcBirthController -> "prodboxrpcbirth.slice"
  OrdinaryCascadeController -> "prodboxcascade.slice"

hostControllerKindPrefix :: HostControllerKind -> String
hostControllerKindPrefix kind = case kind of
  RpcBirthController -> "prodbox-rpc-birth-"
  OrdinaryCascadeController -> "prodbox-cascade-"

-- The original parent-only controller slot on the retained operator host. The descriptor
-- key and full original window bind its invocation metadata, not its name.
hostControllerUnitName, hostControllerSliceName :: String
hostControllerUnitName = "prodbox-rpc-birth-controller.service"
hostControllerSliceName = hostControllerKindSliceName RpcBirthController

hostControllerRuntimeDirectoryName :: String
hostControllerRuntimeDirectoryName = "prodbox-rpc-birth"

hostControllerDescription :: HostExecutionKey -> HostExecutionWindow -> String
hostControllerDescription key window =
  "prodbox rpc-birth host v1 "
    <> unwords
      ( hostExecutionKeyText key
          : map
            (show . ($ window))
            [ hostExecutionOuterEnd
            , hostExecutionWorkEnd
            , hostExecutionHardEnd
            , hostExecutionStopEnd
            , hostExecutionFinishEnd
            ]
      )

newtype InvocationId = InvocationId ByteString
  deriving (Eq, Show)

-- An inactive or not-yet-started unit can report no assigned invocation.
-- This observation cannot be passed to an invocation-qualified operation.
data InvocationObservation = InvocationAbsent | InvocationPresent !InvocationId
  deriving (Eq, Show)

invocationObservationFromBytes :: ByteString -> Maybe InvocationObservation
invocationObservationFromBytes value
  | Bytes.length value /= 16 = Nothing
  | Bytes.all (== 0) value = Just InvocationAbsent
  | otherwise = InvocationPresent <$> invocationIdFromBytes value

-- No record selectors: identifiers cannot be changed through a record update.
data InvocationPath = InvocationPath !InvocationId !String
  deriving (Eq, Show)

-- | A null ID has systemd's default-caller meaning, never exact identity.
invocationIdFromBytes :: ByteString -> Maybe InvocationId
invocationIdFromBytes value
  | Bytes.length value == 16 && Bytes.any (/= 0) value = Just (InvocationId value)
  | otherwise = Nothing

invocationIdBytes :: InvocationId -> ByteString
invocationIdBytes (InvocationId value) = value

-- | Keep the actual returned alias, including systemd's label escaping. A
-- canonical name path cannot stand in for an invocation-qualified route.
invocationPathFromReply :: InvocationId -> String -> Maybe InvocationPath
invocationPathFromReply expected path = do
  label <- stripPrefix "/org/freedesktop/systemd1/unit/" path
  guard (null (drop 96 label))
  decoded <- unescape label
  guard (length decoded == 32)
  actual <- decodeHex decoded >>= invocationIdFromBytes . Bytes.pack
  if actual == expected then Just (InvocationPath expected path) else Nothing

invocationPathText :: InvocationPath -> String
invocationPathText (InvocationPath _ path) = path

invocationPathId :: InvocationPath -> InvocationId
invocationPathId (InvocationPath identifier _) = identifier

unescape :: String -> Maybe String
unescape input = case input of
  [] -> Just []
  '_' : high : low : rest -> do
    byte <- hexByte high low
    (chr (fromIntegral byte) :) <$> unescape rest
  '_' : _ -> Nothing
  character : rest
    | asciiHex character -> (character :) <$> unescape rest
    | otherwise -> Nothing

decodeHex :: String -> Maybe [Word8]
decodeHex input = case input of
  [] -> Just []
  high : low : rest -> (:) <$> hexByte high low <*> decodeHex rest
  [_] -> Nothing

hexByte :: Char -> Char -> Maybe Word8
hexByte high low = do
  upper <- nibble high
  lower <- nibble low
  pure (upper * 16 + lower)

nibble :: Char -> Maybe Word8
nibble value
  | value >= '0' && value <= '9' = Just (fromIntegral (fromEnum value - fromEnum '0'))
  | value >= 'a' && value <= 'f' = Just (fromIntegral (fromEnum value - fromEnum 'a' + 10))
  | value >= 'A' && value <= 'F' = Just (fromIntegral (fromEnum value - fromEnum 'A' + 10))
  | otherwise = Nothing

asciiHex :: Char -> Bool
asciiHex value = case nibble value of
  Just _ -> True
  Nothing -> False
