{-# LANGUAGE OverloadedStrings #-}

module Prodbox.K8s.InCluster
  ( InClusterCredentials (..)
  , inClusterServiceAccountDir
  , inClusterTokenPath
  , inClusterCaCertPath
  , inClusterNamespacePath
  , loadInClusterCredentials
  , secretApiPath
  , secretApiBaseUrl
  , secretManifestJson
  , secretManifestStringData
  , K8sSecretOps (..)
  , inClusterK8sSecretOps
  )
where

import Control.Exception (IOException, SomeException, try)
import Data.Aeson (Value (..), eitherDecode, encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.X509.CertificateStore (readCertificateStore)
import Network.Connection (TLSSettings (..))
import Network.HTTP.Client
  ( Manager
  , Request (..)
  , RequestBody (..)
  , Response
  , httpLbs
  , newManager
  , parseRequest
  , responseBody
  , responseStatus
  )
import Network.HTTP.Client.TLS (mkManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Network.TLS
  ( ClientParams (..)
  , Shared (..)
  , defaultParamsClient
  )
import System.Directory (doesFileExist)

-- | Sprint 3.13 second chunk: credentials projected into every pod by
--   Kubernetes for the pod's @ServiceAccount@. Lives under the standard
--   in-pod path
--   @/var/run/secrets/kubernetes.io/serviceaccount/@ unless overridden
--   via the same-named mount.
data InClusterCredentials = InClusterCredentials
  { inClusterCredentialsToken :: Text
  , inClusterCredentialsCaCertPath :: FilePath
  , inClusterCredentialsNamespace :: Text
  }
  deriving (Eq, Show)

-- | Canonical in-pod ServiceAccount mount directory.
inClusterServiceAccountDir :: FilePath
inClusterServiceAccountDir = "/var/run/secrets/kubernetes.io/serviceaccount"

-- | Path of the bearer-token file the pod's ServiceAccount projects.
inClusterTokenPath :: FilePath
inClusterTokenPath = inClusterServiceAccountDir ++ "/token"

-- | Path of the API server's CA certificate (PEM) the pod's
--   ServiceAccount projects. Callers pass this directly to
--   @tls-client-cafile@ / @http-client-tls@'s @ManagerSettings@ so the
--   API request verifies against the cluster's internal CA, not the
--   system trust store.
inClusterCaCertPath :: FilePath
inClusterCaCertPath = inClusterServiceAccountDir ++ "/ca.crt"

-- | Path of the file holding the pod's own namespace string.
inClusterNamespacePath :: FilePath
inClusterNamespacePath = inClusterServiceAccountDir ++ "/namespace"

-- | Sprint 3.13 second chunk: read the in-pod ServiceAccount
--   credentials from disk. Fails @Left@ if any of @token@, @ca.crt@, or
--   @namespace@ is missing — those files are projected automatically
--   when a pod has any ServiceAccount, so absence indicates the daemon
--   is running outside Kubernetes (e.g. an operator-host smoke run).
--   The 'inClusterCredentialsCaCertPath' field is returned as a path
--   rather than the cert bytes because @http-client-tls@'s
--   @TLSSettings@ wants a path or a 'CertificateStore', and reading
--   the bytes here would force the caller to re-write them to disk.
loadInClusterCredentials :: IO (Either String InClusterCredentials)
loadInClusterCredentials = do
  tokenExists <- doesFileExist inClusterTokenPath
  caExists <- doesFileExist inClusterCaCertPath
  nsExists <- doesFileExist inClusterNamespacePath
  case (tokenExists, caExists, nsExists) of
    (False, _, _) ->
      pure
        ( Left
            ( "in-pod ServiceAccount token not found at "
                ++ inClusterTokenPath
                ++ " (is the daemon running inside Kubernetes?)"
            )
        )
    (_, False, _) ->
      pure
        ( Left
            ("in-pod ServiceAccount CA cert not found at " ++ inClusterCaCertPath)
        )
    (_, _, False) ->
      pure
        ( Left
            ( "in-pod ServiceAccount namespace file not found at "
                ++ inClusterNamespacePath
            )
        )
    (True, True, True) -> do
      tokenResult <- try (readFile inClusterTokenPath) :: IO (Either IOException String)
      nsResult <- try (readFile inClusterNamespacePath) :: IO (Either IOException String)
      pure $ case (tokenResult, nsResult) of
        (Left exc, _) -> Left ("failed to read ServiceAccount token: " ++ show exc)
        (_, Left exc) -> Left ("failed to read ServiceAccount namespace: " ++ show exc)
        (Right tokenContents, Right nsContents) ->
          let trimmedToken = Text.strip (Text.pack tokenContents)
              trimmedNs = Text.strip (Text.pack nsContents)
           in if Text.null trimmedToken
                then Left "in-pod ServiceAccount token file is empty"
                else
                  if Text.null trimmedNs
                    then Left "in-pod ServiceAccount namespace file is empty"
                    else
                      Right
                        InClusterCredentials
                          { inClusterCredentialsToken = trimmedToken
                          , inClusterCredentialsCaCertPath = inClusterCaCertPath
                          , inClusterCredentialsNamespace = trimmedNs
                          }

-- | Sprint 3.13 second chunk: API server base URL for the in-cluster
--   kube-apiserver. Always
--   @https://kubernetes.default.svc.cluster.local:443@; the DNS name
--   resolves via the cluster's CoreDNS to the kube-apiserver Service's
--   ClusterIP, and TLS is verified against the per-pod CA in
--   'inClusterCaCertPath'. The port is included so the URL is
--   complete for downstream @http-client@-style consumers; downstream
--   defaults to @443@ but expressing it inline matches the doctrine
--   §4 examples in
--   [Secret Derivation Doctrine](../../documents/engineering/secret_derivation_doctrine.md).
secretApiBaseUrl :: String
secretApiBaseUrl = "https://kubernetes.default.svc.cluster.local:443"

-- | Sprint 3.13 second chunk: REST path for a single namespaced
--   @v1.Secret@ object. Used both for GET (existence check) and
--   PATCH / PUT (create-or-update) requests.
secretApiPath :: Text -> Text -> String
secretApiPath namespace name =
  "/api/v1/namespaces/" ++ Text.unpack namespace ++ "/secrets/" ++ Text.unpack name

-- | Sprint 3.13 second chunk: build the JSON body for a @v1.Secret@
--   with @type: Opaque@ and the given @stringData@ map. Mirrors what
--   @kubectl apply -f -@ would PUT against the API server's
--   @/api/v1/namespaces/<ns>/secrets@ collection. Encoding the value
--   as 'stringData' (rather than already-base64-encoded 'data') lets
--   the API server do the base64 step server-side, which matches every
--   chart manifest in @charts/*/templates/secret.yaml@ and keeps the
--   materialization pipeline working on the raw 'Text' value Vault-backed
--   callers provide.
secretManifestJson :: Text -> Text -> Map Text Text -> Value
secretManifestJson namespace name stringData =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("Secret" :: Text)
    , "metadata"
        .= object
          [ "name" .= name
          , "namespace" .= namespace
          ]
    , "type" .= ("Opaque" :: Text)
    , "stringData" .= secretManifestStringData stringData
    ]

-- | Sprint 3.13 second chunk: stable encoding of the @stringData@ map
--   as a JSON object. Exposed separately so unit tests can pin the
--   key-ordering / Unicode-safety contract without re-parsing the
--   full manifest envelope. Keys are emitted in ascending lexical
--   order so the rendered JSON is byte-deterministic per the
--   doctrine's deterministic-renderer rule.
secretManifestStringData :: Map Text Text -> Value
secretManifestStringData stringData =
  object [Key.fromText k .= v | (k, v) <- Map.toAscList stringData]

-- | Capability record bundling namespaced @v1.Secret@ operations. The
--   production constructor is built atop 'http-client-tls' with the in-pod
--   CA store and ServiceAccount bearer token.
--
-- * 'secretOpsGet' returns @Right Nothing@ for an absent Secret
--   (HTTP 404), @Right (Just value)@ for an existing one, and @Left@
--   for any other error (network, auth, malformed body).
-- * 'secretOpsPut' is create-or-replace: it submits the full manifest
--   and the API server decides whether to insert or update.
data K8sSecretOps = K8sSecretOps
  { secretOpsGet :: Text -> Text -> IO (Either String (Maybe Value))
  , secretOpsPut :: Text -> Text -> Value -> IO (Either String ())
  }

-- | Sprint 3.13 fourth chunk: TLS-backed 'K8sSecretOps' for the
--   in-pod gateway daemon. Builds an HTTP 'Manager' configured against
--   the in-pod CA store loaded from 'inClusterCredentialsCaCertPath'
--   (so the API server's serving cert verifies against the cluster's
--   internal CA, not the system trust store), and injects the
--   ServiceAccount bearer token on every request. Fails @Left@ if the
--   CA cert cannot be read (e.g. running outside Kubernetes).
inClusterK8sSecretOps :: InClusterCredentials -> IO (Either String K8sSecretOps)
inClusterK8sSecretOps creds = do
  caStoreM <- readCertificateStore (inClusterCredentialsCaCertPath creds)
  case caStoreM of
    Nothing ->
      pure
        ( Left
            ( "failed to read in-pod CA certificate at "
                ++ inClusterCredentialsCaCertPath creds
            )
        )
    Just caStore -> do
      let host = "kubernetes.default.svc.cluster.local"
          baseParams = defaultParamsClient host ""
          clientParams =
            baseParams {clientShared = (clientShared baseParams) {sharedCAStore = caStore}}
          tlsSettings = TLSSettings clientParams
      manager <- newManager (mkManagerSettings tlsSettings Nothing)
      let token = inClusterCredentialsToken creds
      pure
        ( Right
            K8sSecretOps
              { secretOpsGet = httpGetSecret manager token
              , secretOpsPut = httpPutSecret manager token
              }
        )

-- | Sprint 3.13 fourth chunk: GET @/api/v1/namespaces/<ns>/secrets/<name>@.
--   Returns @Right Nothing@ on 404, @Right (Just value)@ on 200 with a
--   parseable JSON body, and @Left@ for everything else.
httpGetSecret
  :: Manager -> Text -> Text -> Text -> IO (Either String (Maybe Value))
httpGetSecret manager token namespace name = do
  let url = secretApiBaseUrl ++ secretApiPath namespace name
  reqResult <-
    try (parseRequest url) :: IO (Either SomeException Request)
  case reqResult of
    Left exc -> pure (Left ("parseRequest failed: " ++ show exc))
    Right baseReq -> do
      let req =
            baseReq
              { method = "GET"
              , requestHeaders =
                  [ ("Authorization", TE.encodeUtf8 ("Bearer " <> token))
                  , ("Accept", "application/json")
                  ]
              }
      respResult <-
        try (httpLbs req manager) :: IO (Either SomeException (Response BL.ByteString))
      case respResult of
        Left exc -> pure (Left ("HTTP GET failed: " ++ show exc))
        Right resp ->
          case statusCode (responseStatus resp) of
            404 -> pure (Right Nothing)
            200 ->
              case eitherDecode (responseBody resp) of
                Left err -> pure (Left ("decode K8s Secret JSON: " ++ err))
                Right value -> pure (Right (Just value))
            code ->
              pure
                ( Left
                    ("K8s API GET returned " ++ show code ++ ": " ++ truncateBody (responseBody resp))
                )

-- | Sprint 3.13 fourth chunk + chunk 23 (2026-05-31 fix): create-or-update
--   a namespaced @v1.Secret@ via the k8s API. The earlier prose claimed
--   "the API server handles create-vs-update server-side" but that is
--   only true for @PATCH@ (with @application/apply-patch+yaml@, server-side
--   apply) or for the legacy three-way merge — plain @PUT@ to
--   @/api/v1/namespaces/<ns>/secrets/<name>@ returns 404 NotFound when
--   the named Secret doesn't yet exist (PUT replaces; it doesn't insert).
--   This function therefore tries @POST /api/v1/namespaces/<ns>/secrets@
--   first (create); on 409 Conflict it falls back to
--   @PUT /api/v1/namespaces/<ns>/secrets/<name>@ (update). Returns
--   @Right ()@ on a 200/201 from either path, @Left@ on any other
--   non-success status with the response body for diagnostics.
httpPutSecret
  :: Manager -> Text -> Text -> Text -> Value -> IO (Either String ())
httpPutSecret manager token namespace name manifest = do
  createResult <- httpRequestSecret manager token "POST" collectionUrl manifest
  case createResult of
    Right () -> pure (Right ())
    Left (code, body)
      | code == 409 -> do
          updateResult <-
            httpRequestSecret manager token "PUT" objectUrl manifest
          pure $ case updateResult of
            Right () -> Right ()
            Left (updateCode, updateBody) ->
              Left
                ( "K8s API PUT (fallback after 409) returned "
                    ++ show updateCode
                    ++ ": "
                    ++ truncateBody updateBody
                )
      | otherwise ->
          pure
            ( Left
                ("K8s API POST returned " ++ show code ++ ": " ++ truncateBody body)
            )
 where
  collectionUrl =
    secretApiBaseUrl ++ "/api/v1/namespaces/" ++ Text.unpack namespace ++ "/secrets"
  objectUrl = secretApiBaseUrl ++ secretApiPath namespace name

-- | Submit a JSON request to the k8s API. Returns @Right ()@ on
-- 200/201; @Left (statusCode, body)@ on any other status so the caller
-- can branch on specific codes (e.g. 409 Conflict → PUT fallback).
httpRequestSecret
  :: Manager
  -> Text
  -> BS.ByteString
  -> String
  -> Value
  -> IO (Either (Int, BL.ByteString) ())
httpRequestSecret manager token verb url manifest = do
  reqResult <-
    try (parseRequest url) :: IO (Either SomeException Request)
  case reqResult of
    Left exc -> pure (Left (0, BL8.pack ("parseRequest failed: " ++ show exc)))
    Right baseReq -> do
      let req =
            baseReq
              { method = verb
              , requestHeaders =
                  [ ("Authorization", TE.encodeUtf8 ("Bearer " <> token))
                  , ("Content-Type", "application/json")
                  , ("Accept", "application/json")
                  ]
              , requestBody = RequestBodyLBS (encode manifest)
              }
      respResult <-
        try (httpLbs req manager) :: IO (Either SomeException (Response BL.ByteString))
      case respResult of
        Left exc ->
          pure
            ( Left
                ( 0
                , BL8.pack ("HTTP " ++ show verb ++ " failed: " ++ show exc)
                )
            )
        Right resp ->
          case statusCode (responseStatus resp) of
            200 -> pure (Right ())
            201 -> pure (Right ())
            code -> pure (Left (code, responseBody resp))

-- | Truncate the response body for inclusion in error strings so log
-- lines stay readable when the API server returns a large HTML error page.
truncateBody :: BL.ByteString -> String
truncateBody body =
  let s = BL8.unpack body
   in if length s > 200 then take 200 s ++ "…" else s
