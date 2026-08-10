{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (void)
import Data.IORef
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (ControlPlaneRequestInvalid)
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.Coordinate (mkAuthorityScope)
import Prodbox.ControlPlane.MigrationEndpoint
  ( MigrationEndpointResult (MigrationEndpointApplied)
  , serveAuthorityMigrationApply
  )
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.Route (ControlPlaneRoute (LifecycleOperationSubmit))
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.Admission
import Prodbox.Lifecycle.Authority.BackupRepair
  ( BackupHealth (..)
  , BackupRepairCommand (AssessBackupHealth)
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityEpoch
  , AuthorityGenesisCommand (..)
  , BackupReceipt (BackupReceipt)
  , GenesisPlan (GenesisPlan)
  , TargetAgentGenerationReceipt (TargetAgentGenerationReceipt)
  , authorityEpochGenesis
  , nextAuthorityEpoch
  )
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationBinding
  , MigrationCommand (..)
  , MigrationDecision (MigrationRefused)
  , MigrationDigest
  , MigrationEpoch
  , MigrationForwardCommand (BeginForwardMigration)
  , MigrationImportCommand (..)
  , MigrationProjection
  , MigrationProjectionImport (ProjectionMissing)
  , MigrationRefusal (ShadowDigestConflict)
  , encodeMigrationCommand
  , mkMigrationDigest
  , mkMigrationEpoch
  )
import Prodbox.Lifecycle.Authority.Submission
  ( ClientId (ClientId)
  , ClientSequence (ClientSequence)
  , OperationId (..)
  , RequestDigest (RequestDigest)
  , SubmissionStatus (StatusInFlight)
  , SubmitDecision (..)
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (ModelBCasApplied)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  )
import Prodbox.Lifecycle.Lease
  ( authorityDurationFromMicros
  , authorityTimeFromMicros
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime, ProviderWorkerRuntime))
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit
  ( Assertion
  , assertBool
  , assertFailure
  , testCase
  , (@?=)
  )

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "Sprint 4.50 retained authority admission"
    [ pureAdmissionTests
    , endpointTests
    , physicalRepositoryTests
    ]

pureAdmissionTests :: TestTree
pureAdmissionTests =
  testGroup
    "pure aggregate"
    [ testCase "fresh submission is closed while genesis is frozen" $ do
        decision <- decide frozen client1 seq1 digestA
        decision @?= AuthoritySubmissionRefusedByGate AuthorityGenesisFrozen
    , testCase "one genesis read-back is insufficient" $ do
        let establishing = advance frozen (ApplyAuthorityGenesis (BeginGenesisEstablishment plan))
            oneReceipt =
              advance
                establishing
                (ApplyAuthorityGenesis (ObserveBackupReceipt backupReceipt))
        decide establishing client1 seq1 digestA
          >>= (@?= AuthoritySubmissionRefusedByGate AuthorityGenesisEstablishing)
        decide oneReceipt client1 seq1 digestA
          >>= (@?= AuthoritySubmissionRefusedByGate AuthorityGenesisEstablishing)
    , testCase "both genesis read-backs open admission under the retained epoch" $ do
        activeAuthorityEpoch opened @?= Right authorityEpochGenesis
        let (decision, _) = submit opened client1 seq1 digestA
        operationEpoch decision @?= authorityEpochGenesis
    , testCase "repair freeze blocks fresh work but an accepted retry remains recoverable" $ do
        let (accepted, withFirst) = submit opened client1 seq1 digestA
            firstId = acceptedOperation accepted
            repairFrozen =
              advance
                withFirst
                (ApplyAuthorityBackupRepair (AssessBackupHealth BackupTemporarilyUnavailable))
        decide repairFrozen client1 seq2 digestB
          >>= (@?= AuthoritySubmissionRefusedByGate AuthorityBackupRepairFrozen)
        let duplicate = fst (submit repairFrozen client1 seq1 digestA)
        duplicateOperation duplicate @?= firstId
    , testCase "repair reopen advances the retained epoch used by new submissions" $ do
        let repairFrozen =
              advance
                opened
                (ApplyAuthorityBackupRepair (AssessBackupHealth BackupTemporarilyUnavailable))
            reopened =
              advance
                repairFrozen
                (ApplyAuthorityBackupRepair (AssessBackupHealth BackupHealthy))
            (accepted, _) = submit reopened client1 seq1 digestA
        activeAuthorityEpoch reopened @?= Right (nextAuthorityEpoch authorityEpochGenesis)
        operationEpoch accepted @?= nextAuthorityEpoch authorityEpochGenesis
    , testCase "migration-controlled install remains closed while legacy owns writes" $ do
        let migrationOpened = openAuthority migratingFrozen
        decide migrationOpened client1 seq1 digestA
          >>= (@?= AuthoritySubmissionRefusedByGate AuthorityLegacyWriterActive)
    , testCase "migration cannot shadow or freeze before the complete import inventory" $ do
        let begun = advance opened BeginAuthorityMigration
            (decision, afterAttempt) =
              stepAuthorityAdmission
                begun
                (ApplyAuthorityMigration (VerifyShadow digestOne))
        decision @?= AuthorityMigrationDecided (MigrationRefused ShadowDigestConflict)
        afterAttempt @?= begun
    , testCase "writer freeze and activation are atomic with submission admission" $ do
        let started = beginImportedMigration opened
            shadow = advance started (ApplyAuthorityMigration (VerifyShadow digestOne))
            writersFrozen = advance shadow (ApplyAuthorityMigration (FreezeLegacy digestOne))
        decide started client1 seq1 digestA
          >>= (@?= AuthoritySubmissionRefusedByGate AuthorityLegacyWriterActive)
        decide writersFrozen client1 seq1 digestA
          >>= (@?= AuthoritySubmissionRefusedByGate AuthorityMigrationWritersQuiesced)
        let activated = activateMigration epochTwo writersFrozen
            (accepted, _) = submit activated client1 seq1 digestA
        activeAuthorityEpoch activated @?= Right authorityEpochTwo
        operationEpoch accepted @?= authorityEpochTwo
    , testCase "forward migration preserves old IDs and fences fresh work during freeze" $ do
        let activatedTwo =
              activateMigration
                epochTwo
                ( advance
                    ( advance
                        (beginImportedMigration opened)
                        (ApplyAuthorityMigration (VerifyShadow digestOne))
                    )
                    (ApplyAuthorityMigration (FreezeLegacy digestOne))
                )
            (acceptedTwo, withOld) = submit activatedTwo client1 seq1 digestA
            oldId = acceptedOperation acceptedTwo
            forwardShadow =
              advance
                withOld
                (ApplyAuthorityForwardMigration (BeginForwardMigration digestTwo epochThree))
            forwardFrozen =
              advance forwardShadow (ApplyAuthorityMigration (FreezeLegacy digestTwo))
        decide forwardFrozen client1 seq2 digestB
          >>= (@?= AuthoritySubmissionRefusedByGate AuthorityMigrationWritersQuiesced)
        duplicateOperation (fst (submit forwardFrozen client1 seq1 digestA)) @?= oldId
        let activatedThree = activateMigration epochThree forwardFrozen
            (acceptedThree, _) = submit activatedThree client1 seq2 digestB
        operationEpoch acceptedThree @?= authorityEpochThree
        duplicateOperation (fst (submit activatedThree client1 seq1 digestA)) @?= oldId
    , testCase "retained identity capacity is bounded independently of request bytes" $ do
        let capacityOne = openAuthority (mustRight (initialCleanInstallAuthority 1 1))
            (_, full) = submit capacityOne client1 seq1 digestA
        decide full client1 seq2 digestB
          >>= (@?= AuthoritySubmissionRefusedRetainedCapacity)
    , testCase "retained capacity cannot be configured below live capacity" $
        initialCleanInstallAuthority 2 1
          @?= Left (AuthorityRetainedCapacityBelowLiveCapacity 2 1)
    , testCase "registered aggregate resolves replay before a later freeze" $ do
        let (accepted, withFirst) =
              registeredSubmit
                registeredOpened
                providerCaller
                generationOne
                submissionKeyA
                digestA
            frozenAfterAcceptance =
              advance
                withFirst
                (ApplyAuthorityBackupRepair (AssessBackupHealth BackupTemporarilyUnavailable))
            (duplicate, unchanged) =
              registeredSubmit
                frozenAfterAcceptance
                providerCaller
                generationOne
                submissionKeyA
                digestA
        registeredDuplicateOperation duplicate
          @?= registeredAcceptedOperation accepted
        unchanged @?= frozenAfterAcceptance
    , testCase "registered aggregate refuses unregistered and rotated callers without mutation" $ do
        let (unregistered, afterUnregistered) =
              registeredSubmit
                registeredOpened
                CallerTestHarness
                generationOne
                submissionKeyA
                digestA
            (rotated, afterRotated) =
              registeredSubmit
                registeredOpened
                providerCaller
                generationTwo
                submissionKeyA
                digestA
        unregistered
          @?= AuthorityRegisteredSubmissionDecided
            RegisteredSubmissionRefusedUnregistered
        rotated
          @?= AuthorityRegisteredSubmissionDecided
            ( RegisteredSubmissionRefusedGenerationMismatch
                generationOne
                generationTwo
            )
        afterUnregistered @?= registeredOpened
        afterRotated @?= registeredOpened
    , testCase "registered aggregate enforces its fixed per-client reservation capacity" $ do
        let oneReservationTable =
              mustRight
                ( mkRegisteredClientTable
                    1
                    [ mustRight
                        ( mkRegisteredClientSpec
                            providerPrincipal
                            registeredSlotOne
                            generationOne
                            1
                        )
                    ]
                )
            oneReservationAuthority =
              openAuthority
                ( mustRight
                    ( initialCleanInstallAuthorityWithRegisteredClients
                        4
                        8
                        oneReservationTable
                    )
                )
            (_, full) =
              registeredSubmit
                oneReservationAuthority
                providerCaller
                generationOne
                submissionKeyA
                digestA
            (refused, unchanged) =
              registeredSubmit
                full
                providerCaller
                generationOne
                submissionKeyB
                digestB
        refused
          @?= AuthorityRegisteredSubmissionDecided
            RegisteredSubmissionRefusedReservationCapacity
        unchanged @?= full
    ]

endpointTests :: TestTree
endpointTests =
  testGroup
    "bounded exact-revision endpoints"
    [ testCase "malformed submit is rejected before retained state is read" $ do
        readCount <- newIORef (0 :: Natural)
        let repository = unreadRepository readCount registeredOpened
        serveAuthorityOperationSubmitRequest 4096 repository providerSlot "not-cbor"
          >>= (@?= AuthorityOperationSubmitBadRequest ControlPlaneRequestInvalid)
        readIORef readCount >>= (@?= 0)
    , testCase "invalid submit fields are rejected before retained state is read" $ do
        readCount <- newIORef (0 :: Natural)
        let repository = unreadRepository readCount registeredOpened
            cases =
              [
                ( AuthorityOperationSubmitPayload "" "digest-a"
                , AuthorityOperationSubmissionKeyEmpty
                )
              ,
                ( AuthorityOperationSubmitPayload (Text.replicate 129 "a") "digest-a"
                , AuthorityOperationSubmissionKeyTooLong
                )
              ,
                ( AuthorityOperationSubmitPayload "request\n1" "digest-a"
                , AuthorityOperationSubmissionKeyInvalidCharacter
                )
              ,
                ( AuthorityOperationSubmitPayload "request-1" ""
                , AuthorityOperationDigestEmpty
                )
              ,
                ( AuthorityOperationSubmitPayload "request-1" (Text.replicate 129 "a")
                , AuthorityOperationDigestTooLong
                )
              ,
                ( AuthorityOperationSubmitPayload "request-1" "digest a"
                , AuthorityOperationDigestInvalidCharacter
                )
              ]
        mapM_
          ( \(payload, expected) ->
              serveAuthorityOperationSubmitRequest
                4096
                repository
                providerSlot
                (encodeControlPlaneRequest payload)
                >>= (@?= AuthorityOperationSubmitInvalidField expected)
          )
          cases
        readIORef readCount >>= (@?= 0)
    , testCase "invalid observe fields are rejected before retained state is read" $ do
        readCount <- newIORef (0 :: Natural)
        let repository = unreadRepository readCount registeredOpened
            body =
              encodeControlPlaneRequest
                (AuthorityOperationObservePayload "request key")
        serveAuthorityOperationObserveRequest 4096 repository providerSlot body
          >>= ( @?=
                  AuthorityOperationObserveInvalidField
                    AuthorityOperationSubmissionKeyInvalidCharacter
              )
        readIORef readCount >>= (@?= 0)
    , testCase "bounded submit request commits and observes through one aggregate" $ do
        (repository, _, _) <- mutableRepository registeredOpened
        let body =
              encodeControlPlaneRequest
                (AuthorityOperationSubmitPayload "request-a" "digest-a")
        result <- serveAuthorityOperationSubmitRequest 4096 repository providerSlot body
        assertAcceptedResult result
        serveAuthorityOperationObserve repository providerSlot submissionKeyA
          >>= ( @?=
                  AuthorityOperationObserveDecided
                    (RegisteredSubmissionObserved StatusInFlight)
              )
    , testCase "closed control and migration routes mutate the same exact-revision aggregate" $ do
        (repository, _, revisionRef) <- mutableRepository registeredOpened
        begun <-
          serveAuthorityControlRequest
            4096
            repository
            (encodeControlPlaneRequest AuthorityControlBeginMigration)
        authorityTransitionHttpStatus begun @?= ReplyOk
        authorityTransitionSummary begun @?= "authority-migration-started"
        mapM_
          ( \projection ->
              serveAuthorityTransition
                repository
                ( ApplyAuthorityMigrationImport
                    (RecordProjectionImport projection ProjectionMissing)
                )
          )
          ([minBound .. maxBound] :: [MigrationProjection])
        _ <-
          serveAuthorityTransition
            repository
            (ApplyAuthorityMigrationImport CompleteProjectionImports)
        migrated <-
          serveAuthorityMigrationApply
            4096
            repository
            (encodeMigrationCommand (VerifyShadow digestOne))
        case migrated of
          MigrationEndpointApplied _ -> pure ()
          other -> assertFailure ("expected aggregate-backed migration apply, got " <> show other)
        serveAuthorityOperationSubmit repository providerSlot submissionKeyA digestA
          >>= ( @?=
                  AuthorityOperationSubmitDecided
                    ( AuthorityRegisteredSubmissionRefusedByGate
                        AuthorityLegacyWriterActive
                    )
              )
        readIORef revisionRef >>= (@?= 7)
    , testCase "malformed closed control input is rejected before state observation" $ do
        readCount <- newIORef (0 :: Natural)
        serveAuthorityControlRequest 4096 (unreadRepository readCount opened) "not-cbor"
          >>= (@?= AuthorityTransitionBadRequest ControlPlaneRequestInvalid)
        readIORef readCount >>= (@?= 0)
    , testCase "an applied submission with a lost CAS response is confirmed by read-back" $ do
        stateRef <- newIORef registeredOpened
        revisionRef <- newIORef (0 :: Natural)
        result <-
          serveAuthorityOperationSubmit
            (responseLostRepository stateRef revisionRef)
            providerSlot
            submissionKeyA
            digestA
        assertAcceptedResult result
        readIORef revisionRef >>= (@?= 1)
        state <- readIORef stateRef
        serveAuthorityOperationObserve
          (readOnlyRepository state)
          providerSlot
          submissionKeyA
          >>= ( @?=
                  AuthorityOperationObserveDecided
                    (RegisteredSubmissionObserved StatusInFlight)
              )
    , testCase "an applied genesis transition with a lost response is confirmed" $ do
        stateRef <- newIORef frozen
        revisionRef <- newIORef (0 :: Natural)
        result <-
          serveAuthorityTransition
            (responseLostRepository stateRef revisionRef)
            (ApplyAuthorityGenesis (BeginGenesisEstablishment plan))
        case result of
          AuthorityTransitionDecided _ -> pure ()
          other -> assertFailure ("expected confirmed transition, got " <> show other)
        state <- readIORef stateRef
        decide state client1 seq1 digestA
          >>= (@?= AuthoritySubmissionRefusedByGate AuthorityGenesisEstablishing)
    , testCase "an un-applied exact-revision conflict is retryable and does not invent work" $ do
        let repository = failedCasRepository registeredOpened
        result <-
          serveAuthorityOperationSubmit repository providerSlot submissionKeyA digestA
        assertBool "expected write failure" (isWriteFailure result)
        serveAuthorityOperationObserve repository providerSlot submissionKeyA
          >>= (@?= AuthorityOperationObserveDecided RegisteredSubmissionUnknown)
    , testCase "a duplicate after a freeze does not attempt another CAS" $ do
        let (accepted, withFirst) = registeredSubmit registeredOpened providerCaller generationOne submissionKeyA digestA
            frozenAfterAcceptance =
              advance
                withFirst
                (ApplyAuthorityBackupRepair (AssessBackupHealth BackupTemporarilyUnavailable))
        casCount <- newIORef (0 :: Natural)
        result <-
          serveAuthorityOperationSubmit
            (failOnCasRepository casCount frozenAfterAcceptance)
            providerSlot
            submissionKeyA
            digestA
        duplicateResultOperation result @?= registeredAcceptedOperation accepted
        readIORef casCount >>= (@?= 0)
    ]

physicalRepositoryTests :: TestTree
physicalRepositoryTests =
  testGroup
    "retained physical state"
    [ testCase "bounded canonical codec pins both capacities" $ do
        let codec = authorityAdmissionStateCodec 4096 4 8
            bytes = mustRight (encodeModelBValue codec frozen)
        decodeModelBValue codec bytes @?= Right frozen
        assertCodecFailure
          "AuthorityAdmissionTooLarge"
          (decodeModelBValue (authorityAdmissionStateCodec 1 4 8) bytes)
        assertCodecFailure
          "AuthorityLiveCapacityMismatch"
          (decodeModelBValue (authorityAdmissionStateCodec 4096 5 8) bytes)
        assertCodecFailure
          "AuthorityRetainedCapacityMismatch"
          (decodeModelBValue (authorityAdmissionStateCodec 4096 4 9) bytes)
    , testCase "production codec pins the fixed registered-client configuration" $ do
        let codec =
              authorityAdmissionStateCodecWithRegisteredClients
                4096
                4
                8
                registeredClientTable
            bytes = mustRight (encodeModelBValue codec registeredOpened)
            rotatedTable =
              mustRight
                ( mkRegisteredClientTable
                    1
                    [ mustRight
                        ( mkRegisteredClientSpec
                            providerPrincipal
                            registeredSlotOne
                            generationTwo
                            8
                        )
                    ]
                )
        decodeModelBValue codec bytes @?= Right registeredOpened
        assertCodecFailure
          "AuthorityRegisteredClientConfigurationMismatch"
          ( decodeModelBValue
              ( authorityAdmissionStateCodecWithRegisteredClients
                  4096
                  4
                  8
                  rotatedTable
              )
              bytes
          )
    , testCase "Model-B binding initializes absence then replaces the exact revision" $ do
        observationRef <- newIORef ModelBMissing
        requestsRef <- newIORef []
        versionRef <- newIORef (1 :: Natural)
        let adapter = retainedAdapter observationRef requestsRef versionRef
            repository =
              modelBAuthorityAdmissionRepository
                registeredOpened
                adapter
                retainedAdmissionCoordinate
        serveAuthorityOperationSubmit repository providerSlot submissionKeyA digestA
          >>= assertAcceptedResult
        serveAuthorityOperationSubmit repository providerSlot submissionKeyB digestB
          >>= assertAcceptedResult
        requests <- reverse <$> readIORef requestsRef
        case requests of
          [ ModelBInitialize initialized _
            , ModelBReplace replaced expected _
            ] -> do
              initialized @?= retainedAdmissionCoordinate
              replaced @?= retainedAdmissionCoordinate
              expected @?= mustRight (mkModelBObjectVersion "authority-admission-v1")
          other -> assertFailure ("expected initialize then exact replace, got " <> show other)
    ]

frozen :: AuthorityAdmissionAggregate
frozen = mustRight (initialCleanInstallAuthority 4 8)

migratingFrozen :: AuthorityAdmissionAggregate
migratingFrozen = mustRight (initialMigratingAuthority 4 8)

opened :: AuthorityAdmissionAggregate
opened = openAuthority frozen

registeredFrozen :: AuthorityAdmissionAggregate
registeredFrozen =
  mustRight
    ( initialCleanInstallAuthorityWithRegisteredClients
        4
        8
        registeredClientTable
    )

registeredOpened :: AuthorityAdmissionAggregate
registeredOpened = openAuthority registeredFrozen

providerCaller :: CallerPrincipal
providerCaller = CallerService ProviderWorkerRuntime

providerPrincipal :: ClientPrincipal
providerPrincipal = clientPrincipalForCaller providerCaller

generationOne, generationTwo :: RegisteredClientGeneration
generationOne = mustRight (mkRegisteredClientGeneration 1)
generationTwo = mustRight (mkRegisteredClientGeneration 2)

registeredSlotOne :: RegisteredClientSlot
registeredSlotOne = mustRight (mkRegisteredClientSlot 1)

registeredClientTable :: RegisteredClientTable
registeredClientTable =
  mustRight
    ( mkRegisteredClientTable
        1
        [ mustRight
            ( mkRegisteredClientSpec
                providerPrincipal
                registeredSlotOne
                generationOne
                8
            )
        ]
    )

submissionKeyA, submissionKeyB :: ClientSubmissionKey
submissionKeyA = mustRight (mkClientSubmissionKey "request-a")
submissionKeyB = mustRight (mkClientSubmissionKey "request-b")

providerSlot :: VerifiedCallerSlot
providerSlot = verifiedSlotFor providerCaller generationOne

verifiedSlotFor :: CallerPrincipal -> RegisteredClientGeneration -> VerifiedCallerSlot
verifiedSlotFor caller registeredGeneration =
  verifiedRequestCallerSlot
    ( mustRight
        ( decodeAndVerifyControlPlaneRequest
            4096
            verificationContext
            (encodeSignedControlPlaneRequest signed)
        )
    )
 where
  signingGeneration =
    mustRight
      ( mkSigningKeyGeneration
          (registeredClientGenerationValue registeredGeneration)
      )
  signer =
    mustRight
      ( mkRequestSigner
          caller
          signingGeneration
          "01234567890123456789012345678901"
      )
  trusted = trustedRequestKeyFromSigner signer
  scope = mustRight (mkAuthorityScope "test/authority-admission")
  nonce = mustRight (mkRequestNonce "0123456789abcdef")
  now = authorityTimeFromMicros 100
  deadline = authorityTimeFromMicros 200
  lifetime = mustRight (authorityDurationFromMicros 1000)
  signed =
    mustRight
      ( signControlPlaneRequest
          signer
          LifecycleOperationSubmit
          LifecycleAuthorityRuntime
          scope
          authorityEpochGenesis
          deadline
          nonce
          "slot-fixture"
      )
  verificationContext =
    mustRight
      ( mkRequestVerificationContext
          trusted
          LifecycleOperationSubmit
          LifecycleAuthorityRuntime
          scope
          authorityEpochGenesis
          deadline
          nonce
          now
          lifetime
      )

openAuthority :: AuthorityAdmissionAggregate -> AuthorityAdmissionAggregate
openAuthority initial =
  advance
    ( advance
        (advance initial (ApplyAuthorityGenesis (BeginGenesisEstablishment plan)))
        (ApplyAuthorityGenesis (ObserveTargetAgentGeneration targetReceipt))
    )
    (ApplyAuthorityGenesis (ObserveBackupReceipt backupReceipt))

activateMigration
  :: MigrationEpoch
  -> AuthorityAdmissionAggregate
  -> AuthorityAdmissionAggregate
activateMigration epoch aggregate =
  advance
    (foldl prepare aggregate ([minBound .. maxBound] :: [MigrationBinding]))
    (ApplyAuthorityMigration (ActivateReplacement epoch))
 where
  prepare state binding =
    advance state (ApplyAuthorityMigration (PrepareBinding binding))

beginImportedMigration
  :: AuthorityAdmissionAggregate
  -> AuthorityAdmissionAggregate
beginImportedMigration aggregate =
  advance
    ( foldl
        ( \state projection ->
            advance
              state
              ( ApplyAuthorityMigrationImport
                  (RecordProjectionImport projection ProjectionMissing)
              )
        )
        (advance aggregate BeginAuthorityMigration)
        ([minBound .. maxBound] :: [MigrationProjection])
    )
    (ApplyAuthorityMigrationImport CompleteProjectionImports)

advance
  :: AuthorityAdmissionAggregate
  -> AuthorityAdmissionCommand
  -> AuthorityAdmissionAggregate
advance aggregate = snd . stepAuthorityAdmission aggregate

decide
  :: AuthorityAdmissionAggregate
  -> ClientId
  -> ClientSequence
  -> RequestDigest
  -> IO AuthoritySubmissionDecision
decide aggregate client seqNo digest =
  either
    (assertFailure . show)
    pure
    (decideAuthoritySubmission aggregate client seqNo digest)

submit
  :: AuthorityAdmissionAggregate
  -> ClientId
  -> ClientSequence
  -> RequestDigest
  -> (AuthoritySubmissionDecision, AuthorityAdmissionAggregate)
submit aggregate client seqNo digest =
  mustRight (stepAuthoritySubmission aggregate client seqNo digest)

acceptedOperation :: AuthoritySubmissionDecision -> OperationId
acceptedOperation decision = case decision of
  AuthoritySubmissionDecided (SubmissionAccepted operationId) -> operationId
  other -> error ("expected accepted operation, got " <> show other)

duplicateOperation :: AuthoritySubmissionDecision -> OperationId
duplicateOperation decision = case decision of
  AuthoritySubmissionDecided (SubmissionDuplicate operationId) -> operationId
  other -> error ("expected duplicate operation, got " <> show other)

operationEpoch :: AuthoritySubmissionDecision -> AuthorityEpoch
operationEpoch = operationIdEpoch . acceptedOperation

assertAcceptedResult :: AuthorityOperationSubmitResult -> Assertion
assertAcceptedResult result = case result of
  AuthorityOperationSubmitDecided decision ->
    case decision of
      AuthorityRegisteredSubmissionDecided (RegisteredSubmissionAccepted _) -> pure ()
      _ -> assertFailure ("expected accepted result, got " <> show result)
  _ -> assertFailure ("expected accepted result, got " <> show result)

duplicateResultOperation :: AuthorityOperationSubmitResult -> OperationId
duplicateResultOperation result = case result of
  AuthorityOperationSubmitDecided decision -> registeredDuplicateOperation decision
  other -> error ("expected duplicate result, got " <> show other)

isWriteFailure :: AuthorityOperationSubmitResult -> Bool
isWriteFailure result = case result of
  AuthorityOperationSubmitWriteFailed _ -> True
  _ -> False

mustRight :: (Show error) => Either error value -> value
mustRight = either (error . show) id

mustJust :: String -> Maybe value -> value
mustJust label = maybe (error ("invalid fixture: " <> label)) id

registeredSubmit
  :: AuthorityAdmissionAggregate
  -> CallerPrincipal
  -> RegisteredClientGeneration
  -> ClientSubmissionKey
  -> RequestDigest
  -> (AuthorityRegisteredSubmissionDecision, AuthorityAdmissionAggregate)
registeredSubmit aggregate caller generation submissionKey digest =
  mustRight
    ( stepRegisteredAuthoritySubmission
        aggregate
        caller
        generation
        submissionKey
        digest
    )

registeredAcceptedOperation :: AuthorityRegisteredSubmissionDecision -> OperationId
registeredAcceptedOperation decision = case decision of
  AuthorityRegisteredSubmissionDecided (RegisteredSubmissionAccepted operationId) ->
    operationId
  other -> error ("expected registered accepted operation, got " <> show other)

registeredDuplicateOperation :: AuthorityRegisteredSubmissionDecision -> OperationId
registeredDuplicateOperation decision = case decision of
  AuthorityRegisteredSubmissionDecided (RegisteredSubmissionDuplicate operationId) ->
    operationId
  other -> error ("expected registered duplicate operation, got " <> show other)

plan :: GenesisPlan
plan = GenesisPlan "genesis-plan" "s3://authority-backup/prefix"

targetReceipt :: TargetAgentGenerationReceipt
targetReceipt = TargetAgentGenerationReceipt "target-generation-1"

backupReceipt :: BackupReceipt
backupReceipt = BackupReceipt "backup-receipt-1"

client1 :: ClientId
client1 = ClientId "client-1"

seq1, seq2 :: ClientSequence
seq1 = ClientSequence 1
seq2 = ClientSequence 2

digestA, digestB :: RequestDigest
digestA = RequestDigest "digest-a"
digestB = RequestDigest "digest-b"

digestOne, digestTwo :: MigrationDigest
digestOne = mustJust "migration digest one" (mkMigrationDigest "migration-one")
digestTwo = mustJust "migration digest two" (mkMigrationDigest "migration-two")

epochTwo, epochThree :: MigrationEpoch
epochTwo = mustJust "migration epoch two" (mkMigrationEpoch 2)
epochThree = mustJust "migration epoch three" (mkMigrationEpoch 3)

authorityEpochTwo, authorityEpochThree :: AuthorityEpoch
authorityEpochTwo = nextAuthorityEpoch authorityEpochGenesis
authorityEpochThree = nextAuthorityEpoch authorityEpochTwo

mutableRepository
  :: AuthorityAdmissionAggregate
  -> IO
       ( AuthorityAdmissionRepository IO Natural
       , IORef AuthorityAdmissionAggregate
       , IORef Natural
       )
mutableRepository initial = do
  stateRef <- newIORef initial
  revisionRef <- newIORef 0
  pure (countedRepository stateRef revisionRef Nothing, stateRef, revisionRef)

countedRepository
  :: IORef AuthorityAdmissionAggregate
  -> IORef Natural
  -> Maybe (IORef Natural)
  -> AuthorityAdmissionRepository IO Natural
countedRepository stateRef revisionRef maybeCasCount =
  AuthorityAdmissionRepository
    { readAuthorityAdmission = do
        state <- readIORef stateRef
        revision <- readIORef revisionRef
        pure (Right (AuthorityAdmissionSnapshot revision state))
    , compareAndSwapAuthorityAdmission = \expected next -> do
        current <- readIORef revisionRef
        if current /= expected
          then pure (Left "retained authority CAS conflict")
          else do
            writeIORef stateRef next
            writeIORef revisionRef (current + 1)
            traverse_ (\ref -> modifyIORef' ref (+ 1)) maybeCasCount
            pure (Right ())
    }

responseLostRepository
  :: IORef AuthorityAdmissionAggregate
  -> IORef Natural
  -> AuthorityAdmissionRepository IO Natural
responseLostRepository stateRef revisionRef =
  AuthorityAdmissionRepository
    { readAuthorityAdmission = do
        state <- readIORef stateRef
        revision <- readIORef revisionRef
        pure (Right (AuthorityAdmissionSnapshot revision state))
    , compareAndSwapAuthorityAdmission = \expected next -> do
        current <- readIORef revisionRef
        if current /= expected
          then pure (Left "retained authority CAS conflict")
          else do
            writeIORef stateRef next
            writeIORef revisionRef (current + 1)
            pure (Left "CAS response lost after apply")
    }

failedCasRepository
  :: AuthorityAdmissionAggregate
  -> AuthorityAdmissionRepository IO Natural
failedCasRepository state =
  AuthorityAdmissionRepository
    { readAuthorityAdmission = pure (Right (AuthorityAdmissionSnapshot 0 state))
    , compareAndSwapAuthorityAdmission = \_ _ -> pure (Left "stale exact revision")
    }

failOnCasRepository
  :: IORef Natural
  -> AuthorityAdmissionAggregate
  -> AuthorityAdmissionRepository IO Natural
failOnCasRepository casCount state =
  AuthorityAdmissionRepository
    { readAuthorityAdmission = pure (Right (AuthorityAdmissionSnapshot 0 state))
    , compareAndSwapAuthorityAdmission = \_ _ -> do
        modifyIORef' casCount (+ 1)
        pure (Left "unexpected CAS")
    }

readOnlyRepository
  :: AuthorityAdmissionAggregate
  -> AuthorityAdmissionRepository IO Natural
readOnlyRepository state =
  AuthorityAdmissionRepository
    { readAuthorityAdmission = pure (Right (AuthorityAdmissionSnapshot 0 state))
    , compareAndSwapAuthorityAdmission = \_ _ -> pure (Left "read-only")
    }

unreadRepository
  :: IORef Natural
  -> AuthorityAdmissionAggregate
  -> AuthorityAdmissionRepository IO Natural
unreadRepository readCount state =
  AuthorityAdmissionRepository
    { readAuthorityAdmission = do
        modifyIORef' readCount (+ 1)
        pure (Right (AuthorityAdmissionSnapshot 0 state))
    , compareAndSwapAuthorityAdmission = \_ _ -> pure (Left "unreachable")
    }

assertCodecFailure :: String -> Either String value -> Assertion
assertCodecFailure expected result = case result of
  Left detail -> assertBool ("expected " <> expected <> ", got " <> detail) (expected `isInfixOf` detail)
  Right _ -> assertFailure ("expected codec failure " <> expected)

retainedAdapter
  :: IORef (ModelBObservation AuthorityAdmissionAggregate)
  -> IORef [ModelBCasRequest 'ClusterRetained AuthorityAdmissionAggregate]
  -> IORef Natural
  -> ModelBCasAdapter 'ClusterRetained IO AuthorityAdmissionAggregate
retainedAdapter observationRef requestsRef versionRef =
  ModelBCasAdapter
    { modelBObserve = \_ -> readIORef observationRef
    , modelBCompareAndSwap = \request -> do
        modifyIORef' requestsRef (request :)
        versionNumber <- readIORef versionRef
        let version =
              mustRight
                ( mkModelBObjectVersion
                    ("authority-admission-v" <> Text.pack (show versionNumber))
                )
            aggregate = requestAggregate request
        writeIORef observationRef (ModelBObserved version aggregate)
        writeIORef versionRef (versionNumber + 1)
        pure (ModelBCasApplied version aggregate)
    }

requestAggregate
  :: ModelBCasRequest lifetime AuthorityAdmissionAggregate
  -> AuthorityAdmissionAggregate
requestAggregate request = case request of
  ModelBInitialize _ aggregate -> aggregate
  ModelBReplace _ _ aggregate -> aggregate
  ModelBInitializeGuarded _ _ aggregate -> aggregate
  ModelBReplaceGuarded _ _ _ aggregate -> aggregate

retainedAdmissionCoordinate :: ModelBObjectCoordinate 'ClusterRetained
retainedAdmissionCoordinate =
  mustRight
    (mkClusterRetainedCoordinate retainedAuthority "authority/admission")

retainedAuthority :: LongLivedCheckpointAuthority
retainedAuthority =
  mustRight
    ( mkLongLivedCheckpointAuthority
        "home"
        "prodbox-state"
        "authority"
        "secret/lifecycle"
    )

traverse_ :: (a -> IO b) -> Maybe a -> IO ()
traverse_ action maybeValue = case maybeValue of
  Nothing -> pure ()
  Just value -> void (action value)
