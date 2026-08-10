{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Permit-scoped Target Agent effects for explicit Admin Actions.
--
-- These routes are deliberately disjoint from decommission.  They accept a
-- backup-bound, Pod-bound Admin Action permit and one exact member already
-- contained in that permit; they never accept or manufacture a
-- 'VerifiedDecommissionManifest'.  After proof verification the endpoint
-- lowers only to the existing exact local tombstone boundaries.
module Prodbox.ControlPlane.AdminActionTargetEndpoint
  ( AdminTargetTombstoneRequest (..)
  , AdminTargetTombstoneResponse (..)
  , AdminCustodyTombstoneRequest (..)
  , AdminCustodyTombstoneResponse (..)
  , AdminActionTargetVerification (..)
  , serveAdminTargetTombstoneRequest
  , serveAdminCustodyTombstoneRequest
  , adminTargetTombstoneResponseStatus
  , adminCustodyTombstoneResponseStatus
  , adminActionTargetResponseBody
  , adminActionTargetMaximumBytes
  , adminActionTargetResponseMaximumBytes
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.AdminAction.Protocol
  ( AdminActionPlan (AdminDestroyAwsSesPlanAction)
  , AdminDestroyAwsSesPlan
  , AdminRetainedCustodyMember (..)
  , AdminTargetGeneration (..)
  , AdminTargetGenerationReadBack (..)
  , SignedAdminActionPermit
  , adminActionJobPodName
  , adminActionJobPodUid
  , adminActionPermitAction
  , adminActionPermitOperationId
  , adminActionPermitPlan
  , adminDestroyRetainedCustody
  , adminDestroyTargetGenerations
  , signedAdminActionPermitBinding
  , signedAdminActionPermitCore
  , signedAdminActionPermitSignerGeneration
  , verifySignedAdminActionPermit
  )
import Prodbox.Lifecycle.Authority.AdminAction (AdminAction (DestroyAwsSes))
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityManifestSigner (readAuthorityManifestPublicKey)
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( manifestPublicKeyBytes
  , mkDecommissionTargetGeneration
  )
import Prodbox.Lifecycle.Decommission.RetainedCustodyTombstone
  ( RetainedCustodyBoundary
  , RetainedCustodyKind (RetainedHomeSesSmtpSource)
  , RetainedCustodyTombstoneAction
  , RetainedCustodyTombstoneResult (..)
  , runAuthorizedRetainedCustodyKindTombstone
  )
import Prodbox.Lifecycle.Decommission.TargetTombstone
  ( TargetGenerationTombstoneAction
  , TargetGenerationTombstoneCommand (..)
  , TargetGenerationTombstoneRegistry
  , TargetGenerationTombstoneResult (..)
  , runAuthorizedTargetGenerationTombstone
  )
import Prodbox.Lifecycle.Lease (AuthorityTime)

data AdminTargetTombstoneRequest = AdminTargetTombstoneRequest
  { adminTargetRequestPermit :: !SignedAdminActionPermit
  , adminTargetRequestOperationId :: !Text
  , adminTargetRequestPodName :: !Text
  , adminTargetRequestPodUid :: !Text
  , adminTargetRequestMember :: !AdminTargetGeneration
  , adminTargetRequestAction :: !TargetGenerationTombstoneAction
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminTargetTombstoneResponse
  = AdminTargetTombstoneAbsent !AdminTargetGenerationReadBack
  | AdminTargetTombstonePresent
  | AdminTargetTombstoneDestroyed !AdminTargetGenerationReadBack
  | AdminTargetTombstoneRefused !Text
  | AdminTargetTombstoneUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminCustodyTombstoneRequest = AdminCustodyTombstoneRequest
  { adminCustodyRequestPermit :: !SignedAdminActionPermit
  , adminCustodyRequestOperationId :: !Text
  , adminCustodyRequestPodName :: !Text
  , adminCustodyRequestPodUid :: !Text
  , adminCustodyRequestMember :: !AdminRetainedCustodyMember
  , adminCustodyRequestAction :: !RetainedCustodyTombstoneAction
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminCustodyTombstoneResponse
  = AdminCustodyTombstoneAbsent !Text
  | AdminCustodyTombstonePresent
  | AdminCustodyTombstoneDestroyed !Text
  | AdminCustodyTombstoneRefused !Text
  | AdminCustodyTombstoneUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminActionTargetVerification m = AdminActionTargetVerification
  { adminTargetAuthoritySigner :: !(AuthorityManifestSigner m)
  , adminTargetCurrentTime :: !(m (Either Text AuthorityTime))
  , adminTargetLocalIdentity :: !Text
  }

adminActionTargetMaximumBytes :: Int
adminActionTargetMaximumBytes = 512 * 1024

adminActionTargetResponseMaximumBytes :: Int
adminActionTargetResponseMaximumBytes = 128 * 1024

serveAdminTargetTombstoneRequest
  :: (Monad m)
  => Int
  -> AdminActionTargetVerification m
  -> TargetGenerationTombstoneRegistry m payload
  -> LazyByteString.ByteString
  -> m AdminTargetTombstoneResponse
serveAdminTargetTombstoneRequest maximumBytes verification registry body =
  case decodeControlPlaneRequest maximumBytes body of
    Left _ -> pure (AdminTargetTombstoneRefused "request-codec-rejected")
    Right request -> do
      verified <- verifyRequest verification request
      case verified of
        Left detail -> pure (AdminTargetTombstoneRefused detail)
        Right () -> case mkDecommissionTargetGeneration
          (adminTargetGenerationValue (adminTargetRequestMember request)) of
          Left _ -> pure (AdminTargetTombstoneRefused "target-generation-invalid")
          Right generation -> do
            result <-
              runAuthorizedTargetGenerationTombstone
                registry
                (adminTargetRequestAction request)
                TargetGenerationTombstoneCommand
                  { targetTombstoneReference =
                      adminTargetGenerationTargetId (adminTargetRequestMember request)
                  , targetTombstoneGeneration = generation
                  }
            pure (targetResponse request result)

serveAdminCustodyTombstoneRequest
  :: (Monad m)
  => Int
  -> AdminActionTargetVerification m
  -> RetainedCustodyBoundary m
  -> LazyByteString.ByteString
  -> m AdminCustodyTombstoneResponse
serveAdminCustodyTombstoneRequest maximumBytes verification boundary body =
  case decodeControlPlaneRequest maximumBytes body of
    Left _ -> pure (AdminCustodyTombstoneRefused "request-codec-rejected")
    Right request -> do
      verified <- verifyCustodyRequest verification request
      case verified of
        Left detail -> pure (AdminCustodyTombstoneRefused detail)
        Right () -> do
          result <-
            runAuthorizedRetainedCustodyKindTombstone
              boundary
              RetainedHomeSesSmtpSource
              (adminCustodyRequestAction request)
          pure (custodyResponse request result)

verifyRequest
  :: (Monad m)
  => AdminActionTargetVerification m
  -> AdminTargetTombstoneRequest
  -> m (Either Text ())
verifyRequest verification request =
  verifyPermitProjection
    verification
    (adminTargetRequestPermit request)
    (adminTargetRequestOperationId request)
    (adminTargetRequestPodName request)
    (adminTargetRequestPodUid request)
    (\plan -> adminTargetRequestMember request `elem` adminDestroyTargetGenerations plan)
    (adminTargetGenerationTargetId (adminTargetRequestMember request))

verifyCustodyRequest
  :: (Monad m)
  => AdminActionTargetVerification m
  -> AdminCustodyTombstoneRequest
  -> m (Either Text ())
verifyCustodyRequest verification request =
  verifyPermitProjection
    verification
    (adminCustodyRequestPermit request)
    (adminCustodyRequestOperationId request)
    (adminCustodyRequestPodName request)
    (adminCustodyRequestPodUid request)
    (\plan -> adminCustodyRequestMember request == adminDestroyRetainedCustody plan)
    (adminRetainedCustodyTargetId (adminCustodyRequestMember request))

verifyPermitProjection
  :: (Monad m)
  => AdminActionTargetVerification m
  -> SignedAdminActionPermit
  -> Text
  -> Text
  -> Text
  -> (AdminDestroyAwsSesPlan -> Bool)
  -> Text
  -> m (Either Text ())
verifyPermitProjection verification permit operationId podName podUid memberAllowed targetId = do
  publicResult <- readAuthorityManifestPublicKey (adminTargetAuthoritySigner verification)
  nowResult <- adminTargetCurrentTime verification
  pure $ do
    (publicGeneration, publicKey) <- publicResult
    now <- nowResult
    let core = signedAdminActionPermitCore permit
        binding = signedAdminActionPermitBinding permit
    if publicGeneration == signedAdminActionPermitSignerGeneration permit
      then Right ()
      else Left "authority-signer-generation-mismatch"
    mapLeft (const "permit-signature-rejected") $
      verifySignedAdminActionPermit (manifestPublicKeyBytes publicKey) now permit
    if adminActionPermitAction core == DestroyAwsSes
      then Right ()
      else Left "permit-action-refused"
    if adminActionPermitOperationId core == operationId
      && adminActionJobPodName binding == podName
      && adminActionJobPodUid binding == podUid
      then Right ()
      else Left "permit-operation-pod-binding-mismatch"
    if targetId == adminTargetLocalIdentity verification
      then Right ()
      else Left "permit-target-binding-mismatch"
    case adminActionPermitPlan core of
      AdminDestroyAwsSesPlanAction plan
        | memberAllowed plan -> Right ()
        | otherwise -> Left "permit-plan-member-refused"
      _ -> Left "permit-plan-refused"

targetResponse
  :: AdminTargetTombstoneRequest
  -> TargetGenerationTombstoneResult
  -> AdminTargetTombstoneResponse
targetResponse request result = case result of
  TargetGenerationAlreadyAbsent -> AdminTargetTombstoneAbsent readBack
  TargetGenerationPresent -> AdminTargetTombstonePresent
  TargetGenerationDestroyedAndReadBack -> AdminTargetTombstoneDestroyed readBack
  TargetGenerationTombstoneRefused _ ->
    AdminTargetTombstoneUnavailable "target-generation-readback-unavailable"
 where
  member = adminTargetRequestMember request
  readBack =
    AdminTargetGenerationReadBack
      { adminTargetReadBackTargetId = adminTargetGenerationTargetId member
      , adminTargetReadBackGeneration = adminTargetGenerationValue member
      , adminTargetReadBackAbsenceEvidence =
          "admin-action:" <> adminTargetRequestOperationId request <> ":target-absent"
      }

custodyResponse
  :: AdminCustodyTombstoneRequest
  -> RetainedCustodyTombstoneResult
  -> AdminCustodyTombstoneResponse
custodyResponse request result = case result of
  RetainedCustodyAlreadyAbsent -> AdminCustodyTombstoneAbsent evidence
  RetainedCustodyPresentResult -> AdminCustodyTombstonePresent
  RetainedCustodyDestroyedAndReadBack -> AdminCustodyTombstoneDestroyed evidence
  RetainedCustodyTombstoneRefused _ ->
    AdminCustodyTombstoneUnavailable "retained-custody-readback-unavailable"
 where
  evidence =
    "admin-action:" <> adminCustodyRequestOperationId request <> ":ses-custody-absent"

adminTargetTombstoneResponseStatus :: AdminTargetTombstoneResponse -> ReplyStatus
adminTargetTombstoneResponseStatus response = case response of
  AdminTargetTombstoneAbsent _ -> ReplyOk
  AdminTargetTombstonePresent -> ReplyOk
  AdminTargetTombstoneDestroyed _ -> ReplyOk
  AdminTargetTombstoneRefused _ -> ReplyForbidden
  AdminTargetTombstoneUnavailable _ -> ReplyServiceUnavailable

adminCustodyTombstoneResponseStatus :: AdminCustodyTombstoneResponse -> ReplyStatus
adminCustodyTombstoneResponseStatus response = case response of
  AdminCustodyTombstoneAbsent _ -> ReplyOk
  AdminCustodyTombstonePresent -> ReplyOk
  AdminCustodyTombstoneDestroyed _ -> ReplyOk
  AdminCustodyTombstoneRefused _ -> ReplyForbidden
  AdminCustodyTombstoneUnavailable _ -> ReplyServiceUnavailable

adminActionTargetResponseBody :: (Serialise response) => response -> ByteString
adminActionTargetResponseBody = LazyByteString.toStrict . encodeControlPlaneResponse

mapLeft :: (left -> other) -> Either left value -> Either other value
mapLeft convert value = case value of
  Left err -> Left (convert err)
  Right result -> Right result
