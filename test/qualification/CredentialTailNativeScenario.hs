{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module CredentialTailNativeScenario
  ( BorrowedRetirement
  , checkCredentialTail
  , verifyBorrowedRetirement
  ) where

import Control.Concurrent.Async (link, withAsync)
import Control.Monad (unless, when)
import CredentialTailMockKubectl (serveMockCompletion)
import CredentialTailWireFixture
import Data.Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isLeft, isRight)
import Data.IORef
import Data.Text qualified as Text
import Prodbox.Aws.Region (canonicalRegressionAwsRegion)
import Prodbox.ControlPlane.AuthorityBackupReconcileProduction
  ( GenesisAwsAdminIntentParameters (..)
  )
import Prodbox.ControlPlane.OperationCredentialRetirement
import Prodbox.ControlPlane.TargetMaterialEndpoint (TargetMaterialObservation (..))
import Prodbox.ControlPlane.TargetSecretAgentExecution (mkTargetAgentIdentity)
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminCoordinator
  ( AwsAdminCoordinatorError (AwsAdminCoordinatorAbsenceUnobservable, AwsAdminCoordinatorStillPresent)
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminKubernetes
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit (mkLifecycleProviderIamParameters)
import Prodbox.Lifecycle.CredentialProvisioner.HarnessCredential
import Prodbox.Lifecycle.CredentialProvisioner.KubernetesJob
  ( CredentialProvisionerJobConnection (..)
  )
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Lifecycle.Teardown.EphemeralKubectl
import Prodbox.Settings (Credentials (..))
import Prodbox.Subprocess (OperationSubprocesses)
import System.Directory (createDirectory, doesFileExist, removeFile)
import System.Environment (getExecutablePath)
import System.FilePath (takeDirectory, (</>))
import System.Posix.Files (setFileMode)

data BorrowedRetirement
  = BorrowedRetirement
      !(IO (Either OperationCredentialRetirementError HarnessCredentialRevocationEvidence))
      !(IO (Int, Int))

verifyBorrowedRetirement :: BorrowedRetirement -> IO ()
verifyBorrowedRetirement (BorrowedRetirement run snapshot) = do
  before <- snapshot
  result <- run
  case result of
    Left (RetirementBoundaryRefused _) -> pure ()
    _ -> fail "escaped credential tail did not refuse its closed home capability"
  after <- snapshot
  unless (before == after) (fail "escaped credential tail issued an effect")

checkCredentialTail
  :: String
  -> AuthorityTime
  -> FilePath
  -> OperationSubprocesses
  -> IORef (Maybe BorrowedRetirement)
  -> IO Value
checkCredentialTail mode deadline configuration owned borrowed = do
  let directory = takeDirectory configuration </> "credential-api"
  createDirectory directory
  setFileMode directory 0o700
  writeFile (directory </> "target-present") "synthetic target metadata"
  writeFile (directory </> "iam-identity-present") "synthetic IAM identity"
  when
    (mode `elem` ["cleanup-held", "cleanup-released"])
    (writeFile (directory </> "hold-job") "simulate non-converging foreground deletion")
  when
    (mode == "empty-attach")
    (writeFile (directory </> "empty-attach") "simulate empty successful attach")
  fixture <- newCredentialWireFixture deadline directory metadata CredentialAgentHealthy
  executable <- getExecutablePath
  projection <- require (prepareEmbeddedHomeKubeconfig embeddedHome)
  iam <-
    require
      (mkLifecycleProviderIamParameters canonicalRegressionAwsRegion "123456789012" "prodbox-provider-role")
  agent <- require (mkTargetAgentIdentity ("home@sha256:" <> Text.replicate 64 "b"))
  lineage <- require (mkHarnessCredentialLineage "all" (BS.replicate 32 1))
  let parameters =
        GenesisAwsAdminIntentParameters
          iam
          imageDigest
          "home"
          "http://lifecycle-authority.lifecycle-authority.svc:8600"
          agent
          deadline
      credentials =
        Credentials
          "fixture-admin-access-key-1"
          "fixture-admin-secret-access-key-1"
          Nothing
          canonicalRegressionAwsRegion
      environment =
        [ ("PATH", "/usr/bin:/bin")
        , ("LC_ALL", "C")
        , ("GHCRTS", "-M16777216b -N1")
        , ("CREDENTIAL_FIXTURE_DIRECTORY", directory)
        ]
      connection =
        CredentialProvisionerJobConnection
          Nothing
          "/"
          (Just "system:serviceaccount:lifecycle-authority:prodbox-control-plane-test-harness")
      kubeEvents = lines <$> readFile (directory </> "kube-events")
      snapshot = do
        events <- kubeEvents
        frames <- credentialWireFrameCount fixture
        pure (length events, frames)
  inputs <-
    require (mkOperationCredentialRetirementInputs deadline parameters iam lineage credentials)
  withAsync (serveMockCompletion fixture directory) $ \service -> do
    link service
    withOperationHomeKubectl owned executable environment (Just "/") projection $ \available -> do
      home <- require available
      boundary <-
        require
          =<< operationAwsAdminKubernetesBoundary home connection imageReference oneShotAwsAdminJobResources
      let run =
            runOperationCredentialRetirement
              owned
              inputs
              (credentialWireAuthority fixture)
              (credentialWireAgent fixture)
              boundary
      writeIORef borrowed (Just (BorrowedRetirement run snapshot))
      first <- run
      case first of
        Left cause -> writeFile (directory </> "first-retirement-error") (show cause)
        Right _ -> pure ()
      if mode `elem` ["cleanup-held", "cleanup-released"]
        then case first of
          Left
            (RetirementCoordinateFailed (OperationAwsAdminCoordinateRefused AwsAdminCoordinatorStillPresent)) -> pure ()
          Left
            ( RetirementCoordinateFailed
                ( OperationAwsAdminCoordinateRefused
                    (AwsAdminCoordinatorAbsenceUnobservable "AwsAdminKubernetesStillPresent")
                  )
              ) -> pure ()
          Left other -> fail ("unexpected first cleanup refusal: " <> show other)
          Right _ -> fail "held Job yielded first retirement evidence"
        else requireSuccess first
      -- The test API recovers; only the canonical owned delete may remove
      -- the retained Job. The original lineage/window and permit stay fixed.
      when (mode == "cleanup-released") (removeFile (directory </> "hold-job"))
      second <- run
      when (mode /= "cleanup-held") (requireSuccess second)
      events <- kubeEvents
      workerEvents <- lines <$> readFile (directory </> "worker-events")
      absent <- doesFileExist (directory </> "job-deleted")
      let count event = length (filter (== event) events)
      unless
        (count "create" == 1 && count "attach" == 1)
        (fail "fixed retirement slot created or ran a second Job")
      unless
        (length (filter (== "destroy-iam-identity") workerEvents) == 1)
        (fail "worker IAM retirement was replayed")
      when
        (mode == "empty-attach")
        (unless (count "logs" == 1) (fail "empty attach did not use owned log recovery"))
      job <- BS.readFile (directory </> "job.json")
      unless
        (not (any (`BS.isInfixOf` job) ["fixture-admin-access-key-1", "fixture-admin-secret-access-key-1"]))
        (fail "administrator credential entered the Job manifest")
      frames <- credentialWireFrameCount fixture
      observations <- credentialWireAgentReadCount fixture
      pure
        ( object
            [ "first_refused" .= isLeft first
            , "retirement_evidence_after_unresolved_job" .= (mode == "cleanup-held" && isRight second)
            , "job_present_after_replay" .= not absent
            , "job_recovered_after_refusal"
                .= (mode == "cleanup-released" && isLeft first && isRight second && absent)
            , "second_succeeded" .= isRight second
            , "second_error" .= either (Just . show) (const Nothing) second
            , "kube_events" .= events
            , "worker_events" .= workerEvents
            , "authenticated_frames" .= frames
            , "agent_reads" .= observations
            , "support_checks"
                .= ( [ ("single-job-and-worker", True)
                     , ("no-admin-material-in-job", True)
                     , ("original-home-capability", True)
                     ]
                       :: [(String, Bool)]
                   )
            ]
        )

imageDigest, imageReference :: Text.Text
imageDigest = "sha256:" <> Text.replicate 64 "a"
imageReference = "127.0.0.1:30080/prodbox/worker:fixture-runtime"

metadata :: TargetMaterialObservation
metadata =
  TargetMaterialObservation
    1
    1
    "vault:v1:lineage"
    "lineage-owner"
    1
    (Text.replicate 64 "a")
    (Text.replicate 64 "b")
    "lineage-pod"
    imageDigest

embeddedHome :: BS.ByteString
embeddedHome =
  Lazy.toStrict
    ( encode
        ( object
            [ "apiVersion" .= ("v1" :: String)
            , "kind" .= ("Config" :: String)
            , "current-context" .= ("home" :: String)
            , "clusters"
                .= [ object
                       [ "name" .= ("home" :: String)
                       , "cluster"
                           .= object
                             [ "server" .= ("https://127.0.0.1:6443" :: String)
                             , "certificate-authority-data" .= ("fixture-ca" :: String)
                             ]
                       ]
                   ]
            , "contexts"
                .= [ object
                       [ "name" .= ("home" :: String)
                       , "context" .= object ["cluster" .= ("home" :: String), "user" .= ("home" :: String)]
                       ]
                   ]
            , "users"
                .= [ object
                       [ "name" .= ("home" :: String)
                       , "user"
                           .= object
                             [ "client-certificate-data" .= ("fixture-certificate" :: String)
                             , "client-key-data" .= ("fixture-key" :: String)
                             ]
                       ]
                   ]
            ]
        )
    )

requireSuccess :: Either OperationCredentialRetirementError value -> IO ()
requireSuccess = either (fail . show) (const (pure ()))

require :: (Show failure) => Either failure value -> IO value
require = either (fail . show) pure
