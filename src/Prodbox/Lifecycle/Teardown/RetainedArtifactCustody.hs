{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: custody of the retained bytes an ordinary-teardown repair
-- names.
--
-- "Prodbox.Config.OrdinaryTeardownRepair" answers which artifacts a repair of
-- the recovery closure is /allowed/ to read, and refuses to render a plan when
-- the inventory does not retain them.  That refusal is honest and it is also
-- terminal: nothing in the repository ever put bytes under the retained root,
-- so the absent-substrate arm of the repair matrix could only ever refuse.
-- This module is the lifecycle execution that closes the gap — acquiring the
-- inventory's artifacts, keeping them verifiable, and collecting what no
-- inventory entry names.
--
-- Three properties carry the design.
--
--   * __The inventory is the authority; a source is a transport.__  An
--     acquisition is admitted only when the bytes it produced hash to the
--     digest the inventory already pinned.  The catalog refuses at
--     construction to bind a locator whose declared digest disagrees, and
--     'applyRetainedArtifactCustody' refuses again at execution against the
--     digest the boundary actually observed.  Neither an ambient network fetch
--     nor a host image cache can therefore decide what is retained; they can
--     only deliver bytes an existing decision already named.
--
--   * __Membership is exact in both directions.__  Every inventory entry is
--     classified exactly once, and every observed store member is classified
--     exactly once.  A member the inventory does not name is a collection
--     target rather than something quietly kept, and a collection target can
--     never be a path an inventory entry names.  Retention drift in either
--     direction is a planned action, not a silent divergence.
--
--   * __Custody mutation is Authority-bound; locating retained bytes is not.__
--     The store is indexed by how its root was obtained.  A bootstrap-located
--     store can be read, which is what recovery needs while the Authority is
--     absent; acquiring and collecting require the Authority-bound index, so
--     the mutating surface cannot be reached from the non-authorizing locator.
--
-- The pure kernel plans and reads back.  The only effects live behind an
-- injected 'RetainedArtifactCustodyBoundary', so the fault matrix — a lost
-- acquisition response, delivered bytes with the wrong digest, an unobservable
-- store, a removal that fails — is exercised without a filesystem or a
-- network.
module Prodbox.Lifecycle.Teardown.RetainedArtifactCustody
  ( -- * Where retained artifacts live
    RetainedArtifactStoreAuthority (..)
  , RetainedArtifactStore
  , retainedArtifactStorePath
  , retainedArtifactStagingDirectory
  , retainedArtifactStoreDirectoryName
  , bootstrapLocatedRetainedArtifactStore
  , authorityBoundRetainedArtifactStore
  , retainedArtifactMemberPath

    -- * Pinned acquisition sources
  , RetainedArtifactLocator (..)
  , retainedArtifactLocatorText
  , RetainedArtifactSourceEntry (..)
  , RetainedArtifactSource
  , retainedArtifactSourceKind
  , retainedArtifactSourceArchitecture
  , retainedArtifactSourceDigest
  , retainedArtifactSourceLocator
  , RetainedArtifactSourceCatalog
  , retainedArtifactSourceCatalogKinds
  , RetainedArtifactSourceError (..)
  , renderRetainedArtifactSourceError
  , retainedArtifactSourceCatalog
  , lookupRetainedArtifactSource

    -- * Observing the store
  , RetainedArtifactMemberDigest (..)
  , RetainedArtifactMember (..)
  , RetainedArtifactStoreObservation (..)
  , observeRetainedArtifactStore

    -- * The custody plan
  , RetainedArtifactUnusable (..)
  , renderRetainedArtifactUnusable
  , RetainedArtifactCustodyAction (..)
  , RetainedArtifactCustodyPlan
  , retainedArtifactCustodyPlanArchitecture
  , retainedArtifactCustodyPlanActions
  , retainedArtifactCustodyPlanAcquisitions
  , retainedArtifactCustodyPlanCollections
  , retainedArtifactCustodyPlanVerified
  , RetainedArtifactCustodyError (..)
  , renderRetainedArtifactCustodyError
  , planRetainedArtifactCustody

    -- * Applying the plan
  , RetainedArtifactStaging (..)
  , RetainedArtifactCustodyBoundary (..)
  , RetainedArtifactCustodyOutcome (..)
  , renderRetainedArtifactCustodyOutcome
  , RetainedArtifactCustodyStep (..)
  , applyRetainedArtifactCustody
  , maximumRetainedArtifactBytes
  , productionRetainedArtifactCustodyBoundary

    -- * Read-back
  , RetainedArtifactCustodyResidue (..)
  , renderRetainedArtifactCustodyResidue
  , RetainedArtifactCustodyConvergence (..)
  , retainedArtifactCustodyReadBack

    -- * Repair readiness
  , RetainedArtifactRepairReadiness (..)
  , renderRetainedArtifactRepairReadiness
  , retainedArtifactRepairPlanRefs
  , retainedArtifactRepairReadiness
  )
where

import Control.Exception (IOException, try)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as ByteString
import Data.List (sort, sortOn)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Config.LocalRetainedRoot
  ( AuthorityBoundRetainedRoot
  , BootstrapRetainedRootLocator
  , authorityBoundRetainedRootControlDirectory
  , bootstrapRetainedRootControlDirectory
  )
import Prodbox.Config.OrdinaryTeardownRepair
  ( OrdinaryTeardownRepairPlan
  , OrdinaryTeardownRepairStep (..)
  , RetainedArtifactArchitecture
  , RetainedArtifactInventory
  , RetainedArtifactKind
  , RetainedArtifactLocator (..)
  , RetainedArtifactRef
  , RetainedArtifactSource
  , RetainedArtifactSourceCatalog
  , RetainedArtifactSourceEntry (..)
  , RetainedArtifactSourceError (..)
  , lookupRetainedArtifact
  , lookupRetainedArtifactSource
  , ordinaryTeardownRepairPlanSteps
  , renderRetainedArtifactSourceError
  , retainedArtifactArchitectureText
  , retainedArtifactInventoryArchitecture
  , retainedArtifactInventoryKinds
  , retainedArtifactKindText
  , retainedArtifactLocatorText
  , retainedArtifactRefArchitecture
  , retainedArtifactRefDigest
  , retainedArtifactRefKind
  , retainedArtifactRefRelativePath
  , retainedArtifactSourceArchitecture
  , retainedArtifactSourceCatalog
  , retainedArtifactSourceCatalogArchitecture
  , retainedArtifactSourceCatalogKinds
  , retainedArtifactSourceDigest
  , retainedArtifactSourceKind
  , retainedArtifactSourceLocator
  )
import Prodbox.Http.Client
  ( HttpConfig (..)
  , HttpDownload (..)
  , httpDownloadToFile
  , renderHttpDownloadError
  )
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , listDirectory
  , removeFile
  , renamePath
  )
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode (ReadMode), withFile)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (FileStatus, getSymbolicLinkStatus, isRegularFile)

-- ---------------------------------------------------------------------------
-- Where retained artifacts live
-- ---------------------------------------------------------------------------

-- | How a store's retained root was obtained.  Promoted by @DataKinds@ and
-- used only as a fully erased phantom index: it carries no runtime
-- representation and exists so that \"collect bytes under a root nobody
-- authenticated\" is a type error rather than a review comment.
data RetainedArtifactStoreAuthority
  = -- | Located by the non-authorizing bootstrap locator.  Readable, because
    -- recovery has to find retained bytes while the Authority is absent.
    BootstrapLocatedStore
  | -- | Bound to a fresh authenticated Operator projection.  Only this index
    -- reaches 'applyRetainedArtifactCustody'.
    AuthorityBoundStore
  deriving (Eq, Show)

-- | The retained-artifact store.  Opaque, and it holds the prodbox-owned
-- control directory rather than the store path itself, because the store and
-- its staging area are siblings that must both be derived from one place.
newtype RetainedArtifactStore (authority :: RetainedArtifactStoreAuthority)
  = RetainedArtifactStore FilePath
  deriving (Eq, Ord, Show)

-- | The single segment that names the store inside the prodbox-owned control
-- directory.  It sits beside the establishment marker rather than beside the
-- MinIO and Vault data roots, because these bytes are prodbox's own retained
-- inputs and not a component's state.
retainedArtifactStoreDirectoryName :: FilePath
retainedArtifactStoreDirectoryName = "artifacts"

retainedArtifactStorePath :: RetainedArtifactStore authority -> FilePath
retainedArtifactStorePath (RetainedArtifactStore control) =
  control </> retainedArtifactStoreDirectoryName

-- | Where a delivery is written before it is admitted.
--
-- It is a sibling of the store rather than a directory inside it, for two
-- reasons: a partial delivery must never be observable as a store member, and
-- an admission has to be a same-filesystem rename rather than a copy that can
-- be interrupted halfway.
retainedArtifactStagingDirectory :: RetainedArtifactStore authority -> FilePath
retainedArtifactStagingDirectory (RetainedArtifactStore control) =
  control </> (retainedArtifactStoreDirectoryName ++ ".staging")

-- | Locate the store from the non-authorizing bootstrap locator.
bootstrapLocatedRetainedArtifactStore
  :: BootstrapRetainedRootLocator -> RetainedArtifactStore 'BootstrapLocatedStore
bootstrapLocatedRetainedArtifactStore =
  RetainedArtifactStore . bootstrapRetainedRootControlDirectory

-- | Bind the store to an Authority-bound root.  Custody mutation starts here.
authorityBoundRetainedArtifactStore
  :: AuthorityBoundRetainedRoot -> RetainedArtifactStore 'AuthorityBoundStore
authorityBoundRetainedArtifactStore =
  RetainedArtifactStore . authorityBoundRetainedRootControlDirectory

-- | The exact path of one retained artifact.
--
-- The relative half comes from a validated 'RetainedArtifactRef', which
-- already proved it is relative and free of empty, current-, and
-- parent-directory segments, so this composition cannot leave the store.
retainedArtifactMemberPath
  :: RetainedArtifactStore authority -> RetainedArtifactRef -> FilePath
retainedArtifactMemberPath store ref =
  retainedArtifactStorePath store </> retainedArtifactRefRelativePath ref

-- ---------------------------------------------------------------------------
-- Observing the store
-- ---------------------------------------------------------------------------

-- | What an observation established about one member's bytes.
data RetainedArtifactMemberDigest
  = -- | The member's content digest was computed.
    RetainedArtifactMemberDigested !Text
  | -- | The member exists but its bytes could not be read.  Distinct from a
    -- mismatch on purpose: an unreadable member proves nothing about content,
    -- and the receipt should not be able to say it did.
    RetainedArtifactMemberUnreadable !Text
  deriving (Eq, Ord, Show)

-- | One observed member of the store, addressed the same way the inventory
-- addresses its entries: relative to the store root.
data RetainedArtifactMember = RetainedArtifactMember
  { retainedArtifactMemberRelativePath :: !FilePath
  , retainedArtifactMemberDigest :: !RetainedArtifactMemberDigest
  }
  deriving (Eq, Ord, Show)

-- | The exact result of listing the store.
--
-- An absent store is /not/ unobservable: a store that has never been populated
-- is exactly an empty member set, and planning acquisition of everything is
-- the correct answer for it.  Unobservable is reserved for a listing that
-- failed, which closes nothing.
data RetainedArtifactStoreObservation
  = RetainedArtifactStoreMembers ![RetainedArtifactMember]
  | RetainedArtifactStoreUnobservable !Text
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- The custody plan
-- ---------------------------------------------------------------------------

-- | Why a retained member cannot serve the entry that names its location.
data RetainedArtifactUnusable
  = RetainedArtifactDigestMismatch !Text
  | RetainedArtifactDigestUnreadable !Text
  deriving (Eq, Show)

renderRetainedArtifactUnusable :: RetainedArtifactUnusable -> String
renderRetainedArtifactUnusable = \case
  RetainedArtifactDigestMismatch observed ->
    "retained bytes hash to `" ++ Text.unpack observed ++ "`"
  RetainedArtifactDigestUnreadable detail ->
    "retained bytes are unreadable: " ++ Text.unpack detail

-- | One planned custody action.
data RetainedArtifactCustodyAction
  = -- | Present and hashing to the pinned digest.  Retained as-is.
    RetainedArtifactVerified !RetainedArtifactRef
  | -- | Named by the inventory and absent from the store.
    RetainedArtifactAcquire !RetainedArtifactRef !RetainedArtifactSource
  | -- | Present and unusable.  The remedy is the same acquisition, but the
    -- reason is preserved so the receipt distinguishes a corrupt artifact from
    -- one that was never there.
    RetainedArtifactReplace
      !RetainedArtifactRef
      !RetainedArtifactSource
      !RetainedArtifactUnusable
  | -- | Present under the store and named by no inventory entry.
    RetainedArtifactCollect !FilePath
  deriving (Eq, Show)

-- | Opaque rendered custody plan.  Construction proves the plan covers every
-- inventory entry and every observed member exactly once.
data RetainedArtifactCustodyPlan = RetainedArtifactCustodyPlan
  { retainedArtifactCustodyPlanArchitecture :: !RetainedArtifactArchitecture
  , retainedArtifactCustodyPlanActions :: ![RetainedArtifactCustodyAction]
  }
  deriving (Eq, Show)

retainedArtifactCustodyPlanAcquisitions
  :: RetainedArtifactCustodyPlan -> [RetainedArtifactRef]
retainedArtifactCustodyPlanAcquisitions plan =
  [ ref
  | action <- retainedArtifactCustodyPlanActions plan
  , ref <- case action of
      RetainedArtifactAcquire acquired _ -> [acquired]
      RetainedArtifactReplace replaced _ _ -> [replaced]
      _ -> []
  ]

retainedArtifactCustodyPlanCollections :: RetainedArtifactCustodyPlan -> [FilePath]
retainedArtifactCustodyPlanCollections plan =
  [ path
  | RetainedArtifactCollect path <- retainedArtifactCustodyPlanActions plan
  ]

retainedArtifactCustodyPlanVerified
  :: RetainedArtifactCustodyPlan -> [RetainedArtifactRef]
retainedArtifactCustodyPlanVerified plan =
  [ ref
  | RetainedArtifactVerified ref <- retainedArtifactCustodyPlanActions plan
  ]

data RetainedArtifactCustodyError
  = -- | The store could not be listed, so neither what is retained nor what is
    -- unreferenced is known.  Nothing is planned against an unknown store.
    RetainedArtifactCustodyStoreUnobservable !Text
  | -- | The catalog is for a different architecture than the inventory.
    RetainedArtifactCustodyArchitectureMismatch
      !RetainedArtifactArchitecture
      !RetainedArtifactArchitecture
  | -- | The inventory names artifacts no source can deliver.  The complete set
    -- is reported, so an operator learns the whole declaration gap at once.
    RetainedArtifactCustodyUnsourced
      !RetainedArtifactArchitecture
      !(NonEmpty RetainedArtifactKind)
  | -- | A source is declared for a kind whose inventory digest it does not
    -- match.  Admitting it would let the transport redefine what is retained.
    RetainedArtifactCustodySourceDigestMismatch
      !RetainedArtifactKind
      !Text
      !Text
  deriving (Eq, Show)

renderRetainedArtifactCustodyError :: RetainedArtifactCustodyError -> String
renderRetainedArtifactCustodyError = \case
  RetainedArtifactCustodyStoreUnobservable detail ->
    "Retained artifact custody cannot plan against an unobservable store: "
      ++ Text.unpack detail
      ++ ". Neither retention nor collection is decided from an unread store."
  RetainedArtifactCustodyArchitectureMismatch inventoryArchitecture catalogArch ->
    "Retained artifact custody was given a `"
      ++ retainedArtifactArchitectureText catalogArch
      ++ "` source catalog for a `"
      ++ retainedArtifactArchitectureText inventoryArchitecture
      ++ "` inventory."
  RetainedArtifactCustodyUnsourced architecture missing ->
    "Retained artifact custody has no declared "
      ++ retainedArtifactArchitectureText architecture
      ++ " source for: "
      ++ commaSeparated (fmap retainedArtifactKindText (NonEmpty.toList missing))
      ++ ". An artifact the repository intends to retain but cannot acquire is \
         \a retention obligation nobody can discharge."
  RetainedArtifactCustodySourceDigestMismatch kind pinned declared ->
    "Retained artifact source `"
      ++ retainedArtifactKindText kind
      ++ "` declares digest `"
      ++ Text.unpack declared
      ++ "` while the inventory pins `"
      ++ Text.unpack pinned
      ++ "`. The inventory decides what is retained; a source only delivers it."

commaSeparated :: [String] -> String
commaSeparated = \case
  [] -> ""
  [single] -> single
  first : remaining -> first ++ ", " ++ commaSeparated remaining

-- | Derive the custody plan for one inventory against one observation.
--
-- Both directions are total.  Every inventory entry produces exactly one of
-- verified/acquire/replace, and every observed member is either the location of
-- an inventory entry or a collection target; nothing is skipped and nothing is
-- classified twice.
planRetainedArtifactCustody
  :: RetainedArtifactInventory
  -> RetainedArtifactSourceCatalog
  -> RetainedArtifactStoreObservation
  -> Either RetainedArtifactCustodyError RetainedArtifactCustodyPlan
planRetainedArtifactCustody inventory catalog observation
  | inventoryArchitecture /= retainedArtifactSourceCatalogArchitecture catalog =
      Left
        ( RetainedArtifactCustodyArchitectureMismatch
            inventoryArchitecture
            (retainedArtifactSourceCatalogArchitecture catalog)
        )
  | otherwise = case observation of
      RetainedArtifactStoreUnobservable detail ->
        Left (RetainedArtifactCustodyStoreUnobservable detail)
      RetainedArtifactStoreMembers members -> do
        bound <- bindSources
        let observed =
              Map.fromList
                [ (retainedArtifactMemberRelativePath member, retainedArtifactMemberDigest member)
                | member <- members
                ]
            entryActions = fmap (entryAction observed) bound
            retainedPaths =
              [retainedArtifactRefRelativePath ref | (ref, _) <- bound]
            collections =
              [ RetainedArtifactCollect path
              | path <- sort (Map.keys observed)
              , path `notElem` retainedPaths
              ]
        pure
          RetainedArtifactCustodyPlan
            { retainedArtifactCustodyPlanArchitecture = inventoryArchitecture
            , retainedArtifactCustodyPlanActions = entryActions ++ collections
            }
 where
  inventoryArchitecture = retainedArtifactInventoryArchitecture inventory

  entryAction observed (ref, source) =
    case Map.lookup (retainedArtifactRefRelativePath ref) observed of
      Nothing -> RetainedArtifactAcquire ref source
      Just (RetainedArtifactMemberUnreadable detail) ->
        RetainedArtifactReplace ref source (RetainedArtifactDigestUnreadable detail)
      Just (RetainedArtifactMemberDigested observedDigest)
        | observedDigest == Text.pack (retainedArtifactRefDigest ref) ->
            RetainedArtifactVerified ref
        | otherwise ->
            RetainedArtifactReplace
              ref
              source
              (RetainedArtifactDigestMismatch observedDigest)

  -- Pair every inventory entry with the source that may deliver it, refusing
  -- the complete unsourced set and any source whose digest is not the pinned
  -- one.
  bindSources = do
    let kinds = retainedArtifactInventoryKinds inventory
        attempted =
          [ (kind, lookupRetainedArtifact kind inventory, lookupRetainedArtifactSource kind catalog)
          | kind <- kinds
          ]
        unsourced = [kind | (kind, _, Nothing) <- attempted]
    case NonEmpty.nonEmpty unsourced of
      Just missing ->
        Left (RetainedArtifactCustodyUnsourced inventoryArchitecture missing)
      Nothing ->
        traverse
          bindOne
          [(ref, source) | (_, Just ref, Just source) <- attempted]

  bindOne (ref, source)
    | pinned /= declared =
        Left
          ( RetainedArtifactCustodySourceDigestMismatch
              (retainedArtifactRefKind ref)
              pinned
              declared
          )
    | retainedArtifactRefArchitecture ref
        /= retainedArtifactSourceArchitecture source =
        Left
          ( RetainedArtifactCustodyArchitectureMismatch
              (retainedArtifactRefArchitecture ref)
              (retainedArtifactSourceArchitecture source)
          )
    | otherwise = Right (ref, source)
   where
    pinned = Text.pack (retainedArtifactRefDigest ref)
    declared = retainedArtifactSourceDigest source

-- ---------------------------------------------------------------------------
-- Applying the plan
-- ---------------------------------------------------------------------------

-- | What an acquisition delivered, before it is admitted to the store.
--
-- Staging is separate from placement on purpose: bytes that fail the digest
-- check are never placed, so a failed acquisition cannot leave a plausible but
-- wrong artifact where a later repair would read it.
data RetainedArtifactStaging = RetainedArtifactStaging
  { retainedArtifactStagingPath :: !FilePath
  , retainedArtifactStagingDigest :: !Text
  }
  deriving (Eq, Show)

-- | The injected physical boundary.
--
-- Tests deliver the wrong bytes, lose an acquisition response, fail a removal,
-- or make the store unobservable, without the adapter's plan, digests, or
-- classification changing.
data RetainedArtifactCustodyBoundary m = RetainedArtifactCustodyBoundary
  { custodyObserveStore :: m RetainedArtifactStoreObservation
  , custodyAcquire
      :: RetainedArtifactRef
      -> RetainedArtifactSource
      -> m (Either Text RetainedArtifactStaging)
  , custodyPlace
      :: RetainedArtifactRef
      -> RetainedArtifactStaging
      -> m (Either Text ())
  , custodyDiscardStaging :: RetainedArtifactStaging -> m ()
  , custodyRemoveMember :: FilePath -> m (Either Text ())
  -- ^ Addressed by the store-relative path the observation reported.  The
  -- boundary resolves it under the store it was built from, so the pure
  -- adapter composes no path and cannot be handed one that leaves the store.
  }

-- | What one applied action did.
data RetainedArtifactCustodyOutcome
  = -- | The artifact was already retained and verified; no effect was issued.
    RetainedArtifactCustodyAlreadyRetained
  | -- | Bytes were delivered, matched the pinned digest, and were placed.
    RetainedArtifactCustodyRetained !Text
  | -- | The delivery failed or its response was lost.  Not evidence that
    -- nothing was fetched, which is why the store is re-observed afterwards.
    RetainedArtifactCustodyDeliveryLost !Text
  | -- | Bytes were delivered and hashed to something other than the pinned
    -- digest.  They were discarded rather than placed.
    RetainedArtifactCustodyDeliveryRejected !Text !Text
  | -- | The verified bytes could not be placed into the store.
    RetainedArtifactCustodyPlacementFailed !Text
  | -- | An unreferenced member was removed.
    RetainedArtifactCustodyCollected
  | -- | An unreferenced member could not be removed.
    RetainedArtifactCustodyCollectionFailed !Text
  deriving (Eq, Show)

renderRetainedArtifactCustodyOutcome :: RetainedArtifactCustodyOutcome -> String
renderRetainedArtifactCustodyOutcome = \case
  RetainedArtifactCustodyAlreadyRetained -> "already retained"
  RetainedArtifactCustodyRetained digest ->
    "retained bytes matching " ++ Text.unpack digest
  RetainedArtifactCustodyDeliveryLost detail ->
    "delivery response lost: " ++ Text.unpack detail
  RetainedArtifactCustodyDeliveryRejected pinned observed ->
    "delivery rejected: expected "
      ++ Text.unpack pinned
      ++ " and received "
      ++ Text.unpack observed
  RetainedArtifactCustodyPlacementFailed detail ->
    "placement failed: " ++ Text.unpack detail
  RetainedArtifactCustodyCollected -> "collected"
  RetainedArtifactCustodyCollectionFailed detail ->
    "collection failed: " ++ Text.unpack detail

-- | One applied action and what it did.
data RetainedArtifactCustodyStep = RetainedArtifactCustodyStep
  { retainedArtifactCustodyStepAction :: !RetainedArtifactCustodyAction
  , retainedArtifactCustodyStepOutcome :: !RetainedArtifactCustodyOutcome
  }
  deriving (Eq, Show)

-- | Apply a custody plan through its boundary.
--
-- The Authority-bound index is enforced where it belongs, at
-- 'productionRetainedArtifactCustodyBoundary': a boundary that mutates the
-- store cannot be constructed from a bootstrap-located one, and this traversal
-- then has no store to be handed the wrong one of.
--
-- Applying every action rather than stopping at the first failure is
-- deliberate: a plan is a set of independent obligations, and one undeliverable
-- artifact is not a reason to leave the rest unretained or an unreferenced
-- member in place.  The read-back, not this traversal, decides convergence.
applyRetainedArtifactCustody
  :: (Monad m)
  => RetainedArtifactCustodyBoundary m
  -> RetainedArtifactCustodyPlan
  -> m [RetainedArtifactCustodyStep]
applyRetainedArtifactCustody boundary plan =
  traverse applyAction (retainedArtifactCustodyPlanActions plan)
 where
  applyAction action = do
    outcome <- case action of
      RetainedArtifactVerified _ -> pure RetainedArtifactCustodyAlreadyRetained
      RetainedArtifactAcquire ref source -> acquire ref source
      RetainedArtifactReplace ref source _ -> acquire ref source
      RetainedArtifactCollect relativePath -> collect relativePath
    pure
      RetainedArtifactCustodyStep
        { retainedArtifactCustodyStepAction = action
        , retainedArtifactCustodyStepOutcome = outcome
        }

  acquire ref source = do
    delivered <- custodyAcquire boundary ref source
    case delivered of
      Left detail -> pure (RetainedArtifactCustodyDeliveryLost detail)
      Right staging
        | retainedArtifactStagingDigest staging /= pinnedDigest ref -> do
            custodyDiscardStaging boundary staging
            pure
              ( RetainedArtifactCustodyDeliveryRejected
                  (pinnedDigest ref)
                  (retainedArtifactStagingDigest staging)
              )
        | otherwise -> do
            placed <- custodyPlace boundary ref staging
            pure $ case placed of
              Left detail -> RetainedArtifactCustodyPlacementFailed detail
              Right () -> RetainedArtifactCustodyRetained (pinnedDigest ref)

  collect relativePath = do
    removed <- custodyRemoveMember boundary relativePath
    pure $ case removed of
      Left detail -> RetainedArtifactCustodyCollectionFailed detail
      Right () -> RetainedArtifactCustodyCollected

  pinnedDigest = Text.pack . retainedArtifactRefDigest

-- | The ceiling one retained artifact may occupy.
--
-- It exists so an acquisition is a bounded transfer rather than an unbounded
-- one: a source that turns out to serve something far larger than a substrate
-- installer is refused mid-stream instead of filling the retained root.
maximumRetainedArtifactBytes :: Int
maximumRetainedArtifactBytes = 4 * 1024 * 1024 * 1024

-- | Artifacts are large and their transfers are long; the ten-second default
-- describes an API call, not a release download.
retainedArtifactHttpConfig :: HttpConfig
retainedArtifactHttpConfig =
  HttpConfig {httpRequestTimeoutMicros = 30 * 60 * 1_000_000}

-- | The physical custody boundary for one Authority-bound store.
--
-- This constructor is where the phantom index is spent: there is no way to
-- build a mutating boundary out of a bootstrap-located store, so the
-- non-authorizing locator can find retained bytes and can never collect or
-- replace them.
productionRetainedArtifactCustodyBoundary
  :: RetainedArtifactStore 'AuthorityBoundStore
  -> RetainedArtifactCustodyBoundary IO
productionRetainedArtifactCustodyBoundary store =
  RetainedArtifactCustodyBoundary
    { custodyObserveStore = observeRetainedArtifactStore store
    , custodyAcquire = acquireProductionArtifact store
    , custodyPlace = placeProductionArtifact store
    , custodyDiscardStaging = discardProductionStaging
    , custodyRemoveMember = removeProductionMember store
    }

-- | List and digest every member of the store.
--
-- An absent store directory is an empty member set rather than an
-- observation failure: a store that was never populated is a fact the plan
-- knows how to act on, while a listing that failed is not.
--
-- Available from either root, and deliberately so: listing a store is not a
-- mutation, and a bootstrap-located root is exactly what a recovery has while
-- the Authority is absent.  Only the mutating boundary above requires the
-- Authority-bound index.
observeRetainedArtifactStore
  :: RetainedArtifactStore authority -> IO RetainedArtifactStoreObservation
observeRetainedArtifactStore store = do
  present <- try (doesDirectoryExist root) :: IO (Either IOException Bool)
  case present of
    Left err -> pure (unobservable err)
    Right False -> pure (RetainedArtifactStoreMembers [])
    Right True -> do
      walked <- try (walk "") :: IO (Either IOException [RetainedArtifactMember])
      pure $ case walked of
        Left err -> unobservable err
        Right members -> RetainedArtifactStoreMembers (sortMembers members)
 where
  root = retainedArtifactStorePath store

  unobservable err =
    RetainedArtifactStoreUnobservable (boundedDetail (Text.pack (show err)))

  walk relative = do
    entries <- listDirectory (root </> relative)
    fmap concat (traverse (member relative) entries)

  member relative entry = do
    let childRelative = if null relative then entry else relative </> entry
        childPath = root </> childRelative
    isDirectory <- doesDirectoryExist childPath
    if isDirectory
      then walk childRelative
      else do
        status <-
          try (getSymbolicLinkStatus childPath)
            :: IO (Either IOException FileStatus)
        case status of
          Left err ->
            pure
              [ RetainedArtifactMember
                  { retainedArtifactMemberRelativePath = childRelative
                  , retainedArtifactMemberDigest =
                      RetainedArtifactMemberUnreadable (boundedDetail (Text.pack (show err)))
                  }
              ]
          Right observed
            | not (isRegularFile observed) ->
                pure
                  [ RetainedArtifactMember
                      { retainedArtifactMemberRelativePath = childRelative
                      , retainedArtifactMemberDigest =
                          RetainedArtifactMemberUnreadable "store member is not a regular file"
                      }
                  ]
            | otherwise -> do
                digested <- digestFile childPath
                pure
                  [ RetainedArtifactMember
                      { retainedArtifactMemberRelativePath = childRelative
                      , retainedArtifactMemberDigest = digested
                      }
                  ]

sortMembers :: [RetainedArtifactMember] -> [RetainedArtifactMember]
sortMembers = sortOn retainedArtifactMemberRelativePath

-- | Digest a member by streaming it, so a multi-gigabyte archive is a bounded
-- read rather than a resident buffer.
digestFile :: FilePath -> IO RetainedArtifactMemberDigest
digestFile path = do
  hashed <-
    try (withFile path ReadMode (consume SHA256.init))
      :: IO (Either IOException Text)
  pure $ case hashed of
    Left err -> RetainedArtifactMemberUnreadable (boundedDetail (Text.pack (show err)))
    Right digest -> RetainedArtifactMemberDigested digest
 where
  consume context handle = do
    chunk <- ByteString.hGet handle digestChunkBytes
    if ByteString.null chunk
      then pure (canonicalDigest (SHA256.finalize context))
      else consume (SHA256.update context chunk) handle

digestChunkBytes :: Int
digestChunkBytes = 1024 * 1024

canonicalDigest :: ByteString.ByteString -> Text
canonicalDigest = ("sha256:" <>) . Text.pack . concatMap renderByte . ByteString.unpack
 where
  renderByte byte = [hexDigit (byte `div` 16), hexDigit (byte `mod` 16)]
  hexDigit value
    | value < 10 = toEnum (fromEnum '0' + fromIntegral value)
    | otherwise = toEnum (fromEnum 'a' + fromIntegral value - 10)

-- | Deliver one artifact into the staging area.
--
-- The staged file mirrors the member's own relative location, so a staged
-- delivery is readable as the artifact it is for; it is under the staging
-- sibling rather than the store, so it is never observable as a member.
acquireProductionArtifact
  :: RetainedArtifactStore authority
  -> RetainedArtifactRef
  -> RetainedArtifactSource
  -> IO (Either Text RetainedArtifactStaging)
acquireProductionArtifact store ref source = do
  prepared <-
    try (createDirectoryIfMissing True (takeDirectory stagingPath))
      :: IO (Either IOException ())
  case prepared of
    Left err -> pure (Left (boundedDetail (Text.pack (show err))))
    Right () -> do
      delivered <-
        httpDownloadToFile
          retainedArtifactHttpConfig
          maximumRetainedArtifactBytes
          (Text.unpack (retainedArtifactLocatorText (retainedArtifactSourceLocator source)))
          stagingPath
      pure $ case delivered of
        Left err -> Left (boundedDetail (Text.pack (renderHttpDownloadError err)))
        Right download ->
          Right
            RetainedArtifactStaging
              { retainedArtifactStagingPath = stagingPath
              , retainedArtifactStagingDigest =
                  "sha256:" <> Text.pack (httpDownloadSha256 download)
              }
 where
  stagingPath =
    retainedArtifactStagingDirectory store </> retainedArtifactRefRelativePath ref

-- | Admit staged bytes to the store by rename.
placeProductionArtifact
  :: RetainedArtifactStore authority
  -> RetainedArtifactRef
  -> RetainedArtifactStaging
  -> IO (Either Text ())
placeProductionArtifact store ref staging = do
  placed <-
    try
      ( do
          createDirectoryIfMissing True (takeDirectory memberPath)
          renamePath (retainedArtifactStagingPath staging) memberPath
      )
      :: IO (Either IOException ())
  pure (either (Left . boundedDetail . Text.pack . show) Right placed)
 where
  memberPath = retainedArtifactMemberPath store ref

-- | Discard rejected bytes.  A discard that itself fails changes nothing the
-- read-back decides: the staging sibling is outside the store, so a surviving
-- rejected delivery is never a member and never satisfies an obligation.
discardProductionStaging :: RetainedArtifactStaging -> IO ()
discardProductionStaging staging = do
  discarded <-
    try (removeFile (retainedArtifactStagingPath staging))
      :: IO (Either IOException ())
  either (const (pure ())) pure discarded

-- | Remove one unreferenced member.
--
-- The relative path is re-checked even though it came from this boundary's own
-- listing, because the value crossed a pure adapter in between and a removal is
-- not the place to assume provenance.
removeProductionMember
  :: RetainedArtifactStore authority -> FilePath -> IO (Either Text ())
removeProductionMember store relativePath
  | not (isStoreRelativePath relativePath) =
      pure
        ( Left
            ( "refused to collect `"
                <> Text.pack relativePath
                <> "`: not a normalized store-relative location"
            )
        )
  | otherwise = do
      removed <-
        try (removeFile (retainedArtifactStorePath store </> relativePath))
          :: IO (Either IOException ())
      pure $ case removed of
        Left err
          | isDoesNotExistError err -> Right ()
          | otherwise -> Left (boundedDetail (Text.pack (show err)))
        Right () -> Right ()

isStoreRelativePath :: FilePath -> Bool
isStoreRelativePath path = case path of
  [] -> False
  '/' : _ -> False
  _ -> all usable (splitOnSlash path)
 where
  usable segment = not (null segment) && segment /= "." && segment /= ".."

splitOnSlash :: FilePath -> [String]
splitOnSlash path = case break (== '/') path of
  (segment, []) -> [segment]
  (segment, _ : remaining) -> segment : splitOnSlash remaining

boundedDetail :: Text -> Text
boundedDetail detail
  | Text.length detail <= maximumDetailCharacters = detail
  | otherwise = Text.take maximumDetailCharacters detail <> "..."

maximumDetailCharacters :: Int
maximumDetailCharacters = 2048

-- ---------------------------------------------------------------------------
-- Read-back
-- ---------------------------------------------------------------------------

-- | One way a re-observed store still diverges from the inventory.
data RetainedArtifactCustodyResidue
  = RetainedArtifactMissing !RetainedArtifactKind !FilePath
  | RetainedArtifactCorrupt !RetainedArtifactKind !FilePath !RetainedArtifactUnusable
  | RetainedArtifactUnreferenced !FilePath
  deriving (Eq, Show)

renderRetainedArtifactCustodyResidue :: RetainedArtifactCustodyResidue -> String
renderRetainedArtifactCustodyResidue = \case
  RetainedArtifactMissing kind path ->
    "retained artifact `"
      ++ retainedArtifactKindText kind
      ++ "` is absent at "
      ++ path
  RetainedArtifactCorrupt kind path unusable ->
    "retained artifact `"
      ++ retainedArtifactKindText kind
      ++ "` at "
      ++ path
      ++ " does not match its pinned digest: "
      ++ renderRetainedArtifactUnusable unusable
  RetainedArtifactUnreferenced path ->
    "store member " ++ path ++ " is named by no inventory entry"

-- | The convergence verdict over a fresh observation.
data RetainedArtifactCustodyConvergence
  = -- | Exactly the inventory's members are present, each matching its pinned
    -- digest, and nothing else is under the store.
    RetainedArtifactCustodyConverged
  | RetainedArtifactCustodyDiverged !(NonEmpty RetainedArtifactCustodyResidue)
  | -- | The store could not be listed.  An unobservable store closes nothing;
    -- it is neither converged nor a specific divergence.
    RetainedArtifactCustodyUnverifiable !Text
  deriving (Eq, Show)

-- | Decide convergence from the inventory and a fresh observation alone.
--
-- The applied steps are deliberately not an input.  A successful delivery
-- response is not evidence that the retained store now holds the bytes, and
-- reading convergence out of the responses is exactly the class of defect that
-- an independent read-back exists to exclude.
retainedArtifactCustodyReadBack
  :: RetainedArtifactInventory
  -> RetainedArtifactStoreObservation
  -> RetainedArtifactCustodyConvergence
retainedArtifactCustodyReadBack inventory = \case
  RetainedArtifactStoreUnobservable detail ->
    RetainedArtifactCustodyUnverifiable detail
  RetainedArtifactStoreMembers members ->
    case NonEmpty.nonEmpty (entryResidue members ++ unreferencedResidue members) of
      Nothing -> RetainedArtifactCustodyConverged
      Just residue -> RetainedArtifactCustodyDiverged residue
 where
  refs =
    [ ref
    | kind <- retainedArtifactInventoryKinds inventory
    , Just ref <- [lookupRetainedArtifact kind inventory]
    ]

  entryResidue members =
    [ residue
    | ref <- refs
    , let path = retainedArtifactRefRelativePath ref
    , residue <-
        case lookup path [(retainedArtifactMemberRelativePath m, retainedArtifactMemberDigest m) | m <- members] of
          Nothing -> [RetainedArtifactMissing (retainedArtifactRefKind ref) path]
          Just (RetainedArtifactMemberUnreadable detail) ->
            [ RetainedArtifactCorrupt
                (retainedArtifactRefKind ref)
                path
                (RetainedArtifactDigestUnreadable detail)
            ]
          Just (RetainedArtifactMemberDigested observed)
            | observed == Text.pack (retainedArtifactRefDigest ref) -> []
            | otherwise ->
                [ RetainedArtifactCorrupt
                    (retainedArtifactRefKind ref)
                    path
                    (RetainedArtifactDigestMismatch observed)
                ]
    ]

  unreferencedResidue members =
    [ RetainedArtifactUnreferenced path
    | path <- sort (fmap retainedArtifactMemberRelativePath members)
    , path `notElem` fmap retainedArtifactRefRelativePath refs
    ]

-- ---------------------------------------------------------------------------
-- Repair readiness
-- ---------------------------------------------------------------------------

-- | Whether a rendered repair may start.
--
-- An inventory entry is a /declaration/ that bytes are retained, and a repair
-- plan is rendered from that declaration alone.  Nothing between the two
-- observes the store, so a plan can name an installer that is not on disk and
-- fail at the moment the substrate is already absent — which is the one moment
-- the recovery closure exists for.  This is the observation that closes the
-- gap: the plan is checked against a listing before it runs, not trusted
-- because it validated.
data RetainedArtifactRepairReadiness
  = -- | Every artifact the plan names is present and matches its pinned
    -- digest.
    RetainedArtifactRepairReady
  | RetainedArtifactRepairUnready !(NonEmpty RetainedArtifactCustodyResidue)
  | -- | The store could not be listed.  A repair does not start against an
    -- unread store; an unobservable one is neither ready nor a specific gap.
    RetainedArtifactRepairUnverifiable !Text
  deriving (Eq, Show)

renderRetainedArtifactRepairReadiness :: RetainedArtifactRepairReadiness -> String
renderRetainedArtifactRepairReadiness = \case
  RetainedArtifactRepairReady ->
    "every artifact the repair names is retained and matches its pinned digest"
  RetainedArtifactRepairUnready residue ->
    "the repair cannot start: "
      ++ commaSeparated
        (fmap renderRetainedArtifactCustodyResidue (NonEmpty.toList residue))
  RetainedArtifactRepairUnverifiable detail ->
    "the repair cannot start: the retained artifact store could not be listed: "
      ++ Text.unpack detail

-- | Exactly the artifacts a rendered repair reads, in plan order.
--
-- The set is derived from the plan's own steps rather than re-derived from the
-- closure and observed state, so a plan and its readiness check cannot disagree
-- about what the repair will touch.
retainedArtifactRepairPlanRefs :: OrdinaryTeardownRepairPlan -> [RetainedArtifactRef]
retainedArtifactRepairPlanRefs plan =
  concatMap refsOfStep (ordinaryTeardownRepairPlanSteps plan)
 where
  refsOfStep = \case
    RepairInstallSubstrateFromRetained refs -> NonEmpty.toList refs
    RepairLoadRetainedImage ref -> [ref]
    RepairStartSubstrateService -> []
    RepairAwaitSubstrateApi -> []
    RepairReconcileRecoveryPlatform _ -> []
    RepairReconcileRecoveryChart _ -> []

-- | Check a rendered repair against an observation of the store.
--
-- Only the artifacts the plan names are checked.  A store member the plan does
-- not read is not a reason to refuse a repair — membership is custody's
-- question, and answering it here would let an unrelated stray file block a
-- recovery.
retainedArtifactRepairReadiness
  :: OrdinaryTeardownRepairPlan
  -> RetainedArtifactStoreObservation
  -> RetainedArtifactRepairReadiness
retainedArtifactRepairReadiness plan = \case
  RetainedArtifactStoreUnobservable detail ->
    RetainedArtifactRepairUnverifiable detail
  RetainedArtifactStoreMembers members ->
    case NonEmpty.nonEmpty (concatMap (residueFor members) refs) of
      Nothing -> RetainedArtifactRepairReady
      Just residue -> RetainedArtifactRepairUnready residue
 where
  refs = retainedArtifactRepairPlanRefs plan

  residueFor members ref =
    case lookup path (fmap observedMember members) of
      Nothing -> [RetainedArtifactMissing kind path]
      Just (RetainedArtifactMemberUnreadable detail) ->
        [RetainedArtifactCorrupt kind path (RetainedArtifactDigestUnreadable detail)]
      Just (RetainedArtifactMemberDigested observed)
        | observed == Text.pack (retainedArtifactRefDigest ref) -> []
        | otherwise ->
            [RetainedArtifactCorrupt kind path (RetainedArtifactDigestMismatch observed)]
   where
    kind = retainedArtifactRefKind ref
    path = retainedArtifactRefRelativePath ref

  observedMember member =
    ( retainedArtifactMemberRelativePath member
    , retainedArtifactMemberDigest member
    )
