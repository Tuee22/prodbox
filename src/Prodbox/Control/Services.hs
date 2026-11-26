{-# LANGUAGE OverloadedStrings #-}

-- | Phase 2 slice: deploy the pinned MinIO and Vault into an already created
-- test environment from local artifacts, then observe both directly. Nothing
-- here pulls from the platform registry or the public edge: the MinIO archive
-- is the repository's source-built bootstrap artifact, Vault is the pinned
-- public image saved to a local archive, and both are imported into the node's
-- containerd and run with a pull policy of Never.
--
-- Order matters. The pinned management policy is proven to be enforced by real
-- sockets before any secret is created; only then is the MinIO bootstrap
-- credential generated (random, never printed, kept in a cluster Secret and a
-- private file under the retained root), the policy installed for the
-- management namespace, the data directories created by the operator and the
-- services applied. Direct status is read through the API server's pod proxy
-- (the services have no host port), not inferred from rollout status.
module Prodbox.Control.Services
  ( ServicesOutcome (..)
  , ServiceStep (..)
  , reconcileServices
  , renderServicesOutcome
  , mcReference
  , observeServices
  , stopServicePods
  , startServicePods
  ) where

import Control.Concurrent (threadDelay)
import Control.Monad (foldM)
import Data.Aeson ((.!=), (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (isInfixOf)
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRootGeneration
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope (scopeKindName, scopeRoot)
import Prodbox.Control.BrokerDeploy (deployBroker, observeBrokerReadiness)
import Prodbox.Control.KindControllerReceipt
  ( ControllerReceiptObservation (ControllerReceiptObserved)
  , observeControllerReceipt
  )
import Prodbox.Control.KindFamilyRecovery
  ( KindFamilyRetirementOutcome (KindFamilyRetirementReturned)
  , verifyKindFamilyRetirement
  , withKindFamilyRetirement
  )
import Prodbox.Control.KindIntent
  ( KindIntentObservation (KindIntentMatches, KindIntentMissing)
  , observeKindIntent
  , observeKindTeardownAdmission
  )
import Prodbox.Control.KindKubeconfigFile (withKindKubeconfigSnapshotBound)
import Prodbox.Control.KindLease
  ( KindOperationOutcome (KindOperationCallbackReturned)
  , withRecoveredKindOperation
  )
import Prodbox.Control.KindNodeBootstrap
  ( JournalRecordObservation (..)
  , observeJournalRecord
  , writeJournalRecord
  )
import Prodbox.Control.ManagementPolicy (managementNamespace, managementPolicyManifest)
import Prodbox.Control.ManagementRestore (managementRestoreIdle)
import Prodbox.Control.NetworkEnforcement
  ( EnforcementCleanup (..)
  , EnforcementOutcome (..)
  , enforcementComplete
  , observeNetworkEnforcementUnderBoundLease
  , renderEnforcementCleanup
  )
import Prodbox.Control.ServiceSupport
  ( ServiceStep (..)
  , importImageStep
  , maxServiceAttempts
  , run
  , serviceAttemptNamespace
  , serviceAttemptRecordName
  )
import Prodbox.Control.Status (observeNodeCaBindingUnderLease)
import Prodbox.Infra.BootstrapImageArchive (BootstrapImageArchitecture (BootstrapImageAmd64))
import Prodbox.Infra.BootstrapImageSourceNative
  ( bootstrapSourceArtifactArchivePath
  , bootstrapSourceArtifactIdentity
  , bootstrapSourceArtifactReference
  , ensureBootstrapSourceArtifacts
  )
import Prodbox.Minio.RootCredential (minioRootPassword, minioRootUser)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.Posix.Files (setFileMode)

newtype ServicesOutcome = ServicesOutcome [ServiceStep]
  deriving (Eq, Show)

renderServicesOutcome :: ServicesOutcome -> (Bool, String)
renderServicesOutcome (ServicesOutcome steps) =
  ( all serviceStepOk steps && not (null steps)
  , unlines
      [ "  "
          ++ serviceStepName step
          ++ ": "
          ++ (if serviceStepOk step then "ok" else "NOT completed")
          ++ " - "
          ++ serviceStepDetail step
      | step <- steps
      ]
  )

vaultReference, vaultDigest, vaultTagged :: String
vaultReference = "docker.io/hashicorp/vault"
vaultDigest = "sha256:8f1ba670da547c6af67be55609bd285c3ee3d8b73f88021adbfc43c82ca409e8"
vaultTagged = vaultReference ++ ":1.18.3"

mcReference :: String
mcReference = "docker.io/prodbox/mc-bootstrap:RELEASE.2024-11-21T17-21-54Z-source-v1"

minioReference :: String
minioReference = "docker.io/prodbox/minio-bootstrap:RELEASE.2024-12-18T13-15-44Z-source-v1"

reconcileServices :: BootstrapProjection -> IO ServicesOutcome
reconcileServices bootstrap = do
  intent <- observeKindIntent bootstrap
  case intent of
    KindIntentMatches operation -> do
      ending <- (+ 1200000000000) <$> getMonotonicTimeNSec
      retired <- withKindFamilyRetirement ending bootstrap operation $ \owner ->
        withRecoveredKindOperation bootstrap operation $ \stable -> do
          let admitted = do
                held <- stable
                checkpoint <- observeKindTeardownAdmission bootstrap
                idle <- managementRestoreIdle bootstrap
                after <- stable
                pure (held && checkpoint == KindIntentMissing && idle && after)
          before <- verifyKindFamilyRetirement owner admitted
          receipt <- observeControllerReceipt bootstrap operation admitted
          case (before, receipt) of
            (Right (), ControllerReceiptObserved node) ->
              runServicesAttempt bootstrap operation node admitted
            _ -> pure (refusedServices "exact running kind operation or worker settlement is unconfirmed")
      pure $ case retired of
        KindFamilyRetirementReturned (KindOperationCallbackReturned outcome) (Right ()) True -> outcome
        _ -> refusedServices "owner or operation lease did not settle; inspect the retained service attempt"
    _ -> pure (refusedServices "a recorded kind operation is required; run control reconcile first")

refusedServices :: String -> ServicesOutcome
refusedServices reason = ServicesOutcome [ServiceStep "service-admission" False reason]

runServicesAttempt :: BootstrapProjection -> String -> String -> IO Bool -> IO ServicesOutcome
runServicesAttempt bootstrap operation node stable = do
  snapshot <- withKindKubeconfigSnapshotBound bootstrap $ \config kubeconfig -> do
    let bindConfig selected = observeNodeCaBindingUnderLease bootstrap operation node selected stable
    running <- bindConfig config
    if not running
      then pure (refusedServices "the exact node and its Kubernetes credential could not be verified")
      else do
        allocation <- nextServiceAttempt bootstrap operation node stable
        case allocation of
          Left reason -> pure (refusedServices reason)
          Right attempt -> do
            enforcement <-
              observeNetworkEnforcementUnderBoundLease
                bootstrap
                operation
                (serviceProbeNamespace attempt)
                stable
                bindConfig
            let proven = enforcementComplete enforcement
                gate =
                  ServiceStep "enforcement-gate" proven $
                    if proven
                      then "pinned management policy enforced by real sockets before any secret is created"
                      else
                        "enforcement not proven ("
                          ++ maybe "no complete observation" id (enforcementFailure enforcement)
                          ++ "; cleanup: "
                          ++ renderEnforcementCleanup (enforcementCleanup enforcement)
                          ++ "); no secret was created"
            if not proven
              then case enforcementCleanup enforcement of
                EnforcementCleanupConfirmed -> finishServiceAttempt bootstrap stable attempt False [gate]
                EnforcementCleanupNotStarted -> finishServiceAttempt bootstrap stable attempt False [gate]
                EnforcementCleanupUnconfirmed _ -> pure (ServicesOutcome [gate, pendingServiceStep attempt])
              else do
                current <- bindConfig config
                if not current
                  then pure (ServicesOutcome [gate, pendingServiceStep attempt])
                  else do
                    steps <- deployServiceComponents bootstrap node kubeconfig stable gate
                    if all serviceStepOk steps
                      then finishServiceAttempt bootstrap (bindConfig config) attempt True steps
                      else pure (ServicesOutcome (steps ++ [pendingServiceStep attempt]))
  pure (either (const (refusedServices "validated Kubernetes credential unavailable")) id snapshot)

data ServiceAttempt = ServiceAttempt !String !String !String !Int

serviceProbeNamespace :: ServiceAttempt -> String
serviceProbeNamespace (ServiceAttempt operation _ _ index) = serviceAttemptNamespace operation index

serviceRecordName :: ServiceAttempt -> String -> FilePath
serviceRecordName (ServiceAttempt operation _ _ index) = serviceAttemptRecordName operation index

serviceRecord :: ServiceAttempt -> Maybe Bool -> Aeson.Value
serviceRecord attempt@(ServiceAttempt operation generation node index) result =
  Aeson.object $
    [ "schema_version" .= (2 :: Int)
    , "kind" .= maybe ("kind-services-attempt" :: String) (const "kind-services-result") result
    , "operation_id" .= operation
    , "generation" .= generation
    , "node_id" .= node
    , "attempt" .= index
    , "probe_namespace" .= serviceProbeNamespace attempt
    ]
      ++ ["ok" .= ok | ok <- maybe [] pure result]

nextServiceAttempt
  :: BootstrapProjection -> String -> String -> IO Bool -> IO (Either String ServiceAttempt)
nextServiceAttempt bootstrap operation node stable = do
  legacyAttempt <- observeJournalRecord bootstrap "kind-services-attempt.json"
  legacyResult <- observeJournalRecord bootstrap "kind-services-result.json"
  case (legacyAttempt, legacyResult) of
    (JournalRecordMissing, JournalRecordMissing) -> next 1
    _ ->
      pure
        ( Left
            "retained legacy service records lack operation binding; preserve the original scope for recovery"
        )
 where
  next index
    | index > maxServiceAttempts = pure (Left "service attempts exhausted for the exact kind operation")
    | otherwise = do
        let attempt = ServiceAttempt operation (Text.unpack (bootstrapRootGeneration bootstrap)) node index
            path = serviceRecordName attempt "attempt"
            expected = serviceRecord attempt Nothing
        previous <- observeJournalRecord bootstrap path
        result <- observeJournalRecord bootstrap (serviceRecordName attempt "result")
        held <- stable
        case (held, previous, result) of
          (True, JournalRecordMissing, JournalRecordMissing) -> do
            written <- writeJournalRecord bootstrap path expected
            found <- observeJournalRecord bootstrap path
            current <- stable
            pure $
              if written && current && found == JournalRecordObserved expected
                then Right attempt
                else Left "the new service attempt could not be durably bound"
          (True, JournalRecordObserved observed, JournalRecordObserved settled)
            | observed == expected
            , settled == serviceRecord attempt (Just True) || settled == serviceRecord attempt (Just False) ->
                next (index + 1)
          _ -> pure (Left (serviceStepDetail (pendingServiceStep attempt)))

pendingServiceStep :: ServiceAttempt -> ServiceStep
pendingServiceStep attempt =
  ServiceStep "service-settlement" False $
    "service attempt remains recoverable under "
      ++ serviceProbeNamespace attempt
      ++ "; settle the original kind operation with control delete before recreation"

finishServiceAttempt
  :: BootstrapProjection -> IO Bool -> ServiceAttempt -> Bool -> [ServiceStep] -> IO ServicesOutcome
finishServiceAttempt bootstrap stable attempt ok steps = do
  let path = serviceRecordName attempt "result"
      expected = serviceRecord attempt (Just ok)
  before <- stable
  written <- if before then writeJournalRecord bootstrap path expected else pure False
  observed <- observeJournalRecord bootstrap path
  after <- stable
  pure $
    ServicesOutcome $
      if written && after && observed == JournalRecordObserved expected
        then steps
        else steps ++ [pendingServiceStep attempt]

deployServiceComponents
  :: BootstrapProjection -> String -> FilePath -> IO Bool -> ServiceStep -> IO [ServiceStep]
deployServiceComponents bootstrap node kubeconfig stable gate = do
  let scope = bootstrapScope bootstrap
      root = scopeRoot scope
      socket = bootstrapRuntimeSocket bootstrap
      guarded action = do
        held <- stable
        if held then action else pure (Left "service operation identity changed")
      docker seconds arguments input =
        guarded $
          run seconds "/usr/bin/docker" (["--host", "unix://" ++ socket] ++ arguments) input
      kubectl seconds arguments input =
        guarded $
          run
            seconds
            "/usr/bin/kubectl"
            (["--kubeconfig", kubeconfig, "--request-timeout=60s"] ++ arguments)
            input
      importAll = foldM $ \steps (name, path, reference) ->
        if all serviceStepOk steps
          then (\step -> steps ++ [step]) <$> importImageStep docker name path reference node
          else pure steps
  minioArtifacts <- ensureBootstrapSourceArtifacts "." BootstrapImageAmd64
  minioArchive <- pure $ case minioArtifacts of
    Right artifacts ->
      case [a | a <- artifacts, Text.unpack (bootstrapSourceArtifactReference a) == minioReference] of
        [artifact] ->
          Right
            ( bootstrapSourceArtifactArchivePath artifact
            , Text.unpack (bootstrapSourceArtifactIdentity artifact)
            )
        _ -> Left "the source build did not yield exactly the pinned MinIO artifact"
    Left failure -> Left ("source artifact acquisition failed: " ++ show failure)
  let mcArchive = case minioArtifacts of
        Right artifacts ->
          case [a | a <- artifacts, Text.unpack (bootstrapSourceArtifactReference a) == mcReference] of
            [artifact] ->
              Right
                ( bootstrapSourceArtifactArchivePath artifact
                , Text.unpack (bootstrapSourceArtifactIdentity artifact)
                )
            _ -> Left "the source build did not yield exactly the pinned MinIO client artifact"
        Left failure -> Left ("source artifact acquisition failed: " ++ show failure)
  vaultArchive <- saveVaultArchive (\arguments -> docker 120 arguments ByteString.empty) root
  let archiveStep name result = case result of
        Right (path, identity) -> ServiceStep name True (path ++ " identity " ++ identity)
        Left reason -> ServiceStep name False reason
      archiveSteps =
        [ archiveStep "minio-archive" minioArchive
        , archiveStep "mc-archive" mcArchive
        , archiveStep "vault-archive" vaultArchive
        ]
  case (minioArchive, mcArchive, vaultArchive) of
    (Right (minioPath, _), Right (mcPath, _), Right (vaultPath, _)) -> do
      imported <-
        importAll
          (gate : archiveSteps)
          [ ("minio-import", minioPath, minioReference)
          , ("mc-import", mcPath, mcReference)
          , ("vault-import", vaultPath, vaultTagged)
          ]
      if not (all serviceStepOk imported)
        then pure imported
        else do
          created <- prepareAndApply root kubectl
          broker <-
            if all serviceStepOk created
              then deployBroker socket root node (scopeKindName scope) docker kubectl
              else pure []
          pure (imported ++ created ++ broker)
    _ -> pure (gate : archiveSteps)

-- | Pull by digest, tag with the readable name so containerd registers it,
-- and save to a private archive under the retained root. The saved archive's
-- SHA-256 is the recorded identity of what was imported.
saveVaultArchive
  :: ([String] -> IO (Either String (Int, String, String)))
  -> FilePath
  -> IO (Either String (FilePath, String))
saveVaultArchive docker root = do
  let directory = root </> "service-images"
      path = directory </> "vault-1.18.3.tar"
  createDirectoryIfMissing False directory
  setFileMode directory 0o700
  pulled <- docker ["pull", vaultReference ++ "@" ++ vaultDigest]
  case pulled of
    Right (0, _, _) -> do
      tagged <- docker ["tag", vaultReference ++ "@" ++ vaultDigest, vaultTagged]
      saved <- docker ["save", "--output", path, vaultTagged]
      case (tagged, saved) of
        (Right (0, _, _), Right (0, _, _)) -> do
          digestText <- fileDigest path
          pure (Right (path, "sha256:" ++ digestText))
        _ -> pure (Left "tagging or saving the pinned Vault image failed")
    Right (code, _, err) ->
      pure
        (Left ("pulling the pinned Vault image failed with exit " ++ show code ++ ": " ++ take 200 err))
    Left failure -> pure (Left failure)

fileDigest :: FilePath -> IO String
fileDigest path = do
  bytes <- withBinaryFile path ReadMode ByteString.hGetContents
  pure (ByteString8.unpack (hexSha256 bytes))

prepareAndApply
  :: FilePath
  -> (Int -> [String] -> ByteString.ByteString -> IO (Either String (Int, String, String)))
  -> IO [ServiceStep]
prepareAndApply root kubectl = do
  namespace <- apply "namespace" namespaceManifest
  prerequisites <-
    advance [namespace] (apply "management-policy" (managementPolicyManifest managementNamespace))
  if all serviceStepOk prerequisites
    then provision prerequisites
    else pure prerequisites
 where
  advance steps action
    | all serviceStepOk steps = (\step -> steps ++ [step]) <$> action
    | otherwise = pure steps
  provision prerequisites = do
    createDirectoryIfMissing False (root </> "minio-data")
    setFileMode (root </> "minio-data") 0o700
    createDirectoryIfMissing False (root </> "vault-data")
    setFileMode (root </> "vault-data") 0o700
    -- The Broker uses the compiled bootstrap-floor credential. The restricted
    -- unlock-object reader is random per environment and reused on repeat.
    (readerUser, readerPassword) <-
      loadOrCreateCredential (root </> "control" </> "minio-unlock-reader-credential") "unlock-reader"
    bootstrap <-
      advance prerequisites $
        applyCredential "bootstrap-credential" "minio-bootstrap-credential" minioRootUser minioRootPassword
    reader <-
      advance bootstrap $
        applyCredential
          "unlock-reader-credential"
          "minio-unlock-reader-credential"
          readerUser
          readerPassword
    applied <- advance reader (apply "services" servicesManifest)
    ready <- advance applied waitForComponents
    minio <- advance ready (proxyGet "minio-direct" "minio:9000" "minio/health/ready")
    vault <-
      advance minio $
        proxyGet "vault-direct" "vault:8200" "v1/sys/health?uninitcode=200&sealedcode=200&standbyok=true"
    advance vault (reconcileUnlockReader readerUser kubectl)
  waitForComponents = do
    waited <-
      kubectl
        200
        [ "-n"
        , managementNamespace
        , "wait"
        , "--for=condition=Ready"
        , "pod"
        , "--all"
        , "--timeout=180s"
        ]
        ByteString.empty
    pure $ case waited of
      Right (0, _, _) -> ServiceStep "services-ready" True "MinIO, Vault and the MinIO client pods report Ready"
      Right (code, _, err) -> ServiceStep "services-ready" False ("wait exit " ++ show code ++ ": " ++ take 200 err)
      Left failure -> ServiceStep "services-ready" False failure
  applyCredential step name user password = do
    result <- kubectl 90 ["apply", "-f", "-"] (secretManifest name user password)
    pure $ case result of
      Right (0, _, _) -> ServiceStep step True "credential applied"
      Right (code, _, _) -> ServiceStep step False ("credential apply exit " ++ show code)
      Left _ -> ServiceStep step False "credential apply request unobservable"
  apply name manifest = do
    result <- kubectl 90 ["apply", "-f", "-"] manifest
    pure $ case result of
      Right (0, _, _) -> ServiceStep name True "applied"
      Right (code, _, err) -> ServiceStep name False ("kubectl exit " ++ show code ++ ": " ++ take 200 err)
      Left failure -> ServiceStep name False failure
  proxyGet name target path = do
    result <-
      kubectl
        60
        [ "get"
        , "--raw"
        , "/api/v1/namespaces/" ++ managementNamespace ++ "/pods/" ++ target ++ "/proxy/" ++ path
        ]
        ByteString.empty
    pure $ case result of
      Right (0, out, _) -> ServiceStep name True ("direct read: " ++ take 200 (filter (/= '\n') (summarise out)))
      Right (code, _, err) -> ServiceStep name False ("direct read exit " ++ show code ++ ": " ++ take 200 err)
      Left failure -> ServiceStep name False failure
  summarise out = case Aeson.decodeStrict (ByteString8.pack out) of
    Just (Aeson.Object fields) ->
      unwords
        [ show key ++ "=" ++ renderValue value
        | key <- ["initialized", "sealed"]
        , Just value <- [KeyMap.lookup (Key.fromString key) fields]
        ]
    _ -> out
  renderValue value = case value of
    Aeson.Bool flag -> if flag then "true" else "false"
    other -> show other

data ReaderAdminObservation a
  = ReaderAdminObserved !a
  | ReaderAdminAbsent
  | ReaderAdminUnobservable
  deriving (Eq)

data ReaderAttachment = ReaderUnattached | ReaderAttached
  deriving (Eq)

unlockReaderPolicyName :: String
unlockReaderPolicyName = "unlock-object-read"

unlockReaderPolicy :: Aeson.Value
unlockReaderPolicy =
  Aeson.object
    [ "Version" .= ("2012-10-17" :: Text.Text)
    , "Statement"
        .= [ Aeson.object
               [ "Effect" .= ("Allow" :: Text.Text)
               , "Action" .= ["s3:GetObject" :: Text.Text]
               , "Resource" .= ["arn:aws:s3:::prodbox-bootstrap/vault-unlock-test.json" :: Text.Text]
               ]
           ]
    ]

-- Observe the exact MinIO records before changing them. A healthy retained
-- reader needs no writes after kind recreation. A mutation reply alone does
-- not settle the attempt, including when the reply was lost.
reconcileUnlockReader
  :: String
  -> (Int -> [String] -> ByteString.ByteString -> IO (Either String (Int, String, String)))
  -> IO ServiceStep
reconcileUnlockReader readerUser kubectl = do
  existing <- policyState
  policy <- case existing of
    ReaderAdminAbsent -> do
      _ <-
        admin
          ( "umask 077; policy=$(mktemp) && trap 'rm -f \"$policy\"' EXIT && cat > \"$policy\" && "
              ++ "mc admin policy create local "
              ++ unlockReaderPolicyName
              ++ " \"$policy\""
          )
          (LazyByteString.toStrict (Aeson.encode unlockReaderPolicy))
      policyState
    recorded -> pure recorded
  if policy /= ReaderAdminObserved True
    then pure (refuseReader "the exact single-object policy definition is unconfirmed")
    else do
      previous <- accountState
      account <- case previous of
        ReaderAdminAbsent -> do
          _ <-
            admin "mc admin user add local \"$MINIO_READER_USER\" \"$MINIO_READER_PASSWORD\"" ByteString.empty
          accountState
        recorded -> pure recorded
      attached <- case account of
        ReaderAdminObserved ReaderUnattached -> do
          _ <-
            admin
              ("mc admin policy attach local " ++ unlockReaderPolicyName ++ " --user \"$MINIO_READER_USER\"")
              ByteString.empty
          accountState
        recorded -> pure recorded
      pure $
        if attached == ReaderAdminObserved ReaderAttached
          then
            ServiceStep
              "unlock-reader"
              True
              "the exact enabled reader is bound only to the single-object policy"
          else refuseReader "the exact enabled reader and its exclusive policy attachment are unconfirmed"
 where
  refuseReader = ServiceStep "unlock-reader" False
  admin script =
    kubectl
      40
      [ "-n"
      , managementNamespace
      , "exec"
      , "-i"
      , "mc"
      , "--"
      , "/bin/sh"
      , "-c"
      , "mc alias set local http://minio:9000 \"$MINIO_USER\" \"$MINIO_PASSWORD\" >/dev/null 2>&1 && { "
          ++ script
          ++ "; }"
      ]
  policyState =
    observeReaderAdmin
      "XMinioAdminNoSuchPolicy"
      ( Aeson.withObject "MinIO policy" $ \policy -> do
          status <- policy .: "status"
          name <- policy .: "policy"
          info <- policy .: "policyInfo"
          definition <- Aeson.withObject "MinIO policy document" (.: "Policy") info
          pure
            ( status == ("success" :: Text.Text)
                && name == unlockReaderPolicyName
                && definition == unlockReaderPolicy
            )
      )
      (admin ("mc --json admin policy info local " ++ unlockReaderPolicyName) ByteString.empty)
  accountState =
    observeReaderAdmin
      "XMinioAdminNoSuchUser"
      ( Aeson.withObject "MinIO user" $ \account -> do
          status <- account .: "status"
          user <- account .: "accessKey"
          enabled <- account .: "userStatus"
          groups <- account .:? "memberOf" .!= ([] :: [Aeson.Value])
          attached <- account .:? "policyName" .!= ""
          if status == ("success" :: Text.Text)
            && user == readerUser
            && enabled == ("enabled" :: Text.Text)
            && null groups
            then
              if attached == unlockReaderPolicyName
                then pure ReaderAttached
                else if null attached then pure ReaderUnattached else fail "unexpected reader policy"
            else fail "unexpected reader account"
      )
      (admin "mc --json admin user info local \"$MINIO_READER_USER\"" ByteString.empty)

observeReaderAdmin
  :: Text.Text
  -> (Aeson.Value -> AesonTypes.Parser a)
  -> IO (Either String (Int, String, String))
  -> IO (ReaderAdminObservation a)
observeReaderAdmin missing parse action = go (3 :: Int)
 where
  go attempts = do
    reply <- action
    case reply of
      Right (0, out, _)
        | Just result <- decode parse out -> pure (ReaderAdminObserved result)
      Right (1, out, _)
        | Just code <- decode minioAdminErrorCode out
        , code == missing ->
            pure ReaderAdminAbsent
      _ | attempts > 0 -> threadDelay 1500000 >> go (attempts - 1)
      _ -> pure ReaderAdminUnobservable
  decode parser out = Aeson.decodeStrict' (ByteString8.pack out) >>= AesonTypes.parseMaybe parser
  minioAdminErrorCode = Aeson.withObject "MinIO admin refusal" $ \response -> do
    status <- response .: "status"
    if status == ("error" :: Text.Text)
      then do
        failure <- response .: "error"
        cause <- Aeson.withObject "MinIO admin failure" (.: "cause") failure
        detail <- Aeson.withObject "MinIO admin cause" (.: "error") cause
        Aeson.withObject "MinIO admin code" (.: "Code") detail
      else fail "expected a MinIO admin refusal"

namespaceManifest :: ByteString.ByteString
namespaceManifest =
  ByteString8.pack
    ("apiVersion: v1\nkind: Namespace\nmetadata: {name: " ++ managementNamespace ++ "}\n")

loadOrCreateCredential :: FilePath -> String -> IO (String, String)
loadOrCreateCredential path prefix = do
  random <- withBinaryFile "/dev/urandom" ReadMode (\handle -> ByteString.hGet handle 32)
  let secret = ByteString8.unpack (hexSha256 (random <> ByteString8.pack prefix))
      user = prefix ++ "-" ++ take 12 secret
      password = drop 12 secret
  exists <- doesFileExist path
  if exists
    then do
      stored <- ByteString8.unpack <$> withBinaryFile path ReadMode ByteString.hGetContents
      pure $ case lines stored of
        [u, p] -> (u, p)
        _ -> (user, password)
    else do
      ByteString8.writeFile path (ByteString8.pack (user ++ "\n" ++ password ++ "\n"))
      setFileMode path 0o600
      pure (user, password)

secretManifest :: String -> String -> String -> ByteString.ByteString
secretManifest name user password =
  ByteString8.pack $
    unlines
      [ "apiVersion: v1"
      , "kind: Secret"
      , "metadata: {name: " ++ name ++ ", namespace: " ++ managementNamespace ++ "}"
      , "type: Opaque"
      , "stringData: {user: " ++ user ++ ", password: " ++ password ++ "}"
      ]

servicesManifest :: ByteString.ByteString
servicesManifest =
  ByteString8.pack $
    unlines
      [ "apiVersion: v1"
      , "kind: ServiceAccount"
      , "metadata: {name: vault, namespace: " ++ managementNamespace ++ "}"
      , "---"
      , "apiVersion: rbac.authorization.k8s.io/v1"
      , "kind: ClusterRoleBinding"
      , "metadata: {name: " ++ managementNamespace ++ "-vault-token-reviewer}"
      , "roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: system:auth-delegator}"
      , "subjects: [{kind: ServiceAccount, name: vault, namespace: " ++ managementNamespace ++ "}]"
      , "---"
      , "apiVersion: v1"
      , "kind: ConfigMap"
      , "metadata: {name: vault-config, namespace: " ++ managementNamespace ++ "}"
      , "data:"
      , "  vault.hcl: |"
      , "    disable_mlock = true"
      , "    ui = false"
      , "    storage \"file\" { path = \"/vault/file\" }"
      , "    listener \"tcp\" { address = \"0.0.0.0:8200\" tls_disable = 1 }"
      , "    api_addr = \"http://127.0.0.1:8200\""
      , "---"
      , "apiVersion: v1"
      , "kind: Pod"
      , "metadata: {name: minio, namespace: "
          ++ managementNamespace
          ++ ", labels: {prodbox.io/plane: management, app: minio}}"
      , "spec:"
      , "  securityContext: {runAsUser: 1000, runAsGroup: 1000}"
      , "  containers:"
      , "  - name: minio"
      , "    image: " ++ minioReference
      , "    imagePullPolicy: Never"
      , "    args: [server, /data, --address, \":9000\"]"
      , "    env:"
      , "    - {name: MINIO_ROOT_USER, valueFrom: {secretKeyRef: {name: minio-bootstrap-credential, key: user}}}"
      , "    - {name: MINIO_ROOT_PASSWORD, valueFrom: {secretKeyRef: {name: minio-bootstrap-credential, key: password}}}"
      , "    volumeMounts: [{name: data, mountPath: /data}]"
      , "    resources: {requests: {cpu: 100m, memory: 256Mi}, limits: {cpu: \"1\", memory: 1Gi}}"
      , "    readinessProbe: {httpGet: {path: /minio/health/ready, port: 9000}, periodSeconds: 2}"
      , "  volumes: [{name: data, hostPath: {path: /var/lib/prodbox/minio-data, type: Directory}}]"
      , "---"
      , "apiVersion: v1"
      , "kind: Service"
      , "metadata: {name: minio, namespace: " ++ managementNamespace ++ "}"
      , "spec: {selector: {app: minio}, ports: [{port: 9000, targetPort: 9000}]}"
      , "---"
      , "apiVersion: v1"
      , "kind: Service"
      , "metadata: {name: vault, namespace: " ++ managementNamespace ++ "}"
      , "spec: {selector: {app: vault}, ports: [{port: 8200, targetPort: 8200}]}"
      , "---"
      , "apiVersion: v1"
      , "kind: Pod"
      , "metadata: {name: mc, namespace: "
          ++ managementNamespace
          ++ ", labels: {prodbox.io/management-client: \"true\", app: mc}}"
      , "spec:"
      , "  securityContext: {runAsUser: 1000, runAsGroup: 1000}"
      , "  containers:"
      , "  - name: mc"
      , "    image: " ++ mcReference
      , "    imagePullPolicy: Never"
      , "    command: [/bin/sh, -c, \"sleep 2147483647\"]"
      , "    resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {cpu: 500m, memory: 512Mi}}"
      , "    env:"
      , "    - {name: HOME, value: /tmp}"
      , "    - {name: MC_CONFIG_DIR, value: /tmp/mc}"
      , "    - {name: MINIO_USER, valueFrom: {secretKeyRef: {name: minio-bootstrap-credential, key: user}}}"
      , "    - {name: MINIO_PASSWORD, valueFrom: {secretKeyRef: {name: minio-bootstrap-credential, key: password}}}"
      , "    - {name: MINIO_READER_USER, valueFrom: {secretKeyRef: {name: minio-unlock-reader-credential, key: user}}}"
      , "    - {name: MINIO_READER_PASSWORD, valueFrom: {secretKeyRef: {name: minio-unlock-reader-credential, key: password}}}"
      , "---"
      , "apiVersion: v1"
      , "kind: Pod"
      , "metadata: {name: vault, namespace: "
          ++ managementNamespace
          ++ ", labels: {prodbox.io/plane: management, app: vault}}"
      , "spec:"
      , "  serviceAccountName: vault"
      , "  securityContext: {runAsUser: 1000, runAsGroup: 1000}"
      , "  containers:"
      , "  - name: vault"
      , "    image: " ++ vaultTagged
      , "    imagePullPolicy: Never"
      , "    command: [vault, server, -config=/vault/config/vault.hcl]"
      , "    resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: \"1\", memory: 512Mi}}"
      , "    env: [{name: HOME, value: /tmp}]"
      , "    volumeMounts: [{name: data, mountPath: /vault/file}, {name: config, mountPath: /vault/config}]"
      , "    readinessProbe: {httpGet: {path: \"/v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204\", port: 8200}, periodSeconds: 2}"
      , "  volumes:"
      , "  - {name: data, hostPath: {path: /var/lib/prodbox/vault-data, type: Directory}}"
      , "  - {name: config, configMap: {name: vault-config}}"
      ]

-- | Direct, read-only component status for @control status@: Vault's
-- initialization and seal state and MinIO's readiness, each read through the
-- API server's pod proxy. A service that cannot be reached is reported as
-- such, never as absent or ready.
observeServices :: FilePath -> IO String
observeServices kubeconfig = do
  present <- doesFileExist kubeconfig
  if not present
    then pure "Services: no installed cluster credential; not observed.\n"
    else do
      let proxy target path =
            run
              30
              "/usr/bin/kubectl"
              [ "--kubeconfig"
              , kubeconfig
              , "--request-timeout=20s"
              , "get"
              , "--raw"
              , "/api/v1/namespaces/" ++ managementNamespace ++ "/pods/" ++ target ++ "/proxy/" ++ path
              ]
              ByteString.empty
      minio <- proxy "minio:9000" "minio/health/ready"
      vault <- proxy "vault:8200" "v1/sys/health?uninitcode=200&sealedcode=200&standbyok=true"
      let minioLine = case minio of
            Right (0, _, _) -> "MinIO ready"
            Right (code, _, _) -> "MinIO not ready (read exit " ++ show code ++ ")"
            Left _ -> "MinIO unobservable"
          vaultLine = case vault of
            Right (0, out, _) -> case Aeson.decodeStrict (ByteString8.pack out) of
              Just (Aeson.Object fields) ->
                "Vault initialized="
                  ++ flag (KeyMap.lookup (Key.fromString "initialized") fields)
                  ++ " sealed="
                  ++ flag (KeyMap.lookup (Key.fromString "sealed") fields)
              _ -> "Vault answered with an unreadable health document"
            Right (code, _, _) -> "Vault not reachable (read exit " ++ show code ++ ")"
            Left _ -> "Vault unobservable"
          flag value = case value of
            Just (Aeson.Bool True) -> "true"
            Just (Aeson.Bool False) -> "false"
            _ -> "unknown"
      brokerRead <-
        observeBrokerReadiness
          ( \seconds arguments input ->
              run
                seconds
                "/usr/bin/kubectl"
                (["--kubeconfig", kubeconfig, "--request-timeout=20s"] ++ arguments)
                input
          )
      let brokerLine = case brokerRead of
            Right text
              | "\"ready\":true" `isInfixOf` text -> "Broker ready"
              | otherwise -> "Broker not ready (" ++ take 120 text ++ ")"
            Left _ -> "Broker unobservable"
      pure ("Services: " ++ minioLine ++ "; " ++ vaultLine ++ "; " ++ brokerLine ++ ".\n")

-- | Remove the Vault and MinIO Pods and wait until they are gone, so their
-- data directories can be copied or replaced consistently. The MinIO client Pod
-- keeps no data and is left alone.
stopServicePods :: FilePath -> IO ServiceStep
stopServicePods kubeconfig = do
  result <-
    run
      180
      "/usr/bin/kubectl"
      [ "--kubeconfig"
      , kubeconfig
      , "--request-timeout=60s"
      , "-n"
      , managementNamespace
      , "delete"
      , "pod"
      , "vault"
      , "minio"
      , "--ignore-not-found"
      , "--wait=true"
      ]
      ByteString.empty
  pure $ case result of
    Right (0, _, _) -> ServiceStep "stop-services" True "the Vault and MinIO Pods are gone"
    Right (code, _, err) -> ServiceStep "stop-services" False ("kubectl exit " ++ show code ++ ": " ++ take 160 err)
    Left failure -> ServiceStep "stop-services" False failure

-- | Apply the pinned service manifests again and wait for every Pod to be Ready.
startServicePods :: FilePath -> IO ServiceStep
startServicePods kubeconfig = do
  applied <-
    run
      90
      "/usr/bin/kubectl"
      ["--kubeconfig", kubeconfig, "--request-timeout=60s", "apply", "-f", "-"]
      servicesManifest
  waited <-
    run
      200
      "/usr/bin/kubectl"
      [ "--kubeconfig"
      , kubeconfig
      , "--request-timeout=60s"
      , "-n"
      , managementNamespace
      , "wait"
      , "--for=condition=Ready"
      , "pod"
      , "--all"
      , "--timeout=180s"
      ]
      ByteString.empty
  pure $ case (applied, waited) of
    (Right (0, _, _), Right (0, _, _)) -> ServiceStep "start-services" True "the service Pods were applied again and report Ready"
    (Right (0, _, _), Right (code, _, err)) -> ServiceStep "start-services" False ("wait exit " ++ show code ++ ": " ++ take 160 err)
    (Right (code, _, err), _) -> ServiceStep "start-services" False ("apply exit " ++ show code ++ ": " ++ take 160 err)
    (Left failure, _) -> ServiceStep "start-services" False failure
