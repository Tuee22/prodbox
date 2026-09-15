{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}

-- | The host-side lane that makes a registered stack's creation addressable.
--
-- Sprint @4.84@ landed the run-invariant generation, its durable slot, the
-- ordinal succession, the Authority-side producer, and the read-back-bound
-- cleanup selector.  Every one of those was proven and none of them ran,
-- because no production path could reach the producer: committing a generation
-- needs the @OperationId@ of the admitted create and of the admitted
-- @ObserveProviderAwsScope@, and an 'OperationId' is
-- @(epoch, client, sequence, digest)@ — the epoch and sequence are assigned at
-- admission, so a submitter cannot derive one.  It has to be told, and the
-- dispatch response discarded it.
--
-- That is now fixed at the route, and this module is the composition it
-- enables.  One submission does, in order:
--
--   1. dispatch @ObserveProviderAwsScope@ and keep the operation that carried
--      it, so the account and region behind the generation key are ones the
--      Provider Worker observed under an admitted operation;
--   2. __admit__ the caller\'s create intent without executing it, and keep
--      /its/ operation;
--   3. present both to the Authority\'s registered-stack creation route, which
--      reserves the cycle, commits the run-invariant generation settled by an
--      independent read-back, and only then commits the run-scoped creation
--      binding; and
--   4. execute the already-admitted create on the same submission key.
--
-- __The generation is durable before the stack exists.__  Sprint @7.36@ split
-- steps 2 and 4, which the route ran as one call.  The old order created the
-- stack first and committed its generation afterwards, so an Authority that
-- became unreachable in between left a stack whose cycle no later cleanup run
-- could name — a hazard the code named in
-- @RegisteredStackCreationAuthorityUnreachable@ and could not avoid, because the
-- 'OperationId' the generation binds did not exist until the create had already
-- run.  With admission separated, every failure before step 4 leaves an
-- addressable record and no AWS resource, and the only failure that can leave an
-- AWS resource is one whose generation is already committed and read back.
--
-- __The foundation is the retained cluster, not an invented value.__  The
-- foundation id is part of the run-invariant generation /key/, so a later
-- cleanup run must compute the same one without knowing anything about this
-- run.  It therefore comes from the retained local RKE2 control plane's own
-- cluster id — the one fact that is stable across runs by construction — and
-- never from a per-invocation value.  The creating run scope and surface, by
-- contrast, are provenance the selector never consults, so a per-invocation
-- value there is correct rather than merely tolerable.
module Prodbox.ControlPlane.RegisteredStackCreationSubmitter
  ( -- * The submission
    RegisteredStackCreationSubmission (..)
  , RegisteredStackCreationSubmitError (..)
  , renderRegisteredStackCreationSubmitError
  , submitRegisteredStackCreation

    -- * The proof an execute consumes
  , WriteAheadOwnershipProof
  , proveWriteAheadOwnership
  , writeAheadOwnershipProofStackKey
  , writeAheadOwnershipProofVersion

    -- * The scope a creation is submitted under
  , homeLinuxRke2FoundationId
  , registeredStackCreationScope
  , registeredStackCreationRunScope

    -- * The consumer half
  , RegisteredStackCleanupSelectError (..)
  , renderRegisteredStackCleanupSelectError
  , registeredStackCleanupScope
  , selectRegisteredStackGenerationForCleanup
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Prodbox.Config.Basics (UnencryptedBasics (basicsClusterId))
import Prodbox.Config.FloorDhall (loadUnencryptedBasics)
import Prodbox.ControlPlane.AwsStackCreationBindingRepository
  ( AwsStackCreationBindingClient (..)
  , AwsStackCreationBindingError
  , AwsStackCreationCommitResult (..)
  )
import Prodbox.ControlPlane.AwsStackCreationBindingTransportClient
  ( lifecycleAuthorityAwsStackCreationBindingAuthenticatedClient
  , selectRegisteredStackGenerationOverTransport
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( LifecycleAuthorityAuthentication
  , LifecycleAuthorityAuthenticationError
  , renderLifecycleAuthorityAuthenticationError
  , withLifecycleAuthorityAuthenticatedTransport
  )
import Prodbox.ControlPlane.OwnershipManifestRepository
  ( OwnershipManifestClient (..)
  , OwnershipManifestCommitResult (..)
  , OwnershipManifestRepositoryError
  , readBackOwnershipManifestDecisionForScope
  )
import Prodbox.ControlPlane.OwnershipManifestTransportClient
  ( lifecycleAuthorityOwnershipManifestAuthenticatedClient
  )
import Prodbox.ControlPlane.ProviderCaller
  ( ProviderCallerError
  , admitAuthenticatedProviderIntentAt
  , dispatchAuthenticatedProviderIntentFreshWithOperation
  , executeAdmittedProviderIntentAt
  , freshProviderSubmissionKey
  , renderProviderCallerError
  )
import Prodbox.Lifecycle.Authority.Submission (OperationId)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (ObserveProviderAwsScope)
  , ProviderRefError
  , ProviderRevision
  , ProviderRunMarker
  , mkProviderRunMarker
  , providerIntentRegisteredStackRef
  , providerStackRefText
  )
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface (ExplicitPerRun)
  , CleanupSurfaceWitness (ExplicitPerRunSurface)
  , DurableObservationRunScope (..)
  , LifecycleOperation (ReconcileDesiredAbsent, ReconcileDesiredPresent)
  , LinuxRke2FoundationId (..)
  , ObservationEvidenceScope
  , RegisteredResourceKey
  , evidenceDurableRunScope
  , evidenceLinuxRke2Foundation
  , evidenceRegistryRevision
  , mkObservationEvidenceScope
  , registeredResourceKeyFromText
  , registeredResourceKeyText
  )
import Prodbox.Lifecycle.Teardown.Observation
  ( ObservedResourceIdentity (..)
  , OwnershipManifestVersion (..)
  )
import Prodbox.Lifecycle.Teardown.OwnershipManifest
  ( OwnershipManifestDecisionEvidence
  , OwnershipManifestDecisionView (..)
  , OwnershipManifestError
  , OwnershipManifestPurpose (WriteAheadOwnership)
  , appendObservedIdentitiesToWriteAheadManifest
  , initialWriteAheadManifestWrite
  , mkWriteAheadManifestIntent
  , ownershipManifestDecisionView
  )
import Prodbox.Lifecycle.Teardown.Registry (lifecycleRegistryRevision)
import Prodbox.Lifecycle.Teardown.StackGeneration
  ( RegisteredStackGeneration
  , registeredStackGenerationKey
  , stackGenerationKeyAwsScope
  )

-- | What one admitted registered-stack creation produced.
data RegisteredStackCreationSubmission = RegisteredStackCreationSubmission
  { submittedCreateOperation :: !OperationId
  -- ^ The admitted create, named so a later diagnosis can join to it.
  , submittedProviderScopeOperation :: !OperationId
  -- ^ The admitted scope observation whose retained receipt proved the
  -- account and region.
  , submittedCreateEvidence :: !Text
  -- ^ The Provider receipt the create returned, unmodified.
  , submittedGenerationDisposition :: !AwsStackCreationCommitResult
  }
  deriving (Eq, Show)

-- | Every way one submission can fail, ordered as the lane runs.
--
-- Sprint @7.36@: only the last arm can leave an AWS resource behind, and its
-- generation is committed and independently read back before it is reachable.
-- Every earlier arm fails with nothing created.
data RegisteredStackCreationSubmitError
  = -- | The retained local control plane's identity could not be read, so the
    -- foundation the generation key is built on is unknown.  Creation refuses
    -- rather than minting a key a later cleanup run could not reproduce.
    RegisteredStackCreationFoundationUnknown !String
  | -- | The @ObserveProviderAwsScope@ dispatch failed.  Without it the account
    -- and region would have to be asserted, which the producer refuses.
    RegisteredStackCreationScopeDispatchFailed !ProviderCallerError
  | -- | The create could not be admitted.  Nothing was executed and no
    -- generation was committed, so nothing exists to be addressed.
    RegisteredStackCreationAdmissionFailed !ProviderCallerError
  | -- | The create is admitted and Pending and the Authority could not be
    -- reached to commit its generation.  The create is /not/ executed, so no
    -- stack exists; the Pending operation expires with the submission key.
    RegisteredStackCreationAuthorityUnreachable
      !LifecycleAuthorityAuthenticationError
  | -- | The Authority refused or could not settle the generation commit.  The
    -- create stays Pending and unexecuted.
    RegisteredStackCreationGenerationRefused !AwsStackCreationBindingError
  | -- | The commit was reached and did not settle as committed.  The create
    -- stays Pending and unexecuted.
    RegisteredStackCreationGenerationUnsettled !AwsStackCreationCommitResult
  | -- | The generation is committed and read back, and executing the admitted
    -- create failed.  This is the one arm under which an AWS resource may
    -- exist — and it is addressable, because its cycle is already durable.
    RegisteredStackCreationDispatchFailed
      !AwsStackCreationCommitResult
      !ProviderCallerError
      !(WriteAheadOwnershipProof 'WriteAheadOwnership)
  | -- | Sprint 7.41: the intent this lane was given is not a registered-stack
    -- create, so there is no stack to write a manifest about.
    RegisteredStackCreationIntentNotRegisteredStack
  | -- | Sprint 7.41: the run marker this create must carry is not one a
    -- provider would accept. Nothing has been created.
    RegisteredStackCreationRunMarkerInvalid !ProviderRefError
  | -- | Sprint 7.41: the committed generation could not be read back, so the
    -- account and region the ownership manifest must be keyed under are
    -- unknown. Nothing has been created.
    RegisteredStackCreationGenerationUnreadable !RegisteredStackCleanupSelectError
  | -- | Sprint 7.41: the write-ahead ownership manifest could not be built for
    -- the stack this create names.
    RegisteredStackCreationManifestInvalid !OwnershipManifestError
  | -- | Sprint 7.41: committing the write-ahead ownership manifest did not
    -- settle. Nothing has been created.
    RegisteredStackCreationManifestUnsettled !OwnershipManifestCommitResult
  | -- | Sprint 7.41: the write-ahead ownership manifest could not be read back
    -- independently before the effect.
    RegisteredStackCreationManifestUnreadable !OwnershipManifestRepositoryError
  | -- | Sprint 7.41: the manifest was read back and is not authority, so the
    -- effect is refused rather than run against a record a later teardown
    -- cannot use.
    RegisteredStackCreationManifestNotAuthority
  | -- | The execute step ran under a different operation from the admitted one,
    -- so the effect is not the one the committed generation names.  Carries the
    -- admitted operation first and the executed one second.
    RegisteredStackCreationOperationDiverged !OperationId !OperationId
  deriving (Eq, Show)

renderRegisteredStackCreationSubmitError
  :: RegisteredStackCreationSubmitError -> String
renderRegisteredStackCreationSubmitError err = case err of
  RegisteredStackCreationFoundationUnknown detail ->
    "resolve the retained local RKE2 foundation identity for the registered \
    \stack generation: "
      ++ detail
  RegisteredStackCreationScopeDispatchFailed detail ->
    "observe the Provider AWS scope before creating a registered stack: "
      ++ renderProviderCallerError detail
  RegisteredStackCreationAdmissionFailed detail ->
    "admit the registered stack create: " ++ renderProviderCallerError detail
  RegisteredStackCreationAuthorityUnreachable detail ->
    "the registered stack create is admitted and was not executed, because its \
    \lifecycle generation could not be committed: "
      ++ renderLifecycleAuthorityAuthenticationError detail
  RegisteredStackCreationGenerationRefused detail ->
    "the registered stack create is admitted and was not executed, because the \
    \Authority refused its lifecycle generation: "
      ++ show detail
  RegisteredStackCreationGenerationUnsettled disposition ->
    "the registered stack create is admitted and was not executed, because its \
    \lifecycle generation did not settle as committed: "
      ++ show disposition
  RegisteredStackCreationDispatchFailed disposition detail proof ->
    -- Sprint 7.41: this is the one arm under which an AWS resource may exist,
    -- and it no longer dies as a sentence about what went wrong. It carries the
    -- durable obligation: the manifest that names the coordinates this create
    -- was authorized to make was committed and read back before the effect, so
    -- an operator has a record to act on and a command that consumes it.
    "the registered stack lifecycle generation is committed ("
      ++ show disposition
      ++ ") and executing the admitted create failed, so a stack may exist \
         \under that cycle: "
      ++ renderProviderCallerError detail
      ++ ". A write-ahead ownership manifest for "
      ++ Text.unpack
        (registeredResourceKeyText (writeAheadOwnershipProofStackKey proof))
      ++ " is durable at version "
      ++ Text.unpack
        (manifestVersionText (writeAheadOwnershipProofVersion proof))
      ++ " and names every coordinate this create was authorized to make. Run \
         \the registered cleanup for that stack; it reads that manifest rather \
         \than guessing, and this obligation is not discharged until it \
         \observes exact absence."
  RegisteredStackCreationIntentNotRegisteredStack ->
    "this lane submits registered-stack creates, and the intent it was given \
    \names no registered stack, so no write-ahead ownership manifest could be \
    \written for it. Nothing was created."
  RegisteredStackCreationRunMarkerInvalid detail ->
    "this create's provider-held run marker is not one AWS would accept as a \
    \tag value, so the create was not admitted and nothing was created: "
      ++ show detail
  RegisteredStackCreationGenerationUnreadable detail ->
    "the registered stack create is admitted and was not executed, because the \
    \lifecycle generation it just committed could not be read back, so the \
    \account and region its ownership manifest must be keyed under are \
    \unknown: "
      ++ renderRegisteredStackCleanupSelectError detail
  RegisteredStackCreationManifestInvalid detail ->
    "the registered stack create is admitted and was not executed, because its \
    \write-ahead ownership manifest could not be built: "
      ++ show detail
  RegisteredStackCreationManifestUnsettled disposition ->
    "the registered stack create is admitted and was not executed, because its \
    \write-ahead ownership manifest did not settle as committed: "
      ++ show disposition
  RegisteredStackCreationManifestUnreadable detail ->
    "the registered stack create is admitted and was not executed, because its \
    \write-ahead ownership manifest could not be read back independently: "
      ++ show detail
  RegisteredStackCreationManifestNotAuthority ->
    "the registered stack create is admitted and was not executed, because its \
    \write-ahead ownership manifest read back as an observation rather than as \
    \authority. A create whose record a later teardown could not use is \
    \refused before the effect, not after it."
  RegisteredStackCreationOperationDiverged admitted executed ->
    "the registered stack create executed under an operation the committed \
    \lifecycle generation does not name; admitted "
      ++ show admitted
      ++ " and executed "
      ++ show executed

-- | Sprint 7.41: proof that this submission's write-ahead ownership manifest
-- was committed and independently read back /before/ any provider effect.
--
-- The constructor is not exported and there is exactly one minter,
-- 'proveWriteAheadOwnership', which accepts nothing but a read-back that came
-- back as authority. The execute step takes this value as an argument, so an
-- execute that skips the read-back does not compile rather than failing a
-- review: there is no other way to obtain what it requires.
--
-- The purpose index is on the type rather than on a field for the same reason.
-- A cleanup-only adoption receipt is a manifest too, and it is authority for a
-- destroy of resources somebody else made; letting one inhabit this slot would
-- let an adoption stand in for a create's own record of what it was about to
-- make. @'WriteAheadOwnership'@ is the only index this GADT can produce.
data WriteAheadOwnershipProof (purpose :: OwnershipManifestPurpose) where
  WriteAheadOwnershipProved
    :: !RegisteredResourceKey
    -> !OwnershipManifestVersion
    -> WriteAheadOwnershipProof 'WriteAheadOwnership

deriving stock instance Eq (WriteAheadOwnershipProof purpose)

deriving stock instance Show (WriteAheadOwnershipProof purpose)

writeAheadOwnershipProofStackKey
  :: WriteAheadOwnershipProof purpose -> RegisteredResourceKey
writeAheadOwnershipProofStackKey (WriteAheadOwnershipProved key _) = key

writeAheadOwnershipProofVersion
  :: WriteAheadOwnershipProof purpose -> OwnershipManifestVersion
writeAheadOwnershipProofVersion (WriteAheadOwnershipProved _ version) = version

manifestVersionText :: OwnershipManifestVersion -> Text
manifestVersionText (OwnershipManifestVersion value) = value

runScopeValue :: DurableObservationRunScope -> Text
runScopeValue (DurableObservationRunScope value) = value

-- | The one minter. A read-back that came back as an observation -- absent,
-- partial, unobservable, or present-without-complete-evidence -- is not a
-- proof, and there is no arm here that turns one into one.
--
-- Exported so a test can obtain a proof the only way production does, by
-- exercising the real minter against real complete evidence. That is the same
-- shape @verifiedCallerSlotFixture@ uses for the authentication capability:
-- publishing the minter is not publishing the constructor, and a caller still
-- has to produce evidence a bind actually returned.
proveWriteAheadOwnership
  :: RegisteredResourceKey
  -> OwnershipManifestDecisionEvidence
  -> Maybe (WriteAheadOwnershipProof 'WriteAheadOwnership)
proveWriteAheadOwnership stackKey evidence =
  case ownershipManifestDecisionView evidence of
    OwnershipManifestDecisionComplete _ version ->
      Just (WriteAheadOwnershipProved stackKey version)
    OwnershipManifestDecisionObservation _ -> Nothing

-- | The foundation id every generation key for this host is built on.
--
-- Derived from the retained control plane's cluster id, so a cleanup run
-- computes the same value from the same retained config without knowing which
-- run created the stack.  The prefix keeps it self-describing in a durable
-- record.
homeLinuxRke2FoundationId :: Text -> LinuxRke2FoundationId
homeLinuxRke2FoundationId clusterId =
  LinuxRke2FoundationId ("linux-rke2/" <> clusterId)

-- | A creating run scope.  Provenance only: 'selectRegisteredStackGeneration'
-- records it and never matches on it, which is exactly why a per-invocation
-- value is correct here and would not be in the key.
registeredStackCreationRunScope :: Integer -> DurableObservationRunScope
registeredStackCreationRunScope micros =
  DurableObservationRunScope ("stack-create/" <> Text.pack (show micros))

-- | The evidence scope one registered-stack creation is submitted under.
--
-- The AWS scope is deliberately 'Nothing': the account and region enter the
-- generation only through the Provider proof the Authority reads back, so
-- offering a slot for them here would be offering a slot for an assertion.
registeredStackCreationScope
  :: LinuxRke2FoundationId
  -> DurableObservationRunScope
  -> ObservationEvidenceScope
registeredStackCreationScope foundation runScope =
  mkObservationEvidenceScope
    ExplicitPerRun
    lifecycleRegistryRevision
    runScope
    foundation
    Nothing
    ReconcileDesiredPresent

-- | Submit one registered-stack creation through the Authority, commit its
-- lifecycle generation, and only then execute it.
--
-- The order is the producer's, and it matters: the scope observation precedes
-- the create's admission so the generation can be committed against a proven
-- account and region; the generation precedes the run-scoped binding so a
-- failure midway leaves the addressable record present rather than the
-- run-scoped one alone; and the whole commit precedes execution so no AWS
-- resource can exist under a cycle no later run can name.
--
-- The create is admitted and executed at __one__ submission key.  A fresh key
-- per call would make the execute step a different operation from the admitted
-- one, which is the property that makes the generation's binding meaningful at
-- all.
submitRegisteredStackCreation
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> Text
  -- ^ submission-key prefix for this create
  -> ProviderRevision
  -> (ProviderRunMarker -> ProviderIntent)
  -- ^ the caller's exact registered-stack create intent, built from the run
  -- marker this lane mints.  A builder rather than a value because the marker
  -- must be inside the intent and the intent must be byte-identical at admit
  -- and execute: the lane owns both the run scope and the submission key, so it
  -- is the only place that can guarantee one marker reaches both calls.
  -> IO (Either RegisteredStackCreationSubmitError RegisteredStackCreationSubmission)
submitRegisteredStackCreation authentication repoRoot prefix revision buildIntent = do
  basics <- loadUnencryptedBasics repoRoot
  case basics of
    Left detail -> pure (Left (RegisteredStackCreationFoundationUnknown detail))
    Right identity -> do
      scopeDispatch <-
        dispatchAuthenticatedProviderIntentFreshWithOperation
          authentication
          (prefix <> "-observe-aws-scope")
          ObserveProviderAwsScope
      case scopeDispatch of
        Left err -> pure (Left (RegisteredStackCreationScopeDispatchFailed err))
        Right (scopeOperation, _) -> do
          createKey <- freshProviderSubmissionKey prefix
          -- Sprint 7.41: the run scope is minted here, before the intent
          -- exists, because the intent carries it. It was minted after
          -- admission until this sprint, which was fine while nothing outside
          -- the host needed to know it.
          micros <- currentMicros
          let runScope = registeredStackCreationRunScope micros
          case mkProviderRunMarker (runScopeValue runScope) createKey of
            Left err -> pure (Left (RegisteredStackCreationRunMarkerInvalid err))
            Right marker -> do
              let intent = buildIntent marker
              admitted <-
                admitAuthenticatedProviderIntentAt authentication createKey intent
              case admitted of
                Left err -> pure (Left (RegisteredStackCreationAdmissionFailed err))
                Right createOperation ->
                  commitGenerationThenExecute
                    intent
                    (basicsClusterId identity)
                    runScope
                    createKey
                    scopeOperation
                    createOperation
 where
  commitGenerationThenExecute intent clusterId runScope createKey scopeOperation createOperation = do
    let scope =
          registeredStackCreationScope
            (homeLinuxRke2FoundationId clusterId)
            runScope
    committed <-
      withLifecycleAuthorityAuthenticatedTransport authentication $ \transport ->
        attemptAwsStackCreationBindingCommit
          (lifecycleAuthorityAwsStackCreationBindingAuthenticatedClient transport)
          createOperation
          scopeOperation
          revision
          scope
    case committed of
      Left err ->
        pure (Left (RegisteredStackCreationAuthorityUnreachable err))
      Right (Left err) ->
        pure (Left (RegisteredStackCreationGenerationRefused err))
      Right (Right disposition)
        | settled disposition ->
            commitOwnershipThenExecute
              intent
              scope
              createKey
              scopeOperation
              createOperation
              disposition
        | otherwise ->
            pure (Left (RegisteredStackCreationGenerationUnsettled disposition))

  -- Sprint 7.41: between the generation commit and the effect, at the same
  -- submission key.
  --
  -- A generation names a cycle. It made the 2026-09-08 create addressable and
  -- left its VPC, roles, policy and cluster named by nothing, because nothing
  -- else was durable when the transport deadline cancelled the reply. This
  -- writes the record that names them, reads it back through a second,
  -- independent call, and only then runs the effect -- and it refuses the
  -- effect if any of that does not hold, because a create whose record a later
  -- teardown could not use is worse than a create that did not happen.
  commitOwnershipThenExecute intent scope createKey scopeOperation createOperation disposition =
    case providerIntentRegisteredStackRef intent
      >>= registeredResourceKeyFromText . providerStackRefText of
      Nothing ->
        pure (Left RegisteredStackCreationIntentNotRegisteredStack)
      Just stackKey -> do
        -- The caller's creation scope deliberately carries no AWS coordinates:
        -- only the independently read-back Provider receipt may introduce them,
        -- and the ownership-manifest identity refuses a scope without them.
        -- The generation that just committed carries the proven account and
        -- region, so the manifest scope is derived from the generation the host
        -- reads back rather than from anything the host could assert -- which is
        -- the same reason the Authority derives the creation binding's scope
        -- from it and not from the caller's.
        selected <-
          selectRegisteredStackGenerationForCleanup
            authentication
            repoRoot
            stackKey
            ExplicitPerRun
        case selected of
          Left err -> pure (Left (RegisteredStackCreationGenerationUnreadable err))
          Right generation ->
            withManifestScope
              intent
              stackKey
              (provenManifestScope scope generation)
              createKey
              scopeOperation
              createOperation
              disposition

  withManifestScope intent stackKey scope createKey scopeOperation createOperation disposition =
    case mkWriteAheadManifestIntent ExplicitPerRunSurface stackKey scope of
      Left err -> pure (Left (RegisteredStackCreationManifestInvalid err))
      Right manifestIntent -> do
        committed <-
          withLifecycleAuthorityAuthenticatedTransport authentication $ \transport ->
            attemptOwnershipManifestWriteAheadCommit
              (lifecycleAuthorityOwnershipManifestAuthenticatedClient transport)
              (initialWriteAheadManifestWrite manifestIntent)
        case committed of
          Left err -> pure (Left (RegisteredStackCreationAuthorityUnreachable err))
          Right (Left err) ->
            pure (Left (RegisteredStackCreationManifestUnreadable err))
          Right (Right manifestDisposition)
            | not (manifestSettled manifestDisposition) ->
                pure
                  ( Left
                      (RegisteredStackCreationManifestUnsettled manifestDisposition)
                  )
            | otherwise -> do
                -- The read-back is a second, independent call rather than a
                -- projection of the commit response: a commit that says it
                -- created an object and a read that finds one are different
                -- observations, and only the second is evidence.
                readBack <-
                  withLifecycleAuthorityAuthenticatedTransport authentication $ \transport ->
                    readBackOwnershipManifestDecisionForScope
                      (lifecycleAuthorityOwnershipManifestAuthenticatedClient transport)
                      stackKey
                      scope
                case readBack of
                  Left err ->
                    pure (Left (RegisteredStackCreationAuthorityUnreachable err))
                  Right (Left err) ->
                    pure (Left (RegisteredStackCreationManifestUnreadable err))
                  Right (Right evidence) ->
                    case proveWriteAheadOwnership stackKey evidence of
                      Nothing ->
                        pure (Left RegisteredStackCreationManifestNotAuthority)
                      Just proof ->
                        executeAdmittedCreate
                          intent
                          manifestIntent
                          proof
                          createKey
                          scopeOperation
                          createOperation
                          disposition

  -- The scope the ownership manifest is keyed under: the caller's creation
  -- scope with the account and region the committed generation proved.
  provenManifestScope scope generation =
    mkObservationEvidenceScope
      ExplicitPerRun
      (evidenceRegistryRevision scope)
      (evidenceDurableRunScope scope)
      (evidenceLinuxRke2Foundation scope)
      (Just (stackGenerationKeyAwsScope (registeredStackGenerationKey generation)))
      ReconcileDesiredPresent

  -- The generation and the write-ahead ownership manifest are both durable and
  -- both read back before this runs, so a failure here leaves a record that
  -- names the coordinates rather than an anonymous stack.
  --
  -- The proof is an argument rather than a check: there is no way to call this
  -- without having read the manifest back, because there is no other way to
  -- obtain a 'WriteAheadOwnershipProof'.
  --
  -- The executed operation must be the admitted one.  Same key, same digest,
  -- same intent means the admission ledger hands back the operation it already
  -- admitted; anything else means the effect ran under an operation the
  -- committed generation does not name, which is the exact condition this lane
  -- exists to prevent and is reported rather than returned as a success.
  executeAdmittedCreate
    intent
    manifestIntent
    proof
    createKey
    scopeOperation
    createOperation
    disposition = do
      executed <- executeAdmittedProviderIntentAt authentication createKey intent
      case executed of
        Left err ->
          pure (Left (RegisteredStackCreationDispatchFailed disposition err proof))
        Right (executedOperation, evidence)
          | executedOperation /= createOperation ->
              pure
                ( Left
                    ( RegisteredStackCreationOperationDiverged
                        createOperation
                        executedOperation
                    )
                )
          | otherwise -> do
              appendCompletion manifestIntent proof executedOperation
              pure
                ( Right
                    RegisteredStackCreationSubmission
                      { submittedCreateOperation = createOperation
                      , submittedProviderScopeOperation = scopeOperation
                      , submittedCreateEvidence = evidence
                      , submittedGenerationDisposition = disposition
                      }
                )

  -- Sprint 7.41: the return route's append.
  --
  -- The identity appended is the one the provider actually returned for this
  -- create -- the settled operation the effect ran under, against the stack the
  -- write-ahead record already declared. It is deliberately not parsed out of
  -- the provider's evidence text: an identity minted by reading a diagnostic is
  -- the shape Sprint `4.98` removed from the absence vocabulary, and it has no
  -- place in the ownership one either.
  --
  -- The append is best effort by construction, and that is the whole reason
  -- deliverable 4 exists. If the process dies here, the write-ahead record is
  -- still durable and still names the coordinates, and the provider-side tags
  -- still carry the run scope and cycle -- so the outcome of losing this call
  -- is a manifest without identities, which the destroy authorization refuses
  -- by naming the missing entry rather than by destroying nothing.
  appendCompletion manifestIntent proof executedOperation =
    case appendObservedIdentitiesToWriteAheadManifest
      manifestIntent
      [
        ( writeAheadOwnershipProofStackKey proof
        ,
          [ ObservedResourceIdentity
              ( "provider-operation/"
                  <> Text.pack (show executedOperation)
              )
          ]
        )
      ] of
      Left _ -> pure ()
      Right completion -> do
        _ <-
          withLifecycleAuthorityAuthenticatedTransport authentication $ \transport ->
            attemptOwnershipManifestCompletionCommit
              (lifecycleAuthorityOwnershipManifestAuthenticatedClient transport)
              completion
        pure ()

  manifestSettled result = case result of
    OwnershipManifestCommitCreated -> True
    OwnershipManifestCommitExactReplay -> True
    OwnershipManifestCommitConflict -> False
    OwnershipManifestCommitResponseLost {} -> False
    OwnershipManifestCommitUnavailable {} -> False

  -- A replay is a settled outcome: the retried create was recognized as the
  -- same admitted operation and handed back its own cycle, which is the
  -- property that makes this lane safe to retry.
  settled disposition = case disposition of
    AwsStackCreationCommitCreated -> True
    AwsStackCreationCommitExactReplay -> True
    AwsStackCreationCommitConflict -> False
    AwsStackCreationCommitResponseLost {} -> False
    AwsStackCreationCommitUnavailable {} -> False

-- ---------------------------------------------------------------------------
-- The consumer half
-- ---------------------------------------------------------------------------

data RegisteredStackCleanupSelectError
  = -- | The retained control plane\'s identity could not be read, so the
    -- foundation this cleanup run would address the series under is unknown.
    -- It refuses rather than addressing a series it invented.
    RegisteredStackCleanupFoundationUnknown !String
  | -- | This cleanup run could not observe the Provider AWS scope, so the
    -- account and region that address the series are unproven.
    RegisteredStackCleanupScopeDispatchFailed !ProviderCallerError
  | -- | The Authority could not be reached.
    RegisteredStackCleanupAuthorityUnreachable !LifecycleAuthorityAuthenticationError
  | -- | The series cursor or the generation the ordinal addresses refused.  An
    -- unopened series, an unobservable store, a slot collision, and a surface
    -- that may not select this identity are distinct refusals behind this arm,
    -- and none of them degrades into \"nothing is there\".
    RegisteredStackCleanupSelectionRefused !AwsStackCreationBindingError
  deriving (Eq, Show)

renderRegisteredStackCleanupSelectError
  :: RegisteredStackCleanupSelectError -> String
renderRegisteredStackCleanupSelectError err = case err of
  RegisteredStackCleanupFoundationUnknown detail ->
    "resolve the retained local RKE2 foundation identity for registered stack \
    \cleanup selection: "
      ++ detail
  RegisteredStackCleanupScopeDispatchFailed detail ->
    "observe the Provider AWS scope before selecting a registered stack for \
    \cleanup: "
      ++ renderProviderCallerError detail
  RegisteredStackCleanupAuthorityUnreachable detail ->
    "reach the Lifecycle Authority to select a registered stack generation: "
      ++ renderLifecycleAuthorityAuthenticationError detail
  RegisteredStackCleanupSelectionRefused detail ->
    "the registered stack generation could not be selected for cleanup: "
      ++ show detail

-- | The evidence scope a cleanup run selects under.
--
-- The foundation is the same value a creating run used, because both derive it
-- from the retained cluster id — that identity is what makes selection across
-- runs possible at all.  The run scope differs and is meant to: the selector
-- records it and never matches on it.
registeredStackCleanupScope
  :: CleanupSurface
  -> LinuxRke2FoundationId
  -> DurableObservationRunScope
  -> ObservationEvidenceScope
registeredStackCleanupScope surface foundation runScope =
  mkObservationEvidenceScope
    surface
    lifecycleRegistryRevision
    runScope
    foundation
    Nothing
    ReconcileDesiredAbsent

-- | Select the current lifecycle generation of one registered stack for
-- cleanup, from a run that knows only which stack it intends to act on.
--
-- This is the production consumer the sprint owed.  It presents facts it can
-- prove — the registered key, its own admitted Provider AWS-scope observation,
-- its foundation, and its own run scope and surface — and reaches the cycle
-- through the series cursor and the generation that cursor's ordinal
-- addresses, and through nothing else.  There is no parameter through which
-- visible residue, the creating run's scope, or a caller-asserted account could
-- enter.
selectRegisteredStackGenerationForCleanup
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> RegisteredResourceKey
  -> CleanupSurface
  -> IO
       ( Either
           RegisteredStackCleanupSelectError
           RegisteredStackGeneration
       )
selectRegisteredStackGenerationForCleanup
  authentication
  repoRoot
  resourceKey
  surface = do
    basics <- loadUnencryptedBasics repoRoot
    case basics of
      Left detail -> pure (Left (RegisteredStackCleanupFoundationUnknown detail))
      Right identity -> do
        scopeDispatch <-
          dispatchAuthenticatedProviderIntentFreshWithOperation
            authentication
            "cleanup-observe-aws-scope"
            ObserveProviderAwsScope
        case scopeDispatch of
          Left err ->
            pure (Left (RegisteredStackCleanupScopeDispatchFailed err))
          Right (scopeOperation, _) ->
            select (basicsClusterId identity) scopeOperation
   where
    select clusterId scopeOperation = do
      micros <- currentMicros
      let scope =
            registeredStackCleanupScope
              surface
              (homeLinuxRke2FoundationId clusterId)
              (registeredStackCleanupRunScope micros)
      selected <-
        withLifecycleAuthorityAuthenticatedTransport authentication $ \transport ->
          selectRegisteredStackGenerationOverTransport
            transport
            resourceKey
            scopeOperation
            scope
      pure $ case selected of
        Left err -> Left (RegisteredStackCleanupAuthorityUnreachable err)
        Right (Left err) -> Left (RegisteredStackCleanupSelectionRefused err)
        Right (Right generation) -> Right generation

registeredStackCleanupRunScope :: Integer -> DurableObservationRunScope
registeredStackCleanupRunScope micros =
  DurableObservationRunScope ("stack-cleanup/" <> Text.pack (show micros))

currentMicros :: IO Integer
currentMicros = floor . (* 1000000) <$> getPOSIXTime
