{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module CredentialProvisioner (credentialProvisionerSuite) where

import Control.Monad (forM_)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Network.HTTP.Types.URI (urlDecode, urlEncode)
import Options.Applicative
  ( ParserResult (..)
  , defaultPrefs
  , execParserPure
  )
import Prodbox.Aws.Native.Wire
  ( DispatchPhase (PossiblySent)
  , HttpOutcome (HttpOutcome)
  , SignedHttpRequest (shrBody, shrMethod)
  , TransportFailure (TransportFailure)
  )
import Prodbox.CLI.Command
  ( CommandRequest (..)
  , CredentialProvisionerCommand (..)
  , NativeCommand (..)
  , PlanOptions (..)
  )
import Prodbox.CLI.Parser (Options (..), parserInfo)
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity (..)
  , TargetSecretId (..)
  , targetSecretIdVaultLogicalPath
  , targetSecretPayloadToVaultFields
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( GenesisPlan (..)
  , TargetAgentGenerationReceipt (..)
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminRetainedCustody
  ( sesSmtpPayloadForIdentity
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminWorker
  ( AwsAdminWorkerMode (AwsAdminNormalMode)
  , AwsAdminWorkerOptions (..)
  )
import Prodbox.Lifecycle.CredentialProvisioner.Execution
import Prodbox.Lifecycle.CredentialProvisioner.ExternalMaterialWorker
  ( ExternalMaterialWorkerError (..)
  , ExternalMaterialWorkerOptions (..)
  , finishExternalMaterialWorkerSession
  )
import Prodbox.Lifecycle.CredentialProvisioner.FirstReconcileJournal
import Prodbox.Lifecycle.CredentialProvisioner.Kubernetes
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
import Prodbox.Lifecycle.CredentialProvisioner.ProductionIam
import Prodbox.Lifecycle.CredentialProvisioner.TargetMaterial
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , mkCredentialGeneration
  )
import Prodbox.Native
  ( awsAdminCredentialProvisionerRunPlan
  , credentialProvisionerRunPlan
  )
import Prodbox.Settings qualified as Settings
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import TestSupport

credentialProvisionerSuite :: SuiteBuilder ()
credentialProvisionerSuite =
  describe "Sprint 4.50 Credential Provisioner" $ do
    it
      "registers one distinct deterministic identity, policy, target, and two-key bound per AWS credential family"
      $ do
        let descriptors = managedAwsCredentialInventory
            principals = awsCredentialDescriptorPrincipal <$> descriptors
            policies = awsCredentialDescriptorPolicy <$> descriptors
            targets = awsCredentialDescriptorTarget <$> descriptors
        length descriptors `shouldBe` length ([minBound .. maxBound] :: [AwsCredentialClass])
        length principals `shouldBe` length (nub principals)
        length policies `shouldBe` length (nub policies)
        length targets `shouldBe` length (nub targets)
        (awsCredentialDescriptorMaximumAccessKeys <$> descriptors)
          `shouldBe` replicate (length descriptors) 2

    it "Sprint 4.85 admits exactly one of twelve revocation observation pairs" $ do
      -- The production revoke path used to take the revoke response itself as
      -- evidence that the target generation was gone, so an applied-but-
      -- unconfirmed revoke and a confirmed one were the same value. Both paths
      -- now decide through this one function, and it mints a read-back only
      -- from two independent absences.
      let generation = must (mkCredentialGeneration 3)
          table =
            credentialRevocationReadBackDecisionTable
              LifecycleProviderTarget
              generation
      length table `shouldBe` 12
      [pair | (pair, minted) <- table, minted]
        `shouldBe` [(RevokedTargetAbsent, RevokedIdentityAbsent)]
      canonicalTargetRevocationReadBackProtocolExists `shouldBe` True

      -- Each refusal is distinct, so an unobservable target can never be read
      -- as an absent one and an unattempted identity step can never be read as
      -- an observed absence.
      let refusalFor targetObservation identityObservation =
            either
              Just
              (const Nothing)
              ( decideCredentialRevocationReadBack
                  LifecycleProviderTarget
                  generation
                  targetObservation
                  identityObservation
              )
      refusalFor RevokedTargetUnobservable RevokedIdentityNotReached
        `shouldBe` Just RevocationTargetUnobservable
      refusalFor RevokedTargetStillPresent RevokedIdentityNotReached
        `shouldBe` Just RevocationTargetStillPresent
      refusalFor RevokedTargetAbsent RevokedIdentityNotReached
        `shouldBe` Just RevocationIdentityNotReached
      refusalFor RevokedTargetAbsent RevokedIdentityUnobservable
        `shouldBe` Just RevocationIdentityUnobservable
      refusalFor RevokedTargetAbsent RevokedIdentityStillPresent
        `shouldBe` Just RevocationIdentityStillPresent

      -- The minted read-back carries both absences and the exact target and
      -- generation it was decided for.
      case decideCredentialRevocationReadBack
        LifecycleProviderTarget
        generation
        RevokedTargetAbsent
        RevokedIdentityAbsent of
        Left refusal -> expectationFailure ("unexpected refusal: " ++ show refusal)
        Right readBack -> do
          operatorMaterialRevocationTarget readBack `shouldBe` LifecycleProviderTarget
          operatorMaterialRevocationGeneration readBack `shouldBe` generation

    it "constructs only the seven closed least-privilege production IAM programs" $ do
      let programs =
            [ must (mkLifecycleProviderIamProgram "us-west-2" "123456789012" "prodbox-provider-role")
            , must
                ( mkAuthorityBackupIamProgram
                    "us-west-2"
                    "prodbox-pulumi-state-long-lived"
                    ["authority-backup-store/home"]
                )
            , must
                ( mkTlsRetentionIamProgram
                    "us-west-2"
                    "prodbox-pulumi-state-long-lived"
                    ["public-edge-tls/home-local/certificates"]
                )
            , must (mkGatewayDnsIamProgram "us-west-2" "Z123ABC")
            , must (mkHomeDns01IamProgram "us-west-2" "Z123ABC")
            , must (mkAwsRunDns01IamProgram "us-west-2" "Z123ABC")
            , must (mkSesSmtpIamProgram "us-west-2" "123456789012" "mail.example.com")
            ]
          documents = credentialIamProgramPolicyDocument <$> programs
          lifecycleProgram = case programs of
            firstProgram : _ -> firstProgram
            [] -> error "compiled credential program inventory is empty"
      (credentialIamProgramClass <$> programs)
        `shouldBe` ([minBound .. maxBound] :: [AwsCredentialClass])
      (credentialIamProgramPrincipal <$> programs)
        `shouldBe` (awsCredentialDescriptorPrincipal . awsCredentialDescriptor <$> [minBound .. maxBound])
      all (not . Text.isInfixOf "iam:*") documents `shouldBe` True
      all (not . Text.isInfixOf "s3:*") documents `shouldBe` True
      all (not . Text.isInfixOf "route53:*") documents `shouldBe` True
      all (not . Text.isInfixOf "ses:*") documents `shouldBe` True
      credentialIamProgramRoleName lifecycleProgram
        `shouldBe` Just "prodbox-provider-role"
      credentialIamProgramRoleTrustPolicy lifecycleProgram
        `shouldSatisfy` maybe
          False
          (Text.isInfixOf "arn:aws:iam::123456789012:user/prodbox-lifecycle-provider")
      credentialIamProgramRolePolicyDocument lifecycleProgram
        `shouldSatisfy` maybe False (not . Text.isInfixOf "iam:CreateAccessKey")
      credentialIamProgramRolePolicyDocument lifecycleProgram
        `shouldSatisfy` maybe False (not . Text.isInfixOf "iam:CreateUser")

    it "derives the complete retained SMTP schema from its registered identity" $ do
      targetSecretPayloadToVaultFields
        ( sesSmtpPayloadForIdentity
            "mail.example.com"
            "ca-central-1"
            "AKIAEXAMPLE"
            "derived-password"
        )
        `shouldBe` Right
          ( Map.fromList
              [ ("host", "email-smtp.ca-central-1.amazonaws.com")
              , ("port", "587")
              , ("from", "noreply@mail.example.com")
              , ("from_display_name", "prodbox")
              , ("reply_to", "noreply@mail.example.com")
              , ("username", "AKIAEXAMPLE")
              , ("password", "derived-password")
              ]
          )

    it "rejects cross-class S3 prefixes and credential-region drift" $ do
      case mkAuthorityBackupIamProgram
        "us-west-2"
        "prodbox-pulumi-state-long-lived"
        ["public-edge-tls/certificates"] of
        Left _ -> pure ()
        Right _ -> expectationFailure "Authority Backup accepted a TLS-owned S3 prefix"
      let iamProgram =
            must
              ( mkLifecycleProviderIamProgram
                  "us-west-2"
                  "123456789012"
                  "prodbox-provider-role"
              )
      case openProductionIamSession iamProgram (adminCredentials "us-east-1") of
        Left err ->
          err
            `shouldBe` ProductionIamCredentialRegionMismatch "us-west-2" "us-east-1"
        Right _ -> expectationFailure "production IAM session accepted credential-region drift"

    it "requires the shared TLS bucket to preexist and never creates it on absence" $ do
      requests <- newIORef []
      let iamProgram =
            must
              ( mkTlsRetentionIamProgram
                  "us-west-2"
                  "prodbox-pulumi-state-long-lived"
                  ["public-edge-tls/home-local/certificates"]
              )
          sender request = do
            modifyIORef' requests (<> [shrMethod request])
            pure
              ( Right
                  ( HttpOutcome
                      404
                      []
                      "<Error><Code>NoSuchBucket</Code><Message>absent</Message></Error>"
                  )
              )
          session =
            must
              ( openProductionIamSessionWithSender
                  iamProgram
                  (adminCredentials "us-west-2")
                  sender
              )
      ensureProductionIamPrerequisites session
        `shouldReturn` Left ProductionIamBucketReadBackMismatch
      readIORef requests `shouldReturn` ["HEAD"]

    it "creates and exactly reads back the Lifecycle-provider role and policies" $ do
      trustRef <- newIORef Nothing
      userPolicyRef <- newIORef Nothing
      rolePolicyRef <- newIORef Nothing
      let iamProgram =
            must
              ( mkLifecycleProviderIamProgram
                  "us-west-2"
                  "123456789012"
                  "prodbox-lifecycle-provider"
              )
          sender request =
            Right <$> roleFixtureOutcome trustRef userPolicyRef rolePolicyRef request
          session =
            must
              ( openProductionIamSessionWithSender
                  iamProgram
                  (adminCredentials "us-west-2")
                  sender
              )
      ensureProductionIamPrerequisites session `shouldReturn` Right ()
      trustPolicy <- readIORef trustRef
      userPolicy <- readIORef userPolicyRef
      rolePolicy <- readIORef rolePolicyRef
      trustPolicy `shouldSatisfy` maybe False (Text.isInfixOf "TrustLifecycleProviderIdentity")
      userPolicy `shouldSatisfy` maybe False (Text.isInfixOf "sts:AssumeRole")
      rolePolicy `shouldSatisfy` maybe False (Text.isInfixOf "RegisteredIamRoleEffects")

    it "classifies a possibly-sent one-time IAM key response as ambiguous" $ do
      let iamProgram =
            must
              ( mkLifecycleProviderIamProgram
                  "us-west-2"
                  "123456789012"
                  "prodbox-provider-role"
              )
          sender _ = pure (Left (TransportFailure "lost after dispatch" PossiblySent))
          session =
            must
              ( openProductionIamSessionWithSender
                  iamProgram
                  (adminCredentials "us-west-2")
                  sender
              )
      result <- createProductionAccessKey session
      case result of
        AwsAccessKeyCreateResponseLost -> pure ()
        _ -> expectationFailure "possibly-sent CreateAccessKey was not classified as response-lost"

    it "pins the Phase-4.50 first-reconcile plan and excludes later AWS-run/SES live projections" $ do
      let actions = firstReconcilePlanMemberAction <$> firstReconcilePlanMembers plan
      actions
        `shouldBe` [ EstablishAuthorityBackupMember
                   , ProvisionAwsCredentialMember LifecycleProviderCredential
                   , ProvisionAwsCredentialMember TlsRetentionStoreCredential
                   , ProvisionAwsCredentialMember GatewayDnsCredential
                   , ProvisionAwsCredentialMember HomeCertManagerDns01Credential
                   ]
      actions
        `shouldSatisfy` (notElem (ProvisionAwsCredentialMember AwsRunCertManagerDns01Credential))
      actions
        `shouldSatisfy` (notElem (ProvisionAwsCredentialMember SesSmtpRetainedCustodyCredential))

    it "uses distinct doctrine-exact Target-Agent paths instead of the removed shared AWS object" $ do
      targetSecretIdVaultLogicalPath (TargetAwsCredential AwsLifecycleProvider)
        `shouldBe` "aws/lifecycle-provider"
      targetSecretIdVaultLogicalPath (TargetAwsCredential AwsAuthorityBackupStore)
        `shouldBe` "aws/authority-backup-store"
      targetSecretIdVaultLogicalPath (TargetAwsCredential AwsTlsRetentionStore)
        `shouldBe` "aws/tls-retention-store"
      targetSecretIdVaultLogicalPath (TargetAwsCredential AwsGatewayDns)
        `shouldBe` "aws/gateway-dns"
      targetSecretIdVaultLogicalPath (TargetAwsCredential AwsHomeCertManagerDns01)
        `shouldBe` "aws/cert-manager/home/dns01"
      targetSecretIdVaultLogicalPath (TargetAwsCredential AwsRunCertManagerDns01)
        `shouldBe` "aws/cert-manager/aws/dns01"

    it "round-trips canonical closed requests and keeps EAB outside the AWS schema" $ do
      case decodeOperatorMaterialRequest (encodeOperatorMaterialRequest lifecycleRequest) of
        Right (SomeOperatorMaterialRequest SAwsAdminProvisioningIngress decoded) ->
          operatorMaterialRequestAwsClass decoded `shouldBe` Just LifecycleProviderCredential
        other -> expectationFailure ("unexpected AWS request decode: " ++ show other)
      case decodeOperatorMaterialRequest (encodeOperatorMaterialRequest eabRequest) of
        Right (SomeOperatorMaterialRequest SExternalAcmeEabIngress decoded) -> do
          operatorMaterialRequestAwsClass decoded `shouldBe` Nothing
          operatorMaterialRequestTarget decoded `shouldBe` RetainedHomeAcmeEabSourceTarget
        other -> expectationFailure ("unexpected EAB request decode: " ++ show other)

    it "advances the finite plan only with the exact next member receipt and binds a separate permit" $ do
      let cursor0 = initialFirstReconcileCursor plan
          backupMember = headMember plan
          backupReceipt = must (mkFirstReconcileReceipt backupMember "vault-v1" "agent-ref-1")
          cursor1 = must (advanceFirstReconcileCursor plan cursor0 backupReceipt)
          lifecycleMember = nextMember plan cursor1
          lifecycleReceipt =
            must (mkFirstReconcileReceipt lifecycleMember "vault-v2" "agent-ref-2")
          binding =
            must (bindPermitToNextFirstReconcileMember plan cursor1 lifecycleRequest)
          boundPermit =
            must
              ( mkOperatorMaterialPermit
                  (must (mkOperatorMaterialPermitId "permit-plan-lifecycle"))
                  lifecycleRequest
                  (authorityTimeFromMicros 1000)
                  (Just binding)
                  "signed-plan-permit"
              )
      firstReconcilePlanMemberAction lifecycleMember
        `shouldBe` ProvisionAwsCredentialMember LifecycleProviderCredential
      bindPermitToNextFirstReconcileMember plan cursor1 lifecycleRequest
        `shouldSatisfy` either (const False) (const True)
      bindPermitToNextFirstReconcileMember plan cursor1 tlsRequest
        `shouldBe` Left FirstReconcileRequestClassMismatch
      validateFirstReconcileOperatorMaterialPermit
        (authorityTimeFromMicros 100)
        plan
        cursor1
        boundPermit
        `shouldBe` Right ()
      advanceFirstReconcileCursor plan cursor1 lifecycleReceipt
        `shouldSatisfy` either (const False) (const True)
      advanceFirstReconcileCursor plan cursor0 lifecycleReceipt
        `shouldBe` Left FirstReconcileReceiptWrongMember

    it "durably round-trips the exact first-reconcile cursor and prior receipt" $ do
      let firstMember = headMember plan
          firstReceipt = must (mkFirstReconcileReceipt firstMember "vault-v1" "target-ref-1")
          committed = must (appendFirstReconcileReceipt firstReceipt (initialFirstReconcileJournal plan))
          recovered = must (decodeFirstReconcileJournal (encodeFirstReconcileJournal committed))
      recovered `shouldBe` committed
      firstReconcileJournalReceipts recovered `shouldBe` [firstReceipt]
      firstReconcilePriorReceiptDigest (firstReconcileJournalCursor recovered)
        `shouldBe` Just (firstReconcileReceiptDigest firstReceipt)
      nextFirstReconcileMember plan (firstReconcileJournalCursor recovered)
        `shouldBe` Right (Just (firstReconcilePlanMembers plan !! 1))
      firstReconcileJournalComplete recovered `shouldBe` False

    it "makes exact journal replay idempotent and rejects divergent or out-of-order receipts" $ do
      let firstMember = headMember plan
          secondMember = firstReconcilePlanMembers plan !! 1
          firstReceipt = must (mkFirstReconcileReceipt firstMember "vault-v1" "target-ref-1")
          divergentReceipt = must (mkFirstReconcileReceipt firstMember "vault-v1" "different-ref")
          secondReceipt = must (mkFirstReconcileReceipt secondMember "vault-v2" "target-ref-2")
          initial = initialFirstReconcileJournal plan
          committed = must (appendFirstReconcileReceipt firstReceipt initial)
      appendFirstReconcileReceipt firstReceipt committed `shouldBe` Right committed
      appendFirstReconcileReceipt divergentReceipt committed
        `shouldBe` Left (FirstReconcileJournalReceiptConflict 0)
      appendFirstReconcileReceipt secondReceipt initial
        `shouldBe` Left (FirstReconcileJournalReceiptRejected FirstReconcileReceiptWrongMember)

    it "rejects corrupt, trailing, and over-bound journal bytes" $ do
      let encoded = encodeFirstReconcileJournal (initialFirstReconcileJournal plan)
      decodeFirstReconcileJournal (ByteString.snoc encoded 0)
        `shouldSatisfy` either (const True) (const False)
      decodeFirstReconcileJournal (ByteString.replicate (32 * 1024 + 1) 0)
        `shouldBe` Left (FirstReconcileJournalTooLarge (32 * 1024 + 1) (32 * 1024))

    it "initializes and advances the retained first-reconcile journal with CAS semantics" $ do
      store <- newIORef Nothing
      let adapter = fakeFirstReconcileJournalAdapter store
          coordinate = firstReconcileJournalCoordinate
          firstReceipt =
            must
              ( mkFirstReconcileReceipt
                  (headMember plan)
                  "vault-v1"
                  "target-ref-1"
              )
          expectedInitial = initialFirstReconcileJournal plan
          expectedAdvanced = must (appendFirstReconcileReceipt firstReceipt expectedInitial)
      initializeFirstReconcileJournalStore adapter coordinate plan
        `shouldReturn` Right (FirstReconcileJournalStoreApplied journalVersionOne expectedInitial)
      appendFirstReconcileJournalStore adapter coordinate firstReceipt
        `shouldReturn` Right (FirstReconcileJournalStoreApplied journalVersionTwo expectedAdvanced)
      appendFirstReconcileJournalStore adapter coordinate firstReceipt
        `shouldReturn` Right (FirstReconcileJournalStoreAlreadyCurrent expectedAdvanced)

    it "keeps journal CAS conflicts and endpoint-unready observations typed" $ do
      let conflictAdapter =
            ModelBCasAdapter
              { modelBObserve = \_ -> pure ModelBMissing
              , modelBCompareAndSwap = \_ -> pure (ModelBCasConflict ModelBMissing)
              }
          unreadyAdapter =
            ModelBCasAdapter
              { modelBObserve = \_ -> pure (ModelBEndpointUnready "authority endpoint warming")
              , modelBCompareAndSwap = \_ -> pure (ModelBCasEndpointUnready "authority endpoint warming")
              }
      initializeFirstReconcileJournalStore conflictAdapter firstReconcileJournalCoordinate plan
        `shouldReturn` Left FirstReconcileJournalStoreConcurrentWrite
      initializeFirstReconcileJournalStore unreadyAdapter firstReconcileJournalCoordinate plan
        `shouldReturn` Left (FirstReconcileJournalStoreEndpointUnready "authority endpoint warming")

    it
      "admits Authority-backup installation only through the member-zero genesis permit and returns typed establishment inputs"
      $ do
        let cursor0 = initialFirstReconcileCursor plan
            genesisPlan = GenesisPlan "genesis-plan-digest" "authority-backup-store/home"
            genesisPermit =
              must
                ( mkGenesisBackupPermit
                    genesisPlan
                    plan
                    cursor0
                    (must (mkOperatorMaterialPermitId "permit-genesis-backup"))
                    (must (mkOperatorMaterialOperationId "op-genesis-backup"))
                    generationOne
                    (authorityTimeFromMicros 1000)
                    "signed-genesis-permit"
                )
        genesisBackupPermitDescriptor genesisPermit
          `shouldBe` awsCredentialDescriptor AuthorityBackupStoreCredential
        firstReconcilePlanMemberAction (genesisBackupPermitFirstReconcileMember genesisPermit)
          `shouldBe` EstablishAuthorityBackupMember
        validateGenesisBackupPermit now genesisPermit `shouldBe` Right ()
        mkAwsOperatorMaterialRequest
          AuthorityBackupStoreCredential
          InstallOperatorMaterial
          (must (mkOperatorMaterialOperationId "forbidden-normal-backup"))
          generationOne
          `shouldBe` Left AuthorityBackupInstallRequiresGenesisPermit

        events <- newIORef []
        inventories <-
          newIORef
            [ observedAccessKeyInventory []
            , observedAccessKeyInventory []
            , observedAccessKeyInventory [replacementKey]
            ]
        createResults <-
          newIORef [AwsAccessKeyCreated replacementKey replacementMaterial]
        framed <-
          case withAwsAdminIngressFrame "bounded-admin-frame" id of
            Left err -> expectationFailure ("frame refused: " ++ show err) >> error "unreachable"
            Right frame -> pure frame
        result <-
          runGenesisBackupProvisioner
            (fakeBoundary events inventories createResults)
            (fakeTargetClient events)
            "us-east-1"
            now
            genesisPermit
            framed
        case result of
          Left err -> expectationFailure ("genesis provisioning failed: " ++ show err)
          Right provisioned -> do
            genesisBackupProvisioningTargetGenerationReceipt provisioned
              `shouldSatisfy` \(TargetAgentGenerationReceipt value) ->
                "authority-backup-store:1:7:" `Text.isPrefixOf` value
            let establishment = genesisBackupProvisioningEstablishmentInput provisioned
            genesisBackupEstablishmentPlan establishment `shouldBe` genesisPlan
            targetMaterialReceiptTarget
              (genesisBackupEstablishmentTargetReceipt establishment)
              `shouldBe` AuthorityBackupStoreTarget

    it "attests the exact UID/image/SA/permit/deadline/heartbeat and refuses stale heartbeat" $ do
      let intent = mkCredentialProvisionerJobIntent imageDigest lifecyclePermit
          observed = validPodObservation lifecyclePermit intent
      attestCredentialProvisionerPod now 20 intent observed
        `shouldSatisfy` either (const False) (const True)
      attestCredentialProvisionerPod
        now
        5
        intent
        observed
        `shouldBe` Left CredentialProvisionerHeartbeatStale
      attestCredentialProvisionerPod
        now
        20
        intent
        observed {rawCredentialProvisionerServiceAccount = "default"}
        `shouldBe` Left CredentialProvisionerServiceAccountMismatch

    it
      "persists intent, proves an empty inventory, and repairs only its own ambiguous create before remint"
      $ do
        events <- newIORef []
        inventories <-
          newIORef
            [ observedAccessKeyInventory []
            , observedAccessKeyInventory []
            , observedAccessKeyInventory [lostKey]
            , observedAccessKeyInventory []
            , observedAccessKeyInventory []
            , observedAccessKeyInventory []
            , observedAccessKeyInventory [replacementKey]
            ]
        createResults <-
          newIORef
            [ AwsAccessKeyCreateResponseLost
            , AwsAccessKeyCreated replacementKey replacementMaterial
            ]
        let boundary = fakeBoundary events inventories createResults
            client = fakeTargetClient events
        framed <-
          case withAwsAdminIngressFrame "bounded-admin-frame" id of
            Left err -> expectationFailure ("frame refused: " ++ show err) >> error "unreachable"
            Right frame -> pure frame
        result <-
          runAwsOperatorMaterialProvisioner
            boundary
            client
            "us-east-1"
            lifecyclePermit
            framed
        result `shouldSatisfy` either (const False) (const True)
        actualEvents <- readIORef events
        actualEvents
          `shouldBe` [ BeganSession
                     , PersistedIntent
                     , ObservedInventory
                     , WaitedVisibility
                     , ObservedInventory
                     , CreatedKey
                     , ObservedInventory
                     , DeletedKey "LOSTKEY1"
                     , WaitedVisibility
                     , ObservedInventory
                     , ObservedInventory
                     , WaitedVisibility
                     , ObservedInventory
                     , CreatedKey
                     , ObservedInventory
                     , HandedToAgent
                     , CommittedReceipt
                     , RevokedSession
                     , DeletedJob
                     , ObservedPodAbsence
                     ]

    it "refuses install when an existing principal key is observed and never deletes it" $ do
      events <- newIORef []
      inventories <- newIORef [observedAccessKeyInventory [oldKey]]
      createResults <- newIORef []
      result <-
        runAwsOperatorMaterialProvisioner
          (fakeBoundary events inventories createResults)
          (fakeTargetClient events)
          "us-east-1"
          lifecyclePermit
          awsFrame
      result `shouldBe` Left CredentialProvisionerInstallRequiresEmptyInventory
      readIORef events
        `shouldReturn` [ BeganSession
                       , PersistedIntent
                       , ObservedInventory
                       , RevokedSession
                       , DeletedJob
                       , ObservedPodAbsence
                       ]

    it "makes rotation unrepresentable until committed-generation retirement ordering exists" $ do
      events <- newIORef []
      inventories <- newIORef []
      createResults <- newIORef []
      result <-
        runAwsOperatorMaterialProvisioner
          (fakeBoundary events inventories createResults)
          (fakeTargetClient events)
          "us-east-1"
          rotationPermit
          awsFrame
      result `shouldBe` Left CredentialProvisionerRotationRequiresRetirementProtocol
      readIORef events
        `shouldReturn` [ BeganSession
                       , RevokedSession
                       , DeletedJob
                       , ObservedPodAbsence
                       ]

    it "rejects a create whose inventory identity disagrees with its secret response" $ do
      events <- newIORef []
      inventories <-
        newIORef
          [ observedAccessKeyInventory []
          , observedAccessKeyInventory []
          ]
      createResults <-
        newIORef [AwsAccessKeyCreated replacementKey mismatchedMaterial]
      result <-
        runAwsOperatorMaterialProvisioner
          (fakeBoundary events inventories createResults)
          (fakeTargetClient events)
          "us-east-1"
          lifecyclePermit
          awsFrame
      result `shouldBe` Left CredentialProvisionerCreatedAccessKeyIdMismatch
      readIORef events
        `shouldReturn` [ BeganSession
                       , PersistedIntent
                       , ObservedInventory
                       , WaitedVisibility
                       , ObservedInventory
                       , CreatedKey
                       , RevokedSession
                       , DeletedJob
                       , ObservedPodAbsence
                       ]

    it
      "revokes the worker token after every authenticated terminal path and requires exact absence before receipts"
      $ do
        forM_
          [ ExternalMaterialWorkerAuthorityKeyUnavailable
          , ExternalMaterialWorkerPermitRejected
          , ExternalMaterialWorkerCustodyHandoffUnavailable
          ]
          $ \workerError -> do
            revocations <- newIORef (0 :: Int)
            result <-
              finishExternalMaterialWorkerSession
                (pure (Left workerError :: Either ExternalMaterialWorkerError ()))
                (modifyIORef' revocations (+ 1) >> pure (Right ()))
                (pure (Right True))
            result `shouldBe` Left workerError
            readIORef revocations `shouldReturn` 1
        revocations <- newIORef (0 :: Int)
        result <-
          finishExternalMaterialWorkerSession
            (pure (Right () :: Either ExternalMaterialWorkerError ()))
            ( modifyIORef' revocations (+ 1)
                >> pure (Left ExternalMaterialWorkerSessionRevocationFailed)
            )
            (pure (Right True))
        -- The revoke response is provisional: an exact independent absence
        -- observation closes an applied-but-response-lost revoke safely.
        result `shouldBe` Right ()
        readIORef revocations `shouldReturn` 1
        finishExternalMaterialWorkerSession
          (pure (Right () :: Either ExternalMaterialWorkerError ()))
          (pure (Left ExternalMaterialWorkerSessionRevocationFailed))
          (pure (Right False))
          `shouldReturn` Left ExternalMaterialWorkerSessionRevocationFailed

    it "keeps plaintext ingress out of long-lived control-plane handlers" $ do
      targetMaterial <-
        readFile
          ( "src"
              </> "Prodbox"
              </> "Lifecycle"
              </> "CredentialProvisioner"
              </> "TargetMaterial.hs"
          )
      runtime <- readFile ("src" </> "Prodbox" </> "ControlPlane" </> "Runtime.hs")
      job <-
        readFile
          ( "src"
              </> "Prodbox"
              </> "Lifecycle"
              </> "CredentialProvisioner"
              </> "KubernetesJob.hs"
          )
      targetIngressEndpoint <-
        doesFileExist
          ( "src"
              </> "Prodbox"
              </> "ControlPlane"
              </> "ExternalMaterialTargetEndpoint.hs"
          )
      targetIngressClient <-
        doesFileExist
          ( "src"
              </> "Prodbox"
              </> "ControlPlane"
              </> "ExternalMaterialTargetClient.hs"
          )
      targetMaterial `shouldNotContain` "registeredTargetMaterialClient"
      runtime `shouldNotContain` "targetMaterialAuthenticatedHandler"
      job `shouldContain` "encodeExternalMaterialWorkerIngress"
      job `shouldNotContain` "data ExternalMaterialWorkerIngress"
      targetIngressEndpoint `shouldBe` False
      targetIngressClient `shouldBe` False

    it
      "parses each closed worker schema and binds every schema-specific attested metadata argument"
      $ do
        case execParserPure defaultPrefs parserInfo externalWorkerArgv of
          Success
            Options
              { optRequest =
                RunNative
                  ( NativeCredentialProvisioner
                      ( CredentialProvisionerExternalAcmeEabRun
                          options
                          PlanOptions {dryRun = True, planFile = Nothing}
                        )
                    )
              } -> do
              externalMaterialWorkerPermitId options `shouldBe` "permit-example"
              externalMaterialWorkerRequestDigest options `shouldBe` Text.replicate 64 "a"
              externalMaterialWorkerDeadlineMicros options `shouldBe` 123
              externalMaterialWorkerPodUidFile options `shouldBe` "/run/prodbox/pod-uid"
              externalMaterialWorkerServiceAccountTokenFile options
                `shouldBe` "/run/prodbox/token"
          _ -> expectationFailure "exact external-acme-eab worker argv did not parse"
        case execParserPure defaultPrefs parserInfo awsAdminWorkerArgv of
          Success
            Options
              { optRequest =
                RunNative
                  ( NativeCredentialProvisioner
                      ( CredentialProvisionerAwsAdminRun
                          options
                          PlanOptions {dryRun = True, planFile = Nothing}
                        )
                    )
              } -> do
              awsAdminWorkerExpectedMode options `shouldBe` AwsAdminNormalMode
              awsAdminWorkerExpectedOperationId options `shouldBe` "operation-example"
              awsAdminWorkerExpectedPermitId options `shouldBe` "permit-example"
              awsAdminWorkerExpectedRequestDigest options `shouldBe` Text.replicate 64 "a"
              awsAdminWorkerExpectedDeadlineMicros options `shouldBe` 123
              awsAdminWorkerExpectedImageDigest options
                `shouldBe` ("sha256:" <> Text.replicate 64 "b")
              awsAdminWorkerTargetImageRepository options
                `shouldBe` "registry.example.invalid/prodbox"
              awsAdminWorkerExpectedAuthorityScope options `shouldBe` "home"
              awsAdminWorkerExpectedAuthorityEndpoint options
                `shouldBe` "https://lifecycle-authority.example.invalid"
              awsAdminWorkerPodNameFile options `shouldBe` "/run/prodbox/pod-name"
              awsAdminWorkerPodUidFile options `shouldBe` "/run/prodbox/pod-uid"
              awsAdminWorkerServiceAccountTokenFile options `shouldBe` "/run/prodbox/token"
          Failure _ -> expectationFailure "exact aws-admin worker argv did not parse"
          CompletionInvoked _ -> expectationFailure "unexpected completion result"
          _ -> expectationFailure "AWS-admin worker parsed to the wrong closed command"

    goldenTest
      "renders the external-acme-eab dry-run plan without touching stdin"
      "test/golden/plans/credential-provisioner-external-acme-eab.txt"
      (pure (BL8.pack credentialProvisionerRunPlan))

    goldenTest
      "renders the AWS-admin dry-run plan without touching stdin"
      "test/golden/plans/credential-provisioner-aws-admin.txt"
      (pure (BL8.pack awsAdminCredentialProvisionerRunPlan))

    it
      "renders an inert-by-default, secret-free, digest-pinned one-shot chart with separate ingress identities"
      $ do
        values <- readFile (chartRoot </> "values.yaml")
        job <- readFile (chartRoot </> "templates" </> "job.yaml")
        serviceAccount <- readFile (chartRoot </> "templates" </> "serviceaccount.yaml")
        policy <- readFile (chartRoot </> "templates" </> "networkpolicy.yaml")
        authorityPolicy <-
          readFile
            ( "charts"
                </> "lifecycle-authority"
                </> "templates"
                </> "networkpolicy.yaml"
            )
        values `shouldContain` "enabled: false"
        job `shouldContain` "backoffLimit: 0"
        job `shouldContain` "@{{ .Values.image.digest }}"
        job `shouldContain` "stdin: true"
        job `shouldContain` "stdinOnce: true"
        job `shouldContain` "--mode"
        job `shouldContain` "--operation-id"
        job `shouldContain` "--authority-scope"
        job `shouldContain` "--authority-endpoint"
        job `shouldContain` "--target-worker-image-repository"
        job `shouldContain` "path: pod-name"
        job `shouldContain` "fieldPath: metadata.uid"
        job `shouldNotContain` "env:"
        job `shouldNotContain` "kind: Secret"
        serviceAccount `shouldContain` "automountServiceAccountToken: false"
        policy `shouldContain` "ingress: []"
        policy `shouldContain` "kubernetes.io/metadata.name: vault"
        -- Sprint 3.34: the Vault egress port is a values binding, not a
        -- restated literal.
        policy `shouldContain` "port: {{ .Values.ports.vault }}"
        policy `shouldContain` "metadata.name: target-secret-agent"
        policy `shouldContain` "app.kubernetes.io/name: prodbox-target-secret-agent"
        policy `shouldContain` "metadata.name: lifecycle-authority"
        policy `shouldContain` "app.kubernetes.io/name: prodbox-lifecycle-authority"
        authorityPolicy `shouldContain` "metadata.name: credential-provisioner"
        authorityPolicy `shouldContain` "app.kubernetes.io/name: prodbox-credential-provisioner"
        (values <> job <> serviceAccount <> policy)
          `shouldNotContain` legacySharedAwsPath
 where
  plan = defaultFirstReconcileProvisioningPlan (authorityTimeFromMicros 1000)
  now = authorityTimeFromMicros 100
  lifecycleRequest = awsRequest LifecycleProviderCredential InstallOperatorMaterial "op-lifecycle"
  tlsRequest = awsRequest TlsRetentionStoreCredential InstallOperatorMaterial "op-tls"
  eabRequest =
    mkExternalAcmeEabRequest
      InstallOperatorMaterial
      (must (mkOperatorMaterialOperationId "op-eab"))
      generationOne
  lifecyclePermit =
    must
      ( mkOperatorMaterialPermit
          (must (mkOperatorMaterialPermitId "permit-lifecycle"))
          lifecycleRequest
          (authorityTimeFromMicros 1000)
          Nothing
          "signed-permit"
      )
  rotationPermit =
    must
      ( mkOperatorMaterialPermit
          (must (mkOperatorMaterialPermitId "permit-lifecycle-rotation"))
          (awsRequest LifecycleProviderCredential RotateOperatorMaterial "op-lifecycle-rotation")
          (authorityTimeFromMicros 1000)
          Nothing
          "signed-rotation-permit"
      )
  imageDigest =
    must
      ( mkCredentialProvisionerImageDigest
          "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      )

awsFrame :: OperatorMaterialIngressFrame 'AwsAdminProvisioningIngress
awsFrame =
  must (withAwsAdminIngressFrame "bounded-admin-frame" id)

awsRequest
  :: AwsCredentialClass
  -> OperatorMaterialAction
  -> Text
  -> OperatorMaterialRequest 'AwsAdminProvisioningIngress
awsRequest credentialClass action operationId =
  must
    ( mkAwsOperatorMaterialRequest
        credentialClass
        action
        (must (mkOperatorMaterialOperationId operationId))
        generationOne
    )

generationOne :: CredentialGeneration
generationOne = must (mkCredentialGeneration 1)

headMember :: FirstReconcileProvisioningPlan -> FirstReconcilePlanMember
headMember provisioningPlan = case firstReconcilePlanMembers provisioningPlan of
  member : _ -> member
  [] -> error "compiled first-reconcile plan is empty"

nextMember :: FirstReconcileProvisioningPlan -> FirstReconcileCursor -> FirstReconcilePlanMember
nextMember provisioningPlan cursor =
  case must (nextFirstReconcileMember provisioningPlan cursor) of
    Just member -> member
    Nothing -> error "compiled first-reconcile plan ended unexpectedly"

validPodObservation
  :: OperatorMaterialPermit 'AwsAdminProvisioningIngress
  -> CredentialProvisionerJobIntent 'AwsAdminProvisioningIngress
  -> RawCredentialProvisionerPodObservation
validPodObservation permit intent =
  RawCredentialProvisionerPodObservation
    { rawCredentialProvisionerJobName = credentialProvisionerJobName intent
    , rawCredentialProvisionerJobUid = "fixture-job-uid-1"
    , rawCredentialProvisionerPodUid = "fixture-pod-uid-1"
    , rawCredentialProvisionerImageDigest =
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    , rawCredentialProvisionerServiceAccount = "prodbox-credential-provisioner"
    , rawCredentialProvisionerServiceAccountUid =
        "fixture-service-account-uid-1"
    , rawCredentialProvisionerSchema = AwsAdminProvisioningIngress
    , rawCredentialProvisionerPermitId = "permit-lifecycle"
    , rawCredentialProvisionerRequestDigest = operatorMaterialPermitRequestDigest permit
    , rawCredentialProvisionerPlanBinding = Nothing
    , rawCredentialProvisionerDeadline = authorityTimeFromMicros 1000
    , rawCredentialProvisionerHeartbeat = authorityTimeFromMicros 90
    , rawCredentialProvisionerPhase = "Running"
    , rawCredentialProvisionerContainerReady = True
    , rawCredentialProvisionerRestartCount = 0
    , rawCredentialProvisionerDeletionTimestamp = Nothing
    }

data FakeEvent
  = BeganSession
  | PersistedIntent
  | ObservedInventory
  | DeletedKey !Text
  | WaitedVisibility
  | CreatedKey
  | HandedToAgent
  | CommittedReceipt
  | RevokedSession
  | DeletedJob
  | ObservedPodAbsence
  deriving (Eq, Show)

fakeBoundary
  :: IORef [FakeEvent]
  -> IORef [AccessKeyInventoryObservation]
  -> IORef [AwsAccessKeyCreateResult]
  -> CredentialProvisionerBoundary IO
fakeBoundary events inventories createResults =
  mkCredentialProvisionerBoundary
    (\_ -> append BeganSession >> pure (Right awsSession))
    (\_ -> pure (Right externalSession))
    (\_ -> append PersistedIntent >> pure (Right ()))
    (\_ -> append ObservedInventory >> pop inventories)
    (\_ keyId -> append (DeletedKey (provisionedAccessKeyIdText keyId)) >> pure (Right ()))
    (append WaitedVisibility >> pure (Right ()))
    (\_ -> append CreatedKey >> pop createResults)
    (\_ _ -> pure (Left "unexpected revoke"))
    (\_ _ -> pure (Left "unexpected external revoke"))
    (\_ -> append CommittedReceipt >> pure (Right ()))
    (\_ -> pure (Right ()))
    (\_ -> append RevokedSession >> pure (Right ()))
    (\_ -> pure (Right ()))
    (append DeletedJob >> pure (Right ()))
    (append ObservedPodAbsence >> pure (Right True))
 where
  append event = modifyIORef' events (<> [event])
  awsSession = must (mkProvisionerIngressSession "aws-session")
  externalSession = must (mkProvisionerIngressSession "eab-session")

fakeTargetClient :: IORef [FakeEvent] -> TargetMaterialClient IO
fakeTargetClient events =
  mkTargetMaterialClient $ \handoff -> do
    modifyIORef' events (<> [HandedToAgent])
    pure
      ( Right
          ( withTargetMaterialHandoff handoff $ \_ _ target generation _ ->
              mkTargetMaterialReceipt target generation 7
          )
      )

pop :: IORef [value] -> IO value
pop ref = do
  values <- readIORef ref
  case values of
    [] -> error "fake sequence exhausted"
    value : rest -> do
      modifyIORef' ref (const rest)
      pure value

oldKey, lostKey, replacementKey :: ProvisionedAccessKeyId
oldKey = must (mkProvisionedAccessKeyId "OLDKEY1")
lostKey = must (mkProvisionedAccessKeyId "LOSTKEY1")
replacementKey = must (mkProvisionedAccessKeyId "NEWKEY1")

replacementMaterial :: CreatedAwsAccessKey
replacementMaterial = must (mkCreatedAwsAccessKey "NEWKEY1" "one-time-secret")

mismatchedMaterial :: CreatedAwsAccessKey
mismatchedMaterial = must (mkCreatedAwsAccessKey "OTHERKEY1" "one-time-secret")

legacySharedAwsPath :: String
legacySharedAwsPath = "secret/gateway/" <> "gateway/aws"

chartRoot :: FilePath
chartRoot = "charts" </> "credential-provisioner"

externalWorkerArgv :: [String]
externalWorkerArgv =
  [ "credential-provisioner"
  , "run"
  , "--ingress-schema"
  , "external-acme-eab"
  , "--permit-id"
  , "permit-example"
  , "--request-digest"
  , replicate 64 'a'
  , "--deadline-micros"
  , "123"
  , "--pod-uid-file"
  , "/run/prodbox/pod-uid"
  , "--service-account-token-file"
  , "/run/prodbox/token"
  , "--dry-run"
  ]

awsAdminWorkerArgv :: [String]
awsAdminWorkerArgv =
  [ "credential-provisioner"
  , "run"
  , "--ingress-schema"
  , "aws-admin"
  , "--mode"
  , "normal"
  , "--operation-id"
  , "operation-example"
  , "--permit-id"
  , "permit-example"
  , "--request-digest"
  , replicate 64 'a'
  , "--deadline-micros"
  , "123"
  , "--image-digest"
  , "sha256:" <> replicate 64 'b'
  , "--target-worker-image-repository"
  , "registry.example.invalid/prodbox"
  , "--authority-scope"
  , "home"
  , "--authority-endpoint"
  , "https://lifecycle-authority.example.invalid"
  , "--pod-name-file"
  , "/run/prodbox/pod-name"
  , "--pod-uid-file"
  , "/run/prodbox/pod-uid"
  , "--service-account-token-file"
  , "/run/prodbox/token"
  , "--dry-run"
  ]

roleFixtureOutcome
  :: IORef (Maybe Text)
  -> IORef (Maybe Text)
  -> IORef (Maybe Text)
  -> SignedHttpRequest
  -> IO HttpOutcome
roleFixtureOutcome trustRef userPolicyRef rolePolicyRef request =
  case formValue "Action" request of
    Just "GetUser" -> ok getUser
    Just "TagUser" -> ok "<TagUserResponse/>"
    Just "ListUserTags" -> ok listTags
    Just "PutUserPolicy" -> storePolicy userPolicyRef "<PutUserPolicyResponse/>"
    Just "GetUserPolicy" -> readPolicy userPolicyRef "GetUserPolicy"
    Just "GetRole" -> do
      trust <- readIORef trustRef
      case trust of
        Nothing -> pure noSuchEntity
        Just document -> ok (getRole document)
    Just "CreateRole" ->
      storeNamedPolicy trustRef "AssumeRolePolicyDocument" "<CreateRoleResponse/>"
    Just "UpdateAssumeRolePolicy" ->
      storeNamedPolicy trustRef "PolicyDocument" "<UpdateAssumeRolePolicyResponse/>"
    Just "PutRolePolicy" -> storePolicy rolePolicyRef "<PutRolePolicyResponse/>"
    Just "GetRolePolicy" -> readPolicy rolePolicyRef "GetRolePolicy"
    other ->
      pure
        ( HttpOutcome
            500
            []
            ( "<Error><Code>UnexpectedAction</Code><Message>"
                <> encodeUtf8 (Text.pack (show other))
                <> "</Message></Error>"
            )
        )
 where
  ok body = pure (HttpOutcome 200 [] body)
  getUser =
    "<GetUserResponse><GetUserResult><User>"
      <> "<UserName>prodbox-lifecycle-provider</UserName>"
      <> "<UserId>AIDALIFECYCLE</UserId>"
      <> "<Arn>arn:aws:iam::123456789012:user/prodbox-lifecycle-provider</Arn>"
      <> "</User></GetUserResult></GetUserResponse>"
  listTags =
    "<ListUserTagsResponse><ListUserTagsResult><Tags>"
      <> "<member><Key>prodbox.io/managed-by</Key><Value>prodbox</Value></member>"
      <> "<member><Key>prodbox.io/credential-class</Key><Value>lifecycle-provider</Value></member>"
      <> "</Tags><IsTruncated>false</IsTruncated></ListUserTagsResult></ListUserTagsResponse>"
  noSuchEntity =
    HttpOutcome
      404
      []
      "<ErrorResponse><Error><Code>NoSuchEntity</Code><Message>missing</Message></Error></ErrorResponse>"
  storePolicy ref response = storeNamedPolicy ref "PolicyDocument" response
  storeNamedPolicy ref field response = case formValue field request of
    Nothing -> pure (HttpOutcome 400 [] "<Error><Code>MissingPolicy</Code></Error>")
    Just document -> writeIORef ref (Just document) >> ok response
  readPolicy ref action = do
    current <- readIORef ref
    case current of
      Nothing -> pure noSuchEntity
      Just document ->
        ok
          ( "<"
              <> action
              <> "Response><"
              <> action
              <> "Result><PolicyDocument>"
              <> urlEncode True (encodeUtf8 document)
              <> "</PolicyDocument></"
              <> action
              <> "Result></"
              <> action
              <> "Response>"
          )
  getRole trust =
    "<GetRoleResponse><GetRoleResult><Role>"
      <> "<RoleName>prodbox-lifecycle-provider</RoleName>"
      <> "<Arn>arn:aws:iam::123456789012:role/prodbox-lifecycle-provider</Arn>"
      <> "<AssumeRolePolicyDocument>"
      <> urlEncode True (encodeUtf8 trust)
      <> "</AssumeRolePolicyDocument></Role></GetRoleResult></GetRoleResponse>"

formValue :: ByteString.ByteString -> SignedHttpRequest -> Maybe Text
formValue field request =
  decodeUtf8 . urlDecode True
    <$> lookup field (splitForm (shrBody request))
 where
  splitForm = fmap splitPair . ByteString8.split '&'
  splitPair pair =
    let (key, remainder) = ByteString8.break (== '=') pair
     in (key, ByteString.drop 1 remainder)

adminCredentials :: Text -> Settings.Credentials
adminCredentials regionValue =
  Settings.Credentials
    "AKIAADMINFORTEST"
    "admin-secret-for-test"
    Nothing
    regionValue

firstReconcileJournalCoordinate
  :: ModelBObjectCoordinate 'ClusterRetained
firstReconcileJournalCoordinate =
  must
    ( mkClusterRetainedCoordinate
        ( must
            ( mkLongLivedCheckpointAuthority
                "home-authority"
                "prodbox-retained"
                "authority"
                "secret/lifecycle"
            )
        )
        "credential-provisioner/first-reconcile"
    )

journalVersionOne, journalVersionTwo :: ModelBObjectVersion
journalVersionOne = must (mkModelBObjectVersion "journal-v1")
journalVersionTwo = must (mkModelBObjectVersion "journal-v2")

fakeFirstReconcileJournalAdapter
  :: IORef (Maybe (ModelBObjectVersion, FirstReconcileJournal))
  -> ModelBCasAdapter 'ClusterRetained IO FirstReconcileJournal
fakeFirstReconcileJournalAdapter store =
  ModelBCasAdapter
    { modelBObserve = \_ -> do
        current <- readIORef store
        pure $ case current of
          Nothing -> ModelBMissing
          Just (version, journal) -> ModelBObserved version journal
    , modelBCompareAndSwap = \request -> do
        current <- readIORef store
        case request of
          ModelBInitialize _ journal -> case current of
            Nothing -> apply journalVersionOne journal
            Just (version, existing) ->
              pure (ModelBCasConflict (ModelBObserved version existing))
          ModelBReplace _ expected journal -> case current of
            Just (actual, _)
              | actual == expected -> apply journalVersionTwo journal
            Nothing -> pure (ModelBCasConflict ModelBMissing)
            Just (actual, existing) ->
              pure (ModelBCasConflict (ModelBObserved actual existing))
          ModelBInitializeGuarded {} ->
            pure (ModelBCasRefusedCorrupt "guarded journal initialization is invalid")
          ModelBReplaceGuarded {} ->
            pure (ModelBCasRefusedCorrupt "guarded journal replacement is invalid")
    }
 where
  apply version journal = do
    modifyIORef' store (const (Just (version, journal)))
    pure (ModelBCasApplied version journal)

must :: (Show errorValue) => Either errorValue value -> value
must = either (error . show) id
