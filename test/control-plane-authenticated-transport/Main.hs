{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
import Prodbox.ControlPlane.AuthenticatedRuntime
import Prodbox.ControlPlane.AuthenticatedTransport
import Prodbox.ControlPlane.AuthenticationRegistry
  ( controlPlaneSigningKeyName
  , controlPlaneSigningKeyRefFor
  , trustedCallersForRoute
  )
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  , AuthorityOperationSubmitPayload (..)
  , AuthorityOperationSubmitResponse (..)
  , authorityOperationResponseMaximumBytes
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor
    ( LifecycleOperationSubmitRoute
    , ProviderWorkApplyRoute
    )
  , controlPlaneClientWithTransport
  , mkLifecycleAuthorityEndpoint
  , mkProviderWorkerEndpoint
  )
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneRequest
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.ConfigEndpoint
  ( ConfigAuthorityRepository (..)
  , ConfigObservation (ConfigObservationMissing)
  , ConfigProposeCasResponse (ConfigProposalUnavailable)
  )
import Prodbox.ControlPlane.Coordinate
  ( AuthorityScope
  , mkAuthorityScope
  )
import Prodbox.ControlPlane.ProjectionImportEndpoint
  ( unavailableProjectionImportHandler
  )
import Prodbox.ControlPlane.PulumiCheckpointEndpoint
  ( PulumiCheckpointHandler
  , PulumiCheckpointObservation (PulumiCheckpointMissing)
  , PulumiCheckpointPublicationResult (PulumiCheckpointPublicationUnavailable)
  , PulumiCheckpointRepository (..)
  , PulumiCheckpointRetirementResult (PulumiCheckpointRetirementUnavailable)
  , mkPulumiCheckpointHandler
  )
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.RequestReplay
import Prodbox.ControlPlane.RetainedSesLeaseEndpoint
  ( resolvingRetainedSesLeaseHandler
  )
import Prodbox.ControlPlane.RoleInterpreters
  ( lifecycleAuthorityAdmissionAuthenticatedHandler
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (..)
  , controlPlaneRoutePath
  , routesForRole
  )
import Prodbox.ControlPlane.Server
  ( RoleInterpreter (..)
  )
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , AuthorityAdmissionCommand (ApplyAuthorityGenesis)
  , initialCleanInstallAuthorityWithRegisteredClients
  , stepAuthorityAdmission
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityGenesisCommand (..)
  , BackupReceipt (BackupReceipt)
  , GenesisPlan (GenesisPlan)
  , TargetAgentGenerationReceipt (TargetAgentGenerationReceipt)
  , authorityEpochGenesis
  )
import Prodbox.Lifecycle.Authority.Submission
  ( ClientId (ClientId)
  , ClientSequence (ClientSequence)
  , OperationId (OperationId)
  , RequestDigest (RequestDigest)
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , authorityDurationFromMicros
  , authorityTimeFromMicros
  )
import Prodbox.Runtime.Role
  ( RuntimeRole (..)
  )
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit
  ( assertFailure
  , testCase
  , (@?=)
  )

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "Sprint 4.50 authenticated transport and retained replay"
    [ replayPureTests
    , replayCodecTests
    , durableReplayTests
    , authenticatedTransportTests
    , authenticatedRoleInterpreterTests
    , authenticatedRuntimeTests
    ]

replayPureTests :: TestTree
replayPureTests =
  testGroup
    "pure bounded replay authority"
    [ testCase "validates limits, attempts, response, and CAS retry bounds" $ do
        mkRequestReplayLimits 0 64 skew
          @?= Left RequestReplayCapacityMustBePositive
        mkRequestReplayLimits 65537 64 skew
          @?= Left (RequestReplayCapacityExceedsHardMaximum 65537 65536)
        mkRequestReplayLimits 1 0 skew
          @?= Left RequestReplayResponseMaximumMustBePositive
        mkRequestReplayLimits 1 (100 * 1024 * 1024 + 1) skew
          @?= Left
            ( RequestReplayResponseMaximumExceedsHardMaximum
                (100 * 1024 * 1024 + 1)
                (100 * 1024 * 1024)
            )
        mkReplayAttemptId (ByteString.replicate 15 0)
          @?= Left (ReplayAttemptIdTooShort 15 16)
        mkReplayAttemptId (ByteString.replicate 65 0)
          @?= Left (ReplayAttemptIdTooLong 65 64)
        mkReplayCasAttempts 0 @?= Left ReplayCasAttemptsMustBePositive
        mkReplayCasAttempts 101
          @?= Left (ReplayCasAttemptsExceedHardMaximum 101 100)
        mkAuthenticatedTransportBounds (100 * 1024 * 1024 + 1) 256 65000
          @?= Left
            ( AuthenticatedFrameMaximumExceedsHardMaximum
                (100 * 1024 * 1024 + 1)
                (100 * 1024 * 1024)
            )
        mkReplayResponse replayLimits 99 "body"
          @?= Left (ReplayResponseStatusInvalid 99)
        mkReplayResponse replayLimits 200 (ByteString.replicate 65 0)
          @?= Left (ReplayResponseBodyTooLarge 65 64)
    , testCase "reserves before effect and classifies owner versus concurrent duplicate" $ do
        let fresh = reserveVerifiedRequest now attemptA verifiedRequest emptyReplay
            projection = replayReservationProjection fresh
        replayReservationDecision fresh @?= ReplayReservationFresh
        requestReplayEntryCount projection @?= 1
        replayReservationDecision
          (reserveVerifiedRequest now attemptA verifiedRequest projection)
          @?= ReplayReservationOwned
        replayReservationDecision
          (reserveVerifiedRequest now attemptB verifiedRequest projection)
          @?= ReplayReservationDuplicateInFlight
    , testCase "refuses digest conflict for one exact replay key" $ do
        let projection =
              replayReservationProjection
                (reserveVerifiedRequest now attemptA verifiedRequest emptyReplay)
        replayReservationDecision
          (reserveVerifiedRequest now attemptB verifiedDifferentBody projection)
          @?= ReplayReservationDigestConflict
    , testCase "keys identical nonces independently for service, CLI, and harness principals" $ do
        let principalLimits = mustRight (mkRequestReplayLimits 3 64 skew)
            empty = initialRequestReplayProjection principalLimits
            serviceRequest =
              verifiedForPrincipal
                (CallerService LifecycleAuthorityRuntime)
                nonceA
                body
            cliRequest = verifiedForPrincipal CallerOperatorCli nonceA body
            harnessRequest = verifiedForPrincipal CallerTestHarness nonceA body
            serviceReserved = reserveVerifiedRequest now attemptA serviceRequest empty
            cliReserved =
              reserveVerifiedRequest
                now
                attemptA
                cliRequest
                (replayReservationProjection serviceReserved)
            harnessReserved =
              reserveVerifiedRequest
                now
                attemptA
                harnessRequest
                (replayReservationProjection cliReserved)
        replayReservationDecision serviceReserved @?= ReplayReservationFresh
        replayReservationDecision cliReserved @?= ReplayReservationFresh
        replayReservationDecision harnessReserved @?= ReplayReservationFresh
        requestReplayEntryCount (replayReservationProjection harnessReserved) @?= 3
    , testCase "records one response and recovers exact completed duplicates" $ do
        let reserved =
              replayReservationProjection
                (reserveVerifiedRequest now attemptA verifiedRequest emptyReplay)
            wrongOwner =
              completeVerifiedRequest attemptB verifiedRequest response reserved
            completed =
              completeVerifiedRequest attemptA verifiedRequest response reserved
            projection = replayCompletionProjection completed
        replayCompletionDecision wrongOwner @?= ReplayCompletionOwnerMismatch
        replayCompletionDecision completed @?= ReplayCompletionRecorded response
        replayCompletionDecision
          (completeVerifiedRequest attemptA verifiedRequest response projection)
          @?= ReplayCompletionDuplicate response
        replayCompletionDecision
          (completeVerifiedRequest attemptA verifiedRequest otherResponse projection)
          @?= ReplayCompletionResponseConflict
        replayReservationDecision
          (reserveVerifiedRequest now attemptB verifiedRequest projection)
          @?= ReplayReservationDuplicateCompleted response
    , testCase "fails closed at capacity until deadline-plus-skew compaction" $ do
        let reserved =
              replayReservationProjection
                (reserveVerifiedRequest now attemptA verifiedRequest emptyReplay)
        replayReservationDecision
          (reserveVerifiedRequest now attemptB verifiedOtherNonce reserved)
          @?= ReplayReservationCapacityExhausted
        let atDeadline = compactRequestReplayProjection deadline reserved
        requestReplayEntryCount atDeadline @?= 1
        replayReservationDecision
          (reserveVerifiedRequest deadline attemptB verifiedRequest atDeadline)
          @?= ReplayReservationDuplicateTombstoned
        let beforeRetention = compactRequestReplayProjection (authorityTimeFromMicros 2099) atDeadline
            atRetention = compactRequestReplayProjection (authorityTimeFromMicros 2100) atDeadline
        requestReplayEntryCount beforeRetention @?= 1
        requestReplayEntryCount atRetention @?= 0
    ]

replayCodecTests :: TestTree
replayCodecTests =
  testGroup
    "bounded canonical retained codec"
    [ testCase "round-trips an exact non-empty projection" $ do
        let encoded = mustRight (encodeRequestReplayProjection 65536 replayLimits completedReplay)
        decodeRequestReplayProjection 65536 replayLimits encoded
          @?= Right completedReplay
    , testCase "rejects oversize, malformed, noncanonical, and config drift" $ do
        let encoded = mustRight (encodeRequestReplayProjection 65536 replayLimits completedReplay)
            nonCanonical = makeReplayVersionNonCanonical encoded
            otherLimits = mustRight (mkRequestReplayLimits 2 64 skew)
        encodeRequestReplayProjection 1 replayLimits completedReplay
          @?= Left (RequestReplayEnvelopeTooLarge (ByteString.length encoded) 1)
        decodeRequestReplayProjection 65536 replayLimits "not-cbor"
          @?= Left RequestReplayEnvelopeInvalid
        decodeRequestReplayProjection 65536 replayLimits nonCanonical
          @?= Left RequestReplayEnvelopeNonCanonical
        decodeRequestReplayProjection 65536 otherLimits encoded
          @?= Left RequestReplayLimitsMismatch
    ]

durableReplayTests :: TestTree
durableReplayTests =
  testGroup
    "exact-revision replay interpreter"
    [ testCase "runs the effect only after reserve readback and recovers duplicate response" $ do
        state <- newReplayState emptyReplay
        effects <- newIORef (0 :: Int)
        first <-
          runReplayProtectedRequest
            casAttempts
            (fakeReplayRepository state RequestReplayCasApplied)
            now
            attemptA
            verifiedRequest
            (modifyIORef' effects (+ 1) >> pure (Right response :: Either Text ReplayResponse))
        second <-
          runReplayProtectedRequest
            casAttempts
            (fakeReplayRepository state RequestReplayCasApplied)
            now
            attemptB
            verifiedRequest
            (modifyIORef' effects (+ 1) >> pure (Right otherResponse :: Either Text ReplayResponse))
        first @?= ReplayProtectedExecuted response
        second @?= ReplayProtectedRecovered response
        readIORef effects >>= (@?= 1)
    , testCase "recovers applied-but-response-lost CAS by exact owner readback" $ do
        state <- newReplayState emptyReplay
        effects <- newIORef (0 :: Int)
        result <-
          runReplayProtectedRequest
            casAttempts
            (fakeReplayRepository state responseLostCas)
            now
            attemptA
            verifiedRequest
            (modifyIORef' effects (+ 1) >> pure (Right response :: Either Text ReplayResponse))
        result @?= ReplayProtectedExecuted response
        readIORef effects >>= (@?= 1)
    , testCase "an unobservable read and a concurrent in-flight owner never run the effect" $ do
        effects <- newIORef (0 :: Int)
        unavailable <-
          runReplayProtectedRequest
            casAttempts
            unobservableReplayRepository
            now
            attemptA
            verifiedRequest
            (modifyIORef' effects (+ 1) >> pure (Right response :: Either Text ReplayResponse))
        unavailable
          @?= ReplayProtectedUnavailable
            (RequestReplayRepositoryUnobservable "read unavailable")
        let reserved =
              replayReservationProjection
                (reserveVerifiedRequest now attemptA verifiedRequest emptyReplay)
        state <- newReplayState reserved
        inFlight <-
          runReplayProtectedRequest
            casAttempts
            (fakeReplayRepository state RequestReplayCasApplied)
            now
            attemptB
            verifiedRequest
            (modifyIORef' effects (+ 1) >> pure (Right response :: Either Text ReplayResponse))
        inFlight @?= ReplayProtectedInFlight
        readIORef effects >>= (@?= 0)
    ]

authenticatedTransportTests :: TestTree
authenticatedTransportTests =
  testGroup
    "authenticated client/server wrappers"
    [ testCase "authenticates service, operator CLI, and test-harness principals" $
        mapM_ verifyPrincipalIdentity principalSlotFixtures
    , testCase "signs through injected client providers and verifies before exposing inner bytes" $ do
        captured <- captureAuthenticatedFrame clientProviders body
        authenticated <-
          authenticateControlPlaneFrame
            transportBounds
            maximumLifetime
            serverProviders
            ProviderWorkerRuntime
            ProviderWorkApply
            captured
        case authenticated of
          Left err -> assertFailure (show err)
          Right request -> do
            authenticatedServerInnerBody request @?= body
            verifiedCallerSlotPrincipal (authenticatedServerCallerSlot request)
              @?= CallerService LifecycleAuthorityRuntime
            verifiedCallerSlotKeyGeneration (authenticatedServerCallerSlot request)
              @?= generation
    , testCase "independent deadline metadata substitution fails authentication" $ do
        captured <- captureAuthenticatedFrame clientProviders body
        let frame = decodeTestFrame captured
            metadata = decodeTestMetadata (testFrameMetadata frame)
            tamperedMetadata =
              LazyByteString.toStrict
                (serialise metadata {testMetadataDeadlineMicros = 2500})
            tampered =
              serialise frame {testFrameMetadata = tamperedMetadata}
        result <-
          authenticateControlPlaneFrame
            transportBounds
            maximumLifetime
            serverProviders
            ProviderWorkerRuntime
            ProviderWorkApply
            tampered
        case result of
          Left (AuthenticatedServerRequestAuthenticationFailed [_]) -> pure ()
          other -> assertFailure ("unexpected metadata-tamper result: " <> show other)
    , testCase
        "closed role-local trust registry refuses missing, foreign, duplicate, or over-capacity routes"
        $ do
          registryError
            (mkRouteTrustRegistry ProviderWorkerRuntime 1 (drop 1 trustEntries))
            @?= RouteTrustRouteMissing ProviderWorkApply
          registryError
            ( mkRouteTrustRegistry
                ProviderWorkerRuntime
                1
                (trustEntries <> [(LifecycleAuthorityControl, trusted)])
            )
            @?= RouteTrustRouteNotOwned ProviderWorkerRuntime LifecycleAuthorityControl
          registryError
            ( mkRouteTrustRegistry
                ProviderWorkerRuntime
                1
                (trustEntries <> [(ProviderWorkApply, trusted)])
            )
            @?= RouteTrustDuplicateIdentity
              ProviderWorkApply
              (CallerService LifecycleAuthorityRuntime)
              1
          registryError (mkRouteTrustRegistry ProviderWorkerRuntime 0 trustEntries)
            @?= RouteTrustMaximumMustBePositive
    , testCase "provider failure and wrong local role fail before any inner handler" $ do
        captured <- captureAuthenticatedFrame clientProviders body
        let unavailableProviders =
              serverProviders
                { provideAuthenticatedServerEpoch =
                    pure (Left "epoch unavailable")
                }
        unavailable <-
          authenticateControlPlaneFrame
            transportBounds
            maximumLifetime
            unavailableProviders
            ProviderWorkerRuntime
            ProviderWorkApply
            captured
        unavailable @?= Left (AuthenticatedServerEpochUnavailable "epoch unavailable")
        wrongRole <-
          authenticateControlPlaneFrame
            transportBounds
            maximumLifetime
            serverProviders
            AuthorityBackupRuntime
            ProviderWorkApply
            captured
        wrongRole
          @?= Left
            ( AuthenticatedServerRouteRoleMismatch
                ProviderWorkApply
                AuthorityBackupRuntime
                ProviderWorkerRuntime
            )
    , testCase "full server seam authenticates, executes once, then recovers from replay" $ do
        captured <- captureAuthenticatedFrame clientProviders body
        state <- newReplayState emptyReplay
        effects <- newIORef (0 :: Int)
        let serve attempt =
              serveAuthenticatedControlPlaneFrame
                transportBounds
                maximumLifetime
                serverProviders
                ProviderWorkerRuntime
                ProviderWorkApply
                casAttempts
                (fakeReplayRepository state RequestReplayCasApplied)
                attempt
                captured
                ( \_ ->
                    modifyIORef' effects (+ 1)
                      >> pure (Right response :: Either Text ReplayResponse)
                )
        first <- serve attemptA
        second <- serve attemptB
        first @?= AuthenticatedServeReplayed (ReplayProtectedExecuted response)
        second @?= AuthenticatedServeReplayed (ReplayProtectedRecovered response)
        readIORef effects >>= (@?= 1)
    ]

authenticatedRoleInterpreterTests :: TestTree
authenticatedRoleInterpreterTests =
  testGroup
    "authenticated role interpreter composition"
    [ testCase "passes the opaque verified slot to the context-aware handler" $ do
        let cliSigner = signerForPrincipal CallerOperatorCli
            cliTrusted = trustedRequestKeyFromSigner cliSigner
            cliProviders = serverProvidersForRole LifecycleAuthorityRuntime cliTrusted
        captured <-
          captureLifecycleFrame
            (clientProvidersFor cliSigner)
            LifecycleOperationSubmitRoute
            (operationSubmitBody "request-a")
        state <- newReplayState emptyReplay
        effects <- newIORef (0 :: Int)
        seenCaller <- newIORef Nothing
        seenKey <- newIORef Nothing
        let handleInner slot route requestBody = case route of
              LifecycleOperationSubmit -> do
                let decoded =
                      mustRight
                        ( decodeControlPlaneRequest
                            1024
                            (LazyByteString.fromStrict requestBody)
                        )
                writeIORef seenCaller (Just (verifiedCallerSlotPrincipal slot))
                writeIORef seenKey (Just (authorityOperationSubmitKey decoded))
                modifyIORef' effects (+ 1)
                pure (Just (200, "inner-response"))
              _ -> pure Nothing
            inner =
              AuthenticatedRoleHandler
                { authenticatedHandlerReadyz = pure True
                , authenticatedHandlerHandle = handleInner
                }
            wrapped =
              wrappedHandler
                cliProviders
                attemptA
                state
                LifecycleAuthorityRuntime
                inner
        handled <-
          interpreterHandle
            wrapped
            LifecycleOperationSubmit
            (LazyByteString.toStrict captured)
        handled @?= Just (200, "inner-response")
        readIORef effects >>= (@?= 1)
        readIORef seenCaller >>= (@?= Just CallerOperatorCli)
        readIORef seenKey >>= (@?= Just "request-a")
    , testCase "admits registered operations only through the authenticated aggregate handler" $ do
        let cliSigner = signerForPrincipal CallerOperatorCli
            cliProviders =
              serverProvidersForRole
                LifecycleAuthorityRuntime
                (trustedRequestKeyFromSigner cliSigner)
        captured <-
          captureLifecycleFrame
            (clientProvidersFor cliSigner)
            LifecycleOperationSubmitRoute
            (operationSubmitBody "request-a")
        replayState <- newReplayState emptyReplay
        (handler, authorityRevision) <- freshProductionAuthorityHandler
        let wrapped =
              wrappedHandler
                cliProviders
                attemptA
                replayState
                LifecycleAuthorityRuntime
                handler
        handled <-
          interpreterHandle
            wrapped
            LifecycleOperationSubmit
            (LazyByteString.toStrict captured)
        case handled of
          Just (200, responseBody) ->
            decodeControlPlaneResponse
              authorityOperationResponseMaximumBytes
              (LazyByteString.fromStrict responseBody)
              @?= Right (AuthorityOperationAccepted expectedAcceptedOperation)
          other -> assertFailure ("unexpected operation response: " <> show other)
        readIORef authorityRevision >>= (@?= 1)
    , testCase "an authenticated but unregistered principal cannot create authority state" $ do
        let harnessSigner = signerForPrincipal CallerTestHarness
            harnessProviders =
              serverProvidersForRole
                LifecycleAuthorityRuntime
                (trustedRequestKeyFromSigner harnessSigner)
        captured <-
          captureLifecycleFrame
            (clientProvidersFor harnessSigner)
            LifecycleOperationSubmitRoute
            (operationSubmitBody "request-a")
        replayState <- newReplayState emptyReplay
        (handler, authorityRevision) <- freshProductionAuthorityHandler
        let wrapped =
              wrappedHandler
                harnessProviders
                attemptA
                replayState
                LifecycleAuthorityRuntime
                handler
        handled <-
          interpreterHandle
            wrapped
            LifecycleOperationSubmit
            (LazyByteString.toStrict captured)
        case handled of
          Just (403, responseBody) ->
            decodeControlPlaneResponse
              authorityOperationResponseMaximumBytes
              (LazyByteString.fromStrict responseBody)
              @?= Right
                ( AuthorityOperationSubmitRefused
                    "authority-operation-refused-unregistered"
                )
          other -> assertFailure ("unexpected operation refusal: " <> show other)
        readIORef authorityRevision >>= (@?= 0)
    , testCase "confirms the durable reservation before effect and recovers an exact duplicate" $ do
        let cliSigner = signerForPrincipal CallerOperatorCli
            cliTrusted = trustedRequestKeyFromSigner cliSigner
            cliProviders = serverProvidersForRole LifecycleAuthorityRuntime cliTrusted
        captured <-
          captureLifecycleFrame
            (clientProvidersFor cliSigner)
            LifecycleOperationSubmitRoute
            (operationSubmitBody "request-a")
        state <- newReplayState emptyReplay
        effects <- newIORef (0 :: Int)
        reservedBeforeEffect <- newIORef False
        seenCaller <- newIORef Nothing
        let handleInner slot route requestBody = case route of
              LifecycleOperationSubmit -> do
                observed <- readIORef state
                writeIORef
                  reservedBeforeEffect
                  (requestReplayEntryCount (fakeReplayProjection observed) == 1)
                let decoded =
                      mustRight
                        ( decodeControlPlaneRequest
                            1024
                            (LazyByteString.fromStrict requestBody)
                        )
                authorityOperationSubmitKey decoded @?= "request-a"
                writeIORef seenCaller (Just (verifiedCallerSlotPrincipal slot))
                modifyIORef' effects (+ 1)
                pure (Just (200, "inner-response"))
              _ -> pure Nothing
            inner =
              AuthenticatedRoleHandler
                { authenticatedHandlerReadyz = pure True
                , authenticatedHandlerHandle = handleInner
                }
            firstWrapper =
              wrappedHandler
                cliProviders
                attemptA
                state
                LifecycleAuthorityRuntime
                inner
            duplicateWrapper =
              wrappedHandler
                cliProviders
                attemptB
                state
                LifecycleAuthorityRuntime
                inner
            raw = LazyByteString.toStrict captured
        first <- interpreterHandle firstWrapper LifecycleOperationSubmit raw
        duplicate <- interpreterHandle duplicateWrapper LifecycleOperationSubmit raw
        first @?= Just (200, "inner-response")
        duplicate @?= Just (200, "inner-response")
        readIORef effects >>= (@?= 1)
        readIORef reservedBeforeEffect >>= (@?= True)
        readIORef seenCaller >>= (@?= Just CallerOperatorCli)
    , testCase "refuses a concurrently owned in-flight request without invoking the handler" $ do
        captured <- captureAuthenticatedFrame clientProviders body
        authenticated <-
          authenticateControlPlaneFrame
            transportBounds
            maximumLifetime
            serverProviders
            ProviderWorkerRuntime
            ProviderWorkApply
            captured
        request <- mustRightIO authenticated
        let reserved =
              replayReservationProjection
                ( reserveVerifiedRequest
                    now
                    attemptA
                    (authenticatedServerVerifiedRequest request)
                    emptyReplay
                )
        state <- newReplayState reserved
        effects <- newIORef (0 :: Int)
        let wrapped =
              wrappedInterpreter
                serverProviders
                attemptB
                state
                ProviderWorkerRuntime
                (countingInterpreter effects)
        handled <-
          interpreterHandle
            wrapped
            ProviderWorkApply
            (LazyByteString.toStrict captured)
        handled @?= Just (409, "authenticated-replay-in-flight\n")
        readIORef effects >>= (@?= 0)
    , testCase "projects every replay outcome onto a stable status and body" $
        mapM_
          (\(outcome, expected) -> replayProtectedResponse outcome @?= expected)
          replayResponseFixtures
    , testCase "projects authentication and attempt-provider refusals" $ do
        authenticatedServerErrorResponse
          (AuthenticatedServerFrameFailed AuthenticatedFrameInvalid)
          @?= (400, "authenticated-frame-refused\n")
        authenticatedServerErrorResponse
          (AuthenticatedServerRequestAuthenticationFailed [])
          @?= (401, "authentication-refused\n")
        captured <- captureAuthenticatedFrame clientProviders body
        state <- newReplayState emptyReplay
        let unavailableAttemptProviders =
              AuthenticatedRoleProviders
                { authenticatedRoleServerProviders = serverProviders
                , provideAuthenticatedReplayAttempt = pure (Left "rng unavailable")
                }
            wrapped =
              authenticatedRoleInterpreter
                transportBounds
                maximumLifetime
                unavailableAttemptProviders
                ProviderWorkerRuntime
                casAttempts
                replayLimits
                (fakeReplayRepository state RequestReplayCasApplied)
                (contextFreeAuthenticatedRoleHandler countingInterpreterDiscarded)
        handled <-
          interpreterHandle
            wrapped
            ProviderWorkApply
            (LazyByteString.toStrict captured)
        handled @?= Just (503, "authenticated-replay-attempt-unavailable\n")
    ]

authenticatedRuntimeTests :: TestTree
authenticatedRuntimeTests =
  testGroup
    "authenticated production runtime boundary"
    [ testCase "resolves canonical mounted key references into the callee's total route registry" $ do
        let wire =
              ControlPlaneAuthenticationWire
                { maximum_trusted_callers_per_route = 3
                , signing_principal_code =
                    fromIntegral
                      (callerPrincipalCode (CallerService ProviderWorkerRuntime))
                , signing_key_name =
                    controlPlaneSigningKeyName
                      (controlPlaneSigningKeyRefFor (CallerService ProviderWorkerRuntime))
                , trusted_callers =
                    [ ControlPlaneTrustedCallerWire
                        { trusted_route_path = Text.pack (controlPlaneRoutePath route)
                        , trusted_caller_code = fromIntegral (callerPrincipalCode caller)
                        , trusted_signing_key_name =
                            controlPlaneSigningKeyName (controlPlaneSigningKeyRefFor caller)
                        }
                    | route <- routesForRole ProviderWorkerRuntime
                    , caller <- trustedCallersForRoute route
                    ]
                }
            topology = mustRight (validateControlPlaneAuthenticationWire ProviderWorkerRuntime wire)
        resolved <-
          resolveRouteTrustRegistryWith
            (\_ -> pure (Right (1, requestSignerPublicKeyBytes signer)))
            topology
        let registry = mustRight resolved
            mountedProviders =
              AuthenticatedServerProviders
                { provideAuthenticatedServerScope = pure (Right scope)
                , provideAuthenticatedServerEpoch = pure (Right authorityEpochGenesis)
                , provideAuthenticatedServerTime = pure (Right now)
                , provideAuthenticatedServerTrustRegistry = pure (Right registry)
                }
        captured <- captureAuthenticatedFrame clientProviders body
        authenticated <-
          authenticateControlPlaneFrame
            transportBounds
            maximumLifetime
            mountedProviders
            ProviderWorkerRuntime
            ProviderWorkApply
            captured
        case authenticated of
          Left err -> assertFailure (show err)
          Right request -> authenticatedServerInnerBody request @?= body
    , testCase "installs an authenticated interpreter only for the supplied role" $ do
        state <- newReplayState emptyReplay
        effects <- newIORef 0
        let inputs =
              AuthenticatedRuntimeInputs
                ProviderWorkerRuntime
                transportBounds
                maximumLifetime
                AuthenticatedRoleProviders
                  { authenticatedRoleServerProviders = serverProviders
                  , provideAuthenticatedReplayAttempt = pure (Right attemptA)
                  }
                casAttempts
                replayLimits
                (fakeReplayRepository state RequestReplayCasApplied)
            handler = contextFreeAuthenticatedRoleHandler (countingInterpreter effects)
        installed <- case installAuthenticatedRuntimeInterpreter ProviderWorkerRuntime inputs handler of
          Left err -> assertFailure (show err) >> fail (show err)
          Right interpreter -> pure interpreter
        captured <- captureAuthenticatedFrame clientProviders body
        interpreterHandle installed ProviderWorkApply (LazyByteString.toStrict captured)
          >>= (@?= Just (200, "inner-response"))
        readIORef effects >>= (@?= 1)
        case installAuthenticatedRuntimeInterpreter LifecycleAuthorityRuntime inputs handler of
          Left (AuthenticatedRuntimeRoleMismatch LifecycleAuthorityRuntime ProviderWorkerRuntime) ->
            pure ()
          Left err -> assertFailure ("unexpected role mismatch: " <> show err)
          Right _ -> assertFailure "cross-role authenticated runtime installation succeeded"
    , testCase "represents missing retained replay/epoch provisioning without dummy providers" $ do
        let unavailable =
              authenticatedRuntimeUnavailableInterpreter
                ( AuthenticatedRuntimeRetainedReplayAndEpochProvisioningMissing
                    ProviderWorkerRuntime
                )
        interpreterReadyz unavailable >>= (@?= False)
        interpreterHandle unavailable ProviderWorkApply "ignored"
          >>= ( @?=
                  Just
                    ( 503
                    , "authenticated-runtime-retained-replay-and-epoch-provisioning-missing\n"
                    )
              )
    ]

principalSlotFixtures :: [CallerPrincipal]
principalSlotFixtures =
  [ CallerService LifecycleAuthorityRuntime
  , CallerOperatorCli
  , CallerTestHarness
  ]

verifyPrincipalIdentity :: CallerPrincipal -> IO ()
verifyPrincipalIdentity principal = do
  let verified = verifiedForPrincipal principal nonceA body
  verifiedRequestCallerPrincipal verified @?= principal
  verifiedCallerSlotPrincipal (verifiedRequestCallerSlot verified) @?= principal
  verifiedCallerSlotKeyGeneration (verifiedRequestCallerSlot verified) @?= generation

operationSubmitBody :: Text -> ByteString
operationSubmitBody submissionKey =
  LazyByteString.toStrict
    ( encodeControlPlaneRequest
        AuthorityOperationSubmitPayload
          { authorityOperationSubmitKey = submissionKey
          , authorityOperationSubmitDigest = "request-digest"
          }
    )

expectedAcceptedOperation :: OperationId
expectedAcceptedOperation =
  OperationId
    authorityEpochGenesis
    (ClientId "registered-slot/1/generation/1")
    (ClientSequence 1)
    (RequestDigest "request-digest")

wrappedInterpreter
  :: AuthenticatedServerProviders IO
  -> ReplayAttemptId
  -> IORef FakeReplayState
  -> RuntimeRole
  -> RoleInterpreter IO
  -> RoleInterpreter IO
wrappedInterpreter providers attempt state localRole =
  wrappedHandler
    providers
    attempt
    state
    localRole
    . contextFreeAuthenticatedRoleHandler

wrappedHandler
  :: AuthenticatedServerProviders IO
  -> ReplayAttemptId
  -> IORef FakeReplayState
  -> RuntimeRole
  -> AuthenticatedRoleHandler IO
  -> RoleInterpreter IO
wrappedHandler providers attempt state localRole =
  authenticatedRoleInterpreter
    transportBounds
    maximumLifetime
    AuthenticatedRoleProviders
      { authenticatedRoleServerProviders = providers
      , provideAuthenticatedReplayAttempt = pure (Right attempt)
      }
    localRole
    casAttempts
    replayLimits
    (fakeReplayRepository state RequestReplayCasApplied)

freshProductionAuthorityHandler
  :: IO (AuthenticatedRoleHandler IO, IORef Natural)
freshProductionAuthorityHandler = do
  stateRef <- newIORef openedProductionAuthority
  revisionRef <- newIORef 0
  let repository =
        AuthorityAdmissionRepository
          { readAuthorityAdmission = do
              revision <- readIORef revisionRef
              aggregate <- readIORef stateRef
              pure (Right (AuthorityAdmissionSnapshot revision aggregate))
          , compareAndSwapAuthorityAdmission = \expected next -> do
              revision <- readIORef revisionRef
              if revision /= expected
                then pure (Left "authority admission CAS conflict")
                else do
                  writeIORef stateRef next
                  writeIORef revisionRef (revision + 1)
                  pure (Right ())
          }
      handler =
        lifecycleAuthorityAdmissionAuthenticatedHandler
          4096
          (pure True)
          "cluster-a"
          (pure (Right 1000))
          (const (Right "fixture-authority-envelope"))
          repository
          ConfigAuthorityRepository
            { observeAuthorityConfig = const (pure ConfigObservationMissing)
            , proposeAuthorityConfig =
                const (pure (ConfigProposalUnavailable "fixture config unavailable"))
            }
          (unavailableProjectionImportHandler "fixture projection registration absent")
          ( resolvingRetainedSesLeaseHandler
              (pure (Left "fixture lease registration absent"))
          )
          fixturePulumiCheckpointHandler
          (error "fixture cleanup-run repository is unavailable")
  pure (handler, revisionRef)

openedProductionAuthority :: AuthorityAdmissionAggregate
openedProductionAuthority =
  foldl
    (\aggregate command -> snd (stepAuthorityAdmission aggregate command))
    initial
    [ ApplyAuthorityGenesis
        ( BeginGenesisEstablishment
            (GenesisPlan "fixture-plan" "s3://fixture/authority-backup")
        )
    , ApplyAuthorityGenesis
        (ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "target-generation-1"))
    , ApplyAuthorityGenesis
        (ObserveBackupReceipt (BackupReceipt "backup-receipt-1"))
    ]
 where
  initial =
    mustRight
      ( initialCleanInstallAuthorityWithRegisteredClients
          4
          8
          productionRegisteredClients
      )

productionRegisteredClients :: RegisteredClientTable
productionRegisteredClients =
  mustRight
    ( mkRegisteredClientTable
        1
        [ mustRight
            ( mkRegisteredClientSpec
                (clientPrincipalForCaller CallerOperatorCli)
                (mustRight (mkRegisteredClientSlot 1))
                (mustRight (mkRegisteredClientGeneration 1))
                4
            )
        ]
    )

fixturePulumiCheckpointHandler :: PulumiCheckpointHandler IO
fixturePulumiCheckpointHandler =
  mkPulumiCheckpointHandler
    PulumiCheckpointRepository
      { observeRegisteredPulumiCheckpoint = \_callerSlot _ -> pure PulumiCheckpointMissing
      , publishRegisteredPulumiCheckpoint = \_callerSlot _ _ _ ->
          pure (PulumiCheckpointPublicationUnavailable "fixture unavailable")
      , retireRegisteredPulumiCheckpoint = \_callerSlot _ _ ->
          pure (PulumiCheckpointRetirementUnavailable "fixture unavailable")
      }

countingInterpreter :: IORef Int -> RoleInterpreter IO
countingInterpreter effects =
  RoleInterpreter
    { interpreterReadyz = pure True
    , interpreterHandle = \_ _ -> do
        modifyIORef' effects (+ 1)
        pure (Just (200, "inner-response"))
    }

countingInterpreterDiscarded :: RoleInterpreter IO
countingInterpreterDiscarded =
  RoleInterpreter
    { interpreterReadyz = pure True
    , interpreterHandle = \_ _ -> pure (Just (200, "inner-response"))
    }

replayResponseFixtures
  :: [(ReplayProtectedResult AuthenticatedRoleHandlerFailure, (Int, ByteString))]
replayResponseFixtures =
  [ (ReplayProtectedExecuted response, (200, "response"))
  , (ReplayProtectedRecovered response, (200, "response"))
  , (ReplayProtectedInFlight, (409, "authenticated-replay-in-flight\n"))
  , (ReplayProtectedTombstoned, (409, "authenticated-replay-tombstoned\n"))
  , (ReplayProtectedDigestConflict, (409, "authenticated-replay-digest-conflict\n"))
  , (ReplayProtectedExpired, (408, "authenticated-replay-expired\n"))
  ,
    ( ReplayProtectedCapacityExhausted
    , (503, "authenticated-replay-capacity-exhausted\n")
    )
  ,
    ( ReplayProtectedUnavailable
        (RequestReplayRepositoryUnobservable "unavailable")
    , (503, "authenticated-replay-unavailable\n")
    )
  ,
    ( ReplayProtectedAttemptsExhausted
    , (503, "authenticated-replay-attempts-exhausted\n")
    )
  ,
    ( ReplayProtectedEffectFailed AuthenticatedRoleHandlerUnavailable
    , (503, "interpreter-unavailable\n")
    )
  ,
    ( ReplayProtectedEffectFailed
        ( AuthenticatedRoleHandlerResponseInvalid
            (ReplayResponseStatusInvalid 99)
        )
    , (500, "authenticated-handler-response-invalid\n")
    )
  ,
    ( ReplayProtectedCompletionUnconfirmed
        DurableReplayCompletionReservationMissing
    , (503, "authenticated-replay-completion-unconfirmed\n")
    )
  ]

data TestMetadataWire = TestMetadataWire
  { testMetadataVersion :: !Word
  , testMetadataDeadlineMicros :: !Natural
  , testMetadataNonce :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TestFrameWire = TestFrameWire
  { testFrameVersion :: !Word
  , testFrameMetadata :: !ByteString
  , testFrameEnvelope :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

decodeTestFrame :: LazyByteString.ByteString -> TestFrameWire
decodeTestFrame bytes = mustRight (mapLeft show (deserialiseOrFail bytes))

decodeTestMetadata :: ByteString -> TestMetadataWire
decodeTestMetadata bytes =
  mustRight (mapLeft show (deserialiseOrFail (LazyByteString.fromStrict bytes)))

makeReplayVersionNonCanonical :: ByteString -> ByteString
makeReplayVersionNonCanonical bytes =
  case replaceFirst "\x19\x00\x02" "\x18\x02" bytes of
    Just replaced -> replaced
    Nothing -> replaceShortReplayVersion bytes

replaceShortReplayVersion :: ByteString -> ByteString
replaceShortReplayVersion bytes = case replaceFirst "\x02" "\x18\x02" bytes of
  Just replaced -> replaced
  Nothing -> error "unexpected replay envelope encoding"

replaceFirst :: ByteString -> ByteString -> ByteString -> Maybe ByteString
replaceFirst needle replacement bytes =
  let (prefix, suffix) = ByteString.breakSubstring needle bytes
   in if ByteString.null suffix
        then Nothing
        else
          Just
            ( prefix
                <> replacement
                <> ByteString.drop (ByteString.length needle) suffix
            )

data FakeReplayState = FakeReplayState
  { fakeReplayRevision :: !Int
  , fakeReplayProjection :: !RequestReplayProjection
  }

newReplayState :: RequestReplayProjection -> IO (IORef FakeReplayState)
newReplayState projection = newIORef (FakeReplayState 0 projection)

fakeReplayRepository
  :: IORef FakeReplayState
  -> RequestReplayCasResult
  -> RequestReplayRepository IO Int
fakeReplayRepository state appliedResult =
  RequestReplayRepository
    { readRequestReplayProjection = do
        observed <- readIORef state
        pure
          ( Right
              RequestReplaySnapshot
                { requestReplayRevision = fakeReplayRevision observed
                , requestReplaySnapshotProjection = fakeReplayProjection observed
                }
          )
    , compareAndSwapRequestReplayProjection = \expected projection ->
        atomicModifyIORef' state $ \observed ->
          if fakeReplayRevision observed == expected
            then
              ( FakeReplayState
                  { fakeReplayRevision = expected + 1
                  , fakeReplayProjection = projection
                  }
              , appliedResult
              )
            else (observed, RequestReplayCasConflict)
    }

responseLostCas :: RequestReplayCasResult
responseLostCas =
  RequestReplayCasUnobservable
    (RequestReplayRepositoryUnobservable "CAS response lost")

unobservableReplayRepository :: RequestReplayRepository IO Int
unobservableReplayRepository =
  RequestReplayRepository
    { readRequestReplayProjection =
        pure (Left (RequestReplayRepositoryUnobservable "read unavailable"))
    , compareAndSwapRequestReplayProjection = \_ _ ->
        pure
          ( RequestReplayCasUnobservable
              (RequestReplayRepositoryUnobservable "write unavailable")
          )
    }

captureAuthenticatedFrame
  :: AuthenticatedClientProviders IO
  -> ByteString
  -> IO LazyByteString.ByteString
captureAuthenticatedFrame providers innerBody = do
  captured <- newIORef Nothing
  endpoint <- mustRightIO (mkProviderWorkerEndpoint "http://provider-worker:8600")
  client <-
    mustRightIO
      ( controlPlaneClientWithTransport
          1024
          endpoint
          ( \_ _ _ requestBody -> do
              writeIORef captured (Just requestBody)
              pure (Right (200, "ok"))
          )
      )
  result <-
    callAuthenticatedControlPlane
      transportBounds
      providers
      client
      ProviderWorkApplyRoute
      innerBody
  result @?= Right (ControlPlaneResponse 200 "ok")
  observed <- readIORef captured
  case observed of
    Nothing -> assertFailure "authenticated client did not invoke transport"
    Just requestBody -> pure (LazyByteString.fromStrict requestBody)

captureLifecycleFrame
  :: AuthenticatedClientProviders IO
  -> ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  -> ByteString
  -> IO LazyByteString.ByteString
captureLifecycleFrame providers route innerBody = do
  captured <- newIORef Nothing
  endpoint <- mustRightIO (mkLifecycleAuthorityEndpoint "http://lifecycle-authority:8600")
  client <-
    mustRightIO
      ( controlPlaneClientWithTransport
          1024
          endpoint
          ( \_ _ _ requestBody -> do
              writeIORef captured (Just requestBody)
              pure (Right (200, "ok"))
          )
      )
  result <-
    callAuthenticatedControlPlane
      transportBounds
      providers
      client
      route
      innerBody
  result @?= Right (ControlPlaneResponse 200 "ok")
  observed <- readIORef captured
  case observed of
    Nothing -> assertFailure "authenticated lifecycle client did not invoke transport"
    Just requestBody -> pure (LazyByteString.fromStrict requestBody)

clientProviders :: AuthenticatedClientProviders IO
clientProviders = clientProvidersFor signer

clientProvidersFor :: RequestSigner -> AuthenticatedClientProviders IO
clientProvidersFor requestSigner =
  AuthenticatedClientProviders
    { provideAuthenticatedClientSigner =
        pure (Right (localRequestSigningCapability requestSigner))
    , provideAuthenticatedClientScope = pure (Right scope)
    , provideAuthenticatedClientEpoch = pure (Right authorityEpochGenesis)
    , provideAuthenticatedClientDeadline = pure (Right deadline)
    , provideAuthenticatedClientNonce = pure (Right nonceA)
    }

serverProviders :: AuthenticatedServerProviders IO
serverProviders = serverProvidersForRole ProviderWorkerRuntime trusted

serverProvidersForRole
  :: RuntimeRole
  -> TrustedRequestKey
  -> AuthenticatedServerProviders IO
serverProvidersForRole role trustedKey =
  AuthenticatedServerProviders
    { provideAuthenticatedServerScope = pure (Right scope)
    , provideAuthenticatedServerEpoch = pure (Right authorityEpochGenesis)
    , provideAuthenticatedServerTime = pure (Right now)
    , provideAuthenticatedServerTrustRegistry =
        pure (Right (trustRegistryFor role trustedKey))
    }

trustEntries :: [(ControlPlaneRoute, TrustedRequestKey)]
trustEntries = [(route, trusted) | route <- routesForRole ProviderWorkerRuntime]

trustRegistryFor :: RuntimeRole -> TrustedRequestKey -> RouteTrustRegistry
trustRegistryFor role trustedKey =
  mustRight
    ( mkRouteTrustRegistry
        role
        1
        [(route, trustedKey) | route <- routesForRole role]
    )

verifiedRequest :: VerifiedControlPlaneRequest
verifiedRequest = verifiedFor nonceA body

verifiedDifferentBody :: VerifiedControlPlaneRequest
verifiedDifferentBody = verifiedFor nonceA "different-body"

verifiedOtherNonce :: VerifiedControlPlaneRequest
verifiedOtherNonce = verifiedFor nonceB body

verifiedFor :: RequestNonce -> ByteString -> VerifiedControlPlaneRequest
verifiedFor nonce innerBody =
  verifiedForSigner signer nonce innerBody

verifiedForPrincipal
  :: CallerPrincipal -> RequestNonce -> ByteString -> VerifiedControlPlaneRequest
verifiedForPrincipal principal = verifiedForSigner (signerForPrincipal principal)

verifiedForSigner
  :: RequestSigner -> RequestNonce -> ByteString -> VerifiedControlPlaneRequest
verifiedForSigner requestSigner nonce innerBody =
  let signed =
        mustRight
          ( signControlPlaneRequest
              requestSigner
              ProviderWorkApply
              ProviderWorkerRuntime
              scope
              authorityEpochGenesis
              deadline
              nonce
              innerBody
          )
      context =
        mustRight
          ( mkRequestVerificationContext
              (trustedRequestKeyFromSigner requestSigner)
              ProviderWorkApply
              ProviderWorkerRuntime
              scope
              authorityEpochGenesis
              deadline
              nonce
              now
              maximumLifetime
          )
   in mustRight
        ( decodeAndVerifyControlPlaneRequest
            65536
            context
            (encodeSignedControlPlaneRequest signed)
        )

completedReplay :: RequestReplayProjection
completedReplay =
  replayCompletionProjection
    ( completeVerifiedRequest
        attemptA
        verifiedRequest
        response
        ( replayReservationProjection
            (reserveVerifiedRequest now attemptA verifiedRequest emptyReplay)
        )
    )

emptyReplay :: RequestReplayProjection
emptyReplay = initialRequestReplayProjection replayLimits

replayLimits :: RequestReplayLimits
replayLimits = mustRight (mkRequestReplayLimits 1 64 skew)

response :: ReplayResponse
response = mustRight (mkReplayResponse replayLimits 200 "response")

otherResponse :: ReplayResponse
otherResponse = mustRight (mkReplayResponse replayLimits 409 "other")

transportBounds :: AuthenticatedTransportBounds
transportBounds = mustRight (mkAuthenticatedTransportBounds 65536 256 65000)

signer :: RequestSigner
signer = signerForPrincipal (CallerService LifecycleAuthorityRuntime)

signerForPrincipal :: CallerPrincipal -> RequestSigner
signerForPrincipal principal =
  mustRight (mkRequestSigner principal generation signingSeed)

trusted :: TrustedRequestKey
trusted = trustedRequestKeyFromSigner signer

generation :: SigningKeyGeneration
generation = mustRight (mkSigningKeyGeneration 1)

scope :: AuthorityScope
scope = mustRight (mkAuthorityScope "cluster-a")

nonceA :: RequestNonce
nonceA = mustRight (mkRequestNonce (ByteString.pack [0 .. 15]))

nonceB :: RequestNonce
nonceB = mustRight (mkRequestNonce (ByteString.pack [16 .. 31]))

attemptA :: ReplayAttemptId
attemptA = mustRight (mkReplayAttemptId (ByteString.pack [32 .. 47]))

attemptB :: ReplayAttemptId
attemptB = mustRight (mkReplayAttemptId (ByteString.pack [48 .. 63]))

casAttempts :: ReplayCasAttempts
casAttempts = mustRight (mkReplayCasAttempts 4)

now :: AuthorityTime
now = authorityTimeFromMicros 1000

deadline :: AuthorityTime
deadline = authorityTimeFromMicros 2000

skew :: AuthorityDuration
skew = mustRight (authorityDurationFromMicros 100)

maximumLifetime :: AuthorityDuration
maximumLifetime = mustRight (authorityDurationFromMicros 5000)

body :: ByteString
body = "canonical-inner-request"

signingSeed :: ByteString
signingSeed = ByteString.pack [0 .. 31]

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft convert value = case value of
  Left err -> Left (convert err)
  Right result -> Right result

registryError
  :: Either RouteTrustRegistryError RouteTrustRegistry -> RouteTrustRegistryError
registryError value = case value of
  Left err -> err
  Right _ -> error "expected route trust registry construction to fail"

mustRight :: (Show err) => Either err value -> value
mustRight value = case value of
  Left err -> error (show err)
  Right result -> result

mustRightIO :: (Show err) => Either err value -> IO value
mustRightIO value = case value of
  Left err -> fail (show err)
  Right result -> pure result
