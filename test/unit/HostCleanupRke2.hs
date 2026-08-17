{-# LANGUAGE OverloadedStrings #-}

module HostCleanupRke2
  ( hostCleanupRke2Suite
  )
where

import Control.Exception (SomeException, bracket, try)
import Control.Monad (forM_)
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.List (isInfixOf, nub)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.CleanupRun
  ( CleanupOperationId
  , cleanupOperationIdText
  , mkCleanupOperationId
  )
import Prodbox.Lifecycle.HostCleanupRke2
import Prodbox.Lifecycle.HostCleanupRunner (HostCleanupEffectOutcome (..))
import Prodbox.Lifecycle.Teardown.Observation (AbsenceEvidence (..))
import Prodbox.Subprocess (ProcessOutput (..), Subprocess (..))
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import TestSupport

hostCleanupRke2Suite :: SuiteBuilder ()
hostCleanupRke2Suite =
  describe "lifecycle-owned local RKE2 terminal adapter" $ do
    it "defines one closed, unique install-marker universe" $ do
      canonicalLocalRke2InstallMarkers
        `shouldBe` [minBound .. maxBound]
      length (nub (map localRke2InstallMarkerPath canonicalLocalRke2InstallMarkers))
        `shouldBe` length canonicalLocalRke2InstallMarkers
      localRke2InstallMarkerPath LocalRke2UninstallScriptMarker
        `shouldBe` "/usr/local/bin/rke2-uninstall.sh"
      localRke2InstallMarkerPath LocalRke2DataDirectoryMarker
        `shouldBe` "/var/lib/rancher/rke2"

    it "requires a fresh absent answer from every canonical marker" $ do
      observedMarkers <- newIORef []
      let adapter =
            adapterWith
              ( \marker -> do
                  modifyIORef' observedMarkers (++ [marker])
                  pure LocalRke2MarkerAbsent
              )
              unexpectedCommand
      observeLocalRke2Install adapter
        `shouldReturn` LocalRke2InstallAbsent exactAbsence
      readIORef observedMarkers
        `shouldReturn` canonicalLocalRke2InstallMarkers

      forM_ canonicalLocalRke2InstallMarkers $ \soleSurvivor -> do
        observation <-
          observeLocalRke2Install
            ( adapterWith
                ( \marker ->
                    pure
                      ( if marker == soleSurvivor
                          then LocalRke2MarkerPresent
                          else LocalRke2MarkerAbsent
                      )
                )
                unexpectedCommand
            )
        observation
          `shouldBe` LocalRke2InstallPresent (soleSurvivor NonEmpty.:| []) []

    it "treats stopped or damaged control-plane state as installed, never absent" $ do
      commandCount <- newIORef (0 :: Int)
      let adapter =
            adapterWith
              ( markerAnswer
                  [ (LocalRke2DataDirectoryMarker, LocalRke2MarkerPresent)
                  ,
                    ( LocalRke2SystemdUnitMarker
                    , LocalRke2MarkerUnconfirmed "systemd is not serving"
                    )
                  ]
              )
              (\_ _ -> modifyIORef' commandCount (+ 1) >> pure successfulCommand)
      observeLocalRke2Install adapter
        `shouldReturn` LocalRke2InstallPresent
          (LocalRke2DataDirectoryMarker NonEmpty.:| [])
          [ LocalRke2MarkerFailure
              LocalRke2SystemdUnitMarker
              "systemd is not serving"
          ]
      readIORef commandCount `shouldReturn` 0

    it "keeps marker I/O failure typed and cannot mint absence from it" $ do
      let adapter =
            adapterWith
              ( markerAnswer
                  [
                    ( LocalRke2ConfigDirectoryMarker
                    , LocalRke2MarkerUnconfirmed "permission denied"
                    )
                  ]
              )
              unexpectedCommand
      observeLocalRke2Install adapter
        `shouldReturn` LocalRke2InstallUnconfirmed
          ( LocalRke2MarkerFailure
              LocalRke2ConfigDirectoryMarker
              "permission denied"
              NonEmpty.:| []
          )

    it "refuses an installed-damaged host whose uninstall script marker is absent" $ do
      commandCount <- newIORef (0 :: Int)
      let adapter =
            adapterWith
              ( markerAnswer
                  [(LocalRke2DataDirectoryMarker, LocalRke2MarkerPresent)]
              )
              (\_ _ -> modifyIORef' commandCount (+ 1) >> pure successfulCommand)
      attemptLocalRke2Uninstall adapter fixtureOperation
        `shouldReturn` LocalRke2UninstallRefused
          fixtureOperation
          ( LocalRke2UninstallInstalledDamaged
              (LocalRke2DataDirectoryMarker NonEmpty.:| [])
          )
      readIORef commandCount `shouldReturn` 0

    it "refuses an unconfirmed uninstall-script marker before mutation" $ do
      commandCount <- newIORef (0 :: Int)
      let scriptFailure =
            LocalRke2MarkerFailure
              LocalRke2UninstallScriptMarker
              "lstat interrupted"
          adapter =
            adapterWith
              ( markerAnswer
                  [ (LocalRke2DataDirectoryMarker, LocalRke2MarkerPresent)
                  ,
                    ( LocalRke2UninstallScriptMarker
                    , LocalRke2MarkerUnconfirmed "lstat interrupted"
                    )
                  ]
              )
              (\_ _ -> modifyIORef' commandCount (+ 1) >> pure successfulCommand)
      result <- attemptLocalRke2Uninstall adapter fixtureOperation
      case result of
        LocalRke2UninstallRefused
          operation
          (LocalRke2UninstallObservationUnconfirmed failures) -> do
            operation `shouldBe` fixtureOperation
            NonEmpty.toList failures `shouldContain` [scriptFailure]
        other -> expectationFailure ("unexpected result: " ++ show other)
      readIORef commandCount `shouldReturn` 0

    it "ignores hostile ambient KUBECONFIG and runs only the fixed local uninstaller" $ do
      captured <- newIORef Nothing
      let adapter =
            adapterWith
              ( markerAnswer
                  [ (LocalRke2UninstallScriptMarker, LocalRke2MarkerPresent)
                  ]
              )
              ( \operation spec -> do
                  writeIORef captured (Just (operation, spec))
                  pure successfulCommand
              )
      withEnvironmentVariable
        "KUBECONFIG"
        "/tmp/hostile-remote-admin-kubeconfig"
        ( attemptLocalRke2Uninstall adapter fixtureOperation
            `shouldReturn` LocalRke2UninstallApplied fixtureOperation
        )
      invocation <- readIORef captured
      case invocation of
        Nothing -> expectationFailure "uninstaller was not invoked"
        Just (operation, spec) -> do
          operation `shouldBe` fixtureOperation
          subprocessPath spec `shouldBe` "/usr/bin/sudo"
          subprocessEnvironment spec
            `shouldBe` Just
              [ ("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
              , ("LC_ALL", "C")
              ]
          subprocessWorkingDirectory spec `shouldBe` Just fixtureWorkingDirectory
          subprocessArguments spec
            `shouldContain` ["KUBECONFIG=/etc/rancher/rke2/rke2.yaml"]
          subprocessArguments spec
            `shouldContain` [ "PRODBOX_CLEANUP_OPERATION_ID="
                                ++ Text.unpack (cleanupOperationIdText fixtureOperation)
                            ]
          subprocessArguments spec
            `shouldSatisfy` all (not . isInfixOf "hostile-remote")
          unwords (subprocessPath spec : subprocessArguments spec)
            `shouldNotContain` "kubectl"

    it "keeps a non-zero uninstaller result typed until read-back" $ do
      let adapter =
            adapterWith
              ( markerAnswer
                  [ (LocalRke2UninstallScriptMarker, LocalRke2MarkerPresent)
                  ]
              )
              ( \_ _ ->
                  pure
                    ( Right
                        ProcessOutput
                          { processExitCode = ExitFailure 23
                          , processStdout = "partial cleanup"
                          , processStderr = "unit remained"
                          }
                    )
              )
      attemptLocalRke2Uninstall adapter fixtureOperation
        `shouldReturn` LocalRke2UninstallRefused
          fixtureOperation
          ( LocalRke2UninstallCommandFailed
              (ExitFailure 23)
              "unit remained partial cleanup"
          )
      observeLocalRke2Install adapter
        `shouldReturn` LocalRke2InstallPresent
          (LocalRke2UninstallScriptMarker NonEmpty.:| [])
          []

    it "resolves a lost mutation response only through exact absence read-back" $ do
      markerState <- newIORef allPresent
      commandCount <- newIORef (0 :: Int)
      let adapter =
            adapterWith
              (\marker -> answerFromState markerState marker)
              ( \_ _ -> do
                  modifyIORef' commandCount (+ 1)
                  writeIORef markerState allAbsent
                  pure (Left "transport closed after process start")
              )
      attemptLocalRke2Uninstall adapter fixtureOperation
        `shouldReturn` LocalRke2UninstallResponseLost
          fixtureOperation
          "transport closed after process start"
      observeLocalRke2Install adapter
        `shouldReturn` LocalRke2InstallAbsent exactAbsence
      attemptLocalRke2Uninstall adapter fixtureOperation
        `shouldReturn` LocalRke2UninstallAlreadyAbsent fixtureOperation exactAbsence
      readIORef commandCount `shouldReturn` 1
      localRke2UninstallResultToHostEffect
        ( LocalRke2UninstallResponseLost
            fixtureOperation
            "transport closed after process start"
        )
        `shouldBe` HostCleanupEffectResponseLost
          "transport closed after process start"

    it "survives interruption after apply and never repeats a confirmed uninstall" $ do
      markerState <- newIORef allPresent
      commandCount <- newIORef (0 :: Int)
      let adapter =
            adapterWith
              (\marker -> answerFromState markerState marker)
              ( \_ _ -> do
                  modifyIORef' commandCount (+ 1)
                  writeIORef markerState allAbsent
                  ioError (userError "interrupted after local uninstall")
              )
      interrupted <-
        try (attemptLocalRke2Uninstall adapter fixtureOperation)
          :: IO (Either SomeException LocalRke2UninstallResult)
      interrupted `shouldSatisfy` isLeft
      observeLocalRke2Install adapter
        `shouldReturn` LocalRke2InstallAbsent exactAbsence
      attemptLocalRke2Uninstall adapter fixtureOperation
        `shouldReturn` LocalRke2UninstallAlreadyAbsent fixtureOperation exactAbsence
      readIORef commandCount `shouldReturn` 1

    it "withholds absence when response loss is followed by an unconfirmed read-back" $ do
      markerState <- newIORef allPresent
      let adapter =
            adapterWith
              (\marker -> answerFromState markerState marker)
              ( \_ _ -> do
                  writeIORef
                    markerState
                    ( replaceMarker
                        LocalRke2ConfigDirectoryMarker
                        (LocalRke2MarkerUnconfirmed "read-back permission denied")
                        allAbsent
                    )
                  pure (Left "response lost")
              )
      attemptLocalRke2Uninstall adapter fixtureOperation
        `shouldReturn` LocalRke2UninstallResponseLost fixtureOperation "response lost"
      observeLocalRke2Install adapter
        `shouldReturn` LocalRke2InstallUnconfirmed
          ( LocalRke2MarkerFailure
              LocalRke2ConfigDirectoryMarker
              "read-back permission denied"
              NonEmpty.:| []
          )

adapterWith
  :: (LocalRke2InstallMarker -> IO LocalRke2MarkerObservation)
  -> ( CleanupOperationId
       -> Subprocess
       -> IO (Either Text ProcessOutput)
     )
  -> LocalRke2TerminalAdapter IO
adapterWith observeMarker runCommand =
  mkLocalRke2TerminalAdapter
    fixtureWorkingDirectory
    LocalRke2TerminalBoundary
      { localRke2ObserveInstallMarker = observeMarker
      , localRke2ExecuteUninstallCommand = runCommand
      }

markerAnswer
  :: [(LocalRke2InstallMarker, LocalRke2MarkerObservation)]
  -> LocalRke2InstallMarker
  -> IO LocalRke2MarkerObservation
markerAnswer overrides marker =
  pure (maybe LocalRke2MarkerAbsent id (lookup marker overrides))

answerFromState
  :: IORef [(LocalRke2InstallMarker, LocalRke2MarkerObservation)]
  -> LocalRke2InstallMarker
  -> IO LocalRke2MarkerObservation
answerFromState stateRef marker = do
  state <- readIORef stateRef
  pure
    ( maybe
        (LocalRke2MarkerUnconfirmed "fake omitted canonical marker")
        id
        (lookup marker state)
    )

replaceMarker
  :: LocalRke2InstallMarker
  -> LocalRke2MarkerObservation
  -> [(LocalRke2InstallMarker, LocalRke2MarkerObservation)]
  -> [(LocalRke2InstallMarker, LocalRke2MarkerObservation)]
replaceMarker selected replacement =
  map
    ( \(marker, observation) ->
        if marker == selected
          then (marker, replacement)
          else (marker, observation)
    )

allPresent, allAbsent :: [(LocalRke2InstallMarker, LocalRke2MarkerObservation)]
allPresent =
  [(marker, LocalRke2MarkerPresent) | marker <- canonicalLocalRke2InstallMarkers]
allAbsent =
  [(marker, LocalRke2MarkerAbsent) | marker <- canonicalLocalRke2InstallMarkers]

unexpectedCommand
  :: CleanupOperationId
  -> Subprocess
  -> IO (Either Text ProcessOutput)
unexpectedCommand _ _ = do
  expectationFailure "unexpected uninstall command"
  pure (Left "unexpected uninstall command")

successfulCommand :: Either Text ProcessOutput
successfulCommand =
  Right
    ProcessOutput
      { processExitCode = ExitSuccess
      , processStdout = ""
      , processStderr = ""
      }

fixtureOperation :: CleanupOperationId
fixtureOperation =
  case mkCleanupOperationId "cleanup-run/host-rke2/uninstall-local" of
    Left err -> error (Text.unpack err)
    Right operation -> operation

fixtureWorkingDirectory :: FilePath
fixtureWorkingDirectory = "/tmp/prodbox-host-cleanup-rke2"

exactAbsence :: AbsenceEvidence
exactAbsence =
  AbsenceEvidence
    "local-rke2-install/v1: every canonical no-follow install marker was observed absent"

withEnvironmentVariable :: String -> String -> IO value -> IO value
withEnvironmentVariable key value action =
  bracket
    ( do
        original <- lookupEnv key
        setEnv key value
        pure original
    )
    (\original -> maybe (unsetEnv key) (setEnv key) original)
    (const action)

isLeft :: Either left right -> Bool
isLeft value = case value of
  Left _ -> True
  Right _ -> False
