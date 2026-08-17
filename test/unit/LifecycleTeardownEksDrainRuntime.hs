{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownEksDrainRuntime
  ( lifecycleTeardownEksDrainRuntimeSuite
  )
where

import Data.List (isInfixOf, isPrefixOf, tails)
import Data.Text qualified as Text
import EksClientAuthProjectionFixture (testEksClientAuthProjection)
import Prodbox.ControlPlane.EksClientAuthProjection
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (ProviderIntentExecutionObserved)
  )
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.K8sDrain
import Prodbox.Lifecycle.ProviderWorker.ProviderWork (providerIntentCoordinate)
import Prodbox.Lifecycle.Teardown.AwsEksAdapter
import Prodbox.Lifecycle.Teardown.EksDrainRuntime
import Prodbox.Lifecycle.Teardown.EksDrainSession
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (ownerModes, setFileMode)
import TestSupport

lifecycleTeardownEksDrainRuntimeSuite :: SuiteBuilder ()
lifecycleTeardownEksDrainRuntimeSuite =
  describe "Sprint 7.36 ephemeral exact EKS drain runtime" $ do
    it "observes the live UID and drains through one exact ephemeral kubeconfig" $
      withFakeKubectl $ \directory kubectl logPath -> do
        result <- runRuntime kubectl directory [] fixtureVerified
        case result of
          Left err -> expectationFailure (show err)
          Right completed -> do
            eksDrainRuntimeDrainResult completed `shouldBe` DrainSucceeded
            eksClusterUidText
              (eksDrainSessionClusterUid (eksDrainRuntimeSession completed))
              `shouldBe` fixtureUid
            eksKubernetesIdentityResult
              (eksDrainRuntimeKubernetesIdentity completed)
              `shouldBe` EksKubernetesIdentityPresent fixtureUid
            show completed `shouldNotContain` "bearer-secret"
        logContents <- readFile logPath
        logContents `shouldContain` "get namespace kube-system"
        logContents `shouldContain` "cluster-info"
        logContents `shouldContain` "delete services"
        logContents `shouldContain` "delete ingresses"
        everyInvocationTargetsOneKubeconfig logContents `shouldBe` True
        logContents `shouldNotContain` "bearer-secret"

    it "strips hostile ambient KUBECONFIG and never falls back to it" $
      withFakeKubectl $ \directory kubectl logPath -> do
        let hostile = directory </> "unrelated-admin-kubeconfig"
        writeFile hostile "must-not-be-read"
        result <-
          runRuntime
            kubectl
            directory
            [("KUBECONFIG", hostile)]
            fixtureVerified
        result `shouldSatisfy` isRight
        logContents <- readFile logPath
        logContents `shouldContain` "ENV_KUBECONFIG=<unset>"
        logContents `shouldNotContain` hostile
        readFile hostile `shouldReturn` "must-not-be-read"

    it "turns UID probe failure into unobservable evidence and performs no drain mutation" $
      withFakeKubectl $ \directory kubectl logPath -> do
        result <-
          runRuntime
            kubectl
            directory
            [("FAKE_FAIL_UID", "1")]
            fixtureVerified
        case result of
          Left (EksDrainRuntimeIdentityRefused identity (EksDrainKubernetesIdentityNotPresent _)) ->
            case eksKubernetesIdentityResult identity of
              EksKubernetesIdentityUnobservable _ -> pure ()
              other -> expectationFailure ("unexpected identity result: " ++ show other)
          other -> expectationFailure ("unexpected runtime result: " ++ show other)
        logContents <- readFile logPath
        logContents `shouldContain` "get namespace kube-system"
        logContents `shouldNotContain` "delete services"
        logContents `shouldNotContain` "delete ingresses"

    it "refuses exact Provider absence before invoking kubectl" $
      withFakeKubectl $ \directory kubectl logPath -> do
        result <- runRuntime kubectl directory [] fixtureAbsentVerified
        case result of
          Left
            ( EksDrainRuntimeExactObservationInvalid
                (EksDrainObservationNotPresent (ExactResourceAbsent _))
              ) -> pure ()
          other -> expectationFailure ("unexpected runtime result: " ++ show other)
        doesFileExist logPath `shouldReturn` False

withFakeKubectl
  :: (FilePath -> FilePath -> FilePath -> IO value)
  -> IO value
withFakeKubectl action =
  withSystemTempDirectory "prodbox-eks-drain-runtime-test" $ \directory -> do
    let executable = directory </> "kubectl"
        logPath = directory </> "kubectl.log"
    writeFile executable fakeKubectlScript
    setFileMode executable ownerModes
    action directory executable logPath

fakeKubectlScript :: String
fakeKubectlScript =
  unlines
    [ "#!/bin/sh"
    , "printf 'ENV_KUBECONFIG=%s ARGS=%s\\n' \"${KUBECONFIG-<unset>}\" \"$*\" >> \"$FAKE_KUBECTL_LOG\""
    , "case \"$*\" in"
    , "  *\"get namespace kube-system\"*)"
    , "    if [ \"${FAKE_FAIL_UID-0}\" = 1 ]; then"
    , "      printf 'identity probe refused\\n' >&2"
    , "      exit 23"
    , "    fi"
    , "    printf 'eks-kube-system-uid-7'"
    , "    ;;"
    , "esac"
    , "exit 0"
    ]

runRuntime
  :: FilePath
  -> FilePath
  -> [(String, String)]
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
  -> IO (Either EksDrainRuntimeError EksDrainRuntimeResult)
runRuntime kubectl directory extraEnvironment verified = do
  let environment =
        ("FAKE_KUBECTL_LOG", directory </> "kubectl.log") : extraEnvironment
  runEksDrainWithProjectionUsing
    kubectl
    environment
    (Just directory)
    1_000
    1_500
    fixtureOperation
    fixtureScope
    verified
    fixtureProjection
    (DrainTimeout 1)

everyInvocationTargetsOneKubeconfig :: String -> Bool
everyInvocationTargetsOneKubeconfig contents =
  all hasExactBinding (filter (not . null) (lines contents))
 where
  hasExactBinding line =
    length (occurrences "--kubeconfig" line) == 1
      && "prodbox-eks-drain-" `isInfixOf` line
  occurrences needle value =
    [ ()
    | suffix <- tails value
    , needle `isPrefixOf` suffix
    ]

fixtureVerified :: VerifiedAwsEksObservation 'ObserveEksForDecision
fixtureVerified = verifiedFor "eks-cluster-arn:" fixtureArn

fixtureAbsentVerified :: VerifiedAwsEksObservation 'ObserveEksForDecision
fixtureAbsentVerified = verifiedFor "" "registered EKS cluster is absent"

verifiedFor
  :: Text.Text
  -> Text.Text
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
verifiedFor prefix evidence =
  let request = mustRight (mkAwsEksDecisionObservationRequest (ObservationRevision 7) fixtureScope)
   in case
        decodeAwsEksObservation
          request
          ( Right
              ( ProviderIntentExecutionObserved
                  (providerIntentCoordinate (awsEksObservationRequestProviderIntent request))
                  (prefix <> evidence)
              )
          ) of
        AwsEksObservationDecoded verified -> verified
        AwsEksObservationRejected err _ -> error (show err)

fixtureProjection :: EksClientAuthProjection
fixtureProjection =
  case testEksClientAuthProjection
    "111122223333"
    "ca-central-1"
    fixtureClusterName
    fixtureArn
    "https://example.eks.amazonaws.com"
    "Y2EtZGF0YQ=="
    "bearer-secret"
    1_800 of
    Left err -> error (show err)
    Right projection -> projection

fixtureScope :: ObservationEvidenceScope
fixtureScope =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope "cleanup-run/eks-drain-runtime")
    (LinuxRke2FoundationId "home-linux-rke2")
    (Just (AwsScope (AwsAccountId "111122223333") (AwsRegion "ca-central-1")))
    ReconcileDesiredAbsent

fixtureArn :: Text.Text
fixtureArn =
  "arn:aws:eks:ca-central-1:111122223333:cluster/aws-eks-test-cluster"

fixtureUid :: Text.Text
fixtureUid = "eks-kube-system-uid-7"

fixtureClusterName :: Text.Text
fixtureClusterName = "aws-eks-test-cluster"

fixtureOperation :: CleanupOperationId
fixtureOperation = case mkCleanupOperationId "cleanup-run/eks-drain-runtime/drain" of
  Left err -> error (Text.unpack err)
  Right operation -> operation

isRight :: Either left right -> Bool
isRight result = case result of
  Right _ -> True
  Left _ -> False

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
