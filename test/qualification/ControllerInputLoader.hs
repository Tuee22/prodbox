{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Main (main) where

import Control.Concurrent (newEmptyMVar, putMVar, readMVar, takeMVar, threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception
  ( AsyncException (ThreadKilled)
  , IOException
  , SomeException
  , bracket
  , catch
  , finally
  , fromException
  , throwIO
  , try
  )
import Control.Monad (forM_, forever, unless, when, (<=<), (>=>))
import Data.Aeson (encode, object, (.=))
import Data.Bifunctor (first)
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isLeft)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (stripPrefix)
import Data.Text qualified as Text
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Network.Socket qualified as Net
import Network.Socket.ByteString (recv, sendAll)
import Numeric (showHex)
import Prodbox.Capacity.Config qualified as C
import Prodbox.Capacity.HostExecution qualified as H
import Prodbox.Config.Tier0 qualified as Tier0
import Prodbox.ControlPlane.AuthenticatedTransport qualified as Auth
import Prodbox.ControlPlane.Client (ControlPlaneRouteFor (LifecycleMigrationApplyRoute))
import Prodbox.ControlPlane.Coordinate (mkAuthorityScope)
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication (ExternalLifecycleAuthorityCaller (..))
import Prodbox.ControlPlane.LocalClient (withOperationLifecycleAuthorityAuthenticatedTransport)
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.RpcAdmissionBirthControllerInputs
import Prodbox.ControlPlane.RpcAdmissionBirthCoordinator
import Prodbox.ControlPlane.RpcAdmissionBirthNative (rpcBirthSystemTime)
import Prodbox.ControlPlane.RpcAdmissionBirthPayload
import Prodbox.ControlPlane.RpcAdmissionBirthRequest
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros, authorityTimeMicros)
import Prodbox.Lifecycle.Teardown.EphemeralKubectl (prepareEmbeddedHomeKubeconfig)
import Prodbox.Settings qualified as S
import Prodbox.Subprocess qualified as P
import Prodbox.Subprocess.HostControllerInputs qualified as Metadata
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getCurrentDirectory
  , listDirectory
  , makeAbsolute
  , renameFile
  )
import System.Environment (getArgs, lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (makeRelative, takeDirectory, takeFileName, (</>))
import System.Posix.Files (fileID, fileMode, fileOwner, getFileStatus, setFileMode)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)
import TestSupport (syntheticConfigFile, syntheticProjectConfig)

right :: (Show errorValue) => Either errorValue value -> IO value
right = either (fail . show) pure

assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)

profile :: RpcBirthControllerProfileInput
profile =
  RpcBirthControllerProfileInput
    ( C.RuntimeMemoryProfile
        "rpc-birth-host"
        (mib 2)
        (mib 1)
        (mib 3)
        (mib 2)
        (mib 128)
        (mib 32)
        (C.ChildProcessBudgetConfig (Just 2) (Just 30000) [mib 64, mib 16])
        (mib 8)
        (mib 8)
    )
    (mib 256)
    (H.HostExecutionDemand 300000 200000 100000 16 24 8 (mib 48) (mib 16) 1 0)
    (H.HostTransportDemand 100000 8 (mib 16))
    20000
    20000
    (RpcBirthControllerStreamInput 65536 65536 500000)
    (RpcBirthControllerStreamInput 4096 4096 500000)
 where
  mib value = value * 1048576

fixture :: FilePath -> IO (RpcBirthControllerPreparation, BS.ByteString, BS.ByteString, Word64)
fixture = fixtureWithKey "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

fixtureWithKey
  :: Text.Text -> FilePath -> IO (RpcBirthControllerPreparation, BS.ByteString, BS.ByteString, Word64)
fixtureWithKey registrationKey directory = do
  root <- getCurrentDirectory
  unsetEnv "PRODBOX_TEST_HOST_CAPACITY"
  let context = Tier0.context syntheticProjectConfig
      input =
        S.DeploymentContextInput
          (Tier0.cluster_id context)
          (Tier0.vault_address context)
          (Tier0.minio_endpoint context)
          (Tier0.rpc_registration context)
      capacity = S.capacity syntheticConfigFile
      plan = C.resource_plan capacity
      selected = filter ((`elem` C.guaranteedControlPlaneProfileIds) . C.profile_id) (C.workload_profiles plan)
      ids = map C.profile_id selected
      config =
        syntheticConfigFile
          { S.storage =
              (S.storage syntheticConfigFile) {S.manual_pv_host_root = Text.pack (makeRelative root directory)}
          , S.capacity =
              capacity
                { C.resource_plan =
                    plan {C.host_capacity = C.ResourceVector 6000 12000 60000 60000, C.workload_profiles = selected}
                , C.runtime_memory_profiles =
                    filter ((`elem` ids) . C.runtime_profile_id) (C.runtime_memory_profiles capacity)
                }
          }
  settings <- right =<< S.validateConfigWithContext root input config
  scope <- right (mkAuthorityScope (Tier0.cluster_id context))
  authority <- rpcBirthSystemTime
  request <-
    right
      ( mkRpcBirthCoordinationRequest
          scope
          (authorityTimeFromMicros (authorityTimeMicros authority + 60000000))
          1
          registrationKey
      )
  started <- getMonotonicTimeNSec
  window <-
    maybe
      (fail "fixture window")
      pure
      ( P.hostExecutionWindow
          (started + 20000000000)
          (started + 15000000000)
          (started + 16000000000)
          (started + 17000000000)
          (started + 18000000000)
      )
  domain <- right =<< observeRpcBirthControllerManagerDomain (started + 15000000000)
  controllerRequest <-
    right
      ( mkRpcBirthControllerRequest
          LifecycleAuthorityTestHarness
          domain
          root
          settings
          request
          window
          profile
      )
  preparation <- right =<< prepareRpcBirthControllerRequest controllerRequest settings
  configuration <- rpcBirthSettingsBytes <$> right (encodeRpcBirthControllerSettings settings)
  command <-
    rpcBirthControllerRequestBytes <$> right (encodeRpcBirthControllerRequest controllerRequest)
  pure (preparation, configuration, command, started)

writeInputs :: FilePath -> BS.ByteString -> BS.ByteString -> IO (FilePath, FilePath)
writeInputs directory configuration command = do
  let cfg = directory </> "settings.cbor"
      req = directory </> "request.cbor"
  BS.writeFile cfg configuration
  BS.writeFile req command
  mapM_ (`setFileMode` 0o600) [cfg, req]
  pure (cfg, req)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["authority-channel", scenario, path, forward] -> do
      directory <- makeAbsolute path
      helper <- makeAbsolute forward
      authorityChannel scenario directory helper
    ["local", path] -> local =<< makeAbsolute path
    ["physical", path] -> physical =<< makeAbsolute path
    ["publication", path] -> publication =<< makeAbsolute path
    ["published-physical", path] -> publishedPhysical =<< makeAbsolute path
    ["field", path] -> observeExpiredField False =<< makeAbsolute path
    ["field-retirement", path] -> observeExpiredField True =<< makeAbsolute path
    [mode, path]
      | mode
          `elem` [ "published-unsent"
                 , "published-unsent-expired"
                 , "published-unsent-exception"
                 , "published-unsent-cancel"
                 , "published-unsent-drift"
                 , "published-unsent-reload"
                 ] ->
          publishedUnsent mode =<< makeAbsolute path
    "internal-rpc-birth-controller" : flags -> controller flags
    _ -> fail "unsupported qualification invocation"

local :: FilePath -> IO ()
local directory = do
  (preparation, configBytes, requestBytes, started) <- fixture directory
  (cfg, req) <- writeInputs directory configBytes requestBytes
  escaped <- newIORef Nothing
  arguments <-
    right
      =<< withRpcBirthControllerLaunchFiles
        preparation
        cfg
        req
        ( \launch -> do
            value <- right =<< rpcBirthControllerLaunchArguments launch
            writeIORef escaped (Just launch)
            pure value
        )
  assert "renderer did not emit nine closed pairs" (length arguments == 18)
  parse <- right (parseRpcBirthControllerArguments arguments)
  lease <- newIORef Nothing
  result <-
    right
      =<< withRpcBirthControllerInputs
        parse
        ( \inputs -> do
            right =<< verifyRpcBirthControllerInputs inputs
            writeIORef lease (Just inputs)
            unmanaged <- withRpcBirthControllerProcesses inputs (const (fail "unmanaged callback executed"))
            assert
              "unmanaged process received physical admission"
              (case unmanaged of Left (ControllerLoadParentRefused _) -> True; _ -> False)
            pure
              ( rpcBirthControllerRequestKey
                  (rpcBirthControllerPreparedRequest (rpcBirthControllerInputPreparation inputs))
              )
        )
  assert
    "loaded key changed"
    (result == rpcBirthControllerRequestKey (rpcBirthControllerPreparedRequest preparation))
  Just retained <- readIORef lease
  outside <- verifyRpcBirthControllerInputs retained
  assert
    "escaped file lease remained usable"
    (case outside of Left (ControllerLoadInputsRefused _) -> True; _ -> False)
  Just oldLaunch <- readIORef escaped
  closed <- rpcBirthControllerLaunchArguments oldLaunch
  assert
    "escaped launch remained usable"
    (case closed of Left (ControllerLoadInputsRefused _) -> True; _ -> False)
  mapM_ (doesFileExist >=> assert "scope release deleted launch inputs") [cfg, req]
  putStrLn
    "PASS packaged loader/renderer roundtrip, foreign-parent refusal and closed-scope rejection; files retained"
  let replace label replacement = replaceValue arguments
       where
        replaceValue [] = []
        replaceValue (key : value : rest) = key : (if key == label then replacement else value) : replaceValue rest
        replaceValue _ = error "fixture argument pairs"
      refuseArgs label values = assert ("accepted " ++ label) (isLeft (parseRpcBirthControllerArguments values))
  refuseArgs "no arguments" []
  refuseArgs "argument tail" (arguments ++ ["--unknown", "value"])
  refuseArgs "missing argument" (drop 1 arguments)
  refuseArgs "duplicate flag" (take 2 arguments ++ arguments)
  refuseArgs "foreign flag" ("--foreign" : drop 1 arguments)
  forM_ ["relative", cfg ++ "/..", cfg ++ "/.", cfg ++ "\NULsuffix", replicate 4097 'x'] $ \path ->
    refuseArgs "unsafe path" (replace "--config" path)
  forM_ ["", replicate 64 'g', replicate 65 'a', replicate 64 'A'] $ \key -> do
    refuseArgs "fingerprint" (replace "--input-fingerprint" key)
    refuseArgs "operation key" (replace "--operation-key" key)
  forM_ ["--outer-ns", "--work-ns", "--hard-ns", "--stop-ns", "--finish-ns"] $ \label ->
    forM_
      [ ""
      , "0"
      , "01"
      , "-1"
      , "+1"
      , "1e3"
      , "１２"
      , "18446744073709551615"
      , "18446744073709551616"
      , replicate 21 '9'
      ]
      $ \value ->
        refuseArgs "noncanonical or overflowing clock" (replace label value)
  putStrLn "PASS strict shape/path/fingerprint/key and all five decimal-clock refusal tables"
  let withFingerprint values = do
        fingerprint <-
          right
            =<< Metadata.withHostControllerInputs
              (started + 15000000000)
              cfg
              req
              (pure . Metadata.hostControllerInputFingerprintText . Metadata.hostControllerInputFingerprint)
        right (parseRpcBirthControllerArguments (replaceIn values "--input-fingerprint" fingerprint))
      noCallback _ = fail "refused input reached its effect callback"
      expectInput resultValue =
        assert
          "expected input refusal before decoding"
          (case resultValue of Left (ControllerLoadInputsRefused _) -> True; _ -> False)
  BS.writeFile cfg "bad settings CBOR"
  expectInput =<< withRpcBirthControllerInputs parse noCallback
  current <- withFingerprint arguments
  badSettings <- withRpcBirthControllerInputs current noCallback
  assert
    "malformed settings were accepted or misclassified"
    (case badSettings of Left (ControllerLoadSettingsRefused _) -> True; _ -> False)
  publicationMismatch <-
    withRpcBirthControllerLaunchFiles
      preparation
      cfg
      req
      (const (fail "mismatched publication callback"))
  assert
    "caller preparation did not bind exact encoded settings"
    (case publicationMismatch of Left ControllerLoadPublicationMismatch -> True; _ -> False)
  BS.writeFile cfg configBytes
  BS.writeFile req "bad request CBOR"
  currentRequest <- withFingerprint arguments
  badRequest <- withRpcBirthControllerInputs currentRequest noCallback
  assert
    "malformed request was accepted or misclassified"
    (case badRequest of Left (ControllerLoadRequestRefused _) -> True; _ -> False)
  BS.writeFile req requestBytes
  fresh <- withFingerprint arguments
  right
    =<< withRpcBirthControllerInputs
      fresh
      ( \inputs -> do
          renameFile cfg (cfg ++ ".held")
          BS.writeFile cfg configBytes
          setFileMode cfg 0o600
          expectInput =<< verifyRpcBirthControllerInputs inputs
      )
  setFileMode cfg 0o640
  unsafe <- withRpcBirthControllerInputs fresh noCallback
  expectInput unsafe
  setFileMode cfg 0o600
  let elapsed =
        foldl
          (\values (label, value) -> replaceIn values label (show value))
          arguments
          [ ("--outer-ns", started - 1000000000)
          , ("--work-ns", started - 6000000000)
          , ("--hard-ns", started - 5000000000)
          , ("--stop-ns", started - 4000000000)
          , ("--finish-ns", started - 3000000000)
          ]
  elapsedArgs <- right (parseRpcBirthControllerArguments elapsed)
  expectInput =<< withRpcBirthControllerInputs elapsedArgs noCallback
  putStrLn
    "PASS pinned metadata before decoding, exact publication, malformed payloads, replacement, permissions and original expiry"

replaceIn :: [String] -> String -> String -> [String]
replaceIn [] _ _ = []
replaceIn (label : value : rest) target replacement = label : (if label == target then replacement else value) : replaceIn rest target replacement
replaceIn _ _ _ = error "fixture argument pairs"

argumentValue :: String -> [String] -> String
argumentValue wanted values = case values of
  label : value : rest -> if label == wanted then value else argumentValue wanted rest
  _ -> error "missing fixture argument"

publication :: FilePath -> IO ()
publication directory = do
  uid <- getEffectiveUserID
  nonce <- getMonotonicTimeNSec
  let stamp = showHex nonce ""
      key marker = Text.pack (replicate (31 - length stamp) '0' <> stamp <> [marker])
      runtime = "/run/user/" <> show uid
      paths arguments = map (`argumentValue` arguments) ["--config", "--request"]
      retained arguments = mapM_ (doesFileExist >=> assert "publication inputs were deleted") (paths arguments)
      verifyBytes arguments configuration command = do
        actual <- mapM BS.readFile (paths arguments)
        assert "publication changed exact canonical bytes" (actual == [configuration, command])
  -- The native root does not come from the environment.
  setEnv "XDG_RUNTIME_DIR" (directory </> "unused-runtime")
  (preparation, configuration, command, _) <- fixtureWithKey (key 'b') directory
  escape <- newIORef Nothing
  arguments <-
    right
      =<< withPublishedRpcBirthControllerLaunch
        preparation
        ( \launch -> do
            values <- right =<< rpcBirthControllerLaunchArguments launch
            let cfg = argumentValue "--config" values
                expectedDirectory = runtime <> "/prodbox-rpc-birth-inputs-" <> argumentValue "--operation-key" values
            assert "publisher accepted environment-selected root" (takeDirectory cfg == expectedDirectory)
            parent <- getFileStatus expectedDirectory
            assert
              "publication directory unsafe"
              (fileMode parent .&. 0o7777 == 0o700 && fileOwner parent == uid)
            forM_ (paths values) $ \path -> do
              status <- getFileStatus path
              assert "publication file unsafe" (fileMode status .&. 0o7777 == 0o400 && fileOwner status == uid)
            verifyBytes values configuration command
            parsed <- right (parseRpcBirthControllerArguments values)
            right =<< withRpcBirthControllerInputs parsed (right <=< verifyRpcBirthControllerInputs)
            writeIORef escape (Just launch)
            pure values
        )
  retained arguments
  Just escaped <- readIORef escape
  closed <- rpcBirthControllerLaunchArguments escaped
  assert "published launch escaped its file lease" (isLeft closed)
  inodes <- mapM (fmap fileID . getFileStatus) (paths arguments)
  collision <-
    withPublishedRpcBirthControllerLaunch preparation (const (fail "collision callback executed"))
  assert
    "publisher reused an existing operation directory"
    (case collision of Left (ControllerLoadPublicationRefused _) -> True; _ -> False)
  closingInodes <- mapM (fmap fileID . getFileStatus) (paths arguments)
  assert "collision overwrote published files" (inodes == closingInodes)
  verifyBytes arguments configuration command
  putStrLn
    "PASS actual fixed-root publication, canonical byte delivery, private modes, escaped lease and exclusive collision"
  (failedPreparation, failedConfiguration, failedCommand, _) <- fixtureWithKey (key 'c') directory
  failurePaths <- newIORef Nothing
  failure <- try $
    withPublishedRpcBirthControllerLaunch failedPreparation $ \launch -> do
      values <- right =<< rpcBirthControllerLaunchArguments launch
      writeIORef failurePaths (Just values)
      ioError (userError "authored publication callback failure")
  case failure :: Either IOException (Either RpcBirthControllerLoadError ()) of
    Left _ -> pure ()
    Right _ -> fail "publisher swallowed the callback exception"
  Just failedArguments <- readIORef failurePaths
  retained failedArguments
  verifyBytes failedArguments failedConfiguration failedCommand
  (cancelPreparation, cancelConfiguration, cancelCommand, _) <- fixtureWithKey (key 'd') directory
  ready <- newEmptyMVar
  worker <- Async.async $
    withPublishedRpcBirthControllerLaunch cancelPreparation $ \launch -> do
      values <- right =<< rpcBirthControllerLaunchArguments launch
      putMVar ready values
      threadDelay 10000000
  cancelArguments <- takeMVar ready
  Async.cancel worker
  cancelled <- Async.waitCatch worker
  assert "publication callback was not cancelled" (isLeft cancelled)
  retained cancelArguments
  verifyBytes cancelArguments cancelConfiguration cancelCommand
  putStrLn "PASS callback failure/cancellation propagate and retain the exact launch inputs"
  (changedPreparation, changedConfiguration, _, _) <- fixtureWithKey (key 'e') directory
  changedArguments <-
    right
      =<< withPublishedRpcBirthControllerLaunch
        changedPreparation
        ( \launch -> do
            values <- right =<< rpcBirthControllerLaunchArguments launch
            let cfg = argumentValue "--config" values
            renameFile cfg (cfg <> ".held")
            BS.writeFile cfg changedConfiguration
            setFileMode cfg 0o400
            rejected <- rpcBirthControllerLaunchArguments launch
            assert "changed published inode remained usable" (isLeft rejected)
            pure values
        )
  retained changedArguments
  putStrLn "PASS published inode replacement invalidates the same launch capability"
  (expiredPreparation, _, _, started) <- fixtureWithKey (key 'f') directory
  let matchesExpired entry =
        (stripPrefix "prodbox-rpc-birth-inputs-" entry >>= P.hostExecutionKeyFromText)
          == Just (rpcBirthControllerRequestKey (rpcBirthControllerPreparedRequest expiredPreparation))
  entries <- listDirectory runtime
  assert "expired fixture key already exists" (not (any matchesExpired entries))
  now <- getMonotonicTimeNSec
  let remaining = started + 15000000000 - min (started + 15000000000) now
  threadDelay (fromIntegral (remaining `div` 1000 + 1000))
  expired <-
    withPublishedRpcBirthControllerLaunch
      expiredPreparation
      (const (fail "expired publisher callback executed"))
  assert
    "expired publication was accepted"
    (case expired of Left (ControllerLoadPublicationRefused _) -> True; _ -> False)
  closingEntries <- listDirectory runtime
  assert "expired publisher created input files" (not (any matchesExpired closingEntries))
  putStrLn "PASS original work expiry refuses before creating an operation directory"

observeExpiredField :: Bool -> FilePath -> IO ()
observeExpiredField retireInputs directory = do
  nonce <- (`showHex` "") <$> getMonotonicTimeNSec
  let key marker = Text.pack (replicate (31 - length nonce) '0' <> nonce <> [marker])
  (preparation, _, bytes, started) <- fixtureWithKey (key 'f') directory
  let original = rpcBirthControllerPreparedRequest preparation
      settings = rpcBirthControllerPreparedSettings preparation
      expectedKey = rpcBirthControllerRequestKey original
      expectedWindow = rpcBirthControllerRequestWindow original
      coordination = rpcBirthControllerRequestCoordination original
  historical <- right (decodeRpcBirthControllerRequest expectedKey expectedWindow bytes)
  otherCoordination <-
    right
      ( mkRpcBirthCoordinationRequest
          (rpcBirthCoordinationScope coordination)
          (rpcBirthCoordinationDeadline coordination)
          (rpcBirthCoordinationGeneration coordination)
          (key 'e')
      )
  otherRequest <-
    right
      ( mkRpcBirthControllerRequest
          (rpcBirthControllerRequestCaller original)
          (rpcBirthControllerRequestDomain original)
          (rpcBirthControllerRequestRoot original)
          settings
          otherCoordination
          expectedWindow
          profile
      )
  (initialField, otherField, historicalPath) <-
    right
      =<< withPublishedRpcBirthControllerLaunch
        preparation
        ( \launch -> do
            launchArguments <- right =<< rpcBirthControllerLaunchArguments launch
            let historicalPath = argumentValue "--request" launchArguments
            Lazy.writeFile (directory </> "field.json") $
              encode $
                object
                  [ "units" .= rpcBirthControllerLaunchUnitNames launch
                  , "started_ns" .= started
                  , "hard_ns" .= (started + 16000000000)
                  , "finish_ns" .= (started + 18000000000)
                  , "config_path" .= argumentValue "--config" launchArguments
                  , "request_path" .= historicalPath
                  ]
            right =<< submitRpcBirthControllerLaunch launch
            observed <- right =<< observeRpcBirthControllerField (started + 3000000000) historical
            assert
              "admitted field was not observable/present"
              (rpcBirthControllerFieldState observed == ControllerFieldPresent)
            assert
              "matching keyed timer was not observed"
              (rpcBirthControllerFieldRoleState observed OperationTimer == ControllerFieldPresent)
            foreignField <- right =<< observeRpcBirthControllerField (started + 3000000000) otherRequest
            assert
              "foreign request selected the admitted keyed timer"
              (rpcBirthControllerFieldRoleState foreignField OperationTimer == ControllerFieldAbsent)
            assert
              "foreign request selected the admitted controller"
              (rpcBirthControllerFieldRoleState foreignField OperationController == ControllerFieldAbsent)
            pure (observed, foreignField, historicalPath)
        )
  putStrLn
    "PASS actual matching keyed presence and foreign-key absence through the read-only selector"
  now <- getMonotonicTimeNSec
  let outer = started + 20000000000
      remaining = outer - min outer now
  threadDelay (fromIntegral (remaining `div` 1000 + 1000))
  decodedAt <- getMonotonicTimeNSec
  assert "fixture resumed before the original outer end" (decodedAt > outer)
  decodedAfterExpiry <- right (decodeRpcBirthControllerRequest expectedKey expectedWindow bytes)
  refused <- prepareRpcBirthControllerRequest decodedAfterExpiry settings
  assert
    "historical request regained effect preparation"
    (case refused of Left ControllerRequestExpired -> True; _ -> False)
  fresh <- getMonotonicTimeNSec
  let readEnd = fresh + 1000000000
  observed <- right =<< observeRpcBirthControllerField readEnd decodedAfterExpiry
  observedAt <- getMonotonicTimeNSec
  assert "fresh field read exceeded its own bound" (observedAt < readEnd)
  assert
    "expired field was not fully observed absent"
    (rpcBirthControllerFieldState observed == ControllerFieldAbsent)
  forM_ [minBound .. maxBound] $ \role ->
    assert
      "expired role was not observed absent"
      (rpcBirthControllerFieldRoleState observed role == ControllerFieldAbsent)
  expiredBudget <- observeRpcBirthControllerField (fresh - 1) decodedAfterExpiry
  assert
    "expired read budget was accepted"
    (case expiredBudget of Left (ControllerLoadBusRefused _) -> True; _ -> False)
  result <- readFile (directory </> "controller-result")
  assert
    "managed controller did not complete its actual command and transport"
    (result == "PASS pinned loader, observed parent and concurrent command/transport\n")
  retirementStart <- getMonotonicTimeNSec
  let retirementEnd = retirementStart + 1000000000
  retired <-
    right
      =<< withRpcBirthControllerRetirement
        retirementEnd
        historicalPath
        decodedAfterExpiry
        ( \owner -> do
            right =<< verifyRpcBirthControllerRetirement owner
            pure owner
        )
  escapedRetirement <- verifyRpcBirthControllerRetirement retired
  assert
    "physical retirement owner escaped its native scope"
    (case escapedRetirement of Left (ControllerLoadRetirementRefused _) -> True; _ -> False)
  retirementObserved <- getMonotonicTimeNSec
  assert "retirement renewed its own observation deadline" (retirementObserved < retirementEnd)
  when retireInputs $ do
    cleanupEnd <- (+ 5000000000) <$> getMonotonicTimeNSec
    _ <- right =<< retireRpcBirthControllerInputs cleanupEnd historicalPath decodedAfterExpiry
    _ <- right =<< retireRpcBirthControllerInputs cleanupEnd historicalPath decodedAfterExpiry
    expiredCleanup <- retireRpcBirthControllerInputs 0 historicalPath decodedAfterExpiry
    assert "expired cleanup budget was accepted" (isLeft expiredCleanup)
    stillExpired <- prepareRpcBirthControllerRequest decodedAfterExpiry settings
    assert
      "payload retirement renewed original work"
      (case stillExpired of Left ControllerRequestExpired -> True; _ -> False)
  Lazy.writeFile (directory </> "observation.json") $
    encode $
      object
        [ "started_ns" .= started
        , "original_outer_ns" .= outer
        , "decoded_after_expiry_ns" .= decodedAt
        , "fresh_read_started_ns" .= fresh
        , "fresh_read_end_ns" .= readEnd
        , "fresh_observed_ns" .= observedAt
        , "matching_timer_state" .= show (rpcBirthControllerFieldRoleState initialField OperationTimer)
        , "foreign_timer_state" .= show (rpcBirthControllerFieldRoleState otherField OperationTimer)
        , "closing_field_state" .= show (rpcBirthControllerFieldState observed)
        , "expired_effect_refused" .= isLeft refused
        , "expired_read_refused" .= isLeft expiredBudget
        , "qualified_physical_retirement_observed" .= True
        , "retirement_read_start_ns" .= retirementStart
        , "retirement_read_end_ns" .= retirementEnd
        , "retirement_observed_ns" .= retirementObserved
        , "submitted_inputs_retired" .= retireInputs
        ]
  putStrLn
    "PASS post-outer-expiry data reconstruction/observation without renewed effects; expired read budget refused"

publishedUnsent :: String -> FilePath -> IO ()
publishedUnsent mode directory = do
  nonce <- (`showHex` "") <$> getMonotonicTimeNSec
  let key = Text.pack (replicate (31 - length nonce) '0' <> nonce <> "b")
  (preparation, _, _, started) <- fixtureWithKey key directory
  saved <- newIORef Nothing
  let original = rpcBirthControllerPreparedRequest preparation
      action launch = do
        args <- right =<< rpcBirthControllerLaunchArguments launch
        let cfg = argumentValue "--config" args
            req = argumentValue "--request" args
        writeIORef saved (Just (launch, cfg, req))
        case mode of
          "published-unsent-expired" -> do
            now <- getMonotonicTimeNSec
            let ending = started + 20000000000
            threadDelay (fromIntegral ((ending - min ending now) `div` 1000 + 1000))
          "published-unsent-exception" -> ioError (userError "authored never-sent caller failure")
          "published-unsent-cancel" -> throwIO ThreadKilled
          "published-unsent-drift" -> do
            renameFile cfg (cfg <> ".original")
            BS.writeFile cfg "foreign configuration"
            setFileMode cfg 0o400
          "published-unsent-reload" -> do
            reloaded <-
              right =<< withRpcBirthControllerLaunchFiles preparation cfg req submitRpcBirthControllerLaunch
            assert
              "unmarked raw-file reload bypassed the publisher"
              (case reloaded of Left (ControllerLoadInputsRefused _) -> True; _ -> False)
            names <- listDirectory (takeDirectory req)
            assert
              "unmarked reload registered a submission"
              ( length names == 3
                  && all (`elem` [takeFileName cfg, takeFileName req, "publication-birth.cbor"]) names
              )
          "published-unsent" -> pure ()
          _ -> fail "unsupported never-sent fixture mode"
  attempted <-
    try (withPublishedRpcBirthControllerLaunchRetiringUnsent (started + 25000000000) preparation action)
      :: IO
           (Either SomeException (Either RpcBirthControllerLoadError (RpcBirthControllerPublicationResult ())))
  case attempted of
    Left cause -> case mode of
      "published-unsent-exception" ->
        assert
          "wrong caller exception"
          (case fromException cause :: Maybe IOException of Just _ -> True; Nothing -> False)
      "published-unsent-cancel" ->
        assert
          "wrong caller cancellation"
          (case fromException cause of Just ThreadKilled -> True; _ -> False)
      _ -> fail "unexpected never-sent fixture exception"
    Right result -> do
      assert
        "never-sent callback failure was swallowed"
        (mode `notElem` ["published-unsent-exception", "published-unsent-cancel"])
      report <- right result
      assert "never-sent caller outcome changed" (rpcBirthPublicationOutcome report == Right ())
      case rpcBirthPublicationDisposition report of
        ControllerUnsubmittedInputsRetired _ -> assert "changed input was reported retired" (mode /= "published-unsent-drift")
        ControllerUnsubmittedInputsUnresolved _ -> assert "unmodified input was unresolved" (mode == "published-unsent-drift")
        ControllerSubmittedInputsRetained -> fail "never-sent launch was marked submitted"
  (launch, cfg, req) <- readIORef saved >>= maybe (fail "missing never-sent launch") pure
  escaped <- submitRpcBirthControllerLaunch launch
  assert
    "sealed launch submitted after cleanup"
    (case escaped of Left (ControllerLoadInputsRefused _) -> True; _ -> False)
  if mode == "published-unsent-drift"
    then do
      assert "foreign configuration was changed" . (== "foreign configuration") =<< BS.readFile cfg
      assert "changed configuration removed request" =<< doesFileExist req
    else do
      absent <- mapM (fmap not . doesFileExist) [cfg, req]
      assert "never-sent payloads survived cleanup" (and absent)
      names <- listDirectory (takeDirectory req)
      assert
        "unexpected never-sent fence set"
        ( length names == 3
            && all
              (`elem` ["retirement-prepared.cbor", "retirement-terminal.cbor", "publication-birth.cbor"])
              names
        )
  recoveryEnd <- (+ 5000000000) <$> getMonotonicTimeNSec
  cold <- recoverNeverSentRpcBirthControllerInputs recoveryEnd original
  if mode == "published-unsent-drift"
    then assert "cold recovery accepted foreign payload" (isLeft cold)
    else do
      _ <- right cold
      pure ()
  when (mode == "published-unsent-expired") $ do
    expired <-
      prepareRpcBirthControllerRequest original (rpcBirthControllerPreparedSettings preparation)
    assert
      "never-sent cleanup renewed work"
      (case expired of Left ControllerRequestExpired -> True; _ -> False)
  Lazy.writeFile (directory </> "observation.json") $
    encode $
      object
        [ "mode" .= mode
        , "configuration" .= cfg
        , "request" .= req
        , "started_ns" .= started
        , "sealed_launch_refused" .= True
        ]
  putStrLn ("PASS built-library never-sent publication " <> mode)

publishedPhysical :: FilePath -> IO ()
publishedPhysical directory = do
  nonce <- (`showHex` "") <$> getMonotonicTimeNSec
  let key = Text.pack (replicate (31 - length nonce) '0' <> nonce <> "a")
  (preparation, _, _, started) <- fixtureWithKey key directory
  escaped <- newIORef Nothing
  result <- try $ withPublishedRpcBirthControllerLaunch preparation $ \launch -> do
    arguments <- right =<< rpcBirthControllerLaunchArguments launch
    let cfg = argumentValue "--config" arguments
        req = argumentValue "--request" arguments
    inodes <- mapM (fmap fileID . getFileStatus) [cfg, req]
    writeIORef escaped (Just (cfg, req, inodes))
    Lazy.writeFile (directory </> "field.json") $
      encode $
        object
          [ "units" .= rpcBirthControllerLaunchUnitNames launch
          , "started_ns" .= started
          , "hard_ns" .= (started + 16000000000)
          , "finish_ns" .= (started + 18000000000)
          , "config_path" .= cfg
          , "request_path" .= req
          ]
    right =<< submitRpcBirthControllerLaunch launch
    ioError (userError "authored caller failure after manager acknowledgement")
  case result :: Either IOException (Either RpcBirthControllerLoadError ()) of
    Left _ -> pure ()
    Right _ -> fail "publisher swallowed the submitted caller's exception"
  Just (cfg, req, before) <- readIORef escaped
  after <- mapM (fmap fileID . getFileStatus) [cfg, req]
  assert "submitted caller failure removed or replaced launch inputs" (before == after)
  writeFile
    (directory </> "launcher-result")
    "PASS submitted caller failed and exact input files survived\n"

physical :: FilePath -> IO ()
physical directory = do
  (preparation, configuration, request, started) <- fixture directory
  (cfg, req) <- writeInputs directory configuration request
  before <- mapM (fmap fileID . getFileStatus) [cfg, req]
  right
    =<< withRpcBirthControllerLaunchFiles
      preparation
      cfg
      req
      ( \launch -> do
          Lazy.writeFile
            (directory </> "field.json")
            ( encode
                ( object
                    [ "units" .= rpcBirthControllerLaunchUnitNames launch
                    , "started_ns" .= started
                    , "hard_ns" .= (started + 16000000000)
                    , "finish_ns" .= (started + 18000000000)
                    ]
                )
            )
          right =<< submitRpcBirthControllerLaunch launch
          duplicate <- submitRpcBirthControllerLaunch launch
          assert
            "duplicate submission accepted"
            (case duplicate of Left (ControllerLoadInputsRefused _) -> True; _ -> False)
      )
  after <- mapM (fmap fileID . getFileStatus) [cfg, req]
  assert "launch scope removed/replaced files after submission" (before == after)
  writeFile (directory </> "launcher-result") "PASS submitted once and retained exact input files\n"

controller :: [String] -> IO ()
controller flags = run `catch` failed
 where
  configuration = value "--config" flags
  value _ [] = error "missing controller fixture argument"
  value wanted (label : argument : rest) = if label == wanted then argument else value wanted rest
  value _ _ = error "malformed controller fixture arguments"
  directory = takeDirectory configuration
  failed :: IOException -> IO ()
  failed cause = writeFile (directory </> "controller-error") (show cause) >> ioError cause
  run = do
    arguments <- right (parseRpcBirthControllerArguments flags)
    right
      =<< withRpcBirthControllerInputs
        arguments
        ( \inputs -> do
            let preparation = rpcBirthControllerInputPreparation inputs
                root = S.resolvedManualPvHostRoot (rpcBirthControllerPreparedSettings preparation)
            channelCase <- doesFileExist (root </> "authority-channel-case")
            when channelCase $ do
              runtime <- lookupEnv "RUNTIME_DIRECTORY"
              present <- maybe (pure False) doesDirectoryExist runtime
              Lazy.writeFile (root </> "authority-channel-runtime.json") $
                encode (object ["runtime_directory" .= runtime, "runtime_present" .= present])
            readEnd <- (+ 1000000000) <$> getMonotonicTimeNSec
            _ <-
              right
                =<< observeRpcBirthControllerSubmission
                  readEnd
                  (value "--request" flags)
                  (rpcBirthControllerPreparedRequest preparation)
            right
              =<< withRpcBirthControllerProcesses
                inputs
                ( \processes -> do
                    if channelCase
                      then
                        ( do
                            writeFile (root </> "authority-channel-parent-admitted") "observed"
                            runAuthorityChannel
                              root
                              processes
                              (rpcBirthControllerRequestCoordination (rpcBirthControllerPreparedRequest preparation))
                        )
                          `catch` channelFailure root
                      else runOriginalProcesses processes
                )
            writeFile
              (root </> "controller-result")
              "PASS pinned loader, observed parent and concurrent command/transport\n"
        )
  runOriginalProcesses processes = do
    let spec path args =
          P.Subprocess
            path
            args
            (Just [("PATH", "/usr/bin:/bin"), ("LANG", "C.UTF-8")])
            (Just (P.operationSubprocessRuntimeDirectory processes))
    right
      =<< P.withOperationTransport
        processes
        (spec "/bin/sleep" ["2"])
        ( \transport -> do
            right =<< P.verifyOperationTransportBeforeEffect transport
            output <- right =<< P.captureOperationCommand processes (spec "/bin/printf" ["%s", "admitted"])
            assert
              "command did not execute under its declared role"
              (P.operationProcessExitCode output == ExitSuccess && P.operationProcessStdout output == "admitted")
            pure ()
        )
  channelFailure root (cause :: IOException) = do
    writeFile (root </> "controller-error") (show cause)
    throwIO cause

-- The driver deliberately records both old and replacement observations. Its
-- source, profile, original clocks and authored requests are identical in the
-- frozen/replacement comparison; the validator decides the expected verdict.
authorityChannel :: String -> FilePath -> FilePath -> IO ()
authorityChannel scenario directory forward = do
  assert
    "unsupported channel case"
    ( scenario
        `elem` [ "escape"
               , "nested"
               , "join-signer"
               , "join-http"
               , "cancel-signer"
               , "cancel-http"
               , "exception-signer"
               , "cancel-owner"
               , "startup-missing"
               , "startup-wrong-port"
               , "startup-partial"
               , "startup-good"
               ]
    )
  createDirectoryIfMissing True (directory </> "mock-bin")
  copyFile forward (directory </> "mock-bin" </> "kubectl")
  setFileMode (directory </> "mock-bin" </> "kubectl") 0o755
  writeFile (directory </> "authority-channel-case") scenario
  now <- getMonotonicTimeNSec
  let hex = showHex now ""
      key = Text.pack (replicate (32 - length hex) 'a' <> hex)
  (preparation, _, _, started) <- fixtureWithKey key directory
  right
    =<< withPublishedRpcBirthControllerLaunch
      preparation
      ( \launch -> do
          arguments <- right =<< rpcBirthControllerLaunchArguments launch
          Lazy.writeFile (directory </> "field.json") $
            encode $
              object
                [ "units" .= rpcBirthControllerLaunchUnitNames launch
                , "started_ns" .= started
                , "finish_ns" .= (started + 18000000000)
                , "config_path" .= argumentValue "--config" arguments
                , "request_path" .= argumentValue "--request" arguments
                ]
          right =<< submitRpcBirthControllerLaunch launch
      )
  writeFile (directory </> "launcher-result") "PASS channel fixture submitted\n"

runAuthorityChannel :: FilePath -> P.OperationSubprocesses -> RpcBirthCoordinationRequest -> IO ()
runAuthorityChannel directory processes request = do
  scenario <- readFile (directory </> "authority-channel-case")
  -- The native executeFile boundary searches its parent's PATH. Keep the
  -- fixture's explicit child environment and executable search identical.
  setEnv "PATH" (directory </> "mock-bin" <> ":/usr/bin:/bin")
  config <-
    right $
      prepareEmbeddedHomeKubeconfig
        "{\"apiVersion\":\"v1\",\"kind\":\"Config\",\"current-context\":\"home\",\"clusters\":[{\"name\":\"home\",\"cluster\":{\"server\":\"https://127.0.0.1:6443\",\"certificate-authority-data\":\"synthetic-ca\"}}],\"contexts\":[{\"name\":\"home\",\"context\":{\"cluster\":\"home\",\"user\":\"home\"}}],\"users\":[{\"name\":\"home\",\"user\":{\"client-certificate-data\":\"synthetic-cert\",\"client-key-data\":\"synthetic-key\"}}]}"
  count <- newIORef (0 :: Int)
  nonce <- newIORef (0 :: Int)
  nested <- newIORef False
  selected <- newIORef Nothing
  started <- newEmptyMVar
  release <- newEmptyMVar
  finished <- newIORef False
  let principal = CallerTestHarness
      baseSigner =
        localRequestSigningCapability $
          either (error . show) id $
            mkRequestSigner principal (either (error . show) id (mkSigningKeyGeneration 1)) (BS.replicate 32 41)
      record = modifyIORef' count (+ 1)
      call transport =
        Auth.callAuthenticatedClientTransport transport LifecycleMigrationApplyRoute "fixture-owned-request"
      signer =
        either (error . show) id $
          mkRequestSigningCapability
            principal
            (requestSigningCapabilityGeneration baseSigner)
            (requestSigningCapabilityPublicKeyBytes baseSigner)
            ( \bytes -> do
                record
                wasNested <- atomicModifyIORef' nested (True,)
                when (scenario == "nested" && not wasNested) $ do
                  saved <- readIORef selected
                  case saved of
                    Nothing -> fail "nested fixture transport missing"
                    Just transport -> do
                      reply <- call transport
                      assert "nested registry-shaped request failed" (not (isLeft reply))
                writeIORef nested False
                first (Text.pack . show) <$> signCanonicalBytesWithRequestCapability baseSigner bytes
            )
      provideSigner = do
        record
        when (scenario `elem` ["join-signer", "cancel-signer", "exception-signer", "cancel-owner"]) $
          (putMVar started () >> takeMVar release) `finally` writeIORef finished True
        pure (Right signer)
      providers =
        Auth.AuthenticatedClientProviders
          provideSigner
          (record >> pure (Right (rpcBirthCoordinationScope request)))
          (record >> pure (Right authorityEpochGenesis))
          (record >> pure (Right (rpcBirthCoordinationDeadline request)))
          ( do
              record
              value <- atomicModifyIORef' nonce (\old -> (old + 1, old + 1))
              pure (Right (either (error . show) id (mkRequestNonce (BS.replicate 16 (fromIntegral value)))))
          )
      environment =
        [ ("PATH", directory </> "mock-bin" <> ":/usr/bin:/bin")
        , ("LANG", "C.UTF-8")
        , ("FIXTURE_AUTHORITY_CHANNEL_ROOT", directory)
        ]
      bounds = either (error . show) id (Auth.mkAuthenticatedTransportBounds 65536 256 65000)
      owned =
        withOperationLifecycleAuthorityAuthenticatedTransport processes config environment bounds providers
      output fields = Lazy.writeFile (directory </> "authority-channel.json") (encode (object fields))
  case scenario of
    name | name `elem` ["startup-missing", "startup-wrong-port", "startup-partial", "startup-good"] -> do
      entered <- newIORef False
      outcome <- owned $ \transport -> writeIORef entered True >> call transport
      actionEntered <- readIORef entered
      calls <- readIORef count
      probes <- doesFileExist (directory </> "authority-channel-probe-started")
      posted <- doesFileExist (directory </> "authority-channel-http-started")
      output
        [ "startup_refused" .= isLeft outcome
        , "action_entered" .= actionEntered
        , "provider_calls" .= calls
        , "startup_probe_observed" .= probes
        , "post_observed" .= posted
        ]
    "escape" -> escape owned call selected count output
    "nested" -> escape owned call selected count output
    "join-signer" -> Async.withAsync (readMVar started >> threadDelay 1000000 >> putMVar release ()) $ \releaser -> do
      worker <-
        right
          =<< owned
            ( \transport -> do
                task <- Async.async (call transport)
                readMVar started
                pure task
            )
      joined <- readIORef finished
      Async.wait releaser
      _ <- Async.waitCatch worker
      output ["provider_finished_at_return" .= joined]
    "cancel-signer" -> do
      right
        =<< owned
          ( \transport -> do
              worker <- Async.async (call transport)
              readMVar started
              Async.cancel worker
              outcome <- Async.waitCatch worker
              assert "cancelled provider returned a value" (isLeft outcome)
          )
      joined <- readIORef finished
      output ["cancelled_provider_joined" .= joined]
    "join-http" -> do
      worker <-
        right
          =<< owned
            ( \transport -> do
                task <- Async.async (call transport)
                waitForFile (directory </> "authority-channel-http-started")
                pure task
            )
      joined <- doesFileExist (directory </> "authority-channel-http-finished")
      _ <- Async.waitCatch worker
      output ["http_finished_at_return" .= joined]
    "cancel-http" -> do
      right
        =<< owned
          ( \transport -> do
              worker <- Async.async (call transport)
              waitForFile (directory </> "authority-channel-http-started")
              Async.cancel worker
              outcome <- Async.waitCatch worker
              assert "cancelled HTTP returned a value" (isLeft outcome)
          )
      output ["cancelled_http_joined" .= True]
    "exception-signer" -> Async.withAsync (readMVar started >> threadDelay 1000000 >> putMVar release ()) $ \releaser -> do
      saved <- newIORef Nothing
      outcome <-
        owned
          ( \transport -> do
              worker <- Async.async (call transport)
              writeIORef saved (Just worker)
              readMVar started
              ioError (userError "authored channel callback failure")
          )
      joined <- readIORef finished
      Async.wait releaser
      worker <- readIORef saved
      forM_ worker Async.waitCatch
      output ["callback_failure_refused" .= isLeft outcome, "provider_finished_at_failure" .= joined]
    "cancel-owner" -> Async.withAsync (readMVar started >> threadDelay 1000000 >> putMVar release ()) $ \releaser -> do
      saved <- newIORef Nothing
      parked <- newEmptyMVar
      owner <-
        Async.async $
          owned
            ( \transport -> do
                worker <- Async.async (call transport)
                writeIORef saved (Just worker)
                takeMVar parked
            )
      readMVar started
      Async.withAsync (Async.cancel owner) $ \firstCancel -> do
        threadDelay 10000
        Async.cancel owner
        Async.wait firstCancel
      joined <- readIORef finished
      Async.wait releaser
      worker <- readIORef saved
      forM_ worker Async.waitCatch
      output ["provider_finished_at_owner_cancel" .= joined]
    _ -> fail "unsupported native channel scenario"
 where
  waitForFile path = do
    present <- doesFileExist path
    unless present (threadDelay 1000 >> waitForFile path)
  escape owned call selected count output = do
    transport <-
      right
        =<< owned
          ( \value -> do
              writeIORef selected (Just value)
              inside <- call value
              assert "live native channel request failed" (not (isLeft inside))
              pure value
          )
    writeIORef count 0
    rawPort <- readFile (directory </> "authority-channel-port")
    let port = read rawPort :: Int
    observed <- newIORef (0 :: Int)
    bracket (Net.socket Net.AF_INET Net.Stream Net.defaultProtocol) Net.close $ \listener -> do
      Net.setSocketOption listener Net.ReuseAddr 1
      Net.bind listener (Net.SockAddrInet (fromIntegral port) (Net.tupleToHostAddress (127, 0, 0, 1)))
      Net.listen listener 8
      Async.withAsync
        ( forever $ bracket (fst <$> Net.accept listener) Net.close $ \connection -> do
            _ <- recv connection 65536
            modifyIORef' observed (+ 1)
            sendAll connection "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        )
        $ \_ -> do
          attempted <- timeout 2000000 (call transport)
          calls <- readIORef count
          packets <- readIORef observed
          output
            [ "escaped_success" .= maybe False (not . isLeft) attempted
            , "provider_calls_after_release" .= calls
            , "http_requests_after_release" .= packets
            ]
