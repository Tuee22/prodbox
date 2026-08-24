{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module AdminActionLifecycle (adminActionLifecycleSuite) where

import Control.Exception
  ( AsyncException (ThreadKilled)
  , throwIO
  , try
  )
import Control.Monad (forM_, when)
import Data.ByteString qualified as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AdminActionClient
  ( AdminActionClient
  , mkAdminActionClient
  )
import Prodbox.ControlPlane.AdminActionEndpoint
  ( AdminActionAuthorityRequest (..)
  , AdminActionAuthorityResponse (..)
  )
import Prodbox.Lifecycle.AdminAction.Authority
  ( AdminActionAuthorityError (..)
  , AdminActionAuthorityRepository (..)
  , AdminActionAuthoritySnapshot (..)
  , AdminActionPrepareRequest (..)
  , completeAdminActionForPermit
  )
import Prodbox.Lifecycle.AdminAction.Coordinator
  ( AdminActionCleanupBinding (..)
  , AdminActionCoordinatorError (..)
  , AdminActionKubernetesBoundary (..)
  , coordinateAdminAction
  )
import Prodbox.Lifecycle.AdminAction.Kubernetes
  ( AdminActionAttestationError (..)
  , RawAdminActionPodObservation (..)
  , attestAdminActionPod
  )
import Prodbox.Lifecycle.AdminAction.Protocol
import Prodbox.Lifecycle.AdminAction.Runner
  ( AdminActionAuditorRecoveryBoundary (..)
  , acquireAdminActionAuditorWith
  )
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeFromMicros)
import Prodbox.Settings (Credentials (..))
import TestSupport

data CancelPoint
  = CancelAfterCreate
  | CancelAfterAttestation
  | CancelAfterAttach
  | CancelAfterComplete
  | DoNotCancel
  deriving stock (Eq, Show)

data LifecycleEvent
  = Created
  | Attached
  | AuthorityCompleted
  | Deleted !(Maybe AdminActionCleanupBinding)
  | AbsenceObserved !(Maybe AdminActionCleanupBinding)
  deriving stock (Eq, Show)

adminActionLifecycleSuite :: SuiteBuilder ()
adminActionLifecycleSuite =
  describe "Sprint 4.50 Admin Action exception-safe lifecycle" $ do
    forM_
      [ CancelAfterCreate
      , CancelAfterAttestation
      , CancelAfterAttach
      , CancelAfterComplete
      ]
      $ \point ->
        it ("cleans the exact Job/Pod and preserves cancellation at " <> show point) $ do
          events <- newIORef []
          outcome <-
            try (runFixture point events (Right ()) (Right True))
              :: IO
                   ( Either
                       AsyncException
                       (Either AdminActionCoordinatorError AdminActionReceipt)
                   )
          outcome `shouldBe` Left ThreadKilled
          observed <- readIORef events
          case point of
            CancelAfterCreate ->
              observed
                `shouldBe` [Created, Deleted Nothing, AbsenceObserved Nothing]
            CancelAfterAttestation ->
              observed
                `shouldBe` [Created, Deleted exactCleanup, AbsenceObserved exactCleanup]
            CancelAfterAttach ->
              observed
                `shouldBe` [ Created
                           , Attached
                           , Deleted exactCleanup
                           , AbsenceObserved exactCleanup
                           ]
            CancelAfterComplete ->
              observed
                `shouldBe` [ Created
                           , Attached
                           , AuthorityCompleted
                           , Deleted exactCleanup
                           , AbsenceObserved exactCleanup
                           ]
            DoNotCancel -> expectationFailure "unreachable fixture branch"

    it "converts a thrown synchronous effect only after exact cleanup" $ do
      events <- newIORef []
      result <- runThrownAttachFixture events
      result `shouldBe` Left AdminActionCoordinatorUnhandledException
      readIORef events
        `shouldReturn` [ Created
                       , Attached
                       , Deleted exactCleanup
                       , AbsenceObserved exactCleanup
                       ]

    it "UID-cleans the exact observed Job and Pod after attestation refusal" $ do
      events <- newIORef []
      result <-
        coordinateAdminAction
          (fixtureClient DoNotCancel events)
          ( observationOnlyKubernetes
              (rawObservation {observedAdminActionAction = "wrong-action"})
              events
              False
          )
          now
          30
          imageReference
          credentials
          prepareRequest
      result
        `shouldBe` Left
          ( AdminActionCoordinatorAttestationFailed
              AdminActionAttestationPermitMetadataMismatch
          )
      readIORef events
        `shouldReturn` [ Created
                       , Deleted exactCleanup
                       , AbsenceObserved exactCleanup
                       ]

    it "UID-cleans the exact observed Job and Pod when attestation is cancelled" $ do
      events <- newIORef []
      outcome <-
        try
          ( coordinateAdminAction
              (fixtureClient DoNotCancel events)
              (observationOnlyKubernetes rawObservation events True)
              now
              30
              imageReference
              credentials
              prepareRequest
          )
          :: IO
               ( Either
                   AsyncException
                   (Either AdminActionCoordinatorError AdminActionReceipt)
               )
      outcome `shouldBe` Left ThreadKilled
      readIORef events
        `shouldReturn` [ Created
                       , Deleted exactCleanup
                       , AbsenceObserved exactCleanup
                       ]

    it "accepts response-lost deletion only when positive absence closes it" $ do
      events <- newIORef []
      result <- runFixture DoNotCancel events (Left "delete response lost") (Right True)
      result `shouldBe` Right receipt
      readIORef events
        `shouldReturn` [ Created
                       , Attached
                       , AuthorityCompleted
                       , Deleted exactCleanup
                       , AbsenceObserved exactCleanup
                       ]

    it "suppresses a valid receipt when deletion response is lost and absence is false" $ do
      events <- newIORef []
      result <- runFixture DoNotCancel events (Left "delete response lost") (Right False)
      result `shouldBe` Left (AdminActionCoordinatorDeleteFailed "delete response lost")

    it "recovers an Authority-completed receipt when worker stdout is lost" $ do
      events <- newIORef []
      state <- newIORef (AdminActionExecutionAuthorized permit)
      applications <- newIORef (0 :: Int)
      completionCalls <- newIORef (0 :: Int)
      result <-
        coordinateAdminAction
          (terminalStateClient state completionCalls)
          (terminalLossKubernetes state applications events False)
          now
          30
          imageReference
          credentials
          prepareRequest
      result `shouldBe` Right receipt
      readIORef applications `shouldReturn` 1
      readIORef completionCalls `shouldReturn` 0
      readIORef events
        `shouldReturn` [ Created
                       , Attached
                       , Deleted exactCleanup
                       , AbsenceObserved exactCleanup
                       ]

    it "replays the same completed receipt without creating a successor Job" $ do
      events <- newIORef []
      state <- newIORef (AdminActionExecutionCompleted permit receipt)
      applications <- newIORef (1 :: Int)
      completionCalls <- newIORef (0 :: Int)
      result <-
        coordinateAdminAction
          (terminalStateClient state completionCalls)
          (terminalLossKubernetes state applications events False)
          now
          30
          imageReference
          credentials
          prepareRequest
      result `shouldBe` Right receipt
      readIORef applications `shouldReturn` 1
      readIORef completionCalls `shouldReturn` 0
      readIORef events
        `shouldReturn` [Deleted exactCleanup, AbsenceObserved exactCleanup]

    it "cleans the exact Job and rethrows cancellation after Authority completion" $ do
      events <- newIORef []
      state <- newIORef (AdminActionExecutionAuthorized permit)
      applications <- newIORef (0 :: Int)
      completionCalls <- newIORef (0 :: Int)
      outcome <-
        try
          ( coordinateAdminAction
              (terminalStateClient state completionCalls)
              (terminalLossKubernetes state applications events True)
              now
              30
              imageReference
              credentials
              prepareRequest
          )
          :: IO
               ( Either
                   AsyncException
                   (Either AdminActionCoordinatorError AdminActionReceipt)
               )
      outcome `shouldBe` Left ThreadKilled
      readIORef state
        `shouldReturn` AdminActionExecutionCompleted permit receipt
      readIORef applications `shouldReturn` 1
      readIORef events
        `shouldReturn` [ Created
                       , Attached
                       , Deleted exactCleanup
                       , AbsenceObserved exactCleanup
                       ]

    it "recovers an applied terminal-completion CAS after its response is lost" $ do
      retained <- newIORef (0 :: Int, AdminActionExecutionAuthorized permit)
      loseFirstResponse <- newIORef True
      let repository = responseLossAuthorityRepository retained loseFirstResponse
      first <- completeAdminActionForPermit repository permit receipt
      first
        `shouldBe` Left
          (AdminActionAuthorityCommitFailed "terminal completion CAS response lost")
      (snd <$> readIORef retained)
        `shouldReturn` AdminActionExecutionCompleted permit receipt
      second <- completeAdminActionForPermit repository permit receipt
      second `shouldBe` Right receipt

    it "revokes an invalid auditor bearer and proves role-wide stable zero before use" $ do
      logins <- newIORef [InvalidAuditor "leaked-accessor-1", ValidAuditor]
      events <- newIORef []
      result <-
        acquireAdminActionAuditorWith
          3
          (auditorRecoveryFixture logins events (Right ()))
      result `shouldBe` Right ValidAuditor
      readIORef events
        `shouldReturn` [ RevokedInvalidAuditor "leaked-accessor-1"
                       , ProvedAuditorRoleEmpty ["leaked-accessor-1"]
                       ]

    it "never returns a valid auditor when its role-wide absence proof fails" $ do
      logins <- newIORef [InvalidAuditor "leaked-accessor-1", ValidAuditor]
      events <- newIORef []
      result <-
        acquireAdminActionAuditorWith
          3
          (auditorRecoveryFixture logins events (Left "role inventory visible"))
      result `shouldBe` Left "role inventory visible"
      readIORef events
        `shouldReturn` [ RevokedInvalidAuditor "leaked-accessor-1"
                       , ProvedAuditorRoleEmpty ["leaked-accessor-1"]
                       ]

runFixture
  :: CancelPoint
  -> IORef [LifecycleEvent]
  -> Either Text ()
  -> Either Text Bool
  -> IO (Either AdminActionCoordinatorError AdminActionReceipt)
runFixture cancelPoint events deleteResult absenceResult =
  coordinateAdminAction
    (fixtureClient cancelPoint events)
    (fixtureKubernetes cancelPoint events deleteResult absenceResult False)
    now
    30
    imageReference
    credentials
    prepareRequest

runThrownAttachFixture
  :: IORef [LifecycleEvent]
  -> IO (Either AdminActionCoordinatorError AdminActionReceipt)
runThrownAttachFixture events =
  coordinateAdminAction
    (fixtureClient DoNotCancel events)
    (fixtureKubernetes DoNotCancel events (Right ()) (Right True) True)
    now
    30
    imageReference
    credentials
    prepareRequest

fixtureClient
  :: CancelPoint -> IORef [LifecycleEvent] -> AdminActionClient IO
fixtureClient cancelPoint events =
  mkAdminActionClient handleRequest
 where
  handleRequest request = case request of
    PrepareAdminAction _ -> pure (Right (AdminActionPrepared core backupReceipt))
    AuthorizeAdminAction _ _ -> do
      when (cancelPoint == CancelAfterAttestation) (throwIO ThreadKilled)
      pure (Right (AdminActionAuthorized (encodeSignedAdminActionPermit permit)))
    CompleteAdminAction _ completed -> do
      modifyIORef' events (++ [AuthorityCompleted])
      completed `shouldBe` receipt
      when (cancelPoint == CancelAfterComplete) (throwIO ThreadKilled)
      pure (Right (AdminActionCompleted completed))
    ObserveAdminAction _ ->
      pure
        ( Right
            ( AdminActionObserved
                (AdminActionExecutionPrepared core backupReceipt)
            )
        )

fixtureKubernetes
  :: CancelPoint
  -> IORef [LifecycleEvent]
  -> Either Text ()
  -> Either Text Bool
  -> Bool
  -> AdminActionKubernetesBoundary IO
fixtureKubernetes cancelPoint events deleteResult absenceResult throwAttach =
  AdminActionKubernetesBoundary
    { createAdminActionJob = \_ -> do
        modifyIORef' events (++ [Created])
        when (cancelPoint == CancelAfterCreate) (throwIO ThreadKilled)
        pure (Right ())
    , observeAdminActionJob = \_ -> pure (Right (Just rawObservation))
    , attestAdminActionJob = \observedNow intent observation ->
        pure (attestAdminActionPod observedNow intent observation)
    , attachAdminActionIngress = \_ _ -> do
        modifyIORef' events (++ [Attached])
        if throwAttach
          then throwIO (userError "attach transport threw")
          else do
            when (cancelPoint == CancelAfterAttach) (throwIO ThreadKilled)
            pure (Right (encodeAdminActionReceipt receipt))
    , deleteAdminActionJob = \_ binding -> do
        modifyIORef' events (++ [Deleted binding])
        pure deleteResult
    , observeAdminActionJobAbsent = \_ binding -> do
        modifyIORef' events (++ [AbsenceObserved binding])
        pure absenceResult
    }

observationOnlyKubernetes
  :: RawAdminActionPodObservation
  -> IORef [LifecycleEvent]
  -> Bool
  -> AdminActionKubernetesBoundary IO
observationOnlyKubernetes observation events cancelAttestation =
  AdminActionKubernetesBoundary
    { createAdminActionJob = \_ -> do
        modifyIORef' events (++ [Created])
        pure (Right ())
    , observeAdminActionJob = \_ -> pure (Right (Just observation))
    , attestAdminActionJob = \observedNow intent raw ->
        if cancelAttestation
          then throwIO ThreadKilled
          else pure (attestAdminActionPod observedNow intent raw)
    , attachAdminActionIngress = \_ _ ->
        expectationFailure "attestation refusal must not attach" >> pure (Left "unreachable")
    , deleteAdminActionJob = \_ binding -> do
        modifyIORef' events (++ [Deleted binding])
        pure (Right ())
    , observeAdminActionJobAbsent = \_ binding -> do
        modifyIORef' events (++ [AbsenceObserved binding])
        pure (Right True)
    }

terminalStateClient
  :: IORef AdminActionExecutionState
  -> IORef Int
  -> AdminActionClient IO
terminalStateClient state completionCalls =
  mkAdminActionClient handleRequest
 where
  handleRequest request = case request of
    PrepareAdminAction _ -> pure (Right (AdminActionPrepared core backupReceipt))
    AuthorizeAdminAction _ _ ->
      pure (Right (AdminActionAuthorized (encodeSignedAdminActionPermit permit)))
    CompleteAdminAction _ completed -> do
      modifyIORef' completionCalls (+ 1)
      pure (Right (AdminActionCompleted completed))
    ObserveAdminAction _ ->
      Right . AdminActionObserved <$> readIORef state

terminalLossKubernetes
  :: IORef AdminActionExecutionState
  -> IORef Int
  -> IORef [LifecycleEvent]
  -> Bool
  -> AdminActionKubernetesBoundary IO
terminalLossKubernetes state applications events cancelAfterCompletion =
  AdminActionKubernetesBoundary
    { createAdminActionJob = \_ -> do
        modifyIORef' events (++ [Created])
        pure (Right ())
    , observeAdminActionJob = \_ -> pure (Right (Just rawObservation))
    , attestAdminActionJob = \observedNow intent observation ->
        pure (attestAdminActionPod observedNow intent observation)
    , attachAdminActionIngress = \_ _ -> do
        modifyIORef' events (++ [Attached])
        modifyIORef' applications (+ 1)
        writeIORef state (AdminActionExecutionCompleted permit receipt)
        if cancelAfterCompletion
          then throwIO ThreadKilled
          else pure (Left "worker stdout transport lost")
    , deleteAdminActionJob = \_ binding -> do
        modifyIORef' events (++ [Deleted binding])
        pure (Right ())
    , observeAdminActionJobAbsent = \_ binding -> do
        modifyIORef' events (++ [AbsenceObserved binding])
        pure (Right True)
    }

responseLossAuthorityRepository
  :: IORef (Int, AdminActionExecutionState)
  -> IORef Bool
  -> AdminActionAuthorityRepository IO Int
responseLossAuthorityRepository retained loseFirstResponse =
  AdminActionAuthorityRepository
    { readAdminActionAuthority = do
        (revision, state) <- readIORef retained
        pure
          ( Right
              AdminActionAuthoritySnapshot
                { adminActionAuthorityRevision = revision
                , adminActionAuthorityState = state
                }
          )
    , compareAndSwapAdminActionAuthority = \expected next -> do
        (revision, _) <- readIORef retained
        if revision /= expected
          then pure (Left "fixture CAS conflict")
          else do
            writeIORef retained (revision + 1, next)
            lose <- readIORef loseFirstResponse
            if lose
              then do
                writeIORef loseFirstResponse False
                pure (Left "terminal completion CAS response lost")
              else pure (Right ())
    }

data AuditorFixtureLogin
  = InvalidAuditor !Text
  | ValidAuditor
  deriving stock (Eq, Show)

data AuditorRecoveryEvent
  = RevokedInvalidAuditor !Text
  | ProvedAuditorRoleEmpty ![Text]
  deriving stock (Eq, Show)

auditorRecoveryFixture
  :: IORef [AuditorFixtureLogin]
  -> IORef [AuditorRecoveryEvent]
  -> Either Text ()
  -> AdminActionAuditorRecoveryBoundary IO AuditorFixtureLogin
auditorRecoveryFixture logins events proofResult =
  AdminActionAuditorRecoveryBoundary
    { acquireAdminActionAuditorLogin = do
        remaining <- readIORef logins
        case remaining of
          [] -> pure (Left "fixture login inventory exhausted")
          login : rest -> do
            writeIORef logins rest
            pure (Right login)
    , adminActionAuditorLoginAccepted = (== ValidAuditor)
    , adminActionAuditorLoginMayHaveAccessor = auditorMayHaveAccessor
    , adminActionAuditorLoginAccessor = auditorAccessor
    , revokeAdminActionAuditorLogin = revokeAuditorLogin
    , closeAdminActionAuditorRole = \_ accessors -> do
        modifyIORef' events (<> [ProvedAuditorRoleEmpty accessors])
        pure proofResult
    }
 where
  auditorMayHaveAccessor login = case login of
    InvalidAuditor _ -> True
    ValidAuditor -> False
  auditorAccessor login = case login of
    InvalidAuditor accessor -> accessor
    ValidAuditor -> ""
  revokeAuditorLogin login = do
    case login of
      InvalidAuditor accessor ->
        modifyIORef' events (<> [RevokedInvalidAuditor accessor])
      ValidAuditor -> pure ()
    pure (Right ())

prepareRequest :: AdminActionPrepareRequest
prepareRequest =
  AdminActionPrepareRequest
    { adminActionPrepareOperationId = operationId
    , adminActionPreparePlan = plan
    , adminActionPrepareDeadlineMicros = 10 * 1000000
    , adminActionPrepareImageDigest = imageDigest
    }

core :: AdminActionPermitCore
core =
  mustRight
    ( mkAdminActionPermitCore
        operationId
        authorityScope
        authorityEndpoint
        plan
        "admin-action-nonce"
        (authorityTimeFromMicros (10 * 1000000))
        imageDigest
    )

backupReceipt :: AdminActionBackupReceipt
backupReceipt =
  mustRight
    ( mkAdminActionBackupReceipt
        core
        "authority-backup/admin-action"
        (adminActionPermitBackupDigest core)
        "backup-version-1"
    )

jobBinding :: AdminActionJobBinding
jobBinding =
  mustRight
    ( mkAdminActionJobBinding
        core
        (adminActionJobNameFor core)
        "job-uid-1"
        "admin-action-pod-1"
        "pod-uid-1"
        imageDigest
        adminActionRunnerServiceAccount
        "service-account-uid-1"
        now
    )

permit :: SignedAdminActionPermit
permit =
  mustRight
    ( mkSignedAdminActionPermit
        1
        core
        backupReceipt
        jobBinding
        (ByteString.replicate 64 7)
    )

receipt :: AdminActionReceipt
receipt =
  mustRight
    ( mkAdminActionReceipt
        permit
        ( AdminReconcileQuotaReadBack
            [ AdminQuotaItemReadBack
                { adminQuotaServiceCode = adminQuotaRequestServiceCode quotaRequest
                , adminQuotaCode = adminQuotaRequestCode quotaRequest
                , adminQuotaRegion = adminQuotaRequestRegion quotaRequest
                , adminQuotaDesiredValue = adminQuotaRequestDesiredValue quotaRequest
                , adminQuotaAttemptIdentity = "quota-attempt-1"
                , adminQuotaProviderRequestIdentity = "provider-request-1"
                , adminQuotaStatus = "pending"
                }
            ]
        )
    )

plan :: AdminActionPlan
plan = AdminReconcileQuotaPlanAction [quotaRequest]

quotaRequest :: AdminQuotaRequest
quotaRequest =
  AdminQuotaRequest
    { adminQuotaRequestAuthorityScope = "home-authority"
    , adminQuotaRequestAuthorityEndpoint = "http://lifecycle-authority.gateway.svc:8080"
    , adminQuotaRequestServiceCode = "vpc"
    , adminQuotaRequestCode = "L-F678F1CE"
    , adminQuotaRequestRegion = (fixtureAwsRegion FixtureCaCentral1)
    , adminQuotaRequestDesiredValue = "10"
    }

rawObservation :: RawAdminActionPodObservation
rawObservation =
  RawAdminActionPodObservation
    { observedAdminActionJobName = adminActionJobNameFor core
    , observedAdminActionJobUid = "job-uid-1"
    , observedAdminActionPodName = "admin-action-pod-1"
    , observedAdminActionPodUid = "pod-uid-1"
    , observedAdminActionImageDigest = imageDigest
    , observedAdminActionServiceAccount = adminActionRunnerServiceAccount
    , observedAdminActionServiceAccountUid = "service-account-uid-1"
    , observedAdminActionOperationId = operationId
    , observedAdminActionAction = "reconcile-quota"
    , observedAdminActionDeadlineMicros = 10 * 1000000
    , observedAdminActionHeartbeatMicros = 1000000
    , observedAdminActionPhase = "Running"
    , observedAdminActionContainerReady = True
    , observedAdminActionRestartCount = 0
    , observedAdminActionDeletionTimestamp = Nothing
    }

exactCleanup :: Maybe AdminActionCleanupBinding
exactCleanup =
  Just
    AdminActionCleanupBinding
      { adminActionCleanupJobUid = "job-uid-1"
      , adminActionCleanupPodName = "admin-action-pod-1"
      , adminActionCleanupPodUid = "pod-uid-1"
      }

credentials :: Credentials
credentials =
  Credentials
    { access_key_id = "AKIAIOSFODNN7EXAMPLE"
    , secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    , session_token = Just "fixture-session-token"
    , region = (fixtureAwsRegion FixtureCaCentral1)
    }

operationId :: Text
operationId = "admin-operation-1"

authorityScope :: Text
authorityScope = "home-authority"

authorityEndpoint :: Text
authorityEndpoint = "http://lifecycle-authority.gateway.svc:8080"

imageDigest :: Text
imageDigest = "sha256:" <> Text.replicate 64 "a"

imageReference :: Text
imageReference = "registry.local/prodbox:admin-action-test"

now :: AuthorityTime
now = authorityTimeFromMicros 1000000

mustRight :: (Show errorValue) => Either errorValue value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
