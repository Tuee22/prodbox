{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module ControlPlaneTlsRetentionEndpoint (controlPlaneTlsRetentionEndpointSuite) where

import Data.Aeson (object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRolePlainResponseCause (AuthenticatedRoleReplayCapacityExhausted)
  , AuthenticatedRolePlainResponseObservation (AuthenticatedRolePlainResponseKnown)
  , authenticatedRolePlainResponse
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (ControlPlaneRequestInvalid, ControlPlaneRequestTooLarge)
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.DedicatedAdapterStore
  ( AdapterObjectObservation (..)
  , AdapterObjectVersion
  , AdapterPutResult (..)
  , DedicatedAdapterKind (TlsRetentionAdapter)
  , DedicatedAdapterReadiness (DedicatedAdapterReady)
  , DedicatedAdapterTransport (..)
  , adapterObjectNameText
  , awsS3EndpointForRegion
  , mkAdapterObjectVersion
  , mkTlsRetentionStoreConfig
  , tlsLegacyRetentionEnvelopeObjectName
  , tlsRetentionEnvelopeObjectName
  , tlsRetentionStorePrefix
  , tlsRetentionStoreScopeKey
  , tlsRetentionStoreSubstrate
  )
import Prodbox.ControlPlane.Runtime qualified as ControlPlaneRuntime
import Prodbox.ControlPlane.TargetIntentAuthorityClient
  ( TargetIntentAuthorityClientError (..)
  , classifyTargetIntentAuthorityResponseDecodeFailure
  )
import Prodbox.ControlPlane.TargetMaterializationProduction
  ( classifyTargetIntentIssueError
  )
import Prodbox.ControlPlane.TargetOneShotOperationEndpoint
  ( TlsTargetAgentPlainResponseCause (..)
  , allTlsTargetAgentPlainResponseCauses
  , renderTlsTargetAgentPlainResponseCause
  , tlsTargetAgentPlainResponse
  )
import Prodbox.ControlPlane.TlsDekExchange
  ( TlsDekTransitBoundary (..)
  , mkTlsWrappedDek
  , prepareTlsDekExchange
  , sealTlsDekForDestination
  , tlsDekPreparedPublicKey
  )
import Prodbox.ControlPlane.TlsRetentionAdapter
  ( tlsRetentionRepositoryWithTransport
  )
import Prodbox.ControlPlane.TlsRetentionAuthorityClient
  ( TlsAuthorityPromotionOutcome (..)
  , TlsAuthorityStagingOutcome (..)
  , TlsRetentionAuthorityClient (..)
  , TlsRetentionAuthorityClientError (TlsRetentionAuthorityClientRemoteRefused)
  )
import Prodbox.ControlPlane.TlsRetentionClient
  ( TlsRetentionClient (..)
  , TlsRetentionClientError (..)
  , TlsRetentionHttpResponseObservation (..)
  , classifyTlsRetentionHttpStatus
  , renderTlsRetentionClientCause
  )
import Prodbox.ControlPlane.TlsRetentionEndpoint
import Prodbox.ControlPlane.TlsRetentionWorkflow
  ( TlsRetentionWorkflow (..)
  , TlsRetentionWorkflowError (..)
  , TlsWorkflowRetainOutcome (..)
  , retainPublicEdgeTlsWorkflow
  )
import Prodbox.ControlPlane.TlsRetentionWorkflowAuthorityEndpoint
import Prodbox.ControlPlane.TlsTargetAgentClient
  ( TlsTargetAgentClient (..)
  , TlsTargetAgentClientError (..)
  , classifyTlsTargetAgentHttpStatus
  , renderTlsTargetAgentClientCause
  )
import Prodbox.ControlPlane.TlsTargetAgentEndpoint
  ( TlsPublicEdgeSecret
  , TlsSecretApplyFailure (..)
  , TlsSecretBoundary (..)
  , TlsSecretObservation (..)
  , TlsTargetRestoreReceipt (..)
  , TlsTargetRetainReceipt (..)
  , TlsTargetVerifyMismatchCause (..)
  , TlsTargetVerifyReceipt (..)
  , TlsTargetVerifyResult (..)
  , mkTlsPublicEdgeSecret
  , verifyTlsSourceAtSelectedAgent
  )
import Prodbox.ControlPlane.TlsTargetAgentProduction
  ( TlsSecretApplyDecision (..)
  , decideTlsSecretApply
  , isTlsPublicEdgeSecretRestoreSlot
  , tlsPublicEdgeSecretBoundary
  , tlsPublicEdgeSecretRestoreSlotManifest
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..), replyStatusCode)
import Prodbox.K8s.InCluster (K8sSecretOps (..))
import Prodbox.K8s.InCluster qualified as K8s
import Prodbox.Lib.ChartPlatform
  ( PublicEdgePreserveOutcome (..)
  , PublicEdgeTlsRetainResult (..)
  , classifyPublicEdgePreserve
  , classifyPublicEdgeTlsRetainResponse
  )
import Prodbox.Lifecycle.Authority.TlsRetention
  ( CertIdentity (..)
  , KeyRotationApproval (..)
  , RetainedTlsRef (..)
  , RetentionVersion (..)
  , SourceSecretRef (..)
  , TlsLegacyRecoveryEvidence (..)
  , TlsLegacyRecoveryStagingDecision (..)
  , TlsPromotionDecision (..)
  , TlsRetentionPending (..)
  , TlsRetentionState (..)
  , TlsStagingDecision (..)
  , applyTlsLegacyRecoveryStaging
  , applyTlsPromotion
  , applyTlsStaging
  , decideTlsLegacyRecoveryStaging
  , decideTlsPromotion
  , decideTlsStaging
  , pendingTlsRetention
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( AwsAdminTargetIntentIssueCause (AwsAdminTargetIntentAuthenticatedResponseInvalid)
  )
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import TestSupport

controlPlaneTlsRetentionEndpointSuite :: SuiteBuilder ()
controlPlaneTlsRetentionEndpointSuite =
  describe "Sprint 4.50 TLS Retention opaque-envelope endpoint" $ do
    it "accepts only the exact canonical substrate/scope prefix" $ do
      let config =
            mustRight
              ( mkTlsRetentionStoreConfig
                  "home"
                  (awsS3EndpointForRegion (fixtureAwsRegion FixtureCaCentral1))
                  (fixtureAwsRegion FixtureCaCentral1)
                  "prodbox-retained"
                  "home-local"
                  "%2A.example.com%2Ctest.example.com"
                  "public-edge-tls/home-local/%2A.example.com%2Ctest.example.com"
              )
      tlsRetentionStoreSubstrate config `shouldBe` "home-local"
      tlsRetentionStoreScopeKey config `shouldBe` "%2A.example.com%2Ctest.example.com"
      tlsRetentionStorePrefix config
        `shouldBe` "public-edge-tls/home-local/%2A.example.com%2Ctest.example.com"
      mkTlsRetentionStoreConfig
        "home"
        (awsS3EndpointForRegion (fixtureAwsRegion FixtureCaCentral1))
        (fixtureAwsRegion FixtureCaCentral1)
        "prodbox-retained"
        "home-local"
        "test.example"
        "public-edge-tls/aws/test.example"
        `shouldSatisfy` isLeft
    it "patches only the exact graph-owned public-edge TLS restore slot" $ do
      let desired = samplePublicEdgeSecret "source-a" "1" "certificate"
      decideTlsSecretApply desired (Right TlsSecretMissing)
        `shouldBe` TlsSecretApplyFailed TlsSecretApplyRestoreSlotMissing
      decideTlsSecretApply desired (Right (TlsSecretRestoreSlot "42"))
        `shouldBe` TlsSecretApplyRestoreSlot "42"
    it "recognizes only the exact empty public-edge TLS restore slot" $ do
      let almostSlot secretData immutable =
            object
              [ "apiVersion" .= ("v1" :: Text)
              , "kind" .= ("Secret" :: Text)
              , "metadata"
                  .= object
                    [ "name" .= ("public-edge-tls" :: Text)
                    , "namespace" .= ("vscode" :: Text)
                    , "labels"
                        .= object
                          [ "prodbox.io/retained-secret" .= ("public-edge-tls" :: Text)
                          , "prodbox.io/tls-restore-slot" .= ("v1" :: Text)
                          ]
                    ]
              , "type" .= ("kubernetes.io/tls" :: Text)
              , "immutable" .= immutable
              , "data" .= secretData
              ]
      isTlsPublicEdgeSecretRestoreSlot tlsPublicEdgeSecretRestoreSlotManifest
        `shouldBe` True
      isTlsPublicEdgeSecretRestoreSlot
        ( almostSlot
            (object ["tls.crt" .= ("not-empty" :: Text), "tls.key" .= ("" :: Text)])
            False
        )
        `shouldBe` False
      isTlsPublicEdgeSecretRestoreSlot
        ( almostSlot
            (object ["tls.crt" .= ("" :: Text), "tls.key" .= ("" :: Text)])
            True
        )
        `shouldBe` False
    it "CAS-patches the restore slot at its observed Kubernetes resourceVersion" $ do
      capturedPatch <- newIORef Nothing
      let desired = samplePublicEdgeSecret "source-a" "1" "certificate"
          observedSlot =
            object
              [ "apiVersion" .= ("v1" :: Text)
              , "kind" .= ("Secret" :: Text)
              , "metadata"
                  .= object
                    [ "name" .= ("public-edge-tls" :: Text)
                    , "namespace" .= ("vscode" :: Text)
                    , "resourceVersion" .= ("42" :: Text)
                    , "labels"
                        .= object
                          [ "prodbox.io/retained-secret" .= ("public-edge-tls" :: Text)
                          , "prodbox.io/tls-restore-slot" .= ("v1" :: Text)
                          ]
                    ]
              , "type" .= ("kubernetes.io/tls" :: Text)
              , "data"
                  .= object
                    [ "tls.crt" .= ("" :: Text)
                    , "tls.key" .= ("" :: Text)
                    ]
              ]
          operations =
            K8sSecretOps
              { secretOpsGet = \_ _ -> pure (Right (Just observedSlot))
              , secretOpsPut = \_ _ manifest -> do
                  writeIORef capturedPatch (Just manifest)
                  pure (Left K8s.K8sSecretApplyConflict)
              }
          boundary = tlsPublicEdgeSecretBoundary operations
      applied <- applyExactPublicEdgeTlsSecret boundary desired
      applied `shouldBe` Left TlsSecretApplyConflict
      patch <- readIORef capturedPatch
      show patch `shouldContain` "resourceVersion"
      show patch `shouldContain` "42"
    it "treats exact retained content as idempotent despite a new Kubernetes identity" $ do
      let desired = samplePublicEdgeSecret "retained-source" "7" "certificate"
          existing = samplePublicEdgeSecret "restored-source" "12" "certificate"
      decideTlsSecretApply desired (Right (TlsSecretPresent existing))
        `shouldBe` TlsSecretApplyIdempotent existing
    it
      "TLS-RETENTION-VERIFY-MISMATCH-BEFORE-VSCODE-DELETE-2026-09-06 distinguishes source, certificate, and combined mismatch without retaining values"
      $ do
        let reference = referenceFor 1 (sampleEnvelope "ciphertext" "wrapped-dek")
            verify observed =
              verifyTlsSourceAtSelectedAgent
                TlsSecretBoundary
                  { readExactPublicEdgeTlsSecret = pure (Right (TlsSecretPresent observed))
                  , applyExactPublicEdgeTlsSecret =
                      \_ -> pure (Left TlsSecretApplyRequestInvalid)
                  }
                reference
        verify (samplePublicEdgeSecret "different-uid" "different-rv" "serial")
          `shouldReturn` TlsTargetVerifyMismatch TlsTargetVerifySourceMismatch
        verify (samplePublicEdgeSecret "secret-uid" "resource-version" "different-serial")
          `shouldReturn` TlsTargetVerifyMismatch TlsTargetVerifyCertificateMismatch
        verify (samplePublicEdgeSecret "different-uid" "different-rv" "different-serial")
          `shouldReturn` TlsTargetVerifyMismatch TlsTargetVerifySourceAndCertificateMismatch
        verify (samplePublicEdgeSecret "secret-uid" "resource-version" "serial")
          `shouldReturn` TlsTargetSourceVerified
            TlsTargetVerifyReceipt
              { tlsTargetVerifiedCertificate = CertIdentity "serial" "spki-digest" 2000000000
              , tlsTargetVerifiedSource = SourceSecretRef "secret-uid" "resource-version"
              }
    it "refuses different or corrupt existing public-edge Secret content" $ do
      let desired = samplePublicEdgeSecret "source-a" "1" "certificate-a"
          different = samplePublicEdgeSecret "source-b" "2" "certificate-b"
      decideTlsSecretApply desired (Right (TlsSecretPresent different))
        `shouldBe` TlsSecretApplyFailed TlsSecretApplyExistingContentMismatch
      decideTlsSecretApply desired (Right (TlsSecretCorrupt "invalid certificate"))
        `shouldBe` TlsSecretApplyFailed TlsSecretApplyExistingCorrupt
      mkTlsRetentionStoreConfig
        "home"
        (awsS3EndpointForRegion (fixtureAwsRegion FixtureCaCentral1))
        (fixtureAwsRegion FixtureCaCentral1)
        "prodbox-retained"
        "other"
        "test.example"
        "public-edge-tls/other/test.example"
        `shouldSatisfy` isLeft
    it "accepts cert-manager's empty optional adoption annotations" $ do
      let build annotations =
            mkTlsPublicEdgeSecret
              (SourceSecretRef "source-a" "1")
              (CertIdentity "serial" "spki" 1)
              "kubernetes.io/tls"
              ( Map.fromList
                  [ ("tls.crt", encodeBase64Text "certificate")
                  , ("tls.key", encodeBase64Text "private-key")
                  ]
              )
              annotations
      build
        ( Map.fromList
            [ ("cert-manager.io/ip-sans", "")
            , ("cert-manager.io/issuer-group", "")
            , ("cert-manager.io/uri-sans", "")
            ]
        )
        `shouldSatisfy` isRight
      build (Map.singleton "cert-manager.io/ip-sans" "line\nbreak")
        `shouldSatisfy` isLeft
      build (Map.singleton "cert-manager.io/ip-sans" (Text.replicate 4097 "x"))
        `shouldSatisfy` isLeft
    it "stores a sealed envelope and returns a canonical binary receipt" $ do
      (transport, _, _) <- freshMemoryTransport False
      let repository = tlsRetentionRepositoryWithTransport transport
          envelope = sampleEnvelope "certificate-ciphertext" "wrapped-dek"
          reference = referenceFor 1 envelope
          request = TlsStorePayload reference envelope
      result <- serveTlsStoreRequest 4096 repository (encodeControlPlaneRequest request)
      tlsStoreHttpStatus result `shouldBe` ReplyOk
      tlsStoreSummary result `shouldBe` "tls-store:read-back-confirmed"
      case result of
        TlsStoreSucceeded receipt ->
          decodeControlPlaneResponse
            4096
            (LazyByteString.fromStrict (tlsStoreResponseBody result))
            `shouldBe` Right receipt
        other -> expectationFailure ("expected TLS receipt, got " <> show other)
    it "recovers an applied immutable PUT after its response is lost" $ do
      (transport, _, putCount) <- freshMemoryTransport True
      let repository = tlsRetentionRepositoryWithTransport transport
          envelope = sampleEnvelope "response-loss-certificate" "wrapped-dek"
          reference = referenceFor 7 envelope
      stored <- storeTlsEnvelope repository reference envelope
      stored `shouldSatisfy` isRight
      readIORef putCount `shouldReturn` 1
      restored <- restoreTlsEnvelope repository reference
      case restored of
        Right (TlsEnvelopePresent readBack _) -> readBack `shouldBe` envelope
        other -> expectationFailure ("expected exact TLS read-back, got " <> show other)
    it "classifies PUT and confirmation failures without retaining transport detail" $ do
      let envelope = sampleEnvelope "diagnostic-certificate" "diagnostic-wrapped-dek"
          reference = referenceFor 8 envelope
          unavailable detail =
            tlsRetentionRepositoryWithTransport
              ( DedicatedAdapterTransport
                  { observeAdapterObject = \_ -> pure (Right AdapterObjectMissing)
                  , putAdapterObjectIfAbsent = \_ _ -> pure (Left detail)
                  , adapterObjectStoreReadiness = pure DedicatedAdapterReady
                  }
              )
          expected =
            Left
              ( TlsStoreRepositoryConfirmationFailed
                  TlsStorePutUnobservable
                  TlsStoreConfirmationMissing
              )
      first <- storeTlsEnvelope (unavailable "private-detail-a") reference envelope
      second <- storeTlsEnvelope (unavailable "private-detail-b") reference envelope
      first `shouldBe` expected
      second `shouldBe` expected
      let cause =
            TlsRetentionStoreRepositoryFailed
              ( TlsStoreRepositoryConfirmationFailed
                  TlsStorePutUnobservable
                  TlsStoreConfirmationMissing
              )
          (status, body) = tlsRetentionPlainResponse cause
      status `shouldBe` ReplyServiceUnavailable
      body
        `shouldBe` "tls-store:failed/put/unobservable/confirmation/missing"
      renderTlsRetentionPlainResponseCause cause
        `shouldBe` "store/repository-failed/put/unobservable/confirmation/missing"
    it "treats same-version same-envelope replay as idempotent" $ do
      (transport, _, putCount) <- freshMemoryTransport False
      let repository = tlsRetentionRepositoryWithTransport transport
          envelope = sampleEnvelope "same-certificate" "same-wrapped-dek"
          reference = referenceFor 2 envelope
      first <- storeTlsEnvelope repository reference envelope
      second <- storeTlsEnvelope repository reference envelope
      first `shouldSatisfy` isRight
      second `shouldSatisfy` isRight
      readIORef putCount `shouldReturn` 2
    it
      "TLS-AUTHORITY-RETAIN-READBACK-MISMATCH-SELECTED-AGENT-UNAVAILABLE-2026-09-08 stages before PUT, resumes pending bytes, and never re-enters legacy adoption after promotion"
      $ do
        events <- newIORef ([] :: [String])
        authorityState <- newIORef TlsRetentionEmpty
        stageCount <- newIORef (0 :: Int)
        storeCount <- newIORef (0 :: Int)
        storeInputs <- newIORef ([] :: [(RetainedTlsRef, TlsSealedEnvelope)])
        promotionApprovals <- newIORef ([] :: [KeyRotationApproval])
        protectedPrivate <- newIORef ByteString.empty
        let transit =
              TlsDekTransitBoundary
                { tlsDekTransitEncrypt = \bytes -> do
                    writeIORef protectedPrivate bytes
                    pure (Right "vault:v1:prepared")
                , tlsDekTransitDecrypt = \_ -> Right <$> readIORef protectedPrivate
                }
        prepared <- mustRight <$> prepareTlsDekExchange transit
        dekEnvelope <-
          mustRight
            <$> sealTlsDekForDestination
              (tlsDekPreparedPublicKey prepared)
              (ByteString.replicate 32 7)
        let wrapped = mustRight (mkTlsWrappedDek "vault:v1:retained")
            certificate = CertIdentity "serial" "spki-digest" 2000000000
            source = SourceSecretRef "secret-uid" "resource-version"
            retained =
              TlsTargetRetainReceipt
                { tlsTargetRetainedVersion = RetentionVersion 1
                , tlsTargetRetainedCertificate = certificate
                , tlsTargetRetainedSource = source
                , tlsTargetRetainedCertificateCiphertext = "fresh-ciphertext"
                , tlsTargetRetainedDekEnvelope = dekEnvelope
                }
            authorityClient =
              TlsRetentionAuthorityClient
                { observeTlsRetentionCurrent = do
                    recordEvent events "observe-authority"
                    Right <$> readIORef authorityState
                , stageTlsRetentionCurrent = \stageApproval candidate envelope -> do
                    recordEvent events "stage"
                    modifyIORef' stageCount (+ 1)
                    state <- readIORef authorityState
                    let decision = decideTlsStaging stageApproval state candidate envelope
                        next = applyTlsStaging decision state
                    case decision of
                      TlsStaged _ -> do
                        writeIORef authorityState next
                        pure (Right (TlsAuthorityStagingCommitted next))
                      TlsStagingNoop _ ->
                        pure (Right (TlsAuthorityStagingAlreadyPending next))
                      TlsStagingRefused refusal ->
                        pure
                          ( Left
                              ( TlsRetentionAuthorityClientRemoteRefused
                                  (Text.pack (show refusal))
                              )
                          )
                , stageTlsRetentionAfterUnrecoverableLegacy = \_ _ _ _ _ ->
                    error "ordinary retention must not stage legacy recovery"
                , promoteTlsRetentionCurrent = \promoteApproval evidence candidate -> do
                    recordEvent events "promote"
                    modifyIORef' promotionApprovals (<> [promoteApproval])
                    state <- readIORef authorityState
                    let decision = decideTlsPromotion promoteApproval evidence state candidate
                        next = applyTlsPromotion decision state
                    case decision of
                      TlsPromoted _ -> do
                        writeIORef authorityState next
                        pure (Right (TlsAuthorityPromotionCommitted next))
                      TlsPromotionNoop _ ->
                        pure (Right (TlsAuthorityPromotionAlreadyCurrent next))
                      TlsPromotionRefused refusal ->
                        pure
                          ( Left
                              ( TlsRetentionAuthorityClientRemoteRefused
                                  (Text.pack (show refusal))
                              )
                          )
                }
            adapterClient =
              TlsRetentionClient
                { observeTlsRetentionVersion = \_ -> do
                    state <- readIORef authorityState
                    case state of
                      TlsRetentionCurrent _ ->
                        error "a promoted Authority current must not re-enter legacy observation"
                      _ -> do
                        recordEvent events "observe-version"
                        pure (Right TlsVersionEnvelopeMissing)
                , observeTlsRetentionAuthorityVersion = \_ ->
                    error "ordinary retention must not observe an Authority collision"
                , storeTlsRetention = \candidate envelope -> do
                    recordEvent events "store"
                    modifyIORef' storeInputs (<> [(candidate, envelope)])
                    attempt <- atomicModifyIORef' storeCount (\count -> (count + 1, count))
                    if attempt == 0
                      then pure (Left TlsRetentionClientReceiptVersionInvalid)
                      else pure (Right (receiptForFixture candidate envelope))
                , restoreTlsRetention = \candidate -> do
                    recordEvent events "restore"
                    inputs <- readIORef storeInputs
                    pure $ case reverse inputs of
                      (_, envelope) : _ ->
                        Right
                          ( TlsEnvelopePresent
                              envelope
                              (receiptForFixture candidate envelope)
                          )
                      [] -> Left TlsRetentionClientReceiptVersionInvalid
                }
            homeAgent =
              TlsTargetAgentClient
                { prepareTlsDekDestination = do
                    recordEvent events "prepare-home"
                    pure (Right prepared)
                , retainSelectedPublicEdgeTls = \_ _ -> error "unused home retain"
                , wrapRetainedHomeTlsDek = \_ _ -> do
                    recordEvent events "wrap"
                    pure (Right wrapped)
                , rewrapRetainedHomeTlsDek = \_ _ -> error "unused home rewrap"
                , restoreSelectedPublicEdgeTls = \_ _ _ _ -> error "unused home restore"
                , verifySelectedPublicEdgeTlsSource = \_ -> error "unused home verify"
                }
            selectedAgent =
              TlsTargetAgentClient
                { prepareTlsDekDestination = error "unused selected prepare"
                , retainSelectedPublicEdgeTls = \_ _ -> do
                    recordEvent events "retain"
                    pure (Right retained)
                , wrapRetainedHomeTlsDek = \_ _ -> error "unused selected wrap"
                , rewrapRetainedHomeTlsDek = \_ _ -> error "unused selected rewrap"
                , restoreSelectedPublicEdgeTls = \_ _ _ _ -> error "unused selected restore"
                , verifySelectedPublicEdgeTlsSource = \reference -> do
                    recordEvent events "verify"
                    pure
                      ( Right
                          TlsTargetVerifyReceipt
                            { tlsTargetVerifiedCertificate = retainedCert reference
                            , tlsTargetVerifiedSource = retainedSourceSecret reference
                            }
                      )
                }
            workflow =
              TlsRetentionWorkflow
                { tlsWorkflowAuthority = authorityClient
                , tlsWorkflowAdapter = adapterClient
                , tlsWorkflowRetainedHomeAgent = homeAgent
                , tlsWorkflowSelectedAgent = selectedAgent
                }
        first <- retainPublicEdgeTlsWorkflow workflow KeyRotationNotApproved
        first
          `shouldBe` Left
            (TlsWorkflowAdapterFailed TlsRetentionClientReceiptVersionInvalid)
        readIORef authorityState >>= (`shouldSatisfy` pendingState)
        second <- retainPublicEdgeTlsWorkflow workflow KeyRotationApproved
        case second of
          Right (TlsWorkflowRetained reference) ->
            readIORef authorityState `shouldReturn` TlsRetentionCurrent reference
          other -> expectationFailure ("expected resumed retention, got " <> show other)
        inputs <- readIORef storeInputs
        case inputs of
          [firstInput, secondInput] -> firstInput `shouldBe` secondInput
          other -> expectationFailure ("expected exactly two store inputs, got " <> show other)
        readIORef stageCount `shouldReturn` 1
        readIORef promotionApprovals `shouldReturn` [KeyRotationNotApproved]
        readIORef events
          `shouldReturn` [ "observe-authority"
                         , "observe-version"
                         , "prepare-home"
                         , "retain"
                         , "wrap"
                         , "stage"
                         , "store"
                         , "observe-authority"
                         , "store"
                         , "restore"
                         , "verify"
                         , "promote"
                         ]
        writeIORef events []
        third <- retainPublicEdgeTlsWorkflow workflow KeyRotationNotApproved
        case third of
          Right (TlsWorkflowRetained reference) -> do
            retainedVersion reference `shouldBe` RetentionVersion 2
            readIORef authorityState `shouldReturn` TlsRetentionCurrent reference
          other -> expectationFailure ("expected a fresh Authority successor, got " <> show other)
        readIORef events
          `shouldReturn` [ "observe-authority"
                         , "prepare-home"
                         , "retain"
                         , "wrap"
                         , "stage"
                         , "store"
                         , "restore"
                         , "verify"
                         , "promote"
                         ]
    it "adopts a pre-outbox version only after exact Agent apply/read-back proof" $ do
      events <- newIORef ([] :: [String])
      authorityState <- newIORef TlsRetentionEmpty
      storeInputs <- newIORef ([] :: [(RetainedTlsRef, TlsSealedEnvelope)])
      protectedPrivate <- newIORef ByteString.empty
      let transit =
            TlsDekTransitBoundary
              { tlsDekTransitEncrypt = \bytes -> do
                  writeIORef protectedPrivate bytes
                  pure (Right "vault:v1:prepared")
              , tlsDekTransitDecrypt = \_ -> Right <$> readIORef protectedPrivate
              }
      prepared <- mustRight <$> prepareTlsDekExchange transit
      dekEnvelope <-
        mustRight
          <$> sealTlsDekForDestination
            (tlsDekPreparedPublicKey prepared)
            (ByteString.replicate 32 9)
      let legacyEnvelope =
            sampleEnvelope "legacy-certificate-ciphertext" "vault:v1:legacy-wrapped"
          certificate = CertIdentity "legacy-serial" "legacy-spki" 2000000000
          source = SourceSecretRef "legacy-uid" "legacy-rv"
          retained =
            TlsTargetRetainReceipt
              { tlsTargetRetainedVersion = RetentionVersion 1
              , tlsTargetRetainedCertificate = certificate
              , tlsTargetRetainedSource = source
              , tlsTargetRetainedCertificateCiphertext = "discarded-fresh-ciphertext"
              , tlsTargetRetainedDekEnvelope = dekEnvelope
              }
          authorityClient =
            TlsRetentionAuthorityClient
              { observeTlsRetentionCurrent = do
                  recordEvent events "observe-authority"
                  Right <$> readIORef authorityState
              , stageTlsRetentionCurrent = \stageApproval candidate envelope -> do
                  recordEvent events "stage"
                  state <- readIORef authorityState
                  let decision = decideTlsStaging stageApproval state candidate envelope
                      next = applyTlsStaging decision state
                  case decision of
                    TlsStaged _ -> do
                      writeIORef authorityState next
                      pure (Right (TlsAuthorityStagingCommitted next))
                    TlsStagingNoop _ ->
                      pure (Right (TlsAuthorityStagingAlreadyPending next))
                    TlsStagingRefused refusal ->
                      pure
                        ( Left
                            ( TlsRetentionAuthorityClientRemoteRefused
                                (Text.pack (show refusal))
                            )
                        )
              , stageTlsRetentionAfterUnrecoverableLegacy = \_ _ _ _ _ ->
                  error "idempotent legacy adoption must not stage recovery"
              , promoteTlsRetentionCurrent = \promoteApproval evidence candidate -> do
                  recordEvent events "promote"
                  state <- readIORef authorityState
                  let decision = decideTlsPromotion promoteApproval evidence state candidate
                      next = applyTlsPromotion decision state
                  case decision of
                    TlsPromoted _ -> do
                      writeIORef authorityState next
                      pure (Right (TlsAuthorityPromotionCommitted next))
                    TlsPromotionNoop _ ->
                      pure (Right (TlsAuthorityPromotionAlreadyCurrent next))
                    TlsPromotionRefused refusal ->
                      pure
                        ( Left
                            ( TlsRetentionAuthorityClientRemoteRefused
                                (Text.pack (show refusal))
                            )
                        )
              }
          adapterClient =
            TlsRetentionClient
              { observeTlsRetentionVersion = \version -> do
                  recordEvent events "observe-version"
                  version `shouldBe` RetentionVersion 1
                  pure (Right (TlsVersionEnvelopePresent legacyEnvelope "legacy-etag"))
              , observeTlsRetentionAuthorityVersion = \_ ->
                  error "legacy adoption must not observe an Authority collision"
              , storeTlsRetention = \candidate envelope -> do
                  recordEvent events "store"
                  modifyIORef' storeInputs (<> [(candidate, envelope)])
                  pure (Right (receiptForFixture candidate envelope))
              , restoreTlsRetention = \candidate -> do
                  recordEvent events "restore-adapter"
                  pure
                    ( Right
                        ( TlsEnvelopePresent
                            legacyEnvelope
                            (receiptForFixture candidate legacyEnvelope)
                        )
                    )
              }
          homeAgent =
            TlsTargetAgentClient
              { prepareTlsDekDestination = do
                  recordEvent events "prepare-home"
                  pure (Right prepared)
              , retainSelectedPublicEdgeTls = \_ _ -> error "unused home retain"
              , wrapRetainedHomeTlsDek = \_ _ -> error "unused home wrap"
              , rewrapRetainedHomeTlsDek = \_ _ -> do
                  recordEvent events "rewrap"
                  pure (Right dekEnvelope)
              , restoreSelectedPublicEdgeTls = \_ _ _ _ -> error "unused home restore"
              , verifySelectedPublicEdgeTlsSource = \_ -> error "unused home verify"
              }
          selectedAgentWithReadBack readBackSource =
            TlsTargetAgentClient
              { prepareTlsDekDestination = do
                  recordEvent events "prepare-selected"
                  pure (Right prepared)
              , retainSelectedPublicEdgeTls = \_ _ -> do
                  recordEvent events "retain"
                  pure (Right retained)
              , wrapRetainedHomeTlsDek = \_ _ -> error "unused selected wrap"
              , rewrapRetainedHomeTlsDek = \_ _ -> error "unused selected rewrap"
              , restoreSelectedPublicEdgeTls = \reference _ _ ciphertext -> do
                  recordEvent events "restore-legacy"
                  ciphertext `shouldBe` tlsCertificateCiphertextBytes legacyEnvelope
                  pure
                    ( Right
                        TlsTargetRestoreReceipt
                          { tlsTargetRestoredReference = reference
                          , tlsTargetRestoredReadBackSource = readBackSource
                          }
                    )
              , verifySelectedPublicEdgeTlsSource = \reference -> do
                  recordEvent events "verify"
                  pure
                    ( Right
                        TlsTargetVerifyReceipt
                          { tlsTargetVerifiedCertificate = retainedCert reference
                          , tlsTargetVerifiedSource = retainedSourceSecret reference
                          }
                    )
              }
          selectedAgent = selectedAgentWithReadBack source
          workflow =
            TlsRetentionWorkflow
              { tlsWorkflowAuthority = authorityClient
              , tlsWorkflowAdapter = adapterClient
              , tlsWorkflowRetainedHomeAgent = homeAgent
              , tlsWorkflowSelectedAgent = selectedAgent
              }
      result <- retainPublicEdgeTlsWorkflow workflow KeyRotationNotApproved
      adopted <- case result of
        Right (TlsWorkflowRetained reference) -> pure reference
        other -> do
          expectationFailure ("expected legacy adoption, got " <> show other)
          pure
            RetainedTlsRef
              { retainedVersion = RetentionVersion 1
              , retainedCert = certificate
              , retainedCiphertextDigest = tlsSealedEnvelopeDigest legacyEnvelope
              , retainedSourceSecret = source
              }
      retainedVersion adopted `shouldBe` RetentionVersion 1
      retainedCiphertextDigest adopted
        `shouldBe` tlsSealedEnvelopeDigest legacyEnvelope
      readIORef authorityState `shouldReturn` TlsRetentionCurrent adopted
      readIORef storeInputs `shouldReturn` [(adopted, legacyEnvelope)]
      readIORef events
        `shouldReturn` [ "observe-authority"
                       , "observe-version"
                       , "prepare-home"
                       , "retain"
                       , "prepare-selected"
                       , "rewrap"
                       , "restore-legacy"
                       , "stage"
                       , "store"
                       , "restore-adapter"
                       , "verify"
                       , "promote"
                       ]

      writeIORef events []
      writeIORef authorityState TlsRetentionEmpty
      writeIORef storeInputs []
      let refusingWorkflow =
            workflow
              { tlsWorkflowSelectedAgent =
                  selectedAgentWithReadBack
                    (SourceSecretRef "different-uid" "different-rv")
              }
      retainPublicEdgeTlsWorkflow refusingWorkflow KeyRotationNotApproved
        `shouldReturn` Left TlsWorkflowLegacyAdoptionNotIdempotent
      readIORef authorityState `shouldReturn` TlsRetentionEmpty
      readIORef storeInputs `shouldReturn` []
      readIORef events
        `shouldReturn` [ "observe-authority"
                       , "observe-version"
                       , "prepare-home"
                       , "retain"
                       , "prepare-selected"
                       , "rewrap"
                       , "restore-legacy"
                       ]
    it "stages a fresh version after an exact legacy Transit authentication failure" $ do
      events <- newIORef ([] :: [String])
      authorityState <- newIORef TlsRetentionEmpty
      storedEnvelope <- newIORef Nothing
      protectedPrivate <- newIORef ByteString.empty
      let transit =
            TlsDekTransitBoundary
              { tlsDekTransitEncrypt = \bytes -> do
                  writeIORef protectedPrivate bytes
                  pure (Right "vault:v1:prepared")
              , tlsDekTransitDecrypt = \_ -> Right <$> readIORef protectedPrivate
              }
      prepared <- mustRight <$> prepareTlsDekExchange transit
      dekEnvelope <-
        mustRight
          <$> sealTlsDekForDestination
            (tlsDekPreparedPublicKey prepared)
            (ByteString.replicate 32 11)
      let legacyEnvelope =
            sampleEnvelope
              "legacy-certificate-ciphertext"
              "vault:v1:prior-home-key"
          certificate = CertIdentity "current-serial" "current-spki" 2000000000
          source = SourceSecretRef "current-uid" "current-rv"
          retained version =
            TlsTargetRetainReceipt
              { tlsTargetRetainedVersion = version
              , tlsTargetRetainedCertificate = certificate
              , tlsTargetRetainedSource = source
              , tlsTargetRetainedCertificateCiphertext = "fresh-certificate-ciphertext"
              , tlsTargetRetainedDekEnvelope = dekEnvelope
              }
          authorityClient =
            TlsRetentionAuthorityClient
              { observeTlsRetentionCurrent = do
                  recordEvent events "observe-authority"
                  Right <$> readIORef authorityState
              , stageTlsRetentionCurrent = \_ _ _ ->
                  error "legacy recovery must use its evidence-bearing stage"
              , stageTlsRetentionAfterUnrecoverableLegacy =
                  \stageApproval evidence collision candidate envelope -> do
                    recordEvent events "stage-legacy-recovery"
                    state <- readIORef authorityState
                    let decision =
                          decideTlsLegacyRecoveryStaging
                            stageApproval
                            state
                            evidence
                            collision
                            candidate
                            envelope
                        next =
                          applyTlsLegacyRecoveryStaging evidence decision state
                    case decision of
                      TlsLegacyRecoveryStaged _ -> do
                        writeIORef authorityState next
                        pure (Right (TlsAuthorityStagingCommitted next))
                      TlsLegacyRecoveryCollisionRebased _ _ -> do
                        writeIORef authorityState next
                        pure (Right (TlsAuthorityStagingCommitted next))
                      TlsLegacyRecoveryCollisionSuccessorStaged _ _ ->
                        error "initial legacy recovery cannot stage collision successor"
                      TlsLegacyRecoveryStagingNoop _ ->
                        pure (Right (TlsAuthorityStagingAlreadyPending next))
                      TlsLegacyRecoveryStagingRefused refusal ->
                        pure
                          ( Left
                              ( TlsRetentionAuthorityClientRemoteRefused
                                  (Text.pack (show refusal))
                              )
                          )
              , promoteTlsRetentionCurrent = \promoteApproval evidence candidate -> do
                  recordEvent events "promote"
                  state <- readIORef authorityState
                  let decision = decideTlsPromotion promoteApproval evidence state candidate
                      next = applyTlsPromotion decision state
                  case decision of
                    TlsPromoted _ -> do
                      writeIORef authorityState next
                      pure (Right (TlsAuthorityPromotionCommitted next))
                    TlsPromotionNoop _ ->
                      pure (Right (TlsAuthorityPromotionAlreadyCurrent next))
                    TlsPromotionRefused refusal ->
                      pure
                        ( Left
                            ( TlsRetentionAuthorityClientRemoteRefused
                                (Text.pack (show refusal))
                            )
                        )
              }
          adapterClient =
            TlsRetentionClient
              { observeTlsRetentionVersion = \version -> do
                  recordEvent events "observe-version"
                  version `shouldBe` RetentionVersion 1
                  pure (Right (TlsVersionEnvelopePresent legacyEnvelope "legacy-etag"))
              , observeTlsRetentionAuthorityVersion = \_ ->
                  error "initial recovery must not observe an Authority collision"
              , storeTlsRetention = \candidate envelope -> do
                  recordEvent events "store"
                  retainedVersion candidate `shouldBe` RetentionVersion 2
                  writeIORef storedEnvelope (Just (candidate, envelope))
                  pure (Right (receiptForFixture candidate envelope))
              , restoreTlsRetention = \candidate -> do
                  recordEvent events "restore-adapter"
                  stored <- readIORef storedEnvelope
                  pure $ case stored of
                    Just (storedCandidate, envelope)
                      | storedCandidate == candidate ->
                          Right
                            ( TlsEnvelopePresent
                                envelope
                                (receiptForFixture candidate envelope)
                            )
                    _ -> Right TlsEnvelopeMissing
              }
          homeAgent =
            TlsTargetAgentClient
              { prepareTlsDekDestination = do
                  recordEvent events "prepare-home"
                  pure (Right prepared)
              , retainSelectedPublicEdgeTls = \_ _ -> error "unused home retain"
              , wrapRetainedHomeTlsDek = \_ _ -> do
                  recordEvent events "wrap"
                  pure (Right (mustRight (mkTlsWrappedDek "vault:v1:current-home")))
              , rewrapRetainedHomeTlsDek = \_ _ -> do
                  recordEvent events "rewrap"
                  pure (Left TlsTargetAgentClientHomeRewrapCiphertextAuthenticationFailed)
              , restoreSelectedPublicEdgeTls = \_ _ _ _ -> error "unused home restore"
              , verifySelectedPublicEdgeTlsSource = \_ -> error "unused home verify"
              }
          selectedAgent =
            TlsTargetAgentClient
              { prepareTlsDekDestination = do
                  recordEvent events "prepare-selected"
                  pure (Right prepared)
              , retainSelectedPublicEdgeTls = \version _ -> do
                  recordEvent events ("retain-" <> show version)
                  pure (Right (retained version))
              , wrapRetainedHomeTlsDek = \_ _ -> error "unused selected wrap"
              , rewrapRetainedHomeTlsDek = \_ _ -> error "unused selected rewrap"
              , restoreSelectedPublicEdgeTls = \_ _ _ _ ->
                  error "unopenable legacy bytes must never be applied"
              , verifySelectedPublicEdgeTlsSource = \reference -> do
                  recordEvent events "verify"
                  pure
                    ( Right
                        TlsTargetVerifyReceipt
                          { tlsTargetVerifiedCertificate = retainedCert reference
                          , tlsTargetVerifiedSource = retainedSourceSecret reference
                          }
                    )
              }
          workflow =
            TlsRetentionWorkflow
              { tlsWorkflowAuthority = authorityClient
              , tlsWorkflowAdapter = adapterClient
              , tlsWorkflowRetainedHomeAgent = homeAgent
              , tlsWorkflowSelectedAgent = selectedAgent
              }
      result <- retainPublicEdgeTlsWorkflow workflow KeyRotationNotApproved
      recovered <- case result of
        Right (TlsWorkflowRetained reference) -> pure reference
        other -> do
          expectationFailure ("expected recovery retention, got " <> show other)
          pure
            RetainedTlsRef
              { retainedVersion = RetentionVersion 2
              , retainedCert = certificate
              , retainedCiphertextDigest = tlsSealedEnvelopeDigest legacyEnvelope
              , retainedSourceSecret = source
              }
      retainedVersion recovered `shouldBe` RetentionVersion 2
      readIORef authorityState `shouldReturn` TlsRetentionCurrent recovered
      readIORef events
        `shouldReturn` [ "observe-authority"
                       , "observe-version"
                       , "prepare-home"
                       , "retain-RetentionVersion 1"
                       , "prepare-selected"
                       , "rewrap"
                       , "prepare-home"
                       , "retain-RetentionVersion 2"
                       , "wrap"
                       , "stage-legacy-recovery"
                       , "store"
                       , "restore-adapter"
                       , "verify"
                       , "promote"
                       ]
    it "rebases an exact occupied-v2 collision before ordinary read-back and promotion" $ do
      events <- newIORef ([] :: [String])
      protectedPrivate <- newIORef ByteString.empty
      let transit =
            TlsDekTransitBoundary
              { tlsDekTransitEncrypt = \bytes -> do
                  writeIORef protectedPrivate bytes
                  pure (Right "vault:v1:prepared")
              , tlsDekTransitDecrypt = \_ -> Right <$> readIORef protectedPrivate
              }
      prepared <- mustRight <$> prepareTlsDekExchange transit
      selectedDekEnvelope <-
        mustRight
          <$> sealTlsDekForDestination
            (tlsDekPreparedPublicKey prepared)
            (ByteString.replicate 32 17)
      let legacyEnvelope = sampleEnvelope "legacy-certificate" "vault:v1:old-home"
          pendingEnvelope = sampleEnvelope "pending-certificate" "vault:v1:new-home-a"
          occupiedEnvelope = sampleEnvelope "occupied-certificate" "vault:v1:new-home-b"
          certificate = CertIdentity "current-serial" "current-spki" 2000000000
          source = SourceSecretRef "current-uid" "current-rv"
          reference envelope =
            RetainedTlsRef
              { retainedVersion = RetentionVersion 2
              , retainedCert = certificate
              , retainedCiphertextDigest = tlsSealedEnvelopeDigest envelope
              , retainedSourceSecret = source
              }
          pendingCandidate = reference pendingEnvelope
          occupiedCandidate = reference occupiedEnvelope
          recoveryEvidence =
            TlsLegacyRecoveryEvidence
              { tlsLegacyRecoveryVersion = RetentionVersion 1
              , tlsLegacyRecoveryEnvelopeDigest = tlsSealedEnvelopeDigest legacyEnvelope
              }
          initialPending =
            TlsRetentionPending
              { tlsPendingPrevious = Nothing
              , tlsPendingApproval = KeyRotationNotApproved
              , tlsPendingCandidate = pendingCandidate
              , tlsPendingEnvelope = pendingEnvelope
              }
          initialState = TlsRetentionLegacyRecoveryPendingState recoveryEvidence initialPending
          exactCollision =
            TlsRetentionClientHttpStatus
              ( TlsRetentionEndpointResponse
                  ( TlsRetentionStoreRepositoryFailed
                      ( TlsStoreRepositoryConfirmationFailed
                          TlsStorePutConflict
                          TlsStoreConfirmationBytesMismatch
                      )
                  )
              )
      authorityState <- newIORef initialState
      let authorityClient =
            TlsRetentionAuthorityClient
              { observeTlsRetentionCurrent = do
                  recordEvent events "observe-authority"
                  Right <$> readIORef authorityState
              , stageTlsRetentionCurrent = \_ _ _ -> error "collision recovery uses legacy staging"
              , stageTlsRetentionAfterUnrecoverableLegacy =
                  \approval evidence collision candidate envelope -> do
                    recordEvent events "stage-collision"
                    state <- readIORef authorityState
                    let decision =
                          decideTlsLegacyRecoveryStaging
                            approval
                            state
                            evidence
                            collision
                            candidate
                            envelope
                        next = applyTlsLegacyRecoveryStaging evidence decision state
                    case decision of
                      TlsLegacyRecoveryCollisionRebased _ _ -> do
                        writeIORef authorityState next
                        pure (Right (TlsAuthorityStagingCommitted next))
                      TlsLegacyRecoveryStagingNoop _ ->
                        pure (Right (TlsAuthorityStagingAlreadyPending next))
                      refusal ->
                        pure
                          ( Left
                              (TlsRetentionAuthorityClientRemoteRefused (Text.pack (show refusal)))
                          )
              , promoteTlsRetentionCurrent = \approval evidence candidate -> do
                  recordEvent events "promote"
                  state <- readIORef authorityState
                  let decision = decideTlsPromotion approval evidence state candidate
                      next = applyTlsPromotion decision state
                  case decision of
                    TlsPromoted _ -> do
                      writeIORef authorityState next
                      pure (Right (TlsAuthorityPromotionCommitted next))
                    refusal ->
                      pure
                        ( Left
                            (TlsRetentionAuthorityClientRemoteRefused (Text.pack (show refusal)))
                        )
              }
          adapterClient =
            TlsRetentionClient
              { storeTlsRetention = \candidate envelope ->
                  if candidate == pendingCandidate && envelope == pendingEnvelope
                    then do
                      recordEvent events "store-pending-collision"
                      pure (Left exactCollision)
                    else
                      if candidate == occupiedCandidate && envelope == occupiedEnvelope
                        then do
                          recordEvent events "store-occupied"
                          pure (Right (receiptForFixture candidate envelope))
                        else error "unexpected collision store candidate"
              , restoreTlsRetention = \candidate -> do
                  recordEvent events "restore-adapter"
                  candidate `shouldBe` occupiedCandidate
                  pure
                    ( Right
                        ( TlsEnvelopePresent
                            occupiedEnvelope
                            (receiptForFixture occupiedCandidate occupiedEnvelope)
                        )
                    )
              , observeTlsRetentionVersion = \_ ->
                  error "pending recovery must not repeat legacy observation"
              , observeTlsRetentionAuthorityVersion = \version -> do
                  recordEvent events "observe-version-2"
                  version `shouldBe` RetentionVersion 2
                  pure (Right (TlsVersionEnvelopePresent occupiedEnvelope "occupied-etag"))
              }
          homeAgent =
            TlsTargetAgentClient
              { prepareTlsDekDestination = error "collision recovery does not prepare home"
              , retainSelectedPublicEdgeTls = \_ _ -> error "collision recovery does not retain"
              , wrapRetainedHomeTlsDek = \_ _ -> error "collision recovery does not wrap"
              , rewrapRetainedHomeTlsDek = \_ _ -> do
                  recordEvent events "rewrap-occupied"
                  pure (Right selectedDekEnvelope)
              , restoreSelectedPublicEdgeTls = \_ _ _ _ -> error "home does not restore selected"
              , verifySelectedPublicEdgeTlsSource = \_ -> error "home does not verify selected"
              }
          selectedAgent =
            TlsTargetAgentClient
              { prepareTlsDekDestination = do
                  recordEvent events "prepare-selected"
                  pure (Right prepared)
              , retainSelectedPublicEdgeTls = \_ _ -> error "collision recovery does not retain"
              , wrapRetainedHomeTlsDek = \_ _ -> error "selected does not wrap"
              , rewrapRetainedHomeTlsDek = \_ _ -> error "selected does not rewrap"
              , restoreSelectedPublicEdgeTls = \candidate _ _ ciphertext -> do
                  recordEvent events "apply-occupied"
                  candidate `shouldBe` occupiedCandidate
                  ciphertext `shouldBe` tlsCertificateCiphertextBytes occupiedEnvelope
                  pure
                    ( Right
                        TlsTargetRestoreReceipt
                          { tlsTargetRestoredReference = candidate
                          , tlsTargetRestoredReadBackSource = source
                          }
                    )
              , verifySelectedPublicEdgeTlsSource = \candidate -> do
                  recordEvent events "verify"
                  candidate `shouldBe` occupiedCandidate
                  pure
                    ( Right
                        TlsTargetVerifyReceipt
                          { tlsTargetVerifiedCertificate = certificate
                          , tlsTargetVerifiedSource = source
                          }
                    )
              }
          workflow =
            TlsRetentionWorkflow
              { tlsWorkflowAuthority = authorityClient
              , tlsWorkflowAdapter = adapterClient
              , tlsWorkflowRetainedHomeAgent = homeAgent
              , tlsWorkflowSelectedAgent = selectedAgent
              }
      retainPublicEdgeTlsWorkflow workflow KeyRotationNotApproved
        `shouldReturn` Right (TlsWorkflowRetained occupiedCandidate)
      readIORef authorityState `shouldReturn` TlsRetentionCurrent occupiedCandidate
      readIORef events
        `shouldReturn` [ "observe-authority"
                       , "store-pending-collision"
                       , "observe-version-2"
                       , "prepare-selected"
                       , "rewrap-occupied"
                       , "apply-occupied"
                       , "stage-collision"
                       , "store-occupied"
                       , "restore-adapter"
                       , "verify"
                       , "promote"
                       ]
    it
      "TLS-LEGACY-RECOVERY-V2-COLLISION-CIPHERTEXT-AUTHENTICATION-FAILED-2026-09-08 stages fresh fixed v3 before PUT"
      $ do
        events <- newIORef ([] :: [String])
        protectedPrivate <- newIORef ByteString.empty
        let transit =
              TlsDekTransitBoundary
                { tlsDekTransitEncrypt = \bytes -> do
                    writeIORef protectedPrivate bytes
                    pure (Right "vault:v1:prepared")
                , tlsDekTransitDecrypt = \_ -> Right <$> readIORef protectedPrivate
                }
        prepared <- mustRight <$> prepareTlsDekExchange transit
        selectedDekEnvelope <-
          mustRight
            <$> sealTlsDekForDestination
              (tlsDekPreparedPublicKey prepared)
              (ByteString.replicate 32 19)
        let legacyEnvelope = sampleEnvelope "legacy-certificate" "vault:v1:old-home"
            pendingEnvelope = sampleEnvelope "pending-certificate" "vault:v1:new-home-a"
            occupiedEnvelope = sampleEnvelope "occupied-certificate" "vault:v1:foreign-home"
            successorEnvelope = sampleEnvelope "successor-certificate" "vault:v1:successor-home"
            certificate = CertIdentity "current-serial" "current-spki" 2000000000
            source = SourceSecretRef "current-uid" "current-rv"
            reference version envelope =
              RetainedTlsRef
                { retainedVersion = version
                , retainedCert = certificate
                , retainedCiphertextDigest = tlsSealedEnvelopeDigest envelope
                , retainedSourceSecret = source
                }
            pendingCandidate = reference (RetentionVersion 2) pendingEnvelope
            successorCandidate = reference (RetentionVersion 3) successorEnvelope
            recoveryEvidence =
              TlsLegacyRecoveryEvidence
                { tlsLegacyRecoveryVersion = RetentionVersion 1
                , tlsLegacyRecoveryEnvelopeDigest = tlsSealedEnvelopeDigest legacyEnvelope
                }
            initialPending =
              TlsRetentionPending
                { tlsPendingPrevious = Nothing
                , tlsPendingApproval = KeyRotationNotApproved
                , tlsPendingCandidate = pendingCandidate
                , tlsPendingEnvelope = pendingEnvelope
                }
            initialState = TlsRetentionLegacyRecoveryPendingState recoveryEvidence initialPending
            exactCollision =
              TlsRetentionClientHttpStatus
                ( TlsRetentionEndpointResponse
                    ( TlsRetentionStoreRepositoryFailed
                        ( TlsStoreRepositoryConfirmationFailed
                            TlsStorePutConflict
                            TlsStoreConfirmationBytesMismatch
                        )
                    )
                )
        authorityState <- newIORef initialState
        let authorityClient =
              TlsRetentionAuthorityClient
                { observeTlsRetentionCurrent = do
                    recordEvent events "observe-authority"
                    Right <$> readIORef authorityState
                , stageTlsRetentionCurrent = \_ _ _ -> error "successor recovery uses legacy staging"
                , stageTlsRetentionAfterUnrecoverableLegacy =
                    \approval evidence collision candidate envelope -> do
                      recordEvent events "stage-successor"
                      state <- readIORef authorityState
                      let decision =
                            decideTlsLegacyRecoveryStaging
                              approval
                              state
                              evidence
                              collision
                              candidate
                              envelope
                          next = applyTlsLegacyRecoveryStaging evidence decision state
                      case decision of
                        TlsLegacyRecoveryCollisionSuccessorStaged _ _ -> do
                          writeIORef authorityState next
                          pure (Right (TlsAuthorityStagingCommitted next))
                        TlsLegacyRecoveryStagingNoop _ ->
                          pure (Right (TlsAuthorityStagingAlreadyPending next))
                        refusal ->
                          pure
                            ( Left
                                (TlsRetentionAuthorityClientRemoteRefused (Text.pack (show refusal)))
                            )
                , promoteTlsRetentionCurrent = \approval evidence candidate -> do
                    recordEvent events "promote"
                    state <- readIORef authorityState
                    let decision = decideTlsPromotion approval evidence state candidate
                        next = applyTlsPromotion decision state
                    case decision of
                      TlsPromoted _ -> do
                        writeIORef authorityState next
                        pure (Right (TlsAuthorityPromotionCommitted next))
                      refusal ->
                        pure
                          ( Left
                              (TlsRetentionAuthorityClientRemoteRefused (Text.pack (show refusal)))
                          )
                }
            storeSuccessor candidate envelope
              | candidate == pendingCandidate && envelope == pendingEnvelope = do
                  recordEvent events "store-pending-collision"
                  pure (Left exactCollision)
              | candidate == successorCandidate && envelope == successorEnvelope = do
                  recordEvent events "store-successor"
                  pure (Right (receiptForFixture candidate envelope))
              | otherwise = error "unexpected successor-recovery store candidate"
            adapterClient =
              TlsRetentionClient
                { storeTlsRetention = storeSuccessor
                , restoreTlsRetention = \candidate -> do
                    recordEvent events "restore-adapter"
                    candidate `shouldBe` successorCandidate
                    pure
                      ( Right
                          ( TlsEnvelopePresent
                              successorEnvelope
                              (receiptForFixture successorCandidate successorEnvelope)
                          )
                      )
                , observeTlsRetentionVersion = \_ ->
                    error "successor recovery must not repeat legacy observation"
                , observeTlsRetentionAuthorityVersion = \version -> do
                    recordEvent events "observe-version-2"
                    version `shouldBe` RetentionVersion 2
                    pure (Right (TlsVersionEnvelopePresent occupiedEnvelope "occupied-etag"))
                }
            homeAgent =
              TlsTargetAgentClient
                { prepareTlsDekDestination = do
                    recordEvent events "prepare-home-successor"
                    pure (Right prepared)
                , retainSelectedPublicEdgeTls = \_ _ -> error "home does not retain"
                , wrapRetainedHomeTlsDek = \_ envelope -> do
                    recordEvent events "wrap-successor"
                    envelope `shouldBe` selectedDekEnvelope
                    pure (Right (mustRight (mkTlsWrappedDek "vault:v1:successor-home")))
                , rewrapRetainedHomeTlsDek = \_ _ -> do
                    recordEvent events "rewrap-occupied-auth-failed"
                    pure (Left TlsTargetAgentClientHomeRewrapCiphertextAuthenticationFailed)
                , restoreSelectedPublicEdgeTls = \_ _ _ _ -> error "home does not restore selected"
                , verifySelectedPublicEdgeTlsSource = \_ -> error "home does not verify selected"
                }
            selectedAgent =
              TlsTargetAgentClient
                { prepareTlsDekDestination = do
                    recordEvent events "prepare-selected-occupied"
                    pure (Right prepared)
                , retainSelectedPublicEdgeTls = \version _ -> do
                    recordEvent events "retain-successor-v3"
                    version `shouldBe` RetentionVersion 3
                    pure
                      ( Right
                          TlsTargetRetainReceipt
                            { tlsTargetRetainedVersion = version
                            , tlsTargetRetainedCertificate = certificate
                            , tlsTargetRetainedSource = source
                            , tlsTargetRetainedCertificateCiphertext = "successor-certificate"
                            , tlsTargetRetainedDekEnvelope = selectedDekEnvelope
                            }
                      )
                , wrapRetainedHomeTlsDek = \_ _ -> error "selected does not wrap"
                , rewrapRetainedHomeTlsDek = \_ _ -> error "selected does not rewrap"
                , restoreSelectedPublicEdgeTls = \_ _ _ _ ->
                    error "unopenable occupied version 2 must never be applied"
                , verifySelectedPublicEdgeTlsSource = \candidate -> do
                    recordEvent events "verify"
                    candidate `shouldBe` successorCandidate
                    pure
                      ( Right
                          TlsTargetVerifyReceipt
                            { tlsTargetVerifiedCertificate = certificate
                            , tlsTargetVerifiedSource = source
                            }
                      )
                }
            workflow =
              TlsRetentionWorkflow
                { tlsWorkflowAuthority = authorityClient
                , tlsWorkflowAdapter = adapterClient
                , tlsWorkflowRetainedHomeAgent = homeAgent
                , tlsWorkflowSelectedAgent = selectedAgent
                }
        retainPublicEdgeTlsWorkflow workflow KeyRotationNotApproved
          `shouldReturn` Right (TlsWorkflowRetained successorCandidate)
        readIORef authorityState `shouldReturn` TlsRetentionCurrent successorCandidate
        readIORef events
          `shouldReturn` [ "observe-authority"
                         , "store-pending-collision"
                         , "observe-version-2"
                         , "prepare-selected-occupied"
                         , "rewrap-occupied-auth-failed"
                         , "prepare-home-successor"
                         , "retain-successor-v3"
                         , "wrap-successor"
                         , "stage-successor"
                         , "store-successor"
                         , "restore-adapter"
                         , "verify"
                         , "promote"
                         ]
    it "refuses corrupt, unobservable, and missing-source legacy occupation before staging" $ do
      events <- newIORef ([] :: [String])
      protectedPrivate <- newIORef ByteString.empty
      let transit =
            TlsDekTransitBoundary
              { tlsDekTransitEncrypt = \bytes -> do
                  writeIORef protectedPrivate bytes
                  pure (Right "vault:v1:prepared")
              , tlsDekTransitDecrypt = \_ -> Right <$> readIORef protectedPrivate
              }
      prepared <- mustRight <$> prepareTlsDekExchange transit
      let legacyEnvelope = sampleEnvelope "legacy-certificate" "legacy-wrapped"
          authorityClient =
            TlsRetentionAuthorityClient
              { observeTlsRetentionCurrent = do
                  recordEvent events "observe-authority"
                  pure (Right TlsRetentionEmpty)
              , stageTlsRetentionCurrent = \_ _ _ -> do
                  recordEvent events "stage"
                  error "legacy refusal must precede Authority staging"
              , stageTlsRetentionAfterUnrecoverableLegacy = \_ _ _ _ _ ->
                  error "legacy refusal must precede Authority recovery staging"
              , promoteTlsRetentionCurrent = \_ _ _ ->
                  error "legacy refusal must precede Authority promotion"
              }
          adapterClient observation =
            TlsRetentionClient
              { observeTlsRetentionVersion = \_ -> do
                  recordEvent events "observe-version"
                  pure observation
              , observeTlsRetentionAuthorityVersion = \_ ->
                  error "legacy refusal must not observe an Authority collision"
              , storeTlsRetention = \_ _ ->
                  error "legacy refusal must precede Adapter storage"
              , restoreTlsRetention = \_ ->
                  error "legacy refusal must precede Adapter confirmation"
              }
          homeAgent =
            TlsTargetAgentClient
              { prepareTlsDekDestination = do
                  recordEvent events "prepare-home"
                  pure (Right prepared)
              , retainSelectedPublicEdgeTls = \_ _ -> error "unused home retain"
              , wrapRetainedHomeTlsDek = \_ _ -> error "unused home wrap"
              , rewrapRetainedHomeTlsDek = \_ _ -> error "unused home rewrap"
              , restoreSelectedPublicEdgeTls = \_ _ _ _ -> error "unused home restore"
              , verifySelectedPublicEdgeTlsSource = \_ -> error "unused home verify"
              }
          selectedAgent =
            TlsTargetAgentClient
              { prepareTlsDekDestination = error "missing source precedes selected prepare"
              , retainSelectedPublicEdgeTls = \_ _ -> do
                  recordEvent events "retain"
                  pure (Left (classifyTlsTargetAgentHttpStatus 404 ""))
              , wrapRetainedHomeTlsDek = \_ _ -> error "unused selected wrap"
              , rewrapRetainedHomeTlsDek = \_ _ -> error "unused selected rewrap"
              , restoreSelectedPublicEdgeTls = \_ _ _ _ -> error "unused selected restore"
              , verifySelectedPublicEdgeTlsSource = \_ -> error "unused selected verify"
              }
          workflow observation =
            TlsRetentionWorkflow
              { tlsWorkflowAuthority = authorityClient
              , tlsWorkflowAdapter = adapterClient observation
              , tlsWorkflowRetainedHomeAgent = homeAgent
              , tlsWorkflowSelectedAgent = selectedAgent
              }

      retainPublicEdgeTlsWorkflow
        (workflow (Right TlsVersionEnvelopeCorrupt))
        KeyRotationNotApproved
        `shouldReturn` Left TlsWorkflowLegacyEnvelopeCorrupt
      readIORef events
        `shouldReturn` ["observe-authority", "observe-version"]

      writeIORef events []
      retainPublicEdgeTlsWorkflow
        (workflow (Left TlsRetentionClientObservationVersionInvalid))
        KeyRotationNotApproved
        `shouldReturn` Left
          (TlsWorkflowAdapterFailed TlsRetentionClientObservationVersionInvalid)
      readIORef events
        `shouldReturn` ["observe-authority", "observe-version"]

      writeIORef events []
      retainPublicEdgeTlsWorkflow
        (workflow (Right (TlsVersionEnvelopePresent legacyEnvelope "legacy-etag")))
        KeyRotationNotApproved
        `shouldReturn` Left TlsWorkflowLegacySourceMissing
      readIORef events
        `shouldReturn` [ "observe-authority"
                       , "observe-version"
                       , "prepare-home"
                       , "retain"
                       ]
    it
      "TLS-RETENTION-AUTHORITY-SOURCE-READBACK-MISMATCH-2026-09-07 projects only exact legacy source absence to delete's existing Certificate classifier"
      $ do
        ControlPlaneRuntime.classifyTlsRetentionWorkflowFailure TlsWorkflowLegacySourceMissing
          `shouldBe` TlsRetentionWorkflowAuthorityLegacySourceMissing
        ControlPlaneRuntime.classifyTlsRetentionWorkflowFailure TlsWorkflowSourceReadBackMismatch
          `shouldBe` TlsRetentionWorkflowAuthoritySourceReadBackMismatch
        ControlPlaneRuntime.classifyTlsRetentionWorkflowFailure TlsWorkflowLegacyAdoptionNotIdempotent
          `shouldBe` TlsRetentionWorkflowAuthoritySourceReadBackMismatch
        classifyPublicEdgeTlsRetainResponse
          ( TlsRetentionWorkflowAuthorityRefused
              TlsRetentionWorkflowAuthorityLegacySourceMissing
          )
          `shouldBe` Right PublicEdgeTlsRetainLegacySourceMissing
        classifyPublicEdgeTlsRetainResponse
          ( TlsRetentionWorkflowAuthorityRefused
              TlsRetentionWorkflowAuthoritySourceReadBackMismatch
          )
          `shouldSatisfy` isLeft
        classifyPublicEdgeTlsRetainResponse
          ( TlsRetentionWorkflowAuthorityRefused
              TlsRetentionWorkflowAuthoritySelectedAgentUnavailable
          )
          `shouldSatisfy` isLeft
        classifyPublicEdgePreserve Nothing (Just (object []))
          `shouldBe` PreserveDeferredIssuanceInFlight
        classifyPublicEdgePreserve Nothing Nothing
          `shouldBe` PreserveNothingToRetain
    it "rejects same-version substitution with different envelope bytes" $ do
      (transport, _, _) <- freshMemoryTransport False
      let repository = tlsRetentionRepositoryWithTransport transport
          firstEnvelope = sampleEnvelope "certificate-one" "wrapped-one"
          secondEnvelope = sampleEnvelope "certificate-two" "wrapped-two"
      first <- storeTlsEnvelope repository (referenceFor 3 firstEnvelope) firstEnvelope
      first `shouldSatisfy` isRight
      substituted <- storeTlsEnvelope repository (referenceFor 3 secondEnvelope) secondEnvelope
      substituted
        `shouldBe` Left
          ( TlsStoreRepositoryConfirmationFailed
              TlsStorePutConflict
              TlsStoreConfirmationBytesMismatch
          )
    it
      "TLS-LEGACY-RECOVERY-V3-IMMUTABLE-COLLISION-2026-09-08 keeps legacy observation disjoint from the Authority-owned immutable lane"
      $ do
        adapterObjectNameText (mustRight (tlsRetentionEnvelopeObjectName 3))
          `shouldBe` "authority-v1/versions/3.envelope"
        adapterObjectNameText (mustRight (tlsLegacyRetentionEnvelopeObjectName 3))
          `shouldBe` "versions/3.envelope"
    it "distinguishes missing and corrupt immutable versions" $ do
      (transport, objectsRef, _) <- freshMemoryTransport False
      let repository = tlsRetentionRepositoryWithTransport transport
          envelope = sampleEnvelope "expected-certificate" "expected-wrapped"
          reference = referenceFor 4 envelope
      restoreTlsEnvelope repository reference `shouldReturn` Right TlsEnvelopeMissing
      let objectName = mustRight (tlsRetentionEnvelopeObjectName 4)
          version = mustRight (mkAdapterObjectVersion "corrupt-etag")
      writeIORef
        objectsRef
        (Map.singleton (adapterObjectNameText objectName) (version, "not-canonical-cbor"))
      restored <- restoreTlsEnvelope repository reference
      case restored of
        Right (TlsEnvelopeCorrupt detail) ->
          detail `shouldContainText` "encoded envelope is invalid"
        other -> expectationFailure ("expected corrupt envelope, got " <> show other)
    it "observes only the exact immutable version for bounded legacy recovery" $ do
      (transport, objectsRef, _) <- freshMemoryTransport False
      let repository = tlsRetentionRepositoryWithTransport transport
          envelope = sampleEnvelope "legacy-certificate" "legacy-wrapped"
          reference = referenceFor 12 envelope
          request = TlsObserveVersionPayload (RetentionVersion 12)
          authorityRequest = tlsObserveAuthorityVersionPayload (RetentionVersion 12)
      missing <-
        serveTlsObserveVersionRequest
          4096
          repository
          (encodeControlPlaneRequest request)
      missing
        `shouldBe` TlsObserveVersionObserved TlsVersionEnvelopeMissing
      tlsObserveVersionHttpStatus missing `shouldBe` ReplyNotFound
      _ <- storeTlsEnvelope repository reference envelope
      authorityPresent <-
        serveTlsObserveVersionRequest
          4096
          repository
          (encodeControlPlaneRequest authorityRequest)
      case authorityPresent of
        TlsObserveVersionObserved (TlsVersionEnvelopePresent observed _) ->
          observed `shouldBe` envelope
        other -> expectationFailure ("expected Authority-lane envelope, got " <> show other)
      authorityObjects <- readIORef objectsRef
      let authorityObjectName = mustRight (tlsRetentionEnvelopeObjectName 12)
          legacyObjectName = mustRight (tlsLegacyRetentionEnvelopeObjectName 12)
      case Map.lookup (adapterObjectNameText authorityObjectName) authorityObjects of
        Nothing -> expectationFailure "Authority-lane store did not create its exact object"
        Just authorityObject ->
          writeIORef
            objectsRef
            (Map.singleton (adapterObjectNameText legacyObjectName) authorityObject)
      present <-
        serveTlsObserveVersionRequest
          4096
          repository
          (encodeControlPlaneRequest request)
      case present of
        TlsObserveVersionObserved (TlsVersionEnvelopePresent observed objectVersion) -> do
          observed `shouldBe` envelope
          objectVersion `shouldSatisfy` (not . Text.null)
        other -> expectationFailure ("expected exact-version envelope, got " <> show other)
      tlsObserveVersionHttpStatus present `shouldBe` ReplyOk
      let objectName = mustRight (tlsLegacyRetentionEnvelopeObjectName 12)
          objectVersion = mustRight (mkAdapterObjectVersion "corrupt-etag")
      writeIORef
        objectsRef
        (Map.singleton (adapterObjectNameText objectName) (objectVersion, "not-cbor"))
      corrupt <-
        serveTlsObserveVersionRequest
          4096
          repository
          (encodeControlPlaneRequest request)
      corrupt
        `shouldBe` TlsObserveVersionObserved TlsVersionEnvelopeCorrupt
      tlsObserveVersionHttpStatus corrupt `shouldBe` ReplyInternalError
    it "refuses malformed, oversized, invalid, and digest-mismatched requests" $ do
      (transport, _, _) <- freshMemoryTransport False
      let repository = tlsRetentionRepositoryWithTransport transport
          envelope = sampleEnvelope "certificate" "wrapped-dek"
          reference = referenceFor 1 envelope
          request = TlsStorePayload reference envelope
      serveTlsStoreRequest 4096 repository "not-cbor"
        `shouldReturn` TlsStoreBadRequest ControlPlaneRequestInvalid
      serveTlsStoreRequest 2 repository (encodeControlPlaneRequest request)
        `shouldReturn` TlsStoreBadRequest ControlPlaneRequestTooLarge
      mkTlsSealedEnvelope ByteString.empty "wrapped" `shouldSatisfy` isLeft
      mkTlsSealedEnvelope
        (ByteString.replicate (tlsMaximumCertificateCiphertextBytes + 1) 0)
        "wrapped"
        `shouldSatisfy` isLeft
      let wrongReference = reference {retainedCiphertextDigest = Text.replicate 64 "0"}
      serveTlsStoreRequest
        4096
        repository
        (encodeControlPlaneRequest (TlsStorePayload wrongReference envelope))
        `shouldReturn` TlsStoreDigestMismatch
    it "returns the exact sealed envelope from the restore response codec" $ do
      (transport, _, _) <- freshMemoryTransport False
      let repository = tlsRetentionRepositoryWithTransport transport
          envelope = sampleEnvelope "certificate-readback" "wrapped-readback"
          reference = referenceFor 9 envelope
      _ <- storeTlsEnvelope repository reference envelope
      result <-
        serveTlsRestoreRequest
          4096
          repository
          (encodeControlPlaneRequest (TlsRestorePayload reference))
      tlsRestoreHttpStatus result `shouldBe` ReplyOk
      decodeControlPlaneResponse
        (1024 * 1024)
        (LazyByteString.fromStrict (tlsRestoreResponseBody result))
        `shouldBe` Right (TlsEnvelopePresent envelope (receiptFromResult result))
    it "redacts certificate ciphertext and wrapped DEK from Show" $ do
      let envelope = sampleEnvelope "do-not-log-certificate" "do-not-log-dek"
      show envelope `shouldNotContain` "do-not-log-certificate"
      show envelope `shouldNotContain` "do-not-log-dek"
    it "admits the exact retained Authority workload to the isolated adapter" $ do
      repoRoot <- getCurrentDirectory
      policy <-
        readFile
          (repoRoot </> "charts" </> "tls-retention" </> "templates" </> "networkpolicy.yaml")
      policy `shouldContain` "kubernetes.io/metadata.name: lifecycle-authority"
      policy `shouldContain` "app.kubernetes.io/name: prodbox-lifecycle-authority"
    it "dispatches only decoded closed Authority workflow requests" $ do
      observed <- newIORef []
      let request =
            TlsRetentionWorkflowAuthorityRetain
              "home-local"
              "%2A.example.com%2Ctest.example.com"
              KeyRotationNotApproved
          boundary =
            TlsRetentionWorkflowAuthorityBoundary $ \decoded -> do
              modifyIORef' observed (decoded :)
              pure TlsRetentionWorkflowAuthorityRetained
      refused <-
        serveTlsRetentionWorkflowAuthorityRequest
          tlsRetentionWorkflowAuthorityMaximumBytes
          boundary
          "not-canonical-cbor"
      refused `shouldBe` TlsRetentionWorkflowAuthorityRequestRefused
      readIORef observed `shouldReturn` []
      accepted <-
        serveTlsRetentionWorkflowAuthorityRequest
          tlsRetentionWorkflowAuthorityMaximumBytes
          boundary
          (encodeControlPlaneRequest request)
      accepted `shouldBe` TlsRetentionWorkflowAuthorityRetained
      readIORef observed `shouldReturn` [request]
    it "projects closed Authority workflow outcomes to exact HTTP statuses" $ do
      tlsRetentionWorkflowAuthorityResponseHttpStatus
        TlsRetentionWorkflowAuthorityNothingToRetain
        `shouldBe` ReplyOk
      tlsRetentionWorkflowAuthorityResponseHttpStatus
        TlsRetentionWorkflowAuthorityIssuancePermitted
        `shouldBe` ReplyOk
      tlsRetentionWorkflowAuthorityResponseHttpStatus
        ( TlsRetentionWorkflowAuthorityRefused
            TlsRetentionWorkflowAuthoritySelectedAgentUnavailable
        )
        `shouldBe` ReplyServiceUnavailable
      tlsRetentionWorkflowAuthorityResponseHttpStatus
        TlsRetentionWorkflowAuthorityRequestRefused
        `shouldBe` ReplyBadRequest
    it "classifies only the exact Target replay-capacity response without retaining its body" $ do
      let (status, body) =
            authenticatedRolePlainResponse AuthenticatedRoleReplayCapacityExhausted
          exact = classifyTlsTargetAgentHttpStatus (replyStatusCode status) body
          arbitrary = classifyTlsTargetAgentHttpStatus (replyStatusCode status) "private-response"
      ControlPlaneRuntime.classifyTlsRetentionWorkflowFailure
        (TlsWorkflowHomeAgentFailed exact)
        `shouldBe` TlsRetentionWorkflowAuthorityHomeAgentReplayCapacityExhausted
      ControlPlaneRuntime.classifyTlsRetentionWorkflowFailure
        (TlsWorkflowSelectedAgentFailed exact)
        `shouldBe` TlsRetentionWorkflowAuthoritySelectedAgentReplayCapacityExhausted
      ControlPlaneRuntime.classifyTlsRetentionWorkflowFailure
        (TlsWorkflowHomeAgentFailed arbitrary)
        `shouldBe` TlsRetentionWorkflowAuthorityHomeAgentUnavailable
      show exact `shouldNotContain` "private-response"
    it
      "TLS-SELECTED-AGENT-ENDPOINT-RESPONSE-COLLAPSED-TO-HTTP-OTHER-2026-09-06 classifies every exact Target TLS plaintext response without retaining its body"
      $ do
        let tokens =
              renderTlsTargetAgentPlainResponseCause
                <$> allTlsTargetAgentPlainResponseCauses
        length tokens `shouldBe` length (nub tokens)
        mapM_
          ( \cause -> do
              let (endpointStatus, endpointBody) = tlsTargetAgentPlainResponse cause
                  classified =
                    classifyTlsTargetAgentHttpStatus
                      (replyStatusCode endpointStatus)
                      endpointBody
              renderTlsTargetAgentClientCause classified
                `shouldBe` case cause of
                  TlsHomeRewrapCiphertextAuthenticationFailedResponse ->
                    "home-rewrap-ciphertext-authentication-failed"
                  _ -> "http-status/target/" <> renderTlsTargetAgentPlainResponseCause cause
              show classified `shouldNotContain` ByteString8.unpack endpointBody
          )
          allTlsTargetAgentPlainResponseCauses
        let arbitraryA = classifyTlsTargetAgentHttpStatus 503 "private-response-a"
            arbitraryB = classifyTlsTargetAgentHttpStatus 503 "different-private-response-b"
        renderTlsTargetAgentClientCause arbitraryA `shouldBe` "http-status/other"
        arbitraryA `shouldBe` arbitraryB
        show arbitraryA `shouldNotContain` "private-response-a"
    it "classifies every exact Adapter plaintext response without retaining its body" $ do
      let tokens = renderTlsRetentionPlainResponseCause <$> allTlsRetentionPlainResponseCauses
      length tokens `shouldBe` length (nub tokens)
      mapM_
        ( \cause -> do
            let (endpointStatus, endpointBody) = tlsRetentionPlainResponse cause
                classified =
                  classifyTlsRetentionHttpStatus
                    (replyStatusCode endpointStatus)
                    endpointBody
            renderTlsRetentionClientCause classified
              `shouldBe` ("http-status/" <> renderTlsRetentionPlainResponseCause cause)
            show classified `shouldNotContain` ByteString8.unpack endpointBody
        )
        allTlsRetentionPlainResponseCauses
      let (status, body) =
            authenticatedRolePlainResponse AuthenticatedRoleReplayCapacityExhausted
          exact = classifyTlsRetentionHttpStatus (replyStatusCode status) body
          arbitraryA =
            classifyTlsRetentionHttpStatus
              (replyStatusCode status)
              "private-response-a"
          arbitraryB =
            classifyTlsRetentionHttpStatus
              (replyStatusCode status)
              "different-private-response-b"
      renderTlsRetentionClientCause exact
        `shouldBe` "http-status/replay-capacity-exhausted"
      renderTlsRetentionClientCause arbitraryA `shouldBe` "http-status/other"
      renderTlsRetentionClientCause arbitraryB `shouldBe` "http-status/other"
      arbitraryA `shouldBe` arbitraryB
      show arbitraryA `shouldNotContain` "private-response-a"
    it "classifies an exact nested Authority replay response without retaining its body" $ do
      let (status, body) =
            authenticatedRolePlainResponse AuthenticatedRoleReplayCapacityExhausted
          known =
            AuthenticatedRolePlainResponseKnown
              AuthenticatedRoleReplayCapacityExhausted
          exact =
            classifyTargetIntentAuthorityResponseDecodeFailure
              (replyStatusCode status)
              body
              ControlPlaneRequestInvalid
          arbitrary =
            classifyTargetIntentAuthorityResponseDecodeFailure
              (replyStatusCode status)
              "private-response"
              ControlPlaneRequestInvalid
      exact
        `shouldBe` TargetIntentAuthorityAuthenticatedResponseInvalid
          known
          ControlPlaneRequestInvalid
      classifyTargetIntentIssueError exact
        `shouldBe` AwsAdminTargetIntentAuthenticatedResponseInvalid known
      arbitrary
        `shouldBe` TargetIntentAuthorityResponseInvalid ControlPlaneRequestInvalid
      show exact `shouldNotContain` "private-response"
    it "requires both least-privilege halves of the Target-intent NetworkPolicy route" $ do
      repoRoot <- getCurrentDirectory
      targetPolicy <-
        Text.pack
          <$> readFile
            (repoRoot </> "charts" </> "target-secret-agent" </> "templates" </> "networkpolicy.yaml")
      authorityPolicy <-
        Text.pack
          <$> readFile
            (repoRoot </> "charts" </> "lifecycle-authority" </> "templates" </> "networkpolicy.yaml")
      targetIntentNetworkPolicyRouteIsClosed targetPolicy authorityPolicy `shouldBe` True
      targetIntentNetworkPolicyRouteIsClosed
        (Text.replace targetIntentAuthorityEgressArm "" targetPolicy)
        authorityPolicy
        `shouldBe` False
      targetIntentNetworkPolicyRouteIsClosed
        targetPolicy
        (Text.replace targetIntentAuthorityIngressArm "" authorityPolicy)
        `shouldBe` False

targetIntentNetworkPolicyRouteIsClosed :: Text -> Text -> Bool
targetIntentNetworkPolicyRouteIsClosed targetPolicy authorityPolicy =
  targetIntentAuthorityEgressArm `Text.isInfixOf` targetPolicy
    && targetIntentAuthorityIngressArm `Text.isInfixOf` authorityPolicy

targetIntentAuthorityEgressArm :: Text
targetIntentAuthorityEgressArm =
  Text.unlines
    [ "    - to:"
    , "        - namespaceSelector:"
    , "            matchLabels:"
    , "              kubernetes.io/metadata.name: lifecycle-authority"
    , "          podSelector:"
    , "            matchLabels:"
    , "              app.kubernetes.io/name: prodbox-lifecycle-authority"
    , "      ports:"
    , "        - protocol: TCP"
    , "          port: {{ .Values.ports.controlPlane }}"
    ]

targetIntentAuthorityIngressArm :: Text
targetIntentAuthorityIngressArm =
  Text.unlines
    [ "    - from:"
    , "        - namespaceSelector:"
    , "            matchLabels:"
    , "              kubernetes.io/metadata.name: target-secret-agent"
    , "          podSelector:"
    , "            matchLabels:"
    , "              app.kubernetes.io/name: prodbox-target-secret-agent"
    , "      ports:"
    , "        - protocol: TCP"
    , "          port: lifecycle"
    ]

sampleEnvelope :: ByteString -> ByteString -> TlsSealedEnvelope
sampleEnvelope certificate wrapped = mustRight (mkTlsSealedEnvelope certificate wrapped)

samplePublicEdgeSecret :: Text -> Text -> Text -> TlsPublicEdgeSecret
samplePublicEdgeSecret uid resourceVersion certificate =
  mustRight
    ( mkTlsPublicEdgeSecret
        (SourceSecretRef uid resourceVersion)
        (CertIdentity certificate "spki-digest" 2000000000)
        "kubernetes.io/tls"
        ( Map.fromList
            [ ("tls.crt", encodeBase64Text certificate)
            , ("tls.key", encodeBase64Text "private-key")
            ]
        )
        (Map.singleton "cert-manager.io/certificate-name" "public-edge-tls")
    )

encodeBase64Text :: Text -> Text
encodeBase64Text = TextEncoding.decodeUtf8 . Base64.encode . TextEncoding.encodeUtf8

referenceFor :: Integer -> TlsSealedEnvelope -> RetainedTlsRef
referenceFor version envelope =
  RetainedTlsRef
    { retainedVersion = RetentionVersion (fromInteger version)
    , retainedCert = CertIdentity "serial" "spki-digest" 2000000000
    , retainedCiphertextDigest = tlsSealedEnvelopeDigest envelope
    , retainedSourceSecret = SourceSecretRef "secret-uid" "resource-version"
    }

receiptFromResult :: TlsRestoreResult -> TlsRetentionReceipt
receiptFromResult result = case result of
  TlsRestoreObserved (TlsEnvelopePresent _ receipt) -> receipt
  _ -> error "expected present TLS envelope"

receiptForFixture :: RetainedTlsRef -> TlsSealedEnvelope -> TlsRetentionReceipt
receiptForFixture reference envelope =
  TlsRetentionReceipt
    { tlsRetentionReceiptReference = reference
    , tlsRetentionReceiptEnvelopeDigest = tlsSealedEnvelopeDigest envelope
    , tlsRetentionReceiptObjectVersion = "fixture-etag"
    }

pendingState :: TlsRetentionState -> Bool
pendingState = maybe False (const True) . pendingTlsRetention

recordEvent :: IORef [String] -> String -> IO ()
recordEvent events event = modifyIORef' events (<> [event])

freshMemoryTransport
  :: Bool
  -> IO
       ( DedicatedAdapterTransport 'TlsRetentionAdapter IO
       , IORef (Map Text (AdapterObjectVersion, ByteString))
       , IORef Int
       )
freshMemoryTransport loseFirstResponse = do
  objectsRef <- newIORef Map.empty
  loseResponseRef <- newIORef loseFirstResponse
  putCount <- newIORef 0
  let transport =
        DedicatedAdapterTransport
          { observeAdapterObject = \objectName -> do
              objects <- readIORef objectsRef
              pure $ case Map.lookup (adapterObjectNameText objectName) objects of
                Nothing -> Right AdapterObjectMissing
                Just (version, bytes) -> Right (AdapterObjectObserved version bytes)
          , putAdapterObjectIfAbsent = \objectName bytes -> do
              modifyIORef' putCount (+ 1)
              let key = adapterObjectNameText objectName
              objects <- readIORef objectsRef
              case Map.lookup key objects of
                Just _ -> pure (Right AdapterPutConflict)
                Nothing -> do
                  let version =
                        mustRight
                          (mkAdapterObjectVersion ("etag-" <> Text.pack (show (ByteString.length bytes))))
                  writeIORef objectsRef (Map.insert key (version, bytes) objects)
                  lose <- atomicModifyIORef' loseResponseRef (False,)
                  pure $ if lose then Left "PUT response lost" else Right AdapterPutApplied
          , adapterObjectStoreReadiness = pure DedicatedAdapterReady
          }
  pure (transport, objectsRef, putCount)

isLeft :: Either left right -> Bool
isLeft value = case value of
  Left _ -> True
  Right _ -> False

isRight :: Either left right -> Bool
isRight value = case value of
  Left _ -> False
  Right _ -> True

shouldContainText :: Text -> Text -> Expectation
shouldContainText actual expected =
  Text.unpack actual `shouldContain` Text.unpack expected

mustRight :: (Show err) => Either err value -> value
mustRight = either (error . show) id
