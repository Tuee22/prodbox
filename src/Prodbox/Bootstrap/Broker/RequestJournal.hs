{-# LANGUAGE DerivingStrategies #-}

-- | Pure durable-idempotency algebra for mutating Bootstrap Broker requests.
--
-- The server's bounded in-memory admission lane may coalesce callers, but it
-- cannot establish replay safety across eviction or process loss.  This module
-- defines the immutable request binding and the only legal durable phase
-- transition: an exact armed request may become one exact terminal response.
module Prodbox.Bootstrap.Broker.RequestJournal
  ( -- * Immutable request identity
    BrokerRequestBinding
  , mkBrokerRequestBinding
  , brokerRequestBindingIdempotencyKey
  , brokerRequestBindingRequestDigest
  , brokerRequestBindingRoute
  , brokerRequestBindingActionDigest
  , brokerRequestBindingStorageGeneration

    -- * Closed effect targets and recovery decisions
  , BrokerEffectTarget
  , BrokerEffectTargetError (..)
  , durableDriverEffectTarget
  , mkUnlockBundleEffectTarget
  , mkTransitKeyEffectTarget
  , mkPkiIssueEffectTarget
  , BrokerEffectResult (..)
  , BrokerEffectTargetObservation (..)
  , BrokerEffectRecoveryDecision (..)
  , BrokerEffectTargetRefusal (..)
  , decideBrokerEffectRecovery

    -- * Bounded terminal wire response
  , BrokerTerminalStatus (..)
  , TerminalBrokerResponse
  , TerminalBrokerResponseError (..)
  , maximumTerminalBrokerResponseBytes
  , mkTerminalBrokerResponse
  , terminalBrokerResponseStatus
  , terminalBrokerResponseRoute
  , terminalBrokerResponseDigest
  , terminalBrokerResponseBytes

    -- * Durable journal transition
  , BrokerRequestJournal
  , BrokerRequestJournalPhase (..)
  , BrokerRequestResume (..)
  , BrokerRequestJournalRefusal (..)
  , newArmedBrokerRequestJournal
  , brokerRequestJournalBinding
  , brokerRequestJournalPhase
  , resumeBrokerRequestJournal
  , recordTerminalBrokerResponse
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Request
  ( IdempotencyKey
  , RequestDigest
  , requestDigestForBytes
  )
import Prodbox.Bootstrap.Broker.Routes (BrokerRoute)
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , StoreVersion (..)
  , VaultStorageGeneration
  )

-- | Identity that may never change while an idempotency key is retained.
-- Request bytes, route selection, semantic action, and Vault storage epoch are
-- all explicit even when one happens to imply another in the current codec.
data BrokerRequestBinding = BrokerRequestBinding
  { brokerRequestBindingIdempotencyKey :: !IdempotencyKey
  , brokerRequestBindingRequestDigest :: !RequestDigest
  , brokerRequestBindingRoute :: !BrokerRoute
  , brokerRequestBindingActionDigest :: !ArtifactDigest
  , brokerRequestBindingStorageGeneration :: !VaultStorageGeneration
  }
  deriving stock (Eq, Show)

mkBrokerRequestBinding
  :: IdempotencyKey
  -> RequestDigest
  -> BrokerRoute
  -> ArtifactDigest
  -> VaultStorageGeneration
  -> BrokerRequestBinding
mkBrokerRequestBinding = BrokerRequestBinding

-- | Operation-specific target committed before the external effect.  The
-- constructors stay private so version-transition invariants cannot be
-- bypassed by a physical adapter.
data BrokerEffectTarget
  = DurableDriverEffectTarget !ArtifactDigest
  | UnlockBundleEffectTarget
      !StoreVersion
      !ArtifactDigest
      !StoreVersion
      !ArtifactDigest
  | TransitKeyEffectTarget
      !ArtifactDigest
      !Natural
      !Natural
  | PkiIssueEffectTarget
      !Natural
      !ArtifactDigest
      !ArtifactDigest
  deriving stock (Eq, Show)

data BrokerEffectTargetError
  = BrokerEffectSourceVersionMustBePositive
  | BrokerEffectTargetVersionMustAdvanceExactlyOne
  | BrokerPkiIssuerGenerationMustBePositive
  deriving stock (Eq, Show)

-- | Internally journaled broker programs bind their recovery to the action
-- digest.  Their own closed state machines retain the finer-grained target.
durableDriverEffectTarget :: ArtifactDigest -> BrokerEffectTarget
durableDriverEffectTarget = DurableDriverEffectTarget

mkUnlockBundleEffectTarget
  :: StoreVersion
  -> ArtifactDigest
  -> StoreVersion
  -> ArtifactDigest
  -> Either BrokerEffectTargetError BrokerEffectTarget
mkUnlockBundleEffectTarget sourceVersion sourceDigest targetVersion targetDigest = do
  requireStoreVersionTransition sourceVersion targetVersion
  Right
    ( UnlockBundleEffectTarget
        sourceVersion
        sourceDigest
        targetVersion
        targetDigest
    )

mkTransitKeyEffectTarget
  :: ArtifactDigest
  -> Natural
  -> Natural
  -> Either BrokerEffectTargetError BrokerEffectTarget
mkTransitKeyEffectTarget keyIdentity sourceVersion targetVersion = do
  requireVersionTransition sourceVersion targetVersion
  Right (TransitKeyEffectTarget keyIdentity sourceVersion targetVersion)

mkPkiIssueEffectTarget
  :: Natural
  -> ArtifactDigest
  -> ArtifactDigest
  -> Either BrokerEffectTargetError BrokerEffectTarget
mkPkiIssueEffectTarget issuerGeneration csrDigest subjectPublicKeyDigest
  | issuerGeneration == 0 = Left BrokerPkiIssuerGenerationMustBePositive
  | otherwise =
      Right
        ( PkiIssueEffectTarget
            issuerGeneration
            csrDigest
            subjectPublicKeyDigest
        )

requireVersionTransition
  :: Natural -> Natural -> Either BrokerEffectTargetError ()
requireVersionTransition sourceVersion targetVersion
  | sourceVersion == 0 = Left BrokerEffectSourceVersionMustBePositive
  | targetVersion == sourceVersion + 1 = Right ()
  | otherwise = Left BrokerEffectTargetVersionMustAdvanceExactlyOne

requireStoreVersionTransition
  :: StoreVersion -> StoreVersion -> Either BrokerEffectTargetError ()
requireStoreVersionTransition (StoreVersion sourceVersion) (StoreVersion targetVersion)
  | sourceVersion == 0 = Left BrokerEffectSourceVersionMustBePositive
  | targetVersion == sourceVersion + 1 = Right ()
  | otherwise = Left BrokerEffectTargetVersionMustAdvanceExactlyOne

-- | Secret-free identity recovered by observing the exact external target.
-- Certificate material is represented only by public digests; no private key
-- or plaintext bootstrap secret can enter this result family.
data BrokerEffectResult
  = DurableDriverEffectResult !ArtifactDigest
  | UnlockBundleEffectResult !StoreVersion !ArtifactDigest
  | TransitKeyEffectResult !ArtifactDigest !Natural
  | PkiIssueEffectResult
      !Natural
      !ArtifactDigest
      !ArtifactDigest
      !ArtifactDigest
      !ArtifactDigest
  deriving stock (Eq, Show)

data BrokerEffectTargetObservation
  = BrokerEffectSourceStillCurrent
  | BrokerEffectTargetReached !BrokerEffectResult
  | BrokerEffectTargetDiverged
  | BrokerEffectTargetUnobservable
  deriving stock (Eq, Show)

data BrokerEffectRecoveryDecision
  = ExecuteArmedBrokerEffect
  | RecoverObservedBrokerEffect !BrokerEffectResult
  deriving stock (Eq, Show)

data BrokerEffectTargetRefusal
  = BrokerEffectObservedResultMismatch
  | BrokerEffectObservedTargetDiverged
  | BrokerEffectObservationUnavailable
  deriving stock (Eq, Show)

-- | Decide recovery without converting unknown or divergent target state into
-- permission to repeat a non-idempotent effect.
decideBrokerEffectRecovery
  :: BrokerEffectTarget
  -> BrokerEffectTargetObservation
  -> Either BrokerEffectTargetRefusal BrokerEffectRecoveryDecision
decideBrokerEffectRecovery target observation = case observation of
  BrokerEffectSourceStillCurrent -> Right ExecuteArmedBrokerEffect
  BrokerEffectTargetReached result
    | resultMatchesTarget target result ->
        Right (RecoverObservedBrokerEffect result)
    | otherwise -> Left BrokerEffectObservedResultMismatch
  BrokerEffectTargetDiverged -> Left BrokerEffectObservedTargetDiverged
  BrokerEffectTargetUnobservable -> Left BrokerEffectObservationUnavailable

resultMatchesTarget :: BrokerEffectTarget -> BrokerEffectResult -> Bool
resultMatchesTarget target result = case (target, result) of
  (DurableDriverEffectTarget expected, DurableDriverEffectResult observed) ->
    observed == expected
  ( UnlockBundleEffectTarget _ _ targetVersion targetDigest
    , UnlockBundleEffectResult observedVersion observedDigest
    ) ->
      observedVersion == targetVersion && observedDigest == targetDigest
  ( TransitKeyEffectTarget expectedKey _ targetVersion
    , TransitKeyEffectResult observedKey observedVersion
    ) ->
      observedKey == expectedKey && observedVersion == targetVersion
  ( PkiIssueEffectTarget expectedIssuer expectedCsr expectedSpki
    , PkiIssueEffectResult
        observedIssuer
        observedCsr
        _certificateSerialDigest
        _certificateDigest
        observedSpki
    ) ->
      observedIssuer == expectedIssuer
        && observedCsr == expectedCsr
        && observedSpki == expectedSpki
  _ -> False

-- | Closed post-prepare terminal status retained with the exact response
-- bytes.  Retryable and pre-prepare replies have no constructor here, so a
-- timeout, overload, unavailable boundary, or internal failure cannot become
-- a durable replay result.  This deliberately lives below the HTTP server so
-- durable replay does not depend on process-local reply values.
data BrokerTerminalStatus
  = BrokerTerminalOk
  | BrokerTerminalAccepted
  | BrokerTerminalConflict
  deriving stock (Bounded, Enum, Eq, Ord, Show)

maximumTerminalBrokerResponseBytes :: Natural
maximumTerminalBrokerResponseBytes = 64 * 1024

data TerminalBrokerResponse = TerminalBrokerResponse
  { terminalBrokerResponseStatus :: !BrokerTerminalStatus
  , terminalBrokerResponseRoute :: !BrokerRoute
  , terminalBrokerResponseDigest :: !RequestDigest
  , terminalBrokerResponseBytes :: !ByteString
  }
  deriving stock (Eq)

instance Show TerminalBrokerResponse where
  show response =
    "TerminalBrokerResponse {status = "
      ++ show (terminalBrokerResponseStatus response)
      ++ ", route = "
      ++ show (terminalBrokerResponseRoute response)
      ++ ", body = <redacted:"
      ++ show (ByteString.length (terminalBrokerResponseBytes response))
      ++ " bytes>}"

data TerminalBrokerResponseError
  = TerminalBrokerResponseTooLarge !Natural !Natural
  deriving stock (Eq, Show)

mkTerminalBrokerResponse
  :: BrokerTerminalStatus
  -> BrokerRoute
  -> ByteString
  -> Either TerminalBrokerResponseError TerminalBrokerResponse
mkTerminalBrokerResponse status route responseBytes
  | responseLength > maximumTerminalBrokerResponseBytes =
      Left
        ( TerminalBrokerResponseTooLarge
            maximumTerminalBrokerResponseBytes
            responseLength
        )
  | otherwise =
      Right
        TerminalBrokerResponse
          { terminalBrokerResponseStatus = status
          , terminalBrokerResponseRoute = route
          , terminalBrokerResponseDigest = requestDigestForBytes responseBytes
          , terminalBrokerResponseBytes = responseBytes
          }
 where
  responseLength = fromIntegral (ByteString.length responseBytes)

data BrokerRequestJournalPhase
  = BrokerRequestArmed !BrokerEffectTarget
  | BrokerRequestTerminal !TerminalBrokerResponse
  deriving stock (Eq, Show)

data BrokerRequestJournal = BrokerRequestJournal
  { brokerRequestJournalBinding :: !BrokerRequestBinding
  , brokerRequestJournalPhase :: !BrokerRequestJournalPhase
  }
  deriving stock (Eq, Show)

data BrokerRequestResume
  = ResumeArmedBrokerRequest !BrokerEffectTarget
  | ReplayTerminalBrokerResponse !TerminalBrokerResponse
  deriving stock (Eq, Show)

data BrokerRequestJournalRefusal
  = BrokerRequestIdempotencyKeyConflict
  | BrokerRequestDigestConflict
  | BrokerRequestRouteConflict
  | BrokerRequestActionDigestConflict
  | BrokerRequestStorageGenerationConflict
  | BrokerRequestTerminalRouteMismatch
  | BrokerRequestTerminalRewriteRefused
  deriving stock (Eq, Show)

newArmedBrokerRequestJournal
  :: BrokerRequestBinding -> BrokerEffectTarget -> BrokerRequestJournal
newArmedBrokerRequestJournal binding target =
  BrokerRequestJournal
    { brokerRequestJournalBinding = binding
    , brokerRequestJournalPhase = BrokerRequestArmed target
    }

resumeBrokerRequestJournal
  :: BrokerRequestBinding
  -> BrokerRequestJournal
  -> Either BrokerRequestJournalRefusal BrokerRequestResume
resumeBrokerRequestJournal expected journal = do
  requireExactBinding expected (brokerRequestJournalBinding journal)
  Right $ case brokerRequestJournalPhase journal of
    BrokerRequestArmed target -> ResumeArmedBrokerRequest target
    BrokerRequestTerminal response -> ReplayTerminalBrokerResponse response

recordTerminalBrokerResponse
  :: BrokerRequestBinding
  -> TerminalBrokerResponse
  -> BrokerRequestJournal
  -> Either BrokerRequestJournalRefusal BrokerRequestJournal
recordTerminalBrokerResponse expected response journal = do
  requireExactBinding expected (brokerRequestJournalBinding journal)
  if terminalBrokerResponseRoute response == brokerRequestBindingRoute expected
    then Right ()
    else Left BrokerRequestTerminalRouteMismatch
  case brokerRequestJournalPhase journal of
    BrokerRequestArmed _ ->
      Right journal {brokerRequestJournalPhase = BrokerRequestTerminal response}
    BrokerRequestTerminal _ -> Left BrokerRequestTerminalRewriteRefused

requireExactBinding
  :: BrokerRequestBinding
  -> BrokerRequestBinding
  -> Either BrokerRequestJournalRefusal ()
requireExactBinding expected observed
  | brokerRequestBindingIdempotencyKey observed
      /= brokerRequestBindingIdempotencyKey expected =
      Left BrokerRequestIdempotencyKeyConflict
  | brokerRequestBindingRequestDigest observed
      /= brokerRequestBindingRequestDigest expected =
      Left BrokerRequestDigestConflict
  | brokerRequestBindingRoute observed /= brokerRequestBindingRoute expected =
      Left BrokerRequestRouteConflict
  | brokerRequestBindingActionDigest observed
      /= brokerRequestBindingActionDigest expected =
      Left BrokerRequestActionDigestConflict
  | brokerRequestBindingStorageGeneration observed
      /= brokerRequestBindingStorageGeneration expected =
      Left BrokerRequestStorageGenerationConflict
  | otherwise = Right ()
