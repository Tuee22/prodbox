{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Package-private bridge between the Provider Worker's admitted execution
-- and the Lifecycle Authority's retained completion.  Raw receipt bytes never
-- mint lifecycle authority through the public package surface.
module Prodbox.ControlPlane.ProviderAwsScopeReceipt.Internal
  ( VerifiedAuthorityProviderAwsScope
  , verifiedAuthorityProviderAwsScopeAccountId
  , verifiedAuthorityProviderAwsScopeRegion
  , verifiedAuthorityProviderAwsScopeRevision
  , verifiedAuthorityProviderAwsScopeOperationId
  , verifiedAuthorityProviderAwsScopeCoordinate
  , ProviderAwsScopeReceiptError (..)
  , providerAwsScopeReceiptMaximumLength
  , providerExecutionResultForAuthority
  , AuthorityProviderAwsScopeReader (..)
  , lifecycleAuthorityProviderAwsScopeReaderInternal
  , readBackVerifiedAuthorityProviderAwsScope
  , readBackVerifiedAuthorityProviderAwsScopeInternal
  , verifyAuthorityProviderAwsScopeCompletion
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (readAuthorityAdmission)
  , AuthorityAdmissionSnapshot (authorityAdmissionSnapshotState)
  )
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ExecutedProviderIntent
  , ProviderIntentExecutionResult (..)
  , executedProviderIntentAction
  , executedProviderIntentResult
  )
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityProviderOperation (..)
  , authorityAggregateProviderOperations
  )
import Prodbox.Lifecycle.Authority.Submission
  ( OperationId
  , operationIdClient
  , operationIdDigest
  , operationIdSequence
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (ObserveProviderAwsScope)
  , ProviderIntentCoordinate
  , ProviderRevision
  , mkProviderRevision
  , providerIntentCoordinate
  , providerIntentCoordinateFromText
  , providerIntentCoordinateText
  , providerRevisionNatural
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (AwsAccountId)
  , AwsRegion (AwsRegion)
  )
import Prodbox.Lifecycle.Teardown.ProviderAwsScopeAdapter
  ( ProviderAwsScopeAdapterError
  , VerifiedProviderAwsScope
  , decodeVerifiedProviderAwsScope
  , verifiedProviderAwsScopeAccountId
  , verifiedProviderAwsScopeCoordinate
  , verifiedProviderAwsScopeOperationId
  , verifiedProviderAwsScopeRegion
  , verifiedProviderAwsScopeRevision
  )

-- | The Authority-side proof is deliberately distinct from the
-- Provider-process-local proof.  Its constructor is package-private and it can
-- only be recovered from an exact completed retained operation.
data VerifiedAuthorityProviderAwsScope = VerifiedAuthorityProviderAwsScope
  { internalAuthorityProviderAwsScopeAccountId :: !AwsAccountId
  , internalAuthorityProviderAwsScopeRegion :: !AwsRegion
  , internalAuthorityProviderAwsScopeRevision :: !ProviderRevision
  , internalAuthorityProviderAwsScopeOperationId :: !OperationId
  , internalAuthorityProviderAwsScopeCoordinate :: !ProviderIntentCoordinate
  }

verifiedAuthorityProviderAwsScopeAccountId
  :: VerifiedAuthorityProviderAwsScope -> AwsAccountId
verifiedAuthorityProviderAwsScopeAccountId =
  internalAuthorityProviderAwsScopeAccountId

verifiedAuthorityProviderAwsScopeRegion
  :: VerifiedAuthorityProviderAwsScope -> AwsRegion
verifiedAuthorityProviderAwsScopeRegion =
  internalAuthorityProviderAwsScopeRegion

verifiedAuthorityProviderAwsScopeRevision
  :: VerifiedAuthorityProviderAwsScope -> ProviderRevision
verifiedAuthorityProviderAwsScopeRevision =
  internalAuthorityProviderAwsScopeRevision

verifiedAuthorityProviderAwsScopeOperationId
  :: VerifiedAuthorityProviderAwsScope -> OperationId
verifiedAuthorityProviderAwsScopeOperationId =
  internalAuthorityProviderAwsScopeOperationId

verifiedAuthorityProviderAwsScopeCoordinate
  :: VerifiedAuthorityProviderAwsScope -> ProviderIntentCoordinate
verifiedAuthorityProviderAwsScopeCoordinate =
  internalAuthorityProviderAwsScopeCoordinate

data ProviderAwsScopeReceiptError
  = ProviderAwsScopeReceiptLocalProofInvalid !ProviderAwsScopeAdapterError
  | ProviderAwsScopeReceiptResultKindMismatch
  | ProviderAwsScopeReceiptTooLarge !Int !Int
  | ProviderAwsScopeReceiptPrefixInvalid
  | ProviderAwsScopeReceiptBase64Invalid
  | ProviderAwsScopeReceiptMalformed
  | ProviderAwsScopeReceiptNonCanonical
  | ProviderAwsScopeReceiptVersionUnsupported !Word16
  | ProviderAwsScopeReceiptOperationInvalid
  | ProviderAwsScopeReceiptRevisionInvalid
  | ProviderAwsScopeReceiptCoordinateInvalid
  | ProviderAwsScopeReceiptAccountInvalid
  | ProviderAwsScopeReceiptRegionInvalid
  | ProviderAwsScopeRetainedPending
  | ProviderAwsScopeAuthorityReadUnavailable !Text
  | ProviderAwsScopeRetainedOperationMissing
  | ProviderAwsScopeRetainedIntentMismatch
  | ProviderAwsScopeRetainedDigestMismatch
  | ProviderAwsScopeRetainedOperationMismatch
  deriving stock (Eq, Show)

data WireProviderAwsScopeReceipt = WireProviderAwsScopeReceipt
  { wireProviderAwsScopeReceiptVersion :: !Word16
  , wireProviderAwsScopeReceiptOperationId :: !Text
  , wireProviderAwsScopeReceiptRevision :: !Natural
  , wireProviderAwsScopeReceiptCoordinate :: !Text
  , wireProviderAwsScopeReceiptAccount :: !Text
  , wireProviderAwsScopeReceiptRegion :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

providerAwsScopeReceiptVersion :: Word16
providerAwsScopeReceiptVersion = 1

providerAwsScopeReceiptPrefix :: Text
providerAwsScopeReceiptPrefix = "provider-aws-scope-receipt-v1:"

-- | The Authority aggregate permits at most 4096 characters of Provider
-- evidence.  The exact scope receipt is intentionally bounded far below that.
providerAwsScopeReceiptMaximumLength :: Int
providerAwsScopeReceiptMaximumLength = 1024

-- | Convert the exact locally admitted execution into the terminal wire result
-- returned to the Authority.  Existing intents retain their existing evidence
-- representation; the new AWS-scope intent alone receives the full receipt.
providerExecutionResultForAuthority
  :: ExecutedProviderIntent
  -> Either ProviderAwsScopeReceiptError ProviderIntentExecutionResult
providerExecutionResultForAuthority executed =
  case executedProviderIntentAction executed of
    ObserveProviderAwsScope -> do
      verified <-
        first
          ProviderAwsScopeReceiptLocalProofInvalid
          (decodeVerifiedProviderAwsScope executed)
      receipt <- encodeReceipt verified
      case executedProviderIntentResult executed of
        ProviderIntentExecutionObserved coordinate _ ->
          Right (ProviderIntentExecutionObserved coordinate receipt)
        ProviderIntentExecutionApplied {} ->
          Left ProviderAwsScopeReceiptResultKindMismatch
        ProviderIntentExecutionAlreadySatisfied {} ->
          Left ProviderAwsScopeReceiptResultKindMismatch
    _ -> Right (executedProviderIntentResult executed)

-- | Package-private Authority reader capability.  Only an Authority-owned
-- composition module may bind this capability to a retained repository; the
-- public facade deliberately exposes neither this constructor nor its
-- repository factory.
newtype AuthorityProviderAwsScopeReader m = AuthorityProviderAwsScopeReader
  { internalReadBackVerifiedAuthorityProviderAwsScope
      :: OperationId
      -> m
           ( Either
               ProviderAwsScopeReceiptError
               VerifiedAuthorityProviderAwsScope
           )
  }

lifecycleAuthorityProviderAwsScopeReaderInternal
  :: (Monad m)
  => AuthorityAdmissionRepository m revision
  -> AuthorityProviderAwsScopeReader m
lifecycleAuthorityProviderAwsScopeReaderInternal repository =
  AuthorityProviderAwsScopeReader
    (readBackVerifiedAuthorityProviderAwsScopeInternal repository)

readBackVerifiedAuthorityProviderAwsScope
  :: AuthorityProviderAwsScopeReader m
  -> OperationId
  -> m
       ( Either
           ProviderAwsScopeReceiptError
           VerifiedAuthorityProviderAwsScope
       )
readBackVerifiedAuthorityProviderAwsScope =
  internalReadBackVerifiedAuthorityProviderAwsScope

-- | Perform a fresh Authority-store observation, select the exact retained
-- operation by its full @(client, sequence)@ identity, and only then invoke the
-- package-private receipt verifier.  Missing and unobservable are explicit;
-- neither can be promoted into an AWS-scope proof.
readBackVerifiedAuthorityProviderAwsScopeInternal
  :: (Monad m)
  => AuthorityAdmissionRepository m revision
  -> OperationId
  -> m
       ( Either
           ProviderAwsScopeReceiptError
           VerifiedAuthorityProviderAwsScope
       )
readBackVerifiedAuthorityProviderAwsScopeInternal repository expectedOperation = do
  observed <- readAuthorityAdmission repository
  pure $ do
    snapshot <- first ProviderAwsScopeAuthorityReadUnavailable observed
    retained <-
      maybe
        (Left ProviderAwsScopeRetainedOperationMissing)
        Right
        ( Map.lookup
            ( operationIdClient expectedOperation
            , operationIdSequence expectedOperation
            )
            ( authorityAggregateProviderOperations
                (authorityAdmissionSnapshotState snapshot)
            )
        )
    verifyAuthorityProviderAwsScopeCompletion expectedOperation retained

-- | Remint the Authority proof only from the exact retained completed
-- operation selected by an independent aggregate read.  This function remains
-- package-private so raw aggregate constructors cannot become a public proof
-- minting surface.
verifyAuthorityProviderAwsScopeCompletion
  :: OperationId
  -> AuthorityProviderOperation
  -> Either ProviderAwsScopeReceiptError VerifiedAuthorityProviderAwsScope
verifyAuthorityProviderAwsScopeCompletion expectedOperation retained = do
  (retainedDigest, evidence) <- case retained of
    AuthorityProviderPending {} -> Left ProviderAwsScopeRetainedPending
    AuthorityProviderCompleted digest intent payload -> do
      if intent == ObserveProviderAwsScope
        then Right ()
        else Left ProviderAwsScopeRetainedIntentMismatch
      Right (digest, payload)
  if retainedDigest == operationIdDigest expectedOperation
    then Right ()
    else Left ProviderAwsScopeRetainedDigestMismatch
  wire <- decodeReceipt evidence
  let expectedOperationText = operationIdentityText expectedOperation
  if wireProviderAwsScopeReceiptOperationId wire == expectedOperationText
    then Right ()
    else Left ProviderAwsScopeRetainedOperationMismatch
  revision <-
    first
      (const ProviderAwsScopeReceiptRevisionInvalid)
      (mkProviderRevision (wireProviderAwsScopeReceiptRevision wire))
  let coordinate =
        providerIntentCoordinateFromText
          (wireProviderAwsScopeReceiptCoordinate wire)
      expectedCoordinate = providerIntentCoordinate ObserveProviderAwsScope
  if coordinate == expectedCoordinate
    then Right ()
    else Left ProviderAwsScopeReceiptCoordinateInvalid
  account <- validateAccount (wireProviderAwsScopeReceiptAccount wire)
  region <- validateRegion (wireProviderAwsScopeReceiptRegion wire)
  Right
    VerifiedAuthorityProviderAwsScope
      { internalAuthorityProviderAwsScopeAccountId = AwsAccountId account
      , internalAuthorityProviderAwsScopeRegion = AwsRegion region
      , internalAuthorityProviderAwsScopeRevision = revision
      , internalAuthorityProviderAwsScopeOperationId = expectedOperation
      , internalAuthorityProviderAwsScopeCoordinate = coordinate
      }

encodeReceipt
  :: VerifiedProviderAwsScope
  -> Either ProviderAwsScopeReceiptError Text
encodeReceipt verified = do
  let AwsAccountId account = verifiedProviderAwsScopeAccountId verified
      AwsRegion region = verifiedProviderAwsScopeRegion verified
      operationText = verifiedProviderAwsScopeOperationId verified
      coordinateText =
        providerIntentCoordinateText
          (verifiedProviderAwsScopeCoordinate verified)
  validateOperation operationText
  _ <- validateAccount account
  _ <- validateRegion region
  let bytes =
        LazyByteString.toStrict
          ( serialise
              WireProviderAwsScopeReceipt
                { wireProviderAwsScopeReceiptVersion =
                    providerAwsScopeReceiptVersion
                , wireProviderAwsScopeReceiptOperationId = operationText
                , wireProviderAwsScopeReceiptRevision =
                    providerRevisionNatural
                      (verifiedProviderAwsScopeRevision verified)
                , wireProviderAwsScopeReceiptCoordinate = coordinateText
                , wireProviderAwsScopeReceiptAccount = account
                , wireProviderAwsScopeReceiptRegion = region
                }
          )
      receipt =
        providerAwsScopeReceiptPrefix
          <> TextEncoding.decodeUtf8 (Base64.encode bytes)
  if Text.length receipt > providerAwsScopeReceiptMaximumLength
    then
      Left
        ( ProviderAwsScopeReceiptTooLarge
            (Text.length receipt)
            providerAwsScopeReceiptMaximumLength
        )
    else Right receipt

decodeReceipt
  :: Text
  -> Either ProviderAwsScopeReceiptError WireProviderAwsScopeReceipt
decodeReceipt receipt = do
  if Text.length receipt > providerAwsScopeReceiptMaximumLength
    then
      Left
        ( ProviderAwsScopeReceiptTooLarge
            (Text.length receipt)
            providerAwsScopeReceiptMaximumLength
        )
    else Right ()
  encoded <-
    maybe
      (Left ProviderAwsScopeReceiptPrefixInvalid)
      Right
      (Text.stripPrefix providerAwsScopeReceiptPrefix receipt)
  bytes <-
    either
      (const (Left ProviderAwsScopeReceiptBase64Invalid))
      Right
      (Base64.decode (TextEncoding.encodeUtf8 encoded))
  if Base64.encode bytes == TextEncoding.encodeUtf8 encoded
    then Right ()
    else Left ProviderAwsScopeReceiptNonCanonical
  if ByteString.length bytes > providerAwsScopeReceiptMaximumLength
    then
      Left
        ( ProviderAwsScopeReceiptTooLarge
            (ByteString.length bytes)
            providerAwsScopeReceiptMaximumLength
        )
    else Right ()
  wire <-
    either
      (const (Left ProviderAwsScopeReceiptMalformed))
      Right
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  if LazyByteString.toStrict (serialise wire) == bytes
    then Right ()
    else Left ProviderAwsScopeReceiptNonCanonical
  if wireProviderAwsScopeReceiptVersion wire == providerAwsScopeReceiptVersion
    then Right ()
    else
      Left
        ( ProviderAwsScopeReceiptVersionUnsupported
            (wireProviderAwsScopeReceiptVersion wire)
        )
  validateOperation (wireProviderAwsScopeReceiptOperationId wire)
  _ <-
    first
      (const ProviderAwsScopeReceiptRevisionInvalid)
      (mkProviderRevision (wireProviderAwsScopeReceiptRevision wire))
  let coordinate = wireProviderAwsScopeReceiptCoordinate wire
  if coordinate
    == providerIntentCoordinateText
      (providerIntentCoordinate ObserveProviderAwsScope)
    then Right ()
    else Left ProviderAwsScopeReceiptCoordinateInvalid
  _ <- validateAccount (wireProviderAwsScopeReceiptAccount wire)
  _ <- validateRegion (wireProviderAwsScopeReceiptRegion wire)
  Right wire

operationIdentityText :: OperationId -> Text
operationIdentityText =
  TextEncoding.decodeUtf8
    . hexSha256
    . LazyByteString.toStrict
    . serialise

validateOperation :: Text -> Either ProviderAwsScopeReceiptError ()
validateOperation operation
  | Text.length operation == 64 && Text.all isLowerHex operation = Right ()
  | otherwise = Left ProviderAwsScopeReceiptOperationInvalid

validateAccount :: Text -> Either ProviderAwsScopeReceiptError Text
validateAccount account
  | Text.length account == 12 && Text.all isAsciiDigit account = Right account
  | otherwise = Left ProviderAwsScopeReceiptAccountInvalid

validateRegion :: Text -> Either ProviderAwsScopeReceiptError Text
validateRegion region
  | Text.length region < 3 || Text.length region > 63 = invalid
  | Text.head region == '-' || Text.last region == '-' = invalid
  | not (Text.all isRegionCharacter region) = invalid
  | length segments < 3 || any Text.null segments = invalid
  | not (Text.all isAsciiDigit (last segments)) = invalid
  | not (any (Text.any isAsciiLower) (init segments)) = invalid
  | otherwise = Right region
 where
  segments = Text.splitOn "-" region
  invalid = Left ProviderAwsScopeReceiptRegionInvalid

isLowerHex :: Char -> Bool
isLowerHex character =
  isAsciiDigit character || (character >= 'a' && character <= 'f')

isRegionCharacter :: Char -> Bool
isRegionCharacter character =
  isAsciiLower character || isAsciiDigit character || character == '-'

isAsciiLower :: Char -> Bool
isAsciiLower character = character >= 'a' && character <= 'z'

isAsciiDigit :: Char -> Bool
isAsciiDigit character = character >= '0' && character <= '9'
