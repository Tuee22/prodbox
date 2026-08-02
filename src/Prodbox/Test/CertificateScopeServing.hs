{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Test.CertificateScopeServing
  ( CertificateServingDefect (..)
  , parsePresentedDnsSans
  , validatePresentedDnsSans
  , renderCertificateServingDefect
  )
where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text

data CertificateServingDefect
  = PresentedCertificateHasNoDnsSans
  | PresentedCertificateScopeMismatch (Set Text) (Set Text)
  deriving (Eq, Show)

-- | Parse the stable @openssl x509 -ext subjectAltName@ DNS projection. IP and
-- URI SANs are intentionally ignored: Sprint 5.22 compares the exact DNS scope
-- that cert-manager renders from 'CertScopeSet'.
parsePresentedDnsSans :: Text -> Either CertificateServingDefect (Set Text)
parsePresentedDnsSans output =
  case Set.fromList (map canonicalDnsName dnsTokens) of
    names | Set.null names -> Left PresentedCertificateHasNoDnsSans
    names -> Right names
 where
  dnsTokens =
    [ Text.drop 4 token
    | token <- Text.words (Text.map commaToSpace output)
    , "DNS:" `Text.isPrefixOf` token
    ]
  commaToSpace ',' = ' '
  commaToSpace value = value

validatePresentedDnsSans
  :: [Text]
  -> Text
  -> Either CertificateServingDefect ()
validatePresentedDnsSans expected presented = do
  actual <- parsePresentedDnsSans presented
  let exactExpected = Set.fromList (map canonicalDnsName expected)
  if actual == exactExpected
    then Right ()
    else Left (PresentedCertificateScopeMismatch exactExpected actual)

canonicalDnsName :: Text -> Text
canonicalDnsName = Text.toLower . Text.dropWhileEnd (== '.') . Text.strip

renderCertificateServingDefect :: CertificateServingDefect -> String
renderCertificateServingDefect defect = case defect of
  PresentedCertificateHasNoDnsSans ->
    "presented certificate contains no DNS subjectAltName entries"
  PresentedCertificateScopeMismatch expected actual ->
    "presented certificate DNS SAN set mismatch: expected="
      ++ show (Set.toAscList expected)
      ++ ", actual="
      ++ show (Set.toAscList actual)
