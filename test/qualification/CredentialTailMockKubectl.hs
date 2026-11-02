{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- External Kubernetes/IAM/target-store seams for the real owned coordinator.
-- No live provider or cluster is contacted; stdin still crosses the native
-- Go/exec boundary and the worker runs the canonical permit execution algebra.
module CredentialTailMockKubectl (runMockKubectl, serveMockCompletion) where

import Codec.Serialise (deserialiseOrFail, serialise)
import Control.Concurrent (threadDelay)
import Control.Monad (unless, when)
import CredentialTailWireFixture
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef
import Data.List (isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Vector qualified as Vector
import Prodbox.ControlPlane.AwsAdminProvisionerClient
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecutionJournal
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminWorkerProtocol
import Prodbox.Lifecycle.CredentialProvisioner.Execution (AccessKeyInventoryObservation (..))
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial (operatorMaterialOperationIdText)
import Prodbox.Lifecycle.Decommission.Manifest (manifestPublicKeyBytes)
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros, authorityTimeMicros)
import System.Directory (doesFileExist, removeFile, renameFile)
import System.Environment (getEnv)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

runMockKubectl :: [String] -> IO ()
runMockKubectl supplied = do
  directory <- getEnv "CREDENTIAL_FIXTURE_DIRECTORY"
  arguments <- case supplied of
    "--kubeconfig" : configuration
      : "--as=system:serviceaccount:lifecycle-authority:prodbox-control-plane-test-harness"
      : "--namespace"
      : "credential-provisioner"
      : rest -> do
        present <- doesFileExist configuration
        unless present (fail "owned private kubeconfig disappeared")
        pure rest
    _ -> fail "unexpected owned kubectl prefix"
  let logEvent event = appendFile (directory </> "kube-events") (event <> "\n")
      loadJob = BS.readFile (directory </> "job.json") >>= require . eitherDecodeStrict'
      deleted = doesFileExist (directory </> "job-deleted")
      jobAbsent = do
        exists <- doesFileExist (directory </> "job.json")
        gone <- deleted
        pure (not exists || gone)
      json = Lazy.putStr . encode
  case arguments of
    ["create", "--filename=-", "--output=json"] -> do
      logEvent "create"
      body <- BS.getContents
      value <- require (eitherDecodeStrict' body)
      let observed = putAt ["metadata", "uid"] (String "fixture-job-uid") value
      Lazy.writeFile (directory </> "job.json") (encode observed)
      json observed
    ["get", raw] | "--raw=" `isPrefixOf` raw -> do
      if "/serviceaccounts/" `Text.isInfixOf` Text.pack raw
        then do
          logEvent "get-service-account"
          json
            ( object
                ["metadata" .= object ["name" .= workerName, "uid" .= ("fixture-service-account-uid" :: Text)]]
            )
        else do
          logEvent "get-job"
          absent <- jobAbsent
          if absent
            then
              hPutStrLn stderr "Error from server (NotFound): jobs.batch fixture not found"
                >> exitWith (ExitFailure 1)
            else loadJob >>= json
    ["get", "pods", selector, "--output=json"] | "--selector=job-name=" `isPrefixOf` selector -> do
      logEvent "get-pods"
      absent <- jobAbsent
      if absent
        then json (object ["items" .= ([] :: [Value])])
        else do
          job <- loadJob
          json (object ["items" .= [podFor job]])
    ["attach", "--pod-running-timeout=10s", "-i", pod, "--container", "credential-provisioner"] | "pod/" `isPrefixOf` pod -> do
      logEvent "attach"
      frame <- BS.getContents
      runWorker <- require (withAwsAdminWorkerIngress frame (executeWorker directory))
      receipt <- runWorker
      let envelope = encodeAwsAdminWorkerReceiptTextEnvelope receipt
      BS.writeFile (directory </> "receipt-envelope") envelope
      logsOnly <- doesFileExist (directory </> "empty-attach")
      unless logsOnly (BS.putStr ("\n" <> envelope))
    ["logs", pod, "--container", "credential-provisioner"] | "pod/" `isPrefixOf` pod -> do
      logEvent "logs"
      bytes <- BS.readFile (directory </> "receipt-envelope")
      BS.putStr (bytes <> "\n")
    ["delete", raw, "--filename=-"] | "--raw=" `isPrefixOf` raw -> do
      logEvent "delete"
      bytes <- BS.getContents
      options <- require (eitherDecodeStrict' bytes)
      unless
        (at ["preconditions", "uid"] options == String "fixture-job-uid")
        (fail "delete lacked the exact Job UID")
      held <- doesFileExist (directory </> "hold-job")
      unless held (writeFile (directory </> "job-deleted") "exact UID deleted")
    _ -> fail ("unexpected mock Kubernetes command: " <> show arguments)

workerName :: Text
workerName = awsAdminWorkerServiceAccount

podFor :: Value -> Value
podFor job =
  object
    [ "metadata" .= metadata
    , "spec" .= at ["spec", "template", "spec"] job
    , "status"
        .= object
          [ "phase" .= ("Running" :: Text)
          , "containerStatuses"
              .= [ object
                     [ "name" .= ("credential-provisioner" :: Text)
                     , "ready" .= True
                     , "restartCount" .= (0 :: Int)
                     , "imageID" .= image
                     ]
                 ]
          ]
    ]
 where
  name = at ["metadata", "name"] job
  image = case at ["spec", "template", "spec", "containers"] job of
    Array containers -> case Vector.toList containers of
      container : _ -> case at ["image"] container of
        String _ -> String ("containerd://sha256:" <> Text.replicate 64 "a")
        _ -> Null
      [] -> Null
    _ -> Null
  metadata =
    putAt
      ["ownerReferences"]
      ( toJSON
          [ object
              [ "kind" .= ("Job" :: Text)
              , "name" .= name
              , "uid" .= ("fixture-job-uid" :: Text)
              , "controller" .= True
              ]
          ]
      )
      ( putAt
          ["labels", "job-name"]
          name
          ( putAt
              ["name"]
              (String "fixture-worker-pod")
              (putAt ["uid"] (String "fixture-pod-uid") (at ["spec", "template", "metadata"] job))
          )
      )

executeWorker :: FilePath -> SignedAwsAdminPermit -> credentials -> IO AwsAdminWorkerReceipt
executeWorker directory permit _credentials = do
  now <- getPOSIXTime
  require
    ( verifySignedAwsAdminPermit
        (manifestPublicKeyBytes credentialFixtureManifestKey)
        7
        (authorityTimeFromMicros (fromInteger (floor (now * 1000000))))
        permit
    )
  journal <- newIORef (initialAwsAdminExecutionJournal permit)
  let logEvent event = appendFile (directory </> "worker-events") (event <> "\n")
      journalBoundary =
        mkAwsAdminExecutionJournalBoundary
          (Right <$> readIORef journal)
          ( \expected next -> do
              actual <- readIORef journal
              if actual == expected
                then writeIORef journal next >> pure (Right next)
                else pure (Left "fixture worker journal CAS conflict")
          )
      iam =
        mkAwsAdminIamBoundary
          (pure (Right ()))
          (logEvent "observe-keys-absent" >> pure (AccessKeyInventoryObserved []))
          (\_ -> fail "fixture has no key to delete")
          (fail "retirement fixture may not create an access key")
          ( do
              logEvent "destroy-iam-identity"
              present <- doesFileExist (directory </> "iam-identity-present")
              when present (removeFile (directory </> "iam-identity-present"))
              pure (Right ())
          )
          ( do
              logEvent "observe-iam-identity-absent"
              present <- doesFileExist (directory </> "iam-identity-present")
              pure (Right (not present))
          )
          (pure (Right ()))
      delivery =
        mkAwsAdminDeliveryBoundary
          (\_ _ _ -> fail "retirement fixture may not deliver material")
          ( \_ _ -> do
              logEvent "revoke-agent-target"
              present <- doesFileExist (directory </> "target-present")
              when present (removeFile (directory </> "target-present"))
              pure (Right "revoked")
          )
          (\_ _ -> logEvent "observe-agent-target-absent" >> pure (Right Nothing))
  result <- executeAwsAdminPermit journalBoundary iam delivery permit
  receipt <- require result
  let deadline = awsAdminPermitIntentDeadline (signedAwsAdminPermitIntent permit)
      exchange _ _ _ frame = do
        BS.writeFile (directory </> "completion-request.tmp") frame
        renameFile (directory </> "completion-request.tmp") (directory </> "completion-request")
        waitForResponse deadline
        raw <- BS.readFile (directory </> "completion-response")
        response <- require (deserialiseOrFail (Lazy.fromStrict raw))
        pure (Right response)
      waitForResponse end = do
        exists <- doesFileExist (directory </> "completion-response")
        unless exists $ do
          current <- getPOSIXTime
          unless
            (floor (current * 1000000) < toInteger (authorityTimeMicros end))
            (fail "worker completion reached its original deadline")
          threadDelay 1000
          waitForResponse end
      client = awsAdminProvisionerClient (credentialFixtureWorkerClient deadline exchange)
  completed <-
    completeAwsAdminProvisioning
      client
      ( operatorMaterialOperationIdText
          (awsAdminPermitIntentOperationId (signedAwsAdminPermitIntent permit))
      )
      permit
      receipt
  confirmed <- require completed
  logEvent "worker-completion-confirmed"
  pure confirmed

serveMockCompletion :: CredentialWireFixture -> FilePath -> IO ()
serveMockCompletion fixture directory = loop
 where
  loop = do
    pending <- doesFileExist (directory </> "completion-request")
    answered <- doesFileExist (directory </> "completion-response")
    when (pending && not answered) $ do
      frame <- BS.readFile (directory </> "completion-request")
      response <- credentialWireHandleCompletion fixture frame
      Lazy.writeFile (directory </> "completion-response.tmp") (serialise response)
      renameFile (directory </> "completion-response.tmp") (directory </> "completion-response")
    threadDelay 1000
    loop

at :: [Text] -> Value -> Value
at [] value = value
at (key : rest) (Object values) = maybe Null (at rest) (KeyMap.lookup (Key.fromText key) values)
at _ _ = Null

putAt :: [Text] -> Value -> Value -> Value
putAt [] new _ = new
putAt (key : rest) new old =
  let values = case old of Object fields -> fields; _ -> KeyMap.empty
      previous = maybe Null id (KeyMap.lookup (Key.fromText key) values)
   in Object (KeyMap.insert (Key.fromText key) (putAt rest new previous) values)

require :: (Show failure) => Either failure value -> IO value
require = either (fail . show) pure
