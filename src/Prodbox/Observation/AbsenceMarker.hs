{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.78: the one place that decides, from a tool's error prose, that a
-- resource is __absent__ rather than __unobserved__.
--
-- The ADT layer downstream is sound: `ResidueStatus`, `PresenceObservation`,
-- `ClusterProbe`, and their siblings nearly all give the uncertain case its own
-- constructor. The defect this module closes is one hop upstream, in the
-- @String -> Bool@ producers that decide /which constructor is minted/ — the
-- conversion class
-- [chaos_hardening_doctrine.md § 23](../../../documents/engineering/chaos_hardening_doctrine.md)
-- already names as "where this project's MISU work has actually failed".
--
-- Before this sprint eight such producers each authored their own marker list,
-- and the markers were unanchored: a bare @\"404\"@, @\"409\"@, or @\"412\"@
-- substring anywhere in a message, or the word @\"missing\"@ anywhere in a
-- lowercased one. A request id, a byte count, a timestamp, or a Vault error
-- reading @token is missing the required policy@ all satisfy those.
--
-- The shape here is __copied, not invented__:
-- 'Prodbox.Infra.AwsSesStack.classifyAwsSesPresenceOutput' has keyed anchored
-- marker sets per probe since Sprint 7.x and documents that access denial,
-- expired credentials, throttling, transport errors, and malformed responses
-- all stay unobservable. This generalises exactly that.
--
-- __The bound is stated__: matching prose is still matching prose. What changes
-- is that (a) every marker is anchored to a form the tool actually emits rather
-- than to a bare number, (b) the marker sets are keyed by probe so an S3
-- not-found vocabulary cannot answer a Kubernetes question, and (c) there is one
-- place to read them. It does not make a wrong classification unrepresentable;
-- the tools do not offer a typed channel to make it so.
module Prodbox.Observation.AbsenceMarker
  ( AbsenceProbe (..)
  , absenceProbeMarkers
  , reportsAbsence
  )
where

import Data.Char (toLower)
import Data.List (isInfixOf)

-- | The closed set of probes whose failure prose this module classifies.
--
-- Closed on purpose: a new probe is a new constructor and a compile error at
-- 'absenceProbeMarkers', which is where the decision "what does absence look
-- like for this tool" has to be made.
data AbsenceProbe
  = -- | @aws s3api get-object@ — the object is not there.
    S3ObjectProbe
  | -- | @aws s3api@ — the bucket itself is not there.
    S3BucketProbe
  | -- | An @aws s3api@ conditional put that lost its precondition. Not an
    -- absence in the resource sense; it shares this module because it is the
    -- same defect — a bare status-code substring standing in for a response.
    S3ConditionalConflictProbe
  | -- | The Pulumi state-backend bucket behind the per-run MinIO backend.
    PulumiStateBackendBucketProbe
  | -- | A key in the long-lived Pulumi state backend.
    LongLivedBackendKeyProbe
  | -- | @kubectl@ — the named object is not in the cluster.
    KubernetesObjectProbe
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The anchored markers that mean "this probe observed absence".
--
-- Every entry is lower-case and is matched case-insensitively against the
-- probe's message. Bare numerals are deliberately absent: @404@ appears in
-- request ids and byte counts, @(404)@ and @status code: 404@ do not.
absenceProbeMarkers :: AbsenceProbe -> [String]
absenceProbeMarkers probe = case probe of
  S3ObjectProbe ->
    [ "nosuchkey"
    , "nosuchbucket"
    , "(404)"
    , "status code: 404"
    ]
  S3BucketProbe ->
    [ "nosuchbucket"
    , "the specified bucket does not exist"
    , "(404)"
    , "status code: 404"
    ]
  S3ConditionalConflictProbe ->
    [ "preconditionfailed"
    , "conditionalrequestconflict"
    , "(412)"
    , "status code: 412"
    , "(409)"
    , "status code: 409"
    ]
  PulumiStateBackendBucketProbe ->
    [ "nosuchbucket"
    , "could not list bucket"
    ]
  LongLivedBackendKeyProbe ->
    [ "nosuchkey"
    , "(404)"
    , "status code: 404"
    ]
  KubernetesObjectProbe ->
    -- kubectl's absence vocabulary is `Error from server (NotFound): ...` and
    -- `... "name" not found`. The parenthesised form is anchored; the bare
    -- `notfound` spelling is not admitted, because it also appears inside
    -- unrelated identifiers and API group names.
    [ "(notfound)"
    , "not found"
    ]

-- | Does this probe's message report absence?
--
-- Total and case-insensitive. Every message that does not match is __not__
-- absence — which is the direction that matters, and the direction the eight
-- replaced predicates had backwards for unanchored numerals.
reportsAbsence :: AbsenceProbe -> String -> Bool
reportsAbsence probe rawDetail =
  any (`isInfixOf` normalized) (absenceProbeMarkers probe)
 where
  normalized = map toLower rawDetail
