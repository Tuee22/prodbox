{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed retained-home SMTP/EAB source-custody tombstone operation.
--
-- This is deliberately decommission-only.  It does not define a steady-state
-- writer, ingestion format, rewrap protocol, or Sprint 8.11 SMTP ownership.
-- The two schema coordinates are compiled here and cannot be supplied by a
-- request.  Production observation reads only KV-v2 metadata existence; it
-- never exports custody bytes.  Deletion physically removes all versions and
-- metadata, then accepts only an exact metadata @404@ as absence.
module Prodbox.Lifecycle.Decommission.RetainedCustodyTombstone
  ( RetainedCustodyKind (..)
  , RetainedCustodyCoordinate
  , retainedCustodyCoordinateKind
  , retainedCustodyCoordinateMount
  , retainedCustodyCoordinatePath
  , retainedHomeCustodyCoordinates
  , RetainedCustodyObservation (..)
  , RetainedCustodyEntryBoundary
  , retainedCustodyEntryBoundary
  , RetainedCustodyBoundary
  , RetainedCustodyBoundaryError (..)
  , mkRetainedCustodyBoundary
  , vaultRetainedCustodyBoundary
  , RetainedCustodyTombstoneAction (..)
  , RetainedCustodyTombstoneRequest (..)
  , RetainedCustodyTombstoneError (..)
  , RetainedCustodyTombstoneResult (..)
  , RetainedCustodyTombstoneResponse (..)
  , runRetainedCustodyTombstone
  , runAuthorizedRetainedCustodyKindTombstone
  , serveRetainedCustodyTombstoneRequest
  , retainedCustodyTombstoneHttpStatus
  , retainedCustodyTombstoneResponseBody
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (find, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.Http.Client (HttpError (HttpStatus), renderHttpError)
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Decommission.Frame (FrameDigest)
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionNode (RetainedCustody)
  , SignedDecommissionManifest
  , VerifiedDecommissionManifest
  , manifestNodes
  , verifiedManifestPlan
  , verifySignedDecommissionManifest
  )
import Prodbox.Vault.Client
  ( vaultKvDeleteMetadataV2
  , vaultKvMetadataExistsV2
  )
import Prodbox.Vault.Session
  ( VaultSession
  , sessionAddress
  , withSessionToken
  )

data RetainedCustodyKind
  = RetainedHomeSesSmtpSource
  | RetainedHomeAcmeEabSource
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data RetainedCustodyCoordinate = RetainedCustodyCoordinate
  { retainedCustodyCoordinateKind :: !RetainedCustodyKind
  , retainedCustodyCoordinateMount :: !Text
  , retainedCustodyCoordinatePath :: !Text
  }
  deriving stock (Eq, Ord, Show)

-- | The exact decommission-only source-custody inventory.  These are distinct
-- from selected-target materializations at @keycloak/smtp@ and @acme/eab@.
retainedHomeCustodyCoordinates :: [RetainedCustodyCoordinate]
retainedHomeCustodyCoordinates =
  [ coordinateFor RetainedHomeSesSmtpSource
  , coordinateFor RetainedHomeAcmeEabSource
  ]

data RetainedCustodyObservation
  = RetainedCustodyAbsent
  | RetainedCustodyPresent
  | RetainedCustodyUnobservable !Text
  deriving stock (Eq, Show)

data RetainedCustodyEntryBoundary m = RetainedCustodyEntryBoundary
  { retainedCustodyEntryCoordinate :: !RetainedCustodyCoordinate
  , observeRetainedCustodyEntry :: m RetainedCustodyObservation
  , destroyRetainedCustodyEntry :: m (Either Text ())
  }

-- | Injectable exact-kind seam for tests.  The kind selects the compiled
-- coordinate; callers cannot inject a mount or path.
retainedCustodyEntryBoundary
  :: RetainedCustodyKind
  -> m RetainedCustodyObservation
  -> m (Either Text ())
  -> RetainedCustodyEntryBoundary m
retainedCustodyEntryBoundary kind observe destroy =
  RetainedCustodyEntryBoundary
    { retainedCustodyEntryCoordinate = coordinateFor kind
    , observeRetainedCustodyEntry = observe
    , destroyRetainedCustodyEntry = destroy
    }

newtype RetainedCustodyBoundary m
  = RetainedCustodyBoundary [RetainedCustodyEntryBoundary m]

data RetainedCustodyBoundaryError
  = RetainedCustodyBoundaryIncomplete
      ![RetainedCustodyKind]
      ![RetainedCustodyKind]
  deriving stock (Eq, Show)

mkRetainedCustodyBoundary
  :: [RetainedCustodyEntryBoundary m]
  -> Either RetainedCustodyBoundaryError (RetainedCustodyBoundary m)
mkRetainedCustodyBoundary entries
  | actual == expected = Right (RetainedCustodyBoundary entries)
  | otherwise = Left (RetainedCustodyBoundaryIncomplete expected actual)
 where
  expected = sort (map retainedCustodyCoordinateKind retainedHomeCustodyCoordinates)
  actual = sort (map (retainedCustodyCoordinateKind . retainedCustodyEntryCoordinate) entries)

vaultRetainedCustodyBoundary
  :: VaultSession
  -> Either RetainedCustodyBoundaryError (RetainedCustodyBoundary IO)
vaultRetainedCustodyBoundary session =
  mkRetainedCustodyBoundary (map productionEntry retainedHomeCustodyCoordinates)
 where
  productionEntry coordinate =
    RetainedCustodyEntryBoundary
      { retainedCustodyEntryCoordinate = coordinate
      , observeRetainedCustodyEntry = observe coordinate
      , destroyRetainedCustodyEntry = destroy coordinate
      }
  observe coordinate = do
    result <-
      withSessionToken session $ \token ->
        vaultKvMetadataExistsV2
          (sessionAddress session)
          token
          (retainedCustodyCoordinateMount coordinate)
          (retainedCustodyCoordinatePath coordinate)
    pure $ case result of
      Right () -> RetainedCustodyPresent
      Left (HttpStatus 404 _) -> RetainedCustodyAbsent
      Left err ->
        RetainedCustodyUnobservable (Text.pack (renderHttpError err))
  destroy coordinate = do
    result <-
      withSessionToken session $ \token ->
        vaultKvDeleteMetadataV2
          (sessionAddress session)
          token
          (retainedCustodyCoordinateMount coordinate)
          (retainedCustodyCoordinatePath coordinate)
    pure (first (Text.pack . renderHttpError) result)

data RetainedCustodyTombstoneAction
  = ObserveRetainedCustodyAbsence
  | DestroyRetainedCustody
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RetainedCustodyTombstoneRequest = RetainedCustodyTombstoneRequest
  { retainedCustodyTombstoneManifest :: !SignedDecommissionManifest
  , retainedCustodyTombstoneAction :: !RetainedCustodyTombstoneAction
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RetainedCustodyTombstoneError
  = RetainedCustodyTombstoneBadRequest !ControlPlaneRequestCodecError
  | RetainedCustodyTombstoneManifestInvalid !Text
  | RetainedCustodyTombstoneNodeNotAuthorized
  | RetainedCustodyTombstoneObservationUnavailable !Text
  | RetainedCustodyTombstoneDeleteNotConfirmed !Text
  deriving stock (Eq, Show)

data RetainedCustodyTombstoneResult
  = RetainedCustodyAlreadyAbsent
  | RetainedCustodyPresentResult
  | RetainedCustodyDestroyedAndReadBack
  | RetainedCustodyTombstoneRefused !RetainedCustodyTombstoneError
  deriving stock (Eq, Show)

data RetainedCustodyTombstoneResponse
  = RetainedCustodyResponseAlreadyAbsent
  | RetainedCustodyResponsePresent
  | RetainedCustodyResponseDestroyed
  | RetainedCustodyResponseRefused !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

runRetainedCustodyTombstone
  :: (Monad m)
  => VerifiedDecommissionManifest
  -> RetainedCustodyBoundary m
  -> RetainedCustodyTombstoneAction
  -> m RetainedCustodyTombstoneResult
runRetainedCustodyTombstone verified boundary action
  | RetainedCustody `notElem` manifestNodes (verifiedManifestPlan verified) =
      pure
        ( RetainedCustodyTombstoneRefused
            RetainedCustodyTombstoneNodeNotAuthorized
        )
  | otherwise = do
      before <- observeBoundary boundary
      case unavailableDetails before of
        details@(_ : _) -> refuseObservation details
        []
          | allAbsent before -> pure RetainedCustodyAlreadyAbsent
          | action == ObserveRetainedCustodyAbsence ->
              pure RetainedCustodyPresentResult
          | otherwise -> destroyAndConfirm before
 where
  destroyAndConfirm before = do
    attempts <- traverse destroyIfPresent before
    after <- observeBoundary boundary
    pure $ case (unavailableDetails after, remainingKinds after) of
      ([], []) -> RetainedCustodyDestroyedAndReadBack
      (unavailable@(_ : _), _) ->
        RetainedCustodyTombstoneRefused
          ( RetainedCustodyTombstoneDeleteNotConfirmed
              (attemptDetails attempts <> renderUnavailable unavailable)
          )
      ([], remaining) ->
        RetainedCustodyTombstoneRefused
          ( RetainedCustodyTombstoneDeleteNotConfirmed
              ( attemptDetails attempts
                  <> "retained custody metadata remains: "
                  <> renderKinds remaining
              )
          )

  destroyIfPresent (entry, observation) = case observation of
    RetainedCustodyPresent -> do
      result <- destroyRetainedCustodyEntry entry
      pure (retainedCustodyCoordinateKind (retainedCustodyEntryCoordinate entry), result)
    _ ->
      pure
        ( retainedCustodyCoordinateKind (retainedCustodyEntryCoordinate entry)
        , Right ()
        )

  refuseObservation details =
    pure
      ( RetainedCustodyTombstoneRefused
          (RetainedCustodyTombstoneObservationUnavailable (renderUnavailable details))
      )

-- | Execute one exact custody kind after a disjoint proof-family endpoint has
-- already authorized it.  Admin Action uses only
-- 'RetainedHomeSesSmtpSource'; total decommission retains the all-kind program
-- above and is not weakened into this proof family.
runAuthorizedRetainedCustodyKindTombstone
  :: (Monad m)
  => RetainedCustodyBoundary m
  -> RetainedCustodyKind
  -> RetainedCustodyTombstoneAction
  -> m RetainedCustodyTombstoneResult
runAuthorizedRetainedCustodyKindTombstone
  (RetainedCustodyBoundary entries)
  kind
  action =
    case find ((== kind) . retainedCustodyCoordinateKind . retainedCustodyEntryCoordinate) entries of
      Nothing ->
        pure
          ( RetainedCustodyTombstoneRefused
              (RetainedCustodyTombstoneObservationUnavailable "custody kind is not registered")
          )
      Just entry -> do
        before <- observeRetainedCustodyEntry entry
        case before of
          RetainedCustodyAbsent -> pure RetainedCustodyAlreadyAbsent
          RetainedCustodyUnobservable detail ->
            pure
              ( RetainedCustodyTombstoneRefused
                  (RetainedCustodyTombstoneObservationUnavailable detail)
              )
          RetainedCustodyPresent
            | action == ObserveRetainedCustodyAbsence ->
                pure RetainedCustodyPresentResult
            | otherwise -> do
                attempted <- destroyRetainedCustodyEntry entry
                after <- observeRetainedCustodyEntry entry
                pure $ case after of
                  RetainedCustodyAbsent -> RetainedCustodyDestroyedAndReadBack
                  RetainedCustodyPresent ->
                    refusedDelete attempted "retained custody metadata remains"
                  RetainedCustodyUnobservable detail ->
                    refusedDelete attempted detail
   where
    refusedDelete attempted detail =
      RetainedCustodyTombstoneRefused
        ( RetainedCustodyTombstoneDeleteNotConfirmed
            ( case attempted of
                Left applyDetail ->
                  "delete response unavailable: " <> applyDetail <> "; " <> detail
                Right () -> detail
            )
        )

serveRetainedCustodyTombstoneRequest
  :: (Monad m)
  => Int
  -> FrameDigest
  -> RetainedCustodyBoundary m
  -> LazyByteString.ByteString
  -> m RetainedCustodyTombstoneResult
serveRetainedCustodyTombstoneRequest maximumBytes expectedSigner boundary body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err ->
      pure
        ( RetainedCustodyTombstoneRefused
            (RetainedCustodyTombstoneBadRequest err)
        )
    Right request ->
      case verifySignedDecommissionManifest
        expectedSigner
        (retainedCustodyTombstoneManifest request) of
        Left err ->
          pure
            ( RetainedCustodyTombstoneRefused
                (RetainedCustodyTombstoneManifestInvalid (Text.pack (show err)))
            )
        Right verified ->
          runRetainedCustodyTombstone
            verified
            boundary
            (retainedCustodyTombstoneAction request)

retainedCustodyTombstoneHttpStatus :: RetainedCustodyTombstoneResult -> ReplyStatus
retainedCustodyTombstoneHttpStatus result = case result of
  RetainedCustodyAlreadyAbsent -> ReplyOk
  RetainedCustodyPresentResult -> ReplyOk
  RetainedCustodyDestroyedAndReadBack -> ReplyOk
  RetainedCustodyTombstoneRefused err -> case err of
    RetainedCustodyTombstoneBadRequest _ -> ReplyBadRequest
    RetainedCustodyTombstoneManifestInvalid _ -> ReplyForbidden
    RetainedCustodyTombstoneNodeNotAuthorized -> ReplyForbidden
    RetainedCustodyTombstoneObservationUnavailable _ -> ReplyServiceUnavailable
    RetainedCustodyTombstoneDeleteNotConfirmed _ -> ReplyServiceUnavailable

retainedCustodyTombstoneResponseBody
  :: RetainedCustodyTombstoneResult
  -> ByteString
retainedCustodyTombstoneResponseBody result =
  LazyByteString.toStrict
    ( encodeControlPlaneResponse $ case result of
        RetainedCustodyAlreadyAbsent -> RetainedCustodyResponseAlreadyAbsent
        RetainedCustodyPresentResult -> RetainedCustodyResponsePresent
        RetainedCustodyDestroyedAndReadBack -> RetainedCustodyResponseDestroyed
        RetainedCustodyTombstoneRefused err ->
          RetainedCustodyResponseRefused (summary err)
    )
 where
  summary err = case err of
    RetainedCustodyTombstoneBadRequest _ -> "retained-custody-bad-request"
    RetainedCustodyTombstoneManifestInvalid _ -> "retained-custody-manifest-invalid"
    RetainedCustodyTombstoneNodeNotAuthorized -> "retained-custody-not-authorized"
    RetainedCustodyTombstoneObservationUnavailable _ -> "retained-custody-unobservable"
    RetainedCustodyTombstoneDeleteNotConfirmed _ -> "retained-custody-delete-unconfirmed"

coordinateFor :: RetainedCustodyKind -> RetainedCustodyCoordinate
coordinateFor kind = case kind of
  RetainedHomeSesSmtpSource ->
    RetainedCustodyCoordinate
      RetainedHomeSesSmtpSource
      "secret"
      "target-agent/retained-home/ses-smtp-source"
  RetainedHomeAcmeEabSource ->
    RetainedCustodyCoordinate
      RetainedHomeAcmeEabSource
      "secret"
      "target-agent/retained-home/acme-eab-source"

observeBoundary
  :: (Monad m)
  => RetainedCustodyBoundary m
  -> m [(RetainedCustodyEntryBoundary m, RetainedCustodyObservation)]
observeBoundary (RetainedCustodyBoundary entries) =
  traverse observeEntry entries
 where
  observeEntry entry = do
    observation <- observeRetainedCustodyEntry entry
    pure (entry, observation)

allAbsent
  :: [(RetainedCustodyEntryBoundary m, RetainedCustodyObservation)]
  -> Bool
allAbsent = all ((== RetainedCustodyAbsent) . snd)

remainingKinds
  :: [(RetainedCustodyEntryBoundary m, RetainedCustodyObservation)]
  -> [RetainedCustodyKind]
remainingKinds observed =
  [ retainedCustodyCoordinateKind (retainedCustodyEntryCoordinate entry)
  | (entry, RetainedCustodyPresent) <- observed
  ]

unavailableDetails
  :: [(RetainedCustodyEntryBoundary m, RetainedCustodyObservation)]
  -> [(RetainedCustodyKind, Text)]
unavailableDetails observed =
  [ (retainedCustodyCoordinateKind (retainedCustodyEntryCoordinate entry), detail)
  | (entry, RetainedCustodyUnobservable detail) <- observed
  ]

attemptDetails :: [(RetainedCustodyKind, Either Text ())] -> Text
attemptDetails attempts =
  case [(kind, detail) | (kind, Left detail) <- attempts] of
    [] -> ""
    failures -> "delete responses unavailable: " <> renderUnavailable failures <> "; "

renderUnavailable :: [(RetainedCustodyKind, Text)] -> Text
renderUnavailable values =
  Text.intercalate
    ", "
    [Text.pack (show kind) <> "=" <> detail | (kind, detail) <- values]

renderKinds :: [RetainedCustodyKind] -> Text
renderKinds = Text.intercalate ", " . map (Text.pack . show)
