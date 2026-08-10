-- | Substrate-neutral compilation and execution of graph-projected reconcile
-- steps. Component and phase identities are closed ADTs; each substrate owns
-- its step inventory and production readiness adapters.
module Prodbox.Lifecycle.AnchoredReconcile
  ( AnchoredOrderSpec (..)
  , ReconcilePhase (..)
  , ReconcileStepAnchor (..)
  , anchorComponent
  , anchoredOrderRespectsGraph
  , compileAnchoredOrder
  , runAnchoredStepOrder
  , runFirstAnchoredStepOrder
  )
where

import Control.Monad (foldM, unless)
import Data.List (elemIndex, nub)
import Numeric.Natural (Natural)
import Prodbox.Config.ComponentGraph
  ( ComponentDag
  , ComponentId
  , ComponentNode
  , componentDagEdges
  , componentIdText
  , componentReconcileOrder
  , renderComponentGraphError
  , validateComponentGraph
  )
import Prodbox.Lifecycle.DependencyAdmission
  ( AdmissionRefusal (AdmissionExpired)
  , AdmissionSet
  , DependencyAdmission
  , MutationAdmission
  , admitComponentMutation
  , recordAdmission
  )

-- Sprint 4.64: this module is the reconcile executor and therefore the one
-- place a run legitimately begins with no admissions. It is on the
-- @dependencyAdmissionInternalSourceViolations@ allowlist for exactly that
-- reason, and 'noAdmissions' is reachable from nowhere else under @src/@.
import Prodbox.Lifecycle.DependencyAdmission.Internal (noAdmissions)
import System.Exit (ExitCode (..))

data ReconcilePhase
  = PhaseBootstrap
  | PhaseTransition
  | PhaseSteady
  | PhaseEdge
  deriving (Eq, Show)

data ReconcileStepAnchor
  = HostPrepBefore ComponentId
  | ComponentMutation ComponentId
  | ComponentReadiness ComponentId
  | HostPostAfter ComponentId
  | TransitionFor ComponentId
  | EdgeOnly
  deriving (Eq, Show)

anchorComponent :: ReconcileStepAnchor -> Maybe ComponentId
anchorComponent anchor =
  case anchor of
    HostPrepBefore component -> Just component
    ComponentMutation component -> Just component
    ComponentReadiness component -> Just component
    HostPostAfter component -> Just component
    TransitionFor component -> Just component
    EdgeOnly -> Nothing

data AnchoredOrderSpec step = AnchoredOrderSpec
  { anchoredSurfaceName :: String
  , anchoredAllSteps :: [step]
  , anchoredRequiredComponents :: [ComponentId]
  , anchoredStepsForComponent :: ComponentId -> [step]
  , anchoredTailSteps :: [step]
  , anchoredStepAnchor :: step -> ReconcileStepAnchor
  , anchoredStepPhase :: step -> ReconcilePhase
  , anchoredStepToken :: step -> String
  }

compileAnchoredOrder
  :: (Eq step, Show step)
  => AnchoredOrderSpec step
  -> [ComponentNode]
  -> Either String (ComponentDag, [step])
compileAnchoredOrder spec graph = do
  dag <-
    case validateComponentGraph graph of
      Left err -> Left (renderComponentGraphError err)
      Right value -> Right value
  let order =
        concatMap (anchoredStepsForComponent spec) (componentReconcileOrder dag)
          ++ anchoredTailSteps spec
  validateInventory spec order
  validateRequiredComponents spec
  anchoredOrderRespectsGraph spec dag order
  validatePhaseMonotonic spec order
  validateReadinessBarriers spec dag order
  pure (dag, order)

validateInventory
  :: (Eq step, Show step) => AnchoredOrderSpec step -> [step] -> Either String ()
validateInventory spec order = do
  let expected = anchoredAllSteps spec
      missing = filter (`notElem` order) expected
      duplicated = filter (appearsMoreThanOnce order) (nub order)
      mappedSteps =
        [ (component, step)
        | component <- componentReconcileOrderUnsafe
        , step <- anchoredStepsForComponent spec component
        ]
      misanchored =
        [ (component, step, anchoredStepAnchor spec step)
        | (component, step) <- mappedSteps
        , anchorComponent (anchoredStepAnchor spec step) /= Just component
        ]
  unless
    (null missing)
    (Left (anchoredSurfaceName spec ++ " step mapping is missing: " ++ show missing))
  unless
    (null duplicated)
    (Left (anchoredSurfaceName spec ++ " step mapping duplicates: " ++ show duplicated))
  unless
    (null misanchored)
    ( Left
        ( anchoredSurfaceName spec
            ++ " step anchors disagree with stepsForComponent: "
            ++ show misanchored
        )
    )
  unless
    (all ((== EdgeOnly) . anchoredStepAnchor spec) (anchoredTailSteps spec))
    (Left (anchoredSurfaceName spec ++ " edge tail contains a non-EdgeOnly step."))
 where
  appearsMoreThanOnce values value = length (filter (== value) values) > 1
  componentReconcileOrderUnsafe = anchoredRequiredComponents spec ++ optionalComponents
  optionalComponents =
    [ component
    | component <- allComponentIds
    , component `notElem` anchoredRequiredComponents spec
    ]

validateRequiredComponents :: AnchoredOrderSpec step -> Either String ()
validateRequiredComponents spec =
  case filter (null . anchoredStepsForComponent spec) (anchoredRequiredComponents spec) of
    [] -> Right ()
    missing ->
      Left
        ( anchoredSurfaceName spec
            ++ " required component mapping is empty: "
            ++ show (map componentIdText missing)
        )

anchoredOrderRespectsGraph
  :: (Eq step)
  => AnchoredOrderSpec step
  -> ComponentDag
  -> [step]
  -> Either String ()
anchoredOrderRespectsGraph spec dag order =
  mapM_ checkEdge (componentDagEdges dag)
 where
  firstIndexFor component =
    elemIndex True (map ((== Just component) . anchorComponent . anchoredStepAnchor spec) order)
  lastIndexFor component =
    fmap
      (\reverseIndex -> length order - reverseIndex - 1)
      ( elemIndex
          True
          (map ((== Just component) . anchorComponent . anchoredStepAnchor spec) (reverse order))
      )
  checkEdge (consumer, dependency) =
    case (firstIndexFor consumer, lastIndexFor dependency) of
      (Just consumerIndex, Just dependencyIndex)
        | dependencyIndex >= consumerIndex ->
            Left
              ( anchoredSurfaceName spec
                  ++ " step order violates component graph edge "
                  ++ componentIdText consumer
                  ++ " -> "
                  ++ componentIdText dependency
                  ++ ": every dependency step must precede its consumer."
              )
      _ -> Right ()

validatePhaseMonotonic
  :: AnchoredOrderSpec step -> [step] -> Either String ()
validatePhaseMonotonic spec order =
  case firstPhaseRegression order of
    Nothing -> Right ()
    Just (earlier, later) ->
      Left
        ( anchoredSurfaceName spec
            ++ " graph projects a phase regression from "
            ++ show (anchoredStepPhase spec earlier)
            ++ " step `"
            ++ anchoredStepToken spec earlier
            ++ "` to "
            ++ show (anchoredStepPhase spec later)
            ++ " step `"
            ++ anchoredStepToken spec later
            ++ "`."
        )
 where
  firstPhaseRegression steps =
    case steps of
      first : second : remaining
        | phaseRank (anchoredStepPhase spec first) > phaseRank (anchoredStepPhase spec second) ->
            Just (first, second)
        | otherwise -> firstPhaseRegression (second : remaining)
      _ -> Nothing

validateReadinessBarriers
  :: (Show step) => AnchoredOrderSpec step -> ComponentDag -> [step] -> Either String ()
validateReadinessBarriers spec dag order =
  mapM_ validateComponent (componentReconcileOrder dag)
 where
  validateComponent component =
    case reverse (anchoredStepsForComponent spec component) of
      [] -> Right ()
      finalStep : _ ->
        case anchoredStepAnchor spec finalStep of
          ComponentReadiness anchoredComponent
            | anchoredComponent == component -> Right ()
          anchor ->
            Left
              ( anchoredSurfaceName spec
                  ++ " component `"
                  ++ componentIdText component
                  ++ "` must end at a production readiness barrier, but final step `"
                  ++ anchoredStepToken spec finalStep
                  ++ "` has anchor "
                  ++ show anchor
                  ++ ". Compiled order: "
                  ++ show order
              )

-- | Sprint 4.56: the executor threads the admissions the readiness barrier
-- mints, and a step anchored at 'ComponentMutation' is invoked through a
-- separate callback that __requires__ a 'MutationAdmission'. A mutation with no
-- admission is therefore not expressible, rather than merely discouraged.
--
-- Two behaviours are worth stating because they are decisions, not accidents:
--
--   * __An expired admission re-observes once before it refuses.__ A hard
--     refusal would fail the first home @cluster reconcile@ outright: admissions
--     cannot survive a reconcile phase boundary, which crosses federated Vault
--     unseal and a settings reload. The point of the sprint is to narrow the
--     observe-to-act window, not to fail the run — so an expiry re-observes the
--     dependency and refuses only if the fresh observation also fails.
--   * __This narrows the window; it does not make the pair atomic.__ Only a
--     fence does that, and that is Sprint @3.31@'s and the cardinality work's
--     surface.
runAnchoredStepOrder
  :: ComponentDag
  -> IO Natural
  -- ^ The reconcile clock, in microseconds.
  -> (step -> ReconcileStepAnchor)
  -> (MutationAdmission -> step -> IO ExitCode)
  -- ^ A step anchored at 'ComponentMutation'. Cannot be invoked without a proof.
  -> (step -> IO ExitCode)
  -- ^ Every other step.
  -> (ComponentId -> IO (Either ExitCode DependencyAdmission))
  -> AdmissionSet
  -- ^ Sprint 4.61: admissions carried in from earlier phases of the same run.
  --
  -- A reconcile runs its phases as separate calls, and this used to start each
  -- one at 'noAdmissions'. A component whose readiness step is anchored in an
  -- earlier phase than its dependant's mutation step was therefore refused
  -- unconditionally — @never observed ready in this run@ was reported of a
  -- component observed ready earlier in that same run. Threading the set makes
  -- "this run" mean the run rather than the phase. An admission that has aged
  -- out across the boundary is not silently trusted: it expires and is
  -- re-observed, which is the behaviour the age bound already specified.
  -> [step]
  -> IO (Either AdmissionRefusal (ExitCode, AdmissionSet))
  -- ^ Sprint 5.31: a refusal leaves as itself, not as an exit code.
  --
  -- This used to end @refuse _ = ExitFailure 1@ — the refusal discarded with a
  -- wildcard, on a path that emitted nothing, so a refused reconcile exited 1
  -- having said no word about why. That is the conversion of
  -- [chaos_hardening_doctrine.md § 23](../../../documents/engineering/chaos_hardening_doctrine.md)
  -- at the step boundary: 'renderAdmissionRefusal' already existed and was
  -- already exported — the crossing simply did not use it. @ExitCode@ carries
  -- one bit and has no room for a reason, so lowering into it here can only
  -- destroy one.
  --
  -- Returning the refusal moves the lowering to the caller, where a reason can
  -- be rendered, and makes the silent version unrepresentable rather than
  -- merely absent: there is no longer an @ExitCode@ to return in its place.
  -- | Begin a reconcile run: 'runAnchoredStepOrder' with the empty admission set
  -- supplied here rather than named by the caller.
  --
  -- Sprint @4.64@. Sprint @4.61@ fixed the admission reset and left the threading
  -- correct-by-convention: @noAdmissions@ was exported, so any phase call site
  -- could pass an empty set and silently discard everything the run had observed.
  -- The residual is closed by removing the choice rather than by policing it —
  -- @noAdmissions@ is now package-internal, this is the only entry point that
  -- starts empty, and every later phase must be handed a value that only an
  -- earlier phase could have returned.
  --
  -- __The bound, stated rather than implied.__ This makes an accidental reset a
  -- compile error and a deliberate one a loudly-named function call. It does not
  -- prevent a caller from invoking /this/ function twice in one reconcile; what
  -- it removes is the innocuous-looking way to do it. A surface with two "first"
  -- phases is visible in review as a second @runFirstAnchoredStepOrder@, which
  -- @noAdmissions@ at a phase boundary never was.
runFirstAnchoredStepOrder
  :: ComponentDag
  -> IO Natural
  -> (step -> ReconcileStepAnchor)
  -> (MutationAdmission -> step -> IO ExitCode)
  -> (step -> IO ExitCode)
  -> (ComponentId -> IO (Either ExitCode DependencyAdmission))
  -> [step]
  -> IO (Either AdmissionRefusal (ExitCode, AdmissionSet))
runFirstAnchoredStepOrder dag clock stepAnchor runMutation runStep requireReadiness =
  runAnchoredStepOrder dag clock stepAnchor runMutation runStep requireReadiness noAdmissions
runAnchoredStepOrder dag clock stepAnchor runMutation runStep requireReadiness carried steps = do
  outcome <- foldM runAnchoredStep (Right ExitSuccess, carried) steps
  pure $ case outcome of
    (Left refusal, _) -> Left refusal
    (Right exitCode, admissions) -> Right (exitCode, admissions)
 where
  runAnchoredStep (previous, admissions) step =
    case previous of
      Left _ -> pure (previous, admissions)
      Right (ExitFailure _) -> pure (previous, admissions)
      Right ExitSuccess -> case stepAnchor step of
        ComponentMutation component -> do
          admitted <- admitMutation component admissions
          case admitted of
            Left refused -> pure (refused, admissions)
            Right (admission, refreshed) -> do
              stepExit <- runMutation admission step
              pure (Right stepExit, refreshed)
        anchor -> do
          stepExit <- runStep step
          case stepExit of
            ExitFailure _ -> pure (Right stepExit, admissions)
            ExitSuccess -> case anchor of
              ComponentReadiness component -> do
                observed <- requireReadiness component
                pure $ case observed of
                  Left exitCode -> (Right exitCode, admissions)
                  Right admission -> (Right ExitSuccess, recordAdmission admission admissions)
              -- Every remaining anchor is non-mutating; the mutation anchor is
              -- handled above, before the step runs at all.
              _ -> pure (Right ExitSuccess, admissions)

  admitMutation component admissions = do
    now <- clock
    case admitComponentMutation dag now component admissions of
      Right admission -> pure (Right (admission, admissions))
      Left refusal -> case refusal of
        AdmissionExpired _ dependency _ _ -> do
          -- Re-observe the one dependency whose admission aged out, then decide
          -- on the fresh evidence.
          observed <- requireReadiness dependency
          case observed of
            Left exitCode -> pure (Left (Right exitCode))
            Right fresh -> do
              let refreshed = recordAdmission fresh admissions
              retryNow <- clock
              case admitComponentMutation dag retryNow component refreshed of
                Right admission -> pure (Right (admission, refreshed))
                Left retryRefusal -> pure (Left (Left retryRefusal))
        _ -> pure (Left (Left refusal))

phaseRank :: ReconcilePhase -> Int
phaseRank phase =
  case phase of
    PhaseBootstrap -> 0
    PhaseTransition -> 1
    PhaseSteady -> 2
    PhaseEdge -> 3

allComponentIds :: [ComponentId]
allComponentIds = [minBound .. maxBound]
