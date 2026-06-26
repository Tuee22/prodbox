{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The dependency-free sealed-Vault bootstrap __floor__ loader, decoded
-- directly from the binary-owned Tier-0 @prodbox.dhall@ (config_doctrine.md
-- §0, §1a).
--
-- The floor is the minimal, non-revealing bootstrap a host needs to reach and
-- unseal this cluster's Vault while Vault is sealed and the in-force config is
-- still opaque ciphertext: the cluster id, this cluster's Vault address, the
-- seal mode, and (for a child) the parent reference it auto-unseals against. It
-- is projected from the Tier-0 record's @context@ — the SAME projection
-- 'Prodbox.Config.Tier0.projectBasics' performs purely in memory — but read
-- here straight off @prodbox.dhall@ so there is no separate derived
-- @prodbox-basics.json@ artifact to keep in sync (Sprint 7.18: ALL Dhall is
-- generated or locally authored, NONE version-controlled, and the redundant
-- JSON projection is eliminated).
--
-- This module is a LEAF: it depends only on the Dhall library,
-- "Prodbox.Config.Basics" (the floor type), and "Prodbox.Repo" (the
-- @prodbox.dhall@ path). It does NOT import "Prodbox.Settings" or
-- "Prodbox.Config.Tier0" — both of which sit downstream of it — so the floor
-- read stays decode-cycle-free and legible the moment a host has a local
-- @prodbox.dhall@, before any Vault is reachable.
--
-- @prodbox.dhall@ is fully self-contained (no Dhall imports), so decoding only
-- its @.context.{ cluster_id, vault_address, topology }@ projection is safe
-- pre-Vault. The floor-relevant context fields decoded here are a strict subset
-- of the Tier-0 @context@ record; the Sprint 1.39 round-trip unit test
-- (@writeTier0@ then @loadUnencryptedBasics@ equals @projectBasics@) pins this
-- decoder against the Tier-0 projection so the two cannot drift.
module Prodbox.Config.FloorDhall
  ( loadUnencryptedBasics
  , loadUnencryptedBasicsAtPath
  , projectFloorContext
  )
where

import Control.Exception (SomeException, displayException, try)
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall
  ( FromDhall (..)
  , InterpretOptions (..)
  , defaultInterpretOptions
  , genericAutoWith
  )
import Dhall qualified
import GHC.Generics (Generic)
import Prodbox.Config.Basics
  ( ParentRef (..)
  , SealMode (..)
  , UnencryptedBasics (..)
  , renderBasicsError
  , validateBasics
  )
import Prodbox.Repo
  ( resolveTier0ConfigPath
  )
import System.Directory (doesFileExist)

-- | The Tier-0 projection of how this cluster's Vault unseals. Mirrors
-- @Prodbox.Config.Tier0.Tier0SealMode@ and decodes the SAME Dhall union
-- (@< Tier0Shamir | Tier0Transit >@) — a 'constructorModifier' maps the local
-- Haskell constructor names onto those Dhall alternative labels so this floor
-- decoder and the Tier-0 encoder cannot disagree on the wire union.
data FloorSealMode
  = FloorShamir
  | FloorTransit
  deriving (Eq, Show, Generic)

instance FromDhall FloorSealMode where
  autoWith _ =
    genericAutoWith
      defaultInterpretOptions {constructorModifier = floorSealModeConstructor}

-- | Map the local 'FloorSealMode' constructor names onto the Dhall union
-- alternative labels emitted by @Prodbox.Config.Tier0.Tier0SealMode@
-- (@Tier0Shamir@ / @Tier0Transit@).
floorSealModeConstructor :: Text -> Text
floorSealModeConstructor value = case value of
  "FloorShamir" -> "Tier0Shamir"
  "FloorTransit" -> "Tier0Transit"
  other -> other

-- | The Tier-0 projection of a child cluster's parent reference. Mirrors
-- @Prodbox.Config.Tier0.Tier0ParentRef@.
data FloorParentRef = FloorParentRef
  { parent_cluster_id :: Text
  , parent_vault_address :: Text
  , parent_transit_key :: Text
  }
  deriving (Eq, Show, Generic, FromDhall)

-- | The Tier-0 @topology@ sub-record. Mirrors
-- @Prodbox.Config.Tier0.ProdboxTopology@.
data FloorTopology = FloorTopology
  { seal_mode :: FloorSealMode
  , parent_ref :: Maybe FloorParentRef
  }
  deriving (Eq, Show, Generic, FromDhall)

-- | The floor-relevant projection of the Tier-0 @context@ record:
-- @.context.{ cluster_id, vault_address, topology }@. These are exactly the
-- fields 'Prodbox.Config.Tier0.projectBasics' reads.
data FloorContext = FloorContext
  { cluster_id :: Text
  , vault_address :: Text
  , topology :: FloorTopology
  }
  deriving (Eq, Show, Generic, FromDhall)

-- | The format version stamped into the floor. The floor schema is owned by
-- "Prodbox.Config.Basics" (Sprint 1.38); this projection stamps version 1, the
-- same constant 'Prodbox.Config.Tier0.projectBasics' uses.
floorFormatVersionV1 :: Int
floorFormatVersionV1 = 1

-- | Build the floor 'UnencryptedBasics' from the decoded Tier-0 context
-- projection. Pure mirror of 'Prodbox.Config.Tier0.projectBasics'.
projectFloorContext :: FloorContext -> UnencryptedBasics
projectFloorContext ctx =
  UnencryptedBasics
    { basicsClusterId = cluster_id ctx
    , basicsVaultAddress = vault_address ctx
    , basicsSealMode = toBasicsSealMode (seal_mode topo)
    , basicsParentRef = fmap toBasicsParentRef (parent_ref topo)
    , basicsFormatVersion = floorFormatVersionV1
    }
 where
  topo = topology ctx

toBasicsSealMode :: FloorSealMode -> SealMode
toBasicsSealMode mode = case mode of
  FloorShamir -> SealModeShamir
  FloorTransit -> SealModeTransit

toBasicsParentRef :: FloorParentRef -> ParentRef
toBasicsParentRef ref =
  ParentRef
    { parentRefClusterId = parent_cluster_id ref
    , parentRefVaultAddress = parent_vault_address ref
    , parentRefTransitKey = parent_transit_key ref
    }

-- | Load the sealed-Vault bootstrap floor by decoding the Tier-0
-- @prodbox.dhall@ at @repoRoot@ and projecting its @context@. Returns the same
-- @Left "Missing unencrypted basics file: ..."@ surface the legacy reader
-- emitted when no @prodbox.dhall@ is present, so the seed/propose first-bring-up
-- fallback in 'Prodbox.Settings.loadConfigForSettingsWith' still takes over
-- before a cluster is established.
--
-- The decode is dependency-free: @prodbox.dhall@ has no Dhall imports, and only
-- the floor-relevant @context@ projection is read, so this is safe while Vault
-- is sealed.
loadUnencryptedBasics :: FilePath -> IO (Either String UnencryptedBasics)
loadUnencryptedBasics repoRoot =
  resolveTier0ConfigPath repoRoot >>= loadUnencryptedBasicsAtPath

-- | Project the sealed-Vault bootstrap floor from a Tier-0 prodbox.dhall at an
-- EXPLICIT path. 'loadUnencryptedBasics' resolves the binary-sibling path and
-- delegates here; this is the path-injection seam in-process unit tests
-- exercise directly. Sprint 1.48.
loadUnencryptedBasicsAtPath :: FilePath -> IO (Either String UnencryptedBasics)
loadUnencryptedBasicsAtPath tier0Path = do
  present <- doesFileExist tier0Path
  if not present
    then
      pure
        ( Left
            ( "Missing unencrypted basics file: no Tier-0 `"
                ++ tier0Path
                ++ "` to project the sealed-Vault bootstrap floor from. Run a"
                ++ " lifecycle command (e.g. `prodbox vault init` /"
                ++ " `prodbox cluster reconcile`) to establish it."
            )
        )
    else do
      -- Project to the floor-relevant context fields before decoding, so the
      -- decoder only needs the floor sub-schema and is decoupled from the rest
      -- of the Tier-0 record (parameters / witness never reach the floor).
      let expression =
            "( "
              ++ tier0Path
              ++ " ).context.{ cluster_id, vault_address, topology }"
      decodeResult <-
        try (Dhall.input Dhall.auto (Text.pack expression))
          :: IO (Either SomeException FloorContext)
      pure $ case decodeResult of
        Left err ->
          Left
            ( "Failed to project the sealed-Vault bootstrap floor from Tier-0 `"
                ++ tier0Path
                ++ "`: "
                ++ displayException err
            )
        Right ctx -> do
          let basics = projectFloorContext ctx
          mapLeft renderBasicsError (validateBasics basics)
          pure basics

mapLeft :: (left -> left') -> Either left right -> Either left' right
mapLeft f value = case value of
  Left err -> Left (f err)
  Right result -> Right result
