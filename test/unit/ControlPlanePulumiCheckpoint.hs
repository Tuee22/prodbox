{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlanePulumiCheckpoint
  ( controlPlanePulumiCheckpointSuite
  )
where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedTransport
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityOperationSubmitPayload (..)
  , AuthorityOperationSubmitResponse (..)
  , AuthorityOperationSubmitResult (..)
  , authorityOperationResponseMaximumBytes
  , authorityOperationSubmitResponseBody
  )
import Prodbox.ControlPlane.AuthorityOperationClient
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli)
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneClient
  , controlPlaneClientWithTransport
  , mkLifecycleAuthorityEndpoint
  )
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneRequest
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.Coordinate (AuthorityScope, mkAuthorityScope)
import Prodbox.ControlPlane.PulumiCheckpointClient
import Prodbox.ControlPlane.PulumiCheckpointEndpoint
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestNonce
  , RequestSigner
  , VerifiedCallerSlot
  , decodeAndVerifyControlPlaneRequest
  , encodeSignedControlPlaneRequest
  , localRequestSigningCapability
  , mkRequestNonce
  , mkRequestSigner
  , mkRequestVerificationContext
  , mkSigningKeyGeneration
  , signControlPlaneRequest
  , trustedRequestKeyFromSigner
  , verifiedRequestCallerSlot
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneMethod (ControlPlanePost)
  , ControlPlaneRoute
    ( LifecycleOperationSubmit
    , LifecyclePulumiCheckpoint
    )
  , decodeRoleRoute
  , routesForRole
  )
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Infra.StackDescriptor
  ( StackDescriptor (..)
  , stackDescriptors
  )
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityRegisteredSubmissionDecision (..)
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( RegisteredSubmissionDecision (..)
  , mkClientSubmissionKey
  )
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.Authority.Submission
  ( ClientId (..)
  , ClientSequence (..)
  , OperationId (..)
  , RequestDigest (..)
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , authorityDurationFromMicros
  , authorityTimeFromMicros
  )
import Prodbox.Lifecycle.PulumiCheckpoint
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import TestSupport

data RepositoryCall
  = RepositoryObserved !RegisteredPulumiCheckpoint
  | RepositoryPublished
      !OperationId
      !(Maybe PulumiCheckpointDigest)
      !RegisteredPulumiCheckpoint
      !ByteString
  | RepositoryRetired
      !OperationId
      !(Maybe PulumiCheckpointDigest)
      !RegisteredPulumiCheckpoint
  deriving stock (Eq, Show)

controlPlanePulumiCheckpointSuite :: SuiteBuilder ()
controlPlanePulumiCheckpointSuite =
  describe "Sprint 4.50 closed Pulumi checkpoint authority transport" $ do
    it "derives the only checkpoint identities from StackDescriptor" $ do
      let expected =
            [ ( stackRegistryName descriptor
              , stackPulumiProjectName descriptor
              , stackPulumiStackId descriptor
              )
            | descriptor <- stackDescriptors
            ]
          actual =
            [ ( registeredPulumiCheckpointName checkpoint
              , registeredPulumiCheckpointProject checkpoint
              , registeredPulumiCheckpointStack checkpoint
              )
            | checkpoint <- registeredPulumiCheckpoints
            ]
      actual
        `shouldBe` [ (fromString name, fromString project, fromString stack)
                   | (name, project, stack) <- expected
                   ]
      registeredPulumiCheckpointByName "caller-selected"
        `shouldBe` Left (PulumiCheckpointNameUnregistered "caller-selected")
      registeredPulumiCheckpointFor "prodbox-aws-test" "another-stack"
        `shouldBe` Left
          ( PulumiCheckpointCoordinatesUnregistered
              "prodbox-aws-test"
              "another-stack"
          )

    it "bounds, versions, canonicalises, and separates file checkpoints from legacy exports" $ do
      forM_ [1 :: Int, 2, 3] $ \version -> do
        checkpoint <-
          accepted
            ( decodeCanonicalPulumiCheckpoint
                (Set.singleton PulumiFileBackendCheckpoint)
                pulumiCheckpointMaximumBytes
                ( ByteString8.pack
                    ("{\"version\":" ++ show version ++ ",\"checkpoint\":{}}")
                )
            )
        canonicalPulumiCheckpointKind checkpoint
          `shouldBe` PulumiFileBackendCheckpoint
        canonicalPulumiCheckpointBytes checkpoint
          `shouldBe` ( "{\"checkpoint\":{},\"version\":"
                         <> ByteString8.pack (show version)
                         <> "}"
                     )
      decodeCanonicalPulumiCheckpoint
        (Set.singleton PulumiFileBackendCheckpoint)
        pulumiCheckpointMaximumBytes
        "{\"version\":4,\"checkpoint\":{}}"
        `shouldBe` Left (PulumiCheckpointUnsupportedVersion 4)
      decodeCanonicalPulumiCheckpoint
        (Set.singleton PulumiFileBackendCheckpoint)
        pulumiCheckpointMaximumBytes
        "{\"version\":3,\"deployment\":{}}"
        `shouldBe` Left
          (PulumiCheckpointPayloadKindRefused PulumiLegacyExportCheckpoint)
      legacy <-
        accepted
          ( decodeCanonicalPulumiCheckpoint
              (Set.singleton PulumiLegacyExportCheckpoint)
              pulumiCheckpointMaximumBytes
              "{\"version\":3,\"deployment\":{}}"
          )
      canonicalPulumiCheckpointKind legacy
        `shouldBe` PulumiLegacyExportCheckpoint
      decodeCanonicalPulumiCheckpoint
        (Set.singleton PulumiFileBackendCheckpoint)
        8
        "{\"version\":3,\"checkpoint\":{}}"
        `shouldBe` Left (PulumiCheckpointTooLarge 29 8)

    it "refuses selectors, malformed requests, and legacy exports before repository effects" $ do
      effects <- newIORef (0 :: Int)
      let repository = countingRepository effects
          handler = mkPulumiCheckpointHandler repository
          legacyExport = "{\"version\":3,\"deployment\":{}}"
      unregistered <-
        runPulumiCheckpointHandler
          handler
          checkpointCallerSlot
          (encodeControlPlaneRequest (ObservePulumiCheckpoint "caller-selected"))
      case unregistered of
        PulumiCheckpointRegistrationRefused _ -> pure ()
        other -> expectationFailure ("expected registration refusal, got " ++ show other)
      invalidOperation <-
        runPulumiCheckpointHandler
          handler
          checkpointCallerSlot
          "not-canonical-cbor"
      case invalidOperation of
        PulumiCheckpointBadRequest _ -> pure ()
        other -> expectationFailure ("expected bad-request refusal, got " ++ show other)
      legacy <-
        runPulumiCheckpointHandler
          handler
          checkpointCallerSlot
          ( encodeControlPlaneRequest
              (PublishPulumiCheckpoint "aws-test" publishTicket legacyExport)
          )
      case legacy of
        PulumiCheckpointPayloadRefused "aws-test" _ -> pure ()
        other -> expectationFailure ("expected legacy-payload refusal, got " ++ show other)
      readIORef effects `shouldReturn` 0

    it "round-trips observe, publish, and retire through the exact role-indexed route" $ do
      registered <- accepted (registeredPulumiCheckpointByName "aws-test")
      let publishOperation = operationFixture 1 "publish-request"
          retireOperation = operationFixture 2 "retire-request"
      checkpoint <-
        accepted
          ( decodeCanonicalPulumiCheckpoint
              (Set.singleton PulumiFileBackendCheckpoint)
              pulumiCheckpointMaximumBytes
              "{\"version\":3,\"checkpoint\":{\"latest\":{}}}"
          )
      (repository, state, calls) <- memoryRepository
      let handler = mkPulumiCheckpointHandler repository
      client <- clientFor handler
      let capability =
            lifecycleAuthorityPulumiCheckpoint
              checkpointTransportBounds
              checkpointClientProviders
              registered
              client
      observePulumiCheckpoint capability
        `shouldReturn` Right PulumiCheckpointMissing
      publishPulumiCheckpoint capability publishOperation Nothing checkpoint
        `shouldReturn` Right
          (PulumiCheckpointPublished (canonicalPulumiCheckpointDigest checkpoint))
      observed <- observePulumiCheckpoint capability
      observed `shouldBe` Right (PulumiCheckpointCurrent checkpoint)
      retirePulumiCheckpoint
        capability
        retireOperation
        (Just (canonicalPulumiCheckpointDigest checkpoint))
        `shouldReturn` Right PulumiCheckpointRetiredAndReadBack
      observePulumiCheckpoint capability
        `shouldReturn` Right PulumiCheckpointMissing
      readIORef state `shouldReturn` Nothing
      readIORef calls
        `shouldReturn` [ RepositoryObserved registered
                       , RepositoryPublished
                           publishOperation
                           Nothing
                           registered
                           (canonicalPulumiCheckpointBytes checkpoint)
                       , RepositoryObserved registered
                       , RepositoryRetired
                           retireOperation
                           (Just (canonicalPulumiCheckpointDigest checkpoint))
                           registered
                       , RepositoryObserved registered
                       ]

    it "returns the identical authority-allocated operation identity on authenticated replay" $ do
      let expectedOperation = operationFixture 7 "operation-request"
          digest = RequestDigest "operation-request"
      submissionKey <- accepted (mkClientSubmissionKey "operation-key")
      client <- operationClientFor expectedOperation
      let capability =
            lifecycleAuthorityOperationClient
              checkpointTransportBounds
              checkpointClientProviders
              client
      submitAuthorityOperation capability submissionKey digest
        `shouldReturn` Right
          (AuthorityOperationAdmissionAccepted expectedOperation)
      submitAuthorityOperation capability submissionKey digest
        `shouldReturn` Right
          (AuthorityOperationAdmissionDuplicate expectedOperation)

    it "encodes accepted and duplicate submissions with the exact authority identity" $ do
      let operation = operationFixture 9 "canonical-operation-response"
          acceptedResponse =
            authorityOperationSubmitResponseBody
              ( AuthorityOperationSubmitDecided
                  ( AuthorityRegisteredSubmissionDecided
                      (RegisteredSubmissionAccepted operation)
                  )
              )
          duplicateResponse =
            authorityOperationSubmitResponseBody
              ( AuthorityOperationSubmitDecided
                  ( AuthorityRegisteredSubmissionDecided
                      (RegisteredSubmissionDuplicate operation)
                  )
              )
      decodeControlPlaneResponse
        authorityOperationResponseMaximumBytes
        (LazyByteString.fromStrict acceptedResponse)
        `shouldBe` Right (AuthorityOperationAccepted operation)
      decodeControlPlaneResponse
        authorityOperationResponseMaximumBytes
        (LazyByteString.fromStrict duplicateResponse)
        `shouldBe` Right (AuthorityOperationDuplicate operation)

    it "owns one authority route and exposes no object-store selector" $ do
      decodeRoleRoute
        LifecycleAuthorityRuntime
        ControlPlanePost
        "/v1/authority/pulumi-checkpoint"
        `shouldBe` Just LifecyclePulumiCheckpoint
      decodeRoleRoute
        LifecycleAuthorityRuntime
        ControlPlanePost
        "/v1/object-store/pulumi/put"
        `shouldBe` Nothing

memoryRepository
  :: IO
       ( PulumiCheckpointRepository IO
       , IORef (Maybe CanonicalPulumiCheckpoint)
       , IORef [RepositoryCall]
       )
memoryRepository = do
  state <- newIORef Nothing
  calls <- newIORef []
  let record call = modifyIORef' calls (<> [call])
      repository =
        PulumiCheckpointRepository
          { observeRegisteredPulumiCheckpoint = \_callerSlot registered -> do
              record (RepositoryObserved registered)
              current <- readIORef state
              pure (maybe PulumiCheckpointMissing PulumiCheckpointCurrent current)
          , observeRegisteredPulumiCheckpointPair = \_callerSlot _ ->
              pure (PulumiCheckpointPairUnobservable "fixture unavailable")
          , publishRegisteredPulumiCheckpoint = \_callerSlot ticket registered checkpoint -> do
              record
                ( RepositoryPublished
                    (pulumiCheckpointTicketOperation ticket)
                    (pulumiCheckpointTicketExpectedDigest ticket)
                    registered
                    (canonicalPulumiCheckpointBytes checkpoint)
                )
              writeIORef state (Just checkpoint)
              pure (PulumiCheckpointPublished (canonicalPulumiCheckpointDigest checkpoint))
          , retireRegisteredPulumiCheckpoint = \_callerSlot ticket registered -> do
              record
                ( RepositoryRetired
                    (pulumiCheckpointTicketOperation ticket)
                    (pulumiCheckpointTicketExpectedDigest ticket)
                    registered
                )
              writeIORef state Nothing
              pure PulumiCheckpointRetiredAndReadBack
          , restoreRegisteredPulumiCheckpointPrimary = \_callerSlot _ _ _ ->
              pure (PulumiCheckpointRestoreUnavailable "fixture unavailable")
          , readBackRegisteredPulumiCheckpointRestore = \_callerSlot _ _ ->
              pure (PulumiCheckpointRestoreReadBackUnavailable "fixture unavailable")
          , attemptRegisteredPulumiCheckpointRetirement = \_callerSlot _ _ _ ->
              pure (PulumiCheckpointRetirementAttemptUnavailable "fixture unavailable")
          , readBackRegisteredPulumiCheckpointRetirement = \_callerSlot _ _ ->
              pure (PulumiCheckpointRetirementReadBackUnavailable "fixture unavailable")
          }
  pure (repository, state, calls)

countingRepository :: IORef Int -> PulumiCheckpointRepository IO
countingRepository effects =
  PulumiCheckpointRepository
    { observeRegisteredPulumiCheckpoint = \_callerSlot _ ->
        effect >> pure PulumiCheckpointMissing
    , observeRegisteredPulumiCheckpointPair = \_callerSlot _ ->
        effect >> pure (PulumiCheckpointPairUnobservable "fixture unavailable")
    , publishRegisteredPulumiCheckpoint = \_callerSlot _ _ checkpoint ->
        effect
          >> pure
            (PulumiCheckpointPublished (canonicalPulumiCheckpointDigest checkpoint))
    , retireRegisteredPulumiCheckpoint = \_callerSlot _ _ ->
        effect >> pure PulumiCheckpointRetiredAndReadBack
    , restoreRegisteredPulumiCheckpointPrimary = \_callerSlot _ _ _ ->
        effect >> pure (PulumiCheckpointRestoreUnavailable "fixture unavailable")
    , readBackRegisteredPulumiCheckpointRestore = \_callerSlot _ _ ->
        effect >> pure (PulumiCheckpointRestoreReadBackUnavailable "fixture unavailable")
    , attemptRegisteredPulumiCheckpointRetirement = \_callerSlot _ _ _ ->
        effect >> pure (PulumiCheckpointRetirementAttemptUnavailable "fixture unavailable")
    , readBackRegisteredPulumiCheckpointRetirement = \_callerSlot _ _ ->
        effect >> pure (PulumiCheckpointRetirementReadBackUnavailable "fixture unavailable")
    }
 where
  effect = modifyIORef' effects (+ 1)

publishTicket :: PulumiCheckpointMutationTicket
publishTicket =
  PulumiCheckpointMutationTicket
    { pulumiCheckpointTicketOperation = operationFixture 1 "publish-request"
    , pulumiCheckpointTicketExpectedDigest = Nothing
    }

operationFixture :: Natural -> Text -> OperationId
operationFixture sequenceNumber digest =
  OperationId
    authorityEpochGenesis
    (ClientId "registered-slot/1/generation/1")
    (ClientSequence sequenceNumber)
    (RequestDigest digest)

clientFor
  :: PulumiCheckpointHandler IO
  -> IO (ControlPlaneClient 'LifecycleAuthorityRuntime)
clientFor handler = do
  endpoint <- accepted (mkLifecycleAuthorityEndpoint "http://lifecycle-authority:8600")
  accepted
    ( controlPlaneClientWithTransport
        pulumiCheckpointResponseMaximumBytes
        endpoint
        ( \method _ url body -> do
            method `shouldBe` "POST"
            url `shouldBe` "http://lifecycle-authority:8600/v1/authority/pulumi-checkpoint"
            response <-
              authenticateControlPlaneFrame
                checkpointTransportBounds
                checkpointMaximumLifetime
                checkpointServerProviders
                LifecycleAuthorityRuntime
                LifecyclePulumiCheckpoint
                (LazyByteString.fromStrict body)
            case response of
              Left _ -> pure (Right (401, "authentication-refused"))
              Right authenticated -> do
                served <-
                  runPulumiCheckpointHandler
                    handler
                    (authenticatedServerCallerSlot authenticated)
                    ( LazyByteString.fromStrict
                        (authenticatedServerInnerBody authenticated)
                    )
                pure
                  ( Right
                      ( replyStatusCode (pulumiCheckpointResponseHttpStatus served)
                      , pulumiCheckpointResponseBody served
                      )
                  )
        )
    )

operationClientFor
  :: OperationId
  -> IO (ControlPlaneClient 'LifecycleAuthorityRuntime)
operationClientFor expectedOperation = do
  endpoint <- accepted (mkLifecycleAuthorityEndpoint "http://lifecycle-authority:8600")
  callCount <- newIORef (0 :: Int)
  accepted
    ( controlPlaneClientWithTransport
        authorityOperationResponseMaximumBytes
        endpoint
        ( \method _ url body -> do
            method `shouldBe` "POST"
            url `shouldBe` "http://lifecycle-authority:8600/v1/operations/submit"
            response <-
              authenticateControlPlaneFrame
                checkpointTransportBounds
                checkpointMaximumLifetime
                checkpointServerProviders
                LifecycleAuthorityRuntime
                LifecycleOperationSubmit
                (LazyByteString.fromStrict body)
            case response of
              Left _ -> pure (Right (401, "authentication-refused"))
              Right authenticated -> do
                decoded <-
                  accepted
                    ( decodeControlPlaneRequest
                        4096
                        ( LazyByteString.fromStrict
                            (authenticatedServerInnerBody authenticated)
                        )
                    )
                authorityOperationSubmitKey decoded `shouldBe` "operation-key"
                authorityOperationSubmitDigest decoded `shouldBe` "operation-request"
                observed <- readIORef callCount
                writeIORef callCount (observed + 1)
                let payload =
                      if observed == 0
                        then AuthorityOperationAccepted expectedOperation
                        else AuthorityOperationDuplicate expectedOperation
                pure
                  ( Right
                      ( 200
                      , LazyByteString.toStrict (encodeControlPlaneResponse payload)
                      )
                  )
        )
    )

checkpointClientProviders :: AuthenticatedClientProviders IO
checkpointClientProviders =
  AuthenticatedClientProviders
    { provideAuthenticatedClientSigner =
        pure (Right (localRequestSigningCapability checkpointRequestSigner))
    , provideAuthenticatedClientScope = pure (Right checkpointAuthorityScope)
    , provideAuthenticatedClientEpoch = pure (Right authorityEpochGenesis)
    , provideAuthenticatedClientDeadline = pure (Right checkpointDeadline)
    , provideAuthenticatedClientNonce = pure (Right checkpointRequestNonce)
    }

checkpointServerProviders :: AuthenticatedServerProviders IO
checkpointServerProviders =
  AuthenticatedServerProviders
    { provideAuthenticatedServerScope = pure (Right checkpointAuthorityScope)
    , provideAuthenticatedServerEpoch = pure (Right authorityEpochGenesis)
    , provideAuthenticatedServerTime = pure (Right checkpointNow)
    , provideAuthenticatedServerTrustRegistry = pure (Right checkpointTrustRegistry)
    }

checkpointTransportBounds :: AuthenticatedTransportBounds
checkpointTransportBounds =
  mustRight (mkAuthenticatedTransportBounds (256 * 1024) 256 (255 * 1024))

checkpointMaximumLifetime :: AuthorityDuration
checkpointMaximumLifetime = mustRight (authorityDurationFromMicros 5000)

checkpointNow :: AuthorityTime
checkpointNow = authorityTimeFromMicros 1000

checkpointDeadline :: AuthorityTime
checkpointDeadline = authorityTimeFromMicros 2000

checkpointAuthorityScope :: AuthorityScope
checkpointAuthorityScope = mustRight (mkAuthorityScope "home")

checkpointRequestSigner :: RequestSigner
checkpointRequestSigner =
  mustRight
    ( mkRequestSigner
        CallerOperatorCli
        (mustRight (mkSigningKeyGeneration 1))
        (ByteString8.pack "0123456789abcdef0123456789abcdef")
    )

checkpointRequestNonce :: RequestNonce
checkpointRequestNonce =
  mustRight (mkRequestNonce (ByteString8.pack "checkpoint-nonce"))

checkpointCallerSlot :: VerifiedCallerSlot
checkpointCallerSlot =
  verifiedRequestCallerSlot
    ( mustRight
        ( decodeAndVerifyControlPlaneRequest
            65536
            verificationContext
            (encodeSignedControlPlaneRequest signed)
        )
    )
 where
  body = ByteString8.empty
  signed =
    mustRight
      ( signControlPlaneRequest
          checkpointRequestSigner
          LifecyclePulumiCheckpoint
          LifecycleAuthorityRuntime
          checkpointAuthorityScope
          authorityEpochGenesis
          checkpointDeadline
          checkpointRequestNonce
          body
      )
  verificationContext =
    mustRight
      ( mkRequestVerificationContext
          (trustedRequestKeyFromSigner checkpointRequestSigner)
          LifecyclePulumiCheckpoint
          LifecycleAuthorityRuntime
          checkpointAuthorityScope
          authorityEpochGenesis
          checkpointDeadline
          checkpointRequestNonce
          checkpointNow
          checkpointMaximumLifetime
      )

checkpointTrustRegistry :: RouteTrustRegistry
checkpointTrustRegistry =
  mustRight
    ( mkRouteTrustRegistry
        LifecycleAuthorityRuntime
        1
        [ (route, trustedRequestKeyFromSigner checkpointRequestSigner)
        | route <- routesForRole LifecycleAuthorityRuntime
        ]
    )

fromString :: String -> Text
fromString = Text.pack

accepted :: (Show err) => Either err value -> IO value
accepted result = case result of
  Left err -> fail (show err)
  Right value -> pure value

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
