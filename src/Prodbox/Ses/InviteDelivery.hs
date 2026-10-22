{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The Provider's captured-mail producer. Its caller first checks the owned
-- bucket and validation recipient; every S3 read uses the supplied fenced runner.
-- Only a pending marker or invocation-encrypted evidence leaves this boundary.
module Prodbox.Ses.InviteDelivery (observeCapturedInviteEvidence) where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Keycloak.Email (parseKeycloakInviteLink)
import Prodbox.Result (Result (..))
import Prodbox.Ses.Capture qualified as Capture
import Prodbox.Ses.InviteEvidence
  ( InviteMailPublicKey
  , pendingInviteMailEvidence
  , sealInviteMailEvidence
  )

observeCapturedInviteEvidence
  :: Capture.CaptureRunner -> InviteMailPublicKey -> Text -> Text -> IO (Either Text Text)
observeCapturedInviteEvidence runner destination bucket recipient = do
  found <- Capture.findCapturedEmail runner (Text.unpack bucket) recipient
  case found of
    Failure _ -> pure (Left "SES invite capture could not be observed")
    Success Nothing -> pure (Right pendingInviteMailEvidence)
    Success (Just captured) -> case parseKeycloakInviteLink (Capture.capturedEmailBody captured) of
      Left _ -> pure (Left "captured message has no usable invite link")
      Right link ->
        sealInviteMailEvidence
          destination
          bucket
          recipient
          (Capture.capturedEmailKey captured)
          (Text.pack link)
