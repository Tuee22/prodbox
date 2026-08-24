{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Secret-safe, revision-specific deployment qualification evidence.
-- Construction accepts only public SHA-256 identities and opaque Authority
-- bindings; there is no field capable of retaining plaintext secret bytes.
module Prodbox.Test.Qualification.Evidence
  ( PublicEvidenceDigest
  , mkPublicEvidenceDigest
  , QualificationIdentity (..)
  , QualificationEvidenceInput (..)
  , QualificationEvidence
  , QualificationEvidenceError (..)
  , mkQualificationEvidence
  , qualificationEvidenceDigest
  , qualificationEvidenceReplacementIdentity
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteString8
import Data.Char (isDigit)
import Data.List (group, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric (showHex)
import Prodbox.Test.Qualification.FrozenCounterexample
  ( CounterexampleDisposition (..)
  , CounterexampleMechanism
  , CounterexampleResult (..)
  , OpaqueFixtureBinding
  )
import Prodbox.Test.Qualification.Invite
  ( InviteQualificationEvidence
  )
import Prodbox.Test.Qualification.SourceIdentity
  ( SourceIdentity
  , sourceManifestDigest
  )
import Prodbox.Test.TemporalQualification
  ( TemporalFaultResult
  , TemporalFaultScheduleError
  , validateTemporalFaultSchedule
  )

newtype PublicEvidenceDigest = PublicEvidenceDigest Text
  deriving stock (Eq, Ord, Show)

mkPublicEvidenceDigest :: Text -> Maybe PublicEvidenceDigest
mkPublicEvidenceDigest raw =
  let value = maybe raw id (Text.stripPrefix "sha256:" raw)
   in if Text.length value == 64 && Text.all isLowerHex value
        then Just (PublicEvidenceDigest value)
        else Nothing
 where
  isLowerHex character = isDigit character || character >= 'a' && character <= 'f'

data QualificationIdentity = QualificationIdentity
  { qualificationSourceIdentity :: !SourceIdentity
  , qualificationGeneratedConfigDigest :: !PublicEvidenceDigest
  , qualificationComponentImageDigests :: ![PublicEvidenceDigest]
  , qualificationTopologyWiringDigest :: !PublicEvidenceDigest
  , qualificationResourceEnvelopeDigest :: !PublicEvidenceDigest
  , qualificationLoadFaultDigest :: !PublicEvidenceDigest
  , qualificationInterpreterDigest :: !PublicEvidenceDigest
  , qualificationPersistenceDigest :: !PublicEvidenceDigest
  , qualificationCleanupSchemaDigest :: !PublicEvidenceDigest
  }
  deriving stock (Eq, Show)

data QualificationEvidenceInput = QualificationEvidenceInput
  { evidenceSubstrate :: !Text
  , evidenceCanonicalCommands :: ![Text]
  , evidenceSupersededIdentity :: !QualificationIdentity
  , evidenceReplacementIdentity :: !QualificationIdentity
  , evidenceNormalizedEnvelopeMappingDigest :: !PublicEvidenceDigest
  , evidenceSupersededCounterexampleResults :: ![CounterexampleResult]
  , evidenceReplacementCounterexampleResults :: ![CounterexampleResult]
  , evidenceFaultResults :: ![TemporalFaultResult]
  , evidenceOpaqueBindings :: ![OpaqueFixtureBinding]
  , evidenceInviteQualification :: !InviteQualificationEvidence
  , evidenceAggregateSucceeded :: !Bool
  , evidenceCleanupResidueAbsent :: !Bool
  , evidenceStartedAt :: !Text
  , evidenceCompletedAt :: !Text
  }
  deriving stock (Eq, Show)

data QualificationEvidence = QualificationEvidence
  { qualificationEvidenceInput :: !QualificationEvidenceInput
  , qualificationEvidenceDigest :: !PublicEvidenceDigest
  }
  deriving stock (Eq, Show)

-- | The exact replacement identity this artifact qualified.  The full input
-- remains opaque so a cutover consumer cannot reinterpret individual success
-- booleans as qualification; it may only bind the already-validated artifact
-- to the identity it is about.
qualificationEvidenceReplacementIdentity
  :: QualificationEvidence -> QualificationIdentity
qualificationEvidenceReplacementIdentity =
  evidenceReplacementIdentity . qualificationEvidenceInput

data QualificationEvidenceError
  = QualificationSubstrateEmpty
  | QualificationCommandsEmpty
  | QualificationCommandEmpty
  | QualificationIdentityReused
  | QualificationImageInventoryEmpty !Text
  | QualificationImageDigestDuplicate !Text
  | QualificationCounterexampleMissing !CounterexampleMechanism !CounterexampleDisposition
  | QualificationCounterexampleDuplicate !CounterexampleMechanism !CounterexampleDisposition
  | QualificationFaultScheduleInvalid !TemporalFaultScheduleError
  | QualificationOpaqueBindingsEmpty
  | QualificationAggregateFailed
  | QualificationCleanupResiduePresent
  | QualificationTimestampEmpty
  | QualificationTimestampOrderInvalid
  deriving stock (Eq, Show)

mkQualificationEvidence
  :: QualificationEvidenceInput
  -> Either QualificationEvidenceError QualificationEvidence
mkQualificationEvidence input = do
  require (not (Text.null (Text.strip (evidenceSubstrate input)))) QualificationSubstrateEmpty
  require (not (null (evidenceCanonicalCommands input))) QualificationCommandsEmpty
  require
    (all (not . Text.null . Text.strip) (evidenceCanonicalCommands input))
    QualificationCommandEmpty
  validateIdentity "superseded" (evidenceSupersededIdentity input)
  validateIdentity "replacement" (evidenceReplacementIdentity input)
  require
    ( sourceManifestDigest (qualificationSourceIdentity (evidenceSupersededIdentity input))
        /= sourceManifestDigest (qualificationSourceIdentity (evidenceReplacementIdentity input))
    )
    QualificationIdentityReused
  validateCounterexamples SupersededFailureObserved (evidenceSupersededCounterexampleResults input)
  validateCounterexamples ReplacementMechanismClosed (evidenceReplacementCounterexampleResults input)
  case validateTemporalFaultSchedule (evidenceFaultResults input) of
    Left err -> Left (QualificationFaultScheduleInvalid err)
    Right _ -> Right ()
  require (not (null (evidenceOpaqueBindings input))) QualificationOpaqueBindingsEmpty
  require (evidenceAggregateSucceeded input) QualificationAggregateFailed
  require (evidenceCleanupResidueAbsent input) QualificationCleanupResiduePresent
  require
    (not (Text.null (evidenceStartedAt input)) && not (Text.null (evidenceCompletedAt input)))
    QualificationTimestampEmpty
  require (evidenceStartedAt input < evidenceCompletedAt input) QualificationTimestampOrderInvalid
  pure
    QualificationEvidence
      { qualificationEvidenceInput = input
      , qualificationEvidenceDigest = digestEvidence input
      }

validateIdentity :: Text -> QualificationIdentity -> Either QualificationEvidenceError ()
validateIdentity label identity = do
  require (not (null images)) (QualificationImageInventoryEmpty label)
  case [value | duplicate@(value : _) <- group (sort images), length duplicate > 1] of
    duplicate : _ -> Left (QualificationImageDigestDuplicate (renderDigest duplicate))
    [] -> Right ()
 where
  images = qualificationComponentImageDigests identity

validateCounterexamples
  :: CounterexampleDisposition
  -> [CounterexampleResult]
  -> Either QualificationEvidenceError ()
validateCounterexamples disposition results =
  mapM_ validateMechanism [minBound .. maxBound]
 where
  validateMechanism mechanism =
    case [ result
         | result <- results
         , counterexampleResultMechanism result == mechanism
         , counterexampleResultDisposition result == disposition
         ] of
      [] -> Left (QualificationCounterexampleMissing mechanism disposition)
      [_] -> Right ()
      _ -> Left (QualificationCounterexampleDuplicate mechanism disposition)

require :: Bool -> error -> Either error ()
require condition err = if condition then Right () else Left err

digestEvidence :: QualificationEvidenceInput -> PublicEvidenceDigest
digestEvidence input =
  PublicEvidenceDigest
    ( sha256Hex
        ( ByteString8.pack
            (show input)
        )
    )

sha256Hex :: ByteString -> Text
sha256Hex = Text.pack . concatMap hexByte . ByteString8.unpack . SHA256.hash
 where
  hexByte character =
    let rendered = showHex (fromEnum character) ""
     in if length rendered == 1 then '0' : rendered else rendered

renderDigest :: PublicEvidenceDigest -> Text
renderDigest (PublicEvidenceDigest value) = value
