module ControlPlaneRoute
  ( controlPlaneRouteSuite
  )
where

import Data.List (nub)
import Prodbox.ControlPlane.Route
import Prodbox.Runtime.Role
  ( RuntimeRole
      ( AuthorityBackupRuntime
      , LifecycleAuthorityRuntime
      , ProviderWorkerRuntime
      , TargetSecretAgentRuntime
      , TlsRetentionRuntime
      )
  )
import TestSupport

controlPlaneRouteSuite :: SuiteBuilder ()
controlPlaneRouteSuite =
  describe "Sprint 4.50 closed role-specific control-plane routes" $ do
    it "assigns every route exactly one unique method/path pair" $ do
      let pairs =
            fmap
              (\route -> (controlPlaneRouteMethod route, controlPlaneRoutePath route))
              allControlPlaneRoutes
      length (nub pairs) `shouldBe` length allControlPlaneRoutes

    it "round-trips every route only through its owning role" $
      mapM_
        ( \route -> do
            decodeRoleRoute
              (controlPlaneRouteRole route)
              (controlPlaneRouteMethod route)
              (controlPlaneRoutePath route)
              `shouldBe` Just route
            mapM_
              ( \otherRole ->
                  decodeRoleRoute
                    otherRole
                    (controlPlaneRouteMethod route)
                    (controlPlaneRoutePath route)
                    `shouldBe` Nothing
              )
              (filter (/= controlPlaneRouteRole route) standingRoles)
        )
        allControlPlaneRoutes

    it "gives each standing role a non-empty closed route family" $
      mapM_
        (\role -> routesForRole role `shouldSatisfy` (not . null))
        standingRoles

    it "contains no generic object-store or Vault route" $
      mapM_
        ( \route -> do
            controlPlaneRoutePath route `shouldNotContain` "object-store"
            controlPlaneRoutePath route `shouldNotContain` "vault"
        )
        allControlPlaneRoutes

standingRoles :: [RuntimeRole]
standingRoles =
  [ LifecycleAuthorityRuntime
  , ProviderWorkerRuntime
  , AuthorityBackupRuntime
  , TlsRetentionRuntime
  , TargetSecretAgentRuntime
  ]
