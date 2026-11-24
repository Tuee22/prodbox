{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- Pure capacity controls; no manager or provider operation is started.
import Control.Monad (unless)
import Data.Either (isLeft)
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Capacity.HostExecution qualified as Host
import Prodbox.Capacity.ObservedHost qualified as Observed
import Prodbox.Control.KindController (compileKindFamilyControllerPlan)
import Prodbox.Control.SealedTool qualified as Sealed

main :: IO ()
main = do
  device <- maybe (fail "device") pure (Observed.mkStorageDeviceId "fixture-device")
  sufficient <- either fail pure (Observed.mkObservedHostRoot (Capacity.ResourceVector 4000 8192 16384 16384) device device)
  otherDevice <- maybe (fail "other device") pure (Observed.mkStorageDeviceId "other-fixture-device")
  larger <- either fail pure (Observed.mkObservedHostRoot (Capacity.ResourceVector 8000 16384 32768 32768) device otherDevice)
  insufficient <- either fail pure (Observed.mkObservedHostRoot (Capacity.ResourceVector 1000 8192 16384 16384) device device)
  (plan, snapshots) <- either fail pure (compileKindFamilyControllerPlan sufficient)
  otherPlan <- either fail pure (compileKindFamilyControllerPlan larger)
  let transport = Host.hostExecutionTransportLimits plan
  unless (Host.hostTransportCpuUsecPerSec transport == 100000 && Host.hostTransportTasks transport == 8 && Host.hostTransportMemoryBytes transport == 16 * 1048576) (fail "transport reservation changed")
  unless (Host.hostExecutionRuntimeMemory plan == Sealed.sealedToolRuntimePlan (Sealed.kindWorkerKindBudget snapshots)) (fail "worker memory plan diverged")
  unless ((plan, snapshots) == otherPlan) (fail "sufficient host observations changed the declared plan")
  unless (isLeft (compileKindFamilyControllerPlan insufficient)) (fail "underfunded host accepted")
  putStrLn "PASS kind family transport budget, snapshot binding and underfunded host refusal"
