-- | Sprint 4.51 Increment B (Stage A): the ONE shared authority-object CAS core
-- that both the in-cluster gateway daemon and the host-direct CLI delegate to.
--
-- The read / compare-and-swap / lease-guard logic is expressed against an
-- injected 'AuthorityCore' seam whose three object operations are, on both
-- transports, partial applications of the SAME exported
-- @getLogicalVersioned@ / @putLogicalIfAbsent@ / @putLogicalIfVersion@ with each
-- transport's object-store config + DEK cipher + HMAC key + cluster id. Because
-- every logical name is routed through the shared 'authorityLogicalObject' inside
-- this module, and both transports feed the same encrypted-object primitives, the
-- envelopes the daemon and the host CLI read and write are byte-identical BY
-- CONSTRUCTION — the two paths cannot silently diverge into disjoint object sets.
-- This is the byte-compat safety of the retained-authority host-direct cutover:
-- there is no second hand-maintained copy to drift.
module Prodbox.Lifecycle.AuthorityObjectCore
  ( AuthorityCore (..)
  , readAuthorityObjectCore
  , compareAndSwapAuthorityObjectCore
  , validateAuthorityLeaseGuardCore
  )
where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Numeric.Natural (Natural)
import Prodbox.Gateway.ObjectStore
  ( AuthorityObjectCasRequest (..)
  , AuthorityObjectCasResponse (..)
  , AuthorityObjectLeaseGuard (..)
  , AuthorityObjectObservation (..)
  )
import Prodbox.Lifecycle.Lease
  ( authorityTimeFromMicros
  , decodeLeaseProjection
  , defaultSesLeasePolicy
  , fencingTokenValue
  , leaseGrantFencingToken
  , leaseGrantKey
  , leaseGrantOwnerNonce
  , leaseGrantSafeUseDeadline
  , leaseLogicalName
  , leaseProjectionActiveGrant
  , ownerNonceText
  )
import Prodbox.Minio.EncryptedObject
  ( EncryptedObjectError
  , LogicalConditionalPutResult (..)
  , LogicalObject
  , VersionedLogicalObject
  , authorityLogicalObject
  , renderEncryptedObjectError
  , versionedLogicalBytes
  , versionedLogicalStoreVersion
  )
import Prodbox.Minio.ObjectStore (ObjectVersion (ObjectVersion), objectVersionEtag)

-- | The injected authority-object I/O seam. Both the in-cluster daemon and the
-- host-direct CLI build this by partially applying the SAME exported
-- encrypted-object primitives with their object-store config + DEK cipher + HMAC
-- key + cluster id, so the envelopes they read and write are byte-identical.
data AuthorityCore m = AuthorityCore
  { authGetVersioned
      :: !(LogicalObject -> m (Either EncryptedObjectError (Maybe VersionedLogicalObject)))
  , authPutIfAbsent
      :: !(LogicalObject -> ByteString -> m (Either EncryptedObjectError LogicalConditionalPutResult))
  , authPutIfVersion
      :: !( LogicalObject
            -> ObjectVersion
            -> ByteString
            -> m (Either EncryptedObjectError LogicalConditionalPutResult)
          )
  , authNow :: !(m UTCTime)
  }

-- | Read an authority object by its logical name (routed through
-- 'authorityLogicalObject').
readAuthorityObjectCore
  :: (Monad m) => AuthorityCore m -> Text -> m (Either String AuthorityObjectObservation)
readAuthorityObjectCore core logicalName = do
  result <- authGetVersioned core (authorityLogicalObject logicalName)
  pure $ case result of
    Left err -> Left (renderEncryptedObjectError err)
    Right Nothing -> Right AuthorityObjectMissing
    Right (Just versioned) ->
      Right
        ( AuthorityObjectObserved
            (objectVersionEtag (versionedLogicalStoreVersion versioned))
            (versionedLogicalBytes versioned)
        )

-- | Conditional compare-and-swap: optional lease-guard validation, then an
-- if-absent or if-version put, then a MANDATORY re-observation of the store
-- version (never the put's echo).
compareAndSwapAuthorityObjectCore
  :: (Monad m)
  => AuthorityCore m
  -> AuthorityObjectCasRequest
  -> m (Either String AuthorityObjectCasResponse)
compareAndSwapAuthorityObjectCore core request = do
  let logicalObject = authorityLogicalObject (authorityObjectCasLogicalName request)
      payload = authorityObjectCasPayload request
  guardResult <-
    case authorityObjectCasLeaseGuard request of
      Nothing -> pure (Right ())
      Just guard -> validateAuthorityLeaseGuardCore core guard
  case guardResult of
    Left err -> pure (Left err)
    Right () -> do
      casResult <-
        case authorityObjectCasExpectedVersion request of
          Nothing -> authPutIfAbsent core logicalObject payload
          Just version -> authPutIfVersion core logicalObject (ObjectVersion version) payload
      case casResult of
        Left err -> pure (Left (renderEncryptedObjectError err))
        Right disposition -> do
          observed <- authGetVersioned core logicalObject
          pure $ case observed of
            Left err -> Left (renderEncryptedObjectError err)
            Right maybeVersioned -> do
              observation <- authorityObservationFromVersioned maybeVersioned
              case disposition of
                LogicalConditionalPutApplied ->
                  case observation of
                    AuthorityObjectMissing ->
                      Left "authority CAS applied but mandatory re-observation was missing"
                    AuthorityObjectObserved version _ ->
                      Right (AuthorityObjectCasApplied version)
                LogicalConditionalPutConflict ->
                  Right (AuthorityObjectCasConflict observation)

-- | Validate a lease guard against the currently-observed lease projection: the
-- object version, the active grant's key / owner nonce / fencing token, and the
-- safe-use deadline. Uses 'defaultSesLeasePolicy' to decode, exactly as the
-- daemon does.
validateAuthorityLeaseGuardCore
  :: (Monad m) => AuthorityCore m -> AuthorityObjectLeaseGuard -> m (Either String ())
validateAuthorityLeaseGuardCore core guard = do
  observed <- authGetVersioned core (authorityLogicalObject (authorityLeaseGuardLogicalName guard))
  now <- authNow core
  pure $ case observed of
    Left err -> Left ("lease guard observation failed: " ++ renderEncryptedObjectError err)
    Right Nothing -> Left "lease guard rejected: lease projection is missing"
    Right (Just versioned)
      | objectVersionEtag (versionedLogicalStoreVersion versioned)
          /= authorityLeaseGuardExpectedVersion guard ->
          Left "lease guard rejected: lease object version changed"
      | otherwise -> do
          projection <-
            case decodeLeaseProjection defaultSesLeasePolicy (versionedLogicalBytes versioned) of
              Left err -> Left ("lease guard rejected: invalid lease projection: " ++ show err)
              Right value -> Right value
          grant <-
            case leaseProjectionActiveGrant projection of
              Nothing -> Left "lease guard rejected: lease has no active grant"
              Just value -> Right value
          if leaseLogicalName (leaseGrantKey grant) /= authorityLeaseGuardLogicalName guard
            then Left "lease guard rejected: lease key does not match its object coordinate"
            else
              if ownerNonceText (leaseGrantOwnerNonce grant) /= authorityLeaseGuardOwnerNonce guard
                then Left "lease guard rejected: owner nonce changed"
                else
                  if fencingTokenValue (leaseGrantFencingToken grant)
                    /= authorityLeaseGuardFencingToken guard
                    then Left "lease guard rejected: fencing token changed"
                    else
                      if authorityTimeFromMicros (authorityMicrosFromUtc now)
                        >= leaseGrantSafeUseDeadline grant
                        then Left "lease guard rejected: lease safe-use deadline has expired"
                        else Right ()

authorityObservationFromVersioned
  :: Maybe VersionedLogicalObject -> Either String AuthorityObjectObservation
authorityObservationFromVersioned maybeVersioned =
  case maybeVersioned of
    Nothing -> Right AuthorityObjectMissing
    Just versioned ->
      Right
        ( AuthorityObjectObserved
            (objectVersionEtag (versionedLogicalStoreVersion versioned))
            (versionedLogicalBytes versioned)
        )

authorityMicrosFromUtc :: UTCTime -> Natural
authorityMicrosFromUtc now =
  fromInteger (max 0 (floor (utcTimeToPOSIXSeconds now * 1000000) :: Integer))
