{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Codec.Serialise (serialise)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception
  ( AsyncException (ThreadKilled)
  , IOException
  , bracket
  , catch
  , fromException
  , try
  )
import Control.Monad (forM_, forever, unless, when, (>=>))
import Control.Monad.Trans.Class (lift)
import ControlPlaneRpcAdmissionBirth
  ( RpcBirthCallerVaultFault (..)
  , rpcBirthHomeRegistryFixture
  , withRpcBirthCallerVaultFixture
  , withRpcBirthCoordinatorWireFixture
  , withRpcBirthPreparedCoordinatorWireFixture
  )
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf, isSuffixOf)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Word (Word64)
import Dhall qualified
import GHC.Clock (getMonotonicTimeNSec)
import HostOperationRpcBirthFixture
import Network.Socket qualified as Net
import Network.Socket.ByteString qualified as NetBytes
import Prodbox.Config.Tier0 qualified as Tier0
import Prodbox.ContainerImage qualified as ContainerImage
import Prodbox.ControlPlane.AuthenticatedTransport (AuthenticatedClientError (..))
import Prodbox.ControlPlane.AuthorityPeerContextClient (AuthorityPeerContextClientError (..))
import Prodbox.ControlPlane.Client qualified as Client
import Prodbox.ControlPlane.Coordinate (authorityScopeText, mkAuthorityScope)
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalCallerTokenError (..)
  , ExternalLifecycleAuthorityCaller (..)
  , LifecycleAuthorityAuthenticationError (..)
  , ServiceAccountObservationFailure (..)
  )
import Prodbox.ControlPlane.LocalClient
  ( LocalLifecycleAuthorityError (..)
  , lifecycleAuthorityRemotePort
  )
import Prodbox.ControlPlane.RegisteredRpcSigning (RpcKeyRegistryObserver (..))
import Prodbox.ControlPlane.RequestAuthentication (RequestSigningCapabilityError (..))
import Prodbox.ControlPlane.RpcAdmissionBirth
import Prodbox.ControlPlane.RpcAdmissionBirthBootstrap (RpcBirthBootstrapError (..))
import Prodbox.ControlPlane.RpcAdmissionBirthChart
import Prodbox.ControlPlane.RpcAdmissionBirthConfig
import Prodbox.ControlPlane.RpcAdmissionBirthCoordinator
import Prodbox.ControlPlane.RpcAdmissionBirthEndpoint (RpcBirthClientError (..))
import Prodbox.ControlPlane.RpcAdmissionBirthNative (rpcBirthSystemTime)
import Prodbox.ControlPlane.RpcAdmissionBirthPublication (tier0RpcBirthPublicationAtPath)
import Prodbox.ControlPlane.RpcAdmissionBirthRollout
import Prodbox.ControlPlane.RpcKeyRegistry (RpcKeyRegistryError (RpcKeyBindingMissing))
import Prodbox.ControlPlane.RpcOwnBindingHint
import Prodbox.ControlPlane.Runtime qualified as Runtime
import Prodbox.ControlPlane.Server qualified as Server
import Prodbox.Http.ReplyStatus (ReplyStatus (..), replyStatusFromCode)
import Prodbox.Lib.ChartPlatform
import Prodbox.Lib.Storage
import Prodbox.Lifecycle.Lease
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import Prodbox.Settings qualified as Settings
import Prodbox.Subprocess qualified as S
import Prodbox.Subprocess.HostOperationFamily
import Prodbox.Subprocess.KernelScope qualified as Kernel
import Prodbox.Subprocess.SystemdBus
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import Prodbox.Substrate (Substrate (SubstrateHomeLocal))
import Prodbox.Vault.Client (VaultAddress (..))
import Prodbox.Vault.Session (VaultSessionError (..))
import System.Directory
import System.Environment
import System.Exit
import System.FilePath
import System.IO (hFlush, stdout)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files
  ( createLink
  , fileMode
  , getSymbolicLinkStatus
  , readSymbolicLink
  , setFileMode
  )
import System.Posix.IO qualified as IO
import System.Posix.IO.ByteString qualified as Posix
import System.Posix.Types (Fd)
import System.Posix.User (getEffectiveUserID)
import TestSupport (syntheticConfigFile, syntheticProjectConfig)
import Text.Read (readMaybe)
import Tier0Fixture (tier0Fixture, writeTier0Fixture)
import "cryptohash-sha256" Crypto.Hash.SHA256 qualified as SHA256

main :: IO ()
main = do
  program <- takeFileName <$> getProgName
  args <- getArgs
  case program of
    "helm" -> fakeHelm args
    "kubectl" -> fakeKubectl args
    "docker" -> fakeDocker args
    _ -> case args of
      [directory, mode] -> launch directory mode
      "internal-rpc-birth-controller" : flags -> controller flags
      _ -> fail "unsupported native fixture invocation"

controller :: [String] -> IO ()
controller flags = run `catch` failed
 where
  pairs [] = []
  pairs (label : value : rest) = (label, value) : pairs rest
  pairs _ = error "malformed closed fixture arguments"
  arguments = pairs flags
  required label = maybe (fail ("missing " ++ label)) pure (lookup label arguments)
  failed :: IOException -> IO ()
  failed cause = do
    configuration <- required "--config"
    writeFile (takeDirectory configuration </> "worker-error") (show cause)
    ioError cause
  run = do
    configuration <- required "--config"
    request <- required "--request"
    let clock label = required label >>= maybe (fail "original fixture clock") pure . readMaybe
    [outer, work, hard, stop, finish] <-
      mapM clock ["--outer-ns", "--work-ns", "--hard-ns", "--stop-ns", "--finish-ns"]
    window <- maybe (fail "window") pure (Identity.hostExecutionWindow outer work hard stop finish)
    keyText <- required "--operation-key"
    key <- maybe (fail "operation key") pure (Identity.hostExecutionKeyFromText keyText)
    fingerprintText <- required "--input-fingerprint"
    fingerprint <-
      maybe (fail "input fingerprint") pure (parseHostControllerInputFingerprint fingerprintText)
    right
      =<< withPinnedHostControllerProgram
        Identity.RpcBirthController
        work
        fingerprint
        configuration
        request
        ( \program -> do
            bytes <- right =<< readHostControllerProgramInputs program
            [mode, authorityText] <- pure (lines (Bytes.unpack (hostControllerRequestBytes bytes)))
            authority <-
              maybe (fail "authority deadline") (pure . authorityTimeFromMicros) (readMaybe authorityText)
            observed <- right (decodeObserved (Lazy.fromStrict (hostControllerConfigurationBytes bytes)))
            plan <- fixturePlanFrom observed
            helper <- maybe (fail "helper bounds") pure (hostOperationHelperBounds 20000 20000)
            intent <- right =<< newHostOperationIntent Identity.RpcBirthController plan helper key window
            worker (takeDirectory configuration) mode authority window intent program
        )

requestFor :: AuthorityTime -> IO RpcBirthCoordinationRequest
requestFor deadline = do
  scope <- right (mkAuthorityScope "home")
  right (mkRpcBirthCoordinationRequest scope deadline 1 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

executionText :: RpcBirthCoordinationRequest -> String
executionText request = concatMap hex (BS.unpack (SHA256.hash payload))
 where
  payload =
    Lazy.toStrict
      ( serialise
          ( "prodbox-rpc-birth-host/v1" :: Text.Text
          , authorityScopeText (rpcBirthCoordinationScope request)
          , rpcBirthCoordinationGeneration request
          , rpcBirthCoordinationKey request
          )
      )
  hex byte =
    [ "0123456789abcdef" !! fromIntegral (byte `div` 16)
    , "0123456789abcdef" !! fromIntegral (byte `mod` 16)
    ]

-- The original serial fixture had 50/40/42/45/47 second clocks and a
-- 256 MiB/700m/56-task family. This profile preserves those aggregate totals.
launch :: FilePath -> String -> IO ()
launch relative mode = do
  directory <- makeAbsolute relative
  setFileMode directory 0o700
  executable <- getExecutablePath
  let tools = directory </> "tools"
      configuration = directory </> "observed.json"
      requestFile = directory </> "request"
  createDirectory tools
  forM_ ["helm", "kubectl", "docker"] $ \name -> createLink executable (tools </> name)
  (plan, observed) <- fixturePlan
  Lazy.writeFile configuration (encode (observedValue observed))
  now <- rpcBirthSystemTime
  let authority = authorityTimeFromMicros (authorityTimeMicros now + 60000000)
  request <- requestFor authority
  key <- right (rpcBirthRolloutExecutionKey request)
  unless
    (Identity.hostExecutionKeyFromText (executionText request) == Just key)
    (fail "independent recovery field disagrees")
  writeFile requestFile (unlines [mode, show (authorityTimeMicros authority)])
  mapM_ (`setFileMode` 0o600) [configuration, requestFile]
  started <- getMonotonicTimeNSec
  let outer = started + 50000000000
      work = started + 40000000000
      hard = started + 42000000000
      stop = started + 45000000000
      finish = started + 47000000000
  window <- maybe (fail "window") pure (Identity.hostExecutionWindow outer work hard stop finish)
  writeFile (directory </> "window") (show [outer, work, hard, stop, finish])
  helper <- maybe (fail "helper bounds") pure (hostOperationHelperBounds 20000 20000)
  intent <- right =<< newHostOperationIntent Identity.RpcBirthController plan helper key window
  right
    =<< withCurrentHostControllerProgram
      Identity.RpcBirthController
      work
      configuration
      requestFile
      ( \program -> do
          uid <- getEffectiveUserID
          let runtime = "/run/user/" ++ show uid ++ "/" ++ hostOperationRuntimeDirectory intent
              group =
                "/sys/fs/cgroup/user.slice/user-"
                  ++ show uid
                  ++ ".slice/user@"
                  ++ show uid
                  ++ ".service/"
                  ++ Identity.hostControllerSliceName
              flags = IO.defaultFileFlags {IO.directory = True, IO.nofollow = True, IO.cloexec = True}
          Lazy.writeFile (directory </> "field.json") $
            encode $
              object
                [ "key" .= Identity.hostExecutionKeyText key
                , "roles" .= map (hostOperationUnitName intent) [minBound .. maxBound]
                , "outer_ns" .= outer
                , "work_ns" .= work
                , "hard_ns" .= hard
                , "stop_ns" .= stop
                , "finish_ns" .= finish
                ]
          result <- withSystemdBus outer ("/run/user/" ++ show uid ++ "/bus") $ \connection -> lift $ do
            right =<< submitHostOperationFamily connection intent program
            waitUntil work (doesDirectoryExist group)
            bracket (IO.openFd group IO.ReadOnly flags) IO.closeFd $ \held -> do
              when (mode == "parent-death") $
                observeParentDeath directory window intent held
              waitUntil finish $ do
                inventory <-
                  right
                    =<< withSystemdBus
                      finish
                      ("/run/user/" ++ show uid ++ "/bus")
                      (\c -> observeHostOperationFamily c intent)
                pure (hostOperationAbsent inventory)
              waitUntil finish $ do
                target <- readSymbolicLink ("/proc/self/fd/" ++ show held)
                gone <-
                  try
                    ( bracket
                        ( IO.openFdAt
                            (Just held)
                            "cgroup.events"
                            IO.ReadOnly
                            IO.defaultFileFlags {IO.nofollow = True, IO.cloexec = True}
                        )
                        IO.closeFd
                        (const (pure ()))
                    )
                    :: IO (Either IOException ())
                pure (" (deleted)" `isSuffixOf` target && either isDoesNotExistError (const False) gone)
            retained <- doesDirectoryExist runtime
            when retained (fail "actual manager workspace survived terminal family")
            Lazy.writeFile (directory </> "closing.json") $
              encode
                (object ["exactSixRolesAbsent" .= True, "heldGroupRetired" .= True, "managerWorkspaceAbsent" .= True])
          right result
          when (mode /= "parent-death") $ do
            report <- readFile (directory </> "result")
            unless (report == "PASS") (fail "domain fixture did not report PASS")
          putStrLn
            "PASS: authenticated coordinator through owned relay and command roles; exact six-role absence, held group retirement and workspace absence"
      )

waitUntil :: Word64 -> IO Bool -> IO ()
waitUntil ending observation = do
  now <- getMonotonicTimeNSec
  when (now >= ending) (fail "original native observation bound expired")
  ready <- observation
  unless ready (threadDelay 1000 >> waitUntil ending observation)

observeParentDeath :: FilePath -> Identity.HostExecutionWindow -> HostOperationIntent -> Fd -> IO ()
observeParentDeath directory window intent held = do
  let work = Identity.hostExecutionWorkEnd window
      flags = IO.defaultFileFlags {IO.directory = True, IO.nofollow = True, IO.cloexec = True}
  waitUntil work (doesFileExist (directory </> "applying"))
  bracket
    (IO.openFdAt (Just held) (hostOperationUnitName intent OperationCommand) IO.ReadOnly flags)
    IO.closeFd
    $ \commandRoot ->
      bracket
        (IO.openFdAt (Just held) (hostOperationUnitName intent OperationTransport) IO.ReadOnly flags)
        IO.closeFd
        $ \transportRoot -> do
          forM_ [commandRoot, transportRoot] $ \root ->
            bracket
              ( IO.openFdAt
                  (Just root)
                  "cgroup.events"
                  IO.ReadOnly
                  IO.defaultFileFlags {IO.nofollow = True, IO.cloexec = True}
              )
              IO.closeFd
              $ \events -> do
                content <- Posix.fdRead events 4096
                unless
                  (any ((== ["populated", "1"]) . Bytes.words) (Bytes.lines content))
                  (fail "parent-death role was not independently live")
          uid <- getEffectiveUserID
          stopped <- withSystemdBus work ("/run/user/" ++ show uid ++ "/bus") $ \connection -> do
            path <-
              callManager
                connection
                GetUnit
                (\m -> appendString m (hostOperationUnitName intent OperationController))
                (`readString` 'o')
            invocation <-
              callManager
                connection
                (ReadUnitProperty path)
                (\m -> appendString m "org.freedesktop.systemd1.Unit" >> appendString m "InvocationID")
                readVariantInvocationId
            alias <-
              callManager
                connection
                (GetUnitByInvocationID invocation)
                (const (pure ()))
                (readInvocationPath invocation)
            _ <- callManager connection (StopInvocationUnit alias) (const (pure ())) (`readString` 'o')
            pure ()
          right stopped
          forM_ [commandRoot, transportRoot] $ \root -> waitUntil work $ do
            target <- readSymbolicLink ("/proc/self/fd/" ++ show root)
            gone <-
              try
                ( bracket
                    ( IO.openFdAt
                        (Just root)
                        "cgroup.events"
                        IO.ReadOnly
                        IO.defaultFileFlags {IO.nofollow = True, IO.cloexec = True}
                    )
                    IO.closeFd
                    (const (pure ()))
                )
                :: IO (Either IOException ())
            pure (" (deleted)" `isSuffixOf` target && either isDoesNotExistError (const False) gone)
          stillArmed <- withSystemdBus work ("/run/user/" ++ show uid ++ "/bus") $ \connection -> do
            inventory <- observeHostOperationFamily connection intent
            case (hostOperationPresence inventory OperationTimer, hostOperationPresence inventory OperationSlice) of
              (HostOperationPresent (InvocationPresent _), HostOperationPresent _) -> pure ()
              _ -> fail "parent death lost the original armed family"
            timer <-
              callManager
                connection
                GetUnit
                (\m -> appendString m (hostOperationUnitName intent OperationTimer))
                (`readString` 'o')
            _ <-
              callManager
                connection
                (ReadUnitProperty timer)
                (\m -> appendString m "org.freedesktop.systemd1.Timer" >> appendString m "TimersMonotonic")
                (readVariantOriginalBootTimer (Identity.hostExecutionHardEnd window `div` 1000))
            pure ()
          right stillArmed
          writeFile
            (directory </> "parent-death-observation")
            "both actual roles independently live before stop; both held groups retired before original work end; original alarm and slice retained"

worker
  :: FilePath
  -> String
  -> AuthorityTime
  -> Identity.HostExecutionWindow
  -> HostOperationIntent
  -> HostControllerProgram
  -> IO ()
worker directory mode deadline window intent program =
  if authenticationMode mode
    then withRpcBirthCallerVaultFixture (fixtureCaller mode) (callerVaultFault mode) $ \address paths ->
      workerWithCallerVault (Just (address, paths)) directory mode deadline window intent program
    else workerWithCallerVault Nothing directory mode deadline window intent program

workerWithCallerVault
  :: Maybe (VaultAddress, IORef [String])
  -> FilePath
  -> String
  -> AuthorityTime
  -> Identity.HostExecutionWindow
  -> HostOperationIntent
  -> HostControllerProgram
  -> IO ()
workerWithCallerVault callerVault directory mode deadline window intent program = do
  let note label = do
        moment <- getMonotonicTimeNSec
        appendFile (directory </> "timings") (label ++ " " ++ show moment ++ "\n")
  note "worker-entry"
  executable <- getExecutablePath
  let project =
        syntheticProjectConfig
          { Tier0.context =
              (Tier0.context syntheticProjectConfig)
                { Tier0.cluster_id = "home"
                , Tier0.vault_address = case callerVault of
                    Just (VaultAddress address, _) -> address
                    Nothing -> Tier0.vault_address (Tier0.context syntheticProjectConfig)
                }
          }
  writeTier0Fixture (takeDirectory executable) (tier0Fixture project)
  note "schemas"
  let root = directory </> "source"
      chart = root </> "charts" </> "lifecycle-authority"
      original = "/home/matthewnowak/prodbox/charts/lifecycle-authority"
  createDirectoryIfMissing True (chart </> "templates")
  names <- listDirectory (original </> "templates")
  forM_ (["Chart.yaml", "values.yaml"] ++ map ("templates" </>) names) $ \name -> copyFile (original </> name) (chart </> name)
  let context = Tier0.context project
      input =
        Settings.DeploymentContextInput
          (Tier0.cluster_id context)
          (Tier0.vault_address context)
          (Tier0.minio_endpoint context)
          (Tier0.rpc_registration context)
      image =
        ResolvedCustomImage
          "registry.test/prodbox/runtime"
          "held-native"
          (Just ("sha256:" ++ replicate 64 'a'))
          (Just ("sha256:" ++ replicate 64 'b'))
      observers =
        ChartPlanObservers
          (const (pure (Right (Just image))))
          (pure (Right (KubernetesApiEgressCoordinate ["10.0.0.1"] 6443)))
  scope <- right (mkAuthorityScope "home")
  settings <- Settings.validateConfigWithContext root input syntheticConfigFile >>= right
  note "settings"
  template <-
    if ownedPreparationMode mode
      then pure Nothing
      else Just <$> (prepareRpcBirthChartWithObservers observers scope root settings >>= right)
  note "template"
  planned <-
    buildChartDeploymentPlanForSubstrateWithObservers
      observers
      SubstrateHomeLocal
      root
      settings
      "lifecycle-authority"
      Map.empty
      Map.empty
      >>= right
  note "duplicate-plan"
  binding <- case concatMap chartReleasePlanStorageBindings (chartDeploymentPlanReleases planned) of
    [value] -> pure value
    _ -> fail "fixture journal binding"
  when (mode == "unicode") $
    unless
      ('卷' `elem` chartStorageBindingHostPath binding)
      (fail "Unicode journal path was not selected")
  let source = directory </> "prodbox.dhall"
  Tier0.writeTier0AtPath source project >>= right
  note "source"
  Lazy.writeFile (directory </> "home.json") (encode homeConfig)
  Lazy.writeFile (directory </> "claim.json") (encode (claimFor binding))
  Lazy.writeFile (directory </> "volume.json") (encode (volumeFor binding))
  setEnv "RPC_BIRTH_FIXTURE_DIRECTORY" directory
  setEnv "RPC_BIRTH_FIXTURE_MODE" mode
  forM_ ambientIdentityKeys $ \name -> setEnv name "synthetic-fixture-only"
  path <- getEnv "PATH"
  setEnv "PATH" (directory </> "tools" ++ ":" ++ path)
  setEnv "TMPDIR" directory
  note "held-host-plan"
  request <- case mode of
    "wrong-key" -> right (mkRpcBirthCoordinationRequest scope deadline 2 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    "owned-wrong-key" -> right (mkRpcBirthCoordinationRequest scope deadline 2 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    "authority-window" -> requestFor (authorityTimeFromMicros (authorityTimeMicros deadline - 30000000))
    _ -> requestFor deadline
  servingCache <- newIORef Nothing
  let observeServing = do
        present <- doesFileExist (directory </> "applied-values.json")
        if not present || mode == "runtime-ack-only"
          then pure Nothing
          else do
            cached <- readIORef servingCache
            case cached of
              Just value -> pure (Just value)
              Nothing -> do
                value <- right . eitherDecodeStrict' =<< BS.readFile (directory </> "applied-values.json")
                role <- case value of
                  Object fields
                    | Just (Object cfg) <- KM.lookup "config" fields
                    , Just (String text) <- KM.lookup "roleDhall" cfg ->
                        pure text
                  _ -> fail "actual applied role"
                config <- Dhall.input Dhall.auto role
                selected <-
                  right
                    ( validateRpcBirthConfig
                        LifecycleAuthorityRuntime
                        scope
                        (Runtime.rpc_registration (config :: Runtime.ControlPlaneConfig))
                    )
                writeIORef servingCache (Just selected)
                pure (Just selected)
  authentication <- newIORef Nothing
  let withWire action =
        if registeredAuthenticationMode mode
          then withRpcBirthPreparedCoordinatorWireFixture deadline observeServing $ \registration observer ->
            action registration (Just observer)
          else
            withRpcBirthCoordinatorWireFixture deadline observeServing (action RpcBirthConfigLegacy Nothing)
  result <- withWire $ \registration registryObserver bounds providers wire probe -> withAuthorityListener mode (totalBootstrapWire directory mode callerVault registryObserver wire) $ \remotePort -> do
    note "protocol-setup"
    capturedSettings <- case registration of
      RpcBirthConfigLegacy -> pure settings
      RpcBirthConfigRegistered _ -> do
        let registeredInput =
              Settings.DeploymentContextInput
                (Tier0.cluster_id context)
                (Tier0.vault_address context)
                (Tier0.minio_endpoint context)
                (if mode == "owned-total-registered-pin-mismatch" then mismatchingPin registration else registration)
            publication =
              tier0RpcBirthPublicationAtPath scope source (\_ _ -> fail "fixture setup cannot reconcile runtime")
        coordinationPublishSource publication deadline RpcBirthConfigLegacy registration >>= right
        observed <- coordinationReadSource publication deadline >>= right
        unless
          (observed == registration)
          (fail "fixture setup did not read back its exact registration pin")
        writeFile (directory </> "captured-registration") (show registration)
        Settings.validateConfigWithContext root registeredInput syntheticConfigFile >>= right
    setEnv "RPC_BIRTH_FIXTURE_REMOTE_PORT" (show remotePort)
    uid <- getEffectiveUserID
    owner <-
      right
        =<< withSystemdBus
          (Identity.hostExecutionOuterEnd window)
          ("/run/user/" ++ show uid ++ "/bus")
          ( \connection -> lift $
              Kernel.withObservedOperationParent connection intent program $ \parent -> do
                note "host-lease"
                limits <- right (S.mkOperationStreamLimits 65536 65536 500000)
                processes <- right (S.operationSubprocesses parent limits limits)
                let home = RpcBirthRolloutObservers (pure (Right (directory </> "home.json")))
                outcome <- case template of
                  Just held ->
                    coordinateRpcBirthOnOperationWithObservers home processes request bounds providers source held
                  Nothing -> do
                    prepared <- prepareRpcBirthOnOperationWithObservers home processes request root capturedSettings
                    case prepared of
                      Left cause -> pure (Left cause)
                      Right held -> do
                        removeDirectoryRecursive (root </> "charts")
                        if authenticationMode mode
                          then
                            authenticatePreparedFixture
                              directory
                              mode
                              window
                              source
                              held
                              callerVault
                              registryObserver
                              authentication
                          else do
                            token <-
                              if callerTokenMode mode
                                then do
                                  when (mode == "owned-token-expired") (waitForOriginalWorkEnd window)
                                  mintPreparedRpcBirthCallerToken (fixtureCaller mode) held
                                else pure (Right "synthetic-token")
                            case token of
                              Left cause -> do
                                when (mode == "owned-token-expired") $ do
                                  unless
                                    (cause == RpcBirthHostPreparationRefused RpcBirthRolloutDeadlineReached)
                                    (fail "caller-token adapter changed its expired refusal")
                                  writeFile (directory </> "token-disposition") "expired-refused"
                                pure (Left cause)
                              Right value -> do
                                unless (value == "synthetic-token") (fail "caller token changed")
                                coordinatePreparedRpcBirthOnOperation bounds providers source held
                pure (Right outcome)
          )
    note "coordinate-return"
    retainedAuthentication <- readIORef authentication
    case (callerVault, retainedAuthentication) of
      (Just (_, paths), Just escaped) -> do
        before <- readIORef paths
        refused <- coordinateAuthenticatedRpcBirthOnOperation source escaped
        case refused of
          Left
            ( RpcBirthHostPreparationRefused
                (RpcBirthRolloutOperationRefused _ (S.OperationScopeRefused Kernel.KernelHostPlacementClosed))
              ) -> pure ()
          _ -> fail "escaped authentication did not refuse its closed parent before effects"
        after <- readIORef paths
        unless (before == after) (fail "escaped authentication contacted Vault")
        writeFile (directory </> "authentication-scope") "closed-parent-refused"
      _ -> pure ()
    (phase, frames) <- probe
    writeFile
      (directory </> "observations")
      ( unlines
          [ "owner=" ++ show owner
          , "phase=" ++ show phase
          , "frames=" ++ show (length frames)
          , "allOriginalBounds=" ++ show (all (== deadline) frames)
          ]
      )
    let effect detail =
          RpcBirthHostCoordinationRefused
            (RpcBirthCoordinationEffectFailed CoordinationReconcileRuntime detail)
        expected = case mode of
          "pending" -> Just (effect "RpcBirthRolloutConcurrentRelease HelmStatusPendingUpgrade")
          "failed" -> Just (effect "RpcBirthRolloutRetainedRelease HelmStatusFailed")
          "unobservable" -> Just (effect "RpcBirthRolloutReleaseUnobservable")
          "apply-failure" -> Just (effect "RpcBirthRolloutCommandFailed RolloutApplyChart")
          "runtime-ack-only" ->
            Just
              (RpcBirthHostCoordinationRefused (RpcBirthCoordinationObservationInvalid CoordinationObserveRuntime))
          "response-overflow" ->
            Just
              ( RpcBirthHostCoordinationRefused
                  ( RpcBirthCoordinationRequestFailed
                      CoordinationObserveInitial
                      ( RpcBirthClientTransport
                          (AuthenticatedClientTransportFailed (Client.ControlPlaneResponseTooLarge 65537 65536))
                      )
                  )
              )
          "readiness-oversized" ->
            Just
              ( RpcBirthHostPreparationRefused
                  ( RpcBirthRolloutTransportRefused
                      (LocalLifecycleAuthorityReadinessFailed "startup response exceeds its 4096-byte bound")
                  )
              )
          "transport-exit" ->
            Just
              ( RpcBirthHostPreparationRefused
                  ( RpcBirthRolloutTransportRefused
                      (LocalLifecycleAuthorityOperationFailed (S.OperationTransportExited (ExitFailure 7)))
                  )
              )
          "wrong-key" -> Just (RpcBirthHostPreparationRefused RpcBirthRolloutHostIdentityMismatch)
          "authority-window" -> Just (RpcBirthHostPreparationRefused RpcBirthRolloutWindowOutsideAuthorityBound)
          "owned-wrong-key" -> Just (RpcBirthHostPreparationRefused RpcBirthRolloutHostIdentityMismatch)
          "owned-image-foreign" -> Just (RpcBirthHostPreparationRefused RpcBirthRolloutRuntimeImageInvalid)
          "owned-image-ambiguous" -> Just (RpcBirthHostPreparationRefused RpcBirthRolloutRuntimeImageInvalid)
          "owned-image-failure" -> Just (RpcBirthHostPreparationRefused (RpcBirthRolloutCommandFailed RolloutObserveRuntimeImage))
          "owned-api-zero" -> Just (RpcBirthHostPreparationRefused RpcBirthRolloutApiEgressInvalid)
          "owned-api-overflow" -> Just (RpcBirthHostPreparationRefused RpcBirthRolloutApiEgressInvalid)
          "owned-api-failure" -> Just (RpcBirthHostPreparationRefused (RpcBirthRolloutCommandFailed RolloutObserveApiEgress))
          _ -> Nothing
    case (mode, owner, phase, expected) of
      (selected, Right (Right _), BirthCommitted, _)
        | successfulMode selected ->
            unless
              (length frames == expectedFrameCount selected)
              (fail "fresh frame budget changed")
      (selected, _, _, _) | successfulMode selected -> fail "healthy mode did not commit"
      (selected, Right (Left actual), phaseBefore, _)
        | totalAuthenticationMode selected
        , phaseBefore == if registeredAuthenticationMode selected then BirthPrepared else BirthLegacy
        , expectedTotalAuthenticationRefusal selected actual -> do
            let expectedFrames = case selected of
                  "owned-total-registered-pin-mismatch" -> 2
                  "owned-total-registered-registry-unavailable" -> 2
                  "owned-total-registered-loss-during-sign" -> 2
                  "owned-total-response-overflow" -> 2
                  _ -> 0
            unless
              (length frames == expectedFrames)
              (fail "total authentication crossed another protocol boundary")
      ("owned-total-expired", Left Kernel.KernelScopeDeadlineReached, BirthLegacy, _) -> do
        disposition <- readFile (directory </> "authentication-disposition")
        unless
          (disposition == "expired-refused" && null frames)
          (fail "total authentication lost its original expiry evidence")
      (selected, Right (Left actual), phaseBefore, _)
        | authenticationMode selected
        , phaseBefore == if registeredAuthenticationMode selected then BirthPrepared else BirthLegacy
        , expectedAuthenticationRefusal selected actual ->
            unless (null frames) (fail "refused authentication reached the coordinator")
      ("owned-auth-expired", Left Kernel.KernelScopeDeadlineReached, BirthLegacy, _) -> do
        disposition <- readFile (directory </> "authentication-disposition")
        unless
          (disposition == "expired-refused" && null frames)
          (fail "expired authentication refusal was not recorded before parent closure")
      (selected, Right (Left actual), BirthLegacy, _)
        | callerTokenMode selected && expectedCallerTokenRefusal selected actual ->
            unless (null frames) (fail "refused token reached the authenticated protocol")
      ("owned-token-expired", Left Kernel.KernelScopeDeadlineReached, BirthLegacy, _) -> do
        disposition <- readFile (directory </> "token-disposition")
        unless
          (disposition == "expired-refused" && null frames)
          (fail "expired caller-token refusal was not recorded before parent closure")
      (_, Right (Left actual), BirthPrepared, Just desired) | actual == desired -> pure ()
      ("response-overflow", Right (Left actual), BirthLegacy, Just desired) | actual == desired -> do
        unless (length frames == 2) (fail "overflow crossed another authenticated boundary")
        applied <- doesFileExist (directory </> "applied-values.json")
        when applied (fail "overflow reached chart application")
      (selected, Right (Left actual), BirthLegacy, Just desired)
        | ownedPreparationMode selected
            || selected `elem` ["readiness-oversized", "transport-exit", "wrong-key", "authority-window"]
        , actual == desired ->
            unless (null frames) (fail "refused client reached authenticated protocol")
      (selected, Right (Left actual), phaseBefore, _)
        | selected `elem` ["deadline", "readiness-unavailable"]
        , deadlineRefusal actual -> do
            moment <- getMonotonicTimeNSec
            unless
              (moment >= Identity.hostExecutionWorkEnd window)
              (fail "deadline refused before original work end")
            unless
              (phaseBefore == if selected == "deadline" then BirthPrepared else BirthLegacy)
              (fail "deadline changed durable phase")
            applied <- doesFileExist (directory </> "applied-values.json")
            when applied (fail "deadline reached chart application completion")
            when (selected == "readiness-unavailable") $
              unless (null frames) (fail "unready client reached authenticated protocol")
      (selected, Left Kernel.KernelScopeDeadlineReached, phaseBefore, _)
        | selected `elem` ["deadline", "readiness-unavailable"] -> do
            moment <- getMonotonicTimeNSec
            unless
              (moment >= Identity.hostExecutionWorkEnd window)
              (fail "parent deadline refused before original work end")
            unless
              (phaseBefore == if selected == "deadline" then BirthPrepared else BirthLegacy)
              (fail "parent deadline changed durable phase")
            applied <- doesFileExist (directory </> "applied-values.json")
            when applied (fail "parent deadline reached chart application completion")
            when (selected == "readiness-unavailable") $
              unless (null frames) (fail "unready parent reached authenticated protocol")
      _ -> fail "unexpected domain or protocol result"
    unless (all (== deadline) frames) (fail "RPC bound renewed")
    when (ownedPreparationMode mode) $ do
      exists <- doesFileExist (directory </> "events")
      events <- if exists then lines <$> readFile (directory </> "events") else pure []
      let count label = length (filter (== label) events)
      unless
        (count "kubectl config view" == if mode == "owned-wrong-key" then 0 else 1)
        (fail "home kubeconfig was recaptured or preparation ran before admission")
      when (successfulMode mode) $
        unless
          (count "docker image-inspect" == 1 && count "kubectl api-egress" == 1)
          (fail "canonical metadata was not observed exactly once")
      when (callerTokenMode mode) $ do
        let tokenEvents = filter (isPrefixOf "caller-token ") events
            expectedCount = case mode of
              "owned-token-account-refused" -> 1
              "owned-token-rbac-refused" -> 2
              "owned-token-expired" -> 0
              _ -> 3
        unless
          (length tokenEvents == expectedCount)
          (fail "caller-token stages continued after refusal or were skipped")
      case callerVault of
        Nothing -> pure ()
        Just (_, paths) -> do
          observed <- readIORef paths
          let logins = length (filter (== "/v1/auth/kubernetes/login") observed)
              signatures = length (filter (isPrefixOf "/v1/transit/sign/") observed)
              tokenStages = length (filter (isPrefixOf "caller-token ") events)
              valid
                | totalAuthenticationMode mode =
                    totalAuthenticationCounts mode logins signatures tokenStages
                | otherwise = case mode of
                    "owned-auth-operator" -> logins == 1 && signatures == 12 && tokenStages == 3
                    "owned-auth-harness" -> logins == 1 && signatures == 12 && tokenStages == 3
                    "owned-auth-refresh" -> logins >= 2 && signatures == 12 && tokenStages == 3 * logins
                    "owned-auth-cancel" -> logins == 2 && signatures == 12 && tokenStages == 6
                    "owned-auth-mode-mismatch" -> logins == 0 && signatures == 0 && tokenStages == 0
                    "owned-auth-expired" -> logins == 0 && signatures == 0 && tokenStages == 0
                    "owned-auth-login-denied" -> logins == 1 && signatures == 0 && tokenStages == 3
                    "owned-auth-unavailable" -> logins >= 1 && signatures == 0 && tokenStages == 3
                    "owned-auth-registered-operator" -> logins == 1 && signatures == 8 && tokenStages == 3
                    "owned-auth-registered-harness" -> logins == 1 && signatures == 8 && tokenStages == 3
                    "owned-auth-registered-refresh" -> logins >= 2 && signatures == 8 && tokenStages == 3 * logins
                    "owned-auth-registered-initial-mismatch" -> logins == 0 && signatures == 0 && tokenStages == 0
                    "owned-auth-registered-unavailable" -> logins == 1 && signatures == 0 && tokenStages == 3
                    "owned-auth-registered-loss-during-sign" -> logins == 1 && signatures == 1 && tokenStages == 3
                    _ -> False
          unless valid (fail "authentication cache/refusal/refresh evidence changed")
          registryEvents <- doesFileExist (directory </> "registry-observations")
          registryReads <-
            if registryEvents
              then length . lines <$> readFile (directory </> "registry-observations")
              else pure 0
          when (registeredAuthenticationMode mode && not (totalAuthenticationMode mode)) $ do
            let expectedReads = case mode of
                  "owned-auth-registered-initial-mismatch" -> 0
                  "owned-auth-registered-unavailable" -> 1
                  "owned-auth-registered-loss-during-sign" -> 3
                  _ -> 17
            unless
              (registryReads == expectedReads)
              (fail "registered signer skipped its live registry barriers")
          bootstrapReads <- countFileLines (directory </> "bootstrap-observations")
          when (totalAuthenticationMode mode) $ do
            let expectedBootstraps = case mode of
                  "owned-total-registered-pin-mismatch" -> 1
                  "owned-total-registered-hint-unavailable" -> 1
                  "owned-total-registered-registry-unavailable" -> 1
                  "owned-total-registered-loss-during-sign" -> 2
                  _
                    | registeredAuthenticationMode mode -> 18
                    | otherwise -> 0
                expectedForwards = if mode == "owned-total-expired" then 0 else 1
            unless (bootstrapReads == expectedBootstraps) (fail "private bootstrap count changed")
            unless
              (count "kubectl port-forward" == expectedForwards)
              (fail "total caller opened another forward")
          Lazy.writeFile
            (directory </> "authentication.json")
            ( encode
                ( object
                    [ "logins" .= logins
                    , "signatures" .= signatures
                    , "token_stages" .= tokenStages
                    , "registry_reads" .= registryReads
                    , "bootstrap_reads" .= bootstrapReads
                    , "forwards" .= count "kubectl port-forward"
                    , "vault_paths" .= observed
                    ]
                )
            )
  result `seq` writeFile (directory </> "result") "PASS"

authenticatePreparedFixture
  :: FilePath
  -> String
  -> Identity.HostExecutionWindow
  -> FilePath
  -> RpcBirthOperationPreparation
  -> Maybe (VaultAddress, IORef [String])
  -> Maybe (RpcKeyRegistryObserver IO)
  -> IORef (Maybe RpcBirthOperationAuthentication)
  -> IO (Either RpcBirthHostError RpcBirthCoordinationResult)
authenticatePreparedFixture directory mode window source prepared callerVault registryObserver retained = do
  if totalAuthenticationMode mode
    then authenticateTotalFixture directory mode window source prepared callerVault
    else authenticateSeparate
 where
  authenticateSeparate = do
    when (mode == "owned-auth-expired") (waitForOriginalWorkEnd window)
    let observedRegistry = RpcKeyRegistryObserver $ do
          appendFile (directory </> "registry-observations") "read\n"
          paths <- maybe (pure []) (readIORef . snd) callerVault
          if mode == "owned-auth-registered-unavailable"
            || (mode == "owned-auth-registered-loss-during-sign" && any (isPrefixOf "/v1/transit/sign/") paths)
            then pure (Left RpcKeyBindingMissing)
            else case registryObserver of
              Just observer -> observeRpcKeyRegistry observer
              Nothing -> fail "registered authentication omitted its retained observer"
        selection
          | mode == "owned-auth-mode-mismatch" =
              RpcBirthRegisteredCallerSigning
                rpcBirthHomeRegistryFixture
                (RpcKeyRegistryObserver (pure (Right rpcBirthHomeRegistryFixture)))
          | registeredAuthenticationMode mode && mode /= "owned-auth-registered-initial-mismatch" =
              RpcBirthRegisteredCallerSigning rpcBirthHomeRegistryFixture observedRegistry
          | otherwise = RpcBirthInitialCallerSigning
        resolve = resolvePreparedRpcBirthCallerAuthentication (fixtureCaller mode) selection prepared
    when (mode == "owned-auth-cancel") $ case callerVault of
      Nothing -> fail "cancel fixture has no Vault observer"
      Just (_, paths) -> Async.withAsync resolve $ \pending -> do
        waitUntil
          (Identity.hostExecutionWorkEnd window)
          (elem "/v1/auth/kubernetes/login" <$> readIORef paths)
        Async.cancelWith pending ThreadKilled
        cancelled <- Async.waitCatch pending
        case cancelled of
          Left cause | fromException cause == Just ThreadKilled -> pure ()
          _ -> fail "authentication converted or swallowed asynchronous cancellation"
        writeFile (directory </> "authentication-cancellation") "thread-killed-propagated"
    resolved <- resolve
    case resolved of
      Left cause -> do
        when (mode == "owned-auth-expired") $ do
          unless
            (cause == RpcBirthHostPreparationRefused RpcBirthRolloutDeadlineReached)
            (fail "authentication changed its original-expiry refusal")
          writeFile (directory </> "authentication-disposition") "expired-refused"
        pure (Left cause)
      Right authentication -> do
        writeIORef retained (Just authentication)
        when (mode `elem` ["owned-auth-refresh", "owned-auth-registered-refresh"]) (threadDelay 1000000)
        coordinateAuthenticatedRpcBirthOnOperation source authentication

authenticateTotalFixture
  :: FilePath
  -> String
  -> Identity.HostExecutionWindow
  -> FilePath
  -> RpcBirthOperationPreparation
  -> Maybe (VaultAddress, IORef [String])
  -> IO (Either RpcBirthHostError RpcBirthCoordinationResult)
authenticateTotalFixture directory mode window source prepared callerVault = do
  when (mode == "owned-total-expired") (waitForOriginalWorkEnd window)
  let run = coordinatePreparedRpcBirthCallerOnOperation (fixtureCaller mode) source prepared
  if mode == "owned-total-cancel"
    then case callerVault of
      Nothing -> fail "total cancellation omitted its Vault observer"
      Just (_, paths) -> Async.withAsync run $ \pending -> do
        waitUntil
          (Identity.hostExecutionWorkEnd window)
          (elem "/v1/auth/kubernetes/login" <$> readIORef paths)
        Async.cancelWith pending ThreadKilled
        cancelled <- Async.waitCatch pending
        case cancelled of
          Left cause
            | fromException cause == Just ThreadKilled ->
                writeFile (directory </> "authentication-cancellation") "thread-killed-propagated"
          _ -> fail "total owner swallowed asynchronous cancellation"
        pure (Left (RpcBirthHostPreparationRefused RpcBirthRolloutIoRefused))
    else do
      result <- run
      when (mode == "owned-total-expired") $ do
        case result of
          Left (RpcBirthHostPreparationRefused RpcBirthRolloutDeadlineReached) -> pure ()
          _ -> fail "total owner changed its original deadline refusal"
        writeFile (directory </> "authentication-disposition") "expired-refused"
      pure result

totalBootstrapWire
  :: FilePath
  -> String
  -> Maybe (VaultAddress, IORef [String])
  -> Maybe (RpcKeyRegistryObserver IO)
  -> Client.ControlPlaneTransport
  -> Client.ControlPlaneTransport
totalBootstrapWire directory mode callerVault observer inner method headers url bytes
  | not (isRpcOwnBindingQuery bytes) = do
      response <- inner method headers url bytes
      pure $
        if mode == "owned-total-registered-registry-unavailable" && "/migration/apply" `isSuffixOf` url
          then fmap (\(_, body) -> (503, body)) response
          else response
  | otherwise = do
      unless
        (totalAuthenticationMode mode && registeredAuthenticationMode mode)
        (fail "unexpected public discovery")
      unless (url == "http://home.test/v1/migration/apply") (fail "discovery changed its compiled route")
      appendFile (directory </> "bootstrap-observations") "hint\n"
      count <- countFileLines (directory </> "bootstrap-observations")
      when (mode == "owned-total-registered-refresh" && count == 1) (threadDelay 1100000)
      paths <- maybe (pure []) (readIORef . snd) callerVault
      if mode == "owned-total-registered-hint-unavailable"
        || (mode == "owned-total-registered-loss-during-sign" && any (isPrefixOf "/v1/transit/sign/") paths)
        then pure (Right (503, "fixture-discovery-unavailable"))
        else do
          registry <-
            maybe (fail "bootstrap omitted retained registry") (observeRpcKeyRegistry >=> right) observer
          scope <- right (mkAuthorityScope "home")
          query <- right (decodeRpcOwnBindingQuery scope bytes)
          hint <- right (selectRpcOwnBindingHint query registry)
          pure (Right (200, encodeRpcOwnBindingHint hint))

mismatchingPin :: RpcBirthConfig -> RpcBirthConfig
mismatchingPin config = case config of
  RpcBirthConfigLegacy -> error "pin mismatch requires registered configuration"
  RpcBirthConfigRegistered pin -> RpcBirthConfigRegistered pin {descriptor_digest = Text.replicate 64 "b"}

expectedFrameCount :: String -> Int
expectedFrameCount mode
  | totalAuthenticationMode mode && registeredAuthenticationMode mode = 44
  | registeredAuthenticationMode mode = 8
  | otherwise = 12

totalAuthenticationCounts :: String -> Int -> Int -> Int -> Bool
totalAuthenticationCounts mode logins signatures tokenStages = case mode of
  "owned-total-operator" -> ordinary 12
  "owned-total-harness" -> ordinary 12
  "owned-total-registered-operator" -> ordinary 44
  "owned-total-registered-harness" -> ordinary 44
  "owned-total-registered-refresh" -> logins >= 2 && signatures == 44 && tokenStages == 3 * logins
  "owned-total-registered-pin-mismatch" -> ordinary 2
  "owned-total-registered-hint-unavailable" -> ordinary 0
  "owned-total-registered-registry-unavailable" -> ordinary 2
  "owned-total-registered-loss-during-sign" -> ordinary 2
  "owned-total-response-overflow" -> ordinary 2
  "owned-total-login-denied" -> ordinary 0
  "owned-total-unavailable" -> logins >= 1 && signatures == 0 && tokenStages == 3
  "owned-total-cancel" -> ordinary 0
  "owned-total-expired" -> logins == 0 && signatures == 0 && tokenStages == 0
  _ -> False
 where
  ordinary expected = logins == 1 && signatures == expected && tokenStages == 3

expectedTotalAuthenticationRefusal :: String -> RpcBirthHostError -> Bool
expectedTotalAuthenticationRefusal mode cause = case (mode, cause) of
  ( "owned-total-registered-pin-mismatch"
    , RpcBirthHostPreparationRefused
        ( RpcBirthRolloutTransportRefused
            (LocalLifecycleAuthorityBootstrapRefused RpcBirthBootstrapPinMismatch)
          )
    ) -> True
  ( "owned-total-registered-hint-unavailable"
    , RpcBirthHostPreparationRefused
        ( RpcBirthRolloutTransportRefused
            (LocalLifecycleAuthorityBootstrapRefused (RpcBirthBootstrapHintHttpStatus 503))
          )
    ) -> True
  ( "owned-total-registered-registry-unavailable"
    , RpcBirthHostPreparationRefused
        ( RpcBirthRolloutTransportRefused
            (LocalLifecycleAuthorityBootstrapRefused (RpcBirthBootstrapRegistry (RpcBirthClientHttpStatus 503)))
          )
    ) -> True
  ( "owned-total-registered-loss-during-sign"
    , RpcBirthHostPreparationRefused
        ( RpcBirthRolloutCallerAuthenticationRefused
            (LifecycleAuthoritySigningCapabilityUnavailable "registered-rpc-signing/registry-unavailable")
          )
    ) -> True
  ("owned-total-login-denied", _) -> expectedAuthenticationRefusal "owned-auth-login-denied" cause
  ("owned-total-unavailable", _) -> expectedAuthenticationRefusal "owned-auth-unavailable" cause
  ("owned-total-expired", _) -> expectedAuthenticationRefusal "owned-auth-expired" cause
  ("owned-total-cancel", RpcBirthHostPreparationRefused RpcBirthRolloutIoRefused) -> True
  ( "owned-total-response-overflow"
    , RpcBirthHostCoordinationRefused
        ( RpcBirthCoordinationRequestFailed
            CoordinationObserveInitial
            ( RpcBirthClientTransport
                (AuthenticatedClientTransportFailed (Client.ControlPlaneResponseTooLarge 65537 65536))
              )
          )
    ) -> True
  _ -> False

countFileLines :: FilePath -> IO Int
countFileLines path = do
  exists <- doesFileExist path
  if exists then length . lines <$> readFile path else pure 0

waitForOriginalWorkEnd :: Identity.HostExecutionWindow -> IO ()
waitForOriginalWorkEnd window = do
  current <- getMonotonicTimeNSec
  let ending = Identity.hostExecutionWorkEnd window
  when (current < ending) (threadDelay (fromIntegral ((ending - current) `div` 1000 + 1000)))

authenticationMode :: String -> Bool
authenticationMode mode =
  totalAuthenticationMode mode
    || registeredAuthenticationMode mode
    || mode
      `elem` [ "owned-auth-operator"
             , "owned-auth-harness"
             , "owned-auth-refresh"
             , "owned-auth-mode-mismatch"
             , "owned-auth-expired"
             , "owned-auth-login-denied"
             , "owned-auth-unavailable"
             , "owned-auth-cancel"
             ]

registeredAuthenticationMode :: String -> Bool
registeredAuthenticationMode mode =
  isPrefixOf "owned-auth-registered-" mode || isPrefixOf "owned-total-registered-" mode

totalAuthenticationMode :: String -> Bool
totalAuthenticationMode = isPrefixOf "owned-total-"

fixtureCaller :: String -> ExternalLifecycleAuthorityCaller
fixtureCaller mode =
  if mode
    `elem` [ "owned-token-operator"
           , "owned-auth-operator"
           , "owned-auth-registered-operator"
           , "owned-total-operator"
           , "owned-total-registered-operator"
           ]
    then LifecycleAuthorityOperator
    else LifecycleAuthorityTestHarness

callerVaultFault :: String -> RpcBirthCallerVaultFault
callerVaultFault mode = case mode of
  "owned-auth-login-denied" -> CallerVaultForbidden
  "owned-auth-unavailable" -> CallerVaultUnavailable
  "owned-auth-refresh" -> CallerVaultShortLease
  "owned-auth-registered-refresh" -> CallerVaultShortLease
  "owned-auth-cancel" -> CallerVaultCancelOnce
  "owned-total-login-denied" -> CallerVaultForbidden
  "owned-total-unavailable" -> CallerVaultUnavailable
  "owned-total-registered-refresh" -> CallerVaultShortLease
  "owned-total-cancel" -> CallerVaultCancelOnce
  _ -> CallerVaultHealthy

expectedAuthenticationRefusal :: String -> RpcBirthHostError -> Bool
expectedAuthenticationRefusal mode cause = case (mode, cause) of
  ( "owned-auth-mode-mismatch"
    , RpcBirthHostPreparationRefused RpcBirthRolloutCallerSigningModeMismatch
    ) -> True
  ( "owned-auth-login-denied"
    , RpcBirthHostPreparationRefused (RpcBirthRolloutCallerSessionRefused (VaultSessionForbidden _))
    ) -> True
  ( "owned-auth-unavailable"
    , RpcBirthHostPreparationRefused (RpcBirthRolloutCallerSessionRefused (VaultSessionUnavailable _))
    ) -> True
  ("owned-auth-expired", RpcBirthHostPreparationRefused RpcBirthRolloutDeadlineReached) -> True
  ( "owned-auth-registered-initial-mismatch"
    , RpcBirthHostPreparationRefused RpcBirthRolloutCallerSigningModeMismatch
    ) -> True
  ( "owned-auth-registered-unavailable"
    , RpcBirthHostPreparationRefused
        ( RpcBirthRolloutCallerAuthenticationRefused
            (LifecycleAuthoritySigningCapabilityUnavailable "registered-rpc-signing/registry-unavailable")
          )
    ) -> True
  ( "owned-auth-registered-loss-during-sign"
    , RpcBirthHostCoordinationRefused
        ( RpcBirthCoordinationRequestFailed
            CoordinationObserveInitial
            ( RpcBirthClientPeer
                ( PeerContextClientTransportFailed
                    (AuthenticatedClientSigningFailed (RequestSigningCapabilityUnavailable _))
                  )
              )
          )
    ) -> True
  _ -> False

ownedPreparationMode :: String -> Bool
ownedPreparationMode = isPrefixOf "owned-"

successfulMode :: String -> Bool
successfulMode mode =
  mode
    `elem` [ "healthy"
           , "unicode"
           , "owned-healthy"
           , "owned-api-upper"
           , "owned-token-operator"
           , "owned-token-harness"
           , "owned-auth-operator"
           , "owned-auth-harness"
           , "owned-auth-refresh"
           , "owned-auth-cancel"
           , "owned-auth-registered-operator"
           , "owned-auth-registered-harness"
           , "owned-auth-registered-refresh"
           , "owned-total-operator"
           , "owned-total-harness"
           , "owned-total-registered-operator"
           , "owned-total-registered-harness"
           , "owned-total-registered-refresh"
           ]

callerTokenMode :: String -> Bool
callerTokenMode = isPrefixOf "owned-token-"

expectedCallerTokenRefusal :: String -> RpcBirthHostError -> Bool
expectedCallerTokenRefusal mode cause = case (mode, cause) of
  ( "owned-token-account-refused"
    , RpcBirthHostPreparationRefused
        ( RpcBirthRolloutCallerTokenRefused
            (ExternalCallerServiceAccountUnobservable (ServiceAccountObservationIdentityMismatch _))
          )
    ) -> True
  ( "owned-token-rbac-refused"
    , RpcBirthHostPreparationRefused
        (RpcBirthRolloutCallerTokenRefused ExternalCallerTokenEligibilityRefused)
    ) -> True
  ( "owned-token-malformed"
    , RpcBirthHostPreparationRefused (RpcBirthRolloutCallerTokenRefused ExternalCallerTokenMalformed)
    ) -> True
  ("owned-token-expired", RpcBirthHostPreparationRefused RpcBirthRolloutDeadlineReached) -> True
  _ -> False

deadlineRefusal :: RpcBirthHostError -> Bool
deadlineRefusal cause = case cause of
  RpcBirthHostPreparationRefused (RpcBirthRolloutTransportRefused local) -> case local of
    LocalLifecycleAuthorityOperationDeadline -> True
    LocalLifecycleAuthorityOperationFailed (S.OperationProcessRefused S.OwnedSubprocessDeadlineReached) -> True
    LocalLifecycleAuthorityOperationFailed (S.OperationScopeRefused Kernel.KernelScopeDeadlineReached) -> True
    _ -> False
  RpcBirthHostCoordinationRefused
    (RpcBirthCoordinationEffectFailed CoordinationReconcileRuntime detail) ->
      detail
        `elem` map
          (Text.pack . show)
          [ RpcBirthRolloutDeadlineReached
          , RpcBirthRolloutOperationRefused
              RolloutApplyChart
              (S.OperationProcessRefused S.OwnedSubprocessDeadlineReached)
          , RpcBirthRolloutOperationRefused
              RolloutApplyChart
              (S.OperationScopeRefused Kernel.KernelScopeDeadlineReached)
          ]
  _ -> False

ambientIdentityKeys :: [String]
ambientIdentityKeys =
  [ "KUBECONFIG"
  , "AWS_ACCESS_KEY_ID"
  , "AWS_SECRET_ACCESS_KEY"
  , "AWS_SESSION_TOKEN"
  , "AWS_PROFILE"
  , "AWS_DEFAULT_PROFILE"
  , "AWS_SHARED_CREDENTIALS_FILE"
  , "AWS_CONFIG_FILE"
  , "HELM_DRIVER"
  ]

observeToolEnvironment :: IO ()
observeToolEnvironment = do
  forM_ ambientIdentityKeys $ \name -> do
    value <- lookupEnv name
    unless (value == Nothing) (fail ("ambient tool identity retained: " ++ name))
  directory <- getEnv "RPC_BIRTH_FIXTURE_DIRECTORY"
  home <- getEnv "HOME"
  cache <- getEnv "XDG_CACHE_HOME"
  uid <- getEffectiveUserID
  let root = "/run/user/" ++ show uid ++ "/prodbox-rpc-birth-"
  unless
    (root `isPrefixOf` home && cache == home </> "cache")
    (fail "tool home/cache escaped managed runtime directory")
  createDirectoryIfMissing True cache
  writeFile (cache </> "fixture-cache") "synthetic-cache"
  writeFile (directory </> "tool-home-location") home

fakeDocker :: [String] -> IO ()
fakeDocker arguments = do
  observeToolEnvironment
  directory <- getEnv "RPC_BIRTH_FIXTURE_DIRECTORY"
  mode <- getEnv "RPC_BIRTH_FIXTURE_MODE"
  case arguments of
    ["image", "inspect", "--format", format, reference]
      | format == "{\"id\":{{json .Id}},\"digests\":{{json .RepoDigests}}}"
      , (ContainerImage.harborRuntimeImageRepository ++ ":prodbox-") `isPrefixOf` reference ->
          pure ()
    _ -> fail "unexpected runtime metadata read"
  appendFile (directory </> "events") "docker image-inspect\n"
  when (mode == "owned-image-failure") (exitWith (ExitFailure 1))
  let repository = ContainerImage.harborRuntimeImageRepository
      digest = "sha256:" ++ replicate 64 'b'
      references = case mode of
        "owned-image-foreign" -> ["foreign.test/runtime@" ++ digest]
        "owned-image-ambiguous" -> [repository ++ "@" ++ digest, repository ++ "@sha256:" ++ replicate 64 'c']
        _ -> [repository ++ "@" ++ digest]
  Lazy.putStr (encode (object ["id" .= ("sha256:" ++ replicate 64 'a'), "digests" .= references]))

fakeKubectl :: [String] -> IO ()
fakeKubectl args = do
  observeToolEnvironment
  directory <- getEnv "RPC_BIRTH_FIXTURE_DIRECTORY"
  mode <- getEnv "RPC_BIRTH_FIXTURE_MODE"
  moment <- getMonotonicTimeNSec
  appendFile (directory </> "timings") ("kubectl " ++ show moment ++ "\n")
  appendFile
    (directory </> "events")
    ("kubectl " ++ unwords (filter (`elem` ["config", "view", "get", "pvc", "pv"]) args) ++ "\n")
  if (callerTokenMode mode || authenticationMode mode)
    && any (`elem` args) ["serviceaccount", "can-i", "token"]
    then fakeCallerToken directory mode args
    else
      if "port-forward" `elem` args
        then forward args
        else
          if "config" `elem` args
            then do
              bytes <- BS.readFile (directory </> "home.json")
              removeFile (directory </> "home.json")
              unless (ownedPreparationMode mode) (removeDirectoryRecursive (directory </> "source" </> "charts"))
              BS.putStr bytes
            else
              if "endpoints" `elem` args
                then do
                  config <- case dropWhile (/= "--kubeconfig") args of
                    _ : path : _ -> pure path
                    _ -> fail "API metadata read omitted its held home credential"
                  checkToolKubeconfig config
                  appendFile (directory </> "events") "kubectl api-egress\n"
                  when (mode == "owned-api-failure") (exitWith (ExitFailure 1))
                  putStrLn $
                    "10.0.0.1|" ++ case mode of
                      "owned-api-zero" -> "0"
                      "owned-api-overflow" -> "18446744073709551617"
                      "owned-api-upper" -> "65535"
                      _ -> "6443"
                else
                  if "pvc" `elem` args
                    then BS.readFile (directory </> "claim.json") >>= BS.putStr
                    else
                      if "pv" `elem` args
                        then BS.readFile (directory </> "volume.json") >>= BS.putStr
                        else fail "unexpected kubectl action"

fakeCallerToken :: FilePath -> String -> [String] -> IO ()
fakeCallerToken directory mode args = do
  config <- case dropWhile (/= "--kubeconfig") args of
    _ : path : _ -> pure path
    _ -> fail "caller token omitted its held home credential"
  checkToolKubeconfig config
  let (namespace, account, duration) =
        case fixtureCaller mode of
          LifecycleAuthorityOperator -> ("bootstrap-broker", "prodbox-control-plane-operator", "600s")
          LifecycleAuthorityTestHarness -> ("gateway", "prodbox-control-plane-test-harness", "900s")
      subject = "--as=system:serviceaccount:" ++ namespace ++ ":" ++ account
      action = dropWhile (`notElem` ["get", "auth", "create"]) args
      accountArgs =
        [ "get"
        , "serviceaccount"
        , account
        , "--namespace"
        , namespace
        , "-o"
        , "jsonpath={.metadata.namespace}{'\\n'}{.metadata.name}{'\\n'}{.automountServiceAccountToken}{'\\n'}"
        ]
      eligibilityArgs =
        [ "auth"
        , "can-i"
        , "create"
        , "serviceaccounts/" ++ account
        , "--subresource=token"
        , "--namespace"
        , namespace
        , subject
        ]
      tokenArgs = ["create", "token", account, "--namespace", namespace, "--duration=" ++ duration, subject]
      note stage = appendFile (directory </> "events") ("caller-token " ++ stage ++ "\n")
  if action == accountArgs
    then do
      note "serviceaccount"
      putStr
        ( namespace
            ++ "\n"
            ++ (if mode == "owned-token-account-refused" then "foreign" else account)
            ++ "\nfalse\n"
        )
    else
      if action == eligibilityArgs
        then do
          note "eligibility"
          putStrLn (if mode == "owned-token-rbac-refused" then "no" else "yes")
        else
          if action == tokenArgs
            then do
              note "request"
              putStrLn (if mode == "owned-token-malformed" then "synthetic token" else "synthetic-token")
            else fail "caller-token arguments do not match the explicit identity"

fakeHelm :: [String] -> IO ()
fakeHelm args = do
  observeToolEnvironment
  directory <- getEnv "RPC_BIRTH_FIXTURE_DIRECTORY"
  moment <- getMonotonicTimeNSec
  appendFile (directory </> "timings") ("helm " ++ show moment ++ "\n")
  mode <- getEnv "RPC_BIRTH_FIXTURE_MODE"
  let option name = case dropWhile (/= name) args of _ : value : _ -> pure value; _ -> fail ("missing " ++ name)
  kubeconfig <- option "--kubeconfig"
  writeFile (directory </> "workspace-location") (takeDirectory kubeconfig)
  checkToolKubeconfig kubeconfig
  case args of
    "status" : _ -> do
      appendFile (directory </> "events") "helm status\n"
      let status = case mode of "pending" -> "pending-upgrade"; "failed" -> "failed"; _ -> "deployed"
      if mode == "unobservable"
        then exitWith (ExitFailure 1)
        else Lazy.putStr (encode (object ["info" .= object ["status" .= (status :: String)]]))
    "upgrade" : "--install" : "lifecycle-authority" : chart : _ -> do
      appendFile (directory </> "events") "helm upgrade\n"
      writeFile (directory </> "applying") chart
      when (mode `elem` ["parent-death", "deadline"]) (threadDelay 70000000)
      values <- option "--values"
      copyFile values (directory </> "applied-values.json")
      case mode of "apply-failure" -> exitWith (ExitFailure 1); _ -> pure ()
    _ -> fail "unexpected Helm mutation"

homeConfig :: Value
homeConfig =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("Config" :: String)
    , "current-context" .= ("home" :: String)
    , "clusters"
        .= [ object
               [ "name" .= ("home" :: String)
               , "cluster"
                   .= object
                     [ "server" .= ("https://127.0.0.1:6443" :: String)
                     , "certificate-authority-data" .= ("synthetic-ca" :: String)
                     ]
               ]
           ]
    , "contexts"
        .= [ object
               [ "name" .= ("home" :: String)
               , "context" .= object ["cluster" .= ("home" :: String), "user" .= ("home" :: String)]
               ]
           ]
    , "users"
        .= [ object
               [ "name" .= ("home" :: String)
               , "user"
                   .= object
                     [ "client-certificate-data" .= ("synthetic-cert" :: String)
                     , "client-key-data" .= ("synthetic-key" :: String)
                     ]
               ]
           ]
    ]

claimFor :: ChartStorageBinding -> Value
claimFor binding =
  object
    [ "kind" .= ("PersistentVolumeClaim" :: String)
    , "metadata"
        .= object
          [ "name" .= chartStorageBindingPersistentVolumeClaimName binding
          , "namespace" .= ("lifecycle-authority" :: String)
          , "uid" .= ("claim-uid" :: String)
          ]
    , "spec"
        .= object
          [ "volumeName" .= chartStorageBindingPersistentVolumeName binding
          , "storageClassName" .= chartStorageClassName
          , "accessModes" .= [renderChartStorageAccessMode (chartStorageBindingAccessMode binding)]
          , "resources" .= object ["requests" .= object ["storage" .= chartStorageBindingStorageSize binding]]
          ]
    , "status" .= object ["phase" .= ("Bound" :: String)]
    ]

volumeFor :: ChartStorageBinding -> Value
volumeFor binding =
  object
    [ "kind" .= ("PersistentVolume" :: String)
    , "metadata" .= object ["name" .= chartStorageBindingPersistentVolumeName binding]
    , "spec"
        .= object
          [ "persistentVolumeReclaimPolicy" .= ("Retain" :: String)
          , "storageClassName" .= chartStorageClassName
          , "accessModes" .= [renderChartStorageAccessMode (chartStorageBindingAccessMode binding)]
          , "capacity" .= object ["storage" .= chartStorageBindingStorageSize binding]
          , "hostPath" .= object ["path" .= chartStorageBindingHostPath binding]
          , "claimRef"
              .= object
                [ "namespace" .= ("lifecycle-authority" :: String)
                , "name" .= chartStorageBindingPersistentVolumeClaimName binding
                , "uid" .= ("claim-uid" :: String)
                ]
          ]
    , "status" .= object ["phase" .= ("Bound" :: String)]
    ]

-- A fixture Authority listener; all mutation replies still pass through the
-- real signed-frame verifier and retained birth state machine.
withAuthorityListener :: String -> Client.ControlPlaneTransport -> (Int -> IO value) -> IO value
withAuthorityListener mode wire action = Net.withSocketsDo $ bracket open Net.close $ \listener -> do
  address <- Net.getSocketName listener
  port <- case address of
    Net.SockAddrInet value _ -> pure (fromIntegral value)
    _ -> fail "fixture Authority listener is not IPv4"
  Async.withAsync (forever (serve listener)) $ \workerThread -> do
    Async.link workerThread
    action port
 where
  open = do
    listener <- Net.socket Net.AF_INET Net.Stream Net.defaultProtocol
    Net.setSocketOption listener Net.ReuseAddr 1
    Net.bind listener (Net.SockAddrInet 0 (Net.tupleToHostAddress (127, 0, 0, 1)))
    Net.listen listener 8
    pure listener
  serve listener = bracket (Net.accept listener) (Net.close . fst) $ \(connection, _) -> do
    raw <- receive connection BS.empty
    request <-
      maybe (fail "invalid Authority fixture framing") pure (Server.parseControlPlaneRequest raw)
    case Server.parsedRequestPath request of
      "/readyz" -> do
        let (status, body) = case mode of
              "readiness-oversized" -> (ReplyOk, BS.replicate 4097 120)
              "readiness-unavailable" -> (ReplyServiceUnavailable, "not ready")
              _ -> (ReplyOk, "ready")
        NetBytes.sendAll connection (Server.renderHttpResponse status body)
      path | path `elem` ["/v1/authority/peer/observe", "/v1/migration/apply"] -> do
        response <- wire "POST" [] ("http://home.test" ++ path) (Server.parsedRequestBody request) >>= right
        let (code, actualBody) = response
            body =
              if mode `elem` ["response-overflow", "owned-total-response-overflow"] && path == "/v1/migration/apply"
                then BS.replicate 65537 120
                else actualBody
        status <- maybe (fail "fixture status") pure (replyStatusFromCode code)
        NetBytes.sendAll connection (Server.renderHttpResponse status body)
      _ -> fail "fixture Authority received an unregistered route"
  receive connection accumulated
    | BS.length accumulated > 70000 = fail "Authority fixture request bound exceeded"
    | otherwise = case Server.inspectControlPlaneRequestFraming accumulated of
        Left cause -> fail (show cause)
        Right (Server.ControlPlaneFramingComplete raw) -> pure raw
        Right Server.ControlPlaneFramingIncomplete -> do
          chunk <- NetBytes.recv connection 4096
          if BS.null chunk then fail "Authority fixture EOF" else receive connection (accumulated <> chunk)

-- The actual owned child forwards bounded chunks over TCP. This fixture does
-- not claim to execute Kubernetes' SPDY/WebSocket port-forward protocol.
forward :: [String] -> IO ()
forward arguments = do
  directory <- getEnv "RPC_BIRTH_FIXTURE_DIRECTORY"
  mode <- getEnv "RPC_BIRTH_FIXTURE_MODE"
  let option name = case dropWhile (/= name) arguments of
        _ : value : _ -> pure value
        _ -> fail ("missing forward option " ++ name)
  address <- option "--address"
  namespace <- option "--namespace"
  configPath <- option "--kubeconfig"
  checkToolKubeconfig configPath
  unless
    (address == "127.0.0.1" && namespace == "lifecycle-authority")
    (fail "forward mapping changed")
  local <- case dropWhile (/= "port-forward") arguments of
    _ : "service/lifecycle-authority" : mapping : _ -> case break (== ':') mapping of
      (number, ':' : remote)
        | remote == show lifecycleAuthorityRemotePort ->
            maybe (fail "local port") pure (readMaybe number)
      _ -> fail "remote port changed"
    _ -> fail "forward service changed"
  remoteText <- getEnv "RPC_BIRTH_FIXTURE_REMOTE_PORT"
  remote <- maybe (fail "remote fixture port") pure (readMaybe remoteText)
  appendFile (directory </> "events") "kubectl port-forward\n"
  writeFile (directory </> "forward-config") configPath
  when (mode == "transport-exit") (exitWith (ExitFailure 7))
  Net.withSocketsDo $ bracket (Net.socket Net.AF_INET Net.Stream Net.defaultProtocol) Net.close $ \listener -> do
    Net.setSocketOption listener Net.ReuseAddr 1
    Net.bind listener (Net.SockAddrInet local (Net.tupleToHostAddress (127, 0, 0, 1)))
    Net.listen listener 8
    putStrLn ("Forwarding from 127.0.0.1:" <> show local <> " -> " <> show lifecycleAuthorityRemotePort)
    hFlush stdout
    forever $ bracket (Net.accept listener) (Net.close . fst) $ \(client, _) ->
      bracket (Net.socket Net.AF_INET Net.Stream Net.defaultProtocol) Net.close $ \server -> do
        Net.connect server (Net.SockAddrInet remote (Net.tupleToHostAddress (127, 0, 0, 1)))
        Async.race_ (pump client server) (pump server client)
 where
  pump from to = do
    chunk <- NetBytes.recv from 4096
    unless (BS.null chunk) (NetBytes.sendAll to chunk >> pump from to)

checkToolKubeconfig :: FilePath -> IO ()
checkToolKubeconfig path = do
  actual <- right . validateRpcBirthHomeKubeconfig =<< BS.readFile path
  expected <- right (validateRpcBirthHomeKubeconfig (Lazy.toStrict (encode homeConfig)))
  unless
    (actual == expected)
    (fail "tool changed the held home projection")
  modeBits <- fileMode <$> getSymbolicLinkStatus path
  unless (modeBits `mod` 512 == 0o600) (fail "private kubeconfig permissions")
