{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownRegistry
  ( lifecycleTeardownRegistrySuite
  )
where

import Control.Monad (forM_)
import Data.Either (isLeft, isRight)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.AwsInventory
import Prodbox.Lifecycle.DnsRecord (HostedZoneId, mkHostedZoneId)
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownRegistrySuite :: SuiteBuilder ()
lifecycleTeardownRegistrySuite = do
  describe "Sprint 4.84 pure exact-keyed lifecycle registry" $ do
    it "registers exact identities under the sole local Linux RKE2 authority" $ do
      map registryRow lifecycleRegistry
        `shouldBe` [ (LocalLinuxRke2Key, Nothing, LocalSubstrate)
                   , (AwsEksKey, Just PerRun, Stack)
                   , (AwsEksSubzoneKey, Just PerRun, Stack)
                   , (AwsTestKey, Just PerRun, Stack)
                   , (AwsEbsPerRunTestKey, Just PerRun, VolumeFamily)
                   , (AwsDnsValidationZoneKey, Just PerRun, DnsZoneFamily)
                   , (AwsDns01ChallengeRecordKey, Just PerRun, DnsRecordFamily)
                   , (AwsEksIamRoleFamilyKey, Just PerRun, ControllerFamily)
                   , (AwsEksLoadBalancerControllerFamilyKey, Just PerRun, ControllerFamily)
                   , (AwsEbsProductionRetainedKey, Just LongLived, VolumeFamily)
                   ]
      map registeredIdentityAuthority lifecycleRegistry
        `shouldBe` replicate 10 LinuxRke2LifecycleAuthority
      lifecycleRegistryValidation `shouldBe` Right ()

    it "keeps the two EBS families on distinct exact coordinates and fixed classes" $ do
      let perRun = mustIdentity AwsEbsPerRunTestKey
          retained = mustIdentity AwsEbsProductionRetainedKey
      registeredIdentityLifecycleClass perRun `shouldBe` Just PerRun
      registeredIdentityLifecycleClass retained `shouldBe` Just LongLived
      registeredIdentityCoordinate perRun
        `shouldBe` AwsEbsPerRunFamilyCoordinate
          "prodbox.io/lifecycle"
          "per-run-test"
          "kubernetes.io/cluster/aws-eks-test-cluster"
          "owned"
      registeredIdentityCoordinate retained
        `shouldBe` AwsEbsRetainedFamilyCoordinate "prodbox.io/lifecycle" "retained-ebs"
      registeredIdentityCoordinateDigest perRun
        `shouldNotBe` registeredIdentityCoordinateDigest retained

    it "projects the complete class/surface table without tag-based reclassification" $ do
      forM_ surfaceTable $ \(key, allowedSurfaces) -> do
        let identity = mustIdentity key
            actual =
              [ surface
              | surface <- [minBound .. maxBound]
              , cleanupSurfaceAllows surface identity
              ]
        actual `shouldBe` allowedSurfaces

    it "constructs cascade targets only for PerRun resources and the final local target" $ do
      projectCleanupTarget CascadeSurface (mustIdentity AwsEbsPerRunTestKey)
        `shouldSatisfy` isRight
      projectCleanupTarget CascadeSurface (mustIdentity AwsEbsProductionRetainedKey)
        `shouldSatisfy` isLeft
      map cleanupTargetKey (cleanupTargetsForSurface CascadeSurface)
        `shouldBe` [ AwsEksKey
                   , AwsEksSubzoneKey
                   , AwsTestKey
                   , AwsEbsPerRunTestKey
                   , AwsDnsValidationZoneKey
                   , AwsDns01ChallengeRecordKey
                   , AwsEksIamRoleFamilyKey
                   , AwsEksLoadBalancerControllerFamilyKey
                   , LocalLinuxRke2Key
                   ]
      map cleanupTargetLifecycleClass (cleanupTargetsForSurface CascadeSurface)
        `shouldBe` [ Just PerRun
                   , Just PerRun
                   , Just PerRun
                   , Just PerRun
                   , Just PerRun
                   , Just PerRun
                   , Just PerRun
                   , Just PerRun
                   , Nothing
                   ]

    it "keeps local-only, explicit per-run, and explicit long-lived projections distinct" $ do
      projectCleanupTarget LocalOnlySurface (mustIdentity LocalLinuxRke2Key)
        `shouldSatisfy` isRight
      projectCleanupTarget LocalOnlySurface (mustIdentity AwsEksKey)
        `shouldSatisfy` isLeft
      projectCleanupTarget ExplicitPerRunSurface (mustIdentity LocalLinuxRke2Key)
        `shouldSatisfy` isLeft
      projectCleanupTarget ExplicitLongLivedSurface (mustIdentity AwsEbsPerRunTestKey)
        `shouldSatisfy` isLeft
      projectCleanupTarget ExplicitLongLivedSurface (mustIdentity AwsEbsProductionRetainedKey)
        `shouldSatisfy` isRight

  describe "Sprint 7.36 the observation scope names the run's DNS zone" $ do
    it "defaults to no zone and carries one only when minted with it" $ do
      -- Account and region already travel on the scope because a registered
      -- family's coordinate is incomplete without them. A registered DNS
      -- \*record* family is incomplete without a zone for the same reason, and
      -- the zone is the run's retained zone rather than a static registry fact.
      evidenceAwsDnsZone cascadeScope `shouldBe` Nothing
      evidenceAwsDnsZone cascadeScopeWithZone `shouldBe` Just challengeZone

    it "differs from the zoneless scope in the zone and nothing else" $ do
      -- The scope is the durable binding a request and its response share, so
      -- adding a zone must not silently change the surface, revision, run
      -- scope, foundation, AWS scope, or operation the two agree on.
      map ($ cascadeScopeWithZone) scopeFacets
        `shouldBe` map ($ cascadeScope) scopeFacets
      cascadeScopeWithZone `shouldNotBe` cascadeScope

  describe "Sprint 4.84 complete exact observation set" $ do
    it "admits one correctly bound observation for every selected key" $ do
      let observations =
            [ correctObservation AwsEksKey (ExactResourceAbsent absence)
            , correctObservation AwsEksSubzoneKey present
            , correctObservation AwsTestKey (ExactResourceAbsent absence)
            ]
      case mkCompleteObservationSet cascadeScope stackKeys observations of
        Left err -> expectationFailure (show err)
        Right complete -> do
          completeObservationSetKeys complete `shouldBe` stackKeys
          decideCompleteObservationSet complete
            `shouldBe` SelectedResourcesRequireCleanup (AwsEksSubzoneKey :| [])

    it "rejects missing, duplicate, and unexpected keys" $ do
      let allObservations =
            map
              (\key -> correctObservation key (ExactResourceAbsent absence))
              stackKeys
      mkCompleteObservationSet cascadeScope stackKeys (take 2 allObservations)
        `shouldBe` Left (ObservationMissingKey AwsTestKey)
      mkCompleteObservationSet
        cascadeScope
        stackKeys
        (correctObservation AwsEksKey (ExactResourceAbsent absence) : allObservations)
        `shouldBe` Left (ObservationDuplicateKey AwsEksKey)
      mkCompleteObservationSet
        cascadeScope
        stackKeys
        (allObservations ++ [correctObservation AwsEbsPerRunTestKey (ExactResourceAbsent absence)])
        `shouldBe` Left (ObservationUnexpectedKey AwsEbsPerRunTestKey)
      mkCompleteObservationSet cascadeScope [AwsEksKey, AwsEksKey] allObservations
        `shouldBe` Left (ObservationSelectionDuplicateKey AwsEksKey)

    it "rejects wrong key/coordinate and authority bindings" $ do
      let eksObservation = correctObservation AwsEksKey (ExactResourceAbsent absence)
          wrongKey =
            eksObservation
              { exactObservationResourceKey = AwsEksSubzoneKey
              }
          expectedSubzoneDigest =
            registeredIdentityCoordinateDigest (mustIdentity AwsEksSubzoneKey)
      mkCompleteObservationSet cascadeScope [AwsEksSubzoneKey] [wrongKey]
        `shouldBe` Left
          ( ObservationCoordinateMismatch
              AwsEksSubzoneKey
              expectedSubzoneDigest
              (exactObservationCoordinateDigest eksObservation)
          )
      mkCompleteObservationSet
        cascadeScope
        [AwsEksKey]
        [eksObservation {exactObservationAuthority = LocalRke2SystemAuthority}]
        `shouldBe` Left
          ( ObservationAuthorityMismatch
              AwsEksKey
              AwsResourceApiAuthority
              LocalRke2SystemAuthority
          )

    it "rejects every wrong durable scope binding independently" $ do
      forM_ wrongScopeTable $ \(wrongScope, expectedError) ->
        mkCompleteObservationSet
          cascadeScope
          [AwsEksKey]
          [ observationWithScope AwsEksKey wrongScope
          ]
          `shouldBe` Left expectedError

    it "rejects an invalid registry revision, surface class, and missing AWS scope" $ do
      mkCompleteObservationSet
        (scopeWithRevision staleRegistryRevision)
        [AwsEksKey]
        [observationWithScope AwsEksKey (scopeWithRevision staleRegistryRevision)]
        `shouldBe` Left
          ( ObservationSetRegistryRevisionMismatch
              lifecycleRegistryRevision
              staleRegistryRevision
          )
      mkCompleteObservationSet
        cascadeScope
        [AwsEbsProductionRetainedKey]
        [correctObservation AwsEbsProductionRetainedKey (ExactResourceAbsent absence)]
        `shouldBe` Left
          ( ObservationSelectionNotAllowed
              ( ManagedResourceNotAllowedOnSurface
                  AwsEbsProductionRetainedKey
                  LongLived
                  Cascade
              )
          )
      mkCompleteObservationSet
        scopeWithoutAws
        [AwsEksKey]
        [observationWithScope AwsEksKey scopeWithoutAws]
        `shouldBe` Left (ObservationSelectionAwsScopeRequired AwsEksKey)

    it "accepts Partial and Unobservable structurally but the total fold refuses both" $ do
      let partial =
            ExactResourcePartial
              (PartialEvidence [ObservedResourceIdentity "i-partial"])
              (ObservationFailure "page missing" :| [])
          unobservable =
            ExactResourceUnobservable
              (ObservationFailure "access denied" :| [])
          observations =
            [ correctObservation AwsEksKey partial
            , correctObservation AwsEksSubzoneKey unobservable
            ]
      case mkCompleteObservationSet
        cascadeScope
        [AwsEksKey, AwsEksSubzoneKey]
        observations of
        Left err -> expectationFailure (show err)
        Right complete ->
          decideCompleteObservationSet complete
            `shouldBe` CompleteObservationsRefused
              ( ExactObservationPartialRefusal
                  AwsEksKey
                  (PartialEvidence [ObservedResourceIdentity "i-partial"])
                  (ObservationFailure "page missing" :| [])
                  :| [ ExactObservationUnobservableRefusal
                         AwsEksSubzoneKey
                         (ObservationFailure "access denied" :| [])
                     ]
              )

  describe "Sprint 4.84 distinct external observation types" $ do
    it "pairs primary and backup checkpoints only for one exact stack and scope" $ do
      let primary = checkpoint PrimaryCheckpointCopy AwsEksKey cascadeScope
          backup = checkpoint BackupCheckpointCopy AwsEksKey cascadeScope
      mkCheckpointPairObservation AwsEksKey cascadeScope backup primary
        `shouldBe` Right
          CheckpointPairObservation
            { checkpointPairStackKey = AwsEksKey
            , checkpointPairEvidenceScope = cascadeScope
            , primaryCheckpointObservation = primary
            , backupCheckpointObservation = backup
            }
      mkCheckpointPairObservation AwsEbsPerRunTestKey cascadeScope primary backup
        `shouldBe` Left
          ( CheckpointPairResourceIsNotStack
              AwsEbsPerRunTestKey
              VolumeFamily
          )
      mkCheckpointPairObservation AwsEksKey cascadeScope primary primary
        `shouldBe` Left (CheckpointPairCopyMissing BackupCheckpointCopy)

    it "retains manifest provenance without promoting it to exact resource truth" $ do
      let manifest =
            OwnershipManifestObservation
              { ownershipManifestStackKey = AwsEksKey
              , ownershipManifestProvenance = OwnershipManifestProvenance "manifest/object/v1"
              , ownershipManifestEvidenceScope = cascadeScope
              , ownershipManifestResult =
                  OwnershipManifestPresent (OwnershipManifestVersion "etag-1")
              }
      ownershipManifestStackKey manifest `shouldBe` AwsEksKey
      ownershipManifestEvidenceScope manifest `shouldBe` cascadeScope

    it "surface-indexes terminal audit scope and rejects exact-observation scope reuse" $ do
      let auditEvidence =
            mkObservationEvidenceScope
              Cascade
              lifecycleRegistryRevision
              runScope
              foundation
              (Just awsScope)
              RunTerminalEscapeAudit
      mkTerminalAuditScope
        CascadeSurface
        auditEvidence
        (TerminalAuditQueryDigest "query-v1")
        (TerminalAuditRetainedSetDigest "retained-v1")
        `shouldSatisfy` isRight
      mkTerminalAuditScope
        CascadeSurface
        cascadeScope
        (TerminalAuditQueryDigest "query-v1")
        (TerminalAuditRetainedSetDigest "retained-v1")
        `shouldBe` Left (TerminalAuditOperationMismatch ReconcileDesiredAbsent)

  describe "Sprint 4.84 AWS ARN normalization" $ do
    it "normalizes tag rows, page overlap, and retries to one resource per ARN" $ do
      let rows = [bucketRow ownerTag, bucketRow lifecycleTag, bucketRow ownerTag]
      case normalizeAwsTagRows rows of
        Left err -> expectationFailure (show err)
        Right inventory -> do
          awsInventorySize inventory `shouldBe` 1
          fmap awsResourceTags (awsInventoryLookup bucketArn inventory)
            `shouldBe` Just
              ( Map.fromList
                  [ ("prodbox.io/owner", "prodbox")
                  , ("prodbox.io/lifecycle", "retained")
                  ]
              )

    it "refuses conflicting scope, type, coordinate, and tag facts for one ARN" $ do
      forM_ conflictingRows $ \(row, expected) ->
        normalizeAwsTagRows [bucketRow ownerTag, row]
          `shouldBe` Left expected

    it "keeps a normalized retained audit resource separate from unobservable stacks" $ do
      inventory <- case normalizeAwsTagRows [bucketRow ownerTag, bucketRow lifecycleTag] of
        Left err -> expectationFailure (show err) >> error "unreachable"
        Right normalized -> pure normalized
      awsInventorySize inventory `shouldBe` 1
      let stackObservations =
            [ correctObservation
                key
                (ExactResourceUnobservable (ObservationFailure "observer unavailable" :| []))
            | key <- stackKeys
            ]
      case mkCompleteObservationSet cascadeScope stackKeys stackObservations of
        Left err -> expectationFailure (show err)
        Right complete ->
          decideCompleteObservationSet complete
            `shouldSatisfy` isRefusedDecision

    it "keeps the pure registry free of effect callbacks and operator commands" $ do
      registrySource <- readFile "src/Prodbox/Lifecycle/Teardown/Registry.hs"
      registrySource `shouldNotContain` "FilePath ->"
      registrySource `shouldNotContain` "IO "
      registrySource `shouldNotContain` "resourceDestroy"
      registrySource `shouldNotContain` "prodbox aws"

registryRow
  :: RegisteredIdentity
  -> (RegisteredResourceKey, Maybe LifecycleClass, ResourceKind)
registryRow identity =
  ( registeredIdentityKey identity
  , registeredIdentityLifecycleClass identity
  , registeredIdentityKind identity
  )

surfaceTable :: [(RegisteredResourceKey, [CleanupSurface])]
surfaceTable =
  [ (LocalLinuxRke2Key, [LocalOnly, Cascade, TotalDecommission])
  , (AwsEksKey, [Cascade, ExplicitPerRun, TotalDecommission])
  , (AwsEksSubzoneKey, [Cascade, ExplicitPerRun, TotalDecommission])
  , (AwsTestKey, [Cascade, ExplicitPerRun, TotalDecommission])
  , (AwsEbsPerRunTestKey, [Cascade, ExplicitPerRun, TotalDecommission])
  , (AwsDnsValidationZoneKey, [Cascade, ExplicitPerRun, TotalDecommission])
  , (AwsDns01ChallengeRecordKey, [Cascade, ExplicitPerRun, TotalDecommission])
  , (AwsEksIamRoleFamilyKey, [Cascade, ExplicitPerRun, TotalDecommission])
  , (AwsEksLoadBalancerControllerFamilyKey, [Cascade, ExplicitPerRun, TotalDecommission])
  , (AwsEbsProductionRetainedKey, [ExplicitLongLived, TotalDecommission])
  ]

stackKeys :: [RegisteredResourceKey]
stackKeys = [AwsEksKey, AwsEksSubzoneKey, AwsTestKey]

runScope :: DurableObservationRunScope
runScope = DurableObservationRunScope "cleanup-run/fixture"

foundation :: LinuxRke2FoundationId
foundation = LinuxRke2FoundationId "home-linux-rke2"

awsScope :: AwsScope
awsScope = AwsScope (AwsAccountId "111122223333") (AwsRegion (fixtureAwsRegion FixtureCaCentral1))

challengeZone :: HostedZoneId
challengeZone = mustRightText (mkHostedZoneId "Z0123456789ABCDEFGHIJ")

mustRightText :: (Show err) => Either err value -> value
mustRightText result = case result of
  Right value -> value
  Left err -> error ("expected Right, got " <> show err)

cascadeScope :: ObservationEvidenceScope
cascadeScope =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    runScope
    foundation
    (Just awsScope)
    ReconcileDesiredAbsent

cascadeScopeWithZone :: ObservationEvidenceScope
cascadeScopeWithZone =
  mkObservationEvidenceScopeWithDnsZone
    Cascade
    lifecycleRegistryRevision
    runScope
    foundation
    (Just awsScope)
    challengeZone
    ReconcileDesiredAbsent

-- | Everything about a scope other than its DNS zone, as comparable text.
scopeFacets :: [ObservationEvidenceScope -> Text]
scopeFacets =
  [ renderText . evidenceCleanupSurface
  , renderText . evidenceRegistryRevision
  , renderText . evidenceDurableRunScope
  , renderText . evidenceLinuxRke2Foundation
  , renderText . evidenceAwsScope
  , renderText . evidenceLifecycleOperation
  ]
 where
  renderText :: (Show value) => value -> Text
  renderText = Text.pack . show

scopeWithRevision :: RegistryRevision -> ObservationEvidenceScope
scopeWithRevision revision =
  mkObservationEvidenceScope
    Cascade
    revision
    runScope
    foundation
    (Just awsScope)
    ReconcileDesiredAbsent

scopeWithoutAws :: ObservationEvidenceScope
scopeWithoutAws =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    runScope
    foundation
    Nothing
    ReconcileDesiredAbsent

staleRegistryRevision :: RegistryRevision
staleRegistryRevision = RegistryRevision "lifecycle-registry/stale"

absence :: AbsenceEvidence
absence = AbsenceEvidence "authoritative-not-found"

present :: ExactObservationResult
present =
  ExactResourcePresent
    (ExactResourceInventory (ObservedResourceIdentity "arn:fixture" :| []))

correctObservation
  :: RegisteredResourceKey
  -> ExactObservationResult
  -> ExactResourceObservation
correctObservation key result = observationWithScopeAndResult key cascadeScope result

observationWithScope
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> ExactResourceObservation
observationWithScope key scope =
  observationWithScopeAndResult key scope (ExactResourceAbsent absence)

observationWithScopeAndResult
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> ExactObservationResult
  -> ExactResourceObservation
observationWithScopeAndResult key scope result =
  exactResourceObservationFor
    (mustIdentity key)
    (ObservationRevision 7)
    scope
    result

wrongScopeTable
  :: [(ObservationEvidenceScope, CompleteObservationSetError)]
wrongScopeTable =
  [
    ( mkObservationEvidenceScope
        ExplicitPerRun
        lifecycleRegistryRevision
        runScope
        foundation
        (Just awsScope)
        ReconcileDesiredAbsent
    , ObservationSurfaceMismatch AwsEksKey Cascade ExplicitPerRun
    )
  ,
    ( scopeWithRevision staleRegistryRevision
    , ObservationRegistryRevisionMismatch
        AwsEksKey
        lifecycleRegistryRevision
        staleRegistryRevision
    )
  ,
    ( mkObservationEvidenceScope
        Cascade
        lifecycleRegistryRevision
        (DurableObservationRunScope "cleanup-run/other")
        foundation
        (Just awsScope)
        ReconcileDesiredAbsent
    , ObservationDurableRunScopeMismatch
        AwsEksKey
        runScope
        (DurableObservationRunScope "cleanup-run/other")
    )
  ,
    ( mkObservationEvidenceScope
        Cascade
        lifecycleRegistryRevision
        runScope
        (LinuxRke2FoundationId "other-linux-rke2")
        (Just awsScope)
        ReconcileDesiredAbsent
    , ObservationFoundationMismatch
        AwsEksKey
        foundation
        (LinuxRke2FoundationId "other-linux-rke2")
    )
  ,
    ( mkObservationEvidenceScope
        Cascade
        lifecycleRegistryRevision
        runScope
        foundation
        (Just (AwsScope (AwsAccountId "999900001111") (AwsRegion (fixtureAwsRegion FixtureCaCentral1))))
        ReconcileDesiredAbsent
    , ObservationAwsScopeMismatch
        AwsEksKey
        (Just awsScope)
        (Just (AwsScope (AwsAccountId "999900001111") (AwsRegion (fixtureAwsRegion FixtureCaCentral1))))
    )
  ,
    ( mkObservationEvidenceScope
        Cascade
        lifecycleRegistryRevision
        runScope
        foundation
        (Just (AwsScope (AwsAccountId "111122223333") (AwsRegion (fixtureAwsRegion FixtureUsEast1))))
        ReconcileDesiredAbsent
    , ObservationAwsScopeMismatch
        AwsEksKey
        (Just awsScope)
        (Just (AwsScope (AwsAccountId "111122223333") (AwsRegion (fixtureAwsRegion FixtureUsEast1))))
    )
  ,
    ( mkObservationEvidenceScope
        Cascade
        lifecycleRegistryRevision
        runScope
        foundation
        (Just awsScope)
        ReconcileDesiredPresent
    , ObservationOperationMismatch
        AwsEksKey
        ReconcileDesiredAbsent
        ReconcileDesiredPresent
    )
  ]

checkpoint
  :: CheckpointCopy
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> CheckpointObservation
checkpoint copy key scope =
  CheckpointObservation
    { checkpointObservationStackKey = key
    , checkpointObservationCopy = copy
    , checkpointObservationProvenance = CheckpointProvenance "checkpoint/object/v1"
    , checkpointObservationEvidenceScope = scope
    , checkpointObservationResult = CheckpointPresent (CheckpointVersion "etag-1")
    }

bucketArn :: Arn
bucketArn = mustArn "arn:aws:s3:::prodbox-retained-state"

ownerTag :: AwsTag
ownerTag = AwsTag "prodbox.io/owner" "prodbox"

lifecycleTag :: AwsTag
lifecycleTag = AwsTag "prodbox.io/lifecycle" "retained"

bucketRow :: AwsTag -> AwsTagRow
bucketRow tag =
  AwsTagRow
    { awsTagRowArn = bucketArn
    , awsTagRowScope = awsScope
    , awsTagRowResourceType = AwsResourceType "s3:bucket"
    , awsTagRowCoordinate = AwsResourceCoordinate "prodbox-retained-state"
    , awsTagRowTag = Just tag
    }

conflictingRows :: [(AwsTagRow, AwsInventoryFailure)]
conflictingRows =
  [
    ( (bucketRow lifecycleTag)
        { awsTagRowScope =
            AwsScope (AwsAccountId "999900001111") (AwsRegion (fixtureAwsRegion FixtureCaCentral1))
        }
    , AwsResourceScopeConflict
        bucketArn
        awsScope
        (AwsScope (AwsAccountId "999900001111") (AwsRegion (fixtureAwsRegion FixtureCaCentral1)))
    )
  ,
    ( (bucketRow lifecycleTag)
        { awsTagRowResourceType = AwsResourceType "ec2:volume"
        }
    , AwsResourceTypeConflict
        bucketArn
        (AwsResourceType "s3:bucket")
        (AwsResourceType "ec2:volume")
    )
  ,
    ( (bucketRow lifecycleTag)
        { awsTagRowCoordinate = AwsResourceCoordinate "other-bucket"
        }
    , AwsResourceCoordinateConflict
        bucketArn
        (AwsResourceCoordinate "prodbox-retained-state")
        (AwsResourceCoordinate "other-bucket")
    )
  ,
    ( bucketRow (AwsTag "prodbox.io/owner" "other-project")
    , AwsResourceTagConflict
        bucketArn
        "prodbox.io/owner"
        "prodbox"
        "other-project"
    )
  ]

mustIdentity :: RegisteredResourceKey -> RegisteredIdentity
mustIdentity key = case lookupRegisteredIdentity key of
  Nothing -> error ("missing registry fixture: " ++ show key)
  Just identity -> identity

mustArn :: Text -> Arn
mustArn raw = case mkArn raw of
  Left err -> error (show err)
  Right arn -> arn

isRefusedDecision :: CompleteObservationDecision -> Bool
isRefusedDecision decision = case decision of
  CompleteObservationsRefused _ -> True
  _ -> False
