{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated, role-indexed clients for the two remote effects in the
-- standalone decommission runner.  The Authority returns the signed manifest;
-- each Target Secret Agent accepts only a target generation already authorized
-- by that manifest and exposes separate destructive and read-only operations.
module Prodbox.ControlPlane.DecommissionClient
  ( AuthorityDecommissionClientError (..)
  , AuthorityDecommissionStopClientError (..)
  , authorityDecommissionMaximumResponseBytes
  , requestAuthorityDecommissionManifest
  , requestAuthorityDecommissionManifestViaTransport
  , enterAuthorityDecommissionPointOfNoReturn
  , enterAuthorityDecommissionPointOfNoReturnViaTransport
  , requestTargetDecommissionInventory
  , targetGenerationTombstoneMaximumResponseBytes
  , targetGenerationTombstoneCapability
  , targetGenerationTombstoneCapabilityViaTransport
  , retainedCustodyTombstoneCapability
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientProviders
  , AuthenticatedClientTransport
  , AuthenticatedTransportBounds
  , callAuthenticatedClientTransport
  , callAuthenticatedControlPlane
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneClient
  , ControlPlaneResponse (..)
  , ControlPlaneRouteFor
    ( LifecycleAuthorityDecommissionExportRoute
    , LifecycleAuthorityDecommissionStopRoute
    , TargetSecretDecommissionCustodyTombstoneRoute
    , TargetSecretDecommissionInventoryRoute
    , TargetSecretDecommissionTombstoneRoute
    )
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityDecommissionExportRequest (..)
  , AuthorityDecommissionExportResponse (..)
  )
import Prodbox.Lifecycle.Decommission.AuthorityStop
  ( AuthorityDecommissionStopRequest (..)
  , AuthorityDecommissionStopResponse (..)
  )
import Prodbox.Lifecycle.Decommission.Frame (FrameDigest)
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionLocalDataDisposition
  , SignedManifestVerificationError
  , VerifiedDecommissionManifest
  , decommissionTargetGenerationValue
  , verifiedSignedManifest
  , verifySignedDecommissionManifest
  )
import Prodbox.Lifecycle.Decommission.NodeEffect
  ( NodeOperation (..)
  , RetainedCustodyTombstoneCapability (..)
  , TargetGenerationTombstoneCapability (..)
  )
import Prodbox.Lifecycle.Decommission.Receipt
  ( AcknowledgedExternalReceipt
  , acknowledgedExternalReceiptHeader
  , acknowledgedExternalReceiptPath
  )
import Prodbox.Lifecycle.Decommission.RetainedCustodyTombstone
  ( RetainedCustodyTombstoneAction (..)
  , RetainedCustodyTombstoneRequest (..)
  , RetainedCustodyTombstoneResponse (..)
  )
import Prodbox.Lifecycle.Decommission.TargetInventory
  ( TargetDecommissionInventory
  , TargetDecommissionInventoryRequest (ObserveTargetDecommissionInventory)
  , TargetDecommissionInventoryResponse (..)
  )
import Prodbox.Lifecycle.Decommission.TargetTombstone
  ( TargetGenerationTombstoneAction (..)
  , TargetGenerationTombstoneCommand (..)
  , TargetGenerationTombstoneRequest (..)
  , TargetGenerationTombstoneResponse (..)
  )
import Prodbox.Lifecycle.Decommission.Verifier
  ( VerifierBinding
  , externalReceiptPath
  )
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueDetails (..)
  , ResidueStatus (..)
  , ResidueUnreachableReason (ResidueQueryFailed)
  )
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime, TargetSecretAgentRuntime)
  )

data AuthorityDecommissionClientError
  = AuthorityDecommissionTransportFailed !AuthenticatedClientError
  | AuthorityDecommissionHttpStatus !Int !ByteString
  | AuthorityDecommissionResponseInvalid !ControlPlaneResponseCodecError
  | AuthorityDecommissionRefused !Text
  | AuthorityDecommissionManifestInvalid !SignedManifestVerificationError
  deriving stock (Eq, Show)

data AuthorityDecommissionStopClientError
  = AuthorityDecommissionStopTransportFailed !AuthenticatedClientError
  | AuthorityDecommissionStopHttpStatus !Int !ByteString
  | AuthorityDecommissionStopResponseInvalid !ControlPlaneResponseCodecError
  | AuthorityDecommissionStopRefused !Text
  deriving stock (Eq, Show)

authorityDecommissionMaximumResponseBytes :: Int
authorityDecommissionMaximumResponseBytes = 4 * 1024 * 1024

-- | Ask the Lifecycle Authority to freeze admission, sign its own plan, and
-- commit it.  A 200 response is still unusable until its signature matches the
-- independently pinned Authority signer digest supplied by the runner.
requestAuthorityDecommissionManifest
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> ControlPlaneClient 'LifecycleAuthorityRuntime
  -> FrameDigest
  -> VerifierBinding
  -> DecommissionLocalDataDisposition
  -> IO
       ( Either
           AuthorityDecommissionClientError
           VerifiedDecommissionManifest
       )
requestAuthorityDecommissionManifest bounds providers client expectedSigner verifier localData = do
  attempted <-
    callAuthenticatedControlPlane
      bounds
      providers
      client
      LifecycleAuthorityDecommissionExportRoute
      ( LazyByteString.toStrict
          ( encodeControlPlaneRequest
              (AuthorityDecommissionExportRequest verifier localData)
          )
      )
  pure (decodeManifestResponse expectedSigner attempted)

requestAuthorityDecommissionManifestViaTransport
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> FrameDigest
  -> VerifierBinding
  -> DecommissionLocalDataDisposition
  -> IO
       ( Either
           AuthorityDecommissionClientError
           VerifiedDecommissionManifest
       )
requestAuthorityDecommissionManifestViaTransport transport expectedSigner verifier localData = do
  attempted <-
    callAuthenticatedClientTransport
      transport
      LifecycleAuthorityDecommissionExportRoute
      ( LazyByteString.toStrict
          ( encodeControlPlaneRequest
              (AuthorityDecommissionExportRequest verifier localData)
          )
      )
  pure (decodeManifestResponse expectedSigner attempted)

decodeManifestResponse
  :: FrameDigest
  -> Either AuthenticatedClientError ControlPlaneResponse
  -> Either AuthorityDecommissionClientError VerifiedDecommissionManifest
decodeManifestResponse expectedSigner attempted = do
  ControlPlaneResponse status responseBody <-
    first AuthorityDecommissionTransportFailed attempted
  if status /= 200
    then Left (AuthorityDecommissionHttpStatus status responseBody)
    else do
      response <-
        first
          AuthorityDecommissionResponseInvalid
          ( decodeControlPlaneResponse
              authorityDecommissionMaximumResponseBytes
              (LazyByteString.fromStrict responseBody)
          )
      case response of
        AuthorityDecommissionExportResponseRefused detail ->
          Left (AuthorityDecommissionRefused detail)
        AuthorityDecommissionExportResponseExported signed ->
          first
            AuthorityDecommissionManifestInvalid
            (verifySignedDecommissionManifest expectedSigner signed)

-- | Commit the Authority's permanent stop after the external receipt has been
-- acknowledged.  The signed manifest, receipt header, and canonical path are
-- all transported so the Authority can independently rebuild the exact
-- acknowledgement digest retained in its admission aggregate.
enterAuthorityDecommissionPointOfNoReturn
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> ControlPlaneClient 'LifecycleAuthorityRuntime
  -> VerifiedDecommissionManifest
  -> AcknowledgedExternalReceipt
  -> IO (Either AuthorityDecommissionStopClientError ())
enterAuthorityDecommissionPointOfNoReturn bounds providers client verified acknowledged = do
  attempted <-
    callAuthenticatedControlPlane
      bounds
      providers
      client
      LifecycleAuthorityDecommissionStopRoute
      ( LazyByteString.toStrict
          ( encodeControlPlaneRequest
              AuthorityDecommissionStopRequest
                { authorityStopManifest = verifiedSignedManifest verified
                , authorityStopReceiptHeader =
                    acknowledgedExternalReceiptHeader acknowledged
                , authorityStopReceiptPath =
                    externalReceiptPath
                      (acknowledgedExternalReceiptPath acknowledged)
                }
          )
      )
  pure (decodeStopResponse attempted)

enterAuthorityDecommissionPointOfNoReturnViaTransport
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> VerifiedDecommissionManifest
  -> AcknowledgedExternalReceipt
  -> IO (Either AuthorityDecommissionStopClientError ())
enterAuthorityDecommissionPointOfNoReturnViaTransport transport verified acknowledged = do
  attempted <-
    callAuthenticatedClientTransport
      transport
      LifecycleAuthorityDecommissionStopRoute
      (authorityStopRequestBody verified acknowledged)
  pure (decodeStopResponse attempted)

authorityStopRequestBody
  :: VerifiedDecommissionManifest
  -> AcknowledgedExternalReceipt
  -> ByteString
authorityStopRequestBody verified acknowledged =
  LazyByteString.toStrict
    ( encodeControlPlaneRequest
        AuthorityDecommissionStopRequest
          { authorityStopManifest = verifiedSignedManifest verified
          , authorityStopReceiptHeader =
              acknowledgedExternalReceiptHeader acknowledged
          , authorityStopReceiptPath =
              externalReceiptPath
                (acknowledgedExternalReceiptPath acknowledged)
          }
    )

decodeStopResponse
  :: Either AuthenticatedClientError ControlPlaneResponse
  -> Either AuthorityDecommissionStopClientError ()
decodeStopResponse attempted = do
  ControlPlaneResponse status responseBody <-
    first AuthorityDecommissionStopTransportFailed attempted
  if status /= 200
    then Left (AuthorityDecommissionStopHttpStatus status responseBody)
    else do
      response <-
        first
          AuthorityDecommissionStopResponseInvalid
          ( decodeControlPlaneResponse
              authorityDecommissionMaximumResponseBytes
              (LazyByteString.fromStrict responseBody)
          )
      case response of
        AuthorityDecommissionStopResponseStopped -> Right ()
        AuthorityDecommissionStopResponseAlreadyStopped -> Right ()
        AuthorityDecommissionStopResponseRefused detail ->
          Left (AuthorityDecommissionStopRefused detail)

-- | Ask a still-live Target Agent to project the identity and current
-- generation of its one trusted sink.  No coordinate is carried on the wire.
requestTargetDecommissionInventory
  :: AuthenticatedClientTransport 'TargetSecretAgentRuntime
  -> IO (Either Text TargetDecommissionInventory)
requestTargetDecommissionInventory transport = do
  attempted <-
    callAuthenticatedClientTransport
      transport
      TargetSecretDecommissionInventoryRoute
      ( LazyByteString.toStrict
          (encodeControlPlaneRequest ObserveTargetDecommissionInventory)
      )
  pure $ do
    ControlPlaneResponse status responseBody <- first (Text.pack . show) attempted
    if status /= 200
      then
        Left
          ("Target Secret Agent inventory HTTP status " <> Text.pack (show status))
      else do
        response <-
          first
            (Text.pack . show)
            ( decodeControlPlaneResponse
                targetGenerationTombstoneMaximumResponseBytes
                (LazyByteString.fromStrict responseBody)
            )
        case response of
          TargetDecommissionInventoryResponseObserved inventory -> Right inventory
          TargetDecommissionInventoryResponseRefused detail ->
            Left ("Target Secret Agent inventory refused: " <> detail)

targetGenerationTombstoneMaximumResponseBytes :: Int
targetGenerationTombstoneMaximumResponseBytes = 64 * 1024

-- | Close an authenticated Target Agent client over one already-verified
-- manifest.  The runner cannot substitute another manifest per node, and the
-- read-back half uses the endpoint's read-only action so recovery observation
-- never acquires deletion as a side effect.
targetGenerationTombstoneCapability
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> ControlPlaneClient 'TargetSecretAgentRuntime
  -> VerifiedDecommissionManifest
  -> TargetGenerationTombstoneCapability IO
targetGenerationTombstoneCapability bounds providers client verified =
  targetGenerationTombstoneCapabilityWith
    (callAuthenticatedControlPlane bounds providers client)
    verified

targetGenerationTombstoneCapabilityViaTransport
  :: AuthenticatedClientTransport 'TargetSecretAgentRuntime
  -> VerifiedDecommissionManifest
  -> TargetGenerationTombstoneCapability IO
targetGenerationTombstoneCapabilityViaTransport transport =
  targetGenerationTombstoneCapabilityWith
    (callAuthenticatedClientTransport transport)

targetGenerationTombstoneCapabilityWith
  :: ( ControlPlaneRouteFor 'TargetSecretAgentRuntime
       -> ByteString
       -> IO (Either AuthenticatedClientError ControlPlaneResponse)
     )
  -> VerifiedDecommissionManifest
  -> TargetGenerationTombstoneCapability IO
targetGenerationTombstoneCapabilityWith callRoute verified =
  TargetGenerationTombstoneCapability $ \reference generation ->
    NodeOperation
      { nodeDestroy = \_ _ -> do
          response <- callTarget DestroyTargetGeneration reference generation
          pure $ case response of
            Left detail -> Left detail
            Right TargetTombstoneResponseAlreadyAbsent -> Right ()
            Right TargetTombstoneResponseDestroyed -> Right ()
            Right TargetTombstoneResponsePresent ->
              Left "Target Secret Agent reported the generation present after destroy"
            Right (TargetTombstoneResponseRefused detail) ->
              Left ("Target Secret Agent refused generation destroy: " <> detail)
      , nodeReadBack = \_ _ -> do
          response <- callTarget ObserveTargetGenerationAbsence reference generation
          pure $ case response of
            Left detail -> unreachable detail
            Right TargetTombstoneResponseAlreadyAbsent -> ResidueAbsent
            Right TargetTombstoneResponsePresent ->
              ResiduePresent
                ResidueDetails
                  { residueEvidence =
                      "Target Secret Agent observed credential generation "
                        <> show (decommissionTargetGenerationValue generation)
                  , residueStackName = "target-generation:" <> Text.unpack reference
                  }
            Right TargetTombstoneResponseDestroyed ->
              unreachable "read-only Target Agent observation returned a destructive result"
            Right (TargetTombstoneResponseRefused detail) ->
              unreachable ("Target Secret Agent refused generation observation: " <> detail)
      }
 where
  callTarget action reference generation = do
    attempted <-
      callRoute
        TargetSecretDecommissionTombstoneRoute
        ( LazyByteString.toStrict
            ( encodeControlPlaneRequest
                TargetGenerationTombstoneRequest
                  { targetTombstoneManifest = verifiedSignedManifest verified
                  , targetTombstoneCommand =
                      TargetGenerationTombstoneCommand
                        { targetTombstoneReference = reference
                        , targetTombstoneGeneration = generation
                        }
                  , targetTombstoneAction = action
                  }
            )
        )
    pure $ do
      ControlPlaneResponse status responseBody <- first renderAuthenticatedError attempted
      if status /= 200
        then
          Left
            ( "Target Secret Agent HTTP status "
                <> Text.pack (show status)
            )
        else
          first
            (Text.pack . show)
            ( decodeControlPlaneResponse
                targetGenerationTombstoneMaximumResponseBytes
                (LazyByteString.fromStrict responseBody)
            )

  renderAuthenticatedError = Text.pack . show
  unreachable = ResidueUnreachable . ResidueQueryFailed . Text.unpack

-- | Close the same Target Agent transport over its distinct retained-home
-- custody arm.  The wire request carries only the verified manifest and a
-- closed observe/destroy action; mount/path selection remains inside the Agent.
retainedCustodyTombstoneCapability
  :: AuthenticatedClientTransport 'TargetSecretAgentRuntime
  -> VerifiedDecommissionManifest
  -> RetainedCustodyTombstoneCapability IO
retainedCustodyTombstoneCapability transport verified =
  RetainedCustodyTombstoneCapability $
    NodeOperation
      { nodeDestroy = \_ _ -> do
          response <- callCustody DestroyRetainedCustody
          pure $ case response of
            Left detail -> Left detail
            Right RetainedCustodyResponseAlreadyAbsent -> Right ()
            Right RetainedCustodyResponseDestroyed -> Right ()
            Right RetainedCustodyResponsePresent ->
              Left "Target Secret Agent reported retained custody present after destroy"
            Right (RetainedCustodyResponseRefused detail) ->
              Left ("Target Secret Agent refused retained-custody destroy: " <> detail)
      , nodeReadBack = \_ _ -> do
          response <- callCustody ObserveRetainedCustodyAbsence
          pure $ case response of
            Left detail -> unreachable detail
            Right RetainedCustodyResponseAlreadyAbsent -> ResidueAbsent
            Right RetainedCustodyResponsePresent ->
              ResiduePresent
                ResidueDetails
                  { residueEvidence =
                      "Target Secret Agent observed retained-home SMTP/EAB custody metadata"
                  , residueStackName = "retained-home-custody"
                  }
            Right RetainedCustodyResponseDestroyed ->
              unreachable "read-only retained-custody observation returned a destructive result"
            Right (RetainedCustodyResponseRefused detail) ->
              unreachable ("Target Secret Agent refused retained-custody observation: " <> detail)
      }
 where
  callCustody action = do
    attempted <-
      callAuthenticatedClientTransport
        transport
        TargetSecretDecommissionCustodyTombstoneRoute
        ( LazyByteString.toStrict
            ( encodeControlPlaneRequest
                RetainedCustodyTombstoneRequest
                  { retainedCustodyTombstoneManifest =
                      verifiedSignedManifest verified
                  , retainedCustodyTombstoneAction = action
                  }
            )
        )
    pure $ do
      ControlPlaneResponse status responseBody <- first (Text.pack . show) attempted
      if status /= 200
        then
          Left
            ( "Target Secret Agent retained-custody HTTP status "
                <> Text.pack (show status)
            )
        else
          first
            (Text.pack . show)
            ( decodeControlPlaneResponse
                targetGenerationTombstoneMaximumResponseBytes
                (LazyByteString.fromStrict responseBody)
            )

  unreachable = ResidueUnreachable . ResidueQueryFailed . Text.unpack
