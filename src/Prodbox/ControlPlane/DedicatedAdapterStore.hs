{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Native, role-indexed S3 storage for the physically separate Authority
-- Backup and TLS Retention adapters.  A binding fixes one validated AWS bucket
-- prefix and one Vault credential path.  Requests can select only an opaque
-- object name constructed by the matching role module, so neither adapter is a
-- generic S3 proxy and a TLS object cannot be passed to the backup transport.
module Prodbox.ControlPlane.DedicatedAdapterStore
  ( DedicatedAdapterKind (..)
  , AuthorityBackupStoreConfig
  , TlsRetentionStoreConfig
  , DedicatedAdapterCoordinate
  , DedicatedAdapterBinding
  , DedicatedAdapterStoreError (..)
  , AdapterObjectName
  , AdapterObjectVersion
  , AdapterObjectObservation (..)
  , AdapterPutResult (..)
  , DedicatedAdapterTransport (..)
  , adapterObjectVersionText
  , mkAdapterObjectVersion
  , adapterBindingCoordinate
  , adapterCoordinateLogicalName
  , adapterBindingTransport
  , adapterObjectNameText
  , authorityBackupCredentialPath
  , tlsRetentionCredentialPath
  , awsS3EndpointForRegion
  , mkAuthorityBackupStoreConfig
  , mkTlsRetentionStoreConfig
  , authorityBackupStoreEndpoint
  , authorityBackupStoreRegion
  , authorityBackupStoreBucket
  , authorityBackupStorePrefix
  , tlsRetentionStoreEndpoint
  , tlsRetentionStoreRegion
  , tlsRetentionStoreBucket
  , tlsRetentionStorePrefix
  , tlsRetentionStoreSubstrate
  , tlsRetentionStoreScopeKey
  , authorityBackupBlobObjectName
  , tlsRetentionEnvelopeObjectName
  , deferredAuthorityBackupBinding
  , newAuthorityBackupAdapterBinding
  , newTlsRetentionAdapterBinding
  )
where

import Codec.Serialise (Serialise)
import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteString8
import Data.CaseInsensitive qualified as CaseInsensitive
import Data.Char (isAsciiLower, isDigit)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import GHC.Generics (Generic)
import Network.HTTP.Client
  ( Request (..)
  , RequestBody (RequestBodyBS)
  , Response (..)
  , parseRequest
  , withResponse
  )
import Network.HTTP.Types.Header (Header)
import Network.HTTP.Types.Status (statusCode)
import Numeric.Natural (Natural)
import Prodbox.Aws.Native.Wire
  ( HttpOutcome (..)
  , TransportFailure (..)
  , defaultNativeAwsResponseByteLimit
  , readBoundedNativeAwsHttpOutcome
  )
import Prodbox.Aws.SigV4
  ( SigV4Credentials (..)
  , SigV4Request (..)
  , SigV4Scope (..)
  , canonicalQueryString
  , canonicalUri
  , hexSha256
  , sigV4AuthorizationHeader
  )
import Prodbox.Http.Client (renderHttpError, sharedTlsManager)
import Prodbox.Lifecycle.CheckpointAuthority
  ( AuthorityCoordinateError
  , ModelBObjectCoordinate
  , StoreLifetime (CrossClusterDurable)
  , mkCrossClusterDurableCoordinate
  , mkLongLivedCheckpointAuthority
  , modelBObjectLogicalName
  )
import Prodbox.Vault.Client (vaultKvReadV2)
import Prodbox.Vault.Session
  ( VaultSession
  , sessionAddress
  , withSessionToken
  )

data DedicatedAdapterKind
  = AuthorityBackupAdapter
  | TlsRetentionAdapter

newtype DedicatedAdapterCoordinate (kind :: DedicatedAdapterKind)
  = DedicatedAdapterCoordinate (ModelBObjectCoordinate 'CrossClusterDurable)
  deriving stock (Eq, Show)

newtype AdapterObjectName (kind :: DedicatedAdapterKind) = AdapterObjectName Text
  deriving stock (Eq, Ord, Show)

newtype AdapterObjectVersion = AdapterObjectVersion Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data AdapterObjectObservation
  = AdapterObjectMissing
  | AdapterObjectObserved !AdapterObjectVersion !ByteString
  deriving stock (Eq, Show)

data AdapterPutResult
  = AdapterPutApplied
  | AdapterPutConflict
  deriving stock (Eq, Show)

-- | Prefix-confined immutable object transport.  There is deliberately no
-- replace operation: both backup blobs and TLS envelope versions are immutable.
data DedicatedAdapterTransport (kind :: DedicatedAdapterKind) m
  = DedicatedAdapterTransport
  { observeAdapterObject
      :: AdapterObjectName kind
      -> m (Either Text AdapterObjectObservation)
  , putAdapterObjectIfAbsent
      :: AdapterObjectName kind
      -> ByteString
      -> m (Either Text AdapterPutResult)
  , adapterObjectStoreReady :: m Bool
  }

data DedicatedAdapterBinding (kind :: DedicatedAdapterKind)
  = DedicatedAdapterBinding
  { internalAdapterBindingCoordinate :: !(DedicatedAdapterCoordinate kind)
  , internalAdapterBindingTransport :: !(DedicatedAdapterTransport kind IO)
  }

data DedicatedAdapterStoreError
  = DedicatedAdapterCoordinateInvalid !AuthorityCoordinateError
  | DedicatedAdapterConfigInvalid !Text
  | DedicatedAdapterVaultReadFailed !Text !String
  | DedicatedAdapterVaultFieldMissing !Text !Text
  | DedicatedAdapterVaultFieldEmpty !Text !Text
  deriving stock (Eq, Show)

data AuthorityBackupStoreConfig = AuthorityBackupStoreConfig
  { internalAuthorityBackupEndpoint :: !Text
  , internalAuthorityBackupRegion :: !Text
  , internalAuthorityBackupBucket :: !Text
  , internalAuthorityBackupPrefix :: !Text
  , internalAuthorityBackupCoordinate :: !(DedicatedAdapterCoordinate 'AuthorityBackupAdapter)
  }
  deriving stock (Eq, Show)

data TlsRetentionStoreConfig = TlsRetentionStoreConfig
  { internalTlsRetentionEndpoint :: !Text
  , internalTlsRetentionRegion :: !Text
  , internalTlsRetentionBucket :: !Text
  , internalTlsRetentionPrefix :: !Text
  , internalTlsRetentionSubstrate :: !Text
  , internalTlsRetentionScopeKey :: !Text
  , internalTlsRetentionCoordinate :: !(DedicatedAdapterCoordinate 'TlsRetentionAdapter)
  }
  deriving stock (Eq, Show)

adapterObjectVersionText :: AdapterObjectVersion -> Text
adapterObjectVersionText (AdapterObjectVersion value) = value

mkAdapterObjectVersion :: Text -> Either Text AdapterObjectVersion
mkAdapterObjectVersion raw =
  let value = Text.strip raw
   in if Text.null value
        || Text.length value > 512
        || Text.any (\character -> character <= '\x1f' || character == '\x7f') value
        then Left "invalid dedicated-adapter object version"
        else Right (AdapterObjectVersion value)

adapterBindingCoordinate
  :: DedicatedAdapterBinding kind
  -> DedicatedAdapterCoordinate kind
adapterBindingCoordinate = internalAdapterBindingCoordinate

adapterCoordinateLogicalName :: DedicatedAdapterCoordinate kind -> Text
adapterCoordinateLogicalName (DedicatedAdapterCoordinate coordinate) =
  modelBObjectLogicalName coordinate

adapterBindingTransport
  :: DedicatedAdapterBinding kind
  -> DedicatedAdapterTransport kind IO
adapterBindingTransport = internalAdapterBindingTransport

adapterObjectNameText :: AdapterObjectName kind -> Text
adapterObjectNameText (AdapterObjectName value) = value

authorityBackupCredentialPath :: Text
authorityBackupCredentialPath = "aws/authority-backup-store"

tlsRetentionCredentialPath :: Text
tlsRetentionCredentialPath = "aws/tls-retention-store"

awsS3EndpointForRegion :: Text -> Text
awsS3EndpointForRegion region =
  "https://s3." <> Text.strip region <> ".amazonaws.com"

mkAuthorityBackupStoreConfig
  :: Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Either DedicatedAdapterStoreError AuthorityBackupStoreConfig
mkAuthorityBackupStoreConfig clusterId endpoint region bucket prefix = do
  validateAwsStore endpoint region bucket
  normalizedCluster <- validateClusterId clusterId
  let normalizedPrefix = Text.dropWhileEnd (== '/') (Text.strip prefix)
      expectedPrefix = "authority-backup-store/" <> normalizedCluster
  if normalizedPrefix /= expectedPrefix
    then
      Left
        ( DedicatedAdapterConfigInvalid
            "authority backup prefix must be authority-backup-store/<cluster_id>"
        )
    else Right ()
  coordinate <-
    mapLeft DedicatedAdapterCoordinateInvalid $
      mkAdapterCoordinate
        normalizedCluster
        endpoint
        bucket
        normalizedPrefix
        authorityBackupCredentialPath
  Right
    AuthorityBackupStoreConfig
      { internalAuthorityBackupEndpoint = Text.strip endpoint
      , internalAuthorityBackupRegion = Text.strip region
      , internalAuthorityBackupBucket = Text.strip bucket
      , internalAuthorityBackupPrefix = normalizedPrefix
      , internalAuthorityBackupCoordinate = coordinate
      }

mkTlsRetentionStoreConfig
  :: Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Either DedicatedAdapterStoreError TlsRetentionStoreConfig
mkTlsRetentionStoreConfig clusterId endpoint region bucket substrate scopeKey prefix = do
  validateAwsStore endpoint region bucket
  normalizedCluster <- validateClusterId clusterId
  normalizedSubstrate <- validateSubstrate substrate
  normalizedScope <- validateScopeKey scopeKey
  let normalizedPrefix = Text.dropWhileEnd (== '/') (Text.strip prefix)
      expectedPrefix =
        "public-edge-tls/" <> normalizedSubstrate <> "/" <> normalizedScope
  if normalizedPrefix /= expectedPrefix
    then
      Left
        ( DedicatedAdapterConfigInvalid
            "TLS retention prefix must be public-edge-tls/<substrate>/<canonical-scope-key>"
        )
    else Right ()
  coordinate <-
    mapLeft DedicatedAdapterCoordinateInvalid $
      mkAdapterCoordinate
        normalizedCluster
        endpoint
        bucket
        normalizedPrefix
        tlsRetentionCredentialPath
  Right
    TlsRetentionStoreConfig
      { internalTlsRetentionEndpoint = Text.strip endpoint
      , internalTlsRetentionRegion = Text.strip region
      , internalTlsRetentionBucket = Text.strip bucket
      , internalTlsRetentionPrefix = normalizedPrefix
      , internalTlsRetentionSubstrate = normalizedSubstrate
      , internalTlsRetentionScopeKey = normalizedScope
      , internalTlsRetentionCoordinate = coordinate
      }

authorityBackupStoreEndpoint :: AuthorityBackupStoreConfig -> Text
authorityBackupStoreEndpoint = internalAuthorityBackupEndpoint

authorityBackupStoreRegion :: AuthorityBackupStoreConfig -> Text
authorityBackupStoreRegion = internalAuthorityBackupRegion

authorityBackupStoreBucket :: AuthorityBackupStoreConfig -> Text
authorityBackupStoreBucket = internalAuthorityBackupBucket

authorityBackupStorePrefix :: AuthorityBackupStoreConfig -> Text
authorityBackupStorePrefix = internalAuthorityBackupPrefix

tlsRetentionStoreEndpoint :: TlsRetentionStoreConfig -> Text
tlsRetentionStoreEndpoint = internalTlsRetentionEndpoint

tlsRetentionStoreRegion :: TlsRetentionStoreConfig -> Text
tlsRetentionStoreRegion = internalTlsRetentionRegion

tlsRetentionStoreBucket :: TlsRetentionStoreConfig -> Text
tlsRetentionStoreBucket = internalTlsRetentionBucket

tlsRetentionStorePrefix :: TlsRetentionStoreConfig -> Text
tlsRetentionStorePrefix = internalTlsRetentionPrefix

tlsRetentionStoreSubstrate :: TlsRetentionStoreConfig -> Text
tlsRetentionStoreSubstrate = internalTlsRetentionSubstrate

tlsRetentionStoreScopeKey :: TlsRetentionStoreConfig -> Text
tlsRetentionStoreScopeKey = internalTlsRetentionScopeKey

authorityBackupBlobObjectName
  :: Text
  -> Text
  -> Either Text (AdapterObjectName 'AuthorityBackupAdapter)
authorityBackupBlobObjectName blobClass digest = do
  classSegment <- case blobClass of
    "authority-aggregate" -> Right "authority-aggregate"
    "checkpoint" -> Right "checkpoint"
    "config" -> Right "config"
    "cleanup-report" -> Right "cleanup-report"
    _ -> Left "invalid Authority backup blob class"
  normalized <- validateSha256Digest digest
  Right (AdapterObjectName ("blobs/" <> classSegment <> "/sha256-" <> normalized))

tlsRetentionEnvelopeObjectName
  :: Natural
  -> Either Text (AdapterObjectName 'TlsRetentionAdapter)
tlsRetentionEnvelopeObjectName version =
  Right (AdapterObjectName ("versions/" <> Text.pack (show version) <> ".envelope"))

newAuthorityBackupAdapterBinding
  :: VaultSession
  -> AuthorityBackupStoreConfig
  -> IO
       ( Either
           DedicatedAdapterStoreError
           (DedicatedAdapterBinding 'AuthorityBackupAdapter)
       )
newAuthorityBackupAdapterBinding session config =
  pure
    ( Right
        ( deferredAuthorityBackupBinding
            config
            ( loadDedicatedAdapterTransport
                session
                authorityBackupCredentialPath
                (internalAuthorityBackupEndpoint config)
                (internalAuthorityBackupRegion config)
                (internalAuthorityBackupBucket config)
                (internalAuthorityBackupPrefix config)
            )
        )
    )

-- | Authority Backup is deployed before genesis creates its long-lived
-- credential. The binding therefore fixes only validated static coordinates;
-- every readiness probe and operation acquires a fresh credential-bound
-- transport. A missing credential keeps readiness false and closes the
-- operation before native S3 is reached.
deferredAuthorityBackupBinding
  :: AuthorityBackupStoreConfig
  -> IO
       ( Either
           DedicatedAdapterStoreError
           (DedicatedAdapterTransport 'AuthorityBackupAdapter IO)
       )
  -> DedicatedAdapterBinding 'AuthorityBackupAdapter
deferredAuthorityBackupBinding config loadTransport =
  DedicatedAdapterBinding
    { internalAdapterBindingCoordinate = internalAuthorityBackupCoordinate config
    , internalAdapterBindingTransport = deferredTransport loadTransport
    }

newTlsRetentionAdapterBinding
  :: VaultSession
  -> TlsRetentionStoreConfig
  -> IO
       ( Either
           DedicatedAdapterStoreError
           (DedicatedAdapterBinding 'TlsRetentionAdapter)
       )
newTlsRetentionAdapterBinding session config =
  newDedicatedAdapterBinding
    session
    tlsRetentionCredentialPath
    (internalTlsRetentionEndpoint config)
    (internalTlsRetentionRegion config)
    (internalTlsRetentionBucket config)
    (internalTlsRetentionPrefix config)
    (internalTlsRetentionCoordinate config)

mkAdapterCoordinate
  :: Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Either AuthorityCoordinateError (DedicatedAdapterCoordinate kind)
mkAdapterCoordinate clusterId _endpoint bucket namespace credentialPath = do
  authority <-
    mkLongLivedCheckpointAuthority
      (Text.strip clusterId)
      (Text.strip bucket)
      namespace
      ("secret/" <> credentialPath)
  coordinate <- mkCrossClusterDurableCoordinate authority namespace
  Right (DedicatedAdapterCoordinate coordinate)

validateAwsStore :: Text -> Text -> Text -> Either DedicatedAdapterStoreError ()
validateAwsStore endpoint region bucket = do
  normalizedRegion <- validateRegion region
  if Text.strip endpoint /= awsS3EndpointForRegion normalizedRegion
    then
      Left
        ( DedicatedAdapterConfigInvalid
            "dedicated adapter endpoint must be the exact regional AWS S3 endpoint"
        )
    else Right ()
  validateBucket bucket

validateRegion :: Text -> Either DedicatedAdapterStoreError Text
validateRegion raw =
  let value = Text.strip raw
      validCharacter character =
        isAsciiLower character || isDigit character || character == '-'
   in case (Text.uncons value, Text.unsnoc value) of
        (Just (first, _), Just (_, lastCharacter))
          | Text.length value <= 63
              && Text.all validCharacter value
              && first /= '-'
              && lastCharacter /= '-' ->
              Right value
        _ -> Left (DedicatedAdapterConfigInvalid "invalid AWS region")

validateBucket :: Text -> Either DedicatedAdapterStoreError ()
validateBucket raw =
  let value = Text.strip raw
      validCharacter character =
        isAsciiLower character || isDigit character || character == '-' || character == '.'
      validEdge character = isAsciiLower character || isDigit character
   in case (Text.uncons value, Text.unsnoc value) of
        (Just (first, _), Just (_, lastCharacter))
          | Text.length value >= 3
              && Text.length value <= 63
              && Text.all validCharacter value
              && validEdge first
              && validEdge lastCharacter
              && not (".." `Text.isInfixOf` value) ->
              Right ()
        _ -> Left (DedicatedAdapterConfigInvalid "invalid AWS S3 bucket")

validateClusterId :: Text -> Either DedicatedAdapterStoreError Text
validateClusterId raw =
  let value = Text.strip raw
      validEdge character = isAsciiLower character || isDigit character
      validCharacter character = validEdge character || character == '-'
   in case (Text.uncons value, Text.unsnoc value) of
        (Just (first, _), Just (_, lastCharacter))
          | Text.length value <= 128
              && validEdge first
              && validEdge lastCharacter
              && Text.all validCharacter value ->
              Right value
        _ -> Left (DedicatedAdapterConfigInvalid "invalid dedicated-adapter cluster id")

validateSubstrate :: Text -> Either DedicatedAdapterStoreError Text
validateSubstrate raw =
  let value = Text.strip raw
   in if value == "home-local" || value == "aws"
        then Right value
        else Left (DedicatedAdapterConfigInvalid "invalid TLS retention substrate")

validateScopeKey :: Text -> Either DedicatedAdapterStoreError Text
validateScopeKey raw =
  let value = Text.strip raw
   in if Text.null value || Text.length value > 512 || not (scopeCharactersValid value)
        then Left (DedicatedAdapterConfigInvalid "invalid canonical TLS scope key")
        else Right value

scopeCharactersValid :: Text -> Bool
scopeCharactersValid value = case Text.uncons value of
  Nothing -> True
  Just ('%', rest) ->
    case Text.splitAt 2 rest of
      (escape, remaining)
        | escape == "2A" || escape == "2C" -> scopeCharactersValid remaining
      _ -> False
  Just (character, rest) ->
    (isAsciiLower character || isDigit character || character `elem` ['-', '.'])
      && scopeCharactersValid rest

validateSha256Digest :: Text -> Either Text Text
validateSha256Digest raw =
  let value = Text.strip raw
      valid character = isDigit character || character >= 'a' && character <= 'f'
   in if Text.length value == 64 && Text.all valid value
        then Right value
        else Left "invalid SHA-256 digest"

data NativeS3Config = NativeS3Config
  { nativeS3Endpoint :: !String
  , nativeS3Bucket :: !Text
  , nativeS3Prefix :: !Text
  , nativeS3Region :: !ByteString
  , nativeS3AccessKey :: !ByteString
  , nativeS3SecretKey :: !ByteString
  , nativeS3SessionToken :: !(Maybe ByteString)
  }

-- Deliberately no Show instance: the value owns the dedicated AWS secret key.

newDedicatedAdapterBinding
  :: VaultSession
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> DedicatedAdapterCoordinate kind
  -> IO (Either DedicatedAdapterStoreError (DedicatedAdapterBinding kind))
newDedicatedAdapterBinding session credentialPath endpoint region bucket prefix coordinate = do
  transportResult <-
    loadDedicatedAdapterTransport session credentialPath endpoint region bucket prefix
  pure $ do
    transport <- transportResult
    Right
      DedicatedAdapterBinding
        { internalAdapterBindingCoordinate = coordinate
        , internalAdapterBindingTransport = transport
        }

loadDedicatedAdapterTransport
  :: VaultSession
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> IO (Either DedicatedAdapterStoreError (DedicatedAdapterTransport kind IO))
loadDedicatedAdapterTransport session credentialPath endpoint region bucket prefix = do
  credentialsResult <- readDedicatedCredentials session credentialPath
  pure $ do
    credentials <- credentialsResult
    if credentialRegion credentials /= region
      then
        Left
          ( DedicatedAdapterConfigInvalid
              "dedicated credential region does not match the configured S3 region"
          )
      else Right ()
    let nativeConfig =
          NativeS3Config
            { nativeS3Endpoint = Text.unpack endpoint
            , nativeS3Bucket = bucket
            , nativeS3Prefix = prefix
            , nativeS3Region = TextEncoding.encodeUtf8 region
            , nativeS3AccessKey = TextEncoding.encodeUtf8 (credentialAccessKey credentials)
            , nativeS3SecretKey = TextEncoding.encodeUtf8 (credentialSecretKey credentials)
            , nativeS3SessionToken =
                TextEncoding.encodeUtf8 <$> credentialSessionToken credentials
            }
    Right (nativeTransport nativeConfig)

deferredTransport
  :: IO (Either DedicatedAdapterStoreError (DedicatedAdapterTransport kind IO))
  -> DedicatedAdapterTransport kind IO
deferredTransport loadTransport =
  DedicatedAdapterTransport
    { observeAdapterObject = \objectName ->
        withCurrentTransport (\transport -> observeAdapterObject transport objectName)
    , putAdapterObjectIfAbsent = \objectName bytes ->
        withCurrentTransport
          (\transport -> putAdapterObjectIfAbsent transport objectName bytes)
    , adapterObjectStoreReady = do
        current <- loadTransport
        case current of
          Left _ -> pure False
          Right transport -> adapterObjectStoreReady transport
    }
 where
  withCurrentTransport action = do
    current <- loadTransport
    case current of
      Left _ -> pure (Left "Authority Backup store credential is unavailable")
      Right transport -> action transport

data DedicatedCredentials = DedicatedCredentials
  { credentialAccessKey :: !Text
  , credentialSecretKey :: !Text
  , credentialSessionToken :: !(Maybe Text)
  , credentialRegion :: !Text
  }

readDedicatedCredentials
  :: VaultSession
  -> Text
  -> IO (Either DedicatedAdapterStoreError DedicatedCredentials)
readDedicatedCredentials session path = do
  result <-
    withSessionToken session $ \token ->
      vaultKvReadV2 (sessionAddress session) token "secret" path
  pure $ case result of
    Left err -> Left (DedicatedAdapterVaultReadFailed path (renderHttpError err))
    Right fields -> credentialsFromFields path fields

credentialsFromFields
  :: Text
  -> Map Text Text
  -> Either DedicatedAdapterStoreError DedicatedCredentials
credentialsFromFields path fields = do
  accessKey <- requireField path "access_key_id" fields
  secretKey <- requireField path "secret_access_key" fields
  region <- requireField path "region" fields
  let sessionToken = normalizeOptional =<< Map.lookup "session_token" fields
  Right
    DedicatedCredentials
      { credentialAccessKey = accessKey
      , credentialSecretKey = secretKey
      , credentialSessionToken = sessionToken
      , credentialRegion = region
      }

requireField
  :: Text
  -> Text
  -> Map Text Text
  -> Either DedicatedAdapterStoreError Text
requireField path field fields = case Map.lookup field fields of
  Nothing -> Left (DedicatedAdapterVaultFieldMissing path field)
  Just value -> case normalizeOptional value of
    Nothing -> Left (DedicatedAdapterVaultFieldEmpty path field)
    Just normalized -> Right normalized

normalizeOptional :: Text -> Maybe Text
normalizeOptional value =
  let normalized = Text.strip value
   in if Text.null normalized then Nothing else Just normalized

nativeTransport
  :: NativeS3Config
  -> DedicatedAdapterTransport kind IO
nativeTransport config =
  DedicatedAdapterTransport
    { observeAdapterObject = observeNativeObject config
    , putAdapterObjectIfAbsent = putNativeObjectIfAbsent config
    , adapterObjectStoreReady = probeNativePrefix config
    }

observeNativeObject
  :: NativeS3Config
  -> AdapterObjectName kind
  -> IO (Either Text AdapterObjectObservation)
observeNativeObject config objectName = do
  response <- performNativeS3 config "GET" (objectPath config objectName) [] "" []
  pure $ case response of
    Left err -> Left err
    Right (status, headers, body)
      | status >= 200 && status < 300 -> case etagOf headers of
          Nothing -> Left "dedicated adapter GET succeeded without an ETag"
          Just version -> Right (AdapterObjectObserved version body)
      | status == 404 -> Right AdapterObjectMissing
      | otherwise -> Left (statusFailure "GET" status body)

putNativeObjectIfAbsent
  :: NativeS3Config
  -> AdapterObjectName kind
  -> ByteString
  -> IO (Either Text AdapterPutResult)
putNativeObjectIfAbsent config objectName bytes = do
  response <-
    performNativeS3
      config
      "PUT"
      (objectPath config objectName)
      []
      bytes
      [("If-None-Match", "*")]
  pure $ case response of
    Left err -> Left err
    Right (status, _, body)
      | status >= 200 && status < 300 -> Right AdapterPutApplied
      | status == 409 || status == 412 -> Right AdapterPutConflict
      | otherwise -> Left (statusFailure "immutable PUT" status body)

probeNativePrefix :: NativeS3Config -> IO Bool
probeNativePrefix config = do
  response <-
    performNativeS3
      config
      "GET"
      (bucketPath config)
      [ ("list-type", "2")
      , ("max-keys", "1")
      , ("prefix", TextEncoding.encodeUtf8 (nativeS3Prefix config <> "/"))
      ]
      ""
      []
  pure $ case response of
    Right (status, _, _) -> status >= 200 && status < 300
    Left _ -> False

data S3Timestamp = S3Timestamp
  { s3AmzDate :: !ByteString
  , s3DateStamp :: !ByteString
  }

performNativeS3
  :: NativeS3Config
  -> ByteString
  -> ByteString
  -> [(ByteString, ByteString)]
  -> ByteString
  -> [(ByteString, ByteString)]
  -> IO (Either Text (Int, [Header], ByteString))
performNativeS3 config httpMethod rawPath rawQuery body extraHeaders = do
  baseResult <- try (parseRequest (nativeS3Endpoint config)) :: IO (Either SomeException Request)
  case baseResult of
    Left err -> pure (Left ("invalid dedicated-adapter S3 endpoint: " <> Text.pack (show err)))
    Right base -> do
      now <- getCurrentTime
      let timestamp = timestampFromUtc now
          hostHeader = requestHostHeader base
          securityHeaders = case nativeS3SessionToken config of
            Nothing -> []
            Just token -> [("x-amz-security-token", token)]
          headersToSign =
            [ ("host", hostHeader)
            , ("x-amz-content-sha256", hexSha256 body)
            , ("x-amz-date", s3AmzDate timestamp)
            ]
              <> securityHeaders
              <> extraHeaders
          scope =
            SigV4Scope
              { sigV4DateStamp = s3DateStamp timestamp
              , sigV4Region = nativeS3Region config
              , sigV4Service = "s3"
              }
          requestToSign =
            SigV4Request
              { sigV4Method = httpMethod
              , sigV4Path = rawPath
              , sigV4Query = rawQuery
              , sigV4Headers = headersToSign
              , sigV4PayloadHashHex = hexSha256 body
              }
          authorization =
            sigV4AuthorizationHeader
              SigV4Credentials
                { sigV4AccessKeyId = nativeS3AccessKey config
                , sigV4SecretAccessKey = nativeS3SecretKey config
                }
              scope
              (s3AmzDate timestamp)
              requestToSign
          wireQuery =
            if null rawQuery
              then ""
              else "?" <> canonicalQueryString rawQuery
          request =
            base
              { method = httpMethod
              , path = canonicalUri rawPath
              , queryString = wireQuery
              , requestHeaders =
                  [ (CaseInsensitive.mk name, value)
                  | (name, value) <- ("Authorization", authorization) : headersToSign
                  ]
              , requestBody = RequestBodyBS body
              }
      sent <-
        try
          ( withResponse request sharedTlsManager $ \response ->
              readBoundedNativeAwsHttpOutcome
                defaultNativeAwsResponseByteLimit
                (statusCode (responseStatus response))
                (responseHeaders response)
                (responseBody response)
          )
          :: IO (Either SomeException (Either TransportFailure HttpOutcome))
      pure $ case sent of
        Left err -> Left ("dedicated-adapter S3 request failed: " <> Text.pack (show err))
        Right (Left failure) ->
          Left ("dedicated-adapter S3 response failed: " <> Text.pack (transportDetail failure))
        Right (Right outcome) ->
          Right (httpStatus outcome, httpHeaders outcome, httpBody outcome)

timestampFromUtc :: UTCTime -> S3Timestamp
timestampFromUtc now =
  S3Timestamp
    { s3AmzDate = ByteString8.pack (formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" now)
    , s3DateStamp = ByteString8.pack (formatTime defaultTimeLocale "%Y%m%d" now)
    }

requestHostHeader :: Request -> ByteString
requestHostHeader request
  | (secure request && port request == 443) || (not (secure request) && port request == 80) =
      host request
  | otherwise = host request <> ByteString8.pack (":" <> show (port request))

objectPath :: NativeS3Config -> AdapterObjectName kind -> ByteString
objectPath config objectName =
  "/"
    <> TextEncoding.encodeUtf8 (nativeS3Bucket config)
    <> "/"
    <> TextEncoding.encodeUtf8 (nativeS3Prefix config)
    <> "/"
    <> TextEncoding.encodeUtf8 (adapterObjectNameText objectName)

bucketPath :: NativeS3Config -> ByteString
bucketPath config = "/" <> TextEncoding.encodeUtf8 (nativeS3Bucket config)

etagOf :: [Header] -> Maybe AdapterObjectVersion
etagOf headers = do
  raw <- snd <$> findHeader "ETag" headers
  normalized <- normalizeOptional (Text.pack (ByteString8.unpack (stripQuotes raw)))
  either (const Nothing) Just (mkAdapterObjectVersion normalized)

findHeader :: ByteString -> [Header] -> Maybe Header
findHeader name = find ((== CaseInsensitive.mk name) . fst)

stripQuotes :: ByteString -> ByteString
stripQuotes value = case ByteString8.uncons value of
  Just ('"', rest) -> case ByteString8.unsnoc rest of
    Just (middle, '"') -> middle
    _ -> value
  _ -> value

statusFailure :: Text -> Int -> ByteString -> Text
statusFailure operation status body =
  "dedicated-adapter S3 "
    <> operation
    <> " failed ("
    <> Text.pack (show status)
    <> "): "
    <> Text.pack (shortBody body)

shortBody :: ByteString -> String
shortBody bytes =
  let rendered = ByteString8.unpack bytes
   in if length rendered > 200 then take 200 rendered <> "…" else rendered

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft convert value = case value of
  Left err -> Left (convert err)
  Right result -> Right result
