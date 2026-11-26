{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}

module DeploymentScopeTests (deploymentScopeSuite) where

import Control.Concurrent (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async (cancel, concurrently, wait, withAsync)
import Control.Exception (IOException, SomeException, bracket, evaluate, try)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Either (isLeft, isRight)
import Data.IORef (modifyIORef, newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Foreign.C.Types (CInt (..))
import Prodbox.Capacity.NativeHostProbe (parseNativeHostAvailableMemoryMib)
import Prodbox.Config.BootstrapProjection
import Prodbox.Config.DeploymentScope
import Prodbox.Config.KindPlan
import Prodbox.Config.KindVolume
import Prodbox.Config.SelectedDhall
import Prodbox.Control.DockerConnectedInfo (parseDockerKindContainers, parseDockerNetworkDetails)
import Prodbox.Control.DockerIdentity
import Prodbox.Control.KindDockerReadGate
import Prodbox.Control.KindIntent
import Prodbox.Control.KindKubeconfig (kindKubeconfigContext)
import Prodbox.Control.KindKubeconfigFile
import Prodbox.Control.KindLease
import Prodbox.Control.KindNodeVolumeIntent
import Prodbox.Control.NodeImageIntent
import Prodbox.Control.Status
  ( ControlStatusError (..)
  , ImageArchiveComparison (..)
  , ImageIdObservation (..)
  , ImageObservation (..)
  , RuntimeInventoryDecision (..)
  , RuntimeObservation (..)
  , chooseRuntimeCandidate
  , compareImageArchive
  , observeRuntimeInventory
  , parseImageIdObservation
  , parseImageObservation
  , parseNodeObservation
  )
import Prodbox.Settings.Coordinate (mkIpLiteral)
import System.Directory
  ( createDirectory
  , createDirectoryIfMissing
  , doesDirectoryExist
  , removeDirectory
  , removeFile
  , renameDirectory
  , renameFile
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files
  ( createLink
  , createSymbolicLink
  , deviceID
  , fileID
  , getFileStatus
  , setFileMode
  )
import System.Posix.IO qualified as Posix
import System.Posix.Types (Fd (..))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)
import TestSupport
  ( SuiteBuilder
  , assertMutationInvariant
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldNotBe
  , shouldReturn
  , shouldSatisfy
  )

foreign import capi "sys/file.h flock" testFlock :: CInt -> CInt -> IO CInt
foreign import capi "sys/file.h value LOCK_EX" testExclusive :: CInt

deploymentScopeSuite :: SuiteBuilder ()
deploymentScopeSuite = describe "deployment scope coordinates" $ do
  it "limits an inventory gate to the selected-cluster request" $
    case deploymentScope "/project" Test "run" 26443 of
      Left failure -> expectationFailure (show failure)
      Right scope -> do
        let imageId = "sha256:" ++ replicate 64 'a'
            request =
              [ "ps"
              , "-a"
              , "--filter"
              , "label=io.x-k8s.kind.cluster"
              , "--format"
              , "{{.Label \"io.x-k8s.kind.cluster\"}}"
              ]
            observe _ = pure (Right () :: Either String ())
        created <- newKindInventoryReadGate scope imageId
        case created of
          Nothing -> expectationFailure "inventory gate refused a valid image ID"
          Just gate -> do
            runKindDockerRead gate request observe `shouldReturn` KindDockerReadCompleted ()
            kindDockerInventoryObserved gate `shouldReturn` True
            runKindDockerRead gate ["info", "--format", "{{json .}}"] observe
              `shouldReturn` KindDockerReadRefused
            runKindDockerRead gate request observe `shouldReturn` KindDockerReadRefused
  it "closes the kind Docker read gate after a forbidden or failed request" $
    case deploymentScope "/project" Test "run" 26443 of
      Left failure -> expectationFailure (show failure)
      Right scope -> do
        let imageId = "sha256:" ++ replicate 64 'a'
            readImage = ["inspect", "--type=image", imageId]
            forbidden =
              [ ["pull", imageId]
              , ["network", "rm", replicate 64 'b']
              , ["inspect", "--type=image", "foreign"]
              , ["ps", "-a", "--filter", "label=io.x-k8s.kind.cluster=foreign", "--format", "{{.Names}}"]
              ]
        invalid <- newKindDockerReadGate scope "not-an-image"
        case invalid of
          Nothing -> pure ()
          Just _ -> expectationFailure "accepted malformed image ID"
        forM_ forbidden $ \request -> do
          created <- newKindDockerReadGate scope imageId
          case created of
            Nothing -> expectationFailure "refused valid image ID"
            Just gate -> do
              calls <- newIORef ([] :: [KindDockerReadRequest])
              let observe value = modifyIORef calls (++ [value]) >> pure (Right () :: Either String ())
              runKindDockerRead gate ["info", "--format", "{{json .}}"] observe
                `shouldReturn` KindDockerReadCompleted ()
              runKindDockerRead
                gate
                ["ps", "-a", "--filter", "label=io.x-k8s.kind.cluster=prodbox-t-run", "--format", "{{.Names}}"]
                observe
                `shouldReturn` KindDockerReadCompleted ()
              runKindDockerRead gate readImage observe `shouldReturn` KindDockerReadCompleted ()
              rejected <- runKindDockerRead gate request observe
              if request == ["pull", imageId]
                then assertMutationInvariant "context.rejects_unowned_pull" (rejected == KindDockerReadRefused)
                else rejected `shouldBe` KindDockerReadRefused
              runKindDockerRead gate readImage observe `shouldReturn` KindDockerReadRefused
              readIORef calls
                `shouldReturn` [KindDockerInfo, KindDockerClusterContainers "prodbox-t-run", KindDockerImage imageId]
        created <- newKindDockerReadGate scope imageId
        case created of
          Nothing -> expectationFailure "refused valid image ID"
          Just gate -> do
            interrupted <- try (runKindDockerRead gate readImage (\_ -> ioError (userError "fixture")))
            case interrupted :: Either IOException (KindDockerReadResult String ()) of
              Left _ -> pure ()
              Right _ -> expectationFailure "failed observation was accepted"
            runKindDockerRead gate readImage (\_ -> pure (Right () :: Either String ()))
              `shouldReturn` KindDockerReadRefused
        failed <- newKindDockerReadGate scope imageId
        case failed of
          Nothing -> expectationFailure "refused valid image ID"
          Just gate -> do
            runKindDockerRead gate readImage (\_ -> pure (Left "unobservable" :: Either String ()))
              `shouldReturn` KindDockerReadFailed "unobservable"
            runKindDockerRead gate readImage (\_ -> pure (Right () :: Either String ()))
              `shouldReturn` KindDockerReadRefused
        deferred <- newKindDockerReadGate scope imageId
        case deferred of
          Nothing -> expectationFailure "refused valid image ID"
          Just gate -> do
            interrupted <-
              try
                ( runKindDockerRead gate readImage (\_ -> pure (Right (error "deferred") :: Either String ()))
                    >>= evaluate
                )
            case interrupted :: Either SomeException (KindDockerReadResult String ()) of
              Left _ -> pure ()
              Right _ -> expectationFailure "deferred failure was accepted"
            runKindDockerRead gate readImage (\_ -> pure (Right () :: Either String ()))
              `shouldReturn` KindDockerReadRefused

  it "parses available host memory without accepting missing or duplicate observations" $ do
    parseNativeHostAvailableMemoryMib "MemTotal: 8192 kB\nMemAvailable: 3072 kB\n" `shouldBe` Right 3
    parseNativeHostAvailableMemoryMib "MemAvailable: 0 kB\n" `shouldBe` Right 0
    parseNativeHostAvailableMemoryMib "MemTotal: 8192 kB\n" `shouldSatisfy` isLeft
    parseNativeHostAvailableMemoryMib "MemAvailable: 1024 kB\nMemAvailable: 2048 kB\n"
      `shouldSatisfy` isLeft
    parseNativeHostAvailableMemoryMib "MemAvailable: 18446744073709551616 kB\n" `shouldSatisfy` isLeft

  it "refuses foreign or ambiguous kind container inventory" $
    case deploymentScope "/project" Test "run" 26443 of
      Left failure -> expectationFailure (show failure)
      Right scope -> do
        let entry label names identifier =
              Aeson.object
                [ "Id" Aeson..= (identifier :: String)
                , "Names" Aeson..= (names :: [String])
                , "Labels" Aeson..= Aeson.object ["io.x-k8s.kind.cluster" Aeson..= (label :: String)]
                ]
            correct = entry "prodbox-t-run" ["/prodbox-t-run-control-plane"] (replicate 64 'a')
            foreignLabel = entry "foreign" ["/prodbox-t-run-control-plane"] (replicate 64 'a')
            foreignName = entry "prodbox-t-run" ["/foreign-control-plane"] (replicate 64 'a')
            invalidId = entry "prodbox-t-run" ["/prodbox-t-run-control-plane"] "bad"
        parseDockerKindContainers scope (Aeson.toJSON ([] :: [Aeson.Value])) `shouldBe` Right []
        parseDockerKindContainers scope (Aeson.toJSON [correct])
          `shouldBe` Right ["prodbox-t-run-control-plane"]
        assertMutationInvariant
          "context.rejects_foreign_scope"
          (isLeft (parseDockerKindContainers scope (Aeson.toJSON [foreignLabel])))
        forM_ [[foreignName], [invalidId], [correct, correct]] $ \entries ->
          parseDockerKindContainers scope (Aeson.toJSON entries) `shouldSatisfy` isLeft

  it "refuses a same-ID Docker network reported under a foreign name" $
    case deploymentScope "/project" Test "run" 26443 of
      Left failure -> expectationFailure (show failure)
      Right scope -> do
        let identifier = replicate 64 'a'
            network name =
              Aeson.object
                [ "Name" Aeson..= (name :: String)
                , "Id" Aeson..= identifier
                , "Driver" Aeson..= ("bridge" :: String)
                , "EnableIPv6" Aeson..= True
                , "IPAM" Aeson..= Aeson.object []
                ]
        parseDockerNetworkDetails scope identifier (network "prodbox-t-run") `shouldSatisfy` isRight
        assertMutationInvariant
          "context.rejects_foreign_network"
          (isLeft (parseDockerNetworkDetails scope identifier (network "foreign")))

  it "serializes kind reads and closes the gate on cancellation" $ do
    outcome <- timeout 5000000 $ case deploymentScope "/project" Test "run" 26443 of
      Left failure -> expectationFailure (show failure)
      Right scope -> do
        let imageId = "sha256:" ++ replicate 64 'a'
            request = ["inspect", "--type=image", imageId]
        created <- newKindDockerReadGate scope imageId
        case created of
          Nothing -> expectationFailure "refused valid image ID"
          Just gate -> do
            started <- newEmptyMVar
            release <- newEmptyMVar
            calls <- newIORef (0 :: Int)
            withAsync
              ( runKindDockerRead
                  gate
                  request
                  (\_ -> putMVar started () >> takeMVar release >> pure (Left "failed" :: Either String ()))
              )
              $ \first -> do
                takeMVar started
                withAsync
                  ( runKindDockerRead
                      gate
                      request
                      (\_ -> modifyIORef calls (+ 1) >> pure (Right () :: Either String ()))
                  )
                  $ \second -> do
                    putMVar release ()
                    wait first `shouldReturn` KindDockerReadFailed "failed"
                    wait second `shouldReturn` KindDockerReadRefused
                    readIORef calls `shouldReturn` 0
        cancellationGate <- newKindDockerReadGate scope imageId
        case cancellationGate of
          Nothing -> expectationFailure "refused valid image ID"
          Just gate -> do
            started <- newEmptyMVar
            never <- newEmptyMVar
            withAsync
              ( runKindDockerRead
                  gate
                  request
                  (\_ -> putMVar started () >> takeMVar never >> pure (Right () :: Either String ()))
              )
              $ \worker -> do
                takeMVar started
                cancel worker
                runKindDockerRead gate request (\_ -> pure (Right () :: Either String ()))
                  `shouldReturn` KindDockerReadRefused
    outcome `shouldBe` Just ()

  it "refuses publication while another descriptor owns the parent lease" $
    withSystemTempDirectory "prodbox-selected-busy" $ \anchor -> do
      let path = anchor </> "prodbox.dhall"
      bracket (Posix.openFd anchor Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \(Fd descriptor) -> do
        testFlock descriptor testExclusive `shouldReturn` 0
        publishNewSelectedDhall path "{ bootstrap = True }" `shouldReturn` SelectedDhallPublicationBusy
      publishNewSelectedDhall path "{ bootstrap = True }" `shouldReturn` SelectedDhallPublished

  it "publishes a selected document once and preserves competing or unsafe paths" $
    withSystemTempDirectory "prodbox-selected-publication" $ \anchor -> do
      let path = anchor </> "prodbox.dhall"
          source = "{ bootstrap = True }"
          pending = anchor </> ".next.dhall.prodbox-pending"
      publishNewSelectedDhall path source `shouldReturn` SelectedDhallPublished
      readSelectedDhall path `shouldReturn` Right source
      publishNewSelectedDhall path "{ bootstrap = False }" `shouldReturn` SelectedDhallDestinationExists
      readSelectedDhall path `shouldReturn` Right source
      writeFile pending "incomplete"
      publishNewSelectedDhall (anchor </> "next.dhall") source `shouldReturn` SelectedDhallPendingExists
      readFile pending `shouldReturn` "incomplete"
      publishNewSelectedDhall (anchor </> "invalid.dhall") "env:SHOULD_NOT_BE_READ"
        `shouldReturn` SelectedDhallPublicationInvalid
      createDirectory (anchor </> "foreign")
      writeFile (anchor </> "foreign" </> "marker") "unchanged"
      createSymbolicLink (anchor </> "foreign") (anchor </> "linked")
      publishNewSelectedDhall (anchor </> "linked" </> "prodbox.dhall") source
        `shouldReturn` SelectedDhallPublicationUnobservable
      readFile (anchor </> "foreign" </> "marker") `shouldReturn` "unchanged"
      setFileMode (anchor </> "foreign") 0o777
      publishNewSelectedDhall (anchor </> "foreign" </> "prodbox.dhall") source
        `shouldReturn` SelectedDhallPublicationUnobservable
      setFileMode (anchor </> "foreign") 0o700

  it "allows only one concurrent selected-document publication" $
    withSystemTempDirectory "prodbox-selected-publication-race" $ \anchor -> do
      let path = anchor </> "prodbox.dhall"
          firstSource = "{ bootstrap = True }"
          secondSource = "{ bootstrap = False }"
      (first, second) <-
        concurrently (publishNewSelectedDhall path firstSource) (publishNewSelectedDhall path secondSource)
      length (filter (== SelectedDhallPublished) [first, second]) `shouldBe` 1
      final <- readSelectedDhall path
      final `shouldSatisfy` (`elem` [Right firstSource, Right secondSource])

  it "recovers only exact v2 pending content and preserves legacy or competing files" $
    withSystemTempDirectory "prodbox-selected-recovery" $ \anchor -> do
      let path = anchor </> "recover.dhall"
          pending = anchor </> ".recover.dhall.prodbox-v2-pending"
          legacy = anchor </> ".recover.dhall.prodbox-pending"
          source = "{ bootstrap = True }"
      writeFile pending "{ bootstrap = False }"
      recoverSelectedDhall path source `shouldReturn` SelectedDhallRecoveryMismatch
      readFile pending `shouldReturn` "{ bootstrap = False }"
      writeFile pending "{ bootstrap = True }"
      writeFile legacy "legacy"
      recoverSelectedDhall path source `shouldReturn` SelectedDhallPendingExists
      readFile legacy `shouldReturn` "legacy"
      removeFile legacy
      recoverSelectedDhall path source `shouldReturn` SelectedDhallPublished
      readSelectedDhall path `shouldReturn` Right source
      recoverSelectedDhall path source `shouldReturn` SelectedDhallAlreadyMatches
      recoverSelectedDhall path "{ bootstrap = False }" `shouldReturn` SelectedDhallDestinationExists
      writeFile pending "{ bootstrap = False }"
      recoverSelectedDhall path source `shouldReturn` SelectedDhallDestinationExists
      readFile pending `shouldReturn` "{ bootstrap = False }"

  it "derives distinct production and test coordinates from an explicit anchor" $ do
    fmap scopeRoot (deploymentScope "/project" Production "alpha" 26443)
      `shouldBe` Right "/project/.data/alpha"
    fmap scopeRoot (deploymentScope "/project" Test "alpha" 26444)
      `shouldBe` Right "/project/.test-data/alpha"
    fmap scopeKubeconfig (deploymentScope "/project" Test "alpha" 26444)
      `shouldBe` Right "/project/.test-data/alpha/control/kubeconfig"
    ( do
        production <- deploymentScope "/project" Production "alpha" 26443
        testing <- deploymentScope "/project" Test "alpha" 26444
        requireDisjointScopes production testing
      )
      `shouldBe` Right ()

  it "rejects unsafe project anchors and invalid deployment identifiers" $ do
    mapM_
      (\anchor -> deploymentScope anchor Test "run" 26443 `shouldBe` Left InvalidProjectAnchor)
      [ "project"
      , "/"
      , "/project/../foreign"
      , "/project/./child"
      , "/project//child"
      , "/project/.data"
      , "/project/.data/production"
      , "/project/.data/production/nested"
      , '/' : replicate 4096 'a'
      ]
    deploymentScope "/project/.test-data/run" Production "policy-fixture" 26443
      `shouldSatisfy` isRight
    mapM_
      ( \identifier -> deploymentScope "/project" Test identifier 26443 `shouldBe` Left InvalidDeploymentIdentifier
      )
      ["", "../prod", "UPPER", "-run", "run-", "run_1", replicate 41 'a', "tést"]

  it "rejects overlapping roots for the mutation catalog" $
    assertMutationInvariant
      "context.rejects_root_alias"
      ( ( do
            outer <- deploymentScope "/project" Test "run" 26443
            nested <- deploymentScope "/project/.test-data/run" Production "child" 26444
            requireDisjointScopes outer nested
        )
          == Left OverlappingDeploymentRoots
      )

  it "rejects overlapping roots, duplicate cluster names, and port collisions" $ do
    ( do
        outer <- deploymentScope "/project" Test "run" 26443
        nested <- deploymentScope "/project/.test-data/run" Production "child" 26444
        requireDisjointScopes outer nested
      )
      `shouldBe` Left OverlappingDeploymentRoots
    ( do
        first <- deploymentScope "/project-a" Test "run" 26443
        second <- deploymentScope "/project-b" Test "run" 26444
        requireDisjointScopes first second
      )
      `shouldBe` Left DuplicateKindName
    ( do
        first <- deploymentScope "/project" Production "one" 26443
        second <- deploymentScope "/project" Test "two" 26443
        requireDisjointScopes first second
      )
      `shouldBe` Left DuplicateApiPort
    deploymentScope "/project" Test "run" 0 `shouldBe` Left InvalidApiPort
    deploymentScope "/project" Test "run" 65536 `shouldBe` Left InvalidApiPort

  it "distinguishes absent and present roots and rejects a symlinked scope parent" $
    withSystemTempDirectory "prodbox-scope-observer" $ \anchor -> do
      scope <- either (fail . show) pure (deploymentScope anchor Test "run" 26443)
      observeScopeRoot scope `shouldReturn` Right ScopeRootAbsent
      createDirectory (anchor </> ".test-data")
      createDirectory (scopeRoot scope)
      observeScopeRoot scope `shouldReturn` Right ScopeRootPresent
      removeDirectory (scopeRoot scope)
      removeDirectory (anchor </> ".test-data")
      createDirectory (anchor </> "foreign")
      writeFile (anchor </> "foreign" </> "marker") "unchanged"
      createSymbolicLink (anchor </> "foreign") (anchor </> ".test-data")
      observeScopeRoot scope `shouldReturn` Left (ScopePathSymlink (anchor </> ".test-data"))
      readFile (anchor </> "foreign" </> "marker") `shouldReturn` "unchanged"

  it "refuses a missing or non-directory project anchor" $
    withSystemTempDirectory "prodbox-scope-anchor" $ \parent -> do
      let missing = parent </> "missing"
          file = parent </> "file"
      writeFile file "fixture"
      case (deploymentScope missing Test "run" 26443, deploymentScope file Test "run" 26444) of
        (Right missingScope, Right fileScope) -> do
          observeScopeRoot missingScope `shouldReturn` Left (ScopeAnchorMissing missing)
          observeScopeRoot fileScope `shouldReturn` Left (ScopePathNotDirectory file)
        other -> expectationFailure (show other)

  it "detects replacement of a held root and refuses a symlinked path" $
    withSystemTempDirectory "prodbox-scope-descriptor" $ \anchor -> do
      createDirectory (anchor </> ".test-data")
      case deploymentScope anchor Test "run" 26443 of
        Left failure -> expectationFailure (show failure)
        Right scope -> do
          createDirectory (scopeRoot scope)
          observed <- withObservedScopeRoot scope $ \stillSame -> do
            stillSame `shouldReturn` True
            renameDirectory (scopeRoot scope) (anchor </> ".test-data" </> "old")
            createDirectory (scopeRoot scope)
            stillSame `shouldReturn` False
          observed `shouldBe` Right ()
          callbackFailure <-
            try (withObservedScopeRoot scope (\_ -> ioError (userError "callback failure")))
              :: IO (Either IOException (Either DeploymentScopeError ()))
          either (const True) (const False) callbackFailure `shouldBe` True
          removeDirectory (scopeRoot scope)
          createSymbolicLink (anchor </> ".test-data" </> "old") (scopeRoot scope)
          refused <- withObservedScopeRoot scope (const (pure ()))
          refused `shouldBe` Left (ScopePathUnobservable (scopeRoot scope))

  it "observes generation metadata without treating copied, corrupt, or linked records as matches" $
    withSystemTempDirectory "prodbox-generation-observer" $ \anchor -> do
      createDirectory (anchor </> ".test-data")
      case deploymentScope anchor Test "run" 26443 of
        Left failure -> expectationFailure (show failure)
        Right scope -> do
          let root = scopeRoot scope
              marker = root </> "scope-generation.json"
              generation = replicate 32 'a'
          createDirectory root
          observeScopeGeneration scope "bad" `shouldReturn` Right ScopeGenerationInvalidExpected
          observeScopeGeneration scope generation `shouldReturn` Right ScopeGenerationMissing
          status <- getFileStatus root
          let record =
                Aeson.object
                  [ "schema_version" Aeson..= (1 :: Int)
                  , "environment" Aeson..= ("test" :: String)
                  , "deployment_id" Aeson..= ("run" :: String)
                  , "generation" Aeson..= generation
                  , "root_device" Aeson..= toInteger (deviceID status)
                  , "root_inode" Aeson..= toInteger (fileID status)
                  ]
          LazyByteString.writeFile marker (Aeson.encode record)
          observeScopeGeneration scope generation `shouldReturn` Right ScopeGenerationMatches
          observeScopeGeneration scope (replicate 32 'b') `shouldReturn` Right ScopeGenerationForeign
          setFileMode marker 0o666
          observeScopeGeneration scope generation `shouldReturn` Right ScopeGenerationUnobservable
          setFileMode marker 0o600
          writeFile marker "not json"
          observeScopeGeneration scope generation `shouldReturn` Right ScopeGenerationInvalid
          removeFile marker
          createSymbolicLink (anchor </> "foreign") marker
          observeScopeGeneration scope generation `shouldReturn` Right ScopeGenerationUnobservable
          removeFile marker
          LazyByteString.writeFile marker (Aeson.encode record)
          renameDirectory root (anchor </> ".test-data" </> "old")
          createDirectory root
          LazyByteString.writeFile (root </> "scope-generation.json") (Aeson.encode record)
          observeScopeGeneration scope generation `shouldReturn` Right ScopeGenerationForeign

  it "creates only the selected shared parent under an owned anchor" $
    withSystemTempDirectory "prodbox-fresh-automatic-parent" $ \anchor -> do
      createDirectory (anchor </> ".data")
      writeFile (anchor </> ".data" </> "production-marker") "unchanged"
      scope <- either (fail . show) pure (deploymentScope anchor Test "run" 26443)
      prepareFreshScope scope "bad" `shouldReturn` FreshScopeInvalidGeneration
      doesDirectoryExist (anchor </> ".test-data") `shouldReturn` False
      prepareFreshScope scope (replicate 32 'a') `shouldReturn` FreshScopePrepared
      observeScopeGeneration scope (replicate 32 'a') `shouldReturn` Right ScopeGenerationMatches
      readFile (anchor </> ".data" </> "production-marker") `shouldReturn` "unchanged"

  it "refuses an unsafe anchor without creating the selected parent" $
    withSystemTempDirectory "prodbox-fresh-unsafe-anchor" $ \anchor -> do
      scope <- either (fail . show) pure (deploymentScope anchor Test "run" 26443)
      setFileMode anchor 0o777
      prepareFreshScope scope (replicate 32 'a') `shouldReturn` FreshScopeUnobservable
      doesDirectoryExist (anchor </> ".test-data") `shouldReturn` False
      setFileMode anchor 0o700

  it "creates a production parent without changing an existing test sibling" $
    withSystemTempDirectory "prodbox-fresh-production-parent" $ \anchor -> do
      createDirectory (anchor </> ".test-data")
      writeFile (anchor </> ".test-data" </> "test-marker") "unchanged"
      scope <- either (fail . show) pure (deploymentScope anchor Production "run" 26443)
      prepareFreshScope scope (replicate 32 'a') `shouldReturn` FreshScopePrepared
      observeScopeGeneration scope (replicate 32 'a') `shouldReturn` Right ScopeGenerationMatches
      readFile (anchor </> ".test-data" </> "test-marker") `shouldReturn` "unchanged"

  it "permits concurrent distinct scopes to share a newly created parent" $
    withSystemTempDirectory "prodbox-fresh-parent-race" $ \anchor -> do
      firstScope <- either (fail . show) pure (deploymentScope anchor Test "first" 26443)
      secondScope <- either (fail . show) pure (deploymentScope anchor Test "second" 26444)
      (first, second) <-
        concurrently
          (prepareFreshScope firstScope (replicate 32 'a'))
          (prepareFreshScope secondScope (replicate 32 'b'))
      (first, second) `shouldBe` (FreshScopePrepared, FreshScopePrepared)
      observeScopeGeneration firstScope (replicate 32 'a') `shouldReturn` Right ScopeGenerationMatches
      observeScopeGeneration secondScope (replicate 32 'b') `shouldReturn` Right ScopeGenerationMatches

  it "refuses a root declared inside another scope's retained root and writes nothing there" $
    withSystemTempDirectory "prodbox-nested-scope" $ \anchor -> do
      createDirectory (anchor </> ".test-data")
      case deploymentScope anchor Test "outer" 26445 of
        Left failure -> fail (show failure)
        Right outer -> do
          prepareFreshScope outer (replicate 32 'a') `shouldReturn` FreshScopePrepared
          -- The inner project anchor is the outer scope's retained root.
          case deploymentScope (scopeRoot outer) Test "inner" 26446 of
            Left failure -> fail (show failure)
            Right inner -> do
              prepareFreshScope inner (replicate 32 'b')
                `shouldReturn` FreshScopeNestedInRetainedRoot (scopeRoot outer)
              doesDirectoryExist (scopeRoot outer </> ".test-data") `shouldReturn` False
              observeScopeGeneration outer (replicate 32 'a') `shouldReturn` Right ScopeGenerationMatches

  it "prepares only a fresh retained root and preserves existing or staged roots" $
    withSystemTempDirectory "prodbox-fresh-scope" $ \anchor -> do
      createDirectory (anchor </> ".test-data")
      case (deploymentScope anchor Test "run" 26443, deploymentScope anchor Test "staged" 26444) of
        (Right scope, Right staged) -> do
          let generation = replicate 32 'a'
              retainedMarker = scopeRoot scope </> "foreign-marker"
              stagedPath = anchor </> ".test-data" </> (".enroll-staged-" ++ generation)
          prepareFreshScope scope "bad" `shouldReturn` FreshScopeInvalidGeneration
          prepareFreshScope scope generation `shouldReturn` FreshScopePrepared
          observeScopeGeneration scope generation `shouldReturn` Right ScopeGenerationMatches
          writeFile retainedMarker "unchanged"
          prepareFreshScope scope generation `shouldReturn` FreshScopeAlreadyExists
          readFile retainedMarker `shouldReturn` "unchanged"
          createDirectory stagedPath
          writeFile (stagedPath </> "marker") "preserved"
          prepareFreshScope staged generation `shouldReturn` FreshScopeStagingExists stagedPath
          readFile (stagedPath </> "marker") `shouldReturn` "preserved"
        other -> expectationFailure (show other)

  it "publishes at most one competing fresh generation" $
    withSystemTempDirectory "prodbox-fresh-race" $ \anchor -> do
      createDirectory (anchor </> ".test-data")
      case deploymentScope anchor Test "race" 26443 of
        Left failure -> expectationFailure (show failure)
        Right scope -> do
          (first, second) <-
            concurrently
              (prepareFreshScope scope (replicate 32 'a'))
              (prepareFreshScope scope (replicate 32 'b'))
          length (filter (== FreshScopePrepared) [first, second]) `shouldBe` 1
          let winner = if first == FreshScopePrepared then replicate 32 'a' else replicate 32 'b'
          observeScopeGeneration scope winner `shouldReturn` Right ScopeGenerationMatches

  it "refuses a symlinked or writable scope parent before staging" $
    withSystemTempDirectory "prodbox-fresh-parent" $ \anchor -> do
      let foreignRoot = anchor </> "foreign"
          parent = anchor </> ".test-data"
      createDirectory foreignRoot
      writeFile (foreignRoot </> "marker") "unchanged"
      createSymbolicLink foreignRoot parent
      case deploymentScope anchor Test "run" 26443 of
        Left failure -> expectationFailure (show failure)
        Right scope -> do
          prepareFreshScope scope (replicate 32 'a') `shouldReturn` FreshScopeUnobservable
          readFile (foreignRoot </> "marker") `shouldReturn` "unchanged"
          removeFile parent
          createDirectory parent
          setFileMode parent 0o777
          prepareFreshScope scope (replicate 32 'a') `shouldReturn` FreshScopeUnobservable
          setFileMode parent 0o700

  it "records one durable kind intent bound to the selected scope and preserves existing records" $
    withSystemTempDirectory "prodbox-kind-intent" $ \anchor -> do
      let generation = replicate 32 'a'
          selected = anchor </> "selected.dhall"
      createDirectory (anchor </> ".test-data")
      writeFile selected (bootstrapDocument anchor "test" generation "26443" "28080")
      parsed <- readBootstrapProjection selected
      case parsed of
        Left failure -> expectationFailure (show failure)
        Right bootstrap -> do
          let scope = bootstrapScope bootstrap
              intent = scopeRoot scope </> "kind-intent.json"
          prepareFreshScope scope generation `shouldReturn` FreshScopePrepared
          observeKindIntent bootstrap `shouldReturn` KindIntentMissing
          recordKindIntent bootstrap "bad" `shouldReturn` KindIntentInvalidOperation
          writeFile selected (bootstrapDocument anchor "test" (replicate 32 'e') "26443" "28080")
          foreignBootstrap <- readBootstrapProjection selected
          case foreignBootstrap of
            Left failure -> expectationFailure (show failure)
            Right different -> recordKindIntent different (replicate 32 'f') `shouldReturn` KindIntentWrongGeneration
          (first, second) <-
            concurrently
              (recordKindIntent bootstrap (replicate 32 'b'))
              (recordKindIntent bootstrap (replicate 32 'c'))
          length (filter (== KindIntentRecorded) [first, second]) `shouldBe` 1
          length (filter (== KindIntentAlreadyExists) [first, second]) `shouldBe` 1
          let winningOperation = if first == KindIntentRecorded then replicate 32 'b' else replicate 32 'c'
          observeKindIntent bootstrap `shouldReturn` KindIntentMatches winningOperation
          writeFile selected (bootstrapDocument anchor "test" generation "26443" "28081")
          changed <- readBootstrapProjection selected
          case changed of
            Left failure -> expectationFailure (show failure)
            Right different -> observeKindIntent different `shouldReturn` KindIntentConflict
          before <- LazyByteString.readFile intent
          let decoded = Aeson.eitherDecode before :: Either String Aeson.Value
          decoded `shouldSatisfy` isRight
          case decoded of
            Right (Aeson.Object fields) -> do
              KeyMap.lookup "cluster" fields `shouldBe` Just (Aeson.String "prodbox-t-run")
              KeyMap.lookup "root_generation" fields `shouldBe` Just (Aeson.String (Text.pack generation))
              KeyMap.lookup "runtime_socket" fields `shouldBe` Just (Aeson.String "/var/run/docker.sock")
              KeyMap.lookup "operation_id" fields
                `shouldBe` Just
                  ( Aeson.String
                      (Text.pack (if first == KindIntentRecorded then replicate 32 'b' else replicate 32 'c'))
                  )
            other -> expectationFailure (show other)
          recordKindIntent bootstrap (replicate 32 'd') `shouldReturn` KindIntentAlreadyExists
          LazyByteString.readFile intent `shouldReturn` before
          let duplicated = "{\"operation_id\":\"" ++ winningOperation ++ "\"," ++ drop 1 (LazyChar8.unpack before)
          writeFile intent duplicated
          observeKindIntent bootstrap `shouldReturn` KindIntentInvalid
          LazyByteString.writeFile intent before
          writeFile intent "incomplete"
          observeKindIntent bootstrap `shouldReturn` KindIntentInvalid
          removeFile intent
          writeFile (anchor </> "foreign-intent") "unchanged"
          createSymbolicLink (anchor </> "foreign-intent") intent
          recordKindIntent bootstrap (replicate 32 'd') `shouldReturn` KindIntentAlreadyExists
          observeKindIntent bootstrap `shouldReturn` KindIntentObservationUnobservable
          readFile (anchor </> "foreign-intent") `shouldReturn` "unchanged"

  it "excludes another process and releases the kind lease after cancellation" $
    withSystemTempDirectory "prodbox-kind-lease" $ \anchor -> do
      let generation = replicate 32 'a'
          selected = anchor </> "selected.dhall"
      createDirectory (anchor </> ".test-data")
      writeFile selected (bootstrapDocument anchor "test" generation "26443" "28080")
      parsed <- readBootstrapProjection selected
      case parsed of
        Left failure -> expectationFailure (show failure)
        Right bootstrap -> do
          let scope = bootstrapScope bootstrap
          prepareFreshScope scope generation `shouldReturn` FreshScopePrepared
          first <- withKindLease bootstrap $ \recheck -> do
            stable <- recheck
            nested <- withKindLease bootstrap (const (pure ()))
            (exitCode, _, _) <-
              readProcessWithExitCode "/usr/bin/flock" ["-n", scopeRoot scope, "/usr/bin/true"] ""
            pure (stable, nested, exitCode)
          first `shouldBe` Right (KindLeaseCompleted (True, Left KindLeaseBusy, ExitFailure 1))
          started <- newEmptyMVar :: IO (MVar ())
          waitForCancellation <- newEmptyMVar :: IO (MVar ())
          withAsync (withKindLease bootstrap (\_ -> putMVar started () >> takeMVar waitForCancellation)) $ \worker -> do
            takeMVar started
            cancel worker
          withKindLease bootstrap (const (pure ())) `shouldReturn` Right (KindLeaseCompleted ())
          (releasedExit, _, _) <-
            readProcessWithExitCode "/usr/bin/flock" ["-n", scopeRoot scope, "/usr/bin/true"] ""
          releasedExit `shouldBe` ExitSuccess
          changed <- withKindLease bootstrap $ \_ -> do
            renameDirectory (scopeRoot scope) (anchor </> ".test-data" </> "original")
            createDirectory (scopeRoot scope)
            pure ("primary result" :: String)
          changed `shouldBe` Right (KindLeaseRootChanged "primary result")

  it "refuses an unsafe scope parent before and during a held kind lease" $
    withSystemTempDirectory "prodbox-kind-lease-parent" $ \anchor -> do
      let generation = replicate 32 'a'
          selected = anchor </> "selected.dhall"
          parent = anchor </> ".test-data"
      writeFile selected (bootstrapDocument anchor "test" generation "26443" "28080")
      bootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
      prepareFreshScope (bootstrapScope bootstrap) generation `shouldReturn` FreshScopePrepared
      called <- newIORef False
      setFileMode parent 0o777
      withKindLease bootstrap (\_ -> writeIORef called True) `shouldReturn` Left KindLeaseUnobservable
      readIORef called `shouldReturn` False
      setFileMode parent 0o700
      changed <- withKindLease bootstrap $ \recheck -> do
        setFileMode parent 0o777
        recheck
      changed `shouldBe` Right (KindLeaseRootChanged False)
      setFileMode parent 0o700
      withKindLease bootstrap (const (pure ())) `shouldReturn` Right (KindLeaseCompleted ())

  it "persists the kind intent before the operation callback and refuses interrupted replay" $
    withSystemTempDirectory "prodbox-kind-operation" $ \anchor -> do
      let generation = replicate 32 'a'
          operationId = replicate 32 'b'
          selected = anchor </> "selected.dhall"
      createDirectory (anchor </> ".test-data")
      writeFile selected (bootstrapDocument anchor "test" generation "26443" "28080")
      parsed <- readBootstrapProjection selected
      case parsed of
        Left failure -> expectationFailure (show failure)
        Right bootstrap -> do
          prepareFreshScope (bootstrapScope bootstrap) generation `shouldReturn` FreshScopePrepared
          called <- newIORef False
          missing <- withRecoveredKindOperation bootstrap operationId $ \_ -> writeIORef called True
          missing `shouldBe` KindOperationRefused (KindOperationObservationRefused KindIntentMissing)
          readIORef called `shouldReturn` False
          started <- newEmptyMVar :: IO (MVar KindIntentObservation)
          waitForCancellation <- newEmptyMVar :: IO (MVar ())
          withAsync
            ( withNewKindOperation bootstrap operationId $ \_ -> do
                observed <- observeKindIntent bootstrap
                putMVar started observed
                takeMVar waitForCancellation
            )
            $ \worker -> do
              takeMVar started `shouldReturn` KindIntentMatches operationId
              cancel worker
          observeKindIntent bootstrap `shouldReturn` KindIntentMatches operationId
          replay <- withNewKindOperation bootstrap operationId $ \_ -> writeIORef called True
          replay `shouldBe` KindOperationRefused (KindOperationIntentRefused KindIntentAlreadyExists)
          readIORef called `shouldReturn` False
          wrong <- withRecoveredKindOperation bootstrap (replicate 32 'c') $ \_ -> writeIORef called True
          wrong
            `shouldBe` KindOperationRefused (KindOperationObservationRefused (KindIntentMatches operationId))
          readIORef called `shouldReturn` False
          let intentPath = scopeRoot (bootstrapScope bootstrap) </> "kind-intent.json"
          original <- readFile intentPath
          recovered <- withRecoveredKindOperation bootstrap operationId $ \recheck -> do
            stable <- recheck
            nested <- withRecoveredKindOperation bootstrap operationId (const (pure ()))
            pure (stable, nested)
          recovered
            `shouldBe` KindOperationCallbackReturned
              (True, KindOperationRefused (KindOperationLeaseRefused KindLeaseBusy))
          readFile intentPath `shouldReturn` original
          changed <- withRecoveredKindOperation bootstrap operationId $ \recheck -> do
            writeFile intentPath "invalid record"
            recheck
          changed `shouldBe` KindOperationCallbackReturned False
          observeKindIntent bootstrap `shouldReturn` KindIntentInvalid
          refused <- withRecoveredKindOperation bootstrap operationId $ \_ -> writeIORef called True
          refused `shouldBe` KindOperationRefused (KindOperationObservationRefused KindIntentInvalid)
          readIORef called `shouldReturn` False

  it "retains an exact node image intent under the recorded operation" $
    withSystemTempDirectory "prodbox-node-image-intent" $ \anchor -> do
      let generation = replicate 32 'a'
          operation = replicate 32 'b'
          selected = anchor </> "selected.dhall"
          digest character = "sha256:" ++ replicate 64 character
          base = Text.pack (bootstrapDocument anchor "test" generation "26443" "28080")
          artifact =
            ", node_artifact = { path = \"artifacts/node.tar\", digest = \""
              <> Text.pack (digest 'a')
              <> "\", maximum_bytes = 4096 }"
          v2 =
            Text.replace
              ", listen_address ="
              (artifact <> ", listen_address =")
              (Text.replace "schema_version = 1" "schema_version = 2" base)
      writeFile selected (Text.unpack v2)
      bootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
      prepareFreshScope (bootstrapScope bootstrap) generation `shouldReturn` FreshScopePrepared
      intent <-
        maybe
          (fail "invalid node image fixture")
          pure
          (mkNodeImageIntent operation (digest 'c') (digest 'd') (digest 'e') 4096)
      other <-
        maybe
          (fail "invalid conflicting fixture")
          pure
          (mkNodeImageIntent operation (digest 'c') (digest 'd') (digest 'f') 4096)
      mkNodeImageIntent operation "sha256:bad" (digest 'd') (digest 'e') 4096 `shouldBe` Nothing
      mkNodeImageIntent operation (digest 'c') (digest 'd') (digest 'e') 0 `shouldBe` Nothing
      recordNodeImageIntent bootstrap intent (pure True) `shouldReturn` NodeImageIntentRefused
      result <- withNewKindOperation bootstrap operation $ \stable -> do
        observeNodeImageIntent bootstrap intent stable `shouldReturn` NodeImageIntentMissing
        observeRecordedNodeImageIntent bootstrap operation `shouldReturn` NodeImageIntentMissing
        recordNodeImageIntent bootstrap intent (pure False) `shouldReturn` NodeImageIntentRefused
        recordNodeImageIntent bootstrap intent stable `shouldReturn` NodeImageIntentRecorded
        observeNodeImageIntent bootstrap intent stable `shouldReturn` NodeImageIntentMatches
        observeRecordedNodeImageIntent bootstrap operation `shouldReturn` NodeImageIntentMatches
        observeNodeImageIntent bootstrap other stable `shouldReturn` NodeImageIntentConflict
        recordNodeImageIntent bootstrap other stable `shouldReturn` NodeImageIntentAlreadyExists
        pure ()
      result `shouldBe` KindOperationCallbackReturned ()
      let path = scopeRoot (bootstrapScope bootstrap) </> "node-image-intent.json"
      original <- readFile path
      let observedDaemon = DockerDaemonObserved "daemon-a" (DockerSocketIdentity 1 2 1000 0o140660)
          changedDaemon = DockerDaemonObserved "daemon-a" (DockerSocketIdentity 1 3 1000 0o140660)
      bound <- maybe (fail "invalid bound image intent") pure (bindNodeImageIntent intent observedDaemon)
      otherBound <-
        maybe (fail "invalid other daemon intent") pure (bindNodeImageIntent intent changedDaemon)
      bindNodeImageIntent intent DockerDaemonUnobservable `shouldBe` Nothing
      bindNodeImageIntent bound observedDaemon `shouldBe` Just bound
      bindNodeImageIntent bound changedDaemon `shouldBe` Nothing
      bindNodeImageIntent bound (DockerDaemonObserved "daemon-b" (DockerSocketIdentity 1 2 1000 0o140660))
        `shouldBe` Nothing
      length original `seq` removeFile path
      withRecoveredKindOperation bootstrap operation (recordNodeImageIntent bootstrap bound)
        `shouldReturn` KindOperationCallbackReturned NodeImageIntentRecorded
      observeRecordedNodeImageIntent bootstrap operation
        `shouldReturn` NodeImageIntentBound observedDaemon
      withRecoveredKindOperation bootstrap operation (observeNodeImageIntent bootstrap otherBound)
        `shouldReturn` KindOperationCallbackReturned NodeImageIntentConflict
      withRecoveredKindOperation bootstrap operation (observeNodeImageIntent bootstrap intent)
        `shouldReturn` KindOperationCallbackReturned NodeImageIntentConflict
      writeFile path original
      length original `seq` writeFile path "incomplete"
      observeRecordedNodeImageIntent bootstrap operation `shouldReturn` NodeImageIntentInvalid
      withRecoveredKindOperation bootstrap operation (observeNodeImageIntent bootstrap intent)
        `shouldReturn` KindOperationCallbackReturned NodeImageIntentInvalid
      writeFile path original
      removeFile path
      writeFile (anchor </> "foreign-image-intent") "foreign"
      createSymbolicLink (anchor </> "foreign-image-intent") path
      observeRecordedNodeImageIntent bootstrap operation `shouldReturn` NodeImageIntentUnobservable
      withRecoveredKindOperation bootstrap operation (observeNodeImageIntent bootstrap intent)
        `shouldReturn` KindOperationCallbackReturned NodeImageIntentUnobservable
      readFile (anchor </> "foreign-image-intent") `shouldReturn` "foreign"

  it "records and safely observes the scoped node volume proposal" $
    withSystemTempDirectory "prodbox-node-var-intent" $ \anchor -> do
      let generation = replicate 32 'a'
          operation = replicate 32 'b'
          selected = anchor </> "selected.dhall"
          daemon = DockerDaemonObserved "daemon-a" (DockerSocketIdentity 1 2 1000 0o140660)
          otherDaemon = DockerDaemonObserved "daemon-a" (DockerSocketIdentity 1 3 1000 0o140660)
      writeFile selected (bootstrapDocument anchor "test" generation "26443" "28080")
      bootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
      prepareFreshScope (bootstrapScope bootstrap) generation `shouldReturn` FreshScopePrepared
      intent <- maybe (fail "invalid volume proposal") pure (mkKindNodeVolumeIntent operation daemon)
      other <- maybe (fail "invalid other proposal") pure (mkKindNodeVolumeIntent operation otherDaemon)
      mkKindNodeVolumeIntent "invalid" daemon `shouldBe` Nothing
      mkKindNodeVolumeIntent operation DockerDaemonUnobservable `shouldBe` Nothing
      recordKindNodeVolumeIntent bootstrap intent (pure True) `shouldReturn` NodeVolumeIntentRefused
      withNewKindOperation
        bootstrap
        operation
        ( \stable -> do
            observeKindNodeVolumeIntent bootstrap intent stable `shouldReturn` NodeVolumeIntentMissing
            recordKindNodeVolumeAttempt bootstrap intent stable `shouldReturn` NodeVolumeAttemptRefused
            observeKindNodeVolumeAttempt bootstrap intent stable `shouldReturn` NodeVolumeAttemptUnobservable
            recordKindNodeVolumeIntent bootstrap intent (pure False) `shouldReturn` NodeVolumeIntentRefused
            recordKindNodeVolumeIntent bootstrap intent stable `shouldReturn` NodeVolumeIntentRecorded
            observeKindNodeVolumeIntent bootstrap intent stable `shouldReturn` NodeVolumeIntentMatches
            observeKindNodeVolumeAttempt bootstrap intent stable `shouldReturn` NodeVolumeAttemptMissing
            recordKindNodeVolumeAttempt bootstrap intent (pure False) `shouldReturn` NodeVolumeAttemptRefused
            recordKindNodeVolumeAttempt bootstrap intent stable `shouldReturn` NodeVolumeAttemptRecorded
            observeKindNodeVolumeAttempt bootstrap intent stable `shouldReturn` NodeVolumeAttemptMatches
            recordKindNodeVolumeAttempt bootstrap intent stable `shouldReturn` NodeVolumeAttemptAlreadyExists
            observeKindNodeVolumeAttempt bootstrap other stable `shouldReturn` NodeVolumeAttemptUnobservable
            observeKindNodeVolumeIntent bootstrap other stable `shouldReturn` NodeVolumeIntentConflict
            recordKindNodeVolumeIntent bootstrap other stable `shouldReturn` NodeVolumeIntentAlreadyExists
        )
        `shouldReturn` KindOperationCallbackReturned ()
      let path = scopeRoot (bootstrapScope bootstrap) </> "kind-node-var-volume-intent.json"
      let attemptPath = scopeRoot (bootstrapScope bootstrap) </> "kind-node-var-volume-attempt.json"
      writeFile attemptPath "{\"kind\":0,\"kind\":0}"
      withRecoveredKindOperation bootstrap operation (observeKindNodeVolumeAttempt bootstrap intent)
        `shouldReturn` KindOperationCallbackReturned NodeVolumeAttemptInvalid
      removeFile attemptPath
      writeFile (anchor </> "foreign-volume-attempt") "foreign"
      createSymbolicLink (anchor </> "foreign-volume-attempt") attemptPath
      withRecoveredKindOperation bootstrap operation (observeKindNodeVolumeAttempt bootstrap intent)
        `shouldReturn` KindOperationCallbackReturned NodeVolumeAttemptUnobservable
      readFile (anchor </> "foreign-volume-attempt") `shouldReturn` "foreign"
      original <- readFile path
      length original `seq` writeFile path "{\"schema_version\":1,\"schema_version\":1}"
      withRecoveredKindOperation bootstrap operation (observeKindNodeVolumeIntent bootstrap intent)
        `shouldReturn` KindOperationCallbackReturned NodeVolumeIntentInvalid
      removeFile path
      writeFile (anchor </> "foreign-volume-intent") "foreign"
      createSymbolicLink (anchor </> "foreign-volume-intent") path
      withRecoveredKindOperation bootstrap operation (observeKindNodeVolumeIntent bootstrap intent)
        `shouldReturn` KindOperationCallbackReturned NodeVolumeIntentUnobservable
      readFile (anchor </> "foreign-volume-intent") `shouldReturn` "foreign"

  it "creates a new retained volume only under the selected recorded operation" $
    withSystemTempDirectory "prodbox-volume-preparation" $ \anchor -> do
      let generation = replicate 32 'a'
          operationId = replicate 32 'b'
          selected = anchor </> "selected.dhall"
      writeFile selected (bootstrapDocument anchor "test" generation "26443" "28080")
      bootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
      let scope = bootstrapScope bootstrap
      prepareFreshScope scope generation `shouldReturn` FreshScopePrepared
      volume <- either (fail . show) pure (kindVolume scope generation "management" "worker" "state" 128)
      otherScope <- either (fail . show) pure (deploymentScope anchor Test "other" 26444)
      otherVolume <-
        either (fail . show) pure (kindVolume otherScope generation "management" "worker" "state" 128)
      prepareNewKindVolumeDirectory bootstrap operationId otherVolume
        `shouldReturn` KindOperationRefused (KindOperationIntentRefused KindIntentWrongVolume)
      observeKindIntent bootstrap `shouldReturn` KindIntentMissing
      observeKindVolumeDirectory volume `shouldReturn` KindVolumeDirectoryMissing
      prepareNewKindVolumeDirectory bootstrap operationId volume
        `shouldReturn` KindOperationCallbackReturned KindVolumeDirectoryCreated
      observeKindIntent bootstrap `shouldReturn` KindIntentVolumeMatches operationId volume
      observeKindVolumeIntent bootstrap volume `shouldReturn` KindIntentMatches operationId
      wrongVolume <-
        either (fail . show) pure (kindVolume scope generation "management" "worker" "other" 128)
      wrong <- prepareRecoveredKindVolumeDirectory bootstrap operationId wrongVolume
      wrong `shouldBe` KindOperationRefused (KindOperationObservationRefused KindIntentConflict)
      wrongCapacity <-
        either (fail . show) pure (kindVolume scope generation "management" "worker" "state" 256)
      prepareRecoveredKindVolumeDirectory bootstrap operationId wrongCapacity
        `shouldReturn` KindOperationRefused (KindOperationObservationRefused KindIntentConflict)
      withRecoveredKindOperation bootstrap operationId (const (pure ()))
        `shouldReturn` KindOperationRefused (KindOperationObservationRefused (KindIntentVolumeMatches operationId volume))
      observeKindVolumeDirectory volume `shouldReturn` KindVolumeDirectoryPresent
      let leaf =
            scopeRoot scope </> "control" </> "volumes" </> generation </> "management" </> "worker" </> "state"
      writeFile (leaf </> "marker") "retained"
      repeated <- prepareRecoveredKindVolumeDirectory bootstrap operationId volume
      repeated `shouldBe` KindOperationCallbackReturned KindVolumeDirectoryAlreadyExists
      readFile (leaf </> "marker") `shouldReturn` "retained"
      let foreignPath = anchor </> "foreign"
      renameDirectory leaf foreignPath
      createSymbolicLink foreignPath leaf
      linked <- prepareRecoveredKindVolumeDirectory bootstrap operationId volume
      linked `shouldBe` KindOperationCallbackReturned KindVolumeDirectoryAlreadyExists
      readFile (foreignPath </> "marker") `shouldReturn` "retained"
      let intentFile = scopeRoot scope </> "kind-intent.json"
      originalIntent <- readFile intentFile
      let duplicateVolume =
            Text.replace "\"volume\":{" "\"volume\":{\"namespace\":\"management\"," (Text.pack originalIntent)
      duplicateVolume `shouldNotBe` Text.pack originalIntent
      length originalIntent `seq` writeFile intentFile (Text.unpack duplicateVolume)
      observeKindIntent bootstrap `shouldReturn` KindIntentInvalid
      observeKindVolumeIntent bootstrap volume `shouldReturn` KindIntentInvalid
      prepareRecoveredKindVolumeDirectory bootstrap operationId volume
        `shouldReturn` KindOperationRefused (KindOperationObservationRefused KindIntentInvalid)
      length originalIntent `seq`
        writeFile intentFile (Text.unpack (Text.replace "management" "foreign" (Text.pack originalIntent)))
      observeKindIntent bootstrap `shouldReturn` KindIntentConflict

  describe "minimal bootstrap projection" $ do
    it "renders a structured version-3 draft that the real decoder validates" $
      withSystemTempDirectory "prodbox-bootstrap-draft" $ \anchor -> do
        let digest = "sha256:" <> Text.replicate 64 "a"
            draft =
              BootstrapDraft
                { draftProjectAnchor = Text.pack anchor
                , draftRuntimeSocket = "/var/run/docker.sock"
                , draftEnvironment = "test"
                , draftDeploymentId = "run"
                , draftRootGeneration = Text.replicate 32 "b"
                , draftApiPort = 26443
                , draftNodeImage = "kindest/node@" <> digest
                , draftHttpHostPort = 28080
                , draftHttpNodePort = 30080
                , draftHttpsHostPort = 28443
                , draftHttpsNodePort = 30443
                , draftListenAddress = "127.0.0.1"
                , draftNodePath = "artifacts/node.tar"
                , draftNodeDigest = digest
                , draftNodeMaximumBytes = 4096
                , draftKindPath = "artifacts/kind"
                , draftKindDigest = digest
                , draftKindMaximumBytes = 1048576
                }
            path = anchor </> "selected.dhall"
        decoded <- decodeOptionalBootstrapSource path (renderBootstrapDraft draft)
        fmap (fmap (scopeRoot . bootstrapScope)) decoded
          `shouldBe` Right (Just (anchor </> ".test-data" </> "run"))
        invalid <-
          decodeOptionalBootstrapSource path (renderBootstrapDraft draft {draftHttpsHostPort = 28080})
        invalid `shouldBe` Left (BootstrapInvalidKindPlan DuplicatePublicationPort)
        invalidNodePort <-
          decodeOptionalBootstrapSource path (renderBootstrapDraft draft {draftHttpNodePort = 29999})
        invalidNodePort `shouldBe` Left (BootstrapInvalidKindPlan InvalidPublicationNodePort)
        escaped <-
          decodeOptionalBootstrapSource path (renderBootstrapDraft draft {draftNodePath = "${env:FORBIDDEN}"})
        escaped `shouldBe` Left BootstrapInvalidArtifact
        writeFile path "production sibling marker"
        publishBootstrapDraft path draft `shouldReturn` Left BootstrapDraftUnsafeDestination
        readFile path `shouldReturn` "production sibling marker"
        let testPath = anchor </> ".test-data" </> "run" </> "config" </> "prodbox.dhall"
        publishBootstrapDraft testPath draft `shouldReturn` Left BootstrapDraftRootUnavailable
        scope <- either (fail . show) pure (deploymentScope anchor Test "run" 26443)
        prepareFreshScope scope (replicate 32 'b') `shouldReturn` FreshScopePrepared
        createDirectory (scopeRoot scope </> "config")
        publishBootstrapDraft testPath draft {draftRootGeneration = Text.replicate 32 "c"}
          `shouldReturn` Left BootstrapDraftRootUnavailable
        publishBootstrapDraft testPath draft `shouldReturn` Right ()
        generated <- readBootstrapProjection testPath
        fmap (scopeRoot . bootstrapScope) generated `shouldBe` Right (anchor </> ".test-data" </> "run")
        publishBootstrapDraft testPath draft
          `shouldReturn` Left (BootstrapDraftPublication SelectedDhallDestinationExists)
        let productionDraft = draft {draftEnvironment = "production"}
            productionPath = anchor </> ".data" </> "run" </> "config" </> "prodbox.dhall"
        publishBootstrapDraft testPath productionDraft `shouldReturn` Left BootstrapDraftUnsafeDestination
        publishBootstrapDraft productionPath productionDraft
          `shouldReturn` Left BootstrapDraftRootUnavailable
        prepareBootstrapRoot productionPath productionDraft `shouldReturn` Right FreshScopePrepared
        prepareBootstrapRoot productionPath productionDraft `shouldReturn` Right FreshScopeAlreadyExists
        publishBootstrapDraft productionPath productionDraft {draftRootGeneration = Text.replicate 32 "c"}
          `shouldReturn` Left BootstrapDraftRootUnavailable
        publishBootstrapDraft productionPath productionDraft `shouldReturn` Right ()
        production <- readBootstrapProjection productionPath
        fmap (scopeRoot . bootstrapScope) production `shouldBe` Right (anchor </> ".data" </> "run")
        readFile path `shouldReturn` "production sibling marker"
        readBootstrapProjection testPath `shouldReturn` generated

    it "decodes an explicit isolated bootstrap without application or cloud fields" $
      withSystemTempDirectory "prodbox-bootstrap-projection" $ \anchor -> do
        let path = anchor </> "selected.dhall"
        writeFile path (bootstrapDocument anchor "test" (replicate 32 'a') "26443" "28080")
        result <- readBootstrapProjection path
        fmap (scopeRoot . bootstrapScope) result `shouldBe` Right (anchor </> ".test-data" </> "run")
        fmap (scopeKindName . bootstrapScope) result `shouldBe` Right "prodbox-t-run"
        fmap bootstrapRootGeneration result `shouldBe` Right (fromStringGeneration (replicate 32 'a'))

    it "rejects invalid generation, port collisions, and imports" $
      withSystemTempDirectory "prodbox-bootstrap-refusal" $ \anchor -> do
        let path = anchor </> "selected.dhall"
        writeFile path (bootstrapDocument anchor "test" "bad" "26443" "28080")
        readBootstrapProjection path `shouldReturn` Left BootstrapInvalidGeneration
        writeFile path (bootstrapDocument anchor "test" (replicate 32 'a') "26443" "26443")
        readBootstrapProjection path `shouldReturn` Left (BootstrapInvalidKindPlan DuplicatePublicationPort)
        writeFile path "env:PRODBOX_BOOTSTRAP_MUST_NOT_BE_READ"
        result <- readBootstrapProjection path
        case result of
          Left (BootstrapSourceError _) -> pure ()
          other -> expectationFailure (show other)

    it "requires a valid retained artifact declaration in version 2" $
      withSystemTempDirectory "prodbox-bootstrap-artifact" $ \anchor -> do
        let path = anchor </> "selected.dhall"
            base = Text.pack (bootstrapDocument anchor "test" (replicate 32 'a') "26443" "28080")
            v2 = Text.replace "schema_version = 1" "schema_version = 2" base
            declaration =
              ", node_artifact = { path = \"artifacts/node.tar\", digest = \"sha256:"
                <> Text.replicate 64 "a"
                <> "\", maximum_bytes = 4096 }"
            withArtifact doc = Text.replace ", listen_address =" (declaration <> ", listen_address =") doc
        writeFile path (Text.unpack (withArtifact v2))
        result <- readBootstrapProjection path
        fmap bootstrapNodeArtifact result
          `shouldBe` Right (Just (ArtifactDeclaration "artifacts/node.tar" ("sha256:" ++ replicate 64 'a') 4096))
        writeFile path (Text.unpack v2)
        readBootstrapProjection path `shouldReturn` Left BootstrapInvalidArtifact
        writeFile path (Text.unpack (withArtifact base))
        readBootstrapProjection path `shouldReturn` Left BootstrapInvalidArtifact
        writeFile
          path
          (Text.unpack (Text.replace "artifacts/node.tar" "artifacts/../node.tar" (withArtifact v2)))
        readBootstrapProjection path `shouldReturn` Left BootstrapInvalidArtifact

    it "requires a distinct bounded kind executable in version 3" $
      withSystemTempDirectory "prodbox-bootstrap-kind-tool" $ \anchor -> do
        let path = anchor </> "selected.dhall"
            base = Text.pack (bootstrapDocument anchor "test" (replicate 32 'a') "26443" "28080")
            v3 = Text.replace "schema_version = 1" "schema_version = 3" base
            digest = "sha256:" <> Text.replicate 64 "a"
            fields =
              ", node_artifact = { path = \"artifacts/node.tar\", digest = \""
                <> digest
                <> "\", maximum_bytes = 4096 }, kind_tool = { path = \"artifacts/kind\", digest = \""
                <> digest
                <> "\", maximum_bytes = 1048576 }"
            document = Text.replace ", listen_address =" (fields <> ", listen_address =") v3
        writeFile path (Text.unpack document)
        result <- readBootstrapProjection path
        fmap bootstrapKindTool result
          `shouldBe` Right (Just (ArtifactDeclaration "artifacts/kind" (Text.unpack digest) 1048576))
        writeFile path (Text.unpack (Text.replace "artifacts/kind" "artifacts/node.tar" document))
        readBootstrapProjection path `shouldReturn` Left BootstrapInvalidKindTool
        writeFile
          path
          (Text.unpack (Text.replace "maximum_bytes = 1048576" "maximum_bytes = 134217729" document))
        readBootstrapProjection path `shouldReturn` Left BootstrapInvalidKindTool

  it "hashes only an owner-safe artifact under the selected root" $
    withSystemTempDirectory "prodbox-artifact-observation" $ \anchor -> do
      createDirectory (anchor </> ".test-data")
      case deploymentScope anchor Test "run" 26443 of
        Left failure -> expectationFailure (show failure)
        Right scope -> do
          let root = scopeRoot scope
              artifacts = root </> "artifacts"
              path = artifacts </> "node.tar"
              digest = "sha256:c7c5c1d70c5dec4416ab6158afd0b223ef40c29b1dc1f97ed9428b94d4cadb1c"
              inspect selected expected limit = observeScopeArtifact scope selected expected limit
          createDirectory root
          createDirectory artifacts
          inspect "artifacts/node.tar" digest 1024 `shouldReturn` Right ScopeArtifactMissing
          writeFile path "artifact"
          inspect "artifacts/node.tar" digest 1024 `shouldReturn` Right (ScopeArtifactDigestMatches 8)
          inspect "artifacts/node.tar" ("sha256:" ++ replicate 64 'a') 1024
            `shouldReturn` Right ScopeArtifactDigestMismatch
          inspect "artifacts/node.tar" digest 7 `shouldReturn` Right ScopeArtifactTooLarge
          inspect "artifacts/../node.tar" digest 1024 `shouldReturn` Right ScopeArtifactInvalidDeclaration
          inspect "artifacts/node.tar" ("sha256:" ++ replicate 64 'A') 1024
            `shouldReturn` Right ScopeArtifactInvalidDeclaration
          createLink path (artifacts </> "alias")
          inspect "artifacts/node.tar" digest 1024 `shouldReturn` Right ScopeArtifactUnsafe
          removeFile (artifacts </> "alias")
          setFileMode path 0o666
          inspect "artifacts/node.tar" digest 1024 `shouldReturn` Right ScopeArtifactUnsafe
          setFileMode path 0o600
          removeFile path
          writeFile (anchor </> "foreign") "unchanged"
          createSymbolicLink (anchor </> "foreign") path
          inspect "artifacts/node.tar" digest 1024 `shouldReturn` Right ScopeArtifactUnobservable
          readFile (anchor </> "foreign") `shouldReturn` "unchanged"

  it "holds verified artifact identity through the callback and reports replacement" $
    withSystemTempDirectory "prodbox-held-artifact" $ \anchor -> do
      createDirectory (anchor </> ".test-data")
      case deploymentScope anchor Test "run" 26443 of
        Left failure -> expectationFailure (show failure)
        Right scope -> do
          let root = scopeRoot scope
              directory = root </> "artifacts"
              path = directory </> "tool"
              digest = "sha256:c7c5c1d70c5dec4416ab6158afd0b223ef40c29b1dc1f97ed9428b94d4cadb1c"
          createDirectory root
          createDirectory directory
          writeFile path "artifact"
          called <- newIORef False
          refused <- withVerifiedScopeArtifact scope "artifacts/tool" ("sha256:" ++ replicate 64 'a') 1024 $ \_ _ -> writeIORef called True
          refused `shouldBe` Right (HeldArtifactRefused ScopeArtifactDigestMismatch)
          readIORef called `shouldReturn` False
          observed <- withVerifiedScopeArtifact scope "artifacts/tool" digest 1024 $ \_ recheck -> do
            recheck `shouldReturn` True
            removeFile path
            writeFile path "replacement"
            recheck `shouldReturn` False
            pure ("callback returned" :: String)
          observed `shouldBe` Right (HeldArtifactObserved "callback returned" False)

  describe "kind configuration plans" $ do
    it "reads only the private selected generation-bound kubeconfig" $
      withSystemTempDirectory "prodbox-kind-kubeconfig" $ \anchor -> do
        let generation = replicate 32 'a'
            selected = anchor </> "selected.dhall"
            document =
              unlines
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
            errorOf = either Just (const Nothing)
        writeFile selected (bootstrapDocument anchor "test" generation "26443" "28080")
        parsed <- readBootstrapProjection selected
        case parsed of
          Left failure -> expectationFailure (show failure)
          Right bootstrap -> do
            let scope = bootstrapScope bootstrap
                control = scopeRoot scope </> "control"
                path = control </> "kubeconfig"
                alias = anchor </> "hardlink"
                saved = control </> "saved"
            prepareFreshScope scope generation `shouldReturn` FreshScopePrepared
            createDirectory control
            setFileMode control 0o700
            writeFile path document
            setFileMode path 0o600
            result <- readKindKubeconfig bootstrap
            case result of
              Left failure -> expectationFailure (show failure)
              Right projection -> kindKubeconfigContext projection `shouldBe` "kind-prodbox-t-run"
            snapshotResult <- withKindKubeconfigSnapshot bootstrap $ \snapshotPath -> do
              (firstExit, before, _) <- readProcessWithExitCode "/usr/bin/cat" [snapshotPath] ""
              firstExit `shouldBe` ExitSuccess
              writeAttempt <- try (writeFile snapshotPath "tampered") :: IO (Either IOException ())
              isLeft writeAttempt `shouldBe` True
              renameFile path saved
              writeFile path "replacement"
              (secondExit, after, _) <- readProcessWithExitCode "/usr/bin/cat" [snapshotPath] ""
              secondExit `shouldBe` ExitSuccess
              after `shouldBe` before
              removeFile path
              renameFile saved path
              pure ()
            snapshotResult `shouldBe` Right ()
            setFileMode path 0o644
            fmap errorOf (readKindKubeconfig bootstrap) `shouldReturn` Just KindKubeconfigFileUnsafe
            setFileMode path 0o600
            setFileMode control 0o755
            fmap errorOf (readKindKubeconfig bootstrap) `shouldReturn` Just KindKubeconfigFileUnsafe
            setFileMode control 0o700
            createLink path alias
            fmap errorOf (readKindKubeconfig bootstrap) `shouldReturn` Just KindKubeconfigFileUnsafe
            removeFile alias
            renameFile path saved
            createSymbolicLink saved path
            fmap errorOf (readKindKubeconfig bootstrap) `shouldReturn` Just KindKubeconfigFileUnobservable
            removeFile path
            renameFile saved path
            writeFile path (replicate 524289 'x')
            fmap errorOf (readKindKubeconfig bootstrap) `shouldReturn` Just KindKubeconfigFileTooLarge
            writeFile selected (bootstrapDocument anchor "test" (replicate 32 'b') "26443" "28080")
            wrong <- readBootstrapProjection selected
            case wrong of
              Left failure -> expectationFailure (show failure)
              Right other -> fmap errorOf (readKindKubeconfig other) `shouldReturn` Just KindKubeconfigGenerationUnavailable

    it "observes only a generation-bound, owner-safe retained volume directory" $
      withSystemTempDirectory "prodbox-kind-volume" $ \anchor -> do
        scope <- either (fail . show) pure (deploymentScope anchor Test "run" 26443)
        let generation = replicate 32 'a'
            root = scopeRoot scope
            path = root </> "control" </> "volumes" </> generation </> "management" </> "worker" </> "state"
        prepareFreshScope scope generation `shouldReturn` FreshScopePrepared
        volume <- either (fail . show) pure (kindVolume scope generation "management" "worker" "state" 128)
        wrongGeneration <-
          either (fail . show) pure (kindVolume scope (replicate 32 'b') "management" "worker" "state" 128)
        observeKindVolumeDirectory volume `shouldReturn` KindVolumeDirectoryMissing
        observeKindVolumeDirectory wrongGeneration `shouldReturn` KindVolumeGenerationUnavailable
        createDirectoryIfMissing True path
        observeKindVolumeDirectory volume `shouldReturn` KindVolumeDirectoryPresent
        setFileMode path 0o777
        observeKindVolumeDirectory volume `shouldReturn` KindVolumeDirectoryUnsafe
        setFileMode path 0o700
        renameDirectory path (path ++ "-old")
        createSymbolicLink (path ++ "-old") path
        observeKindVolumeDirectory volume `shouldReturn` KindVolumeDirectoryUnobservable

    it "binds static volumes to the exact scope, generation and claim" $
      case (deploymentScope "/project" Test "run" 26443, deploymentScope "/project" Test "other" 26444) of
        (Right scope, Right other) -> do
          let generation = replicate 32 'a'
          case ( kindVolume scope generation "management" "worker" "state" 128
               , kindVolume other generation "management" "worker" "state" 128
               , kindVolume scope (replicate 32 'b') "management" "worker" "state" 128
               ) of
            (Right volume, Right otherVolume, Right nextGeneration) -> do
              kindVolumeName volume `shouldSatisfy` (/= kindVolumeName otherVolume)
              kindVolumeName volume `shouldSatisfy` (/= kindVolumeName nextGeneration)
              kindVolumeNodePath volume
                `shouldBe` ("/var/lib/prodbox/control/volumes/" ++ generation ++ "/management/worker/state")
              let name = kindVolumeName volume
                  modes = ["ReadWriteOnce" :: String]
              Aeson.eitherDecode (renderKindVolumeResources volume)
                `shouldBe` Right
                  ( Aeson.object
                      [ "apiVersion" Aeson..= ("v1" :: String)
                      , "kind" Aeson..= ("List" :: String)
                      , "items"
                          Aeson..= [ Aeson.object
                                       [ "apiVersion" Aeson..= ("v1" :: String)
                                       , "kind" Aeson..= ("PersistentVolume" :: String)
                                       , "metadata" Aeson..= Aeson.object ["name" Aeson..= name]
                                       , "spec"
                                           Aeson..= Aeson.object
                                             [ "capacity" Aeson..= Aeson.object ["storage" Aeson..= ("128Mi" :: String)]
                                             , "accessModes" Aeson..= modes
                                             , "volumeMode" Aeson..= ("Filesystem" :: String)
                                             , "persistentVolumeReclaimPolicy" Aeson..= ("Retain" :: String)
                                             , "storageClassName" Aeson..= ("" :: String)
                                             , "claimRef"
                                                 Aeson..= Aeson.object ["namespace" Aeson..= ("management" :: String), "name" Aeson..= name]
                                             , "hostPath"
                                                 Aeson..= Aeson.object ["path" Aeson..= kindVolumeNodePath volume, "type" Aeson..= ("Directory" :: String)]
                                             ]
                                       ]
                                   , Aeson.object
                                       [ "apiVersion" Aeson..= ("v1" :: String)
                                       , "kind" Aeson..= ("PersistentVolumeClaim" :: String)
                                       , "metadata"
                                           Aeson..= Aeson.object ["name" Aeson..= name, "namespace" Aeson..= ("management" :: String)]
                                       , "spec"
                                           Aeson..= Aeson.object
                                             [ "accessModes" Aeson..= modes
                                             , "volumeMode" Aeson..= ("Filesystem" :: String)
                                             , "storageClassName" Aeson..= ("" :: String)
                                             , "volumeName" Aeson..= name
                                             , "resources"
                                                 Aeson..= Aeson.object ["requests" Aeson..= Aeson.object ["storage" Aeson..= ("128Mi" :: String)]]
                                             ]
                                       ]
                                   ]
                      ]
                  )
            otherResult -> expectationFailure (show otherResult)
          kindVolume scope "bad" "management" "worker" "state" 128 `shouldBe` Left KindVolumeInvalidGeneration
          kindVolume scope generation "management" "../foreign" "state" 128
            `shouldBe` Left KindVolumeInvalidCoordinate
          kindVolume scope generation "management" "worker" "state" 0
            `shouldBe` Left KindVolumeInvalidCapacity
        other -> expectationFailure (show other)

    it "renders explicit loopback API, retained mount, pinned image and publication mappings" $
      case (deploymentScope "/project" Test "run" 26443, mkIpLiteral "127.0.0.1") of
        (Right scope, Right address) -> do
          let image = "kindest/node:v1.34.0@sha256:" ++ replicate 64 'a'
              http = PublicationMapping 28080 30080 address
              https = PublicationMapping 28443 30443 address
          case kindPlan scope image http https of
            Left failure -> expectationFailure (show failure)
            Right plan ->
              Aeson.eitherDecode (renderKindConfig plan)
                `shouldBe` Right
                  ( Aeson.object
                      [ "kind" Aeson..= ("Cluster" :: String)
                      , "apiVersion" Aeson..= ("kind.x-k8s.io/v1alpha4" :: String)
                      , "name" Aeson..= ("prodbox-t-run" :: String)
                      , "networking"
                          Aeson..= Aeson.object
                            [ "apiServerAddress" Aeson..= ("127.0.0.1" :: String)
                            , "apiServerPort" Aeson..= (26443 :: Int)
                            ]
                      , "nodes"
                          Aeson..= [ Aeson.object
                                       [ "role" Aeson..= ("control-plane" :: String)
                                       , "image" Aeson..= image
                                       , "extraMounts"
                                           Aeson..= [ Aeson.object
                                                        [ "hostPath" Aeson..= ("/project/.test-data/run" :: String)
                                                        , "containerPath" Aeson..= ("/var/lib/prodbox" :: String)
                                                        ]
                                                    ]
                                       , "extraPortMappings" Aeson..= [mapping 28080 30080, mapping 28443 30443]
                                       ]
                                   ]
                      ]
                  )
        other -> expectationFailure (show other)

  describe "control container observations" $ do
    it "requires repeated matching daemon IDs and socket identities" $ do
      let socket = DockerSocketIdentity 1 2 1000 49645
          other = DockerSocketIdentity 1 3 1000 49645
          identifier = "c20f7230-59a2-4824-a2f4-fda71c982ee6"
      parseDockerDaemonId (show identifier) `shouldBe` Just identifier
      parseDockerDaemonId "\"bad value\"" `shouldBe` Nothing
      parseDockerDaemonId "{}" `shouldBe` Nothing
      classifyDockerDaemon (Just socket) (Just identifier) (Just socket) (Just identifier) (Just socket)
        `shouldBe` DockerDaemonObserved identifier socket
      classifyDockerDaemon (Just socket) (Just identifier) (Just other) (Just identifier) (Just socket)
        `shouldBe` DockerDaemonChanged
      classifyDockerDaemon (Just socket) (Just identifier) (Just socket) (Just "different") (Just socket)
        `shouldBe` DockerDaemonChanged
      classifyDockerDaemon (Just socket) (Just "") (Just socket) (Just "") (Just socket)
        `shouldBe` DockerDaemonUnobservable
      classifyDockerDaemon Nothing (Just identifier) (Just socket) (Just identifier) (Just socket)
        `shouldBe` DockerDaemonUnobservable

    it "observes an exact untagged image ID without inferring absence" $ do
      let identifier = "sha256:" ++ replicate 64 'a'
          other = "sha256:" ++ replicate 64 'b'
          image imageId tags =
            Aeson.object
              [ "Id" Aeson..= imageId
              , "RepoTags" Aeson..= tags
              , "Os" Aeson..= ("linux" :: String)
              , "Architecture" Aeson..= ("amd64" :: String)
              ]
      parseImageIdObservation identifier (image identifier (Nothing :: Maybe [String]))
        `shouldBe` Right (ImageIdObserved "linux" "amd64" 0)
      parseImageIdObservation identifier (image identifier (Just ["private:tag"] :: Maybe [String]))
        `shouldBe` Right (ImageIdObserved "linux" "amd64" 1)
      parseImageIdObservation identifier (image other (Nothing :: Maybe [String])) `shouldSatisfy` isLeft
      parseImageIdObservation "sha256:short" (image identifier (Nothing :: Maybe [String]))
        `shouldSatisfy` isLeft
      parseImageIdObservation identifier (Aeson.object ["Id" Aeson..= identifier]) `shouldSatisfy` isLeft

    it "observes daemon image metadata without equating it to the retained archive" $ do
      let reference = "kindest/node@sha256:" ++ replicate 64 'a'
          identifier = "sha256:" ++ replicate 64 'b'
          fixture digest =
            Aeson.object
              [ "Id" Aeson..= identifier
              , "RepoDigests" Aeson..= ["docker.io/kindest/node@sha256:" ++ replicate 64 digest]
              , "Os" Aeson..= ("linux" :: String)
              , "Architecture" Aeson..= ("amd64" :: String)
              ]
      parseImageObservation reference (fixture 'a')
        `shouldBe` Right (ImageObserved True identifier "linux" "amd64")
      parseImageObservation reference (fixture 'c')
        `shouldBe` Right (ImageObserved False identifier "linux" "amd64")
      parseImageObservation reference (Aeson.object ["Id" Aeson..= identifier]) `shouldSatisfy` isLeft

    it "compares daemon metadata with the verified config and platform" $ do
      let selected = "sha256:" ++ replicate 64 'a'
          manifest = "sha256:" ++ replicate 64 'd'
          identifier = "sha256:" ++ replicate 64 'b'
          other = "sha256:" ++ replicate 64 'c'
          compareObserved = compareImageArchive selected manifest identifier "amd64"
      compareObserved ImageUnobservable `shouldBe` ImageArchiveUnobservable
      compareObserved (ImageObserved True identifier "linux" "amd64") `shouldBe` ImageArchiveConfigMatches
      compareObserved (ImageObserved True selected "linux" "amd64")
        `shouldBe` ImageArchiveDescriptorMatches
      compareObserved (ImageObserved True manifest "linux" "amd64")
        `shouldBe` ImageArchiveDescriptorMatches
      forM_
        [ ImageObserved False identifier "linux" "amd64"
        , ImageObserved True other "linux" "amd64"
        , ImageObserved True identifier "linux" "arm64"
        , ImageObserved True identifier "windows" "amd64"
        ]
        $ \observed -> compareObserved observed `shouldBe` ImageArchiveMetadataDiffers

    it "reports inventory changes and foreign names instead of inferring absence" $ do
      let first = replicate 64 'a'
          second = replicate 64 'b'
      chooseRuntimeCandidate [] [] [] [] `shouldBe` InventoryNoMatches
      chooseRuntimeCandidate [] [] [first] [first] `shouldBe` InventoryChanged
      chooseRuntimeCandidate [first] [] [first] [] `shouldBe` InventoryForeignOrMultiple
      chooseRuntimeCandidate [first] [second] [first] [second] `shouldBe` InventoryForeignOrMultiple
      chooseRuntimeCandidate [first] [first] [first] [first] `shouldBe` InventoryCandidate first

    it "rechecks both inventories after inspecting a candidate" $ do
      let identifier = replicate 64 'a'
          replacement = replicate 64 'b'
          matching = Right [identifier]
          inspect current = pure $ Right (RuntimeNodeObserved (current == identifier) True)
          runScenario responses = do
            pending <- newIORef responses
            let readInventory _ = do
                  remaining <- readIORef pending
                  case remaining of
                    [] -> pure (Left ControlRuntimeResponseInvalid)
                    response : rest -> writeIORef pending rest >> pure response
            observeRuntimeInventory readInventory inspect "label" "name"
      runScenario (replicate 6 matching)
        `shouldReturn` Right (RuntimeNodeObserved True True)
      runScenario (replicate 4 matching ++ [Right [replacement], Right [replacement]])
        `shouldReturn` Right RuntimeInventoryChanged
      runScenario (replicate 4 matching ++ [Right [replacement], matching])
        `shouldReturn` Right RuntimeInventoryChanged
      runScenario (replicate 4 matching ++ [matching, Right [replacement]])
        `shouldReturn` Right RuntimeInventoryChanged
      runScenario (replicate 4 matching ++ [Right [], Right []])
        `shouldReturn` Right RuntimeInventoryChanged
      runScenario (replicate 4 matching ++ [Left ControlRuntimeCommandFailed])
        `shouldReturn` Left ControlRuntimeCommandFailed

    it "checks the exact container identity, label, and retained mount" $ do
      let name = "prodbox-t-run"
          identifier = replicate 64 'a'
          root = "/project/.test-data/run"
          fixture :: String -> FilePath -> Maybe Bool -> Aeson.Value
          fixture label source writable =
            Aeson.object
              [ "Id" Aeson..= identifier
              , "Name" Aeson..= ("/" ++ name ++ "-control-plane")
              , "Config"
                  Aeson..= Aeson.object
                    [ "Labels"
                        Aeson..= Aeson.object
                          [ "io.x-k8s.kind.cluster" Aeson..= label
                          , "io.x-k8s.kind.role" Aeson..= ("control-plane" :: String)
                          ]
                    ]
              , "State" Aeson..= Aeson.object ["Running" Aeson..= True]
              , "Mounts"
                  Aeson..= [ Aeson.object
                               ( [ "Source" Aeson..= source
                                 , "Destination" Aeson..= ("/var/lib/prodbox" :: String)
                                 , "Type" Aeson..= ("bind" :: String)
                                 ]
                                   ++ maybe [] (\value -> ["RW" Aeson..= value]) writable
                               )
                           ]
              ]
      parseNodeObservation name root identifier (fixture name root (Just True))
        `shouldBe` Right (RuntimeNodeObserved True True)
      parseNodeObservation name root identifier (fixture name "/foreign" (Just True))
        `shouldBe` Right (RuntimeNodeObserved True False)
      parseNodeObservation name root identifier (fixture name root (Just False))
        `shouldBe` Right (RuntimeNodeObserved True False)
      parseNodeObservation name root identifier (fixture "foreign" root (Just True))
        `shouldBe` Right RuntimeForeignOrMultiple
      parseNodeObservation name root identifier (fixture name root Nothing) `shouldSatisfy` isLeft
      let withoutMounts = case fixture name root (Just True) of
            Aeson.Object object -> Aeson.Object (KeyMap.delete "Mounts" object)
            other -> other
      parseNodeObservation name root identifier withoutMounts `shouldSatisfy` isLeft

  describe "kind image and publication validation" $ do
    it "matches the observed pinned kind node request only for its planned scope" $
      case (deploymentScope "/project" Test "run" 26443, mkIpLiteral "127.0.0.1", mkIpLiteral "::1") of
        (Right scope, Right ipv4, Right ipv6) -> do
          let image = "sha256:" ++ replicate 64 'a'
              tool = "sha256:50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54"
              http = PublicationMapping 28080 30080 ipv4
              https = PublicationMapping 28443 30443 ipv6
              request =
                [ "run"
                , "--name"
                , "prodbox-t-run-control-plane"
                , "--hostname"
                , "prodbox-t-run-control-plane"
                , "--label"
                , "io.x-k8s.kind.role=control-plane"
                , "--privileged"
                , "--security-opt"
                , "seccomp=unconfined"
                , "--security-opt"
                , "apparmor=unconfined"
                , "--tmpfs"
                , "/tmp"
                , "--tmpfs"
                , "/run"
                , "--volume"
                , "/var"
                , "--volume"
                , "/lib/modules:/lib/modules:ro"
                , "-e"
                , "KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER"
                , "--detach"
                , "--tty"
                , "--label"
                , "io.x-k8s.kind.cluster=prodbox-t-run"
                , "--net"
                , "prodbox-t-run"
                , "--restart=on-failure:1"
                , "--init=false"
                , "--cgroupns=private"
                , "--volume=/project/.test-data/run:/var/lib/prodbox"
                , "--publish=127.0.0.1:28080:30080/TCP"
                , "--publish=[::1]:28443:30443/TCP"
                , "--publish=127.0.0.1:26443:6443/TCP"
                , "-e"
                , "KUBECONFIG=/etc/kubernetes/admin.conf"
                , image
                ]
          case kindPlan scope ("kindest/node@" ++ image) http https of
            Left failure -> expectationFailure (show failure)
            Right plan -> do
              matchesObservedKindNodeRun plan tool image request `shouldBe` True
              matchesObservedKindNodeRun plan ("sha256:" ++ replicate 64 'b') image request `shouldBe` False
              matchesObservedKindNodeRun plan tool ("sha256:" ++ replicate 64 'b') request `shouldBe` False
              matchesObservedKindNodeRun
                plan
                tool
                image
                (map (\argument -> if argument == "--net" then "--network=host" else argument) request)
                `shouldBe` False
              matchesObservedKindNodeRun
                plan
                tool
                image
                ( map
                    ( \argument ->
                        if argument == "--volume=/project/.test-data/run:/var/lib/prodbox"
                          then "--volume=/foreign:/var/lib/prodbox"
                          else argument
                    )
                    request
                )
                `shouldBe` False
              matchesObservedKindNodeRun plan tool image (request ++ ["--privileged"]) `shouldBe` False
              let createInput = KindNodeCreateInput tool image (replicate 64 'b') (replicate 32 'c') (replicate 32 'd') request
                  volume = "prodbox-t-run-var-" ++ replicate 32 'c' ++ "-" ++ replicate 32 'd'
              kindNodeVarVolumeName plan (replicate 32 'c') (replicate 32 'd') `shouldBe` Just volume
              kindNodeVarVolumeName plan (replicate 32 'e') (replicate 32 'd') `shouldNotBe` Just volume
              kindNodeVarVolumeName plan "invalid" (replicate 32 'd') `shouldBe` Nothing
              case kindNodeVarVolumeCreateBody plan (replicate 32 'c') (replicate 32 'd') of
                Just (Aeson.Object proposal) -> do
                  KeyMap.lookup "Name" proposal `shouldBe` Just (Aeson.toJSON volume)
                  KeyMap.lookup "Driver" proposal `shouldBe` Just (Aeson.toJSON ("local" :: String))
                  KeyMap.lookup "DriverOpts" proposal `shouldBe` Just (Aeson.object [])
                other -> expectationFailure (show other)
              kindNodeVarVolumeCreateBody plan "invalid" (replicate 32 'd') `shouldBe` Nothing
              kindNodeVarVolumeCreateBody plan (replicate 32 'c') "invalid" `shouldBe` Nothing
              case kindNodeCreateBody plan createInput of
                Just (Aeson.Object body) -> do
                  KeyMap.lookup "Image" body `shouldBe` Just (Aeson.toJSON image)
                  KeyMap.lookup "Volumes" body `shouldBe` Just (Aeson.object [])
                  KeyMap.lookup "Env" body
                    `shouldBe` Just
                      ( Aeson.toJSON
                          (["KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER", "KUBECONFIG=/etc/kubernetes/admin.conf"] :: [String])
                      )
                  case KeyMap.lookup "HostConfig" body of
                    Just (Aeson.Object hostConfig) -> do
                      KeyMap.lookup "NetworkMode" hostConfig `shouldBe` Just (Aeson.toJSON (replicate 64 'b'))
                      KeyMap.lookup "Privileged" hostConfig `shouldBe` Just (Aeson.Bool True)
                      KeyMap.lookup "Devices" hostConfig `shouldBe` Nothing
                      KeyMap.lookup "Binds" hostConfig
                        `shouldBe` Just
                          ( Aeson.toJSON
                              ( [volume ++ ":/var", "/lib/modules:/lib/modules:ro", "/project/.test-data/run:/var/lib/prodbox"]
                                  :: [String]
                              )
                          )
                    other -> expectationFailure (show other)
                other -> expectationFailure (show other)
              kindNodeCreateBody plan (createInput {nodeCreateNetworkId = "foreign"}) `shouldBe` Nothing
              kindNodeCreateBody plan (createInput {nodeCreateOperation = "invalid"}) `shouldBe` Nothing
              kindNodeCreateBody plan (createInput {nodeCreateArguments = request ++ ["--privileged"]})
                `shouldBe` Nothing
              let (common, mounts) = break (== "--volume=/project/.test-data/run:/var/lib/prodbox") request
                  rootless = kindNodeRunArgumentsFor KindNodeRootless plan image
                  rootlessInput = createInput {nodeCreateArguments = rootless}
              rootless `shouldBe` (common ++ ["--device", "/dev/fuse"] ++ mounts)
              kindNodeCreateMode plan rootlessInput `shouldBe` Just KindNodeRootless
              case kindNodeCreateBody plan rootlessInput of
                Just (Aeson.Object body) -> case KeyMap.lookup "HostConfig" body of
                  Just (Aeson.Object hostConfig) ->
                    KeyMap.lookup "Devices" hostConfig
                      `shouldBe` Just
                        ( Aeson.toJSON
                            [ Aeson.object
                                [ "PathOnHost" Aeson..= ("/dev/fuse" :: String)
                                , "PathInContainer" Aeson..= ("/dev/fuse" :: String)
                                , "CgroupPermissions" Aeson..= ("rwm" :: String)
                                ]
                            ]
                        )
                  other -> expectationFailure (show other)
                other -> expectationFailure (show other)
              kindNodeCreateBody
                plan
                ( rootlessInput
                    { nodeCreateArguments = map (\arg -> if arg == "/dev/fuse" then "/dev/kvm" else arg) rootless
                    }
                )
                `shouldBe` Nothing
        other -> expectationFailure (show other)
    it "refuses mutable or malformed images and colliding publication ports" $
      case (deploymentScope "/project" Test "run" 26443, mkIpLiteral "127.0.0.1") of
        (Right scope, Right address) -> do
          let digest = replicate 64 'a'
              http = PublicationMapping 28080 30080 address
              https = PublicationMapping 28443 30443 address
              invalidImages =
                [ "kindest/node:v1.34.0"
                , "kindest/node:v1.34.0@sha256:" ++ replicate 64 'A'
                , "kindest//node:v1@sha256:" ++ digest
                , "kindest/node:v1@sha256:" ++ digest ++ "@extra"
                , "kindest/node:v1 bad@sha256:" ++ digest
                , "registry.example:999999999999/team/node@sha256:" ++ digest
                , "999.999.999.999/team/node@sha256:" ++ digest
                , "[127.0.0.1]:5000/team/node@sha256:" ++ digest
                ]
          mapM_ (\image -> kindPlan scope image http https `shouldBe` Left InvalidNodeImage) invalidImages
          kindPlan scope ("[::1]:5000/team/node@sha256:" ++ digest) http https `shouldSatisfy` isRight
          kindPlan scope ("Registry.Example:5000/team/node@sha256:" ++ digest) http https
            `shouldSatisfy` isRight
          kindPlan scope ("kindest/node@sha256:" ++ digest) http (PublicationMapping 26443 30443 address)
            `shouldBe` Left DuplicatePublicationPort
          kindPlan scope ("kindest/node@sha256:" ++ digest) http (PublicationMapping 28443 30080 address)
            `shouldBe` Left DuplicatePublicationPort
          kindPlan scope ("kindest/node@sha256:" ++ digest) http (PublicationMapping 0 30443 address)
            `shouldBe` Left InvalidPublicationPort
          mapM_
            ( \nodePort ->
                kindPlan scope ("kindest/node@sha256:" ++ digest) http (PublicationMapping 28443 nodePort address)
                  `shouldBe` Left InvalidPublicationNodePort
            )
            [29999, 32768]
          kindPlan
            scope
            ("kindest/node@sha256:" ++ digest)
            (PublicationMapping 28080 30000 address)
            (PublicationMapping 28443 32767 address)
            `shouldSatisfy` isRight
        other -> expectationFailure (show other)

    it "rejects a publication port that collides across environments" $
      case ( deploymentScope "/project" Production "prod" 26443
           , deploymentScope "/project" Test "run" 26444
           , mkIpLiteral "127.0.0.1"
           ) of
        (Right production, Right testing, Right address) -> do
          let image = "kindest/node@sha256:" ++ replicate 64 'a'
              prodHttp = PublicationMapping 28080 30080 address
              prodHttps = PublicationMapping 28443 30443 address
              testHttp = PublicationMapping 29080 30080 address
              testHttps = PublicationMapping 28080 30443 address
          case (kindPlan production image prodHttp prodHttps, kindPlan testing image testHttp testHttps) of
            (Right prodPlan, Right testPlan) -> requireDisjointKindPlans prodPlan testPlan `shouldBe` Left OverlappingKindHostPort
            other -> expectationFailure (show other)
        other -> expectationFailure (show other)
 where
  fromStringGeneration = Text.pack
  bootstrapDocument anchor environment generation api http =
    "{ bootstrap = { schema_version = 1, project_anchor = \""
      ++ anchor
      ++ "\", runtime_socket = \"/var/run/docker.sock\", environment = \""
      ++ environment
      ++ "\", deployment_id = \"run\", root_generation = \""
      ++ generation
      ++ "\", api_port = "
      ++ api
      ++ ", node_image = \"kindest/node@sha256:"
      ++ replicate 64 'a'
      ++ "\", http_host_port = "
      ++ http
      ++ ", http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, listen_address = \"127.0.0.1\" } }"
  mapping host node =
    Aeson.object
      [ "hostPort" Aeson..= (host :: Int)
      , "containerPort" Aeson..= (node :: Int)
      , "listenAddress" Aeson..= ("127.0.0.1" :: String)
      , "protocol" Aeson..= ("TCP" :: String)
      ]
