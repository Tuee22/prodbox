{-# LANGUAGE ScopedTypeVariables #-}

-- | Compose the parent kind operation, held image stage, and durable image
-- intent. This does not grant Docker admission or settle a prior daemon effect.
module Prodbox.Control.NodeImageOperation
  ( NodeImagePreparation (..)
  , NodeImageRecovery (..)
  , withNewNodeImagePreparation
  , withNewDaemonBoundNodeImagePreparation
  , NodeImageConnectionResult (..)
  , NodeImageConnectedObservation (..)
  , withConnectedNodeImageRecord
  , withNewConnectedNodeImagePreparation
  , NodeImageAttemptAction (..)
  , withNewConnectedNodeImageAttempt
  , NodeImageRecordedSubmission (..)
  , withNewConnectedNodeImageRecordedAttempt
  , withNewConnectedNodeImageRecordedFamilyAttempt
  , withRecoveredConnectedNodeImageRecordedFamilyAttempt
  , observeRecoveredNodeImagePreparation
  , observeRecoveredDaemonBoundNodeImagePreparation
  , NodeImageRecoveryPoint (..)
  , NodeImageIndependentObservation (..)
  , observeRecoveredConnectedNodeImage
  ) where

import Control.Exception (IOException, try)
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfo (..)
  , DockerConnectedInfoFailure (..)
  , DockerConnectedInfoResult
  , DockerImageSubmissionObservation (..)
  , DockerSession
  , withConnectedDockerInfo
  )
import Prodbox.Control.DockerIdentity (DockerDaemonObservation (..), observeDockerDaemon)
import Prodbox.Control.DockerPeer (DockerPeer (..), DockerPeerResult)
import Prodbox.Control.ImageIdObservation (ImageIdObservation)
import Prodbox.Control.KindDockerReadGate
  ( KindDockerReadResult (..)
  , newKindDockerReadGate
  , runConnectedKindDockerImageRead
  )
import Prodbox.Control.KindLease
  ( KindOperationOutcome
  , withNewKindOperation
  , withNewKindFamilyOperation
  , withRecoveredKindOperation
  )
import Prodbox.Control.KindIntent (KindIntentObservation (KindIntentMatches), observeKindOwnerFamilyIntent)
import Prodbox.Control.NodeArchive
  ( InspectedArchiveResult
  , VerifiedNodeArchive (..)
  )
import Prodbox.Control.NodeArchiveStage (StagedNodeResult, withStagedNodeArchive)
import Prodbox.Control.NodeImageIntent
  ( NodeImageAttemptObservation (..)
  , NodeImageAttemptWrite (..)
  , NodeImageIntent
  , NodeImageIntentObservation (..)
  , NodeImageIntentWrite (..)
  , NodeImageResultObservation (..)
  , NodeImageResultWrite
  , bindNodeImageIntent
  , mkNodeImageIntent
  , observeNodeImageAttempt
  , observeNodeImageIntent
  , observeNodeImageResult
  , observeRecordedNodeImageAttempt
  , observeRecordedNodeImageIntent
  , observeRecordedNodeImageResult
  , recordNodeImageAttempt
  , recordNodeImageIntent
  , recordNodeImageResult
  )
import Prodbox.Control.Status (observeImageId)
import System.Posix.Types (Fd)

data NodeImagePreparation value
  = NodeImagePreparationInvalid
  | NodeImagePreparationDaemonRefused !DockerDaemonObservation
  | NodeImagePreparationRecordRefused !NodeImageIntentWrite
  | NodeImagePreparationChanged
  | NodeImagePreparationCompleted !value
  | NodeImagePreparationChangedAfter !value
  deriving (Eq, Show)

data NodeImageRecovery
  = NodeImageRecoveryInvalid
  | NodeImageRecoveryDaemonRefused !DockerDaemonObservation
  | NodeImageRecoveryObserved !NodeImageIntentObservation
  deriving (Eq, Show)

data NodeImageConnectionResult value
  = NodeImageConnectionInvalid
  | NodeImageConnectionRecordRefused !NodeImageIntentObservation
  | NodeImageConnectionReady !value
  | NodeImageConnectionChangedAfter !value
  deriving (Eq, Show)

data NodeImageConnectedObservation value
  = NodeImageConnectedPlanInvalid
  | NodeImageConnectedObserved
      !(DockerPeerResult (DockerConnectedInfoResult (NodeImageConnectionResult value)))
  deriving (Eq, Show)

-- The two marker samples bracket the image read but are not atomic with it.
-- None of these observations settles a prior daemon worker or permits retry.
data NodeImageIndependentObservation
  = NodeImageIndependentUnobservable
  | NodeImageIndependentObserved !ImageIdObservation
  | NodeImageIndependentChanged !ImageIdObservation
  deriving (Eq, Show)

data NodeImageRecoveryPoint = NodeImageRecoveryPoint
  { recoveryImageId :: !String
  , recoveryAttemptBefore :: !NodeImageAttemptObservation
  , recoveryRecordedResult :: !NodeImageResultObservation
  , recoveryImageObservation :: !(Either DockerConnectedInfoFailure ImageIdObservation)
  , recoveryIndependentImage :: !NodeImageIndependentObservation
  , recoveryAttemptAfter :: !NodeImageAttemptObservation
  }
  deriving (Eq, Show)

-- | Regenerate the staged archive under the retained operation and compare it
-- with the intent on a held daemon connection. Read the marker on either side
-- of one exact image-ID query. This is diagnostic only: no absent result,
-- effect permission, daemon authentication, retry or settlement is inferred.
observeRecoveredConnectedNodeImage
  :: BootstrapProjection
  -> String
  -> IO
       ( KindOperationOutcome
           (InspectedArchiveResult (StagedNodeResult (NodeImageConnectedObservation NodeImageRecoveryPoint)))
       )
observeRecoveredConnectedNodeImage bootstrap operation =
  withRecoveredKindOperation bootstrap operation $ \operationStable ->
    withStagedNodeArchive bootstrap $ \verified digest size _ stageStable -> do
      let stable = (&&) <$> operationStable <*> stageStable
      case mkNodeImageIntent operation (nodeManifestDigest verified) (nodeConfigDigest verified) digest size of
        Nothing -> pure NodeImageConnectedPlanInvalid
        Just intent ->
          NodeImageConnectedObserved
            <$> withConnectedNodeImageRecord bootstrap intent stable (sample verified)
 where
  sample verified session stable = do
    before <- observeRecordedNodeImageAttempt bootstrap operation
    recorded <- observeRecordedNodeImageResult bootstrap operation
    ready <- stable
    if not ready
      then
        pure
          ( NodeImageRecoveryPoint
              (nodeConfigDigest verified)
              before
              recorded
              (Left DockerConnectedInfoChanged)
              NodeImageIndependentUnobservable
              NodeImageAttemptUnobservable
          )
      else do
        gate <- newKindDockerReadGate (bootstrapScope bootstrap) (nodeConfigDigest verified)
        image <- case gate of
          Nothing -> pure (Left DockerConnectedInfoInvalid)
          Just admittedReads -> do
            observed <-
              runConnectedKindDockerImageRead
                admittedReads
                session
                ["inspect", "--type=image", nodeConfigDigest verified]
            pure $ case observed of
              KindDockerReadRefused -> Left DockerConnectedInfoInvalid
              KindDockerReadFailed failure -> Left failure
              KindDockerReadCompleted value -> Right value
        independent <- observeIndependentImage bootstrap operation (nodeConfigDigest verified) stable
        after <- observeRecordedNodeImageAttempt bootstrap operation
        pure (NodeImageRecoveryPoint (nodeConfigDigest verified) before recorded image independent after)

-- The separate Docker CLI is a second client of the selected daemon, not
-- authentication of that daemon or proof that a prior worker has stopped.
observeIndependentImage
  :: BootstrapProjection -> String -> String -> IO Bool -> IO NodeImageIndependentObservation
observeIndependentImage bootstrap operation identifier stable = do
  recorded <- observeRecordedNodeImageIntent bootstrap operation
  first <- observeDockerDaemon socket
  ready <- stable
  if not ready || recorded /= NodeImageIntentBound first || not (isObserved first)
    then pure NodeImageIndependentUnobservable
    else do
      image <- observeImageId socket identifier
      lastDaemon <- observeDockerDaemon socket
      after <- try stable
      pure $ case after of
        Right True | first == lastDaemon -> NodeImageIndependentObserved image
        (_ :: Either IOException Bool) -> NodeImageIndependentChanged image
 where
  socket = bootstrapRuntimeSocket bootstrap
  isObserved DockerDaemonObserved {} = True
  isObserved _ = False

observeOptionalDaemon :: Bool -> FilePath -> IO (Maybe DockerDaemonObservation)
observeOptionalDaemon False _ = pure Nothing
observeOptionalDaemon True socket = Just <$> observeDockerDaemon socket

-- | Compare the recorded image intent with the daemon ID and socket identity
-- observed on the borrowed connection. The caller holds the parent lease and
-- supplies its recheck. Matching does not authorize an effect, authenticate
-- the daemon, or settle any earlier daemon worker.
withConnectedNodeImageRecord
  :: BootstrapProjection
  -> NodeImageIntent
  -> IO Bool
  -> (DockerSession -> IO Bool -> IO value)
  -> IO (DockerPeerResult (DockerConnectedInfoResult (NodeImageConnectionResult value)))
withConnectedNodeImageRecord bootstrap intent stable action =
  withConnectedNodeImageRecordBound bootstrap intent stable (\_ -> action)

withConnectedNodeImageRecordBound
  :: BootstrapProjection
  -> NodeImageIntent
  -> IO Bool
  -> (NodeImageIntent -> DockerSession -> IO Bool -> IO value)
  -> IO (DockerPeerResult (DockerConnectedInfoResult (NodeImageConnectionResult value)))
withConnectedNodeImageRecordBound bootstrap intent stable action =
  withConnectedDockerInfo 180000000 (bootstrapRuntimeSocket bootstrap) inspect
 where
  inspect session (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) peerStable = do
    let recheck = (&&) <$> stable <*> peerStable
    case bindNodeImageIntent intent (DockerDaemonObserved identifier identity) of
      Nothing -> pure NodeImageConnectionInvalid
      Just bound -> do
        observed <- observeNodeImageIntent bootstrap bound recheck
        if observed /= NodeImageIntentMatches
          then pure (NodeImageConnectionRecordRefused observed)
          else do
            let recordStable = (== NodeImageIntentMatches) <$> observeNodeImageIntent bootstrap bound recheck
            value <- action bound session recordStable
            after <- try recordStable
            pure $ case after of
              Right True -> NodeImageConnectionReady value
              (_ :: Either IOException Bool) -> NodeImageConnectionChangedAfter value

-- | Hold the verified stage, recorded operation and observed connection
-- together for a callback. No Docker mutation is admitted by this boundary.
withNewConnectedNodeImagePreparation
  :: BootstrapProjection
  -> String
  -> (VerifiedNodeArchive -> String -> Integer -> Fd -> DockerSession -> IO Bool -> IO value)
  -> IO
       ( KindOperationOutcome
           ( InspectedArchiveResult
               (StagedNodeResult (NodeImagePreparation (NodeImageConnectedObservation value)))
           )
       )
withNewConnectedNodeImagePreparation bootstrap operation action =
  withNewDaemonBoundNodeImagePreparation bootstrap operation prepare
 where
  prepare verified digest size descriptor stable =
    case mkNodeImageIntent operation (nodeManifestDigest verified) (nodeConfigDigest verified) digest size of
      Nothing -> pure NodeImageConnectedPlanInvalid
      Just intent ->
        NodeImageConnectedObserved
          <$> withConnectedNodeImageRecord bootstrap intent stable (action verified digest size descriptor)

data NodeImageAttemptAction value
  = NodeImageAttemptActionRefused !NodeImageAttemptWrite
  | NodeImageAttemptActionResultRefused !NodeImageResultObservation
  | NodeImageAttemptActionChanged
  | NodeImageAttemptActionReturned !value
  | NodeImageAttemptActionChangedAfter !value
  deriving (Eq, Show)

-- | Write the attempt marker before entering the callback and never enter it
-- for an existing or incomplete marker. The callback still requires separate
-- admission and must settle or retain any uncertain daemon effect. This is not
-- a public load command or authority to retry an interrupted operation.
withNewConnectedNodeImageAttempt
  :: BootstrapProjection
  -> String
  -> (VerifiedNodeArchive -> String -> Integer -> Fd -> DockerSession -> IO Bool -> IO value)
  -> IO
       ( KindOperationOutcome
           ( InspectedArchiveResult
               ( StagedNodeResult
                   (NodeImagePreparation (NodeImageConnectedObservation (NodeImageAttemptAction value)))
               )
           )
       )
withNewConnectedNodeImageAttempt bootstrap operation action =
  withConnectedNodeImageAttemptBound False False id bootstrap operation (\_ -> action)

data NodeImageRecordedSubmission = NodeImageRecordedSubmission
  { recordedSubmission :: !DockerImageSubmissionObservation
  , recordedSubmissionResult :: !NodeImageResultWrite
  }
  deriving (Eq, Show)

-- | Persist the transport outcome after the caller's submission callback.
-- The outcome and any record failure remain separate. Admission and daemon
-- worker settlement must be established by the caller; no retry is implied.
withNewConnectedNodeImageRecordedAttempt
  :: BootstrapProjection
  -> String
  -> ( VerifiedNodeArchive
       -> String
       -> Integer
       -> Fd
       -> DockerSession
       -> IO Bool
       -> IO DockerImageSubmissionObservation
     )
  -> IO
       ( KindOperationOutcome
           ( InspectedArchiveResult
               ( StagedNodeResult
                   ( NodeImagePreparation
                       (NodeImageConnectedObservation (NodeImageAttemptAction NodeImageRecordedSubmission))
                   )
               )
           )
       )
withNewConnectedNodeImageRecordedAttempt = withNewConnectedNodeImageRecordedAttemptFor False

-- The family variant makes its protocol selection in the initial exclusive
-- operation intent, before the image load or any subsequent effect.
withNewConnectedNodeImageRecordedFamilyAttempt
  :: BootstrapProjection -> String
  -> (VerifiedNodeArchive -> String -> Integer -> Fd -> DockerSession -> IO Bool -> IO DockerImageSubmissionObservation)
  -> IO (KindOperationOutcome (InspectedArchiveResult (StagedNodeResult
       (NodeImagePreparation (NodeImageConnectedObservation (NodeImageAttemptAction NodeImageRecordedSubmission))))))
withNewConnectedNodeImageRecordedFamilyAttempt = withNewConnectedNodeImageRecordedAttemptFor True

withNewConnectedNodeImageRecordedAttemptFor
  :: Bool -> BootstrapProjection -> String
  -> (VerifiedNodeArchive -> String -> Integer -> Fd -> DockerSession -> IO Bool -> IO DockerImageSubmissionObservation)
  -> IO (KindOperationOutcome (InspectedArchiveResult (StagedNodeResult
       (NodeImagePreparation (NodeImageConnectedObservation (NodeImageAttemptAction NodeImageRecordedSubmission))))))
withNewConnectedNodeImageRecordedAttemptFor family bootstrap operation action =
  withConnectedNodeImageAttemptBound family False id bootstrap operation $ \bound verified digest size descriptor session stable -> do
    outcome <- action verified digest size descriptor session stable
    written <- recordNodeImageResult bootstrap bound (submissionTransport outcome) stable
    pure (NodeImageRecordedSubmission outcome written)

-- The operation and family owner already exist when a managed controller
-- starts prerequisites. The admission recheck is borrowed across staging,
-- the image attempt, the daemon effect and its retained result.
withRecoveredConnectedNodeImageRecordedFamilyAttempt
  :: BootstrapProjection -> String -> (IO Bool -> IO Bool)
  -> (VerifiedNodeArchive -> String -> Integer -> Fd -> DockerSession -> IO Bool -> IO DockerImageSubmissionObservation)
  -> IO (KindOperationOutcome (InspectedArchiveResult (StagedNodeResult
       (NodeImagePreparation (NodeImageConnectedObservation (NodeImageAttemptAction NodeImageRecordedSubmission))))))
withRecoveredConnectedNodeImageRecordedFamilyAttempt bootstrap operation admission action =
  withConnectedNodeImageAttemptBound True True admission bootstrap operation $ \bound verified digest size descriptor session stable -> do
    outcome <- action verified digest size descriptor session stable
    written <- recordNodeImageResult bootstrap bound (submissionTransport outcome) stable
    pure (NodeImageRecordedSubmission outcome written)

withConnectedNodeImageAttemptBound
  :: Bool -> Bool -> (IO Bool -> IO Bool)
  -> BootstrapProjection
  -> String
  -> ( NodeImageIntent
       -> VerifiedNodeArchive
       -> String
       -> Integer
       -> Fd
       -> DockerSession
       -> IO Bool
       -> IO value
     )
  -> IO
       ( KindOperationOutcome
           ( InspectedArchiveResult
               ( StagedNodeResult
                   (NodeImagePreparation (NodeImageConnectedObservation (NodeImageAttemptAction value)))
               )
           )
       )
withConnectedNodeImageAttemptBound family recovered admission bootstrap operation action =
  withPreparation family recovered admission True bootstrap operation prepare
 where
  prepare verified digest size descriptor stable =
    case mkNodeImageIntent operation (nodeManifestDigest verified) (nodeConfigDigest verified) digest size of
      Nothing -> pure NodeImageConnectedPlanInvalid
      Just intent ->
        NodeImageConnectedObserved
          <$> withConnectedNodeImageRecordBound bootstrap intent stable (attempt verified digest size descriptor)
  attempt verified digest size descriptor bound session stable = do
    recorded <- recordNodeImageAttempt bootstrap bound stable
    case recorded of
      NodeImageAttemptRecorded -> do
        let markerStable = (== NodeImageAttemptMatches) <$> observeNodeImageAttempt bootstrap bound stable
        previous <- observeNodeImageResult bootstrap bound stable
        case previous of
          NodeImageResultMissing -> do
            ready <- markerStable
            if ready
              then do
                value <- action bound verified digest size descriptor session markerStable
                after <- try markerStable
                pure $ case after of
                  Right True -> NodeImageAttemptActionReturned value
                  (_ :: Either IOException Bool) -> NodeImageAttemptActionChangedAfter value
              else pure NodeImageAttemptActionChanged
          other -> pure (NodeImageAttemptActionResultRefused other)
      other -> pure (NodeImageAttemptActionRefused other)

-- | The callback borrows the staged descriptor while both operation and stage
-- are held. It must not launch a daemon effect without a separate admission,
-- daemon identity, bounded worker settlement and resource recovery protocol.
withNewNodeImagePreparation
  :: BootstrapProjection
  -> String
  -> (VerifiedNodeArchive -> String -> Integer -> Fd -> IO Bool -> IO value)
  -> IO (KindOperationOutcome (InspectedArchiveResult (StagedNodeResult (NodeImagePreparation value))))
withNewNodeImagePreparation bootstrap operation action =
  withNewPreparation False False bootstrap operation action

-- | Record a repeated daemon/socket observation alongside the held stage.
-- This is still not daemon authentication or an effect admission permit.
withNewDaemonBoundNodeImagePreparation
  :: BootstrapProjection
  -> String
  -> (VerifiedNodeArchive -> String -> Integer -> Fd -> IO Bool -> IO value)
  -> IO (KindOperationOutcome (InspectedArchiveResult (StagedNodeResult (NodeImagePreparation value))))
withNewDaemonBoundNodeImagePreparation bootstrap operation action =
  withNewPreparation False True bootstrap operation action

withNewPreparation
  :: Bool
  -> Bool
  -> BootstrapProjection
  -> String
  -> (VerifiedNodeArchive -> String -> Integer -> Fd -> IO Bool -> IO value)
  -> IO (KindOperationOutcome (InspectedArchiveResult (StagedNodeResult (NodeImagePreparation value))))
withNewPreparation family requireDaemon bootstrap operation action =
  withPreparation family False id requireDaemon bootstrap operation action

withPreparation
  :: Bool -> Bool -> (IO Bool -> IO Bool) -> Bool -> BootstrapProjection -> String
  -> (VerifiedNodeArchive -> String -> Integer -> Fd -> IO Bool -> IO value)
  -> IO (KindOperationOutcome (InspectedArchiveResult (StagedNodeResult (NodeImagePreparation value))))
withPreparation family recovered admission requireDaemon bootstrap operation action =
  (if recovered then withRecoveredKindOperation else if family then withNewKindFamilyOperation else withNewKindOperation) bootstrap operation $ \operationStable ->
    withStagedNodeArchive bootstrap (prepare operationStable)
 where
  prepare operationStable verified digest size descriptor stageStable = do
    daemon <- observeOptionalDaemon requireDaemon (bootstrapRuntimeSocket bootstrap)
    let localStable = do
          owner <- admission operationStable
          protocol <- if recovered then (== KindIntentMatches operation) <$> observeKindOwnerFamilyIntent bootstrap else pure True
          stage <- stageStable
          pure (owner && protocol && stage)
        stable = do
          local <- localStable
          if not local
            then pure False
            else case daemon of
              Nothing -> pure True
              Just expected -> (== expected) <$> observeDockerDaemon (bootstrapRuntimeSocket bootstrap)
        base = mkNodeImageIntent operation (nodeManifestDigest verified) (nodeConfigDigest verified) digest size
    case daemon of
      Just failure | not (isObserved failure) -> pure (NodeImagePreparationDaemonRefused failure)
      _ -> case selectIntent base daemon of
        Nothing -> pure NodeImagePreparationInvalid
        Just intent -> do
          recorded <- recordNodeImageIntent bootstrap intent stable
          if recorded /= NodeImageIntentRecorded
            then pure (NodeImagePreparationRecordRefused recorded)
            else do
              before <- stable
              if not before
                then pure NodeImagePreparationChanged
                else do
                  result <- action verified digest size descriptor stable
                  after <- try stable
                  pure $ case after of
                    Right True -> NodeImagePreparationCompleted result
                    (_ :: Either IOException Bool) -> NodeImagePreparationChangedAfter result
  selectIntent base Nothing = base
  selectIntent base (Just observed) = base >>= (`bindNodeImageIntent` observed)
  isObserved DockerDaemonObserved {} = True
  isObserved _ = False

-- | Rebuild and compare the stage with the retained record under the parent
-- lease. This observation does not settle an earlier worker or authorize a
-- retry, image deletion, or any other daemon effect.
observeRecoveredNodeImagePreparation
  :: BootstrapProjection
  -> String
  -> IO (KindOperationOutcome (InspectedArchiveResult (StagedNodeResult NodeImageRecovery)))
observeRecoveredNodeImagePreparation bootstrap operation =
  observeRecovery False bootstrap operation

-- | Compare a regenerated stage and the current repeated daemon observation
-- with the bound record. It does not settle a previously submitted effect.
observeRecoveredDaemonBoundNodeImagePreparation
  :: BootstrapProjection
  -> String
  -> IO (KindOperationOutcome (InspectedArchiveResult (StagedNodeResult NodeImageRecovery)))
observeRecoveredDaemonBoundNodeImagePreparation bootstrap operation =
  observeRecovery True bootstrap operation

observeRecovery
  :: Bool
  -> BootstrapProjection
  -> String
  -> IO (KindOperationOutcome (InspectedArchiveResult (StagedNodeResult NodeImageRecovery)))
observeRecovery requireDaemon bootstrap operation =
  withRecoveredKindOperation bootstrap operation $ \operationStable ->
    withStagedNodeArchive bootstrap (observe operationStable)
 where
  observe operationStable verified digest size _ stageStable = do
    daemon <- observeOptionalDaemon requireDaemon (bootstrapRuntimeSocket bootstrap)
    let localStable = (&&) <$> operationStable <*> stageStable
        stable = do
          local <- localStable
          if not local
            then pure False
            else case daemon of
              Nothing -> pure True
              Just expected -> (== expected) <$> observeDockerDaemon (bootstrapRuntimeSocket bootstrap)
        base = mkNodeImageIntent operation (nodeManifestDigest verified) (nodeConfigDigest verified) digest size
    case daemon of
      Just failure | not (isObserved failure) -> pure (NodeImageRecoveryDaemonRefused failure)
      _ -> case selectIntent base daemon of
        Nothing -> pure NodeImageRecoveryInvalid
        Just intent -> NodeImageRecoveryObserved <$> observeNodeImageIntent bootstrap intent stable
  selectIntent base Nothing = base
  selectIntent base (Just observed) = base >>= (`bindNodeImageIntent` observed)
  isObserved DockerDaemonObserved {} = True
  isObserved _ = False
