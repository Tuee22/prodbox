{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.36: the execution half of the cascade's terminal escape audit.
--
-- "Prodbox.Lifecycle.Teardown.CascadeTerminalAudit" owns the pure kernel — the
-- query catalog, the classification, the region-bounded verdict, and the
-- refusal algebra — behind an injected boundary, and deliberately wires no
-- production one, because on the AWS substrate those queries are a Provider
-- effect this phase owns.  This module is that Provider effect: it turns one
-- symbolic 'TerminalAuditQuery' into a registered 'ProviderIntent', and turns
-- the Provider's evidence back into the rows the kernel classifies.
--
-- Three decisions carry the design, and each is a way of not turning a
-- non-answer into a clean one.
--
--   * __An unanswerable query stays unanswered.__  Transport failure, a
--     coordinate that does not match the intent, a mutation-shaped result, and
--     unreadable evidence all become an 'ObservationFailure', which the kernel
--     downgrades a would-be-clean verdict on.  None of them becomes @[]@.
--   * __A row outside the audited scope is refused, not classified.__  The
--     retained matchers are built from the audited account and region, so a row
--     naming another account — or another region for a regional service — is a
--     row this audit cannot reason about.  Admitting it would let a foreign
--     resource be classified against the wrong catalog in either direction.
--   * __Resource type is derived from the ARN and never guessed.__  A matcher
--     that names a family coordinate also pins the resource type, so a
--     mis-derived type can only ever fail to match — which classifies the row
--     as an escapee and fails the audit closed.
module Prodbox.Lifecycle.Teardown.CascadeTerminalAuditAdapter
  ( terminalAuditQueryProviderIntent
  , terminalAuditQueryEcho
  , decodeTerminalAuditQueryObservation
  , providerCascadeTerminalAuditBoundary
  , awsTagRowsFromOwnedResourceTagEntry
  , awsResourceIdentityFromArn
  , cascadeTerminalAuditReceiptFor
  , TerminalAuditAdapterError (..)
  , renderTerminalAuditAdapterError
  )
where

import Data.Bifunctor (first)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
  ( CascadeTerminalAuditReceipt
  , CascadeTerminalAuditVerdict (..)
  , ProviderAdmissionEpochError
  , mkCascadeTerminalAuditReceipt
  )
import Prodbox.Lifecycle.AwsInventory
  ( Arn
  , AwsResourceCoordinate (AwsResourceCoordinate)
  , AwsResourceType (AwsResourceType)
  , AwsTag (..)
  , AwsTagRow (..)
  , arnText
  , mkArn
  )
import Prodbox.Lifecycle.OwnedResourceTagEvidence
  ( OwnedResourceTagEntry (..)
  , OwnedResourceTagObservation (..)
  , OwnedResourceTagQueryEcho (..)
  , parseOwnedResourceTagObservation
  , renderOwnedResourceTagEvidenceError
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (ObserveOwnedResourceTags)
  , ProviderIntentCoordinate
  , ProviderOwnedTagQuery (..)
  , providerIntentCoordinate
  )
import Prodbox.Lifecycle.Teardown.CascadeTerminalAudit
  ( CascadeTerminalAuditBoundary (..)
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (AwsAccountId)
  , AwsRegion (AwsRegion)
  , AwsScope (..)
  , CleanupSurface (Cascade)
  , ObservationFailure (ObservationFailure)
  )
import Prodbox.Lifecycle.Teardown.Observation
  ( TerminalAuditObservation (..)
  , TerminalAuditQueryDigest (..)
  , TerminalAuditResult (..)
  , TerminalAuditRetainedSetDigest (..)
  , terminalAuditEvidenceScope
  , terminalAuditEvidenceScopeDigest
  , terminalAuditQueryDigest
  , terminalAuditRetainedSetDigest
  )
import Prodbox.Lifecycle.Teardown.RetainedInventory (TerminalAuditQuery (..))

-- | Why one returned row could not be admitted into the audit at all.
data TerminalAuditAdapterError
  = TerminalAuditEvidenceUnreadable !Text
  | TerminalAuditAnsweredAnotherQuery !Text !Text
  | TerminalAuditProviderCoordinateMismatch
      !ProviderIntentCoordinate
      !ProviderIntentCoordinate
  | TerminalAuditProviderResultKindMismatch
  | TerminalAuditArnUnreadable !Text
  | TerminalAuditRowOutsideAuditedAccount !Text !Text
  | TerminalAuditRowOutsideAuditedRegion !Text !Text
  deriving (Eq, Show)

renderTerminalAuditAdapterError :: TerminalAuditAdapterError -> Text
renderTerminalAuditAdapterError = \case
  TerminalAuditEvidenceUnreadable detail ->
    "terminal-audit query evidence is not readable: " <> detail
  TerminalAuditAnsweredAnotherQuery expected actual ->
    "terminal-audit query evidence answered for "
      <> actual
      <> " rather than "
      <> expected
  TerminalAuditProviderCoordinateMismatch expected actual ->
    "terminal-audit query evidence carries provider coordinate "
      <> Text.pack (show actual)
      <> " rather than "
      <> Text.pack (show expected)
  TerminalAuditProviderResultKindMismatch ->
    "terminal-audit query was answered by a mutation result; the audit issues \
    \read-only listings only"
  TerminalAuditArnUnreadable value ->
    "terminal-audit row carries an ARN this audit cannot read: " <> value
  TerminalAuditRowOutsideAuditedAccount audited actual ->
    "terminal-audit row names account "
      <> actual
      <> " rather than the audited account "
      <> audited
  TerminalAuditRowOutsideAuditedRegion audited actual ->
    "terminal-audit row names region "
      <> actual
      <> " rather than the audited region "
      <> audited

-- | The registered Provider intent one catalog query executes as.
terminalAuditQueryProviderIntent :: TerminalAuditQuery -> ProviderIntent
terminalAuditQueryProviderIntent query =
  ObserveOwnedResourceTags $ case query of
    AuditQueryTagKey key -> ProviderOwnedTagKeyQuery key
    AuditQueryTagPair key value -> ProviderOwnedTagPairQuery key value

-- | The echo the Provider must return for that query.
terminalAuditQueryEcho :: TerminalAuditQuery -> OwnedResourceTagQueryEcho
terminalAuditQueryEcho query = case query of
  AuditQueryTagKey key -> OwnedResourceTagKeyEcho key
  AuditQueryTagPair key value -> OwnedResourceTagPairEcho key value

renderQueryEcho :: OwnedResourceTagQueryEcho -> Text
renderQueryEcho = \case
  OwnedResourceTagKeyEcho key -> key
  OwnedResourceTagPairEcho key value -> key <> "=" <> value

-- | Lower one Provider answer into audit rows.
--
-- Every inability is returned as the query's own 'ObservationFailure', which is
-- what the kernel counts as a blind spot; only a complete, coherent, in-scope
-- answer produces rows.
decodeTerminalAuditQueryObservation
  :: AwsScope
  -> TerminalAuditQuery
  -> Either Text ProviderIntentExecutionResult
  -> Either ObservationFailure [AwsTagRow]
decodeTerminalAuditQueryObservation scope query providerResult =
  first (ObservationFailure . renderTerminalAuditAdapterError) $ do
    evidence <- case providerResult of
      Left detail -> Left (TerminalAuditEvidenceUnreadable detail)
      Right (ProviderIntentExecutionObserved actualCoordinate evidence)
        | actualCoordinate /= expectedCoordinate ->
            Left
              ( TerminalAuditProviderCoordinateMismatch
                  expectedCoordinate
                  actualCoordinate
              )
        | otherwise -> Right evidence
      Right _ -> Left TerminalAuditProviderResultKindMismatch
    observation <-
      first
        (TerminalAuditEvidenceUnreadable . renderOwnedResourceTagEvidenceError)
        (parseOwnedResourceTagObservation evidence)
    let actualEcho = ownedResourceTagObservationQuery observation
    if actualEcho == expectedEcho
      then Right ()
      else
        Left
          ( TerminalAuditAnsweredAnotherQuery
              (renderQueryEcho expectedEcho)
              (renderQueryEcho actualEcho)
          )
    concat
      <$> traverse
        (awsTagRowsFromOwnedResourceTagEntry scope)
        (ownedResourceTagObservationEntries observation)
 where
  expectedEcho = terminalAuditQueryEcho query
  expectedCoordinate =
    providerIntentCoordinate (terminalAuditQueryProviderIntent query)

-- | The production boundary the kernel takes.
--
-- The dispatcher argument is the caller's already-authorized Provider path;
-- this module composes the intent and the decode around it and adds no
-- credential or transport of its own.
providerCascadeTerminalAuditBoundary
  :: (Monad m)
  => AwsScope
  -> (ProviderIntent -> m (Either Text ProviderIntentExecutionResult))
  -> CascadeTerminalAuditBoundary m
providerCascadeTerminalAuditBoundary scope dispatch =
  CascadeTerminalAuditBoundary $ \query -> do
    dispatched <- dispatch (terminalAuditQueryProviderIntent query)
    pure (decodeTerminalAuditQueryObservation scope query dispatched)

-- | One returned resource becomes one row per tag, and a resource returned
-- carrying no tags becomes one tagless row: \"returned with no tags\" is a fact
-- about the resource, and dropping it would shorten the audit's field of view.
awsTagRowsFromOwnedResourceTagEntry
  :: AwsScope
  -> OwnedResourceTagEntry
  -> Either TerminalAuditAdapterError [AwsTagRow]
awsTagRowsFromOwnedResourceTagEntry scope entry = do
  (arn, resourceType, coordinate) <-
    awsResourceIdentityFromArn scope (ownedResourceTagEntryArn entry)
  let row tag =
        AwsTagRow
          { awsTagRowArn = arn
          , awsTagRowScope = scope
          , awsTagRowResourceType = resourceType
          , awsTagRowCoordinate = coordinate
          , awsTagRowTag = tag
          }
  Right $ case ownedResourceTagEntryTags entry of
    [] -> [row Nothing]
    tags -> [row (Just (AwsTag key value)) | (key, value) <- tags]

-- | Derive the audit's normalized identity for one ARN.
--
-- The type is @\<service\>:\<type\>@, taken from the ARN's own resource
-- segment.  An ARN whose resource segment carries no type separator has no type
-- to read, and the one such shape the retained catalog names by type is S3,
-- whose ARNs are always buckets; every other separator-less shape keeps the
-- bare service as its type, which no family matcher can equal, so the row
-- classifies as an escapee and the audit fails closed.
awsResourceIdentityFromArn
  :: AwsScope
  -> Text
  -> Either
       TerminalAuditAdapterError
       (Arn, AwsResourceType, AwsResourceCoordinate)
awsResourceIdentityFromArn scope raw = do
  arn <- first (const (TerminalAuditArnUnreadable raw)) (mkArn raw)
  case Text.splitOn ":" (arnText arn) of
    "arn" : _partition : service : region : account : resourceParts
      | not (null resourceParts) && not (Text.null service) -> do
          if account == auditedAccount || Text.null account
            then Right ()
            else Left (TerminalAuditRowOutsideAuditedAccount auditedAccount account)
          if region == auditedRegion || Text.null region
            then Right ()
            else Left (TerminalAuditRowOutsideAuditedRegion auditedRegion region)
          let resource = Text.intercalate ":" resourceParts
              (typeSegment, coordinate) = splitResourceSegment service resource
          Right
            ( arn
            , AwsResourceType typeSegment
            , AwsResourceCoordinate coordinate
            )
    _ -> Left (TerminalAuditArnUnreadable raw)
 where
  AwsAccountId auditedAccount = awsScopeAccountId scope
  AwsRegion auditedRegion = awsScopeRegion scope

splitResourceSegment :: Text -> Text -> (Text, Text)
splitResourceSegment service resource
  | (before, after) <- Text.breakOn "/" resource
  , not (Text.null after) =
      (service <> ":" <> before, Text.drop 1 after)
  | (before, after) <- Text.breakOn ":" resource
  , not (Text.null after) =
      (service <> ":" <> before, Text.drop 1 after)
  | service == "s3" = ("s3:bucket", resource)
  | otherwise = (service, resource)

-- | Mint the durable receipt for one taken audit.
--
-- All three verdicts mint: a receipt says what happened, and a run that found
-- an escape or could not see everything must be able to record that durably
-- without the record authorizing anything.  What the receipt cannot do is claim
-- a scope the audit was not taken in — its scope digest comes from the
-- observation's own evidence scope through the same derivation the reservation
-- used, so recording it against a reservation for another run is refused by the
-- Authority rather than reconciled here.
cascadeTerminalAuditReceiptFor
  :: TerminalAuditObservation 'Cascade
  -> Either ProviderAdmissionEpochError CascadeTerminalAuditReceipt
cascadeTerminalAuditReceiptFor observation =
  mkCascadeTerminalAuditReceipt
    (terminalAuditEvidenceScopeDigest (terminalAuditEvidenceScope scope))
    queryDigest
    retainedDigest
    verdict
 where
  scope = terminalAuditScope observation
  TerminalAuditQueryDigest queryDigest = terminalAuditQueryDigest scope
  TerminalAuditRetainedSetDigest retainedDigest =
    terminalAuditRetainedSetDigest scope
  verdict = case terminalAuditResult observation of
    TerminalAuditConfirmedClean _ -> CascadeTerminalAuditReceiptClean
    TerminalAuditFoundEscapes _ escaped ->
      CascadeTerminalAuditReceiptEscaped
        (fromIntegral (NonEmpty.length escaped))
    TerminalAuditUnobservable _ failures ->
      CascadeTerminalAuditReceiptUnobservable
        (fromIntegral (NonEmpty.length failures))
