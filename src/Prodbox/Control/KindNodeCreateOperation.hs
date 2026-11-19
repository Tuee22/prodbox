{-# LANGUAGE ScopedTypeVariables #-}

-- | Sequence one node create transport behind a retained proposal and
-- attempt. The caller must independently establish daemon authentication,
-- ownership, prerequisite settlement, admission and cleanup before effects.
module Prodbox.Control.KindNodeCreateOperation
  ( KindNodeCreateAction (..)
  , withNewConnectedKindNodeCreate
  , runKindNodeCreateOnSession
  , KindNodeCandidateAction (..)
  , withNewConnectedKindNodeCandidate
  , KindNodeStartAction (..)
  , withNewConnectedKindNodeStart
  , runKindNodeStartOnSession
  , KindNodeRunAction (..)
  , runKindNodeOnSession
  , KindNodeConfigAction (..)
  , runKindNodeConfigOnSession
  , KindNodeBroker
  , newKindNodeBroker
  , newKindNodeBrokerWithConfig
  , runKindNodeBrokerRequest
  , runKindNodeBrokerInput
  , closeKindNodeBroker
  , observeKindNodeBrokerResult
  , KindNodeConfigCandidateObservation (..)
  , observeKindNodeBrokerConfigCandidate
  , observeKindNodeBrokerConfigAction
  , serveKindNodeBroker
  , runBoundKindNodeWorker
  , KindNodeRemoveAction (..)
  , withNewConnectedKindNodeRemove
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (IOException, SomeException, mask, throwIO, try)
import Data.ByteString.Char8 qualified as Bytes
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope (scopeKindName)
import Prodbox.Config.KindPlan (KindNodeCreateInput (nodeCreateArguments, nodeCreateImageId))
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfo (..)
  , DockerConnectedInfoFailure
  , DockerConnectedInfoResult
  , DockerKindInfo (..)
  , DockerNodeConfigPath (..)
  , DockerNodeConfigPathObservation (..)
  , DockerNodeConfigReadback (..)
  , DockerNodeConfigWriteResult (..)
  , DockerNodeContainerCreateResult (..)
  , DockerNodeContainerObservation (..)
  , DockerNodeContainerRemoveResult
  , DockerNodeContainerStartResult (..)
  , DockerSession
  , createDockerSessionKindNode
  , inspectDockerSessionKindNode
  , observeDockerSessionKindNodeConfigPath
  , readDockerSessionKindInfo
  , readDockerSessionKindNodeAddresses
  , readDockerSessionKindNodeBootLine
  , readDockerSessionKindNodeConfig
  , readDockerSessionKindNodeVersion
  , removeDockerSessionKindNode
  , startDockerSessionKindNode
  , withConnectedDockerInfo
  , writeDockerSessionKindNodeConfig
  )
import Prodbox.Control.DockerIdentity (DockerDaemonObservation (DockerDaemonObserved))
import Prodbox.Control.DockerPeer (DockerPeer (..), DockerPeerResult)
import Prodbox.Control.KindDockerEndpoint
  ( KindDockerBrokerExit
  , KindDockerEndpointResult
  , KindDockerWorkerExit
  , runBoundKindDockerWorker
  , serveBoundKindDockerInputRequests
  )
import Prodbox.Control.KindDockerReadGate
  ( KindDockerReadGate
  , KindDockerReply (..)
  , closeKindDockerReadGate
  , newKindDockerReadGate
  , runConnectedKindDockerReply
  )
import Prodbox.Control.KindDockerReadProtocol (KindDockerProtocolOutcome, KindDockerRequest (..))
import Prodbox.Control.KindKubeconfigYaml
  ( decodeBoundedYamlDocuments
  , matchesPinnedKindKubeadmConfig
  )
import Prodbox.Control.KindLease (KindOperationOutcome, withRecoveredKindOperation)
import Prodbox.Control.KindNodeBootstrap
  ( bootstrapInputReply
  , bootstrapReadReply
  , classifyBootstrapRequest
  )
import Prodbox.Control.KindNodeCreateIntent
  ( KindNodeCandidateWrite (..)
  , KindNodeConfigAttemptObservation (..)
  , KindNodeConfigAttemptWrite (..)
  , KindNodeConfigResultObservation (..)
  , KindNodeConfigResultWrite (..)
  , KindNodeCreateAttemptObservation (..)
  , KindNodeCreateAttemptWrite (..)
  , KindNodeCreateIntent
  , KindNodeCreateRecoveryObservation (..)
  , KindNodeCreateResultObservation (..)
  , KindNodeCreateResultWrite (..)
  , KindNodeRemoveAttemptObservation (..)
  , KindNodeRemoveAttemptWrite (..)
  , KindNodeRemoveControlObservation (..)
  , KindNodeRemoveResultObservation (..)
  , KindNodeRemoveResultWrite (..)
  , KindNodeStartAttemptObservation (..)
  , KindNodeStartAttemptWrite (..)
  , KindNodeStartResultObservation (..)
  , KindNodeStartResultWrite (..)
  , kindNodeCreateDaemon
  , kindNodeCreateInput
  , observeKindNodeConfigAttempt
  , observeKindNodeConfigResult
  , observeKindNodeCreateAttempt
  , observeKindNodeCreateResult
  , observeKindNodeRemoveAttempt
  , observeKindNodeRemoveControl
  , observeKindNodeRemoveResult
  , observeKindNodeStartAttempt
  , observeKindNodeStartResult
  , observeRecordedKindNodeCreateIntent
  , recordKindNodeCandidate
  , recordKindNodeConfigAttempt
  , recordKindNodeConfigResult
  , recordKindNodeCreateAttempt
  , recordKindNodeCreateResult
  , recordKindNodeRemoveAttempt
  , recordKindNodeRemoveResult
  , recordKindNodeStartAttempt
  , recordKindNodeStartResult
  )
import Prodbox.Control.KindNodeRemovalReadback
  ( NodeRemovalReadback
  )
import System.Posix.Types (Fd)
import System.Timeout (timeout)

data KindNodeCreateAction
  = NodeCreateActionProposalRefused !KindNodeCreateRecoveryObservation
  | NodeCreateActionDaemonMismatch
  | NodeCreateActionAdmissionRefused
  | NodeCreateActionAttemptRefused !KindNodeCreateAttemptWrite
  | NodeCreateActionResultRefused !KindNodeCreateResultObservation
  | NodeCreateActionChanged
  | NodeCreateActionReturned !DockerNodeContainerCreateResult !KindNodeCreateResultWrite
  | NodeCreateActionChangedAfter !DockerNodeContainerCreateResult !KindNodeCreateResultWrite
  deriving (Eq, Show)

-- The admission callback is an obligation on the future lifecycle owner, not
-- evidence by itself. An existing attempt never submits a new request.
withNewConnectedKindNodeCreate
  :: BootstrapProjection
  -> String
  -> (KindNodeCreateIntent -> DockerSession -> IO Bool -> IO Bool)
  -> IO (KindOperationOutcome (DockerPeerResult (DockerConnectedInfoResult KindNodeCreateAction)))
withNewConnectedKindNodeCreate bootstrap operation admit =
  withRecoveredKindOperation bootstrap operation $ \operationStable ->
    withConnectedDockerInfo 30000000 (bootstrapRuntimeSocket bootstrap) $ \session info peerStable ->
      runKindNodeCreateOnSession
        bootstrap
        operation
        session
        info
        ((&&) <$> operationStable <*> peerStable)
        admit

-- | Run the same write-before-effect sequence on an already held session.
-- The caller must hold the operation lease, bind and recheck the session,
-- authenticate the daemon, settle prior workers, and establish admission and
-- cleanup. This entry point does not supply any of those guarantees.
runKindNodeCreateOnSession
  :: BootstrapProjection
  -> String
  -> DockerSession
  -> DockerConnectedInfo
  -> IO Bool
  -> (KindNodeCreateIntent -> DockerSession -> IO Bool -> IO Bool)
  -> IO KindNodeCreateAction
runKindNodeCreateOnSession bootstrap operation session (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) stable admit = do
  proposal <- observeRecordedKindNodeCreateIntent bootstrap operation stable
  case proposal of
    NodeCreateRecoveryRecorded intent
      | kindNodeCreateDaemon intent == DockerDaemonObserved identifier identity -> do
          admitted <- try (admit intent session stable)
          case (admitted :: Either IOException Bool) of
            Right True -> do
              written <- recordKindNodeCreateAttempt bootstrap intent stable
              case written of
                NodeCreateAttemptRecorded -> do
                  let markerStable = do
                        marker <- observeKindNodeCreateAttempt bootstrap intent stable
                        if marker /= NodeCreateAttemptMatches
                          then pure False
                          else do
                            allowed <- admit intent session stable
                            afterAdmission <- stable
                            pure (allowed && afterAdmission)
                  prior <- observeKindNodeCreateResult bootstrap intent markerStable
                  case prior of
                    NodeCreateResultMissing -> do
                      ready <- markerStable
                      if not ready
                        then pure NodeCreateActionChanged
                        else do
                          result <- createDockerSessionKindNode session bootstrap (kindNodeCreateInput intent) markerStable
                          receipt <- recordKindNodeCreateResult bootstrap intent result markerStable
                          after <- try markerStable
                          pure $ case (after :: Either IOException Bool) of
                            Right True -> NodeCreateActionReturned result receipt
                            _ -> NodeCreateActionChangedAfter result receipt
                    other -> pure (NodeCreateActionResultRefused other)
                other -> pure (NodeCreateActionAttemptRefused other)
            _ -> pure NodeCreateActionAdmissionRefused
      | otherwise -> pure NodeCreateActionDaemonMismatch
    other -> pure (NodeCreateActionProposalRefused other)

-- | Retain a candidate observed for an uncertain create. The exact candidate
-- is inspected over the held session and independently sampled by the writer.
-- This records no create success and grants no ownership or cleanup authority.
data KindNodeCandidateAction
  = NodeCandidateActionProposalRefused !KindNodeCreateRecoveryObservation
  | NodeCandidateActionDaemonMismatch
  | NodeCandidateActionInspectionRefused
      !(Either DockerConnectedInfoFailure DockerNodeContainerObservation)
  | NodeCandidateActionChanged
  | NodeCandidateActionReturned !KindNodeCandidateWrite
  | NodeCandidateActionChangedAfter !KindNodeCandidateWrite
  deriving (Eq, Show)

withNewConnectedKindNodeCandidate
  :: BootstrapProjection
  -> String
  -> String
  -> IO (KindOperationOutcome (DockerPeerResult (DockerConnectedInfoResult KindNodeCandidateAction)))
withNewConnectedKindNodeCandidate bootstrap operation candidate =
  withRecoveredKindOperation bootstrap operation $ \operationStable ->
    withConnectedDockerInfo 30000000 (bootstrapRuntimeSocket bootstrap) $ \session (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) peerStable -> do
      let stable = (&&) <$> operationStable <*> peerStable
      proposal <- observeRecordedKindNodeCreateIntent bootstrap operation stable
      case proposal of
        NodeCreateRecoveryRecorded intent
          | kindNodeCreateDaemon intent == DockerDaemonObserved identifier identity -> do
              inspected <- inspectDockerSessionKindNode session bootstrap (kindNodeCreateInput intent) candidate
              case inspected of
                Right (DockerNodeContainerMatching _) -> do
                  let candidateStable = do
                        current <- inspectDockerSessionKindNode session bootstrap (kindNodeCreateInput intent) candidate
                        scoped <- stable
                        pure (scoped && case current of Right (DockerNodeContainerMatching _) -> True; _ -> False)
                  ready <- try candidateStable
                  case (ready :: Either IOException Bool) of
                    Right True -> do
                      written <- recordKindNodeCandidate bootstrap intent candidate candidateStable
                      after <- try candidateStable
                      pure $ case (after :: Either IOException Bool) of
                        Right True -> NodeCandidateActionReturned written
                        _ -> NodeCandidateActionChangedAfter written
                    _ -> pure NodeCandidateActionChanged
                other -> pure (NodeCandidateActionInspectionRefused other)
          | otherwise -> pure NodeCandidateActionDaemonMismatch
        other -> pure (NodeCandidateActionProposalRefused other)

-- The admission callback must establish exact container ownership, daemon
-- authentication, prerequisite settlement and cleanup before any effect.
data KindNodeStartAction
  = NodeStartActionProposalRefused !KindNodeCreateRecoveryObservation
  | NodeStartActionDaemonMismatch
  | NodeStartActionCreateResultRefused !KindNodeCreateResultObservation
  | NodeStartActionInspectionRefused !(Either DockerConnectedInfoFailure DockerNodeContainerObservation)
  | NodeStartActionRemovalRefused !KindNodeRemoveAttemptObservation
  | NodeStartActionAdmissionRefused
  | NodeStartActionAttemptRefused !KindNodeStartAttemptWrite
  | NodeStartActionResultRefused !KindNodeStartResultObservation
  | NodeStartActionChanged
  | NodeStartActionReturned !DockerNodeContainerStartResult !KindNodeStartResultWrite
  | NodeStartActionChangedAfter !DockerNodeContainerStartResult !KindNodeStartResultWrite
  deriving (Eq, Show)

data KindNodeRunAction
  = NodeRunProposalRefused !KindNodeCreateRecoveryObservation
  | NodeRunArgumentsRefused
  | NodeRunCreateObserved !KindNodeCreateAction
  | NodeRunStartObserved !KindNodeCreateAction !KindNodeStartAction
  deriving (Eq, Show)

data KindNodeBrokerState
  = KindNodeBrokerOpen !(Maybe KindNodeRunAction)
  | KindNodeBrokerClosed !(Maybe KindNodeRunAction)

data KindNodeConfigCandidateObservation
  = NodeConfigCandidateMatches
  | NodeConfigCandidateRejected
  | NodeConfigCandidateUnobservable
  deriving (Eq, Show)

data KindNodeBroker
  = KindNodeBroker
      !(MVar KindNodeBrokerState)
      !KindDockerReadGate
      !DockerSession
      !String
      !(IO Bool)
      !([String] -> IO KindNodeRunAction)
      !(Maybe KindNodeRunAction -> [String] -> IO (Maybe KindDockerReply))
      !(IORef (Maybe KindNodeConfigCandidateObservation))
      !(Maybe KindNodeRunAction -> [String] -> Bytes.ByteString -> IO KindNodeConfigCandidateObservation)
      !(IORef (Maybe KindNodeConfigAction))
      !(Maybe (Maybe KindNodeRunAction -> [String] -> Bytes.ByteString -> IO KindNodeConfigAction))
      !(Maybe KindNodeRunAction -> [String] -> Bytes.ByteString -> IO (Maybe KindDockerReply))

type KindNodeConfigAdmission = KindNodeCreateIntent -> String -> DockerSession -> IO Bool -> IO Bool

-- | The owner must hold the session and operation lease and establish the
-- supplied admissions. This gate serializes requests and closes after any
-- refusal, failure or exception; it does not itself establish admission.
newKindNodeBroker
  :: BootstrapProjection
  -> String
  -> DockerSession
  -> DockerConnectedInfo
  -> IO Bool
  -> (KindNodeCreateIntent -> DockerSession -> IO Bool -> IO Bool)
  -> (KindNodeCreateIntent -> String -> DockerSession -> IO Bool -> IO Bool)
  -> IO (Maybe KindNodeBroker)
newKindNodeBroker bootstrap operation session info stable admitCreate admitStart =
  newKindNodeBrokerInternal bootstrap operation session info stable admitCreate admitStart Nothing

-- | The owner must separately supply the configuration-specific admission and
-- recovery obligations described by 'runKindNodeConfigOnSession'.
newKindNodeBrokerWithConfig
  :: BootstrapProjection
  -> String
  -> DockerSession
  -> DockerConnectedInfo
  -> IO Bool
  -> (KindNodeCreateIntent -> DockerSession -> IO Bool -> IO Bool)
  -> (KindNodeCreateIntent -> String -> DockerSession -> IO Bool -> IO Bool)
  -> KindNodeConfigAdmission
  -> IO (Maybe KindNodeBroker)
newKindNodeBrokerWithConfig bootstrap operation session info stable admitCreate admitStart admitConfig =
  newKindNodeBrokerInternal
    bootstrap
    operation
    session
    info
    stable
    admitCreate
    admitStart
    (Just admitConfig)

newKindNodeBrokerInternal
  :: BootstrapProjection
  -> String
  -> DockerSession
  -> DockerConnectedInfo
  -> IO Bool
  -> (KindNodeCreateIntent -> DockerSession -> IO Bool -> IO Bool)
  -> (KindNodeCreateIntent -> String -> DockerSession -> IO Bool -> IO Bool)
  -> Maybe KindNodeConfigAdmission
  -> IO (Maybe KindNodeBroker)
newKindNodeBrokerInternal bootstrap operation session info@(DockerConnectedInfo daemon (DockerPeer _ _ _ identity)) stable admitCreate admitStart admitConfig = do
  proposal <- observeRecordedKindNodeCreateIntent bootstrap operation stable
  case proposal of
    NodeCreateRecoveryRecorded intent
      | kindNodeCreateDaemon intent == DockerDaemonObserved daemon identity -> do
          gate <-
            newKindDockerReadGate (bootstrapScope bootstrap) (nodeCreateImageId (kindNodeCreateInput intent))
          case gate of
            Nothing -> pure Nothing
            Just readGate -> do
              state <- newMVar (KindNodeBrokerOpen Nothing)
              candidate <- newIORef Nothing
              configAction <- newIORef Nothing
              -- One bracket of the supplied stability around a single record
              -- read. The read itself verifies the file's identity before and
              -- after, so repeating the full closure inside it only multiplied
              -- cost: nested through each action it reached seconds per request.
              let bound = do
                    before <- stable
                    observed <- observeRecordedKindNodeCreateIntent bootstrap operation (pure True)
                    after <- stable
                    pure (before && after && observed == proposal)
              pure $
                Just $
                  KindNodeBroker
                    state
                    readGate
                    session
                    daemon
                    bound
                    ( \arguments -> runKindNodeOnSession bootstrap operation session info bound arguments admitCreate admitStart
                    )
                    (nodeRead bootstrap operation session bound)
                    candidate
                    (observeNodeConfigCandidate bootstrap operation session daemon bound)
                    configAction
                    ( fmap
                        ( \admit previous arguments payload ->
                            runKindNodeConfigOnSession bootstrap operation session info bound previous arguments payload admit
                        )
                        admitConfig
                    )
                    (bootstrapInputRequest bootstrap operation session bound nodeName)
    _ -> pure Nothing
 where
  nodeName = scopeKindName (bootstrapScope bootstrap) ++ "-control-plane"

-- Stdin forms of the bootstrap route: recognised exactly, run only when the
-- selected node is verified both before and after.
bootstrapInputRequest
  :: BootstrapProjection
  -> String
  -> DockerSession
  -> IO Bool
  -> String
  -> Maybe KindNodeRunAction
  -> [String]
  -> Bytes.ByteString
  -> IO (Maybe KindDockerReply)
bootstrapInputRequest bootstrap operation session bound nodeName previous arguments payload =
  maybe (pure Nothing) serve (classifyBootstrapRequest nodeName arguments)
 where
  verifyNode = fmap (fmap snd) (verifyKindNodeRecorded bootstrap operation session bound previous)
  serve request = do
    before <- verifyNode
    reply <- bootstrapInputReply bootstrap operation request payload (pure before)
    after <- verifyNode
    pure $
      Just $
        if before /= Nothing && before == after
          then reply
          else KindDockerReply 1 Bytes.empty (Bytes.pack "kind node observation unavailable\n")

observeKindNodeBrokerResult :: KindNodeBroker -> IO (Maybe KindNodeRunAction)
observeKindNodeBrokerResult (KindNodeBroker state _ _ _ _ _ _ _ _ _ _ _) = do
  current <- readMVar state
  pure $ case current of KindNodeBrokerOpen value -> value; KindNodeBrokerClosed value -> value

closeKindNodeBroker :: KindNodeBroker -> IO ()
closeKindNodeBroker (KindNodeBroker state readGate _ _ _ _ _ _ _ _ _ _) = do
  modifyMVar_ state $ \current -> pure $ case current of
    KindNodeBrokerOpen value -> KindNodeBrokerClosed value
    KindNodeBrokerClosed value -> KindNodeBrokerClosed value
  closeKindDockerReadGate readGate

observeKindNodeBrokerConfigCandidate
  :: KindNodeBroker -> IO (Maybe KindNodeConfigCandidateObservation)
observeKindNodeBrokerConfigCandidate (KindNodeBroker _ _ _ _ _ _ _ candidate _ _ _ _) = readIORef candidate

observeKindNodeBrokerConfigAction :: KindNodeBroker -> IO (Maybe KindNodeConfigAction)
observeKindNodeBrokerConfigAction (KindNodeBroker _ _ _ _ _ _ _ _ _ action _ _) = readIORef action

-- | Serve the serialized broker on already owned endpoints. The outer owner
-- remains responsible for bounding and settling the worker and recovering any
-- in-flight marker or daemon effect.
serveKindNodeBroker
  :: Fd -> IO Bool -> KindNodeBroker -> IO (KindDockerEndpointResult KindDockerProtocolOutcome)
serveKindNodeBroker directory stable broker =
  serveBoundKindDockerInputRequests
    directory
    stable
    (runKindNodeBrokerInput broker)
    (closeKindNodeBroker broker)

-- Without a separately supplied admission, input is observed and refused.
runKindNodeBrokerInput :: KindNodeBroker -> KindDockerRequest -> IO KindDockerReply
runKindNodeBrokerInput broker@(KindNodeBroker state readGate _ _ bound _ _ candidate observe actionResult action bootstrapInput) (KindDockerRequest arguments payload)
  | Bytes.null payload = runKindNodeBrokerRequest broker arguments
  | otherwise = mask $ \restore -> do
      let handle current = case current of
            KindNodeBrokerClosed previous -> pure (KindNodeBrokerClosed previous, Right refused)
            KindNodeBrokerOpen previous -> do
              bootstrapped <- try (restore (bootstrapInput previous arguments payload))
              case bootstrapped of
                Left failure -> pure (KindNodeBrokerClosed previous, Left (failure :: SomeException))
                Right (Just reply) ->
                  pure
                    ( if kindDockerReplyExit reply == 0
                        then KindNodeBrokerOpen previous
                        else KindNodeBrokerClosed previous
                    , Right reply
                    )
                Right Nothing -> configurationInput previous
          configurationInput previous = do
            observed <- try $ restore $ do
              ready <- bound
              candidateValue <-
                if ready then observe previous arguments payload else pure NodeConfigCandidateUnobservable
              performed <- case (candidateValue, action) of
                (NodeConfigCandidateMatches, Just run) -> Just <$> run previous arguments payload
                _ -> pure Nothing
              after <- bound
              pure (candidateValue, performed, after)
            case observed of
              Left failure -> pure (KindNodeBrokerClosed previous, Left (failure :: SomeException))
              Right (value, performed, after) -> do
                writeIORef candidate (Just value)
                writeIORef actionResult performed
                let success =
                      after && case performed of
                        Just
                          ( NodeConfigActionReturned
                              (DockerNodeConfigWriteReply 200)
                              NodeConfigResultRecorded
                              (Just (Right DockerNodeConfigMatches))
                            ) -> True
                        _ -> False
                pure $
                  if success
                    then (KindNodeBrokerOpen previous, Right (KindDockerReply 0 Bytes.empty Bytes.empty))
                    else (KindNodeBrokerClosed previous, Right refused)
      result <- modifyMVar state handle
      case result of
        Left failure -> closeKindDockerReadGate readGate >> throwIO failure
        Right reply -> do
          if kindDockerReplyExit reply == 0 then pure () else closeKindDockerReadGate readGate
          pure reply
 where
  refused = KindDockerReply 1 Bytes.empty (Bytes.pack "kind input request refused\n")

-- | Pair the broker with one worker action. The returned observations do not
-- prove settlement of a child process or any daemon-side effect.
runBoundKindNodeWorker
  :: Fd
  -> IO Bool
  -> KindNodeBroker
  -> IO value
  -> IO (KindDockerBrokerExit, KindDockerWorkerExit value)
runBoundKindNodeWorker directory stable broker =
  runBoundKindDockerWorker (serveKindNodeBroker directory stable broker)

runKindNodeBrokerRequest :: KindNodeBroker -> [String] -> IO KindDockerReply
runKindNodeBrokerRequest broker@(KindNodeBroker state readGate session daemon bound node nodeObservation _ _ _ _ _) arguments = mask $ \restore -> do
  let handle current = case current of
        KindNodeBrokerClosed value -> pure (KindNodeBrokerClosed value, Right refused)
        KindNodeBrokerOpen previous -> do
          before <- try (restore bound)
          case before of
            Left failure -> pure (KindNodeBrokerClosed previous, Left (failure :: SomeException))
            Right False -> pure (KindNodeBrokerClosed previous, Right refused)
            Right True -> do
              attempted <- try $ restore $ case arguments of
                "run" : _ -> do
                  result <- node arguments
                  pure (nodeReply result, Just result)
                _ -> do
                  observed <- nodeObservation previous arguments
                  reply <- maybe (runConnectedKindDockerReply readGate session daemon arguments) pure observed
                  pure (reply, previous)
              case attempted of
                Left failure -> pure (KindNodeBrokerClosed previous, Left (failure :: SomeException))
                Right (reply, result) -> do
                  after <- try (restore bound)
                  case after of
                    Left failure -> pure (KindNodeBrokerClosed result, Left (failure :: SomeException))
                    Right False -> pure (KindNodeBrokerClosed result, Right refused)
                    Right True ->
                      pure
                        ( if kindDockerReplyExit reply == 0 then KindNodeBrokerOpen result else KindNodeBrokerClosed result
                        , Right reply
                        )
  outcome <- modifyMVar state handle
  case outcome of
    Left failure -> closeKindNodeBroker broker >> throwIO failure
    Right reply -> do
      if kindDockerReplyExit reply == 0 then pure () else closeKindNodeBroker broker
      pure reply
 where
  refused = KindDockerReply 1 Bytes.empty (Bytes.pack "kind request refused\n")
  nodeReply result = case result of
    NodeRunStartObserved
      ( NodeCreateActionReturned
          (DockerNodeContainerCreateReply 201 (Just identifier))
          NodeCreateResultRecorded
        )
      (NodeStartActionReturned (DockerNodeContainerStartReply 204) NodeStartResultRecorded) ->
        KindDockerReply 0 (Bytes.pack (identifier ++ "\n")) Bytes.empty
    _ -> refused

-- Recognize only kind's exact selected-node boot, role and version reads after this
-- broker observed the recorded create and start. Each read is bracketed by
-- the operation, record and exact running-container checks.
nodeRead
  :: BootstrapProjection
  -> String
  -> DockerSession
  -> IO Bool
  -> Maybe KindNodeRunAction
  -> [String]
  -> IO (Maybe KindDockerReply)
nodeRead bootstrap operation session stable previous arguments = case arguments of
  ["logs", "-f", name] | name == selected -> Just <$> boot
  ["inspect", "--format", "{{ index .Config.Labels \"io.x-k8s.kind.role\"}}", name] | name == selected -> Just <$> role
  ["exec", "--privileged", name, "cat", "/kind/version"] | name == selected -> Just <$> version
  ["exec", "--privileged", name, "mkdir", "-p", "/kind"] | name == selected -> Just <$> existingDirectory
  [ "inspect"
    , "-f"
    , "{{range .NetworkSettings.Networks}}{{.IPAddress}},{{.GlobalIPv6Address}}{{end}}"
    , name
    ]
      | name == selected -> Just <$> addresses
  _ -> case classifyBootstrapRequest selected arguments of
    Just request -> Just <$> bootstrapped request
    Nothing -> pure Nothing
 where
  selected = scopeKindName (bootstrapScope bootstrap) ++ "-control-plane"
  bootstrapped request = do
    before <- verify
    reply <- bootstrapReadReply bootstrap operation request (pure before)
    after <- verify
    pure (if before /= Nothing && before == after then reply else denied)
  denied = KindDockerReply 1 Bytes.empty (Bytes.pack "kind node observation unavailable\n")
  verify = fmap (fmap snd) (verifyKindNodeRecorded bootstrap operation session stable previous)
  role = do
    before <- verify
    after <- verify
    pure $
      if before /= Nothing && before == after
        then KindDockerReply 0 (Bytes.pack "control-plane\n") Bytes.empty
        else denied
  boot = do
    outcome <- timeout 30000000 poll
    pure (maybe denied id outcome)
  version = do
    before <- verify
    case before of
      Nothing -> pure denied
      Just identifier -> do
        result <- readDockerSessionKindNodeVersion session identifier
        after <- verify
        pure $ case (result, after) of
          (Right bytes, Just current) | current == identifier -> KindDockerReply 0 bytes Bytes.empty
          _ -> denied
  -- The version file proves the directory already exists. Refuse otherwise;
  -- this projection never creates a path in the container.
  existingDirectory = do
    before <- verify
    case before of
      Nothing -> pure denied
      Just identifier -> do
        versionFile <- readDockerSessionKindNodeVersion session identifier
        after <- verify
        pure $ case (versionFile, after) of
          (Right _, Just current) | current == identifier -> KindDockerReply 0 Bytes.empty Bytes.empty
          _ -> denied
  addresses = do
    before <- verify
    case before of
      Nothing -> pure denied
      Just identifier -> do
        proposal <- observeRecordedKindNodeCreateIntent bootstrap operation stable
        result <- case proposal of
          NodeCreateRecoveryRecorded intent ->
            Just
              <$> readDockerSessionKindNodeAddresses session bootstrap (kindNodeCreateInput intent) identifier
          _ -> pure Nothing
        after <- verify
        pure $ case (result, after) of
          (Just (Right bytes), Just current) | current == identifier -> KindDockerReply 0 bytes Bytes.empty
          _ -> denied
  poll = do
    before <- verify
    case before of
      Nothing -> pure denied
      Just identifier -> do
        result <- readDockerSessionKindNodeBootLine session identifier
        after <- verify
        case (result, after) of
          (Right (Just line), Just current) | current == identifier -> pure (KindDockerReply 0 line Bytes.empty)
          (Right Nothing, Just current) | current == identifier -> threadDelay 500000 >> poll
          _ -> pure denied

-- Record and container point observations only; the caller still owns daemon
-- authentication, operation admission, worker settlement and cleanup.
verifyKindNodeRecorded
  :: BootstrapProjection
  -> String
  -> DockerSession
  -> IO Bool
  -> Maybe KindNodeRunAction
  -> IO (Maybe (KindNodeCreateIntent, String))
verifyKindNodeRecorded bootstrap operation session stable previous = case previous of
  Just
    ( NodeRunStartObserved
        ( NodeCreateActionReturned
            (DockerNodeContainerCreateReply 201 (Just identifier))
            NodeCreateResultRecorded
          )
        (NodeStartActionReturned (DockerNodeContainerStartReply 204) NodeStartResultRecorded)
      ) -> do
      proposal <- observeRecordedKindNodeCreateIntent bootstrap operation stable
      case proposal of
        NodeCreateRecoveryRecorded intent -> do
          created <- observeKindNodeCreateResult bootstrap intent stable
          attempt <- observeKindNodeStartAttempt bootstrap intent identifier stable
          started <- observeKindNodeStartResult bootstrap intent identifier stable
          removal <- observeKindNodeRemoveAttempt bootstrap intent identifier stable
          observed <- inspectDockerSessionKindNode session bootstrap (kindNodeCreateInput intent) identifier
          ready <- stable
          pure $
            if ready
              && created == NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just identifier))
              && attempt == NodeStartAttemptMatches
              && started == NodeStartResultObserved (DockerNodeContainerStartReply 204)
              && removal == NodeRemoveAttemptMissing
              && observed == Right (DockerNodeContainerMatching True)
              then Just (intent, identifier)
              else Nothing
        _ -> pure Nothing
  _ -> pure Nothing

-- A candidate match is only a scoped, same-session point observation. It is
-- not authority to mutate, proof of daemon identity or worker settlement.
observeNodeConfigCandidate
  :: BootstrapProjection
  -> String
  -> DockerSession
  -> String
  -> IO Bool
  -> Maybe KindNodeRunAction
  -> [String]
  -> Bytes.ByteString
  -> IO KindNodeConfigCandidateObservation
observeNodeConfigCandidate bootstrap operation session daemon stable previous arguments payload
  | arguments /= ["exec", "--privileged", "-i", selected, "cp", "/dev/stdin", "/kind/kubeadm.conf"] =
      pure NodeConfigCandidateRejected
  | otherwise = do
      decoded <- decodeBoundedYamlDocuments payload
      case decoded of
        Left _ -> pure NodeConfigCandidateRejected
        Right documents -> do
          first <- snapshot
          second <- snapshot
          pure $ case (first, second) of
            (Just a@(_, _, address, version, info, _), Just b)
              | a == b ->
                  if matchesPinnedKindKubeadmConfig
                    (bootstrapScope bootstrap)
                    address
                    version
                    (Text.pack (dockerKindCgroupDriver info))
                    documents
                    then NodeConfigCandidateMatches
                    else NodeConfigCandidateRejected
            _ -> NodeConfigCandidateUnobservable
 where
  selected = scopeKindName (bootstrapScope bootstrap) ++ "-control-plane"
  snapshot = do
    before <- verifyKindNodeRecorded bootstrap operation session stable previous
    case before of
      Nothing -> pure Nothing
      Just (intent, identifier) -> do
        addressResult <-
          readDockerSessionKindNodeAddresses session bootstrap (kindNodeCreateInput intent) identifier
        versionResult <- readDockerSessionKindNodeVersion session identifier
        infoResult <- readDockerSessionKindInfo session daemon
        directoryResult <-
          observeDockerSessionKindNodeConfigPath session identifier DockerNodeConfigDirectory
        fileResult <- observeDockerSessionKindNodeConfigPath session identifier DockerNodeConfigFile
        after <- verifyKindNodeRecorded bootstrap operation session stable previous
        pure $ do
          addressBytes <- either (const Nothing) Just addressResult
          versionBytes <- either (const Nothing) Just versionResult
          info <- either (const Nothing) Just infoResult
          directory <- either (const Nothing) Just directoryResult
          file <- either (const Nothing) Just fileResult
          address <- addressText addressBytes
          version <- singleLine versionBytes
          case (directory, file) of
            (DockerNodeConfigDirectoryObserved {}, DockerNodeConfigNotFoundResponse)
              | after == before -> Just (intent, identifier, address, version, info, directory)
            _ -> Nothing
  singleLine bytes = case Bytes.lines bytes of
    [line] | not (Bytes.null line) -> either (const Nothing) Just (TextEncoding.decodeUtf8' line)
    _ -> Nothing
  addressText bytes = case Bytes.lines bytes of
    [line] -> case Bytes.split ',' line of
      [ipv4, ipv6] -> singleLine (if Bytes.null ipv4 then ipv6 else ipv4)
      _ -> Nothing
    _ -> Nothing

data KindNodeConfigAction
  = NodeConfigActionCandidateRefused !KindNodeConfigCandidateObservation
  | NodeConfigActionNodeChanged
  | NodeConfigActionAdmissionRefused
  | NodeConfigActionAttemptRefused !KindNodeConfigAttemptWrite
  | NodeConfigActionResultRefused !KindNodeConfigResultObservation
  | NodeConfigActionChanged
  | NodeConfigActionReturned
      !DockerNodeConfigWriteResult
      !KindNodeConfigResultWrite
      !(Maybe (Either DockerConnectedInfoFailure DockerNodeConfigReadback))
  | NodeConfigActionChangedAfter !DockerNodeConfigWriteResult !KindNodeConfigResultWrite
  deriving (Eq, Show)

-- | Submit one exact candidate after a durable attempt. The caller must hold
-- the operation lease and session, authenticate the daemon, exclude path and
-- node writers, establish path ownership, settle earlier workers, and own
-- recovery and cleanup. The admission callback must remain meaningful after
-- the file is written; a 404 or matching observation alone is not admission.
-- No input bytes or digest enter the records or returned observations.
runKindNodeConfigOnSession
  :: BootstrapProjection
  -> String
  -> DockerSession
  -> DockerConnectedInfo
  -> IO Bool
  -> Maybe KindNodeRunAction
  -> [String]
  -> Bytes.ByteString
  -> (KindNodeCreateIntent -> String -> DockerSession -> IO Bool -> IO Bool)
  -> IO KindNodeConfigAction
runKindNodeConfigOnSession bootstrap operation session (DockerConnectedInfo daemon (DockerPeer _ _ _ identity)) stable previous arguments payload admit = do
  candidate <-
    observeNodeConfigCandidate bootstrap operation session daemon stable previous arguments payload
  if candidate /= NodeConfigCandidateMatches
    then pure (NodeConfigActionCandidateRefused candidate)
    else do
      selected <- verifyKindNodeRecorded bootstrap operation session stable previous
      case selected of
        Just (intent, identifier) | kindNodeCreateDaemon intent == DockerDaemonObserved daemon identity -> do
          let sameNode = (== selected) <$> verifyKindNodeRecorded bootstrap operation session stable previous
              admissionStable = do
                before <- sameNode
                allowed <- if before then admit intent identifier session sameNode else pure False
                after <- sameNode
                pure (before && allowed && after)
          admitted <- try admissionStable
          case (admitted :: Either IOException Bool) of
            Right True -> do
              attempt <- recordKindNodeConfigAttempt bootstrap intent identifier stable
              case attempt of
                NodeConfigAttemptRecorded -> do
                  let markerStable = do
                        marker <- observeKindNodeConfigAttempt bootstrap intent identifier stable
                        if marker /= NodeConfigAttemptMatches then pure False else admissionStable
                  prior <- observeKindNodeConfigResult bootstrap intent identifier stable
                  case prior of
                    NodeConfigResultMissing -> do
                      stillCandidate <-
                        observeNodeConfigCandidate
                          bootstrap
                          operation
                          session
                          daemon
                          stable
                          previous
                          arguments
                          payload
                      ready <- markerStable
                      if not ready || stillCandidate /= NodeConfigCandidateMatches
                        then pure NodeConfigActionChanged
                        else do
                          result <- writeDockerSessionKindNodeConfig session identifier payload markerStable
                          receipt <- recordKindNodeConfigResult bootstrap intent identifier result stable
                          after <- try markerStable
                          case (after :: Either IOException Bool) of
                            Right True -> do
                              readback <- case (result, receipt) of
                                (DockerNodeConfigWriteReply 200, NodeConfigResultRecorded) ->
                                  Just <$> readDockerSessionKindNodeConfig session identifier payload
                                _ -> pure Nothing
                              final <- try markerStable
                              pure $ case (final :: Either IOException Bool) of
                                Right True -> NodeConfigActionReturned result receipt readback
                                _ -> NodeConfigActionChangedAfter result receipt
                            _ -> pure (NodeConfigActionChangedAfter result receipt)
                    other -> pure (NodeConfigActionResultRefused other)
                other -> pure (NodeConfigActionAttemptRefused other)
            _ -> pure NodeConfigActionAdmissionRefused
        _ -> pure NodeConfigActionNodeChanged

-- | Interpret one exact recorded kind node request on a held session. Create
-- must return a recorded successful receipt before start is attempted. The
-- caller still owns lease and session custody, daemon authentication, effect
-- admission, worker settlement, and recovery of either effect.
runKindNodeOnSession
  :: BootstrapProjection
  -> String
  -> DockerSession
  -> DockerConnectedInfo
  -> IO Bool
  -> [String]
  -> (KindNodeCreateIntent -> DockerSession -> IO Bool -> IO Bool)
  -> (KindNodeCreateIntent -> String -> DockerSession -> IO Bool -> IO Bool)
  -> IO KindNodeRunAction
runKindNodeOnSession bootstrap operation session info stable arguments admitCreate admitStart = do
  proposal <- observeRecordedKindNodeCreateIntent bootstrap operation stable
  case proposal of
    NodeCreateRecoveryRecorded intent
      | arguments /= nodeCreateArguments (kindNodeCreateInput intent) -> pure NodeRunArgumentsRefused
      | otherwise -> do
          let sameIntent = do
                current <- observeRecordedKindNodeCreateIntent bootstrap operation stable
                pure (current == proposal)
          created <- runKindNodeCreateOnSession bootstrap operation session info sameIntent admitCreate
          case created of
            NodeCreateActionReturned (DockerNodeContainerCreateReply 201 (Just _)) NodeCreateResultRecorded -> do
              started <- runKindNodeStartOnSession bootstrap operation session info sameIntent admitStart
              pure (NodeRunStartObserved created started)
            _ -> pure (NodeRunCreateObserved created)
    other -> pure (NodeRunProposalRefused other)

withNewConnectedKindNodeStart
  :: BootstrapProjection
  -> String
  -> (KindNodeCreateIntent -> String -> DockerSession -> IO Bool -> IO Bool)
  -> IO (KindOperationOutcome (DockerPeerResult (DockerConnectedInfoResult KindNodeStartAction)))
withNewConnectedKindNodeStart bootstrap operation admit =
  withRecoveredKindOperation bootstrap operation $ \operationStable ->
    withConnectedDockerInfo 30000000 (bootstrapRuntimeSocket bootstrap) $ \session info peerStable ->
      runKindNodeStartOnSession
        bootstrap
        operation
        session
        info
        ((&&) <$> operationStable <*> peerStable)
        admit

-- | Use a held session and operation lease for the journaled start. The
-- caller owns lease custody, daemon authentication, prior settlement,
-- admission, and recovery; this function does not establish those facts.
runKindNodeStartOnSession
  :: BootstrapProjection
  -> String
  -> DockerSession
  -> DockerConnectedInfo
  -> IO Bool
  -> (KindNodeCreateIntent -> String -> DockerSession -> IO Bool -> IO Bool)
  -> IO KindNodeStartAction
runKindNodeStartOnSession bootstrap operation session (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) stable admit = do
  proposal <- observeRecordedKindNodeCreateIntent bootstrap operation stable
  case proposal of
    NodeCreateRecoveryRecorded intent
      | kindNodeCreateDaemon intent == DockerDaemonObserved identifier identity -> do
          created <- observeKindNodeCreateResult bootstrap intent stable
          case created of
            NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just containerId)) -> do
              inspected <- inspectDockerSessionKindNode session bootstrap (kindNodeCreateInput intent) containerId
              case inspected of
                Right (DockerNodeContainerMatching _) -> do
                  removal <- observeKindNodeRemoveAttempt bootstrap intent containerId stable
                  if removal /= NodeRemoveAttemptMissing
                    then pure (NodeStartActionRemovalRefused removal)
                    else startAdmitted intent containerId
                other -> pure (NodeStartActionInspectionRefused other)
            other -> pure (NodeStartActionCreateResultRefused other)
      | otherwise -> pure NodeStartActionDaemonMismatch
    other -> pure (NodeStartActionProposalRefused other)
 where
  startAdmitted intent containerId = do
    admitted <- try (admit intent containerId session stable)
    case (admitted :: Either IOException Bool) of
      Right True -> do
        written <- recordKindNodeStartAttempt bootstrap intent containerId stable
        case written of
          NodeStartAttemptRecorded -> do
            let markerStable = do
                  marker <- observeKindNodeStartAttempt bootstrap intent containerId stable
                  removal <- observeKindNodeRemoveAttempt bootstrap intent containerId stable
                  if marker /= NodeStartAttemptMatches || removal /= NodeRemoveAttemptMissing
                    then pure False
                    else do
                      currentNode <-
                        inspectDockerSessionKindNode session bootstrap (kindNodeCreateInput intent) containerId
                      case currentNode of
                        Right (DockerNodeContainerMatching _) -> do
                          allowed <- admit intent containerId session stable
                          afterAdmission <- stable
                          pure (allowed && afterAdmission)
                        _ -> pure False
            prior <- observeKindNodeStartResult bootstrap intent containerId markerStable
            case prior of
              NodeStartResultMissing -> do
                ready <- markerStable
                if not ready
                  then pure NodeStartActionChanged
                  else do
                    result <- startDockerSessionKindNode session containerId markerStable
                    receipt <- recordKindNodeStartResult bootstrap intent containerId result markerStable
                    after <- try markerStable
                    pure $ case (after :: Either IOException Bool) of
                      Right True -> NodeStartActionReturned result receipt
                      _ -> NodeStartActionChangedAfter result receipt
              other -> pure (NodeStartActionResultRefused other)
          other -> pure (NodeStartActionAttemptRefused other)
      _ -> pure NodeStartActionAdmissionRefused

-- Matching configuration is not ownership. The caller must authenticate the
-- daemon, settle all prior workers, prove exact ownership and preserve retained
-- data before authorizing removal. A reply never establishes absence.
data KindNodeRemoveAction
  = NodeRemoveActionProposalRefused !KindNodeCreateRecoveryObservation
  | NodeRemoveActionDaemonMismatch
  | NodeRemoveActionCreateResultRefused !KindNodeCreateResultObservation
  | NodeRemoveActionInspectionRefused
      !(Either DockerConnectedInfoFailure DockerNodeContainerObservation)
  | NodeRemoveActionAdmissionRefused
  | NodeRemoveActionPositiveControlRefused !NodeRemovalReadback
  | NodeRemoveActionAttemptRefused !KindNodeRemoveAttemptWrite
  | NodeRemoveActionResultRefused !KindNodeRemoveResultObservation
  | NodeRemoveActionChanged
  | NodeRemoveActionReturned !DockerNodeContainerRemoveResult !KindNodeRemoveResultWrite
  | NodeRemoveActionChangedAfter !DockerNodeContainerRemoveResult !KindNodeRemoveResultWrite
  deriving (Eq, Show)

withNewConnectedKindNodeRemove
  :: BootstrapProjection
  -> String
  -> (KindNodeCreateIntent -> String -> DockerSession -> IO Bool -> IO Bool)
  -> IO (KindOperationOutcome (DockerPeerResult (DockerConnectedInfoResult KindNodeRemoveAction)))
withNewConnectedKindNodeRemove bootstrap operation admit =
  withRecoveredKindOperation bootstrap operation $ \operationStable ->
    withConnectedDockerInfo 30000000 (bootstrapRuntimeSocket bootstrap) $ \session (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) peerStable -> do
      let stable = (&&) <$> operationStable <*> peerStable
      proposal <- observeRecordedKindNodeCreateIntent bootstrap operation stable
      case proposal of
        NodeCreateRecoveryRecorded intent
          | kindNodeCreateDaemon intent == DockerDaemonObserved identifier identity -> do
              created <- observeKindNodeCreateResult bootstrap intent stable
              case created of
                NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just containerId)) -> do
                  inspected <- inspectDockerSessionKindNode session bootstrap (kindNodeCreateInput intent) containerId
                  case inspected of
                    Right (DockerNodeContainerMatching _) -> do
                      admitted <- try (admit intent containerId session stable)
                      case (admitted :: Either IOException Bool) of
                        Right True -> do
                          removeAdmitted intent containerId session stable
                        _ -> pure NodeRemoveActionAdmissionRefused
                    other -> pure (NodeRemoveActionInspectionRefused other)
                other -> pure (NodeRemoveActionCreateResultRefused other)
          | otherwise -> pure NodeRemoveActionDaemonMismatch
        other -> pure (NodeRemoveActionProposalRefused other)
 where
  removeAdmitted intent containerId session stable = do
    written <- recordKindNodeRemoveAttempt bootstrap intent containerId stable
    case written of
      NodeRemoveAttemptRecorded -> do
        let markerStable = do
              marker <- observeKindNodeRemoveAttempt bootstrap intent containerId stable
              control <- observeKindNodeRemoveControl bootstrap intent containerId stable
              if marker /= NodeRemoveAttemptMatches || control /= NodeRemoveControlMatches
                then pure False
                else do
                  currentNode <-
                    inspectDockerSessionKindNode session bootstrap (kindNodeCreateInput intent) containerId
                  case currentNode of
                    Right (DockerNodeContainerMatching _) -> do
                      allowed <- admit intent containerId session stable
                      afterAdmission <- stable
                      pure (allowed && afterAdmission)
                    _ -> pure False
        prior <- observeKindNodeRemoveResult bootstrap intent containerId markerStable
        case prior of
          NodeRemoveResultMissing -> do
            ready <- markerStable
            if not ready
              then pure NodeRemoveActionChanged
              else do
                -- After removal, inspect may no longer find the node.
                let receiptStable =
                      (== NodeRemoveAttemptMatches) <$> observeKindNodeRemoveAttempt bootstrap intent containerId stable
                let effectStable = do
                      marker <- receiptStable
                      control <- observeKindNodeRemoveControl bootstrap intent containerId stable
                      pure (marker && control == NodeRemoveControlMatches)
                result <- removeDockerSessionKindNode session containerId markerStable effectStable
                receipt <- recordKindNodeRemoveResult bootstrap intent containerId result receiptStable
                after <- try receiptStable
                pure $ case (after :: Either IOException Bool) of
                  Right True -> NodeRemoveActionReturned result receipt
                  _ -> NodeRemoveActionChangedAfter result receipt
          other -> pure (NodeRemoveActionResultRefused other)
      NodeRemoveAttemptPositiveControlRefused control -> pure (NodeRemoveActionPositiveControlRefused control)
      other -> pure (NodeRemoveActionAttemptRefused other)
