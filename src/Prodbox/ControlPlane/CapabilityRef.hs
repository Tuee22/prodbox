{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Sprint 1.61: the opaque capability reference. A @'CapabilityRef' k@ owns the
-- ONE coordinate for operation @k@, and it is the only artifact in the algebra
-- that stores a full 'CapabilityCoordinate' — observations, admission tickets,
-- writer permits, and committed intents carry only its 'CoordinateDigest'. The
-- constructor is unexported and the type carries a @nominal@ role, so a
-- reference cannot be forged and @coerce :: CapabilityRef 'A -> CapabilityRef 'B@
-- cannot relabel one operation's authority as another's.
module Prodbox.ControlPlane.CapabilityRef
  ( CapabilityRef
  , mkCapabilityRef
  , refCoordinate
  , refCapabilityOp
  , refCoordinateDigest
  )
where

import Prodbox.ControlPlane.CapabilityKind
  ( CapabilityKind
  , CapabilityOp
  , KnownCapability (capabilityOp)
  )
import Prodbox.ControlPlane.Coordinate
  ( CapabilityCoordinate
  , CoordinateDigest
  , coordinateDigest
  )

-- | The @nominal@ role is load-bearing: without it @k@ would default to a phantom
-- role and 'Data.Coerce.coerce' could relabel a reference from one operation to
-- another, laundering the wrong-operation type error. Do not "simplify" it away.
type role CapabilityRef nominal

data CapabilityRef (k :: CapabilityKind) = MkCapabilityRef
  { refCoordinate :: !CapabilityCoordinate
  , refCapabilityOp :: !CapabilityOp
  }

-- | Build a reference for a statically-known operation. The runtime operation tag
-- is stamped from the kind, so @'refCapabilityOp' ('mkCapabilityRef' \@k c)@ is
-- always @'capabilityOp' \@k@ — the tag can never disagree with the index.
mkCapabilityRef :: forall k. (KnownCapability k) => CapabilityCoordinate -> CapabilityRef k
mkCapabilityRef coordinate = MkCapabilityRef coordinate (capabilityOp @k)

-- | The digest of the reference's one coordinate — the value every downstream
-- artifact must match to prove it belongs to this reference.
refCoordinateDigest :: CapabilityRef k -> CoordinateDigest
refCoordinateDigest = coordinateDigest . refCoordinate
