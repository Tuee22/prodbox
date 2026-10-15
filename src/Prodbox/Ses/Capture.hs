{-# LANGUAGE OverloadedStrings #-}

-- | SES capture-bucket reads for the Phase 8 @ValidationKeycloakInvite@ flow.
--
-- The shared SES infrastructure (Sprint 8.1) routes inbound mail addressed to
-- the receive domain into the capture bucket under the @inbound/@ key prefix.
-- These functions find the messages addressed to one recipient and delete them.
--
-- They run inside the Provider Worker under its assumed-role session, never on
-- the host: the host holds no AWS credential, and the invite validation reaches
-- the bucket through the @ObserveSesInviteMail@ and @ReapSesInviteMail@
-- Provider intents. Each is a single observation; the caller polls by issuing
-- another intent, because a poll loop inside one Provider request would hold
-- the request open for the whole deadline.
--
-- The AWS CLI is reached through a 'CaptureRunner' the Provider supplies, so
-- every call carries the Provider's child-process permit and wall-clock bound,
-- and so a unit case can drive these functions against a scripted runner.
--
-- __An absence claim must not fail open.__ A conclusion that no message
-- remains is only as strong as the listing and the reads behind it, so a
-- listing that cannot be walked to its end, and an object that cannot be read,
-- are failures: reporting \"none\" past either would let a one-time invite token
-- stay in the bucket under a clean verdict.
--
-- __The claim is about recent objects, and the bucket grows without bound.__ The
-- capture bucket keeps every message the receive domain is sent and nothing
-- expires it, while the invite recipient carries a per-run nonce, so a message
-- older than a run cannot be that run's. Reading every object in the bucket
-- made each poll cost one process per object ever delivered and, past a hundred,
-- refused outright. The listing is therefore walked page by page to its end,
-- and only the objects modified within 'captureRecencyWindow' (six hours) are
-- read; an older object is counted and left alone, so \"none remains\" means
-- none among those. An object whose modification time cannot be read is treated
-- as recent, never as old.
module Prodbox.Ses.Capture
  ( CapturedEmail (..)
  , CaptureRunner (..)
  , findCapturedEmail
  , capturedEmailKeysFor
  , deleteCapturedObject
  , messageAddressedTo
  , maximumInboundObjects
  , maximumRecentInboundObjects
  , captureRecencyWindow
  , captureWindowStatement
  , parseListedTime
  )
where

import Control.Monad (foldM)
import Data.Aeson (Value (..), eitherDecode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (isSpace)
import Data.Foldable (asum)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.Encoding.Error qualified as TextEncodingError
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.POSIX (POSIXTime, utcTimeToPOSIXSeconds)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Data.Vector qualified as Vector
import Prodbox.Result (Result (..))
import Prodbox.Ses.Readiness (sesCaptureKeyPrefix)
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))
import System.IO (hClose)
import System.IO.Temp (withSystemTempFile)

-- | An inbound RFC-822 email captured by the SES receive rule.
data CapturedEmail = CapturedEmail
  { capturedEmailKey :: Text
  -- ^ The S3 object key (e.g. `inbound/abc123def…`).
  , capturedEmailBody :: ByteString
  -- ^ The raw RFC-822 body bytes.
  }
  deriving (Eq, Show)

-- | How these functions reach the AWS CLI, and what time it is: one bounded
-- invocation per call, and the clock the recency window is measured against.
data CaptureRunner = CaptureRunner
  { runCaptureAws :: [String] -> IO ProcessOutput
  , captureNow :: IO POSIXTime
  }

-- | The most inbound objects one listing is allowed to walk. A bucket past this
-- is refused rather than sampled, because a verdict over a sample is not a
-- verdict.
maximumInboundObjects :: Int
maximumInboundObjects = 10000

-- | The most recent inbound objects one call is allowed to read. Each read is a
-- process, and the Provider's pod gives a process about a CPU-second of a tenth
-- of a core, so a read costs on the order of ten seconds. The reaper scans three
-- times inside one intent (observe, apply, read-back), so twenty reads keep the
-- worst case near ten minutes against a thirty-minute intent; a handful of
-- invite messages is the normal case.
maximumRecentInboundObjects :: Int
maximumRecentInboundObjects = 20

-- | An object is read only if it was modified within this window of now. The
-- invite validation reads and reaps within minutes of the nonce its recipient
-- carries, so six hours is wide; a bucket that crowds this window refuses
-- instead of reading, and clears itself as the window moves.
captureRecencyWindow :: POSIXTime
captureRecencyWindow = 6 * 60 * 60

-- | The window in words, for the messages that report what a scan covered.
captureWindowStatement :: String
captureWindowStatement =
  "modified within the last "
    <> show (round (captureRecencyWindow / 3600) :: Int)
    <> " hours"

-- | How many objects one listing page asks for.
captureListingPageSize :: Int
captureListingPageSize = 1000

-- | The most pages one listing walks: enough for 'maximumInboundObjects' with
-- room to spare, and a stop for a runner that never ends the listing.
maximumListingPages :: Int
maximumListingPages = 12

-- | The first captured message addressed to the recipient, if any has arrived.
findCapturedEmail
  :: CaptureRunner
  -> String
  -> Text
  -> IO (Result (Maybe CapturedEmail))
findCapturedEmail runner bucket recipient = do
  listed <- listInboundKeys runner bucket
  case listed of
    Failure err -> pure (Failure err)
    Success keys -> firstMatch keys
 where
  firstMatch [] = pure (Success Nothing)
  firstMatch (keyText : rest) = do
    fetched <- getInboundObject runner bucket keyText
    case fetched of
      Failure err -> pure (Failure err)
      Success body
        | messageAddressedTo recipient body ->
            pure (Success (Just CapturedEmail {capturedEmailKey = keyText, capturedEmailBody = body}))
        | otherwise -> firstMatch rest

-- | Every captured object key whose message is addressed to the recipient.
-- An object that cannot be read fails the whole answer: it cannot be shown not
-- to name the recipient.
capturedEmailKeysFor
  :: CaptureRunner
  -> String
  -> Text
  -> IO (Result [Text])
capturedEmailKeysFor runner bucket recipient = do
  listed <- listInboundKeys runner bucket
  case listed of
    Failure err -> pure (Failure err)
    Success keys -> fmap reverse <$> foldM collect (Success []) keys
 where
  collect (Failure err) _ = pure (Failure err)
  collect (Success matched) keyText = do
    fetched <- getInboundObject runner bucket keyText
    pure $ case fetched of
      Failure err -> Failure err
      Success body
        | messageAddressedTo recipient body -> Success (keyText : matched)
        | otherwise -> Success matched

-- | Hard-delete one captured object.
deleteCapturedObject :: CaptureRunner -> String -> Text -> IO (Result ())
deleteCapturedObject runner bucket keyText = do
  output <-
    runCaptureAws
      runner
      ["s3api", "delete-object", "--bucket", bucket, "--key", Text.unpack keyText]
  pure $ case processExitCode output of
    ExitSuccess -> Success ()
    ExitFailure code ->
      Failure
        ( "aws s3api delete-object exit "
            <> show code
            <> ": "
            <> trim (processStderr output)
        )

-- | The inbound object keys worth reading: every page of the listing is walked
-- to its end, and the keys of the objects modified within the recency window are
-- returned. A listing that cannot be walked to its end is a failure.
listInboundKeys :: CaptureRunner -> String -> IO (Result [Text])
listInboundKeys runner bucket = do
  now <- captureNow runner
  walk now Nothing 1 0 []
 where
  walk now token pagesWalked objectsWalked recentSoFar = do
    page <- listInboundPage runner bucket token
    case page of
      Failure err -> pure (Failure err)
      Success (objects, next) ->
        let objectsSeen = objectsWalked + length objects
            recent = recentSoFar ++ [listedKey object | object <- objects, isRecent now object]
         in continue now next pagesWalked objectsSeen recent
  continue now next pagesWalked objectsSeen recent
    | objectsSeen > maximumInboundObjects =
        pure
          ( Failure
              ( "the capture bucket holds more than "
                  <> show maximumInboundObjects
                  <> " inbound objects; refusing to conclude anything from a partial listing"
              )
          )
    | length recent > maximumRecentInboundObjects =
        pure
          ( Failure
              ( "the capture bucket holds more than "
                  <> show maximumRecentInboundObjects
                  <> " inbound objects "
                  <> captureWindowStatement
                  <> "; refusing to read them all"
              )
          )
    | otherwise = case next of
        Nothing -> pure (Success recent)
        Just nextToken
          | pagesWalked >= maximumListingPages ->
              pure (Failure "the capture bucket listing did not end; refusing to conclude anything from it")
          | otherwise -> walk now (Just nextToken) (pagesWalked + 1) objectsSeen recent

-- | One listed object: its key, and when S3 says it was last modified. A
-- modification time that is absent or unreadable is not evidence of age.
data ListedObject = ListedObject
  { listedKey :: Text
  , listedModified :: Maybe POSIXTime
  }

-- | Whether an object is inside the recency window. An object with no readable
-- modification time is recent: it is read rather than skipped.
isRecent :: POSIXTime -> ListedObject -> Bool
isRecent now object = case listedModified object of
  Nothing -> True
  Just modified -> now - modified <= captureRecencyWindow

-- | One page of the listing: its objects, and the token that continues it, if
-- the CLI reported that more objects exist than it returned.
listInboundPage
  :: CaptureRunner -> String -> Maybe String -> IO (Result ([ListedObject], Maybe String))
listInboundPage runner bucket token = do
  output <-
    runCaptureAws
      runner
      ( [ "s3api"
        , "list-objects-v2"
        , "--bucket"
        , bucket
        , "--prefix"
        , sesCaptureKeyPrefix
        , "--max-items"
        , show captureListingPageSize
        ]
          ++ maybe [] (\continuation -> ["--starting-token", continuation]) token
          ++ ["--output", "json"]
      )
  pure $ case processExitCode output of
    ExitFailure code ->
      Failure
        ( "aws s3api list-objects-v2 exit "
            <> show code
            <> ": "
            <> trim (processStderr output)
        )
    ExitSuccess ->
      -- The child's output arrives as one Char per byte, so the bytes come back
      -- through the inverse of that view; encoding it again would double-encode
      -- every non-ASCII byte of a key.
      case eitherDecode (BL8.pack (processStdout output)) of
        Left err -> Failure ("could not decode list-objects-v2 JSON: " <> err)
        Right value -> pageOf value

-- | The objects of a decoded page and its continuation token. A token that is
-- present and not a string is a failure, not the end of the listing.
pageOf :: Value -> Result ([ListedObject], Maybe String)
pageOf value = case value of
  Object obj -> case KeyMap.lookup (Key.fromString "NextToken") obj of
    Nothing -> Success (listedObjects obj, Nothing)
    Just (String token) -> Success (listedObjects obj, Just (Text.unpack token))
    Just _ -> Failure "list-objects-v2 returned a continuation token that is not a string"
  _ -> Success ([], Nothing)

listedObjects :: KeyMap.KeyMap Value -> [ListedObject]
listedObjects obj =
  case KeyMap.lookup (Key.fromString "Contents") obj of
    Just (Array arr) ->
      [ ListedObject keyText (modifiedOf item)
      | Object item <- Vector.toList arr
      , Just (String keyText) <- [KeyMap.lookup (Key.fromString "Key") item]
      ]
    _ -> []
 where
  modifiedOf item = case KeyMap.lookup (Key.fromString "LastModified") item of
    Just (String modified) -> parseListedTime (Text.unpack modified)
    _ -> Nothing

-- | A modification time as the AWS CLI prints it: ISO 8601 with a numeric offset
-- (@2026-10-08T14:03:11+00:00@, with six fractional digits when S3 reports
-- them). A trailing @Z@, which the CLI prints only under its wire timestamp
-- format, is read too. Anything else is not a time.
parseListedTime :: String -> Maybe POSIXTime
parseListedTime raw = utcTimeToPOSIXSeconds <$> asum (map attempt formats)
 where
  attempt :: String -> Maybe UTCTime
  attempt format = parseTimeM False defaultTimeLocale format raw
  formats =
    [ "%Y-%m-%dT%H:%M:%S%Q%Ez"
    , "%Y-%m-%dT%H:%M:%S%Q%z"
    , "%Y-%m-%dT%H:%M:%S%QZ"
    ]

getInboundObject :: CaptureRunner -> String -> Text -> IO (Result ByteString)
getInboundObject runner bucket keyText =
  withSystemTempFile "prodbox-ses-capture-" $ \tempPath handle -> do
    hClose handle
    output <-
      runCaptureAws
        runner
        ["s3api", "get-object", "--bucket", bucket, "--key", Text.unpack keyText, tempPath]
    case processExitCode output of
      ExitFailure code ->
        pure
          ( Failure
              ( "aws s3api get-object exit "
                  <> show code
                  <> ": "
                  <> trim (processStderr output)
              )
          )
      ExitSuccess -> Success <$> BL.readFile tempPath

-- | Whether a message names the recipient as an addressee in its @To:@ header.
--
-- The comparison is of whole addresses, case-insensitively, over the header
-- block only. A substring match let the recipient @a\@example.test@ select the
-- mail of @banana\@example.test@, and let a body line beginning @To:@ select a
-- message the header never named; both matter when the answer decides what is
-- deleted.
messageAddressedTo :: Text -> ByteString -> Bool
messageAddressedTo recipient raw =
  any (elem wanted . addresses) toHeaders
 where
  wanted = Text.toLower (Text.strip recipient)
  decoded = TextEncoding.decodeUtf8With TextEncodingError.lenientDecode (BL.toStrict raw)
  headerLines = takeWhile (not . Text.null . Text.strip) (Text.lines (Text.replace "\r" "" decoded))
  unfolded = unfold headerLines
  toHeaders =
    [ Text.drop 3 headerLine
    | headerLine <- unfolded
    , Text.toLower (Text.take 3 headerLine) == "to:"
    ]
  addresses headerValue =
    [ Text.toLower (angleOrWhole entry)
    | entry <- Text.splitOn "," headerValue
    , not (Text.null (Text.strip entry))
    ]
  angleOrWhole entry =
    case Text.breakOn "<" entry of
      (_, rest)
        | not (Text.null rest) ->
            Text.strip (Text.takeWhile (/= '>') (Text.drop 1 rest))
      _ -> Text.strip entry

-- | Join folded header lines: a line that starts with whitespace continues the
-- one before it.
unfold :: [Text] -> [Text]
unfold = foldr step []
 where
  step line [] = [line]
  step line (next : rest)
    | startsWithSpace next = (line <> " " <> Text.stripStart next) : rest
    | otherwise = line : next : rest
  startsWithSpace line = case Text.uncons line of
    Just (character, _) -> isSpace character
    Nothing -> False

trim :: String -> String
trim = reverse . dropWhile (\c -> c == '\n' || c == '\r' || c == ' ') . reverse
