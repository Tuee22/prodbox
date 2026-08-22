{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.36: the production Kubernetes-scoped execution arm for the
-- registered DNS01 challenge record family.
--
-- This is the other half of the split
-- 'Prodbox.Lifecycle.Teardown.Dns01ChallengeRecordAdapter' describes: the
-- family is observed and read back through the Provider, and removed here, by
-- deleting the cert-manager object that owns the record.  A Provider delete
-- would race the solver into rewriting the record, and the Provider has no
-- Kubernetes capability at all by construction, so this arm exists rather than
-- a @Reap@ intent.
--
-- Three things it deliberately does not do:
--
--   * __It does not delete every Challenge.__ The owner set is derived from the
--     records the observation actually returned, joined on the solver's own
--     @spec.dnsName@.  A challenge for a certificate whose record this run did
--     not observe is another run's or another zone's work.
--   * __It does not report absence.__ Its answer is a
--     'RegisteredTargetMutationAttempt'; the mandatory Route 53 read-back is a
--     separate node.  That separation matters more here than anywhere else,
--     because cert-manager removes the record asynchronously through a
--     finalizer after its object is gone.
--   * __It does not treat an orphaned record as done.__ A record with no
--     surviving owner cannot be removed by an owner delete, and saying so is
--     the only honest answer: reporting the delete as applied would send the
--     read-back looking for an absence nothing was going to produce.
module Prodbox.Lifecycle.Teardown.Dns01ChallengeOwnerDeleteInterpreter
  ( productionDns01ChallengeOwnerDeleteBoundary
  , Dns01ChallengeOwner (..)
  , parseDns01ChallengeOwners
  , dns01ChallengeOwnerRecordName
  , selectDns01ChallengeOwnersToDelete
  , Dns01ChallengeOwnerSelection (..)
  )
where

import Data.List (sort)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.EksClientAuthClient
  ( EksClientAuthClientError
  , withEksClientAuthProjectionForTeardownExecution
  )
import Prodbox.ControlPlane.EksClientAuthProjection (EksClientAuthProjection)
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller
  )
import Prodbox.Lifecycle.OwnedResourceTags (dns01ChallengeRecordNamePrefix)
import Prodbox.Lifecycle.Teardown.AwsRegisteredTargetInterpreter
  ( Dns01ChallengeOwnerDeleteBoundary
  , mkDns01ChallengeOwnerDeleteBoundary
  )
import Prodbox.Lifecycle.Teardown.Dns01ChallengeRecordAdapter
  ( ExactDns01ChallengeOwnerDeleteAuthorization
  , dns01ChallengeOwnerDeleteObservedRecords
  )
import Prodbox.Lifecycle.Teardown.EphemeralKubectl
  ( EphemeralKubectl
  , EphemeralKubectlUnavailable (..)
  , runEphemeralKubectl
  , withEphemeralKubectlForProjection
  )
import Prodbox.Lifecycle.Teardown.Execution
  ( teardownExecutionIdentity
  , teardownExecutionObservationScope
  )
import Prodbox.Lifecycle.Teardown.ExecutionIdentity (TeardownExecutionIdentity)
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope
  , ObservationFailure (..)
  , awsScopeAccountId
  , awsScopeRegion
  , evidenceAwsScope
  )
import Prodbox.Lifecycle.Teardown.RegisteredTargetResult
  ( RegisteredTargetMutationAttempt (..)
  )
import Prodbox.Lifecycle.Teardown.Registry (awsEksProvisionedClusterName)

-- | One cert-manager @Challenge@ object, as the solver reports it.
data Dns01ChallengeOwner = Dns01ChallengeOwner
  { dns01ChallengeOwnerNamespace :: !Text
  , dns01ChallengeOwnerName :: !Text
  , dns01ChallengeOwnerDnsName :: !Text
  }
  deriving (Eq, Ord, Show)

-- | The record name a challenge owner is responsible for.
--
-- Derived through the one prefix constant the coordinate, the creator, and this
-- join all read, so the owner set and the family bound cannot disagree about
-- what an owner owns.
dns01ChallengeOwnerRecordName :: Dns01ChallengeOwner -> Text
dns01ChallengeOwnerRecordName owner =
  canonicalRecordName
    (dns01ChallengeRecordNamePrefix <> dns01ChallengeOwnerDnsName owner)

-- | Lower case with exactly one trailing dot.  Route 53 answers with a trailing
-- dot and cert-manager's @spec.dnsName@ carries none, so comparing them
-- unnormalized would find no owner for every record.
canonicalRecordName :: Text -> Text
canonicalRecordName raw =
  Text.toLower (Text.dropWhileEnd (== '.') (Text.strip raw)) <> "."

-- | The join between the observed records and the owners that can remove them.
data Dns01ChallengeOwnerSelection = Dns01ChallengeOwnerSelection
  { dns01ChallengeOwnersToDelete :: ![Dns01ChallengeOwner]
  , dns01ChallengeOrphanedRecords :: ![Text]
  -- ^ Observed records no surviving owner claims.  An owner delete cannot
  -- remove these, and calling the attempt applied would be a claim about work
  -- nothing is going to do.
  }
  deriving (Eq, Show)

selectDns01ChallengeOwnersToDelete
  :: NonEmpty Text
  -> [Dns01ChallengeOwner]
  -> Dns01ChallengeOwnerSelection
selectDns01ChallengeOwnersToDelete observedRecords owners =
  Dns01ChallengeOwnerSelection
    { dns01ChallengeOwnersToDelete =
        sort [owner | owner <- owners, dns01ChallengeOwnerRecordName owner `elem` wanted]
    , dns01ChallengeOrphanedRecords =
        sort
          [ record
          | record <- wanted
          , record `notElem` map dns01ChallengeOwnerRecordName owners
          ]
    }
 where
  wanted = map canonicalRecordName (NonEmpty.toList observedRecords)

-- | Parse the @namespace|name|dnsName@ rows the listing jsonpath emits.
--
-- A malformed row makes the whole listing unusable rather than being dropped: a
-- shortened owner set reads as an orphaned record, which is a different fact
-- with a different remedy.
parseDns01ChallengeOwners :: Text -> Either Text [Dns01ChallengeOwner]
parseDns01ChallengeOwners raw = traverse parseRow rows
 where
  rows = filter (not . Text.null) (map Text.strip (Text.lines raw))
  parseRow row = case Text.splitOn "|" row of
    [namespace, name, dnsName]
      | not (Text.null namespace)
      , not (Text.null name)
      , not (Text.null dnsName) ->
          Right
            Dns01ChallengeOwner
              { dns01ChallengeOwnerNamespace = namespace
              , dns01ChallengeOwnerName = name
              , dns01ChallengeOwnerDnsName = dnsName
              }
    _ -> Left ("malformed cert-manager challenge row: " <> Text.take 256 row)

-- | The production boundary.
--
-- The cluster it reaches is the registry's deterministic EKS cluster name, and
-- the account and region come from the run's own observation scope, so no
-- caller-composed coordinate participates.
productionDns01ChallengeOwnerDeleteBoundary
  :: ExternalLifecycleAuthorityCaller
  -> FilePath
  -> FilePath
  -> [(String, String)]
  -> Maybe FilePath
  -> Dns01ChallengeOwnerDeleteBoundary IO
productionDns01ChallengeOwnerDeleteBoundary
  caller
  repoRoot
  kubectl
  environment
  workingDirectory =
    mkDns01ChallengeOwnerDeleteBoundary
      ( \context _target authorization ->
          deleteThroughEphemeralClient
            caller
            repoRoot
            kubectl
            environment
            workingDirectory
            (evidenceAwsScope (teardownExecutionObservationScope context))
            (teardownExecutionIdentity context)
            authorization
      )

deleteThroughEphemeralClient
  :: ExternalLifecycleAuthorityCaller
  -> FilePath
  -> FilePath
  -> [(String, String)]
  -> Maybe FilePath
  -> Maybe AwsScope
  -> TeardownExecutionIdentity
  -> ExactDns01ChallengeOwnerDeleteAuthorization
  -> IO (Either err RegisteredTargetMutationAttempt)
deleteThroughEphemeralClient
  caller
  repoRoot
  kubectl
  environment
  workingDirectory
  maybeAwsScope
  identity
  authorization = case maybeAwsScope of
    Nothing ->
      pure
        ( Right
            ( RegisteredTargetMutationRefused
                "DNS01 challenge owner delete requires the run's AWS scope"
            )
        )
    Just awsScope -> do
      let AwsAccountId account = awsScopeAccountId awsScope
          AwsRegion region = awsScopeRegion awsScope
      acquired <-
        withEksClientAuthProjectionForTeardownExecution
          caller
          repoRoot
          identity
          account
          region
          awsEksProvisionedClusterName
          (withOwnerDeleteClient kubectl environment workingDirectory authorization)
      pure (Right (either clientAuthAttempt id acquired))

withOwnerDeleteClient
  :: FilePath
  -> [(String, String)]
  -> Maybe FilePath
  -> ExactDns01ChallengeOwnerDeleteAuthorization
  -> EksClientAuthProjection
  -> IO RegisteredTargetMutationAttempt
withOwnerDeleteClient kubectl environment workingDirectory authorization projection =
  withEphemeralKubectlForProjection
    kubectl
    environment
    workingDirectory
    projection
    (consumeOwnerDeleteClient authorization)

consumeOwnerDeleteClient
  :: ExactDns01ChallengeOwnerDeleteAuthorization
  -> Either EphemeralKubectlUnavailable EphemeralKubectl
  -> IO RegisteredTargetMutationAttempt
consumeOwnerDeleteClient authorization client = case client of
  Left (EphemeralKubectlUnavailable failure) -> pure (unavailable failure)
  Right ready -> deleteOwners ready authorization

-- | An acquisition failure is a refusal rather than a lost response: nothing
-- was submitted, so the cert-manager objects are exactly as they were.
clientAuthAttempt :: EksClientAuthClientError -> RegisteredTargetMutationAttempt
clientAuthAttempt err =
  RegisteredTargetMutationRefused
    ( Text.take
        1024
        ( "DNS01 challenge owner delete could not obtain Kubernetes access: "
            <> Text.pack (show err)
        )
    )

unavailable :: ObservationFailure -> RegisteredTargetMutationAttempt
unavailable (ObservationFailure detail) =
  RegisteredTargetMutationRefused (Text.take 1024 detail)

deleteOwners
  :: EphemeralKubectl
  -> ExactDns01ChallengeOwnerDeleteAuthorization
  -> IO RegisteredTargetMutationAttempt
deleteOwners client authorization = do
  listed <- runEphemeralKubectl client challengeListingArguments
  case listed of
    Left failures ->
      pure
        ( RegisteredTargetMutationRefused
            (renderFailures "cert-manager challenge listing failed" failures)
        )
    Right output -> case parseDns01ChallengeOwners (Text.pack output) of
      Left detail -> pure (RegisteredTargetMutationRefused (Text.take 1024 detail))
      Right owners -> do
        let selection =
              selectDns01ChallengeOwnersToDelete
                (dns01ChallengeOwnerDeleteObservedRecords authorization)
                owners
        deleted <- traverse (deleteOwner client) (dns01ChallengeOwnersToDelete selection)
        pure (combineAttempts selection deleted)

challengeListingArguments :: [String]
challengeListingArguments =
  [ "get"
  , "challenges.acme.cert-manager.io"
  , "--all-namespaces"
  , "--ignore-not-found=true"
  , "-o"
  , "jsonpath={range .items[*]}{.metadata.namespace}{\"|\"}{.metadata.name}{\"|\"}{.spec.dnsName}{\"\\n\"}{end}"
  ]

deleteOwner
  :: EphemeralKubectl
  -> Dns01ChallengeOwner
  -> IO (Either Text ())
deleteOwner client owner = do
  result <-
    runEphemeralKubectl
      client
      [ "delete"
      , "challenges.acme.cert-manager.io"
      , Text.unpack (dns01ChallengeOwnerName owner)
      , "--namespace"
      , Text.unpack (dns01ChallengeOwnerNamespace owner)
      , "--wait=false"
      , "--ignore-not-found=true"
      ]
  pure $ case result of
    Right _ -> Right ()
    Left failures ->
      Left (renderFailures "cert-manager challenge delete result unknown" failures)

-- | An unanswered delete is a lost response, because the object may well be
-- gone; an orphaned record is a refusal, because nothing was going to remove
-- it.  A run with both reports the lost response, which is the arm that still
-- admits the read-back closing the family.
combineAttempts
  :: Dns01ChallengeOwnerSelection
  -> [Either Text ()]
  -> RegisteredTargetMutationAttempt
combineAttempts selection deleted = case [detail | Left detail <- deleted] of
  detail : _ -> RegisteredTargetMutationResponseLost (Text.take 1024 detail)
  [] -> case dns01ChallengeOrphanedRecords selection of
    [] -> RegisteredTargetMutationApplied
    orphans ->
      RegisteredTargetMutationRefused
        ( Text.take
            1024
            ( "DNS01 challenge records survive with no cert-manager owner to \
              \delete: "
                <> Text.intercalate ", " orphans
            )
        )

renderFailures :: Text -> NonEmpty ObservationFailure -> Text
renderFailures label failures =
  Text.take
    1024
    ( label
        <> ": "
        <> Text.intercalate
          "; "
          [detail | ObservationFailure detail <- NonEmpty.toList failures]
    )
