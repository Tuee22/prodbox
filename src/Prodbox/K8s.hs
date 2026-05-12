module Prodbox.K8s
  ( defaultInfrastructureNamespaces
  , parseKubectlObjectNames
  , runK8sCommand
  )
where

import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Prodbox.CLI.Command (K8sCommand (..))
import Prodbox.CLI.Output (writeError)
import Prodbox.Effect (Effect (..))
import Prodbox.EffectDAG (EffectNode (..), fromRootIds)
import Prodbox.EffectInterpreter (InterpreterContext (..), runEffectDAG)
import Prodbox.Error (fatalError)
import Prodbox.Prerequisite (prerequisiteRegistry)
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( CommandSpec (..)
  , ProcessOutput (..)
  , captureCommand
  , commandDisplay
  , runStreamingCommand
  )
import System.Exit (ExitCode (..))

defaultInfrastructureNamespaces :: [String]
defaultInfrastructureNamespaces = ["metallb-system", "envoy-gateway-system", "cert-manager", "postgres-operator"]

runK8sCommand :: FilePath -> K8sCommand -> IO ExitCode
runK8sCommand repoRoot command =
  case command of
    K8sHealth -> do
      prerequisiteResult <- runK8sPrerequisites repoRoot
      case prerequisiteResult of
        Failure err -> failWith err
        Success () -> pure ExitSuccess
    K8sWait timeout namespaces ->
      case validatePositive "--timeout" timeout of
        Left err -> failWith err
        Right () -> runK8sGraph repoRoot (waitNode repoRoot timeout (normalizeNamespaces namespaces))
    K8sLogs namespaces tailLines ->
      case validatePositive "--tail" tailLines of
        Left err -> failWith err
        Right () -> runK8sLogs repoRoot (normalizeNamespaces namespaces) tailLines

parseKubectlObjectNames :: String -> [String]
parseKubectlObjectNames stdoutText = filter (not . null) (map trimWhitespace (lines stdoutText))

runK8sLogs :: FilePath -> [String] -> Int -> IO ExitCode
runK8sLogs repoRoot namespaces tailLines = do
  prerequisiteResult <- runK8sPrerequisites repoRoot
  case prerequisiteResult of
    Failure err -> failWith err
    Success () -> do
      namespacePodsResult <- mapM (listNamespacePods repoRoot) namespaces
      case sequence namespacePodsResult of
        Left err -> failWith err
        Right namespacePods -> do
          let podRefs = concat namespacePods
          case podRefs of
            [] -> putStrLn "No pods found in requested namespaces." >> pure ExitSuccess
            _ -> streamPodLogs repoRoot tailLines podRefs

listNamespacePods :: FilePath -> String -> IO (Either String [(String, String)])
listNamespacePods repoRoot namespace = do
  outputResult <- captureCommand (kubectlSpec repoRoot (Just namespace) ["get", "pods", "-o", "name"])
  pure $
    case outputResult of
      Failure err -> Left ("failed to start `kubectl get pods` for namespace `" ++ namespace ++ "`: " ++ err)
      Success output ->
        case processExitCode output of
          ExitSuccess -> Right (map (namespacePod namespace) (parseKubectlObjectNames (processStdout output)))
          ExitFailure code ->
            Left
              ( "`"
                  ++ commandDisplay (kubectlSpec repoRoot (Just namespace) ["get", "pods", "-o", "name"])
                  ++ "` exited with code "
                  ++ show code
              )
 where
  namespacePod :: String -> String -> (String, String)
  namespacePod namespaceName podName = (namespaceName, podName)

streamPodLogs :: FilePath -> Int -> [(String, String)] -> IO ExitCode
streamPodLogs repoRoot tailLines podRefs = go podRefs
 where
  go [] = pure ExitSuccess
  go ((namespace, podRef) : remaining) = do
    commandResult <-
      runStreamingCommand
        ( kubectlSpec
            repoRoot
            (Just namespace)
            [ "logs"
            , podRef
            , "--all-containers=true"
            , "--tail=" ++ show tailLines
            ]
        )
    case commandResult of
      Failure err -> failWith ("failed to start pod log stream for `" ++ podRef ++ "`: " ++ err)
      Success ExitSuccess -> go remaining
      Success (ExitFailure code) ->
        failWith
          ( "`"
              ++ commandDisplay
                ( kubectlSpec
                    repoRoot
                    (Just namespace)
                    [ "logs"
                    , podRef
                    , "--all-containers=true"
                    , "--tail=" ++ show tailLines
                    ]
                )
              ++ "` exited with code "
              ++ show code
          )

runK8sGraph :: FilePath -> EffectNode -> IO ExitCode
runK8sGraph repoRoot rootNode = do
  let registry = Map.insert (effectNodeId rootNode) rootNode prerequisiteRegistry
  case fromRootIds [effectNodeId rootNode] registry of
    Left err -> failWith err
    Right dag -> do
      result <- runEffectDAG (InterpreterContext repoRoot) dag
      case result of
        Failure err -> failWith err
        Success () -> pure ExitSuccess

runK8sPrerequisites :: FilePath -> IO (Result ())
runK8sPrerequisites repoRoot =
  case fromRootIds k8sPrerequisiteRoots prerequisiteRegistry of
    Left err -> pure (Failure err)
    Right dag -> runEffectDAG (InterpreterContext repoRoot) dag

waitNode :: FilePath -> Int -> [String] -> EffectNode
waitNode repoRoot timeout namespaces =
  EffectNode
    { effectNodeId = "k8s_wait"
    , effectNodeDescription = "Wait for deployments to become available"
    , effectNodeRemedyHint =
        "Wait for the requested deployments to reach `Available=True` or inspect the failing namespace."
    , effectNodePrerequisites = k8sPrerequisiteRoots
    , effectNodeEffect =
        Sequence
          [ RunCommand
            ( kubectlSpec
                repoRoot
                (Just namespace)
                [ "wait"
                , "--all"
                , "--for=condition=available"
                , "deployment"
                , "--timeout=" ++ show timeout ++ "s"
                ]
            )
          | namespace <- namespaces
          ]
    }

k8sPrerequisiteRoots :: [String]
k8sPrerequisiteRoots = ["k8s_cluster_reachable"]

kubectlSpec :: FilePath -> Maybe String -> [String] -> CommandSpec
kubectlSpec repoRoot maybeNamespace args =
  CommandSpec
    { commandPath = "kubectl"
    , commandArguments = namespaceArgs ++ args
    , commandEnvironment = Nothing
    , commandWorkingDirectory = Just repoRoot
    }
 where
  namespaceArgs =
    case maybeNamespace of
      Nothing -> []
      Just namespace -> ["--namespace", namespace]

validatePositive :: String -> Int -> Either String ()
validatePositive flagName value =
  if value > 0
    then Right ()
    else Left (flagName ++ " must be greater than 0.")

normalizeNamespaces :: [String] -> [String]
normalizeNamespaces namespaces =
  case namespaces of
    [] -> defaultInfrastructureNamespaces
    _ -> namespaces

trimWhitespace :: String -> String
trimWhitespace = reverse . dropWhile (== ' ') . reverse . dropWhile (== ' ')

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)
