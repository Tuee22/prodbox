{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.89: the Tier-0 coordinate algebra — the narrow types the config's
-- @Text@ and @Natural@ coordinate fields decode /into/, rather than the shapes
-- a comment claims they have.
--
-- This module exists because of a defect the deletion ledger recorded as one
-- row and Sprint 1.88 split in half. The closed half gave 'ValidatedSettings'
-- one production constructor. This is the other half: a config field whose
-- invariant is decided somewhere and then thrown away, so every consumer
-- re-reads the raw @Text@ and either re-decides it, or does not.
--
-- Two distinct defects live under that one description, and separating them is
-- what makes the fix small:
--
--   * __Decided and discarded.__ 'Prodbox.Settings.validateLocalConfig' already
--     refuses a malformed @ses.capture_bucket@, @aws_substrate.hosted_zone_id@,
--     or @pulumi_state_backend.key_prefix@ — and then returns @()@. The parse
--     happened; the proof did not survive it. This is exactly the /Provenance/
--     class of
--     [chaos_hardening_doctrine.md § 21](../../../../documents/engineering/chaos_hardening_doctrine.md)
--     that Sprint 1.83 closed for the public edge, and the same remedy applies:
--     the one validation keeps the value.
--
--   * __Never decided at all.__ @aws.region@, @pulumi_state_backend.region@,
--     @acme.email@ and @route53.zone_id@ reach live AWS, ACME,
--     and Route 53 calls having been checked, at most, for emptiness.
--     @route53.zone_id@ is the sharpest instance: it is structurally identical
--     to @aws_substrate.hosted_zone_id@, which /is/ shape-checked — so the home
--     zone id, the one every home DNS write uses, was the less defended of the
--     two. @pulumi_state_backend.region@ is the only field of its section with
--     no check at all while both its siblings have one.
--
-- Every type here is built only through its @mk@ constructor and projected back
-- through its accessor. The constructors are not exported, so a value of one of
-- these types is a proof its rule ran.
--
-- __The bound, stated honestly.__ These rules are /shape/ rules. An
-- 'AwsRegion' is a well-formed region name, not a region this account can reach;
-- a 'Route53ZoneId' is a well-formed zone id, not a zone that exists. Shape is
-- what config validation can decide without a network, and separating it from
-- reachability is the point: a typo now fails at decode with the field name,
-- where it used to fail inside an AWS SDK error at the point of use, or not at
-- all.
--
-- __Wire format is unchanged.__ Nothing here is a @FromDhall@ instance. The
-- Dhall record still carries @Text@ and @Natural@, because Dhall has no
-- refinement types and retyping the authored file would change every generated
-- @prodbox.dhall@ — a Standard-P generated-config identity change (the
-- consequence Sprint 0.29 had to record). The narrowing happens one ring in, at
-- the single Haskell validation, which is the seam Sprint 1.83 established.
module Prodbox.Settings.Coordinate
  ( -- * Errors
    CoordinateError (..)
  , renderCoordinateError

    -- * AWS coordinates
  , AwsRegion
  , awsRegionText
  , mkAwsRegion
  , Route53ZoneId
  , route53ZoneIdText
  , mkRoute53ZoneId
  , S3BucketName
  , s3BucketNameText
  , mkS3BucketName

    -- * DNS coordinates
  , DnsLabel
  , dnsLabelText
  , mkDnsLabel
  , DnsTtl
  , dnsTtlSeconds
  , mkDnsTtl
  , IpLiteral
  , ipLiteralText
  , mkIpLiteral

    -- * ACME coordinates
  , EmailAddress
  , emailAddressText
  , mkEmailAddress
  , AcmeDirectoryUrl
  , acmeDirectoryUrlText
  , mkAcmeDirectoryUrl

    -- * Path coordinates
  , SafeRelativePath
  , safeRelativePathText
  , mkSafeRelativePath

    -- * Optional-field helpers
  , normalizeCoordinateText
  , traverseOptionalCoordinate
  )
where

import Data.Char qualified as Char
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)

-- | Why a coordinate was refused.
--
-- The constructors carry the offending value but never the field name: the
-- field name belongs to the call site, which knows it, and threading it through
-- the algebra is what produced the duplicated @fieldName ++ " must ..."@ strings
-- this module replaces. 'renderCoordinateError' produces the predicate half and
-- the caller prefixes its field.
data CoordinateError
  = CoordinateEmpty
  | NotAnAwsRegion !Text
  | NotARoute53ZoneId !Text
  | NotAnS3BucketName !Text
  | NotADnsLabel !Text
  | NotAnIpLiteral !Text
  | NotAnEmailAddress !Text
  | NotAnAcmeDirectoryUrl !Text
  | TtlBelowMinimum !Natural
  | TtlAboveMaximum !Natural
  | PathIsAbsolute !Text
  | PathEscapesRoot !Text
  deriving (Eq, Show)

renderCoordinateError :: CoordinateError -> String
renderCoordinateError err = case err of
  CoordinateEmpty -> "must not be empty"
  NotAnAwsRegion _ ->
    "must be a valid AWS region (two-letter geography, location, and non-zero ordinal)"
  NotARoute53ZoneId _ ->
    "must look like a Route 53 hosted-zone id (for example Z1234)"
  NotAnS3BucketName _ -> "must be a valid S3 bucket name"
  NotADnsLabel _ -> "must be a single DNS label"
  NotAnIpLiteral _ -> "must be a valid IP address when set"
  NotAnEmailAddress _ ->
    "must be an email address (a local part, one @, and a domain)"
  NotAnAcmeDirectoryUrl _ ->
    "must be an https ACME directory URL (for example https://acme.zerossl.com/v2/DV90)"
  TtlBelowMinimum _ -> "must be between 30 and 86400"
  TtlAboveMaximum _ -> "must be between 30 and 86400"
  PathIsAbsolute _ -> "must be a relative path, not absolute"
  PathEscapesRoot _ -> "must not contain a `..` segment"

-- | An AWS region name with geography, location, and non-zero ordinal segments.
--
-- Deliberately a /shape/ rule and not an allowlist of today's regions. AWS adds
-- regions; a repository-pinned list would refuse a legitimate config the day
-- after it shipped, which is a worse failure than the typo it catches. The
-- shape — a lowercase geography, one or more lowercase words, and a trailing
-- ordinal — has been stable across every region AWS has ever launched.
newtype AwsRegion = AwsRegion Text
  deriving (Eq, Ord, Show)

awsRegionText :: AwsRegion -> Text
awsRegionText (AwsRegion value) = value

mkAwsRegion :: Text -> Either CoordinateError AwsRegion
mkAwsRegion raw
  | Text.null value = Left CoordinateEmpty
  | isWellFormed = Right (AwsRegion value)
  | otherwise = Left (NotAnAwsRegion value)
 where
  value = Text.strip raw
  segments = Text.splitOn "-" value
  isWellFormed = case segments of
    (geography : rest@(_ : _)) ->
      isLowerAlphaOfLength 2 4 geography
        && all isLowerAlpha (init rest)
        && isOrdinal (last rest)
    _ -> False
  isOrdinal segment =
    not (Text.null segment) && Text.all Char.isDigit segment && Text.length segment <= 2
  isLowerAlpha segment =
    not (Text.null segment) && Text.all Char.isAsciiLower segment
  isLowerAlphaOfLength lo hi segment =
    isLowerAlpha segment && Text.length segment >= lo && Text.length segment <= hi

-- | A Route 53 hosted-zone id: @Z@ followed by uppercase alphanumerics.
--
-- The rule is character-for-character the one
-- @Prodbox.Settings.validateOptionalHostedZoneIdField@ already applied to
-- @aws_substrate.hosted_zone_id@. Reusing it rather than inventing a second one
-- is the point of this type: before Sprint 1.89 the identical
-- @route53.zone_id@ was checked only for emptiness, so two fields holding the
-- same kind of value disagreed about what a valid one is.
newtype Route53ZoneId = Route53ZoneId Text
  deriving (Eq, Ord, Show)

route53ZoneIdText :: Route53ZoneId -> Text
route53ZoneIdText (Route53ZoneId value) = value

mkRoute53ZoneId :: Text -> Either CoordinateError Route53ZoneId
mkRoute53ZoneId raw
  | Text.null value = Left CoordinateEmpty
  | Text.isPrefixOf "Z" value
  , Text.length value >= 2
  , Text.all (\character -> Char.isAsciiUpper character || Char.isDigit character) value =
      Right (Route53ZoneId value)
  | otherwise = Left (NotARoute53ZoneId value)
 where
  value = Text.strip raw

-- | An S3 bucket name. The rule is the one
-- @Prodbox.Settings.validateOptionalS3BucketField@ already applied.
newtype S3BucketName = S3BucketName Text
  deriving (Eq, Ord, Show)

s3BucketNameText :: S3BucketName -> Text
s3BucketNameText (S3BucketName value) = value

mkS3BucketName :: Text -> Either CoordinateError S3BucketName
mkS3BucketName raw
  | Text.null value = Left CoordinateEmpty
  | Text.length value >= 3
  , Text.length value <= 63
  , Text.all isBucketCharacter value
  , not (Text.isPrefixOf "-" value)
  , not (Text.isSuffixOf "-" value) =
      Right (S3BucketName value)
  | otherwise = Left (NotAnS3BucketName value)
 where
  value = Text.strip raw
  isBucketCharacter character =
    Char.isAsciiLower character || Char.isDigit character || character `elem` ("-." :: String)

-- | A single DNS label — one component of a name, never a dotted name. The rule
-- is the one @Prodbox.Settings.validateOptionalDnsLabelField@ already applied.
newtype DnsLabel = DnsLabel Text
  deriving (Eq, Ord, Show)

dnsLabelText :: DnsLabel -> Text
dnsLabelText (DnsLabel value) = value

mkDnsLabel :: Text -> Either CoordinateError DnsLabel
mkDnsLabel raw
  | Text.null value = Left CoordinateEmpty
  | isValidDnsLabelText value = Right (DnsLabel value)
  | otherwise = Left (NotADnsLabel value)
 where
  value = Text.strip raw

-- | The label rule, exported through 'mkDnsLabel' only. Kept as a predicate
-- because the FQDN check in "Prodbox.Tls.CertScope" is the repository's minter
-- for dotted names and this is its single-label sibling.
isValidDnsLabelText :: Text -> Bool
isValidDnsLabelText label =
  not (Text.null label)
    && Text.length label <= 63
    && Text.all isLabelCharacter label
    && not (Text.isPrefixOf "-" label)
    && not (Text.isSuffixOf "-" label)
 where
  isLabelCharacter character =
    Char.isAsciiLower character
      || Char.isAsciiUpper character
      || Char.isDigit character
      || character == '-'

-- | A DNS record TTL in seconds, inside the bounds a public record may carry.
--
-- The bounds are the ones @Prodbox.Settings.validateDemoTtl@ already applied.
-- What changes is that the decision survives: the one production reader used to
-- @show@ the raw @Natural@ into a rendered Dhall record, so a TTL the validator
-- had already approved was re-read as an unbounded number.
newtype DnsTtl = DnsTtl Natural
  deriving (Eq, Ord, Show)

dnsTtlSeconds :: DnsTtl -> Natural
dnsTtlSeconds (DnsTtl value) = value

minimumDnsTtlSeconds :: Natural
minimumDnsTtlSeconds = 30

maximumDnsTtlSeconds :: Natural
maximumDnsTtlSeconds = 86400

mkDnsTtl :: Natural -> Either CoordinateError DnsTtl
mkDnsTtl value
  | value < minimumDnsTtlSeconds = Left (TtlBelowMinimum value)
  | value > maximumDnsTtlSeconds = Left (TtlAboveMaximum value)
  | otherwise = Right (DnsTtl value)

-- | An IPv4 or IPv6 literal. The rule is the one
-- @Prodbox.Settings.validateOptionalIpAddressField@ already applied, moved here
-- so the accepting parse produces a value.
newtype IpLiteral = IpLiteral Text
  deriving (Eq, Ord, Show)

ipLiteralText :: IpLiteral -> Text
ipLiteralText (IpLiteral value) = value

mkIpLiteral :: Text -> Either CoordinateError IpLiteral
mkIpLiteral raw
  | Text.null value = Left CoordinateEmpty
  | isValidIpv4Literal value || isValidIpv6Literal value = Right (IpLiteral value)
  | otherwise = Left (NotAnIpLiteral value)
 where
  value = Text.strip raw

isValidIpv4Literal :: Text -> Bool
isValidIpv4Literal value =
  case Text.splitOn "." value of
    [firstOctet, secondOctet, thirdOctet, fourthOctet] ->
      all isValidIpv4Octet [firstOctet, secondOctet, thirdOctet, fourthOctet]
    _ -> False

isValidIpv4Octet :: Text -> Bool
isValidIpv4Octet octet =
  not (Text.null octet)
    && Text.all Char.isDigit octet
    && case reads (Text.unpack octet) of
      [(value, "")] -> value >= (0 :: Int) && value <= 255
      _ -> False

-- | IPv6 in the compressed form MetalLB and the bootstrap override accept: at
-- most one @::@ elision, every remaining group one to four hex digits, and an
-- optional trailing IPv4 literal counting as two groups.
--
-- Character-for-character the implementation this rule had in
-- "Prodbox.Settings" before Sprint 1.89 moved it here. Reimplementing it would
-- have been a behaviour change disguised as a refactor, which is the one thing
-- a move of an accepting predicate must not be.
isValidIpv6Literal :: Text -> Bool
isValidIpv6Literal value =
  case Text.splitOn "::" value of
    [groupsText] ->
      let groups = splitIpv6Groups groupsText
       in not (null groups) && isValidIpv6GroupList groups && ipv6GroupWidth groups == 8
    [leftText, rightText] ->
      let leftGroups = splitIpv6Groups leftText
          rightGroups = splitIpv6Groups rightText
          totalWidth = ipv6GroupWidth leftGroups + ipv6GroupWidth rightGroups
       in isValidIpv6GroupList leftGroups
            && isValidIpv6GroupList rightGroups
            && totalWidth < 8
    _ -> False

splitIpv6Groups :: Text -> [Text]
splitIpv6Groups value
  | Text.null value = []
  | otherwise = Text.splitOn ":" value

isValidIpv6GroupList :: [Text] -> Bool
isValidIpv6GroupList groups =
  and (zipWith validateGroup [0 :: Int ..] groups)
 where
  lastIndex = length groups - 1
  validateGroup index group
    | Text.null group = False
    | isValidIpv4Literal group = index == lastIndex
    | otherwise = isValidIpv6Hextet group

isValidIpv6Hextet :: Text -> Bool
isValidIpv6Hextet group =
  let lengthValue = Text.length group
   in lengthValue >= 1 && lengthValue <= 4 && Text.all Char.isHexDigit group

ipv6GroupWidth :: [Text] -> Int
ipv6GroupWidth =
  sum . map (\group -> if isValidIpv4Literal group then 2 else 1)

-- | An email address, to the only depth config validation can decide: a
-- non-empty local part with no whitespace, exactly one @\@@, and a domain that
-- is a dotted multi-label name.
--
-- Deliberately not RFC 5322. The addresses this field carries are ACME account
-- contacts; the failure this rule exists to catch is a missing @\@@ or a bare
-- hostname, not an exotic quoted local part. A rule that tried to be complete
-- would be wrong in the direction that refuses valid config.
newtype EmailAddress = EmailAddress Text
  deriving (Eq, Ord, Show)

emailAddressText :: EmailAddress -> Text
emailAddressText (EmailAddress value) = value

mkEmailAddress :: Text -> Either CoordinateError EmailAddress
mkEmailAddress raw
  | Text.null value = Left CoordinateEmpty
  | isWellFormed = Right (EmailAddress value)
  | otherwise = Left (NotAnEmailAddress value)
 where
  value = Text.strip raw
  isWellFormed = case Text.splitOn "@" value of
    [localPart, domainPart] ->
      not (Text.null localPart)
        && not (Text.any Char.isSpace localPart)
        && isDottedName domainPart
    _ -> False

-- | An https ACME directory URL.
--
-- The scheme is required to be @https@ rather than merely present: an ACME
-- account key is exchanged over this URL, and a plaintext directory endpoint is
-- a configuration mistake with no legitimate use on a supported path.
newtype AcmeDirectoryUrl = AcmeDirectoryUrl Text
  deriving (Eq, Ord, Show)

acmeDirectoryUrlText :: AcmeDirectoryUrl -> Text
acmeDirectoryUrlText (AcmeDirectoryUrl value) = value

mkAcmeDirectoryUrl :: Text -> Either CoordinateError AcmeDirectoryUrl
mkAcmeDirectoryUrl raw
  | Text.null value = Left CoordinateEmpty
  | otherwise = case Text.stripPrefix "https://" value of
      Nothing -> Left (NotAnAcmeDirectoryUrl value)
      Just remainder
        | isDottedName (Text.takeWhile (\character -> character /= '/') remainder) ->
            Right (AcmeDirectoryUrl value)
        | otherwise -> Left (NotAnAcmeDirectoryUrl value)
 where
  value = Text.strip raw

-- | A dotted name of at least two valid labels. Shared by the email domain and
-- the ACME URL authority; both want "looks like a hostname" and neither wants
-- the certificate algebra's lowercasing, which would change the value it
-- returns.
isDottedName :: Text -> Bool
isDottedName value =
  length labels >= 2 && all isValidDnsLabelText labels
 where
  labels = Text.splitOn "." value

-- | A path that may be joined onto a trusted root without leaving it. The rule
-- is the one @Prodbox.Settings.validateSafeRelativePath@ already applied.
newtype SafeRelativePath = SafeRelativePath Text
  deriving (Eq, Ord, Show)

safeRelativePathText :: SafeRelativePath -> Text
safeRelativePathText (SafeRelativePath value) = value

mkSafeRelativePath :: Text -> Either CoordinateError SafeRelativePath
mkSafeRelativePath raw
  | Text.null value = Left CoordinateEmpty
  | Text.isPrefixOf "/" value = Left (PathIsAbsolute value)
  | ".." `elem` Text.splitOn "/" value = Left (PathEscapesRoot value)
  | otherwise = Right (SafeRelativePath value)
 where
  value = Text.strip raw

-- | @Nothing@ for a field whose value is blank.
--
-- Blank is the correct state for most Tier-0 coordinates — a home-only host has
-- no SES identity, no AWS subzone, and no long-lived state backend — so
-- "absent" and "malformed" must stay distinguishable. This is the function that
-- keeps them apart, and 'traverseOptionalCoordinate' is the only way the
-- optional ones are built.
normalizeCoordinateText :: Text -> Maybe Text
normalizeCoordinateText value =
  if Text.null (Text.strip value) then Nothing else Just value

-- | Build an optional coordinate: absent stays absent, present must parse.
traverseOptionalCoordinate
  :: (Text -> Either CoordinateError coordinate)
  -> Maybe Text
  -> Either CoordinateError (Maybe coordinate)
traverseOptionalCoordinate _ Nothing = Right Nothing
traverseOptionalCoordinate build (Just value) = Just <$> build value
