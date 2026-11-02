{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module BootstrapSourceFixture
  ( writeBootstrapSourceFixture
  , readyMinioControllerJson
  , readyMinioPodJson
  , readyVaultControllerJson
  , readyVaultPodJson
  , readyVaultClaimJson
  , readyVaultVolumeJson
  , readyVaultNodeJson
  ) where

import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.Aeson (Value, encode, object, (.=))
import Data.Aeson.Types (Pair)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ContainerImage (publicMinioImage, renderImageRef)
import Prodbox.Infra.BootstrapImageArchive
import Prodbox.Infra.BootstrapImageSource
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

-- Public synthetic build bytes exercise cache verification and the subprocess
-- boundary. This metadata is never an Authority handle or secret receipt.
writeBootstrapSourceFixture :: FilePath -> IO [(Text, Text, FilePath)]
writeBootstrapSourceFixture root = mapM writeOne [BootstrapMinioServer, BootstrapMinioClient]
 where
  writeOne component = do
    let recipe = bootstrapSourceRecipe component BootstrapImageAmd64
        location =
          root </> ".build" </> "bootstrap-images-v1" </> Text.unpack (bootstrapSourceRecipeIdentity recipe)
        binary = "synthetic public bootstrap executable"
        base = "synthetic base filesystem"
        ca = "synthetic public certificate bundle"
        license = "synthetic licence"
        history = object ["created_by" .= ("synthetic pinned base" :: Text)]
        historyBytes = encode history
        manifest = bootstrapSourceInputManifest recipe (digest binary) (digest base) (digest ca)
        inputs =
          BootstrapImageInputs
            base
            history
            binary
            (LazyByteString.toStrict license)
            (LazyByteString.toStrict ca)
            manifest
        receipt =
          encode $
            object
              [ "schema" .= (1 :: Int)
              , "recipe_sha256" .= bootstrapSourceRecipeIdentity recipe
              , "binary_sha256" .= digest binary
              , "base_sha256" .= digest base
              , "ca_sha256" .= digest ca
              , "license_sha256" .= digest license
              , "history_sha256" .= digest historyBytes
              ]
    createDirectoryIfMissing True location
    setFileMode location 0o700
    mapM_
      ( \(name, bytes) -> LazyByteString.writeFile (location </> name) bytes >> setFileMode (location </> name) 0o600
      )
      [ ("binary", binary)
      , ("base.tar", base)
      , ("ca.pem", ca)
      , ("LICENSE", license)
      , ("history.json", historyBytes)
      , ("inputs.json", receipt)
      ]
    case assembleBootstrapImageArchive component BootstrapImageAmd64 inputs of
      Left cause -> ioError (userError (show cause))
      Right archive -> do
        let reference = bootstrapImageArchiveReference archive
            identity = bootstrapImageArchiveIdentity archive
        ByteString.writeFile (location </> "fixture-image-id") (TextEncoding.encodeUtf8 identity)
        pure (reference, identity, location)

digest :: LazyByteString.ByteString -> Text
digest bytes = TextEncoding.decodeUtf8 (convertToBase Base16 (hashlazy bytes :: Digest SHA256))

readyMinioControllerJson :: String
readyMinioControllerJson =
  renderJson $
    object
      [ "apiVersion" .= ("apps/v1" :: Text)
      , "kind" .= ("StatefulSet" :: Text)
      , "metadata"
          .= object
            [ "name" .= ("minio" :: Text)
            , "namespace" .= ("prodbox" :: Text)
            , "uid" .= ("fixture-minio-controller" :: Text)
            , "generation" .= (1 :: Int)
            ]
      , "spec"
          .= object
            [ "replicas" .= (1 :: Int)
            , "podManagementPolicy" .= ("OrderedReady" :: Text)
            , "updateStrategy" .= object ["type" .= ("RollingUpdate" :: Text)]
            , "template" .= object ["spec" .= object ["containers" .= [minioContainer]]]
            ]
      , "status"
          .= object
            [ "observedGeneration" .= (1 :: Int)
            , "replicas" .= (1 :: Int)
            , "readyReplicas" .= (1 :: Int)
            , "updatedReplicas" .= (1 :: Int)
            , "currentRevision" .= ("fixture-ready-revision" :: Text)
            , "updateRevision" .= ("fixture-ready-revision" :: Text)
            ]
      ]

readyMinioPodJson :: String
readyMinioPodJson =
  renderJson $
    object
      [ "apiVersion" .= ("v1" :: Text)
      , "kind" .= ("Pod" :: Text)
      , "metadata"
          .= object
            [ "name" .= ("minio-0" :: Text)
            , "namespace" .= ("prodbox" :: Text)
            , "uid" .= ("fixture-minio-pod" :: Text)
            , "resourceVersion" .= ("1" :: Text)
            , "labels" .= object ["controller-revision-hash" .= ("fixture-ready-revision" :: Text)]
            , "ownerReferences"
                .= [ object
                       [ "apiVersion" .= ("apps/v1" :: Text)
                       , "kind" .= ("StatefulSet" :: Text)
                       , "name" .= ("minio" :: Text)
                       , "uid" .= ("fixture-minio-controller" :: Text)
                       , "controller" .= True
                       ]
                   ]
            ]
      , "spec" .= object ["containers" .= [minioContainer]]
      , "status"
          .= object ["conditions" .= [object ["type" .= ("Ready" :: Text), "status" .= ("True" :: Text)]]]
      ]

minioContainer :: Value
minioContainer = object ["name" .= ("minio" :: Text), "image" .= renderImageRef publicMinioImage]

renderJson :: Value -> String
renderJson = Text.unpack . TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode

readyVaultControllerJson :: String
readyVaultControllerJson =
  renderJson $
    object
      [ "apiVersion" .= ("apps/v1" :: Text)
      , "kind" .= ("StatefulSet" :: Text)
      , "metadata"
          .= object
            [ "name" .= ("vault" :: Text)
            , "namespace" .= ("vault" :: Text)
            , "uid" .= ("fixture-vault-controller" :: Text)
            , "generation" .= (1 :: Int)
            ]
      , "spec"
          .= object
            [ "replicas" .= (1 :: Int)
            , "podManagementPolicy" .= ("OrderedReady" :: Text)
            , "updateStrategy" .= object ["type" .= ("RollingUpdate" :: Text)]
            , "template" .= object ["spec" .= object ["containers" .= [vaultContainer []]]]
            ]
      , "status"
          .= object
            [ "observedGeneration" .= (1 :: Int)
            , "currentRevision" .= ("fixture-vault-revision" :: Text)
            , "updateRevision" .= ("fixture-vault-revision" :: Text)
            ]
      ]

readyVaultPodJson :: String
readyVaultPodJson =
  renderJson $
    object
      [ "apiVersion" .= ("v1" :: Text)
      , "kind" .= ("Pod" :: Text)
      , "metadata"
          .= object
            [ "name" .= ("vault-0" :: Text)
            , "namespace" .= ("vault" :: Text)
            , "uid" .= ("fixture-vault-pod" :: Text)
            , "resourceVersion" .= ("1" :: Text)
            , "labels" .= object ["controller-revision-hash" .= ("fixture-vault-revision" :: Text)]
            , "ownerReferences"
                .= [ object
                       [ "apiVersion" .= ("apps/v1" :: Text)
                       , "kind" .= ("StatefulSet" :: Text)
                       , "name" .= ("vault" :: Text)
                       , "uid" .= ("fixture-vault-controller" :: Text)
                       , "controller" .= True
                       ]
                   ]
            ]
      , "spec"
          .= object
            [ "nodeName" .= ("bathurst" :: Text)
            , "containers"
                .= [ vaultContainer
                       [ "volumeMounts"
                           .= [ object
                                  ["name" .= ("data" :: Text), "mountPath" .= ("/vault/data" :: Text)]
                              ]
                       ]
                   ]
            , "volumes"
                .= [ object
                       [ "name" .= ("data" :: Text)
                       , "persistentVolumeClaim" .= object ["claimName" .= ("data-vault-0" :: Text)]
                       ]
                   ]
            ]
      , "status"
          .= object
            [ "phase" .= ("Running" :: Text)
            , "conditions"
                .= [ object
                       ["type" .= ("Ready" :: Text), "status" .= ("True" :: Text)]
                   ]
            ]
      ]

readyVaultClaimJson :: String
readyVaultClaimJson =
  renderJson $
    object
      [ "apiVersion" .= ("v1" :: Text)
      , "kind" .= ("PersistentVolumeClaim" :: Text)
      , "metadata"
          .= object
            [ "name" .= ("data-vault-0" :: Text)
            , "namespace" .= ("vault" :: Text)
            , "uid" .= ("fixture-vault-claim" :: Text)
            ]
      , "spec"
          .= object
            [ "volumeName" .= ("prodbox-retained-vault-vault-0" :: Text)
            , "storageClassName" .= ("manual" :: Text)
            , "volumeMode" .= ("Filesystem" :: Text)
            , "accessModes" .= (["ReadWriteOnce"] :: [Text])
            ]
      , "status" .= object ["phase" .= ("Bound" :: Text)]
      ]

readyVaultVolumeJson :: FilePath -> String
readyVaultVolumeJson hostPath =
  renderJson $
    object
      [ "apiVersion" .= ("v1" :: Text)
      , "kind" .= ("PersistentVolume" :: Text)
      , "metadata"
          .= object
            ["name" .= ("prodbox-retained-vault-vault-0" :: Text), "uid" .= ("fixture-vault-volume" :: Text)]
      , "spec"
          .= object
            [ "storageClassName" .= ("manual" :: Text)
            , "persistentVolumeReclaimPolicy" .= ("Retain" :: Text)
            , "hostPath" .= object ["path" .= hostPath, "type" .= ("DirectoryOrCreate" :: Text)]
            , "claimRef"
                .= object
                  [ "apiVersion" .= ("v1" :: Text)
                  , "kind" .= ("PersistentVolumeClaim" :: Text)
                  , "name" .= ("data-vault-0" :: Text)
                  , "namespace" .= ("vault" :: Text)
                  , "uid" .= ("fixture-vault-claim" :: Text)
                  ]
            , "nodeAffinity"
                .= object
                  [ "required"
                      .= object
                        [ "nodeSelectorTerms"
                            .= [ object
                                   [ "matchExpressions"
                                       .= [ object
                                              [ "key" .= ("kubernetes.io/hostname" :: Text)
                                              , "operator" .= ("In" :: Text)
                                              , "values" .= (["bathurst"] :: [Text])
                                              ]
                                          ]
                                   ]
                               ]
                        ]
                  ]
            ]
      , "status" .= object ["phase" .= ("Bound" :: Text)]
      ]

readyVaultNodeJson :: String
readyVaultNodeJson =
  renderJson $
    object
      [ "apiVersion" .= ("v1" :: Text)
      , "kind" .= ("Node" :: Text)
      , "metadata" .= object ["name" .= ("bathurst" :: Text), "uid" .= ("fixture-vault-node" :: Text)]
      , "status"
          .= object
            [ "nodeInfo"
                .= object
                  ["bootID" .= ("11111111-2222-4333-8444-555555555555" :: Text)]
            ]
      ]

vaultContainer :: [Pair] -> Value
vaultContainer extra =
  object
    (["name" .= ("vault" :: Text), "image" .= ("hashicorp/vault:1.18.3" :: Text)] ++ extra)
