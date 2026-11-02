{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}

-- Native exclusive-publisher ownership and sealing controls. Marked-but-unsent
-- is deliberately conservative; actual native sends use the facade fixture.
module Main (main) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception (AsyncException (ThreadKilled), IOException, throwIO, try)
import Control.Monad (guard, unless, void)
import Data.Aeson (eitherDecode, encode, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Subprocess.HostControllerInputRetirement qualified as Retirement
import Prodbox.Subprocess.HostControllerPublication qualified as Publication
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import System.Directory (doesPathExist, listDirectory)
import System.Environment (getArgs)
import System.FilePath (takeDirectory, (</>))
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileGroup
  , fileID
  , fileMode
  , fileOwner
  , fileSize
  , getFileStatus
  , linkCount
  , modificationTimeHiRes
  , setFileMode
  , statusChangeTimeHiRes
  )
import System.Posix.User (getEffectiveUserID)
import "crypton" Crypto.Random (getRandomBytes)

right :: (Show failure) => Either failure value -> IO value
right = either (fail . show) pure

assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)

refused :: (Eq failure) => failure -> Either failure value -> Bool
refused expected result = case result of
  Left actual -> actual == expected
  Right _ -> False

freshEnd :: IO Word64
freshEnd = (+ 5000000000) <$> getMonotonicTimeNSec

fixtureKey :: IO Identity.HostExecutionKey
fixtureKey = do
  bytes <- getRandomBytes 32
  let hex byte =
        [ "0123456789abcdef" !! fromIntegral (byte `div` 16)
        , "0123456789abcdef" !! fromIntegral (byte `mod` 16)
        ]
  maybe
    (fail "fixture key")
    pure
    (Identity.hostExecutionKeyFromText (concatMap hex (BS.unpack bytes)))

assertRetired :: Bool -> (FilePath, FilePath) -> IO ()
assertRetired hasBirth (cfg, req) = do
  absent <-
    mapM
      (fmap not . doesPathExist)
      [ cfg
      , req
      , takeDirectory req </> "retirement-settings.cbor"
      , takeDirectory req </> "retirement-request.cbor"
      ]
  assert "never-sent retirement left payloads" (and absent)
  names <- listDirectory (takeDirectory req)
  let expected =
        ["retirement-prepared.cbor", "retirement-terminal.cbor"]
          <> ["publication-birth.cbor" | hasBirth]
  assert
    "never-sent retirement changed the retained fence set"
    (length names == length expected && all (`elem` expected) names)

sameVersion :: FileStatus -> FileStatus -> Bool
sameVersion a b =
  deviceID a == deviceID b
    && fileID a == fileID b
    && fileMode a == fileMode b
    && fileOwner a == fileOwner b
    && fileGroup a == fileGroup b
    && fileSize a == fileSize b
    && linkCount a == linkCount b
    && modificationTimeHiRes a == modificationTimeHiRes b
    && statusChangeTimeHiRes a == statusChangeTimeHiRes b

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["recover", evidence] -> recoverFixture RecoverClean evidence
    ["recover-busy", evidence] -> recoverFixture RecoverBusy evidence
    ["recover-marked", evidence] -> recoverFixture RecoverMarked evidence
    ["recover-malformed", evidence] -> recoverFixture RecoverMalformed evidence
    ["recover-changed", evidence] -> recoverFixture RecoverChanged evidence
    ["recover-drift", evidence] -> recoverFixture RecoverDrift evidence
    ["recover-expired", evidence] -> recoverFixture RecoverExpired evidence
    ["recover-borrow", evidence] -> recoverFixture RecoverBorrow evidence
    _ -> publicationFixture arguments

publicationFixture :: [String] -> IO ()
publicationFixture arguments = do
  [mode, evidence] <- pure arguments
  key <- fixtureKey
  foreignKey <- fixtureKey
  started <- getMonotonicTimeNSec
  let work = started + 2000000000
  uid <- getEffectiveUserID
  let namespace = Publication.hostControllerPublishedDirectory Identity.RpcBirthController uid key
      expectedPaths =
        ( namespace </> Publication.hostControllerConfigurationName
        , namespace </> Publication.hostControllerRequestName
        )
  pathsRef <- newIORef (Just expectedPaths)
  Lazy.writeFile evidence $
    encode $
      object
        [ "configuration" .= fst expectedPaths
        , "request" .= snd expectedPaths
        , "key" .= Identity.hostExecutionKeyText key
        , "work_end_ns" .= work
        ]
  proofRef <- newIORef Nothing
  ownerRef <- newIORef Nothing
  closedRef <- newIORef False
  let run action close =
        Publication.withPublishedHostControllerOwner
          Identity.RpcBirthController
          work
          key
          "configuration fixture"
          "request fixture"
          ( \owner -> do
              let paths@(cfg, req) = Publication.hostPublicationPaths owner
              writeIORef pathsRef (Just paths)
              writeIORef ownerRef (Just owner)
              Lazy.writeFile evidence $
                encode $
                  object
                    [ "configuration" .= cfg
                    , "request" .= req
                    , "key" .= Identity.hostExecutionKeyText key
                    , "work_end_ns" .= work
                    ]
              action owner
          )
          ( \disposition -> do
              writeIORef closedRef True
              close disposition
          )
      mark owner selected ending paths =
        right
          =<< Publication.withHostPublicationSubmission
            owner
            ( \permit ->
                Publication.markHostPublicationPossibleSend
                  permit
                  Identity.RpcBirthController
                  selected
                  ending
                  (fst paths)
                  (snd paths)
            )
      closeOrdinary disposition = case disposition of
        Publication.PublicationPossiblySent -> fail "unmarked publication became possible-send"
        Publication.PublicationNeverSent proof -> do
          writeIORef proofRef (Just proof)
          ending <- freshEnd
          _ <- right =<< Retirement.retireNeverSentHostControllerInputs ending proof
          _ <- right =<< Retirement.retireNeverSentHostControllerInputs ending proof
          paths <- readIORef pathsRef >>= maybe (fail "missing paths") pure
          assertRetired (Publication.hostPublicationNeverSentAllowsMissingOriginal proof) paths
      closeSent disposition = case disposition of
        Publication.PublicationNeverSent _ -> fail "possible-send was downgraded to never-sent"
        Publication.PublicationPossiblySent -> do
          (cfg, req) <- readIORef pathsRef >>= maybe (fail "missing paths") pure
          assert "possible-send configuration changed" . (== "configuration fixture") =<< BS.readFile cfg
          assert "possible-send request changed" . (== "request fixture") =<< BS.readFile req
          assert "possible-send published a retirement preparation" . not
            =<< doesPathExist (takeDirectory req </> "retirement-prepared.cbor")
      markOwn owner = right =<< mark owner key work (Publication.hostPublicationPaths owner)
      closeExpired disposition = case disposition of
        Publication.PublicationPossiblySent -> fail "unexpected send"
        Publication.PublicationNeverSent proof -> do
          before <- mapM getFileStatus [fst expectedPaths, snd expectedPaths]
          assert "expired never-sent cleanup mutated inputs"
            . refused (Retirement.InputRetirementPublicationRefused Publication.ControllerPublicationExpired)
            =<< Retirement.retireNeverSentHostControllerInputs 0 proof
          after <- mapM getFileStatus [fst expectedPaths, snd expectedPaths]
          assert "expired cleanup changed file identities" (and (zipWith sameVersion before after))
          assert "expired cleanup wrote preparation" . not
            =<< doesPathExist (namespace </> "retirement-prepared.cbor")
      closeDrift disposition = case disposition of
        Publication.PublicationPossiblySent -> fail "unexpected send"
        Publication.PublicationNeverSent proof -> do
          ending <- freshEnd
          before <- mapM getFileStatus [fst expectedPaths, snd expectedPaths]
          result <- Retirement.retireNeverSentHostControllerInputs ending proof
          assert
            "changed never-sent input was deleted"
            (case result of Left (Retirement.InputRetirementFileChanged _) -> True; _ -> False)
          after <- mapM getFileStatus [fst expectedPaths, snd expectedPaths]
          assert "refused drift changed file identities" (and (zipWith sameVersion before after))
      closeRetry disposition = case disposition of
        Publication.PublicationPossiblySent -> fail "unexpected send"
        Publication.PublicationNeverSent proof -> do
          ending <- freshEnd
          failed <- Retirement.retireNeverSentHostControllerInputs ending proof
          assert "authored syscall failure was not observed" (case failed of Left _ -> True; Right _ -> False)
          _ <- right =<< Retirement.retireNeverSentHostControllerInputs ending proof
          paths <- readIORef pathsRef >>= maybe (fail "missing paths") pure
          assertRetired (Publication.hostPublicationNeverSentAllowsMissingOriginal proof) paths
  case mode of
    "partial" -> do
      result <- run (const (fail "partial publication entered user callback")) closeOrdinary
      assert
        "partial publication swallowed its original failure"
        ( case result :: Either Publication.HostControllerPublicationError ((), ()) of
            Left _ -> True
            Right _ -> False
        )
      proof <- readIORef proofRef >>= maybe (fail "partial publication did not close") pure
      assertRetired (Publication.hostPublicationNeverSentAllowsMissingOriginal proof) expectedPaths
    "partial-foreign" -> do
      result <- run (const (fail "partial foreign publication entered callback")) closeOrdinary
      assert
        "original publication failure was masked by cleanup"
        ( case result :: Either Publication.HostControllerPublicationError ((), ()) of
            Left Publication.ControllerPublicationExpired -> True
            _ -> False
        )
      assert "foreign request was removed or changed" . (== "authored foreign request")
        =<< BS.readFile (snd expectedPaths)
      assert "refused prefix cleanup removed the configuration" =<< doesPathExist (fst expectedPaths)
      assert "refused prefix cleanup wrote preparation" . not
        =<< doesPathExist (namespace </> "retirement-prepared.cbor")
    "ordinary" -> void (right =<< run (const (pure ())) closeOrdinary)
    "retain" -> void (right =<< run (const (pure ())) (const (pure ())))
    "crash-wait" -> void (right =<< run (const (threadDelay 10000000)) (const (pure ())))
    "live-recovery" ->
      void (right =<< run (const (recoverFixture RecoverBusy evidence)) closeOrdinary)
    "closing-recovery" ->
      void
        ( right
            =<< run
              (const (pure ()))
              (\disposition -> recoverFixture RecoverBusy evidence >> closeOrdinary disposition)
        )
    "attempt-no-send" ->
      void $
        right
          =<< run
            ( \owner -> do
                escaped <- right =<< Publication.withHostPublicationSubmission owner pure
                let (cfg, req) = Publication.hostPublicationPaths owner
                assert "escaped submission marker stayed live" . refused Publication.ControllerPublicationClosed
                  =<< Publication.markHostPublicationPossibleSend escaped Identity.RpcBirthController key work cfg req
                assert "duplicate attempt entered" . refused Publication.ControllerPublicationAlreadyAttempted
                  =<< Publication.withHostPublicationSubmission owner (const (fail "duplicate entered"))
            )
            closeOrdinary
    "mark-sent" -> void (right =<< run markOwn closeSent)
    "mark-wrong-key" ->
      void $
        right
          =<< run
            ( \owner ->
                assert "foreign key marked possible-send"
                  . refused Publication.ControllerPublicationSubmissionMismatch
                  =<< mark owner foreignKey work (Publication.hostPublicationPaths owner)
            )
            closeOrdinary
    "mark-wrong-work" ->
      void $
        right
          =<< run
            ( \owner ->
                assert "foreign work end marked possible-send"
                  . refused Publication.ControllerPublicationSubmissionMismatch
                  =<< mark owner key (work - 1) (Publication.hostPublicationPaths owner)
            )
            closeOrdinary
    "mark-wrong-path" ->
      void $
        right
          =<< run
            ( \owner -> do
                let (cfg, req) = Publication.hostPublicationPaths owner
                assert "foreign path marked possible-send"
                  . refused Publication.ControllerPublicationSubmissionMismatch
                  =<< mark owner key work (cfg <> ".foreign", req)
            )
            closeOrdinary
    "callback-exception" -> do
      result <- try (run (const (ioError (userError "authored publication failure"))) closeOrdinary)
      assert
        "publisher swallowed callback failure"
        ( case result :: Either IOException (Either Publication.HostControllerPublicationError ((), ())) of
            Left _ -> True
            Right _ -> False
        )
    "callback-cancel" -> do
      result <- try (run (const (throwIO ThreadKilled)) closeOrdinary)
      assert
        "publisher swallowed callback cancellation"
        ( case result :: Either AsyncException (Either Publication.HostControllerPublicationError ((), ())) of
            Left ThreadKilled -> True
            _ -> False
        )
    "marked-cancel" -> do
      result <- try (run (\owner -> markOwn owner >> throwIO ThreadKilled) closeSent)
      assert
        "publisher swallowed marked cancellation"
        ( case result :: Either AsyncException (Either Publication.HostControllerPublicationError ((), ())) of
            Left ThreadKilled -> True
            _ -> False
        )
    "concurrent" ->
      void $
        right
          =<< run
            ( \owner -> do
                entered <- newEmptyMVar
                release <- newEmptyMVar
                child <-
                  Async.async $
                    Publication.withHostPublicationSubmission
                      owner
                      (\_ -> putMVar entered () >> takeMVar release)
                takeMVar entered
                assert "concurrent publication attempt entered" . refused Publication.ControllerPublicationBusy
                  =<< Publication.withHostPublicationSubmission owner (const (fail "busy entered"))
                putMVar release ()
                void (right =<< Async.wait child)
            )
            closeOrdinary
    "close-joins" -> do
      entered <- newEmptyMVar
      release <- newEmptyMVar
      childRef <- newEmptyMVar
      parent <-
        Async.async $
          run
            ( \owner -> do
                child <-
                  Async.async $
                    Publication.withHostPublicationSubmission
                      owner
                      ( \permit -> do
                          let (cfg, req) = Publication.hostPublicationPaths owner
                          right
                            =<< Publication.markHostPublicationPossibleSend permit Identity.RpcBirthController key work cfg req
                          putMVar entered ()
                          takeMVar release
                          assert "input descriptor closed before submission settled" . (== "request fixture")
                            =<< BS.readFile req
                      )
                takeMVar entered
                putMVar childRef child
            )
            closeSent
      child <- takeMVar childRef
      threadDelay 20000
      pending <- Async.poll parent
      assert
        "publisher close did not join the active submission"
        (case pending of Nothing -> True; Just _ -> False)
      assert "closing arm ran while submission remained active" . not =<< readIORef closedRef
      putMVar release ()
      void (right =<< Async.wait child)
      void (right =<< Async.wait parent)
    "expired-cleanup" ->
      void (right =<< run (const (pure ())) closeExpired)
    "drift" ->
      void $
        right
          =<< run
            (\owner -> setFileMode (fst (Publication.hostPublicationPaths owner)) 0o600)
            closeDrift
    "retry" ->
      void (right =<< run (const (pure ())) closeRetry)
    _ -> fail "unknown publication lifetime fixture"
  assert "publication closing arm was skipped" =<< readIORef closedRef
  maybeOwner <- readIORef ownerRef
  case maybeOwner of
    Nothing ->
      assert
        "complete publication did not enter its callback"
        (mode `elem` ["partial", "partial-foreign"])
    Just owner ->
      assert "escaped publisher admitted another submission"
        . refused Publication.ControllerPublicationClosed
        =<< Publication.withHostPublicationSubmission owner (const (fail "closed entered"))
  maybeProof <- readIORef proofRef
  case maybeProof of
    Nothing -> pure ()
    Just proof -> do
      ending <- freshEnd
      assert "escaped never-sent owner remained live"
        . refused (Retirement.InputRetirementPublicationRefused Publication.ControllerPublicationClosed)
        =<< Retirement.retireNeverSentHostControllerInputs ending proof
  putStrLn ("PASS native exclusive publication lifecycle " <> mode)

data RecoveryExpectation
  = RecoverClean
  | RecoverBusy
  | RecoverMarked
  | RecoverMalformed
  | RecoverChanged
  | RecoverDrift
  | RecoverExpired
  | RecoverBorrow
  deriving (Eq, Show)

recoverFixture :: RecoveryExpectation -> FilePath -> IO ()
recoverFixture expectation evidence = do
  encoded <- Lazy.readFile evidence
  value <- either fail pure (eitherDecode encoded)
  (keyText, originalWork) <-
    either fail pure $
      parseEither (withObject "publication fixture" readFields) value
  key <- maybe (fail "bad fixture key") pure (Identity.hostExecutionKeyFromText keyText)
  uid <- getEffectiveUserID
  let namespace = Publication.hostControllerPublishedDirectory Identity.RpcBirthController uid key
      paths =
        ( namespace </> Publication.hostControllerConfigurationName
        , namespace </> Publication.hostControllerRequestName
        )
  before <- mapM observe [fst paths, snd paths]
  case expectation of
    RecoverBorrow -> do
      proofRef <- newIORef Nothing
      ending <- (+ 500000000) <$> getMonotonicTimeNSec
      result <- Publication.withRecoveredHostPublicationNeverSent Identity.RpcBirthController ending key $ \proof -> do
        writeIORef proofRef (Just proof)
        assert "concurrent recovery acquired a live native birth fence"
          . refused (Retirement.InputRetirementPublicationRefused Publication.ControllerPublicationBusy)
          =<< Retirement.recoverNeverSentHostControllerInputs ending Identity.RpcBirthController key
        threadDelay 600000
        later <- freshEnd
        assert "recovery renewed its admitted read bound"
          . refused (Retirement.InputRetirementPublicationRefused Publication.ControllerPublicationExpired)
          =<< Retirement.retireNeverSentHostControllerInputs later proof
      _ <- right result
      proof <- readIORef proofRef >>= maybe (fail "missing recovery proof") pure
      later <- freshEnd
      assert "escaped recovery proof stayed live"
        . refused (Retirement.InputRetirementPublicationRefused Publication.ControllerPublicationClosed)
        =<< Retirement.retireNeverSentHostControllerInputs later proof
      assertUnchanged before paths
    _ -> do
      ending <- if expectation == RecoverExpired then pure 0 else freshEnd
      result <- Retirement.recoverNeverSentHostControllerInputs ending Identity.RpcBirthController key
      case expectation of
        RecoverClean -> do
          _ <- right result
          _ <-
            right =<< Retirement.recoverNeverSentHostControllerInputs ending Identity.RpcBirthController key
          assertRetired True paths
          now <- getMonotonicTimeNSec
          putStrLn ("original_work_expired=" <> show (now >= originalWork))
        RecoverBusy -> assertRefused Publication.ControllerPublicationBusy result
        RecoverMarked -> assertRefused Publication.ControllerPublicationPossiblySent result
        RecoverMalformed -> assertRefused Publication.ControllerPublicationRecordMalformed result
        RecoverChanged -> assertRefused Publication.ControllerPublicationChanged result
        RecoverExpired -> assertRefused Publication.ControllerPublicationExpired result
        RecoverDrift -> assert "changed payload was accepted" $
          case result of Left (Retirement.InputRetirementFileChanged _) -> True; _ -> False
      unless (expectation == RecoverClean) (assertUnchanged before paths)
  putStrLn ("PASS native cold recovery " <> show expectation)
 where
  readFields objectValue = (,) <$> objectValue .: "key" <*> objectValue .: "work_end_ns"
  observe :: FilePath -> IO (Maybe FileStatus)
  observe path = do
    present <- doesPathExist path
    traverse getFileStatus (path <$ guard present)
  assertUnchanged before paths = do
    after <- mapM observe [fst paths, snd paths]
    assert "refused recovery mutated a payload" (and (zipWith versions before after))
  versions Nothing Nothing = True
  versions (Just a) (Just b) = sameVersion a b
  versions Nothing (Just _) = False
  versions (Just _) Nothing = False
  assertRefused cause result =
    assert
      "wrong cold recovery refusal"
      (refused (Retirement.InputRetirementPublicationRefused cause) result)
