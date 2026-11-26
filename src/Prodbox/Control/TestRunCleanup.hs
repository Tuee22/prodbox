{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Dispose of one registered test deployment after the supported control
-- removal has settled. Non-secret scenario reports live outside the root.
module Prodbox.Control.TestRunCleanup
  ( registerSettledTestRun
  , retireSettledTestRun
  , resumeTestRunCleanup
  ) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (guard, unless, when)
import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.Bits ((.&.))
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CUInt (..))
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRootGeneration
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , deploymentScope
  , scopeEnvironment
  , scopeIdentifier
  , scopeProjectAnchor
  , validRootGeneration
  , withScopeRootDescriptor
  )
import Prodbox.Control.AuthorityJournalClient (admitKindTeardown)
import Prodbox.Control.Delete (deleteNewTestIdentity, deleteStepCompleted)
import Prodbox.Control.KindIntent
  ( KindIntentObservation (KindIntentMatches)
  , observeKindOwnerFamilyIntent
  )
import Prodbox.Control.KindLease
  ( KindLeaseOutcome (KindLeaseCompleted, KindLeaseRootChanged)
  , withKindLease
  , withLockedKindScope
  )
import Prodbox.Control.KindNodeBootstrap
  ( JournalRecordObservation (..)
  , observeJournalRecord
  , writeJournalRecord
  )
import Prodbox.Control.ManagementRestore (managementRestoreIdle)
import Prodbox.Control.TreeInventory qualified as Tree
import System.Directory (canonicalizePath)
import System.FilePath ((</>))
import System.IO (hClose, hFlush)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.Types (Fd (..), UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

foreign import capi "stdio.h renameat2"
  renameAt :: CInt -> CString -> CInt -> CString -> CUInt -> IO CInt

foreign import capi "stdio.h value RENAME_NOREPLACE" noReplace :: CUInt

data RegisteredRun = RegisteredRun
  { registeredId :: !String
  , registeredGeneration :: !String
  , registeredOperation :: !String
  , registeredEvidence :: !String
  , registeredRoot :: !(Integer, Integer)
  }
  deriving (Eq)

registrationName :: FilePath
registrationName = "test-run-retirement.json"

runRecord :: RegisteredRun -> Aeson.Value
runRecord record =
  Aeson.object
    [ "schema_version" .= (1 :: Int)
    , "kind" .= ("settled-test-run" :: String)
    , "run_id" .= registeredId record
    , "root_generation" .= registeredGeneration record
    , "kind_operation" .= registeredOperation record
    , "scenario_evidence_run" .= registeredEvidence record
    , "root_identity" .= registeredRoot record
    ]

parseRunRecord :: Aeson.Value -> Maybe RegisteredRun
parseRunRecord value = do
  record <- Aeson.parseMaybe parser value
  guard (runRecord record == value)
  pure record
 where
  parser = Aeson.withObject "settled test run" $ \fields -> do
    record <-
      RegisteredRun
        <$> fields .: "run_id"
        <*> fields .: "root_generation"
        <*> fields .: "kind_operation"
        <*> fields .: "scenario_evidence_run"
        <*> fields .: "root_identity"
    unless
      ( all
          validRootGeneration
          [registeredGeneration record, registeredOperation record, registeredEvidence record]
          && fst (registeredRoot record) >= 0
          && snd (registeredRoot record) > 0
      )
      (fail "invalid run identity")
    pure record

-- | Called only after publication of successful scenario and exact cleanup
-- reports. Registration does not authorize retirement of a different or
-- subsequently reconciled operation.
registerSettledTestRun :: BootstrapProjection -> String -> String -> IO Bool
registerSettledTestRun bootstrap operation evidence
  | scopeEnvironment scope /= Test = pure False
  | not (all validRootGeneration [operation, evidence]) = pure False
  | otherwise = do
      result <- withKindLease bootstrap $ \stable -> do
        current <- observeKindOwnerFamilyIntent bootstrap
        observed <- withScopeRootDescriptor scope $ \root rootStable -> do
          identity <- rootIdentity root
          held <- (&&) <$> rootStable <*> stable
          if current == KindIntentMatches operation && held
            then do
              let record = RegisteredRun run generation operation evidence identity
              _ <- writeJournalRecord bootstrap registrationName (runRecord record)
              (== JournalRecordObserved (runRecord record)) <$> observeJournalRecord bootstrap registrationName
            else pure False
        pure (observed == Right True)
      pure (result == Right (KindLeaseCompleted True))
 where
  scope = bootstrapScope bootstrap
  run = scopeIdentifier scope
  generation = Text.unpack (bootstrapRootGeneration bootstrap)

-- | Finish an already quarantined run without reopening its deleted config.
-- A pre-move receipt with the original root still present requires the
-- normal scoped removal and validation path again.
resumeTestRunCleanup :: FilePath -> String -> IO (Either String Bool)
resumeTestRunCleanup project run = do
  observed <- try (Files.getSymbolicLinkStatus (project </> ".test-data"))
  case observed of
    Left failure
      | isDoesNotExistError failure -> pure (Right False)
      | otherwise -> pure (Left "test cleanup storage is unobservable")
    Right _ -> withCleanupParent project run $ \parent stable ->
      recoverRetirement parent stable run

retireSettledTestRun :: BootstrapProjection -> String -> IO (Either String Bool)
retireSettledTestRun bootstrap run
  | scopeEnvironment scope /= Test || scopeIdentifier scope /= run =
      pure (Left "the selected config must name this exact test run")
  | otherwise = withCleanupParent (scopeProjectAnchor scope) run $ \parent stable -> do
      recovered <- recoverRetirement parent stable run
      case recovered of
        Right False -> do
          record <- observeJournalRecord bootstrap registrationName
          case record of
            JournalRecordObserved value
              | Just registered <- parseRunRecord value
              , registeredId registered == run
              , registeredGeneration registered == Text.unpack (bootstrapRootGeneration bootstrap) -> do
                  authorized <- observeRegisteredRoot registered
                  admission <-
                    if authorized then admitKindTeardown bootstrap else pure (Left "registered root changed")
                  case admission of
                    Right () -> do
                      removed <- deleteNewTestIdentity bootstrap
                      if not (null removed) && all deleteStepCompleted removed
                        then quarantineAndFinish parent stable registered
                        else pure (Left "supported control deletion did not confirm settlement and exact absence")
                    Left reason -> pure (Left reason)
            _ -> pure (Left "the selected test run has no successful registered cleanup evidence")
        _ -> pure recovered
 where
  scope = bootstrapScope bootstrap
  observeRegisteredRoot registered = do
    operation <- observeKindOwnerFamilyIntent bootstrap
    observed <- withScopeRootDescriptor scope $ \root stable -> do
      same <- (== registeredRoot registered) <$> rootIdentity root
      (&&) same <$> stable
    pure (observed == Right True && operation == KindIntentMatches (registeredOperation registered))
  quarantineAndFinish parent parentStable registered = do
    moved <- withKindLease bootstrap $ \stable -> do
      current <- observeRegisteredRoot registered
      idle <- managementRestoreIdle bootstrap
      held <- (&&) <$> stable <*> parentStable
      if current && idle && held
        then moveRegisteredRoot parent registered
        else pure False
    case moved of
      Right (KindLeaseRootChanged True) -> recoverRetirement parent parentStable run
      _ -> pure (Left "the registered root could not be quarantined under its original scope lease")

withCleanupParent
  :: FilePath -> String -> (Fd -> IO Bool -> IO (Either String Bool)) -> IO (Either String Bool)
withCleanupParent project run action
  | Left _ <- deploymentScope project Test run 1 =
      pure (Left "expected an anchored test run identity")
  | otherwise = do
      result <- try $ bracket (Posix.openFd path Posix.ReadOnly directoryFlags) Posix.closeFd $ \parent -> do
        expected <- rootIdentity parent
        owner <- getEffectiveUserID
        let stable = do
              canonical <- canonicalizePath path
              named <- Files.getSymbolicLinkStatus path
              held <- Files.getFdStatus parent
              pure
                ( canonical == path
                    && all
                      ( \info -> Files.isDirectory info && Files.fileOwner info == owner && Files.fileMode info .&. 0o077 == 0
                      )
                      [named, held]
                    && all ((== expected) . fileIdentity) [named, held]
                )
        leased <- withLockedKindScope parent stable (action parent)
        pure $ case leased of
          Right (KindLeaseCompleted value) -> value
          _ -> Left "the original test cleanup directory lease did not settle"
      pure
        ( either
            (const (Left "test cleanup storage is unavailable"))
            id
            (result :: Either IOException (Either String Bool))
        )
 where
  path = project </> ".test-data"

moveRegisteredRoot :: Fd -> RegisteredRun -> IO Bool
moveRegisteredRoot parent record = openDirectory parent run $ \root -> do
  named <- rootIdentity root
  sameMount <- Tree.sameTreeMount parent root
  prior <- readRecord parent (claimFile run)
  safe <- case treeLimits of
    Just limits -> isObserved <$> Tree.observeTreeInventory Tree.SettledTestTree limits root
    Nothing -> pure False
  if named /= registeredRoot record || not sameMount || not safe || maybe False (/= record) prior
    then pure False
    else do
      quarantined <- nameExists parent (quarantineName run)
      if quarantined
        then pure False
        else do
          when (prior == Nothing) (publishRecord parent (claimFile run) record)
          confirmed <- readRecord parent (claimFile run)
          if confirmed /= Just record
            then pure False
            else do
              move parent run (quarantineName run)
              fileSynchronise parent
              pure True
 where
  run = registeredId record
  isObserved (Tree.TreeObserved _) = True
  isObserved _ = False

recoverRetirement :: Fd -> IO Bool -> String -> IO (Either String Bool)
recoverRetirement parent stable run = do
  issued <- readRecord parent (claimFile run)
  moved <- readRecord parent (moveFile run)
  live <- nameExists parent run
  quarantined <- nameExists parent (quarantineName run)
  case (issued, moved, live, quarantined) of
    (Nothing, Nothing, _, False) -> pure (Right False)
    (Just issuedRecord, Nothing, True, False)
      | registeredId issuedRecord == run -> pure (Right False)
    (Just issuedRecord, movedRecord, False, True)
      | registeredId issuedRecord == run && maybe True (== issuedRecord) movedRecord ->
          purgeQuarantine parent stable issuedRecord movedRecord
    (Just issuedRecord, Just movedRecord, False, False)
      | registeredId issuedRecord == run && issuedRecord == movedRecord -> Right <$> stable
    _ -> pure (Left "the retired root and its original cleanup receipts could not be matched")

purgeQuarantine :: Fd -> IO Bool -> RegisteredRun -> Maybe RegisteredRun -> IO (Either String Bool)
purgeQuarantine parent stable record moved = case treeLimits of
  Nothing -> pure (Left "the test-root cleanup budget is unavailable")
  Just limits -> do
    inventory <- openDirectory parent name $ \root -> do
      observed <- rootIdentity root
      sameMount <- Tree.sameTreeMount parent root
      if observed == registeredRoot record && sameMount
        then do
          tree <- Tree.observeTreeInventory Tree.SettledTestTree limits root
          pure $ case tree of
            Tree.TreeObserved value -> Just value
            _ -> Nothing
        else pure Nothing
    case inventory of
      Nothing -> pure (Left "the original quarantined tree could not be observed safely")
      Just exact -> do
        when (moved == Nothing) (publishRecord parent (moveFile run) record)
        confirmed <- readRecord parent (moveFile run)
        if confirmed /= Just record
          then pure (Left "the quarantined root move could not be durably confirmed")
          else do
            removed <- Tree.removeObservedTree Tree.SettledTestTree limits parent name exact stable
            original <- nameExists parent run
            remainder <- nameExists parent name
            pure $
              if removed && not original && not remainder
                then Right True
                else Left "test-root cleanup is incomplete; resume the same registered run"
 where
  run = registeredId record
  name = quarantineName run

treeLimits :: Maybe Tree.TreeInventoryLimits
treeLimits = Tree.treeInventoryLimits 20000 (12 * 1024 * 1024 * 1024) 32 90000000

claimFile, moveFile, quarantineName :: String -> FilePath
claimFile run = ".cleanup-" ++ run ++ "-admitted.json"
moveFile run = ".cleanup-" ++ run ++ "-quarantined.json"
quarantineName run = ".cleanup-" ++ run ++ "-root"

fileFlags, directoryFlags :: Posix.OpenFileFlags
fileFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
directoryFlags = fileFlags {Posix.directory = True}

openDirectory :: Fd -> FilePath -> (Fd -> IO a) -> IO a
openDirectory parent name =
  bracket (Posix.openFdAt (Just parent) name Posix.ReadOnly directoryFlags) Posix.closeFd

rootIdentity :: Fd -> IO (Integer, Integer)
rootIdentity descriptor = fileIdentity <$> Files.getFdStatus descriptor

fileIdentity :: Files.FileStatus -> (Integer, Integer)
fileIdentity status = (toInteger (Files.deviceID status), toInteger (Files.fileID status))

namedPath :: Fd -> FilePath -> FilePath
namedPath (Fd descriptor) name = "/proc/self/fd/" ++ show descriptor </> name

nameExists :: Fd -> FilePath -> IO Bool
nameExists parent name = do
  found <- try (Files.getSymbolicLinkStatus (namedPath parent name))
  case found of
    Right _ -> pure True
    Left failure | isDoesNotExistError failure -> pure False
    Left failure -> ioError failure

readRecord :: Fd -> FilePath -> IO (Maybe RegisteredRun)
readRecord parent name = traverse decode =<< readRecordBytes parent name
 where
  decode bytes = case Aeson.decodeStrict bytes >>= parseRunRecord of
    Just record -> pure record
    _ -> ioError (userError "test cleanup record is corrupt")

readRecordBytes :: Fd -> FilePath -> IO (Maybe Bytes.ByteString)
readRecordBytes parent name = do
  exists <- nameExists parent name
  if not exists
    then pure Nothing
    else
      Just
        <$> bracket (Posix.openFdAt (Just parent) name Posix.ReadOnly fileFlags) Posix.closeFd readExact
 where
  readExact source = do
    owner <- getEffectiveUserID
    info <- Files.getFdStatus source
    unless
      (privateRecord owner info)
      (ioError (userError "unsafe test cleanup record"))
    copy <- Posix.dup source
    bytes <- bracket (Posix.fdToHandle copy) hClose (\file -> Bytes.hGet file 4097)
    after <- Files.getFdStatus source
    named <- Files.getSymbolicLinkStatus (namedPath parent name)
    let same file =
          fileIdentity file == fileIdentity info
            && Files.statusChangeTimeHiRes file == Files.statusChangeTimeHiRes info
    if Bytes.length bytes <= 4096 && same after && same named
      then pure bytes
      else ioError (userError "test cleanup record changed or exceeded its bound")

privateRecord :: UserID -> Files.FileStatus -> Bool
privateRecord owner info =
  Files.isRegularFile info
    && Files.fileOwner info == owner
    && Files.fileMode info .&. 0o077 == 0
    && Files.linkCount info == 1

publishRecord :: Fd -> FilePath -> RegisteredRun -> IO ()
publishRecord parent name record = do
  let temporary = name ++ ".pending"
      create = fileFlags {Posix.creat = Just 0o600, Posix.exclusive = True}
      bytes = Lazy.toStrict (Aeson.encode (runRecord record))
  staged <- readRecordBytes parent temporary
  writeFlags <- case staged of
    Nothing -> pure create
    Just prior
      | prior `Bytes.isPrefixOf` bytes -> pure fileFlags
      | otherwise -> ioError (userError "test cleanup record collision")
  bracket (Posix.openFdAt (Just parent) temporary Posix.WriteOnly writeFlags) Posix.closeFd $ \target -> do
    owner <- getEffectiveUserID
    info <- Files.getFdStatus target
    named <- Files.getSymbolicLinkStatus (namedPath parent temporary)
    unless
      (privateRecord owner info && fileIdentity info == fileIdentity named)
      (ioError (userError "unsafe test cleanup staging record"))
    copy <- Posix.dup target
    bracket (Posix.fdToHandle copy) hClose $ \file -> Bytes.hPut file bytes >> hFlush file
    fileSynchronise target
  confirmed <- readRecordBytes parent temporary
  unless (confirmed == Just bytes) (ioError (userError "test cleanup staging record changed"))
  move parent temporary name
  fileSynchronise parent

move :: Fd -> FilePath -> FilePath -> IO ()
move (Fd parent) old new =
  withCString old $ \source -> withCString new $ \destination ->
    throwErrnoIfMinus1_ "move test cleanup member" (renameAt parent source parent destination noReplace)
