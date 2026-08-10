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
  , allDnsRecordTypes
  , DnsRecordOwner (..)
  , DnsOwnerAuthority
  , allDnsRecordOwners
  , dnsOwnerAuthoritiesForProcess
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
  , mkSesVerificationCoordinate
  , mkSesDkimCoordinate
  , mkSesInboundMxCoordinate
  , sesVerificationRecordName
  , sesDkimRecordName
  , sesInboundMxRecordName
  , ownerAcceptsType
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

import Control.Monad (guard)
import Data.Char (isAlphaNum, isAsciiLower, isControl, isDigit, isSpace)
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
  , dnsOwnerAuthoritiesForProcess
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

-- | Sprint @4.73@ adds CNAME and MX, which the SES identity, DKIM, and inbound
-- lanes write.  'Enum'\/'Bounded' exist so the owner\/type rule below can be
-- proven total over the whole matrix rather than sampled.
data DnsRecordType
  = DnsRecordA
  | DnsRecordTxt
  | DnsRecordCname
  | DnsRecordMx
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Every record type, for total folds and inventory proofs.
allDnsRecordTypes :: [DnsRecordType]
allDnsRecordTypes = [minBound .. maxBound]

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
  | SesDkimTokenInvalid !Text
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
  -- | Sprint 3.33: an ensure is a mutation against the same coordinate and is
  -- the same /Direction/ class as a destroy — writing a record you do not own is
  -- not obviously less bad than deleting one. The authority is the running
  -- process's, not a second copy of the coordinate's owner.
  EnsureDnsRecord :: DnsOwnerAuthority -> DnsRecordSet -> DnsRecordProgram DnsProgramResult
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

-- | The exact record names the SES lane owns.
--
-- One definition each, for the same reason 'dns01ChallengeRecordName' has one:
-- the observation that decides whether a reconcile is needed, the ensure that
-- writes the record, and the read-back that closes it must not be able to
-- disagree about which name they mean.  The coordinate constructors below are
-- the only other caller, so the coordinate and the observation are the same
-- name by construction rather than by review.
sesVerificationRecordName :: Text -> Either DnsCoordinateError Text
sesVerificationRecordName rawIdentityDomain =
  (("_amazonses." <>) . fqdnText) <$> mapFqdnError rawIdentityDomain

sesDkimRecordName :: Text -> Text -> Either DnsCoordinateError Text
sesDkimRecordName rawToken rawIdentityDomain = do
  token <- mapDkimTokenError rawToken
  domain <- mapFqdnError rawIdentityDomain
  pure (token <> "._domainkey." <> fqdnText domain)

sesInboundMxRecordName :: Text -> Either DnsCoordinateError Text
sesInboundMxRecordName rawReceiveSubdomain =
  fqdnText <$> mapFqdnError rawReceiveSubdomain

-- | SES DKIM tokens are a single lower-case alphanumeric label.  Validating
-- one here keeps a malformed provider response from composing a record name
-- that is not a name at all.
mapDkimTokenError :: Text -> Either DnsCoordinateError Text
mapDkimTokenError raw
  | Text.null token || Text.length token > 63 = Left (SesDkimTokenInvalid raw)
  | Text.all validCharacter token = Right token
  | otherwise = Left (SesDkimTokenInvalid raw)
 where
  token = Text.strip raw
  validCharacter character = isAsciiLower character || isDigit character

-- | The SES sending identity's verification TXT coordinate.
mkSesVerificationCoordinate
  :: AwsAccountId
  -> HostedZoneId
  -> Text
  -> DnsRecordOwner
  -> OwnershipEpoch
  -> Either DnsCoordinateError DnsRecordCoordinate
mkSesVerificationCoordinate account zone rawIdentityDomain owner epoch = do
  ensureOwnerType owner DnsRecordTxt
  name <- sesVerificationRecordName rawIdentityDomain
  pure (DnsRecordCoordinate account zone (DnsRecordName name) DnsRecordTxt owner epoch)

-- | One SES DKIM CNAME coordinate.  SES publishes three tokens and therefore
-- three coordinates; a coordinate is one name and one type, so they are three
-- values rather than one.
mkSesDkimCoordinate
  :: AwsAccountId
  -> HostedZoneId
  -> Text
  -> Text
  -> DnsRecordOwner
  -> OwnershipEpoch
  -> Either DnsCoordinateError DnsRecordCoordinate
mkSesDkimCoordinate account zone rawToken rawIdentityDomain owner epoch = do
  ensureOwnerType owner DnsRecordCname
  name <- sesDkimRecordName rawToken rawIdentityDomain
  pure (DnsRecordCoordinate account zone (DnsRecordName name) DnsRecordCname owner epoch)

-- | The SES inbound MX coordinate for the receive subdomain.
mkSesInboundMxCoordinate
  :: AwsAccountId
  -> HostedZoneId
  -> Text
  -> DnsRecordOwner
  -> OwnershipEpoch
  -> Either DnsCoordinateError DnsRecordCoordinate
mkSesInboundMxCoordinate account zone rawReceiveSubdomain owner epoch = do
  ensureOwnerType owner DnsRecordMx
  name <- sesInboundMxRecordName rawReceiveSubdomain
  pure (DnsRecordCoordinate account zone (DnsRecordName name) DnsRecordMx owner epoch)

mapFqdnError :: Text -> Either DnsCoordinateError Fqdn
mapFqdnError raw =
  case mkFqdn raw of
    Left _ -> Left (DnsFqdnInvalid raw)
    Right fqdn -> Right fqdn

ensureOwnerType :: DnsRecordOwner -> DnsRecordType -> Either DnsCoordinateError ()
ensureOwnerType owner recordType
  | ownerAcceptsType owner recordType = Right ()
  | otherwise = Left (DnsOwnerTypeMismatch owner recordType)

-- | Which record types each owner may be bound to.
--
-- Sprint @4.73@ writes the whole matrix out.  The superseded body ended in a
-- wildcard @False@, which was correct for the pairs that existed and silently
-- wrong for every pair added afterwards: a new record type would have been
-- rejected for every owner without anyone deciding that, and the rejection
-- would have surfaced as an unconstructible coordinate rather than as a
-- missing decision.  Twenty explicit pairs means adding an owner or a type is a
-- compile error here.
ownerAcceptsType :: DnsRecordOwner -> DnsRecordType -> Bool
ownerAcceptsType owner recordType = case (owner, recordType) of
  (HomeGatewayDnsOwner, DnsRecordA) -> True
  (HomeGatewayDnsOwner, DnsRecordTxt) -> False
  (HomeGatewayDnsOwner, DnsRecordCname) -> False
  (HomeGatewayDnsOwner, DnsRecordMx) -> False
  (AwsLifecycleProviderDnsOwner, DnsRecordA) -> True
  (AwsLifecycleProviderDnsOwner, DnsRecordTxt) -> False
  (AwsLifecycleProviderDnsOwner, DnsRecordCname) -> False
  (AwsLifecycleProviderDnsOwner, DnsRecordMx) -> False
  -- The SES lane owns exactly the three types SES asks for, and no A record:
  -- the public A record belongs to the provider lane above, in the same
  -- account and often the same zone.
  (AwsSesDnsOwner, DnsRecordA) -> False
  (AwsSesDnsOwner, DnsRecordTxt) -> True
  (AwsSesDnsOwner, DnsRecordCname) -> True
  (AwsSesDnsOwner, DnsRecordMx) -> True
  (HomeCertManagerDns01Owner, DnsRecordA) -> False
  (HomeCertManagerDns01Owner, DnsRecordTxt) -> True
  (HomeCertManagerDns01Owner, DnsRecordCname) -> False
  (HomeCertManagerDns01Owner, DnsRecordMx) -> False
  (AwsCertManagerDns01Owner, DnsRecordA) -> False
  (AwsCertManagerDns01Owner, DnsRecordTxt) -> True
  (AwsCertManagerDns01Owner, DnsRecordCname) -> False
  (AwsCertManagerDns01Owner, DnsRecordMx) -> False

-- | Build a record value in the one canonical spelling of its type.
--
-- Sprint @4.73@: CNAME and MX carry a host name, and Route 53 accepts — and
-- echoes back — both the trailing-dot and the bare spelling of the same name,
-- as well as either letter case.  Canonicalizing __here__ rather than at each
-- comparison is what lets 'observationMatches' stay exact equality: the desired
-- value and the value read back from the provider are both built through this
-- function, so a spelling difference cannot present as drift and provoke a
-- rewrite of a record that is already correct.  The canonical spelling is the
-- fully-qualified, lower-case one, which is byte-identical to what this
-- repository already writes.
mkDnsRecordValue :: DnsRecordType -> Text -> Either DnsCoordinateError DnsRecordValue
mkDnsRecordValue recordType raw
  | Text.null value = Left DnsRecordValueEmpty
  | otherwise = case canonicalRecordValue recordType value of
      Just canonical -> Right (DnsRecordValue canonical)
      Nothing -> Left (DnsRecordValueInvalid recordType raw)
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

canonicalRecordValue :: DnsRecordType -> Text -> Maybe Text
canonicalRecordValue recordType value = case recordType of
  DnsRecordA -> if validIpv4 value then Just value else Nothing
  DnsRecordTxt ->
    -- A TXT value keeps its exact bytes, quotes included: Route 53 stores what
    -- it is given and the SES verification token is compared byte for byte.
    if Text.length value <= 255 && not (Text.any isControl value)
      then Just value
      else Nothing
  DnsRecordCname -> canonicalHostname value
  DnsRecordMx -> case Text.words value of
    [rawPreference, rawTarget] -> do
      preference <- readMaybe (Text.unpack rawPreference) :: Maybe Int
      guard (preference >= 0 && preference <= 65535)
      -- A padded spelling such as "010" is a second string for one preference;
      -- rejecting it keeps the canonical form unique.
      guard (Text.pack (show preference) == rawPreference)
      target <- canonicalHostname rawTarget
      pure (rawPreference <> " " <> target)
    _ -> Nothing

-- | A host name in its fully-qualified canonical spelling: lower case, exactly
-- one trailing dot, and every label a legal LDH label.  Underscore labels are
-- deliberately absent — they are legal in a record /name/ (RFC 8552, as in
-- @_amazonses@ and @_acme-challenge@) but not in the host name a CNAME or MX
-- record points at.
canonicalHostname :: Text -> Maybe Text
canonicalHostname raw
  | Text.null bare || Text.length bare > 253 = Nothing
  | all validLabel labels = Just (bare <> ".")
  | otherwise = Nothing
 where
  bare = Text.toLower (Text.dropWhileEnd (== '.') (Text.strip raw))
  labels = Text.splitOn "." bare
  validLabel label =
    not (Text.null label)
      && Text.length label <= 63
      && Text.all validLabelCharacter label
      && Text.head label /= '-'
      && Text.last label /= '-'
  validLabelCharacter character =
    isAsciiLower character || isDigit character || character == '-'

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
  -- The SES records live in the operator's long-lived parent zone alongside
  -- the rest of the retained @aws-ses@ infrastructure, which is why they are
  -- their own owner rather than the provider lane's: an owner decides this,
  -- and a shared owner would have decided it wrongly.
  AwsSesDnsOwner -> LongLived
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
  EnsureDnsRecord authority values -> runEnsure authority values
  DestroyDnsRecord authority -> runDestroy authority
 where
  boundCoordinate = dnsBoundaryCoordinate boundary
  ownerMatches = internalDnsOwner boundCoordinate == internalDnsOwner coordinate
  coordinateMatches = boundCoordinate == coordinate

  runEnsure authority values
    -- Sprint 3.33: the held authority is checked before the coordinate-versus-
    -- boundary comparison, in the same order `runDestroy` checks them, so an
    -- unauthorized caller is refused by the strongest available reason rather
    -- than by whichever mismatch happens to be reported first.
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
