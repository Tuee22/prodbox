{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Host-side orchestration for public-edge TLS custody.  The coordinator
-- carries only opaque certificate ciphertext, Transit ciphertext, signed
-- receipts, and Authority references.  The selected Agent is the sole
-- Kubernetes Secret reader/writer and the retained-home Agent is the sole
-- Transit DEK holder.
module Prodbox.ControlPlane.TlsRetentionWorkflow
  ( TlsRetentionWorkflow (..)
  , TlsWorkflowRetainOutcome (..)
  , TlsWorkflowRestoreOutcome (..)
  , TlsRetentionWorkflowError (..)
  , retainPublicEdgeTlsWorkflow
  , restorePublicEdgeTlsWorkflow
  )
where

import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.TlsDekExchange
  ( mkTlsWrappedDek
  , tlsDekPreparedPublicKey
  , tlsWrappedDekText
  )
import Prodbox.ControlPlane.TlsRetentionAuthorityClient
  ( TlsAuthorityPromotionOutcome (..)
  , TlsAuthorityStagingOutcome (..)
  , TlsRetentionAuthorityClient (..)
  , TlsRetentionAuthorityClientError
  )
import Prodbox.ControlPlane.TlsRetentionClient
  ( TlsRetentionClient (..)
  , TlsRetentionClientError (..)
  , TlsRetentionHttpResponseObservation (..)
  )
import Prodbox.ControlPlane.TlsRetentionEndpoint
  ( TlsEnvelopeObservation (..)
  , TlsRetentionPlainResponseCause (..)
  , TlsRetentionReceipt (..)
  , TlsStoreConfirmationFailure (..)
  , TlsStorePutDisposition (..)
  , TlsStoreRepositoryFailure (..)
  , TlsVersionEnvelopeObservation (..)
  )
import Prodbox.ControlPlane.TlsTargetAgentClient
  ( TlsTargetAgentClient (..)
  , TlsTargetAgentClientError (..)
  )
import Prodbox.ControlPlane.TlsTargetAgentEndpoint
  ( TlsTargetRestoreReceipt (..)
  , TlsTargetRetainReceipt (..)
  )
import Prodbox.Lifecycle.Authority.TlsRetention
  ( CertIdentity (..)
  , KeyRotationApproval
  , PromotionEvidence (..)
  , RestoreObservation (..)
  , RetainedTlsRef (..)
  , RetentionVersion (..)
  , TlsLegacyRecoveryCollisionEvidence (..)
  , TlsLegacyRecoveryEvidence (..)
  , TlsLegacyRecoverySuccessorEvidence (..)
  , TlsRestoreDecision (..)
  , TlsRestoreRefusal
  , TlsRetentionPending (..)
  , TlsRetentionState (..)
  , TlsSealedEnvelope
  , TlsUnopenableVersionEvidence (..)
  , currentRetainedRef
  , decideTlsRestore
  , mkTlsSealedEnvelope
  , nextRetentionVersion
  , pendingTlsRetention
  , tlsCertificateCiphertextBytes
  , tlsSealedEnvelopeDigest
  , tlsUnopenableSuccessorVersion
  , tlsWrappedDekBytes
  )

data TlsRetentionWorkflow m = TlsRetentionWorkflow
  { tlsWorkflowAuthority :: !(TlsRetentionAuthorityClient m)
  , tlsWorkflowAdapter :: !(TlsRetentionClient m)
  , tlsWorkflowRetainedHomeAgent :: !(TlsTargetAgentClient m)
  , tlsWorkflowSelectedAgent :: !(TlsTargetAgentClient m)
  }

data TlsWorkflowRetainOutcome
  = TlsWorkflowNothingToRetain
  | TlsWorkflowRetained !RetainedTlsRef
  | -- | Retained at the one successor version admitted past an Authority-lane
    -- version proven unopenable. Carries the skipped version and the promoted
    -- reference, because a successful retain that permanently abandoned an
    -- immutable object is the one success worth announcing: the failure
    -- diagnostic never fires for it, and otherwise the only record of the skip
    -- is a durable Authority field nobody reads.
    TlsWorkflowRetainedPastUnopenableVersion
      !RetentionVersion
      !RetainedTlsRef
  deriving stock (Eq, Show)

data TlsWorkflowRestoreOutcome
  = TlsWorkflowRestored !RetainedTlsRef
  | TlsWorkflowIssuancePermitted
  deriving stock (Eq, Show)

data TlsRetentionWorkflowError
  = TlsWorkflowAuthorityFailed !TlsRetentionAuthorityClientError
  | TlsWorkflowAdapterFailed !TlsRetentionClientError
  | TlsWorkflowHomeAgentFailed !TlsTargetAgentClientError
  | TlsWorkflowSelectedAgentFailed !TlsTargetAgentClientError
  | TlsWorkflowEnvelopeInvalid !Text
  | TlsWorkflowAdapterReadBackMismatch
  | TlsWorkflowSourceReadBackMismatch
  | TlsWorkflowStagingStateMismatch
  | TlsWorkflowPromotionStateMismatch
  | TlsWorkflowLegacyEnvelopeCorrupt
  | TlsWorkflowLegacySourceMissing
  | TlsWorkflowLegacyAdoptionNotIdempotent
  | TlsWorkflowPendingWithoutCurrent
  | -- | The Authority-lane retention object this retain was about to claim was
    -- already occupied when it looked, before it wrote anything.  Carries the
    -- version it tried, which is the coordinate an unattributed store conflict
    -- did not name; the occupant's digest is deliberately not carried, because
    -- it is a custody value and this refusal is rendered into a protected log.
    TlsWorkflowRetentionVersionOccupied !RetentionVersion
  | -- | A staged pending was resumed and its store answered an exact immutable
    -- collision, so the version that pending is for is held by an envelope that
    -- is not the pending's.  Distinct from the arm above and not merely a
    -- variant of it: that one looked first and never wrote, this one found out
    -- at the write, and only one of the two can be resolved by rebasing.
    TlsWorkflowResumedRetentionVersionOccupied !RetentionVersion
  | -- | The Authority-lane object at the version this retain was about to claim
    -- is present and does not decode.
    TlsWorkflowRetentionVersionCorrupt !RetentionVersion
  | -- | The Authority-lane object at this version decodes, but its wrapped DEK
    -- does not open under the retained-home key, so nothing this control plane
    -- holds can ever restore it.  Distinct from corrupt: the bytes are a
    -- well-formed envelope, they are just not one of ours.  Since Sprint
    -- @2.135@ this is the refusal when no bounded successor is admissible from
    -- the durable state; where one is, the lane takes it.
    TlsWorkflowRetentionVersionUnopenable !RetentionVersion
  | -- | The live source Secret was readable when the occupant was proven
    -- unopenable and gone when the successor was sealed at the version named
    -- here.  Distinct from the ordinary nothing-to-retain answer, which is
    -- about a slot that never had a source.
    TlsWorkflowRetentionSuccessorSourceMissing !RetentionVersion
  | TlsWorkflowRestoreRefused !TlsRestoreRefusal
  | TlsWorkflowWrappedDekInvalid
  deriving stock (Eq, Show)

retainPublicEdgeTlsWorkflow
  :: TlsRetentionWorkflow IO
  -> KeyRotationApproval
  -> IO (Either TlsRetentionWorkflowError TlsWorkflowRetainOutcome)
retainPublicEdgeTlsWorkflow workflow approval = do
  observed <- observeTlsRetentionCurrent (tlsWorkflowAuthority workflow)
  case first TlsWorkflowAuthorityFailed observed of
    Left err -> pure (Left err)
    Right state -> case pendingTlsRetention state of
      Just pending -> resumePending state pending
      Nothing -> do
        let version = nextRetentionVersion state
        case currentRetainedRef state of
          Just _ -> claimFreshVersion state version
          Nothing -> do
            occupied <-
              observeTlsRetentionVersion
                (tlsWorkflowAdapter workflow)
                version
            case first TlsWorkflowAdapterFailed occupied of
              Left err -> pure (Left err)
              Right TlsVersionEnvelopeMissing -> createFresh state version
              Right TlsVersionEnvelopeCorrupt ->
                pure (Left TlsWorkflowLegacyEnvelopeCorrupt)
              Right (TlsVersionEnvelopePresent envelope _) ->
                adoptLegacy state version envelope
 where
  -- Observe the Authority lane before claiming a version on it.
  --
  -- The observation above this one reads the /legacy/ lane, and reads it to
  -- decide whether there is a pre-Authority envelope to adopt; it says nothing
  -- about whether the object this retain is about to write already exists.
  -- Nothing did, so a store whose occupancy had drifted ahead of the
  -- Authority's current version -- which is what an interrupted retain leaves --
  -- reached 'storeEnvelope', hit its put-if-absent, and surfaced as
  -- @put/conflict/confirmation/bytes-mismatch@: a refusal naming neither the
  -- version nor either digest.
  --
  -- The occupant is deliberately not adopted here. Adoption on this lane would
  -- promote an envelope nothing staged, which is a behaviour change on a
  -- Standard-P surface; naming the collision is the measurement, and it is what
  -- the successful path is unchanged by.
  claimFreshVersion state version = do
    occupied <-
      observeTlsRetentionAuthorityVersion
        (tlsWorkflowAdapter workflow)
        version
    case first TlsWorkflowAdapterFailed occupied of
      Left err -> pure (Left err)
      Right TlsVersionEnvelopeMissing -> createFresh state version
      Right TlsVersionEnvelopeCorrupt ->
        pure (Left (TlsWorkflowRetentionVersionCorrupt version))
      Right (TlsVersionEnvelopePresent occupant _) ->
        adoptOccupiedAuthorityVersion state version occupant

  -- Converge onto the envelope the store already holds at this version.
  --
  -- __Why adoption rather than refusal, and why it is safe.__ The envelope a
  -- retain builds is not reproducible: 'retainTlsAtSelectedAgent' draws a fresh
  -- DEK and nonce every time, so two retains of the same certificate seal to
  -- different bytes.  A version the store already holds can therefore never be
  -- written again, and a refusal at this point is permanent for that version --
  -- which on a host whose store had drifted one version ahead of the Authority
  -- meant every retain failed forever, and with it the chart delete that runs
  -- one.
  --
  -- The occupant is adopted rather than trusted.  The AEAD's associated data
  -- binds the version, the certificate identity and the source Secret, so
  -- 'restoreTlsAtSelectedAgent' cannot open an envelope that was sealed for
  -- anything but the live material, and it writes only after that open
  -- succeeds and after re-checking both fields against the reference.  An
  -- occupant that is not this certificate and this source fails to decrypt;
  -- one that is, decrypts to the bytes already live.  So the apply is a proof
  -- and not a gamble, which is the same property the legacy-lane adoption has
  -- relied on since Sprint `4.50`.
  --
  -- Nothing about the Authority's own rules is relaxed.  The candidate is
  -- staged through the ordinary transition, so it still has to be the exact
  -- successor version, still may not regress certificate validity, and still
  -- needs approval for a key change.  What changes is only which envelope the
  -- successor carries: the one the store already committed, instead of one it
  -- can never accept.
  adoptOccupiedAuthorityVersion state version occupant = do
    homePreparedResult <-
      prepareTlsDekDestination (tlsWorkflowRetainedHomeAgent workflow)
    case first TlsWorkflowHomeAgentFailed homePreparedResult of
      Left err -> pure (Left err)
      Right homePrepared -> do
        retainedResult <-
          retainSelectedPublicEdgeTls
            (tlsWorkflowSelectedAgent workflow)
            version
            (tlsDekPreparedPublicKey homePrepared)
        case retainedResult of
          -- No live certificate to retain at all is the ordinary nothing-to-do
          -- answer only when nothing is staged.  Reached while resuming a
          -- durable pending, that same 404 would report success while leaving
          -- the outbox unresolved, which is a false success rather than a
          -- nothing-to-do: the source is gone and the staged candidate binds
          -- it.
          Left (TlsTargetAgentClientHttpStatus 404 _)
            | Nothing <- pendingTlsRetention state ->
                pure (Right TlsWorkflowNothingToRetain)
            | otherwise ->
                pure
                  ( Left
                      (TlsWorkflowRetentionSuccessorSourceMissing version)
                  )
          Left err -> pure (Left (TlsWorkflowSelectedAgentFailed err))
          Right retained -> do
            let candidate = referenceFor version retained occupant
            applied <- applyTlsEnvelopeAtSelected workflow candidate occupant
            case applied of
              -- The occupant's DEK does not open under the retained-home key,
              -- so it is not an envelope this control plane can ever restore --
              -- and its version is not one this control plane can ever write,
              -- because a fresh DEK and nonce are drawn per call.  One bounded
              -- successor past it is the only way forward; where no successor
              -- is admissible the refusal below still names the version.
              Left
                ( TlsWorkflowHomeAgentFailed
                    TlsTargetAgentClientHomeRewrapCiphertextAuthenticationFailed
                  ) ->
                  recoverUnopenableAuthorityVersion state version occupant
              Left err -> pure (Left err)
              Right receipt
                | tlsTargetRestoredReadBackSource receipt
                    == retainedSourceSecret candidate ->
                    stageAndResume state approval candidate occupant
                | otherwise -> pure (Left TlsWorkflowSourceReadBackMismatch)

  -- Step past an Authority-lane version proven unopenable, exactly once.
  --
  -- __Why the state gate is the whole design.__ The Authority admits this
  -- transition only from a committed current reference, because that is what
  -- makes the skip reconstructible: the version being skipped is the one
  -- @nextRetentionVersion@ would have selected from that predecessor, so
  -- 'validateTlsRetentionState' can reproduce the staging from the durable
  -- record alone.  From any pending state there is no such predecessor to
  -- reconstruct it from, and the refusal that named this condition before this
  -- transition existed is still the honest answer.
  --
  -- __Why the successor slot is observed first.__ The admission is one version,
  -- not a search.  If the single successor is itself occupied this lane refuses
  -- by name rather than looking at the integer after it; an unbounded walk is
  -- how a retain starts stepping over objects it should have refused.
  recoverUnopenableAuthorityVersion state version occupant = case state of
    TlsRetentionCurrent previous -> do
      let evidence =
            TlsUnopenableVersionEvidence
              { tlsUnopenableVersion = version
              , tlsUnopenableEnvelopeDigest = tlsSealedEnvelopeDigest occupant
              }
          successorVersion = tlsUnopenableSuccessorVersion evidence
      successorOccupied <-
        observeTlsRetentionAuthorityVersion
          (tlsWorkflowAdapter workflow)
          successorVersion
      case first TlsWorkflowAdapterFailed successorOccupied of
        Left err -> pure (Left err)
        Right TlsVersionEnvelopeMissing ->
          sealUnopenableSuccessor previous evidence successorVersion
        Right TlsVersionEnvelopeCorrupt ->
          pure (Left (TlsWorkflowRetentionVersionCorrupt successorVersion))
        Right (TlsVersionEnvelopePresent _ _) ->
          pure (Left (TlsWorkflowRetentionVersionOccupied successorVersion))
    _ -> pure (Left (TlsWorkflowRetentionVersionUnopenable version))

  -- The successor carries fresh certificate ciphertext because the retention
  -- version is part of the AEAD associated data: the occupant's bytes are not
  -- reusable at another version even when they open, and these do not open at
  -- all.  Nothing about the skipped object is read, asserted, or copied.
  sealUnopenableSuccessor previous evidence successorVersion = do
    homePreparedResult <-
      prepareTlsDekDestination (tlsWorkflowRetainedHomeAgent workflow)
    case first TlsWorkflowHomeAgentFailed homePreparedResult of
      Left err -> pure (Left err)
      Right homePrepared -> do
        retainedResult <-
          retainSelectedPublicEdgeTls
            (tlsWorkflowSelectedAgent workflow)
            successorVersion
            (tlsDekPreparedPublicKey homePrepared)
        case retainedResult of
          -- The live source was read moments ago to prove the occupant
          -- unopenable, so its disappearance now is a distinct fact from the
          -- ordinary nothing-to-retain answer and is named as one.
          Left (TlsTargetAgentClientHttpStatus 404 _) ->
            pure
              ( Left
                  (TlsWorkflowRetentionSuccessorSourceMissing successorVersion)
              )
          Left err -> pure (Left (TlsWorkflowSelectedAgentFailed err))
          Right retained -> do
            wrappedResult <-
              wrapRetainedHomeTlsDek
                (tlsWorkflowRetainedHomeAgent workflow)
                homePrepared
                (tlsTargetRetainedDekEnvelope retained)
            case first TlsWorkflowHomeAgentFailed wrappedResult of
              Left err -> pure (Left err)
              Right wrapped ->
                case mkTlsSealedEnvelope
                  (tlsTargetRetainedCertificateCiphertext retained)
                  (TextEncoding.encodeUtf8 (tlsWrappedDekText wrapped)) of
                  Left detail -> pure (Left (TlsWorkflowEnvelopeInvalid detail))
                  Right envelope ->
                    stageUnopenableSuccessorAndResume
                      previous
                      evidence
                      (referenceFor successorVersion retained envelope)
                      envelope

  stageUnopenableSuccessorAndResume previous evidence candidate envelope = do
    staged <-
      stageTlsRetentionAfterUnopenableVersion
        (tlsWorkflowAuthority workflow)
        approval
        evidence
        candidate
        envelope
    case first TlsWorkflowAuthorityFailed staged of
      Left err -> pure (Left err)
      Right outcome ->
        let expected =
              TlsRetentionPending
                { tlsPendingPrevious = Just previous
                , tlsPendingApproval = approval
                , tlsPendingCandidate = candidate
                , tlsPendingEnvelope = envelope
                }
         in case validateUnopenableSuccessorStaging evidence expected outcome of
              Left err -> pure (Left err)
              Right pending -> resumePending (stagingOutcomeState outcome) pending

  createFresh state version = do
    homePreparedResult <-
      prepareTlsDekDestination (tlsWorkflowRetainedHomeAgent workflow)
    case first TlsWorkflowHomeAgentFailed homePreparedResult of
      Left err -> pure (Left err)
      Right homePrepared -> do
        retainedResult <-
          retainSelectedPublicEdgeTls
            (tlsWorkflowSelectedAgent workflow)
            version
            (tlsDekPreparedPublicKey homePrepared)
        case retainedResult of
          Left (TlsTargetAgentClientHttpStatus 404 _) ->
            pure (Right TlsWorkflowNothingToRetain)
          Left err -> pure (Left (TlsWorkflowSelectedAgentFailed err))
          Right retained -> do
            wrappedResult <-
              wrapRetainedHomeTlsDek
                (tlsWorkflowRetainedHomeAgent workflow)
                homePrepared
                (tlsTargetRetainedDekEnvelope retained)
            case first TlsWorkflowHomeAgentFailed wrappedResult of
              Left err -> pure (Left err)
              Right wrapped ->
                case mkTlsSealedEnvelope
                  (tlsTargetRetainedCertificateCiphertext retained)
                  (TextEncoding.encodeUtf8 (tlsWrappedDekText wrapped)) of
                  Left detail -> pure (Left (TlsWorkflowEnvelopeInvalid detail))
                  Right envelope ->
                    stageAndResume
                      state
                      approval
                      (referenceFor version retained envelope)
                      envelope

  adoptLegacy state version envelope = do
    homePreparedResult <-
      prepareTlsDekDestination (tlsWorkflowRetainedHomeAgent workflow)
    case first TlsWorkflowHomeAgentFailed homePreparedResult of
      Left err -> pure (Left err)
      Right homePrepared -> do
        retainedResult <-
          retainSelectedPublicEdgeTls
            (tlsWorkflowSelectedAgent workflow)
            version
            (tlsDekPreparedPublicKey homePrepared)
        case retainedResult of
          Left (TlsTargetAgentClientHttpStatus 404 _) ->
            pure (Left TlsWorkflowLegacySourceMissing)
          Left err -> pure (Left (TlsWorkflowSelectedAgentFailed err))
          Right retained -> do
            let candidate = referenceFor version retained envelope
            applied <- applyTlsEnvelopeAtSelected workflow candidate envelope
            case applied of
              Left
                ( TlsWorkflowHomeAgentFailed
                    TlsTargetAgentClientHomeRewrapCiphertextAuthenticationFailed
                  ) ->
                  recoverUnopenableLegacy state version envelope
              Left err -> pure (Left err)
              Right receipt
                | tlsTargetRestoredReadBackSource receipt
                    == retainedSourceSecret candidate ->
                    stageAndResume state approval candidate envelope
                | otherwise ->
                    pure (Left TlsWorkflowLegacyAdoptionNotIdempotent)

  recoverUnopenableLegacy state version legacyEnvelope =
    case (state, version) of
      (TlsRetentionEmpty, RetentionVersion 1) -> do
        let recoveryEvidence =
              TlsLegacyRecoveryEvidence
                { tlsLegacyRecoveryVersion = version
                , tlsLegacyRecoveryEnvelopeDigest =
                    tlsSealedEnvelopeDigest legacyEnvelope
                }
            recoveryVersion = RetentionVersion 2
        homePreparedResult <-
          prepareTlsDekDestination (tlsWorkflowRetainedHomeAgent workflow)
        case first TlsWorkflowHomeAgentFailed homePreparedResult of
          Left err -> pure (Left err)
          Right homePrepared -> do
            retainedResult <-
              retainSelectedPublicEdgeTls
                (tlsWorkflowSelectedAgent workflow)
                recoveryVersion
                (tlsDekPreparedPublicKey homePrepared)
            case retainedResult of
              Left (TlsTargetAgentClientHttpStatus 404 _) ->
                pure (Left TlsWorkflowLegacySourceMissing)
              Left err -> pure (Left (TlsWorkflowSelectedAgentFailed err))
              Right retained -> do
                wrappedResult <-
                  wrapRetainedHomeTlsDek
                    (tlsWorkflowRetainedHomeAgent workflow)
                    homePrepared
                    (tlsTargetRetainedDekEnvelope retained)
                case first TlsWorkflowHomeAgentFailed wrappedResult of
                  Left err -> pure (Left err)
                  Right wrapped ->
                    case mkTlsSealedEnvelope
                      (tlsTargetRetainedCertificateCiphertext retained)
                      (TextEncoding.encodeUtf8 (tlsWrappedDekText wrapped)) of
                      Left detail -> pure (Left (TlsWorkflowEnvelopeInvalid detail))
                      Right envelope ->
                        stageLegacyRecoveryAndResume
                          approval
                          recoveryEvidence
                          Nothing
                          (referenceFor recoveryVersion retained envelope)
                          envelope
      _ -> pure (Left TlsWorkflowLegacyAdoptionNotIdempotent)

  referenceFor version retained envelope =
    RetainedTlsRef
      { retainedVersion = version
      , retainedCert = tlsTargetRetainedCertificate retained
      , retainedCiphertextDigest = tlsSealedEnvelopeDigest envelope
      , retainedSourceSecret = tlsTargetRetainedSource retained
      }

  stageAndResume state stagedApproval candidate envelope = do
    staged <-
      stageTlsRetentionCurrent
        (tlsWorkflowAuthority workflow)
        stagedApproval
        candidate
        envelope
    case first TlsWorkflowAuthorityFailed staged of
      Left err -> pure (Left err)
      Right outcome ->
        let expected =
              TlsRetentionPending
                { tlsPendingPrevious = currentRetainedRef state
                , tlsPendingApproval = stagedApproval
                , tlsPendingCandidate = candidate
                , tlsPendingEnvelope = envelope
                }
         in case validateStaging expected outcome of
              Left err -> pure (Left err)
              Right pending -> resumePending (stagingOutcomeState outcome) pending

  stageLegacyRecoveryAndResume stagedApproval evidence collision candidate envelope = do
    staged <-
      stageTlsRetentionAfterUnrecoverableLegacy
        (tlsWorkflowAuthority workflow)
        stagedApproval
        evidence
        collision
        candidate
        envelope
    case first TlsWorkflowAuthorityFailed staged of
      Left err -> pure (Left err)
      Right outcome ->
        let expected =
              TlsRetentionPending
                { tlsPendingPrevious = Nothing
                , tlsPendingApproval = stagedApproval
                , tlsPendingCandidate = candidate
                , tlsPendingEnvelope = envelope
                }
         in case validateLegacyRecoveryStaging evidence expected outcome of
              Left err -> pure (Left err)
              Right pending -> resumePending (stagingOutcomeState outcome) pending

  resumePending state pending = do
    stored <-
      storeTlsRetention
        (tlsWorkflowAdapter workflow)
        (tlsPendingCandidate pending)
        (tlsPendingEnvelope pending)
    case stored of
      Left clientError
        | isExactImmutableCollision clientError ->
            recoverImmutableCollision state pending clientError
        | otherwise -> pure (Left (TlsWorkflowAdapterFailed clientError))
      Right _ -> fmap (fmap (retainOutcomeFor state)) (confirmAndPromote pending)

  -- The skip is announced from the durable state rather than from the call
  -- that staged it, so a run that only resumes an already-staged successor
  -- reports it too.
  retainOutcomeFor state outcome = case (state, outcome) of
    ( TlsRetentionUnopenableSuccessorPendingState evidence _
      , TlsWorkflowRetained reference
      ) ->
        TlsWorkflowRetainedPastUnopenableVersion
          (tlsUnopenableVersion evidence)
          reference
    _ -> outcome

  recoverImmutableCollision state pending originalError = case state of
    TlsRetentionLegacyRecoveryPendingState evidence durablePending
      | durablePending == pending -> do
          let pendingCandidate = tlsPendingCandidate pending
              version = retainedVersion pendingCandidate
          observed <-
            observeTlsRetentionAuthorityVersion
              (tlsWorkflowAdapter workflow)
              version
          case first TlsWorkflowAdapterFailed observed of
            Left err -> pure (Left err)
            Right (TlsVersionEnvelopePresent occupiedEnvelope _) -> do
              let occupiedCandidate =
                    pendingCandidate
                      { retainedCiphertextDigest = tlsSealedEnvelopeDigest occupiedEnvelope
                      }
                  collision =
                    TlsLegacyRecoveryCollisionEvidence
                      { tlsLegacyRecoveryCollisionVersion = version
                      , tlsLegacyRecoveryPendingEnvelopeDigest =
                          retainedCiphertextDigest pendingCandidate
                      , tlsLegacyRecoveryObservedEnvelopeDigest =
                          retainedCiphertextDigest occupiedCandidate
                      }
              applied <- applyTlsEnvelopeAtSelected workflow occupiedCandidate occupiedEnvelope
              case applied of
                Left
                  ( TlsWorkflowHomeAgentFailed
                      TlsTargetAgentClientHomeRewrapCiphertextAuthenticationFailed
                    ) ->
                    recoverUnopenableCollision evidence collision pending
                Left err -> pure (Left err)
                Right receipt
                  | tlsTargetRestoredReadBackSource receipt
                      == retainedSourceSecret occupiedCandidate ->
                      stageLegacyRecoveryAndResume
                        (tlsPendingApproval pending)
                        evidence
                        (Just collision)
                        occupiedCandidate
                        occupiedEnvelope
                  | otherwise -> pure (Left TlsWorkflowSourceReadBackMismatch)
            Right _ -> pure (Left (TlsWorkflowAdapterFailed originalError))
    -- Every other durable state reaches here only because the store answered a
    -- put-if-absent with a conflict *and* the confirming read found different
    -- bytes at that exact object, so the version this pending is for is
    -- occupied by an envelope that is not the pending's.  Only the
    -- legacy-recovery state above can rebase onto it; the rest cannot, and used
    -- to say so by returning the adapter's own error, which names neither the
    -- version nor either digest.  The recovery is unchanged and the version is
    -- now named -- a resumed pending whose slot somebody else holds is a
    -- different fact from an adapter that is unavailable, and the live campaign
    -- could not tell them apart.
    --
    -- __Why this re-observes and then refuses rather than rebasing.__  An
    -- earlier draft sent the occupant to 'adoptOccupiedAuthorityVersion', whose
    -- success path stages through the /ordinary/ transition -- and that
    -- transition supersedes no pending: 'decideTlsStaging' answers
    -- 'TlsStagingNoop' only for a byte-identical pending and
    -- 'TlsStageConcurrentPending' otherwise, while the collision that brought us
    -- here proves the occupant is not the pending's envelope.  So the rebase was
    -- refused in every reachable case, after a live selected retain and a live
    -- restore had already run, and the refusal arrived as an Authority failure
    -- rendered @authority-state-unavailable@ -- an occupied immutable slot
    -- reported as an unavailable Authority, which is the misattribution this
    -- lane exists to remove.  Superseding a pending with an occupant-derived one
    -- needs an Authority-side transition that does not exist; until it does, the
    -- honest answer is the named refusal and no Target work at all.
    _ -> do
      let version = retainedVersion (tlsPendingCandidate pending)
      observed <-
        observeTlsRetentionAuthorityVersion
          (tlsWorkflowAdapter workflow)
          version
      case first TlsWorkflowAdapterFailed observed of
        Left err -> pure (Left err)
        -- The slot is held by an envelope that is not the pending's, which is
        -- exactly what this refusal names.
        Right (TlsVersionEnvelopePresent _ _) ->
          pure (Left (TlsWorkflowResumedRetentionVersionOccupied version))
        Right TlsVersionEnvelopeCorrupt ->
          pure (Left (TlsWorkflowRetentionVersionCorrupt version))
        -- The store said the slot was held and the re-read says it is missing.
        -- Two observations disagreeing is not a fact about the version, so the
        -- store's own error is reported rather than a claim about occupancy.
        Right TlsVersionEnvelopeMissing ->
          pure (Left (TlsWorkflowAdapterFailed originalError))

  recoverUnopenableCollision evidence collision displaced = do
    let successorVersion = RetentionVersion 3
        displacedApproval = tlsPendingApproval displaced
    homePreparedResult <-
      prepareTlsDekDestination (tlsWorkflowRetainedHomeAgent workflow)
    case first TlsWorkflowHomeAgentFailed homePreparedResult of
      Left err -> pure (Left err)
      Right homePrepared -> do
        retainedResult <-
          retainSelectedPublicEdgeTls
            (tlsWorkflowSelectedAgent workflow)
            successorVersion
            (tlsDekPreparedPublicKey homePrepared)
        case retainedResult of
          Left (TlsTargetAgentClientHttpStatus 404 _) ->
            pure (Left TlsWorkflowLegacySourceMissing)
          Left err -> pure (Left (TlsWorkflowSelectedAgentFailed err))
          Right retained -> do
            wrappedResult <-
              wrapRetainedHomeTlsDek
                (tlsWorkflowRetainedHomeAgent workflow)
                homePrepared
                (tlsTargetRetainedDekEnvelope retained)
            case first TlsWorkflowHomeAgentFailed wrappedResult of
              Left err -> pure (Left err)
              Right wrapped ->
                case mkTlsSealedEnvelope
                  (tlsTargetRetainedCertificateCiphertext retained)
                  (TextEncoding.encodeUtf8 (tlsWrappedDekText wrapped)) of
                  Left detail -> pure (Left (TlsWorkflowEnvelopeInvalid detail))
                  Right envelope ->
                    stageLegacyRecoverySuccessorAndResume
                      displacedApproval
                      evidence
                      collision
                      displaced
                      (referenceFor successorVersion retained envelope)
                      envelope

  stageLegacyRecoverySuccessorAndResume
    stagedApproval
    evidence
    collision
    displaced
    candidate
    envelope = do
      staged <-
        stageTlsRetentionAfterUnrecoverableLegacy
          (tlsWorkflowAuthority workflow)
          stagedApproval
          evidence
          (Just collision)
          candidate
          envelope
      case first TlsWorkflowAuthorityFailed staged of
        Left err -> pure (Left err)
        Right outcome ->
          let expectedPending =
                TlsRetentionPending
                  { tlsPendingPrevious = Nothing
                  , tlsPendingApproval = stagedApproval
                  , tlsPendingCandidate = candidate
                  , tlsPendingEnvelope = envelope
                  }
              expectedSuccessor =
                TlsLegacyRecoverySuccessorEvidence
                  { tlsLegacyRecoverySuccessorCollision = collision
                  , tlsLegacyRecoveryDisplacedApproval = tlsPendingApproval displaced
                  , tlsLegacyRecoveryDisplacedCandidate = tlsPendingCandidate displaced
                  }
           in case validateLegacyRecoverySuccessorStaging
                evidence
                expectedSuccessor
                expectedPending
                outcome of
                Left err -> pure (Left err)
                Right pending -> resumePending (stagingOutcomeState outcome) pending

  confirmAndPromote pending = do
    let candidate = tlsPendingCandidate pending
        envelope = tlsPendingEnvelope pending
    readBack <- restoreTlsRetention (tlsWorkflowAdapter workflow) candidate
    case first TlsWorkflowAdapterFailed readBack of
      Left err -> pure (Left err)
      Right (TlsEnvelopePresent readBackEnvelope receipt)
        | readBackEnvelope == envelope
            && tlsRetentionReceiptReference receipt == candidate -> do
            sourceReadBack <-
              verifySelectedPublicEdgeTlsSource
                (tlsWorkflowSelectedAgent workflow)
                candidate
            case first TlsWorkflowSelectedAgentFailed sourceReadBack of
              Left err -> pure (Left err)
              Right _ -> do
                promoted <-
                  promoteTlsRetentionCurrent
                    (tlsWorkflowAuthority workflow)
                    (tlsPendingApproval pending)
                    PromotionEvidence
                      { evidenceSourceReobserved = True
                      , evidenceAdapterReadBack = True
                      }
                    candidate
                pure $ do
                  outcome <- first TlsWorkflowAuthorityFailed promoted
                  validatePromotion candidate outcome
                  Right (TlsWorkflowRetained candidate)
        | otherwise -> pure (Left TlsWorkflowAdapterReadBackMismatch)
      Right _ -> pure (Left TlsWorkflowAdapterReadBackMismatch)

  stagingOutcomeState outcome = case outcome of
    TlsAuthorityStagingCommitted value -> value
    TlsAuthorityStagingAlreadyPending value -> value

  isExactImmutableCollision clientError = case clientError of
    TlsRetentionClientHttpStatus
      ( TlsRetentionEndpointResponse
          ( TlsRetentionStoreRepositoryFailed
              ( TlsStoreRepositoryConfirmationFailed
                  TlsStorePutConflict
                  TlsStoreConfirmationBytesMismatch
                )
            )
        ) -> True
    _ -> False

applyTlsEnvelopeAtSelected
  :: TlsRetentionWorkflow IO
  -> RetainedTlsRef
  -> TlsSealedEnvelope
  -> IO (Either TlsRetentionWorkflowError TlsTargetRestoreReceipt)
applyTlsEnvelopeAtSelected workflow reference envelope =
  case TextEncoding.decodeUtf8' (tlsWrappedDekBytes envelope) of
    Left _ -> pure (Left TlsWorkflowWrappedDekInvalid)
    Right wrappedText -> case mkTlsWrappedDek wrappedText of
      Left _ -> pure (Left TlsWorkflowWrappedDekInvalid)
      Right wrapped -> do
        selectedPreparedResult <-
          prepareTlsDekDestination (tlsWorkflowSelectedAgent workflow)
        case first TlsWorkflowSelectedAgentFailed selectedPreparedResult of
          Left err -> pure (Left err)
          Right selectedPrepared -> do
            rewrappedResult <-
              rewrapRetainedHomeTlsDek
                (tlsWorkflowRetainedHomeAgent workflow)
                wrapped
                (tlsDekPreparedPublicKey selectedPrepared)
            case first TlsWorkflowHomeAgentFailed rewrappedResult of
              Left err -> pure (Left err)
              Right rewrapped -> do
                applied <-
                  restoreSelectedPublicEdgeTls
                    (tlsWorkflowSelectedAgent workflow)
                    reference
                    selectedPrepared
                    rewrapped
                    (tlsCertificateCiphertextBytes envelope)
                pure (first TlsWorkflowSelectedAgentFailed applied)

restorePublicEdgeTlsWorkflow
  :: TlsRetentionWorkflow IO
  -> Natural
  -> IO (Either TlsRetentionWorkflowError TlsWorkflowRestoreOutcome)
restorePublicEdgeTlsWorkflow workflow trustedNow = do
  observed <- observeTlsRetentionCurrent (tlsWorkflowAuthority workflow)
  case first TlsWorkflowAuthorityFailed observed of
    Left err -> pure (Left err)
    Right state -> case currentRetainedRef state of
      Nothing -> case pendingTlsRetention state of
        Just _ -> pure (Left TlsWorkflowPendingWithoutCurrent)
        Nothing -> pure (Right TlsWorkflowIssuancePermitted)
      Just reference
        | certNotAfter (retainedCert reference) <= trustedNow ->
            pure (restoreDecisionOutcome (decideTlsRestore state RestoreTrustedTimeExpired))
        | otherwise -> do
            restored <- restoreTlsRetention (tlsWorkflowAdapter workflow) reference
            case first TlsWorkflowAdapterFailed restored of
              Left err -> pure (Left err)
              Right TlsEnvelopeMissing ->
                pure (restoreDecisionOutcome (decideTlsRestore state RestoreCommittedAbsent))
              Right (TlsEnvelopeCorrupt _) ->
                pure (restoreDecisionOutcome (decideTlsRestore state RestoreCommittedCorrupt))
              Right (TlsEnvelopePresent envelope receipt)
                | tlsRetentionReceiptReference receipt /= reference ->
                    pure (Left TlsWorkflowAdapterReadBackMismatch)
                | otherwise ->
                    case decideTlsRestore state (RestoreCommittedIntact reference) of
                      TlsRestoreApply committed -> applyRestored committed envelope
                      decision -> pure (restoreDecisionOutcome decision)
 where
  applyRestored reference envelope = do
    applied <- applyTlsEnvelopeAtSelected workflow reference envelope
    pure (TlsWorkflowRestored reference <$ applied)

validateStaging
  :: TlsRetentionPending
  -> TlsAuthorityStagingOutcome
  -> Either TlsRetentionWorkflowError TlsRetentionPending
validateStaging expected outcome =
  let state = case outcome of
        TlsAuthorityStagingCommitted value -> value
        TlsAuthorityStagingAlreadyPending value -> value
   in case pendingTlsRetention state of
        Just pending
          | pending == expected -> Right pending
        _ -> Left TlsWorkflowStagingStateMismatch

validateLegacyRecoveryStaging
  :: TlsLegacyRecoveryEvidence
  -> TlsRetentionPending
  -> TlsAuthorityStagingOutcome
  -> Either TlsRetentionWorkflowError TlsRetentionPending
validateLegacyRecoveryStaging expectedEvidence expectedPending outcome =
  let state = case outcome of
        TlsAuthorityStagingCommitted value -> value
        TlsAuthorityStagingAlreadyPending value -> value
   in case state of
        TlsRetentionLegacyRecoveryPendingState evidence pending
          | evidence == expectedEvidence && pending == expectedPending -> Right pending
        TlsRetentionLegacyRecoveryCollisionPendingState evidence _ pending
          | evidence == expectedEvidence && pending == expectedPending -> Right pending
        _ -> Left TlsWorkflowStagingStateMismatch

validateLegacyRecoverySuccessorStaging
  :: TlsLegacyRecoveryEvidence
  -> TlsLegacyRecoverySuccessorEvidence
  -> TlsRetentionPending
  -> TlsAuthorityStagingOutcome
  -> Either TlsRetentionWorkflowError TlsRetentionPending
validateLegacyRecoverySuccessorStaging expectedEvidence expectedSuccessor expectedPending outcome =
  let state = case outcome of
        TlsAuthorityStagingCommitted value -> value
        TlsAuthorityStagingAlreadyPending value -> value
   in case state of
        TlsRetentionLegacyRecoverySuccessorPendingState evidence successor pending
          | evidence == expectedEvidence
              && successor == expectedSuccessor
              && pending == expectedPending ->
              Right pending
        _ -> Left TlsWorkflowStagingStateMismatch

-- | The Authority may only answer with the one durable state this transition
-- produces, carrying exactly the evidence and the /complete/ pending the host
-- derived.  The whole record is compared, as every sibling validator does:
-- accepting a pending that matched only on candidate and envelope would let a
-- returned approval or predecessor the host never sent reach
-- 'confirmAndPromote', which promotes with the pending's own approval.
validateUnopenableSuccessorStaging
  :: TlsUnopenableVersionEvidence
  -> TlsRetentionPending
  -> TlsAuthorityStagingOutcome
  -> Either TlsRetentionWorkflowError TlsRetentionPending
validateUnopenableSuccessorStaging expectedEvidence expectedPending outcome =
  let state = case outcome of
        TlsAuthorityStagingCommitted value -> value
        TlsAuthorityStagingAlreadyPending value -> value
   in case state of
        TlsRetentionUnopenableSuccessorPendingState evidence pending
          | evidence == expectedEvidence && pending == expectedPending ->
              Right pending
        _ -> Left TlsWorkflowStagingStateMismatch

validatePromotion
  :: RetainedTlsRef
  -> TlsAuthorityPromotionOutcome
  -> Either TlsRetentionWorkflowError ()
validatePromotion candidate outcome =
  let state = case outcome of
        TlsAuthorityPromotionCommitted value -> value
        TlsAuthorityPromotionAlreadyCurrent value -> value
   in if currentRetainedRef state == Just candidate
        then Right ()
        else Left TlsWorkflowPromotionStateMismatch

restoreDecisionOutcome
  :: TlsRestoreDecision
  -> Either TlsRetentionWorkflowError TlsWorkflowRestoreOutcome
restoreDecisionOutcome decision = case decision of
  TlsRestoreIssue -> Right TlsWorkflowIssuancePermitted
  TlsRestoreApply reference -> Right (TlsWorkflowRestored reference)
  TlsRestoreRefused refusal -> Left (TlsWorkflowRestoreRefused refusal)
