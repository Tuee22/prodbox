{-# LANGUAGE OverloadedStrings #-}

-- | Canonical public producer provenance. Decoding this data never grants a
-- native publication fence, submission lease or retirement capability.
module Prodbox.Subprocess.HostControllerPublicationRecord
  ( PublicationBirth
  , PublicationBirthDraft
  , preparePublicationBirth
  , capturePublicationBirth
  , encodePublicationBirth
  , decodePublicationBirth
  , publicationBirthKey
  , publicationBirthKind
  , publicationBirthWorkEnd
  , publicationBirthParentMatches
  , publicationBirthFileMatches
  , publicationBirthIdentityMatches
  , publicationBirthNeverSentBytes
  , publicationBirthPossibleSendBytes
  , publicationBirthName
  , publicationPossibleSendName
  ) where

import Codec.Serialise (deserialiseOrFail, serialise)
import Control.Monad (unless)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.Word (Word64, Word8)
import Prodbox.Config.SerialiseString (SerialiseString (..))
import Prodbox.Subprocess.HostControllerInputs qualified as Inputs
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileGroup
  , fileID
  , fileMode
  , fileOwner
  , fileSize
  , isRegularFile
  , linkCount
  )

type BirthIdentity = (Integer, Integer, Integer, Integer, Integer)

data PublicationBirthDraft
  = PublicationBirthDraft
      !Identity.HostControllerKind
      !Identity.HostExecutionKey
      !Word64
      !Inputs.HostControllerAnonymousPayloads
      !Integer
      !Integer

data PublicationBirth
  = PublicationBirth
      !Identity.HostControllerKind
      !Identity.HostExecutionKey
      !Word64
      !Inputs.HostControllerAnonymousPayloads
      !BirthIdentity

publicationBirthName, publicationPossibleSendName :: String
publicationBirthName = "publication-birth.cbor"
publicationPossibleSendName = "publication-possible-send.cbor"

birthPrefix :: ByteString
birthPrefix = "prodbox-host-controller-publication/birth/v2\NUL"

preparePublicationBirth
  :: Identity.HostControllerKind
  -> Identity.HostExecutionKey
  -> Word64
  -> FileStatus
  -> FileStatus
  -> FileStatus
  -> Maybe PublicationBirthDraft
preparePublicationBirth kind key ending parent configuration request = do
  unless (ending > 0) Nothing
  observed <- Inputs.captureHostControllerAnonymousPayloads parent configuration request
  pure
    ( PublicationBirthDraft
        kind
        key
        ending
        observed
        (toInteger (deviceID parent))
        (toInteger (fileOwner parent))
    )

capturePublicationBirth :: PublicationBirthDraft -> FileStatus -> Maybe PublicationBirth
capturePublicationBirth (PublicationBirthDraft kind key ending observed dev uid) status = do
  unless
    ( isRegularFile status
        && fileMode status .&. 0o7777 == 0o400
        && linkCount status == 0
        && fileSize status == 0
        && toInteger (deviceID status) == dev
        && toInteger (fileOwner status) == uid
    )
    Nothing
  pure (PublicationBirth kind key ending observed (birthIdentity status))

birthIdentity :: FileStatus -> BirthIdentity
birthIdentity status =
  ( toInteger (deviceID status)
  , toInteger (fileID status)
  , toInteger (fileOwner status)
  , toInteger (fileGroup status)
  , toInteger (fileMode status)
  )

encodePublicationBirth :: PublicationBirth -> ByteString
encodePublicationBirth (PublicationBirth kind key ending observed identity) = case kind of
  Identity.RpcBirthController -> legacy
  Identity.OrdinaryCascadeController ->
    kindPrefix <> Lazy.toStrict (serialise (1 :: Word8, 1 :: Word8, legacy))
 where
  legacy =
    birthPrefix
      <> Lazy.toStrict
        ( serialise
            ( 2 :: Word8
            , SerialiseString (Identity.hostExecutionKeyText key)
            , ending
            , Inputs.encodeHostControllerAnonymousPayloads observed
            , identity
            )
        )

decodePublicationBirth :: ByteString -> Maybe PublicationBirth
decodePublicationBirth bytes = do
  unless (BS.length bytes <= 8192) Nothing
  case BS.stripPrefix kindPrefix bytes of
    Nothing -> decodeRegistrationBirth bytes
    Just payload -> do
      (version, kind, original) <-
        either (const Nothing) Just (deserialiseOrFail (Lazy.fromStrict payload))
      unless
        (version == (1 :: Word8) && kind == (1 :: Word8) && birthPrefix `BS.isPrefixOf` original)
        Nothing
      PublicationBirth _ key ending observed identity <- decodeRegistrationBirth original
      let birth = PublicationBirth Identity.OrdinaryCascadeController key ending observed identity
      unless (encodePublicationBirth birth == bytes) Nothing
      pure birth

kindPrefix :: ByteString
kindPrefix = "prodbox-host-controller-publication/birth/kind/v1\NUL"

decodeRegistrationBirth :: ByteString -> Maybe PublicationBirth
decodeRegistrationBirth bytes = do
  unless (BS.length bytes <= 8192) Nothing
  payload <- BS.stripPrefix birthPrefix bytes
  (version, SerialiseString keyText, ending, encoded, identity@(dev, ino, uid, group, mode)) <-
    either (const Nothing) Just (deserialiseOrFail (Lazy.fromStrict payload))
  unless (version == (2 :: Word8) && ending > 0) Nothing
  key <- Identity.hostExecutionKeyFromText keyText
  observed <- Inputs.decodeHostControllerAnonymousPayloads encoded
  unless (dev >= 0 && ino > 0 && uid >= 0 && group >= 0 && mode == 0o100400) Nothing
  let birth = PublicationBirth Identity.RpcBirthController key ending observed identity
  unless (encodePublicationBirth birth == bytes) Nothing
  pure birth

publicationBirthKey :: PublicationBirth -> Identity.HostExecutionKey
publicationBirthKey (PublicationBirth _ key _ _ _) = key

publicationBirthKind :: PublicationBirth -> Identity.HostControllerKind
publicationBirthKind (PublicationBirth kind _ _ _ _) = kind

publicationBirthWorkEnd :: PublicationBirth -> Word64
publicationBirthWorkEnd (PublicationBirth _ _ ending _ _) = ending

publicationBirthParentMatches :: PublicationBirth -> FileStatus -> Bool
publicationBirthParentMatches (PublicationBirth _ _ _ observed _) = Inputs.hostControllerAnonymousParentMatches observed

publicationBirthFileMatches
  :: PublicationBirth -> Inputs.HostControllerInputRole -> FileStatus -> Bool
publicationBirthFileMatches (PublicationBirth _ _ _ observed _) = Inputs.hostControllerAnonymousFileMatches observed

publicationBirthIdentityMatches :: PublicationBirth -> FileStatus -> Bool
publicationBirthIdentityMatches (PublicationBirth _ _ _ _ expected) status =
  isRegularFile status && linkCount status == 1 && birthIdentity status == expected

publicationBirthNeverSentBytes :: PublicationBirth -> ByteString
publicationBirthNeverSentBytes = ("prodbox-host-never-sent-inputs/v2\NUL" <>) . encodePublicationBirth

publicationBirthPossibleSendBytes :: PublicationBirth -> ByteString
publicationBirthPossibleSendBytes = ("prodbox-host-possible-send/v2\NUL" <>) . encodePublicationBirth
