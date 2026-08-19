{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownProviderAwsScopeAdapter
  ( providerAwsScopeAdapterSuite
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (filterM)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (isInfixOf, isSuffixOf, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli, CallerService)
  )
import Prodbox.ControlPlane.Codec (decodeControlPlaneResponse)
import Prodbox.ControlPlane.Coordinate (AuthorityEpoch (..))
import Prodbox.ControlPlane.ProviderAwsScopeReceipt
import Prodbox.ControlPlane.ProviderNarrowSession
  ( ProviderEffectObservation (ProviderEffectUnobservable)
  , ProviderIntentCapabilities (..)
  , ProviderMutation (..)
  , ProviderNarrowSessionRunner (..)
  , ProviderReadOnly (..)
  )
import Prodbox.ControlPlane.ProviderWorkerClient
  ( ProviderWorkerResponse (..)
  , providerWorkerExecutionAuthenticatedHandler
  , providerWorkerResponseMaximumBytes
  )
import Prodbox.ControlPlane.ProviderWorkerExecution
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (ProviderWorkApply)
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (ReplyOk))
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , AuthorityAdmissionCommand (ApplyAuthorityGenesis)
  , AuthorityProviderSettlementDecision (..)
  , AuthorityProviderSubmissionDecision (AuthorityProviderSubmissionAccepted)
  , ProviderOperationCleanupOwner (ProviderOperationUnownedByCleanupRun)
  , initialCleanInstallAuthorityWithRegisteredClients
  , stepAuthorityAdmission
  , stepRegisteredProviderSettlement
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
  )
import Prodbox.Lifecycle.Authority.Submission
  ( OperationId (..)
  , RequestDigest (RequestDigest)
  )
import Prodbox.Lifecycle.Lease
  ( authorityTimeFromMicros
  , mkFencingToken
  , mkOwnerNonce
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderIntentCoordinate
  , ProviderRevision
  , mkProviderRevision
  , mkRegisteredProviderResources
  , providerIntentCoordinate
  , providerIntentCoordinateText
  , providerIntentResourceKey
  , providerRevisionNatural
  )
import Prodbox.Lifecycle.TargetCommitIntent (sha256TargetValueDigest)
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  )
import Prodbox.Lifecycle.Teardown.ProviderAwsScopeAdapter
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime)
  )
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import TestSupport

providerAwsScopeAdapterSuite :: SuiteBuilder ()
providerAwsScopeAdapterSuite =
  describe "Provider AWS-scope proof boundary" $ do
    it "binds canonical STS account and sealed region evidence to the admitted operation" $ do
      executed <- executeScope (Right validEvidence)
      verified <- expectDecoded executed
      verifiedProviderAwsScopeAccountId verified
        `shouldBe` AwsAccountId fixtureAccount
      verifiedProviderAwsScopeRegion verified
        `shouldBe` AwsRegion fixtureRegion
      verifiedProviderAwsScopeRevision verified `shouldBe` providerRevision
      verifiedProviderAwsScopeOperationId verified `shouldBe` fixtureOperation
      verifiedProviderAwsScopeCoordinate verified
        `shouldBe` providerAwsScopeIntentCoordinate

    it "round-trips the additive signed-intent tag without changing its coordinate" $ do
      let signed = signedScopeIntent providerAwsScopeIntent
          encoded = encodeSignedProviderCommittedIntent signed
      decoded <-
        case decodeSignedProviderCommittedIntent providerCommittedIntentMaximumEncodedBytes encoded of
          Left err -> expectationFailure ("scope intent codec failed: " <> show err) >> error "unreachable"
          Right value -> pure value
      admitted <-
        expectAdmitted
          =<< admitProviderCommittedIntent
            providerCommittedIntentMaximumEncodedBytes
            (boundaryWithEvidence (Right validEvidence))
            (encodeSignedProviderCommittedIntent decoded)
      executed <-
        expectExecuted
          =<< executeVerifiedProviderIntentBound
            (boundaryWithEvidence (Right validEvidence))
            admitted
      executedProviderIntentAction executed `shouldBe` ObserveProviderAwsScope
      executedProviderIntentCoordinate executed
        `shouldBe` providerIntentCoordinate ObserveProviderAwsScope
      providerIntentResourceKey ObserveProviderAwsScope
        `shouldBe` providerIntentResourceKey ObserveOperationalIdentity
      providerIntentCoordinate ObserveProviderAwsScope
        `shouldNotBe` providerIntentCoordinate ObserveOperationalIdentity

    it "rejects another closed Provider action before inspecting its evidence" $ do
      executed <-
        expectExecuted
          =<< executeIntent ObserveOperationalIdentity (Right validEvidence)
      case decodeVerifiedProviderAwsScope executed of
        Left (ProviderAwsScopeIntentMismatch actual) ->
          actual `shouldBe` ObserveOperationalIdentity
        Left other -> expectationFailure ("unexpected scope refusal: " <> show other)
        Right _ -> expectationFailure "wrong Provider intent minted AWS-scope proof"

    it "rejects malformed, non-versioned, oversized, and noncanonical evidence" $ do
      mapM_
        assertEvidenceRejected
        [ "not-provider-scope-evidence"
        , "provider-aws-scope-v1:not-base64!"
        , fixtureEvidence 2 fixtureAccount fixtureRegion
        , Text.replicate 513 "x"
        , fixtureEvidence 1 "123" fixtureRegion
        , fixtureEvidence 1 fixtureAccount "CA-CENTRAL-1"
        , nonCanonicalEvidence
        ]

    it "keeps response loss retryable and never mints a scope proof" $ do
      let unavailableBoundary = boundaryWithEvidence (Left "STS response lost")
          recoveredBoundary = boundaryWithEvidence (Right validEvidence)
          exactSignedBytes =
            encodeSignedProviderCommittedIntent
              (signedScopeIntent providerAwsScopeIntent)
      admitted <-
        expectAdmitted
          =<< admitProviderCommittedIntent
            providerCommittedIntentMaximumEncodedBytes
            unavailableBoundary
            exactSignedBytes
      firstAttempt <-
        executeVerifiedProviderIntentBound unavailableBoundary admitted
      case firstAttempt of
        Left (ProviderIntentExecutionReadOnlyUnavailable detail) ->
          detail `shouldBe` "STS response lost"
        Left other -> expectationFailure ("unexpected execution refusal: " <> show other)
        Right _ -> expectationFailure "response loss minted ExecutedProviderIntent"
      recovered <-
        expectExecuted
          =<< executeVerifiedProviderIntentBound recoveredBoundary admitted
      verified <- case decodeVerifiedProviderAwsScope recovered of
        Left err -> expectationFailure ("exact retry was refused: " <> show err) >> error "unreachable"
        Right value -> pure value
      verifiedProviderAwsScopeOperationId verified `shouldBe` fixtureOperation

    it "returns a canonical full receipt over the authenticated Worker boundary" $ do
      result <-
        workerResultAt
          providerRevision
          fixtureOperation
          providerAwsScopeIntent
          (Right validEvidence)
      (coordinate, receipt) <- expectObserved result
      coordinate `shouldBe` providerAwsScopeIntentCoordinate
      Text.length receipt `shouldSatisfy` (<= 1024)
      wire <- expectReceipt receipt
      fixtureReceiptVersion wire `shouldBe` 1
      fixtureReceiptOperation wire `shouldBe` fixtureOperation
      fixtureReceiptRevision wire `shouldBe` providerRevisionNatural providerRevision
      fixtureReceiptCoordinate wire
        `shouldBe` providerIntentCoordinateText providerAwsScopeIntentCoordinate
      fixtureReceiptAccount wire `shouldBe` fixtureAccount
      fixtureReceiptRegion wire `shouldBe` fixtureRegion

    it
      "allows a Pending retry to re-observe at a changed revision but preserves the first durable completion"
      $ do
        let (operation, admitted) = admitScopeOperation
            signedOperation = authorityOperationIdentityText operation
            newerRevision = mustRight (mkProviderRevision 8)
        firstResult <-
          workerResultAt
            providerRevision
            signedOperation
            providerAwsScopeIntent
            (Right validEvidence)
        secondResult <-
          workerResultAt
            newerRevision
            signedOperation
            providerAwsScopeIntent
            (Right validEvidence)
        (_, firstReceipt) <- expectObserved firstResult
        (_, secondReceipt) <- expectObserved secondResult
        firstWire <- expectReceipt firstReceipt
        secondWire <- expectReceipt secondReceipt
        fixtureReceiptRevision firstWire
          `shouldBe` providerRevisionNatural providerRevision
        fixtureReceiptRevision secondWire
          `shouldBe` providerRevisionNatural newerRevision
        firstReceipt `shouldNotBe` secondReceipt
        let (firstDecision, completed) =
              mustRight
                ( stepRegisteredProviderSettlement
                    fixtureCaller
                    fixtureGeneration
                    operation
                    providerAwsScopeIntent
                    firstReceipt
                    admitted
                )
            (differentReplay, afterDifferentReplay) =
              mustRight
                ( stepRegisteredProviderSettlement
                    fixtureCaller
                    fixtureGeneration
                    operation
                    providerAwsScopeIntent
                    secondReceipt
                    completed
                )
            (exactReplay, afterExactReplay) =
              mustRight
                ( stepRegisteredProviderSettlement
                    fixtureCaller
                    fixtureGeneration
                    operation
                    providerAwsScopeIntent
                    firstReceipt
                    completed
                )
        firstDecision `shouldBe` AuthorityProviderSettlementCompleted
        differentReplay
          `shouldBe` AuthorityProviderSettlementRefused
            "provider completion evidence mismatch"
        afterDifferentReplay `shouldBe` completed
        exactReplay
          `shouldBe` AuthorityProviderSettlementAlreadyCompleted firstReceipt
        afterExactReplay `shouldBe` completed

    it "keeps Authority read-back refusal states distinct without exposing a proof factory" $ do
      map show authorityReadBackDiagnostics
        `shouldBe` [ "ProviderAwsScopeAuthorityReadUnavailable \"authority unavailable\""
                   , "ProviderAwsScopeRetainedOperationMissing"
                   , "ProviderAwsScopeRetainedPending"
                   , "ProviderAwsScopeRetainedDigestMismatch"
                   , "ProviderAwsScopeRetainedIntentMismatch"
                   , "ProviderAwsScopeRetainedOperationMismatch"
                   , "ProviderAwsScopeReceiptRevisionInvalid"
                   , "ProviderAwsScopeReceiptCoordinateInvalid"
                   , "ProviderAwsScopeReceiptAccountInvalid"
                   , "ProviderAwsScopeReceiptRegionInvalid"
                   , "ProviderAwsScopeReceiptPrefixInvalid"
                   ]

    it "keeps the executed receipt and scope proof constructors opaque" $ do
      executionSource <-
        readFile "src/Prodbox/ControlPlane/ProviderWorkerExecution.hs"
      adapterSource <-
        readFile "src/Prodbox/Lifecycle/Teardown/ProviderAwsScopeAdapter.hs"
      receiptFacade <-
        readFile "src/Prodbox/ControlPlane/ProviderAwsScopeReceipt.hs"
      receiptInternal <-
        readFile "src/Prodbox/ControlPlane/ProviderAwsScopeReceipt/Internal.hs"
      let executionHeader = unlines (takeWhile (/= "where") (lines executionSource))
          adapterHeader = unlines (takeWhile (/= "where") (lines adapterSource))
      executionHeader `shouldNotContain` "ExecutedProviderIntent (.."
      adapterHeader `shouldNotContain` "VerifiedProviderAwsScope (.."
      receiptFacade `shouldNotContain` "VerifiedAuthorityProviderAwsScope (.."
      receiptFacade `shouldNotContain` "AuthorityProviderAwsScopeReader (.."
      receiptFacade `shouldNotContain` "lifecycleAuthorityProviderAwsScopeReader"
      receiptFacade `shouldNotContain` "AuthorityAdmissionRepository"
      receiptFacade `shouldNotContain` "verifyAuthorityProviderAwsScopeCompletion"
      receiptFacade `shouldNotContain` "providerExecutionResultForAuthority"
      receiptFacade `shouldNotContain` "AuthorityProviderOperation"
      receiptInternal `shouldContain` "AuthorityProviderCompleted"
      receiptInternal `shouldContain` "readAuthorityAdmission repository"
      receiptInternal `shouldContain` "Map.lookup"
      receiptInternal `shouldContain` "lifecycleAuthorityProviderAwsScopeReaderInternal"
      receiptInternal `shouldContain` "operationIdDigest expectedOperation"
      receiptInternal `shouldContain` "ProviderAwsScopeRetainedOperationMismatch"
      adapterSource `shouldNotContain` "AwsScope ("
      adapterSource `shouldNotContain` "encodeProviderAwsScopeEvidence"
      adapterSource `shouldContain` "ProviderIntentExecutionObserved"
      adapterSource `shouldContain` "ProviderAwsScopeCoordinateMismatch"
      cabal <- readFile "prodbox.cabal"
      cabal `shouldContain` "Prodbox.Lifecycle.Teardown.ProviderAwsScopeAdapter.Internal"
      cabal `shouldContain` "Prodbox.ControlPlane.ProviderAwsScopeReceipt.Internal"
      let exposedLibrary =
            unlines
              ( takeWhile
                  (/= "    hs-source-dirs:   src")
                  (lines cabal)
              )
      exposedLibrary
        `shouldNotContain` "Prodbox.Lifecycle.Teardown.ProviderAwsScopeAdapter.Internal"
      exposedLibrary
        `shouldNotContain` "Prodbox.ControlPlane.ProviderAwsScopeReceipt.Internal"
      importers <-
        sourceImportersFor
          "src"
          "import Prodbox.Lifecycle.Teardown.ProviderAwsScopeAdapter.Internal"
      importers
        `shouldBe` [ "src/Prodbox/ControlPlane/ProviderProduction.hs"
                   , "src/Prodbox/Lifecycle/Teardown/ProviderAwsScopeAdapter.hs"
                   ]
      boundExecutionUsers <-
        sourceImportersFor "src" "executeVerifiedProviderIntentBound"
      boundExecutionUsers
        `shouldBe` [ "src/Prodbox/ControlPlane/ProviderWorkerClient.hs"
                   , "src/Prodbox/ControlPlane/ProviderWorkerExecution.hs"
                   ]
      receiptInternalUsers <-
        sourceImportersFor
          "src"
          "import Prodbox.ControlPlane.ProviderAwsScopeReceipt.Internal"
      -- Sprint 4.84 admits the Authority composition root: `Runtime` binds the
      -- package-private reader capability to the retained admission repository
      -- so the registered-stack generation producer can read a Provider
      -- AWS-scope receipt back.  It composes the reader and never decodes a
      -- receipt itself, which is why the minting surface stays closed.
      receiptInternalUsers
        `shouldBe` [ "src/Prodbox/ControlPlane/ProviderAwsScopeReceipt.hs"
                   , "src/Prodbox/ControlPlane/ProviderWorkerClient.hs"
                   , "src/Prodbox/ControlPlane/Runtime.hs"
                   ]
      runtimeSource <- readFile "src/Prodbox/ControlPlane/Runtime.hs"
      runtimeSource `shouldContain` "lifecycleAuthorityProviderAwsScopeReaderInternal"
      runtimeSource `shouldNotContain` "verifyAuthorityProviderAwsScopeCompletion"
      runtimeSource `shouldNotContain` "providerExecutionResultForAuthority"
      creationSource <-
        readFile "src/Prodbox/ControlPlane/AwsStackCreationBindingRepository.hs"
      creationSource `shouldNotContain` "VerifiedProviderAwsScope"
      creationSource `shouldNotContain` "decodeVerifiedProviderAwsScope"

    it "derives production evidence only from successful STS Account plus sealed credentials region" $ do
      productionSource <- readFile "src/Prodbox/ControlPlane/ProviderProduction.hs"
      productionSource `shouldContain` "[\"sts\", \"get-caller-identity\", \"--output\", \"json\"]"
      productionSource `shouldContain` "requireTextField \"Account\""
      productionSource `shouldContain` "productionSessionCredentials session"
      productionSource `shouldContain` "encodeProviderAwsScopeEvidence account (region credentials)"
      productionSource `shouldNotContain` "AWS_DEFAULT_REGION"

assertEvidenceRejected :: Text -> IO ()
assertEvidenceRejected evidence = do
  executed <- executeScope (Right evidence)
  case executed of
    Left err -> expectationFailure ("generic execution rejected bounded evidence early: " <> show err)
    Right bound -> case decodeVerifiedProviderAwsScope bound of
      Left (ProviderAwsScopeEvidenceInvalid _) -> pure ()
      Left other -> expectationFailure ("unexpected scope refusal: " <> show other)
      Right _ -> expectationFailure "invalid evidence minted VerifiedProviderAwsScope"

expectDecoded
  :: Either ProviderIntentExecutionError ExecutedProviderIntent
  -> IO VerifiedProviderAwsScope
expectDecoded executed = do
  bound <- expectExecuted executed
  case decodeVerifiedProviderAwsScope bound of
    Left err -> expectationFailure ("scope evidence was refused: " <> show err) >> error "unreachable"
    Right verified -> pure verified

executeScope
  :: Either Text Text
  -> IO (Either ProviderIntentExecutionError ExecutedProviderIntent)
executeScope = executeIntent providerAwsScopeIntent

executeIntent
  :: ProviderIntent
  -> Either Text Text
  -> IO (Either ProviderIntentExecutionError ExecutedProviderIntent)
executeIntent intent evidence = do
  let boundary = boundaryWithEvidence evidence
  admitted <-
    expectAdmitted
      =<< admitProviderCommittedIntent
        providerCommittedIntentMaximumEncodedBytes
        boundary
        (encodeSignedProviderCommittedIntent (signedScopeIntent intent))
  executeVerifiedProviderIntentBound boundary admitted

workerResultAt
  :: ProviderRevision
  -> Text
  -> ProviderIntent
  -> Either Text Text
  -> IO ProviderIntentExecutionResult
workerResultAt revision operation intent evidence = do
  let boundary = boundaryAt revision evidence
      handler =
        providerWorkerExecutionAuthenticatedHandler
          providerCommittedIntentMaximumEncodedBytes
          boundary
          emptyAuthenticatedHandler
      caller =
        verifiedCallerSlotFixture
          (CallerService LifecycleAuthorityRuntime)
          1
      body =
        encodeSignedProviderCommittedIntent
          (signedScopeIntentAt revision operation intent)
  response <-
    authenticatedHandlerHandle handler caller ProviderWorkApply body
  case response of
    Just (ReplyOk, responseBytes) ->
      case decodeControlPlaneResponse
        providerWorkerResponseMaximumBytes
        (LazyByteString.fromStrict responseBytes) of
        Left err ->
          expectationFailure ("worker response decode failed: " <> show err)
            >> error "unreachable"
        Right (ProviderWorkerExecuted result) -> pure result
        Right other ->
          expectationFailure ("worker returned a refusal: " <> show other)
            >> error "unreachable"
    Just (status, _) ->
      expectationFailure ("worker returned unexpected status: " <> show status)
        >> error "unreachable"
    Nothing ->
      expectationFailure "worker did not own ProviderWorkApply"
        >> error "unreachable"

emptyAuthenticatedHandler :: AuthenticatedRoleHandler IO
emptyAuthenticatedHandler =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = fixtureReadyRoleReadinessSource
    , authenticatedHandlerHandle = \_ _ _ -> pure Nothing
    }

expectObserved
  :: ProviderIntentExecutionResult
  -> IO (ProviderIntentCoordinate, Text)
expectObserved result = case result of
  ProviderIntentExecutionObserved coordinate evidence ->
    pure (coordinate, evidence)
  ProviderIntentExecutionApplied {} ->
    expectationFailure "scope observation returned an applied result"
      >> error "unreachable"
  ProviderIntentExecutionAlreadySatisfied {} ->
    expectationFailure "scope observation returned an already-satisfied result"
      >> error "unreachable"

boundaryWithEvidence
  :: Either Text Text
  -> ProviderWorkerExecutionBoundary IO ()
boundaryWithEvidence = boundaryAt providerRevision

boundaryAt
  :: ProviderRevision
  -> Either Text Text
  -> ProviderWorkerExecutionBoundary IO ()
boundaryAt revision evidence =
  mkProviderWorkerExecutionBoundary
    (ProviderWorkerTrustRepository (pure (Right (acceptedAuthorityAt revision))))
    (pure (Right (authorityTimeFromMicros 100)))
    ( ProviderNarrowSessionRunner
        (\_ _ action -> action Nothing ())
    )
    (capabilities evidence)

capabilities :: Either Text Text -> ProviderIntentCapabilities IO ()
capabilities evidence =
  ProviderIntentCapabilities
    { reconcileRegisteredStackCapability = \_ _ _ -> unavailableMutation
    , destroyRegisteredStackCapability = \_ _ _ -> unavailableMutation
    , observeRegisteredStackCapability = const unavailableReadOnly
    , readBackRegisteredStackCapability = const unavailableReadOnly
    , boundedScratchCheckpointCapability = const unavailableMutation
    , reconcileSesSendingIdentityCapability = const unavailableMutation
    , reconcileSesDkimCapability = const unavailableMutation
    , reconcileSesReceiptRulesCapability = const unavailableMutation
    , reconcileSesCaptureBucketCapability = const unavailableMutation
    , reconcileSesDnsCapability = const unavailableMutation
    , observePublicARecordCapability = const unavailableReadOnly
    , reconcilePublicARecordCapability = const unavailableMutation
    , reapTestEbsVolumesCapability = const unavailableMutation
    , observeTestEbsVolumesCapability = const unavailableReadOnly
    , observeSpotPriceCapability = const unavailableReadOnly
    , observeOperationalIdentityCapability = ProviderReadOnly (\_ _ -> pure evidence)
    , observeProviderAwsScopeCapability = ProviderReadOnly (\_ _ -> pure evidence)
    , observeProviderReadinessCapability = const unavailableReadOnly
    , issueEksClientAuthCapability = const unavailableReadOnly
    , observeEksClusterIdentityCapability = const unavailableReadOnly
    }

unavailableReadOnly :: ProviderReadOnly IO ()
unavailableReadOnly = ProviderReadOnly (\_ _ -> pure (Left "unexpected read-only capability"))

unavailableMutation :: ProviderMutation IO ()
unavailableMutation =
  ProviderMutation
    { observeProviderMutation = \_ _ -> pure (ProviderEffectUnobservable "unexpected mutation")
    , applyProviderMutation = \_ _ -> pure (Left "unexpected mutation")
    }

signedScopeIntent :: ProviderIntent -> SignedProviderCommittedIntent
signedScopeIntent = signedScopeIntentAt providerRevision fixtureOperation

signedScopeIntentAt
  :: ProviderRevision
  -> Text
  -> ProviderIntent
  -> SignedProviderCommittedIntent
signedScopeIntentAt revision operation intent =
  signProviderCommittedIntent
    signingKey
    ( mustRight
        ( mkUnsignedProviderCommittedIntent
            ProviderCommittedIntentSpec
              { providerIntentIssuerGeneration = issuerGeneration
              , providerIntentIssuerIdentity = "lifecycle-authority"
              , providerIntentAuthorityEpoch = AuthorityEpoch 1
              , providerIntentOperationId = operation
              , providerIntentActionIndex = 0
              , providerIntentCommitReceiptDigest =
                  sha256TargetValueDigest "provider-scope-receipt"
              , providerIntentOwnerNonce = mustRight (mkOwnerNonce "provider-scope-owner")
              , providerIntentFencingToken = mustRight (mkFencingToken 1)
              , providerIntentRevision = revision
              , providerIntentAction = intent
              , providerIntentDeadline = authorityTimeFromMicros 10000
              , providerIntentIdempotencyKey = "provider-scope-idempotency"
              , providerIntentExpectedCredentialSession = Nothing
              , providerIntentExpectedAcceptedAuthority = Nothing
              }
        )
    )

acceptedAuthorityAt :: ProviderRevision -> AcceptedProviderAuthority
acceptedAuthorityAt revision =
  mustRight
    ( mkAcceptedProviderAuthority
        issuerGeneration
        "lifecycle-authority"
        (providerIntentSigningPublicKey signingKey)
        (AuthorityEpoch 1)
        (mustRight (mkFencingToken 1))
        revision
        (mkRegisteredProviderResources ["operational-identity"])
    )

signingKey :: ProviderIntentSigningKey
signingKey =
  mustRight
    (mkProviderIntentSigningKey (ByteString.pack [32 .. 63]))

issuerGeneration :: ProviderIssuerKeyGeneration
issuerGeneration = mustRight (mkProviderIssuerKeyGeneration 1)

providerRevision :: ProviderRevision
providerRevision = mustRight (mkProviderRevision 7)

fixtureOperation :: Text
fixtureOperation = Text.replicate 64 "a"

fixtureAccount :: Text
fixtureAccount = "123456789012"

fixtureRegion :: Text
fixtureRegion = "ca-central-1"

validEvidence :: Text
validEvidence = fixtureEvidence 1 fixtureAccount fixtureRegion

data FixtureWireProviderAwsScopeEvidence = FixtureWireProviderAwsScopeEvidence
  { fixtureWireVersion :: !Word16
  , fixtureWireAccount :: !Text
  , fixtureWireRegion :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data FixtureWireProviderAwsScopeReceipt = FixtureWireProviderAwsScopeReceipt
  { fixtureReceiptVersion :: !Word16
  , fixtureReceiptOperation :: !Text
  , fixtureReceiptRevision :: !Natural
  , fixtureReceiptCoordinate :: !Text
  , fixtureReceiptAccount :: !Text
  , fixtureReceiptRegion :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

expectReceipt :: Text -> IO FixtureWireProviderAwsScopeReceipt
expectReceipt receipt = do
  encoded <- case Text.stripPrefix "provider-aws-scope-receipt-v1:" receipt of
    Nothing ->
      expectationFailure "worker scope result did not contain a v1 receipt"
        >> error "unreachable"
    Just value -> pure value
  bytes <- case Base64.decode (TextEncoding.encodeUtf8 encoded) of
    Left err ->
      expectationFailure ("scope receipt base64 failed: " <> err)
        >> error "unreachable"
    Right value -> pure value
  if Base64.encode bytes == TextEncoding.encodeUtf8 encoded
    then pure ()
    else expectationFailure "scope receipt base64 was not canonical"
  wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
    Left err ->
      expectationFailure ("scope receipt CBOR failed: " <> show err)
        >> error "unreachable"
    Right value -> pure value
  LazyByteString.toStrict (serialise wire) `shouldBe` bytes
  pure wire

fixtureEvidence :: Word16 -> Text -> Text -> Text
fixtureEvidence version account region =
  "provider-aws-scope-v1:"
    <> TextEncoding.decodeUtf8
      ( Base64.encode
          ( LazyByteString.toStrict
              ( serialise
                  FixtureWireProviderAwsScopeEvidence
                    { fixtureWireVersion = version
                    , fixtureWireAccount = account
                    , fixtureWireRegion = region
                    }
              )
          )
      )

nonCanonicalEvidence :: Text
nonCanonicalEvidence =
  "provider-aws-scope-v1:"
    <> TextEncoding.decodeUtf8
      ( Base64.encode
          ( LazyByteString.toStrict
              (serialise (FixtureWireProviderAwsScopeEvidence 1 fixtureAccount fixtureRegion))
              <> "\NUL"
          )
      )

admitScopeOperation :: (OperationId, AuthorityAdmissionAggregate)
admitScopeOperation =
  admitOperation
    "provider-aws-scope/fixture"
    providerAwsScopeIntent

admitOperation
  :: Text
  -> ProviderIntent
  -> (OperationId, AuthorityAdmissionAggregate)
admitOperation submissionKeyText intent =
  let digest = RequestDigest (Text.replicate 64 "b")
      submissionKey =
        mustRight (mkClientSubmissionKey submissionKeyText)
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
   in case decision of
        AuthorityProviderSubmissionAccepted operation -> (operation, admitted)
        other -> error ("scope admission failed: " <> show other)

authorityReadBackDiagnostics :: [ProviderAwsScopeReceiptError]
authorityReadBackDiagnostics =
  [ ProviderAwsScopeAuthorityReadUnavailable "authority unavailable"
  , ProviderAwsScopeRetainedOperationMissing
  , ProviderAwsScopeRetainedPending
  , ProviderAwsScopeRetainedDigestMismatch
  , ProviderAwsScopeRetainedIntentMismatch
  , ProviderAwsScopeRetainedOperationMismatch
  , ProviderAwsScopeReceiptRevisionInvalid
  , ProviderAwsScopeReceiptCoordinateInvalid
  , ProviderAwsScopeReceiptAccountInvalid
  , ProviderAwsScopeReceiptRegionInvalid
  , ProviderAwsScopeReceiptPrefixInvalid
  ]

authorityOperationIdentityText :: OperationId -> Text
authorityOperationIdentityText =
  TextEncoding.decodeUtf8
    . hexSha256
    . LazyByteString.toStrict
    . serialise

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
        (BeginGenesisEstablishment (GenesisPlan "scope-genesis" "backup-prefix"))
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

expectAdmitted
  :: Either ProviderIntentAdmissionError VerifiedProviderCommittedIntent
  -> IO VerifiedProviderCommittedIntent
expectAdmitted result = case result of
  Left err -> expectationFailure ("intent admission failed: " <> show err) >> error "unreachable"
  Right verified -> pure verified

expectExecuted
  :: Either ProviderIntentExecutionError ExecutedProviderIntent
  -> IO ExecutedProviderIntent
expectExecuted result = case result of
  Left err -> expectationFailure ("intent execution failed: " <> show err) >> error "unreachable"
  Right executed -> pure executed

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value

sourceImportersFor :: FilePath -> String -> IO [FilePath]
sourceImportersFor root importNeedle = do
  paths <- sourceFiles root
  sort <$> filterM containsImport paths
 where
  containsImport path = do
    contents <- readFile path
    pure (importNeedle `isInfixOf` contents)

sourceFiles :: FilePath -> IO [FilePath]
sourceFiles path = do
  directory <- doesDirectoryExist path
  if directory
    then do
      children <- listDirectory path
      concat <$> mapM (sourceFiles . (path </>)) children
    else pure [path | ".hs" `isSuffixOf` path]
