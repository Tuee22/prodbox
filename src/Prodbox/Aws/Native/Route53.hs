{-# LANGUAGE OverloadedStrings #-}

-- | Native Route 53 @ChangeResourceRecordSets@, @GetChange@, and authoritative
-- exact-record observation through @ListResourceRecordSets@ (REST-XML). The
-- request body 'renderChangeBatchXml' is a
-- pure, total, byte-identical function of the desired record set — the "exact
-- records" property — with no map, no timestamp, and list order preserved.
--
-- Downstream (NOTE, not 1.62 work): replaces @Dns.hs@'s
-- @changeRoute53ARecordSetInZone@ (including the @aws route53 wait@ that
-- 'getChange' polling replaces).
module Prodbox.Aws.Native.Route53
  ( RecordType (..)
  , ChangeAction (..)
  , ChangeId (..)
  , ChangeStatus (..)
  , ResourceRecordSet (..)
  , Route53Client (..)
  , newRoute53Client
  , route53Endpoint
  , route53Scope
  , changeRecordSetsPath
  , getChangePath
  , listRecordSetsQuery
  , renderChangeBatchXml
  , parseChangeInfoResponse
  , parseGetChangeResponse
  , parseListResourceRecordSetsResponse
  , scanRecordSetsQuery
  , parseScannedResourceRecordSetsResponse
  , ScannedRecordSetPage (..)
  , maximumScannedRecordSetPages
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Prodbox.Aws.CredentialHandle
  ( CredentialHandle
  , credentialHandleSecurityToken
  , toSigV4Credentials
  )
import Prodbox.Aws.Native.Wire
  ( AwsClientError (AwsResponseParseFailure, AwsSigningError)
  , AwsEndpoint (AwsEndpoint)
  , AwsErrorFormat (XmlErrorFormat)
  , AwsScope (AwsScope)
  , AwsTimestamp
  , Idempotency (Idempotent)
  , NativeAwsSender
  , SignedHttpRequest
  , buildSignedRequest
  , performAwsRequest
  )
import Prodbox.Aws.Native.Xml (extractAll, extractFirst, xmlEscape)
import Prodbox.Aws.Region (awsGlobalServiceRegion)
import Text.Read (readMaybe)

data RecordType = RecordA | RecordAAAA | RecordCNAME | RecordTXT | RecordMX
  deriving (Eq, Show)

data ChangeAction = Upsert | CreateRecord | DeleteRecord
  deriving (Eq, Show)

newtype ChangeId = ChangeId Text
  deriving (Eq, Show)

data ChangeStatus = ChangePending | ChangeInsync
  deriving (Eq, Show)

data ResourceRecordSet = ResourceRecordSet
  { rrsName :: !Text
  , rrsType :: !RecordType
  , rrsTtl :: !Int
  , rrsRecords :: ![Text]
  }
  deriving (Eq, Show)

data Route53Client = Route53Client
  { changeResourceRecordSets
      :: Text
      -> [(ChangeAction, ResourceRecordSet)]
      -> IO (Either AwsClientError (ChangeId, ChangeStatus))
  , getChange :: ChangeId -> IO (Either AwsClientError ChangeStatus)
  , listExactResourceRecordSet
      :: Text
      -> Text
      -> RecordType
      -> IO (Either AwsClientError (Maybe ResourceRecordSet))
  , scanResourceRecordSetsByPrefix
      :: Text
      -> Text
      -> RecordType
      -> IO (Either AwsClientError [ResourceRecordSet])
  -- ^ Sprint 7.36: the bounded name-prefix scan a registered DNS record
  -- __family__ needs.  'listExactResourceRecordSet' answers about one known
  -- coordinate; a family's members are not known before the scan, and a
  -- cleanup that must prove a family absent cannot ask about records it has
  -- no name for.  Pagination is bounded by 'maximumScannedRecordSetPages',
  -- and exhausting the bound is an error rather than a truncated answer --
  -- a truncated scan would read as a smaller family, which is exactly the
  -- shape that lets residue report as absence.
  }

newRoute53Client :: CredentialHandle origin -> NativeAwsSender -> Route53Client
newRoute53Client handle sender =
  Route53Client
    { changeResourceRecordSets = runChangeRecordSets handle sender
    , getChange = runGetChange handle sender
    , listExactResourceRecordSet = runListExactResourceRecordSet handle sender
    , scanResourceRecordSetsByPrefix = runScanRecordSetsByPrefix handle sender
    }

route53Endpoint :: AwsEndpoint
route53Endpoint = AwsEndpoint "https://route53.amazonaws.com" "route53.amazonaws.com"

-- | Route 53 signs under AWS's fixed global-service region.
route53Scope :: AwsScope
route53Scope = AwsScope awsGlobalServiceRegion "route53"

changeRecordSetsPath :: Text -> ByteString
changeRecordSetsPath zoneId =
  encodeUtf8 ("/2013-04-01/hostedzone/" <> bareZoneId zoneId <> "/rrset/")

getChangePath :: ChangeId -> ByteString
getChangePath (ChangeId changeId) =
  encodeUtf8 ("/2013-04-01/change/" <> bareChangeId changeId)

-- | The bounded authoritative lookup query. Route 53 returns the first record
-- at or after this name/type; the response parser therefore checks that the
-- returned record is the exact requested coordinate before exposing it.
listRecordSetsQuery :: Text -> RecordType -> [(ByteString, ByteString)]
listRecordSetsQuery recordName recordType =
  [ ("name", ensureTrailingDot (encodeUtf8 recordName))
  , ("type", renderRecordType recordType)
  , ("maxitems", "1")
  ]

bareZoneId :: Text -> Text
bareZoneId raw =
  let trimmed = Text.dropWhile (== '/') raw
   in Text.dropWhile (== '/') (fromMaybe trimmed (Text.stripPrefix "hostedzone/" trimmed))

bareChangeId :: Text -> Text
bareChangeId raw =
  let trimmed = Text.dropWhile (== '/') raw
   in Text.dropWhile (== '/') (fromMaybe trimmed (Text.stripPrefix "change/" trimmed))

-- | The deterministic change-batch body. Byte-identical for identical input.
renderChangeBatchXml :: [(ChangeAction, ResourceRecordSet)] -> ByteString
renderChangeBatchXml changes =
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    <> "<ChangeResourceRecordSetsRequest xmlns=\"https://route53.amazonaws.com/doc/2013-04-01/\">"
    <> "<ChangeBatch><Changes>"
    <> BS.concat (map renderChange changes)
    <> "</Changes></ChangeBatch></ChangeResourceRecordSetsRequest>"
 where
  renderChange (action, rrs) =
    "<Change><Action>"
      <> renderAction action
      <> "</Action><ResourceRecordSet>"
      <> "<Name>"
      <> xmlEscape (ensureTrailingDot (encodeUtf8 (rrsName rrs)))
      <> "</Name>"
      <> "<Type>"
      <> renderRecordType (rrsType rrs)
      <> "</Type>"
      <> "<TTL>"
      <> BS8.pack (show (rrsTtl rrs))
      <> "</TTL>"
      <> "<ResourceRecords>"
      <> BS.concat
        [ "<ResourceRecord><Value>" <> xmlEscape (encodeUtf8 value) <> "</Value></ResourceRecord>"
        | value <- rrsRecords rrs
        ]
      <> "</ResourceRecords></ResourceRecordSet></Change>"
  renderAction Upsert = "UPSERT"
  renderAction CreateRecord = "CREATE"
  renderAction DeleteRecord = "DELETE"

renderRecordType :: RecordType -> ByteString
renderRecordType recordType = case recordType of
  RecordA -> "A"
  RecordAAAA -> "AAAA"
  RecordCNAME -> "CNAME"
  RecordTXT -> "TXT"
  RecordMX -> "MX"

ensureTrailingDot :: ByteString -> ByteString
ensureTrailingDot name
  | BS8.null name = name
  | BS8.last name == '.' = name
  | otherwise = name <> "."

parseChangeInfoResponse :: ByteString -> Either String (ChangeId, ChangeStatus)
parseChangeInfoResponse body = do
  info <- note "Route53: missing <ChangeInfo>" (extractFirst "<ChangeInfo>" "</ChangeInfo>" body)
  changeId <- note "Route53: missing <Id>" (extractFirst "<Id>" "</Id>" info)
  status <- note "Route53: missing <Status>" (extractFirst "<Status>" "</Status>" info)
  parsedStatus <- parseChangeStatus status
  pure (ChangeId (decodeUtf8 changeId), parsedStatus)

parseGetChangeResponse :: ByteString -> Either String ChangeStatus
parseGetChangeResponse body = do
  info <- note "Route53: missing <ChangeInfo>" (extractFirst "<ChangeInfo>" "</ChangeInfo>" body)
  status <- note "Route53: missing <Status>" (extractFirst "<Status>" "</Status>" info)
  parseChangeStatus status

-- | Parse the bounded list response as an exact lookup. An empty collection or
-- a lexicographically subsequent first record means the requested record is
-- absent. An exact alias/routing-policy record, malformed TTL, or empty value
-- set is unrepresentable and fails closed instead of being reported missing.
parseListResourceRecordSetsResponse
  :: Text
  -> RecordType
  -> ByteString
  -> Either String (Maybe ResourceRecordSet)
parseListResourceRecordSetsResponse requestedName requestedType body = do
  if "<ListResourceRecordSetsResponse" `BS.isInfixOf` body
    then Right ()
    else Left "Route53: missing <ListResourceRecordSetsResponse>"
  let records = extractAll "<ResourceRecordSet>" "</ResourceRecordSet>" body
      hasEmptyCollection = "<ResourceRecordSets/>" `BS.isInfixOf` body
      hasCollection = "<ResourceRecordSets>" `BS.isInfixOf` body
  if hasEmptyCollection || hasCollection
    then Right ()
    else Left "Route53: missing <ResourceRecordSets>"
  case records of
    [] -> Right Nothing
    [record] -> parseExact record
    _ -> Left "Route53: bounded exact-record response returned multiple record sets"
 where
  parseExact record = do
    returnedName <- decodeUtf8 <$> recordElement "Name" record
    returnedType <- recordElement "Type" record >>= parseRecordType
    if normalizeRecordName returnedName /= normalizeRecordName requestedName
      || returnedType /= requestedType
      then Right Nothing
      else do
        if "<AliasTarget>" `BS.isInfixOf` record || "<SetIdentifier>" `BS.isInfixOf` record
          then Left "Route53: exact record uses an unsupported alias or routing policy"
          else Right ()
        ttlBytes <- recordElement "TTL" record
        ttl <-
          case readMaybe (BS8.unpack ttlBytes) of
            Just value | value > (0 :: Int) -> Right value
            _ -> Left "Route53: exact record has an invalid TTL"
        valuesContainer <-
          note
            "Route53: exact record is missing <ResourceRecords>"
            (extractFirst "<ResourceRecords>" "</ResourceRecords>" record)
        let values = map decodeUtf8 (extractAll "<Value>" "</Value>" valuesContainer)
        if null values
          then Left "Route53: exact record has no resource-record values"
          else
            Right
              ( Just
                  ResourceRecordSet
                    { rrsName = normalizeRecordName returnedName
                    , rrsType = returnedType
                    , rrsTtl = ttl
                    , rrsRecords = values
                    }
              )

-- | One required child element of a @\<ResourceRecordSet\>@.  Shared by the
-- exact lookup and the family scan so the two cannot disagree about what a
-- record set must carry.
recordElement :: String -> ByteString -> Either String ByteString
recordElement name hay =
  note
    ("Route53: record set is missing <" ++ name ++ ">")
    (extractFirst (BS8.pack ("<" ++ name ++ ">")) (BS8.pack ("</" ++ name ++ ">")) hay)

normalizeRecordName :: Text -> Text
normalizeRecordName = Text.toLower . Text.dropWhileEnd (== '.') . Text.strip

parseRecordType :: ByteString -> Either String RecordType
parseRecordType value
  | value == "A" = Right RecordA
  | value == "AAAA" = Right RecordAAAA
  | value == "CNAME" = Right RecordCNAME
  | value == "TXT" = Right RecordTXT
  | value == "MX" = Right RecordMX
  | otherwise = Left ("Route53: unknown record type " ++ BS8.unpack value)

parseChangeStatus :: ByteString -> Either String ChangeStatus
parseChangeStatus status
  | status == "PENDING" = Right ChangePending
  | status == "INSYNC" = Right ChangeInsync
  | otherwise = Left ("Route53: unknown change status " ++ BS8.unpack status)

runChangeRecordSets
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> [(ChangeAction, ResourceRecordSet)]
  -> IO (Either AwsClientError (ChangeId, ChangeStatus))
runChangeRecordSets handle sender zoneId changes
  | null changes = pure (Left (AwsSigningError "refusing to write empty Route 53 change set"))
  | otherwise = do
      raw <-
        performAwsRequest
          sender
          ( \ts ->
              signRoute53
                handle
                ts
                "POST"
                (changeRecordSetsPath zoneId)
                []
                (renderChangeBatchXml changes)
          )
          "route53:ChangeResourceRecordSets"
          Idempotent
          XmlErrorFormat
      pure (raw >>= first AwsResponseParseFailure . parseChangeInfoResponse)

runGetChange
  :: CredentialHandle origin
  -> NativeAwsSender
  -> ChangeId
  -> IO (Either AwsClientError ChangeStatus)
runGetChange handle sender changeId = do
  raw <-
    performAwsRequest
      sender
      (\ts -> signRoute53 handle ts "GET" (getChangePath changeId) [] "")
      "route53:GetChange"
      Idempotent
      XmlErrorFormat
  pure (raw >>= first AwsResponseParseFailure . parseGetChangeResponse)

runListExactResourceRecordSet
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> Text
  -> RecordType
  -> IO (Either AwsClientError (Maybe ResourceRecordSet))
runListExactResourceRecordSet handle sender zoneId recordName recordType = do
  raw <-
    performAwsRequest
      sender
      ( \ts ->
          signRoute53
            handle
            ts
            "GET"
            (changeRecordSetsPath zoneId)
            (listRecordSetsQuery recordName recordType)
            ""
      )
      "route53:ListResourceRecordSets"
      Idempotent
      XmlErrorFormat
  pure
    ( raw
        >>= first AwsResponseParseFailure
          . parseListResourceRecordSetsResponse recordName recordType
    )

signRoute53
  :: CredentialHandle origin
  -> AwsTimestamp
  -> ByteString
  -> ByteString
  -> [(ByteString, ByteString)]
  -> ByteString
  -> SignedHttpRequest
signRoute53 handle ts method path query body =
  buildSignedRequest
    (toSigV4Credentials handle)
    (credentialHandleSecurityToken handle)
    route53Scope
    route53Endpoint
    ts
    method
    path
    query
    body
    []

note :: String -> Maybe a -> Either String a
note message = maybe (Left message) Right

-- | The bound on a family scan.  Route 53 pages record sets, and an unbounded
-- follow loop is an unbounded AWS call from a cleanup path.  A hosted zone
-- prodbox owns holds tens of records, not thousands, so this is far above any
-- real answer; reaching it means the query was wrong, and saying so is the
-- point.
maximumScannedRecordSetPages :: Int
maximumScannedRecordSetPages = 16

-- | One page of a scan, with the cursor Route 53 returns when truncated.
data ScannedRecordSetPage = ScannedRecordSetPage
  { scannedRecordSets :: ![ResourceRecordSet]
  , scannedNextRecordName :: !(Maybe Text)
  , scannedNextRecordType :: !(Maybe Text)
  }
  deriving (Eq, Show)

-- | The scan query.  Unlike 'listRecordSetsQuery' it does not pin @maxitems@ to
-- one: a family answer is every member, and asking for one record at a time
-- would make the page bound the family bound.
scanRecordSetsQuery
  :: Text -> RecordType -> Maybe (Text, Text) -> [(ByteString, ByteString)]
scanRecordSetsQuery startName recordType cursor =
  case cursor of
    Nothing ->
      [ ("name", ensureTrailingDot (encodeUtf8 startName))
      , ("type", renderRecordType recordType)
      ]
    Just (nextName, nextType) ->
      [ ("name", encodeUtf8 nextName)
      , ("type", encodeUtf8 nextType)
      ]

-- | Parse one scan page.  Records that fail to parse are __not__ silently
-- dropped: a family answer that quietly omits a member reads as a smaller
-- family, so an unparseable record set is an error.
parseScannedResourceRecordSetsResponse
  :: RecordType -> ByteString -> Either String ScannedRecordSetPage
parseScannedResourceRecordSetsResponse requestedType body = do
  if "<ListResourceRecordSetsResponse" `BS.isInfixOf` body
    then Right ()
    else Left "Route53: missing <ListResourceRecordSetsResponse>"
  let hasEmptyCollection = "<ResourceRecordSets/>" `BS.isInfixOf` body
      hasCollection = "<ResourceRecordSets>" `BS.isInfixOf` body
  if hasEmptyCollection || hasCollection
    then Right ()
    else Left "Route53: missing <ResourceRecordSets>"
  parsed <- traverse parseScanned (extractAll "<ResourceRecordSet>" "</ResourceRecordSet>" body)
  truncatedText <- case extractFirst "<IsTruncated>" "</IsTruncated>" body of
    Nothing -> Right "false"
    Just raw -> Right (decodeUtf8 raw)
  truncated <- case truncatedText of
    "true" -> Right True
    "false" -> Right False
    _ -> Left "Route53: scan response has an invalid <IsTruncated>"
  let nextName = decodeUtf8 <$> extractFirst "<NextRecordName>" "</NextRecordName>" body
      nextType = decodeUtf8 <$> extractFirst "<NextRecordType>" "</NextRecordType>" body
  if truncated && (nextName == Nothing || nextType == Nothing)
    then Left "Route53: truncated scan response carries no continuation cursor"
    else Right ()
  Right
    ScannedRecordSetPage
      { scannedRecordSets = [record | Just record <- parsed]
      , scannedNextRecordName = if truncated then nextName else Nothing
      , scannedNextRecordType = if truncated then nextType else Nothing
      }
 where
  parseScanned record = do
    returnedName <- decodeUtf8 <$> recordElement "Name" record
    returnedType <- recordElement "Type" record >>= parseRecordType
    if returnedType /= requestedType
      then Right Nothing
      else do
        if "<AliasTarget>" `BS.isInfixOf` record || "<SetIdentifier>" `BS.isInfixOf` record
          then Left "Route53: scanned record uses an unsupported alias or routing policy"
          else Right ()
        ttlBytes <- recordElement "TTL" record
        ttl <-
          case readMaybe (BS8.unpack ttlBytes) of
            Just value | value > (0 :: Int) -> Right value
            _ -> Left "Route53: scanned record has an invalid TTL"
        valuesContainer <-
          note
            "Route53: scanned record is missing <ResourceRecords>"
            (extractFirst "<ResourceRecords>" "</ResourceRecords>" record)
        let values = map decodeUtf8 (extractAll "<Value>" "</Value>" valuesContainer)
        if null values
          then Left "Route53: scanned record has no resource-record values"
          else
            Right
              ( Just
                  ResourceRecordSet
                    { rrsName = normalizeRecordName returnedName
                    , rrsType = returnedType
                    , rrsTtl = ttl
                    , rrsRecords = values
                    }
              )

-- | Follow the cursor until the scan leaves the prefix or the page bound is
-- reached.  Route 53 returns records in sorted order, so the first record whose
-- name is outside the prefix ends the family: continuing past it would return
-- records the family does not contain.
runScanRecordSetsByPrefix
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> Text
  -> RecordType
  -> IO (Either AwsClientError [ResourceRecordSet])
runScanRecordSetsByPrefix handle sender zoneId namePrefix recordType =
  go maximumScannedRecordSetPages Nothing []
 where
  normalizedPrefix = normalizeRecordName namePrefix
  go remaining cursor acc
    | remaining <= (0 :: Int) =
        pure
          ( Left
              ( AwsResponseParseFailure
                  "Route53: record-set scan exceeded its page bound"
              )
          )
    | otherwise = do
        raw <-
          performAwsRequest
            sender
            ( \ts ->
                signRoute53
                  handle
                  ts
                  "GET"
                  (changeRecordSetsPath zoneId)
                  (scanRecordSetsQuery namePrefix recordType cursor)
                  ""
            )
            "route53:ListResourceRecordSets"
            Idempotent
            XmlErrorFormat
        case raw >>= first AwsResponseParseFailure . parseScannedResourceRecordSetsResponse recordType of
          Left err -> pure (Left err)
          Right page -> do
            let matched =
                  [ record
                  | record <- scannedRecordSets page
                  , normalizedPrefix `Text.isPrefixOf` rrsName record
                  ]
                leftPrefix =
                  any
                    (not . (normalizedPrefix `Text.isPrefixOf`) . rrsName)
                    (scannedRecordSets page)
            case (leftPrefix, scannedNextRecordName page, scannedNextRecordType page) of
              (False, Just nextName, Just nextType) ->
                go (remaining - 1) (Just (nextName, nextType)) (acc ++ matched)
              _ -> pure (Right (acc ++ matched))
