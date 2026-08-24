{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownDecision
  ( lifecycleTeardownDecisionSuite
  )
where

import Control.Monad (forM_)
import Data.List.NonEmpty (NonEmpty (..))
import Prodbox.Lifecycle.Teardown.Decision
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.OwnershipManifest
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownDecisionSuite :: SuiteBuilder ()
lifecycleTeardownDecisionSuite =
  describe "Sprint 4.85 exact stack desired-absence decision" $ do
    it "covers every exact-result x primary x backup x manifest combination" $ do
      length decisionMatrix `shouldBe` 256
      forM_ decisionMatrix $ \row@(exactCase, primaryCase, backupCase, manifestCase) -> do
        let actual =
              decideStackDesiredAbsence
                AwsEksKey
                (completeObservation exactCase)
                (checkpointPair primaryCase backupCase)
                (manifestDecisionEvidence AwsEksKey decisionScope manifestCase)
            expected =
              ( Right
                  ( expectedDecision
                      exactCase
                      primaryCase
                      backupCase
                      manifestCase
                  )
                  :: Either StackDecisionBindingError StackDesiredAbsenceDecision
              )
        if actual == expected
          then pure ()
          else
            expectationFailure
              ( "decision matrix row "
                  ++ show row
                  ++ " produced "
                  ++ show actual
                  ++ ", expected "
                  ++ show expected
              )

    it "rejects keys, wrapper bindings, and manifest bindings from another stack or scope" $ do
      forM_ wrapperBindingMismatches $ \(label, actual, expected) ->
        if actual == expected
          then pure ()
          else
            expectationFailure
              ( label
                  ++ " produced "
                  ++ show actual
                  ++ ", expected "
                  ++ show expected
              )

    it "revalidates the checkpoint observations inside a public pair value" $ do
      forM_ nestedCheckpointMismatches $ \(label, malformedPair, expectedError) -> do
        let actual =
              decideStackDesiredAbsence
                AwsEksKey
                presentCompleteObservation
                malformedPair
                validManifest
            expected =
              ( Left (StackDecisionCheckpointPairInvalid expectedError)
                  :: Either StackDecisionBindingError StackDesiredAbsenceDecision
              )
        if actual == expected
          then pure ()
          else
            expectationFailure
              ( label
                  ++ " produced "
                  ++ show actual
                  ++ ", expected "
                  ++ show expected
              )

    it "normalizes checkpoint copy order before choosing cleanup authority" $ do
      let swappedPair =
            validCheckpointPair
              { primaryCheckpointObservation =
                  checkpointObservation
                    BackupCheckpointCopy
                    AwsEksKey
                    decisionScope
                    TestCheckpointPresent
              , backupCheckpointObservation =
                  checkpointObservation
                    PrimaryCheckpointCopy
                    AwsEksKey
                    decisionScope
                    TestCheckpointAbsent
              }
      decideStackDesiredAbsence
        AwsEksKey
        presentCompleteObservation
        swappedPair
        (manifestDecisionEvidence AwsEksKey decisionScope TestManifestPresent)
        `shouldBe` Right
          ( StackRestoreBackupThenDestroy
              AwsEksKey
              (VerifiedBackupCheckpoint backupProvenance checkpointVersion)
          )

    it "keeps terminal audit and AWS tag inventory outside the decision API" $ do
      let pinnedDecisionType
            :: RegisteredResourceKey
            -> CompleteObservationSet
            -> CheckpointPairObservation
            -> OwnershipManifestDecisionEvidence
            -> Either StackDecisionBindingError StackDesiredAbsenceDecision
          pinnedDecisionType = decideStackDesiredAbsence
      pinnedDecisionType
        AwsEksKey
        presentCompleteObservation
        validCheckpointPair
        validManifest
        `shouldBe` Right
          ( StackDestroyFromVerifiedPrimary
              AwsEksKey
              (VerifiedPrimaryCheckpoint primaryProvenance checkpointVersion)
          )
      source <- readFile "src/Prodbox/Lifecycle/Teardown/Decision.hs"
      source `shouldNotContain` "TerminalAuditScope"
      source `shouldNotContain` "TerminalAuditObservation"
      source `shouldNotContain` "AwsInventory"
      source `shouldNotContain` "AwsTagRow"

    it "refuses a merely present manifest without validated complete evidence" $ do
      decideStackDesiredAbsence
        AwsEksKey
        presentCompleteObservation
        (checkpointPair TestCheckpointAbsent TestCheckpointAbsent)
        ( ownershipManifestObservationOnly
            (manifestObservation AwsEksKey decisionScope TestManifestPresent)
        )
        `shouldBe` Right
          ( StackDesiredAbsenceRefused
              AwsEksKey
              ( StackPrimaryCheckpointAbsent
                  :| [ StackBackupCheckpointAbsent
                     , StackOwnershipManifestPresentWithoutCompleteEvidence
                     ]
              )
          )

data ExactCase
  = TestExactAbsent
  | TestExactPresent
  | TestExactPartial
  | TestExactUnobservable
  deriving (Bounded, Enum, Eq, Show)

data CheckpointCase
  = TestCheckpointAbsent
  | TestCheckpointPresent
  | TestCheckpointPartial
  | TestCheckpointUnobservable
  deriving (Bounded, Enum, Eq, Show)

data ManifestCase
  = TestManifestAbsent
  | TestManifestPresent
  | TestManifestPartial
  | TestManifestUnobservable
  deriving (Bounded, Enum, Eq, Show)

decisionMatrix :: [(ExactCase, CheckpointCase, CheckpointCase, ManifestCase)]
decisionMatrix =
  [ (exactCase, primaryCase, backupCase, manifestCase)
  | exactCase <- [minBound .. maxBound]
  , primaryCase <- [minBound .. maxBound]
  , backupCase <- [minBound .. maxBound]
  , manifestCase <- [minBound .. maxBound]
  ]

expectedDecision
  :: ExactCase
  -> CheckpointCase
  -> CheckpointCase
  -> ManifestCase
  -> StackDesiredAbsenceDecision
expectedDecision exactCase primaryCase backupCase manifestCase =
  case exactCase of
    TestExactAbsent -> StackAlreadyAbsent AwsEksKey absenceEvidence
    TestExactPartial ->
      StackDesiredAbsenceRefused
        AwsEksKey
        (StackExactObservationPartial partialEvidence exactFailures :| [])
    TestExactUnobservable ->
      StackDesiredAbsenceRefused
        AwsEksKey
        (StackExactObservationUnobservable exactFailures :| [])
    TestExactPresent -> case primaryCase of
      TestCheckpointPresent ->
        StackDestroyFromVerifiedPrimary
          AwsEksKey
          (VerifiedPrimaryCheckpoint primaryProvenance checkpointVersion)
      _ -> case backupCase of
        TestCheckpointPresent ->
          StackRestoreBackupThenDestroy
            AwsEksKey
            (VerifiedBackupCheckpoint backupProvenance checkpointVersion)
        _ ->
          StackDesiredAbsenceRefused
            AwsEksKey
            ( checkpointRefusal PrimaryCheckpointCopy primaryCase
                :| [ checkpointRefusal BackupCheckpointCopy backupCase
                   , manifestRefusal manifestCase
                   ]
            )

checkpointRefusal :: CheckpointCopy -> CheckpointCase -> StackDecisionRefusal
checkpointRefusal copy checkpointCase = case (copy, checkpointCase) of
  (PrimaryCheckpointCopy, TestCheckpointAbsent) -> StackPrimaryCheckpointAbsent
  (PrimaryCheckpointCopy, TestCheckpointPartial) ->
    StackPrimaryCheckpointPartial primaryFailures
  (PrimaryCheckpointCopy, TestCheckpointUnobservable) ->
    StackPrimaryCheckpointUnobservable primaryFailures
  (BackupCheckpointCopy, TestCheckpointAbsent) -> StackBackupCheckpointAbsent
  (BackupCheckpointCopy, TestCheckpointPartial) ->
    StackBackupCheckpointPartial backupFailures
  (BackupCheckpointCopy, TestCheckpointUnobservable) ->
    StackBackupCheckpointUnobservable backupFailures
  (_, TestCheckpointPresent) ->
    error "present checkpoint has authority and cannot be a refusal"

manifestRefusal :: ManifestCase -> StackDecisionRefusal
manifestRefusal manifestCase = case manifestCase of
  TestManifestAbsent -> StackOwnershipManifestAbsent
  TestManifestPartial -> StackOwnershipManifestPartial manifestFailures
  TestManifestUnobservable ->
    StackOwnershipManifestUnobservable manifestFailures
  TestManifestPresent ->
    StackOwnershipManifestPresentWithoutCompleteEvidence

completeObservation :: ExactCase -> CompleteObservationSet
completeObservation exactCase =
  completeObservationFor AwsEksKey decisionScope (exactResult exactCase)

presentCompleteObservation :: CompleteObservationSet
presentCompleteObservation = completeObservation TestExactPresent

completeObservationFor
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> ExactObservationResult
  -> CompleteObservationSet
completeObservationFor key scope result =
  mustRight
    ( mkCompleteObservationSet
        scope
        [key]
        [ exactResourceObservationFor
            (mustIdentity key)
            (ObservationRevision 41)
            scope
            result
        ]
    )

exactResult :: ExactCase -> ExactObservationResult
exactResult exactCase = case exactCase of
  TestExactAbsent -> ExactResourceAbsent absenceEvidence
  TestExactPresent ->
    ExactResourcePresent
      (ExactResourceInventory (ObservedResourceIdentity "arn:aws:fixture:stack" :| []))
  TestExactPartial -> ExactResourcePartial partialEvidence exactFailures
  TestExactUnobservable -> ExactResourceUnobservable exactFailures

checkpointPair :: CheckpointCase -> CheckpointCase -> CheckpointPairObservation
checkpointPair primaryCase backupCase =
  mustRight
    ( mkCheckpointPairObservation
        AwsEksKey
        decisionScope
        ( checkpointObservation
            PrimaryCheckpointCopy
            AwsEksKey
            decisionScope
            primaryCase
        )
        ( checkpointObservation
            BackupCheckpointCopy
            AwsEksKey
            decisionScope
            backupCase
        )
    )

validCheckpointPair :: CheckpointPairObservation
validCheckpointPair =
  checkpointPair TestCheckpointPresent TestCheckpointPresent

checkpointObservation
  :: CheckpointCopy
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> CheckpointCase
  -> CheckpointObservation
checkpointObservation copy key scope checkpointCase =
  CheckpointObservation
    { checkpointObservationStackKey = key
    , checkpointObservationCopy = copy
    , checkpointObservationProvenance = case copy of
        PrimaryCheckpointCopy -> primaryProvenance
        BackupCheckpointCopy -> backupProvenance
    , checkpointObservationEvidenceScope = scope
    , checkpointObservationResult = checkpointResult copy checkpointCase
    }

checkpointResult :: CheckpointCopy -> CheckpointCase -> CheckpointResult
checkpointResult copy checkpointCase = case checkpointCase of
  TestCheckpointAbsent -> CheckpointAbsent
  TestCheckpointPresent -> CheckpointPresent checkpointVersion
  TestCheckpointPartial -> CheckpointPartial (failuresForCopy copy)
  TestCheckpointUnobservable -> CheckpointUnobservable (failuresForCopy copy)

failuresForCopy :: CheckpointCopy -> NonEmpty ObservationFailure
failuresForCopy copy = case copy of
  PrimaryCheckpointCopy -> primaryFailures
  BackupCheckpointCopy -> backupFailures

manifestObservation
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> ManifestCase
  -> OwnershipManifestObservation
manifestObservation key scope manifestCase =
  OwnershipManifestObservation
    { ownershipManifestStackKey = key
    , ownershipManifestProvenance = manifestProvenance
    , ownershipManifestEvidenceScope = scope
    , ownershipManifestResult = case manifestCase of
        TestManifestAbsent -> OwnershipManifestAbsent
        TestManifestPresent -> OwnershipManifestPresent manifestVersion
        TestManifestPartial -> OwnershipManifestPartial manifestFailures
        TestManifestUnobservable -> OwnershipManifestUnobservable manifestFailures
    }

manifestDecisionEvidence
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> ManifestCase
  -> OwnershipManifestDecisionEvidence
manifestDecisionEvidence key scope manifestCase =
  ownershipManifestObservationOnly
    (manifestObservation key scope manifestCase)

validManifest :: OwnershipManifestDecisionEvidence
validManifest =
  ownershipManifestObservationOnly
    (manifestObservation AwsEksKey decisionScope TestManifestPresent)

wrapperBindingMismatches
  :: [ ( String
       , Either StackDecisionBindingError StackDesiredAbsenceDecision
       , Either StackDecisionBindingError StackDesiredAbsenceDecision
       )
     ]
wrapperBindingMismatches =
  [
    ( "unselected exact key"
    , decideStackDesiredAbsence
        AwsEksKey
        (completeObservationFor AwsEksSubzoneKey decisionScope presentResult)
        validCheckpointPair
        validManifest
    , Left (StackDecisionKeyNotSelected AwsEksKey)
    )
  ,
    ( "non-stack registry identity"
    , decideStackDesiredAbsence
        AwsEbsPerRunTestKey
        (completeObservationFor AwsEbsPerRunTestKey decisionScope presentResult)
        validCheckpointPair
        validManifest
    , Left (StackDecisionResourceIsNotStack AwsEbsPerRunTestKey VolumeFamily)
    )
  ,
    ( "checkpoint pair key"
    , decideStackDesiredAbsence
        AwsEksKey
        presentCompleteObservation
        validCheckpointPair {checkpointPairStackKey = AwsEksSubzoneKey}
        validManifest
    , Left (StackDecisionCheckpointKeyMismatch AwsEksKey AwsEksSubzoneKey)
    )
  ,
    ( "manifest key"
    , decideStackDesiredAbsence
        AwsEksKey
        presentCompleteObservation
        validCheckpointPair
        ( ownershipManifestObservationOnly
            ( (manifestObservation AwsEksKey decisionScope TestManifestPresent)
                { ownershipManifestStackKey = AwsEksSubzoneKey
                }
            )
        )
    , Left (StackDecisionManifestKeyMismatch AwsEksKey AwsEksSubzoneKey)
    )
  ,
    ( "checkpoint pair scope"
    , decideStackDesiredAbsence
        AwsEksKey
        presentCompleteObservation
        validCheckpointPair {checkpointPairEvidenceScope = otherScope}
        validManifest
    , Left (StackDecisionCheckpointScopeMismatch decisionScope otherScope)
    )
  ,
    ( "manifest scope"
    , decideStackDesiredAbsence
        AwsEksKey
        presentCompleteObservation
        validCheckpointPair
        ( ownershipManifestObservationOnly
            ( (manifestObservation AwsEksKey decisionScope TestManifestPresent)
                { ownershipManifestEvidenceScope = otherScope
                }
            )
        )
    , Left (StackDecisionManifestScopeMismatch decisionScope otherScope)
    )
  ]

nestedCheckpointMismatches
  :: [(String, CheckpointPairObservation, CheckpointPairError)]
nestedCheckpointMismatches =
  [
    ( "primary key"
    , validCheckpointPair
        { primaryCheckpointObservation =
            (primaryCheckpointObservation validCheckpointPair)
              { checkpointObservationStackKey = AwsEksSubzoneKey
              }
        }
    , CheckpointPairKeyMismatch AwsEksKey AwsEksSubzoneKey AwsEksKey
    )
  ,
    ( "backup key"
    , validCheckpointPair
        { backupCheckpointObservation =
            (backupCheckpointObservation validCheckpointPair)
              { checkpointObservationStackKey = AwsEksSubzoneKey
              }
        }
    , CheckpointPairKeyMismatch AwsEksKey AwsEksKey AwsEksSubzoneKey
    )
  ,
    ( "primary scope"
    , validCheckpointPair
        { primaryCheckpointObservation =
            (primaryCheckpointObservation validCheckpointPair)
              { checkpointObservationEvidenceScope = otherScope
              }
        }
    , CheckpointPairScopeMismatch AwsEksKey decisionScope otherScope
    )
  ,
    ( "backup scope"
    , validCheckpointPair
        { backupCheckpointObservation =
            (backupCheckpointObservation validCheckpointPair)
              { checkpointObservationEvidenceScope = otherScope
              }
        }
    , CheckpointPairScopeMismatch AwsEksKey decisionScope otherScope
    )
  ,
    ( "duplicate primary copy"
    , validCheckpointPair
        { backupCheckpointObservation =
            (backupCheckpointObservation validCheckpointPair)
              { checkpointObservationCopy = PrimaryCheckpointCopy
              }
        }
    , CheckpointPairCopyMissing BackupCheckpointCopy
    )
  ,
    ( "duplicate backup copy"
    , validCheckpointPair
        { primaryCheckpointObservation =
            (primaryCheckpointObservation validCheckpointPair)
              { checkpointObservationCopy = BackupCheckpointCopy
              }
        }
    , CheckpointPairCopyMissing PrimaryCheckpointCopy
    )
  ]

decisionScope :: ObservationEvidenceScope
decisionScope =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope "cleanup-run/decision-fixture")
    (LinuxRke2FoundationId "linux-rke2/home")
    ( Just
        ( AwsScope
            (AwsAccountId "111122223333")
            (AwsRegion (fixtureAwsRegion FixtureCaCentral1))
        )
    )
    ReconcileDesiredAbsent

otherScope :: ObservationEvidenceScope
otherScope =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope "cleanup-run/other")
    (LinuxRke2FoundationId "linux-rke2/home")
    ( Just
        ( AwsScope
            (AwsAccountId "111122223333")
            (AwsRegion (fixtureAwsRegion FixtureCaCentral1))
        )
    )
    ReconcileDesiredAbsent

absenceEvidence :: AbsenceEvidence
absenceEvidence = AbsenceEvidence "provider-authoritative-not-found"

partialEvidence :: PartialEvidence
partialEvidence = PartialEvidence [ObservedResourceIdentity "arn:aws:fixture:partial"]

exactFailures :: NonEmpty ObservationFailure
exactFailures = ObservationFailure "exact observer incomplete" :| []

primaryFailures :: NonEmpty ObservationFailure
primaryFailures = ObservationFailure "primary checkpoint unavailable" :| []

backupFailures :: NonEmpty ObservationFailure
backupFailures = ObservationFailure "backup checkpoint unavailable" :| []

manifestFailures :: NonEmpty ObservationFailure
manifestFailures = ObservationFailure "ownership manifest unavailable" :| []

checkpointVersion :: CheckpointVersion
checkpointVersion = CheckpointVersion "checkpoint/version-7"

primaryProvenance :: CheckpointProvenance
primaryProvenance = CheckpointProvenance "checkpoint/primary"

backupProvenance :: CheckpointProvenance
backupProvenance = CheckpointProvenance "checkpoint/backup"

manifestVersion :: OwnershipManifestVersion
manifestVersion = OwnershipManifestVersion "manifest/version-3"

manifestProvenance :: OwnershipManifestProvenance
manifestProvenance = OwnershipManifestProvenance "manifest/owned-resource-set"

presentResult :: ExactObservationResult
presentResult = exactResult TestExactPresent

mustIdentity :: RegisteredResourceKey -> RegisteredIdentity
mustIdentity key = case lookupRegisteredIdentity key of
  Nothing -> error ("missing registry identity: " ++ show key)
  Just identity -> identity

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
