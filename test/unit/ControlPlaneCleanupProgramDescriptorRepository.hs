{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}

module ControlPlaneCleanupProgramDescriptorRepository
  ( controlPlaneCleanupProgramDescriptorRepositorySuite
  )
where

import Codec.CBOR.Read (deserialiseFromBytes)
import Codec.CBOR.Term (Term (..), decodeTerm, encodeTerm)
import Codec.CBOR.Write (toLazyByteString)
import Codec.Serialise (Serialise, serialise)
import Control.Monad (filterM, forM_)
import Data.Aeson (FromJSON (..), eitherDecodeStrict', withObject, (.:))
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, isPrefixOf, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)
import Network.HTTP.Types.Header (Header)
import Network.HTTP.Types.Method (Method)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientProviders (..)
  , AuthenticatedTransportBounds
  , mkAuthenticatedClientTransport
  , mkAuthenticatedTransportBounds
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli)
  )
import Prodbox.ControlPlane.CleanupProgramDescriptorRepository
import Prodbox.ControlPlane.CleanupRunClient
  ( DescriptorBoundCleanupRun
  , DescriptorBoundCleanupRunClient (..)
  , descriptorBoundCleanupRunClient
  , descriptorBoundCleanupRunDescriptorDigest
  , descriptorBoundCleanupRunGraphDigest
  , descriptorBoundCleanupRunId
  , withDescriptorBoundCleanupProgram
  )
import Prodbox.ControlPlane.CleanupRunEndpoint
  ( CleanupRunDescriptorCommand (CleanupRunDescriptorRecordPrimary)
  , CleanupRunDescriptorRefusal (..)
  , CleanupRunDescriptorResponse (..)
  , CleanupRunEndpointResult (CleanupRunEndpointDescriptorBound)
  , cleanupRunDescriptorMutationAckMaximumBytes
  , cleanupRunEndpointBody
  , cleanupRunEndpointStatus
  , cleanupRunMaximumBytes
  , compactDescriptorTransitionResponse
  , decodeCleanupRunDescriptorResponse
  , encodeCleanupRunDescriptorResponse
  )
import Prodbox.ControlPlane.Client
  ( controlPlaneClientWithTransport
  , mkLifecycleAuthorityEndpoint
  )
import Prodbox.ControlPlane.Coordinate
  ( AuthorityScope
  , mkAuthorityScope
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestNonce
  , RequestSigner
  , localRequestSigningCapability
  , mkRequestNonce
  , mkRequestSigner
  , mkSigningKeyGeneration
  )
import Prodbox.Http.Client (HttpBoundedError)
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.CleanupRunRunner
  ( CleanupNodeExecutionContext
  , cleanupNodeExecutionGraphDigest
  , cleanupNodeExecutionNodeId
  , cleanupNodeExecutionRunId
  , descriptorBoundCleanupNodeAction
  , descriptorBoundCleanupNodeExecutionContext
  )
import Prodbox.Lifecycle.DnsRecord (HostedZoneId, mkHostedZoneId)
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  )
import Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Program (someTeardownOperationTag)
import Prodbox.Lifecycle.Teardown.Registry
  ( cleanupTargetKey
  , cleanupTargetsForSurface
  , lifecycleRegistryRevision
  )
import Prodbox.Lifecycle.Teardown.ResourceScopeBindings
import Prodbox.Settings.Coordinate (mkS3BucketName)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import TestSupport

controlPlaneCleanupProgramDescriptorRepositorySuite :: SuiteBuilder ()
controlPlaneCleanupProgramDescriptorRepositorySuite =
  describe "Authority cleanup-program descriptor repository" $ do
    it "captures every closed surface only from its exact initial compiled run" $ do
      let checkSurface (SurfaceCase witness expectedSurface maybeAwsScope) =
            case descriptorFixture witness fixtureRunId fixtureFoundation maybeAwsScope of
              Left detail -> expectationFailure (Text.unpack detail)
              Right (compiled, initialRun, descriptor) -> do
                cleanupProgramDescriptorRunId descriptor `shouldBe` fixtureRunId
                cleanupProgramDescriptorSurface descriptor `shouldBe` expectedSurface
                cleanupProgramDescriptorFoundation descriptor `shouldBe` fixtureFoundation
                cleanupProgramDescriptorAwsScope descriptor `shouldBe` maybeAwsScope
                cleanupProgramDescriptorAwsDnsZone descriptor `shouldBe` Nothing
                cleanupProgramDescriptorRegistryRevision descriptor
                  `shouldBe` lifecycleRegistryRevision
                cleanupProgramDescriptorLifecycleOperation descriptor
                  `shouldBe` ReconcileDesiredAbsent
                cleanupProgramDescriptorGraphDigest descriptor
                  `shouldBe` cleanupRunGraphDigest initialRun
                cleanupProgramDescriptorCapabilityCatalogDigest descriptor
                  `shouldBe` compiledDesiredAbsenceRecoveryCapabilityCatalogDigest compiled
                cleanupProgramDescriptorOperationIdentityVersion
                  `shouldBe` "lifecycle-cleanup-operation/v3"
                cleanupProgramDescriptorCompilerVersion
                  `shouldBe` "lifecycle-desired-absence-program-compiler/v7"
                cleanupProgramDescriptorCapabilityCatalogVersion
                  `shouldBe` "lifecycle-recovery-capability-catalog/v1"
                cleanupProgramDescriptorCapabilitySetVersion
                  `shouldBe` "lifecycle-recovery-capability-set/v1"
                ByteString.length (cleanupProgramDescriptorBytes descriptor)
                  `shouldSatisfy` (<= maximumCleanupProgramDescriptorBytes)
      forM_ surfaceCases checkSurface

    it "round-trips the Sprint 7.38 DNS zone binding and seals it into both identities" $ do
      (_, _, firstDescriptor) <-
        expectDescriptorFixture
          ( descriptorFixtureWithZone
              CascadeSurface
              fixtureRunId
              fixtureFoundation
              (Just fixtureAwsScope)
              (Just fixtureAwsDnsZone)
          )
      (secondCompiled, _, secondDescriptor) <-
        expectDescriptorFixture
          ( descriptorFixtureWithZone
              CascadeSurface
              fixtureRunId
              fixtureFoundation
              (Just fixtureAwsScope)
              (Just alternateAwsDnsZone)
          )
      cleanupProgramDescriptorFormatVersion `shouldBe` 3
      cleanupProgramDescriptorAwsDnsZone firstDescriptor
        `shouldBe` Just fixtureAwsDnsZone
      cleanupProgramDescriptorAwsDnsZone secondDescriptor
        `shouldBe` Just alternateAwsDnsZone
      evidenceAwsDnsZone
        (compiledDesiredAbsenceObservationScope secondCompiled)
        `shouldBe` Just alternateAwsDnsZone
      cleanupProgramDescriptorGraphDigest firstDescriptor
        `shouldNotBe` cleanupProgramDescriptorGraphDigest secondDescriptor
      cleanupProgramDescriptorDigest firstDescriptor
        `shouldNotBe` cleanupProgramDescriptorDigest secondDescriptor
      (_, _, historical) <-
        expectDescriptorFixture
          ( legacyDescriptorFixtureWithZone
              CascadeSurface
              fixtureRunId
              fixtureFoundation
              (Just fixtureAwsScope)
              (Just fixtureAwsDnsZone)
          )
      cleanupDigestText (cleanupDigestOfBytes (legacyV2Bytes historical))
        `shouldBe` "9945312c1ba45af61e005b07e69f316b8c11100ed6d02f633ec453fb7c2ffbd1"

    it "restarts an unbound v2 descriptor without changing its bytes or graph" $ do
      (compiled, initialRun, descriptor) <-
        expectDescriptorFixture
          ( legacyDescriptorFixtureWithZone
              CascadeSurface
              fixtureRunId
              fixtureFoundation
              (Just fixtureAwsScope)
              (Just fixtureAwsDnsZone)
          )
      encodedRun <- mustRightIO (firstShow (encodeCleanupRun cleanupRunMaximumBytes initialRun))
      let legacy = legacyV2Bytes descriptor
          digest = cleanupDigestOfBytes legacy
      (client, remaining) <-
        authenticatedDescriptorClientFor
          [ CleanupRunDescriptorPresent (cleanupRunIdText fixtureRunId) (cleanupDigestText digest) encodedRun
          , CleanupRunDescriptorProgramPresent (cleanupRunIdText fixtureRunId) (cleanupDigestText digest) legacy
          ]
      recovered <- mustRightIO =<< observeDescriptorBoundCleanupRun client fixtureRunId
      remaining >>= (`shouldBe` [])
      descriptorBoundCleanupRunDescriptorDigest recovered `shouldBe` digest
      descriptorBoundCleanupRunGraphDigest recovered
        `shouldBe` cleanupGraphDigest (compiledDesiredAbsenceGraph compiled)
      mustRightIO
        ( withDescriptorBoundCleanupProgram
            recovered
            (\_ restored _ -> evidenceResourceScopeBindings (compiledDesiredAbsenceObservationScope restored))
        )
        >>= (`shouldBe` Nothing)

    it "restarts all seven frozen v3 programs without changing their graphs or acquiring a later family" $ do
      bytes <- ByteString.readFile "test/fixtures/lifecycle-descriptor-v3.json"
      cleanupDigestText (cleanupDigestOfBytes bytes)
        `shouldBe` "a939f5d898bb03ab2fb8eca45626a0cf5c57aaee769bfb4c3656cf4ba6cc8914"
      frozen <- mustRightIO (eitherDecodeStrict' bytes)
      frozenV3Format frozen `shouldBe` 3
      frozenV3Compiler frozen `shouldBe` "lifecycle-desired-absence-program-compiler/v6"
      length (frozenV3Programs frozen) `shouldBe` 7
      forM_ (frozenV3Programs frozen) $ \fixture -> do
        descriptor <- mustRightIO (Base64.decode (TextEncoding.encodeUtf8 (frozenV3Bytes fixture)))
        let digest = cleanupDigestOfBytes descriptor
        cleanupDigestText digest `shouldBe` frozenV3Digest fixture
        (runId, initial) <- frozenV3RunAndInitial descriptor
        (client, remaining) <-
          authenticatedDescriptorClientFor
            [ CleanupRunDescriptorPresent (cleanupRunIdText runId) (cleanupDigestText digest) initial
            , CleanupRunDescriptorProgramPresent (cleanupRunIdText runId) (cleanupDigestText digest) descriptor
            ]
        recovered <- mustRightIO =<< observeDescriptorBoundCleanupRun client runId
        remaining >>= (`shouldBe` [])
        descriptorBoundCleanupRunDescriptorDigest recovered `shouldBe` digest
        cleanupDigestText (descriptorBoundCleanupRunGraphDigest recovered) `shouldBe` frozenV3Graph fixture
        nodes <-
          mustRightIO
            ( withDescriptorBoundCleanupProgram recovered $ \_ compiled _ ->
                map (cleanupNodeIdText . cleanupNodeId) (cleanupGraphNodes (compiledDesiredAbsenceGraph compiled))
            )
        nodes `shouldSatisfy` all (not . Text.isInfixOf "aws-test-canary-security-groups")

    it "bounds a mutation reply independently of the committed run size" $ do
      (_, initialRun, descriptor) <-
        expectDescriptorFixture
          ( descriptorFixtureWithZone
              CascadeSurface
              fixtureRunId
              fixtureFoundation
              (Just fixtureAwsScope)
              (Just fixtureAwsDnsZone)
          )
      let lease = cleanupRunLease initialRun
          owner = cleanupLeaseOwner lease
          fence = cleanupLeaseFence lease
          primary = CleanupPrimaryFailed (Text.replicate (128 * 1024) "x")
          descriptorText = cleanupDigestText (cleanupProgramDescriptorDigest descriptor)
          runText = cleanupRunIdText fixtureRunId
      failedRun <- mustRightIO (firstShow (recordPrimaryOutcome owner fence primary initialRun))
      bytes <- mustRightIO (firstShow (encodeCleanupRun cleanupRunMaximumBytes failedRun))
      let command = CleanupRunDescriptorRecordPrimary runText descriptorText (cleanupOwnerIdText owner) fence primary
          reply =
            compactDescriptorTransitionResponse
              command
              (CleanupRunDescriptorPresent runText descriptorText bytes)
      ByteString.length bytes `shouldSatisfy` (> 128 * 1024)
      reply
        `shouldBe` CleanupRunDescriptorMutationCommitted
          runText
          descriptorText
          (cleanupDigestText (cleanupDigestOfBytes bytes))
      encoded <- mustRightIO (encodeCleanupRunDescriptorResponse reply)
      ByteString.length encoded `shouldSatisfy` (<= cleanupRunDescriptorMutationAckMaximumBytes)
    it "appends bounded transition metadata at response index seven and refuses its v1 envelope" $ do
      let acknowledgement =
            CleanupRunDescriptorMutationCommitted
              (Text.replicate 160 "r")
              (Text.replicate 64 "a")
              (Text.replicate 64 "b")
      encoded <- mustRightIO (encodeCleanupRunDescriptorResponse acknowledgement)
      ByteString.length encoded `shouldSatisfy` (<= cleanupRunDescriptorMutationAckMaximumBytes)
      decodeCleanupRunDescriptorResponse encoded `shouldBe` Right acknowledgement
      (_, term) <- mustRightIO (deserialiseFromBytes decodeTerm (LazyByteString.fromStrict encoded))
      case term of
        TList [TInt 0, TInt 2, TList (TInt 7 : _)] ->
          decodeCleanupRunDescriptorResponse
            (LazyByteString.toStrict (serialise (DescriptorResponseEnvelopeFixture 1 acknowledgement)))
            `shouldBe` Left "descriptor-bound cleanup response v1 contains v2 state"
        _ ->
          expectationFailure
            "transition acknowledgement moved an existing response constructor or envelope version"
    forM_ [minBound .. maxBound :: TransitionAckFault] $ \fault ->
      it ("confirms cleanup transition acknowledgements through one independent run read: " <> show fault) $ do
        (_, initialRun, descriptor) <-
          expectDescriptorFixture
            ( descriptorFixtureWithZone
                CascadeSurface
                fixtureRunId
                fixtureFoundation
                (Just fixtureAwsScope)
                (Just fixtureAwsDnsZone)
            )
        initialBytes <- mustRightIO (firstShow (encodeCleanupRun cleanupRunMaximumBytes initialRun))
        let owner = cleanupLeaseOwner (cleanupRunLease initialRun)
            now = cleanupLeaseExpiresAtMicros (cleanupRunLease initialRun) + 1
            expires = now + 1000
            digest = cleanupProgramDescriptorDigest descriptor
            runText = cleanupRunIdText fixtureRunId
            descriptorText = cleanupDigestText digest
        claimed <- mustRightIO (firstShow (claimCleanupRun owner now expires initialRun))
        claimedBytes <- mustRightIO (firstShow (encodeCleanupRun cleanupRunMaximumBytes claimed))
        let present bytes = CleanupRunDescriptorPresent runText descriptorText bytes
            program =
              CleanupRunDescriptorProgramPresent runText descriptorText (cleanupProgramDescriptorBytes descriptor)
            stateDigest = cleanupDigestText (cleanupDigestOfBytes claimedBytes)
            acknowledgement = case fault of
              AckLegacyFull -> present claimedBytes
              AckForeignRun -> CleanupRunDescriptorMutationCommitted "different-run" descriptorText stateDigest
              AckForeignDescriptor -> CleanupRunDescriptorMutationCommitted runText (Text.replicate 64 "a") stateDigest
              AckForeignState -> CleanupRunDescriptorMutationCommitted runText descriptorText (Text.replicate 64 "b")
              AckMalformed -> CleanupRunDescriptorMutationCommitted runText descriptorText "malformed"
              _ -> CleanupRunDescriptorMutationCommitted runText descriptorText stateDigest
            closing = case fault of
              AckChangedReadback -> present initialBytes
              AckUnobservableReadback -> CleanupRunDescriptorRefused (CleanupRunDescriptorUnavailable "run readback unavailable")
              AckWrongReadbackKind -> program
              _ -> present claimedBytes
        (client, remaining) <-
          authenticatedDescriptorClientFor [present initialBytes, program, acknowledgement, closing]
        bound <- mustRightIO =<< observeDescriptorBoundCleanupRun client fixtureRunId
        result <- claimDescriptorBoundCleanupRun client bound owner now expires
        if fault `elem` [AckConfirmed, AckLegacyFull]
          then do
            confirmed <- mustRightIO result
            descriptorBoundCleanupRunId confirmed `shouldBe` fixtureRunId
            descriptorBoundCleanupRunGraphDigest confirmed
              `shouldBe` cleanupGraphDigest (cleanupRunGraph claimed)
          else result `shouldSatisfy` either (const True) (const False)
        remaining
          >>= ( `shouldBe`
                  [closing | fault `elem` [AckForeignRun, AckForeignDescriptor, AckMalformed]]
              )

    it "refuses a historical compiler tag on a graph that declares the new canary family" $ do
      (compiled, initial, descriptor) <-
        expectDescriptorFixture
          (descriptorFixture CascadeSurface fixtureRunId fixtureFoundation (Just fixtureAwsScope))
      map (cleanupNodeIdText . cleanupNodeId) (cleanupGraphNodes (compiledDesiredAbsenceGraph compiled))
        `shouldSatisfy` any (Text.isInfixOf "aws-test-canary-security-groups")
      (_, term) <-
        mustRightIO
          ( deserialiseFromBytes
              decodeTerm
              (LazyByteString.fromStrict (cleanupProgramDescriptorBytes descriptor))
          )
      forged <- case term of
        TList fields ->
          pure
            ( LazyByteString.toStrict
                ( toLazyByteString
                    ( encodeTerm
                        ( TList
                            [ if index == 11 then TString "lifecycle-desired-absence-program-compiler/v6" else value
                            | (index, value) <- zip [0 :: Int ..] fields
                            ]
                        )
                    )
                )
            )
        _ -> fail "current descriptor is not a list"
      encodedRun <- mustRightIO (firstShow (encodeCleanupRun cleanupRunMaximumBytes initial))
      let digest = cleanupDigestText (cleanupDigestOfBytes forged)
      (client, _) <-
        authenticatedDescriptorClientFor
          [ CleanupRunDescriptorPresent (cleanupRunIdText fixtureRunId) digest encodedRun
          , CleanupRunDescriptorProgramPresent (cleanupRunIdText fixtureRunId) digest forged
          ]
      observeDescriptorBoundCleanupRun client fixtureRunId >>= (`shouldSatisfy` isLeft)

    it "reconstructs bound home DNS01 and exact mail coordinates after authenticated restart" $ do
      let home = mustRight (mkHomeDns01Scope alternateAwsDnsZone ("auth.example.test" :| []))
          bucket = mustRight (mkS3BucketName "fixture-capture-mail")
          mail = mustRight (mkInviteMailScope bucket (ExactInviteRecipient "test-abc123@receive.example.test"))
          bindings = mkResourceScopeBindings (Just home) (Just mail)
          compile value =
            compileDesiredAbsenceGraphForRegisteredKeysWithBindings
              fixtureRunId
              fixtureFoundation
              (Just fixtureAwsScope)
              (Just fixtureAwsDnsZone)
              (Just value)
              ExplicitPerRunSurface
              []
      compiled <- mustRightIO (firstShow (compile bindings))
      initialRun <-
        mustRightIO
          (firstShow (newCleanupRun fixtureRunId (compiledDesiredAbsenceGraph compiled) fixtureOwner 0 1000000))
      descriptor <- mustRightIO (firstShow (captureCleanupProgramDescriptor compiled initialRun))
      encodedRun <- mustRightIO (firstShow (encodeCleanupRun cleanupRunMaximumBytes initialRun))
      let responses =
            [ CleanupRunDescriptorPresent
                (cleanupRunIdText fixtureRunId)
                (cleanupDigestText (cleanupProgramDescriptorDigest descriptor))
                encodedRun
            , CleanupRunDescriptorProgramPresent
                (cleanupRunIdText fixtureRunId)
                (cleanupDigestText (cleanupProgramDescriptorDigest descriptor))
                (cleanupProgramDescriptorBytes descriptor)
            ]
      (client, remaining) <- authenticatedDescriptorClientFor responses
      recovered <- mustRightIO =<< observeDescriptorBoundCleanupRun client fixtureRunId
      remaining >>= (`shouldBe` [])
      mustRightIO
        ( withDescriptorBoundCleanupProgram
            recovered
            (\_ restored _ -> evidenceResourceScopeBindings (compiledDesiredAbsenceObservationScope restored))
        )
        >>= (`shouldBe` Just bindings)
      changed <- mustRightIO (firstShow (compile emptyResourceScopeBindings))
      cleanupGraphDigest (compiledDesiredAbsenceGraph changed)
        `shouldNotBe` cleanupProgramDescriptorGraphDigest descriptor

    it "refuses a transitioned run and any compiled/run identity disagreement" $ do
      case descriptorFixture
        CascadeSurface
        fixtureRunId
        fixtureFoundation
        (Just fixtureAwsScope) of
        Left detail -> expectationFailure (Text.unpack detail)
        Right (compiled, initialRun, _) -> do
          let transitioned =
                recordPrimaryOutcome
                  fixtureOwner
                  (cleanupLeaseFence (cleanupRunLease initialRun))
                  CleanupPrimarySucceeded
                  initialRun
          case transitioned of
            Left err -> expectationFailure (show err)
            Right nonInitial ->
              captureCleanupProgramDescriptor compiled nonInitial
                `shouldSatisfy` isLeft
          case descriptorFixture
            CascadeSurface
            otherRunId
            fixtureFoundation
            (Just fixtureAwsScope) of
            Left detail -> expectationFailure (Text.unpack detail)
            Right (_, otherInitialRun, _) ->
              captureCleanupProgramDescriptor compiled otherInitialRun
                `shouldSatisfy` isLeft

    it "exercises create/replay, hostile storage, and Sprint 7.38 legacy v1 restart" $ do
      regressionResult <- fixedCleanupProgramDescriptorRepositoryRegression
      case regressionResult of
        Left detail -> expectationFailure (Text.unpack detail)
        Right regression -> do
          cleanupProgramDescriptorRegressionAllSurfacesCaptured regression
            `shouldBe` True
          cleanupProgramDescriptorRegressionInitialStateRefused regression
            `shouldBe` True
          cleanupProgramDescriptorRegressionResponseLossRecovered regression
            `shouldBe` True
          cleanupProgramDescriptorRegressionExactReplayPreserved regression
            `shouldBe` True
          cleanupProgramDescriptorRegressionConflictPreserved regression
            `shouldBe` True
          cleanupProgramDescriptorRegressionTamperingRefused regression
            `shouldBe` True
          cleanupProgramDescriptorRegressionUnknownStatesRefused regression
            `shouldBe` True
          cleanupProgramDescriptorRegressionWrongRunRefused regression
            `shouldBe` True
          cleanupProgramDescriptorRegressionRestartReconstructionValidated regression
            `shouldBe` True
          cleanupProgramDescriptorRegressionLegacyV1RestartReadable regression
            `shouldBe` True

    it "carries only a canonical committed descriptor through the v2 readback response arm" $ do
      case descriptorFixture
        CascadeSurface
        fixtureRunId
        fixtureFoundation
        (Just fixtureAwsScope) of
        Left detail -> expectationFailure (Text.unpack detail)
        Right (_, _, descriptor) -> do
          let response =
                CleanupRunDescriptorProgramPresent
                  (cleanupRunIdText fixtureRunId)
                  (cleanupDigestText (cleanupProgramDescriptorDigest descriptor))
                  (cleanupProgramDescriptorBytes descriptor)
              bytes = mustRight (encodeCleanupRunDescriptorResponse response)
          decodeCleanupRunDescriptorResponse bytes `shouldBe` Right response
          encodeCleanupRunDescriptorResponse
            ( CleanupRunDescriptorProgramPresent
                (cleanupRunIdText otherRunId)
                (cleanupDigestText (cleanupProgramDescriptorDigest descriptor))
                (cleanupProgramDescriptorBytes descriptor)
            )
            `shouldSatisfy` isLeft
          encodeCleanupRunDescriptorResponse
            ( CleanupRunDescriptorProgramPresent
                (cleanupRunIdText fixtureRunId)
                (Text.replicate 64 "a")
                (cleanupProgramDescriptorBytes descriptor)
            )
            `shouldSatisfy` isLeft

    it "recovers and dispatches two exact surface programs after restart without a side map" $ do
      local <-
        freshProcessDispatch
          LocalOnlySurface
          LocalOnly
          localDispatchRunId
          Nothing
          "uninstall-local-only-foundation"
      cascade <-
        freshProcessDispatch
          CascadeSurface
          Cascade
          cascadeDispatchRunId
          (Just fixtureAwsScope)
          "audit-cascade-escapes"
      local
        `shouldBe` DispatchObservation
          { dispatchObservedSurface = LocalOnly
          , dispatchObservedOperation = "uninstall-local-only-foundation"
          , dispatchHandleMatchesCompiled = True
          , dispatchHandleMatchesReadBack = True
          , dispatchContextMatchesHandle = True
          , dispatchContextMatchesPlan = True
          }
      cascade
        `shouldBe` DispatchObservation
          { dispatchObservedSurface = Cascade
          , dispatchObservedOperation = "audit-cascade-escapes"
          , dispatchHandleMatchesCompiled = True
          , dispatchHandleMatchesReadBack = True
          , dispatchContextMatchesHandle = True
          , dispatchContextMatchesPlan = True
          }
      dispatchObservedOperation local
        `shouldSatisfy` (/= dispatchObservedOperation cascade)

    it "keeps raw decoding, Model-B construction, and positive remint hidden" $ do
      descriptorFacade <-
        readFile
          "src/Prodbox/Lifecycle/Teardown/CleanupProgramDescriptor.hs"
      descriptorFacade `shouldNotContain` "decodeAndValidateCleanupProgramDescriptor"
      descriptorFacade `shouldNotContain` "withRecompiledCleanupProgramDescriptor"
      descriptorFacade `shouldNotContain` "CleanupProgramDescriptor (..)"

      repositoryFacade <-
        readFile
          "src/Prodbox/ControlPlane/CleanupProgramDescriptorRepository.hs"
      repositoryFacade `shouldNotContain` "ModelBCasAdapter"
      repositoryFacade `shouldNotContain` "modelBCleanupProgramDescriptorRepository"
      repositoryFacade
        `shouldNotContain` "CleanupProgramDescriptorAuthorityClient (..)"
      repositoryFacade
        `shouldNotContain` "CommittedCleanupProgramDescriptor (..)"
      repositoryFacade
        `shouldNotContain` "confirmCommittedCleanupProgramDescriptorBytes"
      repositoryFacade
        `shouldNotContain` "committedCleanupProgramDescriptorBytes"

      descriptorInternalImporters <-
        sourceImporters
          "src"
          "import Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor.Internal"
      sort descriptorInternalImporters
        `shouldBe` sort
          [ "src/Prodbox/Lifecycle/Teardown/CleanupProgramDescriptor.hs"
          , "src/Prodbox/Lifecycle/HostCleanupIntent/Internal.hs"
          , "src/Prodbox/ControlPlane/CleanupProgramDescriptorRepository/Internal.hs"
          , "src/Prodbox/ControlPlane/CleanupRunEndpoint.hs"
          ]

      repositoryInternalImporters <-
        sourceImporters
          "src"
          "import Prodbox.ControlPlane.CleanupProgramDescriptorRepository.Internal"
      sort repositoryInternalImporters
        `shouldBe` sort
          [ "src/Prodbox/ControlPlane/CleanupProgramDescriptorRepository.hs"
          , "src/Prodbox/ControlPlane/CleanupRunClient.hs"
          , "src/Prodbox/ControlPlane/CleanupRunEndpoint.hs"
          , "src/Prodbox/ControlPlane/CompletedProviderPredecessorRegression/Internal.hs"
          , "src/Prodbox/ControlPlane/CredentialSuccessorRegression/Internal.hs"
          , "src/Prodbox/ControlPlane/RecoveryPlaneEndpoint/Internal.hs"
          , "src/Prodbox/ControlPlane/Runtime.hs"
          ]

      confirmerUsers <-
        sourceImporters
          "src"
          "confirmCommittedCleanupProgramDescriptorBytes"
      sort confirmerUsers
        `shouldBe` sort
          [ "src/Prodbox/ControlPlane/CleanupProgramDescriptorRepository/Internal.hs"
          , "src/Prodbox/ControlPlane/CleanupRunClient.hs"
          , "src/Prodbox/ControlPlane/RecoveryPlaneEndpoint/Internal.hs"
          ]
      descriptorBytesUsers <-
        sourceImporters
          "src"
          "committedCleanupProgramDescriptorBytes"
      sort descriptorBytesUsers
        `shouldBe` sort
          [ "src/Prodbox/ControlPlane/CleanupProgramDescriptorRepository/Internal.hs"
          , "src/Prodbox/ControlPlane/CleanupRunEndpoint.hs"
          ]

      cleanupClient <- readFile "src/Prodbox/ControlPlane/CleanupRunClient.hs"
      let cleanupClientHeader = unlines (takeWhile (/= "where") (lines cleanupClient))
      cleanupClientHeader `shouldNotContain` "DescriptorBoundCleanupRun (..)"
      cleanupClientHeader
        `shouldNotContain` "CommittedCleanupProgramDescriptor (..)"
      cleanupClientHeader
        `shouldNotContain` "withCommittedCleanupProgramDescriptor"
      cleanupClientHeader
        `shouldNotContain` "deriveOrdinaryTeardownRecoveryRequirementInternal"
      cleanupClientHeader
        `shouldNotContain` "confirmCommittedCleanupProgramDescriptorBytes"
      cleanupClientHeader
        `shouldNotContain` "committedCleanupProgramDescriptorBytes"

      cabal <- readFile "prodbox.cabal"
      let (libraryExposed, privateAndTests) =
            break (== "    other-modules:") (lines cabal)
          libraryPrivate =
            takeWhile (not . isPrefixOf "test-suite ") privateAndTests
          descriptorInternal =
            "Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor.Internal"
          repositoryInternal =
            "Prodbox.ControlPlane.CleanupProgramDescriptorRepository.Internal"
      unlines libraryExposed `shouldNotContain` descriptorInternal
      unlines libraryExposed `shouldNotContain` repositoryInternal
      unlines libraryPrivate `shouldContain` descriptorInternal
      unlines libraryPrivate `shouldContain` repositoryInternal

data DispatchObservation = DispatchObservation
  { dispatchObservedSurface :: !CleanupSurface
  , dispatchObservedOperation :: !Text.Text
  , dispatchHandleMatchesCompiled :: !Bool
  , dispatchHandleMatchesReadBack :: !Bool
  , dispatchContextMatchesHandle :: !Bool
  , dispatchContextMatchesPlan :: !Bool
  }
  deriving (Eq, Show)

freshProcessDispatch
  :: CleanupSurfaceWitness surface
  -> CleanupSurface
  -> CleanupRunId
  -> Maybe AwsScope
  -> Text.Text
  -> IO DispatchObservation
freshProcessDispatch witness expectedSurface runId maybeAwsScope expectedOperation = do
  (compiled, initialRun, descriptor) <-
    mustRightIO
      (descriptorFixture witness runId fixtureFoundation maybeAwsScope)
  (plan, running) <-
    mustRightIO
      (runningAtOperation expectedOperation compiled initialRun)
  runningBytes <-
    mustRightIO (firstShow (encodeCleanupRun cleanupRunMaximumBytes running))
  let descriptorDigest = cleanupProgramDescriptorDigest descriptor
      responses =
        [ CleanupRunDescriptorPresent
            (cleanupRunIdText runId)
            (cleanupDigestText descriptorDigest)
            runningBytes
        , CleanupRunDescriptorProgramPresent
            (cleanupRunIdText runId)
            (cleanupDigestText descriptorDigest)
            (cleanupProgramDescriptorBytes descriptor)
        ]
  (client, remainingResponses) <- authenticatedDescriptorClientFor responses
  recovered <-
    mustRightIO =<< observeDescriptorBoundCleanupRun client runId
  remainingResponses >>= (`shouldBe` [])
  executionContext <-
    mustRightIO
      (descriptorBoundCleanupNodeExecutionContext recovered plan)
  observations <- newIORef []
  outcome <-
    descriptorBoundCleanupNodeAction
      (recordDispatch observations recovered descriptorDigest)
      recovered
      executionContext
      plan
  outcome `shouldBe` CleanupNodeSucceeded
  observed <- readIORef observations
  case observed of
    [single] -> pure single
    _ -> do
      expectationFailure
        ( "expected one descriptor-bound semantic dispatch, observed "
            <> show (length observed)
        )
      fail "descriptor-bound semantic dispatch count mismatch"
 where
  recordDispatch
    :: IORef [DispatchObservation]
    -> DescriptorBoundCleanupRun
    -> CleanupDigest
    -> DescriptorBoundCleanupRun
    -> CleanupSurfaceWitness recoveredSurface
    -> CompiledDesiredAbsenceProgram recoveredSurface
    -> CleanupNodeExecutionContext
    -> CleanupNodePlan
    -> IO CleanupNodeOutcome
  recordDispatch observations recovered expectedDigest current recoveredWitness recoveredCompiled context plan = do
    let operation = operationTagForPlan recoveredCompiled plan
        operationText = case operation of
          Left detail -> detail
          Right tag -> tag
        observation =
          DispatchObservation
            { dispatchObservedSurface = cleanupSurfaceFromWitness recoveredWitness
            , dispatchObservedOperation = operationText
            , dispatchHandleMatchesCompiled =
                descriptorBoundCleanupRunId current
                  == compiledDesiredAbsenceRunId recoveredCompiled
                  && descriptorBoundCleanupRunGraphDigest current
                    == cleanupGraphDigest
                      (compiledDesiredAbsenceGraph recoveredCompiled)
            , dispatchHandleMatchesReadBack =
                descriptorBoundCleanupRunId current
                  == descriptorBoundCleanupRunId recovered
                  && descriptorBoundCleanupRunDescriptorDigest current
                    == descriptorBoundCleanupRunDescriptorDigest recovered
                  && descriptorBoundCleanupRunDescriptorDigest current
                    == expectedDigest
            , dispatchContextMatchesHandle =
                cleanupNodeExecutionRunId context
                  == descriptorBoundCleanupRunId current
                  && cleanupNodeExecutionGraphDigest context
                    == descriptorBoundCleanupRunGraphDigest current
            , dispatchContextMatchesPlan =
                cleanupNodeExecutionNodeId context == cleanupNodeId plan
            }
    operation `shouldBe` Right expectedOperation
    cleanupSurfaceFromWitness recoveredWitness `shouldBe` expectedSurface
    modifyIORef' observations (observation :)
    pure CleanupNodeSucceeded

runningAtOperation
  :: Text.Text
  -> CompiledDesiredAbsenceProgram surface
  -> CleanupRun
  -> Either Text.Text (CleanupNodePlan, CleanupRun)
runningAtOperation expectedOperation compiled initialRun = do
  withPrimary <-
    firstShow
      ( recordPrimaryOutcome
          fixtureOwner
          (cleanupLeaseFence (cleanupRunLease initialRun))
          CleanupPrimarySucceeded
          initialRun
      )
  drive withPrimary (cleanupGraphNodes (compiledDesiredAbsenceGraph compiled))
 where
  drive _ [] =
    Left ("compiled program lacks operation " <> expectedOperation)
  drive run (plan : remaining) = do
    operation <- operationTagForPlan compiled plan
    attempt <-
      firstShow
        (mkCleanupAttemptId ("restart-dispatch/" <> cleanupNodeIdText (cleanupNodeId plan)))
    running <-
      firstShow
        ( beginCleanupNode
            fixtureOwner
            (cleanupLeaseFence (cleanupRunLease run))
            (cleanupNodeId plan)
            attempt
            run
        )
    if operation == expectedOperation
      then Right (plan, running)
      else do
        completed <-
          firstShow
            ( completeCleanupNode
                fixtureOwner
                (cleanupLeaseFence (cleanupRunLease running))
                (cleanupNodeId plan)
                attempt
                CleanupNodeSucceeded
                running
            )
        drive completed remaining

operationTagForPlan
  :: CompiledDesiredAbsenceProgram surface
  -> CleanupNodePlan
  -> Either Text.Text Text.Text
operationTagForPlan compiled plan =
  case [ someTeardownOperationTag operation
       | (nodeId, operation) <- compiledDesiredAbsenceOperations compiled
       , nodeId == cleanupNodeId plan
       ] of
    [operation] -> Right operation
    [] -> Left "compiled program has no semantic operation for cleanup node"
    _ -> Left "compiled program has duplicate semantic operations for cleanup node"

data SurfaceCase where
  SurfaceCase
    :: CleanupSurfaceWitness surface
    -> CleanupSurface
    -> Maybe AwsScope
    -> SurfaceCase

surfaceCases :: [SurfaceCase]
surfaceCases =
  [ SurfaceCase LocalOnlySurface LocalOnly Nothing
  , SurfaceCase CascadeSurface Cascade (Just fixtureAwsScope)
  , SurfaceCase ExplicitPerRunSurface ExplicitPerRun (Just fixtureAwsScope)
  , SurfaceCase
      OperationalTeardownSurface
      OperationalTeardown
      (Just fixtureAwsScope)
  , SurfaceCase
      ExplicitLongLivedSurface
      ExplicitLongLived
      (Just fixtureAwsScope)
  , SurfaceCase
      TotalDecommissionSurface
      TotalDecommission
      (Just fixtureAwsScope)
  ]

descriptorFixture
  :: CleanupSurfaceWitness surface
  -> CleanupRunId
  -> LinuxRke2FoundationId
  -> Maybe AwsScope
  -> Either
       Text.Text
       (CompiledDesiredAbsenceProgram surface, CleanupRun, CleanupProgramDescriptor)
descriptorFixture witness runId foundation maybeAwsScope = do
  descriptorFixtureWithZone witness runId foundation maybeAwsScope Nothing

descriptorFixtureWithZone
  :: CleanupSurfaceWitness surface
  -> CleanupRunId
  -> LinuxRke2FoundationId
  -> Maybe AwsScope
  -> Maybe HostedZoneId
  -> Either
       Text.Text
       (CompiledDesiredAbsenceProgram surface, CleanupRun, CleanupProgramDescriptor)
descriptorFixtureWithZone witness runId foundation maybeAwsScope maybeAwsDnsZone = do
  compiled <-
    firstShow
      ( compileDesiredAbsenceGraph
          runId
          foundation
          maybeAwsScope
          maybeAwsDnsZone
          witness
      )
  initialRun <-
    firstShow
      ( newCleanupRun
          runId
          (compiledDesiredAbsenceGraph compiled)
          fixtureOwner
          1
          1000
      )
  descriptor <-
    firstShow (captureCleanupProgramDescriptor compiled initialRun)
  Right (compiled, initialRun, descriptor)

legacyDescriptorFixtureWithZone
  :: CleanupSurfaceWitness surface
  -> CleanupRunId
  -> LinuxRke2FoundationId
  -> Maybe AwsScope
  -> Maybe HostedZoneId
  -> Either
       Text.Text
       (CompiledDesiredAbsenceProgram surface, CleanupRun, CleanupProgramDescriptor)
legacyDescriptorFixtureWithZone witness runId foundation maybeAwsScope maybeAwsDnsZone = do
  compiled <-
    firstShow
      ( compileDesiredAbsenceGraphForRegisteredKeys
          runId
          foundation
          maybeAwsScope
          maybeAwsDnsZone
          witness
          [ cleanupTargetKey target
          | target <- cleanupTargetsForSurface witness
          , cleanupTargetKey target < HomeDns01ChallengeRecordKey
          ]
      )
  initialRun <-
    firstShow
      ( newCleanupRun
          runId
          (compiledDesiredAbsenceGraph compiled)
          fixtureOwner
          1
          1000
      )
  descriptor <-
    firstShow (captureCleanupProgramDescriptor compiled initialRun)
  Right (compiled, initialRun, descriptor)

expectDescriptorFixture
  :: Either
       Text.Text
       (CompiledDesiredAbsenceProgram surface, CleanupRun, CleanupProgramDescriptor)
  -> IO
       (CompiledDesiredAbsenceProgram surface, CleanupRun, CleanupProgramDescriptor)
expectDescriptorFixture result = case result of
  Left detail -> do
    expectationFailure (Text.unpack detail)
    error "unreachable"
  Right fixture -> pure fixture

fixtureRunId :: CleanupRunId
fixtureRunId = mustRight (mkCleanupRunId "descriptor-unit-run")

otherRunId :: CleanupRunId
otherRunId = mustRight (mkCleanupRunId "descriptor-unit-other-run")

localDispatchRunId :: CleanupRunId
localDispatchRunId = mustRight (mkCleanupRunId "descriptor-unit-local-restart")

cascadeDispatchRunId :: CleanupRunId
cascadeDispatchRunId = mustRight (mkCleanupRunId "descriptor-unit-cascade-restart")

fixtureOwner :: CleanupOwnerId
fixtureOwner = mustRight (mkCleanupOwnerId "descriptor-unit-authority")

fixtureFoundation :: LinuxRke2FoundationId
fixtureFoundation = LinuxRke2FoundationId "foundation/home"

fixtureAwsScope :: AwsScope
fixtureAwsScope =
  AwsScope
    (AwsAccountId "111122223333")
    (AwsRegion (fixtureAwsRegion FixtureCaCentral1))

fixtureAwsDnsZone :: HostedZoneId
fixtureAwsDnsZone = mustRight (mkHostedZoneId "Z0123456789ABCDEFGHIJ")

alternateAwsDnsZone :: HostedZoneId
alternateAwsDnsZone = mustRight (mkHostedZoneId "ZABCDEFGHIJ0123456789")

authenticatedDescriptorClientFor
  :: [CleanupRunDescriptorResponse]
  -> IO
       ( DescriptorBoundCleanupRunClient IO
       , IO [CleanupRunDescriptorResponse]
       )
authenticatedDescriptorClientFor responses = do
  queuedResponses <- newIORef responses
  endpoint <-
    mustRightIO
      (mkLifecycleAuthorityEndpoint "http://lifecycle-authority:8600")
  rawClient <-
    mustRightIO
      ( controlPlaneClientWithTransport
          descriptorClientMaximumResponseBytes
          endpoint
          (descriptorClientTransport queuedResponses)
      )
  pure
    ( descriptorBoundCleanupRunClient
        ( mkAuthenticatedClientTransport
            descriptorTransportBounds
            descriptorClientProviders
            rawClient
        )
    , readIORef queuedResponses
    )

descriptorClientTransport
  :: IORef [CleanupRunDescriptorResponse]
  -> Method
  -> [Header]
  -> String
  -> ByteString.ByteString
  -> IO (Either HttpBoundedError (Int, ByteString.ByteString))
descriptorClientTransport queuedResponses method _ url _ = do
  method `shouldBe` "POST"
  url
    `shouldBe` "http://lifecycle-authority:8600/v1/authority/cleanup-run"
  let dequeue queued = case queued of
        [] -> ([], Nothing)
        response : remaining -> (remaining, Just response)
  nextResponse <-
    atomicModifyIORef' queuedResponses dequeue
  case nextResponse of
    Nothing -> do
      expectationFailure "descriptor client issued an unexpected request"
      pure (Right (500, mempty))
    Just response -> do
      let endpointResult = CleanupRunEndpointDescriptorBound response
      pure
        ( Right
            ( replyStatusCode (cleanupRunEndpointStatus endpointResult)
            , cleanupRunEndpointBody endpointResult
            )
        )

descriptorClientMaximumResponseBytes :: Int
descriptorClientMaximumResponseBytes = 4 * 1024 * 1024

descriptorTransportBounds :: AuthenticatedTransportBounds
descriptorTransportBounds =
  mustRight
    ( mkAuthenticatedTransportBounds
        descriptorClientMaximumResponseBytes
        256
        (descriptorClientMaximumResponseBytes - 1024)
    )

descriptorClientProviders :: AuthenticatedClientProviders IO
descriptorClientProviders =
  AuthenticatedClientProviders
    { provideAuthenticatedClientSigner =
        pure
          ( Right
              (localRequestSigningCapability descriptorRequestSigner)
          )
    , provideAuthenticatedClientScope = pure (Right descriptorAuthorityScope)
    , provideAuthenticatedClientEpoch = pure (Right authorityEpochGenesis)
    , provideAuthenticatedClientDeadline = pure (Right descriptorDeadline)
    , provideAuthenticatedClientNonce = pure (Right descriptorRequestNonce)
    }

descriptorRequestSigner :: RequestSigner
descriptorRequestSigner =
  mustRight
    ( mkRequestSigner
        CallerOperatorCli
        (mustRight (mkSigningKeyGeneration 1))
        (ByteString.pack [0 .. 31])
    )

descriptorRequestNonce :: RequestNonce
descriptorRequestNonce =
  mustRight (mkRequestNonce (ByteString.pack [32 .. 47]))

descriptorAuthorityScope :: AuthorityScope
descriptorAuthorityScope = mustRight (mkAuthorityScope "cluster-a")

descriptorDeadline :: AuthorityTime
descriptorDeadline = authorityTimeFromMicros 2000

sourceImporters :: FilePath -> String -> IO [FilePath]
sourceImporters root importNeedle = do
  paths <- haskellFiles root
  filterM (fmap (isInfixOf importNeedle) . readFile) paths

haskellFiles :: FilePath -> IO [FilePath]
haskellFiles path = do
  isDirectory <- doesDirectoryExist path
  if isDirectory
    then do
      children <- listDirectory path
      concat <$> traverse (haskellFiles . (path </>)) children
    else pure [path | takeExtension path == ".hs"]

firstShow :: (Show error) => Either error value -> Either Text.Text value
firstShow result = case result of
  Left err -> Left (Text.pack (show err))
  Right value -> Right value

mustRight :: (Show error) => Either error value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value

mustRightIO :: (Show error) => Either error value -> IO value
mustRightIO result = case result of
  Left err -> do
    expectationFailure (show err)
    fail "invalid descriptor-bound cleanup fixture"
  Right value -> pure value

-- The measured v2 generic constructor has 18 fields after its constructor tag.
-- Keep the byte fixture honest while current captures append the v3 extension.
legacyV2Bytes :: CleanupProgramDescriptor -> ByteString.ByteString
legacyV2Bytes descriptor = LazyByteString.toStrict (toLazyByteString (encodeTerm legacy))
 where
  term =
    snd
      ( mustRight
          ( deserialiseFromBytes
              decodeTerm
              (LazyByteString.fromStrict (cleanupProgramDescriptorBytes descriptor))
          )
      )
  legacy = case term of
    TList fields ->
      TList
        [ case index of
            1 -> TInt 2
            11 -> TString "lifecycle-desired-absence-program-compiler/v5"
            _ -> value
        | (index, value) <- zip [0 :: Int ..] (init fields)
        ]
    _ -> error "descriptor fixture is not a list"

-- Frozen before the canary registry extension; these bytes are never regenerated
-- by a test and contain synthetic metadata only.
data FrozenV3Document = FrozenV3Document
  { frozenV3Format :: !Int
  , frozenV3Compiler :: !Text.Text
  , frozenV3Programs :: ![FrozenV3Program]
  }

instance FromJSON FrozenV3Document where
  parseJSON = withObject "FrozenV3Document" $ \object ->
    FrozenV3Document <$> object .: "format" <*> object .: "compiler" <*> object .: "fixtures"

data FrozenV3Program = FrozenV3Program
  { frozenV3Bytes :: !Text.Text
  , frozenV3Digest :: !Text.Text
  , frozenV3Graph :: !Text.Text
  }

instance FromJSON FrozenV3Program where
  parseJSON = withObject "FrozenV3Program" $ \object ->
    FrozenV3Program
      <$> object .: "descriptor_base64"
      <*> object .: "descriptor_digest"
      <*> object .: "graph_digest"

frozenV3RunAndInitial :: ByteString.ByteString -> IO (CleanupRunId, ByteString.ByteString)
frozenV3RunAndInitial bytes = do
  (remaining, term) <- mustRightIO (deserialiseFromBytes decodeTerm (LazyByteString.fromStrict bytes))
  remaining `shouldBe` LazyByteString.empty
  case term of
    TList fields -> case (lookup 1 indexed, lookup 2 indexed, lookup 17 indexed) of
      (Just (TInt 3), Just (TString runId), Just (TBytes initial)) ->
        (,initial) <$> mustRightIO (mkCleanupRunId runId)
      _ -> fail "frozen v3 metadata is malformed"
     where
      indexed = zip [0 :: Int ..] fields
    _ -> fail "frozen v3 descriptor is not a list"

-- Faults cross the real authenticated client decoder and committed-descriptor reader.
data TransitionAckFault
  = AckConfirmed
  | AckLegacyFull
  | AckForeignRun
  | AckForeignDescriptor
  | AckForeignState
  | AckChangedReadback
  | AckUnobservableReadback
  | AckWrongReadbackKind
  | AckMalformed
  deriving (Bounded, Enum, Eq, Show)

-- The same canonical envelope shape under a deliberately obsolete version.
data DescriptorResponseEnvelopeFixture
  = DescriptorResponseEnvelopeFixture Word16 CleanupRunDescriptorResponse
  deriving stock (Generic)
  deriving anyclass (Serialise)
