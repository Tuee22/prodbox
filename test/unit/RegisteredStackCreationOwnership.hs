{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.41: a create that says what it is about to make.
--
-- The lane's own ordering is not testable here — it needs a live Authority —
-- so what is asserted is everything the ordering rests on: that the two
-- durable slots are distinct objects, that an append narrows rather than
-- widens, that appended identities reach the destroy authorization, and that
-- every failure arm before the effect is one under which no cloud resource can
-- exist.
module RegisteredStackCreationOwnership
  ( registeredStackCreationOwnershipSuite
  )
where

import Control.Monad (forM_)
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthorityProviderEndpoint
  ( AuthorityProviderClientError (AuthorityProviderRemoteRefused)
  )
import Prodbox.ControlPlane.AwsStackCreationBindingRepository
  ( AwsStackCreationCommitResult (AwsStackCreationCommitCreated)
  )
import Prodbox.ControlPlane.OwnershipManifestRepository
  ( OwnershipManifestAuthorityReadBack (OwnershipManifestAuthorityReadBackPresent)
  , OwnershipManifestSlotStage (..)
  , authorityOwnershipManifestWriteBytes
  , authorityOwnershipManifestWriteIdentity
  , confirmOwnershipManifestDecisionReadBack
  , ownershipManifestAuthorityLogicalName
  , ownershipManifestSlotLogicalName
  , prepareAuthorityOwnershipManifestWrite
  )
import Prodbox.ControlPlane.ProviderCaller
  ( ProviderCallerError (ProviderCallerDispatchFailed)
  )
import Prodbox.ControlPlane.ProviderPulumiConfigProjection
  ( providerRunMarkerConfiguration
  , providerRunMarkerProgramBindings
  )
import Prodbox.ControlPlane.RegisteredStackCreationSubmitter
  ( RegisteredStackCreationSubmitError (..)
  , WriteAheadOwnershipProof
  , proveWriteAheadOwnership
  , registeredStackCreationRunScope
  , registeredStackCreationScope
  , renderRegisteredStackCreationSubmitError
  , writeAheadOwnershipProofStackKey
  )
import Prodbox.Lifecycle.Authority.AdminAction
  ( PermitFreshness (PermitFresh)
  , RunnerRole (AdminActionRunner)
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBObjectVersion
  , mkModelBObjectVersion
  )
import Prodbox.Lifecycle.DnsRecord (mkHostedZoneId)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderRefError (ProviderRefEmpty, ProviderRefMalformed, ProviderRefTooLong)
  , maximumProviderRunMarkerLength
  , mkProviderRunMarker
  )
import Prodbox.Lifecycle.Teardown.AuditFieldOfView
  ( DeclaredAwsResource (declaredResourceName, declaredResourceTags)
  , parseProvisioningProgram
  )
import Prodbox.Lifecycle.Teardown.CreateRecordCoverage (perRunProgramDirectories)
import Prodbox.Lifecycle.Teardown.LegacyAdoptionPlan
  ( AdminLegacyAdoptionPermitRequest (..)
  , ConfirmedLegacyAdoptionPlan
  , LegacyAdoptionPlan
  , admitAdminLegacyAdoptionPermit
  , confirmLegacyAdoptionPlan
  , legacyAdoptionPlanDigestOf
  , planLegacyAdoption
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.OwnershipManifest
import Prodbox.Lifecycle.Teardown.Registry
import Prodbox.Lifecycle.Teardown.ScopeCodec
  ( ObservationEvidenceScopeFields (scopeFieldLifecycleOperation)
  , observationEvidenceScopeFields
  , scopeForOwnershipManifestCleanupReadBack
  )
import TestSupport

registeredStackCreationOwnershipSuite :: SuiteBuilder ()
registeredStackCreationOwnershipSuite =
  describe "Sprint 7.41 write-ahead ownership" $ do
    describe "a cleanup-only adoption receipt is not a create's record" $ do
      it "mints a proof from a write-ahead read-back" $ do
        -- The positive control. Without it the negative one below would pass
        -- against a minter that refuses everything.
        proveWriteAheadOwnership AwsTestKey boundEvidence
          `shouldSatisfy` isJustProof
        fmap writeAheadOwnershipProofStackKey (proveWriteAheadOwnership AwsTestKey boundEvidence)
          `shouldBe` Just AwsTestKey

      it "refuses a confirmed legacy-adoption receipt" $ do
        -- Sprint 7.42. The GADT index says an adoption receipt may not inhabit
        -- this slot, and until the decision view carried a purpose nothing here
        -- could tell one from a create's own record: an adoption commits a
        -- complete manifest and reads it back through the same projection. A
        -- proof minted from this value would authorize an execute step for
        -- resources this run never made.
        ownershipManifestDecisionView adoptionEvidence
          `shouldSatisfy` isAdoptionPurpose
        proveWriteAheadOwnership AwsTestKey adoptionEvidence `shouldBe` Nothing

    describe "one identity, two durable objects" $ do
      it "addresses the completion slot as a different object" $ do
        -- The write-ahead slot is immutable by construction, so the identities
        -- the provider returned cannot be appended to it. A second object under
        -- the same identity is what makes the append possible at all.
        let prepared = mustRight (prepareAuthorityOwnershipManifestWrite initialWrite)
            identity = authorityOwnershipManifestWriteIdentity prepared
        ownershipManifestSlotLogicalName WriteAheadSlot identity
          `shouldNotBe` ownershipManifestSlotLogicalName CompletionSlot identity

      it "leaves the write-ahead object's name exactly where it was" $ do
        -- The stage is a namespace on the logical name and not a field of the
        -- identity, so no submission key moves and no encoding version is
        -- spent on a change that is not about identity.
        let prepared = mustRight (prepareAuthorityOwnershipManifestWrite initialWrite)
            identity = authorityOwnershipManifestWriteIdentity prepared
        ownershipManifestSlotLogicalName WriteAheadSlot identity
          `shouldBe` ownershipManifestAuthorityLogicalName identity

    describe "the append narrows, and never widens" $ do
      it "gives every declared entry the identities the provider returned" $ do
        let appended =
              mustRight
                ( appendObservedIdentitiesToWriteAheadManifest
                    creationIntent
                    [(AwsTestKey, [observedIdentity])]
                )
        concatMap
          ownershipManifestEntryObservedIdentities
          (ownershipManifestWriteEntries appended)
          `shouldBe` [observedIdentity]

      it "keeps the entry set the write-ahead record already committed" $ do
        -- Same keys, same coordinate digests, same canonical order. Only the
        -- identity list moves, which is what makes the completion bindable
        -- against the registered ownership edges at cleanup time.
        let appended =
              mustRight
                ( appendObservedIdentitiesToWriteAheadManifest
                    creationIntent
                    [(AwsTestKey, [observedIdentity])]
                )
        map ownershipManifestEntryKey (ownershipManifestWriteEntries appended)
          `shouldBe` map
            ownershipManifestEntryKey
            (ownershipManifestWriteEntries initialWrite)

      it "refuses an identity for a resource the record never declared" $
        -- A create reporting that it made something it never said it was about
        -- to make is the condition the write-ahead record exists to prevent,
        -- not a fact to record.
        appendObservedIdentitiesToWriteAheadManifest
          creationIntent
          [(AwsEksKey, [observedIdentity])]
          `shouldSatisfy` isAppendedKeyUndeclared

      it "refuses an append that appends nothing" $
        -- A completion carrying no identity claims the create returned and made
        -- nothing, which is the false reassurance a leak needs somebody to
        -- believe.
        appendObservedIdentitiesToWriteAheadManifest creationIntent [(AwsTestKey, [])]
          `shouldSatisfy` isAppendedIdentitiesEmpty

    describe "appended identities reach the destroy authorization" $
      it "survives capture, read-back binding, and the decision's entry lookup" $ do
        -- The whole point of the append: a manifest with no identities commits
        -- and reads back exactly as a real one does and authorizes the
        -- destruction of nothing.
        let appended =
              mustRight
                ( appendObservedIdentitiesToWriteAheadManifest
                    creationIntent
                    [(AwsTestKey, [observedIdentity])]
                )
            durable = mustRight (captureDurableWriteAheadOwnershipManifest appended)
            observed =
              mustRight
                ( observedDurableWriteAheadOwnershipManifest
                    "authority/completion"
                    "2"
                    durable
                )
            target =
              mustRight
                (mkOwnershipManifestTarget ExplicitPerRunSurface AwsTestKey cleanupScope)
            evidence =
              mustRight
                ( bindObservedDurableWriteAheadOwnershipManifestForCleanup
                    target
                    observed
                )
        ownershipManifestDecisionEntryIdentities AwsTestKey evidence
          `shouldBe` Just [observedIdentity]

    describe "an identity-less manifest is not authority" $
      it "reaches the decision with no identity on the entry" $ do
        -- The write-ahead record on its own. It is addressable, and the
        -- destroy authorization refuses it by naming what is missing rather
        -- than by destroying nothing.
        let durable = mustRight (captureDurableWriteAheadOwnershipManifest initialWrite)
            observed =
              mustRight
                ( observedDurableWriteAheadOwnershipManifest
                    "authority/write-ahead"
                    "1"
                    durable
                )
            target =
              mustRight
                (mkOwnershipManifestTarget ExplicitPerRunSurface AwsTestKey cleanupScope)
            evidence =
              mustRight
                ( bindObservedDurableWriteAheadOwnershipManifestForCleanup
                    target
                    observed
                )
        ownershipManifestDecisionEntryIdentities AwsTestKey evidence
          `shouldBe` Just []

    describe "the marker the provider holds" $ do
      it "refuses a value a provider would refuse, where the value is named" $ do
        -- The refusal belongs here and not at `pulumi up`, which happens after
        -- the request has been admitted and after the write-ahead record claims
        -- the create is about to run.
        mkProviderRunMarker "" "fixture-create-0001"
          `shouldBe` Left ProviderRefEmpty
        mkProviderRunMarker "stack-create/1" "contains a space"
          `shouldBe` Left (ProviderRefMalformed "contains a space")
        mkProviderRunMarker overlongValue "fixture-create-0001"
          `shouldBe` Left (ProviderRefTooLong (Text.length overlongValue))

      it "projects both values into the Pulumi configuration" $
        -- Into the configuration, which the preview and the apply both carry.
        -- Projecting a key onto only one of them is the frozen counterexample
        -- PROVIDER-WORKER-PULUMI-STACK-CONFIG-ABSENT-2026-09-05.
        providerRunMarkerConfiguration fixtureProviderRunMarker
          `shouldBe` [ ("prodboxRunScope", "stack-create/1700000000000000")
                     , ("prodboxSubmission", "fixture-create-0001")
                     ]

      it "reaches every resource of every per-run program" $
        -- The join the two languages cannot make for themselves: the Haskell
        -- sets a configuration key and the committed program reads one, and
        -- nothing but this compares the names. A rename on either side stamps
        -- an empty tag onto every resource and fails nothing.
        forM_ perRunProvisioningPrograms $ \programName -> do
          source <- readFile ("pulumi/" ++ programName ++ "/Main.yaml")
          case parseProvisioningProgram (Text.pack programName) (Text.pack source) of
            Left err -> expectationFailure (programName ++ ": " ++ show err)
            Right declared -> do
              declared `shouldNotBe` []
              forM_ declared $ \resource ->
                forM_ providerRunMarkerProgramBindings $ \(configKey, tagKey) ->
                  ( programName
                  , Text.unpack (declaredResourceName resource)
                  , lookup (Text.pack tagKey) (declaredResourceTags resource)
                  )
                    `shouldBe` ( programName
                               , Text.unpack (declaredResourceName resource)
                               , Just (Text.pack ("${" ++ configKey ++ "}"))
                               )

      it "does not reach the retained long-lived stack" $
        -- `aws-ses` outlives every run. A per-run marker on it would tell a
        -- per-run sweep that the one stack nothing may reap belongs to the run
        -- currently reaping.
        do
          source <- readFile "pulumi/aws-ses/Main.yaml"
          case parseProvisioningProgram "aws-ses" (Text.pack source) of
            Left err -> expectationFailure ("aws-ses: " ++ show err)
            Right declared ->
              [ tagKey
              | resource <- declared
              , (tagKey, _) <- declaredResourceTags resource
              , tagKey `elem` map (Text.pack . snd) providerRunMarkerProgramBindings
              ]
                `shouldBe` []

    describe "the create reads its own record back on the cleanup side" $ do
      -- The live campaign's first exercise of this lane refused every create
      -- with `OwnershipManifestScopeOperationMismatch ReconcileDesiredAbsent
      -- ReconcileDesiredPresent`, and nothing here could see it: both this
      -- suite and the repository suite hand-built the cleanup-side scope in a
      -- fixture, so the relationship they asserted was the one an author had
      -- already got right rather than the one production passes.
      it "refuses a target minted under the create's own scope" $
        -- The defect, stated as the refusal it was. A target is cleanup
        -- authority's vehicle, so its mint demands the cleanup side; a create
        -- asking with its own scope is asking the wrong question, and the
        -- answer was a refused create rather than a wrong destroy.
        mkOwnershipManifestTarget ExplicitPerRunSurface AwsTestKey creationScope
          `shouldSatisfy` isScopeOperationMismatch

      it "mints one under the scope the submitter asks with" $
        mkOwnershipManifestTarget
          ExplicitPerRunSurface
          AwsTestKey
          (scopeForOwnershipManifestCleanupReadBack creationScope)
          `shouldSatisfy` isMintedTarget

      it "still addresses the object the commit wrote" $ do
        -- The other half, and the one that makes the flip safe rather than
        -- merely accepted: the identity normalises the operation away, so the
        -- commit's own identity confirms against a target minted on the other
        -- side. If it did not, the record would be unreachable at exactly the
        -- moment it exists to be read.
        let prepared = mustRight (prepareAuthorityOwnershipManifestWrite initialWrite)
            identity = authorityOwnershipManifestWriteIdentity prepared
            target =
              mustRight
                ( mkOwnershipManifestTarget
                    ExplicitPerRunSurface
                    AwsTestKey
                    (scopeForOwnershipManifestCleanupReadBack creationScope)
                )
        fmap
          (proveWriteAheadOwnership AwsTestKey)
          ( confirmOwnershipManifestDecisionReadBack
              target
              identity
              ( OwnershipManifestAuthorityReadBackPresent
                  readBackFixtureVersion
                  (authorityOwnershipManifestWriteBytes prepared)
              )
          )
          `shouldSatisfy` isProvedThroughReadBack

      it "changes the operation and nothing else" $
        -- A field-by-field re-mint is how this scope's DNS hosted zone was lost
        -- once already, so the re-scoper is a record update and this states it.
        observationEvidenceScopeFields
          (scopeForOwnershipManifestCleanupReadBack zonedCreationScope)
          `shouldBe` (observationEvidenceScopeFields zonedCreationScope)
            { scopeFieldLifecycleOperation = ReconcileDesiredAbsent
            }

    describe "the one arm that can leave a resource names it" $ do
      it "renders a durable obligation rather than a diagnostic" $ do
        -- Sprint 7.41 deliverable 5. Every other failure on this lane is before
        -- the effect and can leave nothing behind; this one is after it.
        let rendered = renderRegisteredStackCreationSubmitError dispatchFailedFixture
        rendered `shouldSatisfy` ("write-ahead ownership manifest" `isInfixOf`)
        rendered `shouldSatisfy` ("aws-test" `isInfixOf`)
        rendered `shouldSatisfy` ("is not discharged" `isInfixOf`)

      it "states that a pre-effect refusal created nothing" $ do
        let rendered =
              renderRegisteredStackCreationSubmitError
                intentNotRegisteredStackFixture
        rendered `shouldSatisfy` ("Nothing was created" `isInfixOf`)

-- | The three programs a per-run create makes resources with.  @aws-ses@ is
-- deliberately absent. Projected from the create-record declaration, so the
-- list cannot be hand-edited apart from the decision it states.
perRunProvisioningPrograms :: [String]
perRunProvisioningPrograms = map Text.unpack perRunProgramDirectories

overlongValue :: Text.Text
overlongValue = Text.replicate (maximumProviderRunMarkerLength + 1) "x"

isScopeOperationMismatch
  :: Either OwnershipManifestError (OwnershipManifestTarget surface) -> Bool
isScopeOperationMismatch result = case result of
  Left (OwnershipManifestScopeOperationMismatch ReconcileDesiredAbsent ReconcileDesiredPresent) ->
    True
  _ -> False

isMintedTarget
  :: Either OwnershipManifestError (OwnershipManifestTarget surface) -> Bool
isMintedTarget result = case result of
  Right _ -> True
  Left _ -> False

isProvedThroughReadBack
  :: Either err (Maybe (WriteAheadOwnershipProof 'WriteAheadOwnership)) -> Bool
isProvedThroughReadBack result = case result of
  Right (Just _) -> True
  _ -> False

-- | A create scope that carries a retained DNS hosted zone, so the re-scoper's
-- field preservation is stated over the field it was once written without.
zonedCreationScope :: ObservationEvidenceScope
zonedCreationScope =
  mkObservationEvidenceScopeWithDnsZone
    ExplicitPerRun
    (evidenceRegistryRevision laneScope)
    (evidenceDurableRunScope laneScope)
    (evidenceLinuxRke2Foundation laneScope)
    ( Just
        ( AwsScope
            (AwsAccountId "111122223333")
            (AwsRegion (fixtureAwsRegion FixtureCaCentral1))
        )
    )
    (mustRight (mkHostedZoneId "Z0FIXTUREZONEID000"))
    ReconcileDesiredPresent

readBackFixtureVersion :: ModelBObjectVersion
readBackFixtureVersion = mustRight (mkModelBObjectVersion "manifest-object-v1")

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error ("fixture refused: " <> show err)

-- | The scope the manifest is actually keyed under: the lane's creation scope
-- with the account and region the committed generation proved. The creation
-- scope on its own carries no AWS coordinates by design, and the manifest
-- identity refuses one that does not — which is the same refusal the creation
-- binding hit and the same reason both derive their scope from the generation.
creationScope :: ObservationEvidenceScope
creationScope =
  mkObservationEvidenceScope
    ExplicitPerRun
    (evidenceRegistryRevision laneScope)
    (evidenceDurableRunScope laneScope)
    (evidenceLinuxRke2Foundation laneScope)
    ( Just
        ( AwsScope
            (AwsAccountId "111122223333")
            (AwsRegion (fixtureAwsRegion FixtureCaCentral1))
        )
    )
    ReconcileDesiredPresent

laneScope :: ObservationEvidenceScope
laneScope =
  registeredStackCreationScope
    (LinuxRke2FoundationId "linux-rke2/home")
    (registeredStackCreationRunScope 1700000000000000)

cleanupScope :: ObservationEvidenceScope
cleanupScope =
  mkObservationEvidenceScope
    ExplicitPerRun
    lifecycleRegistryRevision
    (evidenceDurableRunScope creationScope)
    (evidenceLinuxRke2Foundation creationScope)
    (evidenceAwsScope creationScope)
    ReconcileDesiredAbsent

creationIntent :: WriteAheadManifestIntent 'ExplicitPerRun
creationIntent =
  mustRight
    (mkWriteAheadManifestIntent ExplicitPerRunSurface AwsTestKey creationScope)

initialWrite :: OwnershipManifestWrite 'WriteAheadOwnership 'ExplicitPerRun
initialWrite = initialWriteAheadManifestWrite creationIntent

observedIdentity :: ObservedResourceIdentity
observedIdentity = ObservedResourceIdentity "provider-operation/fixture-0001"

-- | The proof, minted the only way production mints one: from complete
-- evidence a real bind returned.
writeAheadProof :: WriteAheadOwnershipProof 'WriteAheadOwnership
writeAheadProof =
  case proveWriteAheadOwnership AwsTestKey boundEvidence of
    Just proof -> proof
    Nothing -> error "fixture: a bound write-ahead manifest is not authority"

boundEvidence :: OwnershipManifestDecisionEvidence
boundEvidence =
  mustRight
    ( bindObservedDurableWriteAheadOwnershipManifestForCleanup
        ( mustRight
            (mkOwnershipManifestTarget ExplicitPerRunSurface AwsTestKey cleanupScope)
        )
        ( mustRight
            ( observedDurableWriteAheadOwnershipManifest
                "authority/write-ahead"
                "1"
                (mustRight (captureDurableWriteAheadOwnershipManifest initialWrite))
            )
        )
    )

-- | A real confirmed-adoption read-back, minted the only way the adoption lane
-- mints one.
--
-- Reached through 'completeConfirmedLegacyAdoptionManifestReadBack' rather than
-- through the repository, because the repository wraps its result in the opaque
-- @AdoptedCleanupOwnership@ and that wrapper is the /type-level/ half of the
-- same claim: it has no projection back to this evidence, so the mutation this
-- case exercises cannot even be written against the repository's own result.
-- What is left open at the library level is exactly this function, and this is
-- the arm that closes it.
adoptionEvidence :: OwnershipManifestDecisionEvidence
adoptionEvidence =
  mustRight
    ( completeConfirmedLegacyAdoptionManifestReadBack
        (OwnershipManifestProvenance "fixture/legacy-adoption")
        (OwnershipManifestVersion "adoption-v1")
        ( mustRight
            (confirmedLegacyAdoptionManifestWrite ExplicitPerRunSurface confirmedAdoptionPlan)
        )
    )

confirmedAdoptionPlan :: ConfirmedLegacyAdoptionPlan 'ExplicitPerRun
confirmedAdoptionPlan =
  mustRight (confirmLegacyAdoptionPlan permit adoptionPlan)
 where
  permit =
    mustRight
      ( admitAdminLegacyAdoptionPermit
          PermitFresh
          AdminLegacyAdoptionPermitRequest
            { adminLegacyPermitRequestAudience = AdminActionRunner
            , adminLegacyPermitRequestStackKey = AwsTestKey
            , adminLegacyPermitRequestPlanDigest =
                legacyAdoptionPlanDigestOf adoptionPlan
            , adminLegacyPermitRequestNonce = "adoption-provenance-witness"
            }
      )

adoptionPlan :: LegacyAdoptionPlan 'ExplicitPerRun
adoptionPlan =
  mustRight
    ( planLegacyAdoption
        ExplicitPerRunSurface
        AwsTestKey
        cleanupScope
        [ exactResourceObservationFor
            (mustIdentity familyKey)
            (ObservationRevision 7)
            cleanupScope
            (ExactResourceAbsent (providerWorkerAbsence "fixture observed absence"))
        | familyKey <- [AwsTestKey, AwsTestVpcCniInterfacesKey, AwsTestCanarySecurityGroupsKey]
        ]
    )

isAdoptionPurpose :: OwnershipManifestDecisionView -> Bool
isAdoptionPurpose view = case view of
  OwnershipManifestDecisionComplete (LegacyAdoptionOwnershipValue _) _ _ -> True
  _ -> False

isJustProof :: Maybe (WriteAheadOwnershipProof purpose) -> Bool
isJustProof value = case value of
  Just _ -> True
  Nothing -> False

dispatchFailedFixture :: RegisteredStackCreationSubmitError
dispatchFailedFixture =
  RegisteredStackCreationDispatchFailed
    AwsStackCreationCommitCreated
    ( ProviderCallerDispatchFailed
        (AuthorityProviderRemoteRefused 504 "transport deadline cancelled the reply")
    )
    writeAheadProof

intentNotRegisteredStackFixture :: RegisteredStackCreationSubmitError
intentNotRegisteredStackFixture = RegisteredStackCreationIntentNotRegisteredStack

isAppendedKeyUndeclared
  :: Either OwnershipManifestError value -> Bool
isAppendedKeyUndeclared result = case result of
  Left (OwnershipManifestAppendedKeyUndeclared _ _) -> True
  _ -> False

isAppendedIdentitiesEmpty
  :: Either OwnershipManifestError value -> Bool
isAppendedIdentitiesEmpty result = case result of
  Left (OwnershipManifestAppendedIdentitiesEmpty _) -> True
  _ -> False

mustIdentity :: RegisteredResourceKey -> RegisteredIdentity
mustIdentity key = case lookupRegisteredIdentity key of
  Just identity -> identity
  Nothing -> error ("unregistered fixture key " <> show key)
