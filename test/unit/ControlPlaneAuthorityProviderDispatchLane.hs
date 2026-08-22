{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.36: the Provider dispatch route admits and executes on separate
-- lanes.
--
-- Admission and execution were already two transitions over the retained
-- aggregate, and the route ran both in one call.  A caller therefore could not
-- obtain the admitted 'OperationId' before the effect happened — which is why
-- the registered-stack create lane had to commit the lifecycle generation that
-- names a stack's cycle /after/ the stack existed, and why an Authority that
-- became unreachable in between left a stack no later cleanup run could
-- address.
--
-- These cases measure the property that fixes it: an admit-only dispatch
-- reaches the Provider Worker zero times and still names its operation, and the
-- execute lane on the same submission key runs it exactly once.
module ControlPlaneAuthorityProviderDispatchLane
  ( controlPlaneAuthorityProviderDispatchLaneSuite
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Word (Word16)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
  )
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.ControlPlane.AuthorityProviderEndpoint
  ( AuthorityProviderDispatchBoundary (..)
  , ProviderDispatchLane (ProviderAdmitAndExecute, ProviderAdmitOnly)
  , ProviderDispatchPayload (..)
  , ProviderDispatchResponse (..)
  , authorityProviderDispatchAuthenticatedHandler
  , providerDispatchFormatVersion
  , providerDispatchResponseMaximumBytes
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli, CallerService)
  )
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.Coordinate (AuthorityScope, mkAuthorityScope)
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (ProviderIntentExecutionObserved)
  )
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
import Prodbox.ControlPlane.RoleReadiness (noRoleReadinessContribution)
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (LifecycleProviderDispatch)
  )
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , AuthorityAdmissionCommand (ApplyAuthorityGenesis)
  , ProviderOperationCleanupOwner (ProviderOperationUnownedByCleanupRun)
  , initialCleanInstallAuthorityWithRegisteredClients
  , stepAuthorityAdmission
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( RegisteredClientGeneration
  , RegisteredClientTable
  , clientPrincipalForCaller
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
import Prodbox.Lifecycle.Authority.Submission (OperationId)
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , authorityDurationFromMicros
  , authorityTimeFromMicros
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (ObserveProviderAwsScope)
  , ProviderRevision
  , mkProviderRevision
  , providerIntentCoordinate
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import TestSupport

controlPlaneAuthorityProviderDispatchLaneSuite :: SuiteBuilder ()
controlPlaneAuthorityProviderDispatchLaneSuite =
  describe "Sprint 7.36 Provider dispatch admission/execution lanes" $ do
    -- The whole point. A caller that must bind durable state to the operation
    -- before its effect happens can now obtain the operation with nothing
    -- executed.
    it "admits without reaching the Provider Worker, and names the operation" $ do
      fixture <- newDispatchFixture
      response <- dispatch fixture ProviderAdmitOnly
      admitted <- expectAdmitted response
      executions <- readIORef (fixtureWorkerCalls fixture)
      executions `shouldBe` 0
      -- The operation exists and is nameable, which is the fact the old lane
      -- could not produce before the effect: a second admission at the same key
      -- answers with the same operation.
      repeated <- expectAdmitted =<< dispatch fixture ProviderAdmitOnly
      repeated `shouldBe` admitted

    it "executes the same operation on a second call at the same key" $ do
      fixture <- newDispatchFixture
      admitted <- expectAdmitted =<< dispatch fixture ProviderAdmitOnly
      completed <- expectCompleted =<< dispatch fixture ProviderAdmitAndExecute
      fst completed `shouldBe` admitted
      snd completed `shouldBe` "scope-evidence"
      executions <- readIORef (fixtureWorkerCalls fixture)
      executions `shouldBe` 1

    -- Re-admitting is not a second effect: the ledger recognizes the retry as
    -- the operation it already admitted, so a lost admission response is safe
    -- to repeat.
    it "keeps a repeated admission free of any execution" $ do
      fixture <- newDispatchFixture
      firstAdmission <- expectAdmitted =<< dispatch fixture ProviderAdmitOnly
      secondAdmission <- expectAdmitted =<< dispatch fixture ProviderAdmitOnly
      secondAdmission `shouldBe` firstAdmission
      executions <- readIORef (fixtureWorkerCalls fixture)
      executions `shouldBe` 0

    -- The historical lane is unchanged, so every caller that never separated
    -- the two steps still admits and executes in one call.
    it "still admits and executes in one call on the execute lane" $ do
      fixture <- newDispatchFixture
      completed <- expectCompleted =<< dispatch fixture ProviderAdmitAndExecute
      snd completed `shouldBe` "scope-evidence"
      executions <- readIORef (fixtureWorkerCalls fixture)
      executions `shouldBe` 1

    -- A payload at the previous version carries no lane at all, and the only
    -- default a handler could pick for a missing one is to execute. The version
    -- refusal is what keeps that from happening silently.
    it "refuses a payload at the superseded format version" $ do
      fixture <- newDispatchFixture
      response <- dispatchAtVersion fixture (providerDispatchFormatVersion - 1) ProviderAdmitOnly
      response `shouldSatisfy` isRefused
      executions <- readIORef (fixtureWorkerCalls fixture)
      executions `shouldBe` 0
 where
  isRefused response = case response of
    ProviderDispatchRefused _ -> True
    _ -> False

-- ---------------------------------------------------------------------------
-- The fixture
-- ---------------------------------------------------------------------------

data DispatchFixture = DispatchFixture
  { fixtureAggregate :: !(IORef (Word, AuthorityAdmissionAggregate))
  , fixtureWorkerCalls :: !(IORef Word)
  }

newDispatchFixture :: IO DispatchFixture
newDispatchFixture = do
  aggregate <- newIORef (0, openedAuthority)
  calls <- newIORef 0
  pure
    DispatchFixture
      { fixtureAggregate = aggregate
      , fixtureWorkerCalls = calls
      }

dispatch :: DispatchFixture -> ProviderDispatchLane -> IO ProviderDispatchResponse
dispatch fixture = dispatchAtVersion fixture providerDispatchFormatVersion

dispatchAtVersion
  :: DispatchFixture
  -> Word16Version
  -> ProviderDispatchLane
  -> IO ProviderDispatchResponse
dispatchAtVersion fixture version lane = do
  handled <-
    authenticatedHandlerHandle
      (dispatchHandler fixture)
      dispatchCallerSlot
      LifecycleProviderDispatch
      (payloadBytes version lane)
  case handled of
    Nothing -> failWith "the dispatch route was not owned by its own handler"
    Just (_status, body) ->
      case decodeControlPlaneResponse
        providerDispatchResponseMaximumBytes
        (LazyByteString.fromStrict body) of
        Left err -> failWith ("dispatch response did not decode: " <> show err)
        Right response -> pure response

type Word16Version = Word16

dispatchHandler :: DispatchFixture -> AuthenticatedRoleHandler IO
dispatchHandler fixture =
  authorityProviderDispatchAuthenticatedHandler
    providerDispatchResponseMaximumBytes
    (dispatchBoundary fixture)
    unownedFallbackHandler

dispatchBoundary :: DispatchFixture -> AuthorityProviderDispatchBoundary IO Word
dispatchBoundary fixture =
  AuthorityProviderDispatchBoundary
    { authorityProviderAdmissionRepository = admissionRepository fixture
    , authorityProviderSigningCapability =
        localRequestSigningCapability authoritySigningSigner
    , authorityProviderNow = pure (Right dispatchNow)
    , authorityProviderIntentLifetime = dispatchIntentLifetime
    , authorityProviderRevision = pure (Right dispatchProviderRevision)
    , authorityProviderWorkerDispatch = \_bytes -> do
        modifyIORef' (fixtureWorkerCalls fixture) (+ 1)
        pure
          ( Right
              ( ProviderIntentExecutionObserved
                  (providerIntentCoordinate dispatchIntent)
                  "scope-evidence"
              )
          )
    }

admissionRepository :: DispatchFixture -> AuthorityAdmissionRepository IO Word
admissionRepository fixture =
  AuthorityAdmissionRepository
    { readAuthorityAdmission = do
        (revision, aggregate) <- readIORef (fixtureAggregate fixture)
        pure
          ( Right
              AuthorityAdmissionSnapshot
                { authorityAdmissionRevision = revision
                , authorityAdmissionSnapshotState = aggregate
                }
          )
    , compareAndSwapAuthorityAdmission = \expected next -> do
        (revision, _current) <- readIORef (fixtureAggregate fixture)
        if expected /= revision
          then pure (Left "stale aggregate revision")
          else do
            writeIORef (fixtureAggregate fixture) (revision + 1, next)
            pure (Right ())
    }

unownedFallbackHandler :: AuthenticatedRoleHandler IO
unownedFallbackHandler =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = noRoleReadinessContribution
    , authenticatedHandlerHandle = \_ _ _ -> pure Nothing
    }

payloadBytes :: Word16Version -> ProviderDispatchLane -> ByteString
payloadBytes version lane =
  LazyByteString.toStrict
    ( encodeControlPlaneRequest
        ProviderDispatchPayload
          { providerDispatchVersion = version
          , providerDispatchSubmissionKey = "dispatch-lane-key"
          , providerDispatchIntent = dispatchIntent
          , providerDispatchCleanupOwner = ProviderOperationUnownedByCleanupRun
          , providerDispatchLane = lane
          }
    )

dispatchIntent :: ProviderIntent
dispatchIntent = ObserveProviderAwsScope

expectAdmitted :: ProviderDispatchResponse -> IO OperationId
expectAdmitted response = case response of
  ProviderDispatchAdmitted operation -> pure operation
  other -> failWith ("expected an admission, got " <> show other)

expectCompleted :: ProviderDispatchResponse -> IO (OperationId, Text)
expectCompleted response = case response of
  ProviderDispatchCompleted operation evidence -> pure (operation, evidence)
  ProviderDispatchAlreadyCompleted operation evidence -> pure (operation, evidence)
  other -> failWith ("expected a completion, got " <> show other)

failWith :: String -> IO value
failWith detail = expectationFailure detail >> error "unreachable"

-- ---------------------------------------------------------------------------
-- The authenticated caller
-- ---------------------------------------------------------------------------

openedAuthority :: AuthorityAdmissionAggregate
openedAuthority =
  foldl
    (\aggregate command -> snd (stepAuthorityAdmission aggregate command))
    ( mustRight
        ( initialCleanInstallAuthorityWithRegisteredClients
            8
            16
            dispatchClientTable
        )
    )
    [ ApplyAuthorityGenesis
        (BeginGenesisEstablishment (GenesisPlan "dispatch-genesis" "backup-prefix"))
    , ApplyAuthorityGenesis
        (ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "target-generation-1"))
    , ApplyAuthorityGenesis
        (ObserveBackupReceipt (BackupReceipt "backup-receipt-1"))
    ]

dispatchClientTable :: RegisteredClientTable
dispatchClientTable =
  mustRight (mkRegisteredClientTable 1 [spec])
 where
  spec =
    mustRight
      ( mkRegisteredClientSpec
          (clientPrincipalForCaller CallerOperatorCli)
          (mustRight (mkRegisteredClientSlot 1))
          dispatchClientGeneration
          16
      )

dispatchClientGeneration :: RegisteredClientGeneration
dispatchClientGeneration = mustRight (mkRegisteredClientGeneration 1)

dispatchProviderRevision :: ProviderRevision
dispatchProviderRevision = mustRight (mkProviderRevision 1)

dispatchNow :: AuthorityTime
dispatchNow = authorityTimeFromMicros 1000

dispatchDeadline :: AuthorityTime
dispatchDeadline = authorityTimeFromMicros 2000

dispatchIntentLifetime :: AuthorityDuration
dispatchIntentLifetime = mustRight (authorityDurationFromMicros 5000)

dispatchMaximumLifetime :: AuthorityDuration
dispatchMaximumLifetime = mustRight (authorityDurationFromMicros 5000)

dispatchAuthorityScope :: AuthorityScope
dispatchAuthorityScope = mustRight (mkAuthorityScope "home")

dispatchRequestSigner :: RequestSigner
dispatchRequestSigner =
  mustRight
    ( mkRequestSigner
        CallerOperatorCli
        (mustRight (mkSigningKeyGeneration 1))
        (ByteString8.pack "0123456789abcdef0123456789abcdef")
    )

-- | The Authority signs the committed intent as itself, never as the caller.
-- 'signProviderCommittedIntentWith' refuses any other principal, which is what
-- binds the inner Provider authorization to the same identity the worker's
-- outer authenticated route trusts.
authoritySigningSigner :: RequestSigner
authoritySigningSigner =
  mustRight
    ( mkRequestSigner
        (CallerService LifecycleAuthorityRuntime)
        (mustRight (mkSigningKeyGeneration 1))
        (ByteString8.pack "abcdef0123456789abcdef0123456789")
    )

dispatchRequestNonce :: RequestNonce
dispatchRequestNonce =
  mustRight (mkRequestNonce (ByteString8.pack "dispatch-lane-nonce"))

dispatchCallerSlot :: VerifiedCallerSlot
dispatchCallerSlot =
  verifiedRequestCallerSlot
    ( mustRight
        ( decodeAndVerifyControlPlaneRequest
            65536
            verificationContext
            (encodeSignedControlPlaneRequest signed)
        )
    )
 where
  signed =
    mustRight
      ( signControlPlaneRequest
          dispatchRequestSigner
          LifecycleProviderDispatch
          LifecycleAuthorityRuntime
          dispatchAuthorityScope
          authorityEpochGenesis
          dispatchDeadline
          dispatchRequestNonce
          ByteString8.empty
      )
  verificationContext =
    mustRight
      ( mkRequestVerificationContext
          (trustedRequestKeyFromSigner dispatchRequestSigner)
          LifecycleProviderDispatch
          LifecycleAuthorityRuntime
          dispatchAuthorityScope
          authorityEpochGenesis
          dispatchDeadline
          dispatchRequestNonce
          dispatchNow
          dispatchMaximumLifetime
      )

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
