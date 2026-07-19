{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

-- | Sprint 1.61 Increment B: the pure capability-requirement graph data the
-- component graph is lowered over.
--
-- A component declares which capabilities it PROVIDES and which it REQUIRES, each
-- as a kind-indexed value existentially wrapped with its 'SCapability' singleton.
-- A flat, primitives-only 'CapabilityRequirementSpec' is the (future) wire form;
-- 'resolveRequirement' turns it into the existential, surfacing every coordinate
-- and generation validation failure BEFORE any effect runs. The coordinate is
-- Increment A's unindexed 'CapabilityCoordinate' (the kind lives on the wrapper
-- and the singleton, mirroring 'Prodbox.ControlPlane.CapabilityRef.CapabilityRef'
-- — an intentionally stronger encoding than the doctrine's illustrative
-- @CapabilityCoordinate kind@).
module Prodbox.ControlPlane.CapabilityRequirement
  ( LatencyBudget (..)
  , CapabilityRequirement (..)
  , SomeCapabilityRequirement (..)
  , CapabilityProvision (..)
  , SomeCapabilityProvision (..)
  , CapabilityRequirementSpec (..)
  , CapabilityProvisionSpec (..)
  , RequirementError (..)
  , renderRequirementError
  , resolveRequirement
  , resolveProvision
  , requirementOp
  , requirementTier
  , requirementCoordinate'
  , provisionOp
  , provisionCoordinate'
  , matchesProvision
  )
where

import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.CapabilityKind
  ( CapabilityKind
  , CapabilityOp
  , PermitTier
  )
import Prodbox.ControlPlane.Coordinate
  ( CapabilityCoordinate
  , CoordinateError
  , coordinateDigest
  , mkAuthorityScope
  , mkCapabilityEndpoint
  , mkCoordinate
  , mkLogicalName
  , mkServiceIdentity
  )
import Prodbox.ControlPlane.SCapability
  ( SCapability
  , SomeSCapability (SomeSCapability)
  , opToSCapability
  , sCapabilityOp
  , sCapabilityTier
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( TargetCommitValueError
  , mkCredentialGeneration
  )

-- | A per-requirement admission latency budget (microseconds). Feeds the
-- (deferred) interpreter's absolute-deadline admission; carried as pure data
-- here.
newtype LatencyBudget = LatencyBudget Natural
  deriving (Eq, Ord, Show)

-- | What a component requires: an exact operation at an exact coordinate, plus
-- its latency budget.
data CapabilityRequirement (kind :: CapabilityKind) = CapabilityRequirement
  { requiredCoordinate :: !CapabilityCoordinate
  , requiredLatencyBudget :: !LatencyBudget
  }
  deriving (Eq, Show)

data SomeCapabilityRequirement where
  SomeCapabilityRequirement
    :: SCapability kind -> CapabilityRequirement kind -> SomeCapabilityRequirement

-- | Two requirements are equal when they name the same operation at the same
-- coordinate (digest). The latency budget is presentation metadata, not identity.
instance Eq SomeCapabilityRequirement where
  left == right =
    requirementOp left == requirementOp right
      && coordinateDigest (requirementCoordinate' left) == coordinateDigest (requirementCoordinate' right)

instance Show SomeCapabilityRequirement where
  show requirement =
    "SomeCapabilityRequirement "
      ++ show (requirementOp requirement)
      ++ " "
      ++ show (coordinateDigest (requirementCoordinate' requirement))

-- | What a component provides: an exact operation at an exact coordinate.
newtype CapabilityProvision (kind :: CapabilityKind) = CapabilityProvision
  { provideCoordinate :: CapabilityCoordinate
  }
  deriving (Eq, Show)

data SomeCapabilityProvision where
  SomeCapabilityProvision
    :: SCapability kind -> CapabilityProvision kind -> SomeCapabilityProvision

instance Eq SomeCapabilityProvision where
  left == right =
    provisionOp left == provisionOp right
      && coordinateDigest (provisionCoordinate' left) == coordinateDigest (provisionCoordinate' right)

instance Show SomeCapabilityProvision where
  show provision =
    "SomeCapabilityProvision "
      ++ show (provisionOp provision)
      ++ " "
      ++ show (coordinateDigest (provisionCoordinate' provision))

-- | A flat, primitives-only requirement — the form a coordinate can take in
-- serialized config. All fields are validated by 'resolveRequirement'.
data CapabilityRequirementSpec = CapabilityRequirementSpec
  { specRequireCapability :: !CapabilityOp
  , specRequireService :: !Text
  , specRequireScope :: !Text
  , specRequireEndpoint :: !Text
  , specRequireLogical :: !Text
  , specRequireGeneration :: !Natural
  , specRequireLatencyMicros :: !Natural
  }
  deriving (Eq, Show)

-- | A flat, primitives-only provision.
data CapabilityProvisionSpec = CapabilityProvisionSpec
  { specProvideCapability :: !CapabilityOp
  , specProvideService :: !Text
  , specProvideScope :: !Text
  , specProvideEndpoint :: !Text
  , specProvideLogical :: !Text
  , specProvideGeneration :: !Natural
  }
  deriving (Eq, Show)

-- | A validation failure resolving a flat spec into a kind-indexed value.
data RequirementError
  = RequirementCoordinateInvalid !CoordinateError
  | RequirementGenerationInvalid !TargetCommitValueError
  deriving (Eq, Show)

renderRequirementError :: RequirementError -> String
renderRequirementError err = case err of
  RequirementCoordinateInvalid coordinateError ->
    "capability requirement coordinate is invalid: " ++ show coordinateError
  RequirementGenerationInvalid generationError ->
    "capability requirement generation is invalid: " ++ show generationError

resolveCoordinate
  :: CapabilityOp
  -> Text
  -> Text
  -> Text
  -> Text
  -> Natural
  -> Either RequirementError (SomeSCapability, CapabilityCoordinate)
resolveCoordinate op service scope endpoint logical generation = do
  serviceIdentity <- coordinateField (mkServiceIdentity service)
  authorityScope <- coordinateField (mkAuthorityScope scope)
  capabilityEndpoint <- coordinateField (mkCapabilityEndpoint endpoint)
  logicalName <- coordinateField (mkLogicalName logical)
  credentialGeneration <-
    either (Left . RequirementGenerationInvalid) Right (mkCredentialGeneration generation)
  let coordinate =
        mkCoordinate serviceIdentity authorityScope capabilityEndpoint logicalName credentialGeneration
  Right (opToSCapability op, coordinate)
 where
  coordinateField = either (Left . RequirementCoordinateInvalid) Right

-- | Resolve a flat requirement spec into a kind-indexed 'SomeCapabilityRequirement'.
resolveRequirement :: CapabilityRequirementSpec -> Either RequirementError SomeCapabilityRequirement
resolveRequirement spec = do
  (SomeSCapability singleton, coordinate) <-
    resolveCoordinate
      (specRequireCapability spec)
      (specRequireService spec)
      (specRequireScope spec)
      (specRequireEndpoint spec)
      (specRequireLogical spec)
      (specRequireGeneration spec)
  Right
    ( SomeCapabilityRequirement
        singleton
        (CapabilityRequirement coordinate (LatencyBudget (specRequireLatencyMicros spec)))
    )

-- | Resolve a flat provision spec into a kind-indexed 'SomeCapabilityProvision'.
resolveProvision :: CapabilityProvisionSpec -> Either RequirementError SomeCapabilityProvision
resolveProvision spec = do
  (SomeSCapability singleton, coordinate) <-
    resolveCoordinate
      (specProvideCapability spec)
      (specProvideService spec)
      (specProvideScope spec)
      (specProvideEndpoint spec)
      (specProvideLogical spec)
      (specProvideGeneration spec)
  Right (SomeCapabilityProvision singleton (CapabilityProvision coordinate))

-- | The operation a requirement names.
requirementOp :: SomeCapabilityRequirement -> CapabilityOp
requirementOp (SomeCapabilityRequirement singleton _) = sCapabilityOp singleton

-- | The permit tier of a requirement's operation.
requirementTier :: SomeCapabilityRequirement -> PermitTier
requirementTier (SomeCapabilityRequirement singleton _) = sCapabilityTier singleton

-- | The coordinate a requirement targets.
requirementCoordinate' :: SomeCapabilityRequirement -> CapabilityCoordinate
requirementCoordinate' (SomeCapabilityRequirement _ requirement) = requiredCoordinate requirement

-- | The operation a provision answers.
provisionOp :: SomeCapabilityProvision -> CapabilityOp
provisionOp (SomeCapabilityProvision singleton _) = sCapabilityOp singleton

-- | The coordinate a provision offers.
provisionCoordinate' :: SomeCapabilityProvision -> CapabilityCoordinate
provisionCoordinate' (SomeCapabilityProvision _ provision) = provideCoordinate provision

-- | A provision satisfies a requirement iff it answers the SAME operation at the
-- SAME coordinate (digest equality over service, scope, endpoint, logical name,
-- and generation). Kind-exactness is enforced by the operation equality; a
-- weaker-tier provision names a different operation and so cannot match.
matchesProvision :: SomeCapabilityRequirement -> SomeCapabilityProvision -> Bool
matchesProvision requirement provision =
  requirementOp requirement == provisionOp provision
    && coordinateDigest (requirementCoordinate' requirement)
      == coordinateDigest (provisionCoordinate' provision)
