{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A single, bounded and import-free authored Dhall snapshot. This is a
-- read-only input observation; it does not bind the path to a deployment.
module Prodbox.Config.SelectedDhall
  ( SelectedDhallError (..)
  , SelectedDhallPublication (..)
  , readSelectedDhall
  , publishNewSelectedDhall
  , recoverSelectedDhall
  , validateSelectedDhallSource
  )
where

import Control.Exception (IOException, bracket, finally, mask, try)
import Control.Monad (void)
import Data.Bits ((.&.), (.|.))
import Data.ByteString qualified as ByteString
import Data.Foldable qualified as Foldable
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Dhall.Parser qualified as DhallParser
import Foreign.C.Error (eAGAIN, eWOULDBLOCK, getErrno, throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CUInt (..))
import Prodbox.Config.Tier0File qualified as Tier0File
import System.Directory (makeAbsolute)
import System.FilePath (normalise, splitDirectories, takeDirectory, takeFileName)
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
import System.Posix.Types (Fd (..), UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

data SelectedDhallError
  = SelectedDhallFileError !Tier0File.Tier0FileError
  | SelectedDhallMissing
  | SelectedDhallInvalidUtf8
  | SelectedDhallInvalidSyntax
  | SelectedDhallImportsUnsupported
  deriving (Eq, Show)

foreign import capi "stdio.h renameat2"
  publishSelectedAt :: CInt -> CString -> CInt -> CString -> CUInt -> IO CInt
foreign import capi "stdio.h value RENAME_NOREPLACE" selectedNoReplace :: CUInt
foreign import capi "sys/file.h flock" selectedFlock :: CInt -> CInt -> IO CInt
foreign import capi "sys/file.h value LOCK_EX" selectedExclusive :: CInt
foreign import capi "sys/file.h value LOCK_NB" selectedNonBlocking :: CInt
foreign import capi "sys/file.h value LOCK_UN" selectedUnlock :: CInt

data SelectedDhallPublication
  = SelectedDhallPublished
  | SelectedDhallDestinationExists
  | SelectedDhallPendingExists
  | SelectedDhallPublicationInvalid
  | SelectedDhallPublicationUnobservable
  | SelectedDhallPublicationIncomplete
  | SelectedDhallPublicationBusy
  | SelectedDhallRecoveryMismatch
  | SelectedDhallAlreadyMatches
  deriving (Eq, Show)

-- | Publish a new import-free document exclusively. The caller must validate
-- its meaning, destination scope and operation admission before invoking this
-- function. Interrupted or uncertain publication is preserved for recovery.
publishNewSelectedDhall :: FilePath -> Text -> IO SelectedDhallPublication
publishNewSelectedDhall supplied source
  | ByteString.length bytes > Tier0File.tier0FileMaximumBytes = pure SelectedDhallPublicationInvalid
  | Left _ <- validateSelectedDhallSource source = pure SelectedDhallPublicationInvalid
  | otherwise = do
      started <- newIORef False
      result <- try $ do
        absolute <- makeAbsolute supplied
        let name = takeFileName absolute
            pending = "." ++ name ++ ".prodbox-v2-pending"
            legacyPending = "." ++ name ++ ".prodbox-pending"
        if normalise absolute /= absolute
          || any (`elem` [".", ".."]) (splitDirectories absolute)
          || null name
          || length name > 200
          then pure SelectedDhallPublicationInvalid
          else do
            owner <- getEffectiveUserID
            walkParent absolute $ \directory parents -> do
              directoryStatus <- getFdStatus directory
              if not (safeDirectory owner directoryStatus)
                then pure SelectedDhallPublicationUnobservable
                else withPublicationLease directory $ do
                  existing <- selectedNameExists directory name
                  legacyExists <- selectedNameExists directory legacyPending
                  if existing
                    then pure SelectedDhallDestinationExists
                    else
                      if legacyExists
                        then pure SelectedDhallPendingExists
                        else mask $ \restore -> do
                          created <- try (Posix.openFdAt (Just directory) pending Posix.WriteOnly selectedCreateFlags)
                          case created of
                            Left (failure :: IOException)
                              | isAlreadyExistsError failure -> pure SelectedDhallPendingExists
                              | otherwise -> pure SelectedDhallPublicationUnobservable
                            Right descriptor -> do
                              writeIORef started True
                              bracket (pure descriptor) Posix.closeFd $ \file -> restore $ do
                                writeSelectedBytes file bytes
                                fileSynchronise file
                                fileSynchronise directory
                                written <- getFdStatus file
                                named <-
                                  bracket (Posix.openFdAt (Just directory) pending Posix.ReadOnly readFlags) Posix.closeFd getFdStatus
                                stable <- selectedParentStable absolute owner directory parents
                                if not (safeFile owner written && sameFile written named && stable)
                                  then pure SelectedDhallPublicationIncomplete
                                  else do
                                    let Fd raw = directory
                                    withCString pending $ \old -> withCString name $ \new ->
                                      throwErrnoIfMinus1_
                                        "publish selected configuration"
                                        (publishSelectedAt raw old raw new selectedNoReplace)
                                    fileSynchronise directory
                                    published <- getFdStatus file
                                    observed <- readSelectedSnapshot absolute
                                    namedFinal <-
                                      bracket (Posix.openFdAt (Just directory) name Posix.ReadOnly readFlags) Posix.closeFd getFdStatus
                                    stableAfter <- selectedParentStable absolute owner directory parents
                                    pure $
                                      if stableAfter
                                        && identity written == identity published
                                        && safeFile owner namedFinal
                                        && sameFile published namedFinal
                                        && observed == Right (Just bytes)
                                        then SelectedDhallPublished
                                        else SelectedDhallPublicationIncomplete
      didStart <- readIORef started
      pure $ case result of
        Left (_ :: IOException) -> if didStart then SelectedDhallPublicationIncomplete else SelectedDhallPublicationUnobservable
        Right outcome -> outcome
 where
  bytes = TextEncoding.encodeUtf8 source

-- | Resume a v2 publication only when the operator supplies the exact source.
-- Legacy pending names are never adopted. The caller owns semantic and scope
-- validation, including root observations before and after this operation.
recoverSelectedDhall :: FilePath -> Text -> IO SelectedDhallPublication
recoverSelectedDhall supplied source
  | ByteString.length bytes > Tier0File.tier0FileMaximumBytes = pure SelectedDhallPublicationInvalid
  | Left _ <- validateSelectedDhallSource source = pure SelectedDhallPublicationInvalid
  | otherwise = do
      renamed <- newIORef False
      attempted <- try $ do
        absolute <- makeAbsolute supplied
        let name = takeFileName absolute
            pending = "." ++ name ++ ".prodbox-v2-pending"
            legacyPending = "." ++ name ++ ".prodbox-pending"
        if normalise absolute /= absolute
          || any (`elem` [".", ".."]) (splitDirectories absolute)
          || null name
          || length name > 200
          then pure SelectedDhallPublicationInvalid
          else do
            owner <- getEffectiveUserID
            walkParent absolute $ \directory parents -> do
              status <- getFdStatus directory
              if not (safeDirectory owner status)
                then pure SelectedDhallPublicationUnobservable
                else withPublicationLease directory $ do
                  existing <- selectedNameExists directory name
                  legacyExists <- selectedNameExists directory legacyPending
                  if existing
                    then do
                      pendingExists <- selectedNameExists directory pending
                      if legacyExists || pendingExists
                        then pure SelectedDhallDestinationExists
                        else do
                          observed <- readSelectedSnapshot absolute
                          stable <- selectedParentStable absolute owner directory parents
                          pure $
                            if stable && observed == Right (Just bytes)
                              then SelectedDhallAlreadyMatches
                              else SelectedDhallDestinationExists
                    else
                      if legacyExists
                        then pure SelectedDhallPendingExists
                        else bracket (Posix.openFdAt (Just directory) pending Posix.ReadOnly readFlags) Posix.closeFd $ \file -> do
                          before <- getFdStatus file
                          if not (safeFile owner before) || fileSize before > fromIntegral Tier0File.tier0FileMaximumBytes
                            then pure SelectedDhallPublicationUnobservable
                            else do
                              content <- readBounded file [] 0
                              after <- getFdStatus file
                              named <-
                                bracket (Posix.openFdAt (Just directory) pending Posix.ReadOnly readFlags) Posix.closeFd getFdStatus
                              stable <- selectedParentStable absolute owner directory parents
                              if not (sameFile before after && sameFile after named && stable)
                                then pure SelectedDhallPublicationIncomplete
                                else
                                  if content /= Right bytes
                                    then pure SelectedDhallRecoveryMismatch
                                    else do
                                      fileSynchronise file
                                      fileSynchronise directory
                                      let Fd raw = directory
                                      withCString pending $ \old -> withCString name $ \new ->
                                        throwErrnoIfMinus1_
                                          "recover selected configuration"
                                          (publishSelectedAt raw old raw new selectedNoReplace)
                                      writeIORef renamed True
                                      fileSynchronise directory
                                      final <- getFdStatus file
                                      observed <- readSelectedSnapshot absolute
                                      stableAfter <- selectedParentStable absolute owner directory parents
                                      pure $
                                        if stableAfter && identity after == identity final && observed == Right (Just bytes)
                                          then SelectedDhallPublished
                                          else SelectedDhallPublicationIncomplete
      didRename <- readIORef renamed
      pure $ case attempted of
        Left (_ :: IOException) -> if didRename then SelectedDhallPublicationIncomplete else SelectedDhallPublicationUnobservable
        Right outcome -> outcome
 where
  bytes = TextEncoding.encodeUtf8 source

-- Serialize cooperating publishers on the already verified parent inode.
-- This does not prove that older, non-cooperating writers have stopped and
-- therefore does not itself authorize recovery of an existing pending file.
withPublicationLease :: Fd -> IO SelectedDhallPublication -> IO SelectedDhallPublication
withPublicationLease (Fd descriptor) action = mask $ \restore -> do
  acquired <- selectedFlock descriptor (selectedExclusive .|. selectedNonBlocking)
  if acquired /= 0
    then do
      cause <- getErrno
      pure $
        if cause == eAGAIN || cause == eWOULDBLOCK
          then SelectedDhallPublicationBusy
          else SelectedDhallPublicationUnobservable
    else restore action `finally` void (selectedFlock descriptor selectedUnlock)

selectedNameExists :: Fd -> FilePath -> IO Bool
selectedNameExists parent name = do
  result <-
    try
      (bracket (Posix.openFdAt (Just parent) name Posix.ReadOnly readFlags) Posix.closeFd (const (pure ())))
  case result of
    Right () -> pure True
    Left (failure :: IOException)
      | isDoesNotExistError failure -> pure False
      | otherwise -> ioError failure

selectedParentStable :: FilePath -> UserID -> Fd -> [(Integer, Integer)] -> IO Bool
selectedParentStable path owner held identities = do
  current <- try (walkParent path $ \_ names -> pure names)
  status <- try (getFdStatus held)
  pure $ case (current, status) of
    (Right names, Right heldStatus) -> names == identities && safeDirectory owner heldStatus
    (_ :: Either IOException [(Integer, Integer)], _ :: Either IOException FileStatus) -> False

safeDirectory :: UserID -> FileStatus -> Bool
safeDirectory owner status = isDirectory status && fileOwner status == owner && fileMode status .&. 0o022 == 0

selectedCreateFlags :: Posix.OpenFileFlags
selectedCreateFlags = readFlags {Posix.exclusive = True, Posix.creat = Just 0o600}

writeSelectedBytes :: Fd -> ByteString.ByteString -> IO ()
writeSelectedBytes descriptor bytes
  | ByteString.null bytes = pure ()
  | otherwise = do
      count <- PosixBytes.fdWrite descriptor bytes
      if count <= 0
        then ioError (userError "short selected configuration write")
        else writeSelectedBytes descriptor (ByteString.drop (fromIntegral count) bytes)

readSelectedDhall :: FilePath -> IO (Either SelectedDhallError Text)
readSelectedDhall path = do
  snapshot <- readSelectedSnapshot path
  pure $ case snapshot of
    Left failure -> Left (SelectedDhallFileError failure)
    Right Nothing -> Left SelectedDhallMissing
    Right (Just bytes) -> case TextEncoding.decodeUtf8' bytes of
      Left _ -> Left SelectedDhallInvalidUtf8
      Right source -> source <$ validateSelectedDhallSource source

-- Walk the selected path without following any component, then reopen it and
-- compare the held identities after the bounded read. This is an observation,
-- not an authorization to mutate resources named by the document.
readSelectedSnapshot
  :: FilePath -> IO (Either Tier0File.Tier0FileError (Maybe ByteString.ByteString))
readSelectedSnapshot supplied = do
  attempted <- try $ do
    absolute <- makeAbsolute supplied
    if normalise absolute /= absolute || any (`elem` [".", ".."]) (splitDirectories absolute)
      then pure (Left Tier0File.Tier0FileUnsafe)
      else do
        owner <- getEffectiveUserID
        opened <- try $ walkParent absolute $ \directory parents -> do
          fileResult <- try
            $ bracket
              (Posix.openFdAt (Just directory) (takeFileName absolute) Posix.ReadOnly readFlags)
              Posix.closeFd
            $ \file -> do
              before <- getFdStatus file
              if not (safeFile owner before)
                then pure (Left Tier0File.Tier0FileUnsafe)
                else
                  if fileSize before > fromIntegral Tier0File.tier0FileMaximumBytes
                    then pure (Left Tier0File.Tier0FileTooLarge)
                    else do
                      bytes <- readBounded file [] 0
                      after <- getFdStatus file
                      fresh <- try $ walkParent absolute $ \freshDirectory currentParents ->
                        bracket
                          (Posix.openFdAt (Just freshDirectory) (takeFileName absolute) Posix.ReadOnly readFlags)
                          Posix.closeFd
                          $ \freshFile -> do
                            current <- getFdStatus freshFile
                            pure
                              ( currentParents == parents
                                  && safeFile owner current
                                  && sameFile before after
                                  && sameFile after current
                              )
                      pure $ case (bytes, fresh) of
                        (Left failure, _) -> Left failure
                        (Right content, Right True) -> Right (Just content)
                        (_ :: Either Tier0File.Tier0FileError ByteString.ByteString, _ :: Either IOException Bool) -> Left Tier0File.Tier0FileChanged
          pure $ case fileResult of
            Left (failure :: IOException)
              | isDoesNotExistError failure -> Right Nothing
              | otherwise -> Left Tier0File.Tier0FileUnsafe
            Right result -> result
        pure $
          either
            (const (Left Tier0File.Tier0FileUnsafe))
            id
            (opened :: Either IOException (Either Tier0File.Tier0FileError (Maybe ByteString.ByteString)))
  pure $
    either
      (const (Left Tier0File.Tier0FileUnsafe))
      id
      (attempted :: Either IOException (Either Tier0File.Tier0FileError (Maybe ByteString.ByteString)))

walkParent :: FilePath -> (Fd -> [(Integer, Integer)] -> IO value) -> IO value
walkParent path action = bracket (Posix.openFd "/" Posix.ReadOnly directoryFlags) Posix.closeFd $ \root ->
  descend root (filter (/= "/") (splitDirectories (takeDirectory path))) []
 where
  descend current names identities = do
    status <- getFdStatus current
    if not (isDirectory status)
      then ioError (userError "selected config parent is not a directory")
      else case names of
        [] -> action current (reverse (identity status : identities))
        name : rest -> bracket (Posix.openFdAt (Just current) name Posix.ReadOnly directoryFlags) Posix.closeFd $ \next ->
          descend next rest (identity status : identities)

directoryFlags :: Posix.OpenFileFlags
directoryFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}

readFlags :: Posix.OpenFileFlags
readFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}

identity :: FileStatus -> (Integer, Integer)
identity status = (toInteger (deviceID status), toInteger (fileID status))

safeFile :: UserID -> FileStatus -> Bool
safeFile owner status =
  isRegularFile status
    && fileOwner status == owner
    && linkCount status == 1
    && fileMode status .&. 0o022 == 0

sameFile :: FileStatus -> FileStatus -> Bool
sameFile before after =
  identity before == identity after
    && fileSize before == fileSize after
    && fileMode before == fileMode after
    && fileOwner before == fileOwner after
    && linkCount before == linkCount after
    && modificationTimeHiRes before == modificationTimeHiRes after
    && statusChangeTimeHiRes before == statusChangeTimeHiRes after

readBounded
  :: Fd -> [ByteString.ByteString] -> Int -> IO (Either Tier0File.Tier0FileError ByteString.ByteString)
readBounded file chunks count = do
  result <- try (PosixBytes.fdRead file (fromIntegral (Tier0File.tier0FileMaximumBytes + 1 - count)))
  case result of
    Left (failure :: IOException) | isEOFError failure -> pure (Right (ByteString.concat (reverse chunks)))
    Left failure -> ioError failure
    Right bytes
      | ByteString.null bytes -> pure (Right (ByteString.concat (reverse chunks)))
      | count + ByteString.length bytes > Tier0File.tier0FileMaximumBytes ->
          pure (Left Tier0File.Tier0FileTooLarge)
      | otherwise -> readBounded file (bytes : chunks) (count + ByteString.length bytes)

-- | Refuse every import syntactically, including those in unused branches.
-- This check must precede any Dhall import resolution for a selected source.
validateSelectedDhallSource :: Text -> Either SelectedDhallError ()
validateSelectedDhallSource source = case DhallParser.exprFromText "selected configuration" source of
  Left _ -> Left SelectedDhallInvalidSyntax
  Right expression
    | not (Foldable.null expression) -> Left SelectedDhallImportsUnsupported
    | otherwise -> Right ()
