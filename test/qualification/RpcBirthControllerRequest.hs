{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Control.Monad (forM_, unless)
import Data.Aeson (Value, eitherDecodeStrict', object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isLeft)
import Data.Text qualified as Text
import Data.Void (Void)
import Dhall.Binary qualified as Binary
import Dhall.Core qualified as Core
import Dhall.Map qualified as Map
import Dhall.Parser qualified as Parser
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Capacity.Config qualified as C
import Prodbox.Capacity.HostExecution qualified as H
import Prodbox.Capacity.NativeHostProbe qualified as Native
import Prodbox.Capacity.RuntimeMemory qualified as R
import Prodbox.Config.Tier0 qualified as Tier0
import Prodbox.ControlPlane.Coordinate (mkAuthorityScope)
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication (ExternalLifecycleAuthorityCaller (..))
import Prodbox.ControlPlane.RpcAdmissionBirthCoordinator
import Prodbox.ControlPlane.RpcAdmissionBirthNative (rpcBirthSystemTime)
import Prodbox.ControlPlane.RpcAdmissionBirthPayload
import Prodbox.ControlPlane.RpcAdmissionBirthRequest
import Prodbox.ControlPlane.RpcAdmissionBirthRollout (rpcBirthRolloutExecutionKey)
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros, authorityTimeMicros)
import Prodbox.Settings qualified as S
import Prodbox.Subprocess qualified as I
import System.Directory (getCurrentDirectory, makeAbsolute)
import System.Environment (getArgs, lookupEnv, unsetEnv)
import System.FilePath (makeRelative, (</>))
import System.Posix.Env qualified as PosixEnv
import TestSupport (syntheticConfigFile, syntheticProjectConfig)

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

assert :: String -> Bool -> IO ()
assert label ok = unless ok (fail label)

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

main :: IO ()
main = do
  [directory] <- getArgs
  retained <- makeAbsolute directory
  root <- getCurrentDirectory
  unsetEnv "PRODBOX_TEST_HOST_CAPACITY"
  let context = Tier0.context syntheticProjectConfig
      input =
        S.DeploymentContextInput
          (Tier0.cluster_id context)
          (Tier0.vault_address context)
          (Tier0.minio_endpoint context)
          (Tier0.rpc_registration context)
      baseCapacity = S.capacity syntheticConfigFile
      basePlan = C.resource_plan baseCapacity
      selected =
        filter ((`elem` C.guaranteedControlPlaneProfileIds) . C.profile_id) (C.workload_profiles basePlan)
      ids = map C.profile_id selected
      minimal =
        syntheticConfigFile
          { S.storage =
              (S.storage syntheticConfigFile) {S.manual_pv_host_root = Text.pack (makeRelative root retained)}
          , S.capacity =
              baseCapacity
                { C.resource_plan =
                    basePlan
                      { C.host_capacity = C.ResourceVector 6000 12000 60000 60000
                      , C.workload_profiles = selected
                      }
                , C.runtime_memory_profiles =
                    filter ((`elem` ids) . C.runtime_profile_id) (C.runtime_memory_profiles baseCapacity)
                }
          }
  settings <- right =<< S.validateConfigWithContext root input minimal
  full <-
    right
      =<< S.validateConfigWithContext
        root
        input
        syntheticConfigFile {S.storage = S.storage minimal}
  scope <- right (mkAuthorityScope (Tier0.cluster_id context))
  authorityNow <- rpcBirthSystemTime
  let deadline = authorityTimeFromMicros (authorityTimeMicros authorityNow + 60000000)
  coordination <-
    right (mkRpcBirthCoordinationRequest scope deadline 1 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
  started <- getMonotonicTimeNSec
  window <-
    maybe
      (fail "fixture window")
      pure
      ( I.hostExecutionWindow
          (started + 20000000000)
          (started + 15000000000)
          (started + 16000000000)
          (started + 17000000000)
          (started + 18000000000)
      )
  key <- right (rpcBirthRolloutExecutionKey coordination)
  domain <- right =<< observeRpcBirthControllerManagerDomain (started + 15000000000)
  referenceBytes <- BS.readFile (retained </> "domain-reference.json")
  reference <- right (eitherDecodeStrict' referenceBytes :: Either String Value)
  let observedDomain =
        object
          [ "kernel_boot_id" .= hostManagerBootId domain
          , "bus_instance_id" .= hostManagerBusId domain
          , "manager_unique_name" .= hostManagerUniqueName domain
          , "manager_uid" .= hostManagerUserId domain
          , "manager_pid" .= hostManagerProcessId domain
          , "manager_start_ticks" .= hostManagerStartTicks domain
          ]
  assert
    "native manager/clock domain differs from the independent reference"
    (reference == observedDomain)
  request <-
    right
      ( mkRpcBirthControllerRequest
          LifecycleAuthorityTestHarness
          domain
          root
          settings
          coordination
          window
          profile
      )
  encoded <- rpcBirthControllerRequestBytes <$> right (encodeRpcBirthControllerRequest request)
  decoded <- right (decodeRpcBirthControllerRequest key window encoded)
  assert "root changed" (rpcBirthControllerRequestRoot decoded == root)
  assert "window changed" (rpcBirthControllerRequestWindow decoded == window)
  assert "key changed" (rpcBirthControllerRequestKey decoded == key)
  assert "domain changed" (rpcBirthControllerRequestDomain decoded == domain)
  assert
    "explicit caller changed"
    (rpcBirthControllerRequestCaller decoded == LifecycleAuthorityTestHarness)
  forM_ [LifecycleAuthorityOperator, LifecycleAuthorityTestHarness] $ \caller -> do
    callerRequest <-
      right (mkRpcBirthControllerRequest caller domain root settings coordination window profile)
    wire <- rpcBirthControllerRequestBytes <$> right (encodeRpcBirthControllerRequest callerRequest)
    restored <- right (decodeRpcBirthControllerRequest key window wire)
    assert
      "caller round-trip selected a default identity"
      (rpcBirthControllerRequestCaller restored == caller)
  assert
    "generation changed"
    (rpcBirthCoordinationGeneration (rpcBirthControllerRequestCoordination decoded) == 1)
  assert
    "deadline changed"
    (rpcBirthCoordinationDeadline (rpcBirthControllerRequestCoordination decoded) == deadline)
  settingsBytes <- rpcBirthSettingsBytes <$> right (encodeRpcBirthControllerSettings settings)
  settingsAgain <-
    right
      =<< decodeRpcBirthControllerSettings scope (rpcBirthControllerRequestRoot decoded) settingsBytes
  -- Old recorded profiles remain data for exact observation/retirement.
  -- Only fresh effect preparation needs the added startup-protocol reserve.
  let historicalProfile =
        profile
          { controllerRuntimeProfile =
              (controllerRuntimeProfile profile) {C.other_heap_reserve_bytes = 4 * (4096 + 4096 + 2)}
          , controllerCommandStream = RpcBirthControllerStreamInput 4096 4096 500000
          , controllerTransportStream = RpcBirthControllerStreamInput 4096 4096 500000
          }
  historical <-
    right
      ( mkRpcBirthControllerRequest
          LifecycleAuthorityTestHarness
          domain
          root
          settings
          coordination
          window
          historicalProfile
      )
  historicalBytes <-
    rpcBirthControllerRequestBytes <$> right (encodeRpcBirthControllerRequest historical)
  historicalAgain <- right (decodeRpcBirthControllerRequest key window historicalBytes)
  assert
    "historical startup profile changed its exact key"
    (rpcBirthControllerRequestKey historicalAgain == key)
  refusedHistorical <- prepareRpcBirthControllerRequest historicalAgain settings
  assert
    "historical data minted current startup effects without funding"
    (case refusedHistorical of Left ControllerRequestProfileInvalid -> True; _ -> False)
  preparation <- right =<< prepareRpcBirthControllerRequest decoded settingsAgain
  let plan = rpcBirthControllerPreparedPlan preparation
  assert
    "plan family changed"
    ( rpcBirthControllerRequestKey (rpcBirthControllerPreparedRequest preparation) == key
        && rpcBirthControllerRequestWindow (rpcBirthControllerPreparedRequest preparation) == window
    )
  assert
    "resource declarations changed"
    ( H.hostExecutionSliceMemoryBytes plan == 256 * 1048576
        && H.hostExecutionParentMemoryBytes plan == 176 * 1048576
        && H.hostExecutionSliceCpuUsecPerSec plan == 700000
        && H.hostExecutionSliceTasks plan == 56
    )
  assert
    "prepared settings changed"
    (S.validatedConfig (rpcBirthControllerPreparedSettings preparation) == minimal)
  putStrLn
    ( "PASS request/settings roundtrip and fresh real host compilation: request bytes "
        ++ show (BS.length encoded)
    )
  expression <-
    right
      ( Binary.decodeExpression (Lazy.fromStrict encoded)
          :: Either Binary.DecodingFailure (Core.Expr Void Void)
      )
  let replacePath [] value _ = value
      replacePath (name : names) value term = case term of
        Core.RecordLit fields -> case Map.lookup name fields of
          Just field ->
            Core.RecordLit
              ( Map.insert
                  name
                  (Core.makeRecordField (replacePath names value (Core.recordFieldValue field)))
                  fields
              )
          Nothing -> error "missing fixture field"
        _ -> error "fixture field not a record"
      replace path value = Lazy.toStrict (Binary.encodeExpression (replacePath path value expression))
      refuse label bytes = assert ("accepted " ++ label) (isLeft (decodeRpcBirthControllerRequest key window bytes))
  forM_
    [ ("schema", ["schema_version"], Core.NaturalLit 3)
    , ("legacy-schema", ["schema_version"], Core.NaturalLit 1)
    , ("caller-overflow", ["caller_principal"], Core.NaturalLit (fromIntegral (maxBound :: Word) + 1))
    , ("domain-boot", ["host_domain", "kernel_boot_id"], Core.TextLit (Core.Chunks [] "invalid"))
    ,
      ( "domain-bus"
      , ["host_domain", "bus_instance_id"]
      , Core.TextLit (Core.Chunks [] (Text.replicate 32 "0"))
      )
    , ("domain-owner", ["host_domain", "manager_unique_name"], Core.TextLit (Core.Chunks [] ":1..2"))
    , ("domain-pid-zero", ["host_domain", "manager_pid"], Core.NaturalLit 0)
    , ("domain-pid-overflow", ["host_domain", "manager_pid"], Core.NaturalLit 2147483648)
    , ("domain-uid-overflow", ["host_domain", "manager_uid"], Core.NaturalLit 4294967296)
    , ("domain-start-zero", ["host_domain", "manager_start_ticks"], Core.NaturalLit 0)
    , ("domain-start-overflow", ["host_domain", "manager_start_ticks"], Core.NaturalLit (2 ^ (64 :: Int)))
    , ("program", ["program"], Core.NaturalLit 0)
    , ("foreign-scope", ["authority_scope"], Core.TextLit (Core.Chunks [] "foreign"))
    , ("generation-zero", ["registration_generation"], Core.NaturalLit 0)
    , ("generation-overflow", ["registration_generation"], Core.NaturalLit (2 ^ (64 :: Int)))
    , ("registration-key", ["registration_key"], Core.TextLit (Core.Chunks [] "bad"))
    , ("execution-key", ["execution_key"], Core.TextLit (Core.Chunks [] (Text.replicate 64 "b")))
    , ("deadline-zero", ["authority_deadline_micros"], Core.NaturalLit 0)
    , ("deadline-overflow", ["authority_deadline_micros"], Core.NaturalLit (2 ^ (64 :: Int)))
    ,
      ( "runtime-id"
      , ["host_profile", "runtime_memory", "runtime_profile_id"]
      , Core.TextLit (Core.Chunks [] "foreign")
      )
    , ("container-limit", ["host_profile", "container_limit_bytes"], Core.NaturalLit 1)
    ,
      ( "serial-child-schedule"
      , ["host_profile", "runtime_memory", "child_process_budget", "permit_capacity"]
      , Core.Some (Core.NaturalLit 1)
      )
    , ("helper-zero", ["host_profile", "helper_start_micros"], Core.NaturalLit 0)
    ,
      ( "stdout-overflow"
      , ["host_profile", "command_stream", "stdout_bytes"]
      , Core.NaturalLit (2 ^ (64 :: Int))
      )
    , ("stderr-zero", ["host_profile", "transport_stream", "stderr_bytes"], Core.NaturalLit 0)
    ,
      ( "reader-grace-overflow"
      , ["host_profile", "command_stream", "reader_grace_micros"]
      , Core.NaturalLit (2 ^ (64 :: Int))
      )
    ,
      ( "reader-grace-window"
      , ["host_profile", "command_stream", "reader_grace_micros"]
      , Core.NaturalLit 2000000
      )
    ,
      ( "stream-heap-overflow"
      , ["host_profile", "command_stream", "stdout_bytes"]
      , Core.NaturalLit 1048576
      )
    ]
    $ \(label, path, value) -> refuse label (replace path value)
  forM_ ([0 .. 7] ++ [102, 103, 104]) $ \code ->
    refuse "non-external caller" (replace ["caller_principal"] (Core.NaturalLit code))
  forM_ ["relative", root ++ "/.", root ++ "/..", root ++ "\NULsuffix", replicate 4097 'x'] $ \bad ->
    refuse "root" (replace ["repository_root"] (Core.TextLit (Core.Chunks [] (Text.pack bad))))
  forM_ ["outer_ns", "work_ns", "hard_ns", "stop_ns", "finish_ns"] $ \name -> do
    refuse "zero clock" (replace ["original_window", name] (Core.NaturalLit 0))
    refuse "overflowing clock" (replace ["original_window", name] (Core.NaturalLit (2 ^ (64 :: Int))))
  otherWindow <-
    maybe
      (fail "other window")
      pure
      ( I.hostExecutionWindow
          (started + 20000000001)
          (started + 15000000001)
          (started + 16000000001)
          (started + 17000000001)
          (started + 18000000001)
      )
  assert
    "accepted different launch window"
    (isLeft (decodeRpcBirthControllerRequest key otherWindow encoded))
  otherKey <- maybe (fail "other key") pure (I.hostExecutionKeyFromText (replicate 64 'c'))
  assert
    "accepted different launch key"
    (isLeft (decodeRpcBirthControllerRequest otherKey window encoded))
  case expression of
    Core.RecordLit fields ->
      refuse
        "extra top field"
        ( Lazy.toStrict
            ( Binary.encodeExpression
                (Core.RecordLit (Map.insert "unexpected" (Core.makeRecordField (Core.BoolLit True)) fields))
            )
        )
    _ -> fail "fixture top record"
  let atPath [] term = term
      atPath (name : names) term = case term of
        Core.RecordLit fields -> case Map.lookup name fields of
          Just field -> atPath names (Core.recordFieldValue field)
          Nothing -> error "missing nested fixture field"
        _ -> error "nested fixture field not a record"
      refuseNested path = case atPath path expression of
        Core.RecordLit fields ->
          refuse
            "extra nested field"
            ( replace
                path
                (Core.RecordLit (Map.insert "unexpected" (Core.makeRecordField (Core.BoolLit True)) fields))
            )
        _ -> fail "fixture nested record"
  forM_
    [ ["host_domain"]
    , ["host_profile"]
    , ["host_profile", "runtime_memory"]
    , ["host_profile", "host_demand"]
    , ["host_profile", "command_stream"]
    , ["original_window"]
    , ["deployment_context"]
    ]
    refuseNested
  let changedDomainText name = case atPath ["host_domain", name] expression of
        Core.TextLit (Core.Chunks [] value) ->
          Core.TextLit
            (Core.Chunks [] (Text.dropEnd 1 value <> if Text.isSuffixOf "a" value then "b" else "a"))
        _ -> error "fixture domain text"
      changedDomainNumber name = case atPath ["host_domain", name] expression of
        Core.NaturalLit value -> Core.NaturalLit (value + 1)
        _ -> error "fixture domain number"
      otherOwner = case atPath ["host_domain", "manager_unique_name"] expression of
        Core.TextLit (Core.Chunks [] value) -> if value == ":1.0" then ":1.1" else ":1.0"
        _ -> error "fixture domain owner"
      foreignDomains =
        [ ("kernel_boot_id", changedDomainText "kernel_boot_id")
        , ("bus_instance_id", changedDomainText "bus_instance_id")
        , ("manager_unique_name", Core.TextLit (Core.Chunks [] otherOwner))
        , ("manager_uid", changedDomainNumber "manager_uid")
        , ("manager_pid", changedDomainNumber "manager_pid")
        , ("manager_start_ticks", changedDomainNumber "manager_start_ticks")
        ]
  forM_ foreignDomains $ \(name, value) -> do
    foreignRequest <-
      right (decodeRpcBirthControllerRequest key window (replace ["host_domain", name] value))
    foreignPreparation <- prepareRpcBirthControllerRequest foreignRequest settings
    assert
      ("foreign domain regained effect preparation: " <> Text.unpack name)
      (case foreignPreparation of Left ControllerRequestDomainMismatch -> True; _ -> False)
  expiredDomain <- observeRpcBirthControllerManagerDomain (started - 1)
  assert "expired native domain budget was accepted" (isLeft expiredDomain)
  imported <- right (Parser.exprFromText "request-control" "./disallowed-controller-request.dhall")
  refuse "import" (Lazy.toStrict (Binary.encodeExpression (Core.denote imported)))
  refuse
    "non-normal let"
    ( Lazy.toStrict
        (Binary.encodeExpression (Core.Let (Core.makeBinding "unused" (Core.NaturalLit 0)) expression))
    )
  refuse "trailing data" (encoded <> "\NUL")
  refuse "overlong bytes" (BS.replicate (rpcBirthControllerRequestMaximumBytes + 1) 0)
  forM_ [0 .. 255] $ \byte -> refuse "single byte" (BS.singleton byte)
  forM_ [0x9b, 0x7b, 0xdb] $ \header -> refuse "overflowing CBOR" (BS.pack (header : replicate 8 0xff))
  putStrLn
    "PASS schema/program/operation/key/root/clock/profile/stream/canonical/import/byte refusals"
  changedContext <-
    right
      =<< S.validateConfigWithContext
        root
        input {S.contextInputVaultAddress = "http://127.0.0.1:31821"}
        minimal
  mismatch <- prepareRpcBirthControllerRequest decoded changedContext
  assert
    "accepted foreign settings context"
    (case mismatch of Left ControllerRequestContextMismatch -> True; _ -> False)
  PosixEnv.setEnv "PRODBOX_TEST_HOST_CAPACITY" "" True
  present <- lookupEnv "PRODBOX_TEST_HOST_CAPACITY"
  assert "empty override not installed" (present == Just "")
  override <- prepareRpcBirthControllerRequest decoded settingsAgain
  assert
    "accepted capacity override"
    ( case override of
        Left (ControllerRequestHostRefused Native.NativeHostProbeOverrideRefused) -> True
        _ -> False
    )
  unsetEnv "PRODBOX_TEST_HOST_CAPACITY"
  fullRequest <-
    right
      ( mkRpcBirthControllerRequest
          LifecycleAuthorityTestHarness
          domain
          root
          full
          coordination
          window
          profile
      )
  fullResult <- prepareRpcBirthControllerRequest fullRequest full
  assert
    "admitted full default capacity on this insufficient host"
    (case fullResult of Left (ControllerRequestResourcesRefused _) -> True; _ -> False)
  let alteredProfile demand = profile {controllerHostDemand = demand}
  forM_
    [
      ( "CPU overcommit"
      , alteredProfile ((controllerHostDemand profile) {H.parentCpuUsecPerSec = 6000000})
      )
    , ("zero task count", alteredProfile ((controllerHostDemand profile) {H.parentTasks = 0}))
    ,
      ( "child reserve mismatch"
      , alteredProfile ((controllerHostDemand profile) {H.childMemoryBytes = 1})
      )
    ]
    $ \(label, changed) -> do
      bad <-
        right
          ( mkRpcBirthControllerRequest
              LifecycleAuthorityTestHarness
              domain
              root
              settings
              coordination
              window
              changed
          )
      result <- prepareRpcBirthControllerRequest bad settings
      assert
        ("accepted " ++ label)
        (case result of Left (ControllerRequestResourcesRefused _) -> True; _ -> False)
  expired <-
    right
      (mkRpcBirthCoordinationRequest scope (authorityTimeFromMicros 1) 1 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
  expiredRequest <-
    right
      ( mkRpcBirthControllerRequest
          LifecycleAuthorityTestHarness
          domain
          root
          settings
          expired
          window
          profile
      )
  expiry <- prepareRpcBirthControllerRequest expiredRequest settings
  assert
    "accepted elapsed Authority deadline"
    (case expiry of Left ControllerRequestExpired -> True; _ -> False)
  expiredWindow <-
    maybe
      (fail "elapsed window")
      pure
      ( I.hostExecutionWindow
          (started - 1000000000)
          (started - 6000000000)
          (started - 5000000000)
          (started - 4000000000)
          (started - 3000000000)
      )
  elapsed <-
    right
      ( mkRpcBirthControllerRequest
          LifecycleAuthorityTestHarness
          domain
          root
          settings
          coordination
          expiredWindow
          profile
      )
  elapsedResult <- prepareRpcBirthControllerRequest elapsed settings
  assert
    "accepted elapsed host bound"
    (case elapsedResult of Left ControllerRequestExpired -> True; _ -> False)
  let shortDeadline = authorityTimeFromMicros (authorityTimeMicros authorityNow + 10000000)
  short <-
    right (mkRpcBirthCoordinationRequest scope shortDeadline 1 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
  shortRequest <-
    right
      (mkRpcBirthControllerRequest LifecycleAuthorityTestHarness domain root settings short window profile)
  shortResult <- prepareRpcBirthControllerRequest shortRequest settings
  assert
    "accepted host window outside original Authority bound"
    (case shortResult of Left ControllerRequestAuthorityWindowRefused -> True; _ -> False)
  putStrLn
    "PASS fresh capacity override/default-overcommit/profile/context and original UTC/monotonic bound refusals"
  -- The extracted owner preserves every existing workload memory plan.
  let capacity = S.capacity syntheticConfigFile
  forM_ (C.runtime_memory_profiles capacity) $ \raw -> do
    workload <- case filter
      ((== C.runtime_profile_id raw) . C.profile_id)
      (C.workload_profiles (C.resource_plan capacity)) of
      [value] -> pure value
      _ -> fail "existing workload"
    old <- right (C.runtimeMemoryPlanForProfile capacity (C.runtime_profile_id raw))
    new <-
      right (C.runtimeMemoryPlanForLimit (C.memory_mib (C.limit (C.resources workload)) * 1048576) raw)
    assert "shared runtime compiler changed workload plan" (old == new)
    assert
      "shared runtime compiler erased heap"
      (R.runtimeMemoryRtsArguments old == R.runtimeMemoryRtsArguments new)
  putStrLn "PASS existing workload plans retain exact shared runtime memory and RTS policy"
