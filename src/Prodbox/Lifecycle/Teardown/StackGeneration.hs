{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The stable lifecycle identity of one created registered stack.
--
-- The measured defect this module closes: every existing creation and
-- ownership-manifest slot is keyed by the cleanup surface and durable run scope
-- that produced it, so a /later/ cleanup run — a different run scope, often a
-- different surface — has no key with which to select the stack an earlier run
-- created.  Selection then falls back to whatever residue happens to be
-- visible, which is exactly the composition the 2026-08-15 counterexample
-- exercised.
--
-- The correction splits one identity into two parts that were previously fused:
--
--   * 'StackGenerationKey' is run-invariant.  It names the registered key, its
--     exact static coordinate digest, the registry revision, the sole local
--     lifecycle foundation, the AWS account/region, and an ordinal that
--     distinguishes successive create/destroy cycles of the same key.  Nothing
--     about /who was running/ appears in it.
--
--   * 'RegisteredStackGeneration' adds causal provenance — the admitted create
--     operation, the exact Provider credential session that observed the AWS
--     scope, and the run scope and surface that created it.  Provenance is
--     recorded, never used as a selection key.
--
-- A generation's AWS scope is taken only from an opaque
-- 'VerifiedProviderAwsScope'.  There is no parameter by which a caller can
-- assert an account or region, so a generation cannot be established for a
-- scope the Provider Worker did not itself observe under an admitted operation.
--
-- Everything here is pure and effect-free.
module Prodbox.Lifecycle.Teardown.StackGeneration
  ( -- * The proven Provider credential session
    ProvenProviderAwsSession
  , provenProviderAwsSessionAccountId
  , provenProviderAwsSessionRegion
  , provenProviderAwsSessionRevision
  , provenProviderAwsSessionOperationText
  , providerAwsSessionFromLocalProof
  , providerAwsSessionFromAuthorityProof

    -- * Generation ordinal
  , StackGenerationOrdinal
  , mkStackGenerationOrdinal
  , stackGenerationOrdinalValue
  , initialStackGenerationOrdinal
  , succeedingStackGenerationOrdinal

    -- * The run-invariant series of one registered stack
  , StackGenerationSeriesKey
  , stackGenerationSeriesKeyResource
  , stackGenerationSeriesKeyCoordinateDigest
  , stackGenerationSeriesKeyRegistryRevision
  , stackGenerationSeriesKeyFoundation
  , stackGenerationSeriesKeyAwsScope
  , stackGenerationSeriesKeyText
  , stackGenerationSeriesKeyFromProviderScope
  , stackGenerationSeriesKeyOf
  , stackGenerationKeyForOrdinal
  , stackGenerationSeriesSlotDigest
  , stackGenerationSeriesSlotLogicalName

    -- * The run-invariant selection key
  , StackGenerationKey
  , stackGenerationKeyResource
  , stackGenerationKeyCoordinateDigest
  , stackGenerationKeyRegistryRevision
  , stackGenerationKeyFoundation
  , stackGenerationKeyAwsScope
  , stackGenerationKeyOrdinal
  , stackGenerationKeyText
  , StackGenerationSlotDigest
  , stackGenerationSlotDigestText
  , stackGenerationSlotDigest
  , stackGenerationSlotLogicalName
  , stackGenerationKeyFromProviderScope

    -- * The established generation
  , RegisteredStackGeneration
  , registeredStackGenerationKey
  , registeredStackGenerationAdmittedOperationId
  , registeredStackGenerationProviderOperationId
  , registeredStackGenerationProviderRevision
  , registeredStackGenerationCreatingRunScope
  , registeredStackGenerationCreatingSurface
  , establishRegisteredStackGeneration

    -- * Selection from a later cleanup run
  , StackGenerationSelector (..)
  , SelectedStackGeneration
  , selectedStackGeneration
  , selectedStackGenerationSelectingRunScope
  , selectedStackGenerationSelectingSurface
  , selectRegisteredStackGeneration
  , stackGenerationSelectorForKey

    -- * The durable record
  , maximumRegisteredStackGenerationRecordBytes
  , encodeRegisteredStackGeneration
  , decodeRegisteredStackGeneration

    -- * Ordinal succession
  , StackGenerationCursor
  , stackGenerationCursorSeries
  , stackGenerationCursorOrdinal
  , stackGenerationCursorAdmittedOperationId
  , stackGenerationCursorGenerationKey
  , openStackGenerationCursor
  , advanceStackGenerationCursor
  , maximumStackGenerationCursorRecordBytes
  , encodeStackGenerationCursor
  , decodeStackGenerationCursor

    -- * Refusals
  , StackGenerationError (..)
  , renderStackGenerationError
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAscii, isControl, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word64)
import GHC.Generics (Generic)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AwsStackCreationBindingRepository
  ( ObservedAwsStackCreationOperation
  , observedAwsStackCreationCoordinateDigest
  , observedAwsStackCreationKey
  , observedAwsStackCreationOperationId
  )
import Prodbox.ControlPlane.ProviderAwsScopeReceipt
  ( VerifiedAuthorityProviderAwsScope
  , verifiedAuthorityProviderAwsScopeAccountId
  , verifiedAuthorityProviderAwsScopeOperationText
  , verifiedAuthorityProviderAwsScopeRegion
  , verifiedAuthorityProviderAwsScopeRevision
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( authorityEpochFromValue
  , authorityEpochValue
  )
import Prodbox.Lifecycle.Authority.Submission
  ( ClientId (..)
  , ClientSequence (..)
  , OperationId (..)
  , RequestDigest (..)
  , requestDigestText
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderRevision
  , mkProviderRevision
  , providerRevisionNatural
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurface
  , DurableObservationRunScope (..)
  , LinuxRke2FoundationId (..)
  , ManagedResourceCoordinateDigest
  , RegisteredResourceKey
  , RegistryRevision (..)
  , ResourceKind (..)
  , managedResourceCoordinateDigestText
  , registeredResourceKeyText
  )
import Prodbox.Lifecycle.Teardown.ProviderAwsScopeAdapter
  ( VerifiedProviderAwsScope
  , verifiedProviderAwsScopeAccountId
  , verifiedProviderAwsScopeOperationId
  , verifiedProviderAwsScopeRegion
  , verifiedProviderAwsScopeRevision
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( cleanupSurfaceAllows
  , lifecycleRegistryRevision
  , lookupRegisteredIdentity
  , registeredIdentityCoordinateDigest
  , registeredIdentityKind
  )

-- ---------------------------------------------------------------------------
-- Generation ordinal
-- ---------------------------------------------------------------------------

-- | Distinguishes successive create/destroy cycles of the same registered
-- stack.  Opaque so an ordinal cannot be fabricated from an unrelated counter;
-- the only ways in are the explicit smart constructor, the documented initial
-- value, and succession from an existing ordinal.
newtype StackGenerationOrdinal = StackGenerationOrdinal Word64
  deriving (Eq, Ord, Show)

stackGenerationOrdinalValue :: StackGenerationOrdinal -> Word64
stackGenerationOrdinalValue (StackGenerationOrdinal value) = value

-- | Zero is reserved: an ordinal of zero would make \"never created\" and
-- \"created once\" the same key.
mkStackGenerationOrdinal
  :: Word64 -> Either StackGenerationError StackGenerationOrdinal
mkStackGenerationOrdinal value
  | value == 0 = Left StackGenerationOrdinalZero
  | otherwise = Right (StackGenerationOrdinal value)

initialStackGenerationOrdinal :: StackGenerationOrdinal
initialStackGenerationOrdinal = StackGenerationOrdinal 1

-- | The next cycle's ordinal.  Exhausting a 64-bit ordinal refuses rather than
-- wrapping onto a key that a durable record already used.
succeedingStackGenerationOrdinal
  :: StackGenerationOrdinal -> Either StackGenerationError StackGenerationOrdinal
succeedingStackGenerationOrdinal (StackGenerationOrdinal value)
  | value == maxBound = Left StackGenerationOrdinalExhausted
  | otherwise = Right (StackGenerationOrdinal (value + 1))

-- ---------------------------------------------------------------------------
-- The proven Provider credential session
-- ---------------------------------------------------------------------------

-- | The exact credential-session facts a generation may be minted from.
--
-- Both supported proofs collapse to this shape and nothing else does: the
-- constructor is private and the only two ways to obtain a value are
-- 'providerAwsSessionFromLocalProof', which needs the Provider Worker's own
-- decoded execution proof, and 'providerAwsSessionFromAuthorityProof', which
-- needs a receipt the Lifecycle Authority independently read back from its own
-- admitted-operation aggregate.  A caller therefore still cannot assert an
-- account or region; it can only present a proof that one was observed.
--
-- Production mints generations from the Authority proof, because the Authority
-- is where the create is admitted and where the durable slot lives.  The local
-- proof remains admissible so the Provider-side derivation stays exercisable
-- without an Authority aggregate.
data ProvenProviderAwsSession = ProvenProviderAwsSession
  { internalProvenSessionAccountId :: !AwsAccountId
  , internalProvenSessionRegion :: !AwsRegion
  , internalProvenSessionRevision :: !ProviderRevision
  , internalProvenSessionOperationText :: !Text
  }
  deriving (Eq, Show)

provenProviderAwsSessionAccountId :: ProvenProviderAwsSession -> AwsAccountId
provenProviderAwsSessionAccountId = internalProvenSessionAccountId

provenProviderAwsSessionRegion :: ProvenProviderAwsSession -> AwsRegion
provenProviderAwsSessionRegion = internalProvenSessionRegion

provenProviderAwsSessionRevision :: ProvenProviderAwsSession -> ProviderRevision
provenProviderAwsSessionRevision = internalProvenSessionRevision

provenProviderAwsSessionOperationText :: ProvenProviderAwsSession -> Text
provenProviderAwsSessionOperationText = internalProvenSessionOperationText

providerAwsSessionFromLocalProof
  :: VerifiedProviderAwsScope -> ProvenProviderAwsSession
providerAwsSessionFromLocalProof proof =
  ProvenProviderAwsSession
    { internalProvenSessionAccountId = verifiedProviderAwsScopeAccountId proof
    , internalProvenSessionRegion = verifiedProviderAwsScopeRegion proof
    , internalProvenSessionRevision = verifiedProviderAwsScopeRevision proof
    , internalProvenSessionOperationText =
        verifiedProviderAwsScopeOperationId proof
    }

-- | The Authority-read-back proof renders its operation identity exactly as
-- the retained receipt does, which is the same text the local proof carried, so
-- a generation minted from either proof of the same observation is byte-equal.
providerAwsSessionFromAuthorityProof
  :: VerifiedAuthorityProviderAwsScope -> ProvenProviderAwsSession
providerAwsSessionFromAuthorityProof proof =
  ProvenProviderAwsSession
    { internalProvenSessionAccountId =
        verifiedAuthorityProviderAwsScopeAccountId proof
    , internalProvenSessionRegion =
        verifiedAuthorityProviderAwsScopeRegion proof
    , internalProvenSessionRevision =
        verifiedAuthorityProviderAwsScopeRevision proof
    , internalProvenSessionOperationText =
        verifiedAuthorityProviderAwsScopeOperationText proof
    }

-- ---------------------------------------------------------------------------
-- The run-invariant series of one registered stack
-- ---------------------------------------------------------------------------

-- | Everything a generation key names except which create/destroy cycle it is.
-- One registered stack in one account, region, and foundation has exactly one
-- series; its successive cycles are the ordinals within that series.
data StackGenerationSeriesKey = StackGenerationSeriesKey
  { stackGenerationSeriesKeyResource :: !RegisteredResourceKey
  , stackGenerationSeriesKeyCoordinateDigest :: !ManagedResourceCoordinateDigest
  , stackGenerationSeriesKeyRegistryRevision :: !RegistryRevision
  , stackGenerationSeriesKeyFoundation :: !LinuxRke2FoundationId
  , stackGenerationSeriesKeyAwsScope :: !AwsScope
  }
  deriving (Eq, Ord, Show)

-- | Canonical, constructor-tagged rendering.  Fields are NUL-separated so no
-- field's content can imitate a separator and shift the key's meaning.
stackGenerationSeriesKeyText :: StackGenerationSeriesKey -> Text
stackGenerationSeriesKeyText series =
  Text.intercalate
    "\NUL"
    [ "registered-stack-generation/v1"
    , registeredResourceKeyText (stackGenerationSeriesKeyResource series)
    , managedResourceCoordinateDigestText
        (stackGenerationSeriesKeyCoordinateDigest series)
    , registryRevisionText (stackGenerationSeriesKeyRegistryRevision series)
    , foundationText (stackGenerationSeriesKeyFoundation series)
    , accountText (awsScopeAccountId (stackGenerationSeriesKeyAwsScope series))
    , regionText (awsScopeRegion (stackGenerationSeriesKeyAwsScope series))
    ]

-- | The durable slot address of one series' cursor.  Distinct from every
-- generation slot, so the pointer that says which cycle is current can never be
-- mistaken for a cycle's own record.
stackGenerationSeriesSlotDigest
  :: StackGenerationSeriesKey -> StackGenerationSlotDigest
stackGenerationSeriesSlotDigest =
  hexDigestOf . stackGenerationSeriesKeyText

stackGenerationSeriesSlotLogicalName :: StackGenerationSeriesKey -> Text
stackGenerationSeriesSlotLogicalName series =
  "authority/registered-stack-generation-series/"
    <> stackGenerationSlotDigestText (stackGenerationSeriesSlotDigest series)

-- | Derive the series from the compiled registry and one exact Provider
-- credential session.  Same derivation, same refusals, and same
-- caller-cannot-assert property as a generation key; it simply has no ordinal
-- yet.
stackGenerationSeriesKeyFromProviderScope
  :: RegisteredResourceKey
  -> ProvenProviderAwsSession
  -> LinuxRke2FoundationId
  -> Either StackGenerationError StackGenerationSeriesKey
stackGenerationSeriesKeyFromProviderScope resourceKey providerScope foundation = do
  identity <-
    maybe
      (Left (StackGenerationUnregisteredKey resourceKey))
      Right
      (lookupRegisteredIdentity resourceKey)
  case registeredIdentityKind identity of
    Stack -> Right ()
    otherKind -> Left (StackGenerationNotAStack resourceKey otherKind)
  Right
    StackGenerationSeriesKey
      { stackGenerationSeriesKeyResource = resourceKey
      , stackGenerationSeriesKeyCoordinateDigest =
          registeredIdentityCoordinateDigest identity
      , stackGenerationSeriesKeyRegistryRevision = lifecycleRegistryRevision
      , stackGenerationSeriesKeyFoundation = foundation
      , stackGenerationSeriesKeyAwsScope =
          AwsScope
            { awsScopeAccountId = provenProviderAwsSessionAccountId providerScope
            , awsScopeRegion = provenProviderAwsSessionRegion providerScope
            }
      }

stackGenerationSeriesKeyOf :: StackGenerationKey -> StackGenerationSeriesKey
stackGenerationSeriesKeyOf key =
  StackGenerationSeriesKey
    { stackGenerationSeriesKeyResource = stackGenerationKeyResource key
    , stackGenerationSeriesKeyCoordinateDigest =
        stackGenerationKeyCoordinateDigest key
    , stackGenerationSeriesKeyRegistryRevision =
        stackGenerationKeyRegistryRevision key
    , stackGenerationSeriesKeyFoundation = stackGenerationKeyFoundation key
    , stackGenerationSeriesKeyAwsScope = stackGenerationKeyAwsScope key
    }

stackGenerationKeyForOrdinal
  :: StackGenerationSeriesKey -> StackGenerationOrdinal -> StackGenerationKey
stackGenerationKeyForOrdinal series ordinal =
  StackGenerationKey
    { stackGenerationKeyResource = stackGenerationSeriesKeyResource series
    , stackGenerationKeyCoordinateDigest =
        stackGenerationSeriesKeyCoordinateDigest series
    , stackGenerationKeyRegistryRevision =
        stackGenerationSeriesKeyRegistryRevision series
    , stackGenerationKeyFoundation = stackGenerationSeriesKeyFoundation series
    , stackGenerationKeyAwsScope = stackGenerationSeriesKeyAwsScope series
    , stackGenerationKeyOrdinal = ordinal
    }

-- ---------------------------------------------------------------------------
-- The run-invariant selection key
-- ---------------------------------------------------------------------------

-- | Opaque and deliberately run-invariant.  Every field is a fact about the
-- resource and the foundation that owns it; none is a fact about the run or
-- surface that happened to observe it.
data StackGenerationKey = StackGenerationKey
  { stackGenerationKeyResource :: !RegisteredResourceKey
  , stackGenerationKeyCoordinateDigest :: !ManagedResourceCoordinateDigest
  , stackGenerationKeyRegistryRevision :: !RegistryRevision
  , stackGenerationKeyFoundation :: !LinuxRke2FoundationId
  , stackGenerationKeyAwsScope :: !AwsScope
  , stackGenerationKeyOrdinal :: !StackGenerationOrdinal
  }
  deriving (Eq, Ord, Show)

-- | Canonical, constructor-tagged rendering for durable records and
-- diagnostics: the series rendering plus the cycle ordinal, under the same
-- NUL framing.
stackGenerationKeyText :: StackGenerationKey -> Text
stackGenerationKeyText key =
  Text.intercalate
    "\NUL"
    [ stackGenerationSeriesKeyText (stackGenerationSeriesKeyOf key)
    , Text.pack (show (stackGenerationOrdinalValue (stackGenerationKeyOrdinal key)))
    ]

-- | The durable slot address of one generation.  Opaque so a caller cannot
-- assemble a slot name from parts and address a record whose key it never
-- possessed.
newtype StackGenerationSlotDigest = StackGenerationSlotDigest Text
  deriving (Eq, Ord, Show)

stackGenerationSlotDigestText :: StackGenerationSlotDigest -> Text
stackGenerationSlotDigestText (StackGenerationSlotDigest value) = value

-- | Hash the canonical key rendering.  Because the rendering is run-invariant,
-- so is this address: the run that creates a stack and the later run that
-- cleans it up compute the same slot without either knowing the other's scope.
stackGenerationSlotDigest :: StackGenerationKey -> StackGenerationSlotDigest
stackGenerationSlotDigest = hexDigestOf . stackGenerationKeyText

hexDigestOf :: Text -> StackGenerationSlotDigest
hexDigestOf value =
  StackGenerationSlotDigest
    ( Text.pack
        ( concatMap
            renderHexByte
            (ByteString.unpack (SHA256.hash (TextEncoding.encodeUtf8 value)))
        )
    )
 where
  renderHexByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

-- | The Authority-retained object name for a generation's slot.  The prefix is
-- distinct from the per-run creation-binding prefix, so a generation-keyed
-- record can never collide with, or be mistaken for, a run-keyed one.
stackGenerationSlotLogicalName :: StackGenerationKey -> Text
stackGenerationSlotLogicalName key =
  "authority/registered-stack-generations/"
    <> stackGenerationSlotDigestText (stackGenerationSlotDigest key)

-- | Derive the run-invariant key of a registered stack's generation from the
-- compiled registry and one exact Provider credential session.
--
-- This is how a /later/ cleanup run addresses a generation an earlier run
-- created.  It is deliberately the same derivation the creating run performs:
-- the coordinate digest and registry revision come only from the compiled
-- registry, and the account/region come only from the opaque Provider proof,
-- so a cleanup run cannot assert its way to a key the creating run could not
-- also have minted.
stackGenerationKeyFromProviderScope
  :: RegisteredResourceKey
  -> ProvenProviderAwsSession
  -> LinuxRke2FoundationId
  -> StackGenerationOrdinal
  -> Either StackGenerationError StackGenerationKey
stackGenerationKeyFromProviderScope resourceKey providerScope foundation ordinal =
  flip stackGenerationKeyForOrdinal ordinal
    <$> stackGenerationSeriesKeyFromProviderScope
      resourceKey
      providerScope
      foundation

registryRevisionText :: RegistryRevision -> Text
registryRevisionText (RegistryRevision value) = value

foundationText :: LinuxRke2FoundationId -> Text
foundationText (LinuxRke2FoundationId value) = value

accountText :: AwsAccountId -> Text
accountText (AwsAccountId value) = value

regionText :: AwsRegion -> Text
regionText (AwsRegion value) = value

-- ---------------------------------------------------------------------------
-- The established generation
-- ---------------------------------------------------------------------------

-- | An established generation: the run-invariant key plus the causal
-- provenance that established it.  Provenance is retained for audit and is
-- never consulted during selection.
data RegisteredStackGeneration = RegisteredStackGeneration
  { registeredStackGenerationKey :: !StackGenerationKey
  , registeredStackGenerationAdmittedOperationId :: !OperationId
  , registeredStackGenerationProviderOperationId :: !Text
  , registeredStackGenerationProviderRevision :: !ProviderRevision
  , registeredStackGenerationCreatingRunScope :: !DurableObservationRunScope
  , registeredStackGenerationCreatingSurface :: !CleanupSurface
  }
  deriving (Eq, Show)

-- | Establish the stable generation of a created registered stack.
--
-- Three of the key's components are deliberately not parameters.  The AWS
-- scope comes solely from the opaque Provider proof, the coordinate digest and
-- the registry revision come solely from the compiled registry.  A caller
-- therefore cannot assert an account, a region, a coordinate the registry does
-- not own, or a revision this binary was not built with — each of which would
-- mint a key that no later run could reproduce.
establishRegisteredStackGeneration
  :: ObservedAwsStackCreationOperation
  -> ProvenProviderAwsSession
  -> LinuxRke2FoundationId
  -> DurableObservationRunScope
  -> CleanupSurface
  -> StackGenerationOrdinal
  -> Either StackGenerationError RegisteredStackGeneration
establishRegisteredStackGeneration
  observed
  providerScope
  foundation
  creatingRunScope
  creatingSurface
  ordinal = do
    key <-
      stackGenerationKeyFromProviderScope
        resourceKey
        providerScope
        foundation
        ordinal
    let registryDigest = stackGenerationKeyCoordinateDigest key
    if registryDigest == observedAwsStackCreationCoordinateDigest observed
      then Right ()
      else
        Left
          ( StackGenerationCoordinateDigestMismatch
              resourceKey
              registryDigest
              (observedAwsStackCreationCoordinateDigest observed)
          )
    pure
      RegisteredStackGeneration
        { registeredStackGenerationKey = key
        , registeredStackGenerationAdmittedOperationId =
            observedAwsStackCreationOperationId observed
        , registeredStackGenerationProviderOperationId =
            provenProviderAwsSessionOperationText providerScope
        , registeredStackGenerationProviderRevision =
            provenProviderAwsSessionRevision providerScope
        , registeredStackGenerationCreatingRunScope = creatingRunScope
        , registeredStackGenerationCreatingSurface = creatingSurface
        }
   where
    resourceKey = observedAwsStackCreationKey observed

-- ---------------------------------------------------------------------------
-- Selection from a later cleanup run
-- ---------------------------------------------------------------------------

-- | What a later cleanup run knows when it goes looking for a created stack.
-- It carries its own run scope and surface, but those are used to record the
-- selection and to check surface eligibility — never to match the generation.
data StackGenerationSelector = StackGenerationSelector
  { selectorResourceKey :: !RegisteredResourceKey
  , selectorCoordinateDigest :: !ManagedResourceCoordinateDigest
  , selectorRegistryRevision :: !RegistryRevision
  , selectorFoundation :: !LinuxRke2FoundationId
  , selectorAwsScope :: !AwsScope
  , selectorOrdinal :: !StackGenerationOrdinal
  , selectorRunScope :: !DurableObservationRunScope
  , selectorSurface :: !CleanupSurface
  }
  deriving (Eq, Show)

-- | Opaque proof that one selector matched one generation, retaining which run
-- and surface performed the selection.
data SelectedStackGeneration = SelectedStackGeneration
  { selectedStackGeneration :: !RegisteredStackGeneration
  , selectedStackGenerationSelectingRunScope :: !DurableObservationRunScope
  , selectedStackGenerationSelectingSurface :: !CleanupSurface
  }
  deriving (Eq, Show)

-- | Select an established generation from a later run.
--
-- A differing run scope or creating surface is explicitly /not/ a mismatch:
-- being able to select across runs is the property this identity exists to
-- provide.  What must agree is the run-invariant key, component by component,
-- so each disagreement is reported as its own refusal rather than a single
-- opaque \"no match\".  The selecting surface must additionally be allowed to
-- select this registered identity at all, so a `LongLived` stack cannot be
-- pulled into a cascade by knowing its key.
selectRegisteredStackGeneration
  :: StackGenerationSelector
  -> RegisteredStackGeneration
  -> Either StackGenerationError SelectedStackGeneration
selectRegisteredStackGeneration selector generation = do
  requireEqual
    (selectorResourceKey selector)
    (stackGenerationKeyResource key)
    ( StackGenerationResourceKeyMismatch
        (stackGenerationKeyResource key)
        (selectorResourceKey selector)
    )
  requireEqual
    (selectorCoordinateDigest selector)
    (stackGenerationKeyCoordinateDigest key)
    ( StackGenerationCoordinateDigestMismatch
        (stackGenerationKeyResource key)
        (stackGenerationKeyCoordinateDigest key)
        (selectorCoordinateDigest selector)
    )
  requireEqual
    (selectorRegistryRevision selector)
    (stackGenerationKeyRegistryRevision key)
    ( StackGenerationRegistryRevisionMismatch
        (stackGenerationKeyRegistryRevision key)
        (selectorRegistryRevision selector)
    )
  requireEqual
    (selectorFoundation selector)
    (stackGenerationKeyFoundation key)
    ( StackGenerationFoundationMismatch
        (stackGenerationKeyFoundation key)
        (selectorFoundation selector)
    )
  requireEqual
    (awsScopeAccountId (selectorAwsScope selector))
    (awsScopeAccountId (stackGenerationKeyAwsScope key))
    ( StackGenerationAwsAccountMismatch
        (awsScopeAccountId (stackGenerationKeyAwsScope key))
        (awsScopeAccountId (selectorAwsScope selector))
    )
  requireEqual
    (awsScopeRegion (selectorAwsScope selector))
    (awsScopeRegion (stackGenerationKeyAwsScope key))
    ( StackGenerationAwsRegionMismatch
        (awsScopeRegion (stackGenerationKeyAwsScope key))
        (awsScopeRegion (selectorAwsScope selector))
    )
  requireEqual
    (selectorOrdinal selector)
    (stackGenerationKeyOrdinal key)
    ( StackGenerationOrdinalMismatch
        (stackGenerationKeyOrdinal key)
        (selectorOrdinal selector)
    )
  identity <-
    maybe
      (Left (StackGenerationUnregisteredKey (stackGenerationKeyResource key)))
      Right
      (lookupRegisteredIdentity (stackGenerationKeyResource key))
  if cleanupSurfaceAllows (selectorSurface selector) identity
    then Right ()
    else
      Left
        ( StackGenerationSurfaceRefused
            (selectorSurface selector)
            (stackGenerationKeyResource key)
        )
  pure
    SelectedStackGeneration
      { selectedStackGeneration = generation
      , selectedStackGenerationSelectingRunScope = selectorRunScope selector
      , selectedStackGenerationSelectingSurface = selectorSurface selector
      }
 where
  key = registeredStackGenerationKey generation
  requireEqual actual expected err =
    if actual == expected then Right () else Left err

-- | The selector a cleanup run holding an addressing key presents.  The
-- run-invariant components come from the key it derived itself; only the
-- selecting run scope and surface are its own.
stackGenerationSelectorForKey
  :: StackGenerationKey
  -> DurableObservationRunScope
  -> CleanupSurface
  -> StackGenerationSelector
stackGenerationSelectorForKey key runScope surface =
  StackGenerationSelector
    { selectorResourceKey = stackGenerationKeyResource key
    , selectorCoordinateDigest = stackGenerationKeyCoordinateDigest key
    , selectorRegistryRevision = stackGenerationKeyRegistryRevision key
    , selectorFoundation = stackGenerationKeyFoundation key
    , selectorAwsScope = stackGenerationKeyAwsScope key
    , selectorOrdinal = stackGenerationKeyOrdinal key
    , selectorRunScope = runScope
    , selectorSurface = surface
    }

-- ---------------------------------------------------------------------------
-- The durable record
-- ---------------------------------------------------------------------------

-- | The canonical durable form of one established generation.
--
-- The wire carries the run-invariant key /and/ the causal provenance, because
-- provenance is exactly what a later run cannot reconstruct.  What it does not
-- carry is authority: decoding re-derives the coordinate digest and registry
-- revision from the compiled registry and refuses a record whose stored digest
-- disagrees, so a record cannot smuggle in a coordinate this binary does not
-- own.
data StackGenerationWire = StackGenerationWire
  { generationWireVersion :: !Int
  , generationWireRegistryRevision :: !Text
  , generationWireKey :: !Int
  , generationWireCoordinateDigest :: !Text
  , generationWireFoundation :: !Text
  , generationWireAwsAccount :: !Text
  , generationWireAwsRegion :: !Text
  , generationWireOrdinal :: !Integer
  , generationWireAdmittedEpoch :: !Integer
  , generationWireAdmittedClient :: !Text
  , generationWireAdmittedSequence :: !Integer
  , generationWireAdmittedDigest :: !Text
  , generationWireProviderOperationId :: !Text
  , generationWireProviderRevision :: !Integer
  , generationWireCreatingRunScope :: !Text
  , generationWireCreatingSurface :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

maximumRegisteredStackGenerationRecordBytes :: Int
maximumRegisteredStackGenerationRecordBytes = 16 * 1024

encodeRegisteredStackGeneration :: RegisteredStackGeneration -> ByteString
encodeRegisteredStackGeneration generation =
  LazyByteString.toStrict
    ( serialise
        StackGenerationWire
          { generationWireVersion = 1
          , generationWireRegistryRevision =
              registryRevisionText (stackGenerationKeyRegistryRevision key)
          , generationWireKey = fromEnum (stackGenerationKeyResource key)
          , generationWireCoordinateDigest =
              managedResourceCoordinateDigestText
                (stackGenerationKeyCoordinateDigest key)
          , generationWireFoundation =
              foundationText (stackGenerationKeyFoundation key)
          , generationWireAwsAccount =
              accountText (awsScopeAccountId (stackGenerationKeyAwsScope key))
          , generationWireAwsRegion =
              regionText (awsScopeRegion (stackGenerationKeyAwsScope key))
          , generationWireOrdinal =
              toInteger (stackGenerationOrdinalValue (stackGenerationKeyOrdinal key))
          , generationWireAdmittedEpoch =
              toInteger (authorityEpochValue (operationIdEpoch admitted))
          , generationWireAdmittedClient = clientIdText (operationIdClient admitted)
          , generationWireAdmittedSequence =
              toInteger (clientSequenceNatural (operationIdSequence admitted))
          , generationWireAdmittedDigest =
              requestDigestText (operationIdDigest admitted)
          , generationWireProviderOperationId =
              registeredStackGenerationProviderOperationId generation
          , generationWireProviderRevision =
              toInteger
                ( providerRevisionNatural
                    (registeredStackGenerationProviderRevision generation)
                )
          , generationWireCreatingRunScope =
              durableRunScopeText
                (registeredStackGenerationCreatingRunScope generation)
          , generationWireCreatingSurface =
              fromEnum (registeredStackGenerationCreatingSurface generation)
          }
    )
 where
  key = registeredStackGenerationKey generation
  admitted = registeredStackGenerationAdmittedOperationId generation

decodeRegisteredStackGeneration
  :: ByteString -> Either StackGenerationError RegisteredStackGeneration
decodeRegisteredStackGeneration bytes = do
  when (ByteString.null bytes) (Left StackGenerationRecordEmpty)
  when
    (ByteString.length bytes > maximumRegisteredStackGenerationRecordBytes)
    ( Left
        ( StackGenerationRecordTooLarge
            maximumRegisteredStackGenerationRecordBytes
            (ByteString.length bytes)
        )
    )
  wire <-
    first
      (StackGenerationRecordDecodeFailed . Text.pack . show)
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless
    (LazyByteString.toStrict (serialise wire) == bytes)
    (Left StackGenerationRecordNonCanonical)
  unless
    (generationWireVersion wire == 1)
    (Left (StackGenerationRecordVersionUnsupported (generationWireVersion wire)))
  unless
    ( generationWireRegistryRevision wire
        == registryRevisionText lifecycleRegistryRevision
    )
    ( Left
        ( StackGenerationRegistryRevisionMismatch
            lifecycleRegistryRevision
            (RegistryRevision (generationWireRegistryRevision wire))
        )
    )
  resourceKey <- decodeBoundedKey (generationWireKey wire)
  creatingSurface <- decodeBoundedSurface (generationWireCreatingSurface wire)
  identity <-
    maybe
      (Left (StackGenerationUnregisteredKey resourceKey))
      Right
      (lookupRegisteredIdentity resourceKey)
  case registeredIdentityKind identity of
    Stack -> Right ()
    otherKind -> Left (StackGenerationNotAStack resourceKey otherKind)
  let registryDigest = registeredIdentityCoordinateDigest identity
  unless
    ( managedResourceCoordinateDigestText registryDigest
        == generationWireCoordinateDigest wire
    )
    ( Left
        ( StackGenerationRecordFieldInvalid
            "the stored coordinate digest is not the compiled registry's digest"
        )
    )
  foundation <-
    LinuxRke2FoundationId
      <$> checkedText "Linux RKE2 foundation" 512 (generationWireFoundation wire)
  account <- checkedAwsAccount (generationWireAwsAccount wire)
  region <- checkedText "AWS region" 128 (generationWireAwsRegion wire)
  ordinalValue <- checkedNatural "generation ordinal" (generationWireOrdinal wire)
  when
    (ordinalValue > toInteger (maxBound :: Word64))
    (Left (StackGenerationRecordFieldInvalid "generation ordinal is out of range"))
  ordinal <- mkStackGenerationOrdinal (fromInteger ordinalValue)
  admitted <- decodeAdmittedOperation wire
  providerOperationId <-
    checkedText "Provider operation id" 512 (generationWireProviderOperationId wire)
  providerRevisionValue <-
    checkedNatural "Provider revision" (generationWireProviderRevision wire)
  providerRevision <-
    first
      StackGenerationRecordFieldInvalid
      (mkProviderRevision (fromInteger providerRevisionValue))
  creatingRunScope <-
    DurableObservationRunScope
      <$> checkedText "durable run scope" 512 (generationWireCreatingRunScope wire)
  Right
    RegisteredStackGeneration
      { registeredStackGenerationKey =
          StackGenerationKey
            { stackGenerationKeyResource = resourceKey
            , stackGenerationKeyCoordinateDigest = registryDigest
            , stackGenerationKeyRegistryRevision = lifecycleRegistryRevision
            , stackGenerationKeyFoundation = foundation
            , stackGenerationKeyAwsScope =
                AwsScope
                  { awsScopeAccountId = AwsAccountId account
                  , awsScopeRegion = AwsRegion region
                  }
            , stackGenerationKeyOrdinal = ordinal
            }
      , registeredStackGenerationAdmittedOperationId = admitted
      , registeredStackGenerationProviderOperationId = providerOperationId
      , registeredStackGenerationProviderRevision = providerRevision
      , registeredStackGenerationCreatingRunScope = creatingRunScope
      , registeredStackGenerationCreatingSurface = creatingSurface
      }

decodeAdmittedOperation
  :: StackGenerationWire -> Either StackGenerationError OperationId
decodeAdmittedOperation wire =
  decodeOperationId
    (generationWireAdmittedEpoch wire)
    (generationWireAdmittedClient wire)
    (generationWireAdmittedSequence wire)
    (generationWireAdmittedDigest wire)

decodeOperationId
  :: Integer -> Text -> Integer -> Text -> Either StackGenerationError OperationId
decodeOperationId rawEpoch rawClient rawSequence rawDigest = do
  epochValue <- checkedNatural "admitted operation epoch" rawEpoch
  epoch <-
    maybe
      ( Left
          ( StackGenerationRecordFieldInvalid
              "admitted operation epoch must be positive"
          )
      )
      Right
      (authorityEpochFromValue (fromInteger epochValue))
  client <- checkedText "admitted operation client" 256 rawClient
  sequenceValue <- checkedNatural "admitted operation sequence" rawSequence
  digest <- checkedDigest rawDigest
  Right
    OperationId
      { operationIdEpoch = epoch
      , operationIdClient = ClientId client
      , operationIdSequence = ClientSequence (fromInteger sequenceValue)
      , operationIdDigest = RequestDigest digest
      }

decodeBoundedKey :: Int -> Either StackGenerationError RegisteredResourceKey
decodeBoundedKey raw
  | raw < fromEnum (minBound :: RegisteredResourceKey)
      || raw > fromEnum (maxBound :: RegisteredResourceKey) =
      Left
        ( StackGenerationRecordFieldInvalid
            "the registered key is outside the closed registry"
        )
  | otherwise = Right (toEnum raw)

decodeBoundedSurface :: Int -> Either StackGenerationError CleanupSurface
decodeBoundedSurface raw
  | raw < fromEnum (minBound :: CleanupSurface)
      || raw > fromEnum (maxBound :: CleanupSurface) =
      Left
        ( StackGenerationRecordFieldInvalid
            "the creating cleanup surface is outside the closed enum"
        )
  | otherwise = Right (toEnum raw)

checkedText :: Text -> Int -> Text -> Either StackGenerationError Text
checkedText label maximumLength value
  | Text.null value = invalid "was empty"
  | Text.length value > maximumLength = invalid "was too long"
  | Text.any (\character -> not (isAscii character) || isControl character) value =
      invalid "contained a non-printable character"
  | otherwise = Right value
 where
  invalid detail =
    Left (StackGenerationRecordFieldInvalid (label <> " " <> detail))

checkedAwsAccount :: Text -> Either StackGenerationError Text
checkedAwsAccount value
  | Text.length value == 12 && Text.all isDigit value = Right value
  | otherwise =
      Left
        ( StackGenerationRecordFieldInvalid
            "the AWS account id was not twelve digits"
        )

checkedNatural :: Text -> Integer -> Either StackGenerationError Integer
checkedNatural label value
  | value < 0 =
      Left (StackGenerationRecordFieldInvalid (label <> " was negative"))
  | otherwise = Right value

checkedDigest :: Text -> Either StackGenerationError Text
checkedDigest value
  | Text.length value == 64 && Text.all isLowerHex value = Right value
  | otherwise =
      Left
        ( StackGenerationRecordFieldInvalid
            "the admitted operation digest was not a canonical SHA-256 digest"
        )
 where
  isLowerHex character =
    isDigit character || (character >= 'a' && character <= 'f')

-- ---------------------------------------------------------------------------
-- Ordinal succession
-- ---------------------------------------------------------------------------

-- | The durable pointer that says which cycle of one series is current.
--
-- A generation slot is addressed /by/ its ordinal, so nothing in the generation
-- records themselves can say what the next ordinal is without an unbounded
-- probe.  The cursor answers that question in one read, and it retains the
-- admitted create operation that last advanced it so a retried create is
-- recognized as a replay rather than burning a second cycle.
data StackGenerationCursor = StackGenerationCursor
  { stackGenerationCursorSeries :: !StackGenerationSeriesKey
  , stackGenerationCursorOrdinal :: !StackGenerationOrdinal
  , stackGenerationCursorAdmittedOperationId :: !OperationId
  }
  deriving (Eq, Show)

-- | The generation key this cursor currently points at.
stackGenerationCursorGenerationKey :: StackGenerationCursor -> StackGenerationKey
stackGenerationCursorGenerationKey cursor =
  stackGenerationKeyForOrdinal
    (stackGenerationCursorSeries cursor)
    (stackGenerationCursorOrdinal cursor)

-- | Open a series at its first cycle.  The series is derived exactly as a
-- generation key is, and the admitted create operation must name the same
-- registered stack and the same compiled coordinate.
openStackGenerationCursor
  :: ObservedAwsStackCreationOperation
  -> ProvenProviderAwsSession
  -> LinuxRke2FoundationId
  -> Either StackGenerationError StackGenerationCursor
openStackGenerationCursor observed providerScope foundation = do
  series <-
    stackGenerationSeriesKeyFromProviderScope
      (observedAwsStackCreationKey observed)
      providerScope
      foundation
  requireObservedCoordinate series observed
  Right
    StackGenerationCursor
      { stackGenerationCursorSeries = series
      , stackGenerationCursorOrdinal = initialStackGenerationOrdinal
      , stackGenerationCursorAdmittedOperationId =
          observedAwsStackCreationOperationId observed
      }

-- | Advance an existing series to its next cycle for one admitted create.
--
-- The observation must belong to this series' registered stack: advancing a
-- series on behalf of a different stack would mint a cycle whose record no
-- later run could reproduce.
advanceStackGenerationCursor
  :: StackGenerationCursor
  -> ObservedAwsStackCreationOperation
  -> Either StackGenerationError StackGenerationCursor
advanceStackGenerationCursor cursor observed = do
  let series = stackGenerationCursorSeries cursor
      seriesKey = stackGenerationSeriesKeyResource series
      observedKey = observedAwsStackCreationKey observed
  if observedKey == seriesKey
    then Right ()
    else Left (StackGenerationResourceKeyMismatch seriesKey observedKey)
  requireObservedCoordinate series observed
  ordinal <-
    succeedingStackGenerationOrdinal (stackGenerationCursorOrdinal cursor)
  Right
    cursor
      { stackGenerationCursorOrdinal = ordinal
      , stackGenerationCursorAdmittedOperationId =
          observedAwsStackCreationOperationId observed
      }

requireObservedCoordinate
  :: StackGenerationSeriesKey
  -> ObservedAwsStackCreationOperation
  -> Either StackGenerationError ()
requireObservedCoordinate series observed
  | registryDigest == observedAwsStackCreationCoordinateDigest observed = Right ()
  | otherwise =
      Left
        ( StackGenerationCoordinateDigestMismatch
            (stackGenerationSeriesKeyResource series)
            registryDigest
            (observedAwsStackCreationCoordinateDigest observed)
        )
 where
  registryDigest = stackGenerationSeriesKeyCoordinateDigest series

data StackGenerationCursorWire = StackGenerationCursorWire
  { cursorWireVersion :: !Int
  , cursorWireRegistryRevision :: !Text
  , cursorWireKey :: !Int
  , cursorWireCoordinateDigest :: !Text
  , cursorWireFoundation :: !Text
  , cursorWireAwsAccount :: !Text
  , cursorWireAwsRegion :: !Text
  , cursorWireOrdinal :: !Integer
  , cursorWireAdmittedEpoch :: !Integer
  , cursorWireAdmittedClient :: !Text
  , cursorWireAdmittedSequence :: !Integer
  , cursorWireAdmittedDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

maximumStackGenerationCursorRecordBytes :: Int
maximumStackGenerationCursorRecordBytes = 8 * 1024

encodeStackGenerationCursor :: StackGenerationCursor -> ByteString
encodeStackGenerationCursor cursor =
  LazyByteString.toStrict
    ( serialise
        StackGenerationCursorWire
          { cursorWireVersion = 1
          , cursorWireRegistryRevision =
              registryRevisionText (stackGenerationSeriesKeyRegistryRevision series)
          , cursorWireKey = fromEnum (stackGenerationSeriesKeyResource series)
          , cursorWireCoordinateDigest =
              managedResourceCoordinateDigestText
                (stackGenerationSeriesKeyCoordinateDigest series)
          , cursorWireFoundation =
              foundationText (stackGenerationSeriesKeyFoundation series)
          , cursorWireAwsAccount =
              accountText (awsScopeAccountId (stackGenerationSeriesKeyAwsScope series))
          , cursorWireAwsRegion =
              regionText (awsScopeRegion (stackGenerationSeriesKeyAwsScope series))
          , cursorWireOrdinal =
              toInteger
                (stackGenerationOrdinalValue (stackGenerationCursorOrdinal cursor))
          , cursorWireAdmittedEpoch =
              toInteger (authorityEpochValue (operationIdEpoch admitted))
          , cursorWireAdmittedClient = clientIdText (operationIdClient admitted)
          , cursorWireAdmittedSequence =
              toInteger (clientSequenceNatural (operationIdSequence admitted))
          , cursorWireAdmittedDigest = requestDigestText (operationIdDigest admitted)
          }
    )
 where
  series = stackGenerationCursorSeries cursor
  admitted = stackGenerationCursorAdmittedOperationId cursor

decodeStackGenerationCursor
  :: ByteString -> Either StackGenerationError StackGenerationCursor
decodeStackGenerationCursor bytes = do
  when (ByteString.null bytes) (Left StackGenerationRecordEmpty)
  when
    (ByteString.length bytes > maximumStackGenerationCursorRecordBytes)
    ( Left
        ( StackGenerationRecordTooLarge
            maximumStackGenerationCursorRecordBytes
            (ByteString.length bytes)
        )
    )
  wire <-
    first
      (StackGenerationRecordDecodeFailed . Text.pack . show)
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless
    (LazyByteString.toStrict (serialise wire) == bytes)
    (Left StackGenerationRecordNonCanonical)
  unless
    (cursorWireVersion wire == 1)
    (Left (StackGenerationRecordVersionUnsupported (cursorWireVersion wire)))
  unless
    (cursorWireRegistryRevision wire == registryRevisionText lifecycleRegistryRevision)
    ( Left
        ( StackGenerationRegistryRevisionMismatch
            lifecycleRegistryRevision
            (RegistryRevision (cursorWireRegistryRevision wire))
        )
    )
  resourceKey <- decodeBoundedKey (cursorWireKey wire)
  identity <-
    maybe
      (Left (StackGenerationUnregisteredKey resourceKey))
      Right
      (lookupRegisteredIdentity resourceKey)
  case registeredIdentityKind identity of
    Stack -> Right ()
    otherKind -> Left (StackGenerationNotAStack resourceKey otherKind)
  let registryDigest = registeredIdentityCoordinateDigest identity
  unless
    ( managedResourceCoordinateDigestText registryDigest
        == cursorWireCoordinateDigest wire
    )
    ( Left
        ( StackGenerationRecordFieldInvalid
            "the stored coordinate digest is not the compiled registry's digest"
        )
    )
  foundation <-
    LinuxRke2FoundationId
      <$> checkedText "Linux RKE2 foundation" 512 (cursorWireFoundation wire)
  account <- checkedAwsAccount (cursorWireAwsAccount wire)
  region <- checkedText "AWS region" 128 (cursorWireAwsRegion wire)
  ordinalValue <- checkedNatural "generation ordinal" (cursorWireOrdinal wire)
  when
    (ordinalValue > toInteger (maxBound :: Word64))
    (Left (StackGenerationRecordFieldInvalid "generation ordinal is out of range"))
  ordinal <- mkStackGenerationOrdinal (fromInteger ordinalValue)
  admitted <-
    decodeOperationId
      (cursorWireAdmittedEpoch wire)
      (cursorWireAdmittedClient wire)
      (cursorWireAdmittedSequence wire)
      (cursorWireAdmittedDigest wire)
  Right
    StackGenerationCursor
      { stackGenerationCursorSeries =
          StackGenerationSeriesKey
            { stackGenerationSeriesKeyResource = resourceKey
            , stackGenerationSeriesKeyCoordinateDigest = registryDigest
            , stackGenerationSeriesKeyRegistryRevision = lifecycleRegistryRevision
            , stackGenerationSeriesKeyFoundation = foundation
            , stackGenerationSeriesKeyAwsScope =
                AwsScope
                  { awsScopeAccountId = AwsAccountId account
                  , awsScopeRegion = AwsRegion region
                  }
            }
      , stackGenerationCursorOrdinal = ordinal
      , stackGenerationCursorAdmittedOperationId = admitted
      }

durableRunScopeText :: DurableObservationRunScope -> Text
durableRunScopeText (DurableObservationRunScope value) = value

clientIdText :: ClientId -> Text
clientIdText (ClientId value) = value

clientSequenceNatural :: ClientSequence -> Natural
clientSequenceNatural (ClientSequence value) = value

-- ---------------------------------------------------------------------------
-- Refusals
-- ---------------------------------------------------------------------------

data StackGenerationError
  = StackGenerationOrdinalZero
  | StackGenerationOrdinalExhausted
  | StackGenerationUnregisteredKey !RegisteredResourceKey
  | StackGenerationNotAStack !RegisteredResourceKey !ResourceKind
  | StackGenerationCoordinateDigestMismatch
      !RegisteredResourceKey
      !ManagedResourceCoordinateDigest
      !ManagedResourceCoordinateDigest
  | StackGenerationResourceKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | StackGenerationRegistryRevisionMismatch !RegistryRevision !RegistryRevision
  | StackGenerationFoundationMismatch
      !LinuxRke2FoundationId
      !LinuxRke2FoundationId
  | StackGenerationAwsAccountMismatch !AwsAccountId !AwsAccountId
  | StackGenerationAwsRegionMismatch !AwsRegion !AwsRegion
  | StackGenerationOrdinalMismatch
      !StackGenerationOrdinal
      !StackGenerationOrdinal
  | StackGenerationSurfaceRefused !CleanupSurface !RegisteredResourceKey
  | StackGenerationRecordEmpty
  | StackGenerationRecordTooLarge !Int !Int
  | StackGenerationRecordDecodeFailed !Text
  | StackGenerationRecordNonCanonical
  | StackGenerationRecordVersionUnsupported !Int
  | StackGenerationRecordFieldInvalid !Text
  deriving (Eq, Show)

renderStackGenerationError :: StackGenerationError -> Text
renderStackGenerationError = \case
  StackGenerationOrdinalZero ->
    "A registered stack generation ordinal of 0 is reserved: it would make \
    \`never created` and `created once` the same key."
  StackGenerationOrdinalExhausted ->
    "The registered stack generation ordinal is exhausted; succeeding it would \
    \reuse a key a durable record already holds."
  StackGenerationUnregisteredKey key ->
    "Registered resource `"
      <> registeredResourceKeyText key
      <> "` is not in the compiled lifecycle registry, so no stable stack \
         \generation can be established or selected for it."
  StackGenerationNotAStack key kind ->
    "Registered resource `"
      <> registeredResourceKeyText key
      <> "` has kind `"
      <> Text.pack (show kind)
      <> "`; a stack generation identifies a `Stack` only."
  StackGenerationCoordinateDigestMismatch key expected actual ->
    "Registered resource `"
      <> registeredResourceKeyText key
      <> "` has compiled coordinate digest "
      <> managedResourceCoordinateDigestText expected
      <> " but was presented with "
      <> managedResourceCoordinateDigestText actual
      <> "."
  StackGenerationResourceKeyMismatch expected actual ->
    "This generation belongs to registered resource `"
      <> registeredResourceKeyText expected
      <> "`, not `"
      <> registeredResourceKeyText actual
      <> "`."
  StackGenerationRegistryRevisionMismatch expected actual ->
    "This generation was established under registry revision `"
      <> registryRevisionText expected
      <> "`; selection presented `"
      <> registryRevisionText actual
      <> "`."
  StackGenerationFoundationMismatch expected actual ->
    "This generation belongs to local foundation `"
      <> foundationText expected
      <> "`; selection presented `"
      <> foundationText actual
      <> "`."
  StackGenerationAwsAccountMismatch expected actual ->
    "This generation was created in AWS account `"
      <> accountText expected
      <> "`; selection presented `"
      <> accountText actual
      <> "`."
  StackGenerationAwsRegionMismatch expected actual ->
    "This generation was created in AWS region `"
      <> regionText expected
      <> "`; selection presented `"
      <> regionText actual
      <> "`."
  StackGenerationOrdinalMismatch expected actual ->
    "This generation is cycle "
      <> Text.pack (show (stackGenerationOrdinalValue expected))
      <> "; selection presented cycle "
      <> Text.pack (show (stackGenerationOrdinalValue actual))
      <> ". A different cycle of the same stack is a different resource."
  StackGenerationSurfaceRefused surface key ->
    "Cleanup surface `"
      <> Text.pack (show surface)
      <> "` may not select registered resource `"
      <> registeredResourceKeyText key
      <> "`; knowing a generation key does not widen a surface."
  StackGenerationRecordEmpty ->
    "A durable registered-stack-generation record was empty."
  StackGenerationRecordTooLarge limit actual ->
    "A durable registered-stack-generation record of "
      <> Text.pack (show actual)
      <> " bytes exceeds the bound of "
      <> Text.pack (show limit)
      <> " bytes."
  StackGenerationRecordDecodeFailed detail ->
    "A durable registered-stack-generation record did not decode: "
      <> detail
      <> "."
  StackGenerationRecordNonCanonical ->
    "A durable registered-stack-generation record was not the canonical \
    \encoding of its own content."
  StackGenerationRecordVersionUnsupported version ->
    "A durable registered-stack-generation record declared version "
      <> Text.pack (show version)
      <> "; this binary writes and reads version 1 only."
  StackGenerationRecordFieldInvalid detail ->
    "A durable registered-stack-generation record was rejected: "
      <> detail
      <> "."
