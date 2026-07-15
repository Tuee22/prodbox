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
    -- teardown. This is the gateway-daemon-backed object-store transport; it may
    -- never carry retained authority state.
    ChartLifetime
  | -- | Retained control-plane authority state — the lease, target-commit
    -- intent, SMTP projection, and retained Pulumi checkpoint that outlive any
    -- single run. Reached host-direct over the sealed-envelope layer (the
    -- Lifecycle Authority primary MinIO namespace).
    ClusterRetained
  | -- | State that must survive the destruction of an entire cluster — the
    -- separately credentialed, non-aliased long-lived backup failure domain.
    CrossClusterDurable
  deriving (Eq, Show)
