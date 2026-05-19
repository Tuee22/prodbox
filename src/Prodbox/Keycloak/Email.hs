{-# LANGUAGE OverloadedStrings #-}

-- | RFC-822 invite-email parser for the Phase 8 `ValidationKeycloakInvite` flow.
--
-- Keycloak's `execute-actions-email` endpoint sends an HTML/text email containing one
-- action-token link. The canonical-suite validation polls the SES capture bucket
-- (see `Prodbox.Ses.Capture`) for the message, then extracts the link from the raw
-- RFC-822 body via `parseKeycloakInviteLink`.
--
-- This module is pure; the integration test suite covers happy / multipart / missing
-- fixtures from `test/unit/Main.hs`.
module Prodbox.Keycloak.Email
  ( parseKeycloakInviteLink
  )
where

import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List (isPrefixOf)

-- | Scan an RFC-822 email body for the first Keycloak action-token URL containing
-- `/login-actions/action-token?key=`. Returns the URL with surrounding whitespace and
-- HTML attribute punctuation trimmed.
--
-- Failure modes:
-- - `Left "no Keycloak invite link found in email body"` if zero matches.
-- - `Left "multiple Keycloak invite links found in email body"` if >1 distinct match.
--
-- Quoted-printable soft-wraps (`=\\r\\n` and `=\\n`) are decoded inline before the
-- scan so URLs broken across MIME lines still parse. `=XX` hex decoding is *not*
-- applied because real Keycloak invites emit HTML with literal `?key=…` query
-- strings — interpreting those as QP would clobber the URL.
parseKeycloakInviteLink :: ByteString -> Either String String
parseKeycloakInviteLink raw =
  let decoded = stripSoftWraps (BL8.unpack raw)
      matches = findInviteUrls decoded
   in case dedupe matches of
        [] -> Left "no Keycloak invite link found in email body"
        [single] -> Right single
        (_ : _ : _) -> Left "multiple Keycloak invite links found in email body"

findInviteUrls :: String -> [String]
findInviteUrls = go
 where
  marker = "/login-actions/action-token?key="
  go [] = []
  go s@(_ : rest)
    | "https://" `isPrefixOf` s =
        let candidate = takeWhile validUrlChar s
         in if marker `infixOfHelper` candidate
              then trimPunct candidate : go (drop (length candidate) s)
              else go rest
    | otherwise = go rest

validUrlChar :: Char -> Bool
validUrlChar c = c > ' ' && c /= '"' && c /= '<' && c /= '>' && c /= '\'' && c /= ')'

trimPunct :: String -> String
trimPunct =
  reverse
    . dropWhile (\c -> c == '.' || c == ',' || c == ';' || c == ':' || c == '!')
    . reverse

infixOfHelper :: String -> String -> Bool
infixOfHelper needle haystack
  | length haystack < length needle = False
  | needle `isPrefixOf` haystack = True
  | otherwise = case haystack of
      [] -> False
      _ : rest -> infixOfHelper needle rest

dedupe :: [String] -> [String]
dedupe = foldr step []
 where
  step x acc = if x `elem` acc then acc else x : acc

stripSoftWraps :: String -> String
stripSoftWraps [] = []
stripSoftWraps ('=' : '\r' : '\n' : rest) = stripSoftWraps rest
stripSoftWraps ('=' : '\n' : rest) = stripSoftWraps rest
stripSoftWraps (c : rest) = c : stripSoftWraps rest
