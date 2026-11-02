{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}

-- Native payload ownership, journals and bounded lifetime controls. Fixture
-- preparation records a real qualified sender and closes it without a Start;
-- the built-library controller fixture separately covers actual submitted work.
module Main (main) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception (AsyncException (ThreadKilled), bracket, throwIO, try)
import Control.Monad (unless, void)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT)
import Data.Aeson (encode, object, (.=))
import Data.Bits ((.|.))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Word (Word64)
import Foreign.C.Error (throwErrnoIfMinus1Retry)
import Foreign.C.Types (CInt (..))
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Subprocess.HostControllerInputRetirement qualified as Reaper
import Prodbox.Subprocess.HostControllerInputs qualified as Inputs
import Prodbox.Subprocess.HostControllerPublication qualified as Publication
import Prodbox.Subprocess.HostOperationRetirement qualified as Retirement
import Prodbox.Subprocess.SystemdBus qualified as Bus
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import Prodbox.Subprocess.SystemdProvider qualified as Provider
import System.Directory
  ( createDirectory
  , doesPathExist
  , listDirectory
  , removeFile
  , renameDirectory
  , renameFile
  )
import System.Environment (getArgs)
import System.FilePath (takeDirectory, (</>))
import System.Posix.Files (createLink, createSymbolicLink, setFileMode)
import System.Posix.IO qualified as Posix
import System.Posix.Types (Fd (..))
import System.Posix.User (getEffectiveUserID)
import "crypton" Crypto.Random (getRandomBytes)

foreign import capi "sys/file.h value LOCK_EX" exclusiveLock :: CInt
foreign import capi "sys/file.h value LOCK_NB" nonBlockingLock :: CInt
foreign import capi "sys/file.h flock" lockDirectory :: CInt -> CInt -> IO CInt

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

data Fixture = Fixture !FilePath !FilePath !Inputs.HostControllerSubmissionRecord

withBus :: Word64 -> (Bus.BusConnection -> IO value) -> IO value
withBus ending action = do
  uid <- getEffectiveUserID
  right =<< Bus.withSystemdBus ending ("/run/user/" <> show uid <> "/bus") (lift . action)

prepare :: FilePath -> IO Fixture
prepare evidence = do
  nonce <- getRandomBytes 32
  let hex byte =
        [ "0123456789abcdef" !! fromIntegral (byte `div` 16)
        , "0123456789abcdef" !! fromIntegral (byte `mod` 16)
        ]
  key <-
    maybe
      (fail "fixture key")
      pure
      (Identity.hostExecutionKeyFromText (concatMap hex (BS.unpack nonce)))
  started <- getMonotonicTimeNSec
  let work = started + 2000000000
  window <-
    maybe (fail "fixture window") pure $
      Identity.hostExecutionWindow
        (started + 5000000000)
        work
        (started + 2150000000)
        (started + 2500000000)
        (started + 3000000000)
  fixture <-
    right
      =<< Publication.withPublishedHostControllerInputs
        Identity.RpcBirthController
        work
        key
        "native configuration fixture"
        "native request fixture"
        ( \cfg req -> do
            record <-
              right
                =<< Inputs.withHostControllerInputs
                  work
                  cfg
                  req
                  ( \inputs -> withBus work $ \connection -> do
                      sender <- right =<< runExceptT (Bus.observeBusSender connection)
                      right
                        =<< right
                        =<< Provider.withQualifiedProvider
                          connection
                          ( \provider ->
                              Inputs.registerHostControllerSubmission
                                Identity.RpcBirthController
                                inputs
                                key
                                window
                                (Provider.qualifiedProviderDomain provider)
                                sender
                                provider
                          )
                  )
            pure (Fixture cfg req record)
        )
  let Fixture cfg req record = fixture
  Lazy.writeFile evidence $
    encode $
      object
        [ "configuration" .= cfg
        , "request" .= req
        , "key" .= Identity.hostExecutionKeyText key
        , "submission" .= Inputs.hostControllerSubmissionPath req key
        , "record_bytes" .= BS.length (Inputs.encodeHostControllerSubmission record)
        , "scope" .= ("qualified sender closed without Start; payload retirement only" :: String)
        ]
  pure fixture

withOwner
  :: Fixture -> (Word64 -> Retirement.HostOperationRetirement -> IO value) -> IO value
withOwner (Fixture _ _ record) action = do
  ending <- freshEnd
  withBus ending $ \connection ->
    right =<< Retirement.withHostOperationRetirement connection record (action ending)

retire :: Fixture -> IO (Either Reaper.InputRetirementError Reaper.HostInputRetirementReceipt)
retire fixture@(Fixture _ _ record) = withOwner fixture $ \ending owner ->
  Reaper.retireHostControllerInputs ending owner record

assertUnprepared :: Fixture -> IO ()
assertUnprepared (Fixture _ req _) = do
  prepared <- doesPathExist (takeDirectory req </> "retirement-prepared.cbor")
  terminal <- doesPathExist (takeDirectory req </> "retirement-terminal.cbor")
  assert "refused initial transaction published a journal" (not prepared && not terminal)

assertRetired :: Fixture -> IO ()
assertRetired (Fixture cfg req record) = do
  absent <-
    mapM
      (fmap not . doesPathExist)
      [ cfg
      , req
      , takeDirectory req </> "retirement-settings.cbor"
      , takeDirectory req </> "retirement-request.cbor"
      ]
  assert "retirement left a payload name" (and absent)
  retained <-
    mapM
      doesPathExist
      [ Inputs.hostControllerSubmissionPath req (Inputs.hostControllerSubmissionKey record)
      , takeDirectory req </> "retirement-prepared.cbor"
      , takeDirectory req </> "retirement-terminal.cbor"
      ]
  assert "retirement removed a one-shot metadata fence" (and retained)

check :: String -> Fixture -> IO ()
check mode fixture@(Fixture cfg req record) = case mode of
  "ordinary" -> do
    receipt <- right =<< retire fixture
    assert "receipt lost exact record" (Reaper.hostInputRetirementReceiptMatches receipt record)
    assertRetired fixture
    _ <- right =<< retire fixture
    assertRetired fixture
  "missing-config" -> do
    removeFile cfg
    assert "missing configuration was success"
      . refused (Reaper.InputRetirementFileMissing Inputs.ControllerConfiguration)
      =<< retire fixture
    assert "missing configuration deleted request" =<< doesPathExist req
    assertUnprepared fixture
  "missing-request" -> do
    removeFile req
    assert "missing request was success"
      . refused (Reaper.InputRetirementFileMissing Inputs.ControllerRequest)
      =<< retire fixture
    assert "missing request deleted configuration" =<< doesPathExist cfg
    assertUnprepared fixture
  "changed-mode" -> do
    setFileMode cfg 0o600
    assert "changed mode was accepted"
      . refused (Reaper.InputRetirementFileChanged Inputs.ControllerConfiguration)
      =<< retire fixture
    assertUnprepared fixture
  "request-mode" -> do
    setFileMode req 0o600
    assert "request drift removed configuration"
      . refused (Reaper.InputRetirementFileChanged Inputs.ControllerRequest)
      =<< retire fixture
    assert "request drift deleted configuration" =<< doesPathExist cfg
    assertUnprepared fixture
  "replaced-config" -> do
    renameFile cfg (cfg <> ".original")
    BS.writeFile cfg "foreign replacement"
    setFileMode cfg 0o400
    assert "replaced configuration was accepted"
      . refused (Reaper.InputRetirementFileChanged Inputs.ControllerConfiguration)
      =<< retire fixture
    assert "foreign replacement was changed" . (== "foreign replacement") =<< BS.readFile cfg
    assertUnprepared fixture
  "hardlink" -> do
    createLink cfg (cfg <> ".alias")
    assert "hardlinked payload was accepted"
      . refused (Reaper.InputRetirementFileChanged Inputs.ControllerConfiguration)
      =<< retire fixture
    assertUnprepared fixture
  "symlink" -> do
    renameFile cfg (cfg <> ".original")
    createSymbolicLink (cfg <> ".original") cfg
    result <- retire fixture
    assert
      "symlink payload was accepted"
      (case result of Left (Reaper.InputRetirementIoRefused _ _) -> True; _ -> False)
    assertUnprepared fixture
  "foreign-quarantine" -> do
    let path = takeDirectory cfg </> "retirement-settings.cbor"
    BS.writeFile path "foreign quarantine"
    setFileMode path 0o400
    assert "foreign quarantine was accepted"
      . refused (Reaper.InputRetirementConflictingNames Inputs.ControllerConfiguration)
      =<< retire fixture
    assert "foreign quarantine was changed" . (== "foreign quarantine") =<< BS.readFile path
    assertUnprepared fixture
  "corrupt-submission" -> do
    let path = Inputs.hostControllerSubmissionPath req (Inputs.hostControllerSubmissionKey record)
    setFileMode path 0o600
    BS.writeFile path "corrupt original submission"
    setFileMode path 0o400
    assert "corrupt submission was accepted" . refused Reaper.InputRetirementRecordMismatch
      =<< retire fixture
    assertUnprepared fixture
  "missing-submission" -> do
    removeFile (Inputs.hostControllerSubmissionPath req (Inputs.hostControllerSubmissionKey record))
    assert "missing submission became absence" . refused Reaper.InputRetirementRecordMismatch
      =<< retire fixture
    assert "missing submission deleted request" =<< doesPathExist req
    assertUnprepared fixture
  "corrupt-preparation" -> do
    let path = takeDirectory req </> "retirement-prepared.cbor"
    BS.writeFile path "foreign preparation"
    setFileMode path 0o400
    assert "corrupt preparation was accepted" . refused Reaper.InputRetirementJournalMismatch
      =<< retire fixture
    assert "corrupt preparation deleted request" =<< doesPathExist req
  "orphan-terminal" -> do
    let path = takeDirectory req </> "retirement-terminal.cbor"
    BS.writeFile path "foreign terminal"
    setFileMode path 0o400
    assert "orphan terminal was accepted" . refused Reaper.InputRetirementJournalMismatch
      =<< retire fixture
    assert "orphan terminal deleted request" =<< doesPathExist req
  "terminal-recreation" -> do
    _ <- right =<< retire fixture
    BS.writeFile req "foreign recreated request"
    setFileMode req 0o400
    assert "terminal transaction removed recreation"
      . refused (Reaper.InputRetirementUnexpectedResidue Inputs.ControllerRequest)
      =<< retire fixture
    assert "recreated request changed" . (== "foreign recreated request") =<< BS.readFile req
  "terminal-corruption" -> do
    _ <- right =<< retire fixture
    let path = takeDirectory req </> "retirement-terminal.cbor"
    setFileMode path 0o600
    BS.writeFile path "foreign terminal"
    setFileMode path 0o400
    assert "corrupt terminal became success" . refused Reaper.InputRetirementJournalMismatch
      =<< retire fixture
  "wrong-record" -> do
    Fixture _ _ foreignRecord <- prepare (req <> ".foreign.json")
    withOwner fixture $ \ending owner -> do
      assert "another exact record obtained deletion"
        . refused Reaper.InputRetirementRecordMismatch
        =<< Reaper.retireHostControllerInputs ending owner foreignRecord
    assertUnprepared fixture
  "directory-replacement" -> do
    let path = takeDirectory req
    renameDirectory path (path <> ".original")
    createDirectory path
    setFileMode path 0o700
    BS.writeFile req "foreign namespace"
    setFileMode req 0o400
    assert "replacement directory was accepted" . refused Reaper.InputRetirementNamespaceRefused
      =<< retire fixture
    assert "replacement directory payload changed" . (== "foreign namespace") =<< BS.readFile req
    assertUnprepared fixture
  "directory-mode" -> do
    setFileMode (takeDirectory req) 0o750
    assert "unsafe directory was accepted" . refused Reaper.InputRetirementNamespaceRefused
      =<< retire fixture
  "directory-lock" ->
    bracket
      (Posix.openFd (takeDirectory req) Posix.ReadOnly Posix.defaultFileFlags {Posix.directory = True})
      Posix.closeFd
      ( \(Fd fd) -> do
          _ <-
            throwErrnoIfMinus1Retry
              "native fixture directory lock"
              (lockDirectory fd (exclusiveLock .|. nonBlockingLock))
          assert "another open description bypassed directory lock" . refused Reaper.InputRetirementBusy
            =<< retire fixture
          assertUnprepared fixture
      )
  "expired" -> withOwner fixture $ \_ owner -> do
    result <- Reaper.retireHostControllerInputs 0 owner record
    assert
      "expired transaction mutated inputs"
      (refused (Reaper.InputRetirementPhysicalRefused Retirement.RetirementExpired) result)
    assertUnprepared fixture
  "closed-owner" -> do
    owner <- withOwner fixture (\_ held -> pure held)
    ending <- freshEnd
    assert "escaped owner deleted inputs"
      . refused (Reaper.InputRetirementPhysicalRefused Retirement.RetirementClosed)
      =<< Reaper.retireHostControllerInputs ending owner record
    assertUnprepared fixture
  "borrow" -> withOwner fixture $ \ending owner -> do
    escaped <-
      right
        =<< Retirement.withHostOperationRetirementBorrow
          ending
          owner
          ( \lease -> do
              assert
                "borrow extended original deadline"
                (Retirement.hostOperationRetirementDeadline lease <= ending)
              assert "same owner admitted concurrent borrow" . refused Retirement.RetirementBusy
                =<< Retirement.withHostOperationRetirementBorrow ending owner (const (fail "busy callback entered"))
              right =<< Retirement.verifyHostOperationRetirement lease
              pure lease
          )
    assert "borrow remained live after return" . refused Retirement.RetirementClosed
      =<< Retirement.verifyHostOperationRetirement escaped
    right =<< Retirement.verifyHostOperationRetirement owner
    saved <- newIORef Nothing
    cancelled <-
      try $
        Retirement.withHostOperationRetirementBorrow
          ending
          owner
          (\lease -> writeIORef saved (Just lease) >> throwIO ThreadKilled)
    assert
      "borrow swallowed cancellation"
      ( case cancelled :: Either AsyncException (Either Retirement.RetirementError ()) of
          Left ThreadKilled -> True
          _ -> False
      )
    lease <- readIORef saved >>= maybe (fail "missing cancelled borrow") pure
    assert "cancelled borrow stayed live" . refused Retirement.RetirementClosed
      =<< Retirement.verifyHostOperationRetirement lease
    right =<< Retirement.verifyHostOperationRetirement owner
  "borrow-close" -> do
    entered <- newEmptyMVar
    release <- newEmptyMVar
    callback <- newEmptyMVar
    parent <- Async.async $ withOwner fixture $ \ending owner -> do
      child <-
        Async.async $
          Retirement.withHostOperationRetirementBorrow
            ending
            owner
            ( \lease -> do
                putMVar entered ()
                takeMVar release
                right =<< Retirement.verifyHostOperationRetirement lease
            )
      takeMVar entered
      putMVar callback child
    child <- takeMVar callback
    threadDelay 20000
    pending <- Async.poll parent
    assert
      "parent closed while bounded borrow held native handles"
      (case pending of Nothing -> True; Just _ -> False)
    firstCancel <- Async.async (Async.cancel parent)
    secondCancel <- Async.async (Async.cancel parent)
    putMVar release ()
    right =<< Async.wait child
    void (Async.waitCatch parent)
    mapM_ Async.wait [firstCancel, secondCancel]
  "descriptor-cycles" -> do
    before <- length <$> listDirectory "/proc/self/fd"
    _ <- right =<< retire fixture
    _ <- right =<< retire fixture
    _ <- right =<< retire fixture
    after <- length <$> listDirectory "/proc/self/fd"
    assert "input retirement leaked descriptors" (before == after)
  _ -> fail "unknown native input retirement control"

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["prepare", evidence] -> void (prepare evidence)
    ["retire", request, text] -> do
      ending <- freshEnd
      key <- maybe (fail "fixture key") pure (Identity.hostExecutionKeyFromText text)
      record <- right =<< Inputs.readHostControllerSubmission ending request key
      let fixture = Fixture (takeDirectory request </> Publication.hostControllerConfigurationName) request record
      _ <- right =<< retire fixture
      assertRetired fixture
      putStrLn "PASS exact native payload retirement and synchronized metadata fences"
    ["check", mode, evidence] -> do
      fixture <- prepare evidence
      check mode fixture
      putStrLn ("PASS native input retirement " <> mode)
    _ -> fail "expected prepare, retire or one native ownership control"
