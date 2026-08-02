{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 5.18: durable, capability-bound ownership of a canonical-suite
-- cleanup run.  The aggregate is pure; the Lifecycle Authority repository is
-- the only production interpreter allowed to persist it.
module Prodbox.Test.CleanupRun
  ( CleanupRunId
  , mkCleanupRunId
  , cleanupRunIdText
  , CleanupOwnerId
  , mkCleanupOwnerId
  , cleanupOwnerIdText
  , CleanupNodeId
  , mkCleanupNodeId
  , cleanupNodeIdText
  , CleanupOperationId
  , mkCleanupOperationId
  , CleanupAttemptId
  , mkCleanupAttemptId
  , cleanupAttemptIdText
  , CleanupDigest
  , mkCleanupDigest
  , CleanupDependencyKind (..)
  , CleanupDependency (..)
  , CleanupNodePlan
  , mkCleanupNodePlan
  , cleanupNodeId
  , cleanupNodeOperationId
  , cleanupNodeCapabilityDigest
  , cleanupNodeDependencies
  , CleanupGraph
  , cleanupGraphNodes
  , CleanupGraphError (..)
  , mkCleanupGraph
  , cleanupGraphDigest
  , CleanupPrimaryOutcome (..)
  , CleanupNodeOutcome (..)
  , CleanupNodeState (..)
  , CleanupLease (..)
  , CleanupRun (..)
  , CleanupRunError (..)
  , newCleanupRun
  , claimCleanupRun
  , recordPrimaryOutcome
  , beginCleanupNode
  , completeCleanupNode
  , cleanupRunTerminal
  , CleanupRunReport (..)
  , compactCleanupRun
  , encodeCleanupRunReport
  , decodeCleanupRunReport
  , CleanupRunCodecError (..)
  , encodeCleanupRun
  , decodeCleanupRun
  , cleanupRunCodec
  , CleanupRunSnapshot (..)
  , CleanupRunRepository (..)
  , CleanupRunStored (..)
  , cleanupRunStoredCodec
  , CleanupRunIndex (..)
  , CleanupRunIndexEntry (..)
  , CleanupRunTombstone (..)
  , emptyCleanupRunIndex
  , cleanupRunIndexCodec
  , CleanupRunIndexRepository (..)
  , CleanupRunIndexSnapshot (..)
  , modelBCleanupRunIndexRepository
  , replicatedCleanupRunIndexRepository
  , registerCleanupRun
  , compactCleanupRunIndex
  , publishCleanupRunTombstone
  , compactCleanupRunDurably
  , modelBCleanupRunRepository
  , replicatedCleanupRunRepository
  , CleanupRunStoreError (..)
  , createCleanupRunDurably
  , applyCleanupRunTransition
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAscii, isAsciiLower, isAsciiUpper, isDigit)
import Data.List (find, nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.AuthorityBackupClient
  ( AuthorityAggregateBackupClient (..)
  , AuthorityAggregateBackupObservation (..)
  )
import Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( authorityBackupCiphertextBytes
  , authorityBackupDigestText
  , authorityBackupReceiptDigest
  )
import Prodbox.ControlPlane.CapabilityRef
  ( CapabilityRef
  , refCoordinateDigest
  )
import Prodbox.ControlPlane.Coordinate (CoordinateDigest (..))
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  )
import Prodbox.Lifecycle.TargetCommitIntent (targetValueDigestText)

newtype CleanupRunId = CleanupRunId Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

newtype CleanupOwnerId = CleanupOwnerId Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

newtype CleanupNodeId = CleanupNodeId Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

newtype CleanupOperationId = CleanupOperationId Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

newtype CleanupAttemptId = CleanupAttemptId Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

newtype CleanupDigest = CleanupDigest Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

mkCleanupRunId :: Text -> Either Text CleanupRunId
mkCleanupRunId = fmap CleanupRunId . boundedIdentity "cleanup run id"

cleanupRunIdText :: CleanupRunId -> Text
cleanupRunIdText (CleanupRunId value) = value

mkCleanupOwnerId :: Text -> Either Text CleanupOwnerId
mkCleanupOwnerId = fmap CleanupOwnerId . boundedIdentity "cleanup owner id"

cleanupOwnerIdText :: CleanupOwnerId -> Text
cleanupOwnerIdText (CleanupOwnerId value) = value

mkCleanupNodeId :: Text -> Either Text CleanupNodeId
mkCleanupNodeId = fmap CleanupNodeId . boundedIdentity "cleanup node id"

cleanupNodeIdText :: CleanupNodeId -> Text
cleanupNodeIdText (CleanupNodeId value) = value

mkCleanupOperationId :: Text -> Either Text CleanupOperationId
mkCleanupOperationId = fmap CleanupOperationId . boundedIdentity "cleanup operation id"

mkCleanupAttemptId :: Text -> Either Text CleanupAttemptId
mkCleanupAttemptId = fmap CleanupAttemptId . boundedIdentity "cleanup attempt id"

cleanupAttemptIdText :: CleanupAttemptId -> Text
cleanupAttemptIdText (CleanupAttemptId value) = value

mkCleanupDigest :: Text -> Either Text CleanupDigest
mkCleanupDigest raw
  | Text.length raw /= 64 =
      Left "cleanup digest must contain exactly 64 lowercase hexadecimal characters"
  | Text.all isLowerHex raw = Right (CleanupDigest raw)
  | otherwise = Left "cleanup digest must contain exactly 64 lowercase hexadecimal characters"
 where
  isLowerHex character = character `elem` ("0123456789abcdef" :: String)

boundedIdentity :: Text -> Text -> Either Text Text
boundedIdentity label raw
  | Text.null raw = Left (label <> " must not be empty")
  | Text.length raw > 160 = Left (label <> " exceeds 160 characters")
  | Text.any (not . validIdentityCharacter) raw = Left (label <> " contains an invalid character")
  | otherwise = Right raw
 where
  validIdentityCharacter character =
    isAsciiLower character
      || isAsciiUpper character
      || (isAscii character && isDigit character)
      || character `elem` ("-._:/" :: String)

data CleanupDependencyKind
  = CleanupRequiresSuccess
  | CleanupRequiresAttempt
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data CleanupDependency = CleanupDependency
  { cleanupDependencyNode :: !CleanupNodeId
  , cleanupDependencyKind :: !CleanupDependencyKind
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data CleanupNodePlan = CleanupNodePlan
  { cleanupNodeId :: !CleanupNodeId
  , cleanupNodeOperationId :: !CleanupOperationId
  , cleanupNodeCapabilityDigest :: !Text
  , cleanupNodeDependencies :: ![CleanupDependency]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The capability digest can enter a plan only through the opaque indexed
-- reference used by both admission and execution.
mkCleanupNodePlan
  :: CapabilityRef capability
  -> CleanupNodeId
  -> CleanupOperationId
  -> [CleanupDependency]
  -> CleanupNodePlan
mkCleanupNodePlan capability nodeId operationId dependencies =
  CleanupNodePlan
    { cleanupNodeId = nodeId
    , cleanupNodeOperationId = operationId
    , cleanupNodeCapabilityDigest = coordinateDigestText (refCoordinateDigest capability)
    , cleanupNodeDependencies = dependencies
    }

coordinateDigestText :: CoordinateDigest -> Text
coordinateDigestText (CoordinateDigest digest) = targetValueDigestText digest

newtype CleanupGraph = CleanupGraph
  { cleanupGraphNodes :: [CleanupNodePlan]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CleanupGraphError
  = CleanupGraphEmpty
  | CleanupGraphDuplicateNode !CleanupNodeId
  | CleanupGraphDuplicateOperation !CleanupOperationId
  | CleanupGraphUnknownDependency !CleanupNodeId !CleanupNodeId
  | CleanupGraphSelfDependency !CleanupNodeId
  | CleanupGraphCyclic
  deriving stock (Eq, Show)

mkCleanupGraph :: [CleanupNodePlan] -> Either CleanupGraphError CleanupGraph
mkCleanupGraph nodes = do
  if null nodes then Left CleanupGraphEmpty else Right ()
  refuseDuplicate CleanupGraphDuplicateNode (map cleanupNodeId nodes)
  refuseDuplicate CleanupGraphDuplicateOperation (map cleanupNodeOperationId nodes)
  mapM_ validateDependencies nodes
  if graphAcyclic nodes then Right (CleanupGraph nodes) else Left CleanupGraphCyclic
 where
  nodeIds = Set.fromList (map cleanupNodeId nodes)
  refuseDuplicate constructor values =
    case find (\value -> length (filter (== value) values) > 1) (nub values) of
      Nothing -> Right ()
      Just value -> Left (constructor value)
  validateDependencies node =
    mapM_ (validateDependency (cleanupNodeId node)) (cleanupNodeDependencies node)
  validateDependency owner dependency
    | cleanupDependencyNode dependency == owner = Left (CleanupGraphSelfDependency owner)
    | cleanupDependencyNode dependency `Set.notMember` nodeIds =
        Left (CleanupGraphUnknownDependency owner (cleanupDependencyNode dependency))
    | otherwise = Right ()

graphAcyclic :: [CleanupNodePlan] -> Bool
graphAcyclic nodes = go Set.empty Set.empty (map cleanupNodeId nodes)
 where
  table = Map.fromList [(cleanupNodeId node, cleanupNodeDependencies node) | node <- nodes]
  go _ _ [] = True
  go permanent temporary (node : rest) =
    case visit permanent temporary node of
      Nothing -> False
      Just permanent' -> go permanent' Set.empty rest
  visit permanent temporary node
    | node `Set.member` permanent = Just permanent
    | node `Set.member` temporary = Nothing
    | otherwise = do
        let dependencies = maybe [] (map cleanupDependencyNode) (Map.lookup node table)
        permanent' <- foldVisit permanent (Set.insert node temporary) dependencies
        pure (Set.insert node permanent')
  foldVisit permanent _ [] = Just permanent
  foldVisit permanent temporary (node : rest) = do
    permanent' <- visit permanent temporary node
    foldVisit permanent' temporary rest

cleanupGraphDigest :: CleanupGraph -> CleanupDigest
cleanupGraphDigest = CleanupDigest . sha256Text . LazyByteString.toStrict . serialise

data CleanupPrimaryOutcome
  = CleanupPrimarySucceeded
  | CleanupPrimaryFailed !Text
  | CleanupPrimaryCancelled
  | CleanupPrimaryRunnerLost
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CleanupNodeOutcome
  = CleanupNodeSucceeded
  | CleanupNodeFailed !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CleanupNodeState
  = CleanupNodePending
  | CleanupNodeRunning !CleanupAttemptId
  | CleanupNodeCompleted !CleanupAttemptId !CleanupNodeOutcome
  | CleanupNodeBlocked ![CleanupNodeId]
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CleanupLease = CleanupLease
  { cleanupLeaseOwner :: !CleanupOwnerId
  , cleanupLeaseFence :: !Natural
  , cleanupLeaseExpiresAtMicros :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CleanupRun = CleanupRun
  { cleanupRunId :: !CleanupRunId
  , cleanupRunGraphDigest :: !CleanupDigest
  , cleanupRunGraph :: !CleanupGraph
  , cleanupRunLease :: !CleanupLease
  , cleanupRunPrimaryOutcome :: !(Maybe CleanupPrimaryOutcome)
  , cleanupRunNodeStates :: !(Map CleanupNodeId CleanupNodeState)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CleanupRunError
  = CleanupLeaseInvalid
  | CleanupLeaseHeld !CleanupOwnerId
  | CleanupFenceMismatch !Natural !Natural
  | CleanupOwnerMismatch
  | CleanupPrimaryAlreadyRecorded
  | CleanupNodeUnknown !CleanupNodeId
  | CleanupNodeNotPending !CleanupNodeId
  | CleanupNodeNotRunning !CleanupNodeId
  | CleanupAttemptConflict !CleanupNodeId
  | CleanupDependenciesUnsatisfied !CleanupNodeId ![CleanupNodeId]
  | CleanupRunNotTerminal
  deriving stock (Eq, Show)

newCleanupRun
  :: CleanupRunId
  -> CleanupGraph
  -> CleanupOwnerId
  -> Natural
  -> Natural
  -> Either CleanupRunError CleanupRun
newCleanupRun runId graph owner now expires
  | expires <= now = Left CleanupLeaseInvalid
  | otherwise =
      Right
        CleanupRun
          { cleanupRunId = runId
          , cleanupRunGraphDigest = cleanupGraphDigest graph
          , cleanupRunGraph = graph
          , cleanupRunLease = CleanupLease owner 1 expires
          , cleanupRunPrimaryOutcome = Nothing
          , cleanupRunNodeStates =
              Map.fromList [(cleanupNodeId node, CleanupNodePending) | node <- cleanupGraphNodes graph]
          }

claimCleanupRun
  :: CleanupOwnerId
  -> Natural
  -> Natural
  -> CleanupRun
  -> Either CleanupRunError CleanupRun
claimCleanupRun owner now expires run
  | expires <= now = Left CleanupLeaseInvalid
  | cleanupRunTerminal run = Right run
  | now < cleanupLeaseExpiresAtMicros lease && owner /= cleanupLeaseOwner lease =
      Left (CleanupLeaseHeld (cleanupLeaseOwner lease))
  | now < cleanupLeaseExpiresAtMicros lease =
      Right run {cleanupRunLease = lease {cleanupLeaseExpiresAtMicros = expires}}
  | otherwise =
      Right
        run
          { cleanupRunLease =
              CleanupLease owner (cleanupLeaseFence lease + 1) expires
          , cleanupRunPrimaryOutcome =
              case cleanupRunPrimaryOutcome run of
                Nothing | now >= cleanupLeaseExpiresAtMicros lease -> Just CleanupPrimaryRunnerLost
                existing -> existing
          , cleanupRunNodeStates = Map.map recoverRunning (cleanupRunNodeStates run)
          }
 where
  lease = cleanupRunLease run
  recoverRunning state = case state of
    CleanupNodeRunning _ | now >= cleanupLeaseExpiresAtMicros lease -> CleanupNodePending
    other -> other

recordPrimaryOutcome
  :: CleanupOwnerId
  -> Natural
  -> CleanupPrimaryOutcome
  -> CleanupRun
  -> Either CleanupRunError CleanupRun
recordPrimaryOutcome owner fence outcome run = do
  validateOwner owner fence run
  case cleanupRunPrimaryOutcome run of
    Nothing -> Right run {cleanupRunPrimaryOutcome = Just outcome}
    Just observed | observed == outcome -> Right run
    Just _ -> Left CleanupPrimaryAlreadyRecorded

beginCleanupNode
  :: CleanupOwnerId
  -> Natural
  -> CleanupNodeId
  -> CleanupAttemptId
  -> CleanupRun
  -> Either CleanupRunError CleanupRun
beginCleanupNode owner fence nodeId attempt run = do
  validateOwner owner fence run
  plan <-
    maybe
      (Left (CleanupNodeUnknown nodeId))
      Right
      (find ((== nodeId) . cleanupNodeId) (cleanupGraphNodes (cleanupRunGraph run)))
  state <-
    maybe (Left (CleanupNodeUnknown nodeId)) Right (Map.lookup nodeId (cleanupRunNodeStates run))
  case state of
    CleanupNodePending -> do
      let blockers = unsatisfiedDependencies run plan
      if null blockers
        then
          Right
            run
              { cleanupRunNodeStates =
                  Map.insert nodeId (CleanupNodeRunning attempt) (cleanupRunNodeStates run)
              }
        else Left (CleanupDependenciesUnsatisfied nodeId blockers)
    CleanupNodeRunning observedAttempt | observedAttempt == attempt -> Right run
    _ -> Left (CleanupNodeNotPending nodeId)

completeCleanupNode
  :: CleanupOwnerId
  -> Natural
  -> CleanupNodeId
  -> CleanupAttemptId
  -> CleanupNodeOutcome
  -> CleanupRun
  -> Either CleanupRunError CleanupRun
completeCleanupNode owner fence nodeId attempt outcome run = do
  validateOwner owner fence run
  state <-
    maybe (Left (CleanupNodeUnknown nodeId)) Right (Map.lookup nodeId (cleanupRunNodeStates run))
  case state of
    CleanupNodeRunning observedAttempt
      | observedAttempt == attempt ->
          Right
            ( settleBlockedCleanupNodes
                run
                  { cleanupRunNodeStates =
                      Map.insert nodeId (CleanupNodeCompleted attempt outcome) (cleanupRunNodeStates run)
                  }
            )
      | otherwise -> Left (CleanupAttemptConflict nodeId)
    CleanupNodeCompleted observedAttempt observedOutcome
      | observedAttempt == attempt && observedOutcome == outcome -> Right run
      | otherwise -> Left (CleanupAttemptConflict nodeId)
    _ -> Left (CleanupNodeNotRunning nodeId)

validateOwner :: CleanupOwnerId -> Natural -> CleanupRun -> Either CleanupRunError ()
validateOwner owner fence run
  | cleanupLeaseOwner lease /= owner = Left CleanupOwnerMismatch
  | cleanupLeaseFence lease /= fence = Left (CleanupFenceMismatch fence (cleanupLeaseFence lease))
  | otherwise = Right ()
 where
  lease = cleanupRunLease run

unsatisfiedDependencies :: CleanupRun -> CleanupNodePlan -> [CleanupNodeId]
unsatisfiedDependencies run plan =
  [ cleanupDependencyNode dependency
  | dependency <- cleanupNodeDependencies plan
  , not (dependencySatisfied dependency)
  ]
 where
  dependencySatisfied dependency =
    case Map.lookup (cleanupDependencyNode dependency) (cleanupRunNodeStates run) of
      Just (CleanupNodeCompleted _ CleanupNodeSucceeded) -> True
      Just (CleanupNodeCompleted _ (CleanupNodeFailed _)) ->
        cleanupDependencyKind dependency == CleanupRequiresAttempt
      _ -> False

settleBlockedCleanupNodes :: CleanupRun -> CleanupRun
settleBlockedCleanupNodes run =
  let updated = foldl settleOne (cleanupRunNodeStates run) (cleanupGraphNodes (cleanupRunGraph run))
      next = run {cleanupRunNodeStates = updated}
   in if updated == cleanupRunNodeStates run then run else settleBlockedCleanupNodes next
 where
  settleOne states plan = case Map.lookup (cleanupNodeId plan) states of
    Just CleanupNodePending ->
      case terminalBlockers states plan of
        [] -> states
        blockers -> Map.insert (cleanupNodeId plan) (CleanupNodeBlocked blockers) states
    _ -> states
  terminalBlockers states plan =
    [ cleanupDependencyNode dependency
    | dependency <- cleanupNodeDependencies plan
    , dependencyBlocks states dependency
    ]
  dependencyBlocks states dependency =
    case Map.lookup (cleanupDependencyNode dependency) states of
      Just (CleanupNodeBlocked _) -> True
      Just (CleanupNodeCompleted _ (CleanupNodeFailed _)) ->
        cleanupDependencyKind dependency == CleanupRequiresSuccess
      _ -> False

cleanupRunTerminal :: CleanupRun -> Bool
cleanupRunTerminal run =
  cleanupRunPrimaryOutcome run /= Nothing
    && all terminalNode (Map.elems (cleanupRunNodeStates run))
 where
  terminalNode state = case state of
    CleanupNodeCompleted {} -> True
    CleanupNodeBlocked {} -> True
    _ -> False

data CleanupRunReport = CleanupRunReport
  { cleanupReportRunId :: !CleanupRunId
  , cleanupReportGraphDigest :: !CleanupDigest
  , cleanupReportPrimaryOutcome :: !CleanupPrimaryOutcome
  , cleanupReportNodeStates :: !(Map CleanupNodeId CleanupNodeState)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

compactCleanupRun :: CleanupRun -> Either CleanupRunError CleanupRunReport
compactCleanupRun run
  | not (cleanupRunTerminal run) = Left CleanupRunNotTerminal
  | otherwise = case cleanupRunPrimaryOutcome run of
      Nothing -> Left CleanupRunNotTerminal
      Just primary ->
        Right
          CleanupRunReport
            { cleanupReportRunId = cleanupRunId run
            , cleanupReportGraphDigest = cleanupRunGraphDigest run
            , cleanupReportPrimaryOutcome = primary
            , cleanupReportNodeStates = cleanupRunNodeStates run
            }

data CleanupRunReportEnvelope = CleanupRunReportEnvelope !Word16 !CleanupRunReport
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

encodeCleanupRunReport :: Int -> CleanupRunReport -> Either CleanupRunCodecError ByteString
encodeCleanupRunReport maximumBytes report =
  let bytes = LazyByteString.toStrict (serialise (CleanupRunReportEnvelope 1 report))
   in if ByteString.length bytes > maximumBytes
        then Left (CleanupRunEnvelopeTooLarge (ByteString.length bytes) maximumBytes)
        else Right bytes

decodeCleanupRunReport :: Int -> ByteString -> Either CleanupRunCodecError CleanupRunReport
decodeCleanupRunReport maximumBytes bytes
  | maximumBytes < 0 || ByteString.length bytes > maximumBytes =
      Left (CleanupRunEnvelopeTooLarge (ByteString.length bytes) maximumBytes)
  | otherwise = case deserialiseOrFail (LazyByteString.fromStrict bytes) of
      Left _ -> Left CleanupRunEnvelopeInvalid
      Right envelope@(CleanupRunReportEnvelope version report)
        | version /= 1 -> Left (CleanupRunEnvelopeUnsupportedVersion version)
        | LazyByteString.toStrict (serialise envelope) /= bytes -> Left CleanupRunEnvelopeNonCanonical
        | Map.null (cleanupReportNodeStates report) -> Left CleanupRunEnvelopeInvalid
        | otherwise -> Right report

data CleanupRunEnvelope = CleanupRunEnvelope
  { cleanupRunEnvelopeVersion :: !Word16
  , cleanupRunEnvelopeValue :: !CleanupRun
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CleanupRunCodecError
  = CleanupRunEnvelopeTooLarge !Int !Int
  | CleanupRunEnvelopeInvalid
  | CleanupRunEnvelopeUnsupportedVersion !Word16
  | CleanupRunEnvelopeNonCanonical
  deriving stock (Eq, Show)

encodeCleanupRun :: Int -> CleanupRun -> Either CleanupRunCodecError ByteString
encodeCleanupRun maximumBytes run =
  let bytes = LazyByteString.toStrict (serialise (CleanupRunEnvelope 1 run))
   in if ByteString.length bytes > maximumBytes
        then Left (CleanupRunEnvelopeTooLarge (ByteString.length bytes) maximumBytes)
        else Right bytes

decodeCleanupRun :: Int -> ByteString -> Either CleanupRunCodecError CleanupRun
decodeCleanupRun maximumBytes bytes
  | maximumBytes < 0 || ByteString.length bytes > maximumBytes =
      Left (CleanupRunEnvelopeTooLarge (ByteString.length bytes) maximumBytes)
  | otherwise = case deserialiseOrFail (LazyByteString.fromStrict bytes) of
      Left _ -> Left CleanupRunEnvelopeInvalid
      Right envelope
        | cleanupRunEnvelopeVersion envelope /= 1 ->
            Left (CleanupRunEnvelopeUnsupportedVersion (cleanupRunEnvelopeVersion envelope))
        | LazyByteString.toStrict (serialise envelope) /= bytes -> Left CleanupRunEnvelopeNonCanonical
        | otherwise -> validateDecodedCleanupRun (cleanupRunEnvelopeValue envelope)

validateDecodedCleanupRun :: CleanupRun -> Either CleanupRunCodecError CleanupRun
validateDecodedCleanupRun run = do
  graph <-
    either
      (const (Left CleanupRunEnvelopeInvalid))
      Right
      (mkCleanupGraph (cleanupGraphNodes (cleanupRunGraph run)))
  let expectedNodeIds = Set.fromList (map cleanupNodeId (cleanupGraphNodes graph))
      observedNodeIds = Map.keysSet (cleanupRunNodeStates run)
      lease = cleanupRunLease run
  if expectedNodeIds /= observedNodeIds
    || cleanupRunGraphDigest run /= cleanupGraphDigest graph
    || cleanupLeaseFence lease == 0
    || cleanupLeaseExpiresAtMicros lease == 0
    then Left CleanupRunEnvelopeInvalid
    else Right run

cleanupRunCodec :: Int -> ModelBCodec CleanupRun
cleanupRunCodec maximumBytes =
  ModelBCodec
    { encodeModelBValue = either (Left . show) Right . encodeCleanupRun maximumBytes
    , decodeModelBValue = either (Left . show) Right . decodeCleanupRun maximumBytes
    }

data CleanupRunSnapshot revision
  = CleanupRunMissing
  | CleanupRunObserved !revision !CleanupRun
  | CleanupRunTombstoned !revision !CleanupRunTombstone
  deriving stock (Eq, Show)

data CleanupRunRepository m revision = CleanupRunRepository
  { readCleanupRun :: m (Either Text (CleanupRunSnapshot revision))
  , compareAndSwapCleanupRun
      :: Maybe revision
      -> CleanupRun
      -> m (Either Text ())
  , compareAndSwapCleanupRunTombstone
      :: revision
      -> CleanupRunTombstone
      -> m (Either Text ())
  }

data CleanupRunStored
  = CleanupRunStoredActive !CleanupRun
  | CleanupRunStoredTombstone !CleanupRunTombstone
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CleanupRunStoredEnvelope = CleanupRunStoredEnvelope !Word16 !CleanupRunStored
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

cleanupRunStoredCodec :: Int -> ModelBCodec CleanupRunStored
cleanupRunStoredCodec maximumBytes =
  ModelBCodec
    { encodeModelBValue = \stored ->
        let bytes = LazyByteString.toStrict (serialise (CleanupRunStoredEnvelope 1 stored))
         in if ByteString.length bytes > maximumBytes
              then Left "stored cleanup run exceeds its encoded bound"
              else Right bytes
    , decodeModelBValue = \bytes ->
        if ByteString.length bytes > maximumBytes
          then Left "stored cleanup run exceeds its encoded bound"
          else case deserialiseOrFail (LazyByteString.fromStrict bytes) of
            Left _ -> Left "stored cleanup run is invalid"
            Right envelope@(CleanupRunStoredEnvelope version stored)
              | version /= 1 -> Left "stored cleanup run version is unsupported"
              | LazyByteString.toStrict (serialise envelope) /= bytes ->
                  Left "stored cleanup run is non-canonical"
              | otherwise -> validateStored stored
    }
 where
  validateStored stored = case stored of
    CleanupRunStoredActive run ->
      either (Left . show) (const (Right stored)) (validateDecodedCleanupRun run)
    CleanupRunStoredTombstone tombstone ->
      case mkCleanupDigest (cleanupRunTombstoneReportDigest tombstone) of
        Left detail -> Left (Text.unpack detail)
        Right _ -> Right stored

data CleanupRunTombstone = CleanupRunTombstone
  { cleanupRunTombstoneId :: !CleanupRunId
  , cleanupRunTombstoneReportDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CleanupRunIndexEntry
  = CleanupRunIndexActive !CleanupRun
  | CleanupRunIndexTombstone !CleanupRunTombstone
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

newtype CleanupRunIndex = CleanupRunIndex
  { cleanupRunIndexEntries :: [CleanupRunIndexEntry]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

emptyCleanupRunIndex :: CleanupRunIndex
emptyCleanupRunIndex = CleanupRunIndex []

data CleanupRunIndexEnvelope = CleanupRunIndexEnvelope !Word16 !CleanupRunIndex
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

cleanupRunIndexCodec :: Int -> ModelBCodec CleanupRunIndex
cleanupRunIndexCodec maximumBytes =
  ModelBCodec
    { encodeModelBValue = encodeIndex
    , decodeModelBValue = decodeIndex
    }
 where
  encodeIndex index =
    let bytes = LazyByteString.toStrict (serialise (CleanupRunIndexEnvelope 1 index))
     in if ByteString.length bytes > maximumBytes
          then Left "cleanup run index exceeds its encoded bound"
          else Right bytes
  decodeIndex bytes
    | ByteString.length bytes > maximumBytes = Left "cleanup run index exceeds its encoded bound"
    | otherwise = case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left "cleanup run index is invalid"
        Right envelope@(CleanupRunIndexEnvelope version index)
          | version /= 1 -> Left "cleanup run index version is unsupported"
          | LazyByteString.toStrict (serialise envelope) /= bytes -> Left "cleanup run index is non-canonical"
          | length (cleanupRunIndexEntries index) > 256 -> Left "cleanup run index exceeds 256 entries"
          | length (nub (map indexEntryRunId (cleanupRunIndexEntries index)))
              /= length (cleanupRunIndexEntries index) ->
              Left "cleanup run index contains duplicate run ids"
          | otherwise -> index <$ mapM validateIndexEntry (cleanupRunIndexEntries index)

  validateIndexEntry entry = case entry of
    CleanupRunIndexActive run ->
      either (Left . show) (const (Right ())) (validateDecodedCleanupRun run)
    CleanupRunIndexTombstone tombstone ->
      case mkCleanupDigest (cleanupRunTombstoneReportDigest tombstone) of
        Left detail -> Left (Text.unpack detail)
        Right _ -> Right ()

indexEntryRunId :: CleanupRunIndexEntry -> CleanupRunId
indexEntryRunId entry = case entry of
  CleanupRunIndexActive run -> cleanupRunId run
  CleanupRunIndexTombstone tombstone -> cleanupRunTombstoneId tombstone

data CleanupRunIndexSnapshot revision
  = CleanupRunIndexMissing
  | CleanupRunIndexObserved !revision !CleanupRunIndex
  deriving stock (Eq, Show)

data CleanupRunIndexRepository m revision = CleanupRunIndexRepository
  { readCleanupRunIndex :: m (Either Text (CleanupRunIndexSnapshot revision))
  , compareAndSwapCleanupRunIndex
      :: Maybe revision
      -> CleanupRunIndex
      -> m (Either Text ())
  }

modelBCleanupRunIndexRepository
  :: (Monad m)
  => ModelBCasAdapter 'ClusterRetained m CleanupRunIndex
  -> ModelBObjectCoordinate 'ClusterRetained
  -> CleanupRunIndexRepository m ModelBObjectVersion
modelBCleanupRunIndexRepository adapter coordinate =
  CleanupRunIndexRepository
    { readCleanupRunIndex = do
        observed <- modelBObserve adapter coordinate
        pure $ case observed of
          ModelBMissing -> Right CleanupRunIndexMissing
          ModelBObserved revision index -> Right (CleanupRunIndexObserved revision index)
          ModelBCorrupt detail -> Left ("cleanup run index is corrupt: " <> detail)
          ModelBEndpointUnready detail -> Left ("cleanup run index endpoint is not ready: " <> detail)
          ModelBUnobservable detail -> Left ("cleanup run index is unobservable: " <> detail)
    , compareAndSwapCleanupRunIndex = \expected index -> do
        result <- modelBCompareAndSwap adapter $ case expected of
          Nothing -> ModelBInitialize coordinate index
          Just revision -> ModelBReplace coordinate revision index
        pure $ case result of
          ModelBCasApplied _ _ -> Right ()
          ModelBCasConflict _ -> Left "cleanup run index CAS conflict"
          ModelBCasRefusedCorrupt detail -> Left ("cleanup run index CAS refused corrupt state: " <> detail)
          ModelBCasEndpointUnready detail -> Left ("cleanup run index CAS endpoint is not ready: " <> detail)
          ModelBCasUnobservable detail -> Left ("cleanup run index CAS is unobservable: " <> detail)
    }

replicatedCleanupRunIndexRepository
  :: Int
  -> AuthorityAggregateBackupClient IO
  -> CleanupRunIndexRepository IO revision
  -> CleanupRunIndexRepository IO revision
replicatedCleanupRunIndexRepository maximumBytes backup primary =
  CleanupRunIndexRepository
    { readCleanupRunIndex = do
        observed <- readCleanupRunIndex primary
        case observed of
          Left detail -> pure (Left detail)
          Right CleanupRunIndexMissing -> pure (Right CleanupRunIndexMissing)
          Right snapshot@(CleanupRunIndexObserved _ index) -> do
            verified <- verifyIndexBackup index
            pure (snapshot <$ verified)
    , compareAndSwapCleanupRunIndex = \expected index -> do
        verified <- publishIndexBackup index
        case verified of
          Left detail -> pure (Left detail)
          Right () -> compareAndSwapCleanupRunIndex primary expected index
    }
 where
  canonical index = firstText (encodeModelBValue (cleanupRunIndexCodec maximumBytes) index)
  publishIndexBackup index = case canonical index of
    Left detail -> pure (Left detail)
    Right bytes -> do
      copied <- copyAuthorityAggregateBackup backup bytes
      case copied of
        Left err -> pure (Left ("cleanup index backup copy failed: " <> Text.pack (show err)))
        Right receipt -> verify bytes (authorityBackupDigestText (authorityBackupReceiptDigest receipt))
  verifyIndexBackup index = case canonical index of
    Left detail -> pure (Left detail)
    Right bytes -> verify bytes (sha256Text bytes)
  verify bytes digest = do
    observed <- observeAuthorityAggregateBackup backup digest
    pure $ case observed of
      Left err -> Left ("cleanup index backup observation failed: " <> Text.pack (show err))
      Right AuthorityAggregateBackupMissing -> Left "cleanup index backup is missing"
      Right (AuthorityAggregateBackupCorrupt detail) -> Left ("cleanup index backup is corrupt: " <> detail)
      Right (AuthorityAggregateBackupCurrent ciphertext receipt)
        | authorityBackupCiphertextBytes ciphertext /= bytes ->
            Left "cleanup index primary and backup bytes differ"
        | authorityBackupDigestText (authorityBackupReceiptDigest receipt) /= digest ->
            Left "cleanup index backup receipt digest mismatch"
        | otherwise -> Right ()
  firstText = either (Left . Text.pack) Right

registerCleanupRun
  :: (Monad m)
  => CleanupRunIndexRepository m revision
  -> CleanupRun
  -> m (Either Text CleanupRunIndex)
registerCleanupRun repository run = do
  observed <- readCleanupRunIndex repository
  case observed of
    Left detail -> pure (Left detail)
    Right CleanupRunIndexMissing -> commit Nothing (CleanupRunIndex [CleanupRunIndexActive run])
    Right (CleanupRunIndexObserved revision index)
      | Just existing <- find ((== cleanupRunId run) . indexEntryRunId) (cleanupRunIndexEntries index) ->
          case existing of
            CleanupRunIndexActive existingRun
              | existingRun == run -> pure (Right index)
            _ -> pure (Left "cleanup run id is already registered and cannot be reused")
      | length (cleanupRunIndexEntries index) >= 256 ->
          pure (Left "cleanup run index capacity is exhausted")
      | otherwise ->
          commit
            (Just revision)
            (CleanupRunIndex (cleanupRunIndexEntries index ++ [CleanupRunIndexActive run]))
 where
  commit expected index = do
    committed <- compareAndSwapCleanupRunIndex repository expected index
    case committed of
      Right () -> confirm index
      Left detail -> do
        readBack <- confirm index
        pure (either (const (Left detail)) Right readBack)
  confirm expected = do
    observed <- readCleanupRunIndex repository
    pure $ case observed of
      Right (CleanupRunIndexObserved _ actual) | actual == expected -> Right actual
      Left detail -> Left detail
      _ -> Left "cleanup run index read-back mismatch"

compactCleanupRunIndex
  :: (Monad m)
  => CleanupRunIndexRepository m revision
  -> CleanupRun
  -> Text
  -> m (Either Text CleanupRunIndex)
compactCleanupRunIndex repository run reportDigest =
  case mkCleanupDigest reportDigest of
    Left detail -> pure (Left detail)
    Right _ -> do
      observed <- readCleanupRunIndex repository
      case observed of
        Left detail -> pure (Left detail)
        Right CleanupRunIndexMissing -> pure (Left "cleanup run index is missing")
        Right (CleanupRunIndexObserved revision index) ->
          case find ((== cleanupRunId run) . indexEntryRunId) (cleanupRunIndexEntries index) of
            Nothing -> pure (Left "cleanup run is not registered")
            Just (CleanupRunIndexTombstone tombstone)
              | cleanupRunTombstoneReportDigest tombstone == reportDigest -> pure (Right index)
              | otherwise -> pure (Left "cleanup run tombstone report digest conflicts")
            Just (CleanupRunIndexActive registered)
              | not (sameImmutablePlan registered run) ->
                  pure (Left "cleanup run immutable plan differs from its registration")
              | not (cleanupRunTerminal run) -> pure (Left "cleanup run is not terminal")
              | otherwise -> commit revision index
 where
  sameImmutablePlan left right =
    cleanupRunId left == cleanupRunId right
      && cleanupRunGraphDigest left == cleanupRunGraphDigest right
      && cleanupRunGraph left == cleanupRunGraph right
  commit revision index = do
    let tombstone = CleanupRunTombstone (cleanupRunId run) reportDigest
        replace entry
          | indexEntryRunId entry == cleanupRunId run = CleanupRunIndexTombstone tombstone
          | otherwise = entry
        expected = CleanupRunIndex (map replace (cleanupRunIndexEntries index))
    committed <- compareAndSwapCleanupRunIndex repository (Just revision) expected
    case committed of
      Right () -> confirm expected
      Left detail -> do
        readBack <- confirm expected
        pure (either (const (Left detail)) Right readBack)
  confirm expected = do
    observed <- readCleanupRunIndex repository
    pure $ case observed of
      Right (CleanupRunIndexObserved _ actual) | actual == expected -> Right actual
      Left detail -> Left detail
      _ -> Left "cleanup run index compaction read-back mismatch"

compactCleanupRunDurably
  :: (Monad m)
  => Int
  -> AuthorityAggregateBackupClient m
  -> CleanupRunRepository m revision
  -> CleanupRunIndexRepository m revision
  -> CleanupRun
  -> m (Either Text CleanupRunReport)
compactCleanupRunDurably maximumBytes backup runRepository indexRepository run =
  case compactCleanupRun run of
    Left detail -> pure (Left (Text.pack (show detail)))
    Right report -> case encodeCleanupRunReport maximumBytes report of
      Left detail -> pure (Left (Text.pack (show detail)))
      Right bytes -> do
        copied <- copyAuthorityAggregateBackup backup bytes
        case copied of
          Left detail -> pure (Left ("cleanup report backup copy failed: " <> Text.pack (show detail)))
          Right receipt -> do
            let digest = authorityBackupDigestText (authorityBackupReceiptDigest receipt)
            observed <- observeAuthorityAggregateBackup backup digest
            case observed of
              Left detail -> pure (Left ("cleanup report backup observation failed: " <> Text.pack (show detail)))
              Right AuthorityAggregateBackupMissing -> pure (Left "cleanup report backup is missing")
              Right (AuthorityAggregateBackupCorrupt detail) -> pure (Left ("cleanup report backup is corrupt: " <> detail))
              Right (AuthorityAggregateBackupCurrent ciphertext observedReceipt)
                | authorityBackupCiphertextBytes ciphertext /= bytes ->
                    pure (Left "cleanup report backup bytes differ")
                | authorityBackupReceiptDigest observedReceipt /= authorityBackupReceiptDigest receipt ->
                    pure (Left "cleanup report backup receipt differs")
                | otherwise -> do
                    stored <- compactCleanupRunStorage runRepository run digest
                    case stored of
                      Left detail -> pure (Left detail)
                      Right tombstone -> do
                        compacted <- publishCleanupRunTombstone indexRepository tombstone
                        pure (report <$ compacted)

compactCleanupRunStorage
  :: (Monad m)
  => CleanupRunRepository m revision
  -> CleanupRun
  -> Text
  -> m (Either Text CleanupRunTombstone)
compactCleanupRunStorage repository run reportDigest = do
  observed <- readCleanupRun repository
  case observed of
    Left detail -> pure (Left detail)
    Right CleanupRunMissing -> pure (Left "cleanup run primary is missing during compaction")
    Right (CleanupRunTombstoned _ tombstone)
      | cleanupRunTombstoneId tombstone == cleanupRunId run
          && cleanupRunTombstoneReportDigest tombstone == reportDigest ->
          pure (Right tombstone)
      | otherwise -> pure (Left "cleanup run tombstone conflicts")
    Right (CleanupRunObserved revision current)
      | current /= run -> pure (Left "cleanup run changed before compaction")
      | not (cleanupRunTerminal current) -> pure (Left "cleanup run is not terminal")
      | otherwise -> do
          let tombstone = CleanupRunTombstone (cleanupRunId run) reportDigest
          committed <- compareAndSwapCleanupRunTombstone repository revision tombstone
          case committed of
            Right () -> confirm tombstone
            Left detail -> do
              readBack <- confirm tombstone
              pure (either (const (Left detail)) Right readBack)
 where
  confirm expected = do
    observed <- readCleanupRun repository
    pure $ case observed of
      Right (CleanupRunTombstoned _ actual) | actual == expected -> Right actual
      Left detail -> Left detail
      _ -> Left "cleanup run tombstone read-back mismatch"

publishCleanupRunTombstone
  :: (Monad m)
  => CleanupRunIndexRepository m revision
  -> CleanupRunTombstone
  -> m (Either Text CleanupRunIndex)
publishCleanupRunTombstone repository tombstone = do
  observed <- readCleanupRunIndex repository
  case observed of
    Left detail -> pure (Left detail)
    Right CleanupRunIndexMissing -> pure (Left "cleanup run index is missing")
    Right (CleanupRunIndexObserved revision index) ->
      case find ((== cleanupRunTombstoneId tombstone) . indexEntryRunId) (cleanupRunIndexEntries index) of
        Nothing -> pure (Left "cleanup run is not registered")
        Just (CleanupRunIndexTombstone existing)
          | existing == tombstone -> pure (Right index)
          | otherwise -> pure (Left "cleanup run tombstone conflicts")
        Just (CleanupRunIndexActive _) -> commit revision index
 where
  commit revision index = do
    let replace entry
          | indexEntryRunId entry == cleanupRunTombstoneId tombstone = CleanupRunIndexTombstone tombstone
          | otherwise = entry
        expected = CleanupRunIndex (map replace (cleanupRunIndexEntries index))
    committed <- compareAndSwapCleanupRunIndex repository (Just revision) expected
    case committed of
      Right () -> confirm expected
      Left detail -> do
        readBack <- confirm expected
        pure (either (const (Left detail)) Right readBack)
  confirm expected = do
    observed <- readCleanupRunIndex repository
    pure $ case observed of
      Right (CleanupRunIndexObserved _ actual) | actual == expected -> Right actual
      Left detail -> Left detail
      _ -> Left "cleanup run index tombstone read-back mismatch"

modelBCleanupRunRepository
  :: (Monad m)
  => ModelBCasAdapter 'ClusterRetained m CleanupRunStored
  -> ModelBObjectCoordinate 'ClusterRetained
  -> CleanupRunRepository m ModelBObjectVersion
modelBCleanupRunRepository adapter coordinate =
  CleanupRunRepository
    { readCleanupRun = do
        observed <- modelBObserve adapter coordinate
        pure $ case observed of
          ModelBMissing -> Right CleanupRunMissing
          ModelBObserved revision stored -> case stored of
            CleanupRunStoredActive run -> Right (CleanupRunObserved revision run)
            CleanupRunStoredTombstone tombstone -> Right (CleanupRunTombstoned revision tombstone)
          ModelBCorrupt detail -> Left ("cleanup run is corrupt: " <> detail)
          ModelBEndpointUnready detail -> Left ("cleanup run endpoint is not ready: " <> detail)
          ModelBUnobservable detail -> Left ("cleanup run is unobservable: " <> detail)
    , compareAndSwapCleanupRun = \expected run -> do
        result <- modelBCompareAndSwap adapter $ case expected of
          Nothing -> ModelBInitialize coordinate (CleanupRunStoredActive run)
          Just revision -> ModelBReplace coordinate revision (CleanupRunStoredActive run)
        pure $ projectCas result
    , compareAndSwapCleanupRunTombstone = \revision tombstone -> do
        result <-
          modelBCompareAndSwap
            adapter
            (ModelBReplace coordinate revision (CleanupRunStoredTombstone tombstone))
        pure $ projectCas result
    }
 where
  projectCas result = case result of
    ModelBCasApplied _ _ -> Right ()
    ModelBCasConflict _ -> Left "cleanup run CAS conflict"
    ModelBCasRefusedCorrupt detail -> Left ("cleanup run CAS refused corrupt state: " <> detail)
    ModelBCasEndpointUnready detail -> Left ("cleanup run CAS endpoint is not ready: " <> detail)
    ModelBCasUnobservable detail -> Left ("cleanup run CAS is unobservable: " <> detail)

-- | Require an immutable Authority-Backup receipt for the exact canonical run
-- bytes before the primary CAS may publish them. Reads likewise accept a
-- primary value only when the independently observed backup bytes and receipt
-- digest match.
replicatedCleanupRunRepository
  :: Int
  -> AuthorityAggregateBackupClient IO
  -> CleanupRunRepository IO revision
  -> CleanupRunRepository IO revision
replicatedCleanupRunRepository maximumBytes backup primary =
  CleanupRunRepository
    { readCleanupRun = do
        observed <- readCleanupRun primary
        case observed of
          Left detail -> pure (Left detail)
          Right CleanupRunMissing -> pure (Right CleanupRunMissing)
          Right snapshot@(CleanupRunObserved _ run) -> do
            verified <- verifyBackup run
            pure (snapshot <$ verified)
          Right snapshot@(CleanupRunTombstoned _ tombstone) -> do
            verified <- verifyTombstoneBackup tombstone
            pure (snapshot <$ verified)
    , compareAndSwapCleanupRun = \expected run -> do
        verified <- publishAndVerifyBackup run
        case verified of
          Left detail -> pure (Left detail)
          Right () -> compareAndSwapCleanupRun primary expected run
    , compareAndSwapCleanupRunTombstone = \revision tombstone -> do
        verified <- publishAndVerifyTombstoneBackup tombstone
        case verified of
          Left detail -> pure (Left detail)
          Right () -> compareAndSwapCleanupRunTombstone primary revision tombstone
    }
 where
  canonical run =
    either (Left . Text.pack . show) Right (encodeCleanupRun maximumBytes run)
  canonicalTombstone tombstone =
    firstText
      (encodeModelBValue (cleanupRunStoredCodec maximumBytes) (CleanupRunStoredTombstone tombstone))
  publishAndVerifyBackup run = case canonical run of
    Left detail -> pure (Left detail)
    Right bytes -> do
      copied <- copyAuthorityAggregateBackup backup bytes
      case copied of
        Left err -> pure (Left ("cleanup backup copy failed: " <> Text.pack (show err)))
        Right receipt -> verifyBackupDigest bytes (authorityBackupDigestText (authorityBackupReceiptDigest receipt))
  verifyBackup run = case canonical run of
    Left detail -> pure (Left detail)
    Right bytes -> verifyBackupDigest bytes (sha256Text bytes)
  publishAndVerifyTombstoneBackup tombstone = case canonicalTombstone tombstone of
    Left detail -> pure (Left detail)
    Right bytes -> do
      copied <- copyAuthorityAggregateBackup backup bytes
      case copied of
        Left err -> pure (Left ("cleanup tombstone backup copy failed: " <> Text.pack (show err)))
        Right receipt -> verifyBackupDigest bytes (authorityBackupDigestText (authorityBackupReceiptDigest receipt))
  verifyTombstoneBackup tombstone = case canonicalTombstone tombstone of
    Left detail -> pure (Left detail)
    Right bytes -> verifyBackupDigest bytes (sha256Text bytes)
  verifyBackupDigest bytes digest = do
    observed <- observeAuthorityAggregateBackup backup digest
    pure $ case observed of
      Left err -> Left ("cleanup backup observation failed: " <> Text.pack (show err))
      Right AuthorityAggregateBackupMissing -> Left "cleanup backup is missing"
      Right (AuthorityAggregateBackupCorrupt detail) -> Left ("cleanup backup is corrupt: " <> detail)
      Right (AuthorityAggregateBackupCurrent ciphertext receipt)
        | authorityBackupCiphertextBytes ciphertext /= bytes ->
            Left "cleanup primary and backup bytes differ"
        | authorityBackupDigestText (authorityBackupReceiptDigest receipt) /= digest ->
            Left "cleanup backup receipt digest mismatch"
        | otherwise -> Right ()
  firstText = either (Left . Text.pack) Right

sha256Text :: ByteString -> Text
sha256Text = TextEncoding.decodeUtf8 . hexSha256

data CleanupRunStoreError
  = CleanupRunStoreUnavailable !Text
  | CleanupRunStoreMissing
  | CleanupRunStoreTransitionRejected !CleanupRunError
  | CleanupRunStoreCommitFailed !Text
  | CleanupRunStoreReadBackMismatch
  | CleanupRunStoreAlreadyCompacted !CleanupRunTombstone
  deriving stock (Eq, Show)

createCleanupRunDurably
  :: (Monad m)
  => CleanupRunRepository m revision
  -> CleanupRun
  -> m (Either CleanupRunStoreError CleanupRun)
createCleanupRunDurably repository expected = do
  observed <- readCleanupRun repository
  case observed of
    Left detail -> pure (Left (CleanupRunStoreUnavailable detail))
    Right (CleanupRunObserved _ existing)
      | existing == expected -> pure (Right existing)
      | otherwise -> pure (Left CleanupRunStoreReadBackMismatch)
    Right (CleanupRunTombstoned _ tombstone) ->
      pure (Left (CleanupRunStoreAlreadyCompacted tombstone))
    Right CleanupRunMissing -> do
      committed <- compareAndSwapCleanupRun repository Nothing expected
      case committed of
        Right () -> confirm
        Left detail -> do
          readBack <- confirm
          pure $ case readBack of
            Right value -> Right value
            Left _ -> Left (CleanupRunStoreCommitFailed detail)
 where
  confirm = do
    readBack <- readCleanupRun repository
    pure $ case readBack of
      Right (CleanupRunObserved _ observed) | observed == expected -> Right observed
      Right (CleanupRunTombstoned _ _) -> Left CleanupRunStoreReadBackMismatch
      Left detail -> Left (CleanupRunStoreUnavailable detail)
      _ -> Left CleanupRunStoreReadBackMismatch

-- | Apply one pure transition through exact-revision CAS.  A failed CAS response
-- is ambiguous: exact read-back of the expected value is success; every other
-- observation refuses rather than repeating blindly.
applyCleanupRunTransition
  :: (Monad m)
  => CleanupRunRepository m revision
  -> (CleanupRun -> Either CleanupRunError CleanupRun)
  -> m (Either CleanupRunStoreError CleanupRun)
applyCleanupRunTransition repository transition = do
  observed <- readCleanupRun repository
  case observed of
    Left detail -> pure (Left (CleanupRunStoreUnavailable detail))
    Right CleanupRunMissing -> pure (Left CleanupRunStoreMissing)
    Right (CleanupRunTombstoned _ tombstone) ->
      pure (Left (CleanupRunStoreAlreadyCompacted tombstone))
    Right (CleanupRunObserved revision current) -> case transition current of
      Left err -> pure (Left (CleanupRunStoreTransitionRejected err))
      Right expected -> do
        committed <- compareAndSwapCleanupRun repository (Just revision) expected
        case committed of
          Right () -> confirm expected
          Left detail -> do
            readBack <- confirm expected
            pure $ case readBack of
              Right value -> Right value
              Left _ -> Left (CleanupRunStoreCommitFailed detail)
 where
  confirm expected = do
    readBack <- readCleanupRun repository
    pure $ case readBack of
      Left detail -> Left (CleanupRunStoreUnavailable detail)
      Right (CleanupRunObserved _ observed) | observed == expected -> Right observed
      Right (CleanupRunTombstoned _ _) -> Left CleanupRunStoreReadBackMismatch
      _ -> Left CleanupRunStoreReadBackMismatch
