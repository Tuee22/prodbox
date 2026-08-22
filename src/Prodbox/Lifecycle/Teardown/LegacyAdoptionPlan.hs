{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.36: the bounded legacy-adoption planner.
--
-- A stack created before write-ahead ownership manifests existed, whose
-- checkpoints are unusable, has no durable record of what it owns. Adopting it
-- means establishing that record from provider observation alone — and that is
-- the one place in this lifecycle where discovery and authority come closest to
-- touching. The whole design of this module is the wall between them.
--
-- __Discovery never authorizes mutation.__ 'planLegacyAdoption' is total over
-- the observations it is handed and produces a plan, not a permission. Only an
-- explicit admin permit naming that plan's exact digest can turn it into a
-- 'ConfirmedLegacyAdoptionPlan', and only a confirmed plan can supply the
-- @LegacyAdoptionPlanDigest@ a complete ownership manifest carries.
--
-- __The family is closed and registry-derived.__ The expected members are the
-- stack itself plus exactly the registered families whose controller-owner
-- cluster is that stack's cluster, which is the same derivation the write-ahead
-- manifest seeds itself from. There is no name-prefix sweep and no tag query
-- here: an observation for a key outside that set is an /extra candidate/ and
-- refuses the plan rather than widening it.
--
-- __Every way of not knowing refuses.__ A missing observation, an extra one, a
-- duplicate for one key, a partial or unobservable result, and one observed
-- identity claimed by two different registered keys are five distinct refusals.
-- None of them yields a smaller plan, because a smaller plan is exactly what an
-- adoption must never produce: it would record an ownership statement that omits
-- resources the stack really owns, and the cleanup that consumes it would then
-- prove absence over the wrong set and report completion.
--
-- __The digest is over what the operator was shown.__ 'renderLegacyAdoptionPlan'
-- is the canonical document, and 'legacyAdoptionPlanDigest' hashes exactly it.
-- An operator confirming a digest is confirming those bytes rather than a
-- summary of them.
module Prodbox.Lifecycle.Teardown.LegacyAdoptionPlan
  ( LegacyAdoptionPlanEntry (..)
  , LegacyAdoptionPlan
  , legacyAdoptionPlanStackKey
  , legacyAdoptionPlanScope
  , legacyAdoptionPlanSurface
  , legacyAdoptionPlanEntries
  , legacyAdoptionPlanDigestOf
  , renderLegacyAdoptionPlan
  , legacyAdoptionExpectedFamily
  , LegacyAdoptionRefusal (..)
  , planLegacyAdoption
  , AdminLegacyAdoptionPermitRequest (..)
  , AdminLegacyAdoptionPermit
  , adminLegacyAdoptionPermitPlanDigest
  , adminLegacyAdoptionPermitStackKey
  , adminLegacyAdoptionPermitNonce
  , AdminLegacyAdoptionPermitRefusal (..)
  , admitAdminLegacyAdoptionPermit
  , ConfirmedLegacyAdoptionPlan
  , confirmedLegacyAdoptionPlan
  , confirmedLegacyAdoptionPlanDigest
  , LegacyAdoptionConfirmationRefusal (..)
  , confirmLegacyAdoptionPlan
  )
where

import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Lifecycle.Authority.AdminAction
  ( PermitFreshness (PermitFresh)
  , RunnerRole (AdminActionRunner)
  )
import Prodbox.Lifecycle.DnsRecord (hostedZoneIdText)
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.OwnershipManifest.Internal
  ( LegacyAdoptionPlanDigest (..)
  , ownershipEdgeResourceKey
  , ownershipEdgeStackKey
  , registeredOwnershipEdges
  )
import Prodbox.Lifecycle.Teardown.Registry

-- | One registered family in the plan, with every identity the adoption would
-- take ownership of.
--
-- An entry with no identities is legal and meaningful: the family was observed
-- and is empty, which is a fact the manifest must record so a later cleanup does
-- not treat "nothing recorded" and "recorded as empty" as the same state.
data LegacyAdoptionPlanEntry = LegacyAdoptionPlanEntry
  { legacyAdoptionEntryKey :: !RegisteredResourceKey
  , legacyAdoptionEntryCoordinateDigest :: !ManagedResourceCoordinateDigest
  , legacyAdoptionEntryIdentities :: ![ObservedResourceIdentity]
  }
  deriving (Eq, Ord, Show)

-- | A rendered adoption plan. Opaque: the only way to hold one is
-- 'planLegacyAdoption', so a plan is always a plan over a complete, unambiguous
-- observation of the closed family.
data LegacyAdoptionPlan (surface :: CleanupSurface) = LegacyAdoptionPlan
  { internalLegacyPlanStackKey :: !RegisteredResourceKey
  , internalLegacyPlanSurface :: !CleanupSurface
  , internalLegacyPlanScope :: !ObservationEvidenceScope
  , internalLegacyPlanEntries :: ![LegacyAdoptionPlanEntry]
  , internalLegacyPlanDigest :: !LegacyAdoptionPlanDigest
  }
  deriving (Eq, Show)

legacyAdoptionPlanStackKey :: LegacyAdoptionPlan surface -> RegisteredResourceKey
legacyAdoptionPlanStackKey = internalLegacyPlanStackKey

legacyAdoptionPlanSurface :: LegacyAdoptionPlan surface -> CleanupSurface
legacyAdoptionPlanSurface = internalLegacyPlanSurface

legacyAdoptionPlanScope :: LegacyAdoptionPlan surface -> ObservationEvidenceScope
legacyAdoptionPlanScope = internalLegacyPlanScope

legacyAdoptionPlanEntries :: LegacyAdoptionPlan surface -> [LegacyAdoptionPlanEntry]
legacyAdoptionPlanEntries = internalLegacyPlanEntries

legacyAdoptionPlanDigestOf :: LegacyAdoptionPlan surface -> LegacyAdoptionPlanDigest
legacyAdoptionPlanDigestOf = internalLegacyPlanDigest

-- | The closed, registry-derived family an adoption of one stack must cover:
-- the stack itself plus exactly the registered resources whose controller owner
-- is that stack's cluster.
--
-- The same derivation the write-ahead manifest seeds itself from, so an adopted
-- manifest and a written-ahead one describe the same universe.
legacyAdoptionExpectedFamily :: RegisteredResourceKey -> [RegisteredResourceKey]
legacyAdoptionExpectedFamily stackKey =
  stackKey
    : [ ownershipEdgeResourceKey edge
      | edge <- registeredOwnershipEdges
      , ownershipEdgeStackKey edge == stackKey
      ]

data LegacyAdoptionRefusal
  = -- | The named stack is not a registered @Stack@ descriptor.
    LegacyAdoptionStackUnregistered !RegisteredResourceKey
  | LegacyAdoptionStackKindMismatch !RegisteredResourceKey !ResourceKind
  | -- | The plan's surface witness and the run's scope disagree.
    LegacyAdoptionSurfaceMismatch !CleanupSurface !CleanupSurface
  | LegacyAdoptionSurfaceNotAllowed !CleanupSelectionError
  | LegacyAdoptionRegistryRevisionMismatch !RegistryRevision !RegistryRevision
  | LegacyAdoptionOperationInvalid !LifecycleOperation
  | LegacyAdoptionAwsScopeMissing
  | -- | Registered family members nothing was observed for. Adopting on a
    -- shorter set would record an ownership manifest that omits resources the
    -- stack really owns.
    LegacyAdoptionCandidatesMissing ![RegisteredResourceKey]
  | -- | Observations for keys outside the closed family. Discovery may not
    -- widen the family it is discovering.
    LegacyAdoptionCandidatesExtra ![RegisteredResourceKey]
  | -- | Two observations for one registered key. Which one describes the stack
    -- is exactly what nobody knows.
    LegacyAdoptionCandidatesDuplicated ![RegisteredResourceKey]
  | -- | An observation this run could not complete. A partial or unobservable
    -- family is not a smaller family.
    LegacyAdoptionCandidatesUnobservable ![RegisteredResourceKey]
  | -- | One observed identity claimed by two registered keys. Adopting it would
    -- put one resource under two owners with two destroy orders.
    LegacyAdoptionIdentitiesAmbiguous ![ObservedResourceIdentity]
  | -- | The observation set does not bind to this run.
    LegacyAdoptionObservationBindingInvalid !CompleteObservationSetError
  deriving (Eq, Show)

-- | Render the plan from a complete observation of the closed family.
--
-- Total in the refusing direction: every way the observation set can fail to
-- describe exactly the registry's family for this stack is a distinct refusal,
-- and none of them produces a plan.
planLegacyAdoption
  :: CleanupSurfaceWitness surface
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> [ExactResourceObservation]
  -> Either LegacyAdoptionRefusal (LegacyAdoptionPlan surface)
planLegacyAdoption surface stackKey scope observations = do
  identity <- case lookupRegisteredIdentity stackKey of
    Nothing -> Left (LegacyAdoptionStackUnregistered stackKey)
    Just value -> Right value
  if registeredIdentityKind identity == Stack
    then Right ()
    else
      Left
        (LegacyAdoptionStackKindMismatch stackKey (registeredIdentityKind identity))
  let expectedSurface = cleanupSurfaceFromWitness surface
      actualSurface = evidenceCleanupSurface scope
  if actualSurface == expectedSurface
    then Right ()
    else Left (LegacyAdoptionSurfaceMismatch expectedSurface actualSurface)
  case projectCleanupTarget surface identity of
    Left err -> Left (LegacyAdoptionSurfaceNotAllowed err)
    Right _ -> Right ()
  if evidenceRegistryRevision scope == lifecycleRegistryRevision
    then Right ()
    else
      Left
        ( LegacyAdoptionRegistryRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision scope)
        )
  if evidenceLifecycleOperation scope == ReconcileDesiredAbsent
    then Right ()
    else Left (LegacyAdoptionOperationInvalid (evidenceLifecycleOperation scope))
  case evidenceAwsScope scope of
    Nothing -> Left LegacyAdoptionAwsScopeMissing
    Just _ -> Right ()

  let expected = legacyAdoptionExpectedFamily stackKey
      observedKeys = map exactObservationResourceKey observations
  case [key | key <- expected, key `notElem` observedKeys] of
    [] -> Right ()
    missing -> Left (LegacyAdoptionCandidatesMissing missing)
  case nub [key | key <- observedKeys, key `notElem` expected] of
    [] -> Right ()
    extra -> Left (LegacyAdoptionCandidatesExtra extra)
  case nub [key | key <- expected, occurrences key observedKeys > 1] of
    [] -> Right ()
    duplicated -> Left (LegacyAdoptionCandidatesDuplicated duplicated)

  -- The binding check is the same admission boundary every exact observation
  -- crosses, so an adoption cannot accept a row this run did not ask for.
  either
    (Left . LegacyAdoptionObservationBindingInvalid)
    (const (Right ()))
    (mkCompleteObservationSet scope expected observations)

  entries <- mapM (entryFor observations) expected
  let allIdentities = concatMap legacyAdoptionEntryIdentities entries
  case nub [value | value <- allIdentities, occurrences value allIdentities > 1] of
    [] -> Right ()
    ambiguous -> Left (LegacyAdoptionIdentitiesAmbiguous (sort ambiguous))

  let ordered = sort entries
  Right
    LegacyAdoptionPlan
      { internalLegacyPlanStackKey = stackKey
      , internalLegacyPlanSurface = expectedSurface
      , internalLegacyPlanScope = scope
      , internalLegacyPlanEntries = ordered
      , internalLegacyPlanDigest =
          LegacyAdoptionPlanDigest
            ( hashText
                (renderLegacyAdoptionDocument stackKey expectedSurface scope ordered)
            )
      }
 where
  occurrences value = length . filter (== value)

  entryFor observed key =
    case [observation | observation <- observed, exactObservationResourceKey observation == key] of
      [observation] -> case exactObservationResult observation of
        ExactResourceAbsent _ ->
          Right
            LegacyAdoptionPlanEntry
              { legacyAdoptionEntryKey = key
              , legacyAdoptionEntryCoordinateDigest =
                  exactObservationCoordinateDigest observation
              , legacyAdoptionEntryIdentities = []
              }
        ExactResourcePresent (ExactResourceInventory identities) ->
          Right
            LegacyAdoptionPlanEntry
              { legacyAdoptionEntryKey = key
              , legacyAdoptionEntryCoordinateDigest =
                  exactObservationCoordinateDigest observation
              , legacyAdoptionEntryIdentities = sort (toListNonEmpty identities)
              }
        _ -> Left (LegacyAdoptionCandidatesUnobservable [key])
      _ -> Left (LegacyAdoptionCandidatesMissing [key])

  toListNonEmpty identities = foldr (:) [] identities

-- | The canonical document the digest is taken over, and the document an
-- operator confirms. Exposed so the two cannot be different things.
renderLegacyAdoptionPlan :: LegacyAdoptionPlan surface -> Text
renderLegacyAdoptionPlan plan =
  renderLegacyAdoptionDocument
    (internalLegacyPlanStackKey plan)
    (internalLegacyPlanSurface plan)
    (internalLegacyPlanScope plan)
    (internalLegacyPlanEntries plan)

renderLegacyAdoptionDocument
  :: RegisteredResourceKey
  -> CleanupSurface
  -> ObservationEvidenceScope
  -> [LegacyAdoptionPlanEntry]
  -> Text
renderLegacyAdoptionDocument stackKey surface scope entries =
  Text.intercalate
    "\n"
    ( [ "legacy-adoption-plan/v1"
      , "stack " <> registeredResourceKeyText stackKey
      , "surface " <> renderPlanSurface surface
      , "registry " <> renderRegistryRevisionText (evidenceRegistryRevision scope)
      , "run " <> renderRunScopeText (evidenceDurableRunScope scope)
      , "foundation "
          <> renderFoundationText (evidenceLinuxRke2Foundation scope)
      , "aws " <> maybe "none" renderAwsScopeText (evidenceAwsScope scope)
      , "zone "
          <> maybe "none" hostedZoneIdText (evidenceAwsDnsZone scope)
      ]
        ++ map renderPlanEntry entries
    )

renderPlanEntry :: LegacyAdoptionPlanEntry -> Text
renderPlanEntry entry =
  Text.intercalate
    " "
    ( [ "entry"
      , registeredResourceKeyText (legacyAdoptionEntryKey entry)
      , managedResourceCoordinateDigestText
          (legacyAdoptionEntryCoordinateDigest entry)
      ]
        ++ case legacyAdoptionEntryIdentities entry of
          [] -> ["observed-empty"]
          identities -> map renderIdentity identities
    )

renderIdentity :: ObservedResourceIdentity -> Text
renderIdentity (ObservedResourceIdentity value) = value

renderPlanSurface :: CleanupSurface -> Text
renderPlanSurface surface = case surface of
  LocalOnly -> "local-only"
  Cascade -> "cascade"
  ExplicitPerRun -> "explicit-per-run"
  OperationalTeardown -> "operational"
  ExplicitLongLived -> "explicit-long-lived"
  TotalDecommission -> "total-decommission"

renderRegistryRevisionText :: RegistryRevision -> Text
renderRegistryRevisionText (RegistryRevision revision) = revision

renderRunScopeText :: DurableObservationRunScope -> Text
renderRunScopeText (DurableObservationRunScope runScope) = runScope

renderFoundationText :: LinuxRke2FoundationId -> Text
renderFoundationText (LinuxRke2FoundationId foundation) = foundation

renderAwsScopeText :: AwsScope -> Text
renderAwsScopeText awsScope =
  accountText (awsScopeAccountId awsScope)
    <> "/"
    <> regionText (awsScopeRegion awsScope)
 where
  accountText (AwsAccountId value) = value
  regionText (AwsRegion value) = value

hashText :: Text -> Text
hashText = TextEncoding.decodeUtf8 . hexSha256 . TextEncoding.encodeUtf8

-- | What an operator submits. A plain record: this is the request, not the
-- authorization.
data AdminLegacyAdoptionPermitRequest = AdminLegacyAdoptionPermitRequest
  { adminLegacyPermitRequestAudience :: !RunnerRole
  , adminLegacyPermitRequestStackKey :: !RegisteredResourceKey
  , adminLegacyPermitRequestPlanDigest :: !LegacyAdoptionPlanDigest
  , adminLegacyPermitRequestNonce :: !Text
  }
  deriving (Eq, Show)

-- | The admitted permit. Its constructor is private, so holding one is proof
-- that 'admitAdminLegacyAdoptionPermit' accepted the request.
data AdminLegacyAdoptionPermit = AdminLegacyAdoptionPermit
  { internalAdminLegacyPermitStackKey :: !RegisteredResourceKey
  , internalAdminLegacyPermitPlanDigest :: !LegacyAdoptionPlanDigest
  , internalAdminLegacyPermitNonce :: !Text
  }
  deriving (Eq, Show)

adminLegacyAdoptionPermitStackKey
  :: AdminLegacyAdoptionPermit -> RegisteredResourceKey
adminLegacyAdoptionPermitStackKey = internalAdminLegacyPermitStackKey

adminLegacyAdoptionPermitPlanDigest
  :: AdminLegacyAdoptionPermit -> LegacyAdoptionPlanDigest
adminLegacyAdoptionPermitPlanDigest = internalAdminLegacyPermitPlanDigest

adminLegacyAdoptionPermitNonce :: AdminLegacyAdoptionPermit -> Text
adminLegacyAdoptionPermitNonce = internalAdminLegacyPermitNonce

data AdminLegacyAdoptionPermitRefusal
  = AdminLegacyPermitWrongAudience !RunnerRole
  | AdminLegacyPermitExpired
  | -- | A permit with no nonce cannot be recognized on replay.
    AdminLegacyPermitNonceMissing
  | -- | A permit naming no plan authorizes whatever plan is presented, which is
    -- the confirmation step doing nothing.
    AdminLegacyPermitPlanDigestMissing
  deriving (Eq, Show)

-- | Admit a request into a permit. Freshness is supplied by the interpreter as
-- an observation, in the same shape
-- 'Prodbox.Lifecycle.Teardown.LongLivedAggregatePermit' uses, so this stays
-- pure.
admitAdminLegacyAdoptionPermit
  :: PermitFreshness
  -> AdminLegacyAdoptionPermitRequest
  -> Either AdminLegacyAdoptionPermitRefusal AdminLegacyAdoptionPermit
admitAdminLegacyAdoptionPermit freshness request
  | adminLegacyPermitRequestAudience request /= AdminActionRunner =
      Left
        (AdminLegacyPermitWrongAudience (adminLegacyPermitRequestAudience request))
  | freshness /= PermitFresh = Left AdminLegacyPermitExpired
  | Text.null (adminLegacyPermitRequestNonce request) =
      Left AdminLegacyPermitNonceMissing
  | Text.null requestedDigestText = Left AdminLegacyPermitPlanDigestMissing
  | otherwise =
      Right
        AdminLegacyAdoptionPermit
          { internalAdminLegacyPermitStackKey =
              adminLegacyPermitRequestStackKey request
          , internalAdminLegacyPermitPlanDigest =
              adminLegacyPermitRequestPlanDigest request
          , internalAdminLegacyPermitNonce = adminLegacyPermitRequestNonce request
          }
 where
  LegacyAdoptionPlanDigest requestedDigestText =
    adminLegacyPermitRequestPlanDigest request

-- | A plan an operator has confirmed by its exact digest. Opaque, and the only
-- value from which an adopted ownership manifest may take its plan digest.
data ConfirmedLegacyAdoptionPlan (surface :: CleanupSurface)
  = ConfirmedLegacyAdoptionPlan
      !(LegacyAdoptionPlan surface)
      !AdminLegacyAdoptionPermit
  deriving (Eq, Show)

confirmedLegacyAdoptionPlan
  :: ConfirmedLegacyAdoptionPlan surface -> LegacyAdoptionPlan surface
confirmedLegacyAdoptionPlan (ConfirmedLegacyAdoptionPlan plan _) = plan

confirmedLegacyAdoptionPlanDigest
  :: ConfirmedLegacyAdoptionPlan surface -> LegacyAdoptionPlanDigest
confirmedLegacyAdoptionPlanDigest = legacyAdoptionPlanDigestOf . confirmedLegacyAdoptionPlan

data LegacyAdoptionConfirmationRefusal
  = -- | The permit authorizes a different plan. This is the case the digest
    -- exists for: a plan re-rendered after the provider facts changed is a
    -- different plan, and the operator confirmed the earlier one.
    LegacyAdoptionConfirmationDigestMismatch
      !LegacyAdoptionPlanDigest
      !LegacyAdoptionPlanDigest
  | -- | The permit authorizes a different stack's adoption.
    LegacyAdoptionConfirmationStackMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  deriving (Eq, Show)

confirmLegacyAdoptionPlan
  :: AdminLegacyAdoptionPermit
  -> LegacyAdoptionPlan surface
  -> Either LegacyAdoptionConfirmationRefusal (ConfirmedLegacyAdoptionPlan surface)
confirmLegacyAdoptionPlan permit plan
  | internalAdminLegacyPermitStackKey permit /= internalLegacyPlanStackKey plan =
      Left
        ( LegacyAdoptionConfirmationStackMismatch
            (internalLegacyPlanStackKey plan)
            (internalAdminLegacyPermitStackKey permit)
        )
  | internalAdminLegacyPermitPlanDigest permit /= internalLegacyPlanDigest plan =
      Left
        ( LegacyAdoptionConfirmationDigestMismatch
            (internalLegacyPlanDigest plan)
            (internalAdminLegacyPermitPlanDigest permit)
        )
  | otherwise = Right (ConfirmedLegacyAdoptionPlan plan permit)
