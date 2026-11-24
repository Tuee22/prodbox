{-# LANGUAGE OverloadedStrings #-}

-- | The Phase 2 Broker scenario: initialise, refuse, unseal and re-unseal a
-- fresh environment's Vault through the real Bootstrap Broker and its one-shot
-- secret workers, using an operator password the runner generates and hands to
-- the public commands on standard input. Each claim from a public command is
-- checked against an independent read (Vault's own health through the API
-- server's pod proxy). Neither password is printed, logged or recorded: the
-- runner also checks that no command output contains either one.
module Prodbox.Test.Phase02BrokerRunner
  ( runPhase02BrokerScenario
  ) where

import Control.Concurrent (threadDelay)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.CLI.Output (writeOutputLine)
import Prodbox.Config.BootstrapProjection
  ( ArtifactDeclaration (artifactDigest)
  , BootstrapProjection
  , bootstrapKindPlan
  , bootstrapKindTool
  , bootstrapNodeArtifact
  , bootstrapRootGeneration
  , bootstrapRuntimeSocket
  , bootstrapScope
  , readBootstrapProjection
  )
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , scopeEnvironment
  , scopeKindName
  , scopeRoot
  )
import Prodbox.Config.KindPlan (renderKindConfig)
import Prodbox.Control.ManagementPolicy (managementNamespace)
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
import Prodbox.Test.Phase01Runner
  ( digest
  , hex32
  , independentAbsence
  , independentHostData
  , publishScenario
  , readRandomBytes
  , run
  , scenarioReport
  )
import Prodbox.Test.Qualification.SourceManifest (captureSourceIdentity)
import Prodbox.Test.ScenarioEvidence
  ( ScenarioBinding (..)
  , ScenarioBudget (..)
  , ScenarioCleanup (..)
  , ScenarioPrimary (..)
  , ScenarioTiming (..)
  )
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))

data Health = Health {isInitialized :: Bool, isSealed :: Bool, clusterIdentity :: String}
  deriving (Eq, Show)

runPhase02BrokerScenario :: FilePath -> IO ExitCode
runPhase02BrokerScenario selected = do
  loaded <- readBootstrapProjection selected
  case loaded of
    Left failure -> refuse ("cannot read the selected config: " ++ show failure)
    Right projection
      | scopeEnvironment (bootstrapScope projection) /= Test ->
          refuse "the scenario runner accepts only a test identity"
      | otherwise -> scenario selected projection
 where
  refuse message = writeOutputLine ("phase-02-broker scenario refused: " ++ message) >> pure (ExitFailure 2)

scenario :: FilePath -> BootstrapProjection -> IO ExitCode
scenario selected projection = do
  let scope = bootstrapScope projection
      cluster = scopeKindName scope
      root = scopeRoot scope
      project = takeDirectory (takeDirectory root)
      kubeconfig = root </> "control" </> "kubeconfig"
      generation = Text.unpack (bootstrapRootGeneration projection)
  executable <- getExecutablePath
  binaryBytes <- ByteString.readFile executable
  sourceResult <- captureSourceIdentity "." []
  randomResult <- readRandomBytes
  started <- getMonotonicTimeNSec
  case (sourceResult, randomResult) of
    (Left failure, _) -> writeOutputLine ("source identity refused: " ++ show failure) >> pure (ExitFailure 2)
    (_, Left failure) -> writeOutputLine ("scenario entropy refused: " ++ failure) >> pure (ExitFailure 2)
    (Right source, Right randomBytes) -> do
      let second = 1000000000
          budget = ScenarioBudget (started + 2400 * second) (started + 3000 * second) (2048 * 1048576) 2400000000 0
          artifacts =
            [ ("kind.tool", digest (maybe "" artifactDigest (bootstrapKindTool projection)))
            , ("node.archive", digest (maybe "" artifactDigest (bootstrapNodeArtifact projection)))
            ]
          bindingFor :: Word16 -> String -> ScenarioBinding
          bindingFor caseNumber label =
            ScenarioBinding
              2
              caseNumber
              scope
              generation
              (hex32 (randomBytes <> "run"))
              (hex32 (randomBytes <> "operation" <> ByteString8.pack label))
              (hex32 "phase-02-broker-boot")
              source
              (digest (ByteString8.unpack (hexSha256 binaryBytes)))
              artifacts
              (digest (show (renderKindConfig (bootstrapKindPlan projection))))
              (digest ("control services; broker-init; broker-unseal; case " ++ label))
              budget
          password = hex32 (randomBytes <> "operator-password") ++ "-test"
          wrongPassword = hex32 (randomBytes <> "wrong-password") ++ "-test"
          publicWith args input = do
            result <-
              captureSubprocessWithInputBounded
                (BoundedSubprocessLimits (64 * 1024) (1024 * 1024) (256 * 1024) 900000000)
                input
                ( Subprocess
                    executable
                    (["--config", selected] ++ args)
                    (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent"), ("XDG_RUNTIME_DIR", "/run/user/1000")])
                    Nothing
                )
            pure $ case result of
              Right output ->
                Right
                  ( case processExitCode output of ExitSuccess -> 0 :: Int; ExitFailure code -> code
                  , processStdout output
                  , processStderr output
                  )
              Left failure -> Left (show failure)
          line text = ByteString8.pack (text ++ "\n")
          textOf result = either (const "") (\(_, out, err) -> out ++ err) result
          ok result = either (const False) (\(code, _, _) -> code == 0) result
          kubectl seconds arguments = kubectlInput seconds arguments ByteString.empty
          kubectlInput seconds arguments input = do
            result <-
              captureSubprocessWithInputBounded
                (BoundedSubprocessLimits (64 * 1024) (1024 * 1024) (256 * 1024) (seconds * 1000000))
                input
                ( Subprocess
                    "/usr/bin/kubectl"
                    (["--kubeconfig", kubeconfig, "--request-timeout=60s"] ++ arguments)
                    (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
                    Nothing
                )
            pure $ case result of
              Right output ->
                Right
                  ( case processExitCode output of ExitSuccess -> 0 :: Int; ExitFailure code -> code
                  , processStdout output
                  )
              Left failure -> Left (show failure)
          health = do
            result <-
              kubectl
                60
                [ "get"
                , "--raw"
                , "/api/v1/namespaces/"
                    ++ managementNamespace
                    ++ "/pods/vault:8200/proxy/v1/sys/health?uninitcode=200&sealedcode=200&standbyok=true"
                ]
            pure $ case result of
              Right (0, out) -> case Aeson.decodeStrict (ByteString8.pack out) of
                Just (Aeson.Object fields) -> case (KeyMap.lookup "initialized" fields, KeyMap.lookup "sealed" fields) of
                  (Just (Aeson.Bool i), Just (Aeson.Bool s)) ->
                    Just
                      ( Health
                          i
                          s
                          ( case KeyMap.lookup (Key.fromString "cluster_id") fields of
                              Just (Aeson.String t) -> Text.unpack t
                              _ -> ""
                          )
                      )
                  _ -> Nothing
                _ -> Nothing
              _ -> Nothing
          sealedState h = fmap (\x -> isInitialized x && isSealed x) h == Just True
          unsealedState h = fmap (\x -> isInitialized x && not (isSealed x)) h == Just True
          -- The fence lease a failed worker leaves held lasts its full duration.
          fenceFree = do
            result <-
              kubectl
                30
                [ "-n"
                , "bootstrap-broker"
                , "get"
                , "lease"
                , "bootstrap-broker-fence"
                , "-o"
                , "jsonpath={.spec.renewTime}"
                ]
            pure (case result of Right (0, out) -> out; _ -> "")
          waitFence attempts = do
            renew <- fenceFree
            ageResult <-
              run
                "/bin/sh"
                [ "-c"
                , "t=\""
                    ++ renew
                    ++ "\"; [ -z \"$t\" ] && echo 9999 || echo $(( $(date +%s) - $(date -d \"$t\" +%s) ))"
                ]
            let age =
                  either
                    (const 0)
                    (\(_, out, _) -> read (filter (`elem` ("0123456789" :: String)) out) :: Int)
                    ageResult
            if age > 310 || attempts <= (0 :: Int)
              then pure ()
              else threadDelay 15000000 >> waitFence (attempts - 1)
          -- Vault's own Kubernetes auth: log in as a ServiceAccount (token minted
          -- by the API server, passed on standard input, never printed).
          loginAs role namespace account = do
            minted <- kubectl 60 ["-n", namespace, "create", "token", account, "--duration", "600s"]
            case minted of
              Right (0, token) -> do
                result <-
                  kubectlInput
                    60
                    [ "-n"
                    , managementNamespace
                    , "exec"
                    , "-i"
                    , "vault"
                    , "--"
                    , "env"
                    , "VAULT_ADDR=http://127.0.0.1:8200"
                    , "vault"
                    , "write"
                    , "auth/kubernetes/login"
                    , "role=" ++ role
                    , "jwt=-"
                    ]
                    (ByteString8.pack (filter (/= '\n') token))
                pure (case result of Right (0, _) -> True; _ -> False)
              _ -> pure False
          restartVault = do
            _ <- kubectl 90 ["-n", managementNamespace, "delete", "pod", "vault", "--wait=true"]
            publicWith ["control", "services"] ByteString.empty
          noSecrets results = not (any (\r -> password `isInfixOf` textOf r || wrongPassword `isInfixOf` textOf r) results)
      reconcile <- publicWith ["control", "reconcile"] ByteString.empty
      services <- publicWith ["control", "services"] ByteString.empty
      healthBefore <- health
      -- Case 1: initialize through the Broker.
      noInput <- publicWith ["control", "broker-init"] ByteString.empty
      healthAfterNoInput <- health
      initRun <- publicWith ["control", "broker-init"] (line password)
      healthAfterInit <- health
      statusRun <- publicWith ["control", "vault-status"] ByteString.empty
      case1Done <- getMonotonicTimeNSec
      -- Case 2: a wrong password is refused by the worker; Vault stays sealed.
      wrongRun <- publicWith ["control", "broker-unseal"] (line wrongPassword)
      healthAfterWrong <- health
      case2Done <- getMonotonicTimeNSec
      -- Case 3: the right password unseals once the failed session's fence has lapsed.
      waitFence 40
      unsealRun <- publicWith ["control", "broker-unseal"] (line password)
      healthAfterUnseal <- health
      repeatRun <- publicWith ["control", "broker-unseal"] (line password)
      case3Done <- getMonotonicTimeNSec
      -- Case 4: the Vault Pod is replaced and comes up sealed over its retained data; unseal again.
      servicesAgain <- restartVault
      healthSealedAgain <- health
      reunsealRun <- publicWith ["control", "broker-unseal"] (line password)
      healthReunsealed <- health
      case4Done <- getMonotonicTimeNSec
      -- Case 5: the baseline through the Broker configures Vault's Kubernetes auth.
      loginBefore <-
        loginAs "prodbox-token-accessor-auditor" "bootstrap-broker" "prodbox-bootstrap-broker"
      baselineRun <- publicWith ["control", "broker-baseline"] (line password)
      loginBroker <-
        loginAs "prodbox-token-accessor-auditor" "bootstrap-broker" "prodbox-bootstrap-broker"
      loginWorkerRole <-
        loginAs "prodbox-bootstrap-broker" "bootstrap-broker" "prodbox-bootstrap-secret-worker"
      loginBrokerOnWorkerRole <-
        loginAs "prodbox-bootstrap-broker" "bootstrap-broker" "prodbox-bootstrap-broker"
      loginOther <- loginAs "prodbox-token-accessor-auditor" managementNamespace "default"
      case5Done <- getMonotonicTimeNSec
      deleteRun <- publicWith ["control", "delete", "--yes"] ByteString.empty
      absent <- independentAbsence (bootstrapRuntimeSocket projection) cluster
      retained <- independentHostData root generation (bootstrapNodeArtifact projection)
      done <- getMonotonicTimeNSec
      let all' =
            [ reconcile
            , services
            , noInput
            , initRun
            , statusRun
            , wrongRun
            , unsealRun
            , repeatRun
            , servicesAgain
            , reunsealRun
            ]
          sameCluster a b = fmap clusterIdentity a == fmap clusterIdentity b && fmap clusterIdentity a /= Just ""
          case1 =
            scenarioReport
              (bindingFor 1 "initialize")
              (ScenarioTiming started case1Done case1Done)
              (if ok services && ok initRun then PrimarySucceeded else PrimaryFailed)
              CleanupConfirmed
              [ "broker.needs-input-changes-nothing"
              , "broker.initializes-through-workers"
              , "broker.custody-durable"
              ]
              [ "Needs input" `isInfixOf` textOf noInput
              , "recovery_custody_digest" `isInfixOf` textOf initRun
              , "\"initialized\":true" `isInfixOf` textOf statusRun
                  && "\"recovery_custody_durable\":true" `isInfixOf` textOf statusRun
              ]
              [ fmap (\h -> not (isInitialized h)) healthBefore == Just True
                  && fmap (\h -> not (isInitialized h)) healthAfterNoInput == Just True
                  && not (ok noInput)
              , sealedState healthAfterInit && ok initRun
              , sealedState healthAfterInit && ok statusRun
              ]
          case2 =
            scenarioReport
              (bindingFor 2 "wrong-password")
              (ScenarioTiming case1Done case2Done case2Done)
              (if sealedState healthAfterWrong then PrimarySucceeded else PrimaryFailed)
              CleanupConfirmed
              ["broker.wrong-password-refused"]
              ["Vault unseal failed" `isInfixOf` textOf wrongRun]
              [sealedState healthAfterWrong && not (ok wrongRun)]
          case3 =
            scenarioReport
              (bindingFor 3 "unseal")
              (ScenarioTiming case2Done case3Done case3Done)
              (if ok unsealRun then PrimarySucceeded else PrimaryFailed)
              CleanupConfirmed
              ["broker.unseals-with-operator-password", "broker.repeat-unseal-is-idempotent"]
              ["\"changed\":true" `isInfixOf` textOf unsealRun, "already unsealed" `isInfixOf` textOf repeatRun]
              [unsealedState healthAfterUnseal && ok unsealRun, unsealedState healthAfterUnseal && ok repeatRun]
          case5 =
            scenarioReport
              (bindingFor 5 "baseline")
              (ScenarioTiming case4Done case5Done case5Done)
              (if ok baselineRun then PrimarySucceeded else PrimaryFailed)
              CleanupConfirmed
              [ "baseline.applies-through-broker"
              , "baseline.kubernetes-auth-accepts-broker"
              , "baseline.kubernetes-auth-refuses-other-identity"
              , "baseline.worker-role-bound-to-worker-identity"
              ]
              [ "vault_baseline_reconcile" `isInfixOf` textOf baselineRun
              , ok baselineRun
              , ok baselineRun
              , ok baselineRun
              ]
              [ ok baselineRun && not loginBefore
              , loginBroker
              , not loginOther && loginBroker
              , loginWorkerRole && not loginBrokerOnWorkerRole
              ]
          case4 =
            scenarioReport
              (bindingFor 4 "replaced-vault")
              (ScenarioTiming case3Done case4Done done)
              (if ok reunsealRun && ok servicesAgain then PrimarySucceeded else PrimaryFailed)
              (if absent && retained && ok deleteRun && noSecrets all' then CleanupConfirmed else CleanupFailed)
              ["broker.replaced-vault-comes-up-sealed", "broker.unseals-same-identity", "secrets.never-printed"]
              [ ok servicesAgain
              , "\"changed\":true" `isInfixOf` textOf reunsealRun
              , noSecrets all'
              ]
              [ sealedState healthSealedAgain
              , unsealedState healthReunsealed && sameCluster healthAfterUnseal healthReunsealed
              , noSecrets all'
              ]
      reports <- mapM (publishScenario project) [case1, case2, case3, case4, case5]
      writeOutputLine (unlines (map fst reports))
      pure (if all snd reports then ExitSuccess else ExitFailure 1)
