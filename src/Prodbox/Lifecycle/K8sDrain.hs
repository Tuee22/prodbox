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
  , DrainCallFailure (..)
  , DrainTimeout (..)
  , DrainResult (..)
  , K8sDrainEnv
  , cascadeDecisionFromDrainResult
  , classifyClusterProbe
  , collectSurvivors
  , defaultDrainTimeout
  , drainKubectlDiscoveryAttempts
  , drainKubectlRequestTimeoutArgument
  , drainKubectlRequestTimeoutSeconds
  , drainKubectlWallClockMarginSeconds
  , drainKubectlWallClockSeconds
  , deleteReclaimPersistentVolumeJsonPath
  , deleteReclaimPvcBindings
  , drainAwsAffectingK8sResources
  , observeK8sClusterUid
  , prepareK8sDrainEnv
  , prepareK8sDrainEnvWithKubectl
  , probeCluster
  , renderClusterProbe
  , renderDrainTimeoutRefusal
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (void)
import Data.List (intercalate)
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Error (errorMsg)
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  )
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))

-- | The completion poll's budget. Default is 5 minutes, which is enough
-- headroom for the AWS Load Balancer Controller to delete an ALB (~30-60s) and
-- for the EBS CSI driver to delete a small Delete-reclaim PVC (~30-60s) even on
-- a slow control plane.
--
-- __This is not the bound on a @kubectl@ call, and Sprint 4.93 made the two
-- visibly separate numbers.__ It bounds /waiting for resources to disappear/.
-- Until that sprint it bounded nothing else either: every call that asks ran
-- through an unbounded runner, so a child that blocked held the drain past the
-- five minutes an operator reads about, and the refusal they are told to expect
-- could not be emitted because the code never reached it.
--
-- The two numbers now compose, and each is stated where it is derived. A call
-- is bounded at 'drainKubectlWallClockSeconds'; a poll iteration makes @2 + N@
-- calls for N targeted PVCs; and this budget is an absolute deadline read from
-- a monotonic clock rather than a counter decremented by the sleep interval
-- alone. Time spent inside an iteration's calls is therefore charged against
-- it, which the superseded countdown did not do: it subtracted 10 per iteration
-- whatever the calls cost, so the stated 300 seconds was an iteration count.
newtype DrainTimeout = DrainTimeout {drainTimeoutSeconds :: Int}
  deriving (Eq, Show)

defaultDrainTimeout :: DrainTimeout
defaultDrainTimeout = DrainTimeout 300

-- | Sprint 4.93: the per-request bound every drain @kubectl@ carries.
--
-- It bounds one HTTP request, not one invocation, which is the distinction the
-- wall clock below is derived from. It is appended by 'drainSubprocess' rather
-- than at call sites, so no call can omit it: without one, the outer wall clock
-- is a call's only bound and @kubectl@'s own exact error can never be the
-- reported cause. Two of the nine calls used to pass it and seven did not.
drainKubectlRequestTimeoutSeconds :: Int
drainKubectlRequestTimeoutSeconds = 5

drainKubectlRequestTimeoutArgument :: String
drainKubectlRequestTimeoutArgument =
  "--request-timeout=" ++ show drainKubectlRequestTimeoutSeconds ++ "s"

-- | How many API-group discovery requests @kubectl@ issues before it gives up.
--
-- Measured rather than assumed, by the same Sprint 6.5 measurement the
-- ephemeral client's bound rests on: a discovery-bearing @kubectl get@ against
-- an unreachable endpoint took 10.04 s at a 2-second request timeout, 15.04 s
-- at 3 seconds, and 25.05 s at 5 seconds, emitting exactly five
-- @couldn't get current server API group list@ errors each time.
drainKubectlDiscoveryAttempts :: Int
drainKubectlDiscoveryAttempts = 5

-- | Process spawn and TLS, which the request timeouts do not cover.
drainKubectlWallClockMarginSeconds :: Int
drainKubectlWallClockMarginSeconds = 10

-- | The wall clock one drain @kubectl@ invocation may take.
--
-- Derived, not chosen. A discovery-bearing call can spend
-- 'drainKubectlDiscoveryAttempts' request timeouts on discovery and one more on
-- the resource itself, so the outer bound must exceed that sum or it fires
-- first and replaces @kubectl@'s own exact error with an opaque
-- \"bounded subprocess exceeded its wall-clock timeout\".
drainKubectlWallClockSeconds :: Int
drainKubectlWallClockSeconds =
  (drainKubectlDiscoveryAttempts + 1) * drainKubectlRequestTimeoutSeconds
    + drainKubectlWallClockMarginSeconds

-- | The physical ceilings one drain @kubectl@ runs under.
--
-- The stdout ceiling is load-bearing rather than decorative: the cluster-wide
-- @get pv@ this module runs is its largest output, and it used to be read into
-- a lazy 'String' with no cap at all.
drainKubectlLimits :: BoundedSubprocessLimits
drainKubectlLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 1
    , boundedSubprocessMaximumStdoutBytes = 2 * 1024 * 1024
    , boundedSubprocessMaximumStderrBytes = 128 * 1024
    , boundedSubprocessTimeoutMicros = drainKubectlWallClockSeconds * 1000 * 1000
    }

-- | Why one drain @kubectl@ call produced no answer.
--
-- Sprint 4.93. The two cases used to be one @String@, and the distinction is
-- the one [Lifecycle Reconciliation
-- Doctrine](../../../documents/engineering/lifecycle_reconciliation_doctrine.md)
-- requires: a bounded refusal is __unobservable__ — the API server may or may
-- not have acted, and the drain cannot claim otherwise — while a non-zero exit
-- is the server answering and refusing. Collapsing them made a wedged child
-- indistinguishable from a rejected request, and both became 'DrainFailed',
-- which asserts the cluster was reached.
data DrainCallFailure
  = DrainCallUnobservable !String
  | DrainCallRefused !String
  deriving (Eq, Show)

renderDrainCallFailure :: DrainCallFailure -> String
renderDrainCallFailure failure = case failure of
  DrainCallUnobservable detail -> detail
  DrainCallRefused detail -> detail

-- | Carry one call failure into the drain's own result vocabulary.
drainResultFromCallFailure :: String -> DrainCallFailure -> DrainResult
drainResultFromCallFailure context failure = case failure of
  DrainCallUnobservable detail -> DrainUnobservable (context ++ ": " ++ detail)
  DrainCallRefused detail -> DrainFailed (context ++ ": " ++ detail)

-- | Prefix a call failure's detail without losing which kind it is.
contextualiseCallFailure :: String -> DrainCallFailure -> DrainCallFailure
contextualiseCallFailure context failure = case failure of
  DrainCallUnobservable detail -> DrainCallUnobservable (context ++ ": " ++ detail)
  DrainCallRefused detail -> DrainCallRefused (context ++ ": " ++ detail)

-- | Exact execution target for every kubectl subprocess in one drain.
--
-- The constructor is deliberately private. 'prepareK8sDrainEnv' requires an
-- existing kubeconfig, removes every ambient @KUBECONFIG@ entry, and
-- 'drainKubectlArguments' supplies the sole binding as an explicit kubectl
-- option. A missing local RKE2 kubeconfig therefore cannot fall through to a
-- developer's current context or kubectl's default context.
data K8sDrainEnv = K8sDrainEnv
  { drainEnvironment :: [(String, String)]
  , drainWorkingDirectory :: Maybe FilePath
  , drainKubeconfigPath :: FilePath
  , drainKubectlExecutable :: FilePath
  }
  deriving (Eq, Show)

prepareK8sDrainEnv
  :: FilePath
  -> [(String, String)]
  -> Maybe FilePath
  -> IO (Either String K8sDrainEnv)
prepareK8sDrainEnv = prepareK8sDrainEnvWithKubectl "kubectl"

-- | Variant with an explicit kubectl executable. Production uses
-- 'prepareK8sDrainEnv'; the extra parameter keeps the subprocess boundary
-- testable without changing a process-global @PATH@.
prepareK8sDrainEnvWithKubectl
  :: FilePath
  -> FilePath
  -> [(String, String)]
  -> Maybe FilePath
  -> IO (Either String K8sDrainEnv)
prepareK8sDrainEnvWithKubectl kubectlExecutable kubeconfigPath environment workingDirectory = do
  kubeconfigExists <- doesFileExist kubeconfigPath
  pure $
    if kubeconfigExists
      then
        Right
          K8sDrainEnv
            { drainEnvironment = filter ((/= "KUBECONFIG") . fst) environment
            , drainWorkingDirectory = workingDirectory
            , drainKubeconfigPath = kubeconfigPath
            , drainKubectlExecutable = kubectlExecutable
            }
      else
        Left
          ( "required drain kubeconfig is missing: "
              ++ kubeconfigPath
              ++ ". Refusing to invoke kubectl: ambient KUBECONFIG and the "
              ++ "default context are not authorized fallbacks."
          )

-- | Prefix every invocation with exactly one target binding. Callers provide
-- only the kubectl verb and its arguments; they cannot omit or replace the
-- drain's kubeconfig.
drainKubectlArguments :: K8sDrainEnv -> [String] -> [String]
drainKubectlArguments env arguments =
  ["--kubeconfig", drainKubeconfigPath env] ++ arguments

-- | Outcome of the drain. Encodes the three-outcome ADT documented
-- in @documents/engineering/lifecycle_reconciliation_doctrine.md
-- § 3 layer 1@:
--
--   * 'DrainSucceeded' — cluster was reachable, the targeted K8s
--     resources were deleted, and the bounded poll loop observed
--     them gone before the deadline.
--   * 'DrainSkipped' — independent evidence positively established that the
--     target cluster is absent ('ClusterAbsent'). No delete was attempted; the
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
-- A non-zero kubectl result cannot establish cluster absence. Connection
-- refusal, DNS/routing failure, authentication failure, and a malformed
-- context all describe an unobservable or non-serving control plane. An
-- explicit 'ClusterAbsent' remains in the ADT for callers that acquire
-- independent positive absence evidence, but 'probeCluster' never mints it
-- from a transport error.
data ClusterProbe
  = -- | The API server answered.
    ClusterReachable
  | -- | Positively established absent by evidence independent of a failed
    -- API connection. Carries the evidence that decided it.
    ClusterAbsent !String
  | -- | The probe could not decide. Carries the underlying detail.
    ClusterUnobservable !String
  deriving (Eq, Show)

renderClusterProbe :: ClusterProbe -> String
renderClusterProbe probe = case probe of
  ClusterReachable -> "reachable"
  ClusterAbsent evidence -> "absent (" ++ evidence ++ ")"
  ClusterUnobservable detail -> "unobservable (" ++ detail ++ ")"

-- | Pure fail-closed classifier for the probe subprocess result.
--
-- Sprint 4.93 widened what a 'Failure' can mean. The probe now runs through the
-- bounded runner, so the transport arm covers a child that never started /and/
-- one terminated by its own wall clock; the wording no longer asserts the
-- former. Neither is evidence of absence, which is why both land on
-- 'ClusterUnobservable' rather than on a new constructor.
classifyClusterProbe :: Result ProcessOutput -> ClusterProbe
classifyClusterProbe result = case result of
  Failure err -> ClusterUnobservable ("`kubectl cluster-info` did not complete: " ++ err)
  Success output -> case processExitCode output of
    ExitSuccess -> ClusterReachable
    ExitFailure code ->
      let combined = processStderr output ++ "\n" ++ processStdout output
       in ClusterUnobservable
            ( "control plane is not serving or is not observable: "
                ++ "`kubectl cluster-info` exited with code "
                ++ show code
                ++ ": "
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
-- result through the pure 'classifyClusterProbe'. Every non-zero result is
-- unobservable: neither "nothing is listening" nor "I was refused" proves
-- that the installed cluster is absent.
probeCluster :: K8sDrainEnv -> IO ClusterProbe
probeCluster env =
  classifyClusterProbe . boundedOutcome
    <$> captureSubprocessBounded drainKubectlLimits (drainSubprocess env ["cluster-info"])

-- | Read the exact Kubernetes identity used to bind a remote EKS drain
-- session.  The request always uses this drain environment's explicit
-- kubeconfig and never treats a missing namespace, transport error, or empty
-- response as absence.
observeK8sClusterUid :: K8sDrainEnv -> IO (Either String String)
observeK8sClusterUid env = do
  observed <-
    captureKubectl
      env
      [ "get"
      , "namespace"
      , "kube-system"
      , "-o"
      , "jsonpath={.metadata.uid}"
      ]
  pure $ do
    raw <- either (Left . renderDrainCallFailure) Right observed
    case words raw of
      [uid] -> Right uid
      [] -> Left "Kubernetes identity probe returned an empty namespace UID"
      _ -> Left "Kubernetes identity probe returned more than one namespace UID"

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
        Left failure -> pure (drainResultFromCallFailure "drain delete" failure)
        Right targets -> waitForDrainComplete env targets timeout

newtype DrainTargets = DrainTargets
  { drainTargetPersistentVolumeClaims :: [(String, String)]
  }
  deriving (Eq, Show)

deleteAwsAffectingResources
  :: K8sDrainEnv -> IO (Either DrainCallFailure DrainTargets)
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
    Left failure ->
      pure (Left (contextualiseCallFailure "delete LoadBalancer Services" failure))
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
        Left failure -> pure (Left (contextualiseCallFailure "delete Ingresses" failure))
        Right () -> do
          pvcs <- deleteDeleteReclaimPvcs env
          case pvcs of
            Left failure ->
              pure (Left (contextualiseCallFailure "delete Delete-reclaim PVCs" failure))
            Right bindings -> pure (Right (DrainTargets bindings))

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

deleteDeleteReclaimPvcs
  :: K8sDrainEnv -> IO (Either DrainCallFailure [(String, String)])
deleteDeleteReclaimPvcs env = do
  listResult <- listDeleteReclaimPvcBindings env
  case listResult of
    Left failure -> pure (Left failure)
    Right bindings -> do
      results <- mapM (deletePvc env) bindings
      -- One unobservable delete makes the whole set unobservable: the drain
      -- cannot claim a PVC was refused when it does not know the request
      -- arrived, and it cannot claim the set completed either.
      pure $ case [failure | Left failure <- results] of
        [] -> Right bindings
        failures
          | any isUnobservableCallFailure failures ->
              Left (DrainCallUnobservable (joinCallFailures failures))
          | otherwise -> Left (DrainCallRefused (joinCallFailures failures))

isUnobservableCallFailure :: DrainCallFailure -> Bool
isUnobservableCallFailure failure = case failure of
  DrainCallUnobservable _ -> True
  DrainCallRefused _ -> False

joinCallFailures :: [DrainCallFailure] -> String
joinCallFailures = intercalate "; " . map renderDrainCallFailure

listDeleteReclaimPvcBindings
  :: K8sDrainEnv -> IO (Either DrainCallFailure [(String, String)])
listDeleteReclaimPvcBindings env = do
  result <-
    captureKubectl
      env
      [ "get"
      , "pv"
      , "-o"
      , deleteReclaimPersistentVolumeJsonPath
      ]
  pure $ case result of
    Left failure -> Left (contextualiseCallFailure "list Delete-reclaim PVs" failure)
    Right output -> Right (deleteReclaimPvcBindings output)

deletePvc :: K8sDrainEnv -> (String, String) -> IO (Either DrainCallFailure ())
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

-- | Poll until the targeted resources are gone or the budget is spent.
--
-- Sprint 4.93 replaced a counter with an absolute deadline. The counter was
-- decremented by the sleep interval once per iteration regardless of how long
-- that iteration's @2 + N@ read-backs took, so the stated budget was an
-- iteration count rather than an elapsed-time bound — and with those calls
-- themselves unbounded, an iteration could take arbitrarily long without
-- charging a second against it. The deadline is read from a monotonic clock, so
-- time spent in a call is time spent.
waitForDrainComplete :: K8sDrainEnv -> DrainTargets -> DrainTimeout -> IO DrainResult
waitForDrainComplete env targets timeout = do
  startedAt <- monotonicSeconds
  go startedAt
 where
  pollIntervalSeconds = 10 :: Int

  go :: Word -> IO DrainResult
  go startedAt = do
    survivors <- collectTargetedSurvivors env targets
    case survivors of
      Left failure -> pure (drainResultFromCallFailure "drain read-back" failure)
      Right [] -> pure DrainSucceeded
      Right names -> do
        now <- monotonicSeconds
        if now - startedAt >= fromIntegral (max 0 (drainTimeoutSeconds timeout))
          then pure (DrainTimedOut names)
          else do
            threadDelay (pollIntervalSeconds * 1000000)
            go startedAt

-- | Whole seconds on a monotonic clock, which is what a deadline needs and a
-- wall clock cannot promise.
monotonicSeconds :: IO Word
monotonicSeconds = do
  nanos <- getMonotonicTimeNSec
  pure (fromIntegral (nanos `div` 1_000_000_000))

collectSurvivors :: K8sDrainEnv -> IO (Either DrainCallFailure [String])
collectSurvivors env = do
  bindings <- listDeleteReclaimPvcBindings env
  case bindings of
    Left failure -> pure (Left failure)
    Right targets -> collectTargetedSurvivors env (DrainTargets targets)

-- | Read back every resource class after delete acceptance. Services and
-- Ingresses are queried as complete target classes on each bounded poll. PVCs
-- are queried by the exact namespace/name bindings selected before deletion,
-- so disappearance of their PV rows cannot be mistaken for observed PVC
-- absence.
collectTargetedSurvivors
  :: K8sDrainEnv -> DrainTargets -> IO (Either DrainCallFailure [String])
collectTargetedSurvivors env targets = do
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
    Left failure ->
      pure (Left (contextualiseCallFailure "read back LoadBalancer Services" failure))
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
        Left failure ->
          pure (Left (contextualiseCallFailure "read back Ingresses" failure))
        Right ingressesText -> do
          pvcResults <-
            mapM
              (readBackTargetedPvc env)
              (drainTargetPersistentVolumeClaims targets)
          pure $ case [failure | Left failure <- pvcResults] of
            (failure : _) -> Left failure
            [] ->
              Right
                ( [ "Service/" ++ name | name <- lines loadBalancersText, not (null name)
                  ]
                    ++ [ "Ingress/" ++ name | name <- lines ingressesText, not (null name)
                       ]
                    ++ [ survivor
                       | Right (Just survivor) <- pvcResults
                       ]
                )

readBackTargetedPvc
  :: K8sDrainEnv
  -> (String, String)
  -> IO (Either DrainCallFailure (Maybe String))
readBackTargetedPvc env (namespace, name) = do
  result <-
    captureKubectl
      env
      [ "get"
      , "pvc"
      , "-n"
      , namespace
      , name
      , "--ignore-not-found=true"
      , "-o"
      , "name"
      ]
  pure $ case result of
    Left failure ->
      Left
        ( contextualiseCallFailure
            ("read back targeted PVC " ++ namespace ++ "/" ++ name)
            failure
        )
    -- The module's only absence decision, and it is gated on a successful exit
    -- rather than on the absence of an error. A bounded refusal never reaches
    -- this branch, which is what keeps \"the API server did not answer\" from
    -- reading as \"the PVC is gone\".
    Right output
      | null (words output) -> Right Nothing
      | otherwise -> Right (Just ("PersistentVolumeClaim/" ++ namespace ++ "/" ++ name))

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

-- | The exact subprocess one drain @kubectl@ runs as.
--
-- Sprint 4.93: the per-request bound is appended here, once, so no call site
-- can omit it and no call site can pass it twice.
drainSubprocess :: K8sDrainEnv -> [String] -> Subprocess
drainSubprocess env arguments =
  Subprocess
    { subprocessPath = drainKubectlExecutable env
    , subprocessArguments =
        drainKubectlArguments env (arguments ++ [drainKubectlRequestTimeoutArgument])
    , subprocessEnvironment = Just (drainEnvironment env)
    , subprocessWorkingDirectory = drainWorkingDirectory env
    }

-- | Lift the bounded runner's answer into the 'Result' the pure classifiers
-- already consume, so the classifier tables keep their shape.
boundedOutcome :: Either err ProcessOutput -> Result ProcessOutput
boundedOutcome = either (const (Failure boundedRefusalDetail)) Success

-- | What a transport or wall-clock refusal is called where the exact error is
-- not available to the pure seam.
boundedRefusalDetail :: String
boundedRefusalDetail =
  "the bounded `kubectl` runner returned no process result within "
    ++ show drainKubectlWallClockSeconds
    ++ "s"

-- | Run one drain @kubectl@ for its exit status.
--
-- Sprint 4.93: bounded, and its two failure modes are no longer one @String@.
runKubectl :: K8sDrainEnv -> [String] -> IO (Either DrainCallFailure ())
runKubectl env arguments = fmap void (boundedKubectl env arguments)

-- | Run one drain @kubectl@ for its standard output.
captureKubectl :: K8sDrainEnv -> [String] -> IO (Either DrainCallFailure String)
captureKubectl env arguments =
  fmap (fmap processStdout) (boundedKubectl env arguments)

boundedKubectl
  :: K8sDrainEnv -> [String] -> IO (Either DrainCallFailure ProcessOutput)
boundedKubectl env arguments = do
  result <- captureSubprocessBounded drainKubectlLimits (drainSubprocess env arguments)
  pure $ case result of
    Left err ->
      Left
        ( DrainCallUnobservable
            ( "`kubectl "
                ++ rendered
                ++ "` did not complete: "
                ++ Text.unpack (errorMsg err)
            )
        )
    Right output -> case processExitCode output of
      ExitSuccess -> Right output
      ExitFailure code ->
        Left
          ( DrainCallRefused
              ( "`kubectl "
                  ++ rendered
                  ++ "` exited with code "
                  ++ show code
                  ++ ": "
                  ++ processStderr output
                  ++ processStdout output
              )
          )
 where
  rendered = unwords (subprocessArguments (drainSubprocess env arguments))
