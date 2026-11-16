{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module VaultSessionSafety (vaultSessionSafetySuite) where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , throwIO
  , try
  )
import Control.Monad (forM_)
import Data.Aeson (encode, object, (.=))
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64.URL qualified as Base64Url
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticationRegistry (targetSecretWorkerVaultRole)
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
  ( VaultAccessorAuditDetailedError (..)
  , VaultAccessorAuditDetailedOps (..)
  , VaultAccessorAuditOps (..)
  , VaultAccessorDetailedLookupError (..)
  , VaultAccessorLookupError (..)
  , VaultAccessorSubject (..)
  , classifyVaultAccessorLookupResponse
  , isBoundedBatchAuditorLogin
  , isBoundedServiceTokenLogin
  , isExactBoundedBatchAuditorLogin
  , revokeAndProveVaultAccessorSubjectAbsent
  , revokeAndProveVaultAccessorSubjectAbsentDetailed
  )
import Prodbox.Http.Client (HttpError (..))
import Prodbox.Lifecycle.AdminAction.Runner
  ( AdminActionRunnerError (..)
  , finishAdminActionRunnerSession
  )
import Prodbox.Lifecycle.Lease (mkOwnerNonce)
import Prodbox.Lifecycle.TargetCommitIntent (sha256TargetValueDigest, targetValueDigestText)
import Prodbox.Vault.Client
  ( TokenAccessorInfo (..)
  , VaultKubernetesLoginResult (..)
  , VaultToken (..)
  , VaultTokenSelfObservation (..)
  , vaultAccessorLookupVanished
  )
import TestSupport

-- Independent copy of the v1 wire shape; constructor names are not encoded.
data LegacySessionPhase
  = LegacySessionVacant !Natural
  | LegacySessionAcquiring !ServiceSessionBinding
  | LegacySessionPrecleaned !ServiceSessionBinding
  | LegacySessionLoginAttemptCommitted !ServiceSessionBinding
  | LegacySessionActive !ServiceSessionBinding !Text
  | LegacySessionCleanupRequired !ServiceSessionBinding !(Maybe Text)
  | LegacySessionCleanupProven !ServiceSessionBinding
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data LegacySessionJournal = LegacySessionJournal !Word16 !Text !LegacySessionPhase
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- Frozen version-2 shape, including the workload constructor at index seven.
data LegacyV2Phase
  = LegacyV2Vacant !Natural
  | LegacyV2Acquiring !ServiceSessionBinding
  | LegacyV2Precleaned !ServiceSessionBinding
  | LegacyV2LoginAttemptCommitted !ServiceSessionBinding
  | LegacyV2Active !ServiceSessionBinding !Text
  | LegacyV2CleanupRequired !ServiceSessionBinding !(Maybe Text)
  | LegacyV2CleanupProven !ServiceSessionBinding
  | LegacyV2WorkloadOwned !LegacyV2Phase !ServiceSessionWorkload
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data LegacyV2Journal = LegacyV2Journal !Word16 !Text !LegacyV2Phase
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- Frozen version-4 shape, including the pre-create reservation at index nine.
data LegacyV4Phase
  = LegacyV4Vacant !Natural
  | LegacyV4Acquiring !ServiceSessionBinding
  | LegacyV4Precleaned !ServiceSessionBinding
  | LegacyV4LoginAttemptCommitted !ServiceSessionBinding
  | LegacyV4Active !ServiceSessionBinding !Text
  | LegacyV4CleanupRequired !ServiceSessionBinding !(Maybe Text)
  | LegacyV4CleanupProven !ServiceSessionBinding
  | LegacyV4WorkloadOwned !LegacyV4Phase !ServiceSessionWorkload
  | LegacyV4VerifiedWorkloadOwned !LegacyV4Phase !ServiceSessionWorkloadEvidence
  | LegacyV4CreationReserved !ServiceSessionCreationReservation
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data LegacyV4Journal = LegacyV4Journal !Word16 !Text !LegacyV4Phase
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- Frozen version-5 shape, including dispatch ownership at index ten.
data LegacyV5Phase
  = LegacyV5Vacant !Natural
  | LegacyV5Acquiring !ServiceSessionBinding
  | LegacyV5Precleaned !ServiceSessionBinding
  | LegacyV5LoginAttemptCommitted !ServiceSessionBinding
  | LegacyV5Active !ServiceSessionBinding !Text
  | LegacyV5CleanupRequired !ServiceSessionBinding !(Maybe Text)
  | LegacyV5CleanupProven !ServiceSessionBinding
  | LegacyV5WorkloadOwned !LegacyV5Phase !ServiceSessionWorkload
  | LegacyV5VerifiedWorkloadOwned !LegacyV5Phase !ServiceSessionWorkloadEvidence
  | LegacyV5CreationReserved !ServiceSessionCreationReservation
  | LegacyV5DispatchOwned !LegacyV5Phase !ServiceSessionWorkloadEvidence !ServiceSessionDispatchState
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data LegacyV5Journal = LegacyV5Journal !Word16 !Text !LegacyV5Phase
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- Frozen version-6 dispatch state and envelope, before cleanup ownership.
data LegacyV6DispatchState
  = LegacyV6Ready
  | LegacyV6Issued
  | LegacyV6Settled
  | LegacyV6Retired
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data LegacyV6Phase
  = LegacyV6Vacant !Natural
  | LegacyV6Acquiring !ServiceSessionBinding
  | LegacyV6Precleaned !ServiceSessionBinding
  | LegacyV6LoginAttemptCommitted !ServiceSessionBinding
  | LegacyV6Active !ServiceSessionBinding !Text
  | LegacyV6CleanupRequired !ServiceSessionBinding !(Maybe Text)
  | LegacyV6CleanupProven !ServiceSessionBinding
  | LegacyV6WorkloadOwned !LegacyV6Phase !ServiceSessionWorkload
  | LegacyV6VerifiedWorkloadOwned !LegacyV6Phase !ServiceSessionWorkloadEvidence
  | LegacyV6CreationReserved !ServiceSessionCreationReservation
  | LegacyV6DispatchOwned !LegacyV6Phase !ServiceSessionWorkloadEvidence !LegacyV6DispatchState
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data LegacyV6Journal = LegacyV6Journal !Word16 !Text !LegacyV6Phase
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

legacySessionAccepts :: ByteString.ByteString -> Bool
legacySessionAccepts bytes = case deserialiseOrFail (LazyByteString.fromStrict bytes) of
  Left _ -> False
  Right (LegacySessionJournal version _ _) -> version == 1

vaultSessionSafetySuite :: SuiteBuilder ()
vaultSessionSafetySuite =
  describe "Sprint 4.50 finite one-shot Vault-session cleanup" $ do
    it "requires the issued service token's matching explicit hard cap" $ do
      let login =
            validBatchLogin
              { vaultLoginTokenType = "service"
              , vaultLoginAccessor = "accessor"
              , vaultLoginLeaseSeconds = 300
              , vaultLoginRenewable = True
              }
          observed = VaultTokenSelfObservation "accessor" "service" 299 300 True
          rejected =
            [ (0, login, observed)
            , (300, login, observed {vaultTokenSelfExplicitMaxTtlSeconds = 0})
            , (300, login, observed {vaultTokenSelfExplicitMaxTtlSeconds = 301})
            , (300, login, observed {vaultTokenSelfTtlSeconds = 0})
            , (300, login, observed {vaultTokenSelfTtlSeconds = 301})
            , (300, login {vaultLoginLeaseSeconds = 301}, observed)
            , (300, login {vaultLoginAccessor = " accessor"}, observed)
            , (300, login, observed {vaultTokenSelfAccessor = "other"})
            , (300, login, observed {vaultTokenSelfType = "batch"})
            , (300, login, observed {vaultTokenSelfRenewable = False})
            ]
      isBoundedServiceTokenLogin 300 login observed `shouldBe` True
      forM_ rejected $ \(limit, issued, actual) ->
        isBoundedServiceTokenLogin limit issued actual `shouldBe` False

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

    it "Sprint 2.116 requires the issued auditor lease to equal its compiled bound" $ do
      isExactBoundedBatchAuditorLogin
        300
        validBatchLogin {vaultLoginLeaseSeconds = 300}
        `shouldBe` True
      isExactBoundedBatchAuditorLogin 300 validBatchLogin `shouldBe` False

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

    it "reads frozen version-5 and version-6 workload records" $ do
      let operation = Text.replicate 64 "a"
          job = "target-secret-" <> Text.take 40 operation
          workload = mustRight (mkServiceSessionWorkload job "job-uid" "target-pod" "pod-uid" "sa-uid")
          attempt =
            WireTargetWorkerAttemptBinding
              1
              "agent"
              "deployment-uid"
              1
              1
              "rollout"
              job
              "job-uid"
              "target-pod"
              "pod-uid"
              targetSecretWorkerVaultRole
              "sa-uid"
              "image"
          digest = targetValueDigestText (sha256TargetValueDigest (LazyByteString.toStrict (serialise attempt)))
          binding = mustRight (mkServiceSessionBinding targetSecretWorkerVaultRole operation digest 1)
          evidence = mustRight (mkServiceSessionWorkloadEvidence workload attempt)
          oldRecords =
            [ LegacyV5DispatchOwned (LegacyV5LoginAttemptCommitted binding) evidence ServiceSessionDispatchIssued
            , LegacyV5DispatchOwned
                (LegacyV5Active binding "worker-accessor")
                evidence
                ServiceSessionDispatchSettled
            ]
          oldBytes =
            map (LazyByteString.toStrict . serialise . LegacyV5Journal 5 targetSecretWorkerVaultRole) oldRecords
          checkRecord (bytes, expectedState) = case decodeServiceSessionJournal bytes of
            Left err -> expectationFailure (show err)
            Right journal -> do
              serviceSessionJournalDispatchState journal `shouldBe` Just expectedState
              serviceSessionJournalWorkload journal `shouldBe` Just workload
              encodeServiceSessionJournal journal `shouldBe` bytes
      forM_ (zip oldBytes [ServiceSessionDispatchIssued, ServiceSessionDispatchSettled]) checkRecord
      let oldV6 =
            LazyByteString.toStrict
              ( serialise
                  ( LegacyV6Journal
                      6
                      targetSecretWorkerVaultRole
                      (LegacyV6DispatchOwned (LegacyV6Active binding "worker-accessor") evidence LegacyV6Retired)
                  )
              )
      case decodeServiceSessionJournal oldV6 of
        Left err -> expectationFailure (show err)
        Right journal -> do
          serviceSessionJournalDispatchState journal `shouldBe` Just ServiceSessionWorkloadRetired
          serviceSessionJournalRecoverableRetirement journal `shouldBe` Nothing
          serviceSessionJournalWorkload journal `shouldBe` Just workload
          encodeServiceSessionJournal journal `shouldBe` oldV6
          let owner = mustRight (mkOwnerNonce "fixture-cleanup-owner")
              claimed = mustRight (stepServiceSessionJournal (ClaimServiceSessionCleanup binding owner) journal)
              newBytes = encodeServiceSessionJournal claimed
              oldReader bytes = case deserialiseOrFail (LazyByteString.fromStrict bytes) of
                Left _ -> False
                Right (LegacyV6Journal version _ _) -> version == 6
          serviceSessionJournalDispatchState claimed
            `shouldBe` Just (ServiceSessionDispatchCleanupOwned owner)
          oldReader newBytes `shouldBe` False
          decodeServiceSessionJournal newBytes `shouldBe` Right claimed

    it "reads frozen version-4 reservations and rejects newer versions in the old reader" $ do
      let reservation =
            mustRight
              ( mkServiceSessionCreationReservation
                  (Text.replicate 64 "a")
                  ("target-secret-" <> Text.replicate 40 "a")
                  1
              )
          oldBytes =
            LazyByteString.toStrict
              (serialise (LegacyV4Journal 4 targetSecretWorkerVaultRole (LegacyV4CreationReserved reservation)))
          oldV7Bytes =
            LazyByteString.toStrict
              (serialise (LegacyV4Journal 7 targetSecretWorkerVaultRole (LegacyV4CreationReserved reservation)))
          malformedV8Bytes =
            LazyByteString.toStrict
              (serialise (LegacyV4Journal 8 targetSecretWorkerVaultRole (LegacyV4Vacant 1)))
          initial = mustRight (mkInitialServiceSessionJournal targetSecretWorkerVaultRole)
          newJournal = step (ReserveServiceSessionCreation reservation) initial
          newBytes = encodeServiceSessionJournal newJournal
          oldReader bytes = case deserialiseOrFail (LazyByteString.fromStrict bytes) of
            Left _ -> False
            Right (LegacyV4Journal version _ _) -> version == 4
      case decodeServiceSessionJournal oldBytes of
        Left err -> expectationFailure (show err)
        Right oldJournal -> do
          serviceSessionJournalPhase oldJournal `shouldBe` ServiceSessionCreationReserved reservation
          encodeServiceSessionJournal oldJournal `shouldBe` oldBytes
      oldReader oldBytes `shouldBe` True
      oldReader newBytes `shouldBe` False
      decodeServiceSessionJournal newBytes `shouldBe` Right newJournal
      decodeServiceSessionJournal malformedV8Bytes `shouldBe` Left ServiceSessionJournalInvariantInvalid
      serviceSessionJournalPhase newJournal `shouldBe` ServiceSessionCreationPrepared reservation
      case decodeServiceSessionJournal oldV7Bytes of
        Left err -> expectationFailure (show err)
        Right oldV7 -> do
          serviceSessionJournalPhase oldV7 `shouldBe` ServiceSessionCreationReserved reservation
          encodeServiceSessionJournal oldV7 `shouldBe` oldV7Bytes
          stepServiceSessionJournal (ReleasePreparedServiceSessionCreation reservation) oldV7
            `shouldSatisfy` either (const True) (const False)
      let issued = step (IssueServiceSessionCreation reservation) newJournal
          released = step (ReleasePreparedServiceSessionCreation reservation) newJournal
      decodeServiceSessionJournal (encodeServiceSessionJournal issued) `shouldBe` Right issued
      decodeServiceSessionJournal (encodeServiceSessionJournal released) `shouldBe` Right released
      serviceSessionJournalPhase issued `shouldBe` ServiceSessionCreationReserved reservation
      serviceSessionJournalPhase released `shouldBe` ServiceSessionVacant 1

    it "retains exact Target workload with its session and preserves legacy wire bytes" $ do
      let initial = mustRight (mkInitialServiceSessionJournal targetSecretWorkerVaultRole)
          binding =
            mustRight (mkServiceSessionBinding targetSecretWorkerVaultRole (Text.replicate 64 "a") "attempt" 1)
          workload =
            mustRight
              ( mkServiceSessionWorkload
                  ("target-secret-" <> Text.replicate 40 "a")
                  "job-uid"
                  "target-pod"
                  "pod-uid"
                  "sa-uid"
              )
          acquired = step (BeginServiceSessionWorkload binding workload) initial
          precleaned = step (CommitServiceSessionPrecleaned binding) acquired
          attempted = step (CommitServiceSessionLoginAttempt binding) precleaned
          active = step (CommitServiceSessionActive binding "worker-accessor") attempted
          required = step (RequireServiceSessionCleanup binding) active
          proven = step (CommitServiceSessionCleanupProven binding) required
          released = step (ReleaseServiceSession binding) proven
          legacy = LegacySessionJournal 1 targetSecretWorkerVaultRole (LegacySessionVacant 0)
          legacyActive =
            LegacySessionJournal 1 targetSecretWorkerVaultRole (LegacySessionActive binding "worker-accessor")
          oldAcquired = step (BeginServiceSessionAcquisition binding) initial
          oldPrecleaned = step (CommitServiceSessionPrecleaned binding) oldAcquired
          oldAttempted = step (CommitServiceSessionLoginAttempt binding) oldPrecleaned
          oldActive =
            step (CommitServiceSessionActive binding "worker-accessor") oldAttempted
          oldRequired = step (RequireServiceSessionCleanup binding) oldActive
          oldProven = step (CommitServiceSessionCleanupProven binding) oldRequired
          oldPhases =
            [ LegacySessionVacant 0
            , LegacySessionAcquiring binding
            , LegacySessionPrecleaned binding
            , LegacySessionLoginAttemptCommitted binding
            , LegacySessionActive binding "worker-accessor"
            , LegacySessionCleanupRequired binding (Just "worker-accessor")
            , LegacySessionCleanupProven binding
            ]
      encodeServiceSessionJournal initial `shouldBe` LazyByteString.toStrict (serialise legacy)
      encodeServiceSessionJournal oldActive `shouldBe` LazyByteString.toStrict (serialise legacyActive)
      map
        encodeServiceSessionJournal
        [initial, oldAcquired, oldPrecleaned, oldAttempted, oldActive, oldRequired, oldProven]
        `shouldBe` map
          (LazyByteString.toStrict . serialise . LegacySessionJournal 1 targetSecretWorkerVaultRole)
          oldPhases
      map serviceSessionJournalWorkload [acquired, precleaned, attempted, active, required, proven]
        `shouldBe` replicate 6 (Just workload)
      serviceSessionJournalWorkload released `shouldBe` Nothing
      serviceSessionJournalPhase released `shouldBe` ServiceSessionVacant 1
      map
        (decodeServiceSessionJournal . encodeServiceSessionJournal)
        [initial, acquired, active, released]
        `shouldBe` map Right [initial, acquired, active, released]
      encodeServiceSessionJournal released
        `shouldNotBe` LazyByteString.toStrict
          (serialise (LegacySessionJournal 1 targetSecretWorkerVaultRole (LegacySessionVacant 1)))
      encodeServiceSessionJournal acquired
        `shouldBe` LazyByteString.toStrict
          ( serialise
              ( LegacyV2Journal
                  2
                  targetSecretWorkerVaultRole
                  (LegacyV2WorkloadOwned (LegacyV2Acquiring binding) workload)
              )
          )
      encodeServiceSessionJournal released
        `shouldBe` LazyByteString.toStrict
          (serialise (LegacyV2Journal 2 targetSecretWorkerVaultRole (LegacyV2Vacant 1)))
      legacySessionAccepts (encodeServiceSessionJournal acquired) `shouldBe` False
      legacySessionAccepts (encodeServiceSessionJournal released) `shouldBe` False
      stepServiceSessionJournal (BeginServiceSessionAcquisition binding) released
        `shouldBe` Left ServiceSessionJournalInvariantInvalid
      decodeServiceSessionJournal
        ( LazyByteString.toStrict
            (serialise (LegacySessionJournal 2 targetSecretWorkerVaultRole (LegacySessionAcquiring binding)))
        )
        `shouldBe` Left ServiceSessionJournalInvariantInvalid
      let wrongWorkload = mustRight (mkServiceSessionWorkload "different-job" "job-uid" "target-pod" "pod-uid" "sa-uid")
      stepServiceSessionJournal (BeginServiceSessionWorkload binding wrongWorkload) initial
        `shouldBe` Left ServiceSessionJournalInvariantInvalid

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

    it
      "Sprint 2.137 passes over an accessor that vanished between the inventory and its lookup and still revokes the members"
      $ do
        -- The 2026-10-12 live race: a token expires or a cleanup revokes it after the
        -- LIST, the lookup then names it unknown, and the whole audit used to stop.
        inventories <- newIORef [["gone", "member"], ["gone"], []]
        revoked <- newIORef ([] :: [Text])
        result <-
          revokeAndProveVaultAccessorSubjectAbsent
            VaultAccessorAuditOps
              { auditListAccessors = popInventory inventories
              , auditLookupAccessor = \accessor ->
                  pure
                    ( if accessor == "gone"
                        then Left VaultAccessorLookupAbsent
                        else Right matchingAccessorInfo
                    )
              , auditRevokeAccessor = \accessor ->
                  modifyIORef' revoked (++ [accessor]) >> pure (Right ())
              , auditObserveAccessorAbsent = \_ -> pure (Right True)
              , auditWaitVisibilityGrace = pure (Right ())
              }
            accessorSubject
            Nothing
        result `shouldBe` Right ()
        readIORef revoked `shouldReturn` ["member"]

    it "Sprint 2.137 reads the answer Vault 1.18.3 measured for an unknown accessor, and nothing else" $ do
      let invalidAccessor =
            "{\"errors\":[\"1 error occurred:\\n\\t* invalid accessor\\n\\n\"]}"
      vaultAccessorLookupVanished (HttpStatus 400 invalidAccessor) `shouldBe` True
      map
        vaultAccessorLookupVanished
        [ HttpStatus 404 invalidAccessor
        , HttpStatus 403 invalidAccessor
        , HttpStatus 400 "{\"errors\":[\"missing accessor\"]}"
        , HttpStatus 400 "{\"errors\":[\"failed to parse JSON input\"]}"
        , HttpStatus 403 "{\"errors\":[\"permission denied\"]}"
        , HttpStatus 503 ""
        , HttpConnectionFailure invalidAccessor
        , HttpTimeout invalidAccessor
        , HttpDecode invalidAccessor
        ]
        `shouldBe` replicate 9 False
      classifyVaultAccessorLookupResponse (Left (HttpStatus 400 invalidAccessor))
        `shouldBe` Left VaultAccessorLookupAbsent
      classifyVaultAccessorLookupResponse (Left (HttpStatus 404 invalidAccessor))
        `shouldBe` Left VaultAccessorLookupUnavailable

    it
      "Sprint 2.73 retains authoritative detailed audit failures and keeps revoke responses provisional"
      $ do
        let successfulOps :: VaultAccessorAuditDetailedOps IO Text
            successfulOps =
              VaultAccessorAuditDetailedOps
                { detailedAuditListAccessors = pure (Right [])
                , detailedAuditLookupAccessor = \_ -> pure (Right matchingAccessorInfo)
                , detailedAuditRevokeAccessor = \_ -> pure (Right ())
                , detailedAuditObserveAccessorAbsent = \_ -> pure (Right True)
                , detailedAuditWaitVisibilityGrace = pure (Right ())
                }
            run ops known =
              revokeAndProveVaultAccessorSubjectAbsentDetailed ops accessorSubject known
        run
          successfulOps {detailedAuditListAccessors = pure (Left "list")}
          Nothing
          `shouldReturn` Left (VaultAccessorAuditDetailedObservationFailed "list")
        run
          successfulOps
            { detailedAuditListAccessors = pure (Right ["accessor"])
            , detailedAuditLookupAccessor =
                \_ -> pure (Left (VaultAccessorDetailedLookupFailed "lookup"))
            }
          Nothing
          `shouldReturn` Left (VaultAccessorAuditDetailedClassificationFailed "lookup")
        -- An accessor Vault no longer knows is passed over, not a failure.
        run
          successfulOps
            { detailedAuditListAccessors = pure (Right ["gone"])
            , detailedAuditLookupAccessor = \_ -> pure (Left VaultAccessorDetailedLookupVanished)
            }
          Nothing
          `shouldReturn` Right ()
        run
          successfulOps {detailedAuditObserveAccessorAbsent = \_ -> pure (Left "absence")}
          (Just "known-accessor")
          `shouldReturn` Left (VaultAccessorAuditDetailedObservationFailed "absence")
        run
          successfulOps {detailedAuditWaitVisibilityGrace = pure (Left "visibility")}
          Nothing
          `shouldReturn` Left (VaultAccessorAuditDetailedVisibilityWaitFailed "visibility")
        run successfulOps (Just " ")
          `shouldReturn` Left VaultAccessorAuditDetailedIdentityInvalid

        inventories <- newIORef [["accessor"], [], []]
        run
          successfulOps
            { detailedAuditListAccessors = popInventory inventories
            , detailedAuditRevokeAccessor = \_ -> pure (Left "lost-revoke-response")
            }
          Nothing
          `shouldReturn` Right ()

        run
          successfulOps
            { detailedAuditListAccessors = pure (Right ["still-visible"])
            , detailedAuditRevokeAccessor = \_ -> pure (Left "lost-revoke-response")
            }
          Nothing
          `shouldReturn` Left VaultAccessorAuditDetailedStableAbsenceFailed

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
        pure $
          maybe
            (Left VaultAccessorLookupAbsent)
            Right
            (Map.lookup accessor observed)
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
