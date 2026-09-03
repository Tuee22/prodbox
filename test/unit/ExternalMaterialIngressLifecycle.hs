{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module ExternalMaterialIngressLifecycle
  ( externalMaterialIngressLifecycleSuite
  )
where

import Codec.Serialise (Serialise, serialise)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , throwIO
  , try
  )
import Data.Aeson (encode)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.ByteString.Lazy.Char8 qualified as LazyByteString8
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Vector qualified as Vector
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.CLI.Rke2 (externalMaterialRequestForObservation)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
  )
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal (CallerOperatorCli))
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.ExternalMaterialIngressClient
  ( ExternalMaterialIngressClient
  , ExternalMaterialIngressClientError (..)
  , mkExternalMaterialIngressClient
  , observeCurrentExternalMaterialIngress
  )
import Prodbox.ControlPlane.ExternalMaterialIngressEndpoint
  ( ExternalMaterialIngressAction (ExternalMaterialInstall, ExternalMaterialRotate)
  , ExternalMaterialIngressChallenge (..)
  , ExternalMaterialIngressObservation (..)
  , ExternalMaterialIngressReceiptRecovery (..)
  , ExternalMaterialIngressReceiptRecoveryResult (..)
  , ExternalMaterialIngressRepository (..)
  , ExternalMaterialIngressRequest (..)
  , ExternalMaterialIngressResponse (..)
  , ExternalMaterialIngressSnapshot (..)
  , ExternalMaterialPodObservation (..)
  , externalMaterialIngressAuthenticatedHandler
  , externalMaterialIngressResponseMaximumBytes
  )
import Prodbox.ControlPlane.ExternalMaterialIngressWorkflow
  ( ExternalMaterialIngressWorkflowError (..)
  , ExternalMaterialIngressWorkflowRequest (..)
  , ExternalMaterialJobBoundary (..)
  , runExternalMaterialIngressWorkflow
  , runExternalMaterialIngressWorkflowWithDelivery
  )
import Prodbox.ControlPlane.RetainedMaterialDeliveryClient
  ( retainedMaterialDeliveryClientWith
  )
import Prodbox.ControlPlane.RetainedMaterialDeliveryEndpoint
  ( RetainedMaterialDeliveryWireFields (..)
  , RetainedMaterialDeliveryWireRequest (..)
  , RetainedMaterialDeliveryWireResponse (..)
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (LifecycleExternalMaterialIngress)
  )
import Prodbox.ControlPlane.TargetRetainedMaterialSourceClient
  ( TargetRetainedMaterialSourceClientError (..)
  , renderTargetRetainedMaterialSourceClientCause
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (ReplyOk))
import Prodbox.Lifecycle.CheckpointAuthority (ModelBCodec (..))
import Prodbox.Lifecycle.CredentialProvisioner.ExternalIngress
  ( ExternalMaterialIngressIntent
  , ExternalMaterialIngressPhase (..)
  , ExternalMaterialIngressState
  , ExternalMaterialIngressTransitionError (..)
  , ExternalMaterialJobBinding
  , ExternalMaterialTargetReceipt
  , ExternalMaterialTargetReceiptEnvelopeError (..)
  , ExternalMaterialTargetReceiptError (..)
  , SignedExternalAcmeEabPermit
  , commitExternalMaterialIngressIntent
  , commitExternalMaterialIngressIntentRenewal
  , commitExternalMaterialJobBinding
  , commitExternalMaterialSignedPermit
  , encodeExternalMaterialTargetReceiptTextEnvelope
  , externalMaterialIngressCurrentIntent
  , externalMaterialIngressCurrentReceipt
  , externalMaterialIngressIntentDeadline
  , externalMaterialIngressIntentRequest
  , externalMaterialIngressJobIntent
  , externalMaterialIngressPhase
  , externalMaterialIngressStateCodec
  , initialExternalMaterialIngressState
  , mkExternalMaterialIngressIntent
  , mkExternalMaterialJobBinding
  , mkExternalMaterialTargetReceipt
  , mkSignedExternalAcmeEabPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.ExternalMaterialWorker
  ( ExternalMaterialWorkerTerminalCause (..)
  , ExternalMaterialWorkerTerminalLineDisposition (..)
  , classifyExternalMaterialWorkerTerminalCapture
  , renderExternalMaterialWorkerTerminalCause
  )
import Prodbox.Lifecycle.CredentialProvisioner.Kubernetes
  ( CredentialProvisionerJobUid
  , RawCredentialProvisionerPodObservation (..)
  , credentialProvisionerIntentServiceAccount
  , credentialProvisionerJobName
  , credentialProvisionerPodUidText
  , credentialProvisionerServiceAccountText
  , credentialProvisionerServiceAccountUidText
  , mkCredentialProvisionerImageDigest
  , mkCredentialProvisionerJobUid
  )
import Prodbox.Lifecycle.CredentialProvisioner.KubernetesJob
  ( CredentialProvisionerJobConnection (..)
  , CredentialProvisionerJobCreateRecovery (..)
  , CredentialProvisionerJobError (..)
  , ExternalMaterialJobAttestation
  , ExternalMaterialTargetReceiptCaptureSource (..)
  , attestExternalMaterialJobObservation
  , credentialProvisionerAttachSubprocess
  , credentialProvisionerJobDeleteMaximumInputBytes
  , credentialProvisionerJobDeleteOptions
  , decodeExternalMaterialTargetReceiptCapture
  , externalMaterialJobAttestedJobUid
  , externalMaterialJobAttestedPodUid
  , externalMaterialJobAttestedServiceAccountUid
  , recoverCredentialProvisionerExternalJobCreateWith
  , renderCredentialProvisionerExternalJob
  , renderExternalMaterialReceiptTransportObservation
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( OperatorMaterialAction (InstallOperatorMaterial)
  , OperatorMaterialIngressSchema (ExternalAcmeEabIngress)
  , encodeOperatorMaterialRequest
  , mkOperatorMaterialOperationId
  , mkOperatorMaterialPermitId
  , operatorMaterialRequestDigest
  )
import Prodbox.Lifecycle.CredentialProvisioner.RuntimeSecurity
  ( credentialProvisionerPodSecurityContext
  )
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityManifestSigner (..)
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  , authorityTimeMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( mkCredentialGeneration
  , targetValueDigestText
  )
import Prodbox.Subprocess (Subprocess (subprocessArguments))
import System.Exit (ExitCode (..))
import TestSupport

data LifecycleEvent
  = AuthorityPrepared
  | AuthorityObserved
  | JobRecovered
  | JobCreated
  | JobObserved
  | AuthorityAuthorized
  | MaterialAttached
  | ReceiptRecovered
  | AuthorityCompleted
  | JobDeleted
  | JobAbsenceObserved
  deriving stock (Eq, Show)

data LegacyExternalMaterialReceiptV2 = LegacyExternalMaterialReceiptV2
  { legacyReceiptPermitId :: !Text
  , legacyReceiptRequestDigest :: !Text
  , legacyReceiptGeneration :: !Natural
  , legacyReceiptCommitment :: !Text
  , legacyReceiptCiphertextDigest :: !Text
  , legacyReceiptReadBackVersion :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data LegacyExternalMaterialIntentV2 = LegacyExternalMaterialIntentV2
  { legacyIntentRequest :: !ByteString
  , legacyIntentPermitId :: !Text
  , legacyIntentImageDigest :: !Text
  , legacyIntentDeadlineMicros :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data LegacyExternalMaterialStateEnvelopeV2 = LegacyExternalMaterialStateEnvelopeV2
  { legacyEnvelopeVersion :: !Word16
  , legacyEnvelopePhase :: !ExternalMaterialIngressPhase
  , legacyEnvelopeIntent :: !(Maybe LegacyExternalMaterialIntentV2)
  , legacyEnvelopeBinding :: !(Maybe ExternalMaterialJobBinding)
  , legacyEnvelopePermit :: !(Maybe SignedExternalAcmeEabPermit)
  , legacyEnvelopeReceipt :: !(Maybe LegacyExternalMaterialReceiptV2)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data FixtureAuthorityActions = FixtureAuthorityActions
  { fixtureObserve
      :: IO
           ( Either
               ExternalMaterialIngressClientError
               ExternalMaterialIngressObservation
           )
  , fixtureAuthorize
      :: IO (Either ExternalMaterialIngressClientError ByteString)
  , fixtureComplete
      :: IO
           ( Either
               ExternalMaterialIngressClientError
               ExternalMaterialTargetReceipt
           )
  }

data FixtureJobActions = FixtureJobActions
  { fixtureCreate
      :: IO (Either CredentialProvisionerJobError CredentialProvisionerJobUid)
  , fixtureRecover
      :: IO
           ( Either
               CredentialProvisionerJobError
               CredentialProvisionerJobCreateRecovery
           )
  , fixtureAttach
      :: IO
           ( Either
               CredentialProvisionerJobError
               ExternalMaterialTargetReceipt
           )
  , fixtureRecoverReceipt
      :: IO
           ( Either
               CredentialProvisionerJobError
               ExternalMaterialTargetReceipt
           )
  , fixtureDelete :: IO (Either CredentialProvisionerJobError ())
  , fixtureObserveAbsence :: IO (Either CredentialProvisionerJobError ())
  }

currentAbsenceHandler
  :: ExternalMaterialIngressRequest
  -> IO
       ( Either
           ExternalMaterialIngressClientError
           ExternalMaterialIngressResponse
       )
currentAbsenceHandler request = case request of
  ObserveCurrentExternalMaterialIngress ->
    pure (Right (ExternalMaterialIngressCurrentObserved Nothing))
  _ -> error "unexpected operation-selected request"

externalMaterialIngressLifecycleSuite :: SuiteBuilder ()
externalMaterialIngressLifecycleSuite =
  describe "Sprint 4.50 external-material one-shot lifecycle" $ do
    it "classifies retained-source refusals without rendering response detail" $ do
      map
        renderTargetRetainedMaterialSourceClientCause
        [ TargetRetainedMaterialSourceClientRefused
            "retained-material observation deadline elapsed"
        , TargetRetainedMaterialSourceClientRefused "retained source operation mismatch"
        , TargetRetainedMaterialSourceClientRefused "retained source generation mismatch"
        , TargetRetainedMaterialSourceClientRefused "retained source is absent"
        , TargetRetainedMaterialSourceClientRefused "private detail"
        , TargetRetainedMaterialSourceClientUnavailable
            "retained source digest mismatches metadata"
        , TargetRetainedMaterialSourceClientUnavailable "retained source is corrupt"
        , TargetRetainedMaterialSourceClientUnavailable "retained source is unobservable"
        , TargetRetainedMaterialSourceClientUnavailable "private detail"
        , TargetRetainedMaterialSourceClientUnexpectedResponse
        ]
        `shouldBe` [ "deadline-elapsed"
                   , "operation-mismatch"
                   , "generation-mismatch"
                   , "source-absent"
                   , "refused-other"
                   , "digest-mismatch"
                   , "source-corrupt"
                   , "source-unobservable"
                   , "unavailable-other"
                   , "unexpected-response"
                   ]

    it "migrates a completed v2 receipt to permit-committed recovery" $ do
      let request = externalMaterialIngressIntentRequest fixtureEndpointIntent
          legacy =
            LegacyExternalMaterialStateEnvelopeV2
              { legacyEnvelopeVersion = 2
              , legacyEnvelopePhase = ExternalMaterialIngressReceiptCommitted
              , legacyEnvelopeIntent =
                  Just
                    LegacyExternalMaterialIntentV2
                      { legacyIntentRequest = encodeOperatorMaterialRequest request
                      , legacyIntentPermitId = fixtureEndpointPermitIdText
                      , legacyIntentImageDigest = fixtureImageDigestText
                      , legacyIntentDeadlineMicros = authorityTimeMicros fixtureDeadline
                      }
              , legacyEnvelopeBinding = Just fixtureEndpointJobBinding
              , legacyEnvelopePermit = Just fixtureEndpointSignedPermit
              , legacyEnvelopeReceipt =
                  Just
                    LegacyExternalMaterialReceiptV2
                      { legacyReceiptPermitId = fixtureEndpointPermitIdText
                      , legacyReceiptRequestDigest =
                          targetValueDigestText (operatorMaterialRequestDigest request)
                      , legacyReceiptGeneration = 1
                      , legacyReceiptCommitment =
                          "vault:v1:opaque-endpoint-eab-source-commitment"
                      , legacyReceiptCiphertextDigest =
                          "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
                      , legacyReceiptReadBackVersion = 8
                      }
              }
          legacyBytes = LazyByteString.toStrict (serialise legacy)
          codec = externalMaterialIngressStateCodec (256 * 1024)
      case decodeModelBValue codec legacyBytes of
        Left detail -> expectationFailure ("expected v2 migration, got " ++ detail)
        Right migrated -> do
          externalMaterialIngressPhase migrated
            `shouldBe` ExternalMaterialIngressPermitCommitted
          externalMaterialIngressCurrentReceipt migrated `shouldBe` Nothing
          case encodeModelBValue codec migrated of
            Left detail -> expectationFailure ("expected v3 encoding, got " ++ detail)
            Right currentBytes -> do
              currentBytes `shouldSatisfy` (/= legacyBytes)
              fmap externalMaterialIngressPhase (decodeModelBValue codec currentBytes)
                `shouldBe` Right ExternalMaterialIngressPermitCommitted

    it "renders the shared explicit non-root Pod identity" $ do
      let manifest =
            renderCredentialProvisionerExternalJob
              fixtureImageRepository
              fixtureHeartbeatMicros
              fixtureIntent
      fmap externalJobPodSecurityContext manifest
        `shouldBe` Right (Just credentialProvisionerPodSecurityContext)
      fmap externalJobContainerImage manifest
        `shouldBe` Right
          ( Just
              (fixtureImageRepository <> "@" <> fixtureImageDigestText)
          )
      fmap (LazyByteString.toStrict . encode) manifest
        `shouldSatisfy` either
          (const False)
          (not . ByteString.isInfixOf "/var/run/secrets/kubernetes.io/serviceaccount")
      fmap (LazyByteString.toStrict . encode) manifest
        `shouldSatisfy` either
          (const False)
          (ByteString.isInfixOf "\"stdinOnce\":true")
      fmap (LazyByteString.toStrict . encode) manifest
        `shouldSatisfy` either
          (const False)
          (ByteString.isInfixOf "\"ephemeral-storage\":\"256Mi\"")
      renderCredentialProvisionerExternalJob
        (fixtureImageRepository <> "@" <> fixtureImageDigestText)
        fixtureHeartbeatMicros
        fixtureIntent
        `shouldBe` Left
          (CredentialProvisionerJobRenderInvalid "image repository already contains a digest")

    it "keeps a full EAB permit out of Kubernetes labels and in exact annotations" $ do
      let fullPermit = "eab-" <> Text.replicate 64 "a"
          longPermitIntent =
            must
              ( mkExternalMaterialIngressIntent
                  InstallOperatorMaterial
                  (must (mkOperatorMaterialOperationId fixtureOperationId))
                  (must (mkCredentialGeneration 1))
                  (must (mkOperatorMaterialPermitId fullPermit))
                  (must (mkCredentialProvisionerImageDigest fixtureImageDigestText))
                  fixtureDeadline
              )
          manifest =
            must
              ( renderCredentialProvisionerExternalJob
                  fixtureImageRepository
                  fixtureHeartbeatMicros
                  longPermitIntent
              )
          (jobLabels, jobAnnotations, podLabels, podAnnotations) =
            externalJobMetadata manifest
      all ((<= 63) . Text.length . snd) (jobLabels <> podLabels) `shouldBe` True
      lookup "prodbox.io/permit-id" jobLabels `shouldBe` Nothing
      lookup "prodbox.io/permit-id" podLabels `shouldBe` Nothing
      lookup "prodbox.io/permit-id" jobAnnotations `shouldBe` Just fullPermit
      lookup "prodbox.io/permit-id" podAnnotations `shouldBe` Just fullPermit

    it "observes authoritative current absence without selecting an operation" $ do
      let client = mkExternalMaterialIngressClient currentAbsenceHandler
      observeCurrentExternalMaterialIngress client `shouldReturn` Right Nothing

    it "selects install, exact retained replay, and next-generation rotation from Authority state" $ do
      let absent =
            externalMaterialRequestForObservation
              fixtureOperationId
              fixtureImageRepository
              fixtureImageDigestText
              fixtureHeartbeatMicros
              (Right Nothing :: Either () (Maybe ExternalMaterialIngressObservation))
      fmap externalMaterialWorkflowAction absent `shouldBe` Right ExternalMaterialInstall
      fmap externalMaterialWorkflowGeneration absent `shouldBe` Right 1
      let retainedDeadline = fixtureHeartbeatMicros + 30 * 60 * 1000000
          retainedObservation =
            fixtureReceiptObservation
              { externalMaterialObservedChallenge =
                  (externalMaterialObservedChallenge fixtureReceiptObservation)
                    { externalMaterialChallengeDeadlineMicros = retainedDeadline
                    }
              }
          replay =
            externalMaterialRequestForObservation
              fixtureOperationId
              fixtureImageRepository
              "ignored-new-image"
              999
              (Right (Just retainedObservation) :: Either () (Maybe ExternalMaterialIngressObservation))
      fmap externalMaterialWorkflowDeadline replay
        `shouldBe` Right (authorityTimeFromMicros retainedDeadline)
      fmap externalMaterialWorkflowHeartbeatMicros replay `shouldBe` Right fixtureHeartbeatMicros
      let rotation =
            externalMaterialRequestForObservation
              "different-material-operation"
              fixtureImageRepository
              fixtureImageDigestText
              fixtureHeartbeatMicros
              (Right (Just retainedObservation) :: Either () (Maybe ExternalMaterialIngressObservation))
      fmap externalMaterialWorkflowAction rotation `shouldBe` Right ExternalMaterialRotate
      fmap externalMaterialWorkflowGeneration rotation `shouldBe` Right 2

      let expiredIntentObservation =
            fixtureIntentObservation
              { externalMaterialObservedChallenge =
                  (externalMaterialObservedChallenge fixtureIntentObservation)
                    { externalMaterialChallengeDeadlineMicros = 100
                    }
              }
          renewal =
            externalMaterialRequestForObservation
              fixtureOperationId
              fixtureImageRepository
              "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
              999
              (Right (Just expiredIntentObservation) :: Either () (Maybe ExternalMaterialIngressObservation))
      fmap externalMaterialWorkflowImageDigest renewal
        `shouldBe` Right "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      fmap externalMaterialWorkflowHeartbeatMicros renewal `shouldBe` Right 999
      fmap (authorityTimeMicros . externalMaterialWorkflowDeadline) renewal
        `shouldBe` Right (999 + 30 * 60 * 1000000)
      let permittedRenewal =
            externalMaterialRequestForObservation
              fixtureOperationId
              fixtureImageRepository
              "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
              1000
              ( Right
                  ( Just
                      expiredIntentObservation
                        { externalMaterialObservedPhase =
                            ExternalMaterialIngressPermitCommitted
                        }
                  )
                  :: Either () (Maybe ExternalMaterialIngressObservation)
              )
      fmap externalMaterialWorkflowImageDigest permittedRenewal
        `shouldBe` Right
          "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      fmap (authorityTimeMicros . externalMaterialWorkflowDeadline) permittedRenewal
        `shouldBe` Right (1000 + 30 * 60 * 1000000)

    it "renews only an expired immutable-equivalent intent-committed attempt" $ do
      let retained = intentAt fixtureImageDigestText 1000 fixtureOperationId
          replacement =
            intentAt
              "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
              3000
              fixtureOperationId
          drifted = intentAt fixtureImageDigestText 3000 "other-operation"
          prepared =
            must
              ( commitExternalMaterialIngressIntent
                  retained
                  initialExternalMaterialIngressState
              )
          renewed =
            commitExternalMaterialIngressIntentRenewal
              (authorityTimeFromMicros 2000)
              retained
              replacement
              prepared
      fmap externalMaterialIngressCurrentIntent renewed
        `shouldBe` Right (Just replacement)
      commitExternalMaterialIngressIntentRenewal
        (authorityTimeFromMicros 900)
        retained
        replacement
        prepared
        `shouldBe` Left ExternalMaterialIngressRenewalDeadlineInvalid
      commitExternalMaterialIngressIntentRenewal
        (authorityTimeFromMicros 2000)
        retained
        drifted
        prepared
        `shouldBe` Left ExternalMaterialIngressRenewalBindingMismatch

    it "requires two separated zero observations before create recovery reports absence" $ do
      observations <-
        newIORef
          [ Right Nothing
          , Right Nothing
          ]
      visibilityWaits <- newIORef (0 :: Int)
      retryWaits <- newIORef (0 :: Int)
      result <-
        recoverCredentialProvisionerExternalJobCreateWith
          3
          (modifyIORef' visibilityWaits (+ 1))
          (modifyIORef' retryWaits (+ 1))
          (pop observations)
      result `shouldBe` Right CredentialProvisionerJobCreateStablyAbsent
      readIORef visibilityWaits `shouldReturn` 1
      readIORef retryWaits `shouldReturn` 0

    it "recovers a late exact Job UID instead of creating a successor" $ do
      observations <-
        newIORef
          [ Right Nothing
          , Right (Just fixtureJobUid)
          ]
      result <-
        recoverCredentialProvisionerExternalJobCreateWith
          3
          (pure ())
          (pure ())
          (pop observations)
      result
        `shouldBe` Right (CredentialProvisionerJobCreateRecovered fixtureJobUid)

    it "closes the exact Job, Pod, and ServiceAccount UID attestation and UID-preconditions deletion" $ do
      externalMaterialJobAttestedJobUid fixtureAttestation
        `shouldBe` fixtureJobUid
      credentialProvisionerPodUidText
        (externalMaterialJobAttestedPodUid fixtureAttestation)
        `shouldBe` fixturePodUidText
      credentialProvisionerServiceAccountUidText
        (externalMaterialJobAttestedServiceAccountUid fixtureAttestation)
        `shouldBe` fixtureServiceAccountUidText
      LazyByteString8.unpack
        (encode (credentialProvisionerJobDeleteOptions fixtureJobUid))
        `shouldContain` ("\"uid\":\"" ++ showText fixtureJobUidText ++ "\"")
      let deletePayload =
            LazyByteString.toStrict
              (encode (credentialProvisionerJobDeleteOptions fixtureJobUid))
      ByteString.length deletePayload `shouldSatisfy` (> 1)
      ByteString.length deletePayload
        `shouldSatisfy` (<= credentialProvisionerJobDeleteMaximumInputBytes)

    it "requests only remote-session bytes from the binary receipt attach" $ do
      let attach =
            credentialProvisionerAttachSubprocess
              CredentialProvisionerJobConnection
                { credentialProvisionerJobEnvironment = Nothing
                , credentialProvisionerJobWorkingDirectory = "."
                , credentialProvisionerJobControllerSubject = Nothing
                }
              fixtureAttestation
      subprocessArguments attach
        `shouldBe` [ "--namespace"
                   , "credential-provisioner"
                   , "attach"
                   , "--quiet"
                   , "--pod-running-timeout=10s"
                   , "-i"
                   , "pod/" <> Text.unpack fixturePodName
                   , "--container"
                   , "external-material-ingress"
                   ]

    it "admits only exact source-specific attach and Pod-log receipt records" $ do
      let envelope = encodeExternalMaterialTargetReceiptTextEnvelope fixtureReceipt
          decodeAttach =
            decodeExternalMaterialTargetReceiptCapture
              ExternalMaterialTargetReceiptFromAttach
          decodeLog =
            decodeExternalMaterialTargetReceiptCapture
              ExternalMaterialTargetReceiptFromPodLog
      decodeAttach ("\n" <> envelope) `shouldBe` Right fixtureReceipt
      decodeLog ("\n" <> envelope <> "\n") `shouldBe` Right fixtureReceipt
      decodeLog ("unrelated-record\n" <> envelope <> "\n")
        `shouldBe` Right fixtureReceipt
      decodeAttach envelope
        `shouldBe` Left ExternalMaterialTargetReceiptEnvelopeInvalid
      decodeAttach ("\n" <> envelope <> "\n")
        `shouldBe` Left ExternalMaterialTargetReceiptEnvelopeInvalid
      decodeLog (envelope <> "\r\n")
        `shouldBe` Left ExternalMaterialTargetReceiptEnvelopeInvalid
      decodeLog (envelope <> "\n" <> envelope <> "\n")
        `shouldBe` Left ExternalMaterialTargetReceiptEnvelopeInvalid
      mkExternalMaterialTargetReceipt
        fixtureSignedPermit
        "not-a-custody-hmac"
        "vault:v1:opaque-eab-source-commitment"
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        7
        `shouldBe` Left ExternalMaterialTargetReceiptSourceReceiptInvalid

    it "classifies only one exact value-free worker terminal line" $ do
      let prefix = "external-material worker refused: " :: ByteString
          cause = ExternalMaterialWorkerTerminalCustodyHandoffUnavailable
          line = prefix <> "custody-handoff-unavailable\n"
          causes =
            [minBound .. maxBound] :: [ExternalMaterialWorkerTerminalCause]
          rendered = map renderExternalMaterialWorkerTerminalCause causes
      renderExternalMaterialWorkerTerminalCause cause
        `shouldBe` "custody-handoff-unavailable"
      length rendered `shouldBe` length (nub rendered)
      map
        ( classifyExternalMaterialWorkerTerminalCapture
            . (prefix <>)
            . (<> "\n")
            . TextEncoding.encodeUtf8
            . renderExternalMaterialWorkerTerminalCause
        )
        causes
        `shouldBe` map ExternalMaterialWorkerTerminalLineUnique causes
      classifyExternalMaterialWorkerTerminalCapture line
        `shouldBe` ExternalMaterialWorkerTerminalLineUnique cause
      classifyExternalMaterialWorkerTerminalCapture
        ("unrelated\n" <> line)
        `shouldBe` ExternalMaterialWorkerTerminalLineUnique cause
      classifyExternalMaterialWorkerTerminalCapture
        (prefix <> "future-cause\n")
        `shouldBe` ExternalMaterialWorkerTerminalLineUnrecognized
      classifyExternalMaterialWorkerTerminalCapture (line <> line)
        `shouldBe` ExternalMaterialWorkerTerminalLinesAmbiguous
      classifyExternalMaterialWorkerTerminalCapture "unrelated\n"
        `shouldBe` ExternalMaterialWorkerTerminalLineNone

    it "renders receipt transport topology without captured values or exit integers" $ do
      let secretMarker = "must-not-render"
          observation =
            renderExternalMaterialReceiptTransportObservation
              ExternalMaterialTargetReceiptFromPodLog
              (ExitFailure 73)
              secretMarker
              ( "external-material worker refused: "
                  <> "session-revocation-failed\n"
              )
      observation
        `shouldBe` "source=pod-log/process=failure/stdout=nonempty/stdout-terminal=none/stderr=nonempty/stderr-terminal=session-revocation-failed"
      observation `shouldSatisfy` (not . Text.isInfixOf "must-not-render")
      observation `shouldSatisfy` (not . Text.isInfixOf "73")

    it "recovers an expired permit-committed effect from retained Target custody before replay" $ do
      stateRef <- newIORef (1 :: Natural, fixtureEndpointPermittedState)
      recoveries <- newIORef (0 :: Natural)
      let repository =
            ExternalMaterialIngressRepository
              { readExternalMaterialIngress = do
                  (revision, state) <- readIORef stateRef
                  pure
                    ( Right
                        ExternalMaterialIngressSnapshot
                          { externalMaterialIngressRevision = revision
                          , externalMaterialIngressSnapshotState = state
                          }
                    )
              , compareAndSwapExternalMaterialIngress = \expected next -> do
                  (revision, _) <- readIORef stateRef
                  if revision /= expected
                    then pure (Left "fixture CAS conflict")
                    else writeIORef stateRef (revision + 1, next) >> pure (Right ())
              }
          recovery =
            ExternalMaterialIngressReceiptRecovery $ \now permit -> do
              now `shouldBe` authorityTimeFromMicros 2000
              permit `shouldBe` fixtureEndpointSignedPermit
              modifyIORef' recoveries (+ 1)
              pure (Right (ExternalMaterialIngressReceiptRecovered fixtureEndpointReceipt))
          unusedSigner =
            AuthorityManifestSigner
              { readAuthorityManifestPublicKey = pure (Left "unused")
              , signAuthorityManifestPayload = \_ -> pure (Left "unused")
              }
          fallback =
            AuthenticatedRoleHandler
              { authenticatedHandlerReadiness = fixtureReadyRoleReadinessSource
              , authenticatedHandlerHandle = \_ _ _ -> pure Nothing
              }
          handler =
            externalMaterialIngressAuthenticatedHandler
              (256 * 1024)
              3
              (pure (Right (authorityTimeFromMicros 2000)))
              fixtureReadyRoleReadinessSource
              repository
              recovery
              unusedSigner
              fallback
          body =
            LazyByteString.toStrict
              ( encodeControlPlaneRequest
                  PrepareExternalMaterialIngress
                    { externalMaterialPrepareAction = ExternalMaterialInstall
                    , externalMaterialPrepareOperationId = fixtureOperationId
                    , externalMaterialPrepareGeneration = 1
                    , externalMaterialPrepareImageDigest = fixtureImageDigestText
                    , externalMaterialPrepareDeadlineMicros =
                        3000
                    }
              )
      response <-
        authenticatedHandlerHandle
          handler
          (verifiedCallerSlotFixture CallerOperatorCli 1)
          LifecycleExternalMaterialIngress
          body
      case response of
        Just (ReplyOk, responseBody) ->
          decodeControlPlaneResponse
            externalMaterialIngressResponseMaximumBytes
            (LazyByteString.fromStrict responseBody)
            `shouldBe` Right
              ( ExternalMaterialIngressRecovered
                  fixtureEndpointChallenge
                  fixtureEndpointReceipt
              )
        other -> expectationFailure ("expected recovered prepare response, got " ++ show other)
      readIORef recoveries `shouldReturn` 1
      (externalMaterialIngressCurrentReceipt . snd <$> readIORef stateRef)
        `shouldReturn` Just fixtureEndpointReceipt

    it "reopens an expired permit only after authoritative target-source absence" $ do
      stateRef <- newIORef (1 :: Natural, fixtureEndpointPermittedState)
      recoveries <- newIORef (0 :: Natural)
      let repository =
            ExternalMaterialIngressRepository
              { readExternalMaterialIngress = do
                  (revision, state) <- readIORef stateRef
                  pure
                    ( Right
                        ExternalMaterialIngressSnapshot
                          { externalMaterialIngressRevision = revision
                          , externalMaterialIngressSnapshotState = state
                          }
                    )
              , compareAndSwapExternalMaterialIngress = \expected next -> do
                  (revision, _) <- readIORef stateRef
                  if revision /= expected
                    then pure (Left "fixture CAS conflict")
                    else writeIORef stateRef (revision + 1, next) >> pure (Right ())
              }
          recovery =
            ExternalMaterialIngressReceiptRecovery $ \now permit -> do
              now `shouldBe` authorityTimeFromMicros 2000
              permit `shouldBe` fixtureEndpointSignedPermit
              modifyIORef' recoveries (+ 1)
              pure (Right ExternalMaterialIngressSourcePositivelyAbsent)
          unusedSigner =
            AuthorityManifestSigner
              { readAuthorityManifestPublicKey = pure (Left "unused")
              , signAuthorityManifestPayload = \_ -> pure (Left "unused")
              }
          fallback =
            AuthenticatedRoleHandler
              { authenticatedHandlerReadiness = fixtureReadyRoleReadinessSource
              , authenticatedHandlerHandle = \_ _ _ -> pure Nothing
              }
          handler =
            externalMaterialIngressAuthenticatedHandler
              (256 * 1024)
              3
              (pure (Right (authorityTimeFromMicros 2000)))
              fixtureReadyRoleReadinessSource
              repository
              recovery
              unusedSigner
              fallback
          renewedDeadline = 3000
          renewedChallenge =
            fixtureEndpointChallenge
              { externalMaterialChallengeDeadlineMicros = renewedDeadline
              }
          body =
            LazyByteString.toStrict
              ( encodeControlPlaneRequest
                  PrepareExternalMaterialIngress
                    { externalMaterialPrepareAction = ExternalMaterialInstall
                    , externalMaterialPrepareOperationId = fixtureOperationId
                    , externalMaterialPrepareGeneration = 1
                    , externalMaterialPrepareImageDigest = fixtureImageDigestText
                    , externalMaterialPrepareDeadlineMicros = renewedDeadline
                    }
              )
      response <-
        authenticatedHandlerHandle
          handler
          (verifiedCallerSlotFixture CallerOperatorCli 1)
          LifecycleExternalMaterialIngress
          body
      case response of
        Just (ReplyOk, responseBody) ->
          decodeControlPlaneResponse
            externalMaterialIngressResponseMaximumBytes
            (LazyByteString.fromStrict responseBody)
            `shouldBe` Right (ExternalMaterialIngressPrepared renewedChallenge)
        other -> expectationFailure ("expected absence-authorized retry, got " ++ show other)
      readIORef recoveries `shouldReturn` 1
      (_, recoveredState) <- readIORef stateRef
      externalMaterialIngressPhase recoveredState
        `shouldBe` ExternalMaterialIngressIntentCommitted
      fmap
        (authorityTimeMicros . externalMaterialIngressIntentDeadline)
        (externalMaterialIngressCurrentIntent recoveredState)
        `shouldBe` Just renewedDeadline
      externalMaterialIngressCurrentReceipt recoveredState `shouldBe` Nothing

    it "does not create a Job when the committed Authority observation is unavailable" $ do
      events <- newIORef []
      let unavailable = ExternalMaterialIngressClientUnavailable "observation unavailable"
          authority =
            fixtureAuthorityClient
              events
              defaultAuthorityActions
                { fixtureObserve = pure (Left unavailable)
                }
      result <-
        runExternalMaterialIngressWorkflow
          authority
          (unexpectedJobBoundary events)
          fixtureWorkflowRequest
          fixtureIngressFrame
      result
        `shouldBe` Left (ExternalMaterialWorkflowAuthorityFailed unavailable)
      readIORef events
        `shouldReturn` [AuthorityPrepared, AuthorityObserved]

    it "commits the retained EAB delivery through the same authenticated Authority transport" $ do
      events <- newIORef []
      deliveries <- newIORef []
      let delivery =
            retainedMaterialDeliveryClientWith $ \request -> do
              modifyIORef' deliveries (request :)
              pure
                ( Right
                    RetainedMaterialDeliveryApplied
                      { wireRetainedReceiptOperationId = "delivery-operation"
                      , wireRetainedReceiptSource = "source-receipt"
                      , wireRetainedReceiptTarget = "home"
                      , wireRetainedReceiptGeneration = 1
                      , wireRetainedReceiptTargetVersion = 9
                      , wireRetainedReceiptCommitment = "target-commitment"
                      }
                )
      result <-
        runExternalMaterialIngressWorkflowWithDelivery
          (fixtureAuthorityClient events defaultAuthorityActions)
          delivery
          "home"
          (fixtureJobBoundary events defaultJobActions)
          fixtureWorkflowRequest
          fixtureIngressFrame
      result `shouldBe` Right fixtureReceipt
      observedDeliveries <- readIORef deliveries
      case observedDeliveries of
        [DeliverRetainedAcmeEab fields] ->
          wireRetainedSourceReceipt fields
            `shouldBe` "vault:v1:opaque-eab-source-receipt"
        other -> expectationFailure ("expected one retained EAB delivery, got " ++ show other)

    it "recovers an ambiguous create by exact UID and accepts response-lost deletion only after absence" $ do
      events <- newIORef []
      recoveries <-
        newIORef
          [ Right CredentialProvisionerJobCreateStablyAbsent
          , Right (CredentialProvisionerJobCreateRecovered fixtureJobUid)
          ]
      let jobs =
            fixtureJobBoundary
              events
              defaultJobActions
                { fixtureCreate = throwIO (userError "create response lost")
                , fixtureRecover = pop recoveries
                , fixtureDelete =
                    pure
                      ( Left
                          ( CredentialProvisionerJobDeleteFailed
                              "delete response lost"
                          )
                      )
                }
      result <-
        runExternalMaterialIngressWorkflow
          (fixtureAuthorityClient events defaultAuthorityActions)
          jobs
          fixtureWorkflowRequest
          fixtureIngressFrame
      result `shouldBe` Right fixtureReceipt
      readIORef events
        `shouldReturn` [ AuthorityPrepared
                       , AuthorityObserved
                       , JobRecovered
                       , JobCreated
                       , JobRecovered
                       , JobObserved
                       , AuthorityAuthorized
                       , MaterialAttached
                       , AuthorityCompleted
                       , JobDeleted
                       , JobAbsenceObserved
                       ]

    it "recovers worker and Authority response loss from committed receipts" $ do
      events <- newIORef []
      observations <-
        newIORef
          [ Right fixtureIntentObservation
          , Right fixtureReceiptObservation
          ]
      let authority =
            fixtureAuthorityClient
              events
              defaultAuthorityActions
                { fixtureObserve = pop observations
                , fixtureComplete =
                    pure
                      ( Left
                          ( ExternalMaterialIngressClientUnavailable
                              "completion response lost"
                          )
                      )
                }
          jobs =
            fixtureJobBoundary
              events
              defaultJobActions
                { fixtureAttach =
                    pure
                      ( Left
                          ( CredentialProvisionerJobAttachFailed
                              "attach response lost"
                          )
                      )
                }
      result <-
        runExternalMaterialIngressWorkflow
          authority
          jobs
          fixtureWorkflowRequest
          fixtureIngressFrame
      result `shouldBe` Right fixtureReceipt
      readIORef events
        `shouldReturn` [ AuthorityPrepared
                       , AuthorityObserved
                       , JobRecovered
                       , JobObserved
                       , AuthorityAuthorized
                       , MaterialAttached
                       , ReceiptRecovered
                       , AuthorityCompleted
                       , AuthorityObserved
                       , JobDeleted
                       , JobAbsenceObserved
                       ]

    it "does not replace a non-empty invalid attach capture with Pod-log output" $ do
      events <- newIORef []
      let jobs =
            fixtureJobBoundary
              events
              defaultJobActions
                { fixtureAttach =
                    pure
                      ( Left
                          ( CredentialProvisionerJobReceiptInvalid
                              "non-empty invalid capture"
                          )
                      )
                }
      result <-
        runExternalMaterialIngressWorkflow
          (fixtureAuthorityClient events defaultAuthorityActions)
          jobs
          fixtureWorkflowRequest
          fixtureIngressFrame
      result
        `shouldBe` Left
          ( ExternalMaterialWorkflowJobFailed
              (CredentialProvisionerJobReceiptInvalid "non-empty invalid capture")
          )
      observedEvents <- readIORef events
      observedEvents `shouldSatisfy` (notElem ReceiptRecovered)

    it "replays a committed receipt without creating a successor Job" $ do
      events <- newIORef []
      let authority =
            fixtureAuthorityClient
              events
              defaultAuthorityActions
                { fixtureObserve = pure (Right fixtureReceiptObservation)
                }
          jobs =
            fixtureJobBoundary
              events
              defaultJobActions
                { fixtureRecover =
                    pure (Right CredentialProvisionerJobCreateStablyAbsent)
                }
      result <-
        runExternalMaterialIngressWorkflow
          authority
          jobs
          fixtureWorkflowRequest
          fixtureIngressFrame
      result `shouldBe` Right fixtureReceipt
      readIORef events
        `shouldReturn` [AuthorityPrepared, AuthorityObserved, JobRecovered]

    it "suppresses a valid receipt when exact stable absence cannot be proven" $ do
      events <- newIORef []
      let jobs =
            fixtureJobBoundary
              events
              defaultJobActions
                { fixtureObserveAbsence =
                    pure (Left CredentialProvisionerJobStillPresent)
                }
      result <-
        runExternalMaterialIngressWorkflow
          (fixtureAuthorityClient events defaultAuthorityActions)
          jobs
          fixtureWorkflowRequest
          fixtureIngressFrame
      result
        `shouldBe` Left
          ( ExternalMaterialWorkflowCleanupFailed
              CredentialProvisionerJobStillPresent
          )

    it "cleans the exact Job and preserves cancellation after a committed worker effect" $ do
      events <- newIORef []
      observations <-
        newIORef
          [ Right fixtureIntentObservation
          , Right fixtureReceiptObservation
          ]
      let authority =
            fixtureAuthorityClient
              events
              defaultAuthorityActions {fixtureObserve = pop observations}
          jobs =
            fixtureJobBoundary
              events
              defaultJobActions {fixtureAttach = throwIO ThreadKilled}
      outcome <-
        try
          ( runExternalMaterialIngressWorkflow
              authority
              jobs
              fixtureWorkflowRequest
              fixtureIngressFrame
          )
          :: IO
               ( Either
                   AsyncException
                   ( Either
                       ExternalMaterialIngressWorkflowError
                       ExternalMaterialTargetReceipt
                   )
               )
      outcome `shouldBe` Left ThreadKilled
      readIORef events
        `shouldReturn` [ AuthorityPrepared
                       , AuthorityObserved
                       , JobRecovered
                       , JobObserved
                       , AuthorityAuthorized
                       , MaterialAttached
                       , AuthorityObserved
                       , JobDeleted
                       , JobAbsenceObserved
                       ]

    it "still proves absence and then rethrows cancellation delivered by delete" $ do
      events <- newIORef []
      let jobs =
            fixtureJobBoundary
              events
              defaultJobActions {fixtureDelete = throwIO ThreadKilled}
      outcome <-
        try
          ( runExternalMaterialIngressWorkflow
              (fixtureAuthorityClient events defaultAuthorityActions)
              jobs
              fixtureWorkflowRequest
              fixtureIngressFrame
          )
          :: IO
               ( Either
                   AsyncException
                   ( Either
                       ExternalMaterialIngressWorkflowError
                       ExternalMaterialTargetReceipt
                   )
               )
      outcome `shouldBe` Left ThreadKilled
      readIORef events
        `shouldReturn` [ AuthorityPrepared
                       , AuthorityObserved
                       , JobRecovered
                       , JobObserved
                       , AuthorityAuthorized
                       , MaterialAttached
                       , AuthorityCompleted
                       , JobDeleted
                       , JobAbsenceObserved
                       ]

fixtureAuthorityClient
  :: IORef [LifecycleEvent]
  -> FixtureAuthorityActions
  -> ExternalMaterialIngressClient IO
fixtureAuthorityClient events actions =
  mkExternalMaterialIngressClient handleRequest
 where
  handleRequest request = case request of
    PrepareExternalMaterialIngress action operation generation image deadline -> do
      append events AuthorityPrepared
      action `shouldBe` ExternalMaterialInstall
      operation `shouldBe` fixtureOperationId
      generation `shouldBe` 1
      image `shouldBe` fixtureImageDigestText
      deadline `shouldBe` authorityTimeMicros fixtureDeadline
      pure (Right (ExternalMaterialIngressPrepared fixtureChallenge))
    ObserveExternalMaterialIngress operation -> do
      append events AuthorityObserved
      operation `shouldBe` fixtureOperationId
      fmap ExternalMaterialIngressObserved <$> fixtureObserve actions
    ObserveCurrentExternalMaterialIngress ->
      fmap (ExternalMaterialIngressCurrentObserved . Just) <$> fixtureObserve actions
    AuthorizeExternalMaterialIngress operation pod -> do
      append events AuthorityAuthorized
      operation `shouldBe` fixtureOperationId
      externalMaterialPodJobName pod `shouldBe` fixtureJobName
      externalMaterialPodJobUid pod `shouldBe` fixtureJobUidText
      externalMaterialPodUid pod `shouldBe` fixturePodUidText
      externalMaterialPodServiceAccountUid pod
        `shouldBe` fixtureServiceAccountUidText
      fmap ExternalMaterialIngressAuthorized <$> fixtureAuthorize actions
    CompleteExternalMaterialIngress operation completed -> do
      append events AuthorityCompleted
      operation `shouldBe` fixtureOperationId
      completed `shouldBe` fixtureReceipt
      fmap ExternalMaterialIngressCompleted <$> fixtureComplete actions

fixtureJobBoundary
  :: IORef [LifecycleEvent]
  -> FixtureJobActions
  -> ExternalMaterialJobBoundary IO
fixtureJobBoundary events actions =
  ExternalMaterialJobBoundary
    { createExternalMaterialJob = \repository heartbeat intent -> do
        append events JobCreated
        repository `shouldBe` fixtureImageRepository
        heartbeat `shouldBe` fixtureHeartbeatMicros
        intent `shouldBe` fixtureIntent
        fixtureCreate actions
    , recoverExternalMaterialJob = \intent -> do
        append events JobRecovered
        intent `shouldBe` fixtureIntent
        fixtureRecover actions
    , observeExternalMaterialJob = \intent jobUid -> do
        append events JobObserved
        intent `shouldBe` fixtureIntent
        jobUid `shouldBe` fixtureJobUid
        pure (Right fixtureAttestation)
    , attachExternalMaterialIngress = \attestation permit ingress -> do
        append events MaterialAttached
        attestation `shouldBe` fixtureAttestation
        permit `shouldBe` fixtureEncodedPermit
        ingress `shouldBe` fixtureIngressFrame
        fixtureAttach actions
    , recoverExternalMaterialReceipt = \attestation -> do
        append events ReceiptRecovered
        attestation `shouldBe` fixtureAttestation
        fixtureRecoverReceipt actions
    , deleteExternalMaterialJob = \intent jobUid -> do
        append events JobDeleted
        intent `shouldBe` fixtureIntent
        jobUid `shouldBe` fixtureJobUid
        fixtureDelete actions
    , observeExternalMaterialJobAbsent = \intent jobUid -> do
        append events JobAbsenceObserved
        intent `shouldBe` fixtureIntent
        jobUid `shouldBe` fixtureJobUid
        fixtureObserveAbsence actions
    }

unexpectedJobBoundary :: IORef [LifecycleEvent] -> ExternalMaterialJobBoundary IO
unexpectedJobBoundary events =
  ExternalMaterialJobBoundary
    { createExternalMaterialJob = \_ _ _ -> unexpected "create"
    , recoverExternalMaterialJob = \_ -> unexpected "recover"
    , observeExternalMaterialJob = \_ _ -> unexpected "observe"
    , attachExternalMaterialIngress = \_ _ _ -> unexpected "attach"
    , recoverExternalMaterialReceipt = \_ -> unexpected "receipt recovery"
    , deleteExternalMaterialJob = \_ _ -> unexpected "delete"
    , observeExternalMaterialJobAbsent = \_ _ -> unexpected "absence observation"
    }
 where
  unexpected label = do
    append events JobCreated
    expectationFailure ("unexpected Job boundary call: " ++ label)
    pure
      ( Left
          (CredentialProvisionerJobObservationFailed "unexpected fixture call")
      )

defaultAuthorityActions :: FixtureAuthorityActions
defaultAuthorityActions =
  FixtureAuthorityActions
    { fixtureObserve = pure (Right fixtureIntentObservation)
    , fixtureAuthorize = pure (Right fixtureEncodedPermit)
    , fixtureComplete = pure (Right fixtureReceipt)
    }

defaultJobActions :: FixtureJobActions
defaultJobActions =
  FixtureJobActions
    { fixtureCreate = pure (Right fixtureJobUid)
    , fixtureRecover =
        pure (Right (CredentialProvisionerJobCreateRecovered fixtureJobUid))
    , fixtureAttach = pure (Right fixtureReceipt)
    , fixtureRecoverReceipt = pure (Right fixtureReceipt)
    , fixtureDelete = pure (Right ())
    , fixtureObserveAbsence = pure (Right ())
    }

fixtureWorkflowRequest :: ExternalMaterialIngressWorkflowRequest
fixtureWorkflowRequest =
  ExternalMaterialIngressWorkflowRequest
    { externalMaterialWorkflowAction = ExternalMaterialInstall
    , externalMaterialWorkflowOperationId = fixtureOperationId
    , externalMaterialWorkflowGeneration = 1
    , externalMaterialWorkflowImageRepository = fixtureImageRepository
    , externalMaterialWorkflowImageDigest = fixtureImageDigestText
    , externalMaterialWorkflowDeadline = fixtureDeadline
    , externalMaterialWorkflowHeartbeatMicros = fixtureHeartbeatMicros
    }

fixtureChallenge :: ExternalMaterialIngressChallenge
fixtureChallenge =
  ExternalMaterialIngressChallenge
    { externalMaterialChallengeOperationId = fixtureOperationId
    , externalMaterialChallengePermitId = fixturePermitIdText
    , externalMaterialChallengeRequestDigest = fixtureRequestDigestText
    , externalMaterialChallengeGeneration = 1
    , externalMaterialChallengeJobName = fixtureJobName
    , externalMaterialChallengeImageDigest = fixtureImageDigestText
    , externalMaterialChallengeServiceAccount = fixtureServiceAccountText
    , externalMaterialChallengeDeadlineMicros =
        authorityTimeMicros fixtureDeadline
    }

fixtureIntentObservation :: ExternalMaterialIngressObservation
fixtureIntentObservation =
  ExternalMaterialIngressObservation
    { externalMaterialObservedOperationId = fixtureOperationId
    , externalMaterialObservedPhase = ExternalMaterialIngressIntentCommitted
    , externalMaterialObservedChallenge = fixtureChallenge
    , externalMaterialObservedPermit = Nothing
    , externalMaterialObservedReceipt = Nothing
    }

fixtureReceiptObservation :: ExternalMaterialIngressObservation
fixtureReceiptObservation =
  ExternalMaterialIngressObservation
    { externalMaterialObservedOperationId = fixtureOperationId
    , externalMaterialObservedPhase = ExternalMaterialIngressReceiptCommitted
    , externalMaterialObservedChallenge = fixtureChallenge
    , externalMaterialObservedPermit = Just fixtureEncodedPermit
    , externalMaterialObservedReceipt = Just fixtureReceipt
    }

fixtureIntent :: ExternalMaterialIngressIntent
fixtureIntent =
  intentAt fixtureImageDigestText (authorityTimeMicros fixtureDeadline) fixtureOperationId

intentAt :: Text -> Natural -> Text -> ExternalMaterialIngressIntent
intentAt image deadline operationId =
  must
    ( mkExternalMaterialIngressIntent
        InstallOperatorMaterial
        (must (mkOperatorMaterialOperationId operationId))
        (must (mkCredentialGeneration 1))
        (must (mkOperatorMaterialPermitId fixturePermitIdText))
        (must (mkCredentialProvisionerImageDigest image))
        (authorityTimeFromMicros deadline)
    )

fixtureAttestation :: ExternalMaterialJobAttestation
fixtureAttestation =
  must
    ( attestExternalMaterialJobObservation
        fixtureNow
        fixtureIntent
        fixturePodName
        fixtureRawObservation
    )

fixtureRawObservation :: RawCredentialProvisionerPodObservation
fixtureRawObservation =
  RawCredentialProvisionerPodObservation
    { rawCredentialProvisionerJobName = fixtureJobName
    , rawCredentialProvisionerJobUid = fixtureJobUidText
    , rawCredentialProvisionerPodUid = fixturePodUidText
    , rawCredentialProvisionerImageDigest = fixtureImageDigestText
    , rawCredentialProvisionerServiceAccount = fixtureServiceAccountText
    , rawCredentialProvisionerServiceAccountUid = fixtureServiceAccountUidText
    , rawCredentialProvisionerSchema = ExternalAcmeEabIngress
    , rawCredentialProvisionerPermitId = fixturePermitIdText
    , rawCredentialProvisionerRequestDigest =
        operatorMaterialRequestDigest
          (externalMaterialIngressIntentRequest fixtureIntent)
    , rawCredentialProvisionerPlanBinding = Nothing
    , rawCredentialProvisionerDeadline = fixtureDeadline
    , rawCredentialProvisionerHeartbeat = authorityTimeFromMicros 90
    , rawCredentialProvisionerPhase = "Running"
    , rawCredentialProvisionerContainerReady = True
    , rawCredentialProvisionerRestartCount = 0
    , rawCredentialProvisionerDeletionTimestamp = Nothing
    }

fixtureReceipt :: ExternalMaterialTargetReceipt
fixtureReceipt =
  must
    ( mkExternalMaterialTargetReceipt
        fixtureSignedPermit
        "vault:v1:opaque-eab-source-receipt"
        "vault:v1:opaque-eab-source-commitment"
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        7
    )

fixtureSignedPermit :: SignedExternalAcmeEabPermit
fixtureSignedPermit =
  must
    ( mkSignedExternalAcmeEabPermit
        fixtureIntent
        fixtureJobBinding
        "fixture-signature"
    )

fixtureJobBinding :: ExternalMaterialJobBinding
fixtureJobBinding =
  must
    ( mkExternalMaterialJobBinding
        fixtureJobName
        fixtureJobUidText
        fixturePodUidText
        fixtureImageDigestText
        fixtureServiceAccountText
        fixtureServiceAccountUidText
        90
    )

fixtureEndpointIntent :: ExternalMaterialIngressIntent
fixtureEndpointIntent =
  must
    ( mkExternalMaterialIngressIntent
        InstallOperatorMaterial
        (must (mkOperatorMaterialOperationId fixtureOperationId))
        (must (mkCredentialGeneration 1))
        (must (mkOperatorMaterialPermitId fixtureEndpointPermitIdText))
        (must (mkCredentialProvisionerImageDigest fixtureImageDigestText))
        fixtureDeadline
    )

fixtureEndpointPermitIdText :: Text
fixtureEndpointPermitIdText = "eab-" <> Text.take 64 fixtureRequestDigestText

fixtureEndpointJobBinding :: ExternalMaterialJobBinding
fixtureEndpointJobBinding =
  must
    ( mkExternalMaterialJobBinding
        (credentialProvisionerJobName (externalMaterialIngressJobIntent fixtureEndpointIntent))
        fixtureJobUidText
        fixturePodUidText
        fixtureImageDigestText
        fixtureServiceAccountText
        fixtureServiceAccountUidText
        90
    )

fixtureEndpointSignedPermit :: SignedExternalAcmeEabPermit
fixtureEndpointSignedPermit =
  must
    ( mkSignedExternalAcmeEabPermit
        fixtureEndpointIntent
        fixtureEndpointJobBinding
        "fixture-endpoint-signature"
    )

fixtureEndpointReceipt :: ExternalMaterialTargetReceipt
fixtureEndpointReceipt =
  must
    ( mkExternalMaterialTargetReceipt
        fixtureEndpointSignedPermit
        "vault:v1:opaque-endpoint-eab-source-receipt"
        "vault:v1:opaque-endpoint-eab-source-commitment"
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        8
    )

fixtureEndpointPermittedState :: ExternalMaterialIngressState
fixtureEndpointPermittedState =
  must
    ( commitExternalMaterialSignedPermit
        fixtureEndpointIntent
        fixtureEndpointJobBinding
        fixtureEndpointSignedPermit
        ( must
            ( commitExternalMaterialJobBinding
                fixtureEndpointIntent
                fixtureEndpointJobBinding
                ( must
                    ( commitExternalMaterialIngressIntent
                        fixtureEndpointIntent
                        initialExternalMaterialIngressState
                    )
                )
            )
        )
    )

fixtureEndpointChallenge :: ExternalMaterialIngressChallenge
fixtureEndpointChallenge =
  ExternalMaterialIngressChallenge
    { externalMaterialChallengeOperationId = fixtureOperationId
    , externalMaterialChallengePermitId = fixtureEndpointPermitIdText
    , externalMaterialChallengeRequestDigest = fixtureRequestDigestText
    , externalMaterialChallengeGeneration = 1
    , externalMaterialChallengeJobName =
        credentialProvisionerJobName (externalMaterialIngressJobIntent fixtureEndpointIntent)
    , externalMaterialChallengeImageDigest = fixtureImageDigestText
    , externalMaterialChallengeServiceAccount = fixtureServiceAccountText
    , externalMaterialChallengeDeadlineMicros = authorityTimeMicros fixtureDeadline
    }

fixtureJobUid :: CredentialProvisionerJobUid
fixtureJobUid = must (mkCredentialProvisionerJobUid fixtureJobUidText)

fixtureJobName :: Text
fixtureJobName = credentialProvisionerJobName (externalMaterialIngressJobIntent fixtureIntent)

fixtureServiceAccountText :: Text
fixtureServiceAccountText =
  credentialProvisionerServiceAccountText
    ( credentialProvisionerIntentServiceAccount
        (externalMaterialIngressJobIntent fixtureIntent)
    )

fixturePermitIdText :: Text
fixturePermitIdText = "permit-external-material-ingress"

fixtureRequestDigestText :: Text
fixtureRequestDigestText =
  targetValueDigestText
    (operatorMaterialRequestDigest (externalMaterialIngressIntentRequest fixtureIntent))

fixtureOperationId :: Text
fixtureOperationId = "op-external-material-ingress"

fixtureImageRepository :: Text
fixtureImageRepository = "registry.example/prodbox/credential-provisioner"

fixtureImageDigestText :: Text
fixtureImageDigestText =
  "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

fixtureJobUidText :: Text
fixtureJobUidText = "fixture-job-uid-1"

fixturePodUidText :: Text
fixturePodUidText = "fixture-pod-uid-1"

fixtureServiceAccountUidText :: Text
fixtureServiceAccountUidText = "fixture-service-account-uid-1"

fixturePodName :: Text
fixturePodName = "external-material-ingress-fixture-pod"

fixtureDeadline :: AuthorityTime
fixtureDeadline = authorityTimeFromMicros 1000

fixtureNow :: AuthorityTime
fixtureNow = authorityTimeFromMicros 100

fixtureHeartbeatMicros :: Natural
fixtureHeartbeatMicros = 90

fixtureEncodedPermit :: ByteString
fixtureEncodedPermit = "encoded-permit"

fixtureIngressFrame :: ByteString
fixtureIngressFrame = "opaque-ingress"

externalJobPodSecurityContext :: Aeson.Value -> Maybe Aeson.Value
externalJobPodSecurityContext (Aeson.Object root) = do
  Aeson.Object spec <- AesonKeyMap.lookup "spec" root
  Aeson.Object template <- AesonKeyMap.lookup "template" spec
  Aeson.Object podSpec <- AesonKeyMap.lookup "spec" template
  AesonKeyMap.lookup "securityContext" podSpec
externalJobPodSecurityContext _ = Nothing

externalJobMetadata
  :: Aeson.Value -> ([(Text, Text)], [(Text, Text)], [(Text, Text)], [(Text, Text)])
externalJobMetadata (Aeson.Object root) =
  ( textFields jobLabels
  , textFields jobAnnotations
  , textFields podLabels
  , textFields podAnnotations
  )
 where
  metadata = objectField "metadata" root
  jobLabels = objectField "labels" metadata
  jobAnnotations = objectField "annotations" metadata
  spec = objectField "spec" root
  template = objectField "template" spec
  podMetadata = objectField "metadata" template
  podLabels = objectField "labels" podMetadata
  podAnnotations = objectField "annotations" podMetadata

  objectField key fields =
    case AesonKeyMap.lookup (AesonKey.fromText key) fields of
      Just (Aeson.Object value) -> value
      _ -> error ("missing external Job object field: " ++ Text.unpack key)
  textFields = map textField . AesonKeyMap.toList
  textField (key, Aeson.String textValue) = (AesonKey.toText key, textValue)
  textField _ = error "external Job metadata value is not text"
externalJobMetadata _ = error "external Job manifest is not an object"

externalJobContainerImage :: Aeson.Value -> Maybe Text
externalJobContainerImage (Aeson.Object root) = do
  Aeson.Object spec <- AesonKeyMap.lookup "spec" root
  Aeson.Object template <- AesonKeyMap.lookup "template" spec
  Aeson.Object podSpec <- AesonKeyMap.lookup "spec" template
  Aeson.Array containers <- AesonKeyMap.lookup "containers" podSpec
  Aeson.Object container <- containers Vector.!? 0
  Aeson.String image <- AesonKeyMap.lookup "image" container
  pure image
externalJobContainerImage _ = Nothing

append :: IORef [LifecycleEvent] -> LifecycleEvent -> IO ()
append events event = modifyIORef' events (<> [event])

pop :: IORef [value] -> IO value
pop valuesRef = do
  values <- readIORef valuesRef
  case values of
    [] -> error "external material fixture sequence exhausted"
    value : remaining -> do
      writeIORef valuesRef remaining
      pure value

must :: (Show errorValue) => Either errorValue value -> value
must result = case result of
  Left err -> error (show err)
  Right value -> value

showText :: Text -> String
showText = Text.unpack
