{-# LANGUAGE OverloadedStrings #-}

-- Read-only user-manager qualification in a disposable test scope with a
-- missing Docker socket. It submits no job and proves no worker retirement.
-- Run: cabal exec --builddir=.build -- runghc -package=prodbox -package=temporary test/qualification/KindControllerFreshProvider.hs
import Control.Monad (unless)
import qualified Data.ByteString as B
import Data.List (isInfixOf)
import Prodbox.Config.BootstrapProjection
import Prodbox.Config.DeploymentScope
import Prodbox.Control.KindControllerReceipt
import Prodbox.Control.KindIntent
import Prodbox.Control.KindLease
import Prodbox.Subprocess
import System.FilePath
import System.IO.Temp

main :: IO ()
main = do
  runCase False
  runCase True

runCase :: Bool -> IO ()
runCase mismatch = withSystemTempDirectory "prodbox-fresh-provider" $ \anchor -> do
  let selected = anchor </> "selected.dhall"
      generation = replicate 32 'b'
      operation = replicate 32 'd'
      request = replicate 64 'a'
      config =
        "{ bootstrap = { schema_version = 1, project_anchor = \""
          ++ anchor
          ++ "\", runtime_socket = \""
          ++ anchor
          ++ "/missing.sock\", environment = \"test\", deployment_id = \"fixture\", root_generation = \""
          ++ generation
          ++ "\", api_port = 26443, node_image = \"kindest/node@sha256:"
          ++ replicate 64 'a'
          ++ "\", http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, listen_address = \"127.0.0.1\" } }"
      status =
        captureSubprocessWithInputBounded
          (BoundedSubprocessLimits 1 65536 65536 30000000)
          B.empty
          ( Subprocess
              "./.build/prodbox"
              ["--config", selected, "control", "status"]
              (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
              Nothing
          )
      requireStatus expected = do
        outcome <- status
        case outcome of
          Right output -> do
            let combined = processStdout output ++ processStderr output
            unless
              (expected `isInfixOf` combined && "worker settlement not observed" `isInfixOf` combined)
              (fail ("public status omitted " ++ expected))
          Left failure -> fail (show failure)
  writeFile selected config
  projection <- readBootstrapProjection selected >>= either (fail . show) pure
  prepareFreshScope (bootstrapScope projection) generation >>= \value -> unless (value == FreshScopePrepared) (fail "scope refused")
  recordKindIntent projection operation >>= \value -> unless (value == KindIntentRecorded) (fail "intent refused")
  window <- maybe (fail "window invalid") pure (hostExecutionWindow 50 10 20 30 40)
  result <- withCurrentControllerProvider $ \domain binding sender _ _ verify -> do
    let bus = hostManagerBusId domain
        changedBus = (if take 1 bus == "a" then "b" else "a") ++ drop 1 bus
    alternate <-
      maybe (fail "alternate domain invalid") pure $
        hostManagerDomain
          (hostManagerBootId domain)
          changedBus
          (hostManagerUniqueName domain)
          (hostManagerUserId domain)
          (hostManagerProcessId domain)
          (hostManagerStartTicks domain)
    let retainedDomain = if mismatch then alternate else domain
        expected = if mismatch then "ControllerFreshProviderDifferent" else "ControllerFreshProviderMatches"
    records <- withRecoveredKindOperation projection operation $ \stable -> do
      first <- recordControllerSubmissionIntent projection operation request stable
      second <- recordControllerDomain projection operation request retainedDomain window stable
      third <-
        recordControllerProvider projection operation request (controllerProviderDigest binding) stable
      fourth <- recordControllerProviderMaterial projection operation request binding stable
      fifth <- recordControllerSender projection operation request sender stable
      sixth <-
        recordFamilyResult
          projection
          operation
          request
          ( FamilyResult
              FamilyWorkerConfirmed
              FamilyWorkerIoUnconfirmed
              FamilyParentUnconfirmed
              FamilyInputUnconfirmed
              FamilyPostReceiptComplete
              FamilyPostLeaseUnconfirmed
          )
          stable
      pure (first, second, third, fourth, fifth, sixth)
    unless
      ( records
          == KindOperationCallbackReturned
            ( ControllerSubmissionRecorded
            , ControllerDomainRecorded
            , ControllerProviderRecorded
            , ControllerProviderMaterialRecorded
            , ControllerSenderRecorded
            , FamilyResultRecorded
            )
      )
      (fail "fixture records refused")
    before <- verify
    requireStatus expected
    unless mismatch $ do
      requireStatus "ControllerFreshSenderPresent"
      requireStatus "ControllerManagerSenderPresent"
    after <- verify
    unless (before && after) (fail "live provider changed during fixture")
  either (fail . ("local provider qualification unavailable: " ++)) pure result
  if mismatch
    then putStrLn "public status rejected a different recorded manager domain"
    else do
      requireStatus "ControllerFreshSenderAbsent"
      requireStatus "FamilyWorkerIoUnconfirmed FamilyParentUnconfirmed FamilyInputUnconfirmed"
      outcome <- status
      case outcome of
        Right output -> do
          let combined = processStdout output ++ processStderr output
          unless
            ( ( "ControllerManagerUnitPresent" `isInfixOf` combined
                  || "ControllerManagerUnitAbsent" `isInfixOf` combined
              )
                && "job processing and worker settlement not established" `isInfixOf` combined
            )
            (fail "manager read unobservable")
        Left failure -> fail (show failure)
      putStrLn
        "public status matched the provider and observed the original sender present then absent; retirement remains unobserved"
