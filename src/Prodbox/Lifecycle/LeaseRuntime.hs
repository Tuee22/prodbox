{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Production IO wiring for the retained-resource lease protocol.
--
-- Every clock read and Model-B operation is routed through the explicit
-- retained checkpoint authority.  Provider quiescence remains an injected
-- authoritative observer because AWS inventories are resource-specific.
module Prodbox.Lifecycle.LeaseRuntime
  ( LeaseRuntimeConfigError (..)
  , LeaseAcquireBootstrapError (..)
  , LeaseIdentityDiscoveryError (..)
  , LeaseScopedAwsSession
  , LeaseSessionError (..)
  , MintedAwsSession
  , ProductionLeaseRuntime
  , beginProductionLeaseAcquire
  , beginProductionLeaseAcquireWith
  , discoverAwsSesLeaseKey
  , discoverAwsSesLeaseKeyWith
  , generateSecureOwnerNonce
  , leaseScopedAwsCredentials
  , leaseScopedAwsExpiresAt
  , mintLeaseScopedAwsSession
  , mintLeaseScopedAwsSessionWith
  , mintedAwsSession
  , mkProductionLeaseRuntime
  , productionLeaseInterpreter
  , waitForAuthorityTime
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Crypto.Random (getRandomBytes)
import Data.Aeson (FromJSON (..), eitherDecode, withObject, (.:))
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Base64.URL qualified as Base64Url
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Numeric.Natural (Natural)
import Prodbox.AwsEnvironment (awsCliSubprocessEnvironment)
import Prodbox.Lifecycle.CheckpointAuthority
  ( AuthorityCoordinateError
  , LongLivedCheckpointAuthority
  , ModelBCasAdapter
  , StoreLifetime (ClusterRetained)
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , AwsSessionDeadline
  , FencingToken
  , LeaseAcquireRequest
  , LeaseIdentityError
  , LeaseKey
  , LeaseOwnershipStatus (..)
  , LeasePolicy
  , LeaseProjection
  , LeaseRecoveryPredecessor
  , LeaseRefusal (..)
  , LeaseUsePermit
  , OwnerNonce
  , ProviderObservation (..)
  , QuiescenceRefusal (..)
  , StableQuiescenceWitness
  , TimedProviderObservation (..)
  , addAuthorityDuration
  , authorityDurationMicros
  , authorityTimeFromMicros
  , authorityTimeMicros
  , awsSessionExpiresAt
  , beginLeaseAcquire
  , deriveAwsSessionDeadline
  , fencingTokenValue
  , leasePolicyCancellationGrace
  , leasePolicyClockSkew
  , leasePolicyProviderVisibilityGrace
  , leasePolicyStableObservationCount
  , leaseRecoveryNotBefore
  , leaseUseDeadline
  , leaseUseFencingToken
  , mkLeaseKey
  , mkOwnerNonce
  , proveStableProviderQuiescenceFor
  )
import Prodbox.Lifecycle.LeaseInterpreter
  ( LeaseBoundedFailure (..)
  , LeaseInterpreter (..)
  )
import Prodbox.Result (Result (..))
import Prodbox.Settings (Credentials (..))
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import System.Exit (ExitCode (..))

data LeaseRuntimeConfigError
  = LeaseRuntimePollIntervalMustBePositive
  | LeaseRuntimePollIntervalExceedsInt !Natural
  deriving (Eq, Show)

data LeaseIdentityDiscoveryError
  = LeaseIdentityProbeFailed !Text
  | LeaseIdentityAccountMustBeTwelveDigits !Text
  | LeaseIdentityKeyInvalid !LeaseIdentityError
  deriving (Eq, Show)

data LeaseAcquireBootstrapError
  = LeaseAcquireNonceInvalid !LeaseIdentityError
  | LeaseAcquireClockUnobservable !Text
  | LeaseAcquireCoordinateInvalid !AuthorityCoordinateError
  deriving (Eq, Show)

-- | Consume the raw admin credential only in the injected caller-identity
-- probe.  The result is a non-secret lease key; no environment or credential
-- is returned to the caller.
discoverAwsSesLeaseKeyWith
  :: (Credentials -> IO (Either Text Text))
  -> Credentials
  -> IO (Either LeaseIdentityDiscoveryError LeaseKey)
discoverAwsSesLeaseKeyWith observeAccount rawAdmin = do
  observed <- observeAccount rawAdmin
  pure $ do
    account <- first LeaseIdentityProbeFailed observed
    if Text.length account == 12 && Text.all isDigit account
      then
        first
          LeaseIdentityKeyInvalid
          (mkLeaseKey account (region rawAdmin) "aws-ses")
      else Left (LeaseIdentityAccountMustBeTwelveDigits account)

discoverAwsSesLeaseKey
  :: Credentials -> IO (Either LeaseIdentityDiscoveryError LeaseKey)
discoverAwsSesLeaseKey =
  discoverAwsSesLeaseKeyWith runAwsCallerIdentity

generateSecureOwnerNonce :: IO (Either LeaseIdentityError OwnerNonce)
generateSecureOwnerNonce = do
  randomBytes <- getRandomBytes 32 :: IO ByteString
  pure
    ( mkOwnerNonce
        (TextEncoding.decodeUtf8 (Base64Url.encodeUnpadded randomBytes))
    )

beginProductionLeaseAcquireWith
  :: IO (Either LeaseIdentityError OwnerNonce)
  -> IO (Either Text AuthorityTime)
  -> LeasePolicy
  -> LongLivedCheckpointAuthority
  -> LeaseKey
  -> IO (Either LeaseAcquireBootstrapError LeaseAcquireRequest)
beginProductionLeaseAcquireWith generateNonce observeNow policy authority key = do
  nonceResult <- generateNonce
  case nonceResult of
    Left err -> pure (Left (LeaseAcquireNonceInvalid err))
    Right nonce -> do
      nowResult <- observeNow
      pure $ do
        now <- first LeaseAcquireClockUnobservable nowResult
        first
          LeaseAcquireCoordinateInvalid
          (beginLeaseAcquire policy authority key nonce now)

beginProductionLeaseAcquire
  :: IO (Either Text AuthorityTime)
  -> LongLivedCheckpointAuthority
  -> LeasePolicy
  -> LeaseKey
  -> IO (Either LeaseAcquireBootstrapError LeaseAcquireRequest)
beginProductionLeaseAcquire observeNow authority policy key =
  beginProductionLeaseAcquireWith
    generateSecureOwnerNonce
    observeNow
    policy
    authority
    key

data ProductionLeaseRuntime inventory = ProductionLeaseRuntime
  { internalRuntimeObserveAuthorityNow :: !(IO (Either Text AuthorityTime))
  , internalRuntimeLeaseAdapter :: !(ModelBCasAdapter 'ClusterRetained IO LeaseProjection)
  , internalRuntimePolicy :: !LeasePolicy
  , internalRuntimePollMicros :: !Int
  , internalRuntimeProviderObservation :: !(IO (ProviderObservation inventory))
  }

mkProductionLeaseRuntime
  :: IO (Either Text AuthorityTime)
  -> ModelBCasAdapter 'ClusterRetained IO LeaseProjection
  -> LeasePolicy
  -> Natural
  -> IO (ProviderObservation inventory)
  -> Either LeaseRuntimeConfigError (ProductionLeaseRuntime inventory)
mkProductionLeaseRuntime observeNow leaseAdapter policy pollMicros providerObservation
  | pollMicros == 0 = Left LeaseRuntimePollIntervalMustBePositive
  | pollMicros > fromIntegral (maxBound :: Int) =
      Left (LeaseRuntimePollIntervalExceedsInt pollMicros)
  | otherwise =
      Right
        ProductionLeaseRuntime
          { internalRuntimeObserveAuthorityNow = observeNow
          , internalRuntimeLeaseAdapter = leaseAdapter
          , internalRuntimePolicy = policy
          , internalRuntimePollMicros = fromIntegral pollMicros
          , internalRuntimeProviderObservation = providerObservation
          }

productionLeaseInterpreter
  :: (Eq inventory)
  => ProductionLeaseRuntime inventory
  -> LeaseInterpreter IO inventory
productionLeaseInterpreter runtime =
  LeaseInterpreter
    { leaseInterpreterModelB =
        internalRuntimeLeaseAdapter runtime
    , leaseInterpreterAuthorityNow = observeNow
    , leaseInterpreterWaitUntil =
        waitForAuthorityTime observeNow pollMicros
    , leaseInterpreterRecoverQuiescence =
        sampleStableProviderQuiescence runtime
    , leaseInterpreterRunBounded =
        runProductionBounded
          observeNow
          policy
          pollMicros
    }
 where
  observeNow = internalRuntimeObserveAuthorityNow runtime
  policy = internalRuntimePolicy runtime
  pollMicros = internalRuntimePollMicros runtime

waitForAuthorityTime
  :: IO (Either Text AuthorityTime)
  -> Int
  -> AuthorityTime
  -> IO (Either Text ())
waitForAuthorityTime observeNow pollMicros target = go
 where
  go = do
    observed <- observeNow
    case observed of
      Left err -> pure (Left err)
      Right now
        | now >= target -> pure (Right ())
        | otherwise -> do
            threadDelay pollMicros
            go

sampleStableProviderQuiescence
  :: (Eq inventory)
  => ProductionLeaseRuntime inventory
  -> LeasePolicy
  -> LeaseRecoveryPredecessor
  -> IO
       ( Either
           QuiescenceRefusal
           (StableQuiescenceWitness inventory)
       )
sampleStableProviderQuiescence runtime policy predecessor = do
  let observeNow = internalRuntimeObserveAuthorityNow runtime
      pollMicros = internalRuntimePollMicros runtime
      firstNotBefore = leaseRecoveryNotBefore predecessor
  waited <- waitForAuthorityTime observeNow pollMicros firstNotBefore
  case waited of
    Left err -> pure (Left (QuiescenceProviderUnobservable ("authority clock: " <> err)))
    Right () -> collect [] (leasePolicyStableObservationCount policy)
 where
  collect samples remaining
    | remaining <= 0 =
        pure
          ( proveStableProviderQuiescenceFor
              policy
              predecessor
              (reverse samples)
          )
    | otherwise = do
        observedAtResult <- internalRuntimeObserveAuthorityNow runtime
        case observedAtResult of
          Left err ->
            pure (Left (QuiescenceProviderUnobservable ("authority clock: " <> err)))
          Right observedAt -> do
            observation <- internalRuntimeProviderObservation runtime
            case observation of
              ProviderPending detail -> pure (Left (QuiescenceProviderPending detail))
              ProviderUnbounded actual maximumCardinality ->
                pure (Left (QuiescenceProviderUnbounded actual maximumCardinality))
              ProviderUnobservable detail ->
                pure (Left (QuiescenceProviderUnobservable detail))
              ProviderQuiescent _
                | remaining == 1 ->
                    collect
                      (TimedProviderObservation observedAt observation : samples)
                      0
                | otherwise -> do
                    waited <-
                      waitForAuthorityTime
                        (internalRuntimeObserveAuthorityNow runtime)
                        (internalRuntimePollMicros runtime)
                        ( addAuthorityDuration
                            observedAt
                            (leasePolicyProviderVisibilityGrace policy)
                        )
                    case waited of
                      Left err ->
                        pure
                          ( Left
                              ( QuiescenceProviderUnobservable
                                  ("authority clock: " <> err)
                              )
                          )
                      Right () ->
                        collect
                          (TimedProviderObservation observedAt observation : samples)
                          (remaining - 1)

runProductionBounded
  :: IO (Either Text AuthorityTime)
  -> LeasePolicy
  -> Int
  -> AuthorityTime
  -> IO LeaseOwnershipStatus
  -> IO result
  -> IO (Either LeaseBoundedFailure result)
runProductionBounded observeNow policy pollMicros deadline ownershipProbe action = do
  winner <- race action monitor
  case winner of
    Left result -> pure (Right result)
    Right failure -> do
      -- 'race' returns only after its action thread has received cancellation.
      -- Re-observe the authority clock to audit that cancellation completed
      -- inside the policy's declared grace.
      cancelledAt <- observeNow
      pure $ case cancelledAt of
        Left detail ->
          Left (LeaseBoundedRunnerFailed ("post-cancellation authority clock: " <> detail))
        Right observedAt
          | observedAt
              > addAuthorityDuration deadline (leasePolicyCancellationGrace policy) ->
              Left
                ( LeaseBoundedRunnerFailed
                    "bounded child did not cancel inside lease cancellation grace"
                )
          | otherwise -> Left failure
 where
  monitor = do
    ownership <- ownershipProbe
    case ownership of
      -- A transient endpoint-unreachability (not-yet-ready object-store
      -- port-forward / NodePort) is retried within the existing lease
      -- deadline: the gate stays CLOSED (no work committed) while we re-probe,
      -- and only budget exhaustion is terminal.  Throughout this window the
      -- grant is provably un-stealable (a live contended lease never yields a
      -- steal, and any fenced commit re-validates the guard at the authority
      -- core), so an endpoint-unready reading here is provably a transport
      -- artifact, not a genuine loss — a genuine loss requires a successful
      -- observation yielding owner/fence/expiry mismatch, which stays terminal
      -- below.  EVERY other refusal is terminal (the catch-all arm) — do not
      -- broaden this to a general 'LeaseLost' retry.
      LeaseLost (LeaseAuthorityEndpointUnready detail) -> do
        observedAt <- observeNow
        case observedAt of
          Left clockDetail ->
            pure (LeaseBoundedOwnershipLost (LeaseAuthorityUnobservable clockDetail))
          Right now
            | now >= deadline ->
                pure (LeaseBoundedOwnershipLost (LeaseAuthorityEndpointUnready detail))
            | otherwise -> do
                threadDelay pollMicros
                monitor
      LeaseLost refusal -> pure (LeaseBoundedOwnershipLost refusal)
      LeaseStillOwned -> do
        observedAt <- observeNow
        case observedAt of
          Left detail ->
            pure
              ( LeaseBoundedOwnershipLost
                  (LeaseAuthorityUnobservable detail)
              )
          Right now
            | now >= deadline -> pure (LeaseBoundedDeadlineExceeded deadline)
            | otherwise -> do
                threadDelay pollMicros
                monitor

data LeaseSessionError
  = LeaseSessionDeadlineRefused !LeaseRefusal
  | LeaseSessionClockUnobservable !Text
  | LeaseSessionInsufficientRemainingSeconds !Natural
  | LeaseSessionMintFailed !Text
  | LeaseSessionAlreadyExpired !AuthorityTime !AuthorityTime
  | LeaseSessionExpiresBeforeWorkDeadline !AuthorityTime !AuthorityTime
  | LeaseSessionOutlivesGrant !AuthorityTime !AuthorityTime
  deriving (Eq, Show)

data MintedAwsSession = MintedAwsSession
  { internalMintedAwsCredentials :: !Credentials
  , internalMintedAwsExpiresAt :: !AuthorityTime
  }

instance Show MintedAwsSession where
  show session =
    "MintedAwsSession {credentials = <redacted>, expiresAt = "
      ++ show (internalMintedAwsExpiresAt session)
      ++ "}"

mintedAwsSession :: Credentials -> AuthorityTime -> MintedAwsSession
mintedAwsSession = MintedAwsSession

data LeaseScopedAwsSession = LeaseScopedAwsSession
  { internalLeaseScopedAwsCredentials :: !Credentials
  , internalLeaseScopedAwsExpiresAt :: !AuthorityTime
  }

instance Show LeaseScopedAwsSession where
  show session =
    "LeaseScopedAwsSession {credentials = <redacted>, expiresAt = "
      ++ show (leaseScopedAwsExpiresAt session)
      ++ "}"

leaseScopedAwsCredentials :: LeaseScopedAwsSession -> Credentials
leaseScopedAwsCredentials = internalLeaseScopedAwsCredentials

leaseScopedAwsExpiresAt :: LeaseScopedAwsSession -> AuthorityTime
leaseScopedAwsExpiresAt = internalLeaseScopedAwsExpiresAt

mintLeaseScopedAwsSession
  :: IO (Either Text AuthorityTime)
  -> Text
  -> LeasePolicy
  -> Credentials
  -> LeaseUsePermit
  -> AuthorityDuration
  -> IO (Either LeaseSessionError LeaseScopedAwsSession)
mintLeaseScopedAwsSession observeNow roleArn =
  mintLeaseScopedAwsSessionWith
    observeNow
    runAwsAssumeRole
    roleArn

mintLeaseScopedAwsSessionWith
  :: IO (Either Text AuthorityTime)
  -> (Text -> Credentials -> Text -> Natural -> IO (Either Text MintedAwsSession))
  -> Text
  -> LeasePolicy
  -> Credentials
  -> LeaseUsePermit
  -> AuthorityDuration
  -> IO (Either LeaseSessionError LeaseScopedAwsSession)
mintLeaseScopedAwsSessionWith observeNow mint roleArn policy source permit requestedDuration =
  case deriveAwsSessionDeadline requestedDuration permit of
    Left refusal -> pure (Left (LeaseSessionDeadlineRefused refusal))
    Right deadline -> do
      nowResult <- observeNow
      case nowResult of
        Left detail -> pure (Left (LeaseSessionClockUnobservable detail))
        Right now ->
          case sessionDurationSeconds policy now deadline of
            Left err -> pure (Left err)
            Right durationSeconds -> do
              minted <-
                mint
                  roleArn
                  source
                  (leaseSessionName (leaseUseFencingToken permit))
                  durationSeconds
              pure $ do
                session <- first LeaseSessionMintFailed minted
                validateMintedSession now (leaseUseDeadline permit) deadline session

sessionDurationSeconds
  :: LeasePolicy
  -> AuthorityTime
  -> AwsSessionDeadline
  -> Either LeaseSessionError Natural
sessionDurationSeconds policy now deadline =
  let deadlineMicros = authorityTimeMicros (awsSessionExpiresAt deadline)
      reservedNow =
        authorityTimeMicros now
          + authorityDurationMicros (leasePolicyClockSkew policy)
      remainingMicros =
        if deadlineMicros > reservedNow
          then deadlineMicros - reservedNow
          else 0
      remainingSeconds = remainingMicros `div` 1000000
      requestedSeconds = min maximumStsSessionSeconds remainingSeconds
   in if requestedSeconds < minimumStsSessionSeconds
        then Left (LeaseSessionInsufficientRemainingSeconds requestedSeconds)
        else Right requestedSeconds

minimumStsSessionSeconds :: Natural
minimumStsSessionSeconds = 900

maximumStsSessionSeconds :: Natural
maximumStsSessionSeconds = 3600

leaseSessionName :: FencingToken -> Text
leaseSessionName fence =
  "prodbox-lease-"
    <> Text.takeEnd 12 (Text.pack (show (fencingTokenValue fence)))

validateMintedSession
  :: AuthorityTime
  -> AuthorityTime
  -> AwsSessionDeadline
  -> MintedAwsSession
  -> Either LeaseSessionError LeaseScopedAwsSession
validateMintedSession now workDeadline deadline session
  | internalMintedAwsExpiresAt session <= now =
      Left (LeaseSessionAlreadyExpired (internalMintedAwsExpiresAt session) now)
  | internalMintedAwsExpiresAt session < workDeadline =
      Left
        ( LeaseSessionExpiresBeforeWorkDeadline
            (internalMintedAwsExpiresAt session)
            workDeadline
        )
  | internalMintedAwsExpiresAt session > awsSessionExpiresAt deadline =
      Left
        ( LeaseSessionOutlivesGrant
            (internalMintedAwsExpiresAt session)
            (awsSessionExpiresAt deadline)
        )
  | otherwise =
      Right
        LeaseScopedAwsSession
          { internalLeaseScopedAwsCredentials = internalMintedAwsCredentials session
          , internalLeaseScopedAwsExpiresAt = internalMintedAwsExpiresAt session
          }

newtype CallerIdentityResponse = CallerIdentityResponse
  { callerIdentityAccount :: Text
  }

instance FromJSON CallerIdentityResponse where
  parseJSON =
    withObject "CallerIdentityResponse" $ \objectValue ->
      CallerIdentityResponse <$> objectValue .: "Account"

runAwsCallerIdentity :: Credentials -> IO (Either Text Text)
runAwsCallerIdentity rawAdmin = do
  environment <- awsCliSubprocessEnvironment rawAdmin
  outputResult <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments = ["sts", "get-caller-identity", "--output", "json"]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Nothing
        }
  pure $ case outputResult of
    Failure err -> Left (Text.pack err)
    Success output ->
      case processExitCode output of
        ExitFailure _ ->
          Left
            ( "aws sts get-caller-identity failed: "
                <> Text.pack (processStderr output)
            )
        ExitSuccess -> do
          response <-
            first
              (Text.pack . ("invalid aws sts get-caller-identity response: " ++))
              (eitherDecode (BL8.pack (processStdout output)))
          Right (callerIdentityAccount response)

data StsAssumeRoleResponse = StsAssumeRoleResponse
  { stsAssumeRoleAccessKeyId :: !Text
  , stsAssumeRoleSecretAccessKey :: !Text
  , stsAssumeRoleSessionToken :: !Text
  , stsAssumeRoleExpiration :: !UTCTime
  }

instance FromJSON StsAssumeRoleResponse where
  parseJSON =
    withObject "AssumeRoleResponse" $ \root -> do
      credentials <- root .: "Credentials"
      withObject "Credentials" parseCredentials credentials
   where
    parseCredentials credentials =
      StsAssumeRoleResponse
        <$> credentials .: "AccessKeyId"
        <*> credentials .: "SecretAccessKey"
        <*> credentials .: "SessionToken"
        <*> credentials .: "Expiration"

runAwsAssumeRole
  :: Text
  -> Credentials
  -> Text
  -> Natural
  -> IO (Either Text MintedAwsSession)
runAwsAssumeRole roleArn source sessionName durationSeconds = do
  environment <- awsCliSubprocessEnvironment source
  outputResult <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments =
            [ "sts"
            , "assume-role"
            , "--role-arn"
            , Text.unpack roleArn
            , "--role-session-name"
            , Text.unpack sessionName
            , "--duration-seconds"
            , show durationSeconds
            , "--output"
            , "json"
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Nothing
        }
  pure $ case outputResult of
    Failure err -> Left (Text.pack err)
    Success output ->
      case processExitCode output of
        ExitFailure _ ->
          Left
            ( "aws sts assume-role failed: "
                <> Text.pack (processStderr output)
            )
        ExitSuccess -> do
          response <-
            first
              (Text.pack . ("invalid aws sts assume-role response: " ++))
              (eitherDecode (BL8.pack (processStdout output)))
          Right
            MintedAwsSession
              { internalMintedAwsCredentials =
                  Credentials
                    { access_key_id = stsAssumeRoleAccessKeyId response
                    , secret_access_key = stsAssumeRoleSecretAccessKey response
                    , session_token = Just (stsAssumeRoleSessionToken response)
                    , region = region source
                    }
              , internalMintedAwsExpiresAt =
                  authorityTimeFromMicros
                    ( utcMicros
                        (stsAssumeRoleExpiration response)
                    )
              }

utcMicros :: UTCTime -> Natural
utcMicros value =
  fromInteger
    ( max
        0
        (floor (utcTimeToPOSIXSeconds value * 1000000) :: Integer)
    )
