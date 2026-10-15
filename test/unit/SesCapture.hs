{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 5.53: the SES capture reader walks the whole listing and reads only
-- recent objects.
--
-- The capture bucket keeps every message the receive domain is sent and nothing
-- expires it, while an invite recipient carries a per-run nonce, so an old
-- message cannot be a run's. The reader used to refuse once the bucket held more
-- than a hundred objects, which a bucket that only ever grows reaches without
-- anything having gone wrong. These cases script the AWS CLI's pages and clock.
module SesCapture (sesCaptureSuite) where

import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Either (fromLeft)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (intercalate, isInfixOf)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (POSIXTime)
import Prodbox.Result (Result (..), resultToEither)
import Prodbox.Ses.Capture
import Prodbox.Ses.Readiness (sesCaptureKeyPrefix)
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))
import System.Timeout (timeout)
import TestSupport

-- | One page of a scripted listing: the objects (key, modification time as the
-- CLI prints it, or none) and the token that continues it.
data Page = Page
  { pageObjects :: [(String, Maybe String)]
  , pageNext :: Maybe String
  }

-- | The clock every case runs at.
fixedNow :: POSIXTime
fixedNow = fromMaybe 0 (parseListedTime "2026-10-08T12:00:00+00:00")

-- | An hour old, and two days old.
recentTime, oldTime :: String
recentTime = "2026-10-08T11:00:00+00:00"
oldTime = "2026-10-06T11:00:00+00:00"

recipient :: Text
recipient = "test-ab12@receive.example.test"

-- | A message addressed to the given mailbox.
mailTo :: String -> String
mailTo mailbox = "From: a@b.test\r\nTo: " ++ mailbox ++ "\r\nSubject: invite\r\n\r\nbody\r\n"

listingJson :: Page -> String
listingJson page =
  "{\"Contents\": ["
    ++ intercalate "," (map objectJson (pageObjects page))
    ++ "]"
    ++ maybe "" (\token -> ", \"NextToken\": \"" ++ token ++ "\"") (pageNext page)
    ++ "}"
 where
  objectJson (key, modified) =
    "{\"Key\": \""
      ++ key
      ++ "\""
      ++ maybe "" (\time -> ", \"LastModified\": \"" ++ time ++ "\"") modified
      ++ "}"

-- | What a child process's output looks like to the caller: one Char per byte of
-- the UTF-8 the CLI wrote, so a non-ASCII key arrives as several Chars.
asChildOutput :: String -> String
asChildOutput = BL8.unpack . BL.fromStrict . TextEncoding.encodeUtf8 . Text.pack

ok :: String -> ProcessOutput
ok body = ProcessOutput ExitSuccess body ""

-- | The value following a flag in a command line.
flagValue :: String -> [String] -> Maybe String
flagValue flag arguments = lookup flag (zip arguments (drop 1 arguments))

-- | A runner that serves the given pages by continuation token, serves object
-- bodies by key, accepts deletes, records every command, and tells the time.
scriptedBucket
  :: [(Maybe String, Page)]
  -> [(String, String)]
  -> IO (CaptureRunner, IORef [[String]])
scriptedBucket pages bodies = do
  calls <- newIORef []
  let run arguments = do
        modifyIORef' calls (++ [arguments])
        case drop 1 arguments of
          "list-objects-v2" : _ -> pure (listPage (flagValue "--starting-token" arguments))
          "get-object" : _ -> readObject arguments
          "delete-object" : _ -> pure (ok "")
          _ -> pure (ProcessOutput (ExitFailure 2) "" "unexpected")
      listPage token =
        maybe
          (ProcessOutput (ExitFailure 1) "" "no such page")
          (ok . asChildOutput . listingJson)
          (lookup token pages)
      readObject arguments =
        case (flagValue "--key" arguments >>= (`lookup` bodies), reverse arguments) of
          (Just body, target : _) -> writeFile target body >> pure (ok "")
          _ -> pure (ProcessOutput (ExitFailure 1) "" "NoSuchKey")
  pure (CaptureRunner {runCaptureAws = run, captureNow = pure fixedNow}, calls)

-- | A runner that answers every command with one fixed output.
fixedAnswer :: ProcessOutput -> CaptureRunner
fixedAnswer output = CaptureRunner {runCaptureAws = \_ -> pure output, captureNow = pure fixedNow}

-- | The object keys a run of commands read.
keysRead :: [[String]] -> [String]
keysRead calls =
  [ key
  | arguments <- calls
  , take 2 arguments == ["s3api", "get-object"]
  , Just key <- [flagValue "--key" arguments]
  ]

-- | The listing commands a run issued.
listingsIssued :: [[String]] -> [[String]]
listingsIssued calls = [arguments | arguments <- calls, take 2 arguments == ["s3api", "list-objects-v2"]]

failureOf :: Result value -> String
failureOf result = fromLeft "" (resultToEither result)

-- | One page that holds the given keys, all modified at the given time.
pageOfKeys :: String -> [String] -> Page
pageOfKeys time keys = Page [(key, Just time) | key <- keys] Nothing

-- | A bucket of exactly this many old objects, spread over pages of a thousand.
oldPages :: Int -> [(Maybe String, Page)]
oldPages count =
  [ ( if n == 0 then Nothing else Just ("p" ++ show n)
    , Page
        [("inbound/o" ++ show n ++ "-" ++ show k, Just oldTime) | k <- [1 .. size n]]
        (if n == lastPage then Nothing else Just ("p" ++ show (n + 1)))
    )
  | n <- [0 .. lastPage]
  ]
 where
  lastPage = (count - 1) `div` 1000
  size n = if n == lastPage then count - lastPage * 1000 else 1000

-- | Recent objects, this many on each of several pages.
recentPages :: [Int] -> [(Maybe String, Page)]
recentPages sizes =
  [ ( if n == 0 then Nothing else Just ("r" ++ show n)
    , Page
        [("inbound/r" ++ show n ++ "-" ++ show k, Just recentTime) | k <- [1 .. size]]
        (if n == length sizes - 1 then Nothing else Just ("r" ++ show (n + 1)))
    )
  | (n, size) <- zip [0 ..] sizes
  ]

-- | Bodies for the keys 'recentPages' names, none of them addressed to the recipient.
bodiesForRecentPages :: [Int] -> [(String, String)]
bodiesForRecentPages sizes =
  [ ("inbound/r" ++ show n ++ "-" ++ show k, mailTo "other@receive.example.test")
  | (n, size) <- zip [0 :: Int ..] sizes
  , k <- [1 .. size]
  ]

sesCaptureSuite :: SuiteBuilder ()
sesCaptureSuite =
  describe "Sprint 5.53 SES capture reader walks the whole listing and reads only recent objects" $ do
    it "reads the recent objects of every page and none of the old ones" $ do
      -- The old objects are addressed to the recipient, so a reader that opened them
      -- would find them first. The match is on the second page.
      let pages =
            [ (Nothing, Page [("inbound/old1", Just oldTime), ("inbound/recent1", Just recentTime)] (Just "t1"))
            , (Just "t1", Page [("inbound/old2", Just oldTime), ("inbound/target", Just recentTime)] Nothing)
            ]
          bodies =
            [ ("inbound/old1", mailTo "test-ab12@receive.example.test")
            , ("inbound/old2", mailTo "test-ab12@receive.example.test")
            , ("inbound/recent1", mailTo "someone-else@receive.example.test")
            , ("inbound/target", mailTo "test-ab12@receive.example.test")
            ]
      (runner, calls) <- scriptedBucket pages bodies
      found <- findCapturedEmail runner "bucket" recipient
      fmap (fmap capturedEmailKey) found `shouldBe` Success (Just "inbound/target")
      commands <- readIORef calls
      keysRead commands `shouldBe` ["inbound/recent1", "inbound/target"]
      -- The second page is asked for by the token the first one returned.
      map (flagValue "--starting-token") (listingsIssued commands) `shouldBe` [Nothing, Just "t1"]
      -- The reap path selects by the same rule.
      (reaper, reaperCalls) <- scriptedBucket pages bodies
      capturedEmailKeysFor reaper "bucket" recipient `shouldReturn` Success ["inbound/target"]
      fmap keysRead (readIORef reaperCalls) `shouldReturn` ["inbound/recent1", "inbound/target"]

    it "asks for the bucket's inbound prefix a thousand objects at a time, as JSON" $ do
      (runner, calls) <- scriptedBucket [(Nothing, Page [] Nothing)] []
      _ <- findCapturedEmail runner "bucket" recipient
      commands <- readIORef calls
      case listingsIssued commands of
        [command] -> do
          flagValue "--bucket" command `shouldBe` Just "bucket"
          flagValue "--prefix" command `shouldBe` Just sesCaptureKeyPrefix
          flagValue "--max-items" command `shouldBe` Just "1000"
          flagValue "--output" command `shouldBe` Just "json"
        other -> expectationFailure ("expected one listing command, got " ++ show other)
      -- The limits the plan states, as numbers rather than as the constants themselves.
      maximumInboundObjects `shouldBe` 10000
      maximumRecentInboundObjects `shouldBe` 20
      captureRecencyWindow `shouldBe` (6 * 60 * 60)
      captureWindowStatement `shouldBe` "modified within the last 6 hours"

    it "treats an object whose time it cannot read as recent, and the window's edge as inside it" $ do
      let pages =
            [
              ( Nothing
              , Page
                  [ ("inbound/no-time", Nothing)
                  , ("inbound/garbled", Just "yesterday-ish")
                  , ("inbound/edge-inside", Just "2026-10-08T06:00:00+00:00")
                  , ("inbound/edge-outside", Just "2026-10-08T05:59:59+00:00")
                  ]
                  Nothing
              )
            ]
          bodies =
            [ (key, mailTo "other@receive.example.test")
            | key <- ["inbound/no-time", "inbound/garbled", "inbound/edge-inside", "inbound/edge-outside"]
            ]
      (runner, calls) <- scriptedBucket pages bodies
      found <- findCapturedEmail runner "bucket" recipient
      found `shouldBe` Success Nothing
      -- Exactly six hours old is read; a second older is not.
      fmap keysRead (readIORef calls)
        `shouldReturn` ["inbound/no-time", "inbound/garbled", "inbound/edge-inside"]

    it
      "is a clean absence for an empty bucket, in either shape the CLI prints, and for one holding only old objects"
      $ do
        (emptyRunner, _) <- scriptedBucket [(Nothing, Page [] Nothing)] []
        findCapturedEmail emptyRunner "bucket" recipient `shouldReturn` Success Nothing
        capturedEmailKeysFor emptyRunner "bucket" recipient `shouldReturn` Success []
        -- Measured against the installed CLI: an empty prefix prints a document with no
        -- Contents key at all.
        let noContents = fixedAnswer (ok "{\"RequestCharged\": null, \"Prefix\": \"inbound/\"}")
        findCapturedEmail noContents "bucket" recipient `shouldReturn` Success Nothing
        capturedEmailKeysFor noContents "bucket" recipient `shouldReturn` Success []
        (oldRunner, oldCalls) <-
          scriptedBucket [(Nothing, pageOfKeys oldTime ["inbound/a", "inbound/b"])] []
        findCapturedEmail oldRunner "bucket" recipient `shouldReturn` Success Nothing
        fmap keysRead (readIORef oldCalls) `shouldReturn` []

    it "reads a key that is not ASCII exactly as the CLI wrote it" $ do
      -- The CLI writes non-ASCII key bytes raw. They reach the reader one Char per byte,
      -- and decoding them as if they were text would double-encode each one, so the
      -- key it then asked for would not exist.
      let key = "inbound/uni\233\26085"
          pages = [(Nothing, Page [(key, Just recentTime)] Nothing)]
      (runner, calls) <- scriptedBucket pages [(key, mailTo "test-ab12@receive.example.test")]
      found <- findCapturedEmail runner "bucket" recipient
      fmap (fmap capturedEmailKey) found `shouldBe` Success (Just (Text.pack key))
      fmap keysRead (readIORef calls) `shouldReturn` [key]

    it "refuses what it cannot walk or cannot afford to read, and only past the stated bounds" $ do
      -- Exactly as many recent objects as it will read, split over two pages: read, all of them.
      let half = maximumRecentInboundObjects `div` 2
          atLimit = [half, half]
          overLimit = [half, half, 1]
      (limit, limitCalls) <- scriptedBucket (recentPages atLimit) (bodiesForRecentPages atLimit)
      findCapturedEmail limit "bucket" recipient `shouldReturn` Success Nothing
      fmap (length . keysRead) (readIORef limitCalls) `shouldReturn` maximumRecentInboundObjects
      -- One more, on a third page, so that only the running total can see it.
      (crowded, crowdedCalls) <- scriptedBucket (recentPages overLimit) (bodiesForRecentPages overLimit)
      crowdedFailure <- findCapturedEmail crowded "bucket" recipient
      failureOf crowdedFailure `shouldSatisfy` isInfixOf "modified within the last 6 hours"
      -- Nothing is read from a bucket it will not read.
      fmap keysRead (readIORef crowdedCalls) `shouldReturn` []
      -- Exactly as many objects as it will walk, however old: walked, nothing read.
      (atWalk, atWalkCalls) <- scriptedBucket (oldPages maximumInboundObjects) []
      findCapturedEmail atWalk "bucket" recipient `shouldReturn` Success Nothing
      fmap (length . listingsIssued) (readIORef atWalkCalls) `shouldReturn` 10
      -- One more is refused.
      (vast, _) <- scriptedBucket (oldPages (maximumInboundObjects + 1)) []
      vastFailure <- capturedEmailKeysFor vast "bucket" recipient
      failureOf vastFailure `shouldSatisfy` isInfixOf ("more than " ++ show maximumInboundObjects)
      -- A listing that never ends is stopped, and does not hang.
      (endless, endlessCalls) <-
        scriptedBucket
          [(Nothing, Page [] (Just "again")), (Just "again", Page [] (Just "again"))]
          []
      endlessOutcome <- timeout 10000000 (findCapturedEmail endless "bucket" recipient)
      endlessOutcome `shouldSatisfy` isJust
      fmap failureOf endlessOutcome `shouldSatisfy` maybe False (isInfixOf "did not end")
      fmap (length . listingsIssued) (readIORef endlessCalls) `shouldReturn` 12

    it
      "fails on a page it cannot list, decode or continue, wherever it is, and on a recent object it cannot read"
      $ do
        let single = [(Nothing, pageOfKeys recentTime ["inbound/a"])]
        -- A page that fails to list.
        (missing, _) <- scriptedBucket [] []
        missingFailure <- findCapturedEmail missing "bucket" recipient
        failureOf missingFailure `shouldSatisfy` isInfixOf "list-objects-v2 exit"
        -- A page that is not JSON.
        garbageFailure <- findCapturedEmail (fixedAnswer (ok "not json")) "bucket" recipient
        failureOf garbageFailure `shouldSatisfy` isInfixOf "could not decode"
        -- A continuation token that is not a string is not the end of the listing.
        tokenFailure <-
          capturedEmailKeysFor (fixedAnswer (ok "{\"Contents\": [], \"NextToken\": 5}")) "bucket" recipient
        failureOf tokenFailure `shouldSatisfy` isInfixOf "not a string"
        -- A later page that cannot be listed ends nothing: the answer is a failure, never
        -- an absence read off the part that was listed.
        let firstOnly = [(Nothing, Page [("inbound/a", Just oldTime)] (Just "t1"))]
        (secondMissing, _) <- scriptedBucket firstOnly []
        secondFailure <- findCapturedEmail secondMissing "bucket" recipient
        failureOf secondFailure `shouldSatisfy` isInfixOf "list-objects-v2 exit"
        reapSecondFailure <- capturedEmailKeysFor secondMissing "bucket" recipient
        failureOf reapSecondFailure `shouldSatisfy` isInfixOf "list-objects-v2 exit"
        -- Nor does a later page that is not JSON.
        let pagedThenGarbled =
              CaptureRunner
                { runCaptureAws = \arguments ->
                    pure
                      ( ok
                          ( maybe
                              (listingJson (Page [("inbound/a", Just oldTime)] (Just "t1")))
                              (const "not json")
                              (flagValue "--starting-token" arguments)
                          )
                      )
                , captureNow = pure fixedNow
                }
        laterGarbage <- capturedEmailKeysFor pagedThenGarbled "bucket" recipient
        failureOf laterGarbage `shouldSatisfy` isInfixOf "could not decode"
        -- A recent object that cannot be read fails the answer rather than being skipped.
        (unreadable, _) <- scriptedBucket single []
        unreadableFailure <- findCapturedEmail unreadable "bucket" recipient
        failureOf unreadableFailure `shouldSatisfy` isInfixOf "get-object exit"
        reapFailure <- capturedEmailKeysFor unreadable "bucket" recipient
        failureOf reapFailure `shouldSatisfy` isInfixOf "get-object exit"
        -- An old object that would be unreadable is never touched, so it fails nothing.
        (unreadableOld, _) <- scriptedBucket [(Nothing, pageOfKeys oldTime ["inbound/a"])] []
        findCapturedEmail unreadableOld "bucket" recipient `shouldReturn` Success Nothing

    it "reads the modification times the AWS CLI prints, and nothing else" $ do
      let at = parseListedTime
      -- The shapes measured against the installed CLI: whole seconds with a numeric
      -- offset, and six fractional digits when S3 reports milliseconds.
      at "2026-10-08T14:03:11+00:00" `shouldSatisfy` isJust
      at "2026-10-07T09:00:00.500000+00:00" `shouldSatisfy` isJust
      -- A trailing Z, which only the CLI's wire timestamp format prints, is read too.
      at "2026-10-08T14:03:11Z" `shouldBe` at "2026-10-08T14:03:11+00:00"
      -- An offset is converted, not ignored.
      at "2026-10-08T16:03:11+02:00" `shouldBe` at "2026-10-08T14:03:11+00:00"
      -- Fractions are kept.
      fmap
        (\half -> half - fromMaybe 0 (at "2026-10-07T09:00:00+00:00"))
        (at "2026-10-07T09:00:00.500000+00:00")
        `shouldBe` Just 0.5
      at "yesterday" `shouldBe` Nothing
      at "" `shouldBe` Nothing
      at "2026-10-08" `shouldBe` Nothing
