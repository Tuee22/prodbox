{-# LANGUAGE OverloadedStrings #-}

-- | Sealed representation for the provider-evidence wire.  Sprint @4.99@.
--
-- This module deliberately imports nothing from @Prodbox@, so it sits below
-- everything and no import cycle through it is constructible.  It holds the
-- constructors and nothing else; the codec lives in
-- "Prodbox.Lifecycle.ProviderWorker.Evidence" and the bound is minted from a
-- 'Prodbox.Lifecycle.ProviderWorker.ProviderWork.ProviderIntent' in that
-- module, which is the only other module permitted to import this one.
--
-- The seal is the point.  Before it, provider evidence was a bare 'Text' on the
-- capability signatures, so every 'Text' was a legal answer and the rule an
-- encoder had to satisfy lived in a function the author never had to name.  Six
-- encoders were written that way and all six emitted a character the validator
-- refuses.  Keeping 'ProviderEvidenceBound' abstract is the half that stops an
-- encoder inventing a size limit for itself, which is how one of them came to
-- declare 128 KiB on a wire that carries 4,096 characters.
module Prodbox.Lifecycle.ProviderWorker.Evidence.Internal
  ( ProviderEvidence (..)
  , ProviderEvidenceBound (..)
  , ProviderEvidenceFamily (..)
  , ProviderEvidenceRefusal (..)
  )
where

import Data.Text (Text)

-- | Evidence admitted for some intent.  The constructor is private: a value
-- exists only because the canonical encoder built it, or because the wire
-- boundary re-derived it from bytes that satisfied the same rules.
newtype ProviderEvidence = ProviderEvidence Text
  deriving (Eq, Ord, Show)

-- | The character maximum for the intent being served.  Abstract so a codec
-- cannot author one; it is supplied by the executor that knows the intent.
newtype ProviderEvidenceBound = ProviderEvidenceBound Int
  deriving (Eq, Ord, Show)

-- | One evidence family: its wire prefix and the cardinality it admits.
--
-- The character bound is /derived/ from the cardinality rather than authored
-- beside it, which is the rule this sprint exists to establish: a codec that
-- declares how many rows it can carry has already said how long its evidence
-- can be, and a second number is a second thing to get wrong.
data ProviderEvidenceFamily = ProviderEvidenceFamily
  { providerEvidenceFamilyPrefix :: !Text
  , providerEvidenceFamilyMaximumRows :: !Int
  , providerEvidenceFamilyMaximumRowCharacters :: !Int
  }
  deriving (Eq, Show)

-- | Why evidence was refused.  Every arm names one rule, so a refusal says
-- which rule refused it rather than that something was wrong.
data ProviderEvidenceRefusal
  = ProviderEvidenceEmpty
  | ProviderEvidenceOverBound !Int !Int
  | ProviderEvidenceControlCharacter
  | ProviderEvidenceOverCardinality !Int !Int
  | ProviderEvidenceRetiredVersion !Text !Text
  | ProviderEvidenceUnsupportedEncoding !Text
  | ProviderEvidenceEmptyRowSet !Text
  | ProviderEvidenceMalformedEscape !Text
  | ProviderEvidenceNotCanonical !Text
  deriving (Eq, Show)
