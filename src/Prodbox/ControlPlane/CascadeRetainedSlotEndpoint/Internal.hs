{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: package-private Authority endpoint for the cascade's three
-- retained slot families.
--
-- [Lifecycle Reconciliation Doctrine § 5b nodes 7, 9 and 10](../../../../documents/engineering/lifecycle_reconciliation_doctrine.md#5b-canonical-recover-to-clean-cascade)
-- put the Lifecycle Authority on both sides of the destructive host boundary,
-- and "Prodbox.ControlPlane.HostCleanupReadinessRepository" and
-- "Prodbox.ControlPlane.CascadeReportRepository" are the durable namespaces
-- that carries.  Both are written against a
-- @'ModelBCasAdapter' ''ClusterRetained'@, and the only production adapter in
-- the repository was the /in-cluster/ one: the host, which is where a cascade
-- runs and where the readiness must be accepted before local RKE2 is removed,
-- had no way to reach either namespace at all.  This endpoint is that way.
--
-- Four properties carry the design.
--
--   * __The namespace is closed.__  Exactly three run-keyed slot families are
--     reachable, and a name outside them is refused before any coordinate is
--     built or any object store is touched.  A generic
--     "compare-and-swap any Authority object" route would be an escape path
--     wearing a protocol: it would put the admission projection, the cleanup
--     runs, and every credential namespace one logical name away from the
--     host.
--
--   * __The only write is an initialize.__  There is no replace arm and no
--     guarded arm on the wire, so a host cannot overwrite an accepted
--     readiness, a committed report identity, or a granted destroy permit.  A
--     second and /different/ value under one run comes back as a conflict
--     carrying what is already there, which is exactly what the repositories
--     need to tell an exact replay from a genuine disagreement.
--
--   * __Authority identity never crosses the wire.__  The host names a slot;
--     the Authority builds the coordinate from the authority it was configured
--     with.  A host therefore cannot address another cluster's retained
--     namespace even by construction, and the wire carries no bucket,
--     namespace, or cluster id to be tampered with.
--
--   * __A response that cannot be confirmed is not a refusal.__  Once a
--     request has been issued, a lost, malformed, or mismatched response
--     leaves a write that may well have landed.  The client turns those into
--     the unobservable arms of the Model-B result, never into a refusal, so a
--     run never concludes the opposite of what may be durable.
--
-- What this module does not own: the /content/ of any slot, which belongs to
-- the two repositories above; the durable meaning of a conflict, which belongs
-- to their accept/commit/grant protocols; and the host-side adapter, which is
-- "Prodbox.ControlPlane.CascadeRetainedSlotClient".
module Prodbox.ControlPlane.CascadeRetainedSlotEndpoint.Internal
  ( -- * The closed namespace
    CascadeRetainedSlotFamily (..)
  , cascadeRetainedSlotFamilies
  , cascadeRetainedSlotFamilyPrefix
  , CascadeRetainedSlotNameRefusal (..)
  , renderCascadeRetainedSlotNameRefusal
  , admitCascadeRetainedSlotName

    -- * The wire
  , CascadeRetainedSlotWireOperation (..)
  , CascadeRetainedSlotWireRequest (..)
  , cascadeRetainedSlotObserveWireRequestInternal
  , cascadeRetainedSlotInitializeWireRequestInternal
  , CascadeRetainedSlotWireObservation (..)
  , CascadeRetainedSlotWireCas (..)
  , CascadeRetainedSlotWireOutcome (..)
  , CascadeRetainedSlotWireRefusal (..)
  , CascadeRetainedSlotWireResponse (..)

    -- * Serving
  , CascadeRetainedSlotEndpointHandler
  , lifecycleAuthorityCascadeRetainedSlotEndpointHandlerInternal
  , CascadeRetainedSlotEndpointResult
  , cascadeRetainedSlotEndpointFormatVersion
  , cascadeRetainedSlotEndpointMaximumBytes
  , cascadeRetainedSlotEndpointResponseMaximumBytes
  , maximumCascadeRetainedSlotValueBytes
  , cascadeRetainedSlotModelBCodec
  , serveCascadeRetainedSlotEndpointRequest
  , cascadeRetainedSlotEndpointStatus
  , cascadeRetainedSlotWireResponseStatus
  , cascadeRetainedSlotEndpointBody

    -- * Confirming a response
  , decodeCascadeRetainedSlotEndpointResponseInternal
  , CascadeRetainedSlotEndpointResponseError (..)
  , confirmCascadeRetainedSlotResponseInternal

    -- * Regression over the closed namespace
  , CascadeRetainedSlotEndpointRegression
  , fixedCascadeRetainedSlotEndpointRegression
  , cascadeRetainedSlotEndpointAdmitsExactlyTheCascadeNamespaces
  , cascadeRetainedSlotEndpointForeignNameNoExecution
  , cascadeRetainedSlotEndpointMalformedSuffixNoExecution
  , cascadeRetainedSlotEndpointMalformedNoExecution
  , cascadeRetainedSlotEndpointOversizeNoExecution
  , cascadeRetainedSlotEndpointUnsupportedVersionNoExecution
  , cascadeRetainedSlotEndpointOversizeValueNoExecution
  , cascadeRetainedSlotEndpointConflictCarriesObservedBytes
  , cascadeRetainedSlotEndpointAllArmsValidateRequestDigest
  )
where

import Codec.Serialise (Serialise)
import Control.Monad (unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isDigit)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.CascadeReportRepository
  ( cascadeCompletionPermitAuthorityLogicalName
  , cascadeReportAuthorityLogicalName
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (..)
  , ControlPlaneResponseCodecError
  , decodeControlPlaneRequest
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.HostCleanupReadinessRepository
  ( hostCleanupReadinessAuthorityLogicalName
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (ModelBInitialize)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  , mkModelBObjectVersion
  , modelBObjectVersionText
  )
import Prodbox.Lifecycle.CleanupRun (mkCleanupRunId)

-- ---------------------------------------------------------------------------
-- The closed namespace
-- ---------------------------------------------------------------------------

-- | The three retained slot families a cascade reaches from the host.
--
-- Enumerated rather than derived from a prefix predicate so that adding a
-- fourth reachable namespace is a deliberate edit to a closed type, visible in
-- every @case@ that consumes it.
data CascadeRetainedSlotFamily
  = -- | One run's accepted pre-uninstall readiness.
    CascadeHostCleanupReadinessSlot
  | -- | One run's committed pre-uninstall report identity.
    CascadePreUninstallReportSlot
  | -- | One run's one-shot local-completion permit.
    CascadeLocalCompletionPermitSlot
  deriving stock (Bounded, Enum, Eq, Ord, Show)

cascadeRetainedSlotFamilies :: [CascadeRetainedSlotFamily]
cascadeRetainedSlotFamilies = [minBound .. maxBound]

-- | The exact logical-name prefix each family owns.
--
-- These are the prefixes the two repositories derive their slot names under.
-- The regression below measures that by admitting the names those repositories
-- actually produce, so a rename there fails this route rather than silently
-- leaving the host unable to reach its own namespace.
cascadeRetainedSlotFamilyPrefix :: CascadeRetainedSlotFamily -> Text
cascadeRetainedSlotFamilyPrefix = \case
  CascadeHostCleanupReadinessSlot -> "authority/host-cleanup-readiness/"
  CascadePreUninstallReportSlot -> "authority/cascade-pre-uninstall-report/"
  CascadeLocalCompletionPermitSlot -> "authority/cascade-local-completion-permit/"

data CascadeRetainedSlotNameRefusal
  = -- | The name is under none of the three cascade prefixes.
    CascadeRetainedSlotNameForeign !Text
  | -- | The name is under a cascade prefix but its run-keyed suffix is not the
    -- canonical hex digest the repositories derive.
    CascadeRetainedSlotNameMalformedKey !Text
  deriving stock (Eq, Show)

renderCascadeRetainedSlotNameRefusal :: CascadeRetainedSlotNameRefusal -> Text
renderCascadeRetainedSlotNameRefusal = \case
  CascadeRetainedSlotNameForeign name ->
    "logical name `"
      <> name
      <> "` is outside the cascade's retained slot namespace"
  CascadeRetainedSlotNameMalformedKey name ->
    "logical name `"
      <> name
      <> "` carries no canonical run-keyed slot digest"

-- | Admit a logical name, or say why the closed namespace refuses it.
--
-- The suffix check is exact rather than "non-empty": the repositories key
-- every slot by a SHA-256 of the framed run identity, so anything else is
-- either a different addressing scheme or an attempt to reach a neighbouring
-- object by traversal.
admitCascadeRetainedSlotName
  :: Text -> Either CascadeRetainedSlotNameRefusal CascadeRetainedSlotFamily
admitCascadeRetainedSlotName name =
  case [ (family, suffix)
       | family <- cascadeRetainedSlotFamilies
       , Just suffix <-
           [Text.stripPrefix (cascadeRetainedSlotFamilyPrefix family) name]
       ] of
    [] -> Left (CascadeRetainedSlotNameForeign name)
    ((family, suffix) : _)
      | canonicalSlotKey suffix -> Right family
      | otherwise -> Left (CascadeRetainedSlotNameMalformedKey name)

canonicalSlotKey :: Text -> Bool
canonicalSlotKey suffix =
  Text.length suffix == 64 && Text.all isLowerHex suffix
 where
  isLowerHex character =
    isDigit character || (character >= 'a' && character <= 'f')

-- ---------------------------------------------------------------------------
-- The wire
-- ---------------------------------------------------------------------------

-- | The two operations the cascade performs against a retained slot.
--
-- There is deliberately no replace or guarded constructor: the absence is the
-- guarantee, because a wire type with no such arm cannot be persuaded to
-- overwrite a slot by a caller, a decoder, or a future edit that forgets why.
data CascadeRetainedSlotWireOperation
  = CascadeRetainedSlotObserveOperation
  | CascadeRetainedSlotInitializeOperation !ByteString
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CascadeRetainedSlotWireRequest = CascadeRetainedSlotWireRequest
  { cascadeRetainedSlotWireRequestVersion :: !Word16
  , cascadeRetainedSlotWireRequestLogicalName :: !Text
  , cascadeRetainedSlotWireRequestOperation :: !CascadeRetainedSlotWireOperation
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

cascadeRetainedSlotObserveWireRequestInternal
  :: Text -> CascadeRetainedSlotWireRequest
cascadeRetainedSlotObserveWireRequestInternal logicalName =
  CascadeRetainedSlotWireRequest
    { cascadeRetainedSlotWireRequestVersion =
        cascadeRetainedSlotEndpointFormatVersion
    , cascadeRetainedSlotWireRequestLogicalName = logicalName
    , cascadeRetainedSlotWireRequestOperation =
        CascadeRetainedSlotObserveOperation
    }

cascadeRetainedSlotInitializeWireRequestInternal
  :: Text -> ByteString -> CascadeRetainedSlotWireRequest
cascadeRetainedSlotInitializeWireRequestInternal logicalName value =
  CascadeRetainedSlotWireRequest
    { cascadeRetainedSlotWireRequestVersion =
        cascadeRetainedSlotEndpointFormatVersion
    , cascadeRetainedSlotWireRequestLogicalName = logicalName
    , cascadeRetainedSlotWireRequestOperation =
        CascadeRetainedSlotInitializeOperation value
    }

-- | An observation, carried whole.
--
-- Missing, corrupt, endpoint-unready, and unobservable stay four answers
-- across the wire for the same reason they are four answers at the adapter: a
-- slot that holds nothing and a slot that could not be read say opposite
-- things about whether the cascade may proceed.
data CascadeRetainedSlotWireObservation
  = CascadeRetainedSlotWireMissing
  | CascadeRetainedSlotWireObserved !Text !ByteString
  | CascadeRetainedSlotWireCorrupt !Text
  | CascadeRetainedSlotWireEndpointUnready !Text
  | CascadeRetainedSlotWireUnobservable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | A compare-and-swap result.
--
-- The applied arm carries only the object version: the bytes that were applied
-- are the bytes the caller sent, and echoing them back would invite a client
-- that believed the echo over its own request.  A conflict does carry the
-- observed value, because telling an exact replay from a genuine disagreement
-- is precisely what the repositories use it for.
data CascadeRetainedSlotWireCas
  = CascadeRetainedSlotWireApplied !Text
  | CascadeRetainedSlotWireConflict !CascadeRetainedSlotWireObservation
  | CascadeRetainedSlotWireRefusedCorrupt !Text
  | CascadeRetainedSlotWireCasEndpointUnready !Text
  | CascadeRetainedSlotWireCasUnobservable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CascadeRetainedSlotWireOutcome
  = CascadeRetainedSlotWireObservedOutcome !CascadeRetainedSlotWireObservation
  | CascadeRetainedSlotWireWrittenOutcome !CascadeRetainedSlotWireCas
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CascadeRetainedSlotWireRefusal
  = CascadeRetainedSlotWireRequestTooLarge
  | CascadeRetainedSlotWireRequestInvalid
  | CascadeRetainedSlotWireRequestUnsupportedVersion
  | CascadeRetainedSlotWireRequestNonCanonical
  | CascadeRetainedSlotWireNameRefused !Text
  | CascadeRetainedSlotWireValueInvalid !Text
  | CascadeRetainedSlotWireCoordinateInvalid !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CascadeRetainedSlotWireResponse
  = CascadeRetainedSlotWireCompleted
      !Word16
      !ByteString
      !CascadeRetainedSlotWireOutcome
  | CascadeRetainedSlotWireRefused
      !Word16
      !ByteString
      !CascadeRetainedSlotWireRefusal
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- ---------------------------------------------------------------------------
-- Serving
-- ---------------------------------------------------------------------------

newtype CascadeRetainedSlotEndpointHandler m
  = CascadeRetainedSlotEndpointHandler
      ( ValidCascadeRetainedSlotRequest
        -> ByteString
        -> m CascadeRetainedSlotWireResponse
      )

-- | A request that has already passed the closed namespace and the value
-- bound.  The family it admitted under travels with it so a handler can never
-- re-derive a different one.
data ValidCascadeRetainedSlotRequest = ValidCascadeRetainedSlotRequest
  { validCascadeRetainedSlotFamily :: !CascadeRetainedSlotFamily
  , validCascadeRetainedSlotLogicalName :: !Text
  , validCascadeRetainedSlotOperation :: !CascadeRetainedSlotWireOperation
  }

newtype CascadeRetainedSlotEndpointResult
  = CascadeRetainedSlotEndpointResult CascadeRetainedSlotWireResponse
  deriving stock (Eq, Show)

cascadeRetainedSlotEndpointFormatVersion :: Word16
cascadeRetainedSlotEndpointFormatVersion = 1

cascadeRetainedSlotEndpointMaximumBytes :: Int
cascadeRetainedSlotEndpointMaximumBytes = 192 * 1024

cascadeRetainedSlotEndpointResponseMaximumBytes :: Int
cascadeRetainedSlotEndpointResponseMaximumBytes = 192 * 1024

-- | The canonical bound on one retained slot's bytes.
--
-- Every slot in this namespace is a small canonical record — an accepted
-- readiness, a report identity, a permit — so the bound is far below the
-- Authority's own object limit.  A value that needs more than this is not a
-- cascade slot.
maximumCascadeRetainedSlotValueBytes :: Int
maximumCascadeRetainedSlotValueBytes = 128 * 1024

-- | The Authority-side codec for a cascade slot: canonical bytes, bounded, in
-- both directions.  Nothing about the value is interpreted here, because the
-- meaning of each family's bytes belongs to its repository.
cascadeRetainedSlotModelBCodec :: ModelBCodec ByteString
cascadeRetainedSlotModelBCodec =
  ModelBCodec
    { encodeModelBValue = validateSlotBytes
    , decodeModelBValue = validateSlotBytes
    }

validateSlotBytes :: ByteString -> Either String ByteString
validateSlotBytes bytes
  | ByteString.null bytes = Left "a cascade retained slot value is empty"
  | ByteString.length bytes > maximumCascadeRetainedSlotValueBytes =
      Left "a cascade retained slot value exceeds its canonical bound"
  | otherwise = Right bytes

-- | The Authority's handler.
--
-- The coordinate is built here, from the authority this process was
-- configured with, and never from anything the request carried.
lifecycleAuthorityCascadeRetainedSlotEndpointHandlerInternal
  :: (Monad m)
  => LongLivedCheckpointAuthority
  -> ModelBCasAdapter 'ClusterRetained m ByteString
  -> CascadeRetainedSlotEndpointHandler m
lifecycleAuthorityCascadeRetainedSlotEndpointHandlerInternal authority adapter =
  CascadeRetainedSlotEndpointHandler
    (performAdmittedCascadeRetainedSlot authority adapter)

-- | Perform one admitted slot operation.
--
-- The coordinate is derived here, from the authority this process was
-- configured with, so nothing the request carried can influence which object
-- is addressed.
performAdmittedCascadeRetainedSlot
  :: (Monad m)
  => LongLivedCheckpointAuthority
  -> ModelBCasAdapter 'ClusterRetained m ByteString
  -> ValidCascadeRetainedSlotRequest
  -> ByteString
  -> m CascadeRetainedSlotWireResponse
performAdmittedCascadeRetainedSlot authority adapter request requestDigest =
  case mkClusterRetainedCoordinate
    authority
    (validCascadeRetainedSlotLogicalName request) of
    Left err ->
      pure
        ( refused
            requestDigest
            ( CascadeRetainedSlotWireCoordinateInvalid
                (bounded (Text.pack (show err)))
            )
        )
    Right coordinate ->
      performCoordinateOperation
        adapter
        coordinate
        (validCascadeRetainedSlotOperation request)
        requestDigest

performCoordinateOperation
  :: (Monad m)
  => ModelBCasAdapter 'ClusterRetained m ByteString
  -> ModelBObjectCoordinate 'ClusterRetained
  -> CascadeRetainedSlotWireOperation
  -> ByteString
  -> m CascadeRetainedSlotWireResponse
performCoordinateOperation adapter coordinate operation requestDigest =
  case operation of
    CascadeRetainedSlotObserveOperation -> do
      observed <- modelBObserve adapter coordinate
      pure
        ( completed
            ( CascadeRetainedSlotWireObservedOutcome
                (observationToWire observed)
            )
        )
    CascadeRetainedSlotInitializeOperation value -> do
      applied <- modelBCompareAndSwap adapter (ModelBInitialize coordinate value)
      pure
        (completed (CascadeRetainedSlotWireWrittenOutcome (casToWire applied)))
 where
  completed =
    CascadeRetainedSlotWireCompleted
      cascadeRetainedSlotEndpointFormatVersion
      requestDigest

observationToWire
  :: ModelBObservation ByteString -> CascadeRetainedSlotWireObservation
observationToWire = \case
  ModelBMissing -> CascadeRetainedSlotWireMissing
  ModelBObserved version value ->
    CascadeRetainedSlotWireObserved (modelBObjectVersionText version) value
  ModelBCorrupt detail -> CascadeRetainedSlotWireCorrupt (bounded detail)
  ModelBEndpointUnready detail ->
    CascadeRetainedSlotWireEndpointUnready (bounded detail)
  ModelBUnobservable detail ->
    CascadeRetainedSlotWireUnobservable (bounded detail)

casToWire :: ModelBCasResult ByteString -> CascadeRetainedSlotWireCas
casToWire = \case
  ModelBCasApplied version _ ->
    CascadeRetainedSlotWireApplied (modelBObjectVersionText version)
  ModelBCasConflict observed ->
    CascadeRetainedSlotWireConflict (observationToWire observed)
  ModelBCasRefusedCorrupt detail ->
    CascadeRetainedSlotWireRefusedCorrupt (bounded detail)
  ModelBCasEndpointUnready detail ->
    CascadeRetainedSlotWireCasEndpointUnready (bounded detail)
  ModelBCasUnobservable detail ->
    CascadeRetainedSlotWireCasUnobservable (bounded detail)

serveCascadeRetainedSlotEndpointRequest
  :: (Monad m)
  => CascadeRetainedSlotEndpointHandler m
  -> LazyByteString.ByteString
  -> m CascadeRetainedSlotEndpointResult
serveCascadeRetainedSlotEndpointRequest
  (CascadeRetainedSlotEndpointHandler handle)
  requestBytes = do
    let requestDigest = hexSha256 (LazyByteString.toStrict requestBytes)
    response <-
      case decodeControlPlaneRequest
        cascadeRetainedSlotEndpointMaximumBytes
        requestBytes of
        Left err -> pure (codecRefusal requestDigest err)
        Right request -> case validateRequest request of
          Left refusal -> pure (refused requestDigest refusal)
          Right valid -> handle valid requestDigest
    pure (CascadeRetainedSlotEndpointResult response)

validateRequest
  :: CascadeRetainedSlotWireRequest
  -> Either CascadeRetainedSlotWireRefusal ValidCascadeRetainedSlotRequest
validateRequest request = do
  unless
    ( cascadeRetainedSlotWireRequestVersion request
        == cascadeRetainedSlotEndpointFormatVersion
    )
    (Left CascadeRetainedSlotWireRequestUnsupportedVersion)
  family <-
    first
      (CascadeRetainedSlotWireNameRefused . renderCascadeRetainedSlotNameRefusal)
      (admitCascadeRetainedSlotName logicalName)
  case operation of
    CascadeRetainedSlotObserveOperation -> pure ()
    CascadeRetainedSlotInitializeOperation value -> do
      when
        (ByteString.null value)
        (Left (CascadeRetainedSlotWireValueInvalid "slot value is empty"))
      when
        (ByteString.length value > maximumCascadeRetainedSlotValueBytes)
        ( Left
            ( CascadeRetainedSlotWireValueInvalid
                "slot value exceeds the canonical cascade slot bound"
            )
        )
  pure
    ValidCascadeRetainedSlotRequest
      { validCascadeRetainedSlotFamily = family
      , validCascadeRetainedSlotLogicalName = logicalName
      , validCascadeRetainedSlotOperation = operation
      }
 where
  logicalName = cascadeRetainedSlotWireRequestLogicalName request
  operation = cascadeRetainedSlotWireRequestOperation request

codecRefusal
  :: ByteString
  -> ControlPlaneRequestCodecError
  -> CascadeRetainedSlotWireResponse
codecRefusal requestDigest err = refused requestDigest $ case err of
  ControlPlaneRequestTooLarge -> CascadeRetainedSlotWireRequestTooLarge
  ControlPlaneRequestInvalid -> CascadeRetainedSlotWireRequestInvalid
  ControlPlaneRequestUnsupportedVersion ->
    CascadeRetainedSlotWireRequestUnsupportedVersion
  ControlPlaneRequestNonCanonical -> CascadeRetainedSlotWireRequestNonCanonical

refused
  :: ByteString
  -> CascadeRetainedSlotWireRefusal
  -> CascadeRetainedSlotWireResponse
refused requestDigest =
  CascadeRetainedSlotWireRefused
    cascadeRetainedSlotEndpointFormatVersion
    requestDigest

cascadeRetainedSlotEndpointStatus
  :: CascadeRetainedSlotEndpointResult -> ReplyStatus
cascadeRetainedSlotEndpointStatus (CascadeRetainedSlotEndpointResult response) =
  cascadeRetainedSlotWireResponseStatus response

cascadeRetainedSlotWireResponseStatus
  :: CascadeRetainedSlotWireResponse -> ReplyStatus
cascadeRetainedSlotWireResponseStatus = \case
  CascadeRetainedSlotWireCompleted _ _ outcome -> case outcome of
    CascadeRetainedSlotWireObservedOutcome observed -> case observed of
      CascadeRetainedSlotWireMissing -> ReplyOk
      CascadeRetainedSlotWireObserved _ _ -> ReplyOk
      CascadeRetainedSlotWireCorrupt _ -> ReplyConflict
      CascadeRetainedSlotWireEndpointUnready _ -> ReplyServiceUnavailable
      CascadeRetainedSlotWireUnobservable _ -> ReplyServiceUnavailable
    CascadeRetainedSlotWireWrittenOutcome written -> case written of
      CascadeRetainedSlotWireApplied _ -> ReplyOk
      CascadeRetainedSlotWireConflict _ -> ReplyConflict
      CascadeRetainedSlotWireRefusedCorrupt _ -> ReplyConflict
      CascadeRetainedSlotWireCasEndpointUnready _ -> ReplyServiceUnavailable
      CascadeRetainedSlotWireCasUnobservable _ -> ReplyServiceUnavailable
  CascadeRetainedSlotWireRefused _ _ refusal -> case refusal of
    CascadeRetainedSlotWireRequestTooLarge -> ReplyBadRequest
    CascadeRetainedSlotWireRequestInvalid -> ReplyBadRequest
    CascadeRetainedSlotWireRequestUnsupportedVersion -> ReplyBadRequest
    CascadeRetainedSlotWireRequestNonCanonical -> ReplyBadRequest
    -- A name outside the closed namespace is an authorization statement about
    -- what this route may reach, not a malformed request.
    CascadeRetainedSlotWireNameRefused _ -> ReplyForbidden
    CascadeRetainedSlotWireValueInvalid _ -> ReplyBadRequest
    CascadeRetainedSlotWireCoordinateInvalid _ -> ReplyInternalError

cascadeRetainedSlotEndpointBody
  :: CascadeRetainedSlotEndpointResult -> ByteString
cascadeRetainedSlotEndpointBody (CascadeRetainedSlotEndpointResult response) =
  LazyByteString.toStrict (encodeControlPlaneResponse response)

-- ---------------------------------------------------------------------------
-- Confirming a response
-- ---------------------------------------------------------------------------

decodeCascadeRetainedSlotEndpointResponseInternal
  :: ByteString
  -> Either ControlPlaneResponseCodecError CascadeRetainedSlotWireResponse
decodeCascadeRetainedSlotEndpointResponseInternal =
  decodeControlPlaneResponse cascadeRetainedSlotEndpointResponseMaximumBytes
    . LazyByteString.fromStrict

data CascadeRetainedSlotEndpointResponseError
  = CascadeRetainedSlotEndpointResponseVersionMismatch !Word16 !Word16
  | CascadeRetainedSlotEndpointResponseRequestMismatch !ByteString !ByteString
  | CascadeRetainedSlotEndpointResponseRefused !CascadeRetainedSlotWireRefusal
  | -- | The Authority answered a different question from the one asked: an
    -- observation for an initialize, or the reverse.
    CascadeRetainedSlotEndpointResponseOperationMismatch
  deriving stock (Eq, Show)

-- | Bind a response to the exact request that produced it.
--
-- The format version and the request digest are both checked, and the outcome
-- shape is checked against the operation that was issued, so a response that
-- belongs to another call cannot be read as this call's answer.
confirmCascadeRetainedSlotResponseInternal
  :: CascadeRetainedSlotWireRequest
  -> CascadeRetainedSlotWireResponse
  -> Either
       CascadeRetainedSlotEndpointResponseError
       CascadeRetainedSlotWireOutcome
confirmCascadeRetainedSlotResponseInternal request response = do
  let expectedDigest =
        hexSha256 (LazyByteString.toStrict (encodeControlPlaneRequest request))
      confirmBinding version actualDigest = do
        unless
          (version == cascadeRetainedSlotEndpointFormatVersion)
          ( Left
              ( CascadeRetainedSlotEndpointResponseVersionMismatch
                  cascadeRetainedSlotEndpointFormatVersion
                  version
              )
          )
        unless
          (actualDigest == expectedDigest)
          ( Left
              ( CascadeRetainedSlotEndpointResponseRequestMismatch
                  expectedDigest
                  actualDigest
              )
          )
  case response of
    CascadeRetainedSlotWireCompleted version actualDigest outcome -> do
      confirmBinding version actualDigest
      case (cascadeRetainedSlotWireRequestOperation request, outcome) of
        ( CascadeRetainedSlotObserveOperation
          , CascadeRetainedSlotWireObservedOutcome _
          ) -> Right outcome
        ( CascadeRetainedSlotInitializeOperation _
          , CascadeRetainedSlotWireWrittenOutcome _
          ) -> Right outcome
        _ -> Left CascadeRetainedSlotEndpointResponseOperationMismatch
    CascadeRetainedSlotWireRefused version actualDigest refusal -> do
      confirmBinding version actualDigest
      Left (CascadeRetainedSlotEndpointResponseRefused refusal)

bounded :: Text -> Text
bounded = Text.take 1024

-- ---------------------------------------------------------------------------
-- Regression over the closed namespace
-- ---------------------------------------------------------------------------

-- | Fixed, non-authorizing endpoint regression.  Only booleans cross the
-- public facade; the wire constructors, the handler, and the slot bytes stay
-- confined to this hidden module.
data CascadeRetainedSlotEndpointRegression = CascadeRetainedSlotEndpointRegression
  { cascadeRetainedSlotEndpointAdmitsExactlyTheCascadeNamespaces :: !Bool
  , cascadeRetainedSlotEndpointForeignNameNoExecution :: !Bool
  , cascadeRetainedSlotEndpointMalformedSuffixNoExecution :: !Bool
  , cascadeRetainedSlotEndpointMalformedNoExecution :: !Bool
  , cascadeRetainedSlotEndpointOversizeNoExecution :: !Bool
  , cascadeRetainedSlotEndpointUnsupportedVersionNoExecution :: !Bool
  , cascadeRetainedSlotEndpointOversizeValueNoExecution :: !Bool
  , cascadeRetainedSlotEndpointConflictCarriesObservedBytes :: !Bool
  , cascadeRetainedSlotEndpointAllArmsValidateRequestDigest :: !Bool
  }

fixedCascadeRetainedSlotEndpointRegression
  :: IO CascadeRetainedSlotEndpointRegression
fixedCascadeRetainedSlotEndpointRegression = do
  executions <- newIORef (0 :: Int)
  let handler =
        CascadeRetainedSlotEndpointHandler $ \_ digest -> do
          modifyIORef' executions (+ 1)
          pure
            ( CascadeRetainedSlotWireCompleted
                cascadeRetainedSlotEndpointFormatVersion
                digest
                ( CascadeRetainedSlotWireObservedOutcome
                    CascadeRetainedSlotWireMissing
                )
            )
      serve = serveCascadeRetainedSlotEndpointRequest handler
      readinessRequest =
        cascadeRetainedSlotObserveWireRequestInternal readinessName
  _valid <- serve (encodeControlPlaneRequest readinessRequest)
  validCount <- readIORef executions
  _foreign <-
    serve
      ( encodeControlPlaneRequest
          (cascadeRetainedSlotObserveWireRequestInternal "authority/admission")
      )
  foreignCount <- readIORef executions
  _malformedSuffix <-
    serve
      ( encodeControlPlaneRequest
          ( cascadeRetainedSlotObserveWireRequestInternal
              ( cascadeRetainedSlotFamilyPrefix CascadeHostCleanupReadinessSlot
                  <> "../admission"
              )
          )
      )
  malformedSuffixCount <- readIORef executions
  _malformed <- serve (LazyByteString.singleton 0)
  malformedCount <- readIORef executions
  _oversize <-
    serve
      ( LazyByteString.replicate
          (fromIntegral cascadeRetainedSlotEndpointMaximumBytes + 1)
          0
      )
  oversizeCount <- readIORef executions
  _unsupported <-
    serve
      ( encodeControlPlaneRequest
          readinessRequest
            { cascadeRetainedSlotWireRequestVersion =
                cascadeRetainedSlotEndpointFormatVersion + 1
            }
      )
  unsupportedCount <- readIORef executions
  _oversizeValue <-
    serve
      ( encodeControlPlaneRequest
          ( cascadeRetainedSlotInitializeWireRequestInternal
              readinessName
              (ByteString.replicate (maximumCascadeRetainedSlotValueBytes + 1) 0)
          )
      )
  oversizeValueCount <- readIORef executions
  pure
    CascadeRetainedSlotEndpointRegression
      { -- The route's namespace is the repositories' namespace: these are the
        -- names they derive, not names re-authored here.
        cascadeRetainedSlotEndpointAdmitsExactlyTheCascadeNamespaces =
          and
            [ admitCascadeRetainedSlotName readinessName
                == Right CascadeHostCleanupReadinessSlot
            , admitCascadeRetainedSlotName reportName
                == Right CascadePreUninstallReportSlot
            , admitCascadeRetainedSlotName permitName
                == Right CascadeLocalCompletionPermitSlot
            , length (distinctFamilies [readinessName, reportName, permitName])
                == 3
            , all
                isForeignSlotName
                [ "authority/admission"
                , "authority/cleanup-runs/index"
                , "authority/decommission-manifest"
                , ""
                ]
            ]
      , -- A name outside the namespace never reaches the object store.
        cascadeRetainedSlotEndpointForeignNameNoExecution =
          validCount == 1 && foreignCount == 1
      , cascadeRetainedSlotEndpointMalformedSuffixNoExecution =
          malformedSuffixCount == 1
      , cascadeRetainedSlotEndpointMalformedNoExecution = malformedCount == 1
      , cascadeRetainedSlotEndpointOversizeNoExecution = oversizeCount == 1
      , cascadeRetainedSlotEndpointUnsupportedVersionNoExecution =
          unsupportedCount == 1
      , cascadeRetainedSlotEndpointOversizeValueNoExecution =
          oversizeValueCount == 1
      , -- A conflict is the answer that tells an exact replay from a genuine
        -- disagreement, so it has to carry what is already in the slot.
        cascadeRetainedSlotEndpointConflictCarriesObservedBytes =
          casToWire
            ( ModelBCasConflict
                (ModelBObserved conflictVersion "already-durable-bytes")
            )
            == CascadeRetainedSlotWireConflict
              ( CascadeRetainedSlotWireObserved
                  (modelBObjectVersionText conflictVersion)
                  "already-durable-bytes"
              )
      , -- Every arm of the response, refusal included, is bound to the exact
        -- request digest and format version.
        cascadeRetainedSlotEndpointAllArmsValidateRequestDigest =
          all
            binds
            [ CascadeRetainedSlotWireCompleted
                cascadeRetainedSlotEndpointFormatVersion
                readinessDigest
                ( CascadeRetainedSlotWireObservedOutcome
                    CascadeRetainedSlotWireMissing
                )
            , CascadeRetainedSlotWireRefused
                cascadeRetainedSlotEndpointFormatVersion
                readinessDigest
                (CascadeRetainedSlotWireNameRefused "refused")
            ]
      }
 where
  readinessName = case mkCleanupRunId "cascade-retained-slot-regression-run" of
    Right runId -> hostCleanupReadinessAuthorityLogicalName runId
    Left _ -> ""
  reportName = case mkCleanupRunId "cascade-retained-slot-regression-run" of
    Right runId -> cascadeReportAuthorityLogicalName runId
    Left _ -> ""
  permitName = case mkCleanupRunId "cascade-retained-slot-regression-run" of
    Right runId -> cascadeCompletionPermitAuthorityLogicalName runId
    Left _ -> ""

  readinessRequestBytes =
    encodeControlPlaneRequest
      (cascadeRetainedSlotObserveWireRequestInternal readinessName)
  readinessDigest = hexSha256 (LazyByteString.toStrict readinessRequestBytes)

  conflictVersion = case mkModelBObjectVersion "conflict-version" of
    Right version -> version
    Left _ -> fallbackVersion

  binds response =
    let confirmed =
          confirmCascadeRetainedSlotResponseInternal
            (cascadeRetainedSlotObserveWireRequestInternal readinessName)
            response
        wrongDigest =
          confirmCascadeRetainedSlotResponseInternal
            (cascadeRetainedSlotObserveWireRequestInternal readinessName)
            (withDigest response (ByteString.replicate 64 0))
        wrongVersion =
          confirmCascadeRetainedSlotResponseInternal
            (cascadeRetainedSlotObserveWireRequestInternal readinessName)
            (withVersion response (cascadeRetainedSlotEndpointFormatVersion + 1))
     in isRequestMismatch wrongDigest
          && isVersionMismatch wrongVersion
          && confirmedShapeMatches response confirmed

confirmedShapeMatches
  :: CascadeRetainedSlotWireResponse
  -> Either
       CascadeRetainedSlotEndpointResponseError
       CascadeRetainedSlotWireOutcome
  -> Bool
confirmedShapeMatches response confirmed = case (response, confirmed) of
  (CascadeRetainedSlotWireCompleted _ _ outcome, Right actual) -> outcome == actual
  ( CascadeRetainedSlotWireRefused {}
    , Left (CascadeRetainedSlotEndpointResponseRefused _)
    ) -> True
  _ -> False

isRequestMismatch
  :: Either
       CascadeRetainedSlotEndpointResponseError
       CascadeRetainedSlotWireOutcome
  -> Bool
isRequestMismatch = \case
  Left (CascadeRetainedSlotEndpointResponseRequestMismatch _ _) -> True
  _ -> False

isVersionMismatch
  :: Either
       CascadeRetainedSlotEndpointResponseError
       CascadeRetainedSlotWireOutcome
  -> Bool
isVersionMismatch = \case
  Left (CascadeRetainedSlotEndpointResponseVersionMismatch _ _) -> True
  _ -> False

withDigest
  :: CascadeRetainedSlotWireResponse
  -> ByteString
  -> CascadeRetainedSlotWireResponse
withDigest response digest = case response of
  CascadeRetainedSlotWireCompleted version _ outcome ->
    CascadeRetainedSlotWireCompleted version digest outcome
  CascadeRetainedSlotWireRefused version _ refusal ->
    CascadeRetainedSlotWireRefused version digest refusal

withVersion
  :: CascadeRetainedSlotWireResponse
  -> Word16
  -> CascadeRetainedSlotWireResponse
withVersion response version = case response of
  CascadeRetainedSlotWireCompleted _ digest outcome ->
    CascadeRetainedSlotWireCompleted version digest outcome
  CascadeRetainedSlotWireRefused _ digest refusal ->
    CascadeRetainedSlotWireRefused version digest refusal

-- | A version value the regression can name without an object store.  It is
-- only ever compared with itself.
fallbackVersion :: ModelBObjectVersion
fallbackVersion = case mkModelBObjectVersion "v" of
  Right version -> version
  Left _ -> fallbackVersion

-- | A name the closed namespace does not reach at all.
isForeignSlotName :: Text -> Bool
isForeignSlotName name = case admitCascadeRetainedSlotName name of
  Left (CascadeRetainedSlotNameForeign _) -> True
  _ -> False

distinctFamilies :: [Text] -> [CascadeRetainedSlotFamily]
distinctFamilies = foldr keep []
 where
  keep name seen = case admitCascadeRetainedSlotName name of
    Right family | family `notElem` seen -> family : seen
    _ -> seen
