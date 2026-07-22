# Burn Recipient Provenance

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](./README.md), [vault_doctrine.md](./vault_doctrine.md), [../../src/Prodbox/Bootstrap/Broker/Settings.hs](../../src/Prodbox/Bootstrap/Broker/Settings.hs)
**Generated sections**: none

> **Purpose**: Record the destructive generation ceremony, immutable public identity, packet
> structure, and Vault-library compatibility evidence for the version-one burn recipient.

## 1. Immutable public identity

The version-one burn recipient is a transferable OpenPGP public entity. It is compiled into
`Prodbox.Bootstrap.Broker.Settings`; it is not an operator-authored configuration value.

| Property | Pinned value |
|----------|--------------|
| User ID | `Prodbox Burn Recipient v1 <burn-recipient-v1@prodbox.invalid>` |
| Primary key | OpenPGP v4 RSA3072, certification-only, non-expiring |
| Primary fingerprint | `F0DEBCA077828F2A82813F420020E4E04A4DD831` |
| Encryption subkey | OpenPGP v4 RSA3072, encryption-only, non-expiring |
| Encryption-subkey fingerprint | `00792271F13CC02116C1914993CEED49504F7A21` |
| Transferable public-entity length | `1772` bytes |
| Transferable public-entity SHA-256 | `3873c5409fba7088e036f4cd56c0ab35aab889920802ecf956a5be579ecadd56` |

The public packet sequence is exactly:

1. public primary key (tag `6`);
2. User ID (tag `13`);
3. positive User-ID self-certification (tag `2`, signature class `0x13`, key flags `0x01`);
4. public encryption subkey (tag `14`); and
5. primary-key subkey-binding signature (tag `2`, signature class `0x18`, key flags `0x0c`).

The primary was created at `2026-07-20T14:16:34Z`; the encryption subkey and its binding were
created one second later. Both packet timestamps and all public bytes are part of the pinned
artifact. The Haskell regression in
`test/unit/BootstrapBrokerFoundation.hs` independently decodes the compiled base64, parses this
packet topology, checks the UID, signature classes and key flags, recomputes both standard v4
SHA-1 fingerprints, checks the byte count, and exercises the compiled SHA-256 identity pin.

## 2. Destructive ceremony

The ceremony ran on `2026-07-20` with GnuPG `2.4.4` and libgcrypt `1.10.3`. Its `GNUPGHOME` was a
mode-`0700` directory on the memory-backed `/dev/shm` filesystem. The following command sequence
created and exported the public entity; the fingerprint assignment shown is the value read back
from the generated primary key:

```bash
# Destructive ceremony transcript; these paths were memory-backed and are not repository paths.
CEREMONY_ROOT=/dev/shm/prodbox-burn-ceremony-public
CEREMONY_HOME="$CEREMONY_ROOT/gnupg"
BURN_IDENTITY='Prodbox Burn Recipient v1 <burn-recipient-v1@prodbox.invalid>'

install -d -m 0700 "$CEREMONY_ROOT" "$CEREMONY_HOME"
gpg --homedir "$CEREMONY_HOME" --batch --pinentry-mode loopback --passphrase '' \
  --quick-generate-key "$BURN_IDENTITY" rsa3072 cert never
PRIMARY_FINGERPRINT=F0DEBCA077828F2A82813F420020E4E04A4DD831
gpg --homedir "$CEREMONY_HOME" --batch --pinentry-mode loopback --passphrase '' \
  --quick-add-key "$PRIMARY_FINGERPRINT" rsa3072 encr never
gpg --homedir "$CEREMONY_HOME" --batch --export "$PRIMARY_FINGERPRINT" \
  > "$CEREMONY_ROOT/burn-recipient-v1.pgp"
base64 -w 0 "$CEREMONY_ROOT/burn-recipient-v1.pgp" \
  > "$CEREMONY_ROOT/burn-recipient-v1.base64"
sha256sum "$CEREMONY_ROOT/burn-recipient-v1.pgp"
gpg --list-packets "$CEREMONY_ROOT/burn-recipient-v1.pgp"
gpgconf --homedir "$CEREMONY_HOME" --kill all
find "$CEREMONY_HOME" -depth -delete
test ! -e "$CEREMONY_HOME"
```

A private primary key and private encryption subkey necessarily existed inside that isolated
ceremony long enough to create the User-ID certification and subkey-binding signature. Neither
private key was exported. The complete private keyring and its agent were destroyed before the
public artifact was adopted into the repository; the post-destruction check found no ceremony
`GNUPGHOME`, and the retained transferable entity contains public packets only. Prodbox has no
holder of the private key, never accepts or stores it, and exposes no burn-token decryption
operation. The initial Vault root-token ciphertext is therefore deliberately unrecoverable.

This is the precise meaning of “burn recipient” throughout the repository. It must not be restated
as “a private key was never generated,” because OpenPGP certification and subkey binding require a
ceremony-time signing key.

## 3. Vault compatibility proof

The exact public bytes were tested with Go `1.24.5` against the OpenPGP library revision used by
the Vault `1.18.3` image and, separately, the current `v1.4.0` library release. The verifier:

- parsed exactly one entity and one self-certified identity with `openpgp.ReadEntity`;
- proved that the parsed entity contained no private primary or subkey material;
- asked `Entity.EncryptionKey` to select the pinned encryption subkey at the current time;
- required valid encryption key flags and both pinned fingerprints; and
- completed `openpgp.Encrypt` and closed a non-empty compatibility-probe ciphertext.

| Library under test | Result |
|--------------------|--------|
| `github.com/ProtonMail/go-crypto@v0.0.0-20230828082145-3c4c8a2d2371` (Vault `1.18.3` pin) | `ReadEntity=ok EncryptionKey=ok Encrypt=ok`, one identity, selected subkey `00792271F13CC02116C1914993CEED49504F7A21`, `1772` public bytes |
| `github.com/ProtonMail/go-crypto@v1.4.0` | Same successful parse, selection, and encryption result |

The compatibility program and downloaded toolchain lived only in the ceremony scratch tree; no Go
tooling or verifier is part of the supported Haskell repository. The stable Haskell regression
guards the immutable public structure and pins, while this record preserves the one-time
library-level behavioral proof.

## 4. Rotation rule

There is no in-place edit to this identity. A future recipient version requires a new isolated
destructive ceremony, a new provenance record, an exact Vault-library compatibility proof, and an
atomic update of the compiled public bytes, primary fingerprint, SHA-256 digest, and Haskell
regression fixture. Configuration-supplied replacements and private-key inputs remain forbidden.
