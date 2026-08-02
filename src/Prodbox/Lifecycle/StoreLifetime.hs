{-# LANGUAGE DataKinds #-}

-- | Sprint 4.51: the storage-durability lifetime a Model-B object namespace
-- belongs to. Promoted to a kind by @DataKinds@ and used ONLY as a
-- fully-erased PHANTOM index on the Model-B coordinate/request/guard/adapter
-- types in "Prodbox.Lifecycle.CheckpointAuthority". The index carries no
-- runtime representation; its sole purpose is to make "store 'ClusterRetained@
-- authority state through a 'ChartLifetime@ transport" a compile-time type
-- error, closing the storage half of the @F-SES@ counterexample class
-- (@LCPC-2026-07-11@) without changing a single sealed-envelope byte.
--
-- The three lifetimes are deliberately distinct nominal tags rather than a
-- boolean: a namespace is exactly one of them, and no smart constructor may
-- silently widen or narrow the tag.
module Prodbox.Lifecycle.StoreLifetime
  ( StoreLifetime (..)
  )
where

-- | The durability class of a retained-authority object namespace.
data StoreLifetime
  = -- | State bounded by a Helm chart / per-run Pulumi stack: it is destroyed on
    -- teardown. It may never carry retained authority state; the removed
    -- Gateway/host-direct object-store transports must not be inferred from
    -- this durability tag.
    ChartLifetime
  | -- | Retained control-plane authority state — the lease, target-commit
    -- intent, SMTP projection, and retained Pulumi checkpoint that outlive any
    -- single run. Reached only through the Lifecycle Authority's sealed
    -- in-cluster primary MinIO repository.
    ClusterRetained
  | -- | State that must survive the destruction of an entire cluster — the
    -- separately credentialed, non-aliased long-lived backup failure domain.
    CrossClusterDurable
  deriving (Eq, Show)
