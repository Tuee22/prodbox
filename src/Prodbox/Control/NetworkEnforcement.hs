{-# LANGUAGE OverloadedStrings #-}

-- | Observe whether the cluster's pod network enforces NetworkPolicy, with
-- real TCP connections and a positive control. In a throwaway namespace a
-- server pod accepts connections; before any policy both a client labelled
-- allowed and one labelled other must connect (the observer works); after an
-- ingress policy that admits only the allowed label, the allowed client must
-- still connect and the other must not; after the policy is deleted the
-- other client must connect again (the policy, not something else, was the
-- cause). The namespace is deleted afterwards and that result is reported
-- separately. Every image is one that ships in the pinned node image and is
-- run with pull policy Never, so nothing is pulled. A successful policy apply
-- is not evidence: only the four connection observations are.
module Prodbox.Control.NetworkEnforcement
  ( EnforcementObservation (..)
  , EnforcementOutcome (..)
  , observeNetworkEnforcement
  , enforcementProven
  ) where

import Control.Concurrent (threadDelay)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.List (isInfixOf)
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
import System.Exit (ExitCode (..))

data EnforcementObservation = EnforcementObservation
  { observedBaselineAllowed :: !Bool
  , observedBaselineOther :: !Bool
  , observedPolicyAllowed :: !Bool
  , observedPolicyOther :: !Bool
  , observedRemovedOther :: !Bool
  }
  deriving (Eq, Show)

data EnforcementOutcome = EnforcementOutcome
  { enforcementObservation :: !(Maybe EnforcementObservation)
  , enforcementFailure :: !(Maybe String)
  , enforcementCleanup :: !String
  }
  deriving (Eq, Show)

-- | Enforcement is proven only by a working observer, a held allow, a real
-- deny and a restored connection after the policy is removed.
enforcementProven :: EnforcementObservation -> Bool
enforcementProven observation =
  observedBaselineAllowed observation
    && observedBaselineOther observation
    && observedPolicyAllowed observation
    && not (observedPolicyOther observation)
    && observedRemovedOther observation

helperImage, serverImage :: String
helperImage = "docker.io/kindest/local-path-helper:v20260131-7181c60a"
serverImage = "registry.k8s.io/coredns/coredns:v1.14.2"

limits :: BoundedSubprocessLimits
limits = BoundedSubprocessLimits 65536 65536 16384 120000000

kubectl :: FilePath -> [String] -> ByteString.ByteString -> IO (Either String (Int, String))
kubectl kubeconfig arguments input = do
  result <-
    captureSubprocessWithInputBounded
      limits
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
        ( case processExitCode output of
            ExitSuccess -> 0
            ExitFailure code -> code
        , processStdout output
        )
    Left failure -> Left (show failure)

serverManifest :: String -> ByteString.ByteString
serverManifest namespace =
  ByteString8.pack $
    unlines
      [ "apiVersion: v1"
      , "kind: ConfigMap"
      , "metadata: {name: corefile, namespace: " ++ namespace ++ "}"
      , "data: {Corefile: \".:5353 {\\n whoami\\n}\\n\"}"
      , "---"
      , "apiVersion: v1"
      , "kind: Pod"
      , "metadata: {name: server, namespace: " ++ namespace ++ ", labels: {app: server}}"
      , "spec:"
      , "  containers: [{name: s, image: "
          ++ serverImage
          ++ ", imagePullPolicy: Never, args: [\"-conf\", \"/etc/c/Corefile\"], volumeMounts: [{name: v, mountPath: /etc/c}]}]"
      , "  volumes: [{name: v, configMap: {name: corefile}}]"
      ]

clientManifest :: String -> String -> String -> String -> ByteString.ByteString
clientManifest namespace name role address =
  ByteString8.pack $
    unlines
      [ "apiVersion: v1"
      , "kind: Pod"
      , "metadata: {name: " ++ name ++ ", namespace: " ++ namespace ++ ", labels: {role: " ++ role ++ "}}"
      , "spec:"
      , "  restartPolicy: Never"
      , "  containers: [{name: c, image: "
          ++ helperImage
          ++ ", imagePullPolicy: Never, command: [bash, -c, \"if (exec 3<>/dev/tcp/"
          ++ address
          ++ "/5353) 2>/dev/null; then echo CONNECTED; else echo REFUSED; fi\"]}]"
      ]

policyManifest :: String -> ByteString.ByteString
policyManifest namespace =
  ByteString8.pack $
    unlines
      [ "apiVersion: networking.k8s.io/v1"
      , "kind: NetworkPolicy"
      , "metadata: {name: only-allowed, namespace: " ++ namespace ++ "}"
      , "spec:"
      , "  podSelector: {matchLabels: {app: server}}"
      , "  policyTypes: [Ingress]"
      , "  ingress: [{from: [{podSelector: {matchLabels: {role: allowed}}}]}]"
      ]

-- | Run the whole sequence against the cluster the kubeconfig selects. The
-- namespace name must be unique to this run.
observeNetworkEnforcement :: FilePath -> String -> IO EnforcementOutcome
observeNetworkEnforcement kubeconfig namespace = do
  outcome <- sequenceObservation
  cleanup <-
    kubectl
      kubeconfig
      ["delete", "namespace", namespace, "--wait=true", "--timeout=90s"]
      ByteString.empty
  pure
    outcome
      { enforcementCleanup = case cleanup of
          Right (0, _) -> "namespace removed"
          Right (code, text) -> "namespace removal exit " ++ show code ++ ": " ++ take 200 text
          Left failure -> "namespace removal not run: " ++ failure
      }
 where
  failed reason = pure (EnforcementOutcome Nothing (Just reason) "")
  step description action = do
    result <- action
    pure $ case result of
      Right (0, text) -> Right text
      Right (code, text) -> Left (description ++ " exit " ++ show code ++ ": " ++ take 200 text)
      Left failure -> Left (description ++ ": " ++ failure)
  sequenceObservation = do
    created <-
      step "namespace create" (kubectl kubeconfig ["create", "namespace", namespace] ByteString.empty)
    nodes <-
      step
        "nodes ready"
        ( kubectl
            kubeconfig
            ["wait", "--for=condition=Ready", "node", "--all", "--timeout=120s"]
            ByteString.empty
        )
    case (created, nodes) of
      (Left reason, _) -> failed reason
      (_, Left reason) -> failed reason
      _ -> do
        server <- step "server apply" (kubectl kubeconfig ["apply", "-f", "-"] (serverManifest namespace))
        case server of
          Left reason -> failed reason
          Right _ -> do
            ready <-
              step
                "server ready"
                ( kubectl
                    kubeconfig
                    ["-n", namespace, "wait", "--for=condition=Ready", "pod/server", "--timeout=90s"]
                    ByteString.empty
                )
            address <-
              step
                "server address"
                ( kubectl
                    kubeconfig
                    ["-n", namespace, "get", "pod", "server", "-o", "jsonpath={.status.podIP}"]
                    ByteString.empty
                )
            case (ready, address) of
              (Left reason, _) -> failed reason
              (_, Left reason) -> failed reason
              (Right _, Right ip) | null ip -> failed "server has no pod address"
              (Right _, Right ip) -> observe ip
  -- Each phase starts two uniquely named clients and reads each result after
  -- a fixed settling interval: a connection that is dropped never prints.
  probe phase ip = do
    let allowedName = phase ++ "-allowed"
        otherName = phase ++ "-other"
    _ <-
      kubectl
        kubeconfig
        ["apply", "-f", "-"]
        ( clientManifest namespace allowedName "allowed" ip
            <> "---\n"
            <> clientManifest namespace otherName "other" ip
        )
    threadDelay 9000000
    allowed <- connected allowedName
    other <- connected otherName
    pure (allowed, other)
  connected name = do
    logs <- kubectl kubeconfig ["-n", namespace, "logs", name] ByteString.empty
    pure $ case logs of
      Right (0, text) -> "CONNECTED" `isInfixOf` text
      _ -> False
  observe ip = do
    (baselineAllowed, baselineOther) <- probe "base" ip
    applied <- step "policy apply" (kubectl kubeconfig ["apply", "-f", "-"] (policyManifest namespace))
    case applied of
      Left reason -> failed reason
      Right _ -> do
        threadDelay 5000000
        (policyAllowed, policyOther) <- probe "pol" ip
        removed <-
          step
            "policy delete"
            (kubectl kubeconfig ["-n", namespace, "delete", "networkpolicy", "only-allowed"] ByteString.empty)
        case removed of
          Left reason -> failed reason
          Right _ -> do
            threadDelay 5000000
            (_, removedOther) <- probe "off" ip
            pure
              ( EnforcementOutcome
                  (Just (EnforcementObservation baselineAllowed baselineOther policyAllowed policyOther removedOther))
                  Nothing
                  ""
              )
