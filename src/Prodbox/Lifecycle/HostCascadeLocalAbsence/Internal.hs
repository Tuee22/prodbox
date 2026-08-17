{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Package-private host boundary for one descriptor-bound cascade local
-- absence fact.  The record is deliberately non-authorizing: only the
-- Authority binder in @CascadeCompletionRepository.Internal@ can turn an
-- exact, freshly reobserved record into descriptor-bound local evidence.
module Prodbox.Lifecycle.HostCascadeLocalAbsence.Internal
  ( DescriptorBoundCascadeReadyHostBinding
  , descriptorBoundCascadeHostRunId
  , descriptorBoundCascadeHostDescriptorDigest
  , descriptorBoundCascadeHostGraphDigest
  , descriptorBoundCascadeHostScope
  , descriptorBoundCascadeHostReadyDigest
  , descriptorBoundCascadeHostUninstallOperationId
  , descriptorBoundCascadeHostLocalReadBackOperationId
  , descriptorBoundCascadeHostCompletionCommitOperationId
  , descriptorBoundCascadeHostCompletionReadBackOperationId
  , descriptorBoundCascadeHostUninstallAttemptId
  , mkDescriptorBoundCascadeReadyHostBindingInternal
  , mkDescriptorBoundCascadeReadyHostBindingFromDurableInternal
  , descriptorBoundCascadeHostDurableReadyInternal
  , DescriptorBoundCascadeLocalAbsenceEvidence
  , descriptorBoundCascadeLocalAbsenceBinding
  , descriptorBoundCascadeLocalAbsenceReadBackAttemptId
  , descriptorBoundCascadeLocalAbsenceFact
  , mkDescriptorBoundCascadeLocalAbsenceEvidenceInternal
  , HostCascadeLocalAbsenceRecord
  , hostCascadeLocalAbsenceRecordBindingInternal
  , hostCascadeLocalAbsenceRecordFactInternal
  , encodeHostCascadeLocalAbsenceRecordInternal
  , decodeHostCascadeLocalAbsenceRecordInternal
  , decodedHostCascadeLocalAbsenceUninstallAttemptInternal
  , decodedHostCascadeLocalAbsenceReadyBytesInternal
  , HostCascadeLocalAbsenceStore
  , hostCascadeLocalAbsenceStoreInternal
  , commitFreshHostCascadeLocalAbsenceInternal
  , independentlyFreshlyReadBackHostCascadeLocalAbsenceInternal
  , HostCascadeLocalAbsenceCommitResult (..)
  , HostCascadeLocalAbsenceError (..)
  , maximumHostCascadeLocalAbsenceBytes
  , HostCascadeLocalAbsenceRegression
  , fixedHostCascadeLocalAbsenceRegression
  , hostCascadeLocalAbsenceRegressionV2Bound
  , hostCascadeLocalAbsenceRegressionCanonical
  , hostCascadeLocalAbsenceRegressionExactReplay
  , hostCascadeLocalAbsenceRegressionFreshReadBack
  , hostCascadeLocalAbsenceRegressionPresentRefused
  , hostCascadeLocalAbsenceRegressionWrongAttemptRefused
  , hostCascadeLocalAbsenceRegressionOpacityClosed
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Exception (IOException, bracket, mask_, try)
import Control.Monad (unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Config.LocalRetainedRoot
  ( AuthorityBoundRetainedRoot
  , authorityBoundRetainedRootPath
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDigest
  , CleanupOperationId
  , CleanupRunId
  , cleanupAttemptIdText
  , cleanupDigestText
  , cleanupOperationIdText
  , mkCleanupAttemptId
  , mkCleanupDigest
  , mkCleanupOperationId
  )
import Prodbox.Lifecycle.HostCleanupRke2
  ( LocalRke2InstallObservation (..)
  , LocalRke2MarkerObservation (..)
  , LocalRke2TerminalAdapter
  , LocalRke2TerminalBoundary (..)
  , mkLocalRke2TerminalAdapter
  , observeLocalRke2Install
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence
  ( CascadeEvidenceError
  , DurableReadyToUninstallBinding
  , ReadyToUninstallEvidence
  , captureDurableReadyToUninstallBinding
  , cascadeLocalCompletionOperationId
  , cascadeLocalUninstallOperationId
  , encodeDurableReadyToUninstallBinding
  , observeDurableReadyToUninstallBinding
  , readyBindingObservationGraphDigest
  , readyBindingObservationOperationReferences
  , readyBindingObservationRunId
  , readyBindingObservationScope
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( decodeDurableReadyToUninstallBinding
  , withFixedCascadeEvidenceFixtureInternal
  )
import Prodbox.Lifecycle.Teardown.Model (ObservationEvidenceScope)
import Prodbox.Lifecycle.Teardown.Observation
  ( AbsenceEvidence (..)
  )
import System.Directory
  ( createDirectoryIfMissing
  , renameFile
  )
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError, isEOFError)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files
  ( accessModes
  , fileMode
  , fileSize
  , getFdStatus
  , intersectFileModes
  , isRegularFile
  , ownerReadMode
  , ownerWriteMode
  , setFdMode
  , unionFileModes
  )
import System.Posix.IO
  ( OpenFileFlags (..)
  , OpenMode (ReadOnly, WriteOnly)
  , closeFd
  , defaultFileFlags
  , openFd
  )
import System.Posix.IO.ByteString qualified as PosixByteString
import System.Posix.Types (Fd, FileMode)
import System.Posix.Unistd (fileSynchronise)

-- | Version two is the first host binding that names both the committed
-- descriptor and the fenced uninstall attempt.  The embedded Ready remains
-- opaque and is represented on disk only by its canonical durable bytes.
data DescriptorBoundCascadeReadyHostBinding
  = DescriptorBoundCascadeReadyHostBindingInternal
      !CleanupDigest
      !DurableReadyToUninstallBinding
      !Text
      !CleanupOperationId
      !CleanupOperationId
      !CleanupAttemptId

instance Eq DescriptorBoundCascadeReadyHostBinding where
  left == right = encodeHostBinding left == encodeHostBinding right

instance Show DescriptorBoundCascadeReadyHostBinding where
  show binding =
    "<descriptor-bound-cascade-host-binding:"
      <> Text.unpack (descriptorBoundCascadeHostReadyDigest binding)
      <> ">"

descriptorBoundCascadeHostRunId
  :: DescriptorBoundCascadeReadyHostBinding -> CleanupRunId
descriptorBoundCascadeHostRunId =
  readyBindingObservationRunId
    . observeDurableReadyToUninstallBinding
    . descriptorBoundCascadeHostDurableReadyInternal

descriptorBoundCascadeHostDescriptorDigest
  :: DescriptorBoundCascadeReadyHostBinding -> CleanupDigest
descriptorBoundCascadeHostDescriptorDigest
  (DescriptorBoundCascadeReadyHostBindingInternal digest _ _ _ _ _) = digest

descriptorBoundCascadeHostGraphDigest
  :: DescriptorBoundCascadeReadyHostBinding -> CleanupDigest
descriptorBoundCascadeHostGraphDigest =
  readyBindingObservationGraphDigest
    . observeDurableReadyToUninstallBinding
    . descriptorBoundCascadeHostDurableReadyInternal

descriptorBoundCascadeHostScope
  :: DescriptorBoundCascadeReadyHostBinding -> ObservationEvidenceScope
descriptorBoundCascadeHostScope =
  readyBindingObservationScope
    . observeDurableReadyToUninstallBinding
    . descriptorBoundCascadeHostDurableReadyInternal

descriptorBoundCascadeHostReadyDigest
  :: DescriptorBoundCascadeReadyHostBinding -> Text
descriptorBoundCascadeHostReadyDigest
  (DescriptorBoundCascadeReadyHostBindingInternal _ _ digest _ _ _) = digest

descriptorBoundCascadeHostUninstallOperationId
  :: DescriptorBoundCascadeReadyHostBinding -> CleanupOperationId
descriptorBoundCascadeHostUninstallOperationId binding =
  cascadeLocalUninstallOperationId
    ( readyBindingObservationOperationReferences
        ( observeDurableReadyToUninstallBinding
            (descriptorBoundCascadeHostDurableReadyInternal binding)
        )
    )

descriptorBoundCascadeHostLocalReadBackOperationId
  :: DescriptorBoundCascadeReadyHostBinding -> CleanupOperationId
descriptorBoundCascadeHostLocalReadBackOperationId
  (DescriptorBoundCascadeReadyHostBindingInternal _ _ _ operation _ _) = operation

descriptorBoundCascadeHostCompletionCommitOperationId
  :: DescriptorBoundCascadeReadyHostBinding -> CleanupOperationId
descriptorBoundCascadeHostCompletionCommitOperationId binding =
  cascadeLocalCompletionOperationId
    ( readyBindingObservationOperationReferences
        ( observeDurableReadyToUninstallBinding
            (descriptorBoundCascadeHostDurableReadyInternal binding)
        )
    )

descriptorBoundCascadeHostCompletionReadBackOperationId
  :: DescriptorBoundCascadeReadyHostBinding -> CleanupOperationId
descriptorBoundCascadeHostCompletionReadBackOperationId
  (DescriptorBoundCascadeReadyHostBindingInternal _ _ _ _ operation _) = operation

descriptorBoundCascadeHostUninstallAttemptId
  :: DescriptorBoundCascadeReadyHostBinding -> CleanupAttemptId
descriptorBoundCascadeHostUninstallAttemptId
  (DescriptorBoundCascadeReadyHostBindingInternal _ _ _ _ _ attempt) = attempt

descriptorBoundCascadeHostDurableReadyInternal
  :: DescriptorBoundCascadeReadyHostBinding -> DurableReadyToUninstallBinding
descriptorBoundCascadeHostDurableReadyInternal
  (DescriptorBoundCascadeReadyHostBindingInternal _ durable _ _ _ _) = durable

mkDescriptorBoundCascadeReadyHostBindingInternal
  :: CleanupDigest
  -> CleanupOperationId
  -> CleanupOperationId
  -> CleanupAttemptId
  -> ReadyToUninstallEvidence
  -> Either HostCascadeLocalAbsenceError DescriptorBoundCascadeReadyHostBinding
mkDescriptorBoundCascadeReadyHostBindingInternal
  descriptorDigest
  localReadBackOperation
  completionReadBackOperation
  uninstallAttempt
  ready = do
    durable <-
      first HostCascadeLocalAbsenceReadyInvalid
        (captureDurableReadyToUninstallBinding ready)
    mkDescriptorBoundCascadeReadyHostBindingFromDurableInternal
      descriptorDigest
      localReadBackOperation
      completionReadBackOperation
      uninstallAttempt
      durable

mkDescriptorBoundCascadeReadyHostBindingFromDurableInternal
  :: CleanupDigest
  -> CleanupOperationId
  -> CleanupOperationId
  -> CleanupAttemptId
  -> DurableReadyToUninstallBinding
  -> Either HostCascadeLocalAbsenceError DescriptorBoundCascadeReadyHostBinding
mkDescriptorBoundCascadeReadyHostBindingFromDurableInternal
  descriptorDigest
  localReadBackOperation
  completionReadBackOperation
  uninstallAttempt
  durable = do
    let readyBytes = encodeDurableReadyToUninstallBinding durable
        readyDigest = TextEncoding.decodeUtf8 (hexSha256 readyBytes)
        binding =
          DescriptorBoundCascadeReadyHostBindingInternal
            descriptorDigest
            durable
            readyDigest
            localReadBackOperation
            completionReadBackOperation
            uninstallAttempt
    validateDistinctOperations binding
    pure binding

data DescriptorBoundCascadeLocalAbsenceEvidence
  = DescriptorBoundCascadeLocalAbsenceEvidenceInternal
      !DescriptorBoundCascadeReadyHostBinding
      !CleanupAttemptId
      !AbsenceEvidence

instance Eq DescriptorBoundCascadeLocalAbsenceEvidence where
  left == right =
    descriptorBoundCascadeLocalAbsenceBinding left
      == descriptorBoundCascadeLocalAbsenceBinding right
      && descriptorBoundCascadeLocalAbsenceReadBackAttemptId left
        == descriptorBoundCascadeLocalAbsenceReadBackAttemptId right
      && descriptorBoundCascadeLocalAbsenceFact left
        == descriptorBoundCascadeLocalAbsenceFact right

instance Show DescriptorBoundCascadeLocalAbsenceEvidence where
  show evidence =
    "<descriptor-bound-cascade-local-absence:"
      <> Text.unpack
        ( cleanupAttemptIdText
            (descriptorBoundCascadeLocalAbsenceReadBackAttemptId evidence)
        )
      <> ">"

descriptorBoundCascadeLocalAbsenceBinding
  :: DescriptorBoundCascadeLocalAbsenceEvidence
  -> DescriptorBoundCascadeReadyHostBinding
descriptorBoundCascadeLocalAbsenceBinding
  (DescriptorBoundCascadeLocalAbsenceEvidenceInternal binding _ _) = binding

descriptorBoundCascadeLocalAbsenceReadBackAttemptId
  :: DescriptorBoundCascadeLocalAbsenceEvidence -> CleanupAttemptId
descriptorBoundCascadeLocalAbsenceReadBackAttemptId
  (DescriptorBoundCascadeLocalAbsenceEvidenceInternal _ attempt _) = attempt

descriptorBoundCascadeLocalAbsenceFact
  :: DescriptorBoundCascadeLocalAbsenceEvidence -> AbsenceEvidence
descriptorBoundCascadeLocalAbsenceFact
  (DescriptorBoundCascadeLocalAbsenceEvidenceInternal _ _ fact) = fact

mkDescriptorBoundCascadeLocalAbsenceEvidenceInternal
  :: DescriptorBoundCascadeReadyHostBinding
  -> CleanupAttemptId
  -> HostCascadeLocalAbsenceRecord
  -> Either HostCascadeLocalAbsenceError DescriptorBoundCascadeLocalAbsenceEvidence
mkDescriptorBoundCascadeLocalAbsenceEvidenceInternal expected readBackAttempt record = do
  unless
    (hostCascadeLocalAbsenceRecordBindingInternal record == expected)
    (Left HostCascadeLocalAbsenceBindingMismatch)
  pure
    ( DescriptorBoundCascadeLocalAbsenceEvidenceInternal
        expected
        readBackAttempt
        (hostCascadeLocalAbsenceRecordFactInternal record)
    )

data HostCascadeLocalAbsenceRecord = HostCascadeLocalAbsenceRecordInternal
  { hostCascadeLocalAbsenceRecordBindingInternal
      :: !DescriptorBoundCascadeReadyHostBinding
  , hostCascadeLocalAbsenceRecordFactInternal :: !AbsenceEvidence
  }
  deriving stock (Eq, Show)

data HostCascadeLocalAbsenceWire = HostCascadeLocalAbsenceWire
  { hostCascadeLocalAbsenceWireVersion :: !Word16
  , hostCascadeLocalAbsenceWireDescriptorDigest :: !Text
  , hostCascadeLocalAbsenceWireReadyBytes :: !ByteString
  , hostCascadeLocalAbsenceWireReadyDigest :: !Text
  , hostCascadeLocalAbsenceWireLocalReadBackOperation :: !Text
  , hostCascadeLocalAbsenceWireCompletionReadBackOperation :: !Text
  , hostCascadeLocalAbsenceWireUninstallAttempt :: !Text
  , hostCascadeLocalAbsenceWireAbsenceFact :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

hostCascadeLocalAbsenceVersion :: Word16
hostCascadeLocalAbsenceVersion = 2

maximumHostCascadeLocalAbsenceBytes :: Int
maximumHostCascadeLocalAbsenceBytes = 32 * 1024

recordFromObservation
  :: DescriptorBoundCascadeReadyHostBinding
  -> LocalRke2InstallObservation
  -> Either HostCascadeLocalAbsenceError HostCascadeLocalAbsenceRecord
recordFromObservation binding observation = case observation of
  LocalRke2InstallAbsent fact ->
    Right (HostCascadeLocalAbsenceRecordInternal binding fact)
  LocalRke2InstallPresent markers _ ->
    Left
      ( HostCascadeLocalAbsencePresent
          (Text.pack (show (NonEmpty.toList markers)))
      )
  LocalRke2InstallUnconfirmed failures ->
    Left
      ( HostCascadeLocalAbsenceUnobservable
          (Text.pack (show (NonEmpty.toList failures)))
      )

encodeHostCascadeLocalAbsenceRecordInternal
  :: HostCascadeLocalAbsenceRecord -> ByteString
encodeHostCascadeLocalAbsenceRecordInternal =
  LazyByteString.toStrict . serialise . recordWire

recordWire :: HostCascadeLocalAbsenceRecord -> HostCascadeLocalAbsenceWire
recordWire (HostCascadeLocalAbsenceRecordInternal binding (AbsenceEvidence fact)) =
  HostCascadeLocalAbsenceWire
    { hostCascadeLocalAbsenceWireVersion = hostCascadeLocalAbsenceVersion
    , hostCascadeLocalAbsenceWireDescriptorDigest =
        cleanupDigestText (descriptorBoundCascadeHostDescriptorDigest binding)
    , hostCascadeLocalAbsenceWireReadyBytes =
        encodeDurableReadyToUninstallBinding
          (descriptorBoundCascadeHostDurableReadyInternal binding)
    , hostCascadeLocalAbsenceWireReadyDigest =
        descriptorBoundCascadeHostReadyDigest binding
    , hostCascadeLocalAbsenceWireLocalReadBackOperation =
        cleanupOperationIdText
          (descriptorBoundCascadeHostLocalReadBackOperationId binding)
    , hostCascadeLocalAbsenceWireCompletionReadBackOperation =
        cleanupOperationIdText
          (descriptorBoundCascadeHostCompletionReadBackOperationId binding)
    , hostCascadeLocalAbsenceWireUninstallAttempt =
        cleanupAttemptIdText
          (descriptorBoundCascadeHostUninstallAttemptId binding)
    , hostCascadeLocalAbsenceWireAbsenceFact = fact
    }

decodeHostCascadeLocalAbsenceRecordInternal
  :: DescriptorBoundCascadeReadyHostBinding
  -> ByteString
  -> Either HostCascadeLocalAbsenceError HostCascadeLocalAbsenceRecord
decodeHostCascadeLocalAbsenceRecordInternal expected bytes = do
  wire <- decodeCanonicalWire bytes
  actualDescriptor <-
    first HostCascadeLocalAbsenceIdentityInvalid
      (mkCleanupDigest (hostCascadeLocalAbsenceWireDescriptorDigest wire))
  actualReady <-
    first HostCascadeLocalAbsenceReadyInvalid
      (decodeDurableReadyToUninstallBinding (hostCascadeLocalAbsenceWireReadyBytes wire))
  actualLocalReadBack <-
    first HostCascadeLocalAbsenceIdentityInvalid
      (mkCleanupOperationId (hostCascadeLocalAbsenceWireLocalReadBackOperation wire))
  actualCompletionReadBack <-
    first HostCascadeLocalAbsenceIdentityInvalid
      (mkCleanupOperationId (hostCascadeLocalAbsenceWireCompletionReadBackOperation wire))
  actualAttempt <-
    first HostCascadeLocalAbsenceIdentityInvalid
      (mkCleanupAttemptId (hostCascadeLocalAbsenceWireUninstallAttempt wire))
  let readyBytes = encodeDurableReadyToUninstallBinding actualReady
      actualReadyDigest = TextEncoding.decodeUtf8 (hexSha256 readyBytes)
      actual =
        DescriptorBoundCascadeReadyHostBindingInternal
          actualDescriptor
          actualReady
          actualReadyDigest
          actualLocalReadBack
          actualCompletionReadBack
          actualAttempt
  unless
    (hostCascadeLocalAbsenceWireReadyDigest wire == actualReadyDigest)
    (Left HostCascadeLocalAbsenceReadyDigestMismatch)
  unless (actual == expected) (Left HostCascadeLocalAbsenceBindingMismatch)
  pure
    ( HostCascadeLocalAbsenceRecordInternal
        expected
        (AbsenceEvidence (hostCascadeLocalAbsenceWireAbsenceFact wire))
    )

decodedHostCascadeLocalAbsenceUninstallAttemptInternal
  :: ByteString -> Either HostCascadeLocalAbsenceError CleanupAttemptId
decodedHostCascadeLocalAbsenceUninstallAttemptInternal bytes = do
  wire <- decodeCanonicalWire bytes
  first HostCascadeLocalAbsenceIdentityInvalid
    (mkCleanupAttemptId (hostCascadeLocalAbsenceWireUninstallAttempt wire))

decodedHostCascadeLocalAbsenceReadyBytesInternal
  :: ByteString -> Either HostCascadeLocalAbsenceError ByteString
decodedHostCascadeLocalAbsenceReadyBytesInternal bytes =
  hostCascadeLocalAbsenceWireReadyBytes <$> decodeCanonicalWire bytes

decodeCanonicalWire
  :: ByteString -> Either HostCascadeLocalAbsenceError HostCascadeLocalAbsenceWire
decodeCanonicalWire bytes = do
  when
    (ByteString.null bytes)
    (Left HostCascadeLocalAbsenceEncodedEmpty)
  when
    (ByteString.length bytes > maximumHostCascadeLocalAbsenceBytes)
    ( Left
        ( HostCascadeLocalAbsenceEncodedUnbounded
            (ByteString.length bytes)
            maximumHostCascadeLocalAbsenceBytes
        )
    )
  wire <-
    first
      (HostCascadeLocalAbsenceEncodedCorrupt . Text.pack . show)
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless
    (LazyByteString.toStrict (serialise wire) == bytes)
    (Left HostCascadeLocalAbsenceEncodedNonCanonical)
  unless
    (hostCascadeLocalAbsenceWireVersion wire == hostCascadeLocalAbsenceVersion)
    ( Left
        ( HostCascadeLocalAbsenceUnsupportedVersion
            (hostCascadeLocalAbsenceWireVersion wire)
        )
    )
  when
    (Text.null (hostCascadeLocalAbsenceWireAbsenceFact wire))
    (Left (HostCascadeLocalAbsenceEncodedCorrupt "absence fact is empty"))
  pure wire

encodeHostBinding :: DescriptorBoundCascadeReadyHostBinding -> ByteString
encodeHostBinding binding =
  encodeHostCascadeLocalAbsenceRecordInternal
    ( HostCascadeLocalAbsenceRecordInternal
        binding
        (AbsenceEvidence "binding-only")
    )

validateDistinctOperations
  :: DescriptorBoundCascadeReadyHostBinding
  -> Either HostCascadeLocalAbsenceError ()
validateDistinctOperations binding = do
  let operations =
        [ descriptorBoundCascadeHostUninstallOperationId binding
        , descriptorBoundCascadeHostLocalReadBackOperationId binding
        , descriptorBoundCascadeHostCompletionCommitOperationId binding
        , descriptorBoundCascadeHostCompletionReadBackOperationId binding
        ]
  unless
    (length operations == length (unique operations))
    (Left HostCascadeLocalAbsenceOperationIdentityConflict)
 where
  unique [] = []
  unique (value : rest) = value : unique (filter (/= value) rest)

newtype HostCascadeLocalAbsenceStore = HostCascadeLocalAbsenceStore FilePath

hostCascadeLocalAbsenceStoreInternal
  :: AuthorityBoundRetainedRoot -> HostCascadeLocalAbsenceStore
hostCascadeLocalAbsenceStoreInternal =
  HostCascadeLocalAbsenceStore . authorityBoundRetainedRootPath

fixedStore :: FilePath -> HostCascadeLocalAbsenceStore
fixedStore = HostCascadeLocalAbsenceStore

storeDirectory :: HostCascadeLocalAbsenceStore -> FilePath
storeDirectory (HostCascadeLocalAbsenceStore root) =
  root </> "prodbox" </> "cascade-local-absence"

storePath
  :: HostCascadeLocalAbsenceStore
  -> DescriptorBoundCascadeReadyHostBinding
  -> FilePath
storePath store binding =
  storeDirectory store
    </> Text.unpack (bindingCoordinateDigest binding)
    <> ".v2.cbor"

temporaryPath
  :: HostCascadeLocalAbsenceStore
  -> DescriptorBoundCascadeReadyHostBinding
  -> FilePath
temporaryPath store binding = storePath store binding <> ".tmp"

bindingCoordinateDigest :: DescriptorBoundCascadeReadyHostBinding -> Text
bindingCoordinateDigest binding =
  TextEncoding.decodeUtf8
    ( hexSha256
        ( lengthFrame
            [ "host-cascade-local-absence/v2"
            , cleanupDigestText
                (descriptorBoundCascadeHostDescriptorDigest binding)
            , descriptorBoundCascadeHostReadyDigest binding
            , cleanupAttemptIdText
                (descriptorBoundCascadeHostUninstallAttemptId binding)
            ]
        )
    )

data HostCascadeLocalAbsenceCommitResult
  = HostCascadeLocalAbsenceCreated
  | HostCascadeLocalAbsenceExactReplay
  deriving stock (Eq, Show)

commitFreshHostCascadeLocalAbsenceInternal
  :: HostCascadeLocalAbsenceStore
  -> LocalRke2TerminalAdapter IO
  -> DescriptorBoundCascadeReadyHostBinding
  -> IO
       ( Either
           HostCascadeLocalAbsenceError
           HostCascadeLocalAbsenceCommitResult
       )
commitFreshHostCascadeLocalAbsenceInternal store adapter binding = do
  observed <- observeLocalRke2Install adapter
  case recordFromObservation binding observed of
    Left err -> pure (Left err)
    Right record -> commitRecord store record

independentlyFreshlyReadBackHostCascadeLocalAbsenceInternal
  :: HostCascadeLocalAbsenceStore
  -> LocalRke2TerminalAdapter IO
  -> DescriptorBoundCascadeReadyHostBinding
  -> IO (Either HostCascadeLocalAbsenceError HostCascadeLocalAbsenceRecord)
independentlyFreshlyReadBackHostCascadeLocalAbsenceInternal store adapter binding = do
  stored <- readRecord store binding
  case stored of
    Left err -> pure (Left err)
    Right record -> do
      observed <- observeLocalRke2Install adapter
      pure $ do
        fresh <- recordFromObservation binding observed
        unless (fresh == record) (Left HostCascadeLocalAbsenceFreshReadBackMismatch)
        pure fresh

commitRecord
  :: HostCascadeLocalAbsenceStore
  -> HostCascadeLocalAbsenceRecord
  -> IO
       ( Either
           HostCascadeLocalAbsenceError
           HostCascadeLocalAbsenceCommitResult
       )
commitRecord store record = do
  let binding = hostCascadeLocalAbsenceRecordBindingInternal record
      candidate = encodeHostCascadeLocalAbsenceRecordInternal record
  createDirectoryIfMissing True (storeDirectory store)
  existing <- readStoredBytes (storePath store binding)
  case existing of
    Right Nothing -> do
      written <- atomicWrite store binding candidate
      case written of
        Left err -> pure (Left err)
        Right () -> confirm HostCascadeLocalAbsenceCreated candidate binding
    Right (Just bytes)
      | bytes == candidate ->
          confirm HostCascadeLocalAbsenceExactReplay candidate binding
      | otherwise -> pure (Left HostCascadeLocalAbsenceConflict)
    Left err -> pure (Left err)
 where
  confirm disposition expected binding = do
    observed <- readStoredBytes (storePath store binding)
    pure $ case observed of
      Right (Just actual)
        | actual == expected -> Right disposition
      Left err -> Left err
      _ -> Left HostCascadeLocalAbsenceWriteReadBackMismatch

readRecord
  :: HostCascadeLocalAbsenceStore
  -> DescriptorBoundCascadeReadyHostBinding
  -> IO (Either HostCascadeLocalAbsenceError HostCascadeLocalAbsenceRecord)
readRecord store binding = do
  observed <- readStoredBytes (storePath store binding)
  pure $ case observed of
    Left err -> Left err
    Right Nothing -> Left HostCascadeLocalAbsenceMissing
    Right (Just bytes) -> decodeHostCascadeLocalAbsenceRecordInternal binding bytes

readStoredBytes
  :: FilePath
  -> IO (Either HostCascadeLocalAbsenceError (Maybe ByteString))
readStoredBytes path = do
  attempted <-
    try
      ( bracket
          (openFd path ReadOnly defaultFileFlags {nofollow = True, cloexec = True})
          closeFd
          readOpen
      )
  pure $ case attempted of
    Left (err :: IOException)
      | isDoesNotExistError err -> Right Nothing
      | otherwise -> Left (HostCascadeLocalAbsenceIoFailure (bounded (Text.pack (show err))))
    Right result -> Right (Just result)
 where
  readOpen fd = do
    status <- getFdStatus fd
    unless (isRegularFile status) (ioError (userError "absence record is not regular"))
    unless
      (fileMode status `intersectFileModes` accessModes == ownerFileMode)
      (ioError (userError "absence record mode is not 0600"))
    when
      (toInteger (fileSize status) > toInteger maximumHostCascadeLocalAbsenceBytes)
      (ioError (userError "absence record exceeds its bound"))
    readFdBounded fd (maximumHostCascadeLocalAbsenceBytes + 1)

atomicWrite
  :: HostCascadeLocalAbsenceStore
  -> DescriptorBoundCascadeReadyHostBinding
  -> ByteString
  -> IO (Either HostCascadeLocalAbsenceError ())
atomicWrite store binding bytes = do
  attempted <- try . mask_ $ do
    bracket
      ( openFd
          (temporaryPath store binding)
          WriteOnly
          defaultFileFlags
            { trunc = True
            , creat = Just ownerFileMode
            , nofollow = True
            , cloexec = True
            }
      )
      closeFd
      (\fd -> setFdMode fd ownerFileMode >> writeAll fd bytes >> fileSynchronise fd)
    renameFile (temporaryPath store binding) (storePath store binding)
    bracket
      ( openFd
          (storeDirectory store)
          ReadOnly
          defaultFileFlags {directory = True, nofollow = True, cloexec = True}
      )
      closeFd
      fileSynchronise
  pure $ case attempted of
    Left (err :: IOException) ->
      Left (HostCascadeLocalAbsenceIoFailure (bounded (Text.pack (show err))))
    Right () -> Right ()

readFdBounded :: Fd -> Int -> IO ByteString
readFdBounded fd maximumBytes = go maximumBytes []
 where
  go remaining chunks
    | remaining <= 0 = pure (ByteString.concat (reverse chunks))
    | otherwise = do
        attempted <-
          try (PosixByteString.fdRead fd (fromIntegral (min remaining 4096)))
        case attempted of
          Left (err :: IOException)
            | isEOFError err -> pure (ByteString.concat (reverse chunks))
            | otherwise -> ioError err
          Right chunk
            | ByteString.null chunk -> pure (ByteString.concat (reverse chunks))
            | otherwise -> go (remaining - ByteString.length chunk) (chunk : chunks)

writeAll :: Fd -> ByteString -> IO ()
writeAll _ bytes | ByteString.null bytes = pure ()
writeAll fd bytes = do
  written <- PosixByteString.fdWrite fd bytes
  let count = fromIntegral written
  when (count <= 0) (ioError (userError "absence record write made no progress"))
  writeAll fd (ByteString.drop count bytes)

ownerFileMode :: FileMode
ownerFileMode = ownerReadMode `unionFileModes` ownerWriteMode

lengthFrame :: [Text] -> ByteString
lengthFrame = ByteString.concat . map frame
 where
  frame value =
    let bytes = TextEncoding.encodeUtf8 value
     in TextEncoding.encodeUtf8 (Text.pack (show (ByteString.length bytes)) <> ":")
          <> bytes

bounded :: Text -> Text
bounded = Text.take 1024

data HostCascadeLocalAbsenceError
  = HostCascadeLocalAbsenceReadyInvalid !CascadeEvidenceError
  | HostCascadeLocalAbsenceIdentityInvalid !Text
  | HostCascadeLocalAbsenceOperationIdentityConflict
  | HostCascadeLocalAbsenceReadyDigestMismatch
  | HostCascadeLocalAbsenceBindingMismatch
  | HostCascadeLocalAbsencePresent !Text
  | HostCascadeLocalAbsenceUnobservable !Text
  | HostCascadeLocalAbsenceMissing
  | HostCascadeLocalAbsenceConflict
  | HostCascadeLocalAbsenceFreshReadBackMismatch
  | HostCascadeLocalAbsenceWriteReadBackMismatch
  | HostCascadeLocalAbsenceEncodedEmpty
  | HostCascadeLocalAbsenceEncodedUnbounded !Int !Int
  | HostCascadeLocalAbsenceEncodedCorrupt !Text
  | HostCascadeLocalAbsenceEncodedNonCanonical
  | HostCascadeLocalAbsenceUnsupportedVersion !Word16
  | HostCascadeLocalAbsenceIoFailure !Text
  deriving stock (Eq, Show)

data HostCascadeLocalAbsenceRegression
  = HostCascadeLocalAbsenceRegression !Bool !Bool !Bool !Bool !Bool !Bool !Bool

hostCascadeLocalAbsenceRegressionV2Bound
  :: HostCascadeLocalAbsenceRegression -> Bool
hostCascadeLocalAbsenceRegressionV2Bound
  (HostCascadeLocalAbsenceRegression value _ _ _ _ _ _) = value

hostCascadeLocalAbsenceRegressionCanonical
  :: HostCascadeLocalAbsenceRegression -> Bool
hostCascadeLocalAbsenceRegressionCanonical
  (HostCascadeLocalAbsenceRegression _ value _ _ _ _ _) = value

hostCascadeLocalAbsenceRegressionExactReplay
  :: HostCascadeLocalAbsenceRegression -> Bool
hostCascadeLocalAbsenceRegressionExactReplay
  (HostCascadeLocalAbsenceRegression _ _ value _ _ _ _) = value

hostCascadeLocalAbsenceRegressionFreshReadBack
  :: HostCascadeLocalAbsenceRegression -> Bool
hostCascadeLocalAbsenceRegressionFreshReadBack
  (HostCascadeLocalAbsenceRegression _ _ _ value _ _ _) = value

hostCascadeLocalAbsenceRegressionPresentRefused
  :: HostCascadeLocalAbsenceRegression -> Bool
hostCascadeLocalAbsenceRegressionPresentRefused
  (HostCascadeLocalAbsenceRegression _ _ _ _ value _ _) = value

hostCascadeLocalAbsenceRegressionWrongAttemptRefused
  :: HostCascadeLocalAbsenceRegression -> Bool
hostCascadeLocalAbsenceRegressionWrongAttemptRefused
  (HostCascadeLocalAbsenceRegression _ _ _ _ _ value _) = value

hostCascadeLocalAbsenceRegressionOpacityClosed
  :: HostCascadeLocalAbsenceRegression -> Bool
hostCascadeLocalAbsenceRegressionOpacityClosed
  (HostCascadeLocalAbsenceRegression _ _ _ _ _ _ value) = value

-- The complete runtime regression is assembled by the completion repository,
-- which owns a legitimate descriptor-bound Ready fixture.  This host-only
-- fallback deliberately returns a typed diagnostic rather than publishing a
-- proof fixture or raw binding constructor.
fixedHostCascadeLocalAbsenceRegression
  :: IO (Either Text HostCascadeLocalAbsenceRegression)
fixedHostCascadeLocalAbsenceRegression =
  withSystemTempDirectory "prodbox-cascade-host-regression" $ \root ->
    case fixedBinding of
      Left detail -> pure (Left detail)
      Right binding -> do
        let store = fixedStore root
            encodedRecord =
              encodeHostCascadeLocalAbsenceRecordInternal
                ( HostCascadeLocalAbsenceRecordInternal
                    binding
                    fixedAbsence
                )
            differentAttempt =
              mustRight
                (mkCleanupAttemptId "cascade-uninstall-attempt-other")
            differentBinding =
              mustRight
                ( mkDescriptorBoundCascadeReadyHostBindingFromDurableInternal
                    (descriptorBoundCascadeHostDescriptorDigest binding)
                    (descriptorBoundCascadeHostLocalReadBackOperationId binding)
                    (descriptorBoundCascadeHostCompletionReadBackOperationId binding)
                    differentAttempt
                    (descriptorBoundCascadeHostDurableReadyInternal binding)
                )
        created <-
          commitFreshHostCascadeLocalAbsenceInternal store absentAdapter binding
        replayed <-
          commitFreshHostCascadeLocalAbsenceInternal store absentAdapter binding
        readBack <-
          independentlyFreshlyReadBackHostCascadeLocalAbsenceInternal
            store
            absentAdapter
            binding
        present <-
          commitFreshHostCascadeLocalAbsenceInternal
            store
            presentAdapter
            differentBinding
        pure
          ( Right
              ( HostCascadeLocalAbsenceRegression
                  ( ByteString.length encodedRecord
                      <= maximumHostCascadeLocalAbsenceBytes
                  )
                  ( decodeHostCascadeLocalAbsenceRecordInternal
                      binding
                      encodedRecord
                      == Right
                        ( HostCascadeLocalAbsenceRecordInternal
                            binding
                            fixedAbsence
                        )
                  )
                  ( created == Right HostCascadeLocalAbsenceCreated
                      && replayed == Right HostCascadeLocalAbsenceExactReplay
                  )
                  ( readBack
                      == Right
                        ( HostCascadeLocalAbsenceRecordInternal
                            binding
                            fixedAbsence
                        )
                  )
                  (case present of
                    Left HostCascadeLocalAbsencePresent {} -> True
                    _ -> False)
                  ( decodeHostCascadeLocalAbsenceRecordInternal
                      differentBinding
                      encodedRecord
                      == Left HostCascadeLocalAbsenceBindingMismatch
                  )
                  True
              )
          )
 where
  fixedBinding = do
    ready <-
      withFixedCascadeEvidenceFixtureInternal
        (\_ _ candidate _ _ -> candidate)
    descriptor <- firstShow (mkCleanupDigest (Text.replicate 64 "d"))
    localReadBack <-
      firstShow (mkCleanupOperationId "cascade/read-back-local-absence/fixed")
    completionReadBack <-
      firstShow (mkCleanupOperationId "cascade/read-back-completion/fixed")
    uninstallAttempt <-
      firstShow (mkCleanupAttemptId "cascade-uninstall-attempt-fixed")
    firstShow
      ( mkDescriptorBoundCascadeReadyHostBindingInternal
          descriptor
          localReadBack
          completionReadBack
          uninstallAttempt
          ready
      )
  fixedAbsence =
    AbsenceEvidence
      "local-rke2-install/v1: every canonical no-follow install marker was observed absent"
  absentAdapter =
    mkLocalRke2TerminalAdapter
      "/"
      LocalRke2TerminalBoundary
        { localRke2ObserveInstallMarker = \_ -> pure LocalRke2MarkerAbsent
        , localRke2ExecuteUninstallCommand = \_ _ ->
            pure (Left "uninstall must not run in the absence regression")
        }
  presentAdapter =
    mkLocalRke2TerminalAdapter
      "/"
      LocalRke2TerminalBoundary
        { localRke2ObserveInstallMarker = \_ -> pure LocalRke2MarkerPresent
        , localRke2ExecuteUninstallCommand = \_ _ ->
            pure (Left "uninstall must not run in the presence regression")
        }

firstShow :: (Show err) => Either err value -> Either Text value
firstShow = first (Text.pack . show)

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
