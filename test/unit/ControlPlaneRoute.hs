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

    it "owns the closed projection-import command only at the Lifecycle Authority" $ do
      decodeRoleRoute
        LifecycleAuthorityRuntime
        ControlPlanePost
        "/v1/migration/import"
        `shouldBe` Just LifecycleProjectionImport
      mapM_
        ( \otherRole ->
            decodeRoleRoute
              otherRole
              ControlPlanePost
              "/v1/migration/import"
              `shouldBe` Nothing
        )
        (filter (/= LifecycleAuthorityRuntime) standingRoles)

    it "owns the AWS stack-reader boundary only at the Lifecycle Authority" $ do
      controlPlaneRouteMethod LifecycleAwsStackReader `shouldBe` ControlPlanePost
      controlPlaneRoutePath LifecycleAwsStackReader
        `shouldBe` "/v1/authority/aws-stack-reader"
      decodeRoleRoute
        LifecycleAuthorityRuntime
        ControlPlanePost
        "/v1/authority/aws-stack-reader"
        `shouldBe` Just LifecycleAwsStackReader
      mapM_
        ( \otherRole ->
            decodeRoleRoute
              otherRole
              ControlPlanePost
              "/v1/authority/aws-stack-reader"
              `shouldBe` Nothing
        )
        (filter (/= LifecycleAuthorityRuntime) standingRoles)

    it "owns the two distinct lifecycle-input boundaries only at the Lifecycle Authority" $ do
      let expected =
            [
              ( LifecycleAwsStackCreationBinding
              , "/v1/authority/aws-stack-creation-binding"
              )
            ,
              ( LifecycleOwnershipManifest
              , "/v1/authority/ownership-manifest"
              )
            ]
      mapM_
        ( \(route, path) -> do
            controlPlaneRouteMethod route `shouldBe` ControlPlanePost
            controlPlaneRoutePath route `shouldBe` path
            decodeRoleRoute LifecycleAuthorityRuntime ControlPlanePost path
              `shouldBe` Just route
            mapM_
              ( \otherRole ->
                  decodeRoleRoute otherRole ControlPlanePost path
                    `shouldBe` Nothing
              )
              (filter (/= LifecycleAuthorityRuntime) standingRoles)
        )
        expected

    it "freezes additive authentication route codes 54 and 55" $ do
      source <- readFile "src/Prodbox/ControlPlane/RequestAuthentication.hs"
      source
        `shouldContain` "LifecycleAwsStackCreationBinding -> 54"
      source
        `shouldContain` "LifecycleOwnershipManifest -> 55"
      source
        `shouldContain` "54 -> Just LifecycleAwsStackCreationBinding"
      source
        `shouldContain` "55 -> Just LifecycleOwnershipManifest"

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
