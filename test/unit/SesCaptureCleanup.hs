{-# LANGUAGE OverloadedStrings #-}

module SesCaptureCleanup (sesCaptureCleanupSuite) where

import Data.Aeson (Value, encode, object, (.=))
import Data.Aeson.Types (Pair)
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.Teardown.ResourceScopeBindings
import Prodbox.Ses.Capture (CaptureRunner (..))
import Prodbox.Ses.CaptureCleanup
import Prodbox.Settings.Coordinate (S3BucketName, mkS3BucketName)
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))
import TestSupport

sesCaptureCleanupSuite :: SuiteBuilder ()
sesCaptureCleanupSuite = describe "Sprint 5.53 version-aware registered invite cleanup" $ do
  it "reads old and noncurrent versions and deletes only the exact recipient" $ do
    (runner, calls, remaining) <-
      fixture
        [("inbound/mail", "old-version", wanted), ("inbound/mail", "new-version", unrelated)]
        False
    before <- mustIO =<< observeCapturedMailVersions runner exactScope
    length before `shouldBe` 1
    deleteCapturedMailVersions runner exactScope before >>= (`shouldBe` Right ())
    observeCapturedMailVersions runner exactScope >>= (`shouldBe` Right [])
    remaining >>= (`shouldBe` [("inbound/mail", "new-version", unrelated)])
    observed <- calls
    filter (elem "delete-object") observed
      `shouldBe` [
                   [ "s3api"
                   , "delete-object"
                   , "--bucket"
                   , "fixture-capture-mail"
                   , "--key"
                   , "inbound/mail"
                   , "--version-id"
                   , "old-version"
                   ]
                 ]
    filter (elem "get-object") observed `shouldSatisfy` all (elem "--version-id")
  it "keeps a failed version deletion unresolved and visible to independent read-back" $ do
    (runner, _, _) <- fixture [("inbound/mail", "old-version", wanted)] True
    found <- mustIO =<< observeCapturedMailVersions runner exactScope
    deleteCapturedMailVersions runner exactScope found >>= (`shouldSatisfy` isLeft)
    after <- mustIO =<< observeCapturedMailVersions runner exactScope
    map capturedMailVersionIdentity after `shouldBe` map capturedMailVersionIdentity found
  it "treats a complete empty listing with bodyless delete markers as no mail data" $ do
    (runner, calls) <- pagesRunner [page [] [versionRow "inbound/tombstone" "marker"] False []]
    observeCapturedMailVersions runner exactScope >>= (`shouldBe` Right [])
    calls >>= (`shouldSatisfy` all (notElem "get-object"))
  it "follows both provider version cursors before concluding absence" $ do
    (runner, calls) <-
      pagesRunner
        [ page
            []
            []
            True
            ["NextKeyMarker" .= ("inbound/mail" :: Text), "NextVersionIdMarker" .= ("version-a" :: Text)]
        , page [] [] False []
        ]
    observeCapturedMailVersions runner exactScope >>= (`shouldBe` Right [])
    observed <- calls
    length observed `shouldBe` 2
    last observed
      `shouldSatisfy` isInfixOf ["--key-marker", "inbound/mail", "--version-id-marker", "version-a"]
  it "refuses a repeated pagination cursor instead of sampling" $ do
    let repeating =
          page
            []
            []
            True
            ["NextKeyMarker" .= ("inbound/mail" :: Text), "NextVersionIdMarker" .= ("version-a" :: Text)]
    (runner, _) <- pagesRunner [repeating, repeating]
    observeCapturedMailVersions runner exactScope >>= (`shouldSatisfy` isLeft)
  it "bounds all-age data-version reads before reading any message" $ do
    (runner, calls) <-
      pagesRunner
        [ page
            [ versionRow "inbound/mail" (Text.pack (show index)) | index <- [1 .. maximumCleanupMailVersions + 1]
            ]
            []
            False
            []
        ]
    observeCapturedMailVersions runner exactScope >>= (`shouldSatisfy` isLeft)
    calls >>= (`shouldSatisfy` all (notElem "get-object"))
  it "refuses malformed rows, incomplete disposition, foreign prefix and oversized messages" $
    mapM_
      ( \listing -> do
          (runner, _) <- pagesRunner [listing]
          observeCapturedMailVersions runner exactScope >>= (`shouldSatisfy` isLeft)
      )
      [ object []
      , object ["IsTruncated" .= False, "Versions" .= [object ["Key" .= ("inbound/mail" :: Text)]]]
      , page [versionRow "foreign/mail" "version-a"] [] False []
      , page
          [ object
              [ "Key" .= ("inbound/mail" :: Text)
              , "VersionId" .= ("version-a" :: Text)
              , "Size" .= (1048577 :: Int)
              ]
          ]
          []
          False
          []
      , object ["IsTruncated" .= False, "Versions" .= ("malformed" :: Text)]
      ]
  it "never turns denied listing or unreadable mail into absence" $ do
    let denied = CaptureRunner (const (pure (ProcessOutput (ExitFailure 254) "" "fixture denied"))) (pure 0)
    observeCapturedMailVersions denied exactScope >>= (`shouldSatisfy` isLeft)
    (listed, _) <- pagesRunner [page [versionRow "inbound/mail" "version-a"] [] False []]
    observeCapturedMailVersions listed exactScope >>= (`shouldSatisfy` isLeft)
  it "supports a bounded validation-domain family without selecting unrelated recipients" $ do
    let domainScope = must (mkInviteMailScope bucket (ValidationInviteDomain "receive.example.test"))
    (runner, _, _) <-
      fixture
        [ ("inbound/one", "v1", wanted)
        , ("inbound/two", "v2", "To: operator@receive.example.test\r\n\r\nbody")
        ]
        False
    found <- mustIO =<< observeCapturedMailVersions runner domainScope
    length found `shouldBe` 1
 where
  wanted = "To: test-abc123@receive.example.test\r\n\r\naction-token-secret"
  unrelated = "To: test-def456@receive.example.test\r\n\r\nforeign-token-secret"

exactScope :: InviteMailScope
exactScope = must (mkInviteMailScope bucket (ExactInviteRecipient "test-abc123@receive.example.test"))

bucket :: S3BucketName
bucket = must (mkS3BucketName "fixture-capture-mail")

versionRow :: Text -> Text -> Value
versionRow key version =
  object
    [ "Key" .= key
    , "VersionId" .= version
    , "Size" .= (100 :: Int)
    , "IsLatest" .= False
    , "LastModified" .= ("2020-01-01T00:00:00Z" :: Text)
    ]

page :: [Value] -> [Value] -> Bool -> [Pair] -> Value
page versions markers truncated extra =
  object
    (["Versions" .= versions, "DeleteMarkers" .= markers, "IsTruncated" .= truncated] <> extra)

pagesRunner :: [Value] -> IO (CaptureRunner, IO [[String]])
pagesRunner initial = do
  pages <- newIORef initial
  calls <- newIORef []
  let run arguments = do
        modifyIORef' calls (<> [arguments])
        pending <- readIORef pages
        case (arguments, pending) of
          ("s3api" : "list-object-versions" : _, first : rest) -> do
            modifyIORef' pages (const rest)
            pure (success first)
          _ -> pure (ProcessOutput (ExitFailure 254) "" "fixture unreadable")
  pure (CaptureRunner run (pure 0), readIORef calls)

fixture
  :: [(Text, Text, String)]
  -> Bool
  -> IO (CaptureRunner, IO [[String]], IO [(Text, Text, String)])
fixture initial failDelete = do
  store <- newIORef initial
  calls <- newIORef []
  let run arguments = do
        modifyIORef' calls (<> [arguments])
        current <- readIORef store
        let key = Text.pack (argument "--key" arguments)
            version = Text.pack (argument "--version-id" arguments)
            matches (candidateKey, candidateVersion, _) = candidateKey == key && candidateVersion == version
        case arguments of
          "s3api" : "list-object-versions" : _ ->
            pure (success (page [versionRow k v | (k, v, _) <- current] [] False []))
          "s3api" : "get-object" : _ -> case filter matches current of
            [(_, _, body)] -> writeFile (last arguments) body >> pure (success (object []))
            _ -> pure (ProcessOutput (ExitFailure 254) "" "missing version")
          "s3api" : "delete-object" : _
            | failDelete -> pure (ProcessOutput (ExitFailure 254) "" "fixture denied")
            | otherwise -> do
                modifyIORef' store (filter (not . matches))
                pure (success (object []))
          _ -> pure (ProcessOutput (ExitFailure 254) "" "unexpected call")
  pure (CaptureRunner run (pure 0), readIORef calls, readIORef store)

argument :: String -> [String] -> String
argument key arguments = case dropWhile (/= key) arguments of
  _ : value : _ -> value
  _ -> ""

success :: Value -> ProcessOutput
success value = ProcessOutput ExitSuccess (LazyChar8.unpack (encode value)) ""

must :: (Show error) => Either error value -> value
must = either (error . show) id

mustIO :: (Show error) => Either error value -> IO value
mustIO = either (fail . show) pure
