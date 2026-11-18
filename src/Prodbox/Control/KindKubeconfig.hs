{-# LANGUAGE OverloadedStrings #-}

-- | Strict semantic projection of a selected kind kubeconfig. The caller must
-- supply a bounded, duplicate-key-rejecting decoded document and authenticate
-- its file and cluster independently; this is not a Kubernetes client.
module Prodbox.Control.KindKubeconfig
  ( KindKubeconfig
  , KindKubeconfigError (..)
  , validateKindKubeconfig
  , kindKubeconfigServer
  , kindKubeconfigContext
  , kindKubeconfigScope
  , withKindKubeconfigMaterial
  )
where

import Control.Monad (unless)
import Data.Aeson (Object, Value, withObject, (.:), (.:?))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Config.DeploymentScope (DeploymentScope, scopeApiPort, scopeKindName)

data KindKubeconfigError
  = KindKubeconfigInvalidShape
  | KindKubeconfigWrongIdentity
  | KindKubeconfigInvalidMaterial
  deriving (Eq, Show)

-- No Show instance: client private-key bytes must not enter diagnostics.
data KindKubeconfig
  = KindKubeconfig
      !DeploymentScope
      !String
      !String
      !ByteString.ByteString
      !ByteString.ByteString
      !ByteString.ByteString

kindKubeconfigServer :: KindKubeconfig -> String
kindKubeconfigServer (KindKubeconfig _ server _ _ _ _) = server

kindKubeconfigContext :: KindKubeconfig -> String
kindKubeconfigContext (KindKubeconfig _ _ context _ _ _) = context

kindKubeconfigScope :: KindKubeconfig -> DeploymentScope
kindKubeconfigScope (KindKubeconfig scope _ _ _ _ _) = scope

-- | Supply the decoded CA, client certificate and client private key to a
-- scoped consumer. The caller owns their lifetime and must not log them.
withKindKubeconfigMaterial
  :: KindKubeconfig
  -> (ByteString.ByteString -> ByteString.ByteString -> ByteString.ByteString -> IO value)
  -> IO value
withKindKubeconfigMaterial (KindKubeconfig _ _ _ ca cert key) action = action ca cert key

data RawConfig = RawConfig !String !String !String !String !String !String !String !Text !Text !Text

-- | Permit exactly one self-contained kind context and embedded client TLS
-- material, with no exec plugin, token file, proxy, external cert path or
-- insecure TLS option. Certificate parsing and TLS peer verification remain
-- separate obligations; decoding a Value does not prove file provenance.
validateKindKubeconfig :: DeploymentScope -> Value -> Either KindKubeconfigError KindKubeconfig
validateKindKubeconfig scope value = do
  RawConfig
    current
    context
    clusterRef
    userRef
    clusterName
    userName
    actualServer
    caText
    certText
    keyText <-
    either (const (Left KindKubeconfigInvalidShape)) Right (parseEither parseConfig value)
  let expected = "kind-" ++ scopeKindName scope
      server = "https://127.0.0.1:" ++ show (scopeApiPort scope)
  if all (== expected) [current, context, clusterRef, userRef, clusterName, userName]
    then pure ()
    else Left KindKubeconfigWrongIdentity
  if actualServer == server then pure () else Left KindKubeconfigWrongIdentity
  ca <- material caText
  cert <- material certText
  key <- material keyText
  pure (KindKubeconfig scope server expected ca cert key)
 where
  material raw
    | Text.length raw > 87384 = Left KindKubeconfigInvalidMaterial
    | otherwise =
        let encoded = TextEncoding.encodeUtf8 raw
         in case Base64.decode encoded of
              Right decoded
                | not (ByteString.null decoded)
                    && ByteString.length decoded <= 65536
                    && Base64.encode decoded == encoded ->
                    Right decoded
              _ -> Left KindKubeconfigInvalidMaterial

parseConfig :: Value -> Parser RawConfig
parseConfig = withObject "kubeconfig" $ \top -> do
  onlyKeys
    ["apiVersion", "kind", "preferences", "clusters", "contexts", "current-context", "users"]
    top
  apiVersion <- top .: "apiVersion"
  kind <- top .: "kind"
  unless
    (apiVersion == ("v1" :: String) && kind == ("Config" :: String))
    (fail "invalid kubeconfig type")
  preferences <- top .:? "preferences" :: Parser (Maybe Object)
  maybe (pure ()) (onlyKeys []) preferences
  clusters <- top .: "clusters"
  contexts <- top .: "contexts"
  users <- top .: "users"
  clusterValue <- singleton clusters
  contextValue <- singleton contexts
  userValue <- singleton users
  (clusterName, server, ca) <- parseCluster clusterValue
  (contextName, clusterRef, userRef) <- parseContext contextValue
  (userName, cert, key) <- parseUser userValue
  RawConfig
    <$> top .: "current-context"
    <*> pure contextName
    <*> pure clusterRef
    <*> pure userRef
    <*> pure clusterName
    <*> pure userName
    <*> pure server
    <*> pure ca
    <*> pure cert
    <*> pure key

parseCluster :: Value -> Parser (String, String, Text)
parseCluster = withObject "cluster entry" $ \entry -> do
  onlyKeys ["name", "cluster"] entry
  cluster <- entry .: "cluster"
  onlyKeys ["server", "certificate-authority-data"] cluster
  (,,) <$> entry .: "name" <*> cluster .: "server" <*> cluster .: "certificate-authority-data"

parseContext :: Value -> Parser (String, String, String)
parseContext = withObject "context entry" $ \entry -> do
  onlyKeys ["name", "context"] entry
  context <- entry .: "context"
  onlyKeys ["cluster", "user"] context
  (,,) <$> entry .: "name" <*> context .: "cluster" <*> context .: "user"

parseUser :: Value -> Parser (String, Text, Text)
parseUser = withObject "user entry" $ \entry -> do
  onlyKeys ["name", "user"] entry
  user <- entry .: "user"
  onlyKeys ["client-certificate-data", "client-key-data"] user
  (,,) <$> entry .: "name" <*> user .: "client-certificate-data" <*> user .: "client-key-data"

singleton :: [value] -> Parser value
singleton [value] = pure value
singleton _ = fail "expected exactly one entry"

onlyKeys :: [Text] -> Object -> Parser ()
onlyKeys permitted object =
  unless
    (Set.fromList (map Key.toText (KeyMap.keys object)) `Set.isSubsetOf` Set.fromList permitted)
    (fail "unexpected kubeconfig field")
