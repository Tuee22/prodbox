{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- | How an audit crosses the wire between the Provider that took it and the
-- operator that reads it.
--
-- The evidence is the canonical provider-evidence codec over the
-- @prodbox-aws-audit@ family: forty rows at most, inside the family's own bound,
-- which is inside the shared one. A row is one of
--
-- > binding|<stack>|<account>|<region>|<field>
-- > control|seen | control|missing | control|unanswered|<reason>
-- > count|<class>|<n>          a class that holds anything, with its total
-- > row|<class>|<identity>|<detail>
-- > gap|<class>|<reason>       a class a query did not answer
--
-- The count row is always carried and the residue rows are carried as the bound
-- allows, round-robin across classes so one chatty class cannot hide another;
-- the rows of a class that are counted and not carried are its count less the
-- rows listed, so nothing needs to say so a second time. A clean field is the
-- binding and the control: nothing in it names a resource.
--
-- The @field@ cell is a digest of the classes the stack's field declares. A
-- Provider and a CLI rolled apart declare different fields, and evidence that
-- is silent about a class this build declares would read as an empty class; the
-- digest turns that skew into a refusal.
--
-- Fixed rows cannot crowd the room out: the binding, the control, and at most
-- one count and one gap for each of the seventeen classes of the widest field
-- are thirty-six rows, inside the forty the family admits.
module Prodbox.Lifecycle.AwsAuditEvidence
  ( encodeAwsAuditEvidence
  , AuditBinding (..)
  , decodeAwsAuditEvidence
  , auditFieldDigest
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as ByteString
import Data.Char (isDigit)
import Data.List (transpose)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.AwsAudit
import Prodbox.Lifecycle.ProviderWorker.Evidence
  ( ProviderEvidence
  , ProviderEvidenceBound
  , decodeProviderEvidenceText
  , encodeProviderEvidence
  , providerEvidenceFamilyBound
  , providerEvidenceText
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderNativeStackFamilyRef
  , awsAuditEvidenceFamily
  , providerNativeStackFamilyAccountId
  , providerNativeStackFamilyRegion
  , validRegionText
  )

-- | The rows the family admits.
maximumAuditRows :: Int
maximumAuditRows = 40

-- | How much of a row's identity and detail the wire carries. An identity is an
-- identifier or the resource part of an ARN, which fits; a detail is a few words.
-- A row that does not fit costs rows, never counts, so these are generous.
maximumIdentityCharacters :: Int
maximumIdentityCharacters = 64

maximumDetailCharacters :: Int
maximumDetailCharacters = 48

-- | How much of a reason the wire carries. A reason begins with the command and
-- the code AWS answered with, which are what an operator needs.
maximumReasonCharacters :: Int
maximumReasonCharacters = 64

-- | A digest of the classes a stack's field declares, in the order it declares
-- them.
auditFieldDigest :: AuditStack -> Text
auditFieldDigest stack =
  Text.pack
    ( take
        16
        ( concatMap
            hexByte
            ( ByteString.unpack
                ( SHA256.hash
                    ( TextEncoding.encodeUtf8
                        (Text.intercalate "," (map auditClassLabel (auditStackClasses stack)))
                    )
                )
            )
        )
    )
 where
  hexByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

-- | Render an audit as evidence under the bound of the intent being answered.
-- It never refuses for size: it carries fewer residue rows, the counts being
-- carried whatever the rows, until what is left fits both the intent's bound
-- and the family's own, which is the one the reader enforces.
encodeAwsAuditEvidence
  :: ProviderEvidenceBound
  -> ProviderNativeStackFamilyRef
  -> AuditObservation
  -> Either Text ProviderEvidence
encodeAwsAuditEvidence bound ref observation =
  case fitting of
    Just evidence -> Right evidence
    Nothing -> Left "the audit could not be rendered inside the evidence bound"
 where
  answers = Map.toList (auditObservationAnswers observation)
  totalOf answer = fromIntegral (length (auditAnswerRows answer)) + auditAnswerOmitted answer :: Natural
  fixedRows =
    [
      [ "binding"
      , auditStackLabel (auditObservationStack observation)
      , providerNativeStackFamilyAccountId ref
      , providerNativeStackFamilyRegion ref
      , auditFieldDigest (auditObservationStack observation)
      ]
    , controlRow (auditObservationControl observation)
    ]
      <> [ ["count", auditClassLabel class', showNatural (totalOf answer)]
         | (class', answer) <- answers
         , totalOf answer > 0
         ]
      <> [ ["gap", auditClassLabel class', Text.take maximumReasonCharacters gap]
         | (class', answer) <- answers
         , Just gap <- [auditAnswerGap answer]
         ]
  -- Residue rows in round-robin order across classes.
  candidates =
    concat
      ( transpose
          [ [ [ "row"
              , auditClassLabel class'
              , Text.take maximumIdentityCharacters (auditRowIdentity row)
              , Text.take maximumDetailCharacters (auditRowDetail row)
              ]
            | row <- auditAnswerRows answer
            ]
          | (class', answer) <- answers
          ]
      )
  render shown =
    let rows = fixedRows <> take shown candidates
     in if length rows > maximumAuditRows
          then Nothing
          else case encodeProviderEvidence bound awsAuditEvidenceFamily rows of
            Right evidence
              | Text.length (providerEvidenceText evidence) <= providerEvidenceFamilyBound awsAuditEvidenceFamily ->
                  Just evidence
            _ -> Nothing
  -- Fewer rows is a shorter text, so the most rows that fit is found by halving.
  fitting = search 0 (length candidates) Nothing
  search low high best
    | low > high = best
    | otherwise =
        let middle = (low + high) `div` 2
         in case render middle of
              Just evidence -> search (middle + 1) high (Just evidence)
              Nothing -> search low (middle - 1) best

controlRow :: AuditControl -> [Text]
controlRow control = case control of
  AuditControlSeen -> ["control", "seen"]
  AuditControlMissing -> ["control", "missing"]
  AuditControlUnanswered reason -> ["control", "unanswered", Text.take maximumReasonCharacters reason]

showNatural :: Natural -> Text
showNatural = Text.pack . show

-- | The account and the region the Provider reported it audited.
data AuditBinding = AuditBinding
  { auditBindingAccount :: !Text
  , auditBindingRegion :: !Text
  }
  deriving stock (Eq, Show)

-- | Read the evidence back into an observation and the account and region it
-- is about. It refuses what the encoder cannot have produced: evidence about
-- another stack or another field, a row this build does not know, a class
-- counted twice, a count that is not a plain natural number or is less than the
-- rows it lists, rows with no count, and a binding that is not an account and a
-- region.
decodeAwsAuditEvidence
  :: AuditStack
  -> Text
  -> Either Text (AuditBinding, AuditObservation)
decodeAwsAuditEvidence stack evidence = do
  rows <- decodeProviderEvidenceText awsAuditEvidenceFamily evidence
  mapM_ knownRow rows
  binding <- case [row | row@("binding" : _) <- rows] of
    [["binding", label, account, region, field]]
      | label /= auditStackLabel stack -> Left "the audit evidence is about another stack"
      | field /= auditFieldDigest stack ->
          Left
            "the audit evidence was taken over a different field than this build declares; roll the Provider and the CLI together"
      | Text.length account == 12 && Text.all isDigit account && validRegionText region ->
          Right (AuditBinding account region)
      | otherwise -> Left "the audit evidence binds no account and region"
    _ -> Left "the audit evidence has no single binding row"
  control <- case [row | row@("control" : _) <- rows] of
    [["control", "seen"]] -> Right AuditControlSeen
    [["control", "missing"]] -> Right AuditControlMissing
    [["control", "unanswered", reason]] -> Right (AuditControlUnanswered (sanitizeAuditText reason))
    _ -> Left "the audit evidence has no single readable control row"
  counts <- traverse countOf [row | row@("count" : _) <- rows]
  listed <- traverse rowOf [row | row@("row" : _) <- rows]
  gaps <- traverse gapOf [row | row@("gap" : _) <- rows]
  refuseRepeats "count" (map fst counts)
  refuseRepeats "gap" (map fst gaps)
  let countMap = Map.fromList counts
      gapMap = Map.fromList gaps
  mapM_ (refuseUncounted countMap) [class' | (class', _) <- listed]
  answers <-
    traverse
      (classAnswer countMap listed gapMap)
      (auditStackClasses stack)
  observation <- either (Left . Text.pack . show) Right (mkAuditObservation stack answers control)
  Right (binding, observation)
 where
  knownRow row = case row of
    tag : _
      | tag `elem` ["binding", "control", "count", "row", "gap"] -> Right ()
    _ -> Left "the audit evidence has a row this build does not know"
  countOf row = case row of
    ["count", label, n] -> do
      class' <- classOf label
      total <- naturalOf n
      if total >= 1
        then Right (class', total)
        else Left "a count row counted nothing"
    _ -> Left "a count row was malformed"
  rowOf row = case row of
    ["row", label, identity, detail] -> do
      class' <- classOf label
      Right (class', mkAuditRow class' identity detail)
    _ -> Left "a row row was malformed"
  gapOf row = case row of
    ["gap", label, reason] -> (,sanitizeAuditText reason) <$> classOf label
    _ -> Left "a gap row was malformed"
  classOf label =
    maybe
      (Left ("the audit evidence names a class this build does not know: " <> label))
      Right
      (auditClassFromLabel label)
  -- A plain natural number: digits, no sign, no padding, no base prefix.
  naturalOf n
    | not (Text.null n) && Text.all isDigit n && (n == "0" || Text.head n /= '0') =
        Right (fromInteger (read (Text.unpack n)))
    | otherwise = Left "a count was not a plain natural number"
  refuseRepeats what classes = case [class' | (class', n) <- tally classes, n > (1 :: Int)] of
    class' : _ -> Left ("the audit evidence has two " <> what <> " rows for " <> auditClassLabel class')
    [] -> Right ()
  tally classes = Map.toList (Map.fromListWith (+) [(class', 1 :: Int) | class' <- classes])
  refuseUncounted countMap class' = case Map.lookup class' countMap of
    Just _ -> Right ()
    Nothing -> Left ("the audit evidence lists " <> auditClassLabel class' <> " rows and counts none")

-- | One class's answer from the rows that name it, refusing the evidence if its
-- count is less than the rows it lists. The rows counted and not carried are
-- the difference.
classAnswer
  :: Map.Map AuditClass Natural
  -> [(AuditClass, AuditRow)]
  -> Map.Map AuditClass Text
  -> AuditClass
  -> Either Text (AuditClass, AuditAnswer)
classAnswer countMap listed gapMap class'
  | total < carried =
      Left ("the audit evidence counts fewer " <> auditClassLabel class' <> " rows than it lists")
  | otherwise =
      Right
        ( class'
        , auditWithOmitted
            left
            ( case Map.lookup class' gapMap of
                Nothing -> auditAnswered own
                Just gap -> auditPartial own gap
            )
        )
 where
  own = [row | (c, row) <- listed, c == class']
  carried = fromIntegral (length own)
  total = Map.findWithDefault carried class' countMap
  left = total - carried
