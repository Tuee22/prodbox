{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.61: the exact coordinate a capability owns, and its digest. A
-- 'CapabilityCoordinate' is a FIELD ON EXACTLY ONE TYPE — the capability
-- reference ('Prodbox.ControlPlane.CapabilityRef'). Every other artifact
-- (observation, admission ticket, writer permit, committed intent) carries only
-- a 'CoordinateDigest', so "two disagreeing coordinates for one operation" is
-- unrepresentable: there is no second field to hold one.
--
-- The digest reuses the live target-commit digest discipline
-- ('sha256TargetValueDigest' over a canonical byte encoding), so the control
-- plane speaks the same coordinate-binding language the retained-authority path
-- already uses. The canonical encoding is a NUL-separated join of the validated
-- fields; NUL cannot appear in a field (the smart constructors reject control
-- characters), so the encoding is injective.
module Prodbox.ControlPlane.Coordinate
  ( -- * Coordinate fields (abstract, smart-constructed)
    ServiceIdentity
  , AuthorityScope
  , CapabilityEndpoint
  , LogicalName
  , AuthorityEpoch (..)
  , serviceIdentityText
  , authorityScopeText
  , capabilityEndpointText
  , logicalNameText

    -- * The coordinate and its digest
  , CapabilityCoordinate (..)
  , CoordinateDigest (..)
  , CoordinateError (..)
  , mkServiceIdentity
  , mkAuthorityScope
  , mkCapabilityEndpoint
  , mkLogicalName
  , mkCoordinate
  , coordinateDigest
  )
where

import Data.Char (isControl, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  , credentialGenerationValue
  , sha256TargetValueDigest
  )

newtype ServiceIdentity = ServiceIdentity Text
  deriving (Eq, Ord, Show)

newtype AuthorityScope = AuthorityScope Text
  deriving (Eq, Ord, Show)

newtype CapabilityEndpoint = CapabilityEndpoint Text
  deriving (Eq, Ord, Show)

newtype LogicalName = LogicalName Text
  deriving (Eq, Ord, Show)

-- | A monotonic authority epoch; capability coordinates and intents are bound to
-- one epoch so a stale-epoch reference cannot drive a later-epoch operation.
newtype AuthorityEpoch = AuthorityEpoch Natural
  deriving (Eq, Ord, Show)

serviceIdentityText :: ServiceIdentity -> Text
serviceIdentityText (ServiceIdentity value) = value

authorityScopeText :: AuthorityScope -> Text
authorityScopeText (AuthorityScope value) = value

capabilityEndpointText :: CapabilityEndpoint -> Text
capabilityEndpointText (CapabilityEndpoint value) = value

logicalNameText :: LogicalName -> Text
logicalNameText (LogicalName value) = value

-- | A validation failure in a decoded capability coordinate field.
data CoordinateError
  = CoordinateFieldEmpty !Text
  | CoordinateFieldHasControl !Text
  | CoordinateFieldHasWhitespace !Text
  | CoordinateFieldTooLong !Text !Int !Int
  deriving (Eq, Show)

-- | The exact coordinate a capability reference owns: service identity, authority
-- scope, endpoint, logical name, and the credential generation it targets.
data CapabilityCoordinate = CapabilityCoordinate
  { coordService :: !ServiceIdentity
  , coordAuthority :: !AuthorityScope
  , coordEndpoint :: !CapabilityEndpoint
  , coordLogical :: !LogicalName
  , coordGeneration :: !CredentialGeneration
  }
  deriving (Eq, Show)

-- | The digest that binds every downstream artifact to the one coordinate it
-- came from. Reuses 'TargetValueDigest' so it is a lowercase-hex SHA-256.
newtype CoordinateDigest = CoordinateDigest TargetValueDigest
  deriving (Eq, Ord, Show)

validateField :: Text -> Text -> Either CoordinateError Text
validateField label raw
  | Text.null value = Left (CoordinateFieldEmpty label)
  | Text.any isControl value = Left (CoordinateFieldHasControl label)
  | Text.any isSpace value = Left (CoordinateFieldHasWhitespace label)
  | Text.length value > maximumLength =
      Left (CoordinateFieldTooLong label (Text.length value) maximumLength)
  | otherwise = Right value
 where
  value = Text.strip raw
  maximumLength = 2048

mkServiceIdentity :: Text -> Either CoordinateError ServiceIdentity
mkServiceIdentity = fmap ServiceIdentity . validateField "service_identity"

mkAuthorityScope :: Text -> Either CoordinateError AuthorityScope
mkAuthorityScope = fmap AuthorityScope . validateField "authority_scope"

mkCapabilityEndpoint :: Text -> Either CoordinateError CapabilityEndpoint
mkCapabilityEndpoint = fmap CapabilityEndpoint . validateField "capability_endpoint"

mkLogicalName :: Text -> Either CoordinateError LogicalName
mkLogicalName = fmap LogicalName . validateField "logical_name"

-- | Build a coordinate from validated fields plus a credential generation.
mkCoordinate
  :: ServiceIdentity
  -> AuthorityScope
  -> CapabilityEndpoint
  -> LogicalName
  -> CredentialGeneration
  -> CapabilityCoordinate
mkCoordinate service authority endpoint logical generation =
  CapabilityCoordinate
    { coordService = service
    , coordAuthority = authority
    , coordEndpoint = endpoint
    , coordLogical = logical
    , coordGeneration = generation
    }

-- | The canonical digest of a coordinate: a NUL-separated join of the fields
-- (injective, since fields reject control characters) hashed through the shared
-- SHA-256 digest.
coordinateDigest :: CapabilityCoordinate -> CoordinateDigest
coordinateDigest coordinate =
  CoordinateDigest
    ( sha256TargetValueDigest
        ( TextEncoding.encodeUtf8
            ( Text.intercalate
                "\NUL"
                [ serviceIdentityText (coordService coordinate)
                , authorityScopeText (coordAuthority coordinate)
                , capabilityEndpointText (coordEndpoint coordinate)
                , logicalNameText (coordLogical coordinate)
                , Text.pack (show (credentialGenerationValue (coordGeneration coordinate)))
                ]
            )
        )
    )
