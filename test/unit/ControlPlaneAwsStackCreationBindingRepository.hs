{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module ControlPlaneAwsStackCreationBindingRepository
  ( controlPlaneAwsStackCreationBindingRepositorySuite
  )
where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft)
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  )
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientProviders (..)
  , AuthenticatedTransportBounds
  , mkAuthenticatedClientTransport
  , mkAuthenticatedTransportBounds
  )
import Prodbox.ControlPlane.AuthenticationRegistry
  ( callerMayCallRoute
  , trustedCallersForRoute
  )
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.ControlPlane.AwsStackCreationBindingEndpoint
import Prodbox.ControlPlane.AwsStackCreationBindingRepository
import Prodbox.ControlPlane.AwsStackCreationBindingTransportClient
  ( lifecycleAuthorityAwsStackCreationBindingAuthenticatedClient
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli, CallerService, CallerTestHarness)
  )
import Prodbox.ControlPlane.Client
  ( controlPlaneClientWithTransport
  , mkLifecycleAuthorityEndpoint
  )
import Prodbox.ControlPlane.Codec
  ( encodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.Coordinate (AuthorityScope, mkAuthorityScope)
import Prodbox.ControlPlane.ProviderAwsScopeReceipt
  ( ProviderAwsScopeReceiptError (ProviderAwsScopeRetainedOperationMissing)
  )
import Prodbox.ControlPlane.RegisteredStackCleanupSelection
  ( RegisteredStackCleanupBoundary (..)
  )
import Prodbox.ControlPlane.RegisteredStackCreationProducer
  ( RegisteredStackCreationBoundary (..)
  )
import Prodbox.ControlPlane.RegisteredStackGenerationRepository
  ( RegisteredStackGenerationRepository (..)
  , StackGenerationCursorRepository (..)
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestNonce
  , RequestSigner
  , localRequestSigningCapability
  , mkRequestNonce
  , mkRequestSigner
  , mkSigningKeyGeneration
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (LifecycleAwsStackCreationBinding)
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..), replyStatusCode)
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , AuthorityAdmissionCommand (ApplyAuthorityGenesis)
  , AuthorityProviderSubmissionDecision (AuthorityProviderSubmissionAccepted)
  , ProviderOperationCleanupOwner (ProviderOperationUnownedByCleanupRun)
  , initialCleanInstallAuthorityWithRegisteredClients
  , stepAuthorityAdmission
  , stepRegisteredProviderSubmission
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( RegisteredClientGeneration
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
  , BackupReceipt (..)
  , GenesisPlan (..)
  , TargetAgentGenerationReceipt (..)
  , authorityEpochGenesis
  )
import Prodbox.Lifecycle.Authority.Submission
  ( OperationId (..)
  , RequestDigest (..)
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  , modelBObjectLogicalName
  )
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeFromMicros)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderRevision
  , ProviderStackConfig
  , ProviderStackRef
  , mkAwsTestProviderStackConfig
  , mkProviderRevision
  , mkProviderStackRef
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Registry
  ( RegisteredIdentity
  , lifecycleRegistryRevision
  , lookupRegisteredIdentity
  , registeredIdentityCoordinateDigest
  )
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime, ProviderWorkerRuntime)
  )
import TestSupport

controlPlaneAwsStackCreationBindingRepositorySuite :: SuiteBuilder ()
controlPlaneAwsStackCreationBindingRepositorySuite =
  describe "Authority AWS stack creation binding repository" $ do
    it "accepts only an exact retained ReconcileRegisteredStack operation" $ do
      fixture <- creationFixture fixtureProviderConfig
      let observed = creationObserved fixture
          operation = creationOperation fixture
      observedAwsStackCreationOperationId observed `shouldBe` operation
      observedAwsStackCreationKey observed `shouldBe` AwsTestKey
      observedAwsStackCreationCoordinateDigest observed
        `shouldBe` registeredIdentityCoordinateDigest (mustIdentity AwsTestKey)
      observedAwsStackCreationRevision observed `shouldBe` fixtureRevision
      observedAwsStackCreationConfig observed `shouldBe` fixtureProviderConfig

      observeAuthorityAwsStackCreationOperation
        (readOnlyAuthorityRepository (creationAggregate fixture))
        fixtureRevision
        operation {operationIdDigest = RequestDigest (Text.replicate 64 "f")}
        `shouldReturnSatisfying` isDigestMismatch
      observeAuthorityAwsStackCreationOperation
        (readOnlyAuthorityRepository (creationAggregate fixture))
        (mustRight (mkProviderRevision 2))
        operation
        `shouldReturnSatisfying` isRevisionMismatch

      (nonReconcileOperation, nonReconcileAggregate) <-
        admitFixtureIntent (ObserveRegisteredStack fixtureStackRef)
      observeAuthorityAwsStackCreationOperation
        (readOnlyAuthorityRepository nonReconcileAggregate)
        fixtureRevision
        nonReconcileOperation
        `shouldReturnSatisfying` isNotReconcile

    it "binds every durable lifecycle dimension and gives each generation an immutable slot" $ do
      fixture <- creationFixture fixtureProviderConfig
      let first =
            mustRight
              (prepareAwsStackCreationBinding (creationObserved fixture) fixtureCreationScope)
          firstIdentity = awsStackCreationBindingIdentity first
          second =
            mustRight
              (prepareAwsStackCreationBinding (creationObserved fixture) otherCreationScope)
          secondIdentity = awsStackCreationBindingIdentity second
      awsStackCreationAuthorityKey firstIdentity `shouldBe` AwsTestKey
      awsStackCreationAuthorityCoordinateDigest firstIdentity
        `shouldBe` registeredIdentityCoordinateDigest (mustIdentity AwsTestKey)
      awsStackCreationAuthoritySurface firstIdentity `shouldBe` Cascade
      awsStackCreationAuthorityRegistryRevision firstIdentity
        `shouldBe` lifecycleRegistryRevision
      awsStackCreationAuthorityRunScope firstIdentity
        `shouldBe` evidenceDurableRunScope fixtureCreationScope
      awsStackCreationAuthorityFoundation firstIdentity
        `shouldBe` evidenceLinuxRke2Foundation fixtureCreationScope
      awsStackCreationAuthorityAwsScope firstIdentity
        `shouldBe` mustAwsScope fixtureCreationScope
      awsStackCreationAuthoritySubmissionKey firstIdentity
        `shouldSatisfy` Text.isPrefixOf "aws-stack-creation-v1-"
      Text.length (awsStackCreationAuthoritySubmissionKey firstIdentity) `shouldBe` 86
      awsStackCreationAuthoritySubmissionKey secondIdentity
        `shouldNotBe` awsStackCreationAuthoritySubmissionKey firstIdentity

      prepareAwsStackCreationBinding
        (creationObserved fixture)
        fixtureCleanupScope
        `shouldSatisfy` isLeft
      let otherFoundation =
            mustRight
              ( prepareAwsStackCreationBinding
                  (creationObserved fixture)
                  ( scopeFor
                      "run/creation-1"
                      "foundation/other"
                      "ca-central-1"
                      ReconcileDesiredPresent
                  )
              )
      awsStackCreationAuthoritySubmissionKey
        (awsStackCreationBindingIdentity otherFoundation)
        `shouldNotBe` awsStackCreationAuthoritySubmissionKey firstIdentity

    it "round-trips canonical identities and re-observes retained admission on every client retry" $ do
      fixture <- creationFixture fixtureProviderConfig
      durable <- newDurableModelB False
      admissionReads <- newIORef 0
      let candidate =
            mustRight
              (prepareAwsStackCreationBinding (creationObserved fixture) fixtureCreationScope)
          identity = awsStackCreationBindingIdentity candidate
          identityBytes = encodeAwsStackCreationAuthorityIdentity identity
          client =
            lifecycleAuthorityAwsStackCreationBindingClient
              (countingAuthorityRepository admissionReads (creationAggregate fixture))
              (durableRepository durable)
      ByteString.length identityBytes
        `shouldSatisfy` (<= maximumAwsStackCreationAuthorityIdentityBytes)
      decodeAwsStackCreationAuthorityIdentity identityBytes `shouldBe` Right identity
      decodeAwsStackCreationAuthorityIdentity (ByteString.snoc identityBytes 0)
        `shouldSatisfy` isLeft
      decodeAwsStackCreationAuthorityIdentity
        (ByteString.replicate (maximumAwsStackCreationAuthorityIdentityBytes + 1) 0)
        `shouldSatisfy` isLeft

      -- The binding-only client ignores the scope-observation operation; the
      -- generation join that consumes it is exercised in
      -- LifecycleTeardownStackGeneration and the producer's own cases.
      attemptAwsStackCreationBindingCommit
        client
        (creationOperation fixture)
        (creationOperation fixture)
        fixtureRevision
        fixtureCreationScope
        `shouldReturn` Right AwsStackCreationCommitCreated
      attemptAwsStackCreationBindingCommit
        client
        (creationOperation fixture)
        (creationOperation fixture)
        fixtureRevision
        fixtureCreationScope
        `shouldReturn` Right AwsStackCreationCommitExactReplay
      readIORef admissionReads `shouldReturn` 2

      attemptAwsStackCreationBindingCommit
        client
        (creationOperation fixture)
        (creationOperation fixture)
        (mustRight (mkProviderRevision 2))
        fixtureCreationScope
        `shouldReturnSatisfying` isRevisionMismatch
      readIORef admissionReads `shouldReturn` 3

      recovered <- readBackAwsStackCreationBindingByIdentity client identity
      assertCommitted fixture recovered
      let otherIdentity =
            awsStackCreationBindingIdentity
              ( mustRight
                  (prepareAwsStackCreationBinding (creationObserved fixture) otherCreationScope)
              )
      confirmCommittedAwsStackCreationBindingBytes
        otherIdentity
        (awsStackCreationBindingBytes candidate)
        `shouldSatisfy` isIdentityMismatch
      confirmCommittedAwsStackCreationBindingReadBack
        identity
        AwsStackCreationReadBackMissing
        `shouldSatisfy` isConfirmationMissing
      confirmCommittedAwsStackCreationBindingReadBack
        identity
        (AwsStackCreationReadBackCorrupt "corrupt")
        `shouldSatisfy` isConfirmationCorrupt
      confirmCommittedAwsStackCreationBindingReadBack
        identity
        (AwsStackCreationReadBackUnobservable (ObservationFailure "unobservable"))
        `shouldSatisfy` isConfirmationUnobservable
      confirmCommittedAwsStackCreationBindingReadBack
        identity
        (AwsStackCreationReadBackUnbounded 2 1)
        `shouldSatisfy` isConfirmationUnbounded

    it "creates, exactly replays after restart, recovers response loss, and never replaces a generation" $ do
      fixture <- creationFixture fixtureProviderConfig
      durable <- newDurableModelB True
      let repository = durableRepository durable
      attempted <-
        commitAwsStackCreationBindingAttempt
          repository
          (creationObserved fixture)
          fixtureCreationScope
      attempted `shouldSatisfy` isResponseLost
      readIORef (durableWrites durable) `shouldReturn` 1

      recovered <-
        independentlyReadBackCommittedAwsStackCreationBinding
          (durableRepository durable)
          AwsTestKey
          fixtureCleanupScope
      assertCommitted fixture recovered

      replayed <-
        commitAwsStackCreationBindingAttempt
          (durableRepository durable)
          (creationObserved fixture)
          fixtureCreationScope
      replayed `shouldBe` Right AwsStackCreationCommitExactReplay

      alternate <- creationFixture alternateProviderConfig
      conflict <-
        commitAwsStackCreationBindingAttempt
          repository
          (creationObserved alternate)
          fixtureCreationScope
      conflict `shouldBe` Right AwsStackCreationCommitConflict

      nextGeneration <-
        commitAwsStackCreationBindingAttempt
          repository
          (creationObserved alternate)
          otherCreationScope
      nextGeneration `shouldBe` Right AwsStackCreationCommitCreated
      readIORef (durableWrites durable) `shouldReturn` 2

    it "keeps missing, unobservable, hostile bytes, and wrong generation fail-closed" $ do
      fixture <- creationFixture fixtureProviderConfig
      let candidate =
            mustRight
              (prepareAwsStackCreationBinding (creationObserved fixture) fixtureCreationScope)
          repository observation =
            AwsStackCreationBindingRepository
              { createOrReplayAwsStackCreationBinding =
                  const (pure AwsStackCreationCommitExactReplay)
              , independentlyReadBackAwsStackCreationBinding = const (pure observation)
              }
      independentlyReadBackCommittedAwsStackCreationBinding
        (repository AwsStackCreationReadBackMissing)
        AwsTestKey
        fixtureCleanupScope
        `shouldReturnSatisfying` isLeft
      independentlyReadBackCommittedAwsStackCreationBinding
        (repository (AwsStackCreationReadBackUnobservable (ObservationFailure "timeout")))
        AwsTestKey
        fixtureCleanupScope
        `shouldReturnSatisfying` isLeft
      independentlyReadBackCommittedAwsStackCreationBinding
        (repository (AwsStackCreationReadBackPresent (awsStackCreationBindingBytes candidate)))
        AwsTestKey
        otherCleanupScope
        `shouldReturnSatisfying` isIdentityMismatch

      decodeModelBValue awsStackCreationBindingModelBCodec ByteString.empty
        `shouldSatisfy` isLeft
      decodeModelBValue
        awsStackCreationBindingModelBCodec
        (ByteString.replicate (maximumAwsStackCreationBindingBytes + 1) 0)
        `shouldSatisfy` isLeft
      decodeModelBValue
        awsStackCreationBindingModelBCodec
        (ByteString.snoc (awsStackCreationBindingBytes candidate) 0)
        `shouldSatisfy` isLeft

    it "refuses a commit whose AWS scope no retained Provider receipt proves" $ do
      -- Sprint 4.84: the endpoint no longer commits only the run-scoped
      -- binding.  It first mints the run-invariant generation, whose account
      -- and region may come only from a Provider AWS-scope receipt the
      -- Authority read back itself.  This aggregate holds the admitted create
      -- and no scope observation, so the commit refuses rather than falling
      -- back to the account and region the request asserted.
      fixture <- creationFixture fixtureProviderConfig
      durable <- newDurableModelB False
      admissionReads <- newIORef 0
      let repository = durableRepository durable
          producer =
            creationBoundaryFor admissionReads fixture repository
          commitRequest =
            awsStackCreationCommitWireRequest
              (creationOperation fixture)
              (creationOperation fixture)
              fixtureRevision
              fixtureCreationScope
      committed <-
        serveAwsStackCreationEndpointRequest
          producer
          unreachableCleanupBoundary
          repository
          (encodeControlPlaneRequest commitRequest)
      awsStackCreationEndpointStatus committed `shouldBe` ReplyBadRequest
      decodeAwsStackCreationEndpointResponse
        (awsStackCreationEndpointBody committed)
        `shouldSatisfy` isScopeUnprovenRefusal

    it "serves independent readback without re-observing Authority admission" $ do
      fixture <- creationFixture fixtureProviderConfig
      durable <- newDurableModelB False
      admissionReads <- newIORef 0
      let repository = durableRepository durable
          producer =
            creationBoundaryFor admissionReads fixture repository
      _ <-
        createOrReplayAwsStackCreationBinding
          repository
          ( mustRight
              ( prepareAwsStackCreationBinding
                  (creationObserved fixture)
                  fixtureCreationScope
              )
          )

      let candidate =
            mustRight
              (prepareAwsStackCreationBinding (creationObserved fixture) fixtureCreationScope)
          identity = awsStackCreationBindingIdentity candidate
      readBack <-
        serveAwsStackCreationEndpointRequest
          producer
          unreachableCleanupBoundary
          repository
          ( encodeControlPlaneRequest
              (awsStackCreationReadBackWireRequest identity)
          )
      awsStackCreationEndpointStatus readBack `shouldBe` ReplyOk
      confirmAwsStackCreationReadBackResponse
        identity
        ( mustRight
            ( decodeAwsStackCreationEndpointResponse
                (awsStackCreationEndpointBody readBack)
            )
        )
        `shouldSatisfy` isRightCommitted
      readIORef admissionReads `shouldReturn` 0

    it "refuses malformed, oversized, and wrong-version requests before admission or storage" $ do
      fixture <- creationFixture fixtureProviderConfig
      durable <- newDurableModelB False
      admissionReads <- newIORef 0
      let repository = durableRepository durable
          producer =
            creationBoundaryFor admissionReads fixture repository
          wrongVersion =
            ( awsStackCreationReadBackWireRequest
                ( awsStackCreationBindingIdentity
                    ( mustRight
                        ( prepareAwsStackCreationBinding
                            (creationObserved fixture)
                            fixtureCreationScope
                        )
                    )
                )
            )
              { awsStackCreationWireRequestVersion =
                  awsStackCreationEndpointFormatVersion + 1
              }
          attempts =
            [
              ( LazyByteString.replicate
                  (fromIntegral awsStackCreationEndpointMaximumBytes + 1)
                  0
              , AwsStackCreationWireRequestTooLarge
              )
            ,
              ( encodeControlPlaneRequest wrongVersion
              , AwsStackCreationWireRequestUnsupportedVersion
              )
            , (LazyByteString.singleton 0, AwsStackCreationWireRequestInvalid)
            ]
      forM_ attempts $ \(request, expectedRefusal) -> do
        result <-
          serveAwsStackCreationEndpointRequest
            producer
            unreachableCleanupBoundary
            repository
            request
        awsStackCreationEndpointStatus result `shouldBe` ReplyBadRequest
        decodeAwsStackCreationEndpointResponse
          (awsStackCreationEndpointBody result)
          `shouldBe` Right
            ( AwsStackCreationWireRefused
                awsStackCreationEndpointFormatVersion
                expectedRefusal
            )
      readIORef admissionReads `shouldReturn` 0
      readIORef (durableWrites durable) `shouldReturn` 0

    it "keeps authenticated transport commit proof-free and creation Missing fail-closed" $ do
      fixture <- creationFixture fixtureProviderConfig
      let candidate =
            mustRight
              (prepareAwsStackCreationBinding (creationObserved fixture) fixtureCreationScope)
          identity = awsStackCreationBindingIdentity candidate
          commitRequest =
            awsStackCreationCommitWireRequest
              (creationOperation fixture)
              (creationOperation fixture)
              fixtureRevision
              fixtureCreationScope
          commitResponse =
            AwsStackCreationWireCommitResult
              awsStackCreationEndpointFormatVersion
              (awsStackCreationWireRequestPayload commitRequest)
              AwsStackCreationWireCommitCreated
      commitClient <- authenticatedCreationClientFor commitResponse
      attemptAwsStackCreationBindingCommit
        commitClient
        (creationOperation fixture)
        (creationOperation fixture)
        fixtureRevision
        fixtureCreationScope
        `shouldReturn` Right AwsStackCreationCommitCreated

      readBackClient <-
        authenticatedCreationClientFor
          ( AwsStackCreationWireReadBackPresent
              awsStackCreationEndpointFormatVersion
              (encodeAwsStackCreationAuthorityIdentity identity)
              (awsStackCreationBindingBytes candidate)
          )
      recovered <- readBackAwsStackCreationBindingByIdentity readBackClient identity
      assertCommitted fixture recovered

      missingClient <-
        authenticatedCreationClientFor
          ( AwsStackCreationWireRefused
              awsStackCreationEndpointFormatVersion
              AwsStackCreationWireReadBackMissing
          )
      readBackAwsStackCreationBindingByIdentity missingClient identity
        `shouldReturnSatisfying` isConfirmationMissing

      trustedCallersForRoute LifecycleAwsStackCreationBinding
        `shouldBe` [ CallerOperatorCli
                   , CallerTestHarness
                   , CallerService LifecycleAuthorityRuntime
                   ]
      callerMayCallRoute
        (CallerService LifecycleAuthorityRuntime)
        LifecycleAwsStackCreationBinding
        `shouldBe` True
      callerMayCallRoute
        (CallerService ProviderWorkerRuntime)
        LifecycleAwsStackCreationBinding
        `shouldBe` False

    it "checks the creation protocol version on every response and cross-kind arm" $ do
      fixture <- creationFixture fixtureProviderConfig
      let candidate =
            mustRight
              (prepareAwsStackCreationBinding (creationObserved fixture) fixtureCreationScope)
          identity = awsStackCreationBindingIdentity candidate
          identityBytes = encodeAwsStackCreationAuthorityIdentity identity
          bindingBytes = awsStackCreationBindingBytes candidate
          commitRequest =
            awsStackCreationCommitWireRequest
              (creationOperation fixture)
              (creationOperation fixture)
              fixtureRevision
              fixtureCreationScope
          requestPayload = awsStackCreationWireRequestPayload commitRequest
          wrongVersion = awsStackCreationEndpointFormatVersion + 1
      forM_
        [ AwsStackCreationWireCommitResult
            wrongVersion
            requestPayload
            AwsStackCreationWireCommitCreated
        , AwsStackCreationWireReadBackPresent wrongVersion identityBytes bindingBytes
        , AwsStackCreationWireRefused wrongVersion AwsStackCreationWireRequestInvalid
        , AwsStackCreationWireUnavailable
            wrongVersion
            (AwsStackCreationWireEndpointUnavailable "unavailable")
        ]
        ( \response ->
            confirmAwsStackCreationCommitResponse requestPayload response
              `shouldSatisfy` isEndpointVersionMismatch
        )
      forM_
        [ AwsStackCreationWireReadBackPresent wrongVersion identityBytes bindingBytes
        , AwsStackCreationWireCommitResult
            wrongVersion
            requestPayload
            AwsStackCreationWireCommitCreated
        , AwsStackCreationWireRefused wrongVersion AwsStackCreationWireRequestInvalid
        , AwsStackCreationWireUnavailable
            wrongVersion
            (AwsStackCreationWireEndpointUnavailable "unavailable")
        ]
        ( \response ->
            confirmAwsStackCreationReadBackResponse identity response
              `shouldSatisfy` isEndpointVersionMismatch
        )

    it "is data-only until an opaque lifecycle/AWS admission proof exists" $ do
      source <- readFile "src/Prodbox/ControlPlane/AwsStackCreationBindingRepository.hs"
      endpointSource <-
        readFile "src/Prodbox/ControlPlane/AwsStackCreationBindingEndpoint.hs"
      source `shouldNotContain` "projectCommittedAwsStackProviderBinding"
      source `shouldNotContain` "mkAwsStackProviderBinding"
      source `shouldNotContain` "AwsRegisteredTargetInterpreter"
      source `shouldNotContain` "KUBECONFIG"
      source `shouldNotContain` "publicIp"
      endpointSource `shouldNotContain` "ObservedAwsStackCreationOperation"
      endpointSource `shouldNotContain` "ProviderStackConfig"
      let forbidden = TextEncoding.encodeUtf8 "sensitive-bearer"
      fixture <- creationFixture fixtureProviderConfig
      let bytes =
            awsStackCreationBindingBytes
              ( mustRight
                  (prepareAwsStackCreationBinding (creationObserved fixture) fixtureCreationScope)
              )
      bytes `shouldSatisfy` (not . ByteString.isInfixOf forbidden)

data CreationFixture = CreationFixture
  { creationOperation :: !OperationId
  , creationAggregate :: !AuthorityAdmissionAggregate
  , creationObserved :: !ObservedAwsStackCreationOperation
  }

creationFixture :: ProviderStackConfig -> IO CreationFixture
creationFixture config =
  creationFixtureWithIntent
    (ReconcileRegisteredStack fixtureStackRef fixtureRevision config)

-- | The Sprint 4.84 producer boundary over this fixture's aggregate and durable
-- store.  The aggregate carries the admitted create and no Provider AWS-scope
-- observation, so the scope read-back refuses — which is the fail-closed
-- property the endpoint cases assert.
creationBoundaryFor
  :: IORef Int
  -> CreationFixture
  -> AwsStackCreationBindingRepository IO
  -> RegisteredStackCreationBoundary IO
creationBoundaryFor admissionReads fixture repository =
  RegisteredStackCreationBoundary
    { registeredStackCreationObserveCreate =
        observeAuthorityAwsStackCreationOperation admission
    , registeredStackCreationProveScope =
        \_ -> pure (Left ProviderAwsScopeRetainedOperationMissing)
    , registeredStackCreationCursors = unreachableCursorRepository
    , registeredStackCreationGenerations = unreachableGenerationRepository
    , registeredStackCreationBindings = repository
    }
 where
  admission = countingAuthorityRepository admissionReads (creationAggregate fixture)

-- | Sprint 4.84: the route also serves cleanup selection now. These cases are
-- about the creating direction, so a selection here would be the defect under
-- test rather than a case that needs a fixture.
unreachableCleanupBoundary :: RegisteredStackCleanupBoundary IO
unreachableCleanupBoundary =
  RegisteredStackCleanupBoundary
    { registeredStackCleanupProveScope =
        \_ -> fail "cleanup selection reached from a creation case"
    , registeredStackCleanupCursors = unreachableCursorRepository
    , registeredStackCleanupGenerations = unreachableGenerationRepository
    }

-- | Reached only if the scope read-back stopped refusing, which would itself be
-- the defect under test.
unreachableCursorRepository :: StackGenerationCursorRepository IO
unreachableCursorRepository =
  StackGenerationCursorRepository
    { observeStackGenerationCursor = \_ -> fail "cursor reached without a proven scope"
    , openStackGenerationCursorSlot = \_ -> fail "cursor reached without a proven scope"
    , advanceStackGenerationCursorSlot = \_ _ -> fail "cursor reached without a proven scope"
    }

unreachableGenerationRepository :: RegisteredStackGenerationRepository IO
unreachableGenerationRepository =
  RegisteredStackGenerationRepository
    { createOrReplayRegisteredStackGeneration =
        \_ -> fail "generation reached without a proven scope"
    , independentlyReadBackRegisteredStackGenerationBytes =
        \_ -> fail "generation reached without a proven scope"
    }

isScopeUnprovenRefusal
  :: Either err AwsStackCreationWireResponse -> Bool
isScopeUnprovenRefusal response = case response of
  Right (AwsStackCreationWireRefused _ (AwsStackCreationWireScopeUnproven _)) ->
    True
  _ -> False

creationFixtureWithIntent :: ProviderIntent -> IO CreationFixture
creationFixtureWithIntent intent = do
  (operation, admitted) <- admitFixtureIntent intent
  observed <-
    mustRightIO
      =<< observeAuthorityAwsStackCreationOperation
        (readOnlyAuthorityRepository admitted)
        fixtureRevision
        operation
  pure
    CreationFixture
      { creationOperation = operation
      , creationAggregate = admitted
      , creationObserved = observed
      }

admitFixtureIntent :: ProviderIntent -> IO (OperationId, AuthorityAdmissionAggregate)
admitFixtureIntent intent = do
  let digest = RequestDigest (Text.replicate 64 "a")
      submissionKey = mustRight (mkClientSubmissionKey "aws-stack-create/fixture")
      (decision, admitted) =
        mustRight
          ( stepRegisteredProviderSubmission
              openedAuthority
              fixtureCaller
              fixtureGeneration
              submissionKey
              digest
              intent
              ProviderOperationUnownedByCleanupRun
          )
  operation <- case decision of
    AuthorityProviderSubmissionAccepted accepted -> pure accepted
    other -> fail ("unexpected provider admission: " <> show other)
  pure (operation, admitted)

readOnlyAuthorityRepository
  :: AuthorityAdmissionAggregate -> AuthorityAdmissionRepository IO Word
readOnlyAuthorityRepository aggregate =
  AuthorityAdmissionRepository
    { readAuthorityAdmission =
        pure
          ( Right
              AuthorityAdmissionSnapshot
                { authorityAdmissionRevision = 1
                , authorityAdmissionSnapshotState = aggregate
                }
          )
    , compareAndSwapAuthorityAdmission = \_ _ ->
        pure (Left "read-only fixture")
    }

countingAuthorityRepository
  :: IORef Int
  -> AuthorityAdmissionAggregate
  -> AuthorityAdmissionRepository IO Word
countingAuthorityRepository readsRef aggregate =
  (readOnlyAuthorityRepository aggregate)
    { readAuthorityAdmission = do
        modifyIORef' readsRef (+ 1)
        readAuthorityAdmission (readOnlyAuthorityRepository aggregate)
    }

openedAuthority :: AuthorityAdmissionAggregate
openedAuthority =
  foldl
    (\aggregate command -> snd (stepAuthorityAdmission aggregate command))
    ( mustRight
        ( initialCleanInstallAuthorityWithRegisteredClients
            8
            16
            fixtureClientTable
        )
    )
    [ ApplyAuthorityGenesis
        (BeginGenesisEstablishment (GenesisPlan "creation-genesis" "backup-prefix"))
    , ApplyAuthorityGenesis
        (ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "target-generation-1"))
    , ApplyAuthorityGenesis
        (ObserveBackupReceipt (BackupReceipt "backup-receipt-1"))
    ]

fixtureClientTable :: RegisteredClientTable
fixtureClientTable =
  mustRight (mkRegisteredClientTable 1 [spec])
 where
  spec =
    mustRight
      ( mkRegisteredClientSpec
          (clientPrincipalForCaller fixtureCaller)
          (mustRight (mkRegisteredClientSlot 1))
          fixtureGeneration
          16
      )

fixtureCaller :: CallerPrincipal
fixtureCaller = CallerOperatorCli

fixtureGeneration :: RegisteredClientGeneration
fixtureGeneration = mustRight (mkRegisteredClientGeneration 1)

fixtureStackRef :: ProviderStackRef
fixtureStackRef = mustRight (mkProviderStackRef "aws-test")

fixtureRevision :: ProviderRevision
fixtureRevision = mustRight (mkProviderRevision 1)

fixtureProviderConfig, alternateProviderConfig :: ProviderStackConfig
fixtureProviderConfig = mustRight (mkAwsTestProviderStackConfig "192.0.2.10/32")
alternateProviderConfig = mustRight (mkAwsTestProviderStackConfig "192.0.2.11/32")

fixtureCreationScope
  , fixtureCleanupScope
  , otherCreationScope
  , otherCleanupScope
    :: ObservationEvidenceScope
fixtureCreationScope =
  scopeFor "run/creation-1" "foundation/home" "ca-central-1" ReconcileDesiredPresent
fixtureCleanupScope =
  scopeFor "run/creation-1" "foundation/home" "ca-central-1" ReconcileDesiredAbsent
otherCreationScope =
  scopeFor "run/creation-2" "foundation/home" "ca-central-1" ReconcileDesiredPresent
otherCleanupScope =
  scopeFor "run/creation-2" "foundation/home" "ca-central-1" ReconcileDesiredAbsent

scopeFor :: Text -> Text -> Text -> LifecycleOperation -> ObservationEvidenceScope
scopeFor runScope foundation region operation =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope runScope)
    (LinuxRke2FoundationId foundation)
    (Just (AwsScope (AwsAccountId "111122223333") (AwsRegion region)))
    operation

mustAwsScope :: ObservationEvidenceScope -> AwsScope
mustAwsScope scope = case evidenceAwsScope scope of
  Just awsScope -> awsScope
  Nothing -> error "fixture AWS scope is missing"

data DurableModelB = DurableModelB
  { durableAdapter :: !(ModelBCasAdapter 'ClusterRetained IO ByteString)
  , durableWrites :: !(IORef Int)
  }

newDurableModelB :: Bool -> IO DurableModelB
newDurableModelB loseFirstResponse = do
  valuesRef <- newIORef Map.empty
  writesRef <- newIORef 0
  loseRef <- newIORef loseFirstResponse
  let compareAndSwap request = case request of
        ModelBInitialize coordinate bytes -> do
          let key = modelBObjectLogicalName coordinate
          values <- readIORef valuesRef
          case Map.lookup key values of
            Just (version, existing) ->
              pure (ModelBCasConflict (ModelBObserved version existing))
            Nothing -> do
              modifyIORef'
                valuesRef
                (Map.insert key (fixtureModelBVersion, bytes))
              modifyIORef' writesRef (+ 1)
              lose <- atomicModifyIORef' loseRef (False,)
              pure $
                if lose
                  then ModelBCasUnobservable "response lost after apply"
                  else ModelBCasApplied fixtureModelBVersion bytes
        ModelBReplace {} -> unexpected "replace"
        ModelBInitializeGuarded {} -> unexpected "guarded initialize"
        ModelBReplaceGuarded {} -> unexpected "guarded replace"
      adapter =
        ModelBCasAdapter
          { modelBObserve = \coordinate -> do
              values <- readIORef valuesRef
              pure $ case Map.lookup (modelBObjectLogicalName coordinate) values of
                Nothing -> ModelBMissing
                Just (version, bytes) -> ModelBObserved version bytes
          , modelBCompareAndSwap = compareAndSwap
          }
  pure (DurableModelB adapter writesRef)
 where
  unexpected name = pure (ModelBCasUnobservable ("unexpected " <> name))

durableRepository :: DurableModelB -> AwsStackCreationBindingRepository IO
durableRepository durable =
  modelBAwsStackCreationBindingRepository fixtureAuthority (durableAdapter durable)

fixtureAuthority :: LongLivedCheckpointAuthority
fixtureAuthority =
  mustRight
    ( mkLongLivedCheckpointAuthority
        "home-linux-rke2"
        "prodbox-authority"
        "authority"
        "secret/lifecycle"
    )

fixtureModelBVersion :: ModelBObjectVersion
fixtureModelBVersion = mustRight (mkModelBObjectVersion "creation-version-1")

authenticatedCreationClientFor
  :: AwsStackCreationWireResponse
  -> IO (AwsStackCreationBindingClient IO)
authenticatedCreationClientFor response = do
  endpoint <-
    mustRightIO
      (mkLifecycleAuthorityEndpoint "http://lifecycle-authority:8600")
  rawClient <-
    mustRightIO
      ( controlPlaneClientWithTransport
          awsStackCreationEndpointResponseMaximumBytes
          endpoint
          ( \method _ url _ -> do
              method `shouldBe` "POST"
              url
                `shouldBe` "http://lifecycle-authority:8600/v1/authority/aws-stack-creation-binding"
              pure
                ( Right
                    ( replyStatusCode
                        (awsStackCreationWireResponseStatus response)
                    , LazyByteString.toStrict
                        (encodeControlPlaneResponse response)
                    )
                )
          )
      )
  pure
    ( lifecycleAuthorityAwsStackCreationBindingAuthenticatedClient
        ( mkAuthenticatedClientTransport
            creationTransportBounds
            creationClientProviders
            rawClient
        )
    )

creationTransportBounds :: AuthenticatedTransportBounds
creationTransportBounds =
  mustRight (mkAuthenticatedTransportBounds (256 * 1024) 256 (250 * 1024))

creationClientProviders :: AuthenticatedClientProviders IO
creationClientProviders =
  AuthenticatedClientProviders
    { provideAuthenticatedClientSigner =
        pure (Right (localRequestSigningCapability creationRequestSigner))
    , provideAuthenticatedClientScope = pure (Right creationAuthorityScope)
    , provideAuthenticatedClientEpoch = pure (Right authorityEpochGenesis)
    , provideAuthenticatedClientDeadline = pure (Right creationDeadline)
    , provideAuthenticatedClientNonce = pure (Right creationRequestNonce)
    }

creationRequestSigner :: RequestSigner
creationRequestSigner =
  mustRight
    ( mkRequestSigner
        (CallerService LifecycleAuthorityRuntime)
        (mustRight (mkSigningKeyGeneration 1))
        (ByteString.pack [0 .. 31])
    )

creationRequestNonce :: RequestNonce
creationRequestNonce = mustRight (mkRequestNonce (ByteString.pack [32 .. 47]))

creationAuthorityScope :: AuthorityScope
creationAuthorityScope = mustRight (mkAuthorityScope "cluster-a")

creationDeadline :: AuthorityTime
creationDeadline = authorityTimeFromMicros 2000

assertCommitted
  :: CreationFixture
  -> Either AwsStackCreationBindingError CommittedAwsStackCreationBinding
  -> Expectation
assertCommitted fixture result = case result of
  Left err -> expectationFailure (show err)
  Right committed -> do
    committedAwsStackCreationOperationId committed `shouldBe` creationOperation fixture
    committedAwsStackCreationRevision committed `shouldBe` fixtureRevision
    committedAwsStackCreationConfig committed `shouldBe` fixtureProviderConfig

isRightCommitted
  :: Either
       AwsStackCreationEndpointResponseError
       CommittedAwsStackCreationBinding
  -> Bool
isRightCommitted result = case result of
  Right _ -> True
  Left _ -> False

isEndpointVersionMismatch :: Either AwsStackCreationEndpointResponseError value -> Bool
isEndpointVersionMismatch result = case result of
  Left AwsStackCreationEndpointResponseVersionMismatch {} -> True
  _ -> False

isDigestMismatch
  :: Either AwsStackCreationBindingError ObservedAwsStackCreationOperation -> Bool
isDigestMismatch result = case result of
  Left AwsStackCreationOperationDigestMismatch {} -> True
  _ -> False

isRevisionMismatch
  :: Either AwsStackCreationBindingError value -> Bool
isRevisionMismatch result = case result of
  Left AwsStackCreationProviderRevisionMismatch {} -> True
  _ -> False

isNotReconcile
  :: Either AwsStackCreationBindingError ObservedAwsStackCreationOperation -> Bool
isNotReconcile result = case result of
  Left AwsStackCreationOperationNotReconcile {} -> True
  _ -> False

isIdentityMismatch
  :: Either AwsStackCreationBindingError CommittedAwsStackCreationBinding -> Bool
isIdentityMismatch result = case result of
  Left AwsStackCreationIdentityMismatch {} -> True
  _ -> False

isConfirmationMissing
  :: Either AwsStackCreationBindingError CommittedAwsStackCreationBinding -> Bool
isConfirmationMissing result = case result of
  Left AwsStackCreationConfirmationMissing -> True
  _ -> False

isConfirmationCorrupt
  :: Either AwsStackCreationBindingError CommittedAwsStackCreationBinding -> Bool
isConfirmationCorrupt result = case result of
  Left AwsStackCreationConfirmationCorrupt {} -> True
  _ -> False

isConfirmationUnobservable
  :: Either AwsStackCreationBindingError CommittedAwsStackCreationBinding -> Bool
isConfirmationUnobservable result = case result of
  Left AwsStackCreationConfirmationUnobservable {} -> True
  _ -> False

isConfirmationUnbounded
  :: Either AwsStackCreationBindingError CommittedAwsStackCreationBinding -> Bool
isConfirmationUnbounded result = case result of
  Left AwsStackCreationConfirmationUnbounded {} -> True
  _ -> False

isResponseLost
  :: Either AwsStackCreationBindingError AwsStackCreationCommitResult -> Bool
isResponseLost result = case result of
  Right AwsStackCreationCommitResponseLost {} -> True
  _ -> False

shouldReturnSatisfying :: IO value -> (value -> Bool) -> Expectation
shouldReturnSatisfying action predicate = do
  value <- action
  value `shouldSatisfy` predicate

mustIdentity :: RegisteredResourceKey -> RegisteredIdentity
mustIdentity key = case lookupRegisteredIdentity key of
  Nothing -> error ("missing registered identity: " <> show key)
  Just identity -> identity

mustRightIO :: (Show err) => Either err value -> IO value
mustRightIO result = case result of
  Left err -> fail (show err)
  Right value -> pure value

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
