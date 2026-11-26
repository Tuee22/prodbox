{-# LANGUAGE ImportQualifiedPost #-}

module Main (main) where

import Control.Monad (unless)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Prodbox.Control.KindController
  ( KindFamilyParentOutcome (..)
  , KindFamilyPostAction (..)
  , KindFamilyWorkOutcome (..)
  )
import Prodbox.Control.KindControllerInput (KindControllerInputOutcome (..))
import Prodbox.Control.KindControllerReceipt qualified as Receipt
import Prodbox.Control.KindFamilyDispatcher (summarizeFamilyResult)
import Prodbox.Control.KindFamilyRecovery qualified as Recovery
import Prodbox.Control.KindLease (KindOperationOutcome (..))
import Prodbox.Control.KindNetworkProbeRecord (ProbeRecordWrite (..))
import Prodbox.Control.NetworkEnforcement
  ( EnforcementCleanup (..)
  , EnforcementOutcome (..)
  , ProbeAttemptReadbackOutcome (..)
  , ProbeRecoveryOutcome (..)
  , confirmAttemptedProbeAbsenceWith
  , recoverRecordedProbeWith
  , withProbeRecordAdmission
  )
import Prodbox.Control.NodeArchive (InspectedArchiveResult (..), NodeArchiveObservation (..))
import Prodbox.Control.Reconcile (ImageAttemptFailure (..), ReconcileOutcome (..))
import Prodbox.Subprocess.HostControllerInputs qualified as HostInputs
import Prodbox.Subprocess.HostOperationFamily qualified as HostFamily
import Prodbox.Subprocess.HostOperationRetirement qualified as Retirement

main :: IO ()
main = do
  clock <- newIORef 0
  attempts <- newIORef (0 :: Int)
  let live =
        Recovery.KindFamilyRetirementRefused
          (Recovery.KindFamilyRecoveryRetirementRefused Retirement.RetirementKernelPresent)
      refused = Recovery.KindFamilyRetirementRefused Recovery.KindFamilyRecoveryRequestMissing
      delay micros = modifyIORef' clock (+ fromIntegral micros * 1000)
      observe = do
        count <- atomicModifyIORef' attempts (\n -> (n + 1, n))
        pure (if count == 0 then live else refused :: Recovery.KindFamilyRetirementOutcome ())
  result <- Recovery.awaitKindFamilyCompletionWith (readIORef clock) delay 1000000000 observe
  count <- readIORef attempts
  unless (result == Recovery.KindFamilyCompletionObserved refused && count == 2) $
    fail "live family was not retried or uncertainty was hidden"
  writeIORef clock 0
  writeIORef attempts 0
  let observeLease = do
        current <- atomicModifyIORef' attempts (\n -> (n + 1, n))
        pure
          ( if current == 0
              then Recovery.KindFamilyRetirementLeaseUnconfirmed
              else refused :: Recovery.KindFamilyRetirementOutcome ()
          )
  leaseResult <-
    Recovery.awaitKindFamilyCompletionWith (readIORef clock) delay 1000000000 observeLease
  unless (leaseResult == Recovery.KindFamilyCompletionObserved refused) $
    fail "unconfirmed lease was treated as a settled family"
  writeIORef clock 0
  expired <-
    Recovery.awaitKindFamilyCompletionWith
      (readIORef clock)
      delay
      300000000
      (pure live :: IO (Recovery.KindFamilyRetirementOutcome ()))
  unless (expired == Recovery.KindFamilyCompletionDeadline (Just live)) $
    fail "live family did not terminate at the deadline with its last observation"
  let imageFailure =
        KindInputCompleted
          ( Right
              ( KindFamilyParentCompleted
                  (KindFamilyWorkPrerequisitesUnconfirmed (ReconcileImageNotObserved "operation" "detail"))
              )
          )
  unless
    ( summarizeFamilyResult imageFailure
        == Receipt.FamilyResult
          Receipt.FamilyWorkerNotObserved
          Receipt.FamilyWorkerNotStarted
          Receipt.FamilyParentComplete
          Receipt.FamilyInputComplete
          Receipt.FamilyPostImageObservationFailed
          Receipt.FamilyPostNotStarted
    )
    $ fail "image observation failure lost its bounded diagnostic stage"
  let changedInput =
        KindInputChangedAfter
          ( Right
              ( KindFamilyParentCompleted
                  ( KindFamilyWorkPrerequisitesUnconfirmed
                      (ReconcileImageAttempt "operation" "detail" ImageAttemptResultUnconfirmed)
                  )
              )
          )
          ( HostFamily.HostOperationInputsRefused
              (HostInputs.ControllerInputChanged HostInputs.ControllerRequest)
          )
  unless
    ( summarizeFamilyResult changedInput
        == Receipt.FamilyResult
          Receipt.FamilyWorkerNotObserved
          Receipt.FamilyWorkerNotStarted
          Receipt.FamilyParentComplete
          Receipt.FamilyInputChanged
          Receipt.FamilyPostImageResultUnconfirmed
          Receipt.FamilyPostNotStarted
    )
    $ fail "changed input lost its bounded closing disposition"
  let probeFailure =
        KindInputCompleted
          ( Right
              ( KindFamilyParentCompleted
                  ( KindFamilyWorkObserved
                      (InspectedArchiveRefused NodeArchiveNotDeclared)
                      ( Just
                          ( KindOperationCallbackReturned
                              ( KindFamilyPostProbe
                                  (EnforcementOutcome Nothing (Just "probe intent not recorded: test") EnforcementCleanupNotStarted)
                                  True
                              )
                          )
                      )
                  )
              )
          )
  unless
    ( summarizeFamilyResult probeFailure
        == Receipt.FamilyResult
          Receipt.FamilyWorkerUnconfirmed
          Receipt.FamilyWorkerComplete
          Receipt.FamilyParentComplete
          Receipt.FamilyInputComplete
          Receipt.FamilyPostProbeIntentRefused
          Receipt.FamilyPostLeaseComplete
    )
    $ fail "probe intent refusal lost its bounded diagnostic stage"
  calls <- newIORef (0 :: Int)
  let record = modifyIORef' calls (+ 1) >> pure True
  refusedRecord <- withProbeRecordAdmission (pure False) record
  firstCount <- readIORef calls
  unless (not refusedRecord && firstCount == 0) (fail "probe record ran without initial admission")
  checks <- newIORef (0 :: Int)
  let changes = atomicModifyIORef' checks (\n -> (n + 1, n == 0))
  changed <- withProbeRecordAdmission changes record
  lastCount <- readIORef calls
  unless (not changed && lastCount == 1) (fail "probe record hid changed closing admission")
  accepted <- withProbeRecordAdmission (pure True) record
  unless accepted (fail "stable probe admission was refused")
  let operation = replicate 32 'd'
      namespace = "prodbox-netcheck-" ++ take 12 operation
      uid = "12345678-1234-1234-1234-123456789abc"
      control = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      empty = "{\"apiVersion\":\"v1\",\"kind\":\"NamespaceList\",\"items\":[]}"
      execute arguments _ = pure $ case arguments of
        ["get", "namespace", name, "-o", _] | name == namespace -> Right (1, "")
        ["get", "namespace", "kube-system", "-o", _] -> Right (0, control)
        "get" : "namespaces" : _ -> Right (0, empty)
        _ -> Left "unexpected request"
  removed <- newIORef False
  absence <-
    recoverRecordedProbeWith
      operation
      namespace
      uid
      (pure True)
      execute
      (\_ -> fail "an absent namespace attempted deletion")
      (\_ _ -> fail "an absent namespace recorded a delete failure")
      (\_ -> writeIORef removed True >> pure ProbeRecorded)
  receipt <- readIORef removed
  unless
    (absence == ProbeRecoveryCompleted && receipt)
    (fail "controlled namespace absence was not recorded")
  writeIORef removed False
  let genericList = "{\"apiVersion\":\"v1\",\"kind\":\"List\",\"items\":[]}"
      genericExecute arguments input = case arguments of
        "get" : "namespaces" : _ -> pure (Right (0, genericList))
        _ -> execute arguments input
  genericAbsence <-
    recoverRecordedProbeWith
      operation
      namespace
      uid
      (pure True)
      genericExecute
      (\_ -> fail "an absent namespace attempted deletion")
      (\_ _ -> fail "an absent namespace recorded a delete failure")
      (\_ -> writeIORef removed True >> pure ProbeRecorded)
  genericReceipt <- readIORef removed
  unless
    (genericAbsence == ProbeRecoveryCompleted && genericReceipt)
    (fail "kubectl generic empty List was not accepted")
  writeIORef removed False
  successorReadback <-
    confirmAttemptedProbeAbsenceWith
      operation
      namespace
      uid
      (replicate 32 'e')
      (replicate 32 'f')
      (pure True)
      genericExecute
      (\_ _ _ -> writeIORef removed True >> pure ProbeRecorded)
  successorReceipt <- readIORef removed
  unless
    (successorReadback == ProbeAttemptReadbackRecorded && successorReceipt)
    (fail "successor generic List readback was not recorded")
  writeIORef removed False
  let noControl arguments input = case arguments of
        ["get", "namespace", "kube-system", "-o", _] -> pure (Left "unavailable")
        _ -> genericExecute arguments input
  missingControl <-
    confirmAttemptedProbeAbsenceWith
      operation
      namespace
      uid
      (replicate 32 'e')
      (replicate 32 'f')
      (pure True)
      noControl
      (\_ _ _ -> writeIORef removed True >> pure ProbeRecorded)
  missingControlReceipt <- readIORef removed
  unless
    (missingControl == ProbeAttemptReadbackAbsenceUnconfirmed && not missingControlReceipt)
    (fail "successor accepted an unavailable positive control")
  mapM_
    ( \bad -> do
        writeIORef removed False
        let invalidExecute arguments input = case arguments of
              "get" : "namespaces" : _ -> pure (Right (0, bad))
              _ -> execute arguments input
        invalid <-
          recoverRecordedProbeWith
            operation
            namespace
            uid
            (pure True)
            invalidExecute
            (\_ -> fail "invalid inventory attempted deletion")
            (\_ _ -> fail "invalid inventory recorded a delete failure")
            (\_ -> writeIORef removed True >> pure ProbeRecorded)
        invalidReceipt <- readIORef removed
        unless
          (invalid == ProbeRecoveryIdentityUnconfirmed && not invalidReceipt)
          (fail "invalid or nonempty generic list was accepted")
    )
    [ "{\"apiVersion\":\"v1\",\"kind\":\"List\",\"items\":[{}]}"
    , "{\"apiVersion\":\"v2\",\"kind\":\"List\",\"items\":[]}"
    , "{\"apiVersion\":\"v1\",\"kind\":\"PodList\",\"items\":[]}"
    , "{\"apiVersion\":\"v1\",\"kind\":\"List\"}"
    ]
  writeIORef removed False
  let blind arguments input = case arguments of
        "get" : "namespaces" : _ -> pure (Left "unavailable")
        _ -> execute arguments input
  uncertain <-
    recoverRecordedProbeWith
      operation
      namespace
      uid
      (pure True)
      blind
      (\_ -> fail "uncertain namespace attempted deletion")
      (\_ _ -> fail "uncertain namespace recorded a delete failure")
      (\_ -> writeIORef removed True >> pure ProbeRecorded)
  receiptAfter <- readIORef removed
  unless
    (uncertain == ProbeRecoveryIdentityUnconfirmed && not receiptAfter)
    (fail "unobservable absence was accepted")
  putStrLn "kind family bounded completion wait passed"
