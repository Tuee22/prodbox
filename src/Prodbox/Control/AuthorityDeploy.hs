{-# LANGUAGE OverloadedStrings #-}

-- | Deploy the repository's real Lifecycle Authority runtime into a test
-- environment next to the pinned MinIO, Vault and Bootstrap Broker. It reuses
-- the Broker's locally built runtime image (already imported into the node, so
-- no registry is involved), renders the role's Dhall configuration with the
-- repository's own generator and points its Vault address at the management
-- Vault, and applies a namespace, ServiceAccount, ConfigMap, Deployment and
-- Service. Readiness is read from the Pod itself; on failure the tail of the
-- container log is reported so the next precondition can be read directly.
module Prodbox.Control.AuthorityDeploy
  ( deployAuthority
  , authorityNamespace
  ) where

import Control.Concurrent (threadDelay)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope (scopeKindName, scopeRoot)
import Prodbox.Control.BrokerDeploy (runtimeImageTag, runtimeRepository)
import Prodbox.Control.ManagementPolicy (managementNamespace)
import Prodbox.Control.ServiceSupport (ServiceStep (..), run)
import Prodbox.ControlPlane.AuthorityJournalReadServer (journalReadServiceAccount)
import Prodbox.ControlPlane.ListenPort (authorityJournalReadPort, controlPlaneListenPort)
import Prodbox.Lib.ChartPlatform (ResolvedCustomImage (..), valuesForLifecycleAuthority)
import Prodbox.Minio.ObjectStoreTypes (defaultObjectStoreBucket)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

authorityNamespace :: String
authorityNamespace = "lifecycle-authority"

deployAuthority :: BootstrapProjection -> IO [ServiceStep]
deployAuthority bootstrap = do
  let scope = bootstrapScope bootstrap
      root = scopeRoot scope
      kubeconfig = root </> "control" </> "kubeconfig"
      socket = bootstrapRuntimeSocket bootstrap
      clusterId = Text.pack (scopeKindName scope)
      docker arguments = run 60 "/usr/bin/docker" (["--host", "unix://" ++ socket] ++ arguments) ByteString.empty
      kubectl seconds arguments input =
        run
          seconds
          "/usr/bin/kubectl"
          (["--kubeconfig", kubeconfig, "--request-timeout=60s"] ++ arguments)
          input
  -- The retained journal directory is operator-created (a kubelet-created one
  -- would be root-owned and block unprivileged cleanup of the retained root).
  createDirectoryIfMissing False (root </> "authority-journal")
  setFileMode (root </> "authority-journal") 0o700
  tag <- runtimeImageTag
  identified <- docker ["inspect", "--format", "{{.Id}}", tag]
  case identified of
    Right (0, out, _) -> do
      let imageId = filter (`notElem` ("\n\r " :: String)) out
          image =
            ResolvedCustomImage
              runtimeRepository
              (drop 1 (dropWhile (/= ':') (drop (length runtimeRepository) tag)))
              (Just imageId)
              (Just imageId)
      case valuesForLifecycleAuthority
        clusterId
        (Text.pack ("http://minio." ++ managementNamespace ++ ".svc:9000"))
        authorityNamespace
        "lifecycle-authority"
        (Just image) of
        Left refusal -> pure [ServiceStep "authority-config" False refusal]
        Right values -> case roleDhall values of
          Nothing -> pure [ServiceStep "authority-config" False "the generated values carry no role configuration"]
          Just dhall -> do
            let patched =
                  replaceAll
                    "vault.vault.svc.cluster.local"
                    ("vault." ++ managementNamespace ++ ".svc.cluster.local")
                    dhall
            applied <- kubectl 90 ["apply", "-f", "-"] (ByteString8.pack (manifest tag patched))
            case applied of
              Right (0, _, _) -> do
                seeded <- seedStore kubectl
                if not (serviceStepOk seeded)
                  then
                    pure
                      [ ServiceStep "authority-config" True "role configuration rendered"
                      , ServiceStep "authority-apply" True "manifests applied"
                      , seeded
                      ]
                  else do
                    _ <-
                      kubectl
                        60
                        [ "-n"
                        , authorityNamespace
                        , "delete"
                        , "pod"
                        , "-l"
                        , "app.kubernetes.io/name=prodbox-lifecycle-authority"
                        , "--wait=true"
                        ]
                        ByteString.empty
                    ready <- waitReady kubectl
                    pure
                      [ ServiceStep "authority-config" True "role configuration rendered"
                      , ServiceStep "authority-apply" True "manifests applied"
                      , seeded
                      , ready
                      ]
              Right (code, _, err) ->
                pure
                  [ServiceStep "authority-apply" False ("kubectl apply exit " ++ show code ++ ": " ++ take 300 err)]
              Left failure -> pure [ServiceStep "authority-apply" False failure]
    _ ->
      pure
        [ ServiceStep
            "authority-image"
            False
            "the runtime image is not present locally; run `control services` first"
        ]

roleDhall :: Aeson.Value -> Maybe String
roleDhall (Aeson.Object top) = do
  Aeson.Object config <- KeyMap.lookup (Key.fromString "config") top
  Aeson.String text <- KeyMap.lookup (Key.fromString "roleDhall") config
  pure (Text.unpack text)
roleDhall _ = Nothing

replaceAll :: String -> String -> String -> String
replaceAll needle replacement = go
 where
  go [] = []
  go text@(c : rest)
    | needle `isInfixOf` take (length needle) text && take (length needle) text == needle =
        replacement ++ go (drop (length needle) text)
    | otherwise = c : go rest

manifest :: String -> String -> String
manifest tag dhall =
  unlines
    [ "apiVersion: v1"
    , "kind: Namespace"
    , "metadata: {name: " ++ authorityNamespace ++ "}"
    , "---"
    , "apiVersion: v1"
    , "kind: ServiceAccount"
    , "metadata: {name: prodbox-lifecycle-authority, namespace: " ++ authorityNamespace ++ "}"
    , "---"
    , "apiVersion: v1"
    , "kind: ConfigMap"
    , "metadata: {name: lifecycle-authority-config, namespace: " ++ authorityNamespace ++ "}"
    , "data:"
    , "  config.dhall: |"
    ]
    ++ unlines (map ("    " ++) (lines dhall))
    ++ unlines
      [ "---"
      , "apiVersion: apps/v1"
      , "kind: Deployment"
      , "metadata: {name: lifecycle-authority, namespace: "
          ++ authorityNamespace
          ++ ", labels: "
          ++ labels
          ++ "}"
      , "spec:"
      , "  replicas: 1"
      , "  strategy: {type: Recreate}"
      , "  selector: {matchLabels: {app.kubernetes.io/name: prodbox-lifecycle-authority}}"
      , "  template:"
      , "    metadata: {labels: "
          ++ labels
          ++ ", annotations: {prodbox.io/image-build-id: \""
          ++ tag
          ++ "\"}}"
      , "    spec:"
      , "      serviceAccountName: prodbox-lifecycle-authority"
      , "      containers:"
      , "      - name: lifecycle-authority"
      , "        image: " ++ tag
      , "        imagePullPolicy: Never"
      , "        args: [lifecycle-authority, start, --config, /etc/lifecycle-authority/config/config.dhall]"
      , "        ports: [{name: authority, containerPort: "
          ++ show controlPlaneListenPort
          ++ ", protocol: TCP}, {name: journal-read, containerPort: "
          ++ show authorityJournalReadPort
          ++ ", protocol: TCP}]"
      , "        readinessProbe: {httpGet: {path: /readyz, port: authority}, periodSeconds: 5, failureThreshold: 6}"
      , "        resources: {requests: {cpu: 50m, memory: 128Mi}, limits: {cpu: 500m, memory: 512Mi}}"
      , "        volumeMounts:"
      , "        - {name: config, mountPath: /etc/lifecycle-authority/config, readOnly: true}"
      , "        - {name: journal, mountPath: /var/lib/prodbox/lifecycle-authority-journal}"
      , "      volumes:"
      , "      - {name: config, configMap: {name: lifecycle-authority-config}}"
      , "      - {name: journal, hostPath: {path: /var/lib/prodbox/authority-journal, type: Directory}}"
      , "---"
      , "apiVersion: v1"
      , "kind: Service"
      , "metadata: {name: lifecycle-authority, namespace: " ++ authorityNamespace ++ "}"
      , "spec: {selector: {app.kubernetes.io/name: prodbox-lifecycle-authority}, ports: [{name: authority, port: "
          ++ show controlPlaneListenPort
          ++ ", targetPort: authority}, {name: journal-read, port: "
          ++ show authorityJournalReadPort
          ++ ", targetPort: journal-read}]}"
      , "---"
      , "apiVersion: v1"
      , "kind: ServiceAccount"
      , "metadata: {name: "
          ++ Text.unpack journalReadServiceAccount
          ++ ", namespace: "
          ++ authorityNamespace
          ++ "}"
      , "---"
      , "apiVersion: rbac.authorization.k8s.io/v1"
      , "kind: ClusterRoleBinding"
      , "metadata: {name: " ++ authorityNamespace ++ "-token-reviewer}"
      , "roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: system:auth-delegator}"
      , "subjects: [{kind: ServiceAccount, name: prodbox-lifecycle-authority, namespace: "
          ++ authorityNamespace
          ++ "}]"
      ]
 where
  labels = "{app.kubernetes.io/name: prodbox-lifecycle-authority, app.kubernetes.io/managed-by: prodbox}"

-- | Ask the Authority's own readiness route from inside its Pod (the loopback
-- listener), retrying while it starts; otherwise report the log tail.
waitReady
  :: (Int -> [String] -> ByteString.ByteString -> IO (Either String (Int, String, String)))
  -> IO ServiceStep
waitReady kubectl = go (40 :: Int) ""
 where
  go attempts lastState = do
    state <-
      kubectl
        30
        [ "-n"
        , authorityNamespace
        , "exec"
        , "deploy/lifecycle-authority"
        , "--"
        , "/bin/bash"
        , "-c"
        , "exec 3<>/dev/tcp/127.0.0.1/"
            ++ show controlPlaneListenPort
            ++ "; printf 'GET /readyz HTTP/1.0\\r\\nHost: x\\r\\n\\r\\n' >&3; cat <&3"
        ]
        ByteString.empty
    case state of
      Right (0, out, _)
        | "200" `isInfixOf` take 20 out -> do
            -- The Pod's own Ready condition (its readiness probe) must agree.
            conditioned <-
              kubectl
                90
                [ "-n"
                , authorityNamespace
                , "wait"
                , "--for=condition=Ready"
                , "pod"
                , "-l"
                , "app.kubernetes.io/name=prodbox-lifecycle-authority"
                , "--timeout=80s"
                ]
                ByteString.empty
            pure $ case conditioned of
              Right (0, _, _) ->
                ServiceStep
                  "authority-ready"
                  True
                  ( "the Authority's own readiness route answers and the Pod is Ready: "
                      ++ take 100 (reverse (takeWhile (/= '\n') (reverse (filter (/= '\r') out))))
                  )
              _ ->
                ServiceStep
                  "authority-ready"
                  False
                  "the readiness route answers but the Pod's Ready condition did not hold"
      Right (_, out, err) | attempts > 0 -> threadDelay 3000000 >> go (attempts - 1) (take 120 (out ++ err))
      Left failure | attempts > 0 -> threadDelay 3000000 >> go (attempts - 1) failure
      _ -> do
        logs <-
          kubectl
            30
            ["-n", authorityNamespace, "logs", "deploy/lifecycle-authority", "--tail=12"]
            ByteString.empty
        pure
          ( ServiceStep
              "authority-ready"
              False
              ( "the Authority is not ready ("
                  ++ lastState
                  ++ "); log tail: "
                  ++ either id (\(_, out, err) -> take 1500 (out ++ err)) logs
              )
          )

-- | Create the MinIO user the Authority's store credentials name. The
-- credentials already exist in Vault KV (written by the baseline); they are
-- read with the Authority's own Kubernetes identity, held only in memory and
-- passed on standard input to the management client Pod, which creates the
-- bucket, the user and a policy scoped to that bucket.
seedStore
  :: (Int -> [String] -> ByteString.ByteString -> IO (Either String (Int, String, String)))
  -> IO ServiceStep
seedStore kubectl = do
  minted <-
    kubectl
      60
      ["-n", authorityNamespace, "create", "token", "prodbox-lifecycle-authority", "--duration", "600s"]
      ByteString.empty
  case minted of
    Right (0, token, _) -> do
      let loginScript =
            "read -r JWT; export VAULT_ADDR=http://127.0.0.1:8200; "
              ++ "TOK=$(vault write -field=token auth/kubernetes/login role=prodbox-lifecycle-authority jwt=\"$JWT\") && "
              ++ "VAULT_TOKEN=$TOK vault kv get -format=json secret/minio/lifecycle-authority"
      fetched <-
        kubectl
          60
          ["-n", managementNamespace, "exec", "-i", "vault", "--", "/bin/sh", "-c", loginScript]
          (ByteString8.pack (filter (/= '\n') token ++ "\n"))
      case fetched of
        Right (0, out, _) -> case credentials out of
          Nothing ->
            pure (ServiceStep "authority-store" False "Vault answered but the credential fields are missing")
          Just (user, password) -> do
            let bucket = defaultObjectStoreBucket
                policy =
                  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:*\"],\"Resource\":[\"arn:aws:s3:::"
                    ++ bucket
                    ++ "\",\"arn:aws:s3:::"
                    ++ bucket
                    ++ "/*\"]}]}"
                script =
                  "read -r U; read -r P; "
                    ++ "mc alias set local http://minio:9000 \"$MINIO_USER\" \"$MINIO_PASSWORD\" >/dev/null 2>&1 && "
                    ++ ("mc mb --ignore-existing local/" ++ bucket ++ " >/dev/null && ")
                    ++ "mc admin user add local \"$U\" \"$P\" >/dev/null && "
                    ++ ("printf '%s' '" ++ policy ++ "' > /tmp/authority-policy.json && ")
                    ++ "(mc admin policy create local authority-store /tmp/authority-policy.json >/dev/null 2>&1 || true) && "
                    ++ "mc admin policy attach local authority-store --user \"$U\" >/dev/null"
            created <-
              kubectl
                90
                ["-n", managementNamespace, "exec", "-i", "mc", "--", "/bin/sh", "-c", script]
                (ByteString8.pack (user ++ "\n" ++ password ++ "\n"))
            pure $ case created of
              Right (0, _, _) ->
                ServiceStep
                  "authority-store"
                  True
                  ("the store user and a bucket-scoped policy exist in MinIO for bucket " ++ bucket)
              Right (code, _, err) -> ServiceStep "authority-store" False ("mc exit " ++ show code ++ ": " ++ take 200 err)
              Left failure -> ServiceStep "authority-store" False failure
        Right (code, _, err) ->
          pure
            ( ServiceStep
                "authority-store"
                False
                ("reading the credential from Vault exit " ++ show code ++ ": " ++ take 200 err)
            )
        Left failure -> pure (ServiceStep "authority-store" False failure)
    _ -> pure (ServiceStep "authority-store" False "a ServiceAccount token could not be minted")
 where
  credentials out = do
    value <- Aeson.decodeStrict (ByteString8.pack out)
    AesonTypes.parseMaybe
      ( Aeson.withObject "kv" $ \top -> do
          outer <- top Aeson..: Key.fromString "data"
          inner <- outer Aeson..: Key.fromString "data"
          user <- inner Aeson..: Key.fromString "minio_access_key"
          password <- inner Aeson..: Key.fromString "minio_secret_key"
          pure (Text.unpack user, Text.unpack password)
      )
      value
