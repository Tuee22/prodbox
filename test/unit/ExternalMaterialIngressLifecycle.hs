{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module ExternalMaterialIngressLifecycle
  ( externalMaterialIngressLifecycleSuite
  )
where

import Control.Exception
  ( AsyncException (ThreadKilled)
  , throwIO
  , try
  )
import Data.Aeson (encode)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy.Char8 qualified as LazyByteString8
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.CLI.Rke2 (externalMaterialRequestForObservation)
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
  , ExternalMaterialIngressRequest (..)
  , ExternalMaterialIngressResponse (..)
  , ExternalMaterialPodObservation (..)
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
  ( RetainedMaterialDeliveryWireResponse (..)
  )
import Prodbox.Lifecycle.CredentialProvisioner.ExternalIngress
  ( ExternalMaterialIngressIntent
  , ExternalMaterialIngressPhase (..)
  , ExternalMaterialTargetReceipt
  , SignedExternalAcmeEabPermit
  , externalMaterialIngressIntentRequest
  , externalMaterialIngressJobIntent
  , mkExternalMaterialIngressIntent
  , mkExternalMaterialJobBinding
  , mkExternalMaterialTargetReceipt
  , mkSignedExternalAcmeEabPermit
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
  ( CredentialProvisionerJobCreateRecovery (..)
  , CredentialProvisionerJobError (..)
  , ExternalMaterialJobAttestation
  , attestExternalMaterialJobObservation
  , credentialProvisionerJobDeleteOptions
  , externalMaterialJobAttestedJobUid
  , externalMaterialJobAttestedPodUid
  , externalMaterialJobAttestedServiceAccountUid
  , recoverCredentialProvisionerExternalJobCreateWith
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( OperatorMaterialAction (InstallOperatorMaterial)
  , OperatorMaterialIngressSchema (ExternalAcmeEabIngress)
  , mkOperatorMaterialOperationId
  , mkOperatorMaterialPermitId
  , operatorMaterialRequestDigest
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
      deliveries <- newIORef (0 :: Int)
      let delivery =
            retainedMaterialDeliveryClientWith $ \_ -> do
              modifyIORef' deliveries (+ 1)
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
      readIORef deliveries `shouldReturn` 1

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
  must
    ( mkExternalMaterialIngressIntent
        InstallOperatorMaterial
        (must (mkOperatorMaterialOperationId fixtureOperationId))
        (must (mkCredentialGeneration 1))
        (must (mkOperatorMaterialPermitId fixturePermitIdText))
        (must (mkCredentialProvisionerImageDigest fixtureImageDigestText))
        fixtureDeadline
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
        "vault:v1:opaque-eab-source-commitment"
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        7
    )

fixtureSignedPermit :: SignedExternalAcmeEabPermit
fixtureSignedPermit =
  must
    ( mkSignedExternalAcmeEabPermit
        fixtureIntent
        ( must
            ( mkExternalMaterialJobBinding
                fixtureJobName
                fixtureJobUidText
                fixturePodUidText
                fixtureImageDigestText
                fixtureServiceAccountText
                fixtureServiceAccountUidText
                90
            )
        )
        "fixture-signature"
    )

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
fixtureJobUidText = "f4d16d4a-2b04-48a6-bb02-aef624aec469"

fixturePodUidText :: Text
fixturePodUidText = "2c136199-c7cc-48bf-b78f-a3dc96d78695"

fixtureServiceAccountUidText :: Text
fixtureServiceAccountUidText = "80fb8022-dc57-469f-a0b8-d9cfa06a3c3d"

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
