{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Focused pre-cluster proofs for the encrypted local emitter journal. The
-- suite exercises the real filesystem/lock/encryption interpreter in temporary
-- directories; it needs no Vault, MinIO, Kubernetes, or daemon runtime.
module GatewayEmitterJournal
  ( gatewayEmitterJournalSuite
  , runGatewayEmitterJournalHelper
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.Async (async, cancel, waitCatch)
import Control.Concurrent.MVar
  ( newEmptyMVar
  , putMVar
  , takeMVar
  )
import Control.Exception (IOException, finally, try)
import Control.Monad (forM, unless)
import Data.Bits (xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Text qualified as Text
import Data.Word (Word64)
import Numeric.Natural (Natural)
import Prodbox.Gateway.Emitter.Journal
import System.Directory (createDirectoryIfMissing, createDirectoryLink)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO
  ( Handle
  , hClose
  , hFlush
  , hGetLine
  , stdout
  )
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus)
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process
  ( CreateProcess (..)
  , ProcessHandle
  , StdStream (CreatePipe, Inherit)
  , createProcess
  , getPid
  , getProcessExitCode
  , proc
  , terminateProcess
  , waitForProcess
  )
import System.Timeout (timeout)
import TestSupport

defaultPayloadBound :: Natural
defaultPayloadBound = 4096

eventKey :: ByteString
eventKey = "journal-event-key-material-that-must-not-appear-on-disk"

wrongEventKey :: ByteString
wrongEventKey = "different-journal-event-key-material"

processCrashPayload :: ByteString
processCrashPayload = "exact-cross-process-fsynced-stage"

journalHelperPrefix :: String
journalHelperPrefix = "--prodbox-unit-journal-helper"

data JournalHelperProcess = JournalHelperProcess
  { helperInput :: !Handle
  , helperOutput :: !Handle
  , helperProcess :: !ProcessHandle
  }

identityA :: JournalIdentity
identityA =
  either (error . renderJournalError) id $
    mkJournalIdentity "cluster-a" "emitter-a" (BS.replicate 32 0x11)

identityB :: JournalIdentity
identityB =
  either (error . renderJournalError) id $
    mkJournalIdentity "cluster-a" "emitter-b" (BS.replicate 32 0x11)

identityUnderNewOrders :: JournalIdentity
identityUnderNewOrders =
  either (error . renderJournalError) id $
    mkJournalIdentity "cluster-a" "emitter-a" (BS.replicate 32 0x22)

configUnder :: FilePath -> Natural -> JournalConfig
configUnder temporaryRoot maximumPayload =
  either (error . renderJournalError) id $
    mkJournalConfig (temporaryRoot </> "emitter-journal") maximumPayload

retirementFor :: JournalIdentity -> Word64 -> EmitterRetirementReceipt
retirementFor identity previousIncarnation =
  either (error . renderJournalError) id $
    mkEmitterRetirementReceipt identity previousIncarnation

expectRight :: (Show err) => Either err value -> IO value
expectRight result =
  case result of
    Left err -> do
      expectationFailure ("expected Right, got Left " ++ show err)
      pure (error "unreachable after expectationFailure")
    Right value -> pure value

initializeWithPayload
  :: JournalConfig
  -> JournalIdentity
  -> ByteString
  -> ByteString
  -> IO ()
initializeWithPayload config identity key payload = do
  opened <-
    withEmitterJournal config identity FirstEmitterAdmission key $ \session recovery -> do
      recovery `shouldBe` JournalInitialized
      journalSessionIncarnation session `shouldBe` 1
      writeJournalPayload session payload
  writeResult <- expectRight opened
  writeResult `shouldBe` Right ()

tamperLastByte :: ByteString -> ByteString
tamperLastByte bytes
  | BS.null bytes = error "journal fixture unexpectedly wrote an empty file"
  | otherwise = BS.init bytes <> BS.singleton (BS.last bytes `xor` 0x01)

-- | Dispatch the private self-exec modes used by the cross-process journal
-- fixture. Normal tasty arguments return 'False' and continue into the suite.
runGatewayEmitterJournalHelper :: [String] -> IO Bool
runGatewayEmitterJournalHelper arguments =
  case arguments of
    [prefix, "hold", root]
      | prefix == journalHelperPrefix -> runHolderHelper root >> pure True
    [prefix, "probe", root]
      | prefix == journalHelperPrefix -> runProbeHelper root >> pure True
    [prefix, "recover", root]
      | prefix == journalHelperPrefix -> runRecoveryHelper root >> pure True
    prefix : _
      | prefix == journalHelperPrefix ->
          failJournalHelper "expected MODE and JOURNAL_ROOT"
    _ -> pure False

runHolderHelper :: FilePath -> IO ()
runHolderHelper root = do
  config <- journalHelperConfig root
  mounted <-
    withEmitterJournal config identityA FirstEmitterAdmission eventKey $ \session recovery -> do
      unless (recovery == JournalInitialized) $
        failJournalHelper ("holder recovered unexpected state: " ++ show recovery)
      unless (journalSessionIncarnation session == 1) $
        failJournalHelper "holder did not initialize incarnation 1"
      written <- writeJournalPayload session processCrashPayload
      case written of
        Left err -> failJournalHelper ("holder write failed: " ++ renderJournalError err)
        Right () -> do
          putStrLn "JOURNAL_HOLDER_READY:1"
          hFlush stdout
          release <- getLine
          unless (release == "JOURNAL_HOLDER_RELEASE") $
            failJournalHelper "holder received an invalid release sentinel"
  case mounted of
    Left err -> failJournalHelper ("holder mount failed: " ++ renderJournalError err)
    Right () -> pure ()

runProbeHelper :: FilePath -> IO ()
runProbeHelper root = do
  config <- journalHelperConfig root
  mounted <-
    withEmitterJournal config identityA ExistingEmitterAdmission eventKey $ \_ _ ->
      failJournalHelper "overlapping process unexpectedly acquired the journal"
  case mounted of
    Left JournalAlreadyLocked -> do
      putStrLn "JOURNAL_PROBE_LOCKED"
      hFlush stdout
    Left err -> failJournalHelper ("overlap probe failed unexpectedly: " ++ renderJournalError err)
    Right _ -> failJournalHelper "overlapping process unexpectedly completed a journal mount"

runRecoveryHelper :: FilePath -> IO ()
runRecoveryHelper root = do
  config <- journalHelperConfig root
  mounted <-
    withEmitterJournal config identityA ExistingEmitterAdmission eventKey $ \session recovery ->
      pure (journalSessionIncarnation session, recovery)
  case mounted of
    Right (2, JournalRecovered payload)
      | payload == processCrashPayload -> do
          putStrLn
            ( "JOURNAL_RECOVERED:2:"
                ++ BS8.unpack payload
            )
          hFlush stdout
    Right result -> failJournalHelper ("recovery observed unexpected state: " ++ show result)
    Left err -> failJournalHelper ("recovery mount failed: " ++ renderJournalError err)

journalHelperConfig :: FilePath -> IO JournalConfig
journalHelperConfig root =
  case mkJournalConfig root defaultPayloadBound of
    Left err -> failJournalHelper ("invalid helper journal root: " ++ renderJournalError err)
    Right config -> pure config

failJournalHelper :: String -> IO value
failJournalHelper message = ioError (userError ("journal helper: " ++ message))

startJournalHelper :: FilePath -> String -> FilePath -> IO JournalHelperProcess
startJournalHelper executable mode root = do
  created <-
    createProcess
      (proc executable [journalHelperPrefix, mode, root])
        { std_in = CreatePipe
        , std_out = CreatePipe
        , std_err = Inherit
        }
  case created of
    (Just input, Just output, Nothing, processHandle) ->
      pure
        JournalHelperProcess
          { helperInput = input
          , helperOutput = output
          , helperProcess = processHandle
          }
    _ -> failJournalHelper "createProcess did not return the requested helper pipes"

cleanupJournalHelper :: JournalHelperProcess -> IO ()
cleanupJournalHelper child = do
  ignoreIoFailure (hClose (helperInput child))
  status <- getProcessExitCode (helperProcess child)
  case status of
    Just _ -> pure ()
    Nothing -> do
      ignoreIoFailure (terminateProcess (helperProcess child))
      _ <- timeout helperTimeoutMicroseconds (waitForProcess (helperProcess child))
      pure ()
  ignoreIoFailure (hClose (helperOutput child))

ignoreIoFailure :: IO () -> IO ()
ignoreIoFailure action = do
  _ <- try action :: IO (Either IOException ())
  pure ()

helperTimeoutMicroseconds :: Int
helperTimeoutMicroseconds = 5000000

readHelperLine :: String -> JournalHelperProcess -> IO String
readHelperLine description child = do
  completed <- timeout helperTimeoutMicroseconds (hGetLine (helperOutput child))
  case completed of
    Nothing -> failJournalHelper (description ++ " timed out waiting for its sentinel")
    Just line -> pure line

waitForJournalHelper :: String -> JournalHelperProcess -> IO ExitCode
waitForJournalHelper description child = do
  completed <- timeout helperTimeoutMicroseconds (waitForProcess (helperProcess child))
  case completed of
    Nothing -> failJournalHelper (description ++ " timed out waiting for process exit")
    Just exitCode -> pure exitCode

runJournalHelperToExit :: FilePath -> String -> FilePath -> IO (String, ExitCode)
runJournalHelperToExit executable mode root = do
  child <- startJournalHelper executable mode root
  ( do
      line <- readHelperLine mode child
      ignoreIoFailure (hClose (helperInput child))
      exitCode <- waitForJournalHelper mode child
      pure (line, exitCode)
    )
    `finally` cleanupJournalHelper child

gatewayEmitterJournalSuite :: SuiteBuilder ()
gatewayEmitterJournalSuite =
  describe "Sprint 2.32 encrypted emitter journal" $ do
    it "first admission persists encrypted bytes without plaintext identity, key, or payload" $
      withSystemTempDirectory "prodbox-emitter-journal-first" $ \temporaryRoot -> do
        let config = configUnder temporaryRoot defaultPayloadBound
            payload = "plaintext-emitter-stage-marker-that-must-never-appear-on-disk"
        opened <-
          withEmitterJournal config identityA FirstEmitterAdmission eventKey $ \session recovery -> do
            recovery `shouldBe` JournalInitialized
            journalSessionIncarnation session `shouldBe` 1
            initialDigest <- journalSessionDigest session
            BS.length initialDigest `shouldBe` 32
            written <- writeJournalPayload session payload
            written `shouldBe` Right ()
            payloadDigest <- journalSessionDigest session
            BS.length payloadDigest `shouldBe` 32
            payloadDigest `shouldNotBe` initialDigest
        opened `shouldBe` Right ()
        encoded <- BS.readFile (journalFilePath config)
        BS.null encoded `shouldBe` False
        BS.isInfixOf payload encoded `shouldBe` False
        BS.isInfixOf eventKey encoded `shouldBe` False
        BS.isInfixOf "cluster-a" encoded `shouldBe` False
        BS.isInfixOf "emitter-a" encoded `shouldBe` False

    it "recovers the last fsynced non-empty payload across repeated crash boundaries" $
      withSystemTempDirectory "prodbox-emitter-journal-reopen" $ \temporaryRoot -> do
        let config = configUnder temporaryRoot defaultPayloadBound
            payload = "recoverable-staged-transition"
        initializeWithPayload config identityA eventKey payload
        second <-
          withEmitterJournal config identityA ExistingEmitterAdmission eventKey $ \session recovery ->
            pure (journalSessionIncarnation session, recovery)
        second `shouldBe` Right (2, JournalRecovered payload)
        third <-
          withEmitterJournal config identityA ExistingEmitterAdmission eventKey $ \session recovery ->
            pure (journalSessionIncarnation session, recovery)
        third `shouldBe` Right (3, JournalRecovered payload)

    it "serializes concurrent session writes and publishes the digest of the durable winner" $
      withSystemTempDirectory "prodbox-emitter-journal-concurrent" $ \temporaryRoot -> do
        let config = configUnder temporaryRoot defaultPayloadBound
            payloads = ["concurrent-payload-" <> BS.singleton suffix | suffix <- [0 .. 15]]
        opened <-
          withEmitterJournal config identityA FirstEmitterAdmission eventKey $ \session _ -> do
            initialDigest <- journalSessionDigest session
            completions <-
              forM payloads $ \payload -> do
                completed <- newEmptyMVar
                _ <- forkIO (writeJournalPayload session payload >>= putMVar completed)
                pure completed
            results <- traverse takeMVar completions
            digest <- journalSessionDigest session
            pure (results, initialDigest, digest)
        (results, initialDigest, publishedDigest) <- expectRight opened
        results `shouldBe` replicate (length payloads) (Right ())
        BS.length publishedDigest `shouldBe` 32
        publishedDigest `shouldNotBe` initialDigest
        reopened <-
          withEmitterJournal config identityA ExistingEmitterAdmission eventKey $ \_ recovery -> pure recovery
        recovery <- expectRight reopened
        case recovery of
          JournalRecovered payload -> payload `shouldSatisfy` (`elem` payloads)
          JournalInitialized -> expectationFailure "concurrent durable writes recovered empty genesis"
          JournalOrdersMigrationRequired _ _ ->
            expectationFailure "unchanged Orders unexpectedly required journal migration"

    it "authenticates the prior Orders digest and requires a durable migration" $
      withSystemTempDirectory "prodbox-emitter-journal-orders-migration" $ \temporaryRoot -> do
        let config = configUnder temporaryRoot defaultPayloadBound
            payload = "old-orders-durable-projection"
        initializeWithPayload config identityA eventKey payload
        migrated <-
          withEmitterJournal config identityUnderNewOrders ExistingEmitterAdmission eventKey $
            \session recovery -> do
              recovery
                `shouldBe` JournalOrdersMigrationRequired (BS.replicate 32 0x11) payload
              journalSessionIncarnation session `shouldBe` 2
              writeJournalPayload session payload
        migrated `shouldBe` Right (Right ())
        reopened <-
          withEmitterJournal config identityUnderNewOrders ExistingEmitterAdmission eventKey $
            \session recovery -> pure (journalSessionIncarnation session, recovery)
        reopened `shouldBe` Right (3, JournalRecovered payload)

    it "treats repeated mount-only crashes as empty genesis recovery" $
      withSystemTempDirectory "prodbox-emitter-journal-empty-reopen" $ \temporaryRoot -> do
        let config = configUnder temporaryRoot defaultPayloadBound
        first <-
          withEmitterJournal config identityA FirstEmitterAdmission eventKey $ \session recovery ->
            pure (journalSessionIncarnation session, recovery)
        first `shouldBe` Right (1, JournalInitialized)
        second <-
          withEmitterJournal config identityA ExistingEmitterAdmission eventKey $ \session recovery ->
            pure (journalSessionIncarnation session, recovery)
        second `shouldBe` Right (2, JournalInitialized)
        third <-
          withEmitterJournal config identityA ExistingEmitterAdmission eventKey $ \session recovery ->
            pure (journalSessionIncarnation session, recovery)
        third `shouldBe` Right (3, JournalInitialized)

    it "rejects ciphertext tampering" $
      withSystemTempDirectory "prodbox-emitter-journal-tamper" $ \temporaryRoot -> do
        let config = configUnder temporaryRoot defaultPayloadBound
        initializeWithPayload config identityA eventKey "authenticated-transition"
        encoded <- BS.readFile (journalFilePath config)
        BS.writeFile (journalFilePath config) (tamperLastByte encoded)
        reopened <-
          withEmitterJournal config identityA ExistingEmitterAdmission eventKey $ \_ _ -> pure ()
        reopened `shouldBe` Left JournalAuthenticationFailed

    it "rejects an existing journal under a different emitter identity" $
      withSystemTempDirectory "prodbox-emitter-journal-identity" $ \temporaryRoot -> do
        let config = configUnder temporaryRoot defaultPayloadBound
        initializeWithPayload config identityA eventKey "identity-bound-transition"
        reopened <-
          withEmitterJournal config identityB ExistingEmitterAdmission eventKey $ \_ _ -> pure ()
        reopened `shouldBe` Left JournalAuthenticationFailed

    it "rejects an existing journal under a different event key" $
      withSystemTempDirectory "prodbox-emitter-journal-key" $ \temporaryRoot -> do
        let config = configUnder temporaryRoot defaultPayloadBound
        initializeWithPayload config identityA eventKey "key-bound-transition"
        reopened <-
          withEmitterJournal config identityA ExistingEmitterAdmission wrongEventKey $ \_ _ -> pure ()
        reopened `shouldBe` Left JournalAuthenticationFailed

    it "refuses an overlapping in-process mount while the first session holds the lock" $
      withSystemTempDirectory "prodbox-emitter-journal-lock" $ \temporaryRoot -> do
        let config = configUnder temporaryRoot defaultPayloadBound
        started <- newEmptyMVar
        release <- newEmptyMVar
        completed <- newEmptyMVar
        _ <-
          forkIO $ do
            ownerResult <-
              withEmitterJournal config identityA FirstEmitterAdmission eventKey $ \_ recovery -> do
                putMVar started recovery
                takeMVar release
            putMVar completed ownerResult
        ownerRecovery <- takeMVar started
        overlap <-
          withEmitterJournal config identityA ExistingEmitterAdmission eventKey (\_ _ -> pure ())
            `finally` putMVar release ()
        ownerRecovery `shouldBe` JournalInitialized
        overlap `shouldBe` Left JournalAlreadyLocked
        takeMVar completed `shouldReturn` Right ()

    it "uses one lock identity for canonical and symlink-aliased journal roots" $
      withSystemTempDirectory "prodbox-emitter-journal-lock-alias" $ \temporaryRoot -> do
        let canonicalRoot = temporaryRoot </> "canonical"
            aliasRoot = temporaryRoot </> "alias"
        createDirectoryIfMissing True canonicalRoot
        createDirectoryLink canonicalRoot aliasRoot
        let canonicalConfig =
              either (error . renderJournalError) id (mkJournalConfig canonicalRoot defaultPayloadBound)
            aliasConfig =
              either (error . renderJournalError) id (mkJournalConfig aliasRoot defaultPayloadBound)
        started <- newEmptyMVar
        release <- newEmptyMVar
        completed <- newEmptyMVar
        _ <-
          forkIO $ do
            ownerResult <-
              withEmitterJournal canonicalConfig identityA FirstEmitterAdmission eventKey $ \_ _ -> do
                putMVar started ()
                takeMVar release
            putMVar completed ownerResult
        takeMVar started
        overlap <-
          withEmitterJournal aliasConfig identityA ExistingEmitterAdmission eventKey (\_ _ -> pure ())
            `finally` putMVar release ()
        overlap `shouldBe` Left JournalAlreadyLocked
        takeMVar completed `shouldReturn` Right ()
        aliasWrite <-
          withEmitterJournal aliasConfig identityA ExistingEmitterAdmission eventKey $ \session recovery -> do
            recovery `shouldBe` JournalInitialized
            journalSessionIncarnation session `shouldBe` 2
            writeJournalPayload session "written-through-canonicalized-alias"
        aliasWrite `shouldBe` Right (Right ())
        canonicalReopen <-
          withEmitterJournal canonicalConfig identityA ExistingEmitterAdmission eventKey $ \session recovery ->
            pure (journalSessionIncarnation session, recovery)
        canonicalReopen
          `shouldBe` Right (3, JournalRecovered "written-through-canonicalized-alias")

    it "excludes a symlink-aliased OS process and recovers exactly after SIGKILL" $
      withSystemTempDirectory "prodbox-emitter-journal-process-crash" $ \temporaryRoot -> do
        executable <- getExecutablePath
        let canonicalRoot = temporaryRoot </> "canonical"
            aliasRoot = temporaryRoot </> "alias"
        createDirectoryIfMissing True canonicalRoot
        createDirectoryLink canonicalRoot aliasRoot
        holder <- startJournalHelper executable "hold" canonicalRoot
        ( do
            holderReady <- readHelperLine "holder" holder
            holderReady `shouldBe` "JOURNAL_HOLDER_READY:1"

            (probeLine, probeExit) <- runJournalHelperToExit executable "probe" aliasRoot
            probeLine `shouldBe` "JOURNAL_PROBE_LOCKED"
            probeExit `shouldBe` ExitSuccess

            holderPid <- getPid (helperProcess holder)
            case holderPid of
              Nothing -> expectationFailure "holder process has no POSIX process id"
              Just processId -> signalProcess sigKILL processId
            killedExit <- waitForJournalHelper "SIGKILLed holder" holder
            killedExit `shouldSatisfy` (/= ExitSuccess)

            (recoveryLine, recoveryExit) <-
              runJournalHelperToExit executable "recover" canonicalRoot
            recoveryLine
              `shouldBe` ("JOURNAL_RECOVERED:2:" ++ BS8.unpack processCrashPayload)
            recoveryExit `shouldBe` ExitSuccess
          )
          `finally` cleanupJournalHelper holder

    it "releases the POSIX fd and process-local guard after asynchronous cancellation" $
      withSystemTempDirectory "prodbox-emitter-journal-lock-cancel" $ \temporaryRoot -> do
        let config = configUnder temporaryRoot defaultPayloadBound
        started <- newEmptyMVar
        blocked <- newEmptyMVar
        owner <-
          async $
            withEmitterJournal config identityA FirstEmitterAdmission eventKey $ \_ _ -> do
              putMVar started ()
              takeMVar blocked
        takeMVar started
        cancel owner
        _ <- waitCatch owner
        reopened <-
          withEmitterJournal config identityA ExistingEmitterAdmission eventKey $ \session _ ->
            pure (journalSessionIncarnation session)
        reopened `shouldBe` Right 2

    it "requires an explicit retirement receipt when an admitted journal is missing" $
      withSystemTempDirectory "prodbox-emitter-journal-retirement" $ \temporaryRoot -> do
        let config = configUnder temporaryRoot defaultPayloadBound
        missing <-
          withEmitterJournal config identityA ExistingEmitterAdmission eventKey $ \_ _ -> pure ()
        missing `shouldBe` Left JournalMissingRequiresRetirement
        let receipt = retirementFor identityA 7
        retirementNextIncarnation receipt `shouldBe` 8
        retired <-
          withEmitterJournal config identityA (RetiredEmitterAdmission receipt) eventKey $ \session recovery ->
            pure (journalSessionIncarnation session, recovery)
        retired `shouldBe` Right (8, JournalInitialized)

    it "binds a retirement receipt to the exact emitter identity" $
      withSystemTempDirectory "prodbox-emitter-journal-retirement-identity" $ \temporaryRoot -> do
        let config = configUnder temporaryRoot defaultPayloadBound
            receipt = retirementFor identityA 3
        retired <-
          withEmitterJournal config identityB (RetiredEmitterAdmission receipt) eventKey $ \_ _ -> pure ()
        retired `shouldBe` Left JournalRetirementIdentityMismatch

    it "refuses retirement while the prior journal still exists" $
      withSystemTempDirectory "prodbox-emitter-journal-retirement-conflict" $ \temporaryRoot -> do
        let config = configUnder temporaryRoot defaultPayloadBound
        initializeWithPayload config identityA eventKey "existing-transition"
        retired <-
          withEmitterJournal
            config
            identityA
            (RetiredEmitterAdmission (retirementFor identityA 1))
            eventKey
            (\_ _ -> pure ())
        retired `shouldBe` Left JournalRetirementConflictsWithExistingJournal

    it "enforces the exact payload bound without replacing the last valid journal" $
      withSystemTempDirectory "prodbox-emitter-journal-bound" $ \temporaryRoot -> do
        let config = configUnder temporaryRoot 4
        writes <-
          withEmitterJournal config identityA FirstEmitterAdmission eventKey $ \session _ -> do
            atBound <- writeJournalPayload session "1234"
            overBound <- writeJournalPayload session "12345"
            pure (atBound, overBound)
        writes
          `shouldBe` Right
            ( Right ()
            , Left (JournalPayloadTooLarge 5 4)
            )
        reopened <-
          withEmitterJournal config identityA ExistingEmitterAdmission eventKey $ \_ recovery -> pure recovery
        reopened `shouldBe` Right (JournalRecovered "1234")

    it "rejects an oversized encoded journal before CBOR allocation" $
      withSystemTempDirectory "prodbox-emitter-journal-encoded-bound" $ \temporaryRoot -> do
        let config = configUnder temporaryRoot 4
        initializeWithPayload config identityA eventKey "1234"
        BS.writeFile (journalFilePath config) (BS.replicate 4101 0x81)
        reopened <-
          withEmitterJournal config identityA ExistingEmitterAdmission eventKey $ \_ _ -> pure ()
        reopened `shouldSatisfy` isEncodedTooLarge

    it "requires at least 256 bits of event-key material and bounds identity components" $
      withSystemTempDirectory "prodbox-emitter-journal-input-bounds" $ \temporaryRoot -> do
        let config = configUnder temporaryRoot defaultPayloadBound
        withEmitterJournal config identityA FirstEmitterAdmission "short-key" (\_ _ -> pure ())
          `shouldReturn` Left (JournalEventKeyTooShort 9 32)
        mkJournalIdentity (Text.replicate 256 "x") "emitter-a" (BS.replicate 32 0x11)
          `shouldSatisfy` isIdentityInvalid

    it "rejects direct and symlink-aliased filesystem-root journal targets before chmod" $
      withSystemTempDirectory "prodbox-emitter-journal-root-target" $ \temporaryRoot -> do
        mkJournalConfig "/" defaultPayloadBound
          `shouldBe` Left (JournalConfigInvalid "journal root must not be the filesystem root")
        let aliasRoot = temporaryRoot </> "root-alias"
        createDirectoryLink "/" aliasRoot
        rootModeBefore <- fileMode <$> getFileStatus "/"
        let aliasConfig =
              either (error . renderJournalError) id (mkJournalConfig aliasRoot defaultPayloadBound)
        result <-
          withEmitterJournal aliasConfig identityA FirstEmitterAdmission eventKey (\_ _ -> pure ())
        rootModeAfter <- fileMode <$> getFileStatus "/"
        result
          `shouldBe` Left (JournalConfigInvalid "journal root resolves to the filesystem root")
        rootModeAfter `shouldBe` rootModeBefore

    it "publishes the exact atomic write and fsync protocol in execution order" $ do
      journalWriteProtocol
        `shouldBe` [ WriteEncryptedTemporary
                   , FsyncEncryptedTemporary
                   , RenameJournal
                   , FsyncJournalDirectory
                   ]
      journalWriteProtocol `shouldBe` [minBound .. maxBound]

isEncodedTooLarge :: Either JournalError result -> Bool
isEncodedTooLarge result = case result of
  Left JournalEncodedTooLarge {} -> True
  _ -> False

isIdentityInvalid :: Either JournalError JournalIdentity -> Bool
isIdentityInvalid result = case result of
  Left JournalIdentityInvalid {} -> True
  _ -> False
