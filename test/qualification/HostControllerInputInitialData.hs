{-# LANGUAGE ImportQualifiedPost #-}

-- Native field controls. Run each mode with its explicit actual RTS policy;
-- this fixture does not qualify an ordinary operation or grant admission.
module Main (main) where

import Control.Exception (IOException, try)
import Control.Monad (forM, unless)
import Data.ByteString qualified as Bytes
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (sort)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.RTS.Flags qualified as Rts
import Numeric.Natural (Natural)
import Prodbox.Subprocess.HostControllerInputs qualified as Current
import Prodbox.Subprocess.InitialRuntimePolicy qualified as Policy
import System.Directory (listDirectory)
import System.Environment (getArgs)
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), hSetFileSize, withBinaryFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (readSymbolicLink, setFileMode)
import Text.Read (readMaybe)

right :: (Show err) => Either err value -> IO value
right = either (fail . show) pure

-- A declared caller-data floor for this field-only fixture. It includes
-- both empty source-buffer headers; it is not physical/Authority admission.
fixtureInitialDataFloor :: Natural -> Natural -> Natural
fixtureInitialDataFloor configuration request =
  1048576 + 8 * ((configuration + 7) `div` 8) + 8 * ((request + 7) `div` 8)

payload :: Integer
payload = 1048576

positions :: [FilePath] -> IO [(FilePath, Integer)]
positions paths = do
  descriptors <- listDirectory "/proc/self/fd"
  rows <- forM descriptors $ \descriptor -> do
    target <-
      try (readSymbolicLink ("/proc/self/fd" </> descriptor)) :: IO (Either IOException FilePath)
    case target of
      Right path | path `elem` paths -> do
        fields <- lines <$> readFile ("/proc/self/fdinfo" </> descriptor)
        case [offset | field <- fields, ["pos:", value] <- [words field], Just offset <- [readMaybe value]] of
          [offset] -> pure [(path, offset)]
          _ -> fail "held descriptor had no unique native position"
      _ -> pure []
  let result = sort (concat rows)
  unless (map fst result == sort paths) (fail "did not observe exactly both held input descriptors")
  pure result

assertPosition :: Integer -> [(FilePath, Integer)] -> IO ()
assertPosition expected actual =
  unless
    (all ((== expected) . snd) actual)
    (fail ("unexpected native descriptor positions: " <> show actual))

checkCurrent :: FilePath -> FilePath -> String -> IO ()
checkCurrent configuration request mode = do
  ending <- (+ 5000000000) <$> getMonotonicTimeNSec
  let minimumFloor = fixtureInitialDataFloor 0 0
      required = fixtureInitialDataFloor (fromInteger payload) (fromInteger payload)
      paths = [configuration, request]
  result <- Current.withHostControllerInputs ending configuration request $ \inputs -> do
    positions paths >>= assertPosition 0
    let floorBytes = if mode == "finite" then 128 * 1024 * 1024 + 1 else minimumFloor
        deniedRequired = floorBytes + 2 * fromInteger payload
    denied <- Current.readHostControllerInputsWithInitialDataFloor floorBytes inputs
    case denied of
      Left (Current.ControllerInputRuntimeRefused observed) ->
        unless (observed == deniedRequired) (fail "guard did not use both exact held file sizes")
      Left cause -> fail ("wrong input refusal: " <> show cause)
      Right _ -> fail "underfunded or invalid actual policy entered payload allocation"
    positions paths >>= assertPosition 0
    putStrLn ("typed_refusal_before_read; required=" <> show deniedRequired)
    case mode of
      "finite" -> do
        accepted <- right =<< Current.readHostControllerInputsWithInitialDataFloor minimumFloor inputs
        unless
          ( Bytes.length (Current.hostControllerConfigurationBytes accepted) == fromInteger payload
              && Bytes.length (Current.hostControllerRequestBytes accepted) == fromInteger payload
          )
          (fail "funded owner read changed payload sizes")
        positions paths >>= assertPosition payload
        putStrLn ("accepted_exact_payloads; required=" <> show required)
      "refuse" -> legacy inputs paths
      "unlimited" -> do
        flags <- Rts.getRTSFlags
        unless (Rts.maxHeapSize (Rts.gcFlags flags) == 0) (fail "default policy was not unlimited")
        putStrLn "observed_maxHeapSize_zero"
        legacy inputs paths
      "current" -> pure ()
      _ -> fail "unknown current mode"
  _ <- right result
  pure ()
 where
  legacy inputs paths = do
    bytes <- right =<< Current.readHostControllerInputs inputs
    unless
      ( Bytes.length (Current.hostControllerConfigurationBytes bytes)
          + Bytes.length (Current.hostControllerRequestBytes bytes)
          == 2 * fromInteger payload
      )
      (fail "existing read route changed payload sizes")
    positions paths >>= assertPosition payload
    putStrLn "existing_read_route_preserved"

checkExisting :: FilePath -> FilePath -> IO ()
checkExisting configuration request = do
  ending <- (+ 5000000000) <$> getMonotonicTimeNSec
  bytes <-
    right
      =<< Current.withHostControllerInputs ending configuration request Current.readHostControllerInputs
  value <- right bytes
  let count =
        Bytes.length (Current.hostControllerConfigurationBytes value)
          + Bytes.length (Current.hostControllerRequestBytes value)
  unless (count == 2 * fromInteger payload) (fail "existing route changed payload lengths")
  putStrLn ("baseline_completed_bytes=" <> show count)

checkSizes :: FilePath -> FilePath -> IO ()
checkSizes configuration request = do
  let sizes = [0, 1, 7, 8, 9, 4095, 4096, 1048575, 1048576]
      minimumFloor = fixtureInitialDataFloor 0 0
      excessiveFloor = 128 * 1024 * 1024 + 1
      paths = [configuration, request]
  mapM_
    ( \(a, b) -> do
        withBinaryFile configuration WriteMode (`hSetFileSize` a)
        withBinaryFile request WriteMode (`hSetFileSize` b)
        ending <- (+ 5000000000) <$> getMonotonicTimeNSec
        outer <- Current.withHostControllerInputs ending configuration request $ \inputs -> do
          denied <- Current.readHostControllerInputsWithInitialDataFloor excessiveFloor inputs
          let expected =
                excessiveFloor
                  + fixtureInitialDataFloor (fromInteger a) (fromInteger b)
                  - minimumFloor
          case denied of
            Left (Current.ControllerInputRuntimeRefused required) | required == expected -> pure ()
            _ -> fail "held size/alignment matrix did not produce its exact prospective floor"
          positions paths >>= assertPosition 0
          accepted <- right =<< Current.readHostControllerInputsWithInitialDataFloor minimumFloor inputs
          unless
            ( Bytes.length (Current.hostControllerConfigurationBytes accepted) == fromInteger a
                && Bytes.length (Current.hostControllerRequestBytes accepted) == fromInteger b
            )
            (fail "size matrix changed a captured payload")
          offsets <- positions paths
          unless
            (offsets == sort [(configuration, a), (request, b)])
            (fail "size matrix did not read both exact held payloads")
        _ <- right outer
        pure ()
    )
    [(a, b) | a <- sizes, b <- sizes]
  putStrLn "exact_held_size_pairs=81; refusal_offsets_zero; funded_offsets_exact"

checkDriftClosed :: FilePath -> FilePath -> IO ()
checkDriftClosed configuration request = do
  saved <- newIORef Nothing
  ending <- (+ 5000000000) <$> getMonotonicTimeNSec
  result <- Current.withHostControllerInputs ending configuration request $ \inputs -> do
    writeIORef saved (Just inputs)
    withBinaryFile request WriteMode (`hSetFileSize` 0)
    refused <- Current.readHostControllerInputsWithInitialDataFloor (128 * 1024 * 1024 + 1) inputs
    case refused of
      Left (Current.ControllerInputChanged Current.ControllerRequest) -> pure ()
      _ -> fail "runtime refusal hid a changed held request"
    positions [configuration, request] >>= assertPosition 0
  _ <- right result
  escaped <- readIORef saved >>= maybe (fail "owner fixture did not retain its tested reference") pure
  closed <- Current.readHostControllerInputsWithInitialDataFloor (128 * 1024 * 1024 + 1) escaped
  case closed of
    Left Current.ControllerInputsClosed -> pure ()
    _ -> fail "runtime check reopened a closed owner"
  putStrLn "held_version_drift_and_closed_owner_refuse_before_runtime_or_read"

-- Private owner APIs stay outside the package's public unit-test surface.
-- These four permanent regressions exercise the same actual owners here.
checkRefusalRegressions :: IO ()
checkRefusalRegressions = do
  let impossible = 2 ^ (4096 :: Int)
      files action = withSystemTempDirectory "prodbox-initial-refusal" $ \root -> do
        setFileMode root 0o700
        let configuration = root </> "config.dhall"
            request = root </> "request"
        Bytes.writeFile configuration (Bytes.replicate 3 0)
        Bytes.writeFile request (Bytes.replicate 9 0)
        mapM_ (`setFileMode` 0o600) [configuration, request]
        action configuration request
  expired <- Policy.verifyInitialRuntimePolicyBefore 0 impossible
  unless
    (expired == Left Policy.InitialRuntimePolicyExpired)
    (fail "expired original work did not refuse first")
  files $ \configuration request -> do
    ending <- (+ 5000000000) <$> getMonotonicTimeNSec
    result <- Current.withHostControllerInputs ending configuration request $ \inputs -> do
      observed <- Current.readHostControllerInputsWithInitialDataFloor impossible inputs
      case observed of
        Left (Current.ControllerInputRuntimeRefused required) | required == impossible + 24 -> pure ()
        _ -> fail "impossible floor did not use both rounded held sizes"
      positions [configuration, request] >>= assertPosition 0
    _ <- right result
    pure ()
  files $ \configuration request -> do
    ending <- (+ 5000000000) <$> getMonotonicTimeNSec
    result <- Current.withHostControllerInputs ending configuration request $ \inputs -> do
      Bytes.writeFile request Bytes.empty
      observed <- Current.readHostControllerInputsWithInitialDataFloor impossible inputs
      case observed of
        Left (Current.ControllerInputChanged Current.ControllerRequest) -> pure ()
        _ -> fail "changed file did not refuse before runtime policy"
      positions [configuration, request] >>= assertPosition 0
    _ <- right result
    pure ()
  files $ \configuration request -> do
    ending <- (+ 5000000000) <$> getMonotonicTimeNSec
    owner <- right =<< Current.withHostControllerInputs ending configuration request pure
    observed <- Current.readHostControllerInputsWithInitialDataFloor impossible owner
    case observed of
      Left Current.ControllerInputsClosed -> pure ()
      _ -> fail "a runtime comparison reopened a closed owner"
  putStrLn
    "permanent_private_owner_regressions=4; expired/held-size/no-read/drift/closed precedence passed"

main :: IO ()
main = do
  modes <- getArgs
  withSystemTempDirectory "prodbox-held-input-floor" $ \root -> do
    setFileMode root 0o700
    let configuration = root </> "config.dhall"
        request = root </> "request"
    mapM_
      (\path -> withBinaryFile path WriteMode (`hSetFileSize` payload) >> setFileMode path 0o600)
      [configuration, request]
    case modes of
      ["baseline"] -> checkExisting configuration request
      ["regressions"] -> checkRefusalRegressions
      ["sizes"] -> checkSizes configuration request
      ["drift-closed"] -> checkDriftClosed configuration request
      [mode] -> checkCurrent configuration request mode
      _ -> fail "expected one native policy mode"
