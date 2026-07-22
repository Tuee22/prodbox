{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Encrypted, identity-bound, fsync-ordered local journal for one gateway
-- emitter. One long-held POSIX lock plus a process-local guard excludes
-- overlapping mounts. The event-key-derived journal key is cached for the
-- session, so stage/commit writes perform no Vault, MinIO, or subprocess I/O.
module Prodbox.Gateway.Emitter.Journal
  ( JournalIdentity
  , mkJournalIdentity
  , journalIdentityDigest
  , JournalConfig
  , mkJournalConfig
  , journalRootDirectory
  , journalMaximumPayloadBytes
  , EmitterRetirementReceipt
  , mkEmitterRetirementReceipt
  , retirementNextIncarnation
  , JournalAdmission (..)
  , JournalRecovery (..)
  , JournalSession
  , journalSessionIncarnation
  , journalSessionDigest
  , journalFilePath
  , JournalWriteStep (..)
  , journalWriteProtocol
  , withEmitterJournal
  , writeJournalPayload
  , JournalError (..)
  , renderJournalError
  )
where

import Codec.Serialise
  ( Serialise
  , deserialiseOrFail
  , serialise
  )
import Control.Concurrent.MVar
  ( MVar
  , modifyMVar
  , modifyMVar_
  , newMVar
  )
import Control.Exception
  ( IOException
  , bracket
  , finally
  , mask
  , onException
  , throwIO
  , try
  )
import Crypto.Hash.SHA256 qualified as SHA256
import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16, Word64)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Crypto.Aead
  ( AeadError (..)
  , aeadNonceBytes
  , openAead
  , sealAead
  )
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , doesFileExist
  , renameFile
  )
import System.FilePath (isAbsolute, normalise, (</>))
import System.IO (SeekMode (AbsoluteSeek))
import System.IO.Error (isEOFError)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Files
  ( fileSize
  , getFdStatus
  , ownerModes
  , ownerReadMode
  , ownerWriteMode
  , setFdMode
  , setFileMode
  , unionFileModes
  )
import System.Posix.IO
  ( LockRequest (Unlock, WriteLock)
  , OpenFileFlags (..)
  , OpenMode (ReadOnly, ReadWrite, WriteOnly)
  , closeFd
  , defaultFileFlags
  , openFd
  , setLock
  )
import System.Posix.IO.ByteString qualified as PosixBS
import System.Posix.Types (Fd, FileMode)
import System.Posix.Unistd (fileSynchronise)

data JournalIdentity = JournalIdentity
  { identityCluster :: !Text
  , identityEmitter :: !Text
  , identityOrdersDigest :: !ByteString
  }
  deriving stock (Eq, Show)

mkJournalIdentity :: Text -> Text -> ByteString -> Either JournalError JournalIdentity
mkJournalIdentity cluster emitter ordersDigest = do
  cluster' <- validateIdentityText "cluster" cluster
  emitter' <- validateIdentityText "emitter" emitter
  if BS.length ordersDigest == 32
    then
      Right
        JournalIdentity
          { identityCluster = cluster'
          , identityEmitter = emitter'
          , identityOrdersDigest = ordersDigest
          }
    else Left (JournalIdentityInvalid "orders digest must be exactly 32 bytes")

validateIdentityText :: Text -> Text -> Either JournalError Text
validateIdentityText fieldName raw =
  let value = Text.strip raw
      encodedLength = BS.length (TextEncoding.encodeUtf8 value)
   in if Text.null value
        then Left (JournalIdentityInvalid (Text.unpack fieldName ++ " must not be empty"))
        else
          if encodedLength > 255
            then Left (JournalIdentityInvalid (Text.unpack fieldName ++ " exceeds the 255-byte bound"))
            else
              if Text.any (== '\NUL') value
                then Left (JournalIdentityInvalid (Text.unpack fieldName ++ " must not contain NUL"))
                else Right value

journalIdentityBytes :: JournalIdentity -> ByteString
journalIdentityBytes identity =
  BL.toStrict . Builder.toLazyByteString $
    "prodbox.gateway.emitter-journal.identity.v1"
      <> framedText (identityCluster identity)
      <> framedText (identityEmitter identity)
 where
  framedText = framedBytes . TextEncoding.encodeUtf8
  framedBytes bytes = Builder.word64BE (fromIntegral (BS.length bytes)) <> Builder.byteString bytes

journalIdentityDigest :: JournalIdentity -> ByteString
journalIdentityDigest = SHA256.hash . journalIdentityBytes

data JournalConfig = JournalConfig
  { internalJournalRoot :: !FilePath
  , internalMaximumPayloadBytes :: !Natural
  }
  deriving stock (Eq, Show)

mkJournalConfig :: FilePath -> Natural -> Either JournalError JournalConfig
mkJournalConfig root maximumPayload
  | not (isAbsolute root) = Left (JournalConfigInvalid "journal root must be absolute")
  | normalise root == "/" = Left (JournalConfigInvalid "journal root must not be the filesystem root")
  | maximumPayload == 0 = Left (JournalConfigInvalid "maximum payload bytes must be positive")
  | maximumPayload > maximumJournalPayloadForPlatform =
      Left (JournalConfigInvalid "maximum payload bytes exceed the platform read bound")
  | otherwise =
      Right
        JournalConfig
          { internalJournalRoot = normalise root
          , internalMaximumPayloadBytes = maximumPayload
          }

journalRootDirectory :: JournalConfig -> FilePath
journalRootDirectory = internalJournalRoot

journalMaximumPayloadBytes :: JournalConfig -> Natural
journalMaximumPayloadBytes = internalMaximumPayloadBytes

minimumJournalEventKeyBytes :: Natural
minimumJournalEventKeyBytes = 32

-- This conservative fixed allowance covers both CBOR structures, version and
-- identity metadata, the AEAD nonce/tag, and bounded CBOR length prefixes. It
-- is added to the configured payload bound before any journal file is read.
journalEnvelopeOverheadBytes :: Natural
journalEnvelopeOverheadBytes = 4096

maximumJournalPayloadForPlatform :: Natural
maximumJournalPayloadForPlatform =
  fromIntegral (maxBound :: Int) - journalEnvelopeOverheadBytes - 1

data EmitterRetirementReceipt = EmitterRetirementReceipt
  { retirementIdentityDigest :: !ByteString
  , retirementNextIncarnation :: !Word64
  }
  deriving stock (Eq, Show)

mkEmitterRetirementReceipt
  :: JournalIdentity
  -> Word64
  -> Either JournalError EmitterRetirementReceipt
mkEmitterRetirementReceipt identity previousIncarnation
  | previousIncarnation == maxBound = Left JournalIncarnationExhausted
  | otherwise =
      Right
        EmitterRetirementReceipt
          { retirementIdentityDigest = journalIdentityDigest identity
          , retirementNextIncarnation = previousIncarnation + 1
          }

data JournalAdmission
  = FirstEmitterAdmission
  | ExistingEmitterAdmission
  | RetiredEmitterAdmission !EmitterRetirementReceipt
  deriving stock (Eq, Show)

data JournalRecovery
  = JournalInitialized
  | JournalRecovered !ByteString
  | -- | Prior authenticated Orders digest and exact durable projection. The
    -- daemon must migrate that projection and fsync an epoch invalidation under
    -- current Orders before it may become ready.
    JournalOrdersMigrationRequired !ByteString !ByteString
  deriving stock (Eq, Show)

data JournalSession = JournalSession
  { sessionConfig :: !JournalConfig
  , sessionIdentity :: !JournalIdentity
  , sessionKey :: !ByteString
  , journalSessionIncarnation :: !Word64
  , sessionDigestRef :: !(IORef ByteString)
  , sessionWriteGuard :: !(MVar ())
  }

journalSessionDigest :: JournalSession -> IO ByteString
journalSessionDigest = readIORef . sessionDigestRef

journalFilePath :: JournalConfig -> FilePath
journalFilePath config = journalRootDirectory config </> "emitter.journal.enc"

journalTemporaryPath :: JournalConfig -> FilePath
journalTemporaryPath config = journalRootDirectory config </> ".emitter.journal.tmp"

data JournalWriteStep
  = WriteEncryptedTemporary
  | FsyncEncryptedTemporary
  | RenameJournal
  | FsyncJournalDirectory
  deriving stock (Eq, Show, Enum, Bounded)

journalWriteProtocol :: [JournalWriteStep]
journalWriteProtocol =
  [ WriteEncryptedTemporary
  , FsyncEncryptedTemporary
  , RenameJournal
  , FsyncJournalDirectory
  ]

data PersistedJournal = PersistedJournal
  { persistedFormat :: !Word16
  , persistedIdentityDigest :: !ByteString
  , persistedOrdersDigest :: !ByteString
  , persistedIncarnation :: !Word64
  , persistedPayload :: !ByteString
  }
  deriving stock (Eq, Show, Generic)

instance Serialise PersistedJournal

data JournalEnvelope = JournalEnvelope
  { envelopeFormat :: !Word16
  , envelopeNonce :: !ByteString
  , envelopeCiphertext :: !ByteString
  }
  deriving stock (Eq, Show, Generic)

instance Serialise JournalEnvelope

journalFormatVersion :: Word16
journalFormatVersion = 2

deriveJournalKey :: ByteString -> JournalIdentity -> ByteString
deriveJournalKey eventKey identity =
  SHA256.hmac
    eventKey
    ("prodbox.gateway.emitter-journal.key.v1\NUL" <> journalIdentityBytes identity)

journalAad :: JournalIdentity -> ByteString
journalAad identity =
  "prodbox.gateway.emitter-journal.aad.v1\NUL" <> journalIdentityBytes identity

withEmitterJournal
  :: JournalConfig
  -> JournalIdentity
  -> JournalAdmission
  -> ByteString
  -> (JournalSession -> JournalRecovery -> IO result)
  -> IO (Either JournalError result)
withEmitterJournal config identity admission eventKey action
  | BS.null eventKey = pure (Left JournalEventKeyEmpty)
  | fromIntegral (BS.length eventKey) < minimumJournalEventKeyBytes =
      pure
        ( Left
            ( JournalEventKeyTooShort
                (fromIntegral (BS.length eventKey))
                minimumJournalEventKeyBytes
            )
        )
  | otherwise = do
      rootResult <- prepareJournalRoot config
      case rootResult of
        Left err -> pure (Left err)
        Right preparedConfig ->
          mask $ \restore -> do
            -- Keep asynchronous cancellation masked from process-lock
            -- acquisition until the release finalizer is installed. The
            -- caller action itself runs restored and remains cancellable.
            lockResult <- acquireJournalLock preparedConfig
            case lockResult of
              Left err -> pure (Left err)
              Right heldLock ->
                restore
                  ( do
                      opened <- openJournal preparedConfig identity admission eventKey
                      case opened of
                        Left err -> pure (Left err)
                        Right (session, recovery) -> Right <$> action session recovery
                  )
                  `finally` releaseJournalLock heldLock

prepareJournalRoot :: JournalConfig -> IO (Either JournalError JournalConfig)
prepareJournalRoot config = do
  -- Resolve every existing symlink prefix before creating or chmodding
  -- anything. This prevents a path such as @alias-to-root/new-directory@ from
  -- causing a write through the alias before its actual target is checked.
  initialCanonical <- try (canonicalizePath (journalRootDirectory config))
  case initialCanonical of
    Left (err :: IOException) -> pure (Left (JournalIoFailure (show err)))
    Right canonicalCandidate
      | normalise canonicalCandidate == "/" ->
          pure (Left (JournalConfigInvalid "journal root resolves to the filesystem root"))
      | otherwise -> do
          created <- try (createDirectoryIfMissing True canonicalCandidate)
          case created of
            Left (err :: IOException) -> pure (Left (JournalIoFailure (show err)))
            Right () -> finalizeCanonicalRoot canonicalCandidate
 where
  finalizeCanonicalRoot canonicalCandidate = do
    canonicalResult <- try (canonicalizePath canonicalCandidate)
    case canonicalResult of
      Left (err :: IOException) -> pure (Left (JournalIoFailure (show err)))
      Right canonicalRoot
        | normalise canonicalRoot == "/" ->
            pure (Left (JournalConfigInvalid "journal root resolves to the filesystem root"))
        | otherwise -> do
            modeResult <- try (setFileMode canonicalRoot ownerModes)
            pure $ case modeResult of
              Left (err :: IOException) -> Left (JournalIoFailure (show err))
              Right () ->
                Right config {internalJournalRoot = normalise canonicalRoot}

data HeldJournalLock = HeldJournalLock
  { heldLockPath :: !FilePath
  , heldLockFd :: !Fd
  }

{-# NOINLINE processJournalLocks #-}
processJournalLocks :: MVar (Set FilePath)
processJournalLocks = unsafePerformIO (newMVar Set.empty)

-- Journal and lock files contain encrypted state but are not executable. Keep
-- their mode distinct from the containing directory's owner-only @0700@ mode.
ownerFileModes :: FileMode
ownerFileModes = unionFileModes ownerReadMode ownerWriteMode

acquireJournalLock :: JournalConfig -> IO (Either JournalError HeldJournalLock)
acquireJournalLock config = do
  canonicalResult <- try (canonicalizePath (journalRootDirectory config))
  case canonicalResult of
    Left (err :: IOException) -> pure (Left (JournalIoFailure (show err)))
    Right canonicalRoot -> do
      -- Canonicalizing the directory makes path aliases (including a symlinked
      -- mount root) share one process-local identity and one POSIX lock file.
      let canonicalLockPath = canonicalRoot </> ".emitter.journal.lock"
      locallyAcquired <-
        modifyMVar processJournalLocks $ \held ->
          if Set.member canonicalLockPath held
            then pure (held, False)
            else pure (Set.insert canonicalLockPath held, True)
      if not locallyAcquired
        then pure (Left JournalAlreadyLocked)
        else do
          opened <-
            try
              ( ( openFd
                    canonicalLockPath
                    ReadWrite
                    defaultFileFlags
                      { creat = Just ownerFileModes
                      , nofollow = True
                      , cloexec = True
                      }
                )
                  `onException` releaseProcessLock canonicalLockPath
              )
          case opened of
            Left (err :: IOException) -> pure (Left (JournalIoFailure (show err)))
            Right fd -> do
              secured <-
                try
                  ( setFdMode fd ownerFileModes
                      `onException` cleanupJournalLockAcquisition canonicalLockPath fd
                  )
              case secured of
                Left (err :: IOException) -> pure (Left (JournalIoFailure (show err)))
                Right () -> do
                  locked <-
                    try
                      ( setLock fd (WriteLock, AbsoluteSeek, 0, 0)
                          `onException` cleanupJournalLockAcquisition canonicalLockPath fd
                      )
                  case locked of
                    Left (_ :: IOException) -> pure (Left JournalAlreadyLocked)
                    Right () -> pure (Right (HeldJournalLock canonicalLockPath fd))

releaseJournalLock :: HeldJournalLock -> IO ()
releaseJournalLock held =
  ( do
      _ <- try (setLock (heldLockFd held) (Unlock, AbsoluteSeek, 0, 0)) :: IO (Either IOException ())
      pure ()
  )
    `finally` (safeCloseFd (heldLockFd held) `finally` releaseProcessLock (heldLockPath held))

cleanupJournalLockAcquisition :: FilePath -> Fd -> IO ()
cleanupJournalLockAcquisition path fd =
  safeCloseFd fd `finally` releaseProcessLock path

releaseProcessLock :: FilePath -> IO ()
releaseProcessLock path =
  modifyMVar_ processJournalLocks (pure . Set.delete path)

safeCloseFd :: Fd -> IO ()
safeCloseFd fd = do
  _ <- try (closeFd fd) :: IO (Either IOException ())
  pure ()

openJournal
  :: JournalConfig
  -> JournalIdentity
  -> JournalAdmission
  -> ByteString
  -> IO (Either JournalError (JournalSession, JournalRecovery))
openJournal config identity admission eventKey = do
  exists <- doesFileExist (journalFilePath config)
  if exists
    then case admission of
      FirstEmitterAdmission -> pure (Left JournalAlreadyExists)
      RetiredEmitterAdmission _ -> pure (Left JournalRetirementConflictsWithExistingJournal)
      ExistingEmitterAdmission -> recoverExisting
    else case admission of
      ExistingEmitterAdmission -> pure (Left JournalMissingRequiresRetirement)
      FirstEmitterAdmission -> initializeAt 1
      RetiredEmitterAdmission receipt
        | retirementIdentityDigest receipt /= journalIdentityDigest identity ->
            pure (Left JournalRetirementIdentityMismatch)
        | otherwise -> initializeAt (retirementNextIncarnation receipt)
 where
  key = deriveJournalKey eventKey identity

  recoverExisting = do
    loaded <- loadPersistedJournal config identity key
    case loaded of
      Left err -> pure (Left err)
      Right persisted
        | persistedIncarnation persisted == maxBound -> pure (Left JournalIncarnationExhausted)
        | otherwise -> do
            let nextIncarnation = persistedIncarnation persisted + 1
                bumped = persisted {persistedIncarnation = nextIncarnation}
            written <- persistJournal config identity key bumped
            case written of
              Left err -> pure (Left err)
              Right digest -> do
                digestRef <- newIORef digest
                writeGuard <- newMVar ()
                let recovery =
                      journalRecoveryFor identity persisted
                pure
                  ( Right
                      ( JournalSession
                          { sessionConfig = config
                          , sessionIdentity = identity
                          , sessionKey = key
                          , journalSessionIncarnation = nextIncarnation
                          , sessionDigestRef = digestRef
                          , sessionWriteGuard = writeGuard
                          }
                      , recovery
                      )
                  )

  initializeAt incarnation = do
    written <-
      persistJournal
        config
        identity
        key
        PersistedJournal
          { persistedFormat = journalFormatVersion
          , persistedIdentityDigest = journalIdentityDigest identity
          , persistedOrdersDigest = identityOrdersDigest identity
          , persistedIncarnation = incarnation
          , persistedPayload = BS.empty
          }
    case written of
      Left err -> pure (Left err)
      Right digest -> do
        digestRef <- newIORef digest
        writeGuard <- newMVar ()
        pure
          ( Right
              ( JournalSession
                  { sessionConfig = config
                  , sessionIdentity = identity
                  , sessionKey = key
                  , journalSessionIncarnation = incarnation
                  , sessionDigestRef = digestRef
                  , sessionWriteGuard = writeGuard
                  }
              , JournalInitialized
              )
          )

journalRecoveryFor :: JournalIdentity -> PersistedJournal -> JournalRecovery
journalRecoveryFor identity persisted
  | persistedOrdersDigest persisted /= identityOrdersDigest identity =
      JournalOrdersMigrationRequired
        (persistedOrdersDigest persisted)
        (persistedPayload persisted)
  | BS.null (persistedPayload persisted) = JournalInitialized
  | otherwise = JournalRecovered (persistedPayload persisted)

writeJournalPayload :: JournalSession -> ByteString -> IO (Either JournalError ())
writeJournalPayload session payload
  | fromIntegral (BS.length payload) > journalMaximumPayloadBytes (sessionConfig session) =
      pure
        ( Left
            ( JournalPayloadTooLarge
                (fromIntegral (BS.length payload))
                (journalMaximumPayloadBytes (sessionConfig session))
            )
        )
  | otherwise = do
      -- The session guard serializes the shared temporary path. Keeping the
      -- transaction masked ensures a successful rename and its digest become
      -- visible together before cancellation is observed.
      mask $ \_ ->
        modifyMVar (sessionWriteGuard session) $ \() -> do
          written <-
            persistJournal
              (sessionConfig session)
              (sessionIdentity session)
              (sessionKey session)
              PersistedJournal
                { persistedFormat = journalFormatVersion
                , persistedIdentityDigest = journalIdentityDigest (sessionIdentity session)
                , persistedOrdersDigest = identityOrdersDigest (sessionIdentity session)
                , persistedIncarnation = journalSessionIncarnation session
                , persistedPayload = payload
                }
          case written of
            Left err -> pure ((), Left err)
            Right digest -> do
              writeIORef (sessionDigestRef session) digest
              pure ((), Right ())

loadPersistedJournal
  :: JournalConfig
  -> JournalIdentity
  -> ByteString
  -> IO (Either JournalError PersistedJournal)
loadPersistedJournal config identity key = do
  readResult <- boundedReadJournal config
  pure $ do
    bytes <- readResult
    envelope <- decodeCbor "journal envelope" bytes
    if envelopeFormat envelope /= journalFormatVersion
      then Left (JournalDecodeFailure "unsupported journal envelope format")
      else Right ()
    if BS.length (envelopeNonce envelope) /= aeadNonceBytes
      then Left (JournalDecodeFailure "journal envelope nonce has the wrong length")
      else Right ()
    plaintext <-
      case openAead key (envelopeNonce envelope) (journalAad identity) (envelopeCiphertext envelope) of
        Left AeadAuthenticationFailed -> Left JournalAuthenticationFailed
        Left (AeadCipherFailed err) -> Left (JournalCryptoFailure (show err))
        Right value -> Right value
    persisted <- decodeCbor "journal payload" plaintext
    if persistedFormat persisted /= journalFormatVersion
      then Left (JournalDecodeFailure "unsupported journal payload format")
      else Right ()
    if persistedIdentityDigest persisted /= journalIdentityDigest identity
      then Left JournalIdentityMismatch
      else Right ()
    if BS.length (persistedOrdersDigest persisted) /= 32
      then Left (JournalDecodeFailure "journal Orders digest has the wrong length")
      else Right ()
    let payloadBytes = fromIntegral (BS.length (persistedPayload persisted))
    if payloadBytes > journalMaximumPayloadBytes config
      then
        Left
          ( JournalPayloadTooLarge
              payloadBytes
              (journalMaximumPayloadBytes config)
          )
      else Right persisted

boundedReadJournal :: JournalConfig -> IO (Either JournalError ByteString)
boundedReadJournal config = do
  result <-
    try $
      bracket
        ( openFd
            (journalFilePath config)
            ReadOnly
            defaultFileFlags {nofollow = True, cloexec = True}
        )
        safeCloseFd
        ( \fd -> do
            status <- getFdStatus fd
            let maximumEncoded = journalMaximumPayloadBytes config + journalEnvelopeOverheadBytes
                observedSize = toNaturalSize (fileSize status)
            case observedSize of
              Nothing -> pure (Left (JournalIoFailure "journal file reported a negative size"))
              Just actual
                | actual > maximumEncoded ->
                    pure (Left (JournalEncodedTooLarge actual maximumEncoded))
                | otherwise -> do
                    bytes <- readFdBounded fd (fromIntegral maximumEncoded + 1)
                    let actualRead = fromIntegral (BS.length bytes)
                    pure $
                      if actualRead > maximumEncoded
                        then Left (JournalEncodedTooLarge actualRead maximumEncoded)
                        else Right bytes
        )
  pure $
    either
      (Left . JournalIoFailure . show)
      id
      (result :: Either IOException (Either JournalError ByteString))

toNaturalSize :: (Integral size) => size -> Maybe Natural
toNaturalSize raw
  | toInteger raw < 0 = Nothing
  | otherwise = Just (fromInteger (toInteger raw))

readFdBounded :: Fd -> Int -> IO ByteString
readFdBounded fd maximumBytes = go maximumBytes []
 where
  go :: Int -> [ByteString] -> IO ByteString
  go remaining chunks
    | remaining <= 0 = pure (BS.concat (reverse chunks))
    | otherwise = do
        readResult <-
          try (PosixBS.fdRead fd (fromIntegral (min remaining (64 * 1024))))
        case readResult of
          Left (err :: IOException)
            | isEOFError err -> pure (BS.concat (reverse chunks))
            | otherwise -> throwIO err
          Right chunk
            | BS.null chunk -> pure (BS.concat (reverse chunks))
            | otherwise -> go (remaining - BS.length chunk) (chunk : chunks)

decodeCbor :: (Serialise value) => String -> ByteString -> Either JournalError value
decodeCbor label bytes =
  case deserialiseOrFail (BL.fromStrict bytes) of
    Left err -> Left (JournalDecodeFailure (label ++ ": " ++ show err))
    Right value -> Right value

persistJournal
  :: JournalConfig
  -> JournalIdentity
  -> ByteString
  -> PersistedJournal
  -> IO (Either JournalError ByteString)
persistJournal config identity key persisted
  | fromIntegral (BS.length (persistedPayload persisted)) > journalMaximumPayloadBytes config =
      pure
        ( Left
            ( JournalPayloadTooLarge
                (fromIntegral (BS.length (persistedPayload persisted)))
                (journalMaximumPayloadBytes config)
            )
        )
  | otherwise = do
      nonce <- getRandomBytes aeadNonceBytes
      let plaintext = BL.toStrict (serialise persisted)
      case sealAead key nonce (journalAad identity) plaintext of
        Left AeadAuthenticationFailed -> pure (Left JournalAuthenticationFailed)
        Left (AeadCipherFailed err) -> pure (Left (JournalCryptoFailure (show err)))
        Right ciphertext -> do
          let encoded =
                BL.toStrict . serialise $
                  JournalEnvelope
                    { envelopeFormat = journalFormatVersion
                    , envelopeNonce = nonce
                    , envelopeCiphertext = ciphertext
                    }
              encodedBytes = fromIntegral (BS.length encoded)
              maximumEncoded = journalMaximumPayloadBytes config + journalEnvelopeOverheadBytes
          if encodedBytes > maximumEncoded
            then pure (Left (JournalEncodedTooLarge encodedBytes maximumEncoded))
            else do
              written <- atomicWriteJournal config encoded
              pure (SHA256.hash encoded <$ written)

atomicWriteJournal :: JournalConfig -> ByteString -> IO (Either JournalError ())
atomicWriteJournal config bytes = do
  result <- try $ do
    let temporary = journalTemporaryPath config
        final = journalFilePath config
    bracket
      ( openFd
          temporary
          WriteOnly
          defaultFileFlags
            { trunc = True
            , creat = Just ownerFileModes
            , nofollow = True
            , cloexec = True
            }
      )
      safeCloseFd
      ( \fd -> do
          setFdMode fd ownerFileModes
          writeAll fd bytes
          fileSynchronise fd
      )
    renameFile temporary final
    bracket
      ( openFd
          (journalRootDirectory config)
          ReadOnly
          defaultFileFlags {directory = True, nofollow = True, cloexec = True}
      )
      safeCloseFd
      fileSynchronise
  pure (either (Left . JournalIoFailure . show) Right (result :: Either IOException ()))

writeAll :: Fd -> ByteString -> IO ()
writeAll _ bytes | BS.null bytes = pure ()
writeAll fd bytes = do
  written <- PosixBS.fdWrite fd bytes
  let count = fromIntegral written
  if count <= 0
    then fail "journal write made no progress"
    else writeAll fd (BS.drop count bytes)

data JournalError
  = JournalIdentityInvalid !String
  | JournalConfigInvalid !String
  | JournalEventKeyEmpty
  | JournalEventKeyTooShort !Natural !Natural
  | JournalAlreadyLocked
  | JournalAlreadyExists
  | JournalMissingRequiresRetirement
  | JournalRetirementIdentityMismatch
  | JournalRetirementConflictsWithExistingJournal
  | JournalIncarnationExhausted
  | JournalPayloadTooLarge !Natural !Natural
  | JournalEncodedTooLarge !Natural !Natural
  | JournalAuthenticationFailed
  | JournalIdentityMismatch
  | JournalCryptoFailure !String
  | JournalDecodeFailure !String
  | JournalIoFailure !String
  deriving stock (Eq, Show)

renderJournalError :: JournalError -> String
renderJournalError err = case err of
  JournalIdentityInvalid detail -> "journal identity invalid: " ++ detail
  JournalConfigInvalid detail -> "journal config invalid: " ++ detail
  JournalEventKeyEmpty -> "journal event key must not be empty"
  JournalEventKeyTooShort actual minimumBytes ->
    "journal event key is too short: " ++ show actual ++ " bytes; minimum " ++ show minimumBytes
  JournalAlreadyLocked -> "journal is already locked by another emitter incarnation"
  JournalAlreadyExists -> "first admission refused because the emitter journal already exists"
  JournalMissingRequiresRetirement ->
    "admitted emitter journal is missing; an indexed retirement receipt is required"
  JournalRetirementIdentityMismatch -> "emitter retirement receipt identity mismatch"
  JournalRetirementConflictsWithExistingJournal ->
    "emitter retirement receipt refused because the old journal still exists"
  JournalIncarnationExhausted -> "emitter incarnation counter exhausted"
  JournalPayloadTooLarge actual allowed ->
    "journal payload exceeds bound: " ++ show actual ++ " > " ++ show allowed
  JournalEncodedTooLarge actual allowed ->
    "encoded journal exceeds bound: " ++ show actual ++ " > " ++ show allowed
  JournalAuthenticationFailed -> "journal authentication failed"
  JournalIdentityMismatch -> "journal identity does not match this emitter mount"
  JournalCryptoFailure detail -> "journal cryptography failed: " ++ detail
  JournalDecodeFailure detail -> "journal decode failed: " ++ detail
  JournalIoFailure detail -> "journal I/O failed: " ++ detail
