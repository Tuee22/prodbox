{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthorityProviderAdmissionEpoch
  ( lifecycleAuthorityProviderAdmissionEpochSuite
  )
where

import Codec.Serialise (Serialise)
import Control.Monad (filterM, forM_)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, isPrefixOf, sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word8)
import GHC.Generics (Generic)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  , AuthorityControlPayload (..)
  , AuthorityTransitionResult (..)
  , authorityAdmissionStateCodec
  , authorityControlPayloadCommand
  , authorityControlPayloadRoute
  , authorityTransitionHttpStatus
  , authorityTransitionResponseBody
  , serveAuthorityControlRequest
  )
import Prodbox.ControlPlane.AuthorityControlClient
  ( AuthorityControlClientError (..)
  , decodeAuthorityControlTextResponse
  , decodeProviderAdmissionRecoveryResponse
  , decodeProviderBootstrapPredecessorResponse
  )
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal (CallerService))
import Prodbox.ControlPlane.Client (ControlPlaneResponse (..))
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneRequest
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , AuthorityAdmissionCommand (..)
  , AuthorityAdmissionCommandTag (..)
  , AuthorityAdmissionDecision (..)
  , AuthorityControlRoute (..)
  , AuthorityProviderSettlementDecision (..)
  , AuthorityProviderSubmissionDecision (..)
  , ProviderOperationCleanupOwner (ProviderOperationUnownedByCleanupRun)
  , authorityAggregateCascadeTerminalAuditReceipt
  , authorityAggregateProviderAdmissionEpochView
  , authorityAggregateProviderOperations
  , authorityControlRouteIssuedCommandTag
  , authorityControlRouteTag
  , confirmAggregateCascadeTerminalAuditReceipt
  , initialCleanInstallAuthority
  , initialCleanInstallAuthorityWithRegisteredClients
  , providerOperationKey
  , stepAuthorityAdmission
  , stepRegisteredProviderSettlement
  , stepRegisteredProviderSubmission
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKey
  , RegisteredClientGeneration
  , RegisteredClientTable
  , clientPrincipalForCaller
  , mkClientSubmissionKey
  , mkRegisteredClientGeneration
  , mkRegisteredClientSlot
  , mkRegisteredClientSpec
  , mkRegisteredClientTable
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityGenesisCommand (..)
  , BackupReceipt (BackupReceipt)
  , GenesisPlan (GenesisPlan)
  , TargetAgentGenerationReceipt (TargetAgentGenerationReceipt)
  )
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
import Prodbox.Lifecycle.Authority.Submission
  ( OperationId
  , RequestDigest (RequestDigest)
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCodec (decodeModelBValue, encodeModelBValue)
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDigest
  , CleanupRunId
  , mkCleanupAttemptId
  , mkCleanupDigest
  , mkCleanupNodeId
  , mkCleanupOperationId
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (IssueEksClientAuth, ObserveOperationalIdentity, ObserveOwnedResourceTags)
  , ProviderOwnedTagQuery (ProviderOwnedTagKeyQuery)
  , maximumProviderIntentEvidenceCharacters
  , mkEksClientAuthRequest
  , providerIntentEvidenceMaximumCharacters
  , validateProviderIntentEvidence
  )
import Prodbox.Lifecycle.Teardown.ProviderDispatch
  ( mkFencedTerminalAuditProviderDispatchKey
  , mkTerminalAuditProviderDispatchKey
  , providerDispatchSubmissionKey
  )
import Prodbox.Runtime.Role (RuntimeRole (ProviderWorkerRuntime))
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import TestSupport

-- | Sprint 6.5: the one intent whose evidence is a sealed capability
-- projection rather than a short observation.
issueEksClientAuthIntent :: ProviderIntent
issueEksClientAuthIntent =
  case mkEksClientAuthRequest
    "123456789012"
    (fixtureAwsRegion FixtureCaCentral1)
    "aws-eks-test-cluster"
    (ByteString.replicate 32 7) of
    Left err -> error ("expected an EKS client-auth request, got " <> show err)
    Right request -> IssueEksClientAuth request

lifecycleAuthorityProviderAdmissionEpochSuite :: SuiteBuilder ()
lifecycleAuthorityProviderAdmissionEpochSuite =
  describe "Lifecycle Provider admission epoch" $ do
    it "discovers only the retained bootstrap predecessor without any aggregate write" $ do
      initial <- expectRightIO (initialCleanInstallAuthority 1 1)
      serving <- decidedAggregate initial (BindProviderAdmissionGeneration 7)
      frozen <- decidedAggregate initial (FreezeProviderAdmissionAtGeneration 7 auditFreezeBinding)
      recorded <-
        decidedAggregate frozen (RecordCascadeTerminalAuditReceipt auditFreezeBinding auditReceipt)
      revoked <-
        decidedAggregate
          recorded
          (RevokeCascadeProviderCredential auditFreezeBinding recoveryRevocationProof)
      mapM_
        ( \(aggregate, present, expectedPhase) -> do
            (result, writes) <-
              observeControlFixture (Right aggregate) AuthorityControlObserveProviderBootstrapPredecessor
            writes `shouldBe` 0
            authorityTransitionHttpStatus result `shouldBe` ReplyOk
            predecessor <-
              expectRightIO
                ( decodeProviderBootstrapPredecessorResponse
                    (ControlPlaneResponse 200 (LazyByteString.toStrict (authorityTransitionResponseBody result)))
                )
            case predecessor of
              Nothing -> present `shouldBe` False
              Just metadata -> do
                present `shouldBe` True
                providerBootstrapPredecessorRunId metadata
                  `shouldBe` expectRight (mkCleanupRunId "provider-epoch-audit-run")
                providerBootstrapPredecessorGraphDigest metadata
                  `shouldBe` expectRight (mkCleanupDigest (Text.replicate 64 "b"))
                providerBootstrapPredecessorScopeDigest metadata `shouldBe` auditScopeDigest
                Just (providerBootstrapPredecessorPhase metadata) `shouldBe` expectedPhase
                LazyByteString.length (authorityTransitionResponseBody result) `shouldSatisfy` (< 1024)
            snd (stepAuthorityAdmission aggregate ObserveProviderBootstrapPredecessor) `shouldBe` aggregate
        )
        [ (initial, False, Nothing)
        , (serving, False, Nothing)
        , (frozen, True, Just ProviderBootstrapFrozen)
        , (recorded, True, Just ProviderBootstrapRecorded)
        , (revoked, True, Just ProviderBootstrapRevoked)
        ]

    it "keeps unavailable predecessor reads distinct from absence and rejects malformed metadata" $ do
      (failed, writes) <-
        observeControlFixture (Left "unavailable") AuthorityControlObserveProviderBootstrapPredecessor
      writes `shouldBe` 0
      authorityTransitionHttpStatus failed `shouldBe` ReplyServiceUnavailable
      decodeProviderBootstrapPredecessorResponse
        (ControlPlaneResponse 503 (LazyByteString.toStrict (authorityTransitionResponseBody failed)))
        `shouldSatisfy` isLeft
      let malformed =
            BootstrapPredecessorWireFixture
              (expectRight (mkCleanupRunId "provider-epoch-audit-run"))
              (expectRight (mkCleanupDigest (Text.replicate 64 "a")))
              "invalid scope"
              ProviderBootstrapRevoked
      decodeProviderBootstrapPredecessorResponse
        (ControlPlaneResponse 200 (LazyByteString.toStrict (encodeControlPlaneResponse (Just malformed))))
        `shouldSatisfy` isLeft
      decodeProviderBootstrapPredecessorResponse
        (ControlPlaneResponse 200 "authority-provider-bootstrap-predecessor-observed")
        `shouldSatisfy` isLeft
      decodeProviderBootstrapPredecessorResponse (ControlPlaneResponse 200 (ByteString.replicate 65537 0))
        `shouldSatisfy` isLeft

    it "appends the bootstrap query at wire index ten and leaves earlier control bytes unchanged" $ do
      let query = AuthorityControlObserveProviderBootstrapPredecessor
          bytes = encodeControlPlaneRequest query
      LazyByteString.take 5 bytes `shouldBe` LazyByteString.pack [0x83, 0, 1, 0x81, 10]
      decodeControlPlaneRequest 4096 bytes `shouldBe` Right query
      authorityControlPayloadCommand query `shouldBe` ObserveProviderBootstrapPredecessor
      authorityControlPayloadRoute query `shouldBe` AuthorityControlProviderBootstrapPredecessorRoute
      LazyByteString.take
        5
        (encodeControlPlaneRequest (AuthorityControlObserveProviderAdmissionRecovery auditFreezeBinding))
        `shouldBe` LazyByteString.pack [0x83, 0, 1, 0x82, 9]

    it "Sprint 6.5 refuses malformed generation and foreign audit metadata after canonical decoding" $ do
      let attempt = expectRight (mkCleanupAttemptId "provider-epoch-audit-attempt")
          otherReceipt =
            expectRight
              ( mkCascadeTerminalAuditReceipt
                  (Text.replicate 64 "f")
                  (Text.replicate 64 "1")
                  (Text.replicate 64 "2")
                  CascadeTerminalAuditReceiptClean
              )
          phases =
            [ ProviderRecoveryServing 0
            , ProviderRecoveryFrozen 0 attempt
            , ProviderRecoveryRecorded 7 attempt otherReceipt
            , ProviderRecoveryRevoked 7 attempt otherReceipt recoveryRevocationProof
            ]
      mapM_
        ( \phase -> do
            let bytes =
                  encodeControlPlaneResponse
                    (RecoveryObservationWireFixture (cascadeAuditRecoveryRequestDigest auditFreezeBinding) phase)
            decoded <- expectRightIO (decodeControlPlaneResponse 4096 bytes)
            providerAdmissionRecoveryPhase decoded `shouldBe` phase
            decodeProviderAdmissionRecoveryResponse
              auditFreezeBinding
              (ControlPlaneResponse 200 (LazyByteString.toStrict bytes))
              `shouldSatisfy` isLeft
        )
        phases

    it "Sprint 6.5 observes recovery without any aggregate write and restores the original attempt" $ do
      initial <- expectRightIO (initialCleanInstallAuthority 1 1)
      frozen <- decidedAggregate initial (FreezeProviderAdmissionAtGeneration 7 auditFreezeBinding)
      let takeover = auditFreezeBindingFor "provider-epoch-audit-run" "takeover-attempt"
      (result, writes) <- observeRecoveryFixture (Right frozen) takeover
      writes `shouldBe` 0
      observation <- recoveryObservation result
      providerAdmissionRecoveryPhase observation
        `shouldBe` ProviderRecoveryFrozen 7 (expectRight (mkCleanupAttemptId "provider-epoch-audit-attempt"))
      restoreCascadeAuditRecoveryBinding takeover observation `shouldBe` Right auditFreezeBinding
      cascadeAuditRecoveryRequestDigest takeover
        `shouldBe` cascadeAuditRecoveryRequestDigest auditFreezeBinding
      decodeProviderAdmissionRecoveryResponse
        takeover
        (ControlPlaneResponse 200 (LazyByteString.toStrict (authorityTransitionResponseBody result)))
        `shouldBe` Right observation

    it "Sprint 6.5 recovery refuses another cascade without returning its reservation" $ do
      initial <- expectRightIO (initialCleanInstallAuthority 1 1)
      frozen <- decidedAggregate initial (FreezeProviderAdmissionAtGeneration 7 auditFreezeBinding)
      let neighboringBinding = auditFreezeBindingFor "neighboring-run" "neighboring-attempt"
      (result, writes) <- observeRecoveryFixture (Right frozen) neighboringBinding
      writes `shouldBe` 0
      authorityTransitionHttpStatus result `shouldBe` ReplyConflict
      decodeProviderAdmissionRecoveryResponse
        neighboringBinding
        (ControlPlaneResponse 409 (LazyByteString.toStrict (authorityTransitionResponseBody result)))
        `shouldBe` Left (AuthorityControlRefused "authority-transition-refused")

    it "Sprint 6.5 recovery keeps a failed read unobservable without manufacturing a serving epoch" $ do
      (result, writes) <- observeRecoveryFixture (Left "unavailable") auditFreezeBinding
      writes `shouldBe` 0
      result `shouldBe` AuthorityTransitionReadFailed "unavailable"
      authorityTransitionHttpStatus result `shouldBe` ReplyServiceUnavailable

    it "Sprint 6.5 recovery observes serving without minting a frozen reservation" $ do
      initial <- expectRightIO (initialCleanInstallAuthority 1 1)
      (result, writes) <- observeRecoveryFixture (Right initial) auditFreezeBinding
      writes `shouldBe` 0
      observation <- recoveryObservation result
      providerAdmissionRecoveryPhase observation `shouldBe` ProviderRecoveryLegacyServingUnbound
      restoreCascadeAuditRecoveryBinding auditFreezeBinding observation
        `shouldBe` Left ProviderRecoveryNotFrozen

    it "Sprint 6.5 recovery preserves recorded and revoked receipts under the original attempt" $ do
      initial <- expectRightIO (initialCleanInstallAuthority 1 1)
      bound <- decidedAggregate initial (BindProviderAdmissionGeneration 7)
      frozen <- decidedAggregate initial (FreezeProviderAdmissionAtGeneration 7 auditFreezeBinding)
      recorded <-
        decidedAggregate frozen (RecordCascadeTerminalAuditReceipt auditFreezeBinding auditReceipt)
      revoked <-
        decidedAggregate
          recorded
          (RevokeCascadeProviderCredential auditFreezeBinding recoveryRevocationProof)
      let attempt = expectRight (mkCleanupAttemptId "provider-epoch-audit-attempt")
          takeover = auditFreezeBindingFor "provider-epoch-audit-run" "takeover-attempt"
      mapM_
        ( \(aggregate, expected) -> do
            (result, writes) <- observeRecoveryFixture (Right aggregate) takeover
            writes `shouldBe` 0
            observation <- recoveryObservation result
            providerAdmissionRecoveryPhase observation `shouldBe` expected
            decodeProviderAdmissionRecoveryResponse
              takeover
              (ControlPlaneResponse 200 (LazyByteString.toStrict (authorityTransitionResponseBody result)))
              `shouldBe` Right observation
        )
        [ (bound, ProviderRecoveryServing 7)
        , (recorded, ProviderRecoveryRecorded 7 attempt auditReceipt)
        , (revoked, ProviderRecoveryRevoked 7 attempt auditReceipt recoveryRevocationProof)
        ]

    it "Sprint 6.5 recovery rejects a response bound to a neighboring request" $ do
      initial <- expectRightIO (initialCleanInstallAuthority 1 1)
      (result, _) <- observeRecoveryFixture (Right initial) auditFreezeBinding
      observation <- recoveryObservation result
      let neighboringBinding = auditFreezeBindingFor "neighboring-run" "neighboring-attempt"
      restoreCascadeAuditRecoveryBinding neighboringBinding observation
        `shouldBe` Left ProviderRecoveryResponseMismatch
      decodeProviderAdmissionRecoveryResponse
        neighboringBinding
        (ControlPlaneResponse 200 (LazyByteString.toStrict (authorityTransitionResponseBody result)))
        `shouldBe` Left AuthorityControlRecoveryResponseMismatch

    it "Sprint 6.5 preserves ordinary text replies and rejects them as recovery observations" $ do
      let result = AuthorityTransitionDecided AuthorityProviderAdmissionFrozenForCascadeAudit
          bytes = authorityTransitionResponseBody result
      bytes `shouldBe` "authority-provider-admission-frozen-for-cascade-audit"
      decodeAuthorityControlTextResponse (ControlPlaneResponse 200 (LazyByteString.toStrict bytes))
        `shouldBe` Right "authority-provider-admission-frozen-for-cascade-audit"
      decodeProviderAdmissionRecoveryResponse
        auditFreezeBinding
        (ControlPlaneResponse 200 (LazyByteString.toStrict bytes))
        `shouldSatisfy` isLeft

    it "Sprint 6.5 atomically binds and freezes the legacy serving epoch" $ do
      initial <- expectRightIO (initialCleanInstallAuthority 1 1)
      let (decision, frozen) =
            stepAuthorityAdmission initial (FreezeProviderAdmissionAtGeneration 7 auditFreezeBinding)
      decision `shouldBe` AuthorityProviderAdmissionFrozenForCascadeAudit
      authorityAggregateProviderAdmissionEpochView frozen
        `shouldBe` ProviderAdmissionCascadeAuditFrozen 7

    it "Sprint 6.5 rejects pending work without the split protocol's partial bind" $ do
      closed <- expectRightIO (initialCleanInstallAuthorityWithRegisteredClients 4 4 registry)
      (_, pending) <-
        expectRightIO
          ( stepRegisteredProviderSubmission
              (openAdmission closed)
              providerCaller
              providerGeneration
              providerSubmissionKey
              providerDigest
              ObserveOperationalIdentity
              ProviderOperationUnownedByCleanupRun
          )
      assertAdmissionRefusedUnchanged pending (FreezeProviderAdmissionAtGeneration 7 auditFreezeBinding)
      splitBound <- decidedAggregate pending (BindProviderAdmissionGeneration 7)
      assertAdmissionRefusedUnchanged
        splitBound
        (FreezeProviderAdmissionForCascadeAudit auditFreezeBinding)
      authorityAggregateProviderAdmissionEpochView pending
        `shouldBe` ProviderAdmissionLegacyServingUnbound
      authorityAggregateProviderAdmissionEpochView splitBound
        `shouldBe` ProviderAdmissionServing 7

    it "Sprint 6.5 withholds an invalid or neighboring generation without changing state" $ do
      initial <- expectRightIO (initialCleanInstallAuthority 1 1)
      assertAdmissionRefusedUnchanged initial (FreezeProviderAdmissionAtGeneration 0 auditFreezeBinding)
      bound <- decidedAggregate initial (BindProviderAdmissionGeneration 7)
      assertAdmissionRefusedUnchanged bound (FreezeProviderAdmissionAtGeneration 8 auditFreezeBinding)

    it "Sprint 6.5 replays an identical atomic freeze without replacing its recorded audit" $ do
      initial <- expectRightIO (initialCleanInstallAuthority 1 1)
      let command = FreezeProviderAdmissionAtGeneration 7 auditFreezeBinding
      frozen <- decidedAggregate initial command
      decidedAggregate frozen command `shouldReturn` frozen
      recorded <-
        decidedAggregate frozen (RecordCascadeTerminalAuditReceipt auditFreezeBinding auditReceipt)
      decidedAggregate recorded command `shouldReturn` recorded
      assertAdmissionRefusedUnchanged recorded (FreezeProviderAdmissionAtGeneration 8 auditFreezeBinding)

    it "Sprint 6.5 cannot use atomic freeze to reopen a revoked epoch" $ do
      initial <- expectRightIO (initialCleanInstallAuthority 1 1)
      frozen <- decidedAggregate initial (FreezeProviderAdmissionAtGeneration 7 auditFreezeBinding)
      recorded <-
        decidedAggregate frozen (RecordCascadeTerminalAuditReceipt auditFreezeBinding auditReceipt)
      let revokedProof =
            expectRight
              ( mkProviderCredentialRevocationReceipt
                  (expectRight (mkCleanupDigest (Text.replicate 64 "c")))
                  (expectRight (mkCleanupDigest (Text.replicate 64 "d")))
              )
      revoked <-
        decidedAggregate recorded (RevokeCascadeProviderCredential auditFreezeBinding revokedProof)
      assertAdmissionRefusedUnchanged revoked (FreezeProviderAdmissionAtGeneration 7 auditFreezeBinding)
      assertAdmissionRefusedUnchanged revoked (FreezeProviderAdmissionAtGeneration 8 auditFreezeBinding)

    it "Sprint 6.5 appends the atomic payload without changing earlier wire constructor indices" $ do
      let oldPayload = AuthorityControlFreezeProviderAdmissionForCascadeAudit auditFreezeBinding
          newPayload = AuthorityControlFreezeProviderAdmissionAtGeneration 7 auditFreezeBinding
          oldBytes = encodeControlPlaneRequest oldPayload
          newBytes = encodeControlPlaneRequest newPayload
      LazyByteString.take 5 oldBytes `shouldBe` LazyByteString.pack [0x83, 0, 1, 0x82, 5]
      LazyByteString.take 5 newBytes `shouldBe` LazyByteString.pack [0x83, 0, 1, 0x83, 8]
      decodeControlPlaneRequest 4096 oldBytes `shouldBe` Right oldPayload
      decodeControlPlaneRequest 4096 newBytes `shouldBe` Right newPayload
      authorityControlPayloadRoute newPayload `shouldBe` AuthorityControlCascadeGenerationFreezeRoute
      authorityControlPayloadCommand newPayload
        `shouldBe` FreezeProviderAdmissionAtGeneration 7 auditFreezeBinding

    it "decodes the exact canonical v6 bytes as LegacyServingUnbound" $ do
      ByteString.length legacyV6Fixture `shouldBe` 119
      ByteString.take 3 legacyV6Fixture `shouldBe` ByteString.pack [0x83, 0x00, 0x06]
      migrated <-
        expectRightIO
          (decodeModelBValue fixtureCodec legacyV6Fixture)
      migrated `shouldBe` expectRight (initialCleanInstallAuthority 1 1)
      authorityAggregateProviderAdmissionEpochView migrated
        `shouldBe` ProviderAdmissionLegacyServingUnbound

    it "writes canonical v7 and refuses older, newer, noncanonical, and bounded input" $ do
      initial <- expectRightIO (initialCleanInstallAuthority 1 1)
      encoded <- expectRightIO (encodeModelBValue fixtureCodec initial)
      encoded `shouldNotBe` legacyV6Fixture
      decodeModelBValue fixtureCodec encoded `shouldBe` Right initial
      encodeModelBValue fixtureCodec initial `shouldBe` Right encoded
      decodeModelBValue fixtureCodec (replaceByte 2 0x05 legacyV6Fixture)
        `shouldSatisfy` isUnsupportedVersion 5
      decodeModelBValue fixtureCodec (replaceByte 2 0x08 legacyV6Fixture)
        `shouldSatisfy` isUnsupportedVersion 8
      decodeModelBValue fixtureCodec (ByteString.snoc encoded 0)
        `shouldSatisfy` isLeft
      decodeModelBValue (authorityAdmissionStateCodec 1 1 1) legacyV6Fixture
        `shouldSatisfy` isLeft

    it "CASCADE-FENCED-AUDIT-REPLAY-2026-10-20 cannot reuse a completed unfenced query" $ do
      closed <- expectRightIO (initialCleanInstallAuthorityWithRegisteredClients 4 4 registry)
      let initial = openAdmission closed
          operationRef = expectRight (mkCleanupOperationId "fenced-audit-replay/operation")
          intent = ObserveOwnedResourceTags (ProviderOwnedTagKeyQuery "prodbox.io/managed-by")
          oldKey =
            providerDispatchSubmissionKey (expectRight (mkTerminalAuditProviderDispatchKey operationRef intent))
          -- The retained v1 completion cannot answer the fenced lane's
          -- separately named, freshly admitted query.
          fencedKey =
            providerDispatchSubmissionKey
              (expectRight (mkFencedTerminalAuditProviderDispatchKey operationRef intent))
          binding =
            expectRight
              ( mkCascadeAuditFreezeBinding
                  (expectRight (mkCleanupRunId "fenced-audit-replay/run"))
                  (expectRight (mkCleanupDigest (Text.replicate 64 "a")))
                  (expectRight (mkCleanupDigest (Text.replicate 64 "b")))
                  auditScopeDigest
                  (expectRight (mkCleanupNodeId "fenced-audit-replay/node"))
                  operationRef
                  (expectRight (mkCleanupAttemptId "fenced-audit-replay/attempt"))
                  [fencedKey]
              )
      (admitted, pending) <-
        expectRightIO
          ( stepRegisteredProviderSubmission
              initial
              providerCaller
              providerGeneration
              oldKey
              providerDigest
              intent
              ProviderOperationUnownedByCleanupRun
          )
      operation <- acceptedOperation admitted
      (_, completed) <-
        expectRightIO
          ( stepRegisteredProviderSettlement
              providerCaller
              providerGeneration
              operation
              intent
              "old-unfenced-evidence"
              pending
          )
      frozen <- decidedAggregate completed (FreezeProviderAdmissionAtGeneration 7 binding)
      (afterFreeze, _) <-
        expectRightIO
          ( stepRegisteredProviderSubmission
              frozen
              providerCaller
              providerGeneration
              fencedKey
              providerDigest
              intent
              ProviderOperationUnownedByCleanupRun
          )
      case afterFreeze of
        AuthorityProviderSubmissionAccepted _ -> pure ()
        other -> expectationFailure ("the fenced audit reused a pre-freeze answer: " <> show other)

    it "keeps legacy submissions compatible with exact duplicate and settlement replay" $ do
      closed <-
        expectRightIO
          (initialCleanInstallAuthorityWithRegisteredClients 4 4 registry)
      let initial = openAdmission closed
      authorityAggregateProviderAdmissionEpochView initial
        `shouldBe` ProviderAdmissionLegacyServingUnbound
      (accepted, pending) <-
        expectRightIO
          ( stepRegisteredProviderSubmission
              initial
              providerCaller
              providerGeneration
              providerSubmissionKey
              providerDigest
              ObserveOperationalIdentity
              ProviderOperationUnownedByCleanupRun
          )
      operation <- acceptedOperation accepted
      stepRegisteredProviderSubmission
        pending
        providerCaller
        providerGeneration
        providerSubmissionKey
        providerDigest
        ObserveOperationalIdentity
        ProviderOperationUnownedByCleanupRun
        `shouldBe` Right
          ( AuthorityProviderSubmissionDuplicatePending operation
          , pending
          )
      (settled, completed) <-
        expectRightIO
          ( stepRegisteredProviderSettlement
              providerCaller
              providerGeneration
              operation
              ObserveOperationalIdentity
              "canonical-terminal-evidence"
              pending
          )
      settled `shouldBe` AuthorityProviderSettlementCompleted
      stepRegisteredProviderSubmission
        completed
        providerCaller
        providerGeneration
        providerSubmissionKey
        providerDigest
        ObserveOperationalIdentity
        ProviderOperationUnownedByCleanupRun
        `shouldBe` Right
          ( AuthorityProviderSubmissionDuplicateCompleted
              operation
              "canonical-terminal-evidence"
          , completed
          )

    -- Sprint 6.5: the Authority carried its own copy of the Provider evidence
    -- bound, so correcting the Provider Worker alone only moved the live
    -- refusal from a 503 to a 409. Both now read one per-intent function, and
    -- the Authority refusal names the rule and the length it measured.
    it "settles per-intent evidence bounds and names the rule that refused" $ do
      closed <-
        expectRightIO
          (initialCleanInstallAuthorityWithRegisteredClients 4 4 registry)
      let initial = openAdmission closed
      (accepted, pending) <-
        expectRightIO
          ( stepRegisteredProviderSubmission
              initial
              providerCaller
              providerGeneration
              providerSubmissionKey
              providerDigest
              ObserveOperationalIdentity
              ProviderOperationUnownedByCleanupRun
          )
      operation <- acceptedOperation accepted
      (refused, _) <-
        expectRightIO
          ( stepRegisteredProviderSettlement
              providerCaller
              providerGeneration
              operation
              ObserveOperationalIdentity
              (Text.replicate 4097 "e")
              pending
          )
      refused
        `shouldBe` AuthorityProviderSettlementRefused
          "provider completion evidence is invalid: provider evidence is 4097 characters, over the maximum of 4096"
      (empty, _) <-
        expectRightIO
          ( stepRegisteredProviderSettlement
              providerCaller
              providerGeneration
              operation
              ObserveOperationalIdentity
              ""
              pending
          )
      empty
        `shouldBe` AuthorityProviderSettlementRefused
          "provider completion evidence is invalid: the provider returned no evidence"
      (admitted, _) <-
        expectRightIO
          ( stepRegisteredProviderSettlement
              providerCaller
              providerGeneration
              operation
              ObserveOperationalIdentity
              (Text.replicate 4096 "e")
              pending
          )
      admitted `shouldBe` AuthorityProviderSettlementCompleted
      -- The sealed client-auth projection the live run measured at 4,649
      -- characters settles, and the same string under a short-observation
      -- intent still does not.
      validateProviderIntentEvidence
        (issueEksClientAuthIntent)
        (Text.replicate 4649 "e")
        `shouldBe` Right (Text.replicate 4649 "e")
      validateProviderIntentEvidence
        ObserveOperationalIdentity
        (Text.replicate 4649 "e")
        `shouldBe` Left "provider evidence is 4649 characters, over the maximum of 4096"
      providerIntentEvidenceMaximumCharacters issueEksClientAuthIntent
        `shouldBe` 32793
      providerIntentEvidenceMaximumCharacters ObserveOperationalIdentity
        `shouldBe` maximumProviderIntentEvidenceCharacters

    it "covers hidden serving, pending, Frozen, and Revoked shapes without returning them" $ do
      regression <- expectRightIO fixedProviderAdmissionEpochRegression
      providerAdmissionEpochRegressionLegacyPreserved regression `shouldBe` True
      providerAdmissionEpochRegressionServingPermitsFresh regression `shouldBe` True
      providerAdmissionEpochRegressionFrozenRefusesFresh regression `shouldBe` True
      providerAdmissionEpochRegressionRevokedRefusesFresh regression `shouldBe` True
      providerAdmissionEpochRegressionNoPendingClassified regression `shouldBe` True
      providerAdmissionEpochRegressionOwnedPendingClassified regression `shouldBe` True
      providerAdmissionEpochRegressionUnownedPendingClassified regression `shouldBe` True
      providerAdmissionEpochRegressionFrozenShapeValidated regression `shouldBe` True
      providerAdmissionEpochRegressionRevokedShapeValidated regression `shouldBe` True
      providerAdmissionEpochRegressionInvalidGenerationRefused regression `shouldBe` True
      providerAdmissionEpochRegressionNonCanonicalBindingRefused regression `shouldBe` True

    -- Sprint 4.85: the two transitions this module previously described as
    -- absent. Every arm is a decision a caller could otherwise get wrong in a
    -- way no type would catch.
    it "keeps text control responses bounded, strict UTF-8 and separate from metadata CBOR" $ do
      decodeAuthorityControlTextResponse (ControlPlaneResponse 200 "authority-migration-started")
        `shouldBe` Right "authority-migration-started"
      decodeAuthorityControlTextResponse (ControlPlaneResponse 503 "authority-transition-unavailable")
        `shouldBe` Left (AuthorityControlHttpStatus 503 "authority-transition-unavailable")
      decodeAuthorityControlTextResponse
        (ControlPlaneResponse 200 (ByteString.replicate (64 * 1024 + 1) 65))
        `shouldBe` Left (AuthorityControlTextResponseTooLarge (64 * 1024 + 1) (64 * 1024))
      decodeAuthorityControlTextResponse (ControlPlaneResponse 200 (ByteString.pack [255]))
        `shouldBe` Left AuthorityControlTextResponseInvalidUtf8
      decodeAuthorityControlTextResponse
        ( ControlPlaneResponse
            200
            (LazyByteString.toStrict (encodeControlPlaneResponse ("authority-migration-started" :: Text)))
        )
        `shouldBe` Left AuthorityControlTextResponseInvalidUtf8

    it "AUTHORITY-CONTROL-LEGACY-REPLY-WIRE-2026-10-20 decodes the established text refusal" $
      decodeProviderAdmissionRecoveryResponse
        auditFreezeBinding
        (ControlPlaneResponse 409 "authority-transition-refused")
        `shouldBe` Left (AuthorityControlRefused "authority-transition-refused")

    it "Sprint 4.85 decides the freeze and generation-binding transition matrix" $ do
      regression <- expectRightIO fixedProviderAdmissionFreezeRegression
      -- A freeze must name the generation it fenced, or a later revoke cannot
      -- prove which one it revoked.
      freezeRegressionUnboundGenerationRefused regression `shouldBe` True
      -- Freezing over pending work would fence the retries that settle it.
      freezeRegressionPendingWorkRefused regression `shouldBe` True
      freezeRegressionServingFreezes regression `shouldBe` True
      -- A lost response must not burn a second reservation; a different
      -- reservation must not silently replace the committed one.
      freezeRegressionIdenticalFreezeIdempotent regression `shouldBe` True
      freezeRegressionDifferentBindingRefused regression `shouldBe` True
      freezeRegressionRevokedRefused regression `shouldBe` True
      freezeRegressionGenerationBindIdempotent regression `shouldBe` True
      freezeRegressionRebindDifferentGenerationRefused regression `shouldBe` True
      -- The freeze fences every fresh submission except the one it reserved.
      -- Fencing that one too would fence the audit the freeze exists to run.
      freezeRegressionFrozenAdmitsOnlyReservation regression `shouldBe` True

    -- Sprint 7.36: the durable terminal-audit receipt.
    it "Sprint 7.36 decides the terminal-audit receipt matrix" $ do
      regression <- expectRightIO fixedCascadeTerminalAuditReceiptRegression
      -- A receipt is the result of a reservation, so there must be one.
      auditReceiptRegressionRecordedFromFrozen regression `shouldBe` True
      auditReceiptRegressionServingRefused regression `shouldBe` True
      -- An audit taken in another scope does not answer the question this
      -- fence was raised for, from either direction.
      auditReceiptRegressionOtherBindingRefused regression `shouldBe` True
      auditReceiptRegressionScopeMismatchRefused regression `shouldBe` True
      -- A lost response must not be distinguishable from a repeat; a second,
      -- different answer must not replace a result the run may have acted on.
      auditReceiptRegressionIdenticalRecordIdempotent regression `shouldBe` True
      auditReceiptRegressionDifferentReceiptRefused regression `shouldBe` True
      auditReceiptRegressionRevokedRefused regression `shouldBe` True
      -- A freeze retried after the record must not re-enter the frozen state,
      -- which would discard the durable result.
      auditReceiptRegressionFreezeAfterRecordPreservesIt regression `shouldBe` True
      -- The read-back confirms what is durable rather than what was returned.
      auditReceiptRegressionReadBackConfirms regression `shouldBe` True
      auditReceiptRegressionReadBackRefusesOther regression `shouldBe` True
      auditReceiptRegressionReadBackRefusesUnrecorded regression `shouldBe` True
      -- Recording does not lift the fence: the audit's read-back and any
      -- response-loss retry are still that same reserved work.
      auditReceiptRegressionRecordedAdmitsOnlyReservation regression `shouldBe` True
      -- Zero escapes and zero blind spots are the clean verdict wearing
      -- another constructor.
      auditReceiptRegressionEmptyCountRefused regression `shouldBe` True
      auditReceiptRegressionNonDigestRefused regression `shouldBe` True

    it "Sprint 7.36 keeps the receipt when the audit's own submission is compacted" $ do
      -- The placement is the point. Compaction deletes a settled submission's
      -- ledger record, its epoch binding, and its provider operation together,
      -- so a verdict kept in the provider operation is a verdict the Authority
      -- may discard under capacity pressure. This drives real compaction and
      -- measures that the operation record goes while the receipt stays.
      closed <-
        expectRightIO
          (initialCleanInstallAuthorityWithRegisteredClients 1 1 registry)
      let opened = openAdmission closed
      bound <- decidedAggregate opened (BindProviderAdmissionGeneration 7)
      frozen <-
        decidedAggregate
          bound
          (FreezeProviderAdmissionForCascadeAudit auditFreezeBinding)
      (firstAccepted, firstPending) <-
        expectRightIO
          ( stepRegisteredProviderSubmission
              frozen
              providerCaller
              providerGeneration
              auditSubmissionKeyOne
              providerDigest
              ObserveOperationalIdentity
              ProviderOperationUnownedByCleanupRun
          )
      firstOperation <- acceptedOperation firstAccepted
      (_, firstSettled) <-
        expectRightIO
          ( stepRegisteredProviderSettlement
              providerCaller
              providerGeneration
              firstOperation
              ObserveOperationalIdentity
              "canonical-terminal-evidence"
              firstPending
          )
      recorded <-
        decidedAggregate
          firstSettled
          (RecordCascadeTerminalAuditReceipt auditFreezeBinding auditReceipt)
      Map.size (authorityAggregateProviderOperations recorded) `shouldBe` 1
      (secondAccepted, compacted) <-
        expectRightIO
          ( stepRegisteredProviderSubmission
              recorded
              providerCaller
              providerGeneration
              auditSubmissionKeyTwo
              providerDigest
              ObserveOperationalIdentity
              ProviderOperationUnownedByCleanupRun
          )
      -- The second reserved submission was admitted, so compaction ran to make
      -- room for it rather than the capacity refusal being the outcome.
      secondOperation <- acceptedOperation secondAccepted
      Map.member
        (providerOperationKey secondOperation)
        (authorityAggregateProviderOperations compacted)
        `shouldBe` True
      -- The first operation's durable record is gone.
      Map.member
        (providerOperationKey firstOperation)
        (authorityAggregateProviderOperations compacted)
        `shouldBe` False
      -- The receipt is not, and an independent read of the compacted object
      -- still confirms exactly what was committed.
      authorityAggregateCascadeTerminalAuditReceipt compacted
        `shouldBe` Just auditReceipt
      confirmAggregateCascadeTerminalAuditReceipt
        compacted
        auditFreezeBinding
        auditReceipt
        `shouldBe` Right ()

    it "Sprint 7.36 orders the revocation strictly after a clean recorded audit" $ do
      regression <- expectRightIO fixedCascadeCredentialRevocationRegression
      -- Nothing fenced the credential, so no cascade's audit could license it.
      revocationRegressionServingRefused regression `shouldBe` True
      -- The fence is up but the verdict is not durable. Revoking here destroys
      -- the only credential that could re-run the audit, with no record of what
      -- it found.
      revocationRegressionFrozenRefusedUnrecorded regression `shouldBe` True
      revocationRegressionOtherBindingRefused regression `shouldBe` True
      revocationRegressionCleanRecordRevokes regression `shouldBe` True
      -- An escape or a blind spot withholds the revocation rather than being
      -- overridden by it: the credential is what an investigation needs.
      revocationRegressionEscapeVerdictRefused regression `shouldBe` True
      revocationRegressionUnobservableVerdictRefused regression `shouldBe` True
      revocationRegressionIdenticalRevokeIdempotent regression `shouldBe` True
      revocationRegressionDifferentReceiptRefused regression `shouldBe` True
      -- Revocation ends the credential, not the record of why it was allowed to.
      revocationRegressionAuditReceiptSurvives regression `shouldBe` True
      -- After revocation nothing is admitted, including the reservation: there
      -- is no credential left to execute it with.
      revocationRegressionRevokedRefusesFresh regression `shouldBe` True
      -- One read-back digest may not stand for both proofs.
      revocationRegressionSharedProofRefused regression `shouldBe` True

    it
      "CASCADE-AUDIT-TAKEOVER-HANDOFF-2026-10-20 preserves the original reservation and successful takeover attempt"
      $ do
        initial <- expectRightIO (initialCleanInstallAuthority 1 1)
        frozen <- decidedAggregate initial (FreezeProviderAdmissionAtGeneration 7 auditFreezeBinding)
        recorded <-
          decidedAggregate frozen (RecordCascadeTerminalAuditReceipt auditFreezeBinding auditReceipt)
        revoked <-
          decidedAggregate
            recorded
            (RevokeCascadeProviderCredential auditFreezeBinding recoveryRevocationProof)
        let replacement = auditFreezeBindingFor "provider-epoch-audit-run" "second-audit-attempt"
        observation <- case stepAuthorityAdmission revoked (ObserveProviderAdmissionRecovery replacement) of
          (AuthorityProviderAdmissionRecoveryObserved value, _) -> pure value
          (other, _) -> expectationFailure (show other) >> fail "unreachable"
        restoreCascadeAuditRecoveryBinding replacement observation `shouldBe` Right auditFreezeBinding
        confirmation <- expectRightIO (confirmProviderCredentialRetirement replacement observation)
        let matches attempt =
              providerCredentialRetirementMatches
                (expectRight (mkCleanupRunId "provider-epoch-audit-run"))
                (expectRight (mkCleanupDigest (Text.replicate 64 "a")))
                (expectRight (mkCleanupDigest (Text.replicate 64 "b")))
                auditScopeDigest
                (expectRight (mkCleanupNodeId "provider-epoch-audit-node"))
                (expectRight (mkCleanupOperationId "provider-epoch-audit-operation"))
                (expectRight (mkCleanupAttemptId attempt))
                confirmation
        matches "second-audit-attempt" `shouldBe` True
        matches "provider-epoch-audit-attempt" `shouldBe` False

    it "binds a credential-retired handoff to every historical audit identity" $ do
      initial <- expectRightIO (initialCleanInstallAuthority 1 1)
      frozen <- decidedAggregate initial (FreezeProviderAdmissionAtGeneration 7 auditFreezeBinding)
      recorded <-
        decidedAggregate frozen (RecordCascadeTerminalAuditReceipt auditFreezeBinding auditReceipt)
      revoked <-
        decidedAggregate
          recorded
          (RevokeCascadeProviderCredential auditFreezeBinding recoveryRevocationProof)
      let observe aggregate = case stepAuthorityAdmission aggregate (ObserveProviderAdmissionRecovery auditFreezeBinding) of
            (AuthorityProviderAdmissionRecoveryObserved value, _) -> pure value
            (other, _) -> expectationFailure (show other) >> fail "unreachable"
      mapM_
        ( \aggregate -> do
            observation <- observe aggregate
            confirmProviderCredentialRetirement auditFreezeBinding observation
              `shouldSatisfy` either (const True) (const False)
        )
        [initial, frozen, recorded]
      observation <- observe revoked
      confirmation <- expectRightIO (confirmProviderCredentialRetirement auditFreezeBinding observation)
      let run = expectRight (mkCleanupRunId "provider-epoch-audit-run")
          descriptor = expectRight (mkCleanupDigest (Text.replicate 64 "a"))
          graph = expectRight (mkCleanupDigest (Text.replicate 64 "b"))
          node = expectRight (mkCleanupNodeId "provider-epoch-audit-node")
          operation = expectRight (mkCleanupOperationId "provider-epoch-audit-operation")
          attempt = expectRight (mkCleanupAttemptId "provider-epoch-audit-attempt")
          matches = providerCredentialRetirementMatches
      matches run descriptor graph auditScopeDigest node operation attempt confirmation `shouldBe` True
      sequence_
        [ matches
            (expectRight (mkCleanupRunId "other"))
            descriptor
            graph
            auditScopeDigest
            node
            operation
            attempt
            confirmation
            `shouldBe` False
        , matches run graph graph auditScopeDigest node operation attempt confirmation `shouldBe` False
        , matches run descriptor descriptor auditScopeDigest node operation attempt confirmation
            `shouldBe` False
        , matches run descriptor graph (Text.replicate 64 "f") node operation attempt confirmation
            `shouldBe` False
        , matches
            run
            descriptor
            graph
            auditScopeDigest
            (expectRight (mkCleanupNodeId "other"))
            operation
            attempt
            confirmation
            `shouldBe` False
        , matches
            run
            descriptor
            graph
            auditScopeDigest
            node
            (expectRight (mkCleanupOperationId "other"))
            attempt
            confirmation
            `shouldBe` False
        , matches
            run
            descriptor
            graph
            auditScopeDigest
            node
            operation
            (expectRight (mkCleanupAttemptId "other"))
            confirmation
            `shouldBe` False
        ]

    it "Sprint 7.36 reaches the revocation through an authenticated control route" $ do
      -- A transition no route issues is the defect this repository has found
      -- twice; the route relation is a projection rather than a claim.
      map authorityControlRouteIssuedCommandTag [minBound .. maxBound]
        `shouldContain` [RevokeCascadeProviderCredentialTag]
      authorityControlRouteTag AuthorityControlCascadeCredentialRevokeRoute
        `shouldBe` "authority-control/revoke-cascade-provider-credential"

    it "exports no generation, reservation, freeze transition, or receipt minter" $ do
      facade <-
        readFile
          "src/Prodbox/Lifecycle/Authority/ProviderAdmissionEpoch.hs"
      admission <-
        readFile "src/Prodbox/Lifecycle/Authority/Admission.hs"
      let header = moduleHeader facade
          forbidden =
            [ "ProviderAdmissionEpoch (.."
            , "ProviderCredentialGeneration"
            , "ReservedCascadeAuditSubmission"
            , "servingProviderAdmissionEpoch"
            , "stepProviderAdmissionCascade"
            , "credentialRevokedProviderAdmissionEpoch"
            ]
      mapM_ (header `shouldNotContain`) forbidden
      -- Sprint 4.85 (2026-08-18): the freeze binding and its smart constructor
      -- leave the facade, because the authenticated control route that carries
      -- one now exists -- which is the condition the facade's own comment named.
      -- What stays private is every way to apply one: the epoch constructors
      -- above, both transitions, and the revocation receipt. A caller can state
      -- the reservation it owns and cannot transition the epoch itself.
      header `shouldContain` "CascadeAuditFreezeBinding"
      header `shouldContain` "mkCascadeAuditFreezeBinding"
      -- Sprint 7.36 (2026-08-22): the revocation receipt and its minter leave
      -- the facade for exactly the reason the freeze binding did -- an
      -- authenticated control route now carries one. What stays private is the
      -- transition that applies it, so a caller can state the two read-backs it
      -- performed and still cannot revoke the credential itself.
      header `shouldContain` "mkProviderCredentialRevocationReceipt"
      header `shouldNotContain` "revokeCascadeProviderCredentialInternal"
      header `shouldNotContain` "recordCascadeTerminalAuditReceiptInternal"
      admission `shouldNotContain` "stepProviderAdmissionCascade"
      admission `shouldNotContain` "ReservedCascadeAuditSubmission"
      admission `shouldContain` "RegisteredSubmissionFresh"
      admission `shouldContain` "providerAdmissionFreshSubmissionRefusalInternal"
      doesFileExist "src/Prodbox/ControlPlane/ProviderAdmissionFreeze.hs"
        `shouldReturn` False
      doesFileExist "src/Prodbox/ControlPlane/ProviderAdmissionFreeze/Internal.hs"
        `shouldReturn` False

    it "keeps the epoch implementation package-private with exact production ownership" $ do
      importers <-
        sourceImporters
          "src"
          "import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch.Internal"
      importers
        `shouldBe` [ "src/Prodbox/Lifecycle/Authority/Admission.hs"
                   , "src/Prodbox/Lifecycle/Authority/ProviderAdmissionEpoch.hs"
                   ]
      cabal <- readFile "prodbox.cabal"
      let (libraryExposed, privateAndTests) =
            break (== "    other-modules:") (lines cabal)
          libraryPrivate =
            takeWhile (not . isPrefixOf "test-suite ") privateAndTests
          internalModule =
            "Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch.Internal"
      unlines libraryExposed `shouldNotContain` internalModule
      unlines libraryPrivate `shouldContain` internalModule

    it "keeps the transient credential proof private to its actual producer and facade" $ do
      importers <-
        sourceImporters
          "src"
          "import Prodbox.Lifecycle.Authority.ProviderCredentialAdmissionEvidence.Internal"
      importers
        `shouldBe` [ "src/Prodbox/ControlPlane/ProviderCredentialAdmissionEvidence.hs"
                   , "src/Prodbox/Lifecycle/Authority/ProviderCredentialAdmissionEvidence.hs"
                   ]
      cabal <- readFile "prodbox.cabal"
      let (libraryExposed, privateAndTests) = break (== "    other-modules:") (lines cabal)
          libraryPrivate = takeWhile (not . isPrefixOf "test-suite ") privateAndTests
          internalModule = "Prodbox.Lifecycle.Authority.ProviderCredentialAdmissionEvidence.Internal"
      unlines libraryExposed `shouldNotContain` internalModule
      unlines libraryPrivate `shouldContain` internalModule

    it "keeps raw publication and Agent proof producers package-private" $ do
      let boundaries =
            [
              ( "Prodbox.Lifecycle.Authority.ProviderCredentialCleanupEvidence.Internal"
              ,
                [ "src/Prodbox/ControlPlane/ProviderCredentialMutationRuntime.hs"
                , "src/Prodbox/Lifecycle/Authority/ProviderCredentialCleanupEvidence.hs"
                ]
              )
            ,
              ( "Prodbox.Lifecycle.CredentialProvisioner.AwsAdminAttestedRecovery.Internal"
              ,
                [ "src/Prodbox/ControlPlane/AwsAdminAuthorizedRecoveryProduction.hs"
                , "src/Prodbox/Lifecycle/CredentialProvisioner/AwsAdminAuthority.hs"
                ]
              )
            ,
              ( "Prodbox.ControlPlane.CompletedProviderPredecessor"
              ,
                [ "src/Prodbox/ControlPlane/CompletedProviderPredecessorRegression/Internal.hs"
                , "src/Prodbox/ControlPlane/ProviderCredentialMutationRuntime.hs"
                ]
              )
            ,
              ( "Prodbox.Lifecycle.Authority.CompletedProviderPredecessor.Internal"
              ,
                [ "src/Prodbox/ControlPlane/CompletedProviderPredecessor.hs"
                , "src/Prodbox/Lifecycle/Authority/CompletedProviderPredecessor.hs"
                ]
              )
            ,
              ( "Prodbox.ControlPlane.CompletedProviderPredecessorRegression.Internal"
              , ["src/Prodbox/ControlPlane/CompletedProviderPredecessorRegression.hs"]
              )
            ,
              ( "Prodbox.ControlPlane.ProviderCredentialMutationRuntime"
              ,
                [ "src/Prodbox/ControlPlane/CredentialSuccessorRegression/Internal.hs"
                , "src/Prodbox/ControlPlane/Runtime.hs"
                ]
              )
            ,
              ( "Prodbox.ControlPlane.ProviderCredentialPublication.Internal"
              ,
                [ "src/Prodbox/ControlPlane/CredentialSuccessorRegression/Internal.hs"
                , "src/Prodbox/ControlPlane/ProviderCredentialMutationRuntime.hs"
                , "src/Prodbox/ControlPlane/ProviderCredentialPublication.hs"
                ]
              )
            ,
              ( "Prodbox.ControlPlane.ProviderCredentialAdmissionEvidence"
              ,
                [ "src/Prodbox/ControlPlane/CredentialSuccessorRegression/Internal.hs"
                , "src/Prodbox/ControlPlane/ProviderCredentialMutationRuntime.hs"
                ]
              )
            ,
              ( "Prodbox.ControlPlane.CredentialSuccessorRegression.Internal"
              , ["src/Prodbox/ControlPlane/CredentialSuccessorRegression.hs"]
              )
            ]
      cabal <- readFile "prodbox.cabal"
      let (libraryExposed, privateAndTests) = break (== "    other-modules:") (lines cabal)
          libraryPrivate = takeWhile (not . isPrefixOf "test-suite ") privateAndTests
      forM_ boundaries $ \(internalModule, expected) -> do
        importers <- sourceImporters "src" ("import " ++ internalModule)
        importers `shouldBe` expected
        (internalModule `elem` map (unwords . words) libraryExposed) `shouldBe` False
        (internalModule `elem` map (unwords . words) libraryPrivate) `shouldBe` True

fixtureCodec :: ModelBCodec AuthorityAdmissionAggregate
fixtureCodec = authorityAdmissionStateCodec 4096 1 1

-- The Generic CBOR record shape matches the public response while allowing a
-- peer's malformed fields to reach the actual client decoder.
data RecoveryObservationWireFixture
  = RecoveryObservationWireFixture
      !Text
      !ProviderAdmissionRecoveryPhase
  deriving stock (Generic)
  deriving anyclass (Serialise)

data BootstrapPredecessorWireFixture
  = BootstrapPredecessorWireFixture
      !CleanupRunId
      !CleanupDigest
      !Text
      !ProviderBootstrapPredecessorPhase
  deriving stock (Generic)
  deriving anyclass (Serialise)

observeRecoveryFixture
  :: Either Text AuthorityAdmissionAggregate
  -> CascadeAuditFreezeBinding
  -> IO (AuthorityTransitionResult, Int)
observeRecoveryFixture observed binding =
  observeControlFixture observed (AuthorityControlObserveProviderAdmissionRecovery binding)

observeControlFixture
  :: Either Text AuthorityAdmissionAggregate
  -> AuthorityControlPayload
  -> IO (AuthorityTransitionResult, Int)
observeControlFixture observed payload = do
  writes <- newIORef 0
  let repository =
        AuthorityAdmissionRepository
          { readAuthorityAdmission = pure (AuthorityAdmissionSnapshot () <$> observed)
          , compareAndSwapAuthorityAdmission = \_ _ -> do
              modifyIORef' writes (+ 1)
              pure (Right ())
          }
  result <-
    serveAuthorityControlRequest
      4096
      repository
      (encodeControlPlaneRequest payload)
  count <- readIORef writes
  pure (result, count)

recoveryObservation :: AuthorityTransitionResult -> IO ProviderAdmissionRecoveryObservation
recoveryObservation result = case result of
  AuthorityTransitionDecided (AuthorityProviderAdmissionRecoveryObserved observation) -> pure observation
  other -> expectationFailure ("expected a recovery observation, got " <> show other) >> fail "unreachable"

assertAdmissionRefusedUnchanged :: AuthorityAdmissionAggregate -> AuthorityAdmissionCommand -> IO ()
assertAdmissionRefusedUnchanged aggregate command = do
  let (decision, after) = stepAuthorityAdmission aggregate command
  case decision of
    AuthorityAdmissionCommandRefused _ -> after `shouldBe` aggregate
    other -> expectationFailure ("expected an unchanged refusal, got " <> show other)

decidedAggregate
  :: AuthorityAdmissionAggregate
  -> AuthorityAdmissionCommand
  -> IO AuthorityAdmissionAggregate
decidedAggregate aggregate command =
  case stepAuthorityAdmission aggregate command of
    (AuthorityAdmissionCommandRefused refusal, _) ->
      expectationFailure ("unexpected authority refusal: " <> show refusal)
        >> fail "unreachable"
    (_, next) -> pure next

auditSubmissionKeyOne :: ClientSubmissionKey
auditSubmissionKeyOne =
  expectRight (mkClientSubmissionKey "provider-epoch/audit-one")

auditSubmissionKeyTwo :: ClientSubmissionKey
auditSubmissionKeyTwo =
  expectRight (mkClientSubmissionKey "provider-epoch/audit-two")

auditScopeDigest :: Text
auditScopeDigest = Text.replicate 64 "e"

auditFreezeBinding :: CascadeAuditFreezeBinding
auditFreezeBinding = auditFreezeBindingFor "provider-epoch-audit-run" "provider-epoch-audit-attempt"

auditFreezeBindingFor :: Text -> Text -> CascadeAuditFreezeBinding
auditFreezeBindingFor run attempt =
  expectRight
    ( mkCascadeAuditFreezeBinding
        (expectRight (mkCleanupRunId run))
        (expectRight (mkCleanupDigest (Text.replicate 64 "a")))
        (expectRight (mkCleanupDigest (Text.replicate 64 "b")))
        auditScopeDigest
        (expectRight (mkCleanupNodeId "provider-epoch-audit-node"))
        (expectRight (mkCleanupOperationId "provider-epoch-audit-operation"))
        (expectRight (mkCleanupAttemptId attempt))
        (sort [auditSubmissionKeyOne, auditSubmissionKeyTwo])
    )

auditReceipt :: CascadeTerminalAuditReceipt
auditReceipt =
  expectRight
    ( mkCascadeTerminalAuditReceipt
        auditScopeDigest
        (Text.replicate 64 "1")
        (Text.replicate 64 "2")
        CascadeTerminalAuditReceiptClean
    )

recoveryRevocationProof :: ProviderCredentialRevocationReceipt
recoveryRevocationProof =
  expectRight
    ( mkProviderCredentialRevocationReceipt
        (expectRight (mkCleanupDigest (Text.replicate 64 "c")))
        (expectRight (mkCleanupDigest (Text.replicate 64 "d")))
    )

legacyV6Fixture :: ByteString.ByteString
legacyV6Fixture =
  hexBytes
    "8300068b0081008100830001a001a0a0830001a08400a4676177732d656b73806f6177732d656b732d7375627a6f6e6580676177732d73657380686177732d7465737480a4676177732d656b73806f6177732d656b732d7375627a6f6e6580676177732d73657380686177732d7465737480a081008100"

providerCaller :: CallerPrincipal
providerCaller = CallerService ProviderWorkerRuntime

providerGeneration :: RegisteredClientGeneration
providerGeneration = expectRight (mkRegisteredClientGeneration 1)

providerSubmissionKey :: ClientSubmissionKey
providerSubmissionKey = expectRight (mkClientSubmissionKey "provider-epoch/replay")

providerDigest :: RequestDigest
providerDigest = RequestDigest "provider-epoch-replay-digest"

registry :: RegisteredClientTable
registry =
  expectRight (mkRegisteredClientTable 1 [spec])
 where
  slot = expectRight (mkRegisteredClientSlot 1)
  spec =
    expectRight
      ( mkRegisteredClientSpec
          (clientPrincipalForCaller providerCaller)
          slot
          providerGeneration
          4
      )

openAdmission :: AuthorityAdmissionAggregate -> AuthorityAdmissionAggregate
openAdmission initial =
  foldl
    (\aggregate command -> snd (stepAuthorityAdmission aggregate (ApplyAuthorityGenesis command)))
    initial
    [ BeginGenesisEstablishment
        (GenesisPlan "provider-epoch-genesis" "authority-backup/provider-epoch")
    , ObserveTargetAgentGeneration
        (TargetAgentGenerationReceipt "provider-epoch-target-generation")
    , ObserveBackupReceipt (BackupReceipt "provider-epoch-backup")
    ]

acceptedOperation
  :: AuthorityProviderSubmissionDecision
  -> IO OperationId
acceptedOperation decision = case decision of
  AuthorityProviderSubmissionAccepted operation -> pure operation
  other ->
    expectationFailure ("expected Provider admission, got " <> show other)
      >> fail "unreachable"

replaceByte
  :: Int -> Word8 -> ByteString.ByteString -> ByteString.ByteString
replaceByte index replacement bytes =
  ByteString.take index bytes
    <> ByteString.singleton replacement
    <> ByteString.drop (index + 1) bytes

isUnsupportedVersion :: Int -> Either String value -> Bool
isUnsupportedVersion version result = case result of
  Left err -> ("AuthorityAdmissionUnsupportedVersion " <> show version) `isInfixOf` err
  Right _ -> False

hexBytes :: String -> ByteString.ByteString
hexBytes input = ByteString.pack (go input)
 where
  go [] = []
  go (high : low : rest) = (16 * nibble high + nibble low) : go rest
  go _ = error "odd-length fixed hex fixture"

  nibble character
    | character >= '0' && character <= '9' = fromIntegral (fromEnum character - fromEnum '0')
    | character >= 'a' && character <= 'f' =
        fromIntegral (10 + fromEnum character - fromEnum 'a')
    | otherwise = error "non-hex fixed fixture"

moduleHeader :: String -> String
moduleHeader = unlines . takeWhile (/= "where") . lines

sourceImporters :: FilePath -> String -> IO [FilePath]
sourceImporters root importNeedle = do
  paths <- haskellFiles root
  sort <$> filterM (fileContains importNeedle) paths

haskellFiles :: FilePath -> IO [FilePath]
haskellFiles path = do
  isDirectory <- doesDirectoryExist path
  if isDirectory
    then do
      children <- listDirectory path
      concat <$> traverse (haskellFiles . (path </>)) children
    else pure [path | takeExtension path == ".hs"]

fileContains :: String -> FilePath -> IO Bool
fileContains needle path = do
  contents <- readFile path
  pure (any ((== words needle) . take 2 . words) (lines contents))

expectRight :: (Show err) => Either err value -> value
expectRight result = case result of
  Left err -> error ("unexpected fixture failure: " <> show err)
  Right value -> value

expectRightIO :: (Show err) => Either err value -> IO value
expectRightIO result = case result of
  Left err ->
    expectationFailure ("unexpected fixture failure: " <> show err)
      >> fail "unreachable"
  Right value -> pure value
