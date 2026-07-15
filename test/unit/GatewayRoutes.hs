{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 2.34 conformance suite: the compiled gateway route registry.
--
-- Proves the two properties the daemon dispatcher, client, and chart projections
-- rely on: non-overlap (every route has a distinct path) and pattern round-trip
-- (the exact reverse lookup recovers the route), plus the route-class
-- projection and the kubelet-probe smart constructor.
module GatewayRoutes
  ( gatewayRoutesSuite
  )
where

import Data.List (nub)
import Data.Maybe (isNothing, mapMaybe)
import Prodbox.Gateway.Routes
import TestSupport

gatewayRoutesSuite :: SuiteBuilder ()
gatewayRoutesSuite =
  describe "Sprint 2.34 compiled gateway route registry" $ do
    it "enumerates every route via Enum/Bounded" $ do
      length allGatewayRoutes `shouldBe` 20
      mapM_
        (\route -> (route `elem` allGatewayRoutes) `shouldBe` True)
        [RouteHealthz, RouteReadyz, RouteState, RouteTargetSecretCas]

    it "assigns a distinct path to every route (non-overlap)" $ do
      let paths = map routePattern allGatewayRoutes
      length (nub paths) `shouldBe` length paths

    it "round-trips every route through routeForPath" $ do
      mapM_
        (\route -> routeForPath (routePattern route) `shouldBe` Just route)
        allGatewayRoutes

    it "returns Nothing for an unregistered path" $ do
      routeForPath "/v1/does-not-exist" `shouldBe` Nothing
      routeForPath "/v1/secret/acme/eab" `shouldBe` Nothing

    it "pins the kubelet-facing lifecycle paths" $ do
      routePattern RouteHealthz `shouldBe` "/healthz"
      routePattern RouteReadyz `shouldBe` "/readyz"
      routePattern RouteState `shouldBe` "/v1/state"

    describe "route classes" $ do
      it "classifies liveness, readiness, and diagnostics" $ do
        routeClass RouteHealthz `shouldBe` RouteLiveness
        routeClass RouteReadyz `shouldBe` RouteReadiness
        routeClass RouteMetrics `shouldBe` RouteDiagnostic
        routeClass RouteState `shouldBe` RouteDiagnostic
      it "classifies every authority route as RPC" $ do
        let rpcRoutes =
              [ r
              | r <- allGatewayRoutes
              , r `notElem` [RouteHealthz, RouteReadyz, RouteMetrics, RouteState]
              ]
        mapM_ (\r -> routeClass r `shouldBe` RouteRpc) rpcRoutes

    describe "kubelet probe smart constructor" $ do
      it "admits only liveness and readiness routes" $ do
        let probeRoutes = mapMaybe kubeletProbeRoute allGatewayRoutes
        map kubeletProbeRoutePattern probeRoutes `shouldBe` ["/healthz", "/readyz"]
      it "rejects diagnostic and RPC routes" $ do
        isNothing (kubeletProbeRoute RouteState) `shouldBe` True
        isNothing (kubeletProbeRoute RouteMetrics) `shouldBe` True
        isNothing (kubeletProbeRoute RouteBootstrapVaultEnsure) `shouldBe` True
      it "exposes the two probe routes as total constants" $ do
        kubeletProbeRoutePattern healthzProbeRoute `shouldBe` "/healthz"
        kubeletProbeRoutePattern readyzProbeRoute `shouldBe` "/readyz"
        kubeletProbeGatewayRoute readyzProbeRoute `shouldBe` RouteReadyz

    describe "variable-suffix pattern routes" $ do
      it "names the pattern prefixes as constants (not fixed routes)" $ do
        operatorSecretPathPrefix `shouldBe` "/v1/secret/"
        federationChildPathPrefix `shouldBe` "/v1/federation/children/"
        federationChildBootstrapSuffix `shouldBe` "/bootstrap"
