{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.12: K8s-API drain phase for destructive lifecycle
-- commands.
--
-- Closes leak classes 2-5 from
-- @documents/engineering/lifecycle_reconciliation_doctrine.md § 1@
-- (CSI volumes, LBC load balancers, cert-manager DNS01 records,
-- direct-aws-CLI subprocess Route 53 records) by deleting the K8s
-- resources whose controllers own the corresponding AWS objects, then
-- polling for AWS-side unwind with a bounded timeout.
--
-- The drain runs **before** any per-run Pulumi destroy so the AWS
-- Load Balancer Controller and EBS CSI driver are still alive and can
-- unwind their AWS resources. Once the drain completes the cluster
-- has no LoadBalancer Services, ALB Ingresses, or Delete-reclaim
-- PVCs, and the postflight tag sweep should return clean.
module Prodbox.Lifecycle.K8sDrain
  ( CascadeDecision (..)
  , ClusterProbe (..)
  , DrainTimeout (..)
  , DrainResult (..)
  , K8sDrainEnv (..)
  , cascadeDecisionFromDrainResult
  , classifyClusterProbe
  , clusterAbsenceEvidencePhrases
  , collectSurvivors
  , defaultDrainTimeout
  , deleteReclaimPersistentVolumeJsonPath
  , deleteReclaimPvcBindings
  , drainAwsAffectingK8sResources
  , probeCluster
  , renderClusterProbe
  , renderDrainTimeoutRefusal
  )
where

import Control.Concurrent (threadDelay)
import Data.Char (toLower)
import Data.List (intercalate, isInfixOf)
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import System.Exit (ExitCode (..))

-- | Configurable drain deadline. Default is 5 minutes, which is
-- enough headroom for the AWS Load Balancer Controller to delete an
-- ALB (~30-60s) and for the EBS CSI driver to delete a small Delete-
-- reclaim PVC (~30-60s) even on a slow control plane.
newtype DrainTimeout = DrainTimeout {drainTimeoutSeconds :: Int}
  deriving (Eq, Show)

defaultDrainTimeout :: DrainTimeout
defaultDrainTimeout = DrainTimeout 300

-- | Environment for kubectl subprocesses. Caller supplies the
-- @KUBECONFIG@/@AWS_*@ environment (typically inherited from the
-- substrate-aware test runner) and the working directory.
data K8sDrainEnv = K8sDrainEnv
  { drainEnvironment :: [(String, String)]
  , drainWorkingDirectory :: Maybe FilePath
  }
  deriving (Eq, Show)

-- | Outcome of the drain. Encodes the three-outcome ADT documented
-- in @documents/engineering/lifecycle_reconciliation_doctrine.md
-- § 3 layer 1@:
--
--   * 'DrainSucceeded' — cluster was reachable, the targeted K8s
--     resources were deleted, and the bounded poll loop observed
--     them gone before the deadline.
--   * 'DrainSkipped' — the API server was positively observed to be
--     serving nothing ('ClusterAbsent'). No delete was attempted; the
--     cascade caller treats this as a success-with-reason on the home
--     substrate because the K8s controllers that would have owned AWS
--     resources are already gone, and the postflight tag sweep is the
--     backstop.
--   * 'DrainUnobservable' — Sprint 4.76. The probe could not decide
--     whether a cluster is there ('ClusterUnobservable'): a denied
--     credential, a stale context, an expired token, or a probe that
--     could not be started all land here. Before Sprint 4.76 this state
--     did not exist — 'clusterReachable' returned @False@ for every
--     non-zero @kubectl@ exit, so "I was refused" was reported as "the
--     cluster is gone" and the cascade continued on the branch where a
--     skipped drain is success. It aborts on **both** substrates,
--     matching @src/Prodbox/TestRunner.hs@, which has always treated
--     even 'DrainSkipped' as @ExitFailure 1@.
--   * 'DrainTimedOut' — cluster was reachable and the delete
--     succeeded, but the bounded poll loop still saw surviving
--     resources at the deadline. Carries the list of surviving
--     resources by @Kind/namespace/name@.
--   * 'DrainFailed' — cluster was reachable AND a delete or poll
--     step errored.
data DrainResult
  = DrainSucceeded
  | DrainSkipped String
  | DrainUnobservable String
  | DrainTimedOut [String]
  | DrainFailed String
  deriving (Eq, Show)

-- | Sprint 4.76: the three-valued Kubernetes API-server observation that
-- replaces @clusterReachable :: K8sDrainEnv -> IO Bool@.
--
-- The @Bool@ manufactured certainty it did not have. @kubectl
-- cluster-info@ exits non-zero for "nothing is listening on this
-- address", for "your credential was refused", and for "this context
-- names a cluster that no longer exists" alike, and the caller then
-- read every one of them as "the cluster is gone" — the
-- @IO Bool@ producer collapse
-- [chaos_hardening_doctrine.md § 23](chaos_hardening_doctrine.md) names
-- as where conversions fail.
--
-- Only a **recognised** absence shape yields 'ClusterAbsent'; every
-- other non-zero exit — and a probe that could not be started at all —
-- yields 'ClusterUnobservable'. The default is the uncertain arm, so a
-- @kubectl@ failure mode this classifier has never seen fails closed.
data ClusterProbe
  = -- | The API server answered.
    ClusterReachable
  | -- | Positively observed: nothing is serving at the configured
    -- address. Carries the evidence phrase that decided it.
    ClusterAbsent !String
  | -- | The probe could not decide. Carries the underlying detail.
    ClusterUnobservable !String
  deriving (Eq, Show)

renderClusterProbe :: ClusterProbe -> String
renderClusterProbe probe = case probe of
  ClusterReachable -> "reachable"
  ClusterAbsent evidence -> "absent (" ++ evidence ++ ")"
  ClusterUnobservable detail -> "unobservable (" ++ detail ++ ")"

-- | The closed set of @kubectl@ / client-go transport phrases that
-- positively evidence "no API server is serving at this address". Every
-- entry is a connection-establishment failure: the address was reached
-- and nothing answered, or the name/route does not resolve. An
-- authentication or authorization refusal is deliberately **not** here —
-- being told @Unauthorized@ proves a server answered.
clusterAbsenceEvidencePhrases :: [String]
clusterAbsenceEvidencePhrases =
  [ "connection refused"
  , "connect: no route to host"
  , "connect: network is unreachable"
  , "no such host"
  , "server could not find the requested resource"
  , "the connection to the server localhost:8080 was refused"
  ]

-- | Pure classifier for the probe subprocess result, so the
-- connection-refused / permission-denied / success split is pinned by a
-- unit case rather than by a live cluster.
classifyClusterProbe :: Result ProcessOutput -> ClusterProbe
classifyClusterProbe result = case result of
  Failure err -> ClusterUnobservable ("failed to start `kubectl`: " ++ err)
  Success output -> case processExitCode output of
    ExitSuccess -> ClusterReachable
    ExitFailure code ->
      let combined = processStderr output ++ "\n" ++ processStdout output
          lowered = map toLower combined
       in case [phrase | phrase <- clusterAbsenceEvidencePhrases, phrase `isInfixOf` lowered] of
            (evidence : _) -> ClusterAbsent evidence
            [] ->
              ClusterUnobservable
                ( "`kubectl cluster-info` exited with code "
                    ++ show code
                    ++ " and no recognised absence evidence: "
                    ++ unwords (words combined)
                )

-- | The cascade caller's view of the drain outcome. Mirrors the
-- skip-is-success invariant from the lifecycle doctrine: both
-- 'DrainSucceeded' and 'DrainSkipped' map to 'CascadeContinue',
-- while 'DrainTimedOut' and 'DrainFailed' map to 'CascadeAbort'
-- with a reason string. Exposed as a pure helper so unit tests can
-- pin the decision matrix without needing live cluster IO.
data CascadeDecision
  = -- | @Just reason@ when the drain was skipped (so the cascade
    -- caller logs the operator-visible reason); @Nothing@ when the
    -- drain succeeded cleanly.
    CascadeContinue (Maybe String)
  | CascadeAbort String
  deriving (Eq, Show)

cascadeDecisionFromDrainResult :: DrainResult -> CascadeDecision
cascadeDecisionFromDrainResult result = case result of
  DrainSucceeded -> CascadeContinue Nothing
  DrainSkipped reason -> CascadeContinue (Just reason)
  DrainUnobservable detail ->
    CascadeAbort
      ( "K8s drain could not observe whether a cluster is present: "
          ++ detail
          ++ " This is not evidence that the cluster is gone, so the drain "
          ++ "cannot be recorded as skipped-because-nothing-to-drain."
      )
  DrainTimedOut survivors ->
    CascadeAbort
      ( "K8s drain timed out with surviving resources: "
          ++ intercalate ", " survivors
      )
  DrainFailed err -> CascadeAbort ("K8s drain failed: " ++ err)

-- | Sprint 4.76: observe whether a Kubernetes API server is serving.
-- Runs @kubectl cluster-info --request-timeout=5s@ and classifies the
-- result through the pure 'classifyClusterProbe', so "nothing is
-- listening" and "I was refused" are different answers rather than one
-- @False@.
probeCluster :: K8sDrainEnv -> IO ClusterProbe
probeCluster env =
  classifyClusterProbe
    <$> captureSubprocessResult
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "cluster-info"
            , "--request-timeout=5s"
            ]
        , subprocessEnvironment = Just (drainEnvironment env)
        , subprocessWorkingDirectory = drainWorkingDirectory env
        }

-- | Delete every K8s resource whose deletion is required for
-- AWS-side unwind, then poll for the cluster to settle. Begins with
-- a 'probeCluster' observation so a positively-absent cluster yields
-- 'DrainSkipped', an undecidable probe yields 'DrainUnobservable', and
-- only a serving API server proceeds to the delete phase. Returns
-- 'DrainSucceeded' when the cluster is reachable and clean before
-- the deadline, 'DrainTimedOut' when at least one resource survives,
-- or 'DrainFailed' when kubectl errors out during the delete phase.
drainAwsAffectingK8sResources
  :: K8sDrainEnv -> DrainTimeout -> IO DrainResult
drainAwsAffectingK8sResources env timeout = do
  probe <- probeCluster env
  case probe of
    ClusterAbsent evidence ->
      pure
        ( DrainSkipped
            ( "Kubernetes API server observed absent ("
                ++ evidence
                ++ "); nothing to drain."
            )
        )
    ClusterUnobservable detail -> pure (DrainUnobservable detail)
    ClusterReachable -> do
      deleteResult <- deleteAwsAffectingResources env
      case deleteResult of
        Left err -> pure (DrainFailed err)
        Right () -> waitForDrainComplete env timeout

deleteAwsAffectingResources :: K8sDrainEnv -> IO (Either String ())
deleteAwsAffectingResources env = do
  loadBalancers <-
    runKubectl
      env
      [ "delete"
      , "services"
      , "--all-namespaces"
      , "--field-selector=spec.type=LoadBalancer"
      , "--wait=false"
      , "--ignore-not-found=true"
      ]
  case loadBalancers of
    Left err -> pure (Left ("delete LoadBalancer Services: " ++ err))
    Right () -> do
      ingresses <-
        runKubectl
          env
          [ "delete"
          , "ingresses"
          , "--all-namespaces"
          , "--all"
          , "--wait=false"
          , "--ignore-not-found=true"
          ]
      case ingresses of
        Left err -> pure (Left ("delete Ingresses: " ++ err))
        Right () -> do
          pvcs <- deleteDeleteReclaimPvcs env
          case pvcs of
            Left err -> pure (Left ("delete Delete-reclaim PVCs: " ++ err))
            Right () -> pure (Right ())

-- | Delete every PVC whose underlying PV has @reclaimPolicy=Delete@.
-- Retain-policy PVs intentionally survive the drain because their
-- controllers do not own AWS resources; the operator-managed PV
-- mounts on the home substrate are an example.
deleteReclaimPersistentVolumeJsonPath :: String
deleteReclaimPersistentVolumeJsonPath =
  "jsonpath={range .items[?(@.spec.persistentVolumeReclaimPolicy==\"Delete\")]}\
  \{.spec.claimRef.namespace}{\"|\"}{.spec.claimRef.name}{\"\\n\"}{end}"

deleteReclaimPvcBindings :: String -> [(String, String)]
deleteReclaimPvcBindings rawOutput =
  [ (namespace, name)
  | line <- lines rawOutput
  , (namespace, '|' : name) <- [break (== '|') line]
  , not (null namespace)
  , not (null name)
  ]

deleteDeleteReclaimPvcs :: K8sDrainEnv -> IO (Either String ())
deleteDeleteReclaimPvcs env = do
  listResult <-
    captureKubectl
      env
      [ "get"
      , "pv"
      , "-o"
      , deleteReclaimPersistentVolumeJsonPath
      ]
  case listResult of
    Left err -> pure (Left ("list Delete-reclaim PVs: " ++ err))
    Right rawOutput -> do
      let bindings = deleteReclaimPvcBindings rawOutput
      results <- mapM (deletePvc env) bindings
      pure $ case [err | Left err <- results] of
        [] -> Right ()
        errs -> Left (intercalate "; " errs)

deletePvc :: K8sDrainEnv -> (String, String) -> IO (Either String ())
deletePvc env (namespace, name) =
  runKubectl
    env
    [ "delete"
    , "pvc"
    , "-n"
    , namespace
    , name
    , "--wait=false"
    , "--ignore-not-found=true"
    ]

waitForDrainComplete :: K8sDrainEnv -> DrainTimeout -> IO DrainResult
waitForDrainComplete env timeout = go (drainTimeoutSeconds timeout)
 where
  pollIntervalSeconds = 10 :: Int

  go :: Int -> IO DrainResult
  go remainingSeconds
    | remainingSeconds <= 0 = do
        survivors <- collectSurvivors env
        case survivors of
          Left err -> pure (DrainFailed err)
          Right [] -> pure DrainSucceeded
          Right names -> pure (DrainTimedOut names)
    | otherwise = do
        survivors <- collectSurvivors env
        case survivors of
          Left err -> pure (DrainFailed err)
          Right [] -> pure DrainSucceeded
          Right _ -> do
            threadDelay (pollIntervalSeconds * 1000000)
            go (remainingSeconds - pollIntervalSeconds)

collectSurvivors :: K8sDrainEnv -> IO (Either String [String])
collectSurvivors env = do
  loadBalancersResult <-
    captureKubectl
      env
      [ "get"
      , "services"
      , "--all-namespaces"
      , "--field-selector=spec.type=LoadBalancer"
      , "-o"
      , "jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}{\"\\n\"}{end}"
      ]
  case loadBalancersResult of
    Left err -> pure (Left err)
    Right loadBalancersText -> do
      ingressesResult <-
        captureKubectl
          env
          [ "get"
          , "ingresses"
          , "--all-namespaces"
          , "-o"
          , "jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}{\"\\n\"}{end}"
          ]
      case ingressesResult of
        Left err -> pure (Left err)
        Right ingressesText ->
          pure
            ( Right
                ( [ "Service/" ++ name | name <- lines loadBalancersText, not (null name)
                  ]
                    ++ [ "Ingress/" ++ name | name <- lines ingressesText, not (null name)
                       ]
                )
            )

renderDrainTimeoutRefusal :: [String] -> String
renderDrainTimeoutRefusal survivors =
  unlines
    ( [ "K8s drain timed out: AWS-affecting K8s resources still exist"
      , "after the drain deadline expired. The controllers may need more"
      , "time, or one of the resources has a finalizer that's preventing"
      , "deletion. Investigate the following resources before retrying:"
      , ""
      ]
        ++ map (\survivor -> "  - " ++ survivor) survivors
    )

runKubectl :: K8sDrainEnv -> [String] -> IO (Either String ())
runKubectl env arguments = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments = arguments
        , subprocessEnvironment = Just (drainEnvironment env)
        , subprocessWorkingDirectory = drainWorkingDirectory env
        }
  pure $ case result of
    Failure err -> Left ("failed to start `kubectl`: " ++ err)
    Success output -> case processExitCode output of
      ExitSuccess -> Right ()
      ExitFailure code ->
        Left
          ( "`kubectl "
              ++ unwords arguments
              ++ "` exited with code "
              ++ show code
              ++ ": "
              ++ processStderr output
              ++ processStdout output
          )

captureKubectl :: K8sDrainEnv -> [String] -> IO (Either String String)
captureKubectl env arguments = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments = arguments
        , subprocessEnvironment = Just (drainEnvironment env)
        , subprocessWorkingDirectory = drainWorkingDirectory env
        }
  pure $ case result of
    Failure err -> Left ("failed to start `kubectl`: " ++ err)
    Success output -> case processExitCode output of
      ExitSuccess -> Right (processStdout output)
      ExitFailure code ->
        Left
          ( "`kubectl "
              ++ unwords arguments
              ++ "` exited with code "
              ++ show code
              ++ ": "
              ++ processStderr output
              ++ processStdout output
          )
