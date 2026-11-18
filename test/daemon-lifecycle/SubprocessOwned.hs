{-# LANGUAGE OverloadedStrings #-}

-- | Native kernel-owned children require the local user manager and cgroup2.
module SubprocessOwned (ownedSubprocessLifecycleSuite) where

import Control.Exception
  ( AsyncException (ThreadKilled)
  , IOException
  , bracket
  , finally
  , fromException
  , throwIO
  , try
  )
import Control.Monad (forM_, void)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as ByteString
import Data.Either (isLeft)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Capacity.RuntimeMemory qualified as RuntimeMemory
import Prodbox.Config.BootstrapProjection (readBootstrapProjection)
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , FreshScopeResult (FreshScopePrepared)
  , ScopeArtifactObservation (ScopeArtifactDigestMismatch)
  , deploymentScope
  , prepareFreshScope
  , scopeRoot
  )
import Prodbox.Config.KindVolume
import Prodbox.Control.KindDockerWorker
  ( KindDockerWorkerError (KindDockerWorkerInvalidClientDescriptor)
  , prepareKindDockerWorkerWithSealedClient
  )
import Prodbox.Control.KindIntent
  ( KindIntentObservation (..)
  , KindIntentResult (..)
  , observeKindIntent
  , recordKindIntent
  )
import Prodbox.Control.KindKubeconfig
import Prodbox.Control.KindKubeconfigTls
import Prodbox.Control.KindKubeconfigYaml
import Prodbox.Control.KindTool
import Prodbox.Control.KindVolumeReadback
import Prodbox.Control.SealedTool
import Prodbox.Subprocess
import SubprocessFixtures
import System.Directory (copyFile, createDirectory, doesFileExist, findExecutable)
import System.Exit (ExitCode (..))
import System.IO (SeekMode (AbsoluteSeek))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files
  ( FileStatus
  , fileOwner
  , getSymbolicLinkStatus
  , isSocket
  , setFdSize
  , setFileMode
  )
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (ByteCount, Fd (..))
import System.Posix.User (getEffectiveUserID)
import System.Process qualified as Process
import System.Timeout (timeout)
import TestSupport

ownedSubprocessLifecycleSuite :: SuiteBuilder ()
ownedSubprocessLifecycleSuite = describe "kernel-owned subprocess lifecycle" $ do
  it "rejects ambiguous or unbounded kind kubeconfig YAML" $ do
    scope <- either (fail . show) pure (deploymentScope "/project" Test "run" 26443)
    let document =
          ByteString.unlines
            [ "apiVersion: v1"
            , "kind: Config"
            , "preferences: {}"
            , "current-context: kind-prodbox-t-run"
            , "clusters:"
            , "- name: kind-prodbox-t-run"
            , "  cluster:"
            , "    server: https://127.0.0.1:26443"
            , "    certificate-authority-data: Y2E="
            , "contexts:"
            , "- name: kind-prodbox-t-run"
            , "  context:"
            , "    cluster: kind-prodbox-t-run"
            , "    user: kind-prodbox-t-run"
            , "users:"
            , "- name: kind-prodbox-t-run"
            , "  user:"
            , "    client-certificate-data: Y2VydA=="
            , "    client-key-data: a2V5"
            ]
        failure result = either Just (const Nothing) result
    accepted <- decodeKindKubeconfig scope document
    case accepted of
      Left problem -> fail (show problem)
      Right projection -> kindKubeconfigContext projection `shouldBe` "kind-prodbox-t-run"
    duplicate <- decodeKindKubeconfig scope (document <> "kind: Config\n")
    failure duplicate `shouldBe` Just KindKubeconfigDocumentUnsupported
    nestedDuplicate <-
      decodeKindKubeconfig
        scope
        ( ByteString.unlines
            ["apiVersion: v1", "kind: Config", "clusters:", "- cluster:", "    server: a", "    server: b"]
        )
    failure nestedDuplicate `shouldBe` Just KindKubeconfigDocumentUnsupported
    alias <- decodeKindKubeconfig scope "a: &x value\nb: *x\n"
    failure alias `shouldBe` Just KindKubeconfigDocumentUnsupported
    tagged <- decodeKindKubeconfig scope "kind: !!str Config\n"
    failure tagged `shouldBe` Just KindKubeconfigDocumentUnsupported
    merged <- decodeKindKubeconfig scope "<<: {}\n"
    failure merged `shouldBe` Just KindKubeconfigDocumentUnsupported
    let deep = ByteString.pack (concat [replicate indent ' ' ++ "a:\n" | indent <- [0 .. 17]])
        manyEvents = ByteString.unlines ("items:" : replicate 1100 "- x")
    tooDeep <- decodeKindKubeconfig scope deep
    failure tooDeep `shouldBe` Just KindKubeconfigDocumentUnsupported
    tooManyEvents <- decodeKindKubeconfig scope manyEvents
    failure tooManyEvents `shouldBe` Just KindKubeconfigDocumentUnsupported
    invalidUtf8 <- decodeKindKubeconfig scope (ByteString.pack "\255")
    failure invalidUtf8 `shouldBe` Just KindKubeconfigDocumentInvalidUtf8
    oversized <- decodeKindKubeconfig scope (ByteString.replicate 524289 'x')
    failure oversized `shouldBe` Just KindKubeconfigDocumentTooLarge
    multiple <- decodeKindKubeconfig scope (document <> "---\nkind: Config\n")
    failure multiple `shouldBe` Just KindKubeconfigDocumentInvalid

  it "accepts only the selected self-contained kind kubeconfig" $ do
    scope <- either (fail . show) pure (deploymentScope "/project" Test "run" 26443)
    let selected = "kind-prodbox-t-run" :: String
        user extra =
          Aeson.object
            ( [ "client-certificate-data" Aeson..= ("Y2VydA==" :: String)
              , "client-key-data" Aeson..= ("a2V5" :: String)
              ]
                ++ extra
            )
        document server current ca userValue =
          documentWithCluster server current ca [] userValue
        documentWithCluster server current ca clusterExtra userValue =
          Aeson.object
            [ "apiVersion" Aeson..= ("v1" :: String)
            , "kind" Aeson..= ("Config" :: String)
            , "preferences" Aeson..= Aeson.object []
            , "current-context" Aeson..= (current :: String)
            , "clusters"
                Aeson..= [ Aeson.object
                             [ "name" Aeson..= selected
                             , "cluster"
                                 Aeson..= Aeson.object
                                   ( ["server" Aeson..= (server :: String), "certificate-authority-data" Aeson..= (ca :: String)]
                                       ++ clusterExtra
                                   )
                             ]
                         ]
            , "contexts"
                Aeson..= [ Aeson.object
                             [ "name" Aeson..= selected
                             , "context" Aeson..= Aeson.object ["cluster" Aeson..= selected, "user" Aeson..= selected]
                             ]
                         ]
            , "users" Aeson..= [Aeson.object ["name" Aeson..= selected, "user" Aeson..= userValue]]
            ]
        valid = document "https://127.0.0.1:26443" selected "Y2E=" (user [])
        errorOf = either Just (const Nothing)
    case validateKindKubeconfig scope valid of
      Left failure -> fail (show failure)
      Right kubeconfig -> do
        kindKubeconfigServer kubeconfig `shouldBe` "https://127.0.0.1:26443"
        kindKubeconfigContext kubeconfig `shouldBe` selected
        withKindKubeconfigMaterial kubeconfig (\ca cert key -> pure (ca, cert, key))
          `shouldReturn` ("ca", "cert", "key")
        parsedTls <- parseKindTlsMaterial kubeconfig
        either Just (const Nothing) parsedTls `shouldBe` Just KindTlsInvalidCa
    errorOf
      (validateKindKubeconfig scope (document "https://127.0.0.1:26444" selected "Y2E=" (user [])))
      `shouldBe` Just KindKubeconfigWrongIdentity
    errorOf
      (validateKindKubeconfig scope (document "https://127.0.0.1:26443" "foreign" "Y2E=" (user [])))
      `shouldBe` Just KindKubeconfigWrongIdentity
    errorOf
      (validateKindKubeconfig scope (document "https://127.0.0.1:26443" selected "invalid!" (user [])))
      `shouldBe` Just KindKubeconfigInvalidMaterial
    errorOf
      ( validateKindKubeconfig
          scope
          (document "https://127.0.0.1:26443" selected "Y2E=" (user ["exec" Aeson..= Aeson.object []]))
      )
      `shouldBe` Just KindKubeconfigInvalidShape
    errorOf
      ( validateKindKubeconfig
          scope
          ( documentWithCluster
              "https://127.0.0.1:26443"
              selected
              "Y2E="
              ["insecure-skip-tls-verify" Aeson..= True]
              (user [])
          )
      )
      `shouldBe` Just KindKubeconfigInvalidShape
    errorOf
      ( validateKindKubeconfig
          scope
          ( document
              "https://127.0.0.1:26443"
              selected
              "Y2E="
              (user ["client-key" Aeson..= ("/foreign" :: String)])
          )
      )
      `shouldBe` Just KindKubeconfigInvalidShape
    errorOf
      ( validateKindKubeconfig
          scope
          (document "https://127.0.0.1:26443" selected (replicate 87385 'A') (user []))
      )
      `shouldBe` Just KindKubeconfigInvalidMaterial
    let multipleUsers = case valid of
          Aeson.Object object -> Aeson.Object (KeyMap.insert "users" (Aeson.toJSON [Aeson.object [], Aeson.object []]) object)
          other -> other
    errorOf (validateKindKubeconfig scope multipleUsers) `shouldBe` Just KindKubeconfigInvalidShape

  it "checks independent PV and claim identities, binding and retained path" $ do
    scope <- either (fail . show) pure (deploymentScope "/project" Test "run" 26443)
    volume <-
      either (fail . show) pure (kindVolume scope (replicate 32 'a') "management" "worker" "state" 128)
    let name = kindVolumeName volume
        modes = ["ReadWriteOnce" :: String]
        pv observedPath uid phase =
          Aeson.object
            [ "kind" Aeson..= ("PersistentVolume" :: String)
            , "apiVersion" Aeson..= ("v1" :: String)
            , "metadata"
                Aeson..= Aeson.object
                  [ "name" Aeson..= name
                  , "uid" Aeson..= ("pv-uid" :: String)
                  , "resourceVersion" Aeson..= ("42" :: String)
                  ]
            , "status" Aeson..= Aeson.object ["phase" Aeson..= (phase :: String)]
            , "spec"
                Aeson..= Aeson.object
                  [ "capacity" Aeson..= Aeson.object ["storage" Aeson..= ("128Mi" :: String)]
                  , "accessModes" Aeson..= modes
                  , "volumeMode" Aeson..= ("Filesystem" :: String)
                  , "persistentVolumeReclaimPolicy" Aeson..= ("Retain" :: String)
                  , "storageClassName" Aeson..= ("" :: String)
                  , "hostPath"
                      Aeson..= Aeson.object ["path" Aeson..= (observedPath :: String), "type" Aeson..= ("Directory" :: String)]
                  , "claimRef"
                      Aeson..= Aeson.object
                        [ "name" Aeson..= name
                        , "namespace" Aeson..= ("management" :: String)
                        , "uid" Aeson..= (uid :: String)
                        ]
                  ]
            ]
        claim =
          Aeson.object
            [ "kind" Aeson..= ("PersistentVolumeClaim" :: String)
            , "apiVersion" Aeson..= ("v1" :: String)
            , "metadata"
                Aeson..= Aeson.object
                  [ "name" Aeson..= name
                  , "namespace" Aeson..= ("management" :: String)
                  , "uid" Aeson..= ("claim-uid" :: String)
                  , "resourceVersion" Aeson..= ("43" :: String)
                  ]
            , "status" Aeson..= Aeson.object ["phase" Aeson..= ("Bound" :: String)]
            , "spec"
                Aeson..= Aeson.object
                  [ "volumeName" Aeson..= name
                  , "accessModes" Aeson..= modes
                  , "volumeMode" Aeson..= ("Filesystem" :: String)
                  , "storageClassName" Aeson..= ("" :: String)
                  , "resources"
                      Aeson..= Aeson.object ["requests" Aeson..= Aeson.object ["storage" Aeson..= ("128Mi" :: String)]]
                  ]
            ]
        path = kindVolumeNodePath volume
        deleting value = case value of
          Aeson.Object object -> case KeyMap.lookup "metadata" object of
            Just (Aeson.Object metadata) ->
              Aeson.Object
                ( KeyMap.insert
                    "metadata"
                    (Aeson.Object (KeyMap.insert "deletionTimestamp" (Aeson.String "2026-01-01T00:00:00Z") metadata))
                    object
                )
            _ -> value
          _ -> value
    classifyKindVolumeBinding volume (pv path "claim-uid" "Bound") claim
      `shouldBe` Right (KindVolumeBindingObserved "pv-uid" "42" "claim-uid" "43")
    classifyKindVolumeBinding volume (pv path "wrong-uid" "Bound") claim
      `shouldBe` Right KindVolumeBindingMismatch
    classifyKindVolumeBinding volume (pv "/foreign" "claim-uid" "Bound") claim
      `shouldBe` Right KindVolumeBindingMismatch
    classifyKindVolumeBinding volume (pv path "claim-uid" "Available") claim
      `shouldBe` Right KindVolumeBindingNotBound
    classifyKindVolumeBinding volume (deleting (pv path "claim-uid" "Bound")) claim
      `shouldBe` Right KindVolumeBindingNotBound
    classifyKindVolumeBinding volume (pv path "claim-uid" "Bound") (deleting claim)
      `shouldBe` Right KindVolumeBindingNotBound
    classifyKindVolumeBinding volume Aeson.Null claim `shouldSatisfy` isLeft
    let bound = pv path "claim-uid" "Bound"
        next ref = atomicModifyIORef' ref takeNext
        takeNext values = case values of
          [] -> ([], Left KindVolumeReadUnavailable)
          value : remaining -> (remaining, value)
        expected = KindVolumeBindingObserved "pv-uid" "42" "claim-uid" "43"
    pvReads <- newIORef [Right bound, Right bound]
    claimReads <- newIORef [Right claim, Right claim]
    observeKindVolumeBinding volume (next pvReads) (next claimReads)
      `shouldReturn` KindVolumeStableBinding expected
    changedPvReads <- newIORef [Right bound, Right (deleting bound)]
    changedClaimReads <- newIORef [Right claim, Right claim]
    observeKindVolumeBinding volume (next changedPvReads) (next changedClaimReads)
      `shouldReturn` KindVolumeBindingChanged expected
    failedPvReads <- newIORef [Right bound, Left KindVolumeReadDenied]
    failedClaimReads <- newIORef [Right claim]
    observeKindVolumeBinding volume (next failedPvReads) (next failedClaimReads)
      `shouldReturn` KindVolumeReadFailed SecondVolume KindVolumeReadDenied
    observeKindVolumeBinding volume (pure (Right Aeson.Null)) (pure (Right claim))
      `shouldReturn` KindVolumeReadbackInvalid FirstVolume
    observeKindVolumeBinding volume (ioError (userError "fixture read failure")) (pure (Right claim))
      `shouldReturn` KindVolumeReadFailed FirstVolume KindVolumeReadUnavailable

  it "decodes only well-formed, distinct kind cluster names" $ do
    parseKindClusterList "prodbox-t-run" "" `shouldBe` Just False
    parseKindClusterList "prodbox-t-run" "other\nprodbox-t-run\n" `shouldBe` Just True
    parseKindClusterList "prodbox-t-run" "other\nother\n" `shouldBe` Nothing
    parseKindClusterList "prodbox-t-run" "other\nBAD\n" `shouldBe` Nothing
    parseKindClusterList "prodbox-t-run" "other\n\n" `shouldBe` Nothing

  it "adds separate sealed-snapshot and scratch charges to the runtime plan" $ do
    base <- fixtureRuntimePlan (512 * 1024 * 1024)
    budget <- either (fail . show) pure (planSealedToolBudget base 1024 (2 * 1024 * 1024))
    let planned = sealedToolRuntimePlan budget
        value = RuntimeMemory.positiveBytesValue
    value (RuntimeMemory.runtimeMemoryOuterRequiredBytes planned)
      `shouldBe` (value (RuntimeMemory.runtimeMemoryOuterRequiredBytes base) + sealedToolKernelCharge budget)
    value (RuntimeMemory.runtimeMemoryHeapRequiredBytes planned)
      `shouldBe` (value (RuntimeMemory.runtimeMemoryHeapRequiredBytes base) + 2 * 65536 + 32768)
    small <- fixtureRuntimePlan (128 * 1024 * 1024)
    planSealedToolBudget small (128 * 1024 * 1024) (2 * 1024 * 1024) `shouldSatisfy` isLeft
    planSealedToolBudget base 1024 0 `shouldBe` Left SealedToolBudgetInvalid

  it "funds bounded kind input alongside the sealed executable" $ do
    base <- fixtureRuntimePlan (512 * 1024 * 1024)
    plain <- either (fail . show) pure (planSealedToolBudget base 1024 (2 * 1024 * 1024))
    funded <-
      either (fail . show) pure (planSealedToolBudgetWithInput base 1024 (2 * 1024 * 1024) 65536 65536)
    let value = RuntimeMemory.positiveBytesValue
        plan = sealedToolRuntimePlan
    sealedToolInputMaximum plain `shouldBe` Nothing
    sealedToolInputMaximum funded `shouldBe` Just 65536
    value (RuntimeMemory.runtimeMemoryHeapRequiredBytes (plan funded))
      `shouldBe` (value (RuntimeMemory.runtimeMemoryHeapRequiredBytes (plan plain)) + 2 * 65536)
    value (RuntimeMemory.runtimeMemoryOuterRequiredBytes (plan funded))
      `shouldBe` (value (RuntimeMemory.runtimeMemoryOuterRequiredBytes (plan plain)) + 65536)
    planSealedToolBudgetWithInput base 1024 (2 * 1024 * 1024) 65537 65536
      `shouldBe` Left SealedToolBudgetInvalid
    planSealedToolBudgetWithInput base 1024 (2 * 1024 * 1024) 65536 0
      `shouldBe` Left SealedToolBudgetInvalid

  it "funds a larger client snapshot without widening the regular tool limit" $ do
    base <- fixtureRuntimePlan (512 * 1024 * 1024)
    small <- fixtureRuntimePlan (128 * 1024 * 1024)
    let clientBytes = 192 * 1024 * 1024 + 1
        overhead = 2 * 1024 * 1024
        expectedCharge = 196 * 1024 * 1024
    budget <- either (fail . show) pure (planSealedClientBudget base clientBytes overhead)
    sealedToolKernelCharge budget `shouldBe` expectedCharge
    planSealedToolBudget base clientBytes overhead `shouldBe` Left SealedToolBudgetInvalid
    planSealedClientBudget base (256 * 1024 * 1024 + 1) overhead `shouldBe` Left SealedToolBudgetInvalid
    planSealedClientBudget small clientBytes overhead `shouldSatisfy` isLeft

  it "funds a larger mutation test snapshot only within its charged envelope" $ do
    base <- fixtureRuntimePlan (1024 * 1024 * 1024)
    small <- fixtureRuntimePlan (256 * 1024 * 1024)
    let mib = 1024 * 1024
        maximumBytes = 300 * mib + 1
        overhead = fromInteger (2 * mib)
    budget <- either (fail . show) pure (planSealedMutationTestBudget base maximumBytes overhead)
    sealedToolKernelCharge budget `shouldBe` fromInteger (304 * mib)
    planSealedToolBudget base maximumBytes overhead `shouldBe` Left SealedToolBudgetInvalid
    planSealedClientBudget base maximumBytes overhead `shouldBe` Left SealedToolBudgetInvalid
    planSealedMutationTestBudget base (512 * mib + 1) overhead `shouldBe` Left SealedToolBudgetInvalid
    planSealedMutationTestBudget small maximumBytes overhead `shouldSatisfy` isLeft

  it "charges kind and bridge snapshots to the same simultaneous plan" $ do
    base <- fixtureRuntimePlan (512 * 1024 * 1024)
    small <- fixtureRuntimePlan (128 * 1024 * 1024)
    let mib = 1024 * 1024
        overhead = 2 * 1024 * 1024
        inputMaximum = 65536
        inputKernel = 65536
        value = RuntimeMemory.positiveBytesValue
    budgets <-
      either (fail . show) pure $
        planKindWorkerSnapshots base (64 * mib) overhead (192 * mib) overhead inputMaximum inputKernel
    let kindBudget = kindWorkerKindBudget budgets
        clientBudget = kindWorkerClientBudget budgets
        combined = sealedToolRuntimePlan kindBudget
    sealedToolRuntimePlan clientBudget `shouldBe` combined
    sealedToolInputMaximum kindBudget `shouldBe` Just inputMaximum
    sealedToolInputMaximum clientBudget `shouldBe` Nothing
    value (RuntimeMemory.runtimeMemoryOuterRequiredBytes combined)
      `shouldBe` ( value (RuntimeMemory.runtimeMemoryOuterRequiredBytes base)
                     + sealedToolKernelCharge kindBudget
                     + sealedToolKernelCharge clientBudget
                     + inputKernel
                 )
    value (RuntimeMemory.runtimeMemoryHeapRequiredBytes combined)
      `shouldBe` ( value (RuntimeMemory.runtimeMemoryHeapRequiredBytes base)
                     + 2 * (2 * 65536 + 32768)
                     + 2 * fromIntegral inputMaximum
                 )
    planKindWorkerSnapshots small (64 * mib) overhead (192 * mib) overhead inputMaximum inputKernel
      `shouldSatisfy` isLeft
    planKindWorkerSnapshots base (129 * mib) overhead (192 * mib) overhead inputMaximum inputKernel
      `shouldBe` Left SealedToolBudgetInvalid
    planKindWorkerSnapshots base (64 * mib) overhead (257 * mib) overhead inputMaximum inputKernel
      `shouldBe` Left SealedToolBudgetInvalid

  it "seals the exact tool bytes before use and refuses a wrong digest" $
    withSystemTempDirectory "sealed-kind-tool" $ \directory -> do
      let path = directory <> "/tool"
          digest = "sha256:" <> ByteString.unpack (hexSha256 (ByteString.pack "artifact"))
      runtime <- fixtureRuntimePlan (512 * 1024 * 1024)
      budget <- either (fail . show) pure (planSealedToolBudget runtime 1024 (2 * 1024 * 1024))
      writeFile path "artifact"
      bracket (Posix.openFd path Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \source -> do
        isSealedToolDescriptor source `shouldReturn` False
        called <- newIORef False
        refused <- withSealedTool budget source ("sha256:" <> replicate 64 '0') 1024 $ \_ -> writeIORef called True
        refused `shouldBe` Left SealedToolDigestMismatch
        readIORef called `shouldReturn` False
        unbudgeted <- withSealedTool budget source digest 1025 $ \_ -> writeIORef called True
        unbudgeted `shouldBe` Left SealedToolInvalidDeclaration
        readIORef called `shouldReturn` False
        tooLarge <- withSealedTool budget source digest 7 $ \_ -> writeIORef called True
        tooLarge `shouldBe` Left SealedToolTooLarge
        readIORef called `shouldReturn` False
        observed <- withSealedTool budget source digest 1024 $ \sealed -> do
          isSealedToolDescriptor sealed `shouldReturn` True
          writeFile path "changed"
          _ <- Posix.fdSeek sealed AbsoluteSeek 0
          attempted <- try (PosixBytes.fdWrite sealed "x") :: IO (Either IOException ByteCount)
          shrink <- try (setFdSize sealed 1) :: IO (Either IOException ())
          grow <- try (setFdSize sealed 16) :: IO (Either IOException ())
          bytes <- PosixBytes.fdRead sealed 8
          pure (isLeft attempted, isLeft shrink, isLeft grow, bytes)
        observed `shouldBe` Right (True, True, True, "artifact")

  it "refuses a sealed client aliased through another descriptor" $
    withSystemTempDirectory "sealed-kind-client-alias" $ \directory -> do
      let path = directory <> "/tool"
          digest = "sha256:" <> ByteString.unpack (hexSha256 (ByteString.pack "artifact"))
      runtime <- fixtureRuntimePlan (512 * 1024 * 1024)
      budget <- either (fail . show) pure (planSealedClientBudget runtime 1024 (2 * 1024 * 1024))
      writeFile path "artifact"
      bracket (Posix.openFd path Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \source -> do
        observed <- withSealedTool budget source digest 1024 $ \sealed ->
          bracket (Posix.dup sealed) Posix.closeFd $ \alias ->
            prepareKindDockerWorkerWithSealedClient alias [] source source source source sealed
        observed `shouldBe` Right (Left KindDockerWorkerInvalidClientDescriptor)

  it "rejects ambiguous or unbounded confined worker descriptors" $ do
    let sandbox scratch roots lock request reply nullDevice =
          isJust (mkKindWorkerSandbox scratch roots lock request reply nullDevice)
    sandbox (Fd 3) [Fd 4] (Fd 5) (Fd 6) (Fd 7) (Fd 8) `shouldBe` True
    sandbox (Fd 0) [Fd 4] (Fd 5) (Fd 6) (Fd 7) (Fd 8) `shouldBe` False
    sandbox (Fd 3) [Fd 4] (Fd 5) (Fd 6) (Fd 6) (Fd 8) `shouldBe` False
    sandbox (Fd 3) (map Fd [20 .. 52]) (Fd 5) (Fd 6) (Fd 7) (Fd 8) `shouldBe` False

  it "observes a retained digest-pinned kind version inside an owned scope" $
    withSystemTempDirectory "owned-kind-tool" $ \anchor -> do
      installed <- findExecutable "kind" >>= maybe (fail "kind executable prerequisite unavailable") pure
      (expectedExit, expectedOutput, _) <- Process.readProcessWithExitCode installed ["version"] ""
      expectedExit `shouldBe` ExitSuccess
      expectedVersion <- case lines expectedOutput of
        [line] -> pure line
        _ -> fail "kind version output was not one line"
      let generation = replicate 32 'a'
          selected = anchor <> "/selected.dhall"
      createDirectory (anchor <> "/.test-data")
      scope <- either (fail . show) pure (deploymentScope anchor Test "run" 26443)
      prepareFreshScope scope generation `shouldReturn` FreshScopePrepared
      createDirectory (scopeRoot scope <> "/artifacts")
      let tool = scopeRoot scope <> "/artifacts/kind"
      copyFile installed tool
      setFileMode tool 0o700
      bytes <- ByteString.readFile tool
      let digest = ByteString.unpack (hexSha256 bytes)
          document pinned =
            "{ bootstrap = { schema_version = 3, project_anchor = \""
              <> anchor
              <> "\", runtime_socket = \"/var/run/docker.sock\", environment = \"test\", deployment_id = \"run\", root_generation = \""
              <> generation
              <> "\", api_port = 26443, node_image = \"kindest/node@sha256:"
              <> replicate 64 '0'
              <> "\", node_artifact = { path = \"artifacts/node.tar\", digest = \"sha256:"
              <> replicate 64 '0'
              <> "\", maximum_bytes = 4096 }, kind_tool = { path = \"artifacts/kind\", digest = \"sha256:"
              <> pinned
              <> "\", maximum_bytes = 134217728 }, http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, listen_address = \"127.0.0.1\" } }"
      putStrLn ("Retained kind fixture SHA-256: " <> digest)
      writeFile selected (document digest)
      bootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
      resources <- ownedFixtureResources
      limits <-
        either (fail . show) pure (mkOwnedSubprocessLimits resources 5000000 100000 300000 100000 4096 4096)
      runtime <- fixtureRuntimePlan (512 * 1024 * 1024)
      budget <-
        either (fail . show) pure (planSealedToolBudget runtime (128 * 1024 * 1024) (2 * 1024 * 1024))
      observed <- observeKindToolVersion limits budget bootstrap
      observed `shouldBe` KindToolAttempted (KindToolVersion expectedVersion) True
      recordKindIntent bootstrap (replicate 32 'b') `shouldReturn` KindIntentRecorded
      observeKindIntent bootstrap `shouldReturn` KindIntentMatches (replicate 32 'b')
      snapshots <-
        either (fail . show) pure $
          planKindWorkerSnapshots
            runtime
            (128 * 1024 * 1024)
            (2 * 1024 * 1024)
            (256 * 1024 * 1024)
            (2 * 1024 * 1024)
            65536
            65536
      called <- newIORef False
      invalidClient <- withConfinedKindSnapshots snapshots bootstrap "invalid" (256 * 1024 * 1024) $ \_ _ _ ->
        writeIORef called True
      invalidClient
        `shouldBe` ConfinedKindSnapshotsAttempted (ConfinedClientSnapshotRefused SealedToolInvalidDeclaration) True
      readIORef called `shouldReturn` False
      clientDigest <-
        ("sha256:" <>) . ByteString.unpack . hexSha256 <$> ByteString.readFile "/proc/self/exe"
      changed <- withConfinedKindSnapshots snapshots bootstrap clientDigest (256 * 1024 * 1024) $ \kind client stable -> do
        isSealedToolDescriptor kind `shouldReturn` True
        isSealedToolDescriptor client `shouldReturn` True
        stable `shouldReturn` True
        ByteString.writeFile tool "changed"
        stable `shouldReturn` False
        pure ("retained" :: String)
      changed `shouldBe` ConfinedKindSnapshotsAttempted (ConfinedSnapshotsReady "retained") False
      writeFile selected (document (replicate 64 '0'))
      wrong <- readBootstrapProjection selected >>= either (fail . show) pure
      observeKindToolVersion limits budget wrong
        `shouldReturn` KindToolArtifactRefused ScopeArtifactDigestMismatch
      observeKindIntent wrong `shouldReturn` KindIntentConflict

  it "preserves independent primary and cleanup failures" $ do
    combineOwnedSubprocessResult
      (Left OwnedSubprocessDeadlineReached)
      (Left OwnedSubprocessDescendantStopUnconfirmed)
      `shouldBe` Left
        ( OwnedSubprocessPrimaryAndCleanup
            OwnedSubprocessDeadlineReached
            OwnedSubprocessDescendantStopUnconfirmed
        )
    combineOwnedSubprocessResult
      (Left OwnedSubprocessDeadlineReached)
      (Left OwnedSubprocessDeadlineReached)
      `shouldBe` Left
        (OwnedSubprocessPrimaryAndCleanup OwnedSubprocessDeadlineReached OwnedSubprocessDeadlineReached)
    combineOwnedSubprocessResult (Right (ExitFailure 7)) (Left OwnedSubprocessFamilyUnconfirmed)
      `shouldBe` Left (OwnedSubprocessExitAndCleanup (ExitFailure 7) OwnedSubprocessFamilyUnconfirmed)

  it "preserves cancellation and cleanup failure without rendering the exception payload" $ do
    failed <-
      try
        (onOwnedExceptionWithCleanup (throwIO ThreadKilled) (pure (Left OwnedSubprocessFamilyUnconfirmed)))
        :: IO (Either OwnedSubprocessInterrupted ())
    case failed of
      Left (OwnedSubprocessInterrupted primary cleanup) -> do
        (fromException primary :: Maybe AsyncException) `shouldBe` Just ThreadKilled
        cleanup `shouldBe` OwnedSubprocessFamilyUnconfirmed
        show (OwnedSubprocessInterrupted primary cleanup)
          `shouldBe` "owned subprocess interrupted; cleanup refused: OwnedSubprocessFamilyUnconfirmed"
      Right () -> expectationFailure "interrupted action unexpectedly returned"
    completedCleanup <-
      try (onOwnedExceptionWithCleanup (throwIO ThreadKilled) (pure (Right ())))
        :: IO (Either AsyncException ())
    completedCleanup `shouldBe` Left ThreadKilled
    failedCleanup <-
      try (onOwnedExceptionWithCleanup (throwIO ThreadKilled) (ioError (userError "cleanup fixture")))
        :: IO (Either OwnedSubprocessInterrupted ())
    case failedCleanup of
      Left (OwnedSubprocessInterrupted primary cleanup) -> do
        (fromException primary :: Maybe AsyncException) `shouldBe` Just ThreadKilled
        cleanup `shouldBe` OwnedSubprocessIoRefused
      Right () -> expectationFailure "interrupted action unexpectedly returned"

  it "delivers bounded binary input after scope admission and confirms process settlement" $ do
    resources <- ownedFixtureResources
    limits <-
      either
        (fail . show)
        pure
        (mkOwnedSubprocessLimits resources 3000000 100000 300000 100000 16384 1024)
    let payload = ByteString.pack (replicate 10000 'x' ++ "\NULtail")
    result <-
      captureOwnedSubprocessWithInput limits 16384 payload (Subprocess "/bin/cat" [] Nothing Nothing)
    result `shouldBe` Right (ProcessOutput ExitSuccess (ByteString.unpack payload) "")

  it "rejects over-limit input before starting an owned process" $
    withSystemTempDirectory "owned-input-refusal" $ \directory -> do
      resources <- ownedFixtureResources
      limits <-
        either (fail . show) pure (mkOwnedSubprocessLimits resources 3000000 100000 300000 100000 1024 1024)
      let marker = directory <> "/started"
          command = Subprocess "/bin/sh" ["-c", "touch \"$1\"", "fixture", marker] Nothing Nothing
      captureOwnedSubprocessWithInput limits 3 (ByteString.pack "four") command
        `shouldReturn` Left OwnedSubprocessInvalidLimits
      doesFileExist marker `shouldReturn` False

  it "streams a held regular file beyond the small in-memory input bound" $
    withSystemTempDirectory "owned-file-input" $ \directory -> do
      resources <- ownedFixtureResources
      limits <-
        either (fail . show) pure (mkOwnedSubprocessLimits resources 5000000 100000 300000 100000 1024 1024)
      let path = directory <> "/input"
          payload = ByteString.replicate 200000 'x'
      ByteString.writeFile path payload
      bracket (Posix.openFd path Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \descriptor -> do
        result <-
          captureOwnedSubprocessWithFileInput
            limits
            200000
            descriptor
            (Subprocess "/usr/bin/sha256sum" [] Nothing Nothing)
        result
          `shouldBe` OwnedFileInputObserved
            (Right (ProcessOutput ExitSuccess (ByteString.unpack (hexSha256 payload) ++ "  -\n") ""))
            OwnedFileInputStable
        let marker = directory <> "/started"
            command = Subprocess "/bin/sh" ["-c", "touch \"$1\"", "fixture", marker] Nothing Nothing
        captureOwnedSubprocessWithFileInput limits 199999 descriptor command
          `shouldReturn` OwnedFileInputRefused OwnedSubprocessInvalidLimits
        doesFileExist marker `shouldReturn` False
        let changed =
              Subprocess
                "/bin/sh"
                ["-c", "cat >/dev/null; printf x >> \"$1\"; exit 7", "fixture", path]
                Nothing
                Nothing
        changedResult <- captureOwnedSubprocessWithFileInput limits 200000 descriptor changed
        changedResult
          `shouldBe` OwnedFileInputObserved (Right (ProcessOutput (ExitFailure 7) "" "")) OwnedFileInputChanged

  it "settles a child that does not consume held file input" $
    withSystemTempDirectory "owned-file-timeout" $ \directory -> do
      resources <- ownedFixtureResources
      limits <-
        either (fail . show) pure (mkOwnedSubprocessLimits resources 1500000 100000 300000 100000 1024 1024)
      let path = directory <> "/input"
          pidPath = directory <> "/pid"
          command =
            Subprocess
              "/bin/sh"
              ["-c", "echo $$ > \"$1\"; trap '' TERM; while true; do sleep 0.1; done", "fixture", pidPath]
              Nothing
              Nothing
      ByteString.writeFile path (ByteString.replicate 200000 'x')
      result <- bracket (Posix.openFd path Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \descriptor ->
        captureOwnedSubprocessWithFileInput limits 200000 descriptor command
      result `shouldBe` OwnedFileInputObserved (Left OwnedSubprocessDeadlineReached) OwnedFileInputStable
      recordedPid pidPath >>= eventuallyGone >>= (`shouldBe` True)

  it "settles a blocked held-file writer when its caller is cancelled" $
    withSystemTempDirectory "owned-file-cancel" $ \directory -> do
      resources <- ownedFixtureResources
      limits <-
        either (fail . show) pure (mkOwnedSubprocessLimits resources 5000000 100000 300000 100000 1024 1024)
      let path = directory <> "/input"
          pidPath = directory <> "/pid"
          command =
            Subprocess
              "/bin/sh"
              ["-c", "echo $$ > \"$1\"; trap '' TERM; while true; do sleep 0.1; done", "fixture", pidPath]
              Nothing
              Nothing
      ByteString.writeFile path (ByteString.replicate 200000 'x')
      result <- bracket (Posix.openFd path Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \descriptor ->
        timeout 200000 (captureOwnedSubprocessWithFileInput limits 200000 descriptor command)
      result `shouldBe` Nothing
      recordedPid pidPath >>= eventuallyGone >>= (`shouldBe` True)

  it "settles an owned child when bounded input is not consumed" $
    withSystemTempDirectory "owned-input-timeout" $ \directory -> do
      resources <- ownedFixtureResources
      limits <-
        either (fail . show) pure (mkOwnedSubprocessLimits resources 1500000 100000 300000 100000 1024 1024)
      let pidPath = directory <> "/pid"
          command =
            Subprocess
              "/bin/sh"
              ["-c", "echo $$ > \"$1\"; trap '' TERM; while true; do sleep 0.1; done", "fixture", pidPath]
              Nothing
              Nothing
      result <- captureOwnedSubprocessWithInput limits 65536 (ByteString.replicate 65536 'x') command
      result `shouldBe` Left OwnedSubprocessDeadlineReached
      recordedPid pidPath >>= eventuallyGone >>= (`shouldBe` True)

  it "retires 2048 short children across cgroup teardown windows under their original bounds" $ do
    resources <- ownedFixtureResources
    limits <-
      either (fail . show) pure (mkOwnedSubprocessLimits resources 500000 50000 100000 50000 128 128)
    forM_ [1 .. (2048 :: Int)] $ \_ -> do
      result <- captureOwnedSubprocess limits (Subprocess "/bin/true" [] Nothing Nothing)
      result `shouldBe` Right (ProcessOutput ExitSuccess "" "")

  it "reports the exact exit and both streams after confirmed shutdown" $ do
    result <- runOwned 2000000 4 4 (script "printf out; printf err >&2; sleep 0.1; exit 3")
    result `shouldBe` Right (ProcessOutput (ExitFailure 3) "out" "err")

  it "admits exact output ceilings without an extra retained chunk" $ do
    result <- runOwned 2000000 4 4 (script "printf 1234; printf 5678 >&2; sleep 0.1")
    result `shouldBe` Right (ProcessOutput ExitSuccess "1234" "5678")

  forM_
    [("stdout", "", OwnedSubprocessStdoutExceeded), ("stderr", " >&2", OwnedSubprocessStderrExceeded)]
    $ \(label, redirect, expected) ->
      it ("stops on " <> label <> " overflow and confirms the owned child gone") $
        withSystemTempDirectory "bounded-owned-output" $ \directory -> do
          let pidPath = directory <> "/pid"
              body = "echo $$ > " <> pidPath <> "; sleep 0.05; while true; do printf 12345" <> redirect <> "; done"
          (result, elapsed) <- elapsedMillis (runOwned 2000000 4 4 (script body))
          result `shouldBe` Left expected
          elapsed `shouldSatisfy` (< 1500)
          recordedPid pidPath >>= eventuallyGone >>= (`shouldBe` True)

  it "reserves ignored-TERM stop and confirmation inside the original total" $
    withSystemTempDirectory "bounded-owned-timeout" $ \directory -> do
      let pidPath = directory <> "/pid"
          body = "echo $$ > " <> pidPath <> "; trap '' TERM; while true; do sleep 0.1; done"
      (result, elapsed) <- elapsedMillis (runOwned 1000000 32 32 (script body))
      result `shouldBe` Left OwnedSubprocessDeadlineReached
      elapsed `shouldSatisfy` (< 1500)
      recordedPid pidPath >>= eventuallyGone >>= (`shouldBe` True)

  it "propagates cancellation after confirming the owned child stopped" $
    withSystemTempDirectory "bounded-owned-cancel" $ \directory -> do
      let pidPath = directory <> "/pid"
          body = "echo $$ > " <> pidPath <> "; trap '' TERM; while true; do sleep 0.1; done"
      (result, elapsed) <- elapsedMillis (timeout 200000 (runOwned 5000000 32 32 (script body)))
      result `shouldBe` Nothing
      elapsed `shouldSatisfy` (< 1500)
      recordedPid pidPath >>= eventuallyGone >>= (`shouldBe` True)

  it "stops a separately grouped pipe holder after normal parent exit and preserves a foreign child" $
    withSystemTempDirectory "bounded-owned-pipe" $ \directory -> do
      (_, _, _, foreignProcess) <- Process.createProcess (Process.proc "/bin/sleep" ["30"])
      let pidPath = directory <> "/plugin"
          body =
            "setsid /bin/sh -c 'echo $$ > \"$1\"; cat /proc/$$/stat > \"$1.stat\"; trap \"\" TERM; exec sleep 30' plugin "
              <> pidPath
              <> " & sleep 0.2; printf done"
      ( do
          (result, elapsed) <- elapsedMillis (runOwned 2000000 4 4 (script body))
          result `shouldBe` Right (ProcessOutput ExitSuccess "done" "")
          elapsed `shouldSatisfy` (< 1500)
          recordedPid pidPath >>= processStopped >>= (`shouldBe` True)
          Process.getProcessExitCode foreignProcess >>= (`shouldBe` Nothing)
        )
        `finally` do
          cleanupPlugin pidPath
          Process.terminateProcess foreignProcess
          void (Process.waitForProcess foreignProcess)

  it "refuses an unstartable child without returning exception payload" $ do
    result <- runOwned 2000000 4 4 (Subprocess "/prodbox-fixture-absent/child" [] Nothing Nothing)
    result `shouldBe` Left OwnedSubprocessStartFailed
 where
  runOwned total out err child = do
    uid <- getEffectiveUserID
    socket <-
      try (getSymbolicLinkStatus ("/run/user/" <> show uid <> "/bus"))
        :: IO (Either IOException FileStatus)
    unlessNative (either (const False) (\status -> isSocket status && fileOwner status == uid) socket)
    result <- runOwnedFixture total out err child
    case result of
      Left OwnedSubprocessManagerRefused -> refuse result
      Left OwnedSubprocessScopeUnobservable -> refuse result
      Left OwnedSubprocessRuntimeUnsupported -> refuse result
      _ -> pure result
  refuse result = do
    expectationFailure
      ( "native child ownership refused: "
          <> show result
          <> "; use a Linux user session with its systemd user bus, delegated cgroup v2 and one runtime capability"
      )
    pure result
  unlessNative available =
    if available
      then pure ()
      else
        expectationFailure
          "native child ownership requires an owned systemd user socket and delegated cgroup v2"

fixtureRuntimePlan :: Integer -> IO RuntimeMemory.RuntimeMemoryPlan
fixtureRuntimePlan limit = do
  let positive term amount = either (fail . show) pure (RuntimeMemory.mkPositiveBytes term amount)
      mib = 1024 * 1024
  application <- positive RuntimeMemory.BoundedApplicationState (1 * mib)
  pending <- positive RuntimeMemory.BoundedPendingPersistenceState (1 * mib)
  scratch <- positive RuntimeMemory.InHeapTransportDecodeScratch (2 * mib)
  reserve <- positive RuntimeMemory.OtherHeapReserve (2 * mib)
  heap <- positive RuntimeMemory.HeapCap (16 * mib)
  native <- positive RuntimeMemory.NativeNonHeapReserve (4 * mib)
  kernel <- positive RuntimeMemory.KernelCgroupReserve (4 * mib)
  margin <- positive RuntimeMemory.SafetyMargin (4 * mib)
  container <- positive RuntimeMemory.ContainerMemoryLimit (fromInteger limit)
  let inputs =
        RuntimeMemory.RuntimeMemoryInputs
          { RuntimeMemory.runtimeBoundedApplicationState = application
          , RuntimeMemory.runtimeBoundedPendingPersistenceState = pending
          , RuntimeMemory.runtimeInHeapTransportDecodeScratch = scratch
          , RuntimeMemory.runtimeOtherHeapReserve = reserve
          , RuntimeMemory.runtimeHeapCap = heap
          , RuntimeMemory.runtimeNativeNonHeapReserve = native
          , RuntimeMemory.runtimeRawChildSchedule =
              RuntimeMemory.BoundedChildSchedule 1 (Just 10000000) [80 * mib]
          , RuntimeMemory.runtimeKernelCgroupReserve = kernel
          , RuntimeMemory.runtimeSafetyMargin = margin
          , RuntimeMemory.runtimeContainerMemoryLimit = container
          }
  either (fail . show) pure (RuntimeMemory.validateRuntimeMemoryPlan inputs)
