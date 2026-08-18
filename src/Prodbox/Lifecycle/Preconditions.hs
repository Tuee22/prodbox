{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.11: composable precondition algebra for destructive
-- lifecycle commands.
--
-- Each named 'Precondition' wraps one 'discover' IO action and
-- returns @IO (Either StructuredError ())@. Predicates compose with
-- 'checkAll'. Every command in @{prodbox cluster delete, prodbox aws
-- teardown, prodbox aws stack <stack> destroy, prodbox nuke}@ opens
-- with @checkAll [...]@ over the appropriate set, per
-- @documents/engineering/lifecycle_reconciliation_doctrine.md § 5@.
--
-- The doctrine inventory of every named precondition lives in
-- @documents/engineering/lifecycle_reconciliation_doctrine.md § 4@;
-- when a new resource class needs a precondition, add one
-- @discover@ and one 'Precondition' here.
module Prodbox.Lifecycle.Preconditions
  ( StructuredError (..)
  , Precondition (..)
  , noLiveLongLivedPulumiStacks
  , noLiveLongLivedPulumiStacksPreflight
  )
where

import Prodbox.Lifecycle.LiveResidue
  ( queryAwsSesResidueStatus
  , queryPublicEdgeTlsResidueStatus
  )
import Prodbox.Lifecycle.ResidueStatus qualified as ResidueStatus

-- | Structured error reported when a 'Precondition' fails. Carries
-- the failing predicate's class label, a one-line summary, the
-- offending items by canonical-name + canonical-remedy-command, and
-- a longer narrative block suitable for direct rendering to stderr.
--
-- Held as plain fields (no Aeson dependency) so this module is
-- usable from any layer; the CLI boundary is responsible for any
-- machine-readable serialization.
data StructuredError = StructuredError
  { errorPreconditionLabel :: String
  -- ^ Stable class label (e.g. @noLivePerRunPulumiStacks@).
  , errorSummaryLine :: String
  -- ^ One-line human-readable summary.
  , errorOffendingItems :: [(String, String)]
  -- ^ @(item-name, canonical-remedy-command)@ pairs.
  , errorNarrative :: String
  -- ^ Multi-line narrative for stderr; ends with a final @\\n@.
  }
  deriving (Eq, Show)

-- | A composable precondition. The 'preconditionLabel' is a stable
-- class label (the doctrine inventory uses it as the precondition's
-- name); 'preconditionCheck' performs the discovery and returns the
-- structured error on failure or @Right ()@ on success.
data Precondition = Precondition
  { preconditionLabel :: String
  , preconditionCheck :: IO (Either StructuredError ())
  }

-- | Long-lived cross-substrate shared resources: the @aws-ses@ Pulumi
-- stack and (Sprint 4.24) the retained public-edge production TLS
-- certificate material in the long-lived @pulumi_state_backend@ bucket.
-- @prodbox aws teardown@ refuses on these; @prodbox nuke@ destroys them
-- instead of refusing (the certificate transitively, via the
-- whole-bucket destroy). Both are checked through the single
-- 'Prodbox.Lifecycle.ResidueStatus.residueBlocksTeardownGate'
-- soundness combinator, so an unreachable backend fails closed.
noLiveLongLivedPulumiStacks :: FilePath -> Precondition
noLiveLongLivedPulumiStacks repoRoot =
  Precondition
    { preconditionLabel = "noLiveLongLivedPulumiStacks"
    , preconditionCheck = do
        sesObservation <- queryAwsSesResidueStatus repoRoot
        certObservation <- queryPublicEdgeTlsResidueStatus repoRoot
        -- The gate decision is unchanged; what is new is that each answer now
        -- names the authority that gave it, so a refusal says which layer
        -- spoke rather than leaving the operator to infer it.
        let blocks observation =
              ResidueStatus.residueBlocksTeardownGate
                (ResidueStatus.residueObservationStatus observation)
            live =
              [ ("aws-ses", "prodbox aws stack aws-ses destroy --yes")
              | blocks sesObservation
              ]
                ++ [ ("public-edge-tls", "prodbox nuke")
                   | blocks certObservation
                   ]
        pure $ case live of
          [] -> Right ()
          _ ->
            Left
              StructuredError
                { errorPreconditionLabel = "noLiveLongLivedPulumiStacks"
                , errorSummaryLine =
                    "Long-lived cross-substrate shared Pulumi stacks still have live resources."
                , errorOffendingItems = live
                , errorNarrative = renderLongLivedRefusal live
                }
    }

-- | Sprint 4.26: adapt 'noLiveLongLivedPulumiStacks' to the
-- @FilePath -> IO (Either String ())@ shape the operator @prodbox aws
-- teardown@ preflight injects (it cannot import this module directly —
-- 'Prodbox.Lifecycle.Preconditions' imports 'Prodbox.Aws', so the wiring
-- is dependency-injected from 'Prodbox.Native', which can import both).
-- @Right ()@ when no long-lived stack blocks the teardown; @Left
-- narrative@ (the structured long-lived refusal) otherwise. This wires the
-- deferred Sprint 4.11 consolidation: @aws teardown@ now refuses on a live
-- long-lived stack ('aws-ses' OR the retained 'public-edge-tls'
-- certificate) the same way it refuses on per-run residue. The HARNESS
-- teardown path ('Prodbox.Aws.applyAwsTeardown' under
-- 'BypassAllResidueForHarnessRefresh') is unaffected — only the operator
-- preflight injects this, preserving Sprint 7.9's deliberate aws-ses
-- relaxation for the harness postflight.
noLiveLongLivedPulumiStacksPreflight :: FilePath -> IO (Either String ())
noLiveLongLivedPulumiStacksPreflight repoRoot = do
  result <- preconditionCheck (noLiveLongLivedPulumiStacks repoRoot)
  pure (either (Left . errorNarrative) Right result)

renderLongLivedRefusal :: [(String, String)] -> String
renderLongLivedRefusal live =
  unlines
    ( [ "Refused: long-lived cross-substrate shared Pulumi stacks still have"
      , "live resources."
      , ""
      , "Long-lived stacks are not part of `rke2 delete --cascade`'s scope (per"
      , "documents/engineering/lifecycle_reconciliation_doctrine.md § 7). Run the"
      , "canonical destroy command for each stack below first, or use"
      , "`prodbox nuke` for total teardown:"
      , ""
      ]
        ++ map (\(name, cmd) -> "  - " ++ name ++ " → " ++ cmd) live
    )
