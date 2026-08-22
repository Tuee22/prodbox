{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownCascadeTerminalAuditAdapter
  ( lifecycleTeardownCascadeTerminalAuditAdapterSuite
  )
where

import Data.Functor.Identity (Identity (Identity), runIdentity)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
  ( CascadeTerminalAuditReceipt
  , CascadeTerminalAuditVerdict (..)
  , ProviderAdmissionEpochError
  , cascadeTerminalAuditReceiptScopeDigest
  , cascadeTerminalAuditReceiptVerdict
  )
import Prodbox.Lifecycle.AwsInventory
  ( AwsInventory
  , AwsResourceCoordinate (AwsResourceCoordinate)
  , AwsResourceType (AwsResourceType)
  , AwsTag (AwsTag)
  , AwsTagRow (..)
  , normalizeAwsTagRows
  )
import Prodbox.Lifecycle.OwnedResourceTagEvidence
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderIntentCoordinate
  , ProviderOwnedTagQuery (..)
  , providerIntentCoordinate
  , providerOwnedTagQueryKey
  )
import Prodbox.Lifecycle.TaggedResourceQuery
  ( TaggedResourceEntry (..)
  , TaggedResourceFilter (..)
  , TaggedResourcePage (..)
  , parseTaggedResourcePage
  , taggedResourceQueryArgs
  )
import Prodbox.Lifecycle.Teardown.CascadeTerminalAudit
  ( CascadeTerminalAuditBoundary (..)
  , lowerCascadeTerminalAuditRows
  )
import Prodbox.Lifecycle.Teardown.CascadeTerminalAuditAdapter
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (AwsAccountId)
  , AwsRegion (AwsRegion)
  , AwsScope (..)
  , CleanupSurface (Cascade)
  , CleanupSurfaceWitness (CascadeSurface)
  , DurableObservationRunScope (DurableObservationRunScope)
  , LifecycleOperation (RunTerminalEscapeAudit)
  , LinuxRke2FoundationId (LinuxRke2FoundationId)
  , ObservationEvidenceScope
  , ObservationFailure (ObservationFailure)
  , ObservationRevision (ObservationRevision)
  , mkObservationEvidenceScope
  )
import Prodbox.Lifecycle.Teardown.Observation
  ( TerminalAuditObservation (..)
  , TerminalAuditQueryDigest
  , TerminalAuditResult (..)
  , TerminalAuditRetainedSetDigest
  , TerminalAuditScope
  , mkTerminalAuditScope
  , terminalAuditEvidenceScopeDigest
  )
import Prodbox.Lifecycle.Teardown.Registry (lifecycleRegistryRevision)
import Prodbox.Lifecycle.Teardown.RetainedInventory
  ( RetainedCatalog
  , RetainedNameBinding
  , TerminalAuditQuery (..)
  , mkRetainedNameBinding
  , retainedCatalogFor
  , retainedSetDigestFor
  , terminalAuditQueryCatalog
  , terminalAuditQueryDigestFor
  , terminalAuditResultFor
  )
import TestSupport

lifecycleTeardownCascadeTerminalAuditAdapterSuite :: SuiteBuilder ()
lifecycleTeardownCascadeTerminalAuditAdapterSuite =
  describe "Sprint 7.36 terminal cascade audit execution half" $ do
    it "executes each catalog query as its own registered Provider intent" $ do
      -- The Tagging API intersects filters inside one call, so the audit's
      -- field of view is a union of separately issued single-filter queries.
      -- One intent per query is what keeps that true at the provider boundary.
      terminalAuditQueryProviderIntent (AuditQueryTagKey "prodbox.io/managed-by")
        `shouldBe` ObserveOwnedResourceTags
          (ProviderOwnedTagKeyQuery "prodbox.io/managed-by")
      terminalAuditQueryProviderIntent
        (AuditQueryTagPair "prodbox.io/managed-by" "prodbox")
        `shouldBe` ObserveOwnedResourceTags
          (ProviderOwnedTagPairQuery "prodbox.io/managed-by" "prodbox")

    it "keeps a key query and a pair query at distinct provider coordinates" $ do
      -- A key query asks about a whole family and a pair query about one value.
      -- Sharing a coordinate would let one answer the other, which is how a
      -- narrower listing gets read as the wider family's absence.
      coordinateOf (AuditQueryTagKey "prodbox.io/managed-by")
        `shouldNotBe` coordinateOf
          (AuditQueryTagPair "prodbox.io/managed-by" "prodbox")
      providerOwnedTagQueryKey
        (ProviderOwnedTagPairQuery "prodbox.io/managed-by" "prodbox")
        `shouldBe` "prodbox.io/managed-by=prodbox"

    it "round-trips a complete listing, tagless resources included" $ do
      parseOwnedResourceTagObservation (mustRight (render listing))
        `shouldBe` Right listing

    it "refuses evidence that never stated its completion" $ do
      -- A paginated listing that stopped early looks exactly like a short one.
      -- The terminator is what separates them, so evidence without it is not an
      -- answer -- and specifically never an empty family.
      parseOwnedResourceTagObservation truncatedEvidence
        `shouldBe` Left OwnedResourceTagEvidenceIncomplete
      decodeTerminalAuditQueryObservation
        auditedScope
        managedByQuery
        (observed managedByQuery truncatedEvidence)
        `shouldSatisfy` isLeftResult

    it "never lowers an unanswerable query to an empty answer" $ do
      -- Four distinct inabilities, one shape of outcome: the query went
      -- unanswered. The kernel counts that as a blind spot and downgrades a
      -- would-be-clean verdict; none of them may produce rows.
      decodeTerminalAuditQueryObservation
        auditedScope
        managedByQuery
        (Left "resourcegroupstaggingapi was refused")
        `shouldSatisfy` isLeftResult
      decodeTerminalAuditQueryObservation
        auditedScope
        managedByQuery
        ( Right
            ( ProviderIntentExecutionObserved
                (coordinateOf (AuditQueryTagKey "kubernetes.io/cluster/other"))
                (mustRight (render listing))
            )
        )
        `shouldSatisfy` isLeftResult
      decodeTerminalAuditQueryObservation
        auditedScope
        managedByQuery
        ( Right
            ( ProviderIntentExecutionApplied
                (coordinateOf managedByQuery)
                (mustRight (render listing))
            )
        )
        `shouldSatisfy` isLeftResult
      decodeTerminalAuditQueryObservation
        auditedScope
        managedByQuery
        (observed managedByQuery "not evidence at all")
        `shouldSatisfy` isLeftResult

    it "refuses an answer to a different question" $ do
      -- The evidence echoes the query it answered. Without the echo, a listing
      -- for one tag family would classify as the audit's answer for another.
      decodeTerminalAuditQueryObservation
        auditedScope
        managedByQuery
        ( observed
            managedByQuery
            ( mustRight
                (render listing {ownedResourceTagObservationQuery = otherEcho})
            )
        )
        `shouldSatisfy` isLeftResult

    it "derives resource type and coordinate from the ARN" $ do
      -- A family matcher pins the resource type, so this rendering is what lets
      -- a retained volume be recognised as one.
      identityOf "arn:aws:ec2:us-east-1:111122223333:volume/vol-0123abcd"
        `shouldBe` Right (AwsResourceType "ec2:volume", AwsResourceCoordinate "vol-0123abcd")
      identityOf "arn:aws:s3:::prodbox-fixed-state"
        `shouldBe` Right (AwsResourceType "s3:bucket", AwsResourceCoordinate "prodbox-fixed-state")
      identityOf "arn:aws:eks:us-east-1:111122223333:cluster/prodbox-escapee"
        `shouldBe` Right (AwsResourceType "eks:cluster", AwsResourceCoordinate "prodbox-escapee")

    it "refuses a row from outside the audited account or region" $ do
      -- The retained matchers are built from the audited scope. A row from
      -- another account or region would be classified against a catalog that
      -- does not describe it, in either direction.
      identityOf "arn:aws:ec2:us-east-1:999988887777:volume/vol-0123abcd"
        `shouldSatisfy` isLeftResult
      identityOf "arn:aws:ec2:eu-west-1:111122223333:volume/vol-0123abcd"
        `shouldSatisfy` isLeftResult
      -- A global service carries no region and stays admissible.
      identityOf "arn:aws:iam::111122223333:user/prodbox-operational"
        `shouldSatisfy` isRightResult

    it "produces one row per tag and one tagless row for an untagged resource" $ do
      fmap (map awsTagRowTag) (rowsFor taggedBucket)
        `shouldBe` Right [Just managedByTag, Just roleTag]
      fmap (map awsTagRowTag) (rowsFor untaggedVolume) `shouldBe` Right [Nothing]
      fmap (map awsTagRowScope) (rowsFor taggedBucket)
        `shouldBe` Right [auditedScope, auditedScope]

    it "carries provider bytes through to a verdict" $ do
      -- End to end over the wire the Provider actually returns: the retained
      -- state bucket is retained by design, and a prodbox-tagged resource no
      -- matcher claims fails the audit.
      fmap isClean (verdictFor [retainedBucketEntry]) `shouldBe` Right True
      fmap isEscape (verdictFor [retainedBucketEntry, escapeeEntry])
        `shouldBe` Right True

    it "issues exactly one tag filter per call and paginates by cursor" $ do
      length (filter ("--tag-filters" ==) (taggedResourceQueryArgs keyFilter Nothing))
        `shouldBe` 1
      taggedResourceQueryArgs keyFilter Nothing
        `shouldNotContain` ["--pagination-token"]
      taggedResourceQueryArgs keyFilter (Just "cursor")
        `shouldContain` ["--pagination-token", "cursor"]
      taggedResourceQueryArgs
        (TaggedResourceTagPairFilter "prodbox.io/managed-by" "prodbox")
        Nothing
        `shouldContain` ["Key=prodbox.io/managed-by,Values=prodbox"]

    it "reads a page's cursor and refuses a body it cannot read" $ do
      fmap taggedResourcePageNextToken (parseTaggedResourcePage pageWithCursor)
        `shouldBe` Right (Just "next-page")
      -- An empty-string token is the API's way of saying there is no next page.
      fmap taggedResourcePageNextToken (parseTaggedResourcePage pageWithEmptyCursor)
        `shouldBe` Right Nothing
      fmap taggedResourcePageEntries (parseTaggedResourcePage pageWithCursor)
        `shouldBe` Right
          [ TaggedResourceEntry
              "arn:aws:s3:::prodbox-fixed-state"
              [("prodbox.io/managed-by", "prodbox")]
          ]
      -- An entry with no readable ARN makes the whole page unreadable: dropping
      -- it would shorten the listing in the direction that reads residue as
      -- absence.
      parseTaggedResourcePage pageWithUnreadableEntry `shouldSatisfy` isLeftResult
      parseTaggedResourcePage "{}" `shouldSatisfy` isLeftResult

    it "mints a durable receipt from the audit it took" $ do
      -- All three verdicts mint: a run that found an escape or could not see
      -- everything must be able to record that durably, and the record is what
      -- outlives the compactable provider operation the query ran as.
      fmap cascadeTerminalAuditReceiptVerdict (receiptFor cleanResult)
        `shouldBe` Right CascadeTerminalAuditReceiptClean
      fmap cascadeTerminalAuditReceiptVerdict (receiptFor escapeResult)
        `shouldBe` Right (CascadeTerminalAuditReceiptEscaped 1)
      fmap cascadeTerminalAuditReceiptVerdict (receiptFor unobservableResult)
        `shouldBe` Right (CascadeTerminalAuditReceiptUnobservable 1)

    it "derives the receipt's scope digest where the reservation derives it" $ do
      -- The fence is committed before the audit runs and names the scope it
      -- expects by digest; the receipt names the scope the audit was taken in
      -- the same way. Deriving both here is what makes a mismatch mean "another
      -- run" rather than "another rendering".
      fmap cascadeTerminalAuditReceiptScopeDigest (receiptFor cleanResult)
        `shouldBe` Right (terminalAuditEvidenceScopeDigest auditEvidenceScope)
      -- Every field participates, so a scope naming no AWS account cannot
      -- digest equal to one that does.
      terminalAuditEvidenceScopeDigest auditEvidenceScope
        `shouldNotBe` terminalAuditEvidenceScopeDigest awsLessEvidenceScope

    it "reaches the audit kernel as a boundary" $ do
      runIdentity
        ( auditIssueQuery
            ( providerCascadeTerminalAuditBoundary
                auditedScope
                (\_ -> Identity (Left "provider unavailable"))
            )
            managedByQuery
        )
        `shouldBe` Left
          ( ObservationFailure
              ( renderTerminalAuditAdapterError
                  (TerminalAuditEvidenceUnreadable "provider unavailable")
              )
          )

render
  :: OwnedResourceTagObservation
  -> Either OwnedResourceTagEvidenceError Text
render = renderOwnedResourceTagObservation

receiptFor
  :: TerminalAuditResult
  -> Either ProviderAdmissionEpochError CascadeTerminalAuditReceipt
receiptFor result =
  cascadeTerminalAuditReceiptFor
    TerminalAuditObservation
      { terminalAuditScope = auditScope
      , terminalAuditRevision = ObservationRevision 1
      , terminalAuditResult = result
      }

auditScope :: TerminalAuditScope 'Cascade
auditScope =
  mustRight
    (mkTerminalAuditScope CascadeSurface auditEvidenceScope catalogQueryDigest catalogRetainedDigest)

auditEvidenceScope :: ObservationEvidenceScope
auditEvidenceScope =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope "terminal-audit-adapter-run")
    (LinuxRke2FoundationId "home-rke2")
    (Just auditedScope)
    RunTerminalEscapeAudit

-- | The same run with no AWS scope at all, which must not digest equal.
awsLessEvidenceScope :: ObservationEvidenceScope
awsLessEvidenceScope =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope "terminal-audit-adapter-run")
    (LinuxRke2FoundationId "home-rke2")
    Nothing
    RunTerminalEscapeAudit

catalogQueryDigest :: TerminalAuditQueryDigest
catalogQueryDigest =
  terminalAuditQueryDigestFor (terminalAuditQueryCatalog binding)

catalogRetainedDigest :: TerminalAuditRetainedSetDigest
catalogRetainedDigest = retainedSetDigestFor catalog

cleanResult :: TerminalAuditResult
cleanResult = terminalAuditResultFor catalog emptyInventory

escapeResult :: TerminalAuditResult
escapeResult =
  terminalAuditResultFor
    catalog
    (mustRight (normalizeAwsTagRows (mustRight (rowsFor escapeeEntry))))

unobservableResult :: TerminalAuditResult
unobservableResult =
  TerminalAuditUnobservable
    emptyInventory
    (ObservationFailure "one query went unanswered" :| [])

emptyInventory :: AwsInventory
emptyInventory = mustRight (normalizeAwsTagRows [])

coordinateOf :: TerminalAuditQuery -> ProviderIntentCoordinate
coordinateOf = providerIntentCoordinate . terminalAuditQueryProviderIntent

observed
  :: TerminalAuditQuery -> Text -> Either Text ProviderIntentExecutionResult
observed query evidence =
  Right (ProviderIntentExecutionObserved (coordinateOf query) evidence)

managedByQuery :: TerminalAuditQuery
managedByQuery = AuditQueryTagKey "prodbox.io/managed-by"

otherEcho :: OwnedResourceTagQueryEcho
otherEcho = OwnedResourceTagKeyEcho "kubernetes.io/cluster/other"

pageWithCursor :: String
pageWithCursor =
  "{\"ResourceTagMappingList\":[{\"ResourceARN\":\"arn:aws:s3:::prodbox-fixed-state\",\
  \\"Tags\":[{\"Key\":\"prodbox.io/managed-by\",\"Value\":\"prodbox\"}]}],\
  \\"PaginationToken\":\"next-page\"}"

pageWithEmptyCursor :: String
pageWithEmptyCursor =
  "{\"ResourceTagMappingList\":[],\"PaginationToken\":\"\"}"

pageWithUnreadableEntry :: String
pageWithUnreadableEntry =
  "{\"ResourceTagMappingList\":[{\"Tags\":[]}],\"PaginationToken\":\"\"}"

keyFilter :: TaggedResourceFilter
keyFilter = TaggedResourceTagKeyFilter "prodbox.io/managed-by"

listing :: OwnedResourceTagObservation
listing =
  OwnedResourceTagObservation
    { ownedResourceTagObservationQuery =
        OwnedResourceTagKeyEcho "prodbox.io/managed-by"
    , ownedResourceTagObservationEntries = [taggedBucket, untaggedVolume]
    , ownedResourceTagObservationPages = 3
    }

taggedBucket :: OwnedResourceTagEntry
taggedBucket =
  OwnedResourceTagEntry
    { ownedResourceTagEntryArn = "arn:aws:s3:::prodbox-fixed-state"
    , ownedResourceTagEntryTags =
        [ ("prodbox.io/managed-by", "prodbox")
        , ("prodbox.io/role", "pulumi-state")
        ]
    }

untaggedVolume :: OwnedResourceTagEntry
untaggedVolume =
  OwnedResourceTagEntry
    { ownedResourceTagEntryArn =
        "arn:aws:ec2:us-east-1:111122223333:volume/vol-0123abcd"
    , ownedResourceTagEntryTags = []
    }

truncatedEvidence :: Text
truncatedEvidence =
  Text.intercalate
    "\n"
    [ "query\tkey\tprodbox.io/managed-by"
    , "resource\tarn:aws:s3:::prodbox-fixed-state\tprodbox.io/managed-by\tprodbox"
    ]

rowsFor :: OwnedResourceTagEntry -> Either TerminalAuditAdapterError [AwsTagRow]
rowsFor = awsTagRowsFromOwnedResourceTagEntry auditedScope

identityOf
  :: Text
  -> Either TerminalAuditAdapterError (AwsResourceType, AwsResourceCoordinate)
identityOf raw =
  fmap
    (\(_, resourceType, coordinate) -> (resourceType, coordinate))
    (awsResourceIdentityFromArn auditedScope raw)

managedByTag :: AwsTag
managedByTag = AwsTag "prodbox.io/managed-by" "prodbox"

roleTag :: AwsTag
roleTag = AwsTag "prodbox.io/role" "pulumi-state"

-- | The audited scope every fixture row is returned in.  It is the global
-- tagging region because a cascade audit taken anywhere else can never report
-- clean, and these cases are about the rows rather than about that bound.
auditedScope :: AwsScope
auditedScope =
  AwsScope
    { awsScopeAccountId = AwsAccountId "111122223333"
    , awsScopeRegion = AwsRegion "us-east-1"
    }

stateBucketName :: Text
stateBucketName = "prodbox-fixed-state"

binding :: RetainedNameBinding
binding =
  mustRight
    ( mkRetainedNameBinding
        stateBucketName
        "prodbox-fixed-ses-capture"
        "fixed.example.test"
        "aws-eks-test-cluster"
    )

catalog :: RetainedCatalog 'Cascade
catalog = mustRight (retainedCatalogFor CascadeSurface auditedScope binding)

retainedBucketEntry :: OwnedResourceTagEntry
retainedBucketEntry =
  OwnedResourceTagEntry
    { ownedResourceTagEntryArn = "arn:aws:s3:::" <> stateBucketName
    , ownedResourceTagEntryTags = [("prodbox.io/managed-by", "prodbox")]
    }

escapeeEntry :: OwnedResourceTagEntry
escapeeEntry =
  OwnedResourceTagEntry
    { ownedResourceTagEntryArn =
        "arn:aws:eks:us-east-1:111122223333:cluster/prodbox-escapee"
    , ownedResourceTagEntryTags = [("prodbox.io/managed-by", "prodbox")]
    }

verdictFor :: [OwnedResourceTagEntry] -> Either Text TerminalAuditResult
verdictFor entries = do
  evidence <-
    either
      (Left . renderOwnedResourceTagEvidenceError)
      Right
      ( render
          listing
            { ownedResourceTagObservationEntries = entries
            , ownedResourceTagObservationPages = 1
            }
      )
  rows <-
    either
      (\(ObservationFailure detail) -> Left detail)
      Right
      ( decodeTerminalAuditQueryObservation
          auditedScope
          managedByQuery
          (observed managedByQuery evidence)
      )
  either (Left . Text.pack . show) Right (lowerCascadeTerminalAuditRows catalog rows [])

isClean :: TerminalAuditResult -> Bool
isClean result = case result of
  TerminalAuditConfirmedClean _ -> True
  _ -> False

isEscape :: TerminalAuditResult -> Bool
isEscape result = case result of
  TerminalAuditFoundEscapes _ _ -> True
  _ -> False

isLeftResult :: Either left right -> Bool
isLeftResult result = case result of
  Left _ -> True
  Right _ -> False

isRightResult :: Either left right -> Bool
isRightResult result = case result of
  Right _ -> True
  Left _ -> False

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error ("expected Right, got " <> show err)
