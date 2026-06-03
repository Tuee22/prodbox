{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Secret.EnsureNamespace
  ( applyDerivedSecrets
  , deriveSecretValueText
  , deriveSecretSha256Hex
  )
where

import Crypto.Hash.SHA256 (hash)
import Data.Aeson (Value)
import Data.ByteString qualified as BS
import Data.ByteString.Builder (toLazyByteString, word8HexFixed)
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Prodbox.K8s.InCluster
  ( K8sSecretOps (..)
  , secretManifestJson
  )
import Prodbox.Secret.Derive (MasterSeed, deriveBase64Url)
import Prodbox.Secret.Inventory
  ( DerivedSecretEntry (..)
  )
import Prodbox.Secret.Wire (SecretSha256Entry (..))

-- | Sprint 3.13 third chunk: derive a secret value as base64url Text
--   suitable for the @stringData@ field of a @v1.Secret@. Pure wrapper
--   over 'Prodbox.Secret.Derive.deriveBase64Url' that lives next to the
--   ensure-namespace pipeline for readability at the call site.
deriveSecretValueText :: MasterSeed -> Text -> Text
deriveSecretValueText = deriveBase64Url

-- | Sprint 3.13 third chunk: lowercase-hex SHA-256 of the
--   already-derived secret value, suitable for the @sha256@ field of
--   the @EnsureNamespaceResponse@'s per-Secret inventory entry. The
--   doctrine requires the response to surface a SHA-256 of each
--   derived value (never the plaintext), so this function is what the
--   handler reports back. Lives here rather than in
--   'Prodbox.Secret.Derive' because it is specifically the
--   @ensure-namespace@ wire-shape encoding.
deriveSecretSha256Hex :: Text -> Text
deriveSecretSha256Hex value =
  TE.decodeUtf8
    ( BL.toStrict
        ( toLazyByteString
            ( BS.foldr
                (\byte acc -> word8HexFixed byte <> acc)
                mempty
                (hash (TE.encodeUtf8 value))
            )
        )
    )

-- | Sprint 3.13 third chunk: idempotently materialize every derived
--   k8s @Secret@ in the supplied inventory.
--
-- For each 'DerivedSecretEntry':
--
--   1. Derive the value from the master seed (base64url-encoded).
--   2. Build the full @v1.Secret@ JSON manifest via
--      'secretManifestJson'.
--   3. PUT the manifest through 'secretOpsPut'. The implementation
--      handles create-vs-update server-side, matching the doctrine's
--      idempotence guarantee.
--   4. Compute the SHA-256 of the derived value for the response.
--
-- The function short-circuits on the first @Left@ from 'secretOpsPut',
-- so partial-success states are visible to the caller (the daemon
-- handler maps them to a 5xx response). On full success, returns the
-- per-Secret SHA-256 inventory in the order the entries appeared.
--
-- The @secretOpsGet@ field is intentionally unused for now: the
-- doctrine's lookup-guard semantic (no-op when the existing value
-- already matches the derived value) is a future optimization, not a
-- correctness requirement — a PUT of the same value is idempotent at
-- the API server level. Wiring 'secretOpsGet' in lands when its
-- absence shows up in real-world tracing.
applyDerivedSecrets
  :: K8sSecretOps
  -> MasterSeed
  -> Text
  -> [DerivedSecretEntry]
  -> IO (Either String [SecretSha256Entry])
applyDerivedSecrets ops seed namespace entries = go entries []
 where
  go [] acc = pure (Right (reverse acc))
  go (entry : rest) acc = do
    let derivedPairs =
          [ (key, deriveSecretValueText seed context)
          | (key, context) <- derivedSecretEntryDerivedFields entry
          ]
        manifest = manifestForEntry entry derivedPairs
    putResult <- secretOpsPut ops namespace (derivedSecretEntryName entry) manifest
    case putResult of
      Left err ->
        pure
          ( Left
              ( "failed to apply Secret `"
                  ++ Text.unpack (derivedSecretEntryName entry)
                  ++ "` in namespace `"
                  ++ Text.unpack namespace
                  ++ "`: "
                  ++ err
              )
          )
      Right () -> do
        -- The wire response surfaces one SHA-256 per @Secret@ object so the
        -- caller can confirm idempotence; we hash the concatenation of
        -- @key=<value>@ pairs in the entry's declared order so a Secret
        -- with multiple derived fields gets one stable digest.
        let entrySha =
              SecretSha256Entry
                { secretSha256EntryName = derivedSecretEntryName entry
                , secretSha256EntrySha256 =
                    deriveSecretSha256Hex
                      (Text.intercalate "\n" [k <> "=" <> v | (k, v) <- derivedPairs])
                }
        go rest (entrySha : acc)

  manifestForEntry :: DerivedSecretEntry -> [(Text, Text)] -> Value
  manifestForEntry entry derivedPairs =
    secretManifestJson
      namespace
      (derivedSecretEntryName entry)
      ( Map.fromList
          (derivedPairs ++ derivedSecretEntryStaticFields entry)
      )
