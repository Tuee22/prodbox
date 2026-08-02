{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 4.50: the fsync-ordered durable barrier for the decommission receipt —
-- the only new effectful primitive of the protocol.
--
-- 'appendReceiptFrame' writes one length-delimited frame record, fsyncs the file,
-- then fsyncs the parent directory, so a committed frame (and, on first creation,
-- the directory entry) is durable before the runner performs the external effect
-- the frame authorises. 'reopenReceipt' reads the receipt, computes the pure
-- longest-valid-prefix recovery ('Prodbox.Lifecycle.Decommission.Journal'), and —
-- only for a torn final record — truncates the file back to the last valid frame
-- and fsyncs, so resumption appends cleanly after the recovered prefix. A fully
-- written but corrupt frame, a chain break, or a manifest mismatch is returned
-- as a refusal and the file is left untouched: committed history is never
-- silently rewritten.
module Prodbox.Lifecycle.Decommission.Receipt
  ( ReceiptHeader
  , receiptHeaderManifestDigest
  , receiptHeaderPlanDigest
  , receiptHeaderSignatureDigest
  , receiptHeaderSignerDigest
  , receiptHeaderVerifierBinding
  , mkReceiptHeader
  , ReceiptHeaderCodecError (..)
  , encodeReceiptHeader
  , decodeReceiptHeader
  , BoundReceiptInitialize (..)
  , BoundReceiptRefusal (..)
  , ReceiptHeaderMismatch (..)
  , BoundReceiptReopen (..)
  , initializeBoundReceipt
  , reopenBoundReceipt
  , ExternalReceiptPrepareRefusal (..)
  , PendingExternalReceipt
  , pendingExternalReceiptPath
  , receiptAcknowledgementLiteral
  , receiptAcknowledgementDigest
  , prepareExternalReceiptAcknowledgement
  , ExternalReceiptAcknowledgementError (..)
  , AcknowledgedExternalReceipt
  , acknowledgeExternalReceipt
  , acknowledgedExternalReceiptPath
  , acknowledgedExternalReceiptHeader
  , BoundReceiptAppendError (..)
  , appendBoundReceiptFrame
  , ReceiptReopen (..)
  , appendReceiptFrame
  , reopenReceipt
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Exception (IOException, bracket, try)
import Control.Monad (void)
import Data.Bits (shiftL, shiftR, (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Word (Word32, Word8)
import GHC.Generics (Generic)
import Numeric (showHex)
import Prodbox.Lifecycle.Decommission.Frame
  ( DecommissionFrame
  , FrameDigest (FrameDigest)
  , contentDigest
  , frameDigest
  , frameIndex
  , frameManifestDigest
  , framePreviousDigest
  , genesisPreviousDigest
  )
import Prodbox.Lifecycle.Decommission.Journal
  ( JournalRecoveryError
  , ReceiptRecovery (recoveredFrames, recoveredValidBytes, recoveryOutcome)
  , RecoveryOutcome (RecoveryComplete, RecoveryRefused, RecoveryTruncatableTorn)
  , encodeRecord
  , recoverReceipt
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( VerifiedDecommissionManifest
  , decommissionManifestDigest
  , manifestPublicKeyDigest
  , signedManifestPublicKey
  , signedManifestSignatureDigest
  , verifiedManifestDigest
  , verifiedManifestPlan
  , verifiedSignedManifest
  , verifiedVerifierBinding
  )
import Prodbox.Lifecycle.Decommission.Verifier
  ( ExternalReceiptPath
  , HostValidatedExternalDurablePaths
  , VerifierBinding
  , VerifierBindingError
  , boundArtifactDigest
  , boundArtifactPath
  , boundMetadata
  , externalReceiptPath
  , hostValidatedArtifactPath
  , hostValidatedReceiptPath
  , validateVerifierBinding
  , verifierDependencyDigest
  , verifierInterpreterRegistryDigest
  , verifierInterpreterRegistryVersion
  , verifierManifestSchemaDigest
  , verifierManifestSchemaVersion
  )
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory)
import System.IO.Error (isEOFError)
import System.Posix.Files
  ( fileSize
  , getFdStatus
  , isRegularFile
  , ownerReadMode
  , ownerWriteMode
  , setFdSize
  , unionFileModes
  )
import System.Posix.IO
  ( OpenFileFlags (..)
  , OpenMode (ReadOnly, WriteOnly)
  , closeFd
  , defaultFileFlags
  , openFd
  )
import System.Posix.IO.ByteString qualified as PosixBS
import System.Posix.Types (Fd, FileMode)
import System.Posix.Unistd (fileSynchronise)

currentReceiptHeaderVersion :: Word
currentReceiptHeaderVersion = 1

maximumReceiptHeaderBytes :: Int
maximumReceiptHeaderBytes = 64 * 1024

maximumBoundReceiptBytes :: Integer
maximumBoundReceiptBytes = 256 * 1024 * 1024

receiptHeaderMagic :: ByteString
receiptHeaderMagic = "prodbox-decommission-receipt-v1\NUL"

-- | Public, authenticated receipt identity.  It contains only digests, versions,
-- and the exact public verifier binding; the Authority private key and all admin
-- credentials are structurally absent.
data ReceiptHeader = ReceiptHeader
  { receiptHeaderVersion :: !Word
  , receiptHeaderManifestDigest :: !FrameDigest
  , receiptHeaderPlanDigest :: !FrameDigest
  , receiptHeaderSignatureDigest :: !FrameDigest
  , receiptHeaderSignerDigest :: !FrameDigest
  , receiptHeaderVerifierBinding :: !VerifierBinding
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkReceiptHeader :: VerifiedDecommissionManifest -> ReceiptHeader
mkReceiptHeader verified =
  let signed = verifiedSignedManifest verified
   in ReceiptHeader
        { receiptHeaderVersion = currentReceiptHeaderVersion
        , receiptHeaderManifestDigest = verifiedManifestDigest verified
        , receiptHeaderPlanDigest = decommissionManifestDigest (verifiedManifestPlan verified)
        , receiptHeaderSignatureDigest = signedManifestSignatureDigest signed
        , receiptHeaderSignerDigest = manifestPublicKeyDigest (signedManifestPublicKey signed)
        , receiptHeaderVerifierBinding = verifiedVerifierBinding verified
        }

data ReceiptHeaderCodecError
  = ReceiptHeaderTooLarge
  | ReceiptHeaderInvalid
  | ReceiptHeaderUnsupportedVersion
  | ReceiptHeaderNonCanonical
  | ReceiptHeaderDigestInvalid
  | ReceiptHeaderVerifierBindingInvalid !VerifierBindingError
  deriving stock (Eq, Show)

encodeReceiptHeader :: ReceiptHeader -> ByteString
encodeReceiptHeader = LazyByteString.toStrict . serialise

decodeReceiptHeader :: Int -> ByteString -> Either ReceiptHeaderCodecError ReceiptHeader
decodeReceiptHeader maximumBytes bytes
  | maximumBytes < 0 || ByteString.length bytes > maximumBytes = Left ReceiptHeaderTooLarge
  | otherwise = case deserialiseOrFail (LazyByteString.fromStrict bytes) of
      Left _ -> Left ReceiptHeaderInvalid
      Right header
        | receiptHeaderVersion header /= currentReceiptHeaderVersion ->
            Left ReceiptHeaderUnsupportedVersion
        | encodeReceiptHeader header /= bytes -> Left ReceiptHeaderNonCanonical
        | not (all validHeaderDigest (headerDigests header)) -> Left ReceiptHeaderDigestInvalid
        | otherwise ->
            case validateVerifierBinding (receiptHeaderVerifierBinding header) of
              Left err -> Left (ReceiptHeaderVerifierBindingInvalid err)
              Right binding -> Right header {receiptHeaderVerifierBinding = binding}

headerDigests :: ReceiptHeader -> [FrameDigest]
headerDigests header =
  [ receiptHeaderManifestDigest header
  , receiptHeaderPlanDigest header
  , receiptHeaderSignatureDigest header
  , receiptHeaderSignerDigest header
  ]

validHeaderDigest :: FrameDigest -> Bool
validHeaderDigest (FrameDigest bytes) = ByteString.length bytes == 32

data BoundReceiptInitialize
  = BoundReceiptCreated
  | BoundReceiptAlreadyInitialized
  deriving stock (Eq, Show)

data ReceiptHeaderMismatch
  = ReceiptManifestDigestMismatch
  | ReceiptPlanDigestMismatch
  | ReceiptManifestSignatureMismatch
  | ReceiptManifestSignerMismatch
  | ReceiptArtifactPathMismatch
  | ReceiptArtifactDigestMismatch
  | ReceiptDependencyIdentityMismatch
  | ReceiptManifestSchemaIdentityMismatch
  | ReceiptInterpreterRegistryIdentityMismatch
  deriving stock (Eq, Show)

data BoundReceiptRefusal
  = BoundReceiptAbsent
  | BoundReceiptHeaderTorn
  | BoundReceiptHeaderCodecRefused !ReceiptHeaderCodecError
  | BoundReceiptHeaderDrift !ReceiptHeaderMismatch
  | BoundReceiptJournalRefused !JournalRecoveryError
  | BoundReceiptOversized
  | BoundReceiptNotRegular
  | BoundReceiptIoFailure !String
  deriving stock (Eq, Show)

data BoundReceiptReopen payload = BoundReceiptReopen
  { boundReopenHeader :: !ReceiptHeader
  , boundReopenFrames :: ![DecommissionFrame payload]
  , boundReopenOutcome :: !RecoveryOutcome
  , boundReopenTruncatedTo :: !(Maybe Int)
  }
  deriving stock (Eq, Show)

data BoundReceiptAppendError
  = BoundAppendReopenRefused !BoundReceiptRefusal
  | BoundAppendManifestMismatch
  | BoundAppendSequenceMismatch
  | BoundAppendIoFailure !String
  | BoundAppendReadBackMismatch
  deriving stock (Eq, Show)

data ExternalReceiptPrepareRefusal
  = ExternalReceiptArtifactBindingMismatch
  | ExternalReceiptInitializeRefused !BoundReceiptRefusal
  deriving stock (Eq, Show)

-- | A freshly created or exactly reopened receipt awaiting a human/harness
-- acknowledgement.  The constructor is private: the token is available only
-- after the authenticated header has been durably initialized and read back.
data PendingExternalReceipt = PendingExternalReceipt
  { pendingExternalReceiptPath :: !ExternalReceiptPath
  , pendingExternalReceiptHeader :: !ReceiptHeader
  }
  deriving stock (Eq, Show)

data ExternalReceiptAcknowledgementError
  = ExternalReceiptAcknowledgementMismatch
  deriving stock (Eq, Show)

-- | Capability consumed by the bound runner.  A bare path cannot cross the
-- point of no return.
data AcknowledgedExternalReceipt = AcknowledgedExternalReceipt
  { acknowledgedExternalReceiptPath :: !ExternalReceiptPath
  , acknowledgedExternalReceiptHeader :: !ReceiptHeader
  }
  deriving stock (Eq, Show)

-- | Initialize/read back the header at an already-proven external path.  The
-- artifact used in the path proof must be the exact artifact in the signed
-- manifest, otherwise the receipt is not prepared.
prepareExternalReceiptAcknowledgement
  :: HostValidatedExternalDurablePaths
  -> VerifiedDecommissionManifest
  -> IO (Either ExternalReceiptPrepareRefusal PendingExternalReceipt)
prepareExternalReceiptAcknowledgement paths verified
  | hostValidatedArtifactPath paths /= boundArtifactPath (verifiedVerifierBinding verified) =
      pure (Left ExternalReceiptArtifactBindingMismatch)
  | otherwise = do
      initialized <- initializeBoundReceipt receiptPath verified
      pure $ case initialized of
        Left refusal -> Left (ExternalReceiptInitializeRefused refusal)
        Right _ ->
          Right
            PendingExternalReceipt
              { pendingExternalReceiptPath = hostValidatedReceiptPath paths
              , pendingExternalReceiptHeader = mkReceiptHeader verified
              }
 where
  receiptPath = externalReceiptPath (hostValidatedReceiptPath paths)

-- | Exact typed acknowledgement text.  It binds both the authenticated header
-- and the canonical external receipt path so acknowledging another run or file
-- cannot authorize this one.
receiptAcknowledgementLiteral :: PendingExternalReceipt -> Text
receiptAcknowledgementLiteral pending =
  "ACK DECOMMISSION RECEIPT " <> digestHex acknowledgementDigest
 where
  acknowledgementDigest =
    receiptAcknowledgementDigest
      (pendingExternalReceiptHeader pending)
      (pendingExternalReceiptPath pending)

-- | Stable point-of-no-return identity.  It binds the authenticated header to
-- the exact canonical external path without retaining the acknowledgement
-- literal itself in Authority state.
receiptAcknowledgementDigest :: ReceiptHeader -> ExternalReceiptPath -> FrameDigest
receiptAcknowledgementDigest header path =
  contentDigest
    ( encodeReceiptHeader header
        <> Text.encodeUtf8 (Text.pack (externalReceiptPath path))
    )

acknowledgeExternalReceipt
  :: Text
  -> PendingExternalReceipt
  -> Either ExternalReceiptAcknowledgementError AcknowledgedExternalReceipt
acknowledgeExternalReceipt supplied pending
  | supplied /= receiptAcknowledgementLiteral pending =
      Left ExternalReceiptAcknowledgementMismatch
  | otherwise =
      Right
        AcknowledgedExternalReceipt
          { acknowledgedExternalReceiptPath = pendingExternalReceiptPath pending
          , acknowledgedExternalReceiptHeader = pendingExternalReceiptHeader pending
          }

digestHex :: FrameDigest -> Text
digestHex (FrameDigest bytes) = Text.pack (concatMap byteHex (ByteString.unpack bytes))
 where
  byteHex byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

-- | The result of reopening a receipt file: the recovered valid prefix, its
-- recovery classification, and — when a torn tail was truncated — the byte length
-- the file was truncated to.
data ReceiptReopen payload = ReceiptReopen
  { reopenFrames :: ![DecommissionFrame payload]
  , reopenOutcome :: !RecoveryOutcome
  , reopenTruncatedTo :: !(Maybe Int)
  }
  deriving stock (Eq, Show)

receiptFileMode :: FileMode
receiptFileMode = ownerReadMode `unionFileModes` ownerWriteMode

-- | Create the point-of-no-return receipt with its authenticated header as the
-- first durable bytes. Repeating initialization is idempotent only for the exact
-- same header; any complete drift refuses without truncation.
initializeBoundReceipt
  :: FilePath
  -> VerifiedDecommissionManifest
  -> IO (Either BoundReceiptRefusal BoundReceiptInitialize)
initializeBoundReceipt path verified = do
  exists <- doesFileExist path
  if exists
    then do
      current <- readBoundReceiptBytes path
      pure $ do
        bytes <- current
        (header, _, _) <- splitBoundReceipt bytes
        validateExpectedHeader (mkReceiptHeader verified) header
        Right BoundReceiptAlreadyInitialized
    else do
      let bytes = encodeHeaderPrefix (mkReceiptHeader verified)
      written <- try (writeNewAndSync path bytes)
      case written :: Either IOException () of
        Left err -> pure (Left (BoundReceiptIoFailure (show err)))
        Right () -> do
          readBack <- readBoundReceiptBytes path
          pure $ do
            actualBytes <- readBack
            if actualBytes == bytes
              then Right BoundReceiptCreated
              else Left (BoundReceiptIoFailure "receipt header read-back mismatch")

-- | Reopen and authenticate the header before the structural journal parser is
-- allowed to see a frame. A torn final frame is truncated relative to the header
-- prefix and both file and directory are fsynced; a header defect is never
-- truncatable.
reopenBoundReceipt
  :: (Serialise payload)
  => Int
  -> VerifiedDecommissionManifest
  -> FilePath
  -> IO (Either BoundReceiptRefusal (BoundReceiptReopen payload))
reopenBoundReceipt maximumFrameBytes verified path = do
  exists <- doesFileExist path
  if not exists
    then pure (Left BoundReceiptAbsent)
    else do
      bytesResult <- readBoundReceiptBytes path
      case bytesResult of
        Left err -> pure (Left err)
        Right bytes -> case splitBoundReceipt bytes of
          Left err -> pure (Left err)
          Right (header, journalOffset, journalBytes) ->
            case validateExpectedHeader (mkReceiptHeader verified) header of
              Left err -> pure (Left err)
              Right () -> do
                let recovery =
                      recoverReceipt maximumFrameBytes (verifiedManifestDigest verified) journalBytes
                case recoveryOutcome recovery of
                  RecoveryRefused err -> pure (Left (BoundReceiptJournalRefused err))
                  RecoveryTruncatableTorn -> do
                    let absoluteBytes = journalOffset + recoveredValidBytes recovery
                    truncateToValidPrefix path absoluteBytes
                    syncDirectory (takeDirectory path)
                    pure
                      ( Right
                          BoundReceiptReopen
                            { boundReopenHeader = header
                            , boundReopenFrames = recoveredFrames recovery
                            , boundReopenOutcome = RecoveryTruncatableTorn
                            , boundReopenTruncatedTo = Just absoluteBytes
                            }
                      )
                  RecoveryComplete ->
                    pure
                      ( Right
                          BoundReceiptReopen
                            { boundReopenHeader = header
                            , boundReopenFrames = recoveredFrames recovery
                            , boundReopenOutcome = RecoveryComplete
                            , boundReopenTruncatedTo = Nothing
                            }
                      )

-- | Append only after reopening and validating the header plus complete chain;
-- then reopen again and require the appended terminal digest.  This is the
-- high-level append primitive the Nuke composition must use.
appendBoundReceiptFrame
  :: forall payload
   . (Serialise payload)
  => Int
  -> VerifiedDecommissionManifest
  -> FilePath
  -> DecommissionFrame payload
  -> IO (Either BoundReceiptAppendError FrameDigest)
appendBoundReceiptFrame maximumFrameBytes verified path frame = do
  beforeResult <- reopenBoundReceipt maximumFrameBytes verified path
  case beforeResult of
    Left err -> pure (Left (BoundAppendReopenRefused err))
    Right before
      | frameManifestDigest frame /= verifiedManifestDigest verified ->
          pure (Left BoundAppendManifestMismatch)
      | not (nextFrameMatches (verifiedManifestDigest verified) (boundReopenFrames before) frame) ->
          pure (Left BoundAppendSequenceMismatch)
      | otherwise -> do
          appended <- try (appendReceiptFrame path frame)
          case appended :: Either IOException () of
            Left err -> pure (Left (BoundAppendIoFailure (show err)))
            Right () -> do
              afterResult <-
                reopenBoundReceipt maximumFrameBytes verified path
                  :: IO (Either BoundReceiptRefusal (BoundReceiptReopen payload))
              pure $ case afterResult of
                Left err -> Left (BoundAppendReopenRefused err)
                Right after
                  | length (boundReopenFrames after) /= length (boundReopenFrames before) + 1 ->
                      Left BoundAppendReadBackMismatch
                  | maybe False ((== frameDigest frame) . frameDigest) (lastMaybe (boundReopenFrames after)) ->
                      Right (frameDigest frame)
                  | otherwise -> Left BoundAppendReadBackMismatch

nextFrameMatches
  :: (Serialise payload)
  => FrameDigest
  -> [DecommissionFrame payload]
  -> DecommissionFrame payload
  -> Bool
nextFrameMatches manifest frames frame =
  frameIndex frame == maybe 0 ((+ 1) . frameIndex) previous
    && framePreviousDigest frame == maybe (genesisPreviousDigest manifest) frameDigest previous
 where
  previous = lastMaybe frames

lastMaybe :: [value] -> Maybe value
lastMaybe [] = Nothing
lastMaybe values = Just (last values)

readBoundReceiptBytes :: FilePath -> IO (Either BoundReceiptRefusal ByteString)
readBoundReceiptBytes path = do
  result <-
    try
      ( bracket
          (openFd path ReadOnly defaultFileFlags {nofollow = True, cloexec = True})
          safeCloseFd
          readOpenBoundReceipt
      )
  pure $ case result :: Either IOException (Either BoundReceiptRefusal ByteString) of
    Left err -> Left (BoundReceiptIoFailure (show err))
    Right readResult -> readResult

readOpenBoundReceipt :: Fd -> IO (Either BoundReceiptRefusal ByteString)
readOpenBoundReceipt fd = do
  status <- getFdStatus fd
  if not (isRegularFile status)
    then pure (Left BoundReceiptNotRegular)
    else
      if fromIntegral (fileSize status) > maximumBoundReceiptBytes
        then pure (Left BoundReceiptOversized)
        else do
          content <- readBoundReceiptChunks fd 0 []
          pure (maybe (Left BoundReceiptOversized) Right content)

readBoundReceiptChunks :: Fd -> Integer -> [ByteString] -> IO (Maybe ByteString)
readBoundReceiptChunks fd observed chunks = do
  let remaining = maximumBoundReceiptBytes - observed
      requestBytes = min 65536 (remaining + 1)
  readResult <- try (PosixBS.fdRead fd (fromIntegral requestBytes))
  case readResult :: Either IOException ByteString of
    Left err
      | isEOFError err -> pure (Just (ByteString.concat (reverse chunks)))
      | otherwise -> ioError err
    Right chunk
      | ByteString.null chunk -> pure (Just (ByteString.concat (reverse chunks)))
      | otherwise -> do
          let chunkBytes = fromIntegral (ByteString.length chunk)
          if chunkBytes > remaining
            then pure Nothing
            else readBoundReceiptChunks fd (observed + chunkBytes) (chunk : chunks)

validateExpectedHeader
  :: ReceiptHeader
  -> ReceiptHeader
  -> Either BoundReceiptRefusal ()
validateExpectedHeader expected actual =
  case headerMismatch expected actual of
    Nothing -> Right ()
    Just mismatch -> Left (BoundReceiptHeaderDrift mismatch)

headerMismatch :: ReceiptHeader -> ReceiptHeader -> Maybe ReceiptHeaderMismatch
headerMismatch expected actual
  | receiptHeaderPlanDigest actual /= receiptHeaderPlanDigest expected =
      Just ReceiptPlanDigestMismatch
  | receiptHeaderSignerDigest actual /= receiptHeaderSignerDigest expected =
      Just ReceiptManifestSignerMismatch
  | boundArtifactPath actualBinding /= boundArtifactPath expectedBinding =
      Just ReceiptArtifactPathMismatch
  | boundArtifactDigest actualBinding /= boundArtifactDigest expectedBinding =
      Just ReceiptArtifactDigestMismatch
  | verifierDependencyDigest actualMetadata /= verifierDependencyDigest expectedMetadata =
      Just ReceiptDependencyIdentityMismatch
  | verifierManifestSchemaVersion actualMetadata /= verifierManifestSchemaVersion expectedMetadata
      || verifierManifestSchemaDigest actualMetadata /= verifierManifestSchemaDigest expectedMetadata =
      Just ReceiptManifestSchemaIdentityMismatch
  | verifierInterpreterRegistryVersion actualMetadata
      /= verifierInterpreterRegistryVersion expectedMetadata
      || verifierInterpreterRegistryDigest actualMetadata
        /= verifierInterpreterRegistryDigest expectedMetadata =
      Just ReceiptInterpreterRegistryIdentityMismatch
  | receiptHeaderSignatureDigest actual /= receiptHeaderSignatureDigest expected =
      Just ReceiptManifestSignatureMismatch
  | receiptHeaderManifestDigest actual /= receiptHeaderManifestDigest expected =
      Just ReceiptManifestDigestMismatch
  | otherwise = Nothing
 where
  actualBinding = receiptHeaderVerifierBinding actual
  expectedBinding = receiptHeaderVerifierBinding expected
  actualMetadata = boundMetadata actualBinding
  expectedMetadata = boundMetadata expectedBinding

encodeHeaderPrefix :: ReceiptHeader -> ByteString
encodeHeaderPrefix header =
  receiptHeaderMagic <> word32ToBE (fromIntegral (ByteString.length bytes)) <> bytes
 where
  bytes = encodeReceiptHeader header

splitBoundReceipt
  :: ByteString
  -> Either BoundReceiptRefusal (ReceiptHeader, Int, ByteString)
splitBoundReceipt bytes
  | ByteString.length bytes < prefixBytes = Left BoundReceiptHeaderTorn
  | magic /= receiptHeaderMagic =
      Left (BoundReceiptHeaderCodecRefused ReceiptHeaderInvalid)
  | headerLength > maximumReceiptHeaderBytes =
      Left (BoundReceiptHeaderCodecRefused ReceiptHeaderTooLarge)
  | ByteString.length afterLength < headerLength = Left BoundReceiptHeaderTorn
  | otherwise = do
      header <-
        either
          (Left . BoundReceiptHeaderCodecRefused)
          Right
          (decodeReceiptHeader maximumReceiptHeaderBytes headerBytes)
      Right (header, prefixBytes + headerLength, journalBytes)
 where
  magicBytes = ByteString.length receiptHeaderMagic
  prefixBytes = magicBytes + 4
  (magic, afterMagic) = ByteString.splitAt magicBytes bytes
  (lengthBytes, afterLength) = ByteString.splitAt 4 afterMagic
  headerLength = fromIntegral (word32FromBE lengthBytes)
  (headerBytes, journalBytes) = ByteString.splitAt headerLength afterLength

writeNewAndSync :: FilePath -> ByteString -> IO ()
writeNewAndSync path bytes = do
  bracket
    ( openFd
        path
        WriteOnly
        defaultFileFlags
          { exclusive = True
          , creat = Just receiptFileMode
          , nofollow = True
          , cloexec = True
          }
    )
    safeCloseFd
    ( \fd -> do
        writeAll fd bytes
        fileSynchronise fd
    )
  syncDirectory (takeDirectory path)

-- | Append one frame durably: write the length-delimited record, fsync the file,
-- then fsync the parent directory.
appendReceiptFrame
  :: (Serialise payload)
  => FilePath
  -> DecommissionFrame payload
  -> IO ()
appendReceiptFrame path frame = do
  bracket
    ( openFd
        path
        WriteOnly
        defaultFileFlags
          { append = True
          , creat = Just receiptFileMode
          , nofollow = True
          , cloexec = True
          }
    )
    safeCloseFd
    ( \fd -> do
        writeAll fd (encodeRecord frame)
        fileSynchronise fd
    )
  syncDirectory (takeDirectory path)

-- | Reopen a receipt for recovery. A missing file is an empty (complete) receipt.
-- A torn final record is truncated away and the file fsynced; every other defect
-- is returned untouched.
reopenReceipt
  :: (Serialise payload)
  => Int
  -> FrameDigest
  -> FilePath
  -> IO (ReceiptReopen payload)
reopenReceipt maximumFrameBytes expectedManifest path = do
  exists <- doesFileExist path
  bytes <- if exists then ByteString.readFile path else pure ByteString.empty
  let recovery = recoverReceipt maximumFrameBytes expectedManifest bytes
  truncatedTo <- case recoveryOutcome recovery of
    RecoveryTruncatableTorn -> do
      truncateToValidPrefix path (recoveredValidBytes recovery)
      syncDirectory (takeDirectory path)
      pure (Just (recoveredValidBytes recovery))
    _ -> pure Nothing
  pure
    ReceiptReopen
      { reopenFrames = recoveredFrames recovery
      , reopenOutcome = recoveryOutcome recovery
      , reopenTruncatedTo = truncatedTo
      }

truncateToValidPrefix :: FilePath -> Int -> IO ()
truncateToValidPrefix path validBytes =
  bracket
    (openFd path WriteOnly defaultFileFlags {nofollow = True, cloexec = True})
    safeCloseFd
    ( \fd -> do
        setFdSize fd (fromIntegral validBytes)
        fileSynchronise fd
    )

syncDirectory :: FilePath -> IO ()
syncDirectory directory =
  bracket
    ( openFd
        directory
        ReadOnly
        defaultFileFlags {directory = True, nofollow = True, cloexec = True}
    )
    safeCloseFd
    fileSynchronise

writeAll :: Fd -> ByteString -> IO ()
writeAll _ bytes | ByteString.null bytes = pure ()
writeAll fd bytes = do
  written <- PosixBS.fdWrite fd bytes
  let count = fromIntegral written
  if count <= 0
    then fail "decommission receipt write made no progress"
    else writeAll fd (ByteString.drop count bytes)

word32ToBE :: Word32 -> ByteString
word32ToBE value =
  ByteString.pack
    [ octet 24
    , octet 16
    , octet 8
    , octet 0
    ]
 where
  octet shiftBy = fromIntegral (value `shiftR` shiftBy) :: Word8

word32FromBE :: ByteString -> Word32
word32FromBE bytes = case ByteString.unpack bytes of
  [a, b, c, d] ->
    (fromIntegral a `shiftL` 24)
      .|. (fromIntegral b `shiftL` 16)
      .|. (fromIntegral c `shiftL` 8)
      .|. fromIntegral d
  _ -> 0

safeCloseFd :: Fd -> IO ()
safeCloseFd fd = void (try (closeFd fd) :: IO (Either IOException ()))
