{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Sprint 4.89: the derived dependant set, the destructive boundary's
-- argument type, and the pure projection computed before dispatch.
--
-- Cabal-hidden, so the eliminators and the boundary constructor cannot be
-- reached from outside the library.  The vocabulary they operate on is
-- exposed by
-- "Prodbox.Lifecycle.Teardown.CapabilityCustody.Universe".
--
-- Three properties carry the design.
--
--   * __The dependant set is derived, never authored.__  It comes from the
--     three compiled sources the ownership manifest and the cascade credential
--     disposition already read — the registered ownership edges, the managed
--     resource registry, and the managed AWS credential inventory — so a new
--     registered resource is covered without editing this module.
--
--   * __An undeclared family is underivable, not empty.__  A capability whose
--     dependant set defaulted to nothing would discharge trivially, which is
--     the exact failure that stranded the EKS node role: the registry declares
--     three stack descriptors and two volume families and no IAM family, so no
--     destroy granularity reaches an IAM role at all.  The derivation reports
--     what it could not derive, and a run holding an underivable capability can
--     produce no absence discharge for it.
--
--   * __The invariant survives arbitrary lifts.__  The destructive boundary's
--     argument type mentions no @m@, and the disposition multiset is a pure
--     projection computed before dispatch, so any natural transformation — a
--     test double, a chaos lift, a retry wrapper — observes identical arguments
--     and has no arm through which to synthesise a disposition it was not
--     handed.
module Prodbox.Lifecycle.Teardown.CapabilityCustody.Internal
  ( -- * The derived dependant set
    CapabilityDependants (..)
  , capabilityDependants
  , registeredCapabilityDependants
  , registeredCheckpointCapabilities
  , registeredCredentialCapabilities
  , registeredCustodialCapabilities
  , checkpointCapabilityForStackName

    -- * Checkpoint absence is not a discharge
  , CapabilityLoss (..)
  , CheckpointCustody (..)
  , checkpointCustodyCapability
  , classifyCheckpointCustody
  , DependantAbsenceAnswer (..)
  , dischargeFromDependantAnswers
  , dischargeByObservedAbsence
  , dischargeBySucceededAbsenceReadBack
  , dischargeByObservedEmptiness
  , rotateOntoRetiredReference
  , dischargeByObservedRevocation

    -- * The destructive boundary
  , CustodyRelease
  , mkCustodyRelease
  , custodyReleaseDispositions
  , CustodyReleaseBoundary (..)
  , releaseCustody

    -- * Refusals
  , CapabilityCustodyError (..)
  , renderCapabilityCustodyError

    -- * The gate
  , capabilityDependantDerivationViolations
  , capabilityDependantDerivationViolationsFrom

    -- * Non-authorizing diagnostics
  , CapabilityCustodyRegression
  , fixedCapabilityCustodyRegression
  , capabilityCustodyUniverseClosed
  , capabilityCustodyDischargeMandatory
  , capabilityCustodyDependantsDerived
  , capabilityCustodyUnderivableNotEmpty
  , capabilityCustodyGateMeasuredAgainstDefect
  , capabilityCustodyReleaseRefusalsExact
  , capabilityCustodyLiftInvariant
  , capabilityCustodyCheckpointArmsExact
  , capabilityCustodyRunReadBackDischargeExact
  , capabilityCustodyInertnessOnlyFromEmptiness
  , capabilityCustodyRetirementRotatesOntoRetained
  , capabilityCustodyRevocationIsInertnessOnly
  )
where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass
  , CredentialPermission (..)
  , awsCredentialDescriptor
  , awsCredentialDescriptorPermissions
  )
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueObservation
  , ResidueObservationLayer (ResidueLayerAwsResource)
  , isResidueAbsent
  , residueObservationLayer
  , residueObservationStatus
  )
import Prodbox.Lifecycle.Teardown.CapabilityCustody.Universe
import Prodbox.Lifecycle.Teardown.Model
  ( ManagedResourceCoordinate (AwsPulumiStackCoordinate)
  , RegisteredResourceKey (AwsEksKey, AwsTestKey)
  , ResourceKind (Stack)
  , registeredResourceKeyText
  )
import Prodbox.Lifecycle.Teardown.OwnershipManifest
  ( RegisteredOwnershipEdge
  , ownershipEdgeResourceKey
  , ownershipEdgeStackKey
  , registeredOwnershipEdges
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( SomeManagedResourceDescriptor (SomeManagedResourceDescriptor)
  , managedResourceCoordinate
  , managedResourceKey
  , managedResourceKind
  , managedResourceRegistry
  )

-- ---------------------------------------------------------------------------
-- The derived dependant set
-- ---------------------------------------------------------------------------

-- | What a capability reaches, or why that could not be determined.
data CapabilityDependants
  = -- | Every resource this capability reaches, each one registered.
    CapabilityDependantsDerived ![RegisteredResourceKey]
  | -- | The capability reaches a resource kind the registry declares no family
    -- for. The reasons are carried so an operator is told which kind, rather
    -- than being handed an empty set that would discharge trivially.
    CapabilityDependantsUnderivable ![Text]
  deriving stock (Eq, Ord, Show)

-- | The three compiled sources, read here rather than re-declared.
registeredCheckpointCapabilities :: [RegisteredResourceKey]
registeredCheckpointCapabilities =
  sort
    [ managedResourceKey descriptor
    | SomeManagedResourceDescriptor descriptor <- managedResourceRegistry
    , managedResourceKind descriptor == Stack
    ]

registeredCredentialCapabilities :: [AwsCredentialClass]
registeredCredentialCapabilities = [minBound .. maxBound]

registeredCustodialCapabilities :: [CustodialCapability]
registeredCustodialCapabilities =
  custodialCapabilityUniverse
    registeredCheckpointCapabilities
    registeredCredentialCapabilities

-- | The checkpoint capability one Pulumi stack name names, derived from the
-- registry's own coordinates rather than from a second list of stack names.
--
-- A stack the registry declares no descriptor for has no checkpoint capability
-- here, which is a refusal rather than a default: a caller about to delete a
-- checkpoint object for an unregistered stack is naming something this
-- repository does not manage.
checkpointCapabilityForStackName :: Text -> Maybe CustodialCapability
checkpointCapabilityForStackName stackName =
  case [ managedResourceKey descriptor
       | SomeManagedResourceDescriptor descriptor <- managedResourceRegistry
       , managedResourceKind descriptor == Stack
       , AwsPulumiStackCoordinate _ registeredName <-
           [managedResourceCoordinate descriptor]
       , registeredName == stackName
       ] of
    [key] -> Just (CheckpointCapability key)
    _ -> Nothing

-- | Every registered capability with its derived dependant set.
registeredCapabilityDependants
  :: [(CustodialCapability, CapabilityDependants)]
registeredCapabilityDependants =
  [ (capability, capabilityDependants capability)
  | capability <- registeredCustodialCapabilities
  ]

-- | Derive what one capability reaches.
--
-- A checkpoint reaches its own stack and every controller-owned family the
-- registered ownership edges say that stack owns; both sides are registered by
-- construction, so the set is always derivable. A credential reaches whatever
-- its declared permissions reach, and a permission naming a resource kind the
-- registry declares no family for makes the set underivable.
capabilityDependants :: CustodialCapability -> CapabilityDependants
capabilityDependants = \case
  CheckpointCapability stackKey
    | stackKey `elem` registeredCheckpointCapabilities ->
        CapabilityDependantsDerived
          ( sort
              ( nub
                  ( stackKey
                      : [ ownershipEdgeResourceKey edge
                        | edge <- ownershipEdgesFor stackKey
                        ]
                  )
              )
          )
    | otherwise ->
        CapabilityDependantsUnderivable
          [ "the registry declares no stack family for "
              <> registeredResourceKeyText stackKey
          ]
  CredentialCapability credentialClass ->
    case unregisteredPermissionReaches credentialClass of
      [] -> CapabilityDependantsDerived (registeredPermissionReaches credentialClass)
      reasons -> CapabilityDependantsUnderivable reasons
  -- A retired reference reaches exactly what the live one reached: retiring it
  -- moved the capability into the Authority's retained set, it did not narrow
  -- what the capability names.
  RetiredCheckpointCapability stackKey ->
    capabilityDependants (CheckpointCapability stackKey)

ownershipEdgesFor :: RegisteredResourceKey -> [RegisteredOwnershipEdge]
ownershipEdgesFor stackKey =
  [ edge
  | edge <- registeredOwnershipEdges
  , ownershipEdgeStackKey edge == stackKey
  ]

-- | The registered families a credential's permissions reach.
registeredPermissionReaches :: AwsCredentialClass -> [RegisteredResourceKey]
registeredPermissionReaches credentialClass =
  sort
    ( nub
        [ key
        | permission <- permissionsFor credentialClass
        , Right key <- [permissionReach permission]
        ]
    )

-- | The reasons a credential's permissions cannot be resolved to a registered
-- family.
unregisteredPermissionReaches :: AwsCredentialClass -> [Text]
unregisteredPermissionReaches credentialClass =
  nub
    [ reason
    | permission <- permissionsFor credentialClass
    , Left reason <- [permissionReach permission]
    ]

permissionsFor :: AwsCredentialClass -> [CredentialPermission]
permissionsFor = awsCredentialDescriptorPermissions . awsCredentialDescriptor

-- | Total over the closed permission universe.
--
-- Every arm is presently a 'Left': the managed resource registry declares three
-- stack descriptors and two EBS volume families and the local RKE2 foundation,
-- and every credential permission reaches an IAM role, an S3 prefix, a Route 53
-- record set, or an SES identity — none of which the registry declares a family
-- for. That is a measurement of the registry as it stands rather than a
-- statement about permissions in general: when a family is registered, its arm
-- becomes a 'Right' and the credential's set becomes derivable with no change
-- here beyond naming the key.
permissionReach :: CredentialPermission -> Either Text RegisteredResourceKey
permissionReach = \case
  AssumeRegisteredProviderRole ->
    Left "the registry declares no IAM role family for the registered provider role"
  ReadWriteAuthorityBackupPrefix ->
    Left "the registry declares no S3 prefix family for the Authority backup prefix"
  ReadWriteTlsRetentionPrefixes ->
    Left "the registry declares no S3 prefix family for the TLS retention prefixes"
  ChangeRegisteredGatewayRecord ->
    Left "the registry declares no DNS record family for the registered gateway record"
  ChangeHomeDns01TxtRecords ->
    Left "the registry declares no DNS record family for the home DNS01 TXT records"
  ChangeAwsRunDns01TxtRecords ->
    Left "the registry declares no DNS record family for the AWS-run DNS01 TXT records"
  SendEmailFromRegisteredSesIdentity ->
    Left "the registry declares no SES identity family for the registered sending identity"

-- ---------------------------------------------------------------------------
-- Checkpoint absence is not a discharge
-- ---------------------------------------------------------------------------

-- | A capability this run can no longer use, and what it was.
data CapabilityLoss = CapabilityLoss !CustodialCapability !Text
  deriving stock (Eq, Ord, Show)

-- | What a checkpoint observation says about custody.
data CheckpointCustody
  = CheckpointCustodyHeld !CustodialCapability
  | CheckpointCustodyLost !CapabilityLoss
  | CheckpointCustodyUnobservable !CustodialCapability !Text
  deriving stock (Eq, Ord, Show)

-- | Which capability an answer is about, total over the three arms.
checkpointCustodyCapability :: CheckpointCustody -> CustodialCapability
checkpointCustodyCapability = \case
  CheckpointCustodyHeld capability -> capability
  CheckpointCustodyLost (CapabilityLoss capability _) -> capability
  CheckpointCustodyUnobservable capability _ -> capability

-- | Total over the four checkpoint arms.
--
-- __An absent or empty checkpoint is a lost capability, not a discharge.__ The
-- residue classifier answers @ResidueAbsent@ for both, and it is right to: the
-- residue question is "is there a stack to destroy", and a checkpoint holding
-- no state names no stack. The custody question is a different one — "does this
-- run still hold what makes that stack's resources destroyable" — and the same
-- observation answers it @lost@, because the resources may exist and nothing
-- now names them. Reading the first answer as the second is what stranded two
-- AWS resources.
--
-- A corrupt checkpoint stays unobservable rather than lost: a blob that cannot
-- be parsed may still be the capability, so declaring it gone would be an
-- invention in the opposite direction.
classifyCheckpointCustody
  :: CustodialCapability -> CheckpointCustodyObservation -> CheckpointCustody
classifyCheckpointCustody capability = \case
  CheckpointCapabilityPresent -> CheckpointCustodyHeld capability
  CheckpointCapabilityAbsent ->
    CheckpointCustodyLost
      (CapabilityLoss capability "the encrypted checkpoint object is absent")
  CheckpointCapabilityEmpty ->
    CheckpointCustodyLost
      (CapabilityLoss capability "the encrypted checkpoint object is empty")
  CheckpointCapabilityCorrupt detail ->
    CheckpointCustodyUnobservable capability detail

-- | What one dependant's observation says, reduced to the only three answers
-- an absence discharge distinguishes.
--
-- The reduction exists so the rule below is written once.  Two currencies
-- reach it — a residue observation and a run's completed absence read-back —
-- and a second implementation of the same three refusals is how the two would
-- come to disagree.
data DependantAbsenceAnswer
  = -- | The provider itself reported the resource absent.
    DependantAbsentAtProvider
  | -- | The provider reported the resource, or reported it only partially.
    DependantStillReported
  | -- | Something other than the provider answered.  A retained checkpoint's
    -- absence is this answer, and it is the one this sprint exists to stop
    -- accepting.
    DependantAnsweredAtAnotherLayer
  deriving stock (Eq, Ord, Show)

-- | The one absence-discharge rule, over answers rather than over a currency.
--
-- Four refusals, each naming a distinct way a discharge could otherwise be
-- invented:
--
--   * an __underivable__ dependant set cannot be discharged at all, because
--     nothing enumerates what the capability reaches;
--   * a dependant with __no answer__ cannot, because a missing answer is not an
--     absent resource;
--   * an answer taken at any layer other than the __provider__ cannot — which
--     is precisely the checkpoint-layer absence this sprint exists to stop
--     accepting; and
--   * a dependant the provider __still reports__ cannot.
dischargeFromDependantAnswers
  :: CustodialCapability
  -> CapabilityDependants
  -> [(RegisteredResourceKey, DependantAbsenceAnswer)]
  -> Either CapabilityCustodyError (CapabilityDisposition 'CustodyRetire)
dischargeFromDependantAnswers capability dependants answers =
  case dependants of
    CapabilityDependantsUnderivable reasons ->
      Left (CustodyDependantsUnderivable capability reasons)
    CapabilityDependantsDerived keys -> do
      let unobserved = [key | key <- keys, key `notElem` map fst answers]
          answered =
            [ (key, answer)
            | key <- keys
            , (answeredKey, answer) <- answers
            , answeredKey == key
            ]
          nonProvider =
            [key | (key, DependantAnsweredAtAnotherLayer) <- answered]
          notAbsent = [key | (key, DependantStillReported) <- answered]
      case (unobserved, nonProvider, notAbsent) of
        ([], [], []) ->
          Right
            (CapabilityDischargedByAbsence capability (DependantAbsenceProof keys))
        (_ : _, _, _) ->
          Left (CustodyDependantUnobserved capability unobserved)
        (_, _ : _, _) ->
          Left (CustodyAbsenceNotProviderObserved capability nonProvider)
        (_, _, _ : _) ->
          Left (CustodyDependantNotAbsent capability notAbsent)

-- | The residue-observation projection of the rule.
--
-- A residue observation records the authority that produced it, so the
-- projection is the layer field and nothing else.
dischargeByObservedAbsence
  :: CustodialCapability
  -> CapabilityDependants
  -> [(RegisteredResourceKey, ResidueObservation)]
  -> Either CapabilityCustodyError (CapabilityDisposition 'CustodyRetire)
dischargeByObservedAbsence capability dependants observations =
  dischargeFromDependantAnswers
    capability
    dependants
    [(key, answerFor observation) | (key, observation) <- observations]
 where
  answerFor observation
    | residueObservationLayer observation /= ResidueLayerAwsResource =
        DependantAnsweredAtAnotherLayer
    | isResidueAbsent (residueObservationStatus observation) =
        DependantAbsentAtProvider
    | otherwise = DependantStillReported

-- | Sprint 4.89: the running-cleanup projection of the same rule.
--
-- A @ReadBackRegisteredTargetAbsent@ node succeeds only when the exact
-- observation it carries is bound to that target's key, coordinate, and scope,
-- was answered at the registered identity's own observation authority, and
-- reported the resource absent.  So "this run's read-back for that key
-- succeeded" /is/ a provider-observed absence, and it is the answer the
-- retirement path already had and discarded: it re-observed only its own stack
-- and ended custody of a capability reaching families nobody had asked about.
--
-- Keys the run did not read back are simply absent from the list, which the
-- rule refuses as unobserved rather than reading as absent.
dischargeBySucceededAbsenceReadBack
  :: CustodialCapability
  -> CapabilityDependants
  -> [RegisteredResourceKey]
  -> Either CapabilityCustodyError (CapabilityDisposition 'CustodyRetire)
dischargeBySucceededAbsenceReadBack capability dependants succeeded =
  dischargeFromDependantAnswers
    capability
    dependants
    [(key, DependantAbsentAtProvider) | key <- nub succeeded]

-- | Sprint 4.89: the only constructor of an inertness discharge for a
-- checkpoint capability.
--
-- A zero-length checkpoint object names no stack state, so the capability it
-- would have been authorises nothing and deleting the object strands nothing.
-- That is the /only/ checkpoint observation from which inertness follows.
--
-- A corrupt checkpoint is refused, and that refusal is the point.  A blob that
-- cannot be parsed may still be the capability, so deleting it may destroy the
-- only thing that names live resources — which is the asymmetry the residue
-- classifier already applies when it answers a corrupt checkpoint
-- @ResidueUnreachable@ rather than @ResidueAbsent@.  Ending custody of a
-- corrupt checkpoint needs an absence discharge over its derived dependant set,
-- not an assertion that it was probably empty.
dischargeByObservedEmptiness
  :: CustodialCapability
  -> CheckpointCustodyObservation
  -> Either CapabilityCustodyError (CapabilityDisposition 'CustodyRetire)
dischargeByObservedEmptiness capability = \case
  CheckpointCapabilityEmpty ->
    Right
      ( CapabilityAlreadyInert
          capability
          (InertnessProof "the encrypted checkpoint object is zero-length and names no stack state")
      )
  CheckpointCapabilityAbsent ->
    Left
      ( CustodyCheckpointNotInert
          capability
          "the encrypted checkpoint object is absent, so there is nothing to retire"
      )
  CheckpointCapabilityPresent ->
    Left
      ( CustodyCheckpointNotInert
          capability
          "the encrypted checkpoint decodes to non-empty stack state, so it names resources"
      )
  CheckpointCapabilityCorrupt detail ->
    Left
      ( CustodyCheckpointNotInert
          capability
          ( "the encrypted checkpoint is present but unparseable ("
              <> detail
              <> "), so it may still be the only thing naming live resources"
          )
      )

-- | Sprint 4.89: the only constructor of a retirement rotation for a
-- checkpoint capability.
--
-- Retiring a reference at the Lifecycle Authority records it in the retained
-- set and clears the live slot, and the retained reference still names the
-- backup copy's version.  The capability therefore moves rather than ceases,
-- which is a rotation onto a named successor and not a destruction — and that
-- distinction is the whole reason a corrupt, unparseable checkpoint may be
-- retired at all: a blob that cannot be parsed may still be the only thing
-- naming live resources, so it is kept where it can be found rather than
-- deleted.
--
-- If the Authority ever stopped retaining the predecessor, this disposition
-- would become false; @updateRetired@ in
-- "Prodbox.Lifecycle.Authority.PulumiCheckpointRegistry" is the invariant it
-- reads, and the retained inventory is validated there.
rotateOntoRetiredReference
  :: CustodialCapability
  -> Either CapabilityCustodyError (CapabilityDisposition 'CustodyRetire)
rotateOntoRetiredReference capability = case capability of
  CheckpointCapability stackKey ->
    Right
      ( CapabilityRotatedOnto
          capability
          (SuccessorCapability (RetiredCheckpointCapability stackKey))
      )
  CredentialCapability _ ->
    Left
      ( CustodyCheckpointNotInert
          capability
          "a credential family has no Authority checkpoint reference to retire onto"
      )
  RetiredCheckpointCapability _ ->
    Left
      ( CustodyCheckpointNotInert
          capability
          "the reference is already retired, so there is no live reference to rotate"
      )

-- | Sprint 4.89: the only constructor of an inertness discharge for a managed
-- credential family.
--
-- A revocation read-back is the proof that the family's keys no longer
-- authenticate, so the capability authorises nothing and a run may stop holding
-- it.  It deliberately claims nothing about the IAM principal the family
-- belongs to or about the resources its permissions reached: destroying those
-- alongside the capability is a /joint/ destruction, which is a different
-- constructor and a different operation.
--
-- That distinction is the audited SES defect stated as a type. The retained
-- SMTP principal exists with zero access keys because a decommission deleted
-- keys, then policy, then user inside a short-circuiting sequence; the keys'
-- absence made the capability inert, and inert is not destroyed.
dischargeByObservedRevocation
  :: CustodialCapability
  -> Text
  -> Either CapabilityCustodyError (CapabilityDisposition 'CustodyRetire)
dischargeByObservedRevocation capability receipt = case capability of
  CredentialCapability _ ->
    Right
      ( CapabilityAlreadyInert
          capability
          ( InertnessProof
              ("the credential generation was revoked and read back: " <> receipt)
          )
      )
  CheckpointCapability _ ->
    Left
      ( CustodyCheckpointNotInert
          capability
          "a checkpoint is not revoked; its inertness follows from a zero-length object"
      )
  RetiredCheckpointCapability _ ->
    Left
      ( CustodyCheckpointNotInert
          capability
          "a retired reference is not revoked; it was already disposed when it was retired"
      )

-- ---------------------------------------------------------------------------
-- The destructive boundary
-- ---------------------------------------------------------------------------

-- | The multiset a destructive boundary is handed.
--
-- Opaque, and its type mentions no @m@: it is computed purely, before dispatch,
-- so a lift observes the same value the identity boundary does.
newtype CustodyRelease = CustodyRelease [CapabilityDisposition 'CustodyRetire]
  deriving stock (Eq, Show)

custodyReleaseDispositions
  :: CustodyRelease -> [CapabilityDisposition 'CustodyRetire]
custodyReleaseDispositions (CustodyRelease dispositions) = dispositions

-- | Build the multiset for an exact capability set.
--
-- Refuses when a capability in the set has no disposition, when a disposition
-- names a capability the set does not contain, and when the same capability is
-- disposed twice — a second disposition for one capability is two answers to
-- one question, not a stronger one.
mkCustodyRelease
  :: [CustodialCapability]
  -> [CapabilityDisposition 'CustodyRetire]
  -> Either CapabilityCustodyError CustodyRelease
mkCustodyRelease expected dispositions = do
  let disposed = map dispositionCapability dispositions
      missing = [capability | capability <- nub expected, capability `notElem` disposed]
      foreign' = [capability | capability <- disposed, capability `notElem` expected]
      duplicated =
        [ capability
        | capability <- nub disposed
        , length (filter (== capability) disposed) > 1
        ]
  case (missing, foreign', duplicated) of
    ([], [], []) -> Right (CustodyRelease dispositions)
    (_ : _, _, _) -> Left (CustodyCapabilityUndisposed missing)
    (_, _ : _, _) -> Left (CustodyDispositionUnexpected foreign')
    (_, _, _ : _) -> Left (CustodyDispositionDuplicated duplicated)

-- | The destructive boundary.
--
-- Its argument type is exactly 'CustodyRelease', which mentions no @m@, so no
-- natural transformation over @m@ has an arm through which to introduce a
-- disposition it was not handed.
newtype CustodyReleaseBoundary m = CustodyReleaseBoundary
  { runCustodyReleaseBoundary :: CustodyRelease -> m ()
  }

releaseCustody
  :: (Monad m)
  => CustodyReleaseBoundary m
  -> [CustodialCapability]
  -> [CapabilityDisposition 'CustodyRetire]
  -> m (Either CapabilityCustodyError ())
releaseCustody boundary expected dispositions =
  case mkCustodyRelease expected dispositions of
    Left err -> pure (Left err)
    Right release -> Right <$> runCustodyReleaseBoundary boundary release

-- ---------------------------------------------------------------------------
-- Refusals
-- ---------------------------------------------------------------------------

data CapabilityCustodyError
  = CustodyCapabilityUndisposed ![CustodialCapability]
  | CustodyDispositionUnexpected ![CustodialCapability]
  | CustodyDispositionDuplicated ![CustodialCapability]
  | CustodyDependantsUnderivable !CustodialCapability ![Text]
  | CustodyDependantUnobserved
      !CustodialCapability
      ![RegisteredResourceKey]
  | CustodyAbsenceNotProviderObserved
      !CustodialCapability
      ![RegisteredResourceKey]
  | CustodyDependantNotAbsent
      !CustodialCapability
      ![RegisteredResourceKey]
  | CustodyCheckpointNotInert !CustodialCapability !Text
  deriving stock (Eq, Show)

renderCapabilityCustodyError :: CapabilityCustodyError -> Text
renderCapabilityCustodyError = \case
  CustodyCapabilityUndisposed capabilities ->
    "custody cannot end for a capability with no disposition: "
      <> renderList capabilities
  CustodyDispositionUnexpected capabilities ->
    "a disposition names a capability this release does not hold: "
      <> renderList capabilities
  CustodyDispositionDuplicated capabilities ->
    "one capability was disposed twice, which is two answers to one question: "
      <> renderList capabilities
  CustodyDependantsUnderivable capability reasons ->
    renderCustodialCapability capability
      <> " cannot be discharged by absence because nothing enumerates what it "
      <> "reaches: "
      <> Text.intercalate "; " reasons
  CustodyDependantUnobserved capability keys ->
    renderCustodialCapability capability
      <> " cannot be discharged by absence: a missing answer is not an absent "
      <> "resource for "
      <> renderKeys keys
  CustodyAbsenceNotProviderObserved capability keys ->
    renderCustodialCapability capability
      <> " cannot be discharged by an absence nobody observed at the provider, "
      <> "which is what a retained checkpoint's absence is, for "
      <> renderKeys keys
  CustodyDependantNotAbsent capability keys ->
    renderCustodialCapability capability
      <> " cannot be discharged: the provider did not observe absence for "
      <> renderKeys keys
  CustodyCheckpointNotInert capability detail ->
    renderCustodialCapability capability
      <> " cannot be discharged as already inert: "
      <> detail
 where
  renderList = Text.intercalate ", " . map renderCustodialCapability
  renderKeys = Text.intercalate ", " . map registeredResourceKeyText

-- ---------------------------------------------------------------------------
-- The gate
-- ---------------------------------------------------------------------------

-- | Sprint 4.89: every registered capability has a dependant set that is either
-- derived or explicitly underivable, and all three derivation sources
-- contribute.
--
-- The first half is structural — the answer type has exactly two arms — so what
-- this gate is for is the second: a source that stopped contributing would make
-- every capability quietly derivable-and-empty, which is the failure that
-- stranded a resource. It is therefore written against the sources rather than
-- against the answer, and is measured by removing one.
capabilityDependantDerivationViolations :: [String]
capabilityDependantDerivationViolations =
  capabilityDependantDerivationViolationsFrom
    registeredCheckpointCapabilities
    registeredOwnershipEdges
    registeredCredentialCapabilities

-- | The same rule over supplied sources, so the regression can remove one and
-- measure the refusal rather than measuring the rule's shape.
capabilityDependantDerivationViolationsFrom
  :: [RegisteredResourceKey]
  -> [RegisteredOwnershipEdge]
  -> [AwsCredentialClass]
  -> [String]
capabilityDependantDerivationViolationsFrom checkpoints edges credentials =
  registryViolation ++ edgeViolation ++ credentialViolation
 where
  registryViolation
    | null checkpoints =
        [ "the managed resource registry contributes no stack descriptor, so "
            ++ "every checkpoint capability would have no dependant set to derive"
        ]
    | otherwise = []

  -- At least one checkpoint must reach more than itself. An edge list that
  -- stopped contributing leaves every checkpoint reaching only its own stack,
  -- which reads as a complete answer and is not one.
  edgeViolation
    | any (`elem` map ownershipEdgeStackKey edges) checkpoints = []
    | otherwise =
        [ "the registered ownership edges contribute no controller-owned family "
            ++ "to any registered stack, so a checkpoint's dependant set would "
            ++ "cover only its own stack"
        ]

  credentialViolation
    | null credentials =
        [ "the managed AWS credential inventory contributes no credential class, "
            ++ "so no credential capability would be enumerated at all"
        ]
    | otherwise = []

-- ---------------------------------------------------------------------------
-- Non-authorizing diagnostics
-- ---------------------------------------------------------------------------

-- | Fixed, non-authorizing diagnostics over the compiled registries.
--
-- No capability, disposition, release, or boundary escapes the public facade,
-- so holding one of these booleans authorizes nothing.
data CapabilityCustodyRegression = CapabilityCustodyRegression
  { capabilityCustodyUniverseClosed :: !Bool
  , capabilityCustodyDischargeMandatory :: !Bool
  , capabilityCustodyDependantsDerived :: !Bool
  , capabilityCustodyUnderivableNotEmpty :: !Bool
  , capabilityCustodyGateMeasuredAgainstDefect :: !Bool
  , capabilityCustodyReleaseRefusalsExact :: !Bool
  , capabilityCustodyLiftInvariant :: !Bool
  , capabilityCustodyCheckpointArmsExact :: !Bool
  , capabilityCustodyRunReadBackDischargeExact :: !Bool
  , capabilityCustodyInertnessOnlyFromEmptiness :: !Bool
  , capabilityCustodyRetirementRotatesOntoRetained :: !Bool
  , capabilityCustodyRevocationIsInertnessOnly :: !Bool
  }

fixedCapabilityCustodyRegression :: IO CapabilityCustodyRegression
fixedCapabilityCustodyRegression = do
  liftInvariant <- exerciseLiftInvariance
  pure
    CapabilityCustodyRegression
      { capabilityCustodyUniverseClosed = universeClosed
      , capabilityCustodyDischargeMandatory = dischargeMandatory
      , capabilityCustodyDependantsDerived = dependantsDerived
      , capabilityCustodyUnderivableNotEmpty = underivableNotEmpty
      , capabilityCustodyGateMeasuredAgainstDefect = gateMeasured
      , capabilityCustodyReleaseRefusalsExact = releaseRefusals
      , capabilityCustodyLiftInvariant = liftInvariant
      , capabilityCustodyCheckpointArmsExact = checkpointArms
      , capabilityCustodyRunReadBackDischargeExact = runReadBackDischarge
      , capabilityCustodyInertnessOnlyFromEmptiness = inertnessOnlyFromEmptiness
      , capabilityCustodyRetirementRotatesOntoRetained = retirementRotates
      , capabilityCustodyRevocationIsInertnessOnly = revocationIsInertnessOnly
      }
 where
  fixedCapability = CheckpointCapability regressionStackKey

  -- Counted rather than described: a sixth constructor changes one of these
  -- numbers, and the elimination table is total with no fall-through arm.
  retireArms =
    [ CapabilityAlreadyInert fixedCapability (InertnessProof "no keys remain")
    , CapabilityDischargedByAbsence
        fixedCapability
        (DependantAbsenceProof [regressionStackKey])
    , CapabilityRotatedOnto
        fixedCapability
        (SuccessorCapability (CheckpointCapability regressionOtherStackKey))
    , CapabilityDestroyedJointly
        fixedCapability
        (JointDestructionProof "principal and keys deleted together")
    ]

  universeClosed =
    retireDispositionCount == 4
      && holdDispositionCount == 1
      && length retireArms == retireDispositionCount

  -- Every retire arm names the capability it disposes, which is what lets the
  -- multiset be checked against the set a run holds; and none is constructible
  -- from a capability alone, which is a property of the constructors above.
  dischargeMandatory =
    map dispositionCapability retireArms
      == replicate retireDispositionCount fixedCapability
      && dispositionCapability (CapabilityHeld fixedCapability) == fixedCapability

  -- A checkpoint reaches more than its own stack, so a derivation that returned
  -- only the stack would read as a complete answer without being one.
  dependantsDerived =
    case capabilityDependants fixedCapability of
      CapabilityDependantsDerived keys ->
        regressionStackKey `elem` keys
          && length keys > 1
          && keys == sort (nub keys)
      CapabilityDependantsUnderivable _ -> False

  -- No capability derives an empty set: an empty derived set discharges
  -- trivially, which is the failure that stranded a resource. Every managed
  -- credential reaches a kind the registry declares no family for and is
  -- therefore reported underivable, carrying the reason.
  underivableNotEmpty =
    null
      [ capability
      | (capability, CapabilityDependantsDerived []) <-
          registeredCapabilityDependants
      ]
      && not
        ( null
            [ capability
            | (capability, CapabilityDependantsUnderivable reasons) <-
                registeredCapabilityDependants
            , not (null reasons)
            ]
        )

  -- Sprint 4.87's idiom: remove one source and the rule fails, restore it and
  -- the rule passes. Measuring the rule's shape would pass over a source that
  -- silently stopped contributing.
  gateMeasured =
    null capabilityDependantDerivationViolations
      && mentions
        "managed resource registry"
        ( capabilityDependantDerivationViolationsFrom
            []
            registeredOwnershipEdges
            registeredCredentialCapabilities
        )
      && mentions
        "registered ownership edges"
        ( capabilityDependantDerivationViolationsFrom
            registeredCheckpointCapabilities
            []
            registeredCredentialCapabilities
        )
      && mentions
        "credential inventory"
        ( capabilityDependantDerivationViolationsFrom
            registeredCheckpointCapabilities
            registeredOwnershipEdges
            []
        )
      && null
        ( capabilityDependantDerivationViolationsFrom
            registeredCheckpointCapabilities
            registeredOwnershipEdges
            registeredCredentialCapabilities
        )

  releaseRefusals =
    mkCustodyRelease [fixedCapability] []
      == Left (CustodyCapabilityUndisposed [fixedCapability])
      && isUnexpected
        -- Deliberately paired with the held capability's own disposition, so
        -- the foreign one is the only thing wrong: a release that is both
        -- incomplete and foreign reports the incompleteness first, because a
        -- capability with no disposition is the failure custody exists to
        -- refuse.
        ( mkCustodyRelease
            [fixedCapability]
            [ inertFor fixedCapability
            , inertFor (CheckpointCapability regressionOtherStackKey)
            ]
        )
      && isDuplicated
        ( mkCustodyRelease
            [fixedCapability]
            [inertFor fixedCapability, inertFor fixedCapability]
        )
      && isRight (mkCustodyRelease [fixedCapability] [inertFor fixedCapability])
      && all
        (Text.isInfixOf (renderCustodialCapability fixedCapability))
        [ renderCapabilityCustodyError (CustodyCapabilityUndisposed [fixedCapability])
        , renderCapabilityCustodyError (CustodyDispositionUnexpected [fixedCapability])
        , renderCapabilityCustodyError (CustodyDispositionDuplicated [fixedCapability])
        ]

  inertFor capability = CapabilityAlreadyInert capability (InertnessProof "inert")

  -- One fixed program under two carriers. The boundary's argument type mentions
  -- no @m@ and the multiset is computed before dispatch, so the lift observes
  -- the identical value and has no arm through which to introduce one.
  exerciseLiftInvariance = do
    identityObserved <- newIORef []
    chaosObserved <- newIORef []
    chaosCalls <- newIORef (0 :: Int)
    let dispositions = [inertFor fixedCapability]
    identityResult <-
      releaseCustody
        ( CustodyReleaseBoundary
            (\release -> modifyIORef' identityObserved (<> [release]))
        )
        [fixedCapability]
        dispositions
    chaosResult <-
      releaseCustody
        ( CustodyReleaseBoundary
            ( \release -> do
                modifyIORef' chaosCalls (+ 1)
                modifyIORef' chaosObserved (<> [release])
            )
        )
        [fixedCapability]
        dispositions
    identitySeen <- readIORef identityObserved
    chaosSeen <- readIORef chaosObserved
    calls <- readIORef chaosCalls
    pure
      ( identityResult == Right ()
          && chaosResult == Right ()
          && map custodyReleaseDispositions identitySeen
            == map custodyReleaseDispositions chaosSeen
          && calls == 1
      )

  -- Over the four checkpoint arms: absent and empty are a lost capability,
  -- corrupt stays unobservable, present is held. A checkpoint that holds no
  -- state names no stack, which is the right residue answer and the wrong
  -- custody answer.
  checkpointArms =
    classifyCheckpointCustody fixedCapability CheckpointCapabilityPresent
      == CheckpointCustodyHeld fixedCapability
      && isLost
        (classifyCheckpointCustody fixedCapability CheckpointCapabilityAbsent)
      && isLost
        (classifyCheckpointCustody fixedCapability CheckpointCapabilityEmpty)
      && classifyCheckpointCustody
        fixedCapability
        (CheckpointCapabilityCorrupt "unparseable")
        == CheckpointCustodyUnobservable fixedCapability "unparseable"

  isLost answer = case answer of
    CheckpointCustodyLost _ -> True
    _ -> False

  -- The run projection of the one absence rule: a checkpoint reaches more than
  -- its own stack, so a run that read back only the stack cannot discharge it.
  -- This is the answer the retirement path already had and discarded.
  runReadBackDischarge =
    case capabilityDependants fixedCapability of
      CapabilityDependantsUnderivable _ -> False
      CapabilityDependantsDerived keys ->
        isRight
          ( dischargeBySucceededAbsenceReadBack
              fixedCapability
              (capabilityDependants fixedCapability)
              keys
          )
          && length keys > 1
          && isUnobserved
            ( dischargeBySucceededAbsenceReadBack
                fixedCapability
                (capabilityDependants fixedCapability)
                [regressionStackKey]
            )
          && isUnobserved
            ( dischargeBySucceededAbsenceReadBack
                fixedCapability
                (capabilityDependants fixedCapability)
                []
            )
          && isUnderivable
            ( dischargeBySucceededAbsenceReadBack
                underivableCapability
                (capabilityDependants underivableCapability)
                keys
            )

  -- Inertness follows from a zero-length object and from nothing else. A
  -- corrupt blob may still be the capability, and a present one names
  -- resources.
  inertnessOnlyFromEmptiness =
    isRight (dischargeByObservedEmptiness fixedCapability CheckpointCapabilityEmpty)
      && isNotInert
        (dischargeByObservedEmptiness fixedCapability CheckpointCapabilityPresent)
      && isNotInert
        (dischargeByObservedEmptiness fixedCapability CheckpointCapabilityAbsent)
      && isNotInert
        ( dischargeByObservedEmptiness
            fixedCapability
            (CheckpointCapabilityCorrupt "unparseable")
        )

  -- Retiring a reference moves the capability into the Authority's retained
  -- set rather than ending it, so the disposition names that successor. A
  -- credential has no checkpoint reference to retire, and a reference already
  -- retired has no live one to rotate.
  retirementRotates =
    rotateOntoRetiredReference fixedCapability
      == Right
        ( CapabilityRotatedOnto
            fixedCapability
            (SuccessorCapability (RetiredCheckpointCapability regressionStackKey))
        )
      && capabilityDependants (RetiredCheckpointCapability regressionStackKey)
        == capabilityDependants fixedCapability
      && isNotInert (rotateOntoRetiredReference underivableCapability)
      && isNotInert
        ( rotateOntoRetiredReference
            (RetiredCheckpointCapability regressionStackKey)
        )

  underivableCapability = CredentialCapability minBound

  -- A revocation read-back proves the family's keys no longer authenticate, so
  -- the capability authorises nothing.  It claims nothing about the IAM
  -- principal or the resources the permissions reached: the retained SES SMTP
  -- principal with zero access keys is exactly a capability that became inert
  -- without being destroyed, and inert is not destroyed.
  revocationIsInertnessOnly =
    ( case dischargeByObservedRevocation underivableCapability "generation-7" of
        Right (CapabilityAlreadyInert capability (InertnessProof proof)) ->
          capability == underivableCapability
            && Text.isInfixOf "generation-7" proof
        _ -> False
    )
      && isNotInert (dischargeByObservedRevocation fixedCapability "generation-7")
      && isNotInert
        ( dischargeByObservedRevocation
            (RetiredCheckpointCapability regressionStackKey)
            "generation-7"
        )

  isUnobserved result = case result of
    Left (CustodyDependantUnobserved _ _) -> True
    _ -> False

  isUnderivable result = case result of
    Left (CustodyDependantsUnderivable _ _) -> True
    _ -> False

  isNotInert result = case result of
    Left (CustodyCheckpointNotInert _ _) -> True
    _ -> False

  mentions needle = any (Text.isInfixOf (Text.pack needle) . Text.pack)

  isUnexpected result = case result of
    Left (CustodyDispositionUnexpected _) -> True
    _ -> False

  isDuplicated result = case result of
    Left (CustodyDispositionDuplicated _) -> True
    _ -> False

  isRight result = case result of
    Right _ -> True
    Left _ -> False

-- | The fixed stack the regression disposes.  Chosen because it is the stack
-- whose controllers own a registered family, so its dependant set is larger
-- than itself.
regressionStackKey :: RegisteredResourceKey
regressionStackKey = AwsEksKey

regressionOtherStackKey :: RegisteredResourceKey
regressionOtherStackKey = AwsTestKey
