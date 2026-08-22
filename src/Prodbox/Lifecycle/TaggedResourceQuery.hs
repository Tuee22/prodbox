{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.36: the bounded, cursor-following Resource Groups Tagging API
-- listing the cascade's terminal escape audit executes through the Provider
-- Worker.
--
-- The existing postflight sweep in "Prodbox.Lifecycle.TagSweep" reads only the
-- first response body and never looks at @PaginationToken@, so an account with
-- more owned resources than one page returns a partial listing that reads as a
-- complete one.  The compiled audit cannot inherit that: its whole claim is
-- that nothing escaped, and a short answer is exactly how that claim goes
-- wrong.
--
-- Three rules bound this listing.
--
--   * __One filter per call.__  The Tagging API intersects the filters inside
--     one call, and the audit's field of view is their union, so a query here
--     carries exactly one tag filter and the union is taken by the caller.
--   * __Truncation fails; it never shortens.__  Exceeding
--     'maximumTaggedResourcePages', or being handed the same cursor twice,
--     returns a failure rather than the rows gathered so far.
--   * __An unreadable body is not an empty one.__  Every parse failure stays a
--     'Left', which the audit lowers to an unanswered query and never to a
--     clean surface.
module Prodbox.Lifecycle.TaggedResourceQuery
  ( TaggedResourceFilter (..)
  , taggedResourceFilterArgument
  , TaggedResourceQueryInput (..)
  , TaggedResourceEntry (..)
  , TaggedResourcePage (..)
  , TaggedResourceListing (..)
  , maximumTaggedResourcePages
  , taggedResourceQueryArgs
  , parseTaggedResourcePage
  , discoverTaggedResources
  )
where

import Data.Aeson (Value (..), eitherDecode)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Numeric.Natural (Natural)
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import System.Exit (ExitCode (..))

-- | One tag filter.  Key-only asks for the family at any value; the pair form
-- asks for one exact value.
data TaggedResourceFilter
  = TaggedResourceTagKeyFilter !Text
  | TaggedResourceTagPairFilter !Text !Text
  deriving (Eq, Ord, Show)

-- | The single @--tag-filters@ argument value this filter sends.
taggedResourceFilterArgument :: TaggedResourceFilter -> String
taggedResourceFilterArgument filterValue = case filterValue of
  TaggedResourceTagKeyFilter key -> "Key=" ++ Text.unpack key
  TaggedResourceTagPairFilter key value ->
    "Key=" ++ Text.unpack key ++ ",Values=" ++ Text.unpack value

data TaggedResourceQueryInput = TaggedResourceQueryInput
  { taggedResourceQueryEnvironment :: [(String, String)]
  , taggedResourceQueryWorkingDirectory :: Maybe FilePath
  , taggedResourceQueryFilter :: TaggedResourceFilter
  }
  deriving (Eq, Show)

-- | One returned resource with its complete tag set.
data TaggedResourceEntry = TaggedResourceEntry
  { taggedResourceEntryArn :: !Text
  , taggedResourceEntryTags :: ![(Text, Text)]
  }
  deriving (Eq, Show)

-- | One response body: its rows and the cursor to the next page, if any.
--
-- The API returns an empty-string token to mean \"no more pages\", which is
-- normalized to 'Nothing' here so a caller cannot loop on it.
data TaggedResourcePage = TaggedResourcePage
  { taggedResourcePageEntries :: ![TaggedResourceEntry]
  , taggedResourcePageNextToken :: !(Maybe Text)
  }
  deriving (Eq, Show)

-- | A complete listing and the number of pages it took.
data TaggedResourceListing = TaggedResourceListing
  { taggedResourceListingEntries :: ![TaggedResourceEntry]
  , taggedResourceListingPages :: !Natural
  }
  deriving (Eq, Show)

-- | The page bound.  A listing that needs more pages than this fails rather
-- than returning a prefix: an audited account holding this many owned
-- resources is itself a fact worth refusing on.
maximumTaggedResourcePages :: Natural
maximumTaggedResourcePages = 100

taggedResourceQueryArgs :: TaggedResourceFilter -> Maybe Text -> [String]
taggedResourceQueryArgs filterValue cursor =
  [ "resourcegroupstaggingapi"
  , "get-resources"
  , "--output"
  , "json"
  , "--tag-filters"
  , taggedResourceFilterArgument filterValue
  ]
    ++ concat
      [ ["--pagination-token", Text.unpack token]
      | Just token <- [cursor]
      ]

-- | Read one response body.
--
-- A payload with no readable @ResourceTagMappingList@ is unparseable rather
-- than empty, and an entry with no @ResourceARN@ makes the whole page
-- unreadable: silently dropping it would shorten the listing in exactly the
-- direction that turns residue into absence.
parseTaggedResourcePage :: String -> Either String TaggedResourcePage
parseTaggedResourcePage payload = do
  value <- eitherDecode (BL8.pack payload) :: Either String Value
  case value of
    Object obj -> do
      entries <- case KeyMap.lookup "ResourceTagMappingList" obj of
        Just (Array rows) -> traverse parseEntry (Vector.toList rows)
        Just _ ->
          Left
            "aws resourcegroupstaggingapi payload field `ResourceTagMappingList` is not an array"
        Nothing ->
          Left
            "aws resourcegroupstaggingapi payload has no `ResourceTagMappingList` key"
      cursor <- case KeyMap.lookup "PaginationToken" obj of
        Nothing -> Right Nothing
        Just Null -> Right Nothing
        Just (String token)
          | Text.null token -> Right Nothing
          | otherwise -> Right (Just token)
        Just _ ->
          Left
            "aws resourcegroupstaggingapi payload field `PaginationToken` is not a string"
      Right
        TaggedResourcePage
          { taggedResourcePageEntries = entries
          , taggedResourcePageNextToken = cursor
          }
    _ -> Left "aws resourcegroupstaggingapi payload is not a JSON object"
 where
  parseEntry entry = case entry of
    Object obj -> case KeyMap.lookup "ResourceARN" obj of
      Just (String arn)
        | not (Text.null arn) -> do
            tags <- case KeyMap.lookup "Tags" obj of
              Nothing -> Right []
              Just (Array rows) -> traverse parseTag (Vector.toList rows)
              Just _ ->
                Left
                  "aws resourcegroupstaggingapi entry field `Tags` is not an array"
            Right (TaggedResourceEntry arn tags)
      _ ->
        Left
          "aws resourcegroupstaggingapi entry has no readable `ResourceARN`"
    _ -> Left "aws resourcegroupstaggingapi entry is not a JSON object"

  parseTag tag = case tag of
    Object obj -> case (KeyMap.lookup "Key" obj, KeyMap.lookup "Value" obj) of
      (Just (String key), Just (String value))
        | not (Text.null key) -> Right (key, value)
      (Just (String key), Nothing)
        | not (Text.null key) -> Right (key, "")
      _ -> Left "aws resourcegroupstaggingapi tag has no readable `Key`"
    _ -> Left "aws resourcegroupstaggingapi tag is not a JSON object"

-- | Follow the cursor to exhaustion, or fail.
discoverTaggedResources
  :: TaggedResourceQueryInput -> IO (Either String TaggedResourceListing)
discoverTaggedResources input = collect Nothing [] [] 0
 where
  collect cursor seen accumulated pages
    | pages >= maximumTaggedResourcePages =
        pure
          ( Left
              ( "aws resourcegroupstaggingapi listing exceeded its "
                  ++ show maximumTaggedResourcePages
                  ++ "-page bound; a partial listing is not an answer"
              )
          )
    | otherwise = do
        result <- runPage cursor
        case result of
          Left detail -> pure (Left detail)
          Right page ->
            let gathered = accumulated ++ taggedResourcePageEntries page
                consumed = pages + 1
             in case taggedResourcePageNextToken page of
                  Nothing ->
                    pure
                      ( Right
                          TaggedResourceListing
                            { taggedResourceListingEntries = gathered
                            , taggedResourceListingPages = consumed
                            }
                      )
                  Just next
                    | next `elem` seen ->
                        pure
                          ( Left
                              "aws resourcegroupstaggingapi returned a pagination cursor it had already returned"
                          )
                    | otherwise ->
                        collect (Just next) (next : seen) gathered consumed

  runPage cursor = do
    result <-
      captureSubprocessResult
        Subprocess
          { subprocessPath = "aws"
          , subprocessArguments =
              taggedResourceQueryArgs (taggedResourceQueryFilter input) cursor
          , subprocessEnvironment = Just (taggedResourceQueryEnvironment input)
          , subprocessWorkingDirectory = taggedResourceQueryWorkingDirectory input
          }
    pure $ case result of
      Failure err -> Left ("failed to start `aws resourcegroupstaggingapi`: " ++ err)
      Success output -> case processExitCode output of
        ExitFailure _ ->
          Left
            ( "aws resourcegroupstaggingapi get-resources failed: "
                ++ processStderr output
                ++ processStdout output
            )
        ExitSuccess -> parseTaggedResourcePage (processStdout output)
