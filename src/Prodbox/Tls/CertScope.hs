{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 2.35: the pure certificate-scope algebra.
--
-- The orphan dashboard-certificate incident happened because the served-hostname
-- set, the certificate @dnsNames@, and the retention key were three
-- hand-authored lists that could silently disagree. This module makes the
-- prodbox-managed certificate scope ONE operator-configured value from which
-- every projection (served FQDNs, listener bindings, certificate @dnsNames@, the
-- retention key) is derived, and makes the two illegal states unrepresentable:
--
--   * a wildcard scope anchored at a zone the operator has not delegated in
--     Tier-0 config ('mkScopeSet' rejects it), and
--   * a served hostname with no covering configured scope ('bindListener'
--     rejects it).
--
-- Everything here is pure and total. The wildcard semantics are deliberately
-- strict: @*.z@ covers exactly the single-label children of @z@ — never the apex
-- @z@ itself and never a deeper name @a.b.z@ — so apex coverage always requires
-- an explicit 'ScopeExact'. The narrower-or-equal partial order 'impliedBy'
-- drives restore-vs-reissue: a configured scope set that is 'impliedBy' the
-- retained certificate's scope reuses the retained material; widening beyond it
-- orders exactly one fresh ACME certificate.
module Prodbox.Tls.CertScope
  ( -- * Smart-constructed names
    Fqdn
  , fqdnText
  , mkFqdn
  , DelegatedZone
  , delegatedZoneText
  , mkDelegatedZone

    -- * Scopes and scope sets
  , CertScope (..)
  , CertScopeSet
  , certScopeSetScopes
  , mkScopeSet
  , ScopeError (..)
  , renderScopeError

    -- * Total coverage and the narrower-or-equal order
  , covers
  , scopeSetCovers
  , scopeImpliedBy
  , impliedBy
  , bindListener

    -- * Derived projections (the one set, many views)
  , certScopeDnsName
  , certScopeSetDnsNames
  , renderCertScopeSet
  )
where

import Data.Char (isAsciiLower, isDigit)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text

-- | A fully-qualified domain name: lowercased, at least two labels, every label
-- a non-empty LDH (letter/digit/hyphen) label with no leading or trailing
-- hyphen, and no wildcard. Built only through 'mkFqdn'.
newtype Fqdn = Fqdn Text
  deriving (Eq, Ord, Show)

fqdnText :: Fqdn -> Text
fqdnText (Fqdn value) = value

-- | A DNS zone the operator has delegated (the home parent zone or
-- @aws_substrate.subzone_name@). A wildcard scope may only be anchored at a
-- declared 'DelegatedZone'; this is what keeps the Public Suffix List out of the
-- algebra — delegation is config-declared, not guessed. Built only through
-- 'mkDelegatedZone'.
newtype DelegatedZone = DelegatedZone Text
  deriving (Eq, Ord, Show)

delegatedZoneText :: DelegatedZone -> Text
delegatedZoneText (DelegatedZone value) = value

-- | A single certificate scope: an exact host, or a single-label wildcard
-- anchored at a delegated zone.
data CertScope
  = ScopeExact !Fqdn
  | ScopeWildcard !DelegatedZone
  deriving (Eq, Ord, Show)

-- | A canonical (deduped, ordered) set of scopes. The invariant — every wildcard
-- is anchored at a declared delegated zone — is established by 'mkScopeSet' and
-- preserved because the constructor is not exported.
newtype CertScopeSet = CertScopeSet [CertScope]
  deriving (Eq, Ord, Show)

certScopeSetScopes :: CertScopeSet -> [CertScope]
certScopeSetScopes (CertScopeSet scopes) = scopes

data ScopeError
  = EmptyName
  | NameHasWildcard !Text
  | NameTooFewLabels !Text
  | InvalidLabel !Text !Text
  | WildcardZoneNotDelegated !Text
  | HostNotCovered !Text
  deriving (Eq, Show)

renderScopeError :: ScopeError -> String
renderScopeError err = case err of
  EmptyName -> "certificate scope name is empty"
  NameHasWildcard value ->
    "certificate scope name contains a wildcard where a plain name is required: "
      ++ Text.unpack value
  NameTooFewLabels value ->
    "certificate scope name must have at least two labels: " ++ Text.unpack value
  InvalidLabel value label ->
    "certificate scope name "
      ++ Text.unpack value
      ++ " has an invalid DNS label: "
      ++ Text.unpack label
  WildcardZoneNotDelegated zone ->
    "wildcard certificate scope is anchored at a zone not delegated in Tier-0 config: *."
      ++ Text.unpack zone
  HostNotCovered host ->
    "served hostname is not covered by the configured certificate scope set: "
      ++ Text.unpack host

-- | Validate a plain (non-wildcard) domain name into an 'Fqdn'.
mkFqdn :: Text -> Either ScopeError Fqdn
mkFqdn raw =
  let value = Text.toLower (Text.strip raw)
   in if Text.null value
        then Left EmptyName
        else
          if "*" `Text.isInfixOf` value
            then Left (NameHasWildcard value)
            else
              let labels = Text.splitOn "." value
               in if length labels < 2
                    then Left (NameTooFewLabels value)
                    else case filter (not . isValidLabel) labels of
                      (bad : _) -> Left (InvalidLabel value bad)
                      [] -> Right (Fqdn value)

-- | Validate a delegated zone name. A zone is a plain multi-label name, exactly
-- like an 'Fqdn'; the distinct type is what stops a wildcard being anchored at an
-- arbitrary host rather than a declared zone.
mkDelegatedZone :: Text -> Either ScopeError DelegatedZone
mkDelegatedZone raw = DelegatedZone . fqdnText <$> mkFqdn raw

isValidLabel :: Text -> Bool
isValidLabel label =
  not (Text.null label)
    && Text.all isLdh label
    && Text.head label /= '-'
    && Text.last label /= '-'
 where
  -- The name is already lowercased by 'mkFqdn' before labels are checked.
  isLdh c = isAsciiLower c || isDigit c || c == '-'

-- | Build a canonical scope set, rejecting any wildcard anchored at a zone that
-- is not in the declared delegated-zone list. The result is deduped, sorted, and
-- reduced (a scope subsumed by a wider sibling is dropped), so it is the unique
-- minimal representation of its coverage — two scope sets with the same coverage
-- are structurally equal, which 'renderCertScopeSet' relies on for a stable
-- retention key and which makes 'impliedBy' a genuine partial order.
mkScopeSet :: [DelegatedZone] -> [CertScope] -> Either ScopeError CertScopeSet
mkScopeSet delegated scopes =
  case filter undelegatedWildcard scopes of
    (ScopeWildcard zone : _) -> Left (WildcardZoneNotDelegated (delegatedZoneText zone))
    -- Set.toAscList . Set.fromList canonicalizes (dedup + sort); reduceScopes then
    -- removes any scope made redundant by a wider sibling, giving the unique
    -- minimal representation of the coverage.
    _ -> Right (CertScopeSet (reduceScopes (Set.toAscList (Set.fromList scopes))))
 where
  undelegatedWildcard (ScopeWildcard zone) = zone `notElem` delegated
  undelegatedWildcard (ScopeExact _) = False

-- | Drop scopes made redundant by a strictly-wider scope in the same set (a
-- wildcard subsumes its single-label exact children). Distinct scopes are never
-- mutually implied ('scopeImpliedBy' is antisymmetric on individual scopes), so
-- the surviving representative is unambiguous — minimality is what makes
-- 'impliedBy' a genuine partial order on canonical sets.
reduceScopes :: [CertScope] -> [CertScope]
reduceScopes scopes =
  [ scope
  | scope <- scopes
  , not (any (\other -> other /= scope && scopeImpliedBy scope other) scopes)
  ]

labelsOf :: Text -> [Text]
labelsOf = Text.splitOn "."

-- | Total coverage: does this scope admit this host?
--
--   * 'ScopeExact' covers only the identical host.
--   * 'ScopeWildcard' @z@ covers exactly the single-label children of @z@: a host
--     whose labels are @[oneLabel] ++ labels z@. It never covers the apex @z@
--     (zero extra labels) nor a deeper @a.b.z@ (two or more extra labels).
covers :: CertScope -> Fqdn -> Bool
covers scope (Fqdn host) = case scope of
  ScopeExact (Fqdn exact) -> exact == host
  ScopeWildcard (DelegatedZone zone) ->
    let hostLabels = labelsOf host
        zoneLabels = labelsOf zone
     in length hostLabels == length zoneLabels + 1
          && drop 1 hostLabels == zoneLabels

scopeSetCovers :: CertScopeSet -> Fqdn -> Bool
scopeSetCovers (CertScopeSet scopes) host = any (`covers` host) scopes

-- | The scope-level narrower-or-equal relation: is every host covered by the
-- first scope also covered by the second?
--
--   * exact ⊑ exact iff equal.
--   * exact ⊑ wildcard iff the wildcard covers that exact host.
--   * wildcard ⊑ wildcard iff the zones are equal (@*.a.z@ is NOT ⊑ @*.z@,
--     because @*.z@ does not cover the deeper @x.a.z@).
--   * wildcard ⊑ exact is never true (a wildcard covers infinitely many hosts).
scopeImpliedBy :: CertScope -> CertScope -> Bool
scopeImpliedBy narrower wider = case (narrower, wider) of
  (ScopeExact host, _) -> covers wider host
  (ScopeWildcard z1, ScopeWildcard z2) -> z1 == z2
  (ScopeWildcard _, ScopeExact _) -> False

-- | The scope-set narrower-or-equal partial order: @a `impliedBy` b@ holds when
-- every scope in @a@ is implied by some scope in @b@ — i.e. every host @a@ could
-- serve, @b@ could serve too. Reflexive, transitive, and antisymmetric on
-- canonical sets. Restore-vs-reissue keys on this: reuse retained material when
-- @configured `impliedBy` retained@; widening beyond it orders once.
impliedBy :: CertScopeSet -> CertScopeSet -> Bool
impliedBy (CertScopeSet narrower) wider =
  all (\scope -> any (scopeImpliedBy scope) (certScopeSetScopes wider)) narrower

-- | Admit a served hostname iff the configured scope set covers it.
bindListener :: CertScopeSet -> Fqdn -> Either ScopeError ()
bindListener scopeSet host
  | scopeSetCovers scopeSet host = Right ()
  | otherwise = Left (HostNotCovered (fqdnText host))

-- | The @dnsNames@ entry a scope projects to: the exact host, or @*.zone@.
certScopeDnsName :: CertScope -> Text
certScopeDnsName scope = case scope of
  ScopeExact (Fqdn host) -> host
  ScopeWildcard (DelegatedZone zone) -> "*." <> zone

-- | The canonical @dnsNames@ projection of a scope set — the single source the
-- certificate templates and listener bindings both derive from.
certScopeSetDnsNames :: CertScopeSet -> [Text]
certScopeSetDnsNames (CertScopeSet scopes) = map certScopeDnsName scopes

-- | The canonical scope-set serialization used as the retention key: the sorted
-- @dnsNames@ joined by commas. Equal scope sets serialize identically regardless
-- of input order, so a narrower-or-equal reconfigure keeps the same retained
-- material.
renderCertScopeSet :: CertScopeSet -> Text
renderCertScopeSet = Text.intercalate "," . certScopeSetDnsNames
