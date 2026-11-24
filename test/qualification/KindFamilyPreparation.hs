{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- Synthetic declaration checks; no manager or worker is started.
import Control.Monad (unless)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Capacity.ObservedHost qualified as Observed
import Prodbox.Config.BootstrapProjection (readBootstrapProjection)
import Prodbox.Control.KindController
import Prodbox.Control.KindControllerRequest
import Prodbox.Subprocess.HostOperationFamily qualified as Family
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

main :: IO ()
main = withSystemTempDirectory "prodbox-kind-family-plan" $ \anchor -> do
  let configuration = anchor </> "selected.dhall"
      otherConfiguration = anchor </> "other.dhall"
      config deployment = "{ bootstrap = { schema_version = 1, project_anchor = \"" ++ anchor ++ "\", runtime_socket = \"" ++ anchor ++ "/missing.sock\", environment = \"test\", deployment_id = \"" ++ deployment ++ "\", root_generation = \"" ++ replicate 32 'b' ++ "\", api_port = 26443, node_image = \"kindest/node@sha256:" ++ replicate 64 'a' ++ "\", http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, listen_address = \"127.0.0.1\" } }"
      operation = replicate 32 'd'
      executableDigest = "sha256:" ++ replicate 64 'a'
  writeFile configuration (config "fixture")
  writeFile otherConfiguration (config "other")
  projection <- readBootstrapProjection configuration >>= either (fail . show) pure
  otherProjection <- readBootstrapProjection otherConfiguration >>= either (fail . show) pure
  device <- maybe (fail "device") pure (Observed.mkStorageDeviceId "fixture")
  sufficient <- either fail pure (Observed.mkObservedHostRoot (Capacity.ResourceVector 4000 8192 16384 16384) device device)
  insufficient <- either fail pure (Observed.mkObservedHostRoot (Capacity.ResourceVector 1000 8192 16384 16384) device device)
  domain <- maybe (fail "domain") pure (Identity.hostManagerDomain "11111111-1111-1111-1111-111111111111" (replicate 32 'a') ":1.42" 1000 1234 5678)
  now <- getMonotonicTimeNSec
  let second = 1000000000
  window <- maybe (fail "window") pure (Identity.hostExecutionWindow (now + 60 * second) (now + 40 * second) (now + 45 * second) (now + 55 * second) (now + 58 * second))
  key <- maybe (fail "key") pure (kindControllerOperationKey operation)
  request <- either (fail . show) pure (mkKindControllerRequest projection operation executableDigest domain window)
  result <- prepareKindFamilyControllerFromObserved sufficient projection request
  prepared <- either (fail . show) pure result
  let intent = kindFamilyIntent prepared
  unless (Family.hostOperationKind intent == Identity.KindController && Family.hostOperationKey intent == key && Family.hostOperationWindow intent == window) (fail "prepared identity changed")
  mismatch <- prepareKindFamilyControllerFromObserved sufficient otherProjection request
  case mismatch of Left KindFamilyPreparationBindingRefused -> pure (); _ -> fail "foreign scope accepted"
  recovery <- either (fail . show) pure (mkProbeRecoveryRequest request (replicate 32 'e') "12345678-1234-1234-1234-123456789abc")
  recoveryKey <- maybe (fail "recovery key") pure (kindProbeRecoveryKey operation (replicate 32 'e'))
  recoveryPrepared <- prepareKindProbeRecoveryControllerFromObserved sufficient projection recovery >>= either (fail . show) pure
  let recoveryIntent = kindFamilyIntent recoveryPrepared
  unless (Family.hostOperationKind recoveryIntent == Identity.KindController && Family.hostOperationKey recoveryIntent == recoveryKey
    && Family.hostOperationWindow recoveryIntent == window && recoveryKey /= key) (fail "recovery identity changed")
  recoveryMismatch <- prepareKindProbeRecoveryControllerFromObserved sufficient otherProjection recovery
  case recoveryMismatch of Left KindFamilyPreparationBindingRefused -> pure (); _ -> fail "foreign recovery scope accepted"
  recoveryShortfall <- prepareKindProbeRecoveryControllerFromObserved insufficient projection recovery
  case recoveryShortfall of Left (KindFamilyPreparationCapacityRefused _) -> pure (); _ -> fail "underfunded recovery accepted"
  verifierCoordinates <- either (fail . show) pure (mkProbeRecoveryRequest request (replicate 32 'f') "12345678-1234-1234-1234-123456789abc")
  verifier <- either (fail . show) pure (mkProbeAttemptVerifierRequest verifierCoordinates (replicate 32 'e'))
  verifierKey <- maybe (fail "verifier key") pure (kindProbeRecoveryKey operation (replicate 32 'f'))
  verifierPrepared <- prepareKindProbeVerifierControllerFromObserved sufficient projection verifier >>= either (fail . show) pure
  isolated <- either (fail . show) pure (mkIsolatedProbeVerifierRequest verifierCoordinates (replicate 32 'e'))
  successor <- either (fail . show) pure (mkProbeSuccessorRequest isolated (replicate 32 'c'))
  parentCoordinates <- either (fail . show) pure (mkProbeRecoveryRequest request (replicate 32 'c') "12345678-1234-1234-1234-123456789abc")
  parentVerifier <- either (fail . show) pure (mkIsolatedProbeVerifierRequest parentCoordinates (replicate 32 'e'))
  foreignController <- either (fail . show) pure (mkKindControllerRequest otherProjection operation executableDigest domain window)
  foreignCoordinates <- either (fail . show) pure (mkProbeRecoveryRequest foreignController (replicate 32 'f') "12345678-1234-1234-1234-123456789abc")
  foreignVerifier <- either (fail . show) pure (mkIsolatedProbeVerifierRequest foreignCoordinates (replicate 32 'e'))
  foreignSuccessor <- either (fail . show) pure (mkProbeSuccessorRequest foreignVerifier (replicate 32 'c'))
  unless (decodeProbeSuccessorRequest projection operation (encodeProbeSuccessorRequest successor) == Right successor
    && probeSuccessorPredecessorId successor == replicate 32 'c'
    && validProbeSuccessorChain parentVerifier [successor]
    && not (validProbeSuccessorChain parentVerifier [successor, successor])
    && not (validProbeSuccessorChain isolated [successor])
    && not (validProbeSuccessorChain parentVerifier [foreignSuccessor])
    && either (const True) (const False) (mkProbeSuccessorRequest verifier (replicate 32 'c'))
    && either (const True) (const False) (mkProbeSuccessorRequest isolated (replicate 32 'f')))
    (fail "successor predecessor binding changed")
  unless (decodeProbeAttemptVerifierRequest projection operation (encodeProbeAttemptVerifierRequest verifier) == Right verifier
    && decodeProbeAttemptVerifierRequest projection operation (encodeProbeAttemptVerifierRequest isolated) == Right isolated
    && not (probeVerifierIsIsolated verifier) && probeVerifierIsIsolated isolated) (fail "verifier version binding changed")
  isolatedPrepared <- prepareKindProbeVerifierControllerFromObserved sufficient projection isolated >>= either (fail . show) pure
  unless (Family.hostOperationKind (kindFamilyIntent isolatedPrepared) == Identity.KindProbeVerifierController
    && Identity.hostControllerKindSliceName Identity.KindProbeVerifierController /= Identity.hostControllerKindSliceName Identity.KindController) (fail "isolated verifier shares predecessor identity")
  successorPrepared <- prepareKindProbeSuccessorControllerFromObserved sufficient projection successor >>= either (fail . show) pure
  unless (Family.hostOperationKind (kindFamilyIntent successorPrepared) == Identity.KindProbeSuccessorController
    && Family.hostOperationKey (kindFamilyIntent successorPrepared) == verifierKey) (fail "successor preparation identity changed")
  successorMismatch <- prepareKindProbeSuccessorControllerFromObserved sufficient otherProjection successor
  case successorMismatch of Left KindFamilyPreparationBindingRefused -> pure (); _ -> fail "foreign successor scope accepted"
  let verifierIntent = kindFamilyIntent verifierPrepared
  unless (Family.hostOperationKind verifierIntent == Identity.KindController && Family.hostOperationKey verifierIntent == verifierKey
    && Family.hostOperationWindow verifierIntent == window && verifierKey /= recoveryKey) (fail "verifier identity changed")
  verifierMismatch <- prepareKindProbeVerifierControllerFromObserved sufficient otherProjection verifier
  case verifierMismatch of Left KindFamilyPreparationBindingRefused -> pure (); _ -> fail "foreign verifier scope accepted"
  verifierShortfall <- prepareKindProbeVerifierControllerFromObserved insufficient projection verifier
  case verifierShortfall of Left (KindFamilyPreparationCapacityRefused _) -> pure (); _ -> fail "underfunded verifier accepted"
  shortfall <- prepareKindFamilyControllerFromObserved insufficient projection request
  case shortfall of Left (KindFamilyPreparationCapacityRefused _) -> pure (); _ -> fail "underfunded capacity accepted"
  let past = now - 100 * second
  expiredWindow <- maybe (fail "expired window") pure (Identity.hostExecutionWindow (past + 60 * second) (past + 40 * second) (past + 45 * second) (past + 55 * second) (past + 58 * second))
  expiredRequest <- either (fail . show) pure (mkKindControllerRequest projection operation executableDigest domain expiredWindow)
  expired <- prepareKindFamilyControllerFromObserved sufficient projection expiredRequest
  case expired of Left (KindFamilyPreparationIntentRefused Family.HostOperationExpired) -> pure (); _ -> fail "expired original window accepted"
  putStrLn "PASS kind family preparation: identity, scope, capacity and original window"
