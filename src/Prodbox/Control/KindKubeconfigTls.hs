{-# LANGUAGE OverloadedStrings #-}

-- | Parse selected kind TLS material in memory. This does not authenticate a
-- cluster, verify a certificate chain, or establish a network connection.
module Prodbox.Control.KindKubeconfigTls
  ( KindTlsMaterial
  , KindTlsMaterialError (..)
  , parseKindTlsMaterial
  , withKindTlsMaterial
  )
where

import Data.ByteString qualified as ByteString
import Data.PEM (PEM (..), pemParseBS)
import Data.X509 (CertificateChain (..), SignedCertificate, decodeSignedCertificate)
import Data.X509.CertificateStore (CertificateStore, makeCertificateStore)
import Network.TLS (Credential, credentialLoadX509FromMemory)
import Prodbox.Control.KindKubeconfig (KindKubeconfig, withKindKubeconfigMaterial)

data KindTlsMaterialError = KindTlsInvalidCa | KindTlsInvalidClientCertificate | KindTlsInvalidClientKey
  deriving (Eq, Show)

-- No Show instance: the contained credential includes a private key.
data KindTlsMaterial = KindTlsMaterial !CertificateStore !Credential

-- | Require one PEM CA certificate, one PEM client certificate and one
-- unencrypted private-key block. Parsing alone does not prove key/certificate
-- correspondence, trust, validity periods or a peer's identity.
parseKindTlsMaterial :: KindKubeconfig -> IO (Either KindTlsMaterialError KindTlsMaterial)
parseKindTlsMaterial config = withKindKubeconfigMaterial config $ \caBytes certBytes keyBytes -> pure $ do
  ca <- oneCertificate KindTlsInvalidCa caBytes
  cert <- oneCertificate KindTlsInvalidClientCertificate certBytes
  keyBlocks <- either (const (Left KindTlsInvalidClientKey)) Right (pemParseBS keyBytes)
  case keyBlocks of
    [PEM name headers _]
      | name `elem` ["PRIVATE KEY", "RSA PRIVATE KEY", "EC PRIVATE KEY"] && null headers -> pure ()
    _ -> Left KindTlsInvalidClientKey
  credential <-
    either
      (const (Left KindTlsInvalidClientKey))
      Right
      (credentialLoadX509FromMemory certBytes keyBytes)
  case credential of
    (CertificateChain [observed], _)
      | observed == cert -> pure (KindTlsMaterial (makeCertificateStore [ca]) credential)
    _ -> Left KindTlsInvalidClientCertificate

oneCertificate
  :: KindTlsMaterialError -> ByteString.ByteString -> Either KindTlsMaterialError SignedCertificate
oneCertificate failure bytes = do
  blocks <- either (const (Left failure)) Right (pemParseBS bytes)
  case blocks of
    [PEM "CERTIFICATE" [] contents] -> either (const (Left failure)) Right (decodeSignedCertificate contents)
    _ -> Left failure

-- | Supply parsed values to a scoped client builder. They must never be
-- rendered or logged, and peer and client-key checks remain the caller's job.
withKindTlsMaterial :: KindTlsMaterial -> (CertificateStore -> Credential -> IO value) -> IO value
withKindTlsMaterial (KindTlsMaterial ca credential) action = action ca credential
