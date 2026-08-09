{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed exact-coordinate DNS resource programs.
--
-- Records are keyed by account, hosted zone, canonical FQDN, record type,
-- owner, and ownership epoch. Mutation is interpreted only through the owner
-- bound to that coordinate and closes with authoritative read-back; there is no
-- generic Route 53 or fallback-writer constructor.
--
-- A destroy additionally requires the 'DnsOwnerAuthority' the running process
-- holds ("Prodbox.Lifecycle.DnsRecord.Owner"), because the coordinate-versus-
-- boundary comparison the interpreter already performed proves only that one
-- caller supplied the same owner twice.
module Prodbox.Lifecycle.DnsRecord
  ( AwsAccountId
  , HostedZoneId
  , OwnershipEpoch
  , KubernetesUid
  , DnsRecordType (..)
  , DnsRecordOwner (..)
  , DnsOwnerAuthority
  , allDnsRecordOwners
  , dnsOwnerAuthorityForProcess
  , authorizedDnsOwner
  , DnsRecordCoordinate
  , DnsRecordValue
  , DnsRecordSet
  , DnsRecordRegistration (..)
  , DnsCoordinateError (..)
  , DnsRecordObservation (..)
  , DnsRecordProgram (..)
  , DnsRecordBoundary (..)
  , DnsProgramResult (..)
  , mkAwsAccountId
  , mkHostedZoneId
  , mkOwnershipEpoch
  , mkKubernetesUid
  , mkPublicARecordCoordinate
  , mkDns01ChallengeRegistration
  , mkDns01ChallengeCoordinate
  , dns01ChallengeRecordName
  , mkDnsRecordValue
  , mkDnsRecordSet
  , awsAccountIdText
  , hostedZoneIdText
  , ownershipEpochValue
  , dnsCoordinateAccount
  , dnsCoordinateZone
  , dnsCoordinateName
  , dnsCoordinateType
  , dnsCoordinateOwner
  , dnsCoordinateEpoch
  , dnsRecordValueText
  , dnsRecordSetTtl
  , dnsRecordSetValues
  , dnsRecordLifecycleClass
  , runDnsRecordProgram
  )
where

import Data.Char (isAlphaNum, isControl, isDigit, isSpace)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityEpoch
  , authorityEpochValue
  )
import Prodbox.Lifecycle.DnsRecord.Owner
  ( DnsOwnerAuthority
  , DnsRecordOwner (..)
  , allDnsRecordOwners
  , authorizedDnsOwner
  , dnsOwnerAuthorityForProcess
  )
import Prodbox.Lifecycle.ResourceClass (LifecycleClass (..))
import Prodbox.Tls.CertScope (Fqdn, fqdnText, mkFqdn)
import Text.Read (readMaybe)

newtype AwsAccountId = AwsAccountId Text
  deriving stock (Eq, Ord, Show)

newtype HostedZoneId = HostedZoneId Text
  deriving stock (Eq, Ord, Show)

newtype OwnershipEpoch = OwnershipEpoch AuthorityEpoch
  deriving stock (Eq, Ord, Show)

newtype KubernetesUid = KubernetesUid Text
  deriving stock (Eq, Ord, Show)

data DnsRecordType = DnsRecordA | DnsRecordTxt
  deriving stock (Eq, Ord, Show)

data DnsRecordCoordinate = DnsRecordCoordinate
  { internalDnsAccount :: !AwsAccountId
  , internalDnsZone :: !HostedZoneId
  , internalDnsName :: !DnsRecordName
  , internalDnsType :: !DnsRecordType
  , internalDnsOwner :: !DnsRecordOwner
  , internalDnsEpoch :: !OwnershipEpoch
  }
  deriving stock (Eq, Show)

newtype DnsRecordName = DnsRecordName Text
  deriving stock (Eq, Ord, Show)

newtype DnsRecordValue = DnsRecordValue Text
  deriving stock (Eq, Ord, Show)

data DnsRecordRegistration
  = PublicARecordRegistration !DnsRecordCoordinate
  | Dns01ChallengeRegistration !KubernetesUid !KubernetesUid !DnsRecordCoordinate
  deriving stock (Eq, Show)

data DnsCoordinateError
  = AwsAccountIdInvalid !Text
  | HostedZoneIdInvalid !Text
  | KubernetesUidInvalid !Text
  | DnsFqdnInvalid !Text
  | DnsOwnerTypeMismatch !DnsRecordOwner !DnsRecordType
  | DnsRecordValueEmpty
  | DnsRecordValueInvalid !DnsRecordType !Text
  | DnsRecordTtlInvalid !Natural
  deriving stock (Eq, Show)

data DnsRecordObservation
  = DnsRecordMissing
  | DnsRecordObserved !DnsRecordSet
  | DnsRecordEndpointUnready !Text
  | DnsRecordUnobservable !Text
  deriving stock (Eq, Show)

data DnsRecordProgram result where
  ObserveDnsRecord :: DnsRecordProgram DnsRecordObservation
  EnsureDnsRecord :: DnsRecordSet -> DnsRecordProgram DnsProgramResult
  -- | The authority is the running process's, not a second copy of the
  -- coordinate's owner; see "Prodbox.Lifecycle.DnsRecord.Owner".
  DestroyDnsRecord :: DnsOwnerAuthority -> DnsRecordProgram DnsProgramResult

data DnsRecordBoundary m = DnsRecordBoundary
  { dnsBoundaryCoordinate :: !DnsRecordCoordinate
  , dnsBoundaryObserve :: m DnsRecordObservation
  , dnsBoundaryEnsure :: DnsRecordSet -> m (Either Text ())
  , dnsBoundaryDestroy :: DnsRecordSet -> m (Either Text ())
  }

data DnsProgramResult
  = DnsEnsureAlreadyConverged
  | DnsEnsureAppliedAndReadBack
  | DnsDestroyAlreadyAbsent
  | DnsDestroyAppliedAndReadBack
  | DnsProgramOwnerMismatch !DnsRecordOwner !DnsRecordOwner
  | -- | The running process holds the first owner and the coordinate is bound
    -- to the second.  Distinct from 'DnsProgramOwnerMismatch', which compares
    -- two caller-supplied coordinates and so cannot see this case at all.
    DnsProgramOwnerUnauthorized !DnsRecordOwner !DnsRecordOwner
  | DnsProgramCoordinateMismatch !DnsRecordCoordinate !DnsRecordCoordinate
  | DnsProgramInitialObservationRefused !DnsRecordObservation
  | DnsProgramMutationFailed !Text !DnsRecordObservation
  | DnsProgramPostconditionFailed !DnsRecordObservation
  deriving stock (Eq, Show)

mkAwsAccountId :: Text -> Either DnsCoordinateError AwsAccountId
mkAwsAccountId value
  | Text.length value == 12 && Text.all isDigit value = Right (AwsAccountId value)
  | otherwise = Left (AwsAccountIdInvalid value)

mkHostedZoneId :: Text -> Either DnsCoordinateError HostedZoneId
mkHostedZoneId raw
  | Text.null value || Text.length value > 64 = Left (HostedZoneIdInvalid raw)
  | Text.all validCharacter value = Right (HostedZoneId value)
  | otherwise = Left (HostedZoneIdInvalid raw)
 where
  value = Text.strip raw
  validCharacter character = isAlphaNum character || character == '-'

-- | Bind a DNS owner generation to the activated Lifecycle Authority epoch.
-- There is intentionally no constructor from an arbitrary number or from a
-- Gateway continuity/emitter epoch.
mkOwnershipEpoch :: AuthorityEpoch -> OwnershipEpoch
mkOwnershipEpoch = OwnershipEpoch

mkKubernetesUid :: Text -> Either DnsCoordinateError KubernetesUid
mkKubernetesUid raw
  | Text.null value || Text.length value > 128 = Left (KubernetesUidInvalid raw)
  | Text.any (\character -> isControl character || isSpace character) value =
      Left (KubernetesUidInvalid raw)
  | otherwise = Right (KubernetesUid value)
 where
  value = Text.strip raw

mkPublicARecordCoordinate
  :: AwsAccountId
  -> HostedZoneId
  -> Text
  -> DnsRecordOwner
  -> OwnershipEpoch
  -> Either DnsCoordinateError DnsRecordCoordinate
mkPublicARecordCoordinate account zone rawFqdn owner epoch = do
  ensureOwnerType owner DnsRecordA
  fqdn <- mapFqdnError rawFqdn
  pure (DnsRecordCoordinate account zone (DnsRecordName (fqdnText fqdn)) DnsRecordA owner epoch)

-- | Sprint 5.29: the __pre-issuance__ half of a DNS01 challenge coordinate.
--
-- 'mkDns01ChallengeRegistration' demands two Kubernetes UIDs, and cert-manager
-- mints the Challenge object only after the ACME Order — i.e. after the
-- mutation. A coordinate that must be registered /before/ the record exists
-- therefore cannot carry them, and pretending otherwise is what made the
-- registration unbuildable in practice. The UIDs attach afterwards, as
-- evidence, through 'mkDns01ChallengeRegistration'.
mkDns01ChallengeCoordinate
  :: AwsAccountId
  -> HostedZoneId
  -> Text
  -> DnsRecordOwner
  -> OwnershipEpoch
  -> Either DnsCoordinateError DnsRecordCoordinate
mkDns01ChallengeCoordinate account zone rawCertificateFqdn owner epoch = do
  ensureOwnerType owner DnsRecordTxt
  certificateFqdn <- mapFqdnError rawCertificateFqdn
  pure
    ( DnsRecordCoordinate
        account
        zone
        (DnsRecordName (dns01ChallengeRecordName certificateFqdn))
        DnsRecordTxt
        owner
        epoch
    )

-- | The exact record name a DNS01 solver writes for a certificate FQDN. One
-- definition, so the pre-issuance registration, the deletion node, and the
-- absence read-back cannot disagree about which name they mean.
dns01ChallengeRecordName :: Fqdn -> Text
dns01ChallengeRecordName certificateFqdn = "_acme-challenge." <> fqdnText certificateFqdn

mkDns01ChallengeRegistration
  :: AwsAccountId
  -> HostedZoneId
  -> Text
  -> DnsRecordOwner
  -> OwnershipEpoch
  -> KubernetesUid
  -> KubernetesUid
  -> Either DnsCoordinateError DnsRecordRegistration
mkDns01ChallengeRegistration account zone rawCertificateFqdn owner epoch certificateUid challengeUid = do
  ensureOwnerType owner DnsRecordTxt
  certificateFqdn <- mapFqdnError rawCertificateFqdn
  let challengeName = DnsRecordName (dns01ChallengeRecordName certificateFqdn)
  pure
    ( Dns01ChallengeRegistration
        certificateUid
        challengeUid
        (DnsRecordCoordinate account zone challengeName DnsRecordTxt owner epoch)
    )

mapFqdnError :: Text -> Either DnsCoordinateError Fqdn
mapFqdnError raw =
  case mkFqdn raw of
    Left _ -> Left (DnsFqdnInvalid raw)
    Right fqdn -> Right fqdn

ensureOwnerType :: DnsRecordOwner -> DnsRecordType -> Either DnsCoordinateError ()
ensureOwnerType owner recordType
  | ownerAcceptsType owner recordType = Right ()
  | otherwise = Left (DnsOwnerTypeMismatch owner recordType)

ownerAcceptsType :: DnsRecordOwner -> DnsRecordType -> Bool
ownerAcceptsType owner recordType = case (owner, recordType) of
  (HomeGatewayDnsOwner, DnsRecordA) -> True
  (AwsLifecycleProviderDnsOwner, DnsRecordA) -> True
  (HomeCertManagerDns01Owner, DnsRecordTxt) -> True
  (AwsCertManagerDns01Owner, DnsRecordTxt) -> True
  _ -> False

mkDnsRecordValue :: DnsRecordType -> Text -> Either DnsCoordinateError DnsRecordValue
mkDnsRecordValue recordType raw
  | Text.null value = Left DnsRecordValueEmpty
  | validRecordValue recordType value = Right (DnsRecordValue value)
  | otherwise = Left (DnsRecordValueInvalid recordType raw)
 where
  value = Text.strip raw

data DnsRecordSet = DnsRecordSet
  { internalDnsRecordSetTtl :: !Natural
  , internalDnsRecordSetValues :: !(Set DnsRecordValue)
  }
  deriving stock (Eq, Show)

mkDnsRecordSet
  :: Natural
  -> NonEmpty DnsRecordValue
  -> Either DnsCoordinateError DnsRecordSet
mkDnsRecordSet ttl values
  | ttl == 0 || ttl > 2147483647 = Left (DnsRecordTtlInvalid ttl)
  | otherwise =
      Right
        DnsRecordSet
          { internalDnsRecordSetTtl = ttl
          , internalDnsRecordSetValues = Set.fromList (NonEmpty.toList values)
          }

validRecordValue :: DnsRecordType -> Text -> Bool
validRecordValue recordType value = case recordType of
  DnsRecordA -> validIpv4 value
  DnsRecordTxt ->
    Text.length value <= 255
      && not (Text.any isControl value)

validIpv4 :: Text -> Bool
validIpv4 value =
  case traverse parseOctet (Text.splitOn "." value) of
    Just [_, _, _, _] -> True
    _ -> False
 where
  parseOctet octet
    | Text.null octet = Nothing
    | Text.length octet > 1 && Text.isPrefixOf "0" octet = Nothing
    | not (Text.all isDigit octet) = Nothing
    | otherwise = do
        number <- readMaybe (Text.unpack octet) :: Maybe Int
        if number >= 0 && number <= 255 then Just number else Nothing

dnsCoordinateAccount :: DnsRecordCoordinate -> AwsAccountId
dnsCoordinateAccount = internalDnsAccount

awsAccountIdText :: AwsAccountId -> Text
awsAccountIdText (AwsAccountId value) = value

dnsCoordinateZone :: DnsRecordCoordinate -> HostedZoneId
dnsCoordinateZone = internalDnsZone

hostedZoneIdText :: HostedZoneId -> Text
hostedZoneIdText (HostedZoneId value) = value

dnsCoordinateName :: DnsRecordCoordinate -> Text
dnsCoordinateName coordinate = case internalDnsName coordinate of
  DnsRecordName value -> value

dnsCoordinateType :: DnsRecordCoordinate -> DnsRecordType
dnsCoordinateType = internalDnsType

dnsCoordinateOwner :: DnsRecordCoordinate -> DnsRecordOwner
dnsCoordinateOwner = internalDnsOwner

dnsCoordinateEpoch :: DnsRecordCoordinate -> OwnershipEpoch
dnsCoordinateEpoch = internalDnsEpoch

ownershipEpochValue :: OwnershipEpoch -> Natural
ownershipEpochValue (OwnershipEpoch epoch) = authorityEpochValue epoch

dnsRecordValueText :: DnsRecordValue -> Text
dnsRecordValueText (DnsRecordValue value) = value

dnsRecordSetTtl :: DnsRecordSet -> Natural
dnsRecordSetTtl = internalDnsRecordSetTtl

dnsRecordSetValues :: DnsRecordSet -> Set DnsRecordValue
dnsRecordSetValues = internalDnsRecordSetValues

dnsRecordLifecycleClass :: DnsRecordCoordinate -> LifecycleClass
dnsRecordLifecycleClass coordinate = case internalDnsOwner coordinate of
  HomeGatewayDnsOwner -> LongLived
  HomeCertManagerDns01Owner -> LongLived
  AwsLifecycleProviderDnsOwner -> PerRun
  AwsCertManagerDns01Owner -> PerRun

runDnsRecordProgram
  :: (Monad m)
  => DnsRecordBoundary m
  -> DnsRecordCoordinate
  -> DnsRecordProgram result
  -> m result
runDnsRecordProgram boundary coordinate program = case program of
  ObserveDnsRecord
    | coordinateMatches -> dnsBoundaryObserve boundary
    | otherwise -> pure (DnsRecordUnobservable "DNS boundary coordinate mismatch")
  EnsureDnsRecord values -> runEnsure values
  DestroyDnsRecord authority -> runDestroy authority
 where
  boundCoordinate = dnsBoundaryCoordinate boundary
  ownerMatches = internalDnsOwner boundCoordinate == internalDnsOwner coordinate
  coordinateMatches = boundCoordinate == coordinate

  runEnsure values
    | not ownerMatches =
        pure (DnsProgramOwnerMismatch (internalDnsOwner coordinate) (internalDnsOwner boundCoordinate))
    | not coordinateMatches =
        pure (DnsProgramCoordinateMismatch coordinate boundCoordinate)
    | otherwise = do
        initial <- dnsBoundaryObserve boundary
        if observationMatches values initial
          then pure DnsEnsureAlreadyConverged
          else case initial of
            DnsRecordEndpointUnready _ -> pure (DnsProgramInitialObservationRefused initial)
            DnsRecordUnobservable _ -> pure (DnsProgramInitialObservationRefused initial)
            _ -> do
              mutation <- dnsBoundaryEnsure boundary values
              final <- dnsBoundaryObserve boundary
              pure $ case mutation of
                Left detail -> DnsProgramMutationFailed detail final
                Right ()
                  | observationMatches values final -> DnsEnsureAppliedAndReadBack
                  | otherwise -> DnsProgramPostconditionFailed final

  runDestroy authority
    | authorizedDnsOwner authority /= internalDnsOwner coordinate =
        pure
          ( DnsProgramOwnerUnauthorized
              (authorizedDnsOwner authority)
              (internalDnsOwner coordinate)
          )
    | not ownerMatches =
        pure (DnsProgramOwnerMismatch (internalDnsOwner coordinate) (internalDnsOwner boundCoordinate))
    | not coordinateMatches =
        pure (DnsProgramCoordinateMismatch coordinate boundCoordinate)
    | otherwise = do
        initial <- dnsBoundaryObserve boundary
        case initial of
          DnsRecordMissing -> pure DnsDestroyAlreadyAbsent
          DnsRecordEndpointUnready _ -> pure (DnsProgramInitialObservationRefused initial)
          DnsRecordUnobservable _ -> pure (DnsProgramInitialObservationRefused initial)
          DnsRecordObserved observed -> do
            mutation <- dnsBoundaryDestroy boundary observed
            final <- dnsBoundaryObserve boundary
            pure $ case mutation of
              Left detail -> DnsProgramMutationFailed detail final
              Right () -> case final of
                DnsRecordMissing -> DnsDestroyAppliedAndReadBack
                _ -> DnsProgramPostconditionFailed final

observationMatches :: DnsRecordSet -> DnsRecordObservation -> Bool
observationMatches expected observation = case observation of
  DnsRecordObserved observed -> observed == expected
  _ -> False
