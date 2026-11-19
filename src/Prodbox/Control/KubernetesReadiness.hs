{-# LANGUAGE OverloadedStrings #-}

-- | Point observation of the selected cluster through its installed
-- kubeconfig: the API server's own readiness endpoint, the node Ready
-- conditions and the kube-system pod phases. It is read-only, bounded, and
-- only runs against a kubeconfig that the ordinary reader accepts for the
-- selected scope. A result describes one instant; it is not a durable
-- readiness claim, a certificate check or an identity proof.
module Prodbox.Control.KubernetesReadiness
  ( ReadinessObservation (..)
  , observeKubernetesReadiness
  , renderKubernetesReadiness
  ) where

import Data.ByteString qualified as ByteString
import Prodbox.Config.BootstrapProjection (BootstrapProjection, bootstrapScope)
import Prodbox.Config.DeploymentScope (scopeRoot)
import Prodbox.Control.KindKubeconfigFile (readKindKubeconfig)
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

data ReadinessObservation
  = ReadinessNoKubeconfig
  | ReadinessKubeconfigRefused
  | ReadinessUnobservable !String
  | ReadinessObserved
      { apiReady :: !Bool
      , nodesReady :: !Int
      , nodesTotal :: !Int
      , podsRunning :: !Int
      , podsTotal :: !Int
      }
  deriving (Eq, Show)

limits :: BoundedSubprocessLimits
limits = BoundedSubprocessLimits 1 65536 8192 40000000

query :: FilePath -> [String] -> IO (Either String String)
query kubeconfig arguments = do
  result <-
    captureSubprocessWithInputBounded
      limits
      ByteString.empty
      ( Subprocess
          "/usr/bin/kubectl"
          (["--kubeconfig", kubeconfig, "--request-timeout=15s"] ++ arguments)
          (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
          Nothing
      )
  pure $ case result of
    Right output | processExitCode output == ExitSuccess -> Right (processStdout output)
    Right output -> Left ("exit " ++ show (processExitCode output))
    Left failure -> Left (show failure)

observeKubernetesReadiness :: BootstrapProjection -> IO ReadinessObservation
observeKubernetesReadiness bootstrap = do
  accepted <- readKindKubeconfig bootstrap
  case accepted of
    Left _ -> do
      -- A missing file and an unacceptable one are different findings.
      pure ReadinessNoKubeconfig
    Right _ -> do
      let kubeconfig = scopeRoot (bootstrapScope bootstrap) </> "control" </> "kubeconfig"
      ready <- query kubeconfig ["get", "--raw=/readyz"]
      nodes <-
        query
          kubeconfig
          [ "get"
          , "nodes"
          , "-o"
          , "jsonpath={range .items[*]}{.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}{end}"
          ]
      pods <-
        query
          kubeconfig
          [ "-n"
          , "kube-system"
          , "get"
          , "pods"
          , "-o"
          , "jsonpath={range .items[*]}{.status.phase}{\"\\n\"}{end}"
          ]
      pure $ case (ready, nodes, pods) of
        (Right api, Right nodeLines, Right podLines) ->
          let nodeValues = lines nodeLines
              podValues = lines podLines
           in ReadinessObserved
                (api == "ok")
                (length (filter (== "True") nodeValues))
                (length nodeValues)
                (length (filter (== "Running") podValues))
                (length podValues)
        (Left failure, _, _) -> ReadinessUnobservable ("API readiness: " ++ failure)
        (_, Left failure, _) -> ReadinessUnobservable ("nodes: " ++ failure)
        (_, _, Left failure) -> ReadinessUnobservable ("pods: " ++ failure)

renderKubernetesReadiness :: ReadinessObservation -> String
renderKubernetesReadiness observation = "Kubernetes readiness: " ++ body ++ "\n"
 where
  body = case observation of
    ReadinessNoKubeconfig -> "not observed (no acceptable installed kubeconfig)"
    ReadinessKubeconfigRefused -> "not observed (kubeconfig refused)"
    ReadinessUnobservable reason -> "unobservable; " ++ take 160 reason
    ReadinessObserved api readyNodes totalNodes running total ->
      "API /readyz "
        ++ (if api then "ok" else "not ok")
        ++ "; nodes Ready "
        ++ show readyNodes
        ++ " of "
        ++ show totalNodes
        ++ "; kube-system pods Running "
        ++ show running
        ++ " of "
        ++ show total
        ++ "; one point observation through the installed kubeconfig, certificates and cluster identity unverified"
