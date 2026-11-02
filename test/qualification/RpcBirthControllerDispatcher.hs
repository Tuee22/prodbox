{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- The real App/Native dispatcher runs inside its published native family.
-- Vault/Kubernetes/provider replies and command executables are authored
-- boundaries; this probe is neither an installed-operator nor deployment proof.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception (IOException, bracket, try)
import Control.Monad (forM_, forever, unless, (>=>))
import ControlPlaneRpcAdmissionBirth
  ( RpcBirthCallerVaultFault (CallerVaultHealthy)
  , withRpcBirthCallerVaultFixture
  , withRpcBirthCoordinatorWireFixture
  , withRpcBirthPreparedCoordinatorWireFixtureForKey
  )
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isSuffixOf)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Word (Word64)
import Dhall qualified
import GHC.Clock (getMonotonicTimeNSec)
import Network.Socket qualified as Net
import Network.Socket.ByteString qualified as NetBytes
import Numeric (showHex)
import Prodbox.App qualified as App
import Prodbox.Capacity.Config qualified as C
import Prodbox.Capacity.HostExecution qualified as H
import Prodbox.Config.Tier0 qualified as Tier0
import Prodbox.ControlPlane.Client qualified as Client
import Prodbox.ControlPlane.Coordinate (mkAuthorityScope)
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityTestHarness)
  )
import Prodbox.ControlPlane.RegisteredRpcSigning (RpcKeyRegistryObserver (..))
import Prodbox.ControlPlane.RpcAdmissionBirth
import Prodbox.ControlPlane.RpcAdmissionBirthConfig
import Prodbox.ControlPlane.RpcAdmissionBirthControllerInputs
import Prodbox.ControlPlane.RpcAdmissionBirthCoordinator
import Prodbox.ControlPlane.RpcAdmissionBirthNative (rpcBirthSystemTime)
import Prodbox.ControlPlane.RpcAdmissionBirthPublication (tier0RpcBirthPublicationAtPath)
import Prodbox.ControlPlane.RpcAdmissionBirthRequest
import Prodbox.ControlPlane.RpcOwnBindingHint
import Prodbox.ControlPlane.Runtime qualified as Runtime
import Prodbox.ControlPlane.Server qualified as Server
import Prodbox.Http.ReplyStatus (ReplyStatus (..), replyStatusFromCode)
import Prodbox.Lib.ChartPlatform
import Prodbox.Lib.Storage
import Prodbox.Lifecycle.Lease
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import Prodbox.Settings qualified as S
import Prodbox.Subprocess qualified as P
import Prodbox.Substrate (Substrate (SubstrateHomeLocal))
import Prodbox.Vault.Client (VaultAddress (..))
import System.Directory
import System.Environment
import System.Exit (ExitCode (..), exitWith)
import System.FilePath
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (createLink, readSymbolicLink)
import System.Posix.IO qualified as Posix
import System.Posix.User (getEffectiveUserID)
import TestSupport (syntheticConfigFile, syntheticProjectConfig)
import Tier0Fixture (tier0Fixture, tier0FixturePath, writeTier0Fixture)

right :: (Show err) => Either err value -> IO value
right = either (fail . show) pure

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["launch", mode, path, tools] | mode `elem` ["initial", "registered"] -> do
      directory <- makeAbsolute path
      helper <- makeAbsolute tools
      launch mode directory helper
    "internal-rpc-birth-controller" : _ -> delegate
    _ -> fail "closed dispatcher fixture invocation refused"

-- Authored boundaries enter before App.main. Its real argv parser, pinned
-- loader and native/process/session/coordination interpreters stay unchanged.
delegate :: IO ()
delegate = do
  binaryDirectory <- takeDirectory <$> getExecutablePath
  directory <- readFile (binaryDirectory </> "dispatcher-case")
  port <- readFile (directory </> "remote-port")
  runtime <- getEnv "RUNTIME_DIRECTORY"
  present <- doesDirectoryExist runtime
  unless present (fail "managed runtime directory was not created")
  writeFile (directory </> "managed-runtime") runtime
  inherited <- getEnv "PATH"
  setEnv "PATH" (directory </> "tools" ++ ":" ++ inherited)
  setEnv "HOME" (directory </> "fixture-home")
  setEnv "RPC_BIRTH_FIXTURE_DIRECTORY" directory
  setEnv "RPC_BIRTH_FIXTURE_MODE" "owned-total-harness"
  setEnv "RPC_BIRTH_FIXTURE_REMOTE_PORT" port
  setCurrentDirectory (directory </> "outside")
  outcome <- try App.main :: IO (Either ExitCode ())
  writeFile (directory </> "dispatcher-outcome") (show outcome)
  either exitWith pure outcome

settingsFor
  :: FilePath -> FilePath -> VaultAddress -> RpcBirthConfig -> IO (S.ValidatedSettings, S.ConfigFile)
settingsFor root directory (VaultAddress address) registration = do
  let context = Tier0.context syntheticProjectConfig
      input = S.DeploymentContextInput "home" address (Tier0.minio_endpoint context) registration
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
  pure (settings, config)

launch :: String -> FilePath -> FilePath -> IO ()
launch mode directory fakeTools = do
  root <- getCurrentDirectory
  binaryDirectory <- takeDirectory <$> getExecutablePath
  forM_ ["tools", "outside", "fixture-home/.kube"] $ \name -> createDirectoryIfMissing True (directory </> name)
  forM_ ["helm", "kubectl", "docker"] $ \name -> createLink fakeTools (directory </> "tools" </> name)
  writeFile (binaryDirectory </> "dispatcher-case") directory
  Lazy.writeFile (directory </> "home.json") (encode homeConfig)
  Lazy.writeFile (directory </> "fixture-home/.kube/config") (encode homeConfig)
  scope <- right (mkAuthorityScope "home")
  now <- rpcBirthSystemTime
  operationNonce <- getMonotonicTimeNSec
  let deadline = authorityTimeFromMicros (authorityTimeMicros now + 60000000)
      operationKey = Text.justifyRight 32 '0' (Text.pack (showHex operationNonce ""))
  serving <- newIORef Nothing
  let observeServing = do
        present <- doesFileExist (directory </> "applied-values.json")
        if not present
          then pure Nothing
          else do
            cached <- readIORef serving
            case cached of
              Just value -> pure (Just value)
              Nothing -> do
                value <- right . eitherDecodeStrict' =<< BS.readFile (directory </> "applied-values.json")
                text <- case value of
                  Object fields
                    | Just (Object cfg) <- KM.lookup "config" fields
                    , Just (String role) <- KM.lookup "roleDhall" cfg ->
                        pure role
                  _ -> fail "applied role missing"
                config <- Dhall.input Dhall.auto text
                selected <-
                  right
                    ( validateRpcBirthConfig
                        LifecycleAuthorityRuntime
                        scope
                        (Runtime.rpc_registration (config :: Runtime.ControlPlaneConfig))
                    )
                writeIORef serving (Just selected)
                pure (Just selected)
      withWire action =
        if mode == "registered"
          then withRpcBirthPreparedCoordinatorWireFixtureForKey operationKey deadline observeServing $ \registration observer _ _ wire probe -> action registration (Just observer) wire probe
          else withRpcBirthCoordinatorWireFixture deadline observeServing $ \_ _ wire probe -> action RpcBirthConfigLegacy Nothing wire probe
  withRpcBirthCallerVaultFixture LifecycleAuthorityTestHarness CallerVaultHealthy $ \address paths ->
    withWire $ \registration observer inner probe -> do
      (settings, config) <- settingsFor root directory address registration
      let context =
            (Tier0.context syntheticProjectConfig)
              { Tier0.cluster_id = "home"
              , Tier0.vault_address = case address of VaultAddress value -> value
              }
          project =
            syntheticProjectConfig
              { Tier0.parameters = Tier0.configFileToTier0Parameters config
              , Tier0.context = context
              }
          source = tier0FixturePath binaryDirectory
      writeTier0Fixture binaryDirectory (tier0Fixture project)
      case registration of
        RpcBirthConfigLegacy -> pure ()
        RpcBirthConfigRegistered _ -> do
          let publication = tier0RpcBirthPublicationAtPath scope source (\_ _ -> fail "fixture setup cannot deploy")
          right =<< coordinationPublishSource publication deadline RpcBirthConfigLegacy registration
      let image =
            ResolvedCustomImage
              "registry.test/prodbox/runtime"
              "held-native"
              (Just ("sha256:" ++ replicate 64 'a'))
              (Just ("sha256:" ++ replicate 64 'b'))
          observers =
            ChartPlanObservers
              (const (pure (Right (Just image))))
              (pure (Right (KubernetesApiEgressCoordinate ["10.0.0.1"] 6443)))
      planned <-
        right
          =<< buildChartDeploymentPlanForSubstrateWithObservers
            observers
            SubstrateHomeLocal
            root
            settings
            "lifecycle-authority"
            Map.empty
            Map.empty
      binding <- case concatMap chartReleasePlanStorageBindings (chartDeploymentPlanReleases planned) of
        [value] -> pure value
        _ -> fail "journal binding missing"
      Lazy.writeFile (directory </> "claim.json") (encode (claimFor binding))
      Lazy.writeFile (directory </> "volume.json") (encode (volumeFor binding))
      let wire method headers url bytes
            | isRpcOwnBindingQuery bytes = do
                current <- maybe (fail "initial mode cannot discover") (observeRpcKeyRegistry >=> right) observer
                query <- right (decodeRpcOwnBindingQuery scope bytes)
                hint <- right (selectRpcOwnBindingHint query current)
                pure (Right (200, encodeRpcOwnBindingHint hint))
            | otherwise = inner method headers url bytes
      withAuthorityListener "healthy" wire $ \port -> do
        writeFile (directory </> "remote-port") (show port)
        request <- right (mkRpcBirthCoordinationRequest scope deadline 1 operationKey)
        started <- getMonotonicTimeNSec
        let outer = started + 50000000000
            work = started + 40000000000
            hard = started + 42000000000
            stop = started + 45000000000
            finish = started + 47000000000
        window <- maybe (fail "original window") pure (P.hostExecutionWindow outer work hard stop finish)
        domain <- right =<< observeRpcBirthControllerManagerDomain work
        command <-
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
        prepared <- right =<< prepareRpcBirthControllerRequest command settings
        result <- withPublishedRpcBirthControllerLaunch prepared $ \submission -> do
          let units = rpcBirthControllerLaunchUnitNames submission
          Lazy.writeFile
            (directory </> "field.json")
            ( encode
                ( object
                    [ "units" .= units
                    , "outer_ns" .= outer
                    , "work_ns" .= work
                    , "hard_ns" .= hard
                    , "stop_ns" .= stop
                    , "finish_ns" .= finish
                    ]
                )
            )
          right =<< submitRpcBirthControllerLaunch submission
          observeClosing work finish command
          runtime <- readFile (directory </> "managed-runtime")
          retained <- doesDirectoryExist runtime
          unless (not retained) (fail "dispatcher workspace survived its family")
          outcome <- readFile (directory </> "dispatcher-outcome")
          unless (outcome == "Left ExitSuccess") (fail ("production dispatcher refused: " ++ outcome))
          (phase, frames) <- probe
          unless
            ( phase == BirthCommitted
                && all (== deadline) frames
                && length frames == if mode == "registered" then 44 else 12
            )
            (fail "production dispatcher changed commitment/frame bounds")
          events <- lines <$> readFile (directory </> "events")
          let forwards = length (filter (== "kubectl port-forward") events)
          unless (forwards == 1) (fail "dispatcher opened another forward")
          vaultPaths <- readIORef paths
          unless
            (length (filter (== "/v1/auth/kubernetes/login") vaultPaths) == 1)
            (fail "dispatcher replaced its cached session")
          cwdSchemas <-
            mapM
              (doesFileExist . ((directory </> "outside") </>))
              ["prodbox-config-types.dhall", "test-secrets-types.dhall"]
          unless (not (or cwdSchemas)) (fail "dispatcher materialized cwd schemas")
          Lazy.writeFile
            (directory </> "dispatcher.json")
            ( encode
                ( object
                    [ "phase" .= show phase
                    , "frames" .= length frames
                    , "forwards" .= forwards
                    , "original_bounds" .= True
                    , "outside_repo" .= True
                    , "cwd_schemas_absent" .= True
                    , "all_six_units_absent" .= True
                    ]
                )
            )
        right result

observeClosing :: Word64 -> Word64 -> RpcBirthControllerRequest -> IO ()
observeClosing work finish request = do
  uid <- getEffectiveUserID
  let group =
        "/sys/fs/cgroup/user.slice/user-"
          ++ show uid
          ++ ".slice/user@"
          ++ show uid
          ++ ".service/prodboxrpcbirth.slice"
      flags = Posix.defaultFileFlags {Posix.directory = True, Posix.nofollow = True, Posix.cloexec = True}
  waitUntil work (doesDirectoryExist group)
  bracket (Posix.openFd group Posix.ReadOnly flags) Posix.closeFd $ \held -> do
    waitUntil finish $ do
      observed <- right =<< observeRpcBirthControllerField finish request
      pure (rpcBirthControllerFieldState observed == ControllerFieldAbsent)
    waitUntil finish $ do
      target <- readSymbolicLink ("/proc/self/fd/" ++ show held)
      result <-
        try
          ( bracket
              ( Posix.openFdAt
                  (Just held)
                  "cgroup.events"
                  Posix.ReadOnly
                  Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True}
              )
              Posix.closeFd
              (const (pure ()))
          )
          :: IO (Either IOException ())
      pure (" (deleted)" `isSuffixOf` target && either isDoesNotExistError (const False) result)

waitUntil :: Word64 -> IO Bool -> IO ()
waitUntil ending observation = do
  now <- getMonotonicTimeNSec
  unless (now < ending) (fail "original dispatcher observation bound expired")
  ready <- observation
  unless ready (threadDelay 1000 >> waitUntil ending observation)

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
        (C.ChildProcessBudgetConfig (Just 2) (Just 60000) [mib 64, mib 16])
        (mib 8)
        (mib 8)
    )
    (mib 256)
    (H.HostExecutionDemand 300000 200000 100000 16 24 8 (mib 48) (mib 16) 1 0)
    (H.HostTransportDemand 100000 8 (mib 16))
    20000
    20000
    (RpcBirthControllerStreamInput 65536 65536 500000)
    (RpcBirthControllerStreamInput 65536 65536 500000)
 where
  mib value = value * 1048576

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
