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

import Control.Monad (foldM)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope (scopeKindName, scopeRoot)
import Prodbox.Control.BrokerDeploy (deployBroker, observeBrokerReadiness)
import Prodbox.Control.DockerIdentity (readDocker)
import Prodbox.Control.KindNodeBootstrap (writeJournalRecord)
import Prodbox.Control.ManagementPolicy (managementNamespace, managementPolicyManifest)
import Prodbox.Control.NetworkEnforcement
  ( EnforcementOutcome (..)
  , enforcementProven
  , observeNetworkEnforcement
  )
import Prodbox.Control.ServiceSupport (ServiceStep (..), importImageStep, run)
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
  let scope = bootstrapScope bootstrap
      root = scopeRoot scope
      kubeconfig = root </> "control" </> "kubeconfig"
      node = scopeKindName scope ++ "-control-plane"
      socket = bootstrapRuntimeSocket bootstrap
      docker arguments = run 120 "/usr/bin/docker" (["--host", "unix://" ++ socket] ++ arguments) ByteString.empty
      kubectl seconds arguments input =
        run
          seconds
          "/usr/bin/kubectl"
          (["--kubeconfig", kubeconfig, "--request-timeout=60s"] ++ arguments)
          input
      importAll = foldM $ \steps (name, path, reference) ->
        if all serviceStepOk steps
          then (\step -> steps ++ [step]) <$> importImageStep name path reference node
          else pure steps
  present <- doesFileExist kubeconfig
  running <- readDocker socket ["inspect", "--format", "{{.State.Running}}", node]
  if not present || fmap (take 4 . dropWhile (== ' ')) running /= Just "true"
    then
      pure
        ( ServicesOutcome
            [ ServiceStep
                "environment"
                False
                "no running recorded node and installed cluster credential; run `control reconcile` first"
            ]
        )
    else do
      attempt <-
        writeJournalRecord
          bootstrap
          "kind-services-attempt.json"
          ( Aeson.object
              [ (Key.fromString "schema_version", Aeson.Number 1)
              , (Key.fromString "kind", Aeson.String "kind-services-attempt")
              ]
          )
      -- 1. the management policy must be enforced before any secret exists.
      enforcement <- observeNetworkEnforcement kubeconfig "prodbox-services-gate"
      let proven = maybe False enforcementProven (enforcementObservation enforcement)
          gate =
            ServiceStep
              "enforcement-gate"
              proven
              ( if proven
                  then "pinned management policy enforced by real sockets before any secret is created"
                  else
                    "enforcement not proven ("
                      ++ maybe "no observation" (const "observation incomplete") (enforcementObservation enforcement)
                      ++ "); no secret was created"
              )
      if not proven
        then pure (ServicesOutcome [gate])
        else do
          -- 2. archives
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
          vaultArchive <- saveVaultArchive docker root
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
                then pure (ServicesOutcome imported)
                else do
                  created <- prepareAndApply root kubeconfig kubectl
                  broker <-
                    if all serviceStepOk created
                      then deployBroker socket root node (scopeKindName scope) docker kubectl
                      else pure []
                  let steps = imported ++ created ++ broker
                  _ <-
                    writeJournalRecord
                      bootstrap
                      "kind-services-result.json"
                      ( Aeson.object
                          [ (Key.fromString "schema_version", Aeson.Number 1)
                          , (Key.fromString "kind", Aeson.String "kind-services-result")
                          , (Key.fromString "attempt_recorded", Aeson.Bool attempt)
                          , (Key.fromString "ok", Aeson.Bool (all serviceStepOk steps))
                          ]
                      )
                  pure (ServicesOutcome steps)
            _ -> pure (ServicesOutcome (gate : archiveSteps))

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
  -> FilePath
  -> (Int -> [String] -> ByteString.ByteString -> IO (Either String (Int, String, String)))
  -> IO [ServiceStep]
prepareAndApply root _ kubectl = do
  createDirectoryIfMissing False (root </> "minio-data")
  setFileMode (root </> "minio-data") 0o700
  createDirectoryIfMissing False (root </> "vault-data")
  setFileMode (root </> "vault-data") 0o700
  -- Each credential is created once and reused so existing MinIO data stays
  -- reachable; it is written 0600 and never printed.
  -- MinIO's root credential is the compiled bootstrap-floor credential the
  -- Broker's store boundary uses; the unlock-object reader below is per
  -- environment and random.
  let (finalUser, finalPassword) = (minioRootUser, minioRootPassword)
  (readerUser, readerPassword) <-
    loadOrCreateCredential (root </> "control" </> "minio-unlock-reader-credential") "unlock-reader"
  namespaceStep <- apply "namespace" namespaceManifest
  policyStep <- apply "management-policy" (managementPolicyManifest managementNamespace)
  secretStep <-
    apply "bootstrap-credential" (secretManifest "minio-bootstrap-credential" finalUser finalPassword)
  readerSecretStep <-
    apply
      "unlock-reader-credential"
      (secretManifest "minio-unlock-reader-credential" readerUser readerPassword)
  servicesStep <- apply "services" servicesManifest
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
  let waitStep = case waited of
        Right (0, _, _) -> ServiceStep "services-ready" True "MinIO, Vault and the MinIO client pods report Ready"
        Right (code, _, err) -> ServiceStep "services-ready" False ("wait exit " ++ show code ++ ": " ++ take 200 err)
        Left failure -> ServiceStep "services-ready" False failure
  minio <- proxyGet "minio-direct" "minio:9000" "minio/health/ready"
  vault <-
    proxyGet "vault-direct" "vault:8200" "v1/sys/health?uninitcode=200&sealedcode=200&standbyok=true"
  reader <- unlockReaderStep
  pure
    [ namespaceStep
    , policyStep
    , secretStep
    , readerSecretStep
    , servicesStep
    , waitStep
    , minio
    , vault
    , reader
    ]
 where
  -- The pre-Vault read capability: a MinIO user whose policy allows exactly
  -- GetObject on the one unlock object, created with the root credential
  -- inside the client Pod. Re-running replaces it with the same definition.
  unlockReaderStep = do
    let script =
          "mc alias set local http://minio:9000 \"$MINIO_USER\" \"$MINIO_PASSWORD\" >/dev/null 2>&1 && "
            ++ "printf '%s' '{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\"],\"Resource\":[\"arn:aws:s3:::prodbox-bootstrap/vault-unlock-test.json\"]}]}' > /tmp/unlock-read.json && "
            ++ "(mc admin policy create local unlock-object-read /tmp/unlock-read.json >/dev/null 2>&1 || true) && "
            ++ "mc admin user add local \"$MINIO_READER_USER\" \"$MINIO_READER_PASSWORD\" >/dev/null 2>&1 && "
            ++ "mc admin policy attach local unlock-object-read --user \"$MINIO_READER_USER\" >/dev/null 2>&1; "
            ++ "mc admin user info local \"$MINIO_READER_USER\" 2>&1 | grep -c unlock-object-read"
    result <-
      kubectl 90 ["-n", managementNamespace, "exec", "mc", "--", "/bin/sh", "-c", script] ByteString.empty
    pure $ case result of
      Right (0, out, _)
        | take 1 (words out) == ["1"] ->
            ServiceStep "unlock-reader" True "a MinIO user limited to reading the unlock object exists"
      Right (code, out, err) -> ServiceStep "unlock-reader" False ("exit " ++ show code ++ ": " ++ take 120 (out ++ err))
      Left failure -> ServiceStep "unlock-reader" False failure
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
