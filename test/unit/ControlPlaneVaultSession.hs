{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneVaultSession
  ( controlPlaneVaultSessionSuite
  )
where

import Data.Either (isLeft, isRight)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticationRegistry
  ( controlPlaneSigningKeyInventory
  , controlPlaneSigningKeyName
  , controlPlaneSigningKeyRefFor
  , credentialProvisionerCompletionVaultRole
  , credentialProvisionerVaultRole
  , harnessControlPlaneVaultRole
  , operatorControlPlaneVaultRole
  )
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal (CallerService))
import Prodbox.ControlPlane.InClusterAuthorityStore
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalCallerTokenError (..)
  , ExternalLifecycleAuthorityCaller (..)
  , ServiceAccountObservationFailure (..)
  , classifyServiceAccountObservation
  , externalCallerServiceAccount
  , externalCallerServiceAccountReadArguments
  , externalCallerTokenAuthorityReached
  , externalCallerTokenAuthorityRefusedAuthorization
  , externalCallerTokenEligibilityArguments
  , externalCallerTokenRequestArguments
  , externalCallerTokenSessionError
  , renderExternalCallerTokenError
  , renderServiceAccountObservationFailure
  , serviceAccountObservationAuthorityReached
  , validateExternalCallerServiceAccountReadBack
  )
import Prodbox.ControlPlane.RetainedAuthentication
  ( controlPlaneAuthorityEpochPath
  , controlPlaneRequestReplayPath
  )
import Prodbox.ControlPlane.Runtime
  ( LifecycleAuthorityCoordinates (..)
  , lifecycleAuthorityRetainedSubmissionCapacity
  , lifecycleAuthoritySubmissionCapacity
  , mkLifecycleAuthorityCoordinates
  )
import Prodbox.ControlPlane.VaultSession
import Prodbox.Lifecycle.CheckpointAuthority
  ( checkpointAuthorityClusterId
  , checkpointAuthorityObjectBucket
  , checkpointAuthorityObjectNamespace
  , checkpointAuthorityVaultKeyspace
  , modelBObjectLogicalName
  )
import Prodbox.Runtime.Role
import Prodbox.Secret.VaultInventory qualified as VaultInventory
import Prodbox.Subprocess (ProcessOutput (..))
import Prodbox.Vault.Client (VaultAddress (..))
import Prodbox.Vault.Reconcile
  ( VaultKubernetesRoleSpec (..)
  , VaultPolicySpec (..)
  , VaultReconcilePlan (..)
  , VaultTransitKeySpec (..)
  , defaultVaultReconcilePlan
  )
import Prodbox.Vault.RoleId
import Prodbox.Vault.Session (VaultSessionError (..))
import System.Exit (ExitCode (..))
import TestSupport

controlPlaneVaultSessionSuite :: SuiteBuilder ()
controlPlaneVaultSessionSuite =
  describe "Sprint 4.50 standing-role cached Vault session config" $ do
    it "accepts exactly the compiled Vault role for every standing runtime" $
      mapM_ assertStandingRoleBinding standingRoleBindings

    it "refuses a role identity borrowed from another standing process" $
      mkControlPlaneVaultConfig
        LifecycleAuthorityRuntime
        "http://vault.vault.svc.cluster.local:8200"
        "kubernetes"
        (vaultRoleIdText VaultRoleProviderWorker)
        "/var/run/secrets/kubernetes.io/serviceaccount/token"
        `shouldHaveLeft` ( ControlPlaneVaultRoleMismatch
                             (vaultRoleIdText VaultRoleLifecycleAuthority)
                             (vaultRoleIdText VaultRoleProviderWorker)
                         )

    it "refuses gateway/bootstrap identities and empty transport coordinates" $ do
      mkControlPlaneVaultConfig
        GatewayRuntime
        "http://vault"
        "kubernetes"
        (vaultRoleIdText VaultRoleGatewayDaemon)
        "/token"
        `shouldHaveLeft` ControlPlaneVaultRoleUnsupported
      mkControlPlaneVaultConfig
        LifecycleAuthorityRuntime
        ""
        "kubernetes"
        (vaultRoleIdText VaultRoleLifecycleAuthority)
        "/token"
        `shouldHaveLeft` ControlPlaneVaultAddressEmpty

    it "reconciles one distinct policy and Kubernetes role for every standing process" $
      mapM_ assertReconciledStandingRole standingRoleBindings

    it "binds custom projected JWT audiences only on exact one-shot roles" $ do
      let roles = vaultReconcileKubernetesRoles defaultVaultReconcilePlan
          audienceOf name =
            vaultKubernetesRoleSpecAudience
              <$> exactlyOneRole name roles
      audienceOf "prodbox-target-secret-worker"
        `shouldBe` Just (Just "prodbox-control-plane")
      audienceOf "prodbox-target-secret-worker-auditor"
        `shouldBe` Just (Just "prodbox-control-plane")
      audienceOf "prodbox-external-material-ingress"
        `shouldBe` Just (Just "prodbox-control-plane")
      audienceOf "prodbox-credential-provisioner-auditor"
        `shouldBe` Just (Just "prodbox-control-plane")
      audienceOf credentialProvisionerVaultRole
        `shouldBe` Just (Just "prodbox-control-plane")
      audienceOf credentialProvisionerCompletionVaultRole
        `shouldBe` Just (Just "prodbox-control-plane")
      audienceOf "prodbox-admin-action-runner"
        `shouldBe` Just (Just "vault")
      audienceOf "prodbox-admin-action-session-auditor"
        `shouldBe` Just (Just "vault")
      audienceOf (vaultRoleIdText VaultRoleLifecycleAuthority)
        `shouldBe` Just Nothing

    it "separates the AWS-admin worker data session from its accessor-free terminal signer" $ do
      let policies = vaultReconcilePolicies defaultVaultReconcilePlan
          documentFor name =
            case filter ((== name) . vaultPolicySpecName) policies of
              [policy] -> Text.unpack (vaultPolicySpecDocument policy)
              other -> error ("expected one policy for " <> show name <> ", got " <> show other)
          workerDocument = documentFor credentialProvisionerVaultRole
          completionDocument = documentFor credentialProvisionerCompletionVaultRole
      workerDocument `shouldContain` "secret/data/control-plane/aws-admin-executions/*"
      workerDocument `shouldNotContain` "transit/sign/prodbox-control-plane-credential-provisioner"
      completionDocument `shouldContain` "transit/sign/prodbox-control-plane-credential-provisioner"
      completionDocument `shouldContain` "secret/data/control-plane/authority-epoch"
      completionDocument `shouldNotContain` "aws-admin-executions"
      completionDocument `shouldNotContain` "auth/token/"

    it "reconciles the closed Ed25519 Transit inventory and exact retained auth paths" $ do
      let transitKeys = vaultReconcileTransitKeys defaultVaultReconcilePlan
          policyNamed name =
            filter
              ((== name) . vaultPolicySpecName)
              (vaultReconcilePolicies defaultVaultReconcilePlan)
          assertRolePolicy (role, vaultRole) =
            case policyNamed (vaultRoleIdText vaultRole) of
              [policy] -> do
                let document = Text.unpack (vaultPolicySpecDocument policy)
                    ownKey =
                      Text.unpack
                        ( controlPlaneSigningKeyName
                            (controlPlaneSigningKeyRefFor (CallerService role))
                        )
                document `shouldContain` ("path \"transit/sign/" ++ ownKey ++ "\"")
                document
                  `shouldContain` ( "path \"secret/data/"
                                      ++ Text.unpack (controlPlaneRequestReplayPath role)
                                      ++ "\""
                                  )
                document
                  `shouldContain` ( "path \"secret/data/"
                                      ++ Text.unpack controlPlaneAuthorityEpochPath
                                      ++ "\""
                                  )
              other -> expectationFailure ("expected one auth policy, got " ++ show other)
      mapM_
        ( \ref ->
            filter
              ((== controlPlaneSigningKeyName ref) . vaultTransitKeySpecName)
              transitKeys
              `shouldBe` [VaultTransitKeySpec (controlPlaneSigningKeyName ref) "ed25519"]
        )
        controlPlaneSigningKeyInventory
      mapM_
        assertRolePolicy
        standingRoleBindings

    it "keeps operator and harness signing roles separate and seeds only the public epoch" $ do
      let roles = vaultReconcileKubernetesRoles defaultVaultReconcilePlan
          policies = vaultReconcilePolicies defaultVaultReconcilePlan
          assertExternal name namespace = do
            case filter ((== name) . vaultKubernetesRoleSpecName) roles of
              [role] ->
                vaultKubernetesRoleSpecNamespaces role `shouldBe` [namespace]
              other ->
                expectationFailure ("expected one external role, got " ++ show other)
            case filter ((== name) . vaultPolicySpecName) policies of
              [policy] -> do
                let document = Text.unpack (vaultPolicySpecDocument policy)
                document `shouldContain` "transit/sign/prodbox-control-plane-"
                document `shouldContain` "secret/data/control-plane/authority-epoch"
                document `shouldNotContain` "request-replay"
                document `shouldNotContain` "*"
              other -> expectationFailure ("expected one external policy, got " ++ show other)
      assertExternal operatorControlPlaneVaultRole "bootstrap-broker"
      assertExternal harnessControlPlaneVaultRole "gateway"
      filter
        ( (== VaultInventory.VaultSecretPath "secret" controlPlaneAuthorityEpochPath)
            . VaultInventory.vaultSecretObjectPath
        )
        (vaultReconcileSecretObjects defaultVaultReconcilePlan)
        `shouldBe` [ VaultInventory.VaultSecretObjectSpec
                       (VaultInventory.VaultSecretPath "secret" controlPlaneAuthorityEpochPath)
                       [ VaultInventory.VaultSecretFieldSpec
                           "epoch"
                           (VaultInventory.VaultSecretStatic "1")
                       ]
                   ]

    it "binds each host caller to an exact non-automounting self-TokenRequest identity" $ do
      let operator = LifecycleAuthorityOperator
          harness = LifecycleAuthorityTestHarness
          expectedSubject namespace name =
            "--as=system:serviceaccount:" ++ namespace ++ ":" ++ name
          assertCaller caller namespace name duration = do
            externalCallerServiceAccount caller `shouldBe` Text.pack name
            externalCallerServiceAccountReadArguments caller
              `shouldBe` [ "get"
                         , "serviceaccount"
                         , name
                         , "--namespace"
                         , namespace
                         , "-o"
                         , "jsonpath={.metadata.namespace}{'\\n'}{.metadata.name}{'\\n'}{.automountServiceAccountToken}{'\\n'}"
                         ]
            externalCallerTokenEligibilityArguments caller
              `shouldBe` [ "auth"
                         , "can-i"
                         , "create"
                         , "serviceaccounts/" ++ name
                         , "--subresource=token"
                         , "--namespace"
                         , namespace
                         , expectedSubject namespace name
                         ]
            externalCallerTokenRequestArguments caller
              `shouldBe` [ "create"
                         , "token"
                         , name
                         , "--namespace"
                         , namespace
                         , "--duration=" ++ duration
                         , expectedSubject namespace name
                         ]
            validateExternalCallerServiceAccountReadBack
              caller
              (namespace ++ "\n" ++ name ++ "\nfalse\n")
              `shouldBe` Right ()
            validateExternalCallerServiceAccountReadBack
              caller
              (namespace ++ "\n" ++ name ++ "\ntrue\n")
              `shouldSatisfy` isLeft
      assertCaller operator "bootstrap-broker" "prodbox-control-plane-operator" "5m"
      assertCaller harness "gateway" "prodbox-control-plane-test-harness" "15m"

    it "Sprint 4.84 classifies each distinguishable ServiceAccount observation cause" $ do
      -- kubectl exits 1 for every one of these, so the exit code alone
      -- carries none of the distinction; the captured stderr does, and it
      -- used to be discarded.
      let caller = LifecycleAuthorityOperator
          failed diagnostic =
            classifyServiceAccountObservation
              caller
              ( Right
                  ProcessOutput
                    { processExitCode = ExitFailure 1
                    , processStdout = ""
                    , processStderr = diagnostic
                    }
              )
          expect diagnostic expected = failed diagnostic `shouldBe` Left expected
      expect
        "Error from server (NotFound): serviceaccounts \"x\" not found"
        ServiceAccountObservationAbsent
      expect
        "Error from server (Forbidden): serviceaccounts \"x\" is forbidden: User \"y\" cannot get resource"
        ( ServiceAccountObservationForbidden
            "Error from server (Forbidden): serviceaccounts \"x\" is forbidden: User \"y\" cannot get resource"
        )
      expect
        "error: You must be logged in to the server (Unauthorized)"
        ( ServiceAccountObservationUnauthenticated
            "error: You must be logged in to the server (Unauthorized)"
        )
      expect
        "error: current-context is not set"
        (ServiceAccountObservationContextUnavailable "error: current-context is not set")
      expect
        "The connection to the server 127.0.0.1:6443 was refused - did you specify the right host or port?"
        ( ServiceAccountObservationApiUnreachable
            "The connection to the server 127.0.0.1:6443 was refused - did you specify the right host or port?"
        )
      -- An unrecognized diagnostic is preserved verbatim with its exit code
      -- rather than rounded to the nearest known cause.
      failed "something nobody has seen before"
        `shouldBe` Left
          (ServiceAccountObservationUnclassified 1 "something nobody has seen before")
      -- A subprocess that never started reached no authority at all.
      classifyServiceAccountObservation caller (Left ("boom" :: String))
        `shouldBe` Left ServiceAccountObservationSubprocessUnavailable

    it "Sprint 4.84 only a reached Kubernetes API may report ServiceAccount absence" $ do
      -- Absence is a fact about cluster contents; the unreached arms are facts
      -- about whether the cluster was observed at all, and must never be
      -- promoted into an absence decision.
      map
        serviceAccountObservationAuthorityReached
        [ ServiceAccountObservationSubprocessUnavailable
        , ServiceAccountObservationApiUnreachable "x"
        , ServiceAccountObservationContextUnavailable "x"
        , ServiceAccountObservationUnclassified 1 "x"
        ]
        `shouldBe` [False, False, False, False]
      map
        serviceAccountObservationAuthorityReached
        [ ServiceAccountObservationUnauthenticated "x"
        , ServiceAccountObservationForbidden "x"
        , ServiceAccountObservationAbsent
        , ServiceAccountObservationIdentityMismatch "x"
        ]
        `shouldBe` [True, True, True, True]

    it "Sprint 4.84 the token failure carries the classification to its caller" $ do
      -- The classifier produced a typed cause and a rendering adapter flattened
      -- it immediately, so the caller received one sentence for every arm. The
      -- typed value now reaches the login path, which decides with it.
      let reached =
            map
              externalCallerTokenAuthorityReached
              [ ExternalCallerServiceAccountUnobservable
                  (ServiceAccountObservationForbidden "x")
              , ExternalCallerTokenEligibilityRefused
              , ExternalCallerTokenRequestRefused
              , ExternalCallerTokenMalformed
              ]
          unreached =
            map
              externalCallerTokenAuthorityReached
              [ ExternalCallerServiceAccountUnobservable
                  (ServiceAccountObservationApiUnreachable "x")
              , ExternalCallerTokenEligibilitySubprocessUnavailable
              , ExternalCallerTokenRequestSubprocessUnavailable
              ]
      reached `shouldBe` [True, True, True, True]
      unreached `shouldBe` [False, False, False]
      -- Refused authorization is strictly narrower than "the API answered": an
      -- absent ServiceAccount and a mismatched read-back are answers, and
      -- neither is a denial.
      map
        externalCallerTokenAuthorityRefusedAuthorization
        [ ExternalCallerServiceAccountUnobservable ServiceAccountObservationAbsent
        , ExternalCallerServiceAccountUnobservable
            (ServiceAccountObservationIdentityMismatch "x")
        , ExternalCallerTokenMalformed
        ]
        `shouldBe` [False, False, False]
      map
        externalCallerTokenAuthorityRefusedAuthorization
        [ ExternalCallerServiceAccountUnobservable
            (ServiceAccountObservationForbidden "x")
        , ExternalCallerServiceAccountUnobservable
            (ServiceAccountObservationUnauthenticated "x")
        , ExternalCallerTokenEligibilityRefused
        , ExternalCallerTokenRequestRefused
        ]
        `shouldBe` [True, True, True, True]

    it "Sprint 4.84 an RBAC denial is not reported as a transient unavailability" $ do
      -- Every arm previously became VaultSessionUnavailable, so a permanent
      -- denial for the presented identity was indistinguishable from a
      -- transport failure and read as "retry later".
      let caller = LifecycleAuthorityOperator
          classOf = sessionErrorClass . externalCallerTokenSessionError caller
      classOf ExternalCallerTokenEligibilityRefused `shouldBe` "forbidden"
      classOf ExternalCallerTokenRequestRefused `shouldBe` "forbidden"
      classOf
        ( ExternalCallerServiceAccountUnobservable
            (ServiceAccountObservationForbidden "x")
        )
        `shouldBe` "forbidden"
      classOf
        ( ExternalCallerServiceAccountUnobservable
            (ServiceAccountObservationApiUnreachable "x")
        )
        `shouldBe` "unavailable"
      classOf
        (ExternalCallerServiceAccountUnobservable ServiceAccountObservationAbsent)
        `shouldBe` "unavailable"
      -- The operator sentence each arm carried is preserved, not replaced.
      renderExternalCallerTokenError
        caller
        ( ExternalCallerServiceAccountUnobservable
            (ServiceAccountObservationForbidden "denied")
        )
        `shouldBe` renderServiceAccountObservationFailure
          caller
          (ServiceAccountObservationForbidden "denied")

    it "Sprint 4.84 a successful exit still requires the exact identity read-back" $ do
      let caller = LifecycleAuthorityOperator
          succeeded stdoutText =
            classifyServiceAccountObservation
              caller
              ( Right
                  ProcessOutput
                    { processExitCode = ExitSuccess
                    , processStdout = stdoutText
                    , processStderr = ""
                    }
              )
      succeeded "bootstrap-broker\nprodbox-control-plane-operator\nfalse\n"
        `shouldBe` Right ()
      succeeded "bootstrap-broker\nprodbox-control-plane-operator\ntrue\n"
        `shouldSatisfy` isLeft

    it "keeps shared Gateway AWS and MinIO-root credentials out of standing-role policies" $ do
      let documents =
            Text.unlines
              [ vaultPolicySpecDocument policy
              | policy <- vaultReconcilePolicies defaultVaultReconcilePlan
              , vaultPolicySpecName policy
                  `elem` fmap (vaultRoleIdText . snd) standingRoleBindings
              ]
      Text.unpack documents `shouldNotContain` ("secret/data/gateway/" <> "gateway/aws")
      Text.unpack documents `shouldNotContain` "secret/data/minio/root"
      Text.unpack documents
        `shouldContain` "secret/data/minio/lifecycle-authority"

    it "gives the Gateway client signing and epoch-read authority without replay ownership" $
      case filter
        ((== "prodbox-gateway") . vaultPolicySpecName)
        (vaultReconcilePolicies defaultVaultReconcilePlan) of
        [policy] -> do
          let document = Text.unpack (vaultPolicySpecDocument policy)
          document
            `shouldContain` "transit/sign/prodbox-control-plane-service-gateway-runtime"
          document `shouldContain` "secret/data/control-plane/authority-epoch"
          document `shouldNotContain` "control-plane/request-replay"
        other -> expectationFailure ("expected one Gateway policy, got " ++ show other)

    it "accepts only a bounded in-cluster authority store coordinate" $ do
      mkInClusterAuthorityStoreConfig
        "prodbox-home"
        defaultInClusterAuthorityEndpoint
        defaultInClusterAuthorityBucket
        `shouldSatisfy` isRight
      mkInClusterAuthorityStoreConfig
        "prodbox home"
        defaultInClusterAuthorityEndpoint
        defaultInClusterAuthorityBucket
        `shouldHaveLeft` InClusterAuthorityClusterIdContainsWhitespace
      mkInClusterAuthorityStoreConfig "prodbox-home" "127.0.0.1:9000" "prodbox-state"
        `shouldHaveLeft` InClusterAuthorityEndpointInvalid "127.0.0.1:9000"

    it "derives the canonical authority and its single retained admission coordinate" $ do
      let storeConfig =
            mustRight
              ( mkInClusterAuthorityStoreConfig
                  "prodbox-home"
                  defaultInClusterAuthorityEndpoint
                  defaultInClusterAuthorityBucket
              )
          coordinates = mustRight (mkLifecycleAuthorityCoordinates storeConfig)
          authority = lifecycleCheckpointAuthority coordinates
      checkpointAuthorityClusterId authority `shouldBe` "prodbox-home"
      checkpointAuthorityObjectBucket authority `shouldBe` defaultInClusterAuthorityBucket
      checkpointAuthorityObjectNamespace authority `shouldBe` "authority"
      checkpointAuthorityVaultKeyspace authority `shouldBe` "secret/lifecycle"
      modelBObjectLogicalName (lifecycleAuthorityAdmissionCoordinate coordinates)
        `shouldBe` "authority/admission"
      modelBObjectLogicalName (lifecycleAuthorityRetainedSesSmtpCoordinate coordinates)
        `shouldBe` "retained-material/custody/ses-smtp-source"
      modelBObjectLogicalName (lifecycleAuthorityRetainedAcmeEabCoordinate coordinates)
        `shouldBe` "retained-material/custody/acme-eab-source"
      lifecycleAuthoritySubmissionCapacity `shouldSatisfy` (> 0)
      lifecycleAuthorityRetainedSubmissionCapacity
        `shouldSatisfy` (>= lifecycleAuthoritySubmissionCapacity)

standingRoleBindings :: [(RuntimeRole, VaultRoleId)]
standingRoleBindings =
  [ (LifecycleAuthorityRuntime, VaultRoleLifecycleAuthority)
  , (ProviderWorkerRuntime, VaultRoleProviderWorker)
  , (AuthorityBackupRuntime, VaultRoleAuthorityBackup)
  , (TlsRetentionRuntime, VaultRoleTlsRetention)
  , (TargetSecretAgentRuntime, VaultRoleTargetSecretAgent)
  ]

assertStandingRoleBinding :: (RuntimeRole, VaultRoleId) -> Expectation
assertStandingRoleBinding (runtimeRole, vaultRole) =
  case mkControlPlaneVaultConfig
    runtimeRole
    "http://vault.vault.svc.cluster.local:8200"
    "kubernetes"
    (vaultRoleIdText vaultRole)
    "/var/run/secrets/kubernetes.io/serviceaccount/token" of
    Left err -> expectationFailure ("expected valid config: " ++ show err)
    Right config -> do
      controlPlaneVaultAddress config
        `shouldBe` VaultAddress "http://vault.vault.svc.cluster.local:8200"
      controlPlaneVaultRole config `shouldBe` vaultRoleIdText vaultRole

assertReconciledStandingRole :: (RuntimeRole, VaultRoleId) -> Expectation
assertReconciledStandingRole (_, vaultRole) = do
  let roleName = vaultRoleIdText vaultRole
      matchingRoles =
        filter
          ((== roleName) . vaultKubernetesRoleSpecName)
          (vaultReconcileKubernetesRoles defaultVaultReconcilePlan)
      matchingPolicies =
        filter
          ((== roleName) . vaultPolicySpecName)
          (vaultReconcilePolicies defaultVaultReconcilePlan)
  case (matchingRoles, matchingPolicies) of
    ([role], [_]) -> do
      vaultKubernetesRoleSpecServiceAccounts role `shouldBe` [roleName]
      vaultKubernetesRoleSpecNamespaces role `shouldBe` ["gateway"]
      vaultKubernetesRoleSpecPolicies role `shouldBe` [roleName]
    other ->
      expectationFailure
        ("expected one standing role and policy, got " ++ show other)

exactlyOneRole
  :: Text.Text -> [VaultKubernetesRoleSpec] -> Maybe VaultKubernetesRoleSpec
exactlyOneRole name roles = case filter ((== name) . vaultKubernetesRoleSpecName) roles of
  [role] -> Just role
  _ -> Nothing

shouldHaveLeft
  :: (Eq err, Show err)
  => Either err value
  -> err
  -> Expectation
shouldHaveLeft result expected = case result of
  Left actual -> actual `shouldBe` expected
  Right _ -> expectationFailure "expected Left, got Right"

mustRight :: (Show err) => Either err value -> value
mustRight = either (error . show) id

-- | The session-error class, as a name rather than a constructor, so a case
-- reads as the distinction it is testing.
sessionErrorClass :: VaultSessionError -> String
sessionErrorClass err = case err of
  VaultSessionSealed _ -> "sealed"
  VaultSessionForbidden _ -> "forbidden"
  VaultSessionUnavailable _ -> "unavailable"
