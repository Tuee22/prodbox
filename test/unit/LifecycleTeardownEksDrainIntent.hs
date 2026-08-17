{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownEksDrainIntent
  ( lifecycleTeardownEksDrainIntentSuite
  )
where

import Data.ByteString qualified as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import EksClientAuthProjectionFixture (testEksClientAuthProjection)
import Prodbox.ControlPlane.EksClientAuthProjection
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.Teardown.AwsEksAdapter
import Prodbox.Lifecycle.Teardown.EksDrainIntent
import Prodbox.Lifecycle.Teardown.EksDrainSession
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownEksDrainIntentSuite :: SuiteBuilder ()
lifecycleTeardownEksDrainIntentSuite =
  describe "Sprint 7.36 exact EKS drain write-ahead intent" $ do
    it "binds the full run/graph/four-operation identity without a future attempt" $ do
      let binding = fixtureBinding fixtureScope
      eksDrainBindingScope binding `shouldBe` fixtureScope
      eksDrainBindingRunId binding `shouldBe` fixtureRunId
      eksDrainBindingGraphDigest binding `shouldBe` fixtureGraphDigest
      eksDrainBindingIntentCommitOperationId binding `shouldBe` intentCommitOperation
      eksDrainBindingIntentReadBackOperationId binding `shouldBe` intentReadBackOperation
      eksDrainBindingEffectOperationId binding `shouldBe` drainEffectOperation
      eksDrainBindingDrainReadBackOperationId binding `shouldBe` drainReadBackOperation
      mkEksDrainOperationBinding
        fixtureScope
        fixtureRunId
        fixtureGraphDigest
        intentCommitOperation
        intentReadBackOperation
        drainEffectOperation
        drainEffectOperation
        `shouldBe` Left (EksDrainOperationIdentityReused drainEffectOperation)

    it "admits exactly Cascade, ExplicitPerRun, and TotalDecommission AWS scopes" $ do
      mapM_
        (\surface -> mkBindingFor (scopeFor surface fixtureRunId) `shouldSatisfy` isRight)
        [Cascade, ExplicitPerRun, TotalDecommission]
      mapM_
        (\surface -> mkBindingFor (scopeFor surface fixtureRunId) `shouldSatisfy` isLeft)
        [LocalOnly, OperationalTeardown, ExplicitLongLived]
      mkBindingFor (scopeFor Cascade otherRunId)
        `shouldSatisfy` isRunScopeMismatch
      mkBindingFor
        ( mkObservationEvidenceScope
            Cascade
            lifecycleRegistryRevision
            (DurableObservationRunScope (cleanupRunIdText fixtureRunId))
            fixtureFoundation
            Nothing
            ReconcileDesiredAbsent
        )
        `shouldBe` Left EksDrainAwsScopeMissing

    it "projects an exact session into a complete, canonical target inventory" $ do
      let intent = fixtureKubernetesIntent
      eksDrainIntentResourceKey intent `shouldBe` AwsEksKey
      case eksDrainIntentTarget intent of
        EksDrainExactKubernetesTarget arn uid endpoint ca revision serviceClass ingressClass pvcs -> do
          arn `shouldBe` fixtureArn
          uid `shouldBe` fixtureUid
          endpoint `shouldBe` eksDrainSessionEndpointDigest fixtureSession
          ca `shouldBe` eksDrainSessionCertificateAuthorityDigest fixtureSession
          revision `shouldBe` ObservationRevision 41
          serviceClass `shouldBe` CompleteLoadBalancerServiceClass
          ingressClass `shouldBe` CompleteIngressClass
          pvcs `shouldBe` [fixturePvcA, fixturePvcB]
        target -> expectationFailure ("unexpected target arm: " <> show target)

    it "refuses partial, unobservable, duplicate, or cross-identity selections" $ do
      let make result =
            prepareEksKubernetesDrainIntent
              (fixtureBinding fixtureScope)
              fixtureSession
              (eksDrainTargetSelectionObservationFor fixtureSession (ObservationRevision 41) result)
          failure = ObservationFailure "list refused" :| []
      make (EksDrainTargetSelectionPartial [fixturePvcA] failure)
        `shouldBe` Left (EksDrainSelectionPartial failure)
      make (EksDrainTargetSelectionUnobservable failure)
        `shouldBe` Left (EksDrainSelectionUnobservable failure)
      make (EksDrainTargetSelectionComplete [fixturePvcA, fixturePvcA])
        `shouldBe` Left (EksDrainPvcTargetDuplicate fixturePvcA)
      let wrongUid =
            fixtureSelection
              { eksDrainSelectionClusterUid = "other-kubernetes-uid"
              }
      prepareEksKubernetesDrainIntent
        (fixtureBinding fixtureScope)
        fixtureSession
        wrongUid
        `shouldBe` Left
          ( EksDrainSelectionClusterUidMismatch
              fixtureUid
              "other-kubernetes-uid"
          )

    it "round-trips one bounded canonical intent without durable credential material" $ do
      let intent = fixtureKubernetesIntent
          encoded = encodeEksDrainIntent intent
          forbidden =
            [ "bearer-secret"
            , "https://example.eks.amazonaws.com"
            , "Y2EtZGF0YQ=="
            , cleanupAttemptIdText attemptA
            , cleanupAttemptIdText attemptB
            ]
      decodeEksDrainIntent encoded `shouldBe` Right intent
      Text.length (eksDrainIntentDigestText (eksDrainIntentDigest intent)) `shouldBe` 64
      ByteString.length encoded `shouldSatisfy` (<= maximumEksDrainIntentBytes)
      mapM_
        (\value -> encoded `shouldSatisfy` (not . ByteString.isInfixOf (TextEncoding.encodeUtf8 value)))
        forbidden
      show intent `shouldNotContain` "bearer-secret"
      decodeEksDrainIntent ByteString.empty `shouldBe` Left EksDrainIntentCodecEmpty
      decodeEksDrainIntent (ByteString.replicate (maximumEksDrainIntentBytes + 1) 0)
        `shouldBe` Left
          ( EksDrainIntentCodecTooLarge
              (maximumEksDrainIntentBytes + 1)
              maximumEksDrainIntentBytes
          )
      decodeEksDrainIntent (ByteString.snoc encoded 0) `shouldSatisfy` isLeft

    it "contains no source path from the opaque session to bearer or projection fields" $ do
      source <- readFile "src/Prodbox/Lifecycle/Teardown/EksDrainIntent.hs"
      mapM_
        (\forbidden -> source `shouldNotContain` forbidden)
        [ "eksClientAuthBearerToken"
        , "eksClientAuthEndpoint"
        , "eksClientAuthCertificateAuthorityData"
        , "internalEksDrainSessionProjection"
        , "withEksDrainClientProjection"
        ]

    it "requires exact persisted-byte read-back before an attempt can begin" $ do
      confirmEksDrainIntentCommitted
        fixtureKubernetesIntent
        (EksDrainIntentReadBackPresent (encodeEksDrainIntent fixtureKubernetesIntent))
        `shouldSatisfy` isRight
      confirmEksDrainIntentCommitted fixtureKubernetesIntent EksDrainIntentReadBackMissing
        `shouldBe` Left EksDrainIntentReadBackMissingRefusal
      confirmEksDrainIntentCommitted
        fixtureKubernetesIntent
        (EksDrainIntentReadBackUnobservable (ObservationFailure "store unavailable"))
        `shouldBe` Left
          ( EksDrainIntentReadBackUnobservableRefusal
              (ObservationFailure "store unavailable")
          )
      confirmEksDrainIntentCommitted
        fixtureKubernetesIntent
        (EksDrainIntentReadBackPresent (encodeEksDrainIntent alternateGraphIntent))
        `shouldBe` Left EksDrainIntentReadBackMismatch

    it "replays the stable intent under a new fenced attempt without changing its digest" $ do
      let committed = fixtureCommittedIntent
          firstAttempt = beginEksDrainAttempt committed attemptA
          recoveredAttempt = beginEksDrainAttempt committed attemptB
          firstObservation = eksDrainAttemptObservationFor firstAttempt EksDrainMutationApplied
          recoveredObservation =
            eksDrainAttemptObservationFor
              recoveredAttempt
              (EksDrainMutationUnobservable (ObservationFailure "response lost"))
          firstEvidence = mustRight (recordEksDrainAttempt firstAttempt firstObservation)
          recoveredEvidence = mustRight (recordEksDrainAttempt recoveredAttempt recoveredObservation)
      eksDrainAttemptIntentDigest firstEvidence `shouldBe` committedEksDrainIntentDigest committed
      eksDrainAttemptIntentDigest recoveredEvidence `shouldBe` committedEksDrainIntentDigest committed
      eksDrainAttemptEvidenceAttemptId firstEvidence `shouldBe` attemptA
      eksDrainAttemptEvidenceAttemptId recoveredEvidence `shouldBe` attemptB
      recordEksDrainAttempt
        firstAttempt
        firstObservation {eksDrainAttemptObservationEffectAttemptId = attemptB}
        `shouldBe` Left EksDrainAttemptBindingMismatch

    it "mints positive target evidence only from independent complete exact read-back" $ do
      let attempt = fixtureAttemptEvidence attemptA EksDrainMutationApplied
          readBack = fixtureKubernetesReadBack attempt
          evidence = mustRight (confirmEksDrainTargetsAbsent attempt readBack)
      eksDrainTargetsAbsentIntentDigest evidence `shouldBe` eksDrainAttemptIntentDigest attempt
      eksDrainTargetsAbsentScope evidence `shouldBe` fixtureScope
      eksDrainTargetsAbsentRunId evidence `shouldBe` fixtureRunId
      eksDrainTargetsAbsentGraphDigest evidence `shouldBe` fixtureGraphDigest
      eksDrainTargetsAbsentIntentCommitOperationId evidence `shouldBe` intentCommitOperation
      eksDrainTargetsAbsentIntentReadBackOperationId evidence `shouldBe` intentReadBackOperation
      eksDrainTargetsAbsentEffectOperationId evidence `shouldBe` drainEffectOperation
      eksDrainTargetsAbsentEffectAttemptId evidence `shouldBe` attemptA
      eksDrainTargetsAbsentDrainReadBackOperationId evidence `shouldBe` drainReadBackOperation
      eksDrainTargetsAbsentDisposition evidence `shouldBe` ExactKubernetesDrainTargetsAbsent

    it "refuses wrong attempts, incomplete classes, and missing or surviving PVC rows" $ do
      let attempt = fixtureAttemptEvidence attemptA EksDrainMutationApplied
          exact = fixtureKubernetesReadBack attempt
          exactResult = observedKubernetesReadBack exact
          servicePresent =
            exact
              { eksDrainTargetReadBackResult =
                  EksDrainObservedKubernetesTarget
                    exactResult
                      { eksDrainReadBackLoadBalancerServiceClass =
                          LoadBalancerServiceClassReadBack
                            (EksDrainResourceClassPresent (fixturePvcA :| []))
                      }
              }
          pvcMissing =
            exact
              { eksDrainTargetReadBackResult =
                  EksDrainObservedKubernetesTarget
                    exactResult {eksDrainReadBackDeletePolicyPvcs = [pvcAbsent fixturePvcA]}
              }
          pvcPresent =
            exact
              { eksDrainTargetReadBackResult =
                  EksDrainObservedKubernetesTarget
                    exactResult
                      { eksDrainReadBackDeletePolicyPvcs =
                          [ pvcAbsent fixturePvcA
                          , EksDrainPvcReadBack fixturePvcB EksDrainPvcPresent
                          ]
                      }
              }
      confirmEksDrainTargetsAbsent
        attempt
        exact {eksDrainTargetReadBackEffectAttemptId = attemptB}
        `shouldBe` Left EksDrainTargetReadBackBindingMismatch
      confirmEksDrainTargetsAbsent attempt servicePresent
        `shouldSatisfy` isServiceClassRefusal
      confirmEksDrainTargetsAbsent attempt pvcMissing
        `shouldBe` Left (EksDrainPvcReadBackMissing fixturePvcB)
      confirmEksDrainTargetsAbsent attempt pvcPresent
        `shouldBe` Left (EksDrainPvcNotAbsent fixturePvcB EksDrainPvcPresent)

    it "allows exact absence read-back after a failed effect attempt" $ do
      let attempt =
            fixtureAttemptEvidence
              attemptA
              (EksDrainMutationFailed (ObservationFailure "delete response failed"))
      confirmEksDrainTargetsAbsent attempt (fixtureKubernetesReadBack attempt)
        `shouldSatisfy` isRight

    it "uses an explicit no-Kubernetes-target arm for exact provider absence" $ do
      let intent = fixtureNoTargetIntent
      case eksDrainIntentTarget intent of
        EksDrainNoKubernetesTarget revision _ ->
          revision `shouldBe` ObservationRevision 13
        target -> expectationFailure ("unexpected target arm: " <> show target)
      let committed =
            mustRight
              ( confirmEksDrainIntentCommitted
                  intent
                  (EksDrainIntentReadBackPresent (encodeEksDrainIntent intent))
              )
          begun = beginEksDrainAttempt committed attemptA
          attempt =
            mustRight
              ( recordEksDrainAttempt
                  begun
                  (eksDrainAttemptObservationFor begun EksDrainSkippedNoKubernetesTarget)
              )
          readBack =
            eksDrainTargetReadBackObservationFor
              attempt
              EksDrainObservedNoKubernetesTarget
          evidence = mustRight (confirmEksDrainTargetsAbsent attempt readBack)
      eksDrainTargetsAbsentDisposition evidence
        `shouldBe` NoKubernetesDrainTargetRequired
      recordEksDrainAttempt
        begun
        (eksDrainAttemptObservationFor begun EksDrainMutationApplied)
        `shouldSatisfy` isLeft

    it "cannot turn present or unobservable provider truth into no-target intent" $ do
      prepareEksNoKubernetesTargetIntent
        (fixtureBinding fixtureScope)
        fixtureVerifiedPresent
        `shouldBe` Left EksDrainNoTargetObservationPresent
      case decodeVerified fixtureDecisionRequest (Left "provider unavailable") of
        AwsEksObservationRejected _ observation ->
          exactObservationResult observation `shouldSatisfy` isUnobservable
        AwsEksObservationDecoded _ ->
          expectationFailure "unobservable provider response minted verified EKS truth"

fixtureBinding :: ObservationEvidenceScope -> EksDrainOperationBinding
fixtureBinding = mustRight . mkBindingFor

mkBindingFor
  :: ObservationEvidenceScope
  -> Either EksDrainIntentError EksDrainOperationBinding
mkBindingFor scope =
  mkEksDrainOperationBinding
    scope
    fixtureRunId
    fixtureGraphDigest
    intentCommitOperation
    intentReadBackOperation
    drainEffectOperation
    drainReadBackOperation

fixtureKubernetesIntent :: EksDrainIntent
fixtureKubernetesIntent =
  mustRight
    ( prepareEksKubernetesDrainIntent
        (fixtureBinding fixtureScope)
        fixtureSession
        fixtureSelection
    )

alternateGraphIntent :: EksDrainIntent
alternateGraphIntent =
  mustRight
    ( prepareEksKubernetesDrainIntent
        ( mustRight
            ( mkEksDrainOperationBinding
                fixtureScope
                fixtureRunId
                (mustRight (mkCleanupDigest (Text.replicate 64 "b")))
                intentCommitOperation
                intentReadBackOperation
                drainEffectOperation
                drainReadBackOperation
            )
        )
        fixtureSession
        fixtureSelection
    )

fixtureSelection :: EksDrainTargetSelectionObservation
fixtureSelection =
  eksDrainTargetSelectionObservationFor
    fixtureSession
    (ObservationRevision 41)
    (EksDrainTargetSelectionComplete [fixturePvcB, fixturePvcA])

fixtureCommittedIntent :: CommittedEksDrainIntent
fixtureCommittedIntent =
  mustRight
    ( confirmEksDrainIntentCommitted
        fixtureKubernetesIntent
        (EksDrainIntentReadBackPresent (encodeEksDrainIntent fixtureKubernetesIntent))
    )

fixtureAttemptEvidence
  :: CleanupAttemptId
  -> EksDrainAttemptOutcome
  -> EksDrainAttemptEvidence
fixtureAttemptEvidence attemptId outcome =
  let attempt = beginEksDrainAttempt fixtureCommittedIntent attemptId
   in mustRight (recordEksDrainAttempt attempt (eksDrainAttemptObservationFor attempt outcome))

fixtureKubernetesReadBack
  :: EksDrainAttemptEvidence -> EksDrainTargetReadBackObservation
fixtureKubernetesReadBack attempt =
  eksDrainTargetReadBackObservationFor
    attempt
    ( EksDrainObservedKubernetesTarget
        EksDrainKubernetesTargetReadBack
          { eksDrainReadBackProviderArn = fixtureArn
          , eksDrainReadBackKubernetesUid = fixtureUid
          , eksDrainReadBackEndpointDigest = eksDrainSessionEndpointDigest fixtureSession
          , eksDrainReadBackCertificateAuthorityDigest =
              eksDrainSessionCertificateAuthorityDigest fixtureSession
          , eksDrainReadBackLoadBalancerServiceClass =
              LoadBalancerServiceClassReadBack
                (EksDrainResourceClassAbsent (AbsenceEvidence "all LB Services absent"))
          , eksDrainReadBackIngressClass =
              IngressClassReadBack
                (EksDrainResourceClassAbsent (AbsenceEvidence "all Ingresses absent"))
          , eksDrainReadBackDeletePolicyPvcs =
              [pvcAbsent fixturePvcB, pvcAbsent fixturePvcA]
          }
    )

observedKubernetesReadBack
  :: EksDrainTargetReadBackObservation -> EksDrainKubernetesTargetReadBack
observedKubernetesReadBack observation = case eksDrainTargetReadBackResult observation of
  EksDrainObservedKubernetesTarget readBack -> readBack
  result -> error ("expected Kubernetes target read-back, got " <> show result)

pvcAbsent :: EksNamespacedName -> EksDrainPvcReadBack
pvcAbsent target =
  EksDrainPvcReadBack target (EksDrainPvcAbsent (AbsenceEvidence "PVC absent"))

fixtureNoTargetIntent :: EksDrainIntent
fixtureNoTargetIntent =
  mustRight
    ( prepareEksNoKubernetesTargetIntent
        (fixtureBinding fixtureScope)
        fixtureVerifiedAbsent
    )

fixtureVerifiedPresent
  :: VerifiedAwsEksObservation 'ObserveEksForDecision
fixtureVerifiedPresent =
  verifiedFromEvidence ("eks-cluster-arn:" <> fixtureArn)

fixtureVerifiedAbsent
  :: VerifiedAwsEksObservation 'ObserveEksForDecision
fixtureVerifiedAbsent = verifiedFromEvidence "registered EKS cluster is absent"

verifiedFromEvidence
  :: Text -> VerifiedAwsEksObservation 'ObserveEksForDecision
verifiedFromEvidence evidence =
  case decodeVerified fixtureDecisionRequest (Right evidence) of
    AwsEksObservationDecoded verified -> verified
    AwsEksObservationRejected err _ -> error ("fixture EKS evidence rejected: " <> show err)

decodeVerified
  :: ExactAwsEksObservationRequest purpose
  -> Either Text Text
  -> AwsEksObservationDecode purpose
decodeVerified request result =
  decodeAwsEksObservation request $ case result of
    Left err -> Left err
    Right evidence ->
      Right
        ( ProviderIntentExecutionObserved
            (awsEksObservationRequestProviderCoordinate request)
            evidence
        )

fixtureDecisionRequest
  :: ExactAwsEksObservationRequest 'ObserveEksForDecision
fixtureDecisionRequest =
  mustRight (mkAwsEksDecisionObservationRequest (ObservationRevision 13) fixtureScope)

fixtureSession :: EksDrainSession
fixtureSession =
  mustRight
    ( mkEksDrainSession
        1_000
        1_500
        drainEffectOperation
        fixtureScope
        fixtureVerifiedPresent
        fixtureKubernetesIdentity
        fixtureProjection
    )

fixtureKubernetesIdentity :: EksKubernetesIdentityObservation
fixtureKubernetesIdentity =
  eksKubernetesIdentityObservationFor
    fixtureScope
    (ObservationRevision 14)
    fixtureArn
    (EksKubernetesIdentityPresent fixtureUid)
    fixtureProjection

fixtureProjection :: EksClientAuthProjection
fixtureProjection =
  mustRight
    ( testEksClientAuthProjection
        "123456789012"
        "us-east-1"
        "aws-eks-test-cluster"
        fixtureArn
        "https://example.eks.amazonaws.com"
        "Y2EtZGF0YQ=="
        "bearer-secret"
        1_800
    )

fixtureScope :: ObservationEvidenceScope
fixtureScope = scopeFor Cascade fixtureRunId

scopeFor :: CleanupSurface -> CleanupRunId -> ObservationEvidenceScope
scopeFor surface runId =
  mkObservationEvidenceScope
    surface
    lifecycleRegistryRevision
    (DurableObservationRunScope (cleanupRunIdText runId))
    fixtureFoundation
    (Just fixtureAwsScope)
    ReconcileDesiredAbsent

fixtureRunId, otherRunId :: CleanupRunId
fixtureRunId = mustRight (mkCleanupRunId "cleanup-run/eks-drain-intent")
otherRunId = mustRight (mkCleanupRunId "cleanup-run/other")

fixtureGraphDigest :: CleanupDigest
fixtureGraphDigest = mustRight (mkCleanupDigest (Text.replicate 64 "a"))

intentCommitOperation
  , intentReadBackOperation
  , drainEffectOperation
  , drainReadBackOperation
    :: CleanupOperationId
intentCommitOperation = mustRight (mkCleanupOperationId "operation/eks-drain-intent-commit")
intentReadBackOperation = mustRight (mkCleanupOperationId "operation/eks-drain-intent-readback")
drainEffectOperation = mustRight (mkCleanupOperationId "operation/eks-drain-effect")
drainReadBackOperation = mustRight (mkCleanupOperationId "operation/eks-drain-readback")

attemptA, attemptB :: CleanupAttemptId
attemptA = mustRight (mkCleanupAttemptId "attempt/eks-drain-a")
attemptB = mustRight (mkCleanupAttemptId "attempt/eks-drain-b")

fixtureFoundation :: LinuxRke2FoundationId
fixtureFoundation = LinuxRke2FoundationId "home-linux-rke2"

fixtureAwsScope :: AwsScope
fixtureAwsScope =
  AwsScope (AwsAccountId "123456789012") (AwsRegion "us-east-1")

fixtureArn :: Text
fixtureArn =
  "arn:aws:eks:us-east-1:123456789012:cluster/aws-eks-test-cluster"

fixtureUid :: Text
fixtureUid = "eks-kube-system-uid-7"

fixturePvcA, fixturePvcB :: EksNamespacedName
fixturePvcA = mustRight (mkEksNamespacedName "api" "api-data")
fixturePvcB = mustRight (mkEksNamespacedName "keycloak" "postgres-data")

isRight :: Either left right -> Bool
isRight value = case value of
  Right _ -> True
  Left _ -> False

isLeft :: Either left right -> Bool
isLeft value = case value of
  Left _ -> True
  Right _ -> False

isRunScopeMismatch
  :: Either EksDrainIntentError EksDrainOperationBinding -> Bool
isRunScopeMismatch value = case value of
  Left EksDrainRunScopeMismatch {} -> True
  _ -> False

isServiceClassRefusal
  :: Either EksDrainIntentError EksDrainTargetsAbsentEvidence -> Bool
isServiceClassRefusal value = case value of
  Left EksDrainServiceClassNotAbsent {} -> True
  _ -> False

isUnobservable :: ExactObservationResult -> Bool
isUnobservable value = case value of
  ExactResourceUnobservable _ -> True
  _ -> False

mustRight :: (Show left) => Either left right -> right
mustRight value = case value of
  Left err -> error (show err)
  Right result -> result
