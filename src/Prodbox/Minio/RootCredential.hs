-- | The STATIC MinIO root credential.
--
-- Operator decision (2026-06-22): the MinIO access credential is not prodbox's
-- security boundary, so password-deriving it is theatre. Confidentiality comes
-- from Vault Transit (every stored object is an app-layer Vault-Transit
-- envelope) and from the password-AEAD seal on the unlock bundle (you need the
-- operator password to /decrypt/ the bundle, not merely to read its ciphertext).
-- The MinIO credential only gates who can read/write that already-encrypted
-- ciphertext over a localhost-only NodePort — exactly the situation prodbox
-- already treats as non-secret for Harbor (hardcoded @admin@/@Harbor12345@).
--
-- So the MinIO root credential is a single fixed, stable constant, used both as
-- the @secret/minio/root@ value the in-cluster MinIO consumes and as the
-- credential the host uses for the pre-unseal Tier-1 unlock-bundle read/write. A
-- stable value also means a retained MinIO data PV always matches Vault across
-- rebuilds (no random/derived drift), and it is a credential MinIO actually
-- accepts (so the bundle round-trip no longer fails @InvalidAccessKeyId@).
--
-- The password is plain alphanumeric so it is safe as an @mc@ argument and
-- satisfies the @minioCommandSecretValue@ shape the secret bootstrap validates.
module Prodbox.Minio.RootCredential
  ( minioRootUser
  , minioRootPassword
  )
where

-- | The static MinIO root access key (unchanged from prior schemes).
minioRootUser :: String
minioRootUser = "prodbox-minio-root"

-- | The static MinIO root secret key. Fixed, non-secret, alphanumeric.
minioRootPassword :: String
minioRootPassword = "prodboxMinioRootStaticCredentialV1"
