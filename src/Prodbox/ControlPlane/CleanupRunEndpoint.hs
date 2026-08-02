{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated Lifecycle-Authority endpoint for Sprint 5.18 retained
-- cleanup ownership. Wire identities are rebuilt through smart constructors;
-- callers cannot select a physical object-store coordinate.
module Prodbox.ControlPlane.CleanupRunEndpoint
  ( CleanupRunCommand (..)
  , CleanupRunRepositoryProvider (..)
  , CleanupRunEndpointResult (..)
  , cleanupRunMaximumBytes
  , serveCleanupRunRequest
  , cleanupRunEndpointStatus
  , cleanupRunEndpointBody
  , decodeCleanupRunScanResponse
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthorityBackupClient
  ( AuthorityAggregateBackupClient (..)
  , AuthorityAggregateBackupObservation (..)
  )
import Prodbox.ControlPlane.AuthorityBackupEndpoint (authorityBackupCiphertextBytes)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , decodeControlPlaneRequest
  )
import Prodbox.Test.CleanupRun
  ( CleanupNodeOutcome
  , CleanupPrimaryOutcome
  , CleanupRun
  , CleanupRunError
  , CleanupRunId
  , CleanupRunIndexEntry (..)
  , CleanupRunIndexRepository (..)
  , CleanupRunIndexSnapshot (..)
  , CleanupRunReport
  , CleanupRunRepository (..)
  , CleanupRunSnapshot (..)
  , CleanupRunStoreError
    ( CleanupRunStoreMissing
    , CleanupRunStoreTransitionRejected
    )
  , applyCleanupRunTransition
  , beginCleanupNode
  , claimCleanupRun
  , cleanupLeaseExpiresAtMicros
  , cleanupRunId
  , cleanupRunIdText
  , cleanupRunIndexEntries
  , cleanupRunLease
  , cleanupRunTerminal
  , cleanupRunTombstoneReportDigest
  , compactCleanupRunDurably
  , completeCleanupNode
  , createCleanupRunDurably
  , decodeCleanupRun
  , decodeCleanupRunReport
  , encodeCleanupRun
  , encodeCleanupRunReport
  , mkCleanupAttemptId
  , mkCleanupNodeId
  , mkCleanupOwnerId
  , mkCleanupRunId
  , publishCleanupRunTombstone
  , recordPrimaryOutcome
  , registerCleanupRun
  )

cleanupRunMaximumBytes :: Int
cleanupRunMaximumBytes = 1024 * 1024

data CleanupRunCommand
  = CleanupRunCreate !Text !ByteString
  | CleanupRunObserve !Text
  | CleanupRunClaim !Text !Text !Natural !Natural
  | CleanupRunRecordPrimary !Text !Text !Natural !CleanupPrimaryOutcome
  | CleanupRunBeginNode !Text !Text !Natural !Text !Text
  | CleanupRunCompleteNode !Text !Text !Natural !Text !Text !CleanupNodeOutcome
  | CleanupRunScan
  | CleanupRunCompact !Text !Natural !Natural
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CleanupRunRepositoryProvider m revision = CleanupRunRepositoryProvider
  { cleanupRunRepositoryFor :: CleanupRunId -> CleanupRunRepository m revision
  , cleanupRunIndexRepository :: CleanupRunIndexRepository m revision
  , cleanupRunAggregateBackup :: AuthorityAggregateBackupClient m
  }

data CleanupRunEndpointResult
  = CleanupRunEndpointSucceeded !CleanupRun
  | CleanupRunEndpointScanned ![Text]
  | CleanupRunEndpointCompacted !CleanupRunReport
  | CleanupRunEndpointTombstoned !Text
  | CleanupRunEndpointMissing
  | CleanupRunEndpointInvalidIdentity !Text
  | CleanupRunEndpointInvalidState !Text
  | CleanupRunEndpointTransitionRefused !CleanupRunError
  | CleanupRunEndpointUnavailable !Text
  | CleanupRunEndpointBadRequest !ControlPlaneRequestCodecError
  deriving stock (Eq, Show)

serveCleanupRunRequest
  :: (Monad m)
  => CleanupRunRepositoryProvider m revision
  -> LazyByteString.ByteString
  -> m CleanupRunEndpointResult
serveCleanupRunRequest provider requestBytes =
  case decodeControlPlaneRequest
    cleanupRunMaximumBytes
    requestBytes of
    Left err -> pure (CleanupRunEndpointBadRequest err)
    Right command -> serveCommand provider command

serveCommand
  :: (Monad m)
  => CleanupRunRepositoryProvider m revision
  -> CleanupRunCommand
  -> m CleanupRunEndpointResult
serveCommand provider command = case command of
  CleanupRunCreate rawRunId bytes -> case (mkCleanupRunId rawRunId, decodeCleanupRun cleanupRunMaximumBytes bytes) of
    (Left detail, _) -> pure (CleanupRunEndpointInvalidIdentity detail)
    (_, Left detail) -> pure (CleanupRunEndpointInvalidState (render detail))
    (Right runId, Right run)
      | cleanupRunId run /= runId -> pure (CleanupRunEndpointInvalidState "cleanup run id/body mismatch")
      | otherwise -> do
          registered <- registerCleanupRun (cleanupRunIndexRepository provider) run
          case registered of
            Left detail -> pure (CleanupRunEndpointUnavailable detail)
            Right _ ->
              projectStoreResult
                <$> createCleanupRunDurably (cleanupRunRepositoryFor provider runId) run
  CleanupRunObserve rawRunId -> withRunId rawRunId $ \runId -> do
    observed <- readCleanupRun (cleanupRunRepositoryFor provider runId)
    pure $ case observed of
      Left detail -> CleanupRunEndpointUnavailable detail
      Right CleanupRunMissing -> CleanupRunEndpointMissing
      Right (CleanupRunObserved _ run) -> CleanupRunEndpointSucceeded run
      Right (CleanupRunTombstoned _ tombstone) ->
        CleanupRunEndpointTombstoned (cleanupRunTombstoneReportDigest tombstone)
  CleanupRunClaim rawRunId rawOwner now expires ->
    withOwnerTransition rawRunId rawOwner $ \owner -> claimCleanupRun owner now expires
  CleanupRunRecordPrimary rawRunId rawOwner fence outcome ->
    withOwnerTransition rawRunId rawOwner $ \owner -> recordPrimaryOutcome owner fence outcome
  CleanupRunBeginNode rawRunId rawOwner fence rawNode rawAttempt ->
    withNodeTransition rawRunId rawOwner rawNode rawAttempt $ \owner node attempt ->
      beginCleanupNode owner fence node attempt
  CleanupRunCompleteNode rawRunId rawOwner fence rawNode rawAttempt outcome ->
    withNodeTransition rawRunId rawOwner rawNode rawAttempt $ \owner node attempt ->
      completeCleanupNode owner fence node attempt outcome
  CleanupRunScan -> do
    indexed <- readCleanupRunIndex (cleanupRunIndexRepository provider)
    case indexed of
      Left detail -> pure (CleanupRunEndpointUnavailable detail)
      Right CleanupRunIndexMissing -> pure (CleanupRunEndpointScanned [])
      Right (CleanupRunIndexObserved _ index) -> scanIndexedRuns (activeRuns (cleanupRunIndexEntries index))
  CleanupRunCompact rawRunId now retention -> withRunId rawRunId $ \runId -> do
    observed <- readCleanupRun (cleanupRunRepositoryFor provider runId)
    case observed of
      Left detail -> pure (CleanupRunEndpointUnavailable detail)
      Right CleanupRunMissing -> pure CleanupRunEndpointMissing
      Right (CleanupRunTombstoned _ tombstone) -> do
        report <-
          observeAuthorityAggregateBackup
            (cleanupRunAggregateBackup provider)
            (cleanupRunTombstoneReportDigest tombstone)
        pure $ case report of
          Left detail ->
            CleanupRunEndpointUnavailable
              ("cleanup report backup observation failed: " <> Text.pack (show detail))
          Right AuthorityAggregateBackupMissing ->
            CleanupRunEndpointUnavailable "cleanup report backup is missing"
          Right (AuthorityAggregateBackupCorrupt detail) ->
            CleanupRunEndpointUnavailable ("cleanup report backup is corrupt: " <> detail)
          Right (AuthorityAggregateBackupCurrent ciphertext _) ->
            case decodeCleanupRunReport cleanupRunMaximumBytes (authorityBackupCiphertextBytes ciphertext) of
              Left detail -> CleanupRunEndpointInvalidState (render detail)
              Right reportValue -> CleanupRunEndpointCompacted reportValue
      Right (CleanupRunObserved _ run)
        | not (cleanupRunTerminal run) ->
            pure (CleanupRunEndpointInvalidState "cleanup run is not terminal")
        | now < cleanupLeaseExpiresAtMicros (cleanupRunLease run) + retention ->
            pure (CleanupRunEndpointInvalidState "cleanup run retention window has not elapsed")
        | otherwise -> do
            compacted <-
              compactCleanupRunDurably
                cleanupRunMaximumBytes
                (cleanupRunAggregateBackup provider)
                (cleanupRunRepositoryFor provider runId)
                (cleanupRunIndexRepository provider)
                run
            pure $ either CleanupRunEndpointUnavailable CleanupRunEndpointCompacted compacted
 where
  activeRuns entries = [run | CleanupRunIndexActive run <- entries]
  scanIndexedRuns registeredRuns = do
    observations <- mapM observe registeredRuns
    pure $ case sequence observations of
      Left detail -> CleanupRunEndpointUnavailable detail
      Right runs ->
        CleanupRunEndpointScanned
          [ cleanupRunIdText (cleanupRunId run)
          | Just run <- runs
          ]
  observe registeredRun = do
    let runId = cleanupRunId registeredRun
    result <- readCleanupRun (cleanupRunRepositoryFor provider runId)
    case result of
      Left detail -> pure (Left detail)
      Right CleanupRunMissing -> do
        recovered <- createCleanupRunDurably (cleanupRunRepositoryFor provider runId) registeredRun
        pure $ either (Left . render) (Right . Just) recovered
      Right (CleanupRunObserved _ run) -> pure (Right (Just run))
      Right (CleanupRunTombstoned _ tombstone) -> do
        published <- publishCleanupRunTombstone (cleanupRunIndexRepository provider) tombstone
        pure $ case published of
          Left detail -> Left detail
          Right _ -> Right Nothing
  withRunId rawRunId action = case mkCleanupRunId rawRunId of
    Left detail -> pure (CleanupRunEndpointInvalidIdentity detail)
    Right runId -> action runId
  withOwnerTransition rawRunId rawOwner transition =
    case (mkCleanupRunId rawRunId, mkCleanupOwnerId rawOwner) of
      (Left detail, _) -> pure (CleanupRunEndpointInvalidIdentity detail)
      (_, Left detail) -> pure (CleanupRunEndpointInvalidIdentity detail)
      (Right runId, Right owner) ->
        projectStoreResult
          <$> applyCleanupRunTransition (cleanupRunRepositoryFor provider runId) (transition owner)
  withNodeTransition rawRunId rawOwner rawNode rawAttempt transition =
    case ( mkCleanupRunId rawRunId
         , mkCleanupOwnerId rawOwner
         , mkCleanupNodeId rawNode
         , mkCleanupAttemptId rawAttempt
         ) of
      (Left detail, _, _, _) -> pure (CleanupRunEndpointInvalidIdentity detail)
      (_, Left detail, _, _) -> pure (CleanupRunEndpointInvalidIdentity detail)
      (_, _, Left detail, _) -> pure (CleanupRunEndpointInvalidIdentity detail)
      (_, _, _, Left detail) -> pure (CleanupRunEndpointInvalidIdentity detail)
      (Right runId, Right owner, Right node, Right attempt) ->
        projectStoreResult
          <$> applyCleanupRunTransition
            (cleanupRunRepositoryFor provider runId)
            (transition owner node attempt)

projectStoreResult :: Either CleanupRunStoreError CleanupRun -> CleanupRunEndpointResult
projectStoreResult result = case result of
  Right run -> CleanupRunEndpointSucceeded run
  Left err -> case err of
    CleanupRunStoreMissing -> CleanupRunEndpointMissing
    CleanupRunStoreTransitionRejected refusal ->
      CleanupRunEndpointTransitionRefused refusal
    _ -> CleanupRunEndpointUnavailable (render err)

cleanupRunEndpointStatus :: CleanupRunEndpointResult -> Int
cleanupRunEndpointStatus result = case result of
  CleanupRunEndpointSucceeded _ -> 200
  CleanupRunEndpointScanned _ -> 200
  CleanupRunEndpointCompacted _ -> 200
  CleanupRunEndpointTombstoned _ -> 410
  CleanupRunEndpointMissing -> 404
  CleanupRunEndpointInvalidIdentity _ -> 400
  CleanupRunEndpointInvalidState _ -> 400
  CleanupRunEndpointTransitionRefused _ -> 409
  CleanupRunEndpointUnavailable _ -> 503
  CleanupRunEndpointBadRequest _ -> 400

cleanupRunEndpointBody :: CleanupRunEndpointResult -> ByteString
cleanupRunEndpointBody result = case result of
  CleanupRunEndpointSucceeded run ->
    either (const mempty) id (encodeCleanupRun cleanupRunMaximumBytes run)
  CleanupRunEndpointScanned runIds -> LazyByteString.toStrict (serialise runIds)
  CleanupRunEndpointCompacted report ->
    either (const mempty) id (encodeCleanupRunReport cleanupRunMaximumBytes report)
  CleanupRunEndpointTombstoned digest -> textBytes digest
  CleanupRunEndpointMissing -> mempty
  CleanupRunEndpointInvalidIdentity detail -> textBytes detail
  CleanupRunEndpointInvalidState detail -> textBytes detail
  CleanupRunEndpointTransitionRefused detail -> textBytes (render detail)
  CleanupRunEndpointUnavailable detail -> textBytes detail
  CleanupRunEndpointBadRequest detail -> textBytes (render detail)

textBytes :: Text -> ByteString
textBytes = TextEncoding.encodeUtf8

render :: (Show value) => value -> Text
render = Text.pack . show

decodeCleanupRunScanResponse :: ByteString -> Either Text [Text]
decodeCleanupRunScanResponse bytes =
  case deserialiseOrFail (LazyByteString.fromStrict bytes) of
    Left detail -> Left (Text.pack (show detail))
    Right runIds
      | LazyByteString.toStrict (serialise runIds) /= bytes ->
          Left "cleanup scan response is non-canonical"
      | length runIds > 256 -> Left "cleanup scan response exceeds 256 entries"
      | otherwise -> Right runIds
