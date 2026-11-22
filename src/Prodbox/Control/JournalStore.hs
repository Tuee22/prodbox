{-# LANGUAGE OverloadedStrings #-}

-- | The local scope's durable operation journal: an append-only directory of
-- small records under the retained root, plus a history marker written with
-- the first record and never removed. A reader turns what it finds into a
-- 'JournalObservation' for "Prodbox.Lifecycle.AdmissionHistory"; it never
-- guesses. An unreadable, undecodable or foreign entry makes the whole journal
-- unobservable, and a missing journal directory whose marker survives is
-- reported as missing existing history.
module Prodbox.Control.JournalStore
  ( journalDirectory
  , historyMarkerPath
  , appendIntent
  , appendSettlement
  , observeJournal
  , validOperationName
  ) where

import Control.Exception (IOException, try)
import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower, isDigit)
import Data.List (isSuffixOf, nub, sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.AdmissionHistory (JournalObservation (..), OperationState (..))
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  , renameFile
  )
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

journalDirectory :: FilePath -> FilePath
journalDirectory root = root </> "authority" </> "journal"

historyMarkerPath :: FilePath -> FilePath
historyMarkerPath root = root </> "authority" </> "history-marker"

validOperationName :: Text -> Bool
validOperationName name =
  not (Text.null name)
    && Text.length name <= 64
    && Text.all (\c -> isAsciiLower c || isDigit c || c == '-') name

data Entry = Entry Text OperationState

encodeEntry :: Text -> OperationState -> ByteString.ByteString
encodeEntry name state =
  LazyByteString.toStrict
    ( Aeson.encode
        ( Aeson.object
            [ "schema_version" .= (1 :: Int)
            , "operation" .= name
            , "state"
                .= (case state of OperationSettled -> "settled"; OperationUnresolved -> "unresolved" :: Text)
            ]
        )
    )

decodeEntry :: ByteString.ByteString -> Maybe Entry
decodeEntry bytes = do
  value <- Aeson.decodeStrict bytes
  AesonTypes.parseMaybe
    ( Aeson.withObject "entry" $ \object -> do
        version <- object .: "schema_version" :: AesonTypes.Parser Int
        name <- object .: "operation"
        state <- object .: "state" :: AesonTypes.Parser Text
        if version /= 1 || not (validOperationName name)
          then fail "foreign entry"
          else case state of
            "settled" -> pure (Entry name OperationSettled)
            "unresolved" -> pure (Entry name OperationUnresolved)
            _ -> fail "unknown state"
    )
    value

nextSequence :: FilePath -> IO (Either IOException Int)
nextSequence directory = do
  listed <- try (listDirectory directory)
  pure $ case listed of
    Left failure -> Left failure
    Right names ->
      Right
        ( 1
            + maximum
              ( 0
                  : [ read (take 8 name)
                    | name <- names
                    , ".json" `isSuffixOf` name
                    , all isDigit (take 8 name)
                    , length name > 8
                    ]
              )
        )

appendRecord :: FilePath -> Text -> OperationState -> IO (Either String ())
appendRecord root name state
  | not (validOperationName name) = pure (Left "invalid operation name")
  | otherwise = do
      let directory = journalDirectory root
      written <-
        try
          ( do
              createDirectoryIfMissing True directory
              sequenceResult <- nextSequence directory
              sequenceNumber <- either ioError pure sequenceResult
              let padded = replicate (8 - length (show sequenceNumber)) '0' ++ show sequenceNumber
                  final = directory </> (padded ++ "-" ++ Text.unpack name ++ ".json")
                  temporary = directory </> ("." ++ padded ++ ".tmp")
              ByteString.writeFile temporary (encodeEntry name state)
              setFileMode temporary 0o600
              renameFile temporary final
              ByteString.writeFile (historyMarkerPath root) "history\n"
          )
      pure (either (\failure -> Left (show (failure :: IOException))) Right written)

-- | Register an operation's intent. The marker is written with the first
-- record, so it never exists without history having existed.
appendIntent :: FilePath -> Text -> IO (Either String ())
appendIntent root name = appendRecord root name OperationUnresolved

-- | Record that an operation reached a terminal state; it never edits the
-- earlier intent.
appendSettlement :: FilePath -> Text -> IO (Either String ())
appendSettlement root name = appendRecord root name OperationSettled

observeJournal :: FilePath -> IO JournalObservation
observeJournal root = do
  let directory = journalDirectory root
  present <- try (doesDirectoryExist directory) :: IO (Either IOException Bool)
  case present of
    Left failure ->
      pure (JournalUnobservable (Text.pack ("journal location unreadable: " ++ take 80 (show failure))))
    Right False -> do
      marker <- try (doesFileExist (historyMarkerPath root)) :: IO (Either IOException Bool)
      pure $ case marker of
        Left failure -> JournalUnobservable (Text.pack ("history marker unreadable: " ++ take 80 (show failure)))
        Right survives -> JournalMissing survives
    Right True -> do
      listed <- try (listDirectory directory) :: IO (Either IOException [FilePath])
      case listed of
        Left failure -> pure (JournalUnobservable (Text.pack ("journal unreadable: " ++ take 80 (show failure))))
        Right names -> do
          let recordNames = sort [name | name <- names, ".json" `isSuffixOf` name]
              foreign' = [name | name <- names, not (".json" `isSuffixOf` name), take 1 name /= "."]
          if not (null foreign')
            then pure (JournalUnobservable "the journal holds an entry that is not a record")
            else do
              decoded <- mapM (readEntry directory) recordNames
              pure $ case sequence decoded of
                Nothing -> JournalUnobservable "a journal record could not be read or decoded"
                Just entries ->
                  let finalState = Map.fromList [(name, state) | Entry name state <- entries]
                      order = nub [name | Entry name _ <- entries]
                   in JournalRead [(name, finalState Map.! name) | name <- order]
 where
  readEntry directory name = do
    bytes <-
      try (ByteString.readFile (directory </> name)) :: IO (Either IOException ByteString.ByteString)
    pure (either (const Nothing) decodeEntry bytes)
