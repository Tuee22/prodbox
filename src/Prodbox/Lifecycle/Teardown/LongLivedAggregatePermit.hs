{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.36: the aggregate operator permit that @ExplicitLongLived@
-- completion requires.
--
-- Every other ordinary surface mints completion from its own read-backs alone.
-- This one may not, and the reason is not typing: a long-lived family is
-- infrastructure the rest of the system is built to preserve, so its removal is
-- an operator decision rather than a consequence of a run converging.  Sprint
-- @4.85@ recorded that the permit "has no type", and a completion minter with
-- no permit type would have to either take the decision on the operator's
-- behalf or take a 'Bool'.
--
-- Two properties make the permit non-forgeable from run state:
--
-- * __The aggregate is exact.__  A permit names the registered long-lived keys
--   it authorizes, and that set must equal 'longLivedAggregateUniverse' — the
--   registry's own @ExplicitLongLived@ projection — with nothing missing and
--   nothing added.  A permit for a subset would authorize a partial
--   destruction the surface then reports as complete; a permit naming an extra
--   key would authorize something the registry does not project here.
--
-- * __The permit is bound to one run.__  It carries the run identity and graph
--   digest it authorizes, and the minter re-checks both against the evidence.
--   A permit issued for one run cannot complete another.
--
-- The audience is the 'AdminActionRunner' rather than a new role: the existing
-- @DestroyAwsSes@ admin action is itself a long-lived teardown, so this is the
-- same exceptional-operator-action family rather than a second one.
module Prodbox.Lifecycle.Teardown.LongLivedAggregatePermit
  ( LongLivedAggregatePermitRequest (..)
  , LongLivedAggregatePermit
  , longLivedAggregatePermitRunId
  , longLivedAggregatePermitGraphDigest
  , longLivedAggregatePermitAggregate
  , longLivedAggregatePermitNonce
  , LongLivedAggregatePermitRefusal (..)
  , admitLongLivedAggregatePermit
  , longLivedAggregateUniverse
  )
where

import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.Authority.AdminAction
  ( PermitFreshness (PermitFresh)
  , RunnerRole (AdminActionRunner)
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDigest
  , CleanupRunId
  )
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface (ExplicitLongLived)
  , RegisteredResourceKey
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( RegisteredIdentity (RegisteredManagedResource)
  , SomeManagedResourceDescriptor (SomeManagedResourceDescriptor)
  , cleanupSurfaceAllows
  , managedResourceKey
  , managedResourceRegistry
  )

-- | The exact set of registered keys the @ExplicitLongLived@ surface projects.
--
-- Derived from the registry rather than authored, so a newly registered
-- long-lived descriptor widens the permit's requirement automatically and an
-- older permit naming the smaller set stops being admissible.
longLivedAggregateUniverse :: [RegisteredResourceKey]
longLivedAggregateUniverse =
  sort
    [ managedResourceKey descriptor
    | someDescriptor@(SomeManagedResourceDescriptor descriptor) <-
        managedResourceRegistry
    , cleanupSurfaceAllows
        ExplicitLongLived
        (RegisteredManagedResource someDescriptor)
    ]

-- | What an operator submits.  It is a plain record on purpose: this is the
-- request, not the authorization.
data LongLivedAggregatePermitRequest = LongLivedAggregatePermitRequest
  { longLivedPermitRequestAudience :: !RunnerRole
  , longLivedPermitRequestRunId :: !CleanupRunId
  , longLivedPermitRequestGraphDigest :: !CleanupDigest
  , longLivedPermitRequestAggregate :: ![RegisteredResourceKey]
  , longLivedPermitRequestNonce :: !Text
  }
  deriving (Eq, Show)

-- | The admitted permit.  Its constructor is private, so holding one is proof
-- that 'admitLongLivedAggregatePermit' accepted the request.
data LongLivedAggregatePermit = LongLivedAggregatePermit
  { internalLongLivedPermitRunId :: !CleanupRunId
  , internalLongLivedPermitGraphDigest :: !CleanupDigest
  , internalLongLivedPermitAggregate :: ![RegisteredResourceKey]
  , internalLongLivedPermitNonce :: !Text
  }
  deriving (Eq, Show)

longLivedAggregatePermitRunId :: LongLivedAggregatePermit -> CleanupRunId
longLivedAggregatePermitRunId = internalLongLivedPermitRunId

longLivedAggregatePermitGraphDigest
  :: LongLivedAggregatePermit -> CleanupDigest
longLivedAggregatePermitGraphDigest = internalLongLivedPermitGraphDigest

longLivedAggregatePermitAggregate
  :: LongLivedAggregatePermit -> [RegisteredResourceKey]
longLivedAggregatePermitAggregate = internalLongLivedPermitAggregate

longLivedAggregatePermitNonce :: LongLivedAggregatePermit -> Text
longLivedAggregatePermitNonce = internalLongLivedPermitNonce

data LongLivedAggregatePermitRefusal
  = -- | Issued for a different runner role.
    LongLivedPermitWrongAudience !RunnerRole
  | -- | The permit omits registered long-lived keys the surface projects.
    -- Completing on it would report a partial destruction as complete.
    LongLivedPermitAggregateIncomplete ![RegisteredResourceKey]
  | -- | The permit names keys the surface does not project.
    LongLivedPermitAggregateWidened ![RegisteredResourceKey]
  | -- | The permit is past its validity window.
    LongLivedPermitExpired
  | -- | A permit with no nonce cannot be recognized on replay.
    LongLivedPermitNonceMissing
  deriving (Eq, Show)

-- | Admit a request into a permit.  Freshness is supplied by the interpreter
-- as an observation, in the same shape
-- 'Prodbox.Lifecycle.Authority.AdminAction' and
-- 'Prodbox.Lifecycle.Decommission.Permit' use, so this stays pure.
admitLongLivedAggregatePermit
  :: PermitFreshness
  -> LongLivedAggregatePermitRequest
  -> Either LongLivedAggregatePermitRefusal LongLivedAggregatePermit
admitLongLivedAggregatePermit freshness request
  | longLivedPermitRequestAudience request /= AdminActionRunner =
      Left
        (LongLivedPermitWrongAudience (longLivedPermitRequestAudience request))
  | freshness /= PermitFresh = Left LongLivedPermitExpired
  | Text.null (longLivedPermitRequestNonce request) =
      Left LongLivedPermitNonceMissing
  | not (null missing) = Left (LongLivedPermitAggregateIncomplete missing)
  | not (null extra) = Left (LongLivedPermitAggregateWidened extra)
  | otherwise =
      Right
        LongLivedAggregatePermit
          { internalLongLivedPermitRunId = longLivedPermitRequestRunId request
          , internalLongLivedPermitGraphDigest =
              longLivedPermitRequestGraphDigest request
          , internalLongLivedPermitAggregate = longLivedAggregateUniverse
          , internalLongLivedPermitNonce = longLivedPermitRequestNonce request
          }
 where
  requested = sort (longLivedPermitRequestAggregate request)
  missing = [key | key <- longLivedAggregateUniverse, key `notElem` requested]
  extra = [key | key <- requested, key `notElem` longLivedAggregateUniverse]
