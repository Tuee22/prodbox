{-# LANGUAGE OverloadedStrings #-}

-- | Deploy the repository's real Bootstrap Broker into a test environment next
-- to the pinned MinIO and Vault, and observe its own readiness answer.
--
-- Measured requirements, in the order the Broker enforced them (each was a
-- distinct readiness refusal): the Broker's OpenPGP boundary needs
-- @/usr/bin/gpg@; it observes its own Pod through the API server and requires
-- the chart's identity (the application-name and instance labels, the
-- instance equal to the namespace, the container named @bootstrap-broker@, the
-- ServiceAccount @prodbox-bootstrap-broker@ and the worker image repository
-- @127.0.0.1:30080/prodbox/prodbox-runtime@); it reads and creates its fence
-- Lease and one-shot worker Pods through a namespaced Role and authenticates
-- callers with TokenReview through a ClusterRole; and its bootstrap store is
-- MinIO under the compiled bootstrap-floor credential.
--
-- The runtime image is built locally from this very binary, the host's gpg and
-- the libraries gpg links against on top of the digest-pinned Ubuntu base, saved
-- to a private archive under the retained root and imported into the node's
-- containerd; the Pod's pull policy is Never, so no registry is involved.
module Prodbox.Control.BrokerDeploy
  ( deployBroker
  , observeBrokerReadiness
  , brokerNamespace
  , localBrokerStoreBucket
  , runtimeRepository
  , runtimeImageTag
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.List (isInfixOf)
import Data.Set qualified as Set
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Control.ManagementPolicy (managementNamespace)
import Prodbox.Control.ServiceSupport (ServiceStep (..), importImageStep, run, runWithEnvironment)
import Prodbox.ControlPlane.ListenPort (controlPlaneListenPort)
import System.Directory (copyFile, createDirectoryIfMissing, getFileSize)
import System.Environment (getExecutablePath)
import System.FilePath (takeFileName, (</>))
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.Posix.Files (setFileMode)

ubuntuReference :: String
ubuntuReference = "docker.io/library/ubuntu"

ubuntuDigest :: String
ubuntuDigest = "sha256:9c7f200c07e3d4a03e7249d2c16bf66a51120fb876aa2242cf31451412543289"

runtimeRepository :: String
runtimeRepository = "127.0.0.1:30080/prodbox/prodbox-runtime"

brokerNamespace :: String
brokerNamespace = "bootstrap-broker"

brokerPort :: Int
brokerPort = controlPlaneListenPort

-- | The local runtime image tag for this binary (the same tag 'deployBroker'
-- builds and imports).
runtimeImageTag :: IO String
runtimeImageTag = do
  executable <- getExecutablePath
  binary <- withBinaryFile executable ReadMode ByteString.hGetContents
  pure (runtimeRepository ++ ":phase2-" ++ take 12 (ByteString8.unpack (hexSha256 binary)))

-- | Build, import and apply the Broker; report each step. @docker@ runs
-- Docker commands against the selected socket, @kubectl@ kubectl against the
-- environment, @node@ is the kind node container and @clusterId@ names the
-- environment in the Broker's store keys.
deployBroker
  :: FilePath
  -> FilePath
  -> String
  -> String
  -> (Int -> [String] -> ByteString.ByteString -> IO (Either String (Int, String, String)))
  -> (Int -> [String] -> ByteString.ByteString -> IO (Either String (Int, String, String)))
  -> IO [ServiceStep]
deployBroker socket root node clusterId docker kubectl = do
  executable <- getExecutablePath
  binary <- withBinaryFile executable ReadMode ByteString.hGetContents
  let digest12 = take 12 (ByteString8.unpack (hexSha256 binary))
      tag = runtimeRepository ++ ":phase2-" ++ digest12
      directory = root </> "service-images"
      context = directory </> "runtime-context"
  createDirectoryIfMissing False directory
  setFileMode directory 0o700
  createDirectoryIfMissing False context
  setFileMode context 0o700
  libraries <- gpgLibraries
  case libraries of
    Left reason -> pure [ServiceStep "runtime-image" False reason]
    Right paths -> do
      copyFile executable (context </> "prodbox")
      mapM_ (\tool -> copyFile tool (context </> takeFileName tool)) gpgBinaries
      createDirectoryIfMissing False (context </> "libraries")
      mapM_ (\path -> copyFile path (context </> "libraries" </> takeFileName path)) paths
      ByteString.writeFile
        (context </> "Dockerfile")
        ( ByteString8.pack $
            unlines
              [ "FROM " ++ ubuntuReference ++ "@" ++ ubuntuDigest
              , "COPY prodbox /usr/bin/prodbox"
              , "COPY gpg gpg-agent gpgconf /usr/bin/"
              , "COPY libraries/ /usr/lib/x86_64-linux-gnu/"
              , "ENTRYPOINT [\"/usr/bin/prodbox\"]"
              ]
        )
      let dockerHome = directory </> "docker-home"
      createDirectoryIfMissing False dockerHome
      setFileMode dockerHome 0o700
      built <-
        runWithEnvironment
          [ ("PATH", "/usr/bin:/bin")
          , ("HOME", dockerHome)
          , ("DOCKER_CONFIG", dockerHome)
          , ("DOCKER_BUILDKIT", "0")
          ]
          600
          "/usr/bin/docker"
          (["--host", "unix://" ++ socket] ++ ["build", "-q", "-t", tag, context])
          ByteString.empty
      case built of
        Right (0, _, _) -> do
          let archive = directory </> "prodbox-runtime.tar"
          saved <- docker 120 ["save", "--output", archive, tag] ByteString.empty
          case saved of
            Right (0, _, _) -> do
              size <- try (getFileSize archive) :: IO (Either IOException Integer)
              imported <- importImageStep docker "runtime-import" archive tag node
              if not (serviceStepOk imported)
                then
                  pure
                    [ ServiceStep
                        "runtime-image"
                        True
                        (tag ++ " built, " ++ either (const "unknown size") (\s -> show (s `div` 1048576) ++ " MiB") size)
                    , imported
                    ]
                else do
                  applied <- applyBroker clusterId tag kubectl
                  ready <- waitReady kubectl
                  pure
                    ( [ ServiceStep
                          "runtime-image"
                          True
                          (tag ++ " built, " ++ either (const "unknown size") (\s -> show (s `div` 1048576) ++ " MiB") size)
                      , imported
                      ]
                        ++ applied
                        ++ [ready]
                    )
            _ -> pure [ServiceStep "runtime-image" False "saving the runtime image failed"]
        Right (code, _, err) ->
          pure [ServiceStep "runtime-image" False ("docker build exit " ++ show code ++ ": " ++ take 200 err)]
        Left failure -> pure [ServiceStep "runtime-image" False failure]

-- | The libraries @gpg@ links against, from the host's loader listing.
gpgLibraries :: IO (Either String [FilePath])
gpgLibraries = do
  listings <- mapM (\binary -> run 30 "/usr/bin/ldd" [binary] ByteString.empty) gpgBinaries
  pure $ case mapM libraries listings of
    Left reason -> Left reason
    Right found -> Right (nubOrd (concat found))
 where
  libraries listed = case listed of
    Right (0, out, _) -> Right [path | line <- lines out, (_ : "=>" : path : _) <- [words line], take 1 path == "/"]
    Right (code, _, _) -> Left ("ldd exit " ++ show code ++ "; the host needs gnupg for the Broker's OpenPGP boundary")
    Left failure -> Left failure
  nubOrd = Set.toList . Set.fromList

-- | The OpenPGP tools the Broker's boundary runs. @gpg@ starts @gpg-agent@
-- itself and fails when it is absent, so both travel into the image.
gpgBinaries :: [FilePath]
gpgBinaries = ["/usr/bin/gpg", "/usr/bin/gpg-agent", "/usr/bin/gpgconf"]

applyBroker
  :: String
  -> String
  -> (Int -> [String] -> ByteString.ByteString -> IO (Either String (Int, String, String)))
  -> IO [ServiceStep]
applyBroker clusterId tag kubectl = do
  let apply name manifest = do
        result <- kubectl 90 ["apply", "-f", "-"] manifest
        pure $ case result of
          Right (0, _, _) -> ServiceStep name True "applied"
          Right (code, _, err) -> ServiceStep name False ("kubectl exit " ++ show code ++ ": " ++ take 200 err)
          Left failure -> ServiceStep name False failure
  rbac <- apply "broker-rbac" (ByteString8.pack brokerRbac)
  config <- apply "broker-config" (ByteString8.pack (brokerConfigMap clusterId))
  pod <- apply "broker-pod" (ByteString8.pack (brokerPod tag))
  pure [rbac, config, pod]

brokerRbac :: String
brokerRbac =
  unlines
    [ "apiVersion: v1"
    , "kind: Namespace"
    , "metadata: {name: " ++ brokerNamespace ++ "}"
    , "---"
    , "apiVersion: v1"
    , "kind: ServiceAccount"
    , "metadata: {name: prodbox-bootstrap-broker, namespace: " ++ brokerNamespace ++ "}"
    , "---"
    , "apiVersion: v1"
    , "kind: ServiceAccount"
    , "metadata: {name: prodbox-bootstrap-secret-worker, namespace: " ++ brokerNamespace ++ "}"
    , "---"
    , "apiVersion: v1"
    , "kind: ServiceAccount"
    , "metadata: {name: prodbox-bootstrap-broker-client, namespace: " ++ brokerNamespace ++ "}"
    , "---"
    , "apiVersion: rbac.authorization.k8s.io/v1"
    , "kind: ClusterRole"
    , "metadata: {name: " ++ brokerNamespace ++ "-bootstrap-broker-tokenreview}"
    , "rules: [{apiGroups: [authentication.k8s.io], resources: [tokenreviews], verbs: [create]}]"
    , "---"
    , "apiVersion: rbac.authorization.k8s.io/v1"
    , "kind: ClusterRoleBinding"
    , "metadata: {name: " ++ brokerNamespace ++ "-bootstrap-broker-tokenreview}"
    , "roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: "
        ++ brokerNamespace
        ++ "-bootstrap-broker-tokenreview}"
    , "subjects: [{kind: ServiceAccount, name: prodbox-bootstrap-broker, namespace: "
        ++ brokerNamespace
        ++ "}]"
    , "---"
    , "apiVersion: rbac.authorization.k8s.io/v1"
    , "kind: Role"
    , "metadata: {name: bootstrap-broker-worker-observer, namespace: " ++ brokerNamespace ++ "}"
    , "rules:"
    , "- {apiGroups: [\"\"], resources: [pods], verbs: [create, list]}"
    , "- {apiGroups: [\"\"], resources: [pods], resourceNames: [bootstrap-secret-worker], verbs: [get, delete]}"
    , "- {apiGroups: [coordination.k8s.io], resources: [leases], verbs: [create]}"
    , "- {apiGroups: [coordination.k8s.io], resources: [leases], resourceNames: [bootstrap-broker-fence], verbs: [get, update]}"
    , "---"
    , "apiVersion: rbac.authorization.k8s.io/v1"
    , "kind: RoleBinding"
    , "metadata: {name: bootstrap-broker-worker-observer, namespace: " ++ brokerNamespace ++ "}"
    , "roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: bootstrap-broker-worker-observer}"
    , "subjects: [{kind: ServiceAccount, name: prodbox-bootstrap-broker, namespace: "
        ++ brokerNamespace
        ++ "}]"
    , "---"
    , "apiVersion: rbac.authorization.k8s.io/v1"
    , "kind: Role"
    , "metadata: {name: bootstrap-secret-worker-self-observer, namespace: " ++ brokerNamespace ++ "}"
    , "rules:"
    , "- {apiGroups: [\"\"], resources: [pods], resourceNames: [bootstrap-secret-worker], verbs: [get]}"
    , "- {apiGroups: [coordination.k8s.io], resources: [leases], resourceNames: [bootstrap-broker-fence], verbs: [get]}"
    , "---"
    , "apiVersion: rbac.authorization.k8s.io/v1"
    , "kind: RoleBinding"
    , "metadata: {name: bootstrap-secret-worker-self-observer, namespace: " ++ brokerNamespace ++ "}"
    , "roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: bootstrap-secret-worker-self-observer}"
    , "subjects: [{kind: ServiceAccount, name: prodbox-bootstrap-secret-worker, namespace: "
        ++ brokerNamespace
        ++ "}]"
    ]

storeKeys :: [(String, String)]
storeKeys =
  [ ("vault_storage_generation_key", "vault-storage-generation")
  , ("bootstrap_session_fence_key", "bootstrap-session-fence")
  , ("prepared_init_envelope_key", "prepared-init-envelope")
  , ("encrypted_init_response_key", "encrypted-init-response")
  , ("final_unlock_bundle_key", "final-unlock-bundle")
  , ("child_custody_receipt_key", "child-custody-receipt")
  , ("child_recovery_delivery_key", "child-recovery-delivery")
  , ("root_init_journal_key", "root-init-journal")
  , ("root_session_journal_key", "root-session-journal")
  , ("child_custody_journal_key", "child-custody-journal")
  , ("child_recovery_journal_key", "child-recovery-journal")
  , ("post_unseal_handoff_key", "post-unseal-handoff")
  , ("secret_worker_checkpoint_key", "secret-worker-checkpoint")
  ]

brokerConfigMap :: String -> String
brokerConfigMap clusterId =
  unlines
    [ "apiVersion: v1"
    , "kind: ConfigMap"
    , "metadata: {name: bootstrap-broker-config, namespace: " ++ brokerNamespace ++ "}"
    , "data:"
    , "  config.dhall: |"
    , "    " ++ dhall
    ]
 where
  dhall =
    "{ schemaVersion = 2, cluster_id = \""
      ++ clusterId
      ++ "\", vault_address = \"http://vault."
      ++ managementNamespace
      ++ ".svc.cluster.local:8200\", service_identity = \"prodbox-bootstrap-broker-client\""
      ++ ", listener = { listen_host = \"127.0.0.1\", listen_port = "
      ++ show brokerPort
      ++ " }, bootstrap_store = { store_endpoint = \"http://minio."
      ++ managementNamespace
      ++ ".svc.cluster.local:9000\", store_bucket = \""
      ++ localBrokerStoreBucket
      ++ "\""
      ++ concat
        [ ", " ++ field ++ " = \"bootstrap/" ++ clusterId ++ "/" ++ suffix ++ "\""
        | (field, suffix) <- storeKeys
        ]
      ++ " }, limits = { queue_capacity = 64, max_request_body_bytes = 65536, request_deadline_milliseconds = 300000, drain_deadline_milliseconds = 60000 }"
      ++ ", parent_registration = None { parent_cluster_id : Text, parent_authority_endpoint : Text } }"

localBrokerStoreBucket :: String
localBrokerStoreBucket = "prodbox-objects"

brokerPod :: String -> String
brokerPod tag =
  unlines
    [ "apiVersion: apps/v1"
    , "kind: Deployment"
    , "metadata: {name: bootstrap-broker, namespace: " ++ brokerNamespace ++ ", labels: " ++ labels ++ "}"
    , "spec:"
    , "  replicas: 1"
    , "  strategy: {type: Recreate}"
    , "  selector: {matchLabels: {app.kubernetes.io/name: prodbox-bootstrap-broker, app.kubernetes.io/instance: "
        ++ brokerNamespace
        ++ "}}"
    , "  template:"
    , "    metadata: {labels: "
        ++ labels
        ++ ", annotations: {prodbox.io/image-build-id: \""
        ++ tag
        ++ "\"}}"
    , "    spec:"
    , "      serviceAccountName: prodbox-bootstrap-broker"
    , "      containers:"
    , "      - name: bootstrap-broker"
    , "        image: " ++ tag
    , "        imagePullPolicy: Never"
    , "        args: [bootstrap-broker, start, --config, /etc/bootstrap-broker/config/config.dhall]"
    , "        ports: [{name: broker, containerPort: " ++ show brokerPort ++ ", protocol: TCP}]"
    , "        resources: {requests: {cpu: 50m, memory: 128Mi}, limits: {cpu: 500m, memory: 512Mi}}"
    , "        volumeMounts: [{name: config, mountPath: /etc/bootstrap-broker/config, readOnly: true}]"
    , "      volumes:"
    , "      - {name: config, configMap: {name: bootstrap-broker-config}}"
    , "---"
    , "apiVersion: v1"
    , "kind: Service"
    , "metadata: {name: bootstrap-broker, namespace: " ++ brokerNamespace ++ "}"
    , "spec: {selector: {app.kubernetes.io/name: prodbox-bootstrap-broker, app.kubernetes.io/instance: "
        ++ brokerNamespace
        ++ "}, ports: [{name: broker, port: "
        ++ show brokerPort
        ++ ", targetPort: broker}]}"
    ]
 where
  labels =
    "{app.kubernetes.io/name: prodbox-bootstrap-broker, app.kubernetes.io/instance: "
      ++ brokerNamespace
      ++ ", app.kubernetes.io/managed-by: prodbox, prodbox.io/chart-root: bootstrap-broker}"

-- | Ask the Broker's own loopback readiness route from inside its Pod, retrying
-- while it initializes its store and observes its dependencies.
waitReady
  :: (Int -> [String] -> ByteString.ByteString -> IO (Either String (Int, String, String)))
  -> IO ServiceStep
waitReady kubectl = go (30 :: Int) ""
 where
  go attempts lastState = do
    state <- observeBrokerReadiness kubectl
    case state of
      Right text
        | "\"ready\":true" `isInfixOf` text ->
            pure
              (ServiceStep "broker-ready" True ("the Broker's own readiness route answers: " ++ take 160 text))
      Right text | attempts > 0 -> threadDelay 3000000 >> go (attempts - 1) text
      Left reason | attempts > 0 -> threadDelay 3000000 >> go (attempts - 1) reason
      Right text -> pure (ServiceStep "broker-ready" False ("the Broker is not ready: " ++ take 200 text))
      Left reason ->
        pure
          ( ServiceStep
              "broker-ready"
              False
              ("the Broker is not reachable: " ++ take 200 (if null reason then lastState else reason))
          )

-- | The Broker's readiness answer, read through its own loopback listener.
observeBrokerReadiness
  :: (Int -> [String] -> ByteString.ByteString -> IO (Either String (Int, String, String)))
  -> IO (Either String String)
observeBrokerReadiness kubectl = do
  result <-
    kubectl
      30
      [ "-n"
      , brokerNamespace
      , "exec"
      , "deploy/bootstrap-broker"
      , "--"
      , "/bin/bash"
      , "-c"
      , "exec 3<>/dev/tcp/127.0.0.1/"
          ++ show brokerPort
          ++ "; printf 'GET /readyz HTTP/1.0\\r\\nHost: x\\r\\n\\r\\n' >&3; cat <&3"
      ]
      ByteString.empty
  pure $ case result of
    Right (0, out, _) -> Right (reverse (takeWhile (/= '\n') (reverse (filter (/= '\r') out))))
    Right (code, _, err) -> Left ("exec exit " ++ show code ++ ": " ++ take 120 err)
    Left failure -> Left failure
