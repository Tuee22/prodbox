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
  )
where

import Control.Monad (foldM, unless)
import Data.List (elemIndex, nub)
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

runAnchoredStepOrder
  :: (step -> ReconcileStepAnchor)
  -> (step -> IO ExitCode)
  -> (ComponentId -> IO ExitCode)
  -> [step]
  -> IO ExitCode
runAnchoredStepOrder stepAnchor runStep requireReadiness =
  foldM runAnchoredStep ExitSuccess
 where
  runAnchoredStep previous step =
    case previous of
      ExitFailure _ -> pure previous
      ExitSuccess -> do
        stepExit <- runStep step
        case stepExit of
          ExitFailure _ -> pure stepExit
          ExitSuccess ->
            case stepAnchor step of
              ComponentReadiness component -> requireReadiness component
              HostPrepBefore _ -> pure ExitSuccess
              ComponentMutation _ -> pure ExitSuccess
              HostPostAfter _ -> pure ExitSuccess
              TransitionFor _ -> pure ExitSuccess
              EdgeOnly -> pure ExitSuccess

phaseRank :: ReconcilePhase -> Int
phaseRank phase =
  case phase of
    PhaseBootstrap -> 0
    PhaseTransition -> 1
    PhaseSteady -> 2
    PhaseEdge -> 3

allComponentIds :: [ComponentId]
allComponentIds = [minBound .. maxBound]
