{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 8.5: pure parser for the Keycloak credential-setup HTML
-- form that an invited user lands on after following the
-- `action-token` link from `execute-actions-email`.
--
-- The form is rendered by the Keycloak `freemarker` theme and always
-- has the shape:
--
-- @
--   <form id="kc-passwd-update-form" action="<token-bound-url>" method="post">
--     <input type="hidden" name="..."  value="...">
--     ...
--     <input type="password" name="password" />
--     <input type="password" name="password-confirm" />
--     <button type="submit">Submit</button>
--   </form>
-- @
--
-- The parser scans for the @\<form\>@ tag carrying @id="kc-passwd-update-form"@,
-- extracts its @action@ attribute, collects every @type="hidden"@
-- input as a @(name, value)@ pair, and records the field names of
-- the two @type="password"@ inputs.
--
-- The parser is fixture-driven; the live form shape lands as part
-- of the Sprint 8.5 operator-driven capture step in
-- `DEVELOPMENT_PLAN/phase-8-email-invite-auth.md`. Until then the
-- tests pin the shape against a synthetic Keycloak-shaped fixture.
module Prodbox.Keycloak.CredentialSetupForm
  ( CredentialSetupForm (..)
  , parseCredentialSetupForm
  , parseCredentialSetupContinuationLink
  , renderCredentialSetupFormPost
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text

-- | Captured form shape. The hidden fields are preserved verbatim so
-- the POST body re-submits the same `session_code`, `execution`, and
-- `client_id` parameters that the Keycloak server expects.
data CredentialSetupForm = CredentialSetupForm
  { formActionUrl :: Text
  , formHiddenFields :: [(Text, Text)]
  , formPasswordFieldName :: Text
  , formPasswordConfirmFieldName :: Text
  }
  deriving (Eq, Show)

-- | Parse the credential-setup form. Returns @Left@ when the form
-- cannot be located or any required field is missing. The parser
-- accepts attribute order independence and arbitrary whitespace
-- between attributes.
parseCredentialSetupForm :: ByteString -> Either String CredentialSetupForm
parseCredentialSetupForm raw = do
  let body = Text.pack (BS8.unpack raw)
  formBody <- locateFormBody body
  action <- requireAttribute "action" (formOpeningTag formBody)
  hiddens <- pure (collectHiddenInputs (formBodyContent formBody))
  passwords <- pure (collectPasswordInputs (formBodyContent formBody))
  case passwords of
    (passwordName : confirmName : _) ->
      Right
        CredentialSetupForm
          { formActionUrl = action
          , formHiddenFields = hiddens
          , formPasswordFieldName = passwordName
          , formPasswordConfirmFieldName = confirmName
          }
    [single] ->
      Left
        ( "credential-setup form has only one password input ("
            ++ Text.unpack single
            ++ "); expected two (password + confirm)"
        )
    [] -> Left "credential-setup form has no <input type=\"password\"> fields"

-- | Keycloak 26 renders the VERIFY_EMAIL required action as an
-- intermediate page with a "click here" anchor to the next required
-- action. The invite harness follows that anchor with the same cookie
-- jar before parsing the UPDATE_PASSWORD form.
parseCredentialSetupContinuationLink :: ByteString -> Either String Text
parseCredentialSetupContinuationLink raw =
  case uniqueText (filter isRequiredActionLink (collectAnchorHrefs body)) of
    [] ->
      Left "credential-setup continuation link not found (no required-action anchor)"
    [href] -> Right href
    links ->
      Left
        ( "multiple credential-setup continuation links found ("
            ++ show (length links)
            ++ ")"
        )
 where
  body = Text.pack (BS8.unpack raw)
  isRequiredActionLink href =
    "/login-actions/required-action" `Text.isInfixOf` href

-- | Build the URL-encoded POST body the form submits when the user
-- types a new password. Hidden fields are preserved; the two
-- password fields are filled with the supplied values (typically
-- identical: @password@ and @password-confirm@ both receive the
-- chosen value).
renderCredentialSetupFormPost
  :: CredentialSetupForm
  -> Text
  -- ^ New password value.
  -> Text
  -- ^ Confirmation password value (almost always identical to the new value).
  -> ByteString
renderCredentialSetupFormPost form password confirmation =
  BS8.pack
    ( Text.unpack
        ( Text.intercalate
            "&"
            ( map
                renderField
                ( formHiddenFields form
                    ++ [ (formPasswordFieldName form, password)
                       , (formPasswordConfirmFieldName form, confirmation)
                       ]
                )
            )
        )
    )
 where
  renderField (key, value) = urlEncode key <> "=" <> urlEncode value

-- | Application/x-www-form-urlencoded escaping. Replaces every byte
-- outside the unreserved set with @%HH@. Used by 'renderCredentialSetupFormPost'.
urlEncode :: Text -> Text
urlEncode = Text.concatMap escape
 where
  escape c
    | isUnreserved c = Text.singleton c
    | c == ' ' = "+"
    | otherwise = Text.pack ('%' : hex c)
  isUnreserved c =
    isAsciiUpper c
      || isAsciiLower c
      || isDigit c
      || c == '-'
      || c == '_'
      || c == '.'
      || c == '~'
  hex c =
    let code = fromEnum c
        h n = "0123456789ABCDEF" !! n
     in [h (code `div` 16), h (code `mod` 16)]

-- | The slice of HTML that begins at the @<form>@ open tag and ends
-- at the matching @</form>@ close tag.
data FormBody = FormBody
  { formOpeningTag :: Text
  , formBodyContent :: Text
  }
  deriving (Eq, Show)

locateFormBody :: Text -> Either String FormBody
locateFormBody body =
  case findTagWithAttribute "form" "id" "kc-passwd-update-form" body of
    Nothing ->
      Left "credential-setup form not found (no <form id=\"kc-passwd-update-form\">)"
    Just (openingTag, remainder) ->
      case Text.breakOn "</form>" remainder of
        (_, "") -> Left "credential-setup form not closed (no </form>)"
        (content, _) ->
          Right
            FormBody
              { formOpeningTag = openingTag
              , formBodyContent = content
              }

-- | Locate the first @\<tag ...\>@ whose attributes include the given
-- @key="value"@. Returns the open tag's literal text and the text
-- immediately after the close angle bracket.
findTagWithAttribute :: Text -> Text -> Text -> Text -> Maybe (Text, Text)
findTagWithAttribute tagName attrKey attrValue body =
  let prefix = "<" <> tagName
   in case Text.breakOn prefix body of
        (_, "") -> Nothing
        (_, rest) -> case Text.breakOn ">" rest of
          (_, "") -> Nothing
          (openTagBody, closeAndAfter) ->
            let openTag = openTagBody <> ">"
                afterOpen = Text.drop 1 closeAndAfter
             in case requireAttribute attrKey openTag of
                  Right actualValue
                    | actualValue == attrValue -> Just (openTag, afterOpen)
                  _ ->
                    -- skip past this tag and recurse
                    findTagWithAttribute
                      tagName
                      attrKey
                      attrValue
                      afterOpen

-- | Return every @<input type="hidden" ...>@ as a @(name, value)@
-- pair. Inputs missing @name@ or @value@ are dropped.
collectHiddenInputs :: Text -> [(Text, Text)]
collectHiddenInputs body = go body []
 where
  go remaining acc = case Text.breakOn "<input" remaining of
    (_, "") -> reverse acc
    (_, rest) ->
      case Text.breakOn ">" rest of
        (_, "") -> reverse acc
        (tagBody, closeAndAfter) ->
          let openTag = tagBody <> ">"
              afterOpen = Text.drop 1 closeAndAfter
              entry = do
                t <- requireAttribute "type" openTag
                if t == "hidden"
                  then do
                    name <- requireAttribute "name" openTag
                    value <- requireAttribute "value" openTag
                    Right (name, value)
                  else Left "skip non-hidden"
           in case entry of
                Right pair -> go afterOpen (pair : acc)
                Left _ -> go afterOpen acc

-- | Return the @name@ attribute of every @<input type="password" ...>@.
collectPasswordInputs :: Text -> [Text]
collectPasswordInputs body = go body []
 where
  go remaining acc = case Text.breakOn "<input" remaining of
    (_, "") -> reverse acc
    (_, rest) ->
      case Text.breakOn ">" rest of
        (_, "") -> reverse acc
        (tagBody, closeAndAfter) ->
          let openTag = tagBody <> ">"
              afterOpen = Text.drop 1 closeAndAfter
           in case requireAttribute "type" openTag of
                Right "password" ->
                  case requireAttribute "name" openTag of
                    Right name -> go afterOpen (name : acc)
                    Left _ -> go afterOpen acc
                _ -> go afterOpen acc

collectAnchorHrefs :: Text -> [Text]
collectAnchorHrefs body = go body []
 where
  go remaining acc = case Text.breakOn "<a" remaining of
    (_, "") -> reverse acc
    (_, rest) ->
      case Text.breakOn ">" rest of
        (_, "") -> reverse acc
        (tagBody, closeAndAfter) ->
          let openTag = tagBody <> ">"
              afterOpen = Text.drop 1 closeAndAfter
           in case requireAttribute "href" openTag of
                Right href -> go afterOpen (href : acc)
                Left _ -> go afterOpen acc

uniqueText :: [Text] -> [Text]
uniqueText = foldr addIfMissing []
 where
  addIfMissing value acc
    | value `elem` acc = acc
    | otherwise = value : acc

-- | Extract the value of a quoted attribute (@key="value"@) from an
-- open tag. Accepts arbitrary whitespace between attributes, double
-- or single quotes, and ignores attributes whose key matches as a
-- substring of another key (e.g. @data-name="x"@ does not match
-- @name@). Returns the value with surrounding whitespace trimmed.
requireAttribute :: Text -> Text -> Either String Text
requireAttribute key tag = go tag
 where
  go remaining =
    case Text.breakOn key remaining of
      (_, "") -> Left ("attribute `" ++ Text.unpack key ++ "` missing")
      (before, rest) ->
        if not (Text.null before) && isAttributeBoundary (Text.last before)
          then extractQuoted (Text.drop (Text.length key) rest)
          else case Text.uncons rest of
            Nothing -> Left ("attribute `" ++ Text.unpack key ++ "` missing")
            Just (_, more) -> go more

  -- Match only when the character preceding the key candidate is a
  -- whitespace/tag-open character, so @data-name@ does not falsely
  -- match @name@.
  isAttributeBoundary c = isSpace c || c == '<' || c == '\''

  extractQuoted afterKey =
    let trimmed = Text.dropWhile isSpace afterKey
     in case Text.uncons trimmed of
          Just ('=', body) -> takeQuotedValue (Text.dropWhile isSpace body)
          _ -> Left ("attribute `" ++ Text.unpack key ++ "` is not followed by `=`")

  takeQuotedValue body = case Text.uncons body of
    Just (quoteChar, content)
      | quoteChar == '"' || quoteChar == '\'' ->
          extractQuotedValue quoteChar content
    _ -> Left ("attribute `" ++ Text.unpack key ++ "` value is unquoted")

  extractQuotedValue quoteChar content =
    case Text.breakOn (Text.singleton quoteChar) content of
      (value, rest)
        | not (Text.null rest) -> Right (decodeHtmlAttributeValue (Text.strip value))
      _ -> Left ("attribute `" ++ Text.unpack key ++ "` is not closed")

decodeHtmlAttributeValue :: Text -> Text
decodeHtmlAttributeValue =
  Text.replace "&quot;" "\""
    . Text.replace "&#39;" "'"
    . Text.replace "&lt;" "<"
    . Text.replace "&gt;" ">"
    . Text.replace "&amp;" "&"
