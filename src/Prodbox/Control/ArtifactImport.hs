{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Bounded, resumable ingress of a declared non-secret bootstrap artifact.
module Prodbox.Control.ArtifactImport
  ( BootstrapArtifact (..)
  , ArtifactImportResult (..)
  , ArtifactDiscardResult (..)
  , importBootstrapArtifact
  , discardBootstrapArtifactStaging
  ) where

import Control.Exception (IOException, bracket, mask, onException, throwIO, try)
import Control.Monad (unless, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CUInt (..))
import Numeric (showHex)
import Prodbox.Config.BootstrapProjection
  ( ArtifactDeclaration (..)
  , BootstrapProjection
  , bootstrapKindTool
  , bootstrapNodeArtifact
  , bootstrapRootGeneration
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope
  ( HeldArtifactResult (..)
  , ScopeArtifactObservation (..)
  , ScopeGenerationObservation (ScopeGenerationMatches)
  , observeScopeArtifact
  , observeScopeGeneration
  , validArtifactDeclaration
  , withScopeRootDescriptor
  , withVerifiedScopeArtifact
  )
import Prodbox.Control.KindLease (KindLeaseOutcome (..), withKindLease)
import System.FilePath (isAbsolute, normalise, splitDirectories, takeFileName)
import System.IO (SeekMode (AbsoluteSeek))
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError, isEOFError)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , fileMode
  , fileOwner
  , fileSize
  , getFdStatus
  , isDirectory
  , isRegularFile
  , linkCount
  , modificationTimeHiRes
  , statusChangeTimeHiRes
  )
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (CMode (..), Fd (..), UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

foreign import capi "sys/stat.h mkdirat" mkdirAt :: CInt -> CString -> CMode -> IO CInt
foreign import capi "stdio.h renameat2"
  renameAt2 :: CInt -> CString -> CInt -> CString -> CUInt -> IO CInt
foreign import capi "stdio.h value RENAME_NOREPLACE" noReplace :: CUInt
foreign import capi "unistd.h unlinkat" unlinkAt :: CInt -> CString -> CInt -> IO CInt

data BootstrapArtifact = BootstrapKindTool | BootstrapNodeArchive deriving (Eq, Show)
data ArtifactImportResult
  = ArtifactImported
  | ArtifactAlreadyPresent
  | ArtifactNotDeclared
  | ArtifactSourceUnsafe
  | ArtifactSourceMismatch
  | ArtifactDestinationConflict
  | ArtifactPendingConflict
  | ArtifactImportRefused
  | ArtifactImportIncomplete
  deriving (Eq, Show)

data ArtifactDiscardResult
  = ArtifactStagingDiscarded
  | ArtifactStagingNotObserved
  | ArtifactStagingDiscardRefused
  | ArtifactStagingDiscardIncomplete
  deriving (Eq, Show)

-- | The source is read and hashed before a pending file is created. A retry may
-- append only after proving the existing pending bytes are the exact source
-- prefix. Existing destination bytes are never replaced. Incomplete work is
-- retained under the selected root for an exact retry.
importBootstrapArtifact
  :: BootstrapProjection -> BootstrapArtifact -> FilePath -> IO ArtifactImportResult
importBootstrapArtifact bootstrap role source = case declaration of
  Nothing -> pure ArtifactNotDeclared
  Just artifact
    | not
        ( validArtifactDeclaration
            (artifactPath artifact)
            (artifactDigest artifact)
            (artifactMaximumBytes artifact)
        ) ->
        pure ArtifactImportRefused
    | not (isAbsolute source) || normalise source /= source || takeFileName source == "test-secrets.dhall" ->
        pure ArtifactSourceUnsafe
    | otherwise -> do
        touched <- newIORef False
        result <- timeout 180000000 $ try @IOException $ withKindLease bootstrap $ \recheck ->
          importWithin touched artifact recheck
        changed <- readIORef touched
        pure $ case result of
          Just (Right (Right (KindLeaseCompleted outcome))) -> outcome
          _ | changed -> ArtifactImportIncomplete
          _ -> ArtifactImportRefused
 where
  declaration = case role of
    BootstrapKindTool -> bootstrapKindTool bootstrap
    BootstrapNodeArchive -> bootstrapNodeArtifact bootstrap
  scope = bootstrapScope bootstrap
  generation = Text.unpack (bootstrapRootGeneration bootstrap)
  readFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
  directoryFlags = readFlags {Posix.directory = True}
  importWithin touched artifact recheck = do
    opened <- try @IOException (Posix.openFd source Posix.ReadOnly readFlags)
    case opened of
      Left _ -> pure ArtifactSourceUnsafe
      Right sourceFd -> bracket (pure sourceFd) Posix.closeFd $ \input -> do
        owner <- getEffectiveUserID
        initial <- getFdStatus input
        if not (safeSource owner initial) || toInteger (fileSize initial) > artifactMaximumBytes artifact
          then pure ArtifactSourceUnsafe
          else do
            sourceHash <- hashFile input (artifactMaximumBytes artifact)
            afterHash <- getFdStatus input
            if sourceHash /= Just (artifactDigest artifact, toInteger (fileSize initial))
              || not (sameVersion initial afterHash)
              then pure ArtifactSourceMismatch
              else do
                checked <- withScopeRootDescriptor scope $ \root sameRoot -> do
                  let stable = do
                        a <- sameRoot
                        b <- recheck
                        c <- observeScopeGeneration scope generation
                        pure (a && b && c == Right ScopeGenerationMatches)
                  ready <- stable
                  if not ready
                    then pure ArtifactImportRefused
                    else do
                      current <-
                        observeScopeArtifact
                          scope
                          (artifactPath artifact)
                          (artifactDigest artifact)
                          (artifactMaximumBytes artifact)
                      case current of
                        Right (ScopeArtifactDigestMatches _) -> do
                          pending <- pendingExists owner root artifact
                          usable <- artifactUsable artifact
                          pure $
                            if not usable
                              then ArtifactDestinationConflict
                              else if pending == Just False then ArtifactAlreadyPresent else ArtifactImportIncomplete
                        Right ScopeArtifactMissing -> withStaging touched stable owner root $ \stage -> do
                          quarantined <- namedPresent stage (".discard-" ++ pendingName artifact) readFlags
                          if quarantined
                            then pure ArtifactImportIncomplete
                            else withDestination touched stable owner root (init (splitDirectories (artifactPath artifact))) $ \parent ->
                              copyAndPublish
                                touched
                                owner
                                artifact
                                input
                                initial
                                stage
                                parent
                                (last (splitDirectories (artifactPath artifact)))
                                stable
                        Right _ -> pure ArtifactDestinationConflict
                        Left _ -> pure ArtifactImportRefused
                pure (either (const ArtifactImportRefused) id checked)
  pendingName = artifactPendingName role
  artifactUsable artifact = do
    observed <- withVerifiedScopeArtifact
      scope
      (artifactPath artifact)
      (artifactDigest artifact)
      (artifactMaximumBytes artifact)
      $ \fd stable -> do
        status <- getFdStatus fd
        current <- stable
        pure (current && (role /= BootstrapKindTool || fileMode status .&. 0o100 /= 0))
    pure $ case observed of
      Right (HeldArtifactObserved True True) -> True
      _ -> False
  pendingExists owner root artifact = do
    result <- try @IOException $ bracket (Posix.openFdAt (Just root) ".prodbox-import" Posix.ReadOnly directoryFlags) Posix.closeFd $ \stage -> do
      status <- getFdStatus stage
      unless (safeDirectory owner status) (ioError (userError "unsafe artifact staging"))
      pending <- namedPresent stage (pendingName artifact) readFlags
      quarantined <- namedPresent stage (".discard-" ++ pendingName artifact) readFlags
      pure (pending || quarantined)
    pure $ case result of
      Left e | isDoesNotExistError e -> Just False
      Left _ -> Nothing
      Right present -> Just present
  withStaging touched stable owner root action = do
    ensureDirectory touched stable root ".prodbox-import"
    bracket (Posix.openFdAt (Just root) ".prodbox-import" Posix.ReadOnly directoryFlags) Posix.closeFd $ \stage -> do
      status <- getFdStatus stage
      unless (safeDirectory owner status) (ioError (userError "unsafe artifact staging"))
      action stage
  withDestination touched stable owner root parts action = walk root parts
   where
    walk parent [] = action parent
    walk parent (part : rest) = do
      ensureDirectory touched stable parent part
      bracket (Posix.openFdAt (Just parent) part Posix.ReadOnly directoryFlags) Posix.closeFd $ \child -> do
        status <- getFdStatus child
        unless (safeDirectory owner status) (ioError (userError "unsafe artifact parent"))
        walk child rest
  ensureDirectory touched stable parent name = mask $ \_ -> do
    ready <- stable
    unless ready (ioError (userError "artifact root changed"))
    made <- try @IOException $ withCString name $ \bytes -> throwErrnoIfMinus1_ "mkdir artifact directory" (mkdirAt (rawFd parent) bytes 0o700)
    case made of
      Left e | isAlreadyExistsError e -> pure ()
      Left e -> throwIO e
      Right () -> writeIORef touched True >> fileSynchronise parent
  copyAndPublish touched owner artifact input initial stage parent name stable = do
    let pending = pendingName artifact
        mode = case role of BootstrapKindTool -> 0o700; BootstrapNodeArchive -> 0o600
        createFlags = readFlags {Posix.exclusive = True, Posix.creat = Just mode}
    mask $ \restore -> do
      ready <- stable
      unless ready (ioError (userError "artifact root changed"))
      created <- try @IOException (Posix.openFdAt (Just stage) pending Posix.ReadWrite createFlags)
      file <- case created of
        Right fd -> (writeIORef touched True >> fileSynchronise stage >> pure fd) `onException` Posix.closeFd fd
        Left e | isAlreadyExistsError e -> Posix.openFdAt (Just stage) pending Posix.ReadWrite readFlags
        Left e -> throwIO e
      bracket (pure file) Posix.closeFd $ \output -> restore $ do
        start <- getFdStatus output
        if not (safePending owner mode start) || fileSize start > fileSize initial
          then pure ArtifactPendingConflict
          else do
            prefix <- verifyPrefix input output (toInteger (fileSize start))
            if not prefix
              then pure ArtifactPendingConflict
              else do
                writeIORef touched True
                copied <- appendRemaining input output (artifactMaximumBytes artifact) (toInteger (fileSize start))
                fileSynchronise output
                fileSynchronise stage
                final <- getFdStatus output
                sourceFinal <- getFdStatus input
                contents <- hashFile output (artifactMaximumBytes artifact)
                named <-
                  bracket (Posix.openFdAt (Just stage) pending Posix.ReadOnly readFlags) Posix.closeFd getFdStatus
                readyToPublish <- stable
                quarantined <- namedPresent stage (".discard-" ++ pending) readFlags
                if not
                  ( copied
                      && readyToPublish
                      && not quarantined
                      && sameVersion initial sourceFinal
                      && sameVersion final named
                      && safePending owner mode final
                      && contents == Just (artifactDigest artifact, toInteger (fileSize initial))
                  )
                  then pure ArtifactImportIncomplete
                  else do
                    withCString pending $ \old -> withCString name $ \new ->
                      throwErrnoIfMinus1_ "publish artifact" (renameAt2 (rawFd stage) old (rawFd parent) new noReplace)
                    fileSynchronise stage
                    fileSynchronise parent
                    finalStable <- stable
                    observed <-
                      observeScopeArtifact
                        scope
                        (artifactPath artifact)
                        (artifactDigest artifact)
                        (artifactMaximumBytes artifact)
                    usable <- artifactUsable artifact
                    quarantineAfter <- namedPresent stage (".discard-" ++ pending) readFlags
                    pure $
                      if finalStable
                        && usable
                        && not quarantineAfter
                        && observed == Right (ScopeArtifactDigestMatches (toInteger (fileSize initial)))
                        then ArtifactImported
                        else ArtifactImportIncomplete

rawFd :: Fd -> CInt
rawFd (Fd n) = n
safeDirectory :: UserID -> FileStatus -> Bool
safeDirectory owner status = isDirectory status && fileOwner status == owner && fileMode status .&. 0o022 == 0
safeSource :: UserID -> FileStatus -> Bool
safeSource owner status =
  isRegularFile status
    && fileOwner status `elem` [owner, 0]
    && linkCount status == 1
    && fileMode status .&. 0o022 == 0
safePending :: UserID -> CMode -> FileStatus -> Bool
safePending owner mode status =
  isRegularFile status
    && fileOwner status == owner
    && linkCount status == 1
    && fileMode status .&. 0o777 == mode
sameVersion :: FileStatus -> FileStatus -> Bool
sameVersion a b =
  deviceID a == deviceID b
    && fileID a == fileID b
    && fileOwner a == fileOwner b
    && fileMode a == fileMode b
    && linkCount a == linkCount b
    && fileSize a == fileSize b
    && modificationTimeHiRes a == modificationTimeHiRes b
    && statusChangeTimeHiRes a == statusChangeTimeHiRes b

-- A rename may update ctime even when the inode and contents are unchanged.
sameRenamedVersion :: FileStatus -> FileStatus -> Bool
sameRenamedVersion a b =
  deviceID a == deviceID b
    && fileID a == fileID b
    && fileOwner a == fileOwner b
    && fileMode a == fileMode b
    && linkCount a == linkCount b
    && fileSize a == fileSize b
    && modificationTimeHiRes a == modificationTimeHiRes b
readChunk :: Fd -> Int -> IO BS.ByteString
readChunk fd size = do
  value <- try @IOException (PosixBytes.fdRead fd (fromIntegral size))
  case value of Left e | isEOFError e -> pure BS.empty; Left e -> throwIO e; Right bytes -> pure bytes
writeAll :: Fd -> BS.ByteString -> IO ()
writeAll fd bytes = unless (BS.null bytes) $ do
  count <- PosixBytes.fdWrite fd bytes
  when (count <= 0) (ioError (userError "short artifact write"))
  writeAll fd (BS.drop (fromIntegral count) bytes)
hashFile :: Fd -> Integer -> IO (Maybe (String, Integer))
hashFile fd limit = do
  _ <- Posix.fdSeek fd AbsoluteSeek 0
  let go total context = do
        bytes <- readChunk fd (fromIntegral (min 65536 (limit - total + 1)))
        if BS.null bytes
          then pure (Just ("sha256:" ++ concatMap hexByte (BS.unpack (SHA256.finalize context)), total))
          else
            if total + toInteger (BS.length bytes) > limit
              then pure Nothing
              else
                let next = SHA256.update context bytes in next `seq` go (total + toInteger (BS.length bytes)) next
      hexByte byte = let value = showHex byte "" in if length value == 1 then '0' : value else value
  go 0 SHA256.init
verifyPrefix :: Fd -> Fd -> Integer -> IO Bool
verifyPrefix input output count = do
  _ <- Posix.fdSeek input AbsoluteSeek 0
  _ <- Posix.fdSeek output AbsoluteSeek 0
  let go remaining | remaining == 0 = pure True
      go remaining = do
        let size = fromIntegral (min 65536 remaining)
        a <- readChunk input size
        b <- readChunk output size
        if BS.null a || a /= b then pure False else go (remaining - toInteger (BS.length a))
  go count
appendRemaining :: Fd -> Fd -> Integer -> Integer -> IO Bool
appendRemaining input output limit total = do
  bytes <- readChunk input (fromIntegral (min 65536 (limit - total + 1)))
  if BS.null bytes
    then pure True
    else
      if total + toInteger (BS.length bytes) > limit
        then pure False
        else
          writeAll output bytes >> appendRemaining input output limit (total + toInteger (BS.length bytes))

-- | Explicitly discard only this declaration's private staging file. A
-- deterministic quarantine name preserves an interrupted rename for retry.
-- The selected root and cooperating lease remain held throughout.
discardBootstrapArtifactStaging
  :: BootstrapProjection -> BootstrapArtifact -> IO ArtifactDiscardResult
discardBootstrapArtifactStaging bootstrap role = case declaration of
  Nothing -> pure ArtifactStagingDiscardRefused
  Just artifact
    | not
        ( validArtifactDeclaration
            (artifactPath artifact)
            (artifactDigest artifact)
            (artifactMaximumBytes artifact)
        ) ->
        pure ArtifactStagingDiscardRefused
    | otherwise -> do
        touched <- newIORef False
        outcome <- timeout 10000000 $ try @IOException $ withKindLease bootstrap $ \leaseCheck ->
          withScopeRootDescriptor scope $ \root sameRoot -> do
            owner <- getEffectiveUserID
            let stable = do
                  a <- leaseCheck
                  b <- sameRoot
                  c <- observeScopeGeneration scope generation
                  pure (a && b && c == Right ScopeGenerationMatches)
                flags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
                dirFlags = flags {Posix.directory = True}
                pending = artifactPendingName role artifact
                quarantine = ".discard-" ++ pending
                mode = case role of BootstrapKindTool -> 0o700; BootstrapNodeArchive -> 0o600
            opened <- try @IOException (Posix.openFdAt (Just root) ".prodbox-import" Posix.ReadOnly dirFlags)
            case opened of
              Left e | isDoesNotExistError e -> pure ArtifactStagingNotObserved
              Left _ -> pure ArtifactStagingDiscardRefused
              Right fd -> bracket (pure fd) Posix.closeFd $ \stage -> do
                stageStatus <- getFdStatus stage
                if not (safeDirectory owner stageStatus)
                  then pure ArtifactStagingDiscardRefused
                  else mask $ \restoreStage -> do
                    old <- openOptional stage pending flags
                    retired <- openOptional stage quarantine flags `onException` maybe (pure ()) Posix.closeFd old
                    case (old, retired) of
                      (Nothing, Nothing) -> pure ArtifactStagingNotObserved
                      (Just a, Just b) -> do
                        Posix.closeFd a
                        bracket (pure b) Posix.closeFd $ \held -> do
                          before <- getFdStatus held
                          restoreStage (removeQuarantined touched owner mode stage quarantine held before flags stable)
                      (Just file, Nothing) -> bracket (pure file) Posix.closeFd $ \held -> do
                        before <- getFdStatus held
                        named <-
                          bracket (Posix.openFdAt (Just stage) pending Posix.ReadOnly flags) Posix.closeFd getFdStatus
                        ready <- stable
                        if not (ready && safePending owner mode before && sameVersion before named)
                          then pure ArtifactStagingDiscardRefused
                          else do
                            withCString pending $ \from -> withCString quarantine $ \to ->
                              throwErrnoIfMinus1_
                                "quarantine staged artifact"
                                (renameAt2 (rawFd stage) from (rawFd stage) to noReplace)
                            writeIORef touched True
                            fileSynchronise stage
                            restoreStage (removeQuarantined touched owner mode stage quarantine held before flags stable)
                      (Nothing, Just file) -> bracket (pure file) Posix.closeFd $ \held -> do
                        before <- getFdStatus held
                        restoreStage (removeQuarantined touched owner mode stage quarantine held before flags stable)
        changed <- readIORef touched
        pure $ case outcome of
          Just (Right (Right (KindLeaseCompleted (Right result)))) -> result
          _ | changed -> ArtifactStagingDiscardIncomplete
          _ -> ArtifactStagingDiscardRefused
 where
  declaration = case role of
    BootstrapKindTool -> bootstrapKindTool bootstrap
    BootstrapNodeArchive -> bootstrapNodeArtifact bootstrap
  scope = bootstrapScope bootstrap
  generation = Text.unpack (bootstrapRootGeneration bootstrap)

artifactPendingName :: BootstrapArtifact -> ArtifactDeclaration -> String
artifactPendingName role artifact =
  (case role of BootstrapKindTool -> "kind-"; BootstrapNodeArchive -> "node-")
    ++ drop 7 (artifactDigest artifact)

openOptional :: Fd -> FilePath -> Posix.OpenFileFlags -> IO (Maybe Fd)
openOptional parent name flags = do
  result <- try @IOException (Posix.openFdAt (Just parent) name Posix.ReadOnly flags)
  case result of
    Left e | isDoesNotExistError e -> pure Nothing
    Left e -> throwIO e
    Right fd -> pure (Just fd)

namedPresent :: Fd -> FilePath -> Posix.OpenFileFlags -> IO Bool
namedPresent parent name flags = mask $ \_ -> do
  found <- openOptional parent name flags
  maybe (pure ()) Posix.closeFd found
  pure (found /= Nothing)

removeQuarantined
  :: IORef Bool
  -> UserID
  -> CMode
  -> Fd
  -> FilePath
  -> Fd
  -> FileStatus
  -> Posix.OpenFileFlags
  -> IO Bool
  -> IO ArtifactDiscardResult
removeQuarantined touched owner mode stage name held before flags stable = mask $ \_ -> do
  after <- getFdStatus held
  named <- bracket (Posix.openFdAt (Just stage) name Posix.ReadOnly flags) Posix.closeFd getFdStatus
  ready <- stable
  if not
    (ready && safePending owner mode after && sameRenamedVersion before after && sameVersion after named)
    then pure ArtifactStagingDiscardIncomplete
    else do
      withCString name $ \bytes -> throwErrnoIfMinus1_ "discard staged artifact" (unlinkAt (rawFd stage) bytes 0)
      writeIORef touched True
      fileSynchronise stage
      stillStable <- stable
      remaining <- openOptional stage name flags
      pending <-
        openOptional stage (drop (length (".discard-" :: String)) name) flags
          `onException` maybe (pure ()) Posix.closeFd remaining
      maybe (pure ()) Posix.closeFd remaining
      maybe (pure ()) Posix.closeFd pending
      pure $
        if stillStable && remaining == Nothing && pending == Nothing
          then ArtifactStagingDiscarded
          else ArtifactStagingDiscardIncomplete
