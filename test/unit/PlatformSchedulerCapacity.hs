{-# LANGUAGE OverloadedStrings #-}

module PlatformSchedulerCapacity (platformSchedulerCapacitySuite) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception
  ( AsyncException (UserInterrupt)
  , SomeException
  , fromException
  , throwTo
  , try
  )
import Control.Monad (forM_)
import Data.Aeson (Value, eitherDecodeFileStrict', withObject, (.:))
import Data.Aeson.Types (Parser, parseEither)
import Data.Either (isLeft, isRight)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Dhall qualified
import Prodbox.Capacity.Allocation qualified as Allocation
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Capacity.HostProbe (deriveHostFittingCapacity, parseHostCapacityObservation)
import Prodbox.Capacity.LegacyDhall qualified as Legacy
import Prodbox.Capacity.ObservedHost (ObservedHostRoot)
import Prodbox.Capacity.Placement qualified as Placement
import Prodbox.Capacity.PlatformSchedulerBudget qualified as Platform
import Prodbox.Config.Tier0 qualified as Tier0
import Prodbox.Repo (findRepoRoot)
import Prodbox.Settings qualified as Settings
import Prodbox.Substrate (Substrate (SubstrateHomeLocal))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import TestSupport

platformSchedulerCapacitySuite :: SuiteBuilder ()
platformSchedulerCapacitySuite = describe "LOCAL-PLATFORM-SCHEDULER-BASELINE-OMITTED-2026-10-24" $ do
  it "matches the independent real provider's standing request vectors" $
    withRecording recordedBaseline $ \baseline ->
      Platform.minimumPlatformSchedulerRequests `shouldBe` baseline

  it "retains the native scheduler's positive memory deficit" $
    withRecording recordedDeficit $ \(allocatable, bound, pending) ->
      (bound + pending) `shouldSatisfy` (> allocatable)

  it "refuses the unchanged frozen physical host at the actual allocator" $
    Allocation.compileResourcePlanUncertified causalPlan `shouldSatisfy` isLeft

  it "admits a separately sufficient declared production host" $
    Allocation.compileResourcePlanUncertified Capacity.defaultResourcePlan `shouldSatisfy` isRight

  it "charges the recorded baseline exactly once without inventing application allocations" $ do
    let declared = Capacity.defaultResourcePlan
        standalone = declared {Capacity.platform_scheduler_requests = Just zero}
    case ( Allocation.compileResourcePlanUncertified declared
         , Allocation.compileResourcePlanUncertified standalone
         ) of
      (Right complete, Right applications) -> do
        Allocation.planTotalDraw complete
          `shouldBe` Capacity.plusResourceVector
            (Allocation.planTotalDraw applications)
            Platform.minimumPlatformSchedulerRequests
        Allocation.planWorkloadDraws complete `shouldBe` Allocation.planWorkloadDraws applications
      other -> expectationFailure (show other)

  forM_ ["vscode", "api", "websocket", "gateway", "lifecycle-authority"] $ \namespace ->
    it ("keeps " ++ Text.unpack namespace ++ " namespace/container projections independent") $ do
      let plan = Capacity.defaultResourcePlan
          changed = plan {Capacity.platform_scheduler_requests = Just (Capacity.ResourceVector 4000 9000 1234 5678)}
      Placement.planNamespaceAdmission SubstrateHomeLocal namespace changed
        `shouldBe` Placement.planNamespaceAdmission SubstrateHomeLocal namespace plan
      Placement.planNamespaceLimits SubstrateHomeLocal namespace changed
        `shouldBe` Placement.planNamespaceLimits SubstrateHomeLocal namespace plan

  it "refuses an omitted declaration in allocation, placement and fitting" $ do
    let plan = Capacity.defaultResourcePlan {Capacity.platform_scheduler_requests = Nothing}
    Allocation.compileResourcePlanUncertified plan `shouldSatisfy` isLeft
    Placement.concurrentPlanDraws plan `shouldSatisfy` isLeft
    withObserved
      "milli_cpu=12000,memory_mib=32768,ephemeral_storage_mib=100000,durable_storage_mib=180000"
      $ \host ->
        deriveHostFittingCapacity host plan `shouldSatisfy` isLeft

  forM_
    [ ("CPU", Platform.minimumPlatformSchedulerRequests {Capacity.milli_cpu = 1834})
    , ("memory", Platform.minimumPlatformSchedulerRequests {Capacity.memory_mib = 3383})
    , ("zero", zero)
    ]
    $ \(label, baseline) ->
      it ("refuses underdeclared production " ++ label) $
        Capacity.validateCapacitySection
          ( Capacity.defaultCapacitySection
              { Capacity.resource_plan =
                  Capacity.defaultResourcePlan {Capacity.platform_scheduler_requests = Just baseline}
              }
          )
          `shouldSatisfy` isLeft

  it "admits exact complete demand on all four resource axes" $
    Allocation.compileResourcePlanUncertified
      (Capacity.defaultResourcePlan {Capacity.host_capacity = exactDemand})
      `shouldSatisfy` isRight

  forM_
    [ ("CPU", exactDemand {Capacity.milli_cpu = 9044})
    , ("memory", exactDemand {Capacity.memory_mib = 17481})
    , ("ephemeral", exactDemand {Capacity.ephemeral_storage_mib = 35423})
    , ("durable", exactDemand {Capacity.durable_storage_mib = 157695})
    ]
    $ \(label, host) ->
      it ("refuses a one-unit complete " ++ label ++ " deficit") $
        Allocation.compileResourcePlanUncertified
          (Capacity.defaultResourcePlan {Capacity.host_capacity = host})
          `shouldSatisfy` isLeft

  it "also charges authored nonzero platform storage requests" $ do
    let baseline =
          Platform.minimumPlatformSchedulerRequests
            { Capacity.ephemeral_storage_mib = 128
            , Capacity.durable_storage_mib = 256
            }
        plan = Capacity.defaultResourcePlan {Capacity.platform_scheduler_requests = Just baseline}
    case Allocation.compileResourcePlanUncertified plan of
      Left err -> expectationFailure (show err)
      Right compiled -> Allocation.planTotalDraw compiled `shouldBe` Capacity.ResourceVector 8045 14922 15584 155904

  it "refuses the original host at generation before config can be authored"
    $ withObserved
      "milli_cpu=8000,memory_mib=15872,ephemeral_storage_mib=100000,durable_storage_mib=180000"
    $ \host ->
      deriveHostFittingCapacity host Capacity.defaultResourcePlan `shouldSatisfy` isLeft

  it "fits a sufficient observed host through the same demand projection"
    $ withObserved
      "milli_cpu=10000,memory_mib=20480,ephemeral_storage_mib=100000,durable_storage_mib=180000"
    $ \host ->
      deriveHostFittingCapacity host Capacity.defaultResourcePlan
        `shouldBe` Right (Capacity.ResourceVector 10000 20480 100000 180000)

  it "recomputes the in-force baseline at the generated Dhall assertion" $ do
    let original = Tier0.renderProjectConfigDhall syntheticProjectConfig
        oversized = Text.replace "milli_cpu = 1835" "milli_cpu = 999999" original
    oversized `shouldNotBe` original
    result <-
      try (Dhall.input Dhall.auto oversized) :: IO (Either SomeException Tier0.ProdboxProjectConfig)
    result `shouldSatisfy` isLeft
    case result of
      Left failure -> show failure `shouldContain` "Assertion failed"
      Right _ -> expectationFailure "oversized declared baseline unexpectedly loaded"

  it "preserves a current declaration without migration" $ do
    result <- decodeParameters currentParameters
    either (expectationFailure . show) (`shouldBe` syntheticConfigFile) result

  it "decodes an exact legacy omission as non-authorizing Nothing without rewriting the file" $
    withSystemTempDirectory "prodbox platform legacy quoted" $ \directory -> do
      let path = directory </> "parameters.dhall"
      TextIO.writeFile path legacyParameters
      result <-
        Legacy.decodeDhallFileWithLegacyPlatformDemand Dhall.auto Legacy.StandaloneParameters path
      case result of
        Left failure -> expectationFailure (show failure)
        Right config -> do
          Capacity.platform_scheduler_requests (Capacity.resource_plan (Settings.capacity config))
            `shouldBe` Nothing
          Capacity.validateCapacitySection (Settings.capacity config) `shouldSatisfy` isLeft
      TextIO.readFile path `shouldReturn` legacyParameters

  forM_
    [ ("present malformed declaration", "True")
    , ("present foreign declaration type", "\"unrecognized\"")
    ]
    $ \(label, value) -> it ("refuses " ++ label ++ " instead of replacing it") $ do
      result <-
        decodeParameters
          ("(" <> currentParameters <> ") with capacity.resource_plan.platform_scheduler_requests = " <> value)
      result `shouldSatisfy` isLeft

  it "preserves an undersized declaration for the production refusal" $ do
    let config =
          syntheticConfigFile
            { Settings.capacity =
                Capacity.defaultCapacitySection
                  { Capacity.resource_plan =
                      Capacity.defaultResourcePlan {Capacity.platform_scheduler_requests = Just zero}
                  }
            }
    result <- decodeParameters (Text.pack (Settings.renderConfigDhall config))
    case result of
      Left failure -> expectationFailure (show failure)
      Right decoded -> do
        decoded `shouldBe` config
        Capacity.validateCapacitySection (Settings.capacity decoded) `shouldSatisfy` isLeft

  it "refuses an extra field on a legacy plan" $ do
    result <-
      decodeParameters
        ( "let legacy = "
            <> legacyParameters
            <> " in legacy with capacity.resource_plan = legacy.capacity.resource_plan // { unexpected = True }"
        )
    result `shouldSatisfy` isLeft

  it "uses the same non-authorizing legacy decode at both production config readers" $
    withSystemTempDirectory "prodbox platform project legacy" $ \directory -> do
      let current = Tier0.renderProjectConfigDhall syntheticProjectConfig
          source =
            "let current = "
              <> current
              <> " in current with parameters.capacity.resource_plan = current.parameters.capacity.resource_plan.{ host_capacity, rke2_reserved, eviction_floor, workload_profiles }"
          path = directory </> "prodbox.dhall"
      TextIO.writeFile path source
      project <- Tier0.decodeProjectConfigDhall path
      parameters <- Settings.loadConfigFileAtPath path
      case (project, parameters) of
        (Right legacy, Right config) -> do
          Tier0.parameters legacy `shouldBe` Tier0.configFileToTier0Parameters config
          Capacity.platform_scheduler_requests (Capacity.resource_plan (Settings.capacity config))
            `shouldBe` Nothing
          Capacity.validateCapacitySection (Settings.capacity config) `shouldSatisfy` isLeft
        other -> expectationFailure (show other)
      TextIO.readFile path `shouldReturn` source

  it "loads a current standalone config under spaces and quoted directory components" $
    withSystemTempDirectory "prodbox file \"quoted\" path" $ \directory -> do
      let path = directory </> "parameters.dhall"
      TextIO.writeFile path currentParameters
      result <- Legacy.decodeDhallFileWithLegacyPlatformDemand Dhall.auto Legacy.StandaloneParameters path
      either (expectationFailure . show) (`shouldBe` syntheticConfigFile) result

  forM_ [False, True] $ \legacy ->
    it
      ( "preserves relative imports and trailing comments in "
          ++ if legacy then "legacy files" else "current files"
      )
      $ withSystemTempDirectory "prodbox relative \"quoted\" path"
      $ \directory -> do
        let current = Tier0.renderProjectConfigDhall syntheticProjectConfig
            source =
              if legacy
                then
                  "let current = "
                    <> current
                    <> " in current with parameters.capacity.resource_plan = current.parameters.capacity.resource_plan.{ host_capacity, rke2_reserved, eviction_floor, workload_profiles }"
                else current
            path = directory </> "prodbox.dhall"
            imported = directory </> "payload.dhall"
            importSource = "./payload.dhall\n-- trailing comment"
        TextIO.writeFile imported source
        TextIO.writeFile path importSource
        project <- Tier0.decodeProjectConfigDhall path
        parameters <- Settings.loadConfigFileAtPath path
        context <- Legacy.decodeDhallFileProjection Dhall.auto Legacy.ContextCoordinates path
        case (project, parameters, context) of
          (Right loaded, Right config, Right coordinates) -> do
            Tier0.parameters loaded `shouldBe` Tier0.configFileToTier0Parameters config
            Capacity.platform_scheduler_requests (Capacity.resource_plan (Settings.capacity config))
              `shouldBe` if legacy then Nothing else Just Platform.minimumPlatformSchedulerRequests
            Settings.contextInputClusterId coordinates
              `shouldBe` Tier0.cluster_id (Tier0.context syntheticProjectConfig)
          other -> expectationFailure (show other)
        if legacy
          then pure ()
          else Settings.validateAndLoadSettingsAtPath path directory >>= (`shouldSatisfy` isRight)
        TextIO.readFile path `shouldReturn` importSource
        TextIO.readFile imported `shouldReturn` source

  it "propagates cancellation through legacy decoding" $ do
    started <- newEmptyMVar
    completed <- newEmptyMVar
    let expensive =
          "let n = Natural/fold 10000000000 Natural (\\(n : Natural) -> n + 1) 0 in let _ = assert : n === 10000000000 in "
            <> currentParameters
    child <- forkIO $ do
      putMVar started ()
      result <-
        try (decodeParameters expensive)
          :: IO (Either SomeException (Either SomeException Settings.ConfigFile))
      putMVar completed result
    takeMVar started
    threadDelay 1000
    throwTo child UserInterrupt
    result <- timeout 5000000 (takeMVar completed)
    case result of
      Just (Left failure) -> (fromException failure :: Maybe AsyncException) `shouldBe` Just UserInterrupt
      _ -> expectationFailure "decoder swallowed cancellation or did not settle"

causalPlan :: Capacity.ResourcePlan
causalPlan =
  Capacity.defaultResourcePlan
    { Capacity.host_capacity = Capacity.ResourceVector 8000 15872 100000 180000
    }

exactDemand :: Capacity.ResourceVector
exactDemand = Capacity.ResourceVector 9045 17482 35424 157696

zero :: Capacity.ResourceVector
zero = Capacity.ResourceVector 0 0 0 0

currentParameters :: Text
currentParameters = Text.pack (Settings.renderConfigDhall syntheticConfigFile)

legacyParameters :: Text
legacyParameters =
  "let current = "
    <> currentParameters
    <> " in current with capacity.resource_plan = current.capacity.resource_plan.{ host_capacity, rke2_reserved, eviction_floor, workload_profiles }"

decodeParameters :: Text -> IO (Either SomeException Settings.ConfigFile)
decodeParameters = Legacy.decodeDhallWithLegacyPlatformDemand Dhall.auto Legacy.StandaloneParameters

withObserved :: String -> (ObservedHostRoot -> Expectation) -> Expectation
withObserved source action = either expectationFailure action (parseHostCapacityObservation source)

withRecording :: (Value -> Parser value) -> (value -> Expectation) -> Expectation
withRecording parser action = do
  root <- findRepoRoot
  case root of
    Left failure -> expectationFailure failure
    Right directory -> do
      loaded <-
        eitherDecodeFileStrict'
          (directory </> "test/qualification/LOCAL-PLATFORM-SCHEDULER-BASELINE-OMITTED-2026-10-24.json")
      case loaded >>= parseEither parser of
        Left failure -> expectationFailure failure
        Right value -> action value

recordedBaseline :: Value -> Parser Capacity.ResourceVector
recordedBaseline = withObject "recording" $ \recording -> do
  vectors <- recording .: "recorded_scheduler_request_vectors"
  totals <- vectors .: "baseline_totals"
  cpu <- totals .: "cpu"
  memory <- totals .: "memory"
  if memory `mod` 1048576 == 0
    then pure (Capacity.ResourceVector cpu (memory `div` 1048576) 0 0)
    else fail "provider recording has a fractional-MiB scheduler baseline"

recordedDeficit :: Value -> Parser (Integer, Integer, Integer)
recordedDeficit = withObject "recording" $ \recording -> do
  capacity <- recording .: "recorded_scheduler_capacity"
  (,,)
    <$> capacity .: "allocatable_memory_bytes"
    <*> capacity .: "bound_request_bytes"
    <*> capacity .: "pending_authority_request_bytes"
