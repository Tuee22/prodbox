{-# LANGUAGE OverloadedStrings #-}

module AwsControlPlaneIsolation (awsControlPlaneIsolationSuite) where

import Data.List (nub)
import Prodbox.Lib.AwsControlPlaneIsolation
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (ObservePublicARecord, ReconcilePublicARecord)
  , mkPublicARecordRef
  , providerIntentResourceKey
  )
import TestSupport

awsControlPlaneIsolationSuite :: SuiteBuilder ()
awsControlPlaneIsolationSuite =
  describe "Sprint 7.33 AWS control-plane isolation and fault parity" $ do
    it "projects one distinct transport for every isolated role" $ do
      validateAwsControlPlaneIsolation canonicalAwsRoleTransports `shouldBe` Right ()
      map awsTransportRole canonicalAwsRoleTransports `shouldBe` [minBound .. maxBound]
      let services = map awsTransportService canonicalAwsRoleTransports
      length services `shouldBe` length (nub services)

    it "keeps gateway transport diagnostic-only" $ do
      roleCapabilities AwsGatewayDiagnostics `shouldBe` [GatewayMeshDiagnostics]
      roleCapabilities AwsGatewayDiagnostics `shouldNotContain` [LifecycleAuthorityOperation]
      roleCapabilities AwsGatewayDiagnostics `shouldNotContain` [RegisteredAwsProviderMutation]

    it "binds lifecycle work only to the retained-home authority client" $
      [ role
      | role <- [minBound .. maxBound]
      , LifecycleAuthorityOperation `elem` roleCapabilities role
      ]
        `shouldBe` [RetainedHomeAuthorityClient]

    it "keeps the Authority external to EKS while every target role is local" $ do
      let authorityLocations =
            [ awsTransportLocation transport
            | transport <- canonicalAwsRoleTransports
            , awsTransportRole transport == RetainedHomeAuthorityClient
            ]
          targetLocations =
            [ awsTransportLocation transport
            | transport <- canonicalAwsRoleTransports
            , awsTransportRole transport /= RetainedHomeAuthorityClient
            ]
      authorityLocations `shouldBe` [RetainedHomeService]
      targetLocations `shouldSatisfy` all (== AwsEksService)

    it "rejects a missing role, duplicate role, and shared Service transport" $ do
      case canonicalAwsRoleTransports of
        first : second : remaining -> do
          validateAwsControlPlaneIsolation (second : remaining)
            `shouldBe` Left (AwsRoleMissing AwsBootstrapBroker)
          validateAwsControlPlaneIsolation (first : canonicalAwsRoleTransports)
            `shouldBe` Left (AwsRoleDuplicated AwsBootstrapBroker)
          let shared = second {awsTransportService = awsTransportService first}
          validateAwsControlPlaneIsolation (first : shared : remaining)
            `shouldBe` Left (AwsServiceTransportShared (awsTransportService first))
        _ -> expectationFailure "canonical AWS role transport registry is incomplete"

    it "derives deterministic run/cluster-scoped EKS IAM names" $ do
      mkAwsEksIamNames "run-42" "eks-a"
        `shouldBe` Right
          AwsEksIamNames
            { awsEksClusterRoleName = "prodbox-run-42-eks-a-cluster-role"
            , awsEksNodeRoleName = "prodbox-run-42-eks-a-node-role"
            , awsEksLoadBalancerControllerRoleName = "prodbox-run-42-eks-a-lbc-role"
            }
      mkAwsEksIamNames "Run" "eks-a" `shouldSatisfy` isLeft

    it "renders explicit run/cluster-scoped names in the EKS provider program" $ do
      program <- readFile "pulumi/aws-eks/Main.yaml"
      program `shouldContain` "iamNamePrefix: prodbox-${stackName}-${clusterName}"
      program `shouldContain` "name: ${iamNamePrefix}-cluster-role"
      program `shouldContain` "name: ${iamNamePrefix}-node-role"
      program `shouldContain` "name: ${iamNamePrefix}-lbc-role"

    it "requires inert registration then UID CAS before controller enablement" $ do
      let inert = ControllerOwnerRegisteredInert descriptor
      enableControllerOwner inert `shouldBe` Left ControllerOwnerWrongPhase
      let uidState = expectRight (registerControllerOwnerUid "uid-1" inert)
      registerControllerOwnerUid "uid-2" uidState `shouldBe` Left ControllerOwnerUidConflict
      let enabled = expectRight (enableControllerOwner uidState)
      registerControllerChildArn "arn:aws:elasticloadbalancing:example" enabled
        `shouldBe` Right
          (ControllerChildArnRegistered descriptor "uid-1" "arn:aws:elasticloadbalancing:example")

    it "makes observed child ARN enrichment idempotent and conflict-fenced" $ do
      let uidRegistered =
            expectRight
              (registerControllerOwnerUid "uid-1" (ControllerOwnerRegisteredInert descriptor))
          enabled = expectRight (enableControllerOwner uidRegistered)
          registered = expectRight (registerControllerChildArn "arn:child:1" enabled)
      registerControllerChildArn "arn:child:1" registered `shouldBe` Right registered
      registerControllerChildArn "arn:child:2" registered `shouldBe` Left ControllerChildArnConflict

    it "registers AWS public-edge DNS as a closed Provider intent family" $ do
      let ref = expectRight (mkPublicARecordRef "ZAWS" "edge.example.test." 60 ["192.0.2.10"])
      providerIntentResourceKey (ObservePublicARecord ref)
        `shouldBe` "public-edge:a:ZAWS:edge.example.test"
      providerIntentResourceKey (ReconcilePublicARecord ref)
        `shouldBe` "public-edge:a:ZAWS:edge.example.test"
      mkPublicARecordRef "ZAWS" "edge.example.test" 60 ["not-an-ip"]
        `shouldSatisfy` isLeft

    it "closes every AWS fault with per-run absence and retained-state readability" $
      map awsFaultDisposition [minBound .. maxBound]
        `shouldSatisfy` all
          ( \disposition ->
              perRunResourcesConvergeAbsent disposition
                && retainedSesRemainsPresent disposition
                && retainedAuthorityRemainsReadable disposition
                && not (gatewayMayAuthorizeLifecycle disposition)
          )

descriptor :: ControllerOwnerDescriptor
descriptor =
  ControllerOwnerDescriptor
    { controllerOwnerAccount = "123456789012"
    , controllerOwnerRegion = "us-east-1"
    , controllerOwnerCluster = "prodbox-eks"
    , controllerOwnerResourceName = "public-edge"
    , controllerOwnerManifestDigest = "sha256:manifest"
    , controllerOwnerTags = [("prodbox.io/cluster", "prodbox-eks")]
    }

isLeft :: Either left right -> Bool
isLeft result = case result of
  Left _ -> True
  Right _ -> False

expectRight :: (Show left) => Either left right -> right
expectRight result = case result of
  Left err -> error (show err)
  Right value -> value
