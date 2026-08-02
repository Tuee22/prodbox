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
      classifyHelmReleaseStatus (output ExitSuccess "{}" "")
        `shouldBe` HelmReleasePresent
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
      observations <- newIORef [HelmReleasePresent, HelmReleaseAbsent]
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
      observations <- newIORef [HelmReleasePresent, HelmReleasePresent]
      result <-
        reconcileHelmReleaseAbsentWith
          HelmReleaseHooks
            { helmObserve = pop observations
            , helmUninstall = pure (Left "helm failed")
            }
      result
        `shouldBe` Left (HelmReleaseUninstallFailed "helm failed" HelmReleasePresent)

    it "refuses an unobservable initial state and a present postcondition" $ do
      reconcileHelmReleaseAbsentWith
        HelmReleaseHooks
          { helmObserve = pure (HelmReleaseUnobservable "api down")
          , helmUninstall = pure (Right ())
          }
        `shouldReturn` Left (HelmReleaseInitialObservationFailed "api down")
      observations <- newIORef [HelmReleasePresent, HelmReleasePresent]
      reconcileHelmReleaseAbsentWith
        HelmReleaseHooks
          { helmObserve = pop observations
          , helmUninstall = pure (Right ())
          }
        `shouldReturn` Left (HelmReleaseAbsencePostconditionFailed HelmReleasePresent)

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
