-- | The STATIC MinIO root credential — the sole registered bootstrap-floor
-- credential. @vault_doctrine.md@ §6.1 is the registration and owns the full
-- analysis; this header records only what a reader of this module needs.
--
-- It exists as a constant because it is needed /before/ Vault can be read: the
-- host and the Bootstrap Broker perform the pre-unseal Tier-1 unlock-bundle
-- read\/write with it (§17's chicken-and-egg floor), so it cannot be a Vault
-- reference. It is also the @secret\/minio\/root@ value the in-cluster MinIO
-- consumes.
--
-- Two corrections worth carrying here, because earlier comments in this
-- repository got them wrong and the wrong version propagated by citation:
--
--   * Reachability is /not/ a localhost-only NodePort. Both MinIO Services are
--     @ClusterIP@; the host reaches them over a @kubectl port-forward@ onto the
--     loopback interface. The credential is usable from any pod in the cluster,
--     and from any host holding a working kubeconfig.
--   * It reaches ciphertext only against /Vault's/ material — every Tier-2
--     operational object is a Vault-Transit envelope and the unlock bundle is
--     password-AEAD sealed (the Tier-1 bootstrap objects are the deliberate
--     exception, §9). But it is MinIO /root/, so it also carries write access to
--     the container-registry blob store — overwritten blobs are pulled as trusted
--     images — and destroy-or-deny against Vault's recovery path. That is an
--     integrity exposure the ciphertext argument does not cover.
--
-- OBLIGATION (§6.1): this must become a per-install generated value persisted on
-- first bring-up, not a compiled constant duplicated as the chart default. The
-- in-repo precedent is the registry-storage credential path — generate from the
-- system entropy source on first bring-up, then re-read the persisted Secret on
-- later runs — which gives the same cross-rebuild stability without publishing
-- the value.
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

-- | The static MinIO root secret key. Registered bootstrap-floor credential; see
-- the module header for its reachability and blast radius.
minioRootPassword :: String
minioRootPassword = "prodboxMinioRootStaticCredentialV1"
