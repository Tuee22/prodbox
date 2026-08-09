module HelmRelease (helmReleaseSuite) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Prodbox.Lifecycle.HelmRelease
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))
import TestSupport

helmReleaseSuite :: SuiteBuilder ()
helmReleaseSuite =
  describe "registered Helm release desired-absence reconciliation" $ do
    it "classifies only a successful status as present and an exact not-found as absent" $ do
      classifyHelmReleaseStatus (output ExitSuccess "{\"info\":{\"status\":\"deployed\"}}" "")
        `shouldBe` HelmReleasePresent HelmStatusDeployed
      classifyHelmReleaseStatus (output (ExitFailure 1) "" "Error: release: not found")
        `shouldBe` HelmReleaseAbsent
      classifyHelmReleaseStatus (output (ExitFailure 1) "" "Kubernetes cluster unreachable")
        `shouldBe` HelmReleaseUnobservable "Kubernetes cluster unreachable"

    it "does not mutate when authoritative observation proves absence" $ do
      calls <- newIORef ([] :: [String])
      result <-
        reconcileHelmReleaseAbsentWith
          HelmReleaseHooks
            { helmObserve = modifyIORef' calls (++ ["observe"]) >> pure HelmReleaseAbsent
            , helmUninstall = modifyIORef' calls (++ ["uninstall"]) >> pure (Right ())
            }
      result `shouldBe` Right HelmReleaseAlreadyAbsent
      readIORef calls `shouldReturn` ["observe"]

    it "uninstalls a present release and requires exact absence read-back" $ do
      observations <- newIORef [HelmReleasePresent HelmStatusFailed, HelmReleaseAbsent]
      calls <- newIORef ([] :: [String])
      result <-
        reconcileHelmReleaseAbsentWith
          HelmReleaseHooks
            { helmObserve = do
                modifyIORef' calls (++ ["observe"])
                pop observations
            , helmUninstall = modifyIORef' calls (++ ["uninstall"]) >> pure (Right ())
            }
      result `shouldBe` Right HelmReleaseRemovedAndVerified
      readIORef calls `shouldReturn` ["observe", "uninstall", "observe"]

    it "retains uninstall failure and still re-observes partial effects" $ do
      observations <- newIORef [HelmReleasePresent HelmStatusFailed, HelmReleasePresent HelmStatusFailed]
      result <-
        reconcileHelmReleaseAbsentWith
          HelmReleaseHooks
            { helmObserve = pop observations
            , helmUninstall = pure (Left "helm failed")
            }
      result
        `shouldBe` Left (HelmReleaseUninstallFailed "helm failed" (HelmReleasePresent HelmStatusFailed))

    it "refuses an unobservable initial state and a present postcondition" $ do
      reconcileHelmReleaseAbsentWith
        HelmReleaseHooks
          { helmObserve = pure (HelmReleaseUnobservable "api down")
          , helmUninstall = pure (Right ())
          }
        `shouldReturn` Left (HelmReleaseInitialObservationFailed "api down")
      observations <- newIORef [HelmReleasePresent HelmStatusFailed, HelmReleasePresent HelmStatusFailed]
      reconcileHelmReleaseAbsentWith
        HelmReleaseHooks
          { helmObserve = pop observations
          , helmUninstall = pure (Right ())
          }
        `shouldReturn` Left (HelmReleaseAbsencePostconditionFailed (HelmReleasePresent HelmStatusFailed))

    it "Sprint 3.31: decodes each Helm status to its own constructor" $ do
      -- Seven statuses used to collapse into one constructor because presence
      -- was derived from `helm status`'s EXIT CODE, while `--output json` was
      -- already being requested and `.info.status` discarded.
      let statusJson value = "{\"info\":{\"status\":\"" ++ value ++ "\"}}"
      map
        (classifyHelmReleaseStatus . (\value -> output ExitSuccess (statusJson value) ""))
        [ "deployed"
        , "failed"
        , "pending-install"
        , "pending-upgrade"
        , "pending-rollback"
        , "uninstalling"
        , "uninstalled"
        , "superseded"
        ]
        `shouldBe` map
          HelmReleasePresent
          [ HelmStatusDeployed
          , HelmStatusFailed
          , HelmStatusPendingInstall
          , HelmStatusPendingUpgrade
          , HelmStatusPendingRollback
          , HelmStatusUninstalling
          , HelmStatusUninstalled
          , HelmStatusSuperseded
          ]

    it "Sprint 3.31: an unrecognised status fails closed" $ do
      classifyHelmReleaseStatus (output ExitSuccess "{\"info\":{\"status\":\"marinating\"}}" "")
        `shouldSatisfy` isUnobservableObservation
      classifyHelmReleaseStatus (output ExitSuccess "{}" "")
        `shouldSatisfy` isUnobservableObservation
      classifyHelmReleaseStatus (output ExitSuccess "not json at all" "")
        `shouldSatisfy` isUnobservableObservation

    it "Sprint 3.31: a concurrent writer is refused a permit, not answered by a destroy" $ do
      let coordinate = either (error . show) id (mkHelmReleaseCoordinate "api" "api")
          permitFor status = helmWritePermit coordinate (HelmReleasePresent status)
      permitFor HelmStatusPendingInstall
        `shouldBe` Left (HelmWriteConcurrentOperation HelmStatusPendingInstall)
      permitFor HelmStatusPendingUpgrade
        `shouldBe` Left (HelmWriteConcurrentOperation HelmStatusPendingUpgrade)
      permitFor HelmStatusPendingRollback
        `shouldBe` Left (HelmWriteConcurrentOperation HelmStatusPendingRollback)
      permitFor HelmStatusUninstalling
        `shouldBe` Left (HelmWriteConcurrentOperation HelmStatusUninstalling)
      permitFor HelmStatusDeployed `shouldSatisfy` isRightPermit
      permitFor HelmStatusFailed `shouldSatisfy` isRightPermit
      helmWritePermit coordinate HelmReleaseAbsent `shouldSatisfy` isRightPermit
      helmWritePermit coordinate (HelmReleaseUnobservable "cluster unreachable")
        `shouldBe` Left (HelmWriteUnobservable "cluster unreachable")

    it "Sprint 3.31: the absence reconciler refuses rather than uninstalling" $ do
      -- The exact defect: answering the concurrency error with a destroy deletes
      -- the release another writer is mid-install on.
      calls <- newIORef ([] :: [String])
      result <-
        reconcileHelmReleaseAbsentWith
          HelmReleaseHooks
            { helmObserve =
                modifyIORef' calls (++ ["observe"])
                  >> pure (HelmReleasePresent HelmStatusPendingUpgrade)
            , helmUninstall =
                modifyIORef' calls (++ ["uninstall"]) >> pure (Right ())
            }
      result
        `shouldBe` Left (HelmReleaseWriteRefused (HelmWriteConcurrentOperation HelmStatusPendingUpgrade))
      readIORef calls `shouldReturn` ["observe"]

output :: ExitCode -> String -> String -> ProcessOutput
output exit stdout stderr =
  ProcessOutput
    { processExitCode = exit
    , processStdout = stdout
    , processStderr = stderr
    }

pop :: IORef [HelmReleaseObservation] -> IO HelmReleaseObservation
pop ref = do
  observations <- readIORef ref
  case observations of
    observed : remaining -> modifyIORef' ref (const remaining) >> pure observed
    [] -> pure (HelmReleaseUnobservable "fixture exhausted")

isUnobservableObservation :: HelmReleaseObservation -> Bool
isUnobservableObservation observation = case observation of
  HelmReleaseUnobservable _ -> True
  _ -> False

isRightPermit :: Either HelmWriteRefusal HelmWritePermit -> Bool
isRightPermit = either (const False) (const True)
