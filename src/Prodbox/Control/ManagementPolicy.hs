{-# LANGUAGE OverloadedStrings #-}

-- | The pinned management-plane network policy and its role vocabulary. The
-- manifest is a constant: its bytes (with the namespace placeholder) are
-- bound by 'managementPolicyDigest' and a unit test, so an edit changes the
-- digest and must be reviewed. Applying it proves nothing; enforcement is
-- observed with real sockets by "Prodbox.Control.NetworkEnforcement".
module Prodbox.Control.ManagementPolicy
  ( managementNamespace
  , managementPlaneLabel
  , managementClientLabel
  , managementPolicyTemplate
  , managementPolicyManifest
  , managementPolicyDigest
  ) where

import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Prodbox.Aws.SigV4 (hexSha256)

managementNamespace :: String
managementNamespace = "prodbox-management"

-- | Pods that serve management traffic carry this label.
managementPlaneLabel :: String
managementPlaneLabel = "prodbox.io/plane: management"

-- | Only pods that carry this label may reach the management plane.
managementClientLabel :: String
managementClientLabel = "prodbox.io/management-client: \"true\""

-- | Default-deny ingress for every pod in the namespace, then one allow:
-- management-plane pods accept ingress only from labelled management clients
-- in the same namespace and from the Bootstrap Broker namespace. @NAMESPACE@ is replaced before use.
managementPolicyTemplate :: String
managementPolicyTemplate =
  unlines
    [ "apiVersion: networking.k8s.io/v1"
    , "kind: NetworkPolicy"
    , "metadata: {name: management-default-deny, namespace: NAMESPACE}"
    , "spec:"
    , "  podSelector: {}"
    , "  policyTypes: [Ingress]"
    , "---"
    , "apiVersion: networking.k8s.io/v1"
    , "kind: NetworkPolicy"
    , "metadata: {name: management-allow-clients, namespace: NAMESPACE}"
    , "spec:"
    , "  podSelector: {matchLabels: {prodbox.io/plane: management}}"
    , "  policyTypes: [Ingress]"
    , "  ingress: [{from: [{podSelector: {matchLabels: {prodbox.io/management-client: \"true\"}}}, {namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: bootstrap-broker}}}, {namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: lifecycle-authority}}}]}]"
    ]

managementPolicyManifest :: String -> ByteString.ByteString
managementPolicyManifest namespace = ByteString8.pack (substitute managementPolicyTemplate)
 where
  substitute [] = []
  substitute text@(character : rest)
    | take 9 text == "NAMESPACE" = namespace ++ substitute (drop 9 text)
    | otherwise = character : substitute rest

managementPolicyDigest :: String
managementPolicyDigest = ByteString8.unpack (hexSha256 (ByteString8.pack managementPolicyTemplate))
