{-# LANGUAGE OverloadedStrings #-}

-- Public status with synthetic local records and an intentionally absent Docker
-- socket. This does not submit a systemd job or observe worker settlement.
-- Run: cabal exec --builddir=.build -- runghc -package=prodbox -package=temporary test/qualification/KindControllerJobStatus.hs
import Prodbox.Config.BootstrapProjection
import Prodbox.Config.DeploymentScope
import Prodbox.Control.KindIntent
import Prodbox.Control.KindLease
import Prodbox.Control.KindControllerReceipt
import Prodbox.Subprocess
import qualified Data.ByteString as B
import Data.List (isInfixOf)
import System.FilePath
import System.IO.Temp
import Control.Monad
main :: IO ()
main = withSystemTempDirectory "prodbox-job-status" $ \anchor -> do
 let selected = anchor </> "selected.dhall"; generation = replicate 32 'b'; operation = replicate 32 'd'; digest = replicate 64 'a'; job = "/org/freedesktop/systemd1/job/42"
     config = "{ bootstrap = { schema_version = 1, project_anchor = \"" ++ anchor ++ "\", runtime_socket = \"" ++ anchor ++ "/missing.sock\", environment = \"test\", deployment_id = \"fixture\", root_generation = \"" ++ generation ++ "\", api_port = 26443, node_image = \"kindest/node@sha256:" ++ replicate 64 'a' ++ "\", http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, listen_address = \"127.0.0.1\" } }"
 writeFile selected config
 projection <- readBootstrapProjection selected >>= either (fail . show) pure
 prepareFreshScope (bootstrapScope projection) generation >>= \value -> unless (value == FreshScopePrepared) (fail "scope refused")
 recordKindIntent projection operation >>= \value -> unless (value == KindIntentRecorded) (fail "intent refused")
 domain <- maybe (fail "domain invalid") pure (hostManagerDomain "12345678-1234-1234-1234-123456789abc" (replicate 32 'a') ":1.42" 1000 1234 5678)
 window <- maybe (fail "window invalid") pure (hostExecutionWindow 50 10 20 30 40)
 outcome <- withRecoveredKindOperation projection operation $ \stable -> do
   first <- recordControllerSubmissionIntent projection operation digest stable
   second <- recordControllerDomain projection operation digest domain window stable
   third <- recordControllerProvider projection operation digest (replicate 64 'c') stable
   fourth <- recordControllerJob projection operation digest job stable
   pure (first, second, third, fourth)
 unless (outcome == KindOperationCallbackReturned (ControllerSubmissionRecorded, ControllerDomainRecorded, ControllerProviderRecorded, ControllerJobRecorded)) (fail "fixture records refused")
 result <- captureSubprocessWithInputBounded (BoundedSubprocessLimits 1 65536 65536 30000000) B.empty (Subprocess "./.build/prodbox" ["--config",selected,"control","status"] (Just [("PATH","/usr/bin:/bin"),("HOME","/nonexistent")]) Nothing)
 case result of
   Right output -> do
     let combined = processStdout output ++ processStderr output
     unless ("RetainedControllerDomainObserved" `isInfixOf` combined && "RetainedControllerProviderObserved" `isInfixOf` combined && "RetainedControllerJobObserved" `isInfixOf` combined && job `isInfixOf` combined && "worker settlement not observed" `isInfixOf` combined) (fail "public status omitted job observation")
     putStrLn "public control status reported retained domain, provider binding and job; settlement remains unobserved"
   Left failure -> fail (show failure)
