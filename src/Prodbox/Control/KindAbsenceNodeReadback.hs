{-# LANGUAGE ScopedTypeVariables #-}

-- | Independent inventory of a recorded node and its separate absence
-- control. A sample alone does not prove control ownership or settle workers.
module Prodbox.Control.KindAbsenceNodeReadback
  ( AbsenceNodeSample (..)
  , AbsenceNodeReadback (..)
  , parseAbsenceNodeSample
  , classifyAbsenceNodeReadback
  , observeAbsenceNode
  , observeAbsenceNodeUnderLease
  ) where

import Control.Exception (IOException, try)
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope (scopeKindName)
import Prodbox.Control.DockerIdentity
  ( DockerDaemonObservation (..)
  , observeDockerDaemon
  , readDocker
  )
import Prodbox.Control.ImageIdObservation (validImageId)
import Prodbox.Control.KindLease (KindOperationOutcome, withRecoveredKindOperation)
import Prodbox.Control.KindNodeCreateIntent
  ( KindAbsenceFootprintObservation (..)
  , KindAbsenceIdObservation (..)
  , KindAbsencePlan
  , kindAbsenceDaemon
  , kindAbsenceOperation
  , kindAbsenceTarget
  , recoverKindAbsenceControlId
  , recoverKindAbsenceFootprint
  )
import Prodbox.Control.KindNodeRemovalSampling
  ( NodeRemovalInventory (..)
  , parseNodeRemovalInventory
  )
import System.Timeout (timeout)

data AbsenceNodeSample = AbsenceNodeSample
  { absenceNodeInventory :: !NodeRemovalInventory
  , absenceControlInventory :: !NodeRemovalInventory
  }
  deriving (Eq, Show)

data AbsenceNodeReadback
  = AbsenceNodeRecordsUnconfirmed
  | AbsenceNodeUnobservable
  | AbsenceNodeChanged
  | AbsenceNodeSampled !AbsenceNodeSample
  deriving (Eq, Show)

-- The control has its own name and label; it is deliberately not a kind
-- cluster member. The same unfiltered inventory is used for both IDs.
parseAbsenceNodeSample
  :: String -> String -> String -> String -> String -> String -> String -> Maybe AbsenceNodeSample
parseAbsenceNodeSample target control allOutput nodeName nodeLabel controlName controlLabel = do
  if target == control
    || not (validImageId ("sha256:" ++ target))
    || not (validImageId ("sha256:" ++ control))
    then Nothing
    else pure ()
  node <- parseNodeRemovalInventory target allOutput nodeName nodeLabel
  positive <- parseNodeRemovalInventory control allOutput controlName controlLabel
  pure (AbsenceNodeSample node positive)

classifyAbsenceNodeReadback
  :: String
  -> DockerDaemonObservation
  -> DockerDaemonObservation
  -> Bool
  -> Maybe AbsenceNodeSample
  -> Maybe AbsenceNodeSample
  -> AbsenceNodeReadback
classifyAbsenceNodeReadback control before after stable first second =
  case (before, after, stable, first, second) of
    (DockerDaemonObserved _ _, DockerDaemonChanged, _, _, _) -> AbsenceNodeChanged
    (DockerDaemonObserved _ _, DockerDaemonObserved _ _, True, Just a, Just b)
      | before /= after || a /= b -> AbsenceNodeChanged
      | not (validImageId ("sha256:" ++ control)) -> AbsenceNodeUnobservable
      | nodeRemovalTargetListed node
          || not (null (nodeRemovalNameIds node))
          || not (null (nodeRemovalClusterIds node)) ->
          AbsenceNodeUnobservable
      | not (nodeRemovalTargetListed positive)
          || nodeRemovalNameIds positive /= [control]
          || nodeRemovalClusterIds positive /= [control] ->
          AbsenceNodeUnobservable
      | otherwise -> AbsenceNodeSampled a
     where
      node = absenceNodeInventory a
      positive = absenceControlInventory a
    _ -> AbsenceNodeUnobservable

-- The caller supplies its held family-retirement check; this observer takes
-- the operation lease and binds both samples to the recorded ID and footprint.
-- Inspect the control independently and compose this with the volume sample
-- before writing a sample marker or claiming anything about node absence.
observeAbsenceNode
  :: BootstrapProjection
  -> KindAbsencePlan
  -> (IO Bool -> IO Bool)
  -> IO (KindOperationOutcome AbsenceNodeReadback)
observeAbsenceNode bootstrap plan ownerStable =
  withRecoveredKindOperation bootstrap operation $ \lease -> do
    let stable = do
          before <- lease
          owner <- ownerStable lease
          after <- lease
          pure (before && owner && after)
    observeAbsenceNodeUnderLease bootstrap plan stable
 where
  operation = kindAbsenceOperation plan

-- The caller must hold the recovered operation lease and the family owner.
observeAbsenceNodeUnderLease
  :: BootstrapProjection -> KindAbsencePlan -> IO Bool -> IO AbsenceNodeReadback
observeAbsenceNodeUnderLease bootstrap plan heldStable = do
  observed <- timeout 60000000 (run heldStable)
  pure (maybe AbsenceNodeUnobservable id observed)
 where
  operation = kindAbsenceOperation plan
  expectedDaemon = kindAbsenceDaemon plan
  target = kindAbsenceTarget plan
  socket = bootstrapRuntimeSocket bootstrap
  cluster = scopeKindName (bootstrapScope bootstrap)
  run stable = do
    control <- recoverKindAbsenceControlId bootstrap plan stable
    case control of
      AbsenceIdObserved identifier -> do
        footprint <- recoverKindAbsenceFootprint bootstrap plan identifier stable
        case footprint of
          AbsenceFootprintObserved _ -> do
            before <- observeDockerDaemon socket
            first <- sample stable identifier
            second <- sample stable identifier
            after <- observeDockerDaemon socket
            final <- try stable
            let trusted =
                  before == expectedDaemon
                    && after == expectedDaemon
                    && either (const False) id (final :: Either IOException Bool)
            pure (classifyAbsenceNodeReadback identifier before after trusted first second)
          _ -> pure AbsenceNodeRecordsUnconfirmed
      _ -> pure AbsenceNodeRecordsUnconfirmed
  sample stable identifier = do
    allIds <- query stable []
    nodeName <- query stable ["--filter", "name=^/" ++ cluster ++ "-control-plane$"]
    nodeLabel <- query stable ["--filter", "label=io.x-k8s.kind.cluster=" ++ cluster]
    controlName <- query stable ["--filter", "name=^/" ++ cluster ++ "-absence-control$"]
    controlLabel <- query stable ["--filter", "label=io.prodbox.absence-control=" ++ operation]
    pure
      ( parseAbsenceNodeSample target identifier
          <$> allIds
          <*> nodeName
          <*> nodeLabel
          <*> controlName
          <*> controlLabel
          >>= id
      )
  query stable filters = do
    before <- try stable
    case (before :: Either IOException Bool) of
      Right True -> do
        output <- readDocker socket (["ps", "--all", "--no-trunc"] ++ filters ++ ["--format", "{{.ID}}"])
        after <- try stable
        pure $ case (after :: Either IOException Bool) of Right True -> output; _ -> Nothing
      _ -> pure Nothing
