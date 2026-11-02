{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneRpcBirthRollout (rpcBirthRolloutSuite) where

import Control.Monad (forM_)
import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isLeft, isRight)
import Prodbox.ControlPlane.Coordinate (mkAuthorityScope)
import Prodbox.ControlPlane.RpcAdmissionBirthCoordinator
import Prodbox.ControlPlane.RpcAdmissionBirthRollout
import Prodbox.Lib.Storage
import Prodbox.Lifecycle.HelmRelease qualified as Helm
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import Prodbox.Lifecycle.Teardown.EphemeralKubectl
  ( prepareEmbeddedHomeKubeconfig
  , writeEmbeddedHomeKubeconfig
  )
import Prodbox.Subprocess (ProcessOutput (..))
import System.Directory (createFileLink)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getSymbolicLinkStatus, isSymbolicLink)
import TestSupport

rpcBirthRolloutSuite :: SuiteBuilder ()
rpcBirthRolloutSuite = describe "bounded RPC birth chart rollout" $ do
  it "keeps the operation key across caller deadlines and separates scope, generation and operation" $ do
    let request scope deadline generation operationKey =
          fixture
            ( mkRpcBirthCoordinationRequest
                (fixture (mkAuthorityScope scope))
                (authorityTimeFromMicros deadline)
                generation
                operationKey
            )
        key = fixture (rpcBirthRolloutExecutionKey (request "home" 1000 1 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
    rpcBirthRolloutExecutionKey (request "home" 2000 1 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
      `shouldBe` Right key
    forM_
      [ request "other" 1000 1 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      , request "home" 1000 2 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      , request "home" 1000 1 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      ]
      $ \different -> rpcBirthRolloutExecutionKey different `shouldNotBe` Right key

  it "holds only the selected embedded-certificate context" $ do
    validateRpcBirthHomeKubeconfig (json homeConfig) `shouldSatisfy` isRight
    let extra = at "users" ["user", "token"] (String "synthetic-unrelated-token") homeConfig
    validateRpcBirthHomeKubeconfig (json extra)
      `shouldBe` validateRpcBirthHomeKubeconfig (json homeConfig)

  forM_
    [ ("remote target", at "clusters" ["cluster", "server"] (String "https://eks.invalid:443") homeConfig)
    ,
      ( "exec authentication"
      , at "users" ["user", "exec"] (object ["command" .= ("aws" :: String)]) homeConfig
      )
    , ("auth-provider", at "users" ["user", "auth-provider"] (object []) homeConfig)
    , ("external bearer file", at "users" ["user", "tokenFile"] (String "/mutable/token") homeConfig)
    , ("credential file reload", at "users" ["user", "client-key"] (String "/mutable/key") homeConfig)
    ,
      ( "CA file reload"
      , at "clusters" ["cluster", "certificate-authority"] (String "/mutable/ca") homeConfig
      )
    ,
      ( "proxy redirection"
      , at "clusters" ["cluster", "proxy-url"] (String "http://proxy.invalid") homeConfig
      )
    , ("TLS bypass", at "clusters" ["cluster", "insecure-skip-tls-verify"] (Bool True) homeConfig)
    , ("empty certificate", at "users" ["user", "client-certificate-data"] (String "") homeConfig)
    , ("wrong selected context", set ["current-context"] (String "other") homeConfig)
    ]
    $ \(label, config) ->
      it ("refuses " <> label <> " before preparation") $
        validateRpcBirthHomeKubeconfig (json config) `shouldBe` Left RpcBirthRolloutHomeConfigInvalid

  it "refuses malformed and oversized configuration without returning its bytes" $ do
    forM_ ["not-json", BS.replicate (64 * 1024 + 1) 32] $ \bytes ->
      validateRpcBirthHomeKubeconfig bytes `shouldBe` Left RpcBirthRolloutHomeConfigInvalid

  it "uses the credential owner's private writer and reads back the closed projection" $
    withSystemTempDirectory "rpc-birth-embedded-home" $ \directory -> do
      let config = fixture (prepareEmbeddedHomeKubeconfig (json homeConfig))
          path = directory </> "kubeconfig.json"
      writeEmbeddedHomeKubeconfig directory config >>= (`shouldBe` Right path)
      observed <- BS.readFile path
      validateRpcBirthHomeKubeconfig observed `shouldBe` validateRpcBirthHomeKubeconfig (json homeConfig)
      status <- getSymbolicLinkStatus path
      (fileMode status .&. 0o777) `shouldBe` 0o600

  forM_ [("regular file", False), ("symlink", True)] $ \(label, link) ->
    it ("refuses a pre-placed " <> label <> " without changing its canary") $
      withSystemTempDirectory "rpc-birth-embedded-refusal" $ \directory -> do
        let config = fixture (prepareEmbeddedHomeKubeconfig (json homeConfig))
            path = directory </> "kubeconfig.json"
            canary = directory </> "canary"
            bytes = "synthetic-canary"
        BS.writeFile canary bytes
        if link then createFileLink canary path else BS.writeFile path bytes
        writeEmbeddedHomeKubeconfig directory config >>= (`shouldSatisfy` isLeft)
        BS.readFile canary >>= (`shouldBe` bytes)
        BS.readFile path >>= (`shouldBe` bytes)
        status <- getSymbolicLinkStatus path
        isSymbolicLink status `shouldBe` link

  forM_ [minBound .. maxBound] $ \status ->
    it ("uses the canonical Helm write decision for " <> show status) $ do
      let output =
            ProcessOutput
              ExitSuccess
              ("{\"info\":{\"status\":\"" <> Helm.helmReleaseStatusText status <> "\"}}")
              ""
          expected = case Helm.helmUpgradePreparation (Helm.HelmReleasePresent status) of
            Right Helm.HelmUpgradeAdmit -> Right ()
            Right (Helm.HelmUpgradeRequireExactAbsence actual) -> Left (RpcBirthRolloutRetainedRelease actual)
            Left (Helm.HelmWriteConcurrentOperation actual) -> Left (RpcBirthRolloutConcurrentRelease actual)
            Left (Helm.HelmWriteUnobservable _) -> Left RpcBirthRolloutReleaseUnobservable
      classifyRpcBirthRolloutRelease output `shouldBe` expected

  it "distinguishes release absence from unavailable or malformed status" $ do
    classifyRpcBirthRolloutRelease (ProcessOutput (ExitFailure 1) "" "release: not found")
      `shouldBe` Right ()
    forM_ [ProcessOutput (ExitFailure 1) "" "connection refused", ProcessOutput ExitSuccess "{}" ""] $ \output ->
      classifyRpcBirthRolloutRelease output `shouldBe` Left RpcBirthRolloutReleaseUnobservable

  it "reads the exact retained claim/volume pair and normalizes integral binary units" $ do
    validateRpcBirthJournalBinding binding claim volume `shouldBe` Right ()
    validateRpcBirthJournalBinding
      binding
      (set ["spec", "resources", "requests", "storage"] (String "1024Mi") claim)
      volume
      `shouldBe` Right ()

  forM_
    [ ("replacement UID", claim, set ["spec", "claimRef", "uid"] (String "replacement") volume)
    ,
      ( "malformed UID"
      , set ["metadata", "uid"] (Number 1) claim
      , set ["spec", "claimRef", "uid"] (Number 1) volume
      )
    , ("foreign host root", claim, set ["spec", "hostPath", "path"] (String "/foreign") volume)
    , ("delete reclaim", claim, set ["spec", "persistentVolumeReclaimPolicy"] (String "Delete") volume)
    , ("wrong namespace", set ["metadata", "namespace"] (String "other") claim, volume)
    , ("wrong volume binding", set ["spec", "volumeName"] (String "other") claim, volume)
    , ("unbound claim", set ["status", "phase"] (String "Pending") claim, volume)
    , ("different capacity", claim, set ["spec", "capacity", "storage"] (String "2Gi") volume)
    ]
    $ \(label, observedClaim, observedVolume) ->
      it ("refuses " <> label <> " without changing storage") $
        validateRpcBirthJournalBinding binding observedClaim observedVolume
          `shouldBe` Left RpcBirthRolloutJournalMismatch

fixture :: (Show error) => Either error value -> value
fixture = either (error . show) id

json :: Value -> BS.ByteString
json = Lazy.toStrict . encode

homeConfig :: Value
homeConfig =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("Config" :: String)
    , "current-context" .= ("home" :: String)
    , "clusters"
        .= [ object
               [ "name" .= ("home" :: String)
               , "cluster"
                   .= object
                     [ "server" .= ("https://127.0.0.1:6443" :: String)
                     , "certificate-authority-data" .= ("synthetic-ca" :: String)
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
                     [ "client-certificate-data" .= ("synthetic-cert" :: String)
                     , "client-key-data" .= ("synthetic-key" :: String)
                     ]
               ]
           ]
    ]

binding :: ChartStorageBinding
binding =
  ChartStorageBinding
    "lifecycle-authority"
    "lifecycle-authority"
    "journal-volume"
    "journal-claim"
    "1Gi"
    "/retained/authority/0"
    0
    "authority-journal"
    ReadWriteOnceAccess

claim :: Value
claim =
  object
    [ "kind" .= ("PersistentVolumeClaim" :: String)
    , "metadata"
        .= object
          [ "name" .= ("journal-claim" :: String)
          , "namespace" .= ("lifecycle-authority" :: String)
          , "uid" .= ("claim-uid" :: String)
          ]
    , "spec"
        .= object
          [ "volumeName" .= ("journal-volume" :: String)
          , "storageClassName" .= ("manual" :: String)
          , "accessModes" .= ["ReadWriteOnce" :: String]
          , "resources" .= object ["requests" .= object ["storage" .= ("1Gi" :: String)]]
          ]
    , "status" .= object ["phase" .= ("Bound" :: String)]
    ]

volume :: Value
volume =
  object
    [ "kind" .= ("PersistentVolume" :: String)
    , "metadata" .= object ["name" .= ("journal-volume" :: String)]
    , "spec"
        .= object
          [ "persistentVolumeReclaimPolicy" .= ("Retain" :: String)
          , "storageClassName" .= ("manual" :: String)
          , "accessModes" .= ["ReadWriteOnce" :: String]
          , "capacity" .= object ["storage" .= ("1Gi" :: String)]
          , "hostPath" .= object ["path" .= ("/retained/authority/0" :: String)]
          , "claimRef"
              .= object
                [ "namespace" .= ("lifecycle-authority" :: String)
                , "name" .= ("journal-claim" :: String)
                , "uid" .= ("claim-uid" :: String)
                ]
          ]
    , "status" .= object ["phase" .= ("Bound" :: String)]
    ]

at :: Key -> [Key] -> Value -> Value -> Value
at name path replacement (Object fields) = case KeyMap.lookup name fields of
  Just (Array entries) -> Object (KeyMap.insert name (Array (fmap (set path replacement) entries)) fields)
  _ -> error "invalid array fixture path"
at _ _ _ _ = error "invalid array fixture object"

set :: [Key] -> Value -> Value -> Value
set path replacement original = case path of
  [] -> replacement
  name : rest -> case original of
    Object fields ->
      Object
        (KeyMap.insert name (set rest replacement (maybe Null id (KeyMap.lookup name fields))) fields)
    _ -> error "invalid object fixture path"
