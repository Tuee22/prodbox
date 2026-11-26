{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

-- | Bounded cleanup of an explicitly captured private fixture tree.
module Prodbox.Test.FixtureTree
  ( FixtureTree
  , captureFixtureTree
  , cleanupFixtureTree
  , cleanupFixtureTrees
  , FixtureRootClaim
  , claimEmptyFixtureRoot
  , cleanupNeverSentKindFixturePublication
  , cleanupSettledKindFixturePublication
  ) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (unless)
import Data.Bits ((.&.))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isPrefixOf, sort)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Config.BootstrapProjection (BootstrapProjection, bootstrapScope)
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , scopeEnvironment
  , scopeProjectAnchor
  )
import Prodbox.Control.KindControllerReceipt qualified as Receipt
import Prodbox.Control.KindControllerRequest qualified as Request
import Prodbox.Control.KindFamilyRecovery qualified as Recovery
import Prodbox.Control.KindIntent
  ( KindIntentObservation (KindIntentMatches)
  , observeKindOwnerFamilyIntent
  )
import Prodbox.Control.KindLease qualified as Lease
import Prodbox.Subprocess.HostControllerInputRetirement qualified as InputRetirement
import Prodbox.Subprocess.HostControllerInputs qualified as Inputs
import Prodbox.Subprocess.HostControllerPublication qualified as Publication
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import System.Directory (canonicalizePath, listDirectory, removeDirectory, removeFile)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , fileMode
  , fileOwner
  , fileSize
  , getFdStatus
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , isSymbolicLink
  , linkCount
  , modificationTimeHiRes
  , statusChangeTimeHiRes
  )
import System.Posix.IO qualified as Posix
import System.Posix.Types (Fd (..), UserID)
import System.Posix.User (getEffectiveUserID)

data FixtureTree = FixtureTree FilePath FileStatus Entry
data FixtureRootClaim = FixtureRootClaim FilePath FileStatus FilePath FileStatus [FilePath]
data Entry = Entry FileStatus [(FilePath, Entry)]

directoryFlags :: Posix.OpenFileFlags
directoryFlags = Posix.defaultFileFlags {Posix.directory = True, Posix.nofollow = True, Posix.cloexec = True}

fdPath :: Fd -> FilePath
fdPath (Fd raw) = "/proc/self/fd/" ++ show raw

sameIdentity :: FileStatus -> FileStatus -> Bool
sameIdentity a b =
  deviceID a == deviceID b
    && fileID a == fileID b
    && fileOwner a == fileOwner b
    && fileMode a == fileMode b

sameEntry :: FileStatus -> FileStatus -> Bool
sameEntry a b =
  sameIdentity a b
    && fileSize a == fileSize b
    && modificationTimeHiRes a == modificationTimeHiRes b
    && statusChangeTimeHiRes a == statusChangeTimeHiRes b
    && linkCount a == linkCount b

safeEntry :: UserID -> FileStatus -> Bool
safeEntry owner status =
  fileOwner status == owner
    && ( (isDirectory status && fileMode status .&. 0o077 == 0)
           || (isRegularFile status && linkCount status == 1 && fileMode status .&. 0o077 == 0)
           || isSymbolicLink status
       )

withDirectory :: Fd -> FilePath -> (Fd -> IO a) -> IO a
withDirectory parent name = bracket (Posix.openFdAt (Just parent) name Posix.ReadOnly directoryFlags) Posix.closeFd

-- Claim an empty test-owned root before the command creates any inputs. The
-- claim is valid only while the same private directory remains in place.
claimEmptyFixtureRoot :: FilePath -> IO (Maybe FixtureRootClaim)
claimEmptyFixtureRoot path = do
  attempted <- try $ do
    canonical <- canonicalizePath path
    owner <- getEffectiveUserID
    let runtime = "/run/user/" ++ show owner
    runtimeStatus <- getSymbolicLinkStatus runtime
    unless
      (isDirectory runtimeStatus && safeEntry owner runtimeStatus)
      (ioError (userError "unsafe fixture runtime"))
    bracket (Posix.openFd runtime Posix.ReadOnly directoryFlags) Posix.closeFd $ \runtimeFd -> do
      runtimeHeld <- getFdStatus runtimeFd
      unless (sameIdentity runtimeStatus runtimeHeld) (ioError (userError "fixture runtime changed"))
      prior <- filter ("prodbox-kind-family-inputs-" `isPrefixOf`) <$> listDirectory (fdPath runtimeFd)
      unless (length prior <= 10000) (ioError (userError "fixture runtime inventory exceeds bound"))
      named <- getSymbolicLinkStatus path
      bracket (Posix.openFd path Posix.ReadOnly directoryFlags) Posix.closeFd $ \directory -> do
        held <- getFdStatus directory
        names <- listDirectory (fdPath directory)
        unless
          ( canonical == path
              && isDirectory named
              && safeEntry owner named
              && sameEntry named held
              && null names
          )
          (ioError (userError "fixture root is not empty and private"))
        runtimeAfter <- getSymbolicLinkStatus runtime
        runtimeHeldAfter <- getFdStatus runtimeFd
        unless
          (sameIdentity runtimeStatus runtimeAfter && sameIdentity runtimeAfter runtimeHeldAfter)
          (ioError (userError "fixture runtime changed"))
        pure (FixtureRootClaim path held runtime runtimeStatus prior)
  pure (either (const Nothing) Just (attempted :: Either IOException FixtureRootClaim))

-- This is test-fixture teardown, not a lifecycle deletion. It accepts only a
-- previously claimed test root, an exact owner-first operation and a durable
-- never-sent publication whose inputs are already terminal. Unknown entries,
-- changed trees, live publishers and foreign scopes are left untouched.
cleanupNeverSentKindFixturePublication
  :: FixtureRootClaim -> BootstrapProjection -> String -> IO Bool
cleanupNeverSentKindFixturePublication claim@(FixtureRootClaim anchor _ _ _ prior) bootstrap operation
  | scopeEnvironment scope /= Test || scopeProjectAnchor scope /= anchor = pure False
  | otherwise = case Request.kindControllerOperationKey operation of
      Nothing -> pure False
      Just key -> do
        now <- getMonotonicTimeNSec
        let budget = 10000000000 :: Word64
        if now > maxBound - budget
          then pure False
          else do
            let ending = now + budget
            uid <- getEffectiveUserID
            let path = Publication.hostControllerPublishedDirectory Identity.KindController uid key
            if takeFileName path `elem` prior
              then pure False
              else do
                result <- Lease.withRecoveredKindOperation bootstrap operation $ \stable -> do
                  rootBefore <- fixtureClaimStable claim
                  protocol <- observeKindOwnerFamilyIntent bootstrap
                  launch <- Receipt.observeFamilyLaunch bootstrap operation stable
                  marker <- Receipt.observeFamilyPublicationAttempt bootstrap operation stable
                  unchanged <- stable
                  case (rootBefore, protocol, launch, marker, unchanged) of
                    ( True
                      , KindIntentMatches current
                      , Receipt.FamilyLaunchObserved request
                      , Receipt.FamilyLaunchObserved attempted
                      , True
                      )
                        | current == operation && request == attempted -> do
                            namesBefore <- try (sort <$> listDirectory path) :: IO (Either IOException [FilePath])
                            let expectedNames = ["publication-birth.cbor", "retirement-prepared.cbor", "retirement-terminal.cbor"]
                            if namesBefore /= Right expectedNames
                              then pure False
                              else do
                                statuses <-
                                  try (traverse (getSymbolicLinkStatus . (path </>)) expectedNames)
                                    :: IO (Either IOException [FileStatus])
                                snapshot <- case statuses of
                                  Right files | all (\file -> isRegularFile file && safeEntry uid file) files -> captureFixtureTree path
                                  _ -> pure Nothing
                                case snapshot of
                                  Nothing -> pure False
                                  Just tree -> do
                                    retired <- InputRetirement.recoverNeverSentHostControllerInputs ending Identity.KindController key
                                    verified <- Publication.withRecoveredHostPublicationNeverSent Identity.KindController ending key $ \owner -> do
                                      before <- Publication.verifyHostPublicationNeverSentBefore ending owner
                                      unchangedTree <- verifyFixtureTree tree
                                      after <- Publication.verifyHostPublicationNeverSentBefore ending owner
                                      pure (before, unchangedTree, after)
                                    rootAfter <- fixtureClaimStable claim
                                    held <- stable
                                    case (retired, verified, rootAfter, held) of
                                      (Right _, Right (Right (), True, Right ()), True, True) -> do
                                        removed <- cleanupFixtureTree tree
                                        final <- stable
                                        rootFinal <- fixtureClaimStable claim
                                        pure (removed && final && rootFinal)
                                      _ -> pure False
                    _ -> pure False
                pure (result == Lease.KindOperationCallbackReturned True)
 where
  scope = bootstrapScope bootstrap

fixtureClaimStable :: FixtureRootClaim -> IO Bool
fixtureClaimStable (FixtureRootClaim path expected runtime runtimeExpected _) = do
  observed <- try $ do
    named <- getSymbolicLinkStatus path
    bracket (Posix.openFd path Posix.ReadOnly directoryFlags) Posix.closeFd $ \directory -> do
      held <- getFdStatus directory
      currentRuntime <- getSymbolicLinkStatus runtime
      pure
        ( sameIdentity expected named
            && sameIdentity named held
            && sameIdentity runtimeExpected currentRuntime
        )
  pure (either (const False) id (observed :: Either IOException Bool))

-- The caller supplies the independently observed absence of fixture provider
-- effects. A settled manager family, exact input retirement and unchanged
-- fixture scope are all required before its test-only metadata can be removed.
cleanupSettledKindFixturePublication
  :: FixtureRootClaim -> BootstrapProjection -> String -> IO Bool -> IO Bool
cleanupSettledKindFixturePublication claim@(FixtureRootClaim anchor _ _ _ prior) bootstrap operation noEffects
  | scopeEnvironment scope /= Test || scopeProjectAnchor scope /= anchor = pure False
  | otherwise = case Request.kindControllerOperationKey operation of
      Nothing -> pure False
      Just key -> do
        now <- getMonotonicTimeNSec
        let budget = 30000000000 :: Word64
        if now > maxBound - budget
          then pure False
          else do
            uid <- getEffectiveUserID
            let ending = now + budget
                path = Publication.hostControllerPublishedDirectory Identity.KindController uid key
                requestPath = path </> Publication.hostControllerRequestName
                submission = takeFileName (Inputs.hostControllerSubmissionPath requestPath key)
                names =
                  sort
                    [ "publication-birth.cbor"
                    , "publication-possible-send.cbor"
                    , "retirement-prepared.cbor"
                    , "retirement-terminal.cbor"
                    , submission
                    ]
            if takeFileName path `elem` prior
              then pure False
              else do
                settled <- Recovery.withKindFamilyRetirement ending bootstrap operation $ \owner ->
                  Lease.withRecoveredKindOperation bootstrap operation $ \stable -> do
                    root <- fixtureClaimStable claim
                    protocol <- observeKindOwnerFamilyIntent bootstrap
                    launch <- Receipt.observeFamilyLaunch bootstrap operation stable
                    marker <- Receipt.observeFamilyPublicationAttempt bootstrap operation stable
                    effectFree <- noEffects
                    physical <- Recovery.verifyKindFamilyRetirement owner stable
                    case (root, protocol, launch, marker, effectFree, physical) of
                      ( True
                        , KindIntentMatches current
                        , Receipt.FamilyLaunchObserved request
                        , Receipt.FamilyLaunchObserved attempted
                        , True
                        , Right ()
                        )
                          | current == operation && request == attempted -> do
                              retired <- Recovery.retireKindFamilyPublishedInputs ending owner stable
                              listed <- try (sort <$> listDirectory path) :: IO (Either IOException [FilePath])
                              statuses <-
                                try (traverse (getSymbolicLinkStatus . (path </>)) names) :: IO (Either IOException [FileStatus])
                              snapshot <- case (retired, listed, statuses) of
                                (Recovery.KindFamilyInputRetirement (Right ()) (Right ()) True, Right actual, Right files)
                                  | actual == names && all (\file -> isRegularFile file && safeEntry uid file) files ->
                                      captureFixtureTree path
                                _ -> pure Nothing
                              physicalAfter <- Recovery.verifyKindFamilyRetirement owner stable
                              rootAfter <- fixtureClaimStable claim
                              effectsAfter <- noEffects
                              pure $
                                if physicalAfter == Right () && rootAfter && effectsAfter then (request,) <$> snapshot else Nothing
                      _ -> pure Nothing
                case settled of
                  Recovery.KindFamilyRetirementReturned
                    (Lease.KindOperationCallbackReturned (Just (request, tree)))
                    (Right ())
                    True -> do
                      final <- Lease.withRecoveredKindOperation bootstrap operation $ \stable -> do
                        root <- fixtureClaimStable claim
                        protocol <- observeKindOwnerFamilyIntent bootstrap
                        launch <- Receipt.observeFamilyLaunch bootstrap operation stable
                        marker <- Receipt.observeFamilyPublicationAttempt bootstrap operation stable
                        effectFree <- noEffects
                        held <- stable
                        if root
                          && protocol == KindIntentMatches operation
                          && launch == Receipt.FamilyLaunchObserved request
                          && marker == Receipt.FamilyLaunchObserved request
                          && effectFree
                          && held
                          then do
                            removed <- cleanupFixtureTree tree
                            after <- stable
                            rootAfter <- fixtureClaimStable claim
                            effectsAfter <- noEffects
                            pure (removed && after && rootAfter && effectsAfter)
                          else pure False
                      pure (final == Lease.KindOperationCallbackReturned True)
                  _ -> pure False
 where
  scope = bootstrapScope bootstrap

-- Ordinary callers capture after exclusively creating the tree and before
-- handing it to a command. The settled-publication teardown above also
-- verifies its capture against the retained owner before removing it.
-- No special files are accepted.
captureFixtureTree :: FilePath -> IO (Maybe FixtureTree)
captureFixtureTree path = do
  result <- try $ bracket (Posix.openFd (takeDirectory path) Posix.ReadOnly directoryFlags) Posix.closeFd $ \parent -> do
    owner <- getEffectiveUserID
    parentStatus <- getFdStatus parent
    unless
      (safeEntry owner parentStatus && isDirectory parentStatus)
      (ioError (userError "unsafe fixture parent"))
    count <- newIORef (0 :: Int)
    let capture depth directory name = do
          modifyIORef' count (+ 1)
          total <- readIORef count
          unless (depth <= 8 && total <= 256) (ioError (userError "fixture tree exceeds bound"))
          status <- getSymbolicLinkStatus (fdPath directory </> name)
          unless (safeEntry owner status) (ioError (userError "unsafe fixture entry"))
          if isDirectory status
            then withDirectory directory name $ \child -> do
              held <- getFdStatus child
              unless (sameEntry status held) (ioError (userError "fixture directory changed"))
              names <- sort <$> listDirectory (fdPath child)
              entries <- traverse (\childName -> (,) childName <$> capture (depth + 1) child childName) names
              final <- getFdStatus child
              unless (sameEntry held final) (ioError (userError "fixture directory changed"))
              pure (Entry status entries)
            else pure (Entry status [])
    entry <- capture (0 :: Int) parent (takeFileName path)
    pure (FixtureTree path parentStatus entry)
  pure (either (const Nothing) Just (result :: Either IOException FixtureTree))

-- Refuse before deletion if anything differs, including an unexpected entry.
-- If a later check or removal fails, return False and retain what remains.
cleanupFixtureTree :: FixtureTree -> IO Bool
cleanupFixtureTree (FixtureTree path parentStatus expected) = do
  result <- try $ bracket (Posix.openFd (takeDirectory path) Posix.ReadOnly directoryFlags) Posix.closeFd $ \parent -> do
    currentParent <- getFdStatus parent
    unless (sameIdentity parentStatus currentParent) (ioError (userError "fixture parent changed"))
    verifyEntry parent (takeFileName path) expected
    remove parent (takeFileName path) expected
    absent <- try (getSymbolicLinkStatus (fdPath parent </> takeFileName path))
    pure $ case absent of
      Left failure -> isDoesNotExistError (failure :: IOException)
      Right _ -> False
  pure (either (const False) id (result :: Either IOException Bool))
 where
  remove parent name (Entry status children) = do
    actual <- getSymbolicLinkStatus (fdPath parent </> name)
    unless (sameIdentity status actual) (ioError (userError "fixture entry replaced"))
    if isDirectory status
      then withDirectory parent name $ \directory -> do
        held <- getFdStatus directory
        unless (sameIdentity status held) (ioError (userError "fixture directory replaced"))
        names <- sort <$> listDirectory (fdPath directory)
        unless (names == map fst children) (ioError (userError "fixture entries changed"))
        mapM_ (uncurry (remove directory)) children
        final <- getSymbolicLinkStatus (fdPath parent </> name)
        unless (sameIdentity status final) (ioError (userError "fixture directory replaced"))
        removeDirectory (fdPath parent </> name)
      else do
        unless (sameEntry status actual) (ioError (userError "fixture entry changed"))
        removeFile (fdPath parent </> name)

verifyEntry :: Fd -> FilePath -> Entry -> IO ()
verifyEntry parent name (Entry status children) = do
  actual <- getSymbolicLinkStatus (fdPath parent </> name)
  unless (sameEntry status actual) (ioError (userError "fixture entry changed"))
  if isDirectory status
    then withDirectory parent name $ \directory -> do
      held <- getFdStatus directory
      unless (sameEntry status held) (ioError (userError "fixture directory changed"))
      names <- sort <$> listDirectory (fdPath directory)
      unless (names == map fst children) (ioError (userError "fixture entries changed"))
      mapM_ (uncurry (verifyEntry directory)) children
    else pure ()

verifyFixtureTree :: FixtureTree -> IO Bool
verifyFixtureTree (FixtureTree path parentStatus expected) = do
  result <- try $ bracket (Posix.openFd (takeDirectory path) Posix.ReadOnly directoryFlags) Posix.closeFd $ \parent -> do
    currentParent <- getFdStatus parent
    unless (sameIdentity parentStatus currentParent) (ioError (userError "fixture parent changed"))
    verifyEntry parent (takeFileName path) expected
  pure $ either (const False) (const True) (result :: Either IOException ())

-- Check every tree first and stop on the first failed removal. Callers put
-- recovery configuration last, after the fixtures whose state it describes.
cleanupFixtureTrees :: [Maybe FixtureTree] -> IO Bool
cleanupFixtureTrees captured = case sequence captured of
  Nothing -> pure False
  Just trees -> do
    unchanged <- and <$> traverse verifyFixtureTree trees
    if unchanged then removeAll trees else pure False
 where
  removeAll [] = pure True
  removeAll (tree : trees) = do
    removed <- cleanupFixtureTree tree
    if removed then removeAll trees else pure False
