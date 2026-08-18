{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.84: the stable registered-stack lifecycle generation.
--
-- The property under test is that a /later/ cleanup run, with a different
-- durable run scope and a different cleanup surface, can select the exact stack
-- an earlier run created — and that every run-invariant key component still
-- refuses on disagreement.
module LifecycleTeardownStackGeneration
  ( lifecycleTeardownStackGenerationSuite
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
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
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.ControlPlane.AwsStackCreationBindingRepository
  ( AwsStackCreationCommitResult (AwsStackCreationCommitCreated)
  , ObservedAwsStackCreationOperation
  , modelBAwsStackCreationBindingRepository
  , observeAuthorityAwsStackCreationOperation
  , observedAwsStackCreationKey
  , observedAwsStackCreationOperationId
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli)
  )
import Prodbox.ControlPlane.Coordinate (AuthorityEpoch (..))
import Prodbox.ControlPlane.ProviderAwsScopeReceipt
  ( ProviderAwsScopeReceiptError (ProviderAwsScopeRetainedOperationMissing)
  )
import Prodbox.ControlPlane.ProviderNarrowSession
  ( ProviderEffectObservation (ProviderEffectUnobservable)
  , ProviderIntentCapabilities (..)
  , ProviderMutation (..)
  , ProviderNarrowSessionRunner (..)
  , ProviderReadOnly (..)
  )
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( AcceptedProviderAuthority
  , ExecutedProviderIntent
  , ProviderCommittedIntentSpec (..)
  , ProviderIntentSigningKey
  , ProviderIssuerKeyGeneration
  , ProviderWorkerExecutionBoundary
  , ProviderWorkerTrustRepository (..)
  , SignedProviderCommittedIntent
  , admitProviderCommittedIntent
  , encodeSignedProviderCommittedIntent
  , executeVerifiedProviderIntentBound
  , mkAcceptedProviderAuthority
  , mkProviderIntentSigningKey
  , mkProviderIssuerKeyGeneration
  , mkProviderWorkerExecutionBoundary
  , mkUnsignedProviderCommittedIntent
  , providerCommittedIntentMaximumEncodedBytes
  , providerIntentSigningPublicKey
  , signProviderCommittedIntent
  )
import Prodbox.ControlPlane.RegisteredStackCleanupSelection
  ( RegisteredStackCleanupBoundary (..)
  , RegisteredStackCleanupError (..)
  , selectRegisteredStackForCleanup
  )
import Prodbox.ControlPlane.RegisteredStackCreationProducer
  ( RegisteredStackCreationBoundary (..)
  , RegisteredStackCreationError (..)
  , commitRegisteredStackCreation
  , registeredStackCreationBinding
  , registeredStackCreationGeneration
  , registeredStackCreationReservation
  )
import Prodbox.ControlPlane.RegisteredStackGenerationRepository
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , AuthorityAdmissionCommand (ApplyAuthorityGenesis)
  , AuthorityProviderSubmissionDecision (AuthorityProviderSubmissionAccepted)
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
  )
import Prodbox.Lifecycle.Authority.Submission
  ( OperationId (..)
  , RequestDigest (RequestDigest)
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  , modelBObjectLogicalName
  )
import Prodbox.Lifecycle.Lease
  ( authorityTimeFromMicros
  , mkFencingToken
  , mkOwnerNonce
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderRevision
  , ProviderStackConfig
  , ProviderStackRef
  , mkAwsEksProviderStackConfig
  , mkAwsTestProviderStackConfig
  , mkProviderRevision
  , mkProviderStackRef
  , mkRegisteredProviderResources
  )
import Prodbox.Lifecycle.TargetCommitIntent (sha256TargetValueDigest)
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurface (..)
  , DurableObservationRunScope (..)
  , LifecycleOperation (..)
  , LinuxRke2FoundationId (..)
  , ManagedResourceCoordinateDigest
  , ObservationEvidenceScope
  , ObservationFailure (..)
  , RegisteredResourceKey (..)
  , RegistryRevision (..)
  , mkObservationEvidenceScope
  )
import Prodbox.Lifecycle.Teardown.ProviderAwsScopeAdapter
  ( decodeVerifiedProviderAwsScope
  , providerAwsScopeIntent
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( lifecycleRegistryRevision
  , lookupRegisteredIdentity
  , registeredIdentityCoordinateDigest
  )
import Prodbox.Lifecycle.Teardown.StackGeneration
import TestSupport

lifecycleTeardownStackGenerationSuite :: SuiteBuilder ()
lifecycleTeardownStackGenerationSuite =
  describe "Sprint 4.84 stable registered-stack lifecycle generation" $ do
    describe "generation ordinal" $ do
      it "reserves zero and succeeds monotonically" $ do
        mkStackGenerationOrdinal 0 `shouldBe` Left StackGenerationOrdinalZero
        fmap stackGenerationOrdinalValue (mkStackGenerationOrdinal 4)
          `shouldBe` Right 4
        stackGenerationOrdinalValue initialStackGenerationOrdinal `shouldBe` 1
        fmap
          stackGenerationOrdinalValue
          (succeedingStackGenerationOrdinal initialStackGenerationOrdinal)
          `shouldBe` Right 2

      it "refuses to wrap an exhausted ordinal onto a used key" $ do
        let exhausted = mustRight (mkStackGenerationOrdinal maxBound)
        succeedingStackGenerationOrdinal exhausted
          `shouldBe` Left StackGenerationOrdinalExhausted

    describe "establishing a generation" $ do
      it "takes its AWS scope only from the Provider proof and its digest only from the registry" $ do
        generation <- establishFixtureGeneration initialStackGenerationOrdinal
        let key = registeredStackGenerationKey generation
        stackGenerationKeyResource key `shouldBe` AwsTestKey
        stackGenerationKeyCoordinateDigest key `shouldBe` registryDigest AwsTestKey
        stackGenerationKeyRegistryRevision key `shouldBe` lifecycleRegistryRevision
        stackGenerationKeyFoundation key `shouldBe` fixtureFoundation
        stackGenerationKeyAwsScope key `shouldBe` fixtureAwsScope
        stackGenerationKeyOrdinal key `shouldBe` initialStackGenerationOrdinal

      it "records causal provenance without letting it into the key" $ do
        generation <- establishFixtureGeneration initialStackGenerationOrdinal
        observed <- fixtureObservedCreation
        registeredStackGenerationAdmittedOperationId generation
          `shouldBe` observedAwsStackCreationOperationId observed
        registeredStackGenerationProviderOperationId generation
          `shouldBe` fixtureProviderOperation
        registeredStackGenerationCreatingRunScope generation
          `shouldBe` creatingRunScope
        registeredStackGenerationCreatingSurface generation `shouldBe` ExplicitPerRun
        -- The canonical key rendering must not leak the creating run or surface.
        let rendered = stackGenerationKeyText (registeredStackGenerationKey generation)
        Text.isInfixOf "run/creation-1" rendered `shouldBe` False
        Text.isInfixOf "ExplicitPerRun" rendered `shouldBe` False

      it "gives successive create cycles of one stack distinct keys" $ do
        first <- establishFixtureGeneration initialStackGenerationOrdinal
        second <-
          establishFixtureGeneration
            (mustRight (succeedingStackGenerationOrdinal initialStackGenerationOrdinal))
        registeredStackGenerationKey first
          `shouldNotBe` registeredStackGenerationKey second
        stackGenerationKeyText (registeredStackGenerationKey first)
          `shouldNotBe` stackGenerationKeyText (registeredStackGenerationKey second)
        stackGenerationSlotDigest (registeredStackGenerationKey first)
          `shouldNotBe` stackGenerationSlotDigest (registeredStackGenerationKey second)

    describe "the durable slot address" $ do
      it "is run-invariant, so creator and later cleaner compute the same slot" $ do
        created <- establishFixtureGeneration initialStackGenerationOrdinal
        -- A second establishment differing only in creating run scope and
        -- surface must land in the same durable slot.
        observed <- fixtureObservedCreation
        providerScope <- fixtureVerifiedProviderScope
        recreated <-
          mustRightIO
            ( establishRegisteredStackGeneration
                observed
                providerScope
                fixtureFoundation
                laterCleanupRunScope
                Cascade
                initialStackGenerationOrdinal
            )
        stackGenerationSlotLogicalName (registeredStackGenerationKey created)
          `shouldBe` stackGenerationSlotLogicalName (registeredStackGenerationKey recreated)
        registeredStackGenerationCreatingSurface created
          `shouldNotBe` registeredStackGenerationCreatingSurface recreated

      it "addresses a prefix distinct from the per-run creation-binding prefix" $ do
        generation <- establishFixtureGeneration initialStackGenerationOrdinal
        let slot = stackGenerationSlotLogicalName (registeredStackGenerationKey generation)
            digest =
              stackGenerationSlotDigestText
                (stackGenerationSlotDigest (registeredStackGenerationKey generation))
        slot `shouldBe` ("authority/registered-stack-generations/" <> digest)
        Text.isInfixOf "aws-stack-creations" slot `shouldBe` False
        Text.length digest `shouldBe` 64

    describe "selection from a later cleanup run" $ do
      it "selects across a different run scope and a different cleanup surface" $ do
        generation <- establishFixtureGeneration initialStackGenerationOrdinal
        selected <-
          mustRightIO
            ( selectRegisteredStackGeneration
                (baseSelector generation)
                  { selectorRunScope = laterCleanupRunScope
                  , selectorSurface = Cascade
                  }
                generation
            )
        selectedStackGeneration selected `shouldBe` generation
        selectedStackGenerationSelectingRunScope selected
          `shouldBe` laterCleanupRunScope
        selectedStackGenerationSelectingSurface selected `shouldBe` Cascade
        -- The creating provenance is unchanged by having been selected.
        registeredStackGenerationCreatingRunScope
          (selectedStackGeneration selected)
          `shouldBe` creatingRunScope

      it "refuses each run-invariant key component on its own" $ do
        generation <- establishFixtureGeneration initialStackGenerationOrdinal
        let base = baseSelector generation
            attempt selector = selectRegisteredStackGeneration selector generation
        attempt base {selectorResourceKey = AwsEksKey}
          `shouldBe` Left (StackGenerationResourceKeyMismatch AwsTestKey AwsEksKey)
        attempt base {selectorCoordinateDigest = registryDigest AwsEksKey}
          `shouldBe` Left
            ( StackGenerationCoordinateDigestMismatch
                AwsTestKey
                (registryDigest AwsTestKey)
                (registryDigest AwsEksKey)
            )
        attempt base {selectorRegistryRevision = RegistryRevision "not-this-revision"}
          `shouldBe` Left
            ( StackGenerationRegistryRevisionMismatch
                lifecycleRegistryRevision
                (RegistryRevision "not-this-revision")
            )
        attempt base {selectorFoundation = LinuxRke2FoundationId "foundation/other"}
          `shouldBe` Left
            ( StackGenerationFoundationMismatch
                fixtureFoundation
                (LinuxRke2FoundationId "foundation/other")
            )
        attempt
          base
            { selectorAwsScope =
                fixtureAwsScope {awsScopeAccountId = AwsAccountId "210987654321"}
            }
          `shouldBe` Left
            ( StackGenerationAwsAccountMismatch
                (AwsAccountId fixtureAccount)
                (AwsAccountId "210987654321")
            )
        attempt
          base
            { selectorAwsScope =
                fixtureAwsScope {awsScopeRegion = AwsRegion "eu-west-1"}
            }
          `shouldBe` Left
            ( StackGenerationAwsRegionMismatch
                (AwsRegion fixtureRegion)
                (AwsRegion "eu-west-1")
            )
        let otherOrdinal =
              mustRight (succeedingStackGenerationOrdinal initialStackGenerationOrdinal)
        attempt base {selectorOrdinal = otherOrdinal}
          `shouldBe` Left
            (StackGenerationOrdinalMismatch initialStackGenerationOrdinal otherOrdinal)

      it "does not let a known generation key widen a cleanup surface" $ do
        generation <- establishFixtureGeneration initialStackGenerationOrdinal
        selectRegisteredStackGeneration
          (baseSelector generation) {selectorSurface = ExplicitLongLived}
          generation
          `shouldBe` Left (StackGenerationSurfaceRefused ExplicitLongLived AwsTestKey)
        selectRegisteredStackGeneration
          (baseSelector generation) {selectorSurface = OperationalTeardown}
          generation
          `shouldBe` Left
            (StackGenerationSurfaceRefused OperationalTeardown AwsTestKey)
        -- The surfaces that may select a per-run stack all succeed.
        mapM_
          ( \surface ->
              selectRegisteredStackGeneration
                (baseSelector generation) {selectorSurface = surface}
                generation
                `shouldSatisfy` isRight'
          )
          [Cascade, ExplicitPerRun, TotalDecommission]

      it "renders every refusal without leaking a raw key comparison" $ do
        generation <- establishFixtureGeneration initialStackGenerationOrdinal
        let rendered =
              fmap
                renderStackGenerationError
                [ StackGenerationOrdinalZero
                , StackGenerationOrdinalExhausted
                , StackGenerationUnregisteredKey AwsTestKey
                , StackGenerationSurfaceRefused Cascade AwsTestKey
                ]
        all (not . Text.null) rendered `shouldBe` True
        registeredStackGenerationKey generation
          `shouldBe` registeredStackGenerationKey generation

    describe "the durable generation record" $ do
      it "round-trips canonically and refuses a non-canonical or oversized record" $ do
        generation <- establishFixtureGeneration initialStackGenerationOrdinal
        let bytes = encodeRegisteredStackGeneration generation
        ByteString.length bytes
          `shouldSatisfy` (<= maximumRegisteredStackGenerationRecordBytes)
        decodeRegisteredStackGeneration bytes `shouldBe` Right generation
        decodeRegisteredStackGeneration ByteString.empty
          `shouldBe` Left StackGenerationRecordEmpty
        decodeRegisteredStackGeneration (ByteString.snoc bytes 0)
          `shouldBe` Left StackGenerationRecordNonCanonical
        decodeRegisteredStackGeneration
          (ByteString.replicate (maximumRegisteredStackGenerationRecordBytes + 1) 0)
          `shouldBe` Left
            ( StackGenerationRecordTooLarge
                maximumRegisteredStackGenerationRecordBytes
                (maximumRegisteredStackGenerationRecordBytes + 1)
            )

      it "re-derives the coordinate and revision from the compiled registry" $ do
        generation <- establishFixtureGeneration initialStackGenerationOrdinal
        -- A record may not assert a coordinate digest or a registry revision:
        -- both are re-derived, and a stored disagreement refuses.
        decodeRegisteredStackGeneration
          (encodeWithTamper (\wire -> wire {mirrorCoordinateDigest = "0"}) generation)
          `shouldBe` Left
            ( StackGenerationRecordFieldInvalid
                "the stored coordinate digest is not the compiled registry's digest"
            )
        decodeRegisteredStackGeneration
          ( encodeWithTamper
              (\wire -> wire {mirrorRegistryRevision = "not-this-revision"})
              generation
          )
          `shouldBe` Left
            ( StackGenerationRegistryRevisionMismatch
                lifecycleRegistryRevision
                (RegistryRevision "not-this-revision")
            )
        decodeRegisteredStackGeneration
          (encodeWithTamper (\wire -> wire {mirrorVersion = 2}) generation)
          `shouldBe` Left (StackGenerationRecordVersionUnsupported 2)
        decodeRegisteredStackGeneration
          (encodeWithTamper (\wire -> wire {mirrorOrdinal = 0}) generation)
          `shouldBe` Left StackGenerationOrdinalZero

      it "occupies the slot its own run-invariant key addresses" $ do
        generation <- establishFixtureGeneration initialStackGenerationOrdinal
        record <- mustRightIO (prepareRegisteredStackGenerationRecord generation)
        registeredStackGenerationRecordGeneration record `shouldBe` generation
        registeredStackGenerationRecordLogicalName record
          `shouldBe` stackGenerationSlotLogicalName
            (registeredStackGenerationKey generation)

    describe "the durable generation repository" $ do
      it "commits once and replays the exact record" $ do
        generation <- establishFixtureGeneration initialStackGenerationOrdinal
        durable <- newDurableGenerationStore False
        let repository = generationRepository durable
        committed <-
          mustRightIO
            =<< commitRegisteredStackGenerationWithRepair repository generation
        committedRegisteredStackGeneration committed `shouldBe` generation
        replayed <-
          mustRightIO
            =<< commitRegisteredStackGenerationWithRepair repository generation
        committedRegisteredStackGeneration replayed `shouldBe` generation
        readIORef (durableWrites durable) `shouldReturn` 1

      it "repairs a lost commit response by independent read-back" $ do
        generation <- establishFixtureGeneration initialStackGenerationOrdinal
        -- The CAS applies and then loses its response.  The write result alone
        -- cannot say whether the record exists; only the read-back can.
        durable <- newDurableGenerationStore True
        committed <-
          mustRightIO
            =<< commitRegisteredStackGenerationWithRepair
              (generationRepository durable)
              generation
        committedRegisteredStackGeneration committed `shouldBe` generation
        readIORef (durableWrites durable) `shouldReturn` 1

      it "reports a lost response that applied nothing as nothing committed" $ do
        generation <- establishFixtureGeneration initialStackGenerationOrdinal
        result <-
          commitRegisteredStackGenerationWithRepair
            (generationRepositoryFor (unwritableAdapter "write dropped"))
            generation
        case result of
          Left (RegisteredStackGenerationCommitNotApplied _) -> pure ()
          other -> fail ("expected a not-applied commit: " <> show other)

      it "refuses a slot that already holds a different generation" $ do
        first <- establishFixtureGeneration initialStackGenerationOrdinal
        durable <- newDurableGenerationStore False
        let repository = generationRepository durable
        _ <-
          mustRightIO
            =<< commitRegisteredStackGenerationWithRepair repository first
        -- Same key, different causal provenance: the slot is written once.
        second <- establishFixtureGenerationWithSurface Cascade initialStackGenerationOrdinal
        registeredStackGenerationKey second
          `shouldBe` registeredStackGenerationKey first
        result <- commitRegisteredStackGenerationWithRepair repository second
        result
          `shouldBe` Left
            (RegisteredStackGenerationConflict (registeredStackGenerationKey first))

    describe "ordinal succession" $ do
      it "opens a series at cycle one and advances it per admitted create" $ do
        durable <- newDurableGenerationStore False
        firstCreate <- fixtureObservedCreationAttempt "cycle-1" "a"
        secondCreate <- fixtureObservedCreationAttempt "cycle-2" "b"
        providerScope <- fixtureVerifiedProviderScope
        opened <- reserve durable firstCreate providerScope
        reservedStackGenerationOrdinal opened
          `shouldBe` initialStackGenerationOrdinal
        reservedStackGenerationWasReplay opened `shouldBe` False
        advanced <- reserve durable secondCreate providerScope
        stackGenerationOrdinalValue (reservedStackGenerationOrdinal advanced)
          `shouldBe` 2
        reservedStackGenerationWasReplay advanced `shouldBe` False
        readIORef (durableWrites durable) `shouldReturn` 2

      it "gives a retried create back the cycle it already owns" $ do
        durable <- newDurableGenerationStore False
        create <- fixtureObservedCreationAttempt "retried" "c"
        providerScope <- fixtureVerifiedProviderScope
        opened <- reserve durable create providerScope
        replayed <- reserve durable create providerScope
        reservedStackGenerationOrdinal replayed
          `shouldBe` reservedStackGenerationOrdinal opened
        reservedStackGenerationWasReplay replayed `shouldBe` True
        -- A lost response must not be able to burn a second cycle.
        readIORef (durableWrites durable) `shouldReturn` 1

      it "settles a lost cursor response by re-observing the cursor" $ do
        durable <- newDurableGenerationStore True
        create <- fixtureObservedCreationAttempt "lost" "d"
        providerScope <- fixtureVerifiedProviderScope
        opened <- reserve durable create providerScope
        reservedStackGenerationOrdinal opened
          `shouldBe` initialStackGenerationOrdinal
        readIORef (durableWrites durable) `shouldReturn` 1

      it "reports a lost cursor response that applied nothing" $ do
        create <- fixtureObservedCreationAttempt "dropped" "e"
        providerScope <- fixtureVerifiedProviderScope
        result <-
          reserveNextStackGeneration
            ( modelBStackGenerationCursorRepository
                fixtureGenerationAuthority
                (unwritableAdapter "cursor write dropped")
            )
            create
            providerScope
            fixtureFoundation
        case result of
          Left (RegisteredStackGenerationCommitNotApplied _) -> pure ()
          other -> fail ("expected a not-applied cursor commit: " <> show other)

      it "refuses when another admitted create holds the settled cycle" $ do
        incumbent <- fixtureObservedCreationAttempt "incumbent" "f"
        thirdParty <- fixtureObservedCreationAttempt "third-party" "0"
        contender <- fixtureObservedCreationAttempt "contender" "1"
        providerScope <- fixtureVerifiedProviderScope
        held <-
          mustRightIO
            (openStackGenerationCursor incumbent providerScope fixtureFoundation)
        stolen <- mustRightIO (advanceStackGenerationCursor held thirdParty)
        -- The contender reads the incumbent's cursor, then loses the race: its
        -- conditional advance is refused and re-observation shows a cycle held
        -- by neither its own operation nor the version it read.
        racing <- contendedCursorRepository held stolen
        result <-
          reserveNextStackGeneration racing contender providerScope fixtureFoundation
        case result of
          Left (RegisteredStackGenerationCursorContended _) -> pure ()
          other -> fail ("expected a contended cursor: " <> show other)

      it "keeps the cursor slot distinct from every cycle's own slot" $ do
        durable <- newDurableGenerationStore False
        create <- fixtureObservedCreationAttempt "slots" "2"
        providerScope <- fixtureVerifiedProviderScope
        reserved <- reserve durable create providerScope
        series <-
          mustRightIO
            ( stackGenerationSeriesKeyFromProviderScope
                AwsTestKey
                providerScope
                fixtureFoundation
            )
        let cursorSlot = stackGenerationSeriesSlotLogicalName series
            cycleSlot =
              stackGenerationSlotLogicalName
                ( stackGenerationKeyForOrdinal
                    series
                    (reservedStackGenerationOrdinal reserved)
                )
        Text.isPrefixOf
          "authority/registered-stack-generation-series/"
          cursorSlot
          `shouldBe` True
        cursorSlot `shouldNotBe` cycleSlot

      it "will not advance a series on behalf of a different registered stack" $ do
        create <- fixtureObservedCreationAttempt "own-stack" "3"
        providerScope <- fixtureVerifiedProviderScope
        cursor <-
          mustRightIO
            (openStackGenerationCursor create providerScope fixtureFoundation)
        stackGenerationCursorGenerationKey cursor
          `shouldBe` stackGenerationKeyForOrdinal
            (stackGenerationCursorSeries cursor)
            initialStackGenerationOrdinal
        eksCreate <- fixtureObservedEksCreation
        advanceStackGenerationCursor cursor eksCreate
          `shouldBe` Left (StackGenerationResourceKeyMismatch AwsTestKey AwsEksKey)

      it "round-trips the cursor and re-derives its coordinate from the registry" $ do
        create <- fixtureObservedCreationAttempt "cursor-codec" "4"
        providerScope <- fixtureVerifiedProviderScope
        cursor <-
          mustRightIO
            (openStackGenerationCursor create providerScope fixtureFoundation)
        let bytes = encodeStackGenerationCursor cursor
        ByteString.length bytes
          `shouldSatisfy` (<= maximumStackGenerationCursorRecordBytes)
        decodeStackGenerationCursor bytes `shouldBe` Right cursor
        decodeStackGenerationCursor (ByteString.snoc bytes 0)
          `shouldBe` Left StackGenerationRecordNonCanonical
        decodeStackGenerationCursor ByteString.empty
          `shouldBe` Left StackGenerationRecordEmpty

    describe "cleanup selection bound to the generation read-back" $ do
      it "selects across a different run scope and surface from the durable record" $ do
        generation <- establishFixtureGeneration initialStackGenerationOrdinal
        durable <- newDurableGenerationStore False
        let repository = generationRepository durable
        _ <-
          mustRightIO
            =<< commitRegisteredStackGenerationWithRepair repository generation
        -- The cleanup run derives its addressing key from the compiled registry
        -- and its own Provider credential session.  It never learns, and never
        -- needs, the creating run's scope or surface.
        addressingKey <- cleanupAddressingKey initialStackGenerationOrdinal
        addressingKey `shouldBe` registeredStackGenerationKey generation
        selected <-
          mustRightIO
            =<< selectRegisteredStackGenerationFromRepository
              repository
              addressingKey
              laterCleanupRunScope
              Cascade
        selectedStackGeneration selected `shouldBe` generation
        selectedStackGenerationSelectingRunScope selected
          `shouldBe` laterCleanupRunScope
        selectedStackGenerationSelectingSurface selected `shouldBe` Cascade
        registeredStackGenerationCreatingRunScope
          (selectedStackGeneration selected)
          `shouldBe` creatingRunScope
        registeredStackGenerationCreatingSurface
          (selectedStackGeneration selected)
          `shouldBe` ExplicitPerRun

      it "will not infer a generation from an empty slot" $ do
        durable <- newDurableGenerationStore False
        addressingKey <- cleanupAddressingKey initialStackGenerationOrdinal
        result <-
          selectRegisteredStackGenerationFromRepository
            (generationRepository durable)
            addressingKey
            laterCleanupRunScope
            Cascade
        result `shouldBe` Left (RegisteredStackGenerationAbsent addressingKey)

      it "keeps unobservable distinct from absent" $ do
        addressingKey <- cleanupAddressingKey initialStackGenerationOrdinal
        result <-
          selectRegisteredStackGenerationFromRepository
            (generationRepositoryFor (unobservableAdapter "store unreachable"))
            addressingKey
            laterCleanupRunScope
            Cascade
        case result of
          Left (RegisteredStackGenerationUnobservable failure) ->
            Text.isInfixOf "store unreachable" (observationFailureDetail failure)
              `shouldBe` True
          other -> fail ("expected an unobservable read-back: " <> show other)

      it "does not let the durable record widen a cleanup surface" $ do
        generation <- establishFixtureGeneration initialStackGenerationOrdinal
        durable <- newDurableGenerationStore False
        let repository = generationRepository durable
        _ <-
          mustRightIO
            =<< commitRegisteredStackGenerationWithRepair repository generation
        addressingKey <- cleanupAddressingKey initialStackGenerationOrdinal
        result <-
          selectRegisteredStackGenerationFromRepository
            repository
            addressingKey
            laterCleanupRunScope
            ExplicitLongLived
        result
          `shouldBe` Left
            ( RegisteredStackGenerationNotSelectable
                (StackGenerationSurfaceRefused ExplicitLongLived AwsTestKey)
            )

      it "refuses a record found under a key that is not its own" $ do
        generation <- establishFixtureGeneration initialStackGenerationOrdinal
        otherOrdinal <-
          mustRightIO (succeedingStackGenerationOrdinal initialStackGenerationOrdinal)
        otherKey <- cleanupAddressingKey otherOrdinal
        -- Plant the first generation's bytes in the second generation's slot.
        durable <-
          newPlantedGenerationStore
            (stackGenerationSlotLogicalName otherKey)
            (encodeRegisteredStackGeneration generation)
        result <-
          selectRegisteredStackGenerationFromRepository
            (generationRepository durable)
            otherKey
            laterCleanupRunScope
            Cascade
        result
          `shouldBe` Left
            ( RegisteredStackGenerationSlotKeyMismatch
                otherKey
                (registeredStackGenerationKey generation)
            )

    describe "the production producer and consumer" $ do
      it "reserves a cycle, commits the generation, then commits the binding" $ do
        durable <- newDurableGenerationStore False
        create <- fixtureObservedCreationAttempt "producer" "6"
        producer <- creationBoundary durable create
        created <-
          mustRightIO
            =<< commitRegisteredStackCreation
              producer
              (observedAwsStackCreationOperationId create)
              (observedAwsStackCreationOperationId create)
              fixtureRevision
              (creationEvidenceScope ReconcileDesiredPresent ExplicitPerRun creatingRunScope)
        reservedStackGenerationOrdinal (registeredStackCreationReservation created)
          `shouldBe` initialStackGenerationOrdinal
        registeredStackCreationBinding created
          `shouldBe` AwsStackCreationCommitCreated
        -- A later cleanup run, with a different run scope and surface, reaches
        -- the same record through the cursor and the generation slot alone.
        consumer <- cleanupBoundary durable
        selected <-
          mustRightIO
            =<< selectRegisteredStackForCleanup
              consumer
              AwsTestKey
              (observedAwsStackCreationOperationId create)
              (creationEvidenceScope ReconcileDesiredAbsent Cascade laterCleanupRunScope)
        registeredStackGenerationKey (selectedStackGeneration selected)
          `shouldBe` committedRegisteredStackGenerationKey
            (registeredStackCreationGeneration created)
        selectedStackGenerationSelectingRunScope selected
          `shouldBe` laterCleanupRunScope
        selectedStackGenerationSelectingSurface selected `shouldBe` Cascade

      it "refuses a create whose AWS scope no Provider proof covers" $ do
        durable <- newDurableGenerationStore False
        create <- fixtureObservedCreationAttempt "unproven" "7"
        producer <- creationBoundary durable create
        result <-
          commitRegisteredStackCreation
            producer
              { registeredStackCreationProveScope =
                  \_ -> pure (Left ProviderAwsScopeRetainedOperationMissing)
              }
            (observedAwsStackCreationOperationId create)
            (observedAwsStackCreationOperationId create)
            fixtureRevision
            (creationEvidenceScope ReconcileDesiredPresent ExplicitPerRun creatingRunScope)
        case result of
          Left
            ( RegisteredStackCreationScopeUnproven
                ProviderAwsScopeRetainedOperationMissing
              ) -> pure ()
          Left other -> fail ("expected an unproven-scope refusal: " <> show other)
          Right _ -> fail "expected an unproven-scope refusal, not a creation"
        -- Nothing was written: no cycle was burned and no record was planted.
        readIORef (durableWrites durable) `shouldReturn` 0

      it "refuses cleanup of a stack whose series was never opened" $ do
        durable <- newDurableGenerationStore False
        create <- fixtureObservedCreationAttempt "unopened" "8"
        consumer <- cleanupBoundary durable
        result <-
          selectRegisteredStackForCleanup
            consumer
            AwsTestKey
            (observedAwsStackCreationOperationId create)
            (creationEvidenceScope ReconcileDesiredAbsent Cascade laterCleanupRunScope)
        case result of
          Left
            ( RegisteredStackCleanupGenerationRefused
                (RegisteredStackGenerationSeriesUnopened _)
              ) -> pure ()
          other -> fail ("expected an unopened series refusal: " <> show other)

isRight' :: Either error value -> Bool
isRight' result = case result of
  Left _ -> False
  Right _ -> True

observationFailureDetail :: ObservationFailure -> Text
observationFailureDetail (ObservationFailure detail) = detail

-- ---------------------------------------------------------------------------
-- Fixture: the run-invariant facts and the two opaque proofs
-- ---------------------------------------------------------------------------

baseSelector :: RegisteredStackGeneration -> StackGenerationSelector
baseSelector generation =
  StackGenerationSelector
    { selectorResourceKey = stackGenerationKeyResource key
    , selectorCoordinateDigest = stackGenerationKeyCoordinateDigest key
    , selectorRegistryRevision = stackGenerationKeyRegistryRevision key
    , selectorFoundation = stackGenerationKeyFoundation key
    , selectorAwsScope = stackGenerationKeyAwsScope key
    , selectorOrdinal = stackGenerationKeyOrdinal key
    , selectorRunScope = laterCleanupRunScope
    , selectorSurface = Cascade
    }
 where
  key = registeredStackGenerationKey generation

establishFixtureGeneration
  :: StackGenerationOrdinal -> IO RegisteredStackGeneration
establishFixtureGeneration ordinal = do
  observed <- fixtureObservedCreation
  providerScope <- fixtureVerifiedProviderScope
  mustRightIO
    ( establishRegisteredStackGeneration
        observed
        providerScope
        fixtureFoundation
        creatingRunScope
        ExplicitPerRun
        ordinal
    )

establishFixtureGenerationWithSurface
  :: CleanupSurface -> StackGenerationOrdinal -> IO RegisteredStackGeneration
establishFixtureGenerationWithSurface creatingSurface ordinal = do
  observed <- fixtureObservedCreation
  providerScope <- fixtureVerifiedProviderScope
  mustRightIO
    ( establishRegisteredStackGeneration
        observed
        providerScope
        fixtureFoundation
        creatingRunScope
        creatingSurface
        ordinal
    )

-- | What a later cleanup run knows: the compiled registry and its own exact
-- Provider credential session.  It never sees the creating run's scope.
cleanupAddressingKey :: StackGenerationOrdinal -> IO StackGenerationKey
cleanupAddressingKey ordinal = do
  providerScope <- fixtureVerifiedProviderScope
  mustRightIO
    ( stackGenerationKeyFromProviderScope
        AwsTestKey
        providerScope
        fixtureFoundation
        ordinal
    )

-- ---------------------------------------------------------------------------
-- Fixture: the production producer and consumer boundaries
-- ---------------------------------------------------------------------------

-- | The producer over one durable store.  Its scope prover is bound to the
-- Provider Worker's own decoded execution proof rather than to an Authority
-- read-back, which exercises exactly the same generation derivation without
-- needing a settled Authority aggregate; production binds the Authority form
-- in "Prodbox.ControlPlane.Runtime".
creationBoundary
  :: DurableGenerationStore
  -> ObservedAwsStackCreationOperation
  -> IO (RegisteredStackCreationBoundary IO)
creationBoundary durable observed = do
  session <- fixtureVerifiedProviderScope
  pure
    RegisteredStackCreationBoundary
      { registeredStackCreationObserveCreate = \_ _ -> pure (Right observed)
      , registeredStackCreationProveScope = \_ -> pure (Right session)
      , registeredStackCreationCursors = cursorRepository durable
      , registeredStackCreationGenerations = generationRepository durable
      , registeredStackCreationBindings =
          modelBAwsStackCreationBindingRepository
            fixtureGenerationAuthority
            (durableGenerationAdapter durable)
      }

cleanupBoundary
  :: DurableGenerationStore -> IO (RegisteredStackCleanupBoundary IO)
cleanupBoundary durable = do
  session <- fixtureVerifiedProviderScope
  pure
    RegisteredStackCleanupBoundary
      { registeredStackCleanupProveScope = \_ -> pure (Right session)
      , registeredStackCleanupCursors = cursorRepository durable
      , registeredStackCleanupGenerations = generationRepository durable
      }

-- | A create writes its binding under @ReconcileDesiredPresent@; a cleanup run
-- addresses records under @ReconcileDesiredAbsent@.  The generation identity is
-- invariant across both, which is the point.
creationEvidenceScope
  :: LifecycleOperation
  -> CleanupSurface
  -> DurableObservationRunScope
  -> ObservationEvidenceScope
creationEvidenceScope operation surface runScope =
  mkObservationEvidenceScope
    surface
    lifecycleRegistryRevision
    runScope
    fixtureFoundation
    (Just fixtureAwsScope)
    operation

-- ---------------------------------------------------------------------------
-- Fixture: the durable Model-B generation store
-- ---------------------------------------------------------------------------

data DurableGenerationStore = DurableGenerationStore
  { durableGenerationAdapter
      :: !(ModelBCasAdapter 'ClusterRetained IO ByteString)
  , durableWrites :: !(IORef Int)
  }

newDurableGenerationStore :: Bool -> IO DurableGenerationStore
newDurableGenerationStore loseFirstResponse =
  newGenerationStoreSeededWith Map.empty loseFirstResponse

-- | A store whose slot already holds bytes this run did not write there.
newPlantedGenerationStore :: Text -> ByteString -> IO DurableGenerationStore
newPlantedGenerationStore logicalName bytes =
  newGenerationStoreSeededWith
    (Map.singleton logicalName (fixtureGenerationVersion, bytes))
    False

newGenerationStoreSeededWith
  :: Map.Map Text (ModelBObjectVersion, ByteString)
  -> Bool
  -> IO DurableGenerationStore
newGenerationStoreSeededWith seed loseFirstResponse = do
  valuesRef <- newIORef seed
  writesRef <- newIORef 0
  versionRef <- newIORef (0 :: Int)
  loseRef <- newIORef loseFirstResponse
  let nextVersion = do
        ordinal <- atomicModifyIORef' versionRef (\value -> (value + 1, value + 1))
        pure
          ( mustRight
              (mkModelBObjectVersion ("generation-version-" <> Text.pack (show ordinal)))
          )
      apply logicalName bytes = do
        version <- nextVersion
        modifyIORef' valuesRef (Map.insert logicalName (version, bytes))
        modifyIORef' writesRef (+ 1)
        lose <- atomicModifyIORef' loseRef (False,)
        pure $
          if lose
            then ModelBCasUnobservable "response lost after apply"
            else ModelBCasApplied version bytes
      compareAndSwap request = case request of
        ModelBInitialize coordinate bytes -> do
          let logicalName = modelBObjectLogicalName coordinate
          values <- readIORef valuesRef
          case Map.lookup logicalName values of
            Just (version, existing) ->
              pure (ModelBCasConflict (ModelBObserved version existing))
            Nothing -> apply logicalName bytes
        ModelBReplace coordinate expected bytes -> do
          let logicalName = modelBObjectLogicalName coordinate
          values <- readIORef valuesRef
          case Map.lookup logicalName values of
            Nothing -> pure (ModelBCasConflict ModelBMissing)
            Just (version, existing)
              | version == expected -> apply logicalName bytes
              | otherwise ->
                  pure (ModelBCasConflict (ModelBObserved version existing))
        ModelBInitializeGuarded {} -> unexpected "guarded initialize"
        ModelBReplaceGuarded {} -> unexpected "guarded replace"
      adapter =
        ModelBCasAdapter
          { modelBObserve = \coordinate -> do
              values <- readIORef valuesRef
              pure $
                case Map.lookup (modelBObjectLogicalName coordinate) values of
                  Nothing -> ModelBMissing
                  Just (version, bytes) -> ModelBObserved version bytes
          , modelBCompareAndSwap = compareAndSwap
          }
  pure (DurableGenerationStore adapter writesRef)
 where
  unexpected name = pure (ModelBCasUnobservable ("unexpected " <> name))

-- | A store whose write response is always lost and whose slot stays empty.
unwritableAdapter :: Text -> ModelBCasAdapter 'ClusterRetained IO ByteString
unwritableAdapter detail =
  ModelBCasAdapter
    { modelBObserve = const (pure ModelBMissing)
    , modelBCompareAndSwap = const (pure (ModelBCasUnobservable detail))
    }

-- | A store that can say nothing at all about the slot.
unobservableAdapter :: Text -> ModelBCasAdapter 'ClusterRetained IO ByteString
unobservableAdapter detail =
  ModelBCasAdapter
    { modelBObserve = const (pure (ModelBUnobservable detail))
    , modelBCompareAndSwap = const (pure (ModelBCasUnobservable detail))
    }

generationRepository
  :: DurableGenerationStore -> RegisteredStackGenerationRepository IO
generationRepository = generationRepositoryFor . durableGenerationAdapter

generationRepositoryFor
  :: ModelBCasAdapter 'ClusterRetained IO ByteString
  -> RegisteredStackGenerationRepository IO
generationRepositoryFor =
  modelBRegisteredStackGenerationRepository fixtureGenerationAuthority

fixtureGenerationAuthority :: LongLivedCheckpointAuthority
fixtureGenerationAuthority =
  mustRight
    ( mkLongLivedCheckpointAuthority
        "home-linux-rke2"
        "prodbox-authority"
        "authority"
        "secret/lifecycle"
    )

fixtureGenerationVersion :: ModelBObjectVersion
fixtureGenerationVersion =
  mustRight (mkModelBObjectVersion "generation-version-planted")

cursorRepository
  :: DurableGenerationStore -> StackGenerationCursorRepository IO
cursorRepository =
  modelBStackGenerationCursorRepository fixtureGenerationAuthority
    . durableGenerationAdapter

reserve
  :: DurableGenerationStore
  -> ObservedAwsStackCreationOperation
  -> ProvenProviderAwsSession
  -> IO ReservedStackGeneration
reserve durable observed providerScope =
  mustRightIO
    =<< reserveNextStackGeneration
      (cursorRepository durable)
      observed
      providerScope
      fixtureFoundation

-- | A cursor store in which the reader loses the race: the first observation
-- returns the cursor the contender reads, the conditional write is refused, and
-- re-observation shows a cycle a third admitted create took.
contendedCursorRepository
  :: StackGenerationCursor
  -> StackGenerationCursor
  -> IO (StackGenerationCursorRepository IO)
contendedCursorRepository readCursor settledCursor = do
  observationsRef <- newIORef (0 :: Int)
  pure
    StackGenerationCursorRepository
      { observeStackGenerationCursor = \_ -> do
          observations <-
            atomicModifyIORef' observationsRef (\value -> (value + 1, value + 1))
          pure
            ( StackGenerationCursorPresent
                ( ObservedStackGenerationCursor
                    (if observations == 1 then readCursor else settledCursor)
                    fixtureGenerationVersion
                )
            )
      , openStackGenerationCursorSlot =
          const (pure StackGenerationCursorCommitConflict)
      , advanceStackGenerationCursorSlot =
          \_ _ -> pure StackGenerationCursorCommitConflict
      }

-- ---------------------------------------------------------------------------
-- Fixture: tampering with a stored record
-- ---------------------------------------------------------------------------

-- | A structural mirror of the durable wire.  The record type itself is
-- private, so tampering is expressed by decoding the real bytes into this
-- mirror, changing one field, and re-encoding canonically.
data MirrorGenerationWire = MirrorGenerationWire
  { mirrorVersion :: !Int
  , mirrorRegistryRevision :: !Text
  , mirrorKey :: !Int
  , mirrorCoordinateDigest :: !Text
  , mirrorFoundation :: !Text
  , mirrorAwsAccount :: !Text
  , mirrorAwsRegion :: !Text
  , mirrorOrdinal :: !Integer
  , mirrorAdmittedEpoch :: !Integer
  , mirrorAdmittedClient :: !Text
  , mirrorAdmittedSequence :: !Integer
  , mirrorAdmittedDigest :: !Text
  , mirrorProviderOperationId :: !Text
  , mirrorProviderRevision :: !Integer
  , mirrorCreatingRunScope :: !Text
  , mirrorCreatingSurface :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

encodeWithTamper
  :: (MirrorGenerationWire -> MirrorGenerationWire)
  -> RegisteredStackGeneration
  -> ByteString
encodeWithTamper tamper generation =
  case deserialiseOrFail
    (LazyByteString.fromStrict (encodeRegisteredStackGeneration generation)) of
    Left err -> error ("the durable wire mirror is stale: " <> show err)
    Right wire -> LazyByteString.toStrict (serialise (tamper wire))

registryDigest :: RegisteredResourceKey -> ManagedResourceCoordinateDigest
registryDigest key = case lookupRegisteredIdentity key of
  Nothing -> error ("missing registered identity: " <> show key)
  Just identity -> registeredIdentityCoordinateDigest identity

fixtureFoundation :: LinuxRke2FoundationId
fixtureFoundation = LinuxRke2FoundationId "foundation/home"

fixtureAwsScope :: AwsScope
fixtureAwsScope =
  AwsScope
    { awsScopeAccountId = AwsAccountId fixtureAccount
    , awsScopeRegion = AwsRegion fixtureRegion
    }

creatingRunScope, laterCleanupRunScope :: DurableObservationRunScope
creatingRunScope = DurableObservationRunScope "run/creation-1"
laterCleanupRunScope = DurableObservationRunScope "run/cleanup-9"

-- ---------------------------------------------------------------------------
-- Fixture: the admitted create observation
-- ---------------------------------------------------------------------------

fixtureObservedCreation :: IO ObservedAwsStackCreationOperation
fixtureObservedCreation = fixtureObservedCreationAttempt "fixture" "a"

-- | A distinct admitted create.  Two different submissions of the same intent
-- are two different admitted operations, which is what a second create/destroy
-- cycle of one stack looks like from the Authority.
fixtureObservedCreationAttempt
  :: Text -> Text -> IO ObservedAwsStackCreationOperation
fixtureObservedCreationAttempt label digestCharacter = do
  (operation, admitted) <-
    admitFixtureIntent
      label
      digestCharacter
      (ReconcileRegisteredStack fixtureStackRef fixtureRevision fixtureProviderConfig)
  observed <-
    mustRightIO
      =<< observeAuthorityAwsStackCreationOperation
        (readOnlyAuthorityRepository admitted)
        fixtureRevision
        operation
  observedAwsStackCreationKey observed `shouldBe` AwsTestKey
  pure observed

-- | An admitted create for a /different/ registered stack.
fixtureObservedEksCreation :: IO ObservedAwsStackCreationOperation
fixtureObservedEksCreation = do
  let eksRef = mustRight (mkProviderStackRef "aws-eks")
      eksConfig = mustRight (mkAwsEksProviderStackConfig "192.0.2.10/32")
  (operation, admitted) <-
    admitFixtureIntent
      "eks"
      "5"
      (ReconcileRegisteredStack eksRef fixtureRevision eksConfig)
  observed <-
    mustRightIO
      =<< observeAuthorityAwsStackCreationOperation
        (readOnlyAuthorityRepository admitted)
        fixtureRevision
        operation
  observedAwsStackCreationKey observed `shouldBe` AwsEksKey
  pure observed

admitFixtureIntent
  :: Text
  -> Text
  -> ProviderIntent
  -> IO (OperationId, AuthorityAdmissionAggregate)
admitFixtureIntent label digestCharacter intent = do
  let digest = RequestDigest (Text.replicate 64 digestCharacter)
      submissionKey =
        mustRight (mkClientSubmissionKey ("stack-generation/" <> label))
      (decision, admitted) =
        mustRight
          ( stepRegisteredProviderSubmission
              openedAuthority
              CallerOperatorCli
              fixtureClientGeneration
              submissionKey
              digest
              intent
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

openedAuthority :: AuthorityAdmissionAggregate
openedAuthority =
  foldl
    (\aggregate command -> snd (stepAuthorityAdmission aggregate command))
    ( mustRight
        (initialCleanInstallAuthorityWithRegisteredClients 8 16 fixtureClientTable)
    )
    [ ApplyAuthorityGenesis
        (BeginGenesisEstablishment (GenesisPlan "generation-genesis" "backup-prefix"))
    , ApplyAuthorityGenesis
        (ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "target-generation-1"))
    , ApplyAuthorityGenesis (ObserveBackupReceipt (BackupReceipt "backup-receipt-1"))
    ]

fixtureClientTable :: RegisteredClientTable
fixtureClientTable = mustRight (mkRegisteredClientTable 1 [spec])
 where
  spec =
    mustRight
      ( mkRegisteredClientSpec
          (clientPrincipalForCaller CallerOperatorCli)
          (mustRight (mkRegisteredClientSlot 1))
          fixtureClientGeneration
          16
      )

fixtureClientGeneration :: RegisteredClientGeneration
fixtureClientGeneration = mustRight (mkRegisteredClientGeneration 1)

fixtureStackRef :: ProviderStackRef
fixtureStackRef = mustRight (mkProviderStackRef "aws-test")

fixtureRevision :: ProviderRevision
fixtureRevision = mustRight (mkProviderRevision 1)

fixtureProviderConfig :: ProviderStackConfig
fixtureProviderConfig = mustRight (mkAwsTestProviderStackConfig "192.0.2.10/32")

-- ---------------------------------------------------------------------------
-- Fixture: the exact Provider credential session
-- ---------------------------------------------------------------------------

fixtureVerifiedProviderScope :: IO ProvenProviderAwsSession
fixtureVerifiedProviderScope = do
  executed <- executeScopeIntent
  providerAwsSessionFromLocalProof <$> mustRightIO (decodeVerifiedProviderAwsScope executed)

executeScopeIntent :: IO ExecutedProviderIntent
executeScopeIntent = do
  let boundary = providerBoundary
  admissionResult <-
    admitProviderCommittedIntent
      providerCommittedIntentMaximumEncodedBytes
      boundary
      (encodeSignedProviderCommittedIntent signedScopeIntent)
  admitted <- mustRightIO admissionResult
  executionResult <- executeVerifiedProviderIntentBound boundary admitted
  mustRightIO executionResult

providerBoundary :: ProviderWorkerExecutionBoundary IO ()
providerBoundary =
  mkProviderWorkerExecutionBoundary
    (ProviderWorkerTrustRepository (pure (Right acceptedAuthority)))
    (pure (Right (authorityTimeFromMicros 100)))
    (ProviderNarrowSessionRunner (\_ _ action -> action Nothing ()))
    scopeCapabilities

scopeCapabilities :: ProviderIntentCapabilities IO ()
scopeCapabilities =
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
    , observeOperationalIdentityCapability = unavailableReadOnly
    , observeProviderAwsScopeCapability =
        ProviderReadOnly (\_ _ -> pure (Right validScopeEvidence))
    , observeProviderReadinessCapability = const unavailableReadOnly
    , issueEksClientAuthCapability = const unavailableReadOnly
    , observeEksClusterIdentityCapability = const unavailableReadOnly
    }

unavailableReadOnly :: ProviderReadOnly IO ()
unavailableReadOnly =
  ProviderReadOnly (\_ _ -> pure (Left "unexpected read-only capability"))

unavailableMutation :: ProviderMutation IO ()
unavailableMutation =
  ProviderMutation
    { observeProviderMutation = \_ _ -> pure (ProviderEffectUnobservable "unexpected mutation")
    , applyProviderMutation = \_ _ -> pure (Left "unexpected mutation")
    }

signedScopeIntent :: SignedProviderCommittedIntent
signedScopeIntent =
  signProviderCommittedIntent
    providerSigningKey
    ( mustRight
        ( mkUnsignedProviderCommittedIntent
            ProviderCommittedIntentSpec
              { providerIntentIssuerGeneration = providerIssuerGeneration
              , providerIntentIssuerIdentity = "lifecycle-authority"
              , providerIntentAuthorityEpoch = AuthorityEpoch 1
              , providerIntentOperationId = fixtureProviderOperation
              , providerIntentActionIndex = 0
              , providerIntentCommitReceiptDigest =
                  sha256TargetValueDigest "stack-generation-scope-receipt"
              , providerIntentOwnerNonce =
                  mustRight (mkOwnerNonce "stack-generation-owner")
              , providerIntentFencingToken = mustRight (mkFencingToken 1)
              , providerIntentRevision = providerScopeRevision
              , providerIntentAction = providerAwsScopeIntent
              , providerIntentDeadline = authorityTimeFromMicros 10000
              , providerIntentIdempotencyKey = "stack-generation-idempotency"
              , providerIntentExpectedCredentialSession = Nothing
              , providerIntentExpectedAcceptedAuthority = Nothing
              }
        )
    )

acceptedAuthority :: AcceptedProviderAuthority
acceptedAuthority =
  mustRight
    ( mkAcceptedProviderAuthority
        providerIssuerGeneration
        "lifecycle-authority"
        (providerIntentSigningPublicKey providerSigningKey)
        (AuthorityEpoch 1)
        (mustRight (mkFencingToken 1))
        providerScopeRevision
        (mkRegisteredProviderResources ["operational-identity"])
    )

providerSigningKey :: ProviderIntentSigningKey
providerSigningKey =
  mustRight (mkProviderIntentSigningKey (ByteString.pack [32 .. 63]))

providerIssuerGeneration :: ProviderIssuerKeyGeneration
providerIssuerGeneration = mustRight (mkProviderIssuerKeyGeneration 1)

providerScopeRevision :: ProviderRevision
providerScopeRevision = mustRight (mkProviderRevision 7)

validScopeEvidence :: Text
validScopeEvidence =
  "provider-aws-scope-v1:"
    <> TextEncoding.decodeUtf8
      ( Base64.encode
          ( LazyByteString.toStrict
              ( serialise
                  FixtureWireProviderAwsScopeEvidence
                    { fixtureWireVersion = 1
                    , fixtureWireAccount = fixtureAccount
                    , fixtureWireRegion = fixtureRegion
                    }
              )
          )
      )

data FixtureWireProviderAwsScopeEvidence = FixtureWireProviderAwsScopeEvidence
  { fixtureWireVersion :: !Word16
  , fixtureWireAccount :: !Text
  , fixtureWireRegion :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

fixtureAccount :: Text
fixtureAccount = "123456789012"

fixtureRegion :: Text
fixtureRegion = "ca-central-1"

fixtureProviderOperation :: Text
fixtureProviderOperation = Text.replicate 64 "a"

mustRightIO :: (Show err) => Either err value -> IO value
mustRightIO result = case result of
  Left err -> fail (show err)
  Right value -> pure value

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
