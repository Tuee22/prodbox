{-# LANGUAGE OverloadedStrings #-}

module VaultSessionSafety (vaultSessionSafetySuite) where

import Control.Exception
  ( AsyncException (ThreadKilled)
  , throwIO
  , try
  )
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Base64.URL qualified as Base64Url
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.ProjectedServiceAccountIdentity
  ( decodeProjectedServiceAccountIdentity
  , projectedServiceAccountIdentityMatches
  )
import Prodbox.ControlPlane.ServiceSessionJournal
import Prodbox.ControlPlane.ServiceSessionLifecycle
  ( ServiceSessionLifecycleError (..)
  , ServiceSessionLoginBoundary (..)
  , ServiceSessionSubjects (..)
  , allocateNextServiceSessionBinding
  , withFencedServiceSession
  )
import Prodbox.ControlPlane.VaultAccessorAudit
  ( VaultAccessorAuditOps (..)
  , VaultAccessorSubject (..)
  , isBoundedBatchAuditorLogin
  , revokeAndProveVaultAccessorSubjectAbsent
  )
import Prodbox.Lifecycle.AdminAction.Runner
  ( AdminActionRunnerError (..)
  , finishAdminActionRunnerSession
  )
import Prodbox.Vault.Client
  ( TokenAccessorInfo (..)
  , VaultKubernetesLoginResult (..)
  , VaultToken (..)
  )
import TestSupport

vaultSessionSafetySuite :: SuiteBuilder ()
vaultSessionSafetySuite =
  describe "Sprint 4.50 finite one-shot Vault-session cleanup" $ do
    it "accepts only a bounded non-renewable batch auditor with no accessor" $ do
      isBoundedBatchAuditorLogin 300 validBatchLogin `shouldBe` True
      isBoundedBatchAuditorLogin
        300
        validBatchLogin {vaultLoginTokenType = "service"}
        `shouldBe` False
      isBoundedBatchAuditorLogin
        300
        validBatchLogin {vaultLoginAccessor = "auditor-accessor"}
        `shouldBe` False
      isBoundedBatchAuditorLogin
        300
        validBatchLogin {vaultLoginRenewable = True}
        `shouldBe` False
      isBoundedBatchAuditorLogin
        300
        validBatchLogin {vaultLoginLeaseSeconds = 301}
        `shouldBe` False

    it "rejects projected-token ServiceAccount UID substitution" $ do
      let decoded = decodeProjectedServiceAccountIdentity (projectedJwt "service-account-uid-1")
      decoded
        `shouldSatisfy` either
          (const False)
          ( projectedServiceAccountIdentityMatches
              "admin-action-runner"
              "admin-action-pod-1"
              "pod-uid-1"
              "prodbox-admin-action-runner"
              "service-account-uid-1"
          )
      decoded
        `shouldSatisfy` either
          (const False)
          ( not
              . projectedServiceAccountIdentityMatches
                "admin-action-runner"
                "admin-action-pod-1"
                "pod-uid-1"
                "prodbox-admin-action-runner"
                "service-account-uid-substituted"
          )

    it "persists preclean and the sole login attempt before an accessor can become active" $ do
      let initial = mustRight (mkInitialServiceSessionJournal workerRole)
          binding = sessionBinding 1 "attempt-1"
          acquiring = step (BeginServiceSessionAcquisition binding) initial
          precleaned = step (CommitServiceSessionPrecleaned binding) acquiring
          attempted = step (CommitServiceSessionLoginAttempt binding) precleaned
          active = step (CommitServiceSessionActive binding "worker-accessor") attempted
      serviceSessionJournalPhase active
        `shouldBe` ServiceSessionActive binding "worker-accessor"
      decodeServiceSessionJournal (encodeServiceSessionJournal active)
        `shouldBe` Right active

    it "forces an ambiguous login attempt through cleanup before a greater fenced successor" $ do
      let initial = mustRight (mkInitialServiceSessionJournal workerRole)
          first = sessionBinding 7 "attempt-7"
          attempted =
            step
              (CommitServiceSessionLoginAttempt first)
              ( step
                  (CommitServiceSessionPrecleaned first)
                  (step (BeginServiceSessionAcquisition first) initial)
              )
          required = step (RequireServiceSessionCleanup first) attempted
          proven = step (CommitServiceSessionCleanupProven first) required
          released = step (ReleaseServiceSession first) proven
          successor = sessionBinding 8 "attempt-8"
      stepServiceSessionJournal
        (CommitServiceSessionLoginAttempt first)
        attempted
        `shouldBe` Right attempted
      stepServiceSessionJournal
        (BeginServiceSessionAcquisition first)
        released
        `shouldBe` Left (ServiceSessionFenceStale 7 7)
      serviceSessionJournalPhase
        (step (BeginServiceSessionAcquisition successor) released)
        `shouldBe` ServiceSessionAcquiring successor

    it "polls through post-revoke visibility then proves two stable zero scans" $ do
      inventories <-
        newIORef
          [ ["stale-accessor"]
          , []
          , ["late-accessor"]
          , []
          , []
          ]
      waits <- newIORef (0 :: Int)
      result <-
        revokeAndProveVaultAccessorSubjectAbsent
          VaultAccessorAuditOps
            { auditListAccessors = popInventory inventories
            , auditLookupAccessor = \_ -> pure (Right matchingAccessorInfo)
            , auditRevokeAccessor = \_ -> pure (Right ())
            , auditObserveAccessorAbsent = \_ -> pure (Right True)
            , auditWaitVisibilityGrace =
                modifyIORef' waits (+ 1) >> pure (Right ())
            }
          accessorSubject
          Nothing
      result `shouldBe` Right ()
      readIORef waits `shouldReturn` 2

    it "runs both cleanup effects after a thrown worker effect" $ do
      events <- newIORef ([] :: [Text])
      outcome <-
        finishAdminActionRunnerSession
          ( do
              modifyIORef' events (++ ["action"])
              throwIO (userError "fixture")
          )
          (modifyIORef' events (++ ["revoke"]) >> pure (Right ()))
          (modifyIORef' events (++ ["absence"]) >> pure (Right True))
          :: IO (Either AdminActionRunnerError ())
      outcome `shouldBe` Left AdminActionRunnerExecutionFailed
      readIORef events `shouldReturn` ["action", "revoke", "absence"]

    it "runs cleanup and rethrows ThreadKilled instead of converting cancellation" $ do
      events <- newIORef ([] :: [Text])
      outcome <-
        try
          ( finishAdminActionRunnerSession
              ( do
                  modifyIORef' events (++ ["action"])
                  throwIO ThreadKilled
              )
              (modifyIORef' events (++ ["revoke"]) >> pure (Right ()))
              (modifyIORef' events (++ ["absence"]) >> pure (Right True))
          )
          :: IO
               ( Either
                   AsyncException
                   (Either AdminActionRunnerError ())
               )
      outcome `shouldBe` Left ThreadKilled
      readIORef events `shouldReturn` ["action", "revoke", "absence"]

    it "lets authoritative accessor absence close a response-lost revoke" $ do
      outcome <-
        finishAdminActionRunnerSession
          (pure (Right ("receipt" :: Text)))
          ( throwIO (userError "lost revoke response")
              :: IO (Either AdminActionRunnerError ())
          )
          (pure (Right True))
      outcome `shouldBe` Right "receipt"

    it "cleans a fenced service session after a synchronous action exception" $ do
      store <- newSessionStore
      revocations <- newIORef (0 :: Int)
      outcome <-
        withFencedServiceSession
          (sessionRepository store)
          successfulAuditOps
          sessionSubjects
          (sessionBinding 1 "attempt-sync")
          (successfulLoginBoundary revocations)
          (\_ -> throwIO (userError "fixture") :: IO (Either Text Text))
      outcome `shouldBe` Left ServiceSessionLifecycleUnhandledException
      readIORef revocations `shouldReturn` 1
      observedSessionPhase store
        `shouldReturn` ServiceSessionVacant 1

    it "cleans a fenced service session and rethrows action cancellation" $ do
      store <- newSessionStore
      revocations <- newIORef (0 :: Int)
      outcome <-
        try
          ( withFencedServiceSession
              (sessionRepository store)
              successfulAuditOps
              sessionSubjects
              (sessionBinding 1 "attempt-cancel")
              (successfulLoginBoundary revocations)
              (\_ -> throwIO ThreadKilled :: IO (Either Text Text))
          )
          :: IO
               ( Either
                   AsyncException
                   (Either ServiceSessionLifecycleError Text)
               )
      outcome `shouldBe` Left ThreadKilled
      readIORef revocations `shouldReturn` 1
      observedSessionPhase store
        `shouldReturn` ServiceSessionVacant 1

    it "directly revokes a returned login even when active-journal readback is unavailable" $ do
      store <- newSessionStore
      failReads <- newIORef False
      revocations <- newIORef (0 :: Int)
      actionRuns <- newIORef (0 :: Int)
      outcome <-
        withFencedServiceSession
          (activeReadbackFailureRepository store failReads)
          successfulAuditOps
          sessionSubjects
          (sessionBinding 1 "attempt-readback-loss")
          (successfulLoginBoundary revocations)
          (\_ -> modifyIORef' actionRuns (+ 1) >> pure (Right ("receipt" :: Text)))
      outcome `shouldSatisfy` isJournalUnavailable
      readIORef revocations `shouldReturn` 1
      readIORef actionRuns `shouldReturn` 0

    it "cleans an old ServiceAccount UID before admitting a greater-fenced successor" $ do
      let predecessor = sessionBinding 1 "attempt-old-uid"
          successor = sessionBinding 2 "attempt-new-uid"
          oldJournal =
            step
              (CommitServiceSessionLoginAttempt predecessor)
              ( step
                  (CommitServiceSessionPrecleaned predecessor)
                  ( step
                      (BeginServiceSessionAcquisition predecessor)
                      (mustRight (mkInitialServiceSessionJournal workerRole))
                  )
              )
      store <- newIORef (0, oldJournal)
      inventory <-
        newIORef
          (Map.singleton "old-accessor" (accessorInfoFor "service-account-uid-old"))
      events <- newIORef []
      outcome <-
        withFencedServiceSession
          (sessionRepository store)
          (inventoryAuditOps inventory events)
          (sessionSubjectsFor "service-account-uid-new")
          successor
          (inventoryLoginBoundary inventory events)
          (\_ -> modifyIORef' events (++ ["action"]) >> pure (Right ("receipt" :: Text)))
      outcome `shouldBe` Right "receipt"
      readIORef events
        `shouldReturn` [ "audit-revoke:old-accessor"
                       , "login"
                       , "action"
                       , "direct-revoke:new-accessor"
                       ]
      observedSessionPhase store `shouldReturn` ServiceSessionVacant 2

    it "refuses a foreign-role higher fence before touching the retained role lane" $ do
      let predecessor = sessionBinding 1 "attempt-real-role"
          retained =
            step
              (CommitServiceSessionLoginAttempt predecessor)
              ( step
                  (CommitServiceSessionPrecleaned predecessor)
                  ( step
                      (BeginServiceSessionAcquisition predecessor)
                      (mustRight (mkInitialServiceSessionJournal workerRole))
                  )
              )
          foreignBinding =
            mustRight
              ( mkServiceSessionBinding
                  "foreign-worker-role"
                  "foreign-operation"
                  "foreign-attempt"
                  2
              )
      store <- newIORef (0, retained)
      inventory <-
        newIORef
          (Map.singleton "real-accessor" (accessorInfoFor "service-account-uid-old"))
      events <- newIORef []
      outcome <-
        withFencedServiceSession
          (sessionRepository store)
          (inventoryAuditOps inventory events)
          sessionSubjects
          foreignBinding
          (inventoryLoginBoundary inventory events)
          (\_ -> pure (Right ("must-not-run" :: Text)))
      outcome `shouldBe` Left ServiceSessionLifecycleBindingRoleMismatch
      readIORef events `shouldReturn` []
      readIORef inventory
        `shouldReturn` Map.singleton
          "real-accessor"
          (accessorInfoFor "service-account-uid-old")
      observedSessionPhase store
        `shouldReturn` ServiceSessionLoginAttemptCommitted predecessor

    it "recovers an applied action after session cleanup and receipt loss" $ do
      store <- newSessionStore
      revocations <- newIORef (0 :: Int)
      applications <- newIORef (0 :: Int)
      firstOutcome <-
        withFencedServiceSession
          (sessionRepository store)
          successfulAuditOps
          sessionSubjects
          (sessionBinding 1 "same-permit")
          (successfulLoginBoundary revocations)
          ( \_ ->
              do
                modifyIORef' applications (+ 1)
                throwIO (userError "receipt transport lost")
                :: IO (Either Text Text)
          )
      firstOutcome `shouldBe` Left ServiceSessionLifecycleUnhandledException
      successor <-
        allocateNextServiceSessionBinding
          (sessionRepository store)
          workerRole
          "admin-operation"
          "same-permit"
      (serviceSessionBindingFence <$> successor) `shouldBe` Right 2
      secondOutcome <- case successor of
        Left err -> pure (Left err)
        Right binding ->
          withFencedServiceSession
            (sessionRepository store)
            successfulAuditOps
            sessionSubjects
            binding
            (successfulLoginBoundary revocations)
            ( \_ -> do
                applied <- readIORef applications
                pure
                  ( if applied == 1
                      then Right ("recovered-receipt" :: Text)
                      else Left "action was not durably applied"
                  )
            )
      secondOutcome `shouldBe` Right "recovered-receipt"
      readIORef applications `shouldReturn` 1
      readIORef revocations `shouldReturn` 2
      observedSessionPhase store `shouldReturn` ServiceSessionVacant 2

workerRole :: Text
workerRole = "prodbox-admin-action-runner"

projectedJwt :: Text -> Text
projectedJwt serviceAccountUid =
  "e30."
    <> TextEncoding.decodeUtf8
      ( Base64Url.encodeUnpadded
          ( LazyByteString.toStrict
              ( encode
                  ( object
                      [ "sub"
                          .= ( "system:serviceaccount:admin-action-runner:prodbox-admin-action-runner"
                                 :: Text
                             )
                      , "kubernetes.io"
                          .= object
                            [ "namespace" .= ("admin-action-runner" :: Text)
                            , "pod"
                                .= object
                                  [ "name" .= ("admin-action-pod-1" :: Text)
                                  , "uid" .= ("pod-uid-1" :: Text)
                                  ]
                            , "serviceaccount"
                                .= object
                                  [ "name" .= ("prodbox-admin-action-runner" :: Text)
                                  , "uid" .= serviceAccountUid
                                  ]
                            ]
                      ]
                  )
              )
          )
      )
    <> ".signature"

validBatchLogin :: VaultKubernetesLoginResult
validBatchLogin =
  VaultKubernetesLoginResult
    { vaultLoginToken = VaultToken "fixture-token"
    , vaultLoginAccessor = ""
    , vaultLoginLeaseSeconds = 120
    , vaultLoginRenewable = False
    , vaultLoginTokenType = "batch"
    }

accessorSubject :: VaultAccessorSubject
accessorSubject = accessorSubjectFor "service-account-uid-1"

accessorSubjectFor :: Text -> VaultAccessorSubject
accessorSubjectFor serviceAccountUid =
  VaultAccessorSubject
    { vaultAccessorSubjectPolicies = ["prodbox-admin-action-runner"]
    , vaultAccessorSubjectMetadata =
        Map.fromList
          [ ("role", "prodbox-admin-action-runner")
          , ("service_account_name", "prodbox-admin-action-runner")
          , ("service_account_namespace", "admin-action-runner")
          , ("service_account_uid", serviceAccountUid)
          ]
    , vaultAccessorSubjectCreationPath = "auth/kubernetes/login"
    }

cleanupAccessorSubject :: VaultAccessorSubject
cleanupAccessorSubject =
  accessorSubject
    { vaultAccessorSubjectMetadata =
        Map.delete
          "service_account_uid"
          (vaultAccessorSubjectMetadata accessorSubject)
    }

sessionSubjects :: ServiceSessionSubjects
sessionSubjects = sessionSubjectsFor "service-account-uid-1"

sessionSubjectsFor :: Text -> ServiceSessionSubjects
sessionSubjectsFor serviceAccountUid =
  ServiceSessionSubjects
    { serviceSessionCleanupSubject = cleanupAccessorSubject
    , serviceSessionActiveSubject = accessorSubjectFor serviceAccountUid
    }

matchingAccessorInfo :: TokenAccessorInfo
matchingAccessorInfo = accessorInfoFor "service-account-uid-1"

accessorInfoFor :: Text -> TokenAccessorInfo
accessorInfoFor serviceAccountUid =
  TokenAccessorInfo
    { tokenAccessorInfoPolicies = ["prodbox-admin-action-runner"]
    , tokenAccessorInfoMetadata =
        vaultAccessorSubjectMetadata (accessorSubjectFor serviceAccountUid)
    , tokenAccessorInfoCreationPath = "auth/kubernetes/login"
    , tokenAccessorInfoDisplayName = "kubernetes-prodbox-admin-action-runner"
    }

inventoryAuditOps
  :: IORef (Map.Map Text TokenAccessorInfo)
  -> IORef [Text]
  -> VaultAccessorAuditOps IO
inventoryAuditOps inventory events =
  VaultAccessorAuditOps
    { auditListAccessors = Right . Map.keys <$> readIORef inventory
    , auditLookupAccessor = \accessor -> do
        observed <- readIORef inventory
        pure $ maybe (Left "fixture accessor missing") Right (Map.lookup accessor observed)
    , auditRevokeAccessor = \accessor -> do
        modifyIORef' events (++ ["audit-revoke:" <> accessor])
        modifyIORef' inventory (Map.delete accessor)
        pure (Right ())
    , auditObserveAccessorAbsent = \accessor -> do
        observed <- readIORef inventory
        pure (Right (Map.notMember accessor observed))
    , auditWaitVisibilityGrace = pure (Right ())
    }

inventoryLoginBoundary
  :: IORef (Map.Map Text TokenAccessorInfo)
  -> IORef [Text]
  -> ServiceSessionLoginBoundary Text
inventoryLoginBoundary inventory events =
  ServiceSessionLoginBoundary
    { attemptServiceSessionLogin = do
        modifyIORef' events (++ ["login"])
        modifyIORef'
          inventory
          (Map.insert "new-accessor" (accessorInfoFor "service-account-uid-new"))
        pure (Right "new-accessor")
    , serviceSessionLoginAccessor = id
    , revokeServiceSessionLogin = \accessor -> do
        modifyIORef' events (++ ["direct-revoke:" <> accessor])
        modifyIORef' inventory (Map.delete accessor)
        pure (Right ())
    }

successfulAuditOps :: VaultAccessorAuditOps IO
successfulAuditOps =
  VaultAccessorAuditOps
    { auditListAccessors = pure (Right [])
    , auditLookupAccessor = \_ -> pure (Right matchingAccessorInfo)
    , auditRevokeAccessor = \_ -> pure (Right ())
    , auditObserveAccessorAbsent = \_ -> pure (Right True)
    , auditWaitVisibilityGrace = pure (Right ())
    }

successfulLoginBoundary :: IORef Int -> ServiceSessionLoginBoundary Text
successfulLoginBoundary revocations =
  ServiceSessionLoginBoundary
    { attemptServiceSessionLogin = pure (Right "worker-accessor")
    , serviceSessionLoginAccessor = id
    , revokeServiceSessionLogin = \_ -> do
        modifyIORef' revocations (+ 1)
        pure (Right ())
    }

type SessionStore = IORef (Int, ServiceSessionJournal)

newSessionStore :: IO SessionStore
newSessionStore =
  newIORef (0, mustRight (mkInitialServiceSessionJournal workerRole))

sessionRepository :: SessionStore -> ServiceSessionJournalRepository IO Int
sessionRepository store =
  ServiceSessionJournalRepository
    { readServiceSessionJournal = do
        (revision, journal) <- readIORef store
        pure
          ( Right
              ServiceSessionJournalSnapshot
                { serviceSessionJournalRevision = revision
                , serviceSessionJournalObserved = journal
                }
          )
    , compareAndSwapServiceSessionJournal = \expected next -> do
        (revision, _) <- readIORef store
        if revision /= expected
          then pure (Left "fixture CAS conflict")
          else writeIORef store (revision + 1, next) >> pure (Right ())
    }

activeReadbackFailureRepository
  :: SessionStore
  -> IORef Bool
  -> ServiceSessionJournalRepository IO Int
activeReadbackFailureRepository store failReads =
  ServiceSessionJournalRepository
    { readServiceSessionJournal = do
        unavailable <- readIORef failReads
        if unavailable
          then pure (Left "fixture retained store unavailable")
          else readServiceSessionJournal (sessionRepository store)
    , compareAndSwapServiceSessionJournal = \expected next -> do
        committed <-
          compareAndSwapServiceSessionJournal
            (sessionRepository store)
            expected
            next
        case committed of
          Right () -> case serviceSessionJournalPhase next of
            ServiceSessionActive _ _ -> writeIORef failReads True
            _ -> pure ()
          Left _ -> pure ()
        pure committed
    }

observedSessionPhase :: SessionStore -> IO ServiceSessionPhase
observedSessionPhase store = serviceSessionJournalPhase . snd <$> readIORef store

isJournalUnavailable
  :: Either ServiceSessionLifecycleError value -> Bool
isJournalUnavailable outcome = case outcome of
  Left (ServiceSessionLifecycleJournalUnavailable _) -> True
  Left
    ( ServiceSessionLifecycleJournalFailed
        (ServiceSessionJournalStoreUnavailable _)
      ) -> True
  _ -> False

popInventory
  :: IORef [[Text]] -> IO (Either Text [Text])
popInventory inventories = do
  observed <- readIORef inventories
  case observed of
    [] -> pure (Left "fixture inventory exhausted")
    next : rest -> do
      modifyIORef' inventories (const rest)
      pure (Right next)

sessionBinding :: Natural -> Text -> ServiceSessionBinding
sessionBinding rawFence rawAttempt =
  mustRight
    ( mkServiceSessionBinding
        "prodbox-admin-action-runner"
        "admin-operation"
        rawAttempt
        rawFence
    )

step
  :: ServiceSessionEvent
  -> ServiceSessionJournal
  -> ServiceSessionJournal
step event = mustRight . stepServiceSessionJournal event

mustRight :: (Show errorValue) => Either errorValue value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
