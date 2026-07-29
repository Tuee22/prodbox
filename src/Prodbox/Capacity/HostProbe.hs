-- | Sprint 1.73: the Phase-1-owned host-probe reader plus the generate-time
-- host-fitting derivation.
--
-- The observation reader ('observeHostCapacity') was factored out of
-- @Prodbox.CLI.Rke2@ so both the reconcile Ring-3 check (which imports it) and
-- @prodbox config generate@ (which cannot import the CLI without an import cycle)
-- share a single owner. It reads @nproc@ / procfs meminfo / @df -Pm@ into an
-- 'ObservedHostRoot', honouring the documented @PRODBOX_TEST_HOST_CAPACITY@
-- test-only override.
--
-- 'deriveHostFittingCapacity' turns an observed host plus a resource plan into a
-- @host_capacity@ vector that (a) covers the plan's demand — @rke2_reserved +
-- eviction_floor + Σ concurrent draws@ — so the Haskell over-commit proof (Ring
-- 2) admits it, and (b) fits the real device so the reconcile-time observed-host
-- check (Ring 3, @compileResourcePlanAgainstObserved@) admits it, failing fast
-- when the host is too small. See resource_scaling_doctrine.md §2B.
module Prodbox.Capacity.HostProbe
  ( observeHostCapacity
  , deriveHostFittingCapacity
  , parseHostCapacityObservation
  )
where

import Control.Exception (IOException, displayException, try)
import Data.Char (isSpace)
import Data.List (find, isPrefixOf)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Capacity.Config
  ( ResourcePlan (..)
  , ResourceVector (..)
  , plusResourceVector
  , validateRawResourcePlanShape
  )
import Prodbox.Capacity.ObservedHost
  ( ObservedHostRoot
  , StorageDeviceId
  , mkObservedHostRoot
  , mkStorageDeviceId
  , observedHostVector
  , observedStorageDevicesCoincide
  )
import Prodbox.Capacity.Placement (concurrentPlanDraws)
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))

-- | Observe host capacity, honouring the documented @PRODBOX_TEST_HOST_CAPACITY@
-- test-only override (a @field=value,…@ string). Without the override it probes
-- the real host through @nproc@ / procfs meminfo / @df -Pm@.
observeHostCapacity :: FilePath -> FilePath -> IO (Either String ObservedHostRoot)
observeHostCapacity repoRoot retainedRoot = do
  override <- lookupEnv "PRODBOX_TEST_HOST_CAPACITY"
  case override of
    Just raw -> pure (parseHostCapacityObservation raw)
    Nothing -> observeHostCapacityFromHost repoRoot retainedRoot

observeHostCapacityFromHost
  :: FilePath
  -> FilePath
  -> IO (Either String ObservedHostRoot)
observeHostCapacityFromHost repoRoot retainedRoot = do
  cpuResult <- observedCpuMilli repoRoot
  memoryResult <- observedMemoryMib
  ephemeralResult <- observedFilesystemMib repoRoot "/"
  durableResult <- observedFilesystemMib repoRoot retainedRoot
  pure $ do
    cpu <- cpuResult
    memory <- memoryResult
    (ephemeralDevice, ephemeralStorage) <- ephemeralResult
    (durableDevice, durableStorage) <- durableResult
    mkObservedHostRoot
      ResourceVector
        { milli_cpu = cpu
        , memory_mib = memory
        , ephemeral_storage_mib = ephemeralStorage
        , durable_storage_mib = durableStorage
        }
      ephemeralDevice
      durableDevice

-- | Derive a @host_capacity@ vector that both covers the plan's demand and fits
-- the observed device. CPU and memory are declared at the observed capacity (the
-- reservation is modelled by @rke2_reserved@ / @eviction_floor@, subtracted to
-- form the allocatable). Storage is independent when the kubelet root and the
-- retained-PV path resolve to distinct devices; a shared device gets one joint
-- budget split so ephemeral keeps a bounded headroom and durable takes the
-- remainder, leaving ~5% device slack so a small shrink between generate and
-- reconcile does not immediately fail the Ring-3 check. Fails fast (never clamps)
-- when the host cannot cover the plan.
deriveHostFittingCapacity :: ObservedHostRoot -> ResourcePlan -> Either String ResourceVector
deriveHostFittingCapacity observed plan = do
  -- The shape check makes 'concurrentPlanDraws' total (its request projection
  -- would otherwise be partial on an invalid workload demand).
  validateRawResourcePlanShape plan
  let observedVector = observedHostVector observed
      reservation = plusResourceVector (rke2_reserved plan) (eviction_floor plan)
      totalDraw = foldl' plusResourceVector zeroVector (concurrentPlanDraws plan)
      demand = plusResourceVector reservation totalDraw
  cpu <- fitAxis "CPU (milli-cores)" (milli_cpu observedVector) (milli_cpu demand)
  memory <- fitAxis "memory (MiB)" (memory_mib observedVector) (memory_mib demand)
  (ephemeral, durable) <-
    if observedStorageDevicesCoincide observed
      then
        splitSharedStorage
          (min (ephemeral_storage_mib observedVector) (durable_storage_mib observedVector))
          (ephemeral_storage_mib demand)
          (durable_storage_mib demand)
      else do
        ephemeral <-
          fitAxis
            "ephemeral storage (MiB)"
            (ephemeral_storage_mib observedVector)
            (ephemeral_storage_mib demand)
        durable <-
          fitAxis
            "durable storage (MiB)"
            (durable_storage_mib observedVector)
            (durable_storage_mib demand)
        Right (ephemeral, durable)
  Right
    ResourceVector
      { milli_cpu = cpu
      , memory_mib = memory
      , ephemeral_storage_mib = ephemeral
      , durable_storage_mib = durable
      }
 where
  zeroVector = ResourceVector 0 0 0 0
  fitAxis label available required
    | required <= available = Right available
    | otherwise =
        Left
          ( "observed host "
              ++ label
              ++ " capacity "
              ++ show available
              ++ " is below the plan's required "
              ++ show required
              ++ " — the host is too small for the resource plan"
          )
  splitSharedStorage device ephemeralDemand durableDemand
    | usable < ephemeralDemand + durableDemand =
        Left
          ( "observed shared storage device capacity "
              ++ show device
              ++ "Mi is below the plan's ephemeral+durable requirement "
              ++ show (ephemeralDemand + durableDemand)
              ++ "Mi (ephemeral "
              ++ show ephemeralDemand
              ++ "Mi + durable "
              ++ show durableDemand
              ++ "Mi) — the host is too small for the resource plan"
          )
    | otherwise = Right (ephemeralBudget, usable - ephemeralBudget)
   where
    usable = device - device `div` 20
    slack = usable - ephemeralDemand - durableDemand
    ephemeralBudget = ephemeralDemand + min (ephemeralDemand `div` 4) (slack `div` 2)

parseHostCapacityObservation :: String -> Either String ObservedHostRoot
parseHostCapacityObservation raw =
  do
    vector <-
      ResourceVector
        <$> lookupNatural "milli_cpu"
        <*> lookupNatural "memory_mib"
        <*> lookupNatural "ephemeral_storage_mib"
        <*> lookupNatural "durable_storage_mib"
    ephemeralDevice <- parseDevice "ephemeral_device" "test-kubelet-device"
    durableDevice <- parseDevice "durable_device" "test-retained-device"
    mkObservedHostRoot vector ephemeralDevice durableDevice
 where
  fields = map splitField (splitOnChar ',' raw)
  lookupNatural key =
    case lookup key fields of
      Just value -> parseNatural key value
      Nothing -> Left ("missing host capacity field `" ++ key ++ "`")
  splitField field =
    case break (== '=') field of
      (key, '=' : value) -> (trimWhitespace key, trimWhitespace value)
      _ -> (trimWhitespace field, "")
  parseDevice key fallback =
    case mkStorageDeviceId (Text.pack (maybe fallback id (lookup key fields))) of
      Nothing -> Left ("invalid storage device id for `" ++ key ++ "`")
      Just device -> Right device

observedCpuMilli :: FilePath -> IO (Either String Natural)
observedCpuMilli repoRoot = do
  outputResult <- captureToolOutput repoRoot "nproc" []
  pure $ do
    output <- outputResult
    case processExitCode output of
      ExitFailure _ -> Left ("failed to observe host CPU count: " ++ outputDetail output)
      ExitSuccess -> (* 1000) <$> parseNatural "nproc" (trimWhitespace (processStdout output))

observedMemoryMib :: IO (Either String Natural)
observedMemoryMib = do
  meminfoResult <- try (readFile "/proc/meminfo") :: IO (Either IOException String)
  pure $ do
    meminfo <- either (Left . displayException) Right meminfoResult
    line <-
      maybe
        (Left "failed to observe host memory: /proc/meminfo has no MemTotal line")
        Right
        (find ("MemTotal:" `isPrefixOf`) (lines meminfo))
    case words line of
      ["MemTotal:", kibText, "kB"] -> (`div` 1024) <$> parseNatural "MemTotal" kibText
      _ -> Left ("failed to parse host memory line: " ++ line)

observedFilesystemMib
  :: FilePath
  -> FilePath
  -> IO (Either String (StorageDeviceId, Natural))
observedFilesystemMib repoRoot path = do
  outputResult <- captureToolOutput repoRoot "df" ["-Pm", path]
  pure $ do
    output <- outputResult
    case processExitCode output of
      ExitFailure _ ->
        Left ("failed to observe filesystem capacity for " ++ path ++ ": " ++ outputDetail output)
      ExitSuccess ->
        case drop 1 (lines (processStdout output)) of
          line : _ ->
            case words line of
              filesystem : blocks : _ -> do
                device <-
                  maybe
                    (Left ("invalid filesystem identity from df: " ++ filesystem))
                    Right
                    (mkStorageDeviceId (Text.pack filesystem))
                capacity <- parseNatural "df-1M-blocks" blocks
                Right (device, capacity)
              _ -> Left ("failed to parse df output line: " ++ line)
          [] -> Left "failed to parse df output: missing data line"

captureToolOutput :: FilePath -> FilePath -> [String] -> IO (Either String ProcessOutput)
captureToolOutput repoRoot toolName arguments = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = toolName
        , subprocessArguments = arguments
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $
    case result of
      Failure err -> Left ("failed to start " ++ toolName ++ ": " ++ err)
      Success output -> Right output

outputDetail :: ProcessOutput -> String
outputDetail output =
  case filter
    (/= "")
    [trimTrailingNewlines (processStderr output), trimTrailingNewlines (processStdout output)] of
    [] -> "subprocess exited without output"
    rendered -> foldr1 (\left right -> left ++ " | " ++ right) rendered

parseNatural :: String -> String -> Either String Natural
parseNatural key value =
  case reads value of
    [(parsed, "")] -> Right parsed
    _ -> Left ("invalid natural for `" ++ key ++ "`: " ++ value)

splitOnChar :: Char -> String -> [String]
splitOnChar _ "" = [""]
splitOnChar delimiter input =
  case break (== delimiter) input of
    (before, _ : remaining) -> before : splitOnChar delimiter remaining
    (before, []) -> [before]

trimTrailingNewlines :: String -> String
trimTrailingNewlines = reverse . dropWhile (`elem` ['\n', '\r']) . reverse

trimWhitespace :: String -> String
trimWhitespace = reverse . dropWhile isSpace . reverse . dropWhile isSpace
