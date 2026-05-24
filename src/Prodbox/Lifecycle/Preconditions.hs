{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.11: composable precondition algebra for destructive
-- lifecycle commands.
--
-- Each named 'Precondition' wraps one 'discover' IO action and
-- returns @IO (Either StructuredError ())@. Predicates compose with
-- 'checkAll'. Every command in @{prodbox rke2 delete, prodbox aws
-- teardown, prodbox pulumi <stack>-destroy, prodbox nuke}@ opens
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
  , checkAll
  , noLeftoverDnsBootstrapRecords
  , noLiveClusterTaggedAws
  , noLiveOperationalIamUser
  , noLivePerRunPulumiStacks
  , noLiveLongLivedPulumiStacks
  , noUndrainedK8sAwsResources
  , renderPreconditionFailures
  )
where

import Data.List (intercalate)
import Data.Text qualified as Text
import Prodbox.Aws
  ( operationalBootstrapDnsRecordExists
  , operationalIamUserExists
  , prodboxIamUserName
  )
import Prodbox.Infra.AwsEksSubzoneStack (awsEksSubzoneStackResidueStatus)
import Prodbox.Infra.AwsEksTestStack (awsEksTestStackResidueStatus)
import Prodbox.Infra.AwsSesStack (awsSesStackResidueStatus)
import Prodbox.Infra.AwsTestStack (awsTestStackResidueStatus)
import Prodbox.Lifecycle.K8sDrain
  ( K8sDrainEnv
  , collectSurvivors
  )
import Prodbox.Lifecycle.ResidueStatus qualified as ResidueStatus
import Prodbox.Lifecycle.TagSweep
  ( TagSweepInput (..)
  , TaggedResource (..)
  , discoverClusterTaggedAwsResources
  , renderTagSweepRefusal
  )
import Prodbox.Settings (Credentials)

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

-- | Compose preconditions. Discovery runs sequentially (so subsequent
-- discoveries see the side effects of earlier discoveries, which
-- matters when an earlier discover modifies the cluster). Returns
-- @Right ()@ when every precondition succeeds, or @Left errors@
-- with every failed precondition's structured error.
checkAll :: [Precondition] -> IO (Either [StructuredError] ())
checkAll preconditions = do
  results <- mapM preconditionCheck preconditions
  let failures = [err | Left err <- results]
  pure $ case failures of
    [] -> Right ()
    _ -> Left failures

-- | Render a list of structured precondition failures into a
-- multi-line stderr block. The single-failure rendering is identical
-- to the doctrine's `--destroy-pulumi-residue` refusal; the multi-
-- failure rendering stacks each narrative block separated by blank
-- lines.
renderPreconditionFailures :: [StructuredError] -> String
renderPreconditionFailures failures =
  intercalate "\n" (map errorNarrative failures)

-- | Sprint 7.6 stack inventory generalized to a 'Precondition'.
-- @aws-eks@, @aws-eks-subzone@, and @aws-test@ are the per-run
-- substrate stacks per @DEVELOPMENT_PLAN/substrates.md → Resource
-- Lifecycle Classes@. @aws-ses@ is explicitly excluded because its
-- state lives outside the cluster after Sprint 4.10's migration.
noLivePerRunPulumiStacks :: FilePath -> Precondition
noLivePerRunPulumiStacks repoRoot =
  Precondition
    { preconditionLabel = "noLivePerRunPulumiStacks"
    , preconditionCheck = do
        eksStatus <- awsEksTestStackResidueStatus repoRoot
        subzoneStatus <- awsEksSubzoneStackResidueStatus repoRoot
        testStatus <- awsTestStackResidueStatus repoRoot
        let live =
              [ ("aws-eks", "prodbox pulumi eks-destroy --yes")
              | ResidueStatus.isResiduePresentOrUnknownPerRun eksStatus
              ]
                ++ [ ("aws-eks-subzone", "prodbox pulumi aws-subzone-destroy --yes")
                   | ResidueStatus.isResiduePresentOrUnknownPerRun subzoneStatus
                   ]
                ++ [ ("aws-test", "prodbox pulumi test-destroy --yes")
                   | ResidueStatus.isResiduePresentOrUnknownPerRun testStatus
                   ]
        pure $ case live of
          [] -> Right ()
          _ ->
            Left
              StructuredError
                { errorPreconditionLabel = "noLivePerRunPulumiStacks"
                , errorSummaryLine =
                    "Per-run Pulumi-managed AWS stacks still have live resources."
                , errorOffendingItems = live
                , errorNarrative = renderPerRunRefusal live
                }
    }

renderPerRunRefusal :: [(String, String)] -> String
renderPerRunRefusal live =
  unlines
    ( [ "Refused: per-run Pulumi-managed AWS stacks still have live resources."
      , ""
      , "Run the canonical destroy command for each stack below first:"
      , ""
      ]
        ++ map (\(name, cmd) -> "  - " ++ name ++ " → " ++ cmd) live
        ++ [ ""
           , "Or re-run with `--cascade` to orchestrate the full teardown"
           , "(K8s drain → per-run Pulumi destroys → uninstall → postflight"
           , "tag sweep) as one atomic operator action."
           ]
    )

-- | Long-lived cross-substrate shared Pulumi stacks. Today this is
-- @aws-ses@. @prodbox aws teardown@ refuses on these; @prodbox nuke@
-- destroys them instead of refusing.
noLiveLongLivedPulumiStacks :: FilePath -> Precondition
noLiveLongLivedPulumiStacks repoRoot =
  Precondition
    { preconditionLabel = "noLiveLongLivedPulumiStacks"
    , preconditionCheck = do
        sesStatus <- awsSesStackResidueStatus repoRoot
        let live =
              [ ("aws-ses", "prodbox pulumi aws-ses-destroy --yes")
              | ResidueStatus.isResiduePresentOrUnknownLongLived sesStatus
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

-- | Sprint 4.11: K8s LoadBalancer Services or Ingresses still exist
-- (read-only listing variant of `drainAwsAffectingK8sResources`).
-- Used by `prodbox aws teardown` and `prodbox nuke` to refuse when
-- the cluster still owns AWS-affecting resources whose deletion
-- would orphan AWS objects (ALBs, EBS volumes, DNS01 records).
noUndrainedK8sAwsResources :: K8sDrainEnv -> Precondition
noUndrainedK8sAwsResources env =
  Precondition
    { preconditionLabel = "noUndrainedK8sAwsResources"
    , preconditionCheck = do
        result <- collectSurvivors env
        case result of
          Left err ->
            pure
              ( Left
                  StructuredError
                    { errorPreconditionLabel = "noUndrainedK8sAwsResources"
                    , errorSummaryLine = "K8s drain survivors probe failed: " ++ err
                    , errorOffendingItems = []
                    , errorNarrative =
                        "Could not inspect surviving K8s LoadBalancer Services or Ingresses: "
                          ++ err
                          ++ "\n"
                    }
              )
          Right [] -> pure (Right ())
          Right survivors ->
            pure
              ( Left
                  StructuredError
                    { errorPreconditionLabel = "noUndrainedK8sAwsResources"
                    , errorSummaryLine =
                        "K8s LoadBalancer Services or Ingresses still exist on the cluster."
                    , errorOffendingItems =
                        [ ( s
                          , "kubectl delete --wait=false the resource and confirm AWS-side unwind"
                          )
                        | s <- survivors
                        ]
                    , errorNarrative = renderUndrainedK8sRefusal survivors
                    }
              )
    }

renderUndrainedK8sRefusal :: [String] -> String
renderUndrainedK8sRefusal survivors =
  unlines
    ( [ "Refused: K8s LoadBalancer Services or Ingresses still exist."
      , ""
      , "Deleting the cluster now would orphan their AWS-side resources"
      , "(ALBs, target groups, cert-manager DNS01 records). Run"
      , "`prodbox rke2 delete --cascade` to drain them automatically,"
      , "or delete each manually before proceeding:"
      , ""
      ]
        ++ map (\survivor -> "  - " ++ survivor) survivors
    )

-- | Sprint 4.11: the dedicated operational @prodbox@ IAM user still
-- exists in AWS. Used by `prodbox nuke` to confirm `applyAwsTeardown`
-- actually deleted the user, and by any future operator command
-- that wants to refuse when the user is still present.
noLiveOperationalIamUser :: FilePath -> Credentials -> Precondition
noLiveOperationalIamUser repoRoot adminCredentials =
  Precondition
    { preconditionLabel = "noLiveOperationalIamUser"
    , preconditionCheck = do
        result <- operationalIamUserExists repoRoot adminCredentials
        case result of
          Left err ->
            pure
              ( Left
                  StructuredError
                    { errorPreconditionLabel = "noLiveOperationalIamUser"
                    , errorSummaryLine = "IAM `get-user` probe failed: " ++ err
                    , errorOffendingItems = []
                    , errorNarrative =
                        "Could not query AWS IAM for the operational `prodbox` user: "
                          ++ err
                          ++ "\n"
                    }
              )
          Right False -> pure (Right ())
          Right True ->
            pure
              ( Left
                  StructuredError
                    { errorPreconditionLabel = "noLiveOperationalIamUser"
                    , errorSummaryLine =
                        "Operational IAM user `"
                          ++ Text.unpack prodboxIamUserName
                          ++ "` still exists."
                    , errorOffendingItems =
                        [
                          ( Text.unpack prodboxIamUserName
                          , "prodbox aws teardown"
                          )
                        ]
                    , errorNarrative =
                        unlines
                          [ "Refused: the dedicated operational `"
                              ++ Text.unpack prodboxIamUserName
                              ++ "` IAM user still exists in AWS."
                          , ""
                          , "Run `prodbox aws teardown` to delete the user and its"
                          , "access keys before proceeding."
                          ]
                    }
              )
    }

-- | Sprint 4.11: the bootstrap DNS record `prodbox rke2 reconcile`
-- writes to the operator's Route 53 hosted zone still exists.
-- A non-empty result is a hard refusal for any operator action that
-- assumes a clean DNS surface.
noLeftoverDnsBootstrapRecords :: FilePath -> Credentials -> Precondition
noLeftoverDnsBootstrapRecords repoRoot adminCredentials =
  Precondition
    { preconditionLabel = "noLeftoverDnsBootstrapRecords"
    , preconditionCheck = do
        result <- operationalBootstrapDnsRecordExists repoRoot adminCredentials
        case result of
          Left err ->
            pure
              ( Left
                  StructuredError
                    { errorPreconditionLabel = "noLeftoverDnsBootstrapRecords"
                    , errorSummaryLine =
                        "Route 53 list-resource-record-sets probe failed: " ++ err
                    , errorOffendingItems = []
                    , errorNarrative =
                        "Could not query Route 53 for the bootstrap A record: "
                          ++ err
                          ++ "\n"
                    }
              )
          Right False -> pure (Right ())
          Right True ->
            pure
              ( Left
                  StructuredError
                    { errorPreconditionLabel = "noLeftoverDnsBootstrapRecords"
                    , errorSummaryLine =
                        "Bootstrap DNS A record still exists in the operator's Route 53 zone."
                    , errorOffendingItems =
                        [
                          ( "test.resolvefintech.com"
                          , "aws route53 change-resource-record-sets --change-batch DELETE …"
                          )
                        ]
                    , errorNarrative =
                        unlines
                          [ "Refused: the bootstrap A record `test.resolvefintech.com` still"
                          , "exists in the operator's Route 53 hosted zone."
                          , ""
                          , "Run `prodbox rke2 delete --cascade` (which removes it) before"
                          , "the next reprovision, or delete it manually via:"
                          , ""
                          , "  aws route53 change-resource-record-sets \\"
                          , "    --hosted-zone-id <ZONE_ID> \\"
                          , "    --change-batch <DELETE-A-record JSON>"
                          ]
                    }
              )
    }

-- | Sprint 4.11: AWS resources carrying a prodbox-owned or
-- cluster-owned tag still exist after the upstream destructive
-- command completed. Wraps 'discoverClusterTaggedAwsResources' from
-- @Prodbox.Lifecycle.TagSweep@. Used by @prodbox nuke@ step 4 and by
-- any future destructive command that has admin AWS credentials in
-- scope.
--
-- This predicate requires AWS read permission for
-- @resourcegroupstaggingapi:GetResources@; the operational @prodbox@
-- IAM user does NOT have this grant after the Sprint 7.5.c.v.d
-- policy compaction, so the predicate must be invoked with admin
-- credentials in the supplied environment.
noLiveClusterTaggedAws :: TagSweepInput -> Precondition
noLiveClusterTaggedAws input =
  Precondition
    { preconditionLabel = "noLiveClusterTaggedAws"
    , preconditionCheck = do
        result <- discoverClusterTaggedAwsResources input
        case result of
          Left err ->
            pure
              ( Left
                  StructuredError
                    { errorPreconditionLabel = "noLiveClusterTaggedAws"
                    , errorSummaryLine =
                        "AWS tag-sweep query failed: " ++ err
                    , errorOffendingItems = []
                    , errorNarrative =
                        "Postflight AWS tag sweep could not complete: "
                          ++ err
                          ++ "\n"
                    }
              )
          Right [] -> pure (Right ())
          Right resources ->
            pure
              ( Left
                  StructuredError
                    { errorPreconditionLabel = "noLiveClusterTaggedAws"
                    , errorSummaryLine =
                        "AWS resources carrying prodbox or cluster tags still exist."
                    , errorOffendingItems =
                        [ ( taggedResourceArn resource
                          , "aws resourcegroupstaggingapi untag-resources --resource-arn-list "
                              ++ taggedResourceArn resource
                          )
                        | resource <- resources
                        ]
                    , errorNarrative = renderTagSweepRefusal resources
                    }
              )
    }
