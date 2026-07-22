{-# LANGUAGE DerivingStrategies #-}

-- | Package-internal secret ingress representation.  The public Request
-- module re-exports the type abstractly and its bounded smart constructor;
-- only the PGP primitive adapter may use the CPS byte eliminator.
module Prodbox.Bootstrap.Broker.Request.Internal
  ( SecretPayload
  , mkSecretPayload
  , secretPayloadLength
  , withSecretPayloadBytes
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Numeric.Natural (Natural)

newtype SecretPayload = SecretPayload ByteString
  deriving stock (Eq)

instance Show SecretPayload where
  show payload = "SecretPayload <redacted:" ++ show (secretPayloadLength payload) ++ " bytes>"

mkSecretPayload :: Natural -> ByteString -> Either String SecretPayload
mkSecretPayload maximumBytes bytes
  | BS.null bytes = Left "secret payload must not be empty"
  | fromIntegral (BS.length bytes) > maximumBytes =
      Left
        ( "secret payload exceeds the configured maximum of "
            ++ show maximumBytes
            ++ " bytes"
        )
  | otherwise = Right (SecretPayload bytes)

secretPayloadLength :: SecretPayload -> Natural
secretPayloadLength (SecretPayload bytes) = fromIntegral (BS.length bytes)

-- | Scoped package-internal eliminator.  It returns no bytes and introduces no
-- projection; the trusted primitive crypto callback consumes them in place.
withSecretPayloadBytes :: SecretPayload -> (ByteString -> result) -> result
withSecretPayloadBytes (SecretPayload bytes) consume = consume bytes
