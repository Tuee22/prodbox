{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The Authority's mounted journal: a write-ahead mirror of the
-- admission-relevant facts of its retained submission ledger, kept on the
-- retained volume so they stay readable while Vault is sealed. Each aggregate
-- commit first writes the mirror derived from the aggregate about to be
-- committed and only then performs the compare-and-swap, so the volume can be
-- ahead of the store (it may show an intent the commit never made, which is
-- conservative) and never behind it. A failed mirror write refuses the commit.
-- A genesis record, written once when the Authority first resolves its store,
-- is the positive evidence that "no operation" means never admitted rather than
-- "journal missing". The mirror holds operation labels and states only.
module Prodbox.ControlPlane.AdmissionJournalMirror
  ( journalMountDirectory
  , journalCustodyMountDirectory
  , mirrorAdmissionRepository
  , mirrorRetainedAdmissionRepository
  , initialiseJournalMirror
  , initialiseRetainedJournalMirror
  , observeJournalMirror
  , observeRetainedJournalMirror
  , JournalRemovalFence (..)
  , observeJournalRemovalFence
  , recordJournalRemovalFence
  , withJournalCustodyLease
  , JournalInitialization (..)
  , observeJournalInitialization
  , renderMirror
  , parseMirror
  ) where

import Codec.Serialise (deserialiseOrFail, serialise)
import Control.Exception (IOException, bracket, try)
import Control.Monad (guard)
import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Control.KindLease (KindLeaseOutcome (KindLeaseCompleted), withLockedKindScope)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.Lifecycle.AdmissionHistory (JournalObservation (..), OperationState (..))
import Prodbox.Lifecycle.AdmissionLedgerProjection (ledgerJournalObservation)
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , authorityAggregateSubmissionLedger
  )
import Prodbox.Lifecycle.Authority.Operation
  ( OperationRecord
  , OperationResume (ResumeArmedOperation)
  , completeOperation
  , newArmedOperation
  , resumeOperation
  )
import System.Directory (createDirectory, removeDirectory, renameFile)
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files qualified as Files
import System.Posix.IO (OpenMode (ReadOnly, WriteOnly), closeFd, defaultFileFlags, openFd)
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (Fd (..))
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

-- | The volume the Authority chart mounts for its journal.
journalMountDirectory :: FilePath
journalMountDirectory = "/var/lib/prodbox/lifecycle-authority-journal"

journalCustodyMountDirectory :: FilePath
journalCustodyMountDirectory = "/var/lib/prodbox/lifecycle-authority-custody"

mirrorPath, genesisPath :: FilePath -> FilePath
mirrorPath directory = directory </> "admission.json"
genesisPath directory = directory </> "genesis.json"

genesisBytes :: ByteString.ByteString
genesisBytes = "genesis\n"

mirrorReadLimit :: Int
mirrorReadLimit = 2 * 1024 * 1024

writeGuardPath :: FilePath -> FilePath
writeGuardPath directory = directory </> "admission-write-in-progress"

renderMirror :: [(Text, OperationState)] -> ByteString.ByteString
renderMirror operations =
  LazyByteString.toStrict
    ( Aeson.encode
        ( Aeson.object
            [ "schema_version" .= (1 :: Int)
            , "operations"
                .= [ Aeson.object ["operation" .= name, "state" .= stateText state]
                   | (name, state) <- operations
                   ]
            ]
        )
    )
 where
  stateText :: OperationState -> Text
  stateText OperationSettled = "settled"
  stateText OperationUnresolved = "unresolved"

parseMirror :: ByteString.ByteString -> Maybe [(Text, OperationState)]
parseMirror bytes = do
  value <- Aeson.decodeStrict bytes
  AesonTypes.parseMaybe
    ( Aeson.withObject "mirror" $ \object -> do
        version <- object .: "schema_version" :: AesonTypes.Parser Int
        entries <- object .: "operations" :: AesonTypes.Parser [Aeson.Value]
        if version /= 1
          then fail "unsupported"
          else
            mapM
              ( Aeson.withObject "entry" $ \entry -> do
                  name <- entry .: "operation"
                  state <- entry .: "state" :: AesonTypes.Parser Text
                  case state of
                    "settled" -> pure (name, OperationSettled)
                    "unresolved" -> pure (name, OperationUnresolved)
                    _ -> fail "state"
              )
              entries
    )
    value

atomicWrite :: FilePath -> ByteString.ByteString -> IO (Either String ())
atomicWrite path bytes = do
  let temporary = path ++ ".tmp"
  written <-
    try
      ( do
          bracket
            (openFd temporary WriteOnly readFlags {Posix.creat = Just 0o600, Posix.exclusive = True})
            closeFd
            $ \file -> writeAll file bytes >> fileSynchronise file
          renameFile temporary path
          syncPath (takeDirectory path)
      )
      :: IO (Either IOException ())
  pure (either (Left . ("journal mirror write failed: " ++) . take 120 . show) Right written)
 where
  writeAll file remaining
    | ByteString.null remaining = pure ()
    | otherwise = do
        count <- PosixBytes.fdWrite file remaining
        if count > 0
          then writeAll file (ByteString.drop (fromIntegral count) remaining)
          else ioError (userError "short journal mirror write")

syncPath :: FilePath -> IO ()
syncPath path = bracket (openFd path ReadOnly defaultFileFlags) closeFd fileSynchronise

guardPresent :: FilePath -> IO (Either IOException Bool)
guardPresent directory = do
  result <- try (Files.getSymbolicLinkStatus (writeGuardPath directory))
  pure $ case result of
    Right _ -> Right True
    Left failure | isDoesNotExistError failure -> Right False
    Left failure -> Left failure

data JournalMember
  = JournalMemberMissing
  | JournalMemberUnobservable
  | JournalMemberRead !ByteString.ByteString
  deriving (Eq)

readFlags :: Posix.OpenFileFlags
readFlags = defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}

withJournalDirectory :: FilePath -> (Fd -> IO a) -> IO (Maybe a)
withJournalDirectory directory readEntries = do
  result <- try $
    bracket (openFd directory ReadOnly (readFlags {Posix.directory = True})) closeFd $ \held -> do
      original <- Files.getFdStatus held
      observed <- readEntries held
      current <- Files.getSymbolicLinkStatus directory
      pure $
        observed
          <$ guard
            ( Files.isDirectory current
                && Files.deviceID original == Files.deviceID current
                && Files.fileID original == Files.fileID current
            )
  pure (either (\(_ :: IOException) -> Nothing) id result)

withJournalCustodyLease :: FilePath -> (Fd -> IO Bool -> IO a) -> IO (Maybe a)
withJournalCustodyLease custody action = do
  attempted <- withJournalDirectory custody $ \held ->
    withLockedKindScope held (custodyStillNamed held) (action held)
  pure $ case attempted of
    Just (Right (KindLeaseCompleted result)) -> Just result
    _ -> Nothing
 where
  custodyStillNamed held = do
    original <- Files.getFdStatus held
    named <- Files.getSymbolicLinkStatus custody
    owner <- getEffectiveUserID
    pure
      ( Files.isDirectory named
          && Files.deviceID original == Files.deviceID named
          && Files.fileID original == Files.fileID named
          && Files.fileOwner named == owner
          && Files.fileMode named `Files.intersectFileModes` 0o7777 == 0o700
      )

readJournalMember :: Fd -> FilePath -> Int -> IO JournalMember
readJournalMember directory name limit = do
  opened <- try (Posix.openFdAt (Just directory) name ReadOnly readFlags)
  case opened of
    Left (failure :: IOException)
      | isDoesNotExistError failure -> pure JournalMemberMissing
      | otherwise -> pure JournalMemberUnobservable
    Right file -> bracket (pure file) closeFd $ \held -> do
      parent <- Files.getFdStatus directory
      before <- Files.getFdStatus held
      if Files.isRegularFile before
        && Files.fileOwner before == Files.fileOwner parent
        && Files.fileMode before `Files.intersectFileModes` 0o022 == 0
        && Files.linkCount before == 1
        && Files.fileSize before <= fromIntegral limit
        then do
          bytes <- PosixBytes.fdRead held (fromIntegral (limit + 1))
          after <- Files.getFdStatus held
          named <-
            bracket
              (Posix.openFdAt (Just directory) name ReadOnly readFlags)
              closeFd
              Files.getFdStatus
          pure $
            if fromIntegral (ByteString.length bytes) == Files.fileSize before
              && recordVersion before == recordVersion after
              && recordVersion after == recordVersion named
              then JournalMemberRead bytes
              else JournalMemberUnobservable
        else pure JournalMemberUnobservable
 where
  recordVersion status =
    ( Files.deviceID status
    , Files.fileID status
    , Files.fileOwner status
    , Files.fileMode status
    , Files.fileSize status
    , Files.linkCount status
    , Files.modificationTimeHiRes status
    , Files.statusChangeTimeHiRes status
    )

observedOperations :: JournalObservation -> [(Text, OperationState)]
observedOperations observation = case observation of
  JournalRead operations -> operations
  _ -> []

genesisIntentName :: FilePath
genesisIntentName = "genesis-attempt"

removalFenceName :: FilePath
removalFenceName = "control-removal.json"

data JournalRemovalFence
  = JournalRemovalFenceAbsent
  | JournalRemovalFenceMatches
  | JournalRemovalFenceUnconfirmed
  deriving (Eq, Show)

observeJournalRemovalFence :: Fd -> ByteString.ByteString -> IO JournalRemovalFence
observeJournalRemovalFence custody expected = do
  observed <- readJournalMember custody removalFenceName 4096
  pure $ case observed of
    JournalMemberMissing -> JournalRemovalFenceAbsent
    JournalMemberRead recorded | recorded == expected -> JournalRemovalFenceMatches
    _ -> JournalRemovalFenceUnconfirmed

recordJournalRemovalFence :: Fd -> ByteString.ByteString -> IO Bool
recordJournalRemovalFence custody expected =
  createJournalMember custody removalFenceName expected

-- The cooperating controller and Authority hold the same directory lease for
-- fence publication and admission commits. The fence survives both processes.
createJournalMember :: Fd -> FilePath -> ByteString.ByteString -> IO Bool
createJournalMember directory name bytes = do
  created <- try
    $ bracket
      ( Posix.openFdAt
          (Just directory)
          name
          WriteOnly
          readFlags {Posix.creat = Just 0o600, Posix.exclusive = True}
      )
      closeFd
    $ \file -> do
      count <- PosixBytes.fdWrite file bytes
      if fromIntegral count /= ByteString.length bytes
        then pure False
        else do
          fileSynchronise file
          fileSynchronise directory
          pure True
  pure (either (const False) id (created :: Either IOException Bool))

mirrorCommitmentName :: FilePath
mirrorCommitmentName = "admission.sha256"

writeRetainedMirror :: FilePath -> FilePath -> ByteString.ByteString -> IO (Either String ())
writeRetainedMirror directory custody bytes = do
  written <- atomicWrite (mirrorPath directory) bytes
  case written of
    Left failure -> pure (Left failure)
    Right () -> atomicWrite (custody </> mirrorCommitmentName) (hexSha256 bytes)

observeMirrorCommitment :: FilePath -> IO (Maybe ByteString.ByteString)
observeMirrorCommitment custody = do
  observed <- withJournalDirectory custody $ \directory ->
    readJournalMember directory mirrorCommitmentName 64
  pure $ case observed of
    Just (JournalMemberRead bytes) | ByteString.length bytes == 64 -> Just bytes
    _ -> Nothing

observeGenesisIntent :: FilePath -> IO Bool
observeGenesisIntent custody = do
  held <- withJournalDirectory custody $ \directory ->
    readJournalMember directory genesisIntentName (ByteString.length genesisBytes)
  pure (held == Just (JournalMemberRead genesisBytes))

data JournalInitialization
  = JournalInitializationLegacy
  | JournalInitializationArmed !Text
  | JournalInitializationComplete !Text
  | JournalInitializationUnconfirmed
  deriving (Eq, Show)

type GenesisRecord =
  OperationRecord
    ByteString.ByteString
    (ByteString.ByteString, ByteString.ByteString)
    ByteString.ByteString

data GenesisObservation
  = GenesisLegacy
  | GenesisArmed !ByteString.ByteString !GenesisRecord !(ByteString.ByteString, ByteString.ByteString)
  | GenesisComplete !ByteString.ByteString
  | GenesisUnconfirmed

genesisArmedName, genesisCompleteName :: FilePath
genesisArmedName = "genesis-operation.cbor"
genesisCompleteName = "genesis-operation-complete.cbor"

observeJournalInitialization :: FilePath -> FilePath -> IO JournalInitialization
observeJournalInitialization directory custody = do
  observed <- withJournalDirectory custody (observeBoundGenesis directory)
  pure $ case observed of
    Just GenesisLegacy -> JournalInitializationLegacy
    Just (GenesisArmed identifier _ _) -> JournalInitializationArmed (Text.decodeUtf8 identifier)
    Just (GenesisComplete identifier) -> JournalInitializationComplete (Text.decodeUtf8 identifier)
    _ -> JournalInitializationUnconfirmed

observeBoundGenesis :: FilePath -> Fd -> IO GenesisObservation
observeBoundGenesis directory custody = do
  observed <- withJournalDirectory directory $ \journal -> do
    identifier <- genesisOperationId journal custody
    armed <- readJournalMember custody genesisArmedName armedCommitLimit
    terminal <- readJournalMember custody genesisCompleteName armedCommitLimit
    case (armed, terminal) of
      (JournalMemberMissing, JournalMemberMissing) -> pure GenesisLegacy
      (JournalMemberRead bytes, completion)
        | Right record <- deserialiseOrFail (LazyByteString.fromStrict bytes)
        , LazyByteString.toStrict (serialise (record :: GenesisRecord)) == bytes
        , Right (ResumeArmedOperation commitment) <- resumeOperation identifier record ->
            case completion of
              JournalMemberMissing -> do
                let projection = renderMirror []
                    members = genesisMembers journal custody projection (snd commitment)
                matched <- genesisMembersObserved members
                pure $
                  if matched /= Nothing && snd commitment == hexSha256 projection
                    then GenesisArmed identifier record commitment
                    else GenesisUnconfirmed
              JournalMemberRead settled
                | Right expected <- completeOperation identifier (snd commitment) record
                , settled == LazyByteString.toStrict (serialise expected) ->
                    pure (GenesisComplete identifier)
              _ -> pure GenesisUnconfirmed
      _ -> pure GenesisUnconfirmed
  pure (maybe GenesisUnconfirmed id observed)

genesisOperationId :: Fd -> Fd -> IO ByteString.ByteString
genesisOperationId journal custody = do
  first <- Files.getFdStatus journal
  second <- Files.getFdStatus custody
  let identity status = (Files.deviceID status, Files.fileID status)
  pure
    ( ByteString.take
        32
        ( hexSha256
            (Char8.pack (show ("prodbox-authority-journal-init-v1" :: String, identity first, identity second)))
        )
    )

initialiseBoundGenesis
  :: FilePath
  -> FilePath
  -> Fd
  -> IO Bool
  -> AuthorityAdmissionRepository IO revision
  -> IO (Either String ())
initialiseBoundGenesis directory custody held stable repository = do
  observed <- observeBoundGenesis directory held
  case observed of
    GenesisLegacy -> do
      first <- withJournalDirectory directory $ \journal -> do
        marker <- readJournalMember journal "genesis.json" (ByteString.length genesisBytes)
        mirror <- readJournalMember journal "admission.json" mirrorReadLimit
        reservation <- readJournalMember held genesisIntentName (ByteString.length genesisBytes)
        commitment <- readJournalMember held mirrorCommitmentName 64
        case (marker, mirror, reservation, commitment) of
          (JournalMemberMissing, JournalMemberMissing, JournalMemberMissing, JournalMemberMissing) ->
            Just <$> armGenesis journal
          _ -> pure Nothing
      case first of
        Just (Just outcome) -> pure outcome
        Just Nothing -> checkExisting
        Nothing -> pure (Left "the retained journal directory is unobservable")
    GenesisArmed identifier record intent -> settle identifier record intent
    GenesisComplete _ -> checkExisting
    GenesisUnconfirmed -> pure (Left "the Authority journal initialization is unobservable")
 where
  checkExisting =
    initialiseMirrorWith
      directory
      (observeRetainedJournalMirror directory custody)
      (pure False)
      (writeRetainedMirror directory custody)
      repository
  armGenesis journal = do
    identifier <- genesisOperationId journal held
    observedStore <- readAuthorityAdmission repository
    case observedStore of
      Right snapshot -> do
        let aggregate = authorityAdmissionSnapshotState snapshot
            projection = renderMirror (admissionOperations aggregate)
            intent = (admissionDigest aggregate, hexSha256 projection)
            record :: GenesisRecord
            record = newArmedOperation identifier intent
        unchanged <- stable
        if unchanged && null (admissionOperations aggregate)
          then do
            published <- createJournalMember held genesisArmedName (LazyByteString.toStrict (serialise record))
            if published
              then settle identifier record intent
              else pure (Left "the Authority journal initialization could not be armed")
          else pure (Left "the Authority journal initialization predecessor is unconfirmed")
      Left _ -> pure (Left "the Authority journal initialization predecessor is unavailable")
  settle identifier record (expectedAggregate, expectedProjection) = do
    observed <- readAuthorityAdmission repository
    case observed of
      Right snapshot
        | let aggregate = authorityAdmissionSnapshotState snapshot
        , let projection = renderMirror (admissionOperations aggregate)
        , admissionDigest aggregate == expectedAggregate
        , hexSha256 projection == expectedProjection
        , Right completed <- completeOperation identifier expectedProjection record -> do
            prepared <- withJournalDirectory directory $ \journal -> do
              currentId <- genesisOperationId journal held
              if currentId == identifier
                then publishGenesisMembers journal held stable projection expectedProjection
                else pure False
            current <- observeCommittedJournalMirror directory custody
            unchanged <- stable
            if prepared == Just True && current == JournalRead (admissionOperations aggregate) && unchanged
              then do
                recorded <-
                  createJournalMember held genesisCompleteName (LazyByteString.toStrict (serialise completed))
                verified <- observeBoundGenesis directory held
                pure $ case verified of
                  GenesisComplete observedId | recorded && observedId == identifier -> Right ()
                  _ -> Left "the Authority journal initialization result is unconfirmed"
              else pure (Left "the original Authority journal initialization is pending")
      _ -> pure (Left "the Authority journal initialization no longer matches its backing admission")

publishGenesisMembers
  :: Fd -> Fd -> IO Bool -> ByteString.ByteString -> ByteString.ByteString -> IO Bool
publishGenesisMembers journal custody stable projection commitment = do
  let members = genesisMembers journal custody projection commitment
  observed <- genesisMembersObserved members
  maybe (pure False) (publish . zip members) observed
 where
  publish [] = stable
  publish (((descriptor, name, expected), observed) : rest) = do
    unchanged <- stable
    confirmed <-
      if unchanged && observed == JournalMemberMissing
        then createJournalMember descriptor name expected
        else pure unchanged
    if confirmed then publish rest else pure False

genesisMembers
  :: Fd
  -> Fd
  -> ByteString.ByteString
  -> ByteString.ByteString
  -> [(Fd, FilePath, ByteString.ByteString)]
genesisMembers journal custody projection commitment =
  [ (custody, genesisIntentName, genesisBytes)
  , (journal, "admission.json", projection)
  , (custody, mirrorCommitmentName, commitment)
  , (journal, "genesis.json", genesisBytes)
  ]

genesisMembersObserved :: [(Fd, FilePath, ByteString.ByteString)] -> IO (Maybe [JournalMember])
genesisMembersObserved members = do
  observed <- traverse readMember members
  pure $
    observed <$ guard (and (zipWith compatible members observed) && reservationPrecedesEffects observed)
 where
  readMember (descriptor, name, expected) = readJournalMember descriptor name (ByteString.length expected)
  compatible (_, _, expected) member = member == JournalMemberMissing || member == JournalMemberRead expected
  reservationPrecedesEffects (JournalMemberMissing : later) = all (== JournalMemberMissing) later
  reservationPrecedesEffects _ = True

-- | Wrap the admission repository so that every commit is preceded by its
-- mirror write.
mirrorAdmissionRepository
  :: FilePath
  -> AuthorityAdmissionRepository IO revision
  -> AuthorityAdmissionRepository IO revision
mirrorAdmissionRepository directory = mirrorRepositoryWith directory (atomicWrite (mirrorPath directory))

mirrorRepositoryWith
  :: FilePath
  -> (ByteString.ByteString -> IO (Either String ()))
  -> AuthorityAdmissionRepository IO revision
  -> AuthorityAdmissionRepository IO revision
mirrorRepositoryWith directory writeMirror repository =
  repository
    { compareAndSwapAuthorityAdmission = \expected aggregate -> do
        acquired <-
          try (createDirectory (writeGuardPath directory) >> syncPath directory) :: IO (Either IOException ())
        case acquired of
          Left _ -> pure (Left "journal-write-in-progress-or-unavailable")
          Right () -> do
            let operations = observedOperations (ledgerJournalObservation (authorityAggregateSubmissionLedger aggregate))
            mirrored <- writeMirror (renderMirror operations)
            case mirrored of
              Left failure -> pure (Left (Text.pack failure))
              Right () -> do
                committed <- compareAndSwapAuthorityAdmission repository expected aggregate
                case committed of
                  Left failure -> pure (Left failure)
                  Right revision -> do
                    removed <-
                      try (removeDirectory (writeGuardPath directory) >> syncPath directory) :: IO (Either IOException ())
                    pure $ case removed of
                      Left _ -> Left "journal-write-guard-removal-failed"
                      Right () -> Right revision
    }

mirrorRetainedAdmissionRepository
  :: (Eq revision)
  => FilePath
  -> FilePath
  -> AuthorityAdmissionRepository IO revision
  -> AuthorityAdmissionRepository IO revision
mirrorRetainedAdmissionRepository directory custody repository =
  repository
    { readAuthorityAdmission = do
        observed <- readAuthorityAdmission repository
        retained <- observeRetainedJournalMirror directory custody
        pure $ do
          snapshot <- observed
          if retained == JournalRead (admissionOperations (authorityAdmissionSnapshotState snapshot))
            then Right snapshot
            else Left "retained-journal-or-admission-unavailable"
    , compareAndSwapAuthorityAdmission = \expected aggregate -> do
        outcome <- withJournalCustodyLease custody $ \held stable -> do
          fence <- readJournalMember held removalFenceName 4096
          retained <- observeRetainedJournalMirror directory custody
          unchanged <- stable
          case (fence, retained, unchanged) of
            (JournalMemberMissing, JournalRead operations, True) -> do
              before <- readAuthorityAdmission repository
              case before of
                Right snapshot
                  | authorityAdmissionRevision snapshot == expected
                  , let previous = authorityAdmissionSnapshotState snapshot
                  , operations == admissionOperations previous ->
                      if previous == aggregate
                        then pure (Right ())
                        else commitRetainedAdmission directory custody held stable repository expected aggregate
                _ -> pure (Left "retained-journal-predecessor-unconfirmed")
            _ -> pure (Left "retained-journal-or-admission-unavailable")
        pure (maybe (Left "retained-journal-lease-unavailable") id outcome)
    }

type ArmedAdmissionCommit = OperationRecord ByteString.ByteString ByteString.ByteString ()

armedCommitName :: FilePath
armedCommitName = "admission-commit.cbor"

armedCommitLimit :: Int
armedCommitLimit = 512

admissionOperations :: AuthorityAdmissionAggregate -> [(Text, OperationState)]
admissionOperations = observedOperations . ledgerJournalObservation . authorityAggregateSubmissionLedger

admissionDigest :: AuthorityAdmissionAggregate -> ByteString.ByteString
admissionDigest = hexSha256 . LazyByteString.toStrict . serialise

commitRetainedAdmission
  :: FilePath
  -> FilePath
  -> Fd
  -> IO Bool
  -> AuthorityAdmissionRepository IO revision
  -> revision
  -> AuthorityAdmissionAggregate
  -> IO (Either Text ())
commitRetainedAdmission directory custody held stable repository expected aggregate = do
  let projection = renderMirror (admissionOperations aggregate)
      record :: ArmedAdmissionCommit
      record = newArmedOperation (admissionDigest aggregate) (hexSha256 projection)
      armed = LazyByteString.toStrict (serialise record)
  created <- createJournalMember held armedCommitName armed
  observed <- readJournalMember held armedCommitName armedCommitLimit
  unchanged <- stable
  if created && observed == JournalMemberRead armed && unchanged
    then do
      mirrored <- writeRetainedMirror directory custody projection
      case mirrored of
        Left failure -> pure (Left (Text.pack failure))
        Right () -> do
          attempted <- compareAndSwapAuthorityAdmission repository expected aggregate
          restored <- settleArmedCommit directory custody held stable repository armed
          pure $ case restored of
            Right () -> Right ()
            Left failure -> case attempted of
              Left primary -> Left (primary <> "; " <> Text.pack failure)
              Right () -> Left (Text.pack failure)
    else pure (Left "retained-admission-commit-not-armed")

settleArmedCommit
  :: FilePath
  -> FilePath
  -> Fd
  -> IO Bool
  -> AuthorityAdmissionRepository IO revision
  -> ByteString.ByteString
  -> IO (Either String ())
settleArmedCommit directory custody held stable repository armed = do
  observed <- readAuthorityAdmission repository
  retained <- observeCommittedJournalMirror directory custody
  stillArmed <- readJournalMember held armedCommitName armedCommitLimit
  unchanged <- stable
  case (observed, unchanged, stillArmed) of
    (Right snapshot, True, JournalMemberRead current)
      | current == armed
      , Right record <- deserialiseOrFail (LazyByteString.fromStrict armed)
      , LazyByteString.toStrict (serialise (record :: ArmedAdmissionCommit)) == armed
      , let aggregate = authorityAdmissionSnapshotState snapshot
      , let operations = admissionOperations aggregate
      , Right (ResumeArmedOperation expected) <- resumeOperation (admissionDigest aggregate) record
      , expected == hexSha256 (renderMirror operations)
      , retained == JournalRead operations ->
          retireArmedCommit held
    _ -> pure (Left "the exact armed Authority commit is unconfirmed; recovery is required")

foreign import capi "unistd.h unlinkat" unlinkAt :: CInt -> CString -> CInt -> IO CInt

retireArmedCommit :: Fd -> IO (Either String ())
retireArmedCommit held@(Fd descriptor) = do
  removed <- try $ do
    withCString armedCommitName $ \name -> throwErrnoIfMinus1_ "retire armed Authority commit" (unlinkAt descriptor name 0)
    fileSynchronise held
  pure $ case (removed :: Either IOException ()) of
    Right () -> Right ()
    Left _ -> Left "the settled Authority commit could not be retired"

-- | Create a new mirror once. On restart, compare the retained mirror with the
-- committed aggregate; never overwrite a divergent or unreadable mirror, which
-- may contain the only evidence of an interrupted write.
initialiseJournalMirror
  :: FilePath
  -> AuthorityAdmissionRepository IO revision
  -> IO (Either String ())
initialiseJournalMirror directory =
  initialiseMirrorWith
    directory
    (observeJournalMirror directory)
    (pure True)
    (atomicWrite (mirrorPath directory))

initialiseRetainedJournalMirror
  :: FilePath
  -> FilePath
  -> AuthorityAdmissionRepository IO revision
  -> IO (Either String ())
initialiseRetainedJournalMirror directory custody repository = do
  initialized <- withJournalCustodyLease custody $ \held stable -> do
    armed <- readJournalMember held armedCommitName armedCommitLimit
    case armed of
      JournalMemberMissing -> initialiseBoundGenesis directory custody held stable repository
      JournalMemberRead bytes -> settleArmedCommit directory custody held stable repository bytes
      JournalMemberUnobservable -> pure (Left "the armed Authority commit is unobservable")
  pure (maybe (Left "retained-journal-lease-unavailable") id initialized)

initialiseMirrorWith
  :: FilePath
  -> IO JournalObservation
  -> IO Bool
  -> (ByteString.ByteString -> IO (Either String ()))
  -> AuthorityAdmissionRepository IO revision
  -> IO (Either String ())
initialiseMirrorWith directory readRetained reserve writeMirror repository = do
  writing <- guardPresent directory
  snapshot <- case writing of
    Right False -> readAuthorityAdmission repository
    _ -> pure (Left "journal-write-in-progress-or-unobservable")
  case snapshot of
    Left failure -> pure (Left ("the committed admission could not be read: " ++ Text.unpack failure))
    Right observed -> do
      let operations =
            observedOperations
              ( ledgerJournalObservation
                  (authorityAggregateSubmissionLedger (authorityAdmissionSnapshotState observed))
              )
      entries <- withJournalDirectory directory $ \held ->
        (,)
          <$> readJournalMember held "genesis.json" (ByteString.length genesisBytes)
          <*> readJournalMember held "admission.json" mirrorReadLimit
      case entries of
        Just (JournalMemberRead marker, _)
          | marker == genesisBytes -> do
              retained <- readRetained
              pure $
                if retained == JournalRead operations
                  then Right ()
                  else Left "the retained journal differs from the committed admission; recovery is required"
        Just (JournalMemberMissing, JournalMemberMissing) -> do
          reserved <- reserve
          if reserved
            then do
              mirrored <- writeMirror (renderMirror operations)
              case mirrored of
                Left failure -> pure (Left failure)
                Right () -> do
                  marked <- atomicWrite (genesisPath directory) genesisBytes
                  case marked of
                    Left failure -> pure (Left failure)
                    Right () -> do
                      retained <- readRetained
                      pure $
                        if retained == JournalRead operations
                          then Right ()
                          else Left "the initialized journal could not be confirmed"
            else pure (Left "the retained journal genesis reservation is missing or already used")
        Just (JournalMemberMissing, _) ->
          pure (Left "a journal mirror exists without its genesis; recovery is required")
        _ -> pure (Left "the retained journal genesis is invalid or unobservable; recovery is required")

observeRetainedJournalMirror :: FilePath -> FilePath -> IO JournalObservation
observeRetainedJournalMirror directory custody = do
  before <- commitIdle
  initializing <- observeJournalInitialization directory custody
  retained <- observeCommittedJournalMirror directory custody
  initialized <- observeJournalInitialization directory custody
  after <- commitIdle
  pure $ case (before && after, initializing == initialized, initialized) of
    (True, True, JournalInitializationLegacy) -> retained
    (True, True, JournalInitializationComplete _) -> retained
    (True, True, JournalInitializationArmed identifier) -> JournalRead [(identifier, OperationUnresolved)]
    (True, _, _) -> JournalUnobservable "the Authority journal initialization is unobservable"
    _ -> JournalUnobservable "an armed Authority commit is unsettled or unobservable"
 where
  commitIdle =
    (== Just JournalMemberMissing)
      <$> withJournalDirectory custody (\held -> readJournalMember held armedCommitName armedCommitLimit)

observeCommittedJournalMirror :: FilePath -> FilePath -> IO JournalObservation
observeCommittedJournalMirror directory custody = do
  confirmed <- observeGenesisIntent custody
  commitment <- observeMirrorCommitment custody
  case (confirmed, commitment) of
    (True, Just expected) ->
      observeJournalMirrorWith directory $ \bytes -> do
        closing <- observeMirrorCommitment custody
        pure (closing == Just expected && hexSha256 bytes == expected)
    (False, _) -> pure (JournalUnobservable "the retained journal genesis reservation is unobservable")
    (_, Nothing) -> pure (JournalUnobservable "the retained journal commitment is unobservable")

-- | Read the mirror as an admission observation. Without the genesis record the
-- journal is unobservable (never initialized by this Authority), not empty.
observeJournalMirror :: FilePath -> IO JournalObservation
observeJournalMirror directory = observeJournalMirrorWith directory (const (pure True))

observeJournalMirrorWith :: FilePath -> (ByteString.ByteString -> IO Bool) -> IO JournalObservation
observeJournalMirrorWith directory verify = do
  writing <- guardPresent directory
  case writing of
    Right False -> do
      observed <- withJournalDirectory directory observeAfterGuard
      pure (maybe (JournalUnobservable "the retained journal directory is unobservable") id observed)
    _ -> pure (JournalUnobservable "a journal write is in progress or requires recovery")
 where
  observeAfterGuard held = do
    genesis <- readJournalMember held "genesis.json" (ByteString.length genesisBytes)
    case genesis of
      JournalMemberMissing -> pure (JournalUnobservable "the journal was never initialized by this Authority")
      JournalMemberRead marker
        | marker == genesisBytes -> do
            contents <- readJournalMember held "admission.json" mirrorReadLimit
            writingAfter <- guardPresent directory
            case writingAfter of
              Right False -> case contents of
                JournalMemberMissing -> pure (JournalUnobservable "the journal mirror is missing although the journal was initialized")
                JournalMemberUnobservable -> pure (JournalUnobservable "the retained journal mirror is unobservable")
                JournalMemberRead bytes -> do
                  matched <- verify bytes
                  pure $
                    if matched
                      then
                        maybe
                          (JournalUnobservable "the journal mirror could not be decoded")
                          JournalRead
                          (parseMirror bytes)
                      else JournalUnobservable "the journal mirror differs from the retained commitment"
              _ -> pure (JournalUnobservable "a journal write is in progress or requires recovery")
      _ -> pure (JournalUnobservable "the retained journal genesis is invalid or unobservable")
