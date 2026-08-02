-- | Sprint 2.34: the compiled gateway route registry.
--
-- This is the single place any gateway daemon HTTP path string exists. The
-- daemon dispatcher, the gateway client's URL construction, and the chart
-- kubelet-probe rendering are all projections of this one registry — closing
-- the @F-READY@ / hand-authored-literal seam of counterexample
-- @LCPC-2026-07-11@, where the same path was written by hand in the daemon, the
-- client, and the chart independently and could drift.
--
-- 'GatewayRoute' is a closed 'Enum'/'Bounded' ADT of the fixed-string routes;
-- 'routePattern' is the one function that maps a route to its path, and
-- 'routeClass' classifies it as liveness, readiness, or diagnostic. The
-- daemon dispatcher is a total @case@ over the registry (a registered route with
-- no handler is a @-Werror@ compile error), and 'routeForPath' is the exact
-- reverse lookup. A kubelet probe can
-- only be built from a liveness or readiness route ('kubeletProbeRoute').
module Prodbox.Gateway.Routes
  ( GatewayRoute (..)
  , RouteClass (..)
  , allGatewayRoutes
  , routePattern
  , routeClass
  , routeForPath
  , KubeletProbeRoute
  , kubeletProbeRoute
  , kubeletProbeRoutePattern
  , kubeletProbeGatewayRoute
  , healthzProbeRoute
  , readyzProbeRoute
  )
where

import Data.List (find)

-- | The closed set of fixed-string gateway daemon routes.
data GatewayRoute
  = -- Kubelet-facing lifecycle probes.
    RouteHealthz
  | RouteReadyz
  | -- Operator diagnostics (never a kubelet probe).
    RouteMetrics
  | RouteState
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The kubelet/operator role of a route.
data RouteClass
  = RouteLiveness
  | RouteReadiness
  | RouteDiagnostic
  deriving (Eq, Show)

-- | Every registered route.
allGatewayRoutes :: [GatewayRoute]
allGatewayRoutes = [minBound .. maxBound]

-- | The one place any fixed daemon path string exists.
routePattern :: GatewayRoute -> String
routePattern route = case route of
  RouteHealthz -> "/healthz"
  RouteReadyz -> "/readyz"
  RouteMetrics -> "/metrics"
  RouteState -> "/v1/state"

-- | The kubelet/operator role of a route.
routeClass :: GatewayRoute -> RouteClass
routeClass route = case route of
  RouteHealthz -> RouteLiveness
  RouteReadyz -> RouteReadiness
  RouteMetrics -> RouteDiagnostic
  RouteState -> RouteDiagnostic

-- | Exact reverse lookup of a fixed-string path to its route. Total: an
-- unregistered path is 'Nothing' and the caller returns 404.
routeForPath :: String -> Maybe GatewayRoute
routeForPath path = find ((== path) . routePattern) allGatewayRoutes

-- | A route proven to be a kubelet probe (liveness or readiness). A probe cannot
-- be built from a diagnostic route.
newtype KubeletProbeRoute = KubeletProbeRoute GatewayRoute
  deriving (Eq, Show)

-- | Smart constructor: only a liveness or readiness route yields a probe route;
-- diagnostics cannot become kubelet probes.
kubeletProbeRoute :: GatewayRoute -> Maybe KubeletProbeRoute
kubeletProbeRoute route = case routeClass route of
  RouteLiveness -> Just (KubeletProbeRoute route)
  RouteReadiness -> Just (KubeletProbeRoute route)
  _ -> Nothing

-- | The two valid kubelet probe routes as total constants (no @Maybe@, no
-- partial constructor): the liveness and readiness routes are the only probe
-- routes, and these are the sanctioned way to name them.
healthzProbeRoute :: KubeletProbeRoute
healthzProbeRoute = KubeletProbeRoute RouteHealthz

readyzProbeRoute :: KubeletProbeRoute
readyzProbeRoute = KubeletProbeRoute RouteReadyz

kubeletProbeRoutePattern :: KubeletProbeRoute -> String
kubeletProbeRoutePattern (KubeletProbeRoute route) = routePattern route

-- | The underlying 'GatewayRoute' of a kubelet probe route.
kubeletProbeGatewayRoute :: KubeletProbeRoute -> GatewayRoute
kubeletProbeGatewayRoute (KubeletProbeRoute route) = route
