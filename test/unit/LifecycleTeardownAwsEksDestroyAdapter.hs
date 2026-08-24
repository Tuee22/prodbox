{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownAwsEksDestroyAdapter
  ( lifecycleTeardownAwsEksDestroyAdapterSuite
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import EksClientAuthProjectionFixture (testEksClientAuthProjection)
import Prodbox.ControlPlane.EksClientAuthProjection
  ( EksClientAuthProjection
  )
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderRevision
  , ProviderStackConfig
  , mkAwsEksProviderStackConfig
  , mkAwsTestProviderStackConfig
  , mkProviderRevision
  , providerIntentCoordinate
  , providerStackConfigRef
  )
import Prodbox.Lifecycle.Teardown.AwsEksAdapter
import Prodbox.Lifecycle.Teardown.AwsEksDestroyAdapter
import Prodbox.Lifecycle.Teardown.Decision
import Prodbox.Lifecycle.Teardown.EksDrainIntent
import Prodbox.Lifecycle.Teardown.EksDrainSession
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.RegisteredTargetResult
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownAwsEksDestroyAdapterSuite :: SuiteBuilder ()
lifecycleTeardownAwsEksDestroyAdapterSuite =
  describe "Sprint 7.36 exact EKS destroy authorization" $ do
    it "binds exact drain, decision, current identity, and destroy operation" $ do
      let authorization = fixtureAuthorization
      awsEksDestroyAuthorizationKey authorization `shouldBe` AwsEksKey
      awsEksDestroyAuthorizationCoordinateDigest authorization
        `shouldBe` registeredIdentityCoordinateDigest (mustIdentity AwsEksKey)
      awsEksDestroyAuthorizationScope authorization `shouldBe` fixtureScope
      awsEksDestroyAuthorizationProviderRevision authorization
        `shouldBe` providerRevision
      awsEksDestroyAuthorizationDecision authorization `shouldBe` primaryDecision
      awsEksDestroyAuthorizationAuthorityKind authorization
        `shouldBe` AwsEksDestroyFromPrimaryCheckpoint
      awsEksDestroyAuthorizationDrainBinding authorization
        `shouldBe` fixtureBinding
      awsEksDestroyAuthorizationDrainAttemptId authorization `shouldBe` attemptA
      awsEksDestroyAuthorizationOperationId authorization `shouldBe` destroyOperation
      awsEksDestroyAuthorizationClusterArn authorization `shouldBe` fixtureArn
      awsEksDestroyAuthorizationClusterUid authorization `shouldBe` fixtureUid
      awsEksDestroyAuthorizationEndpointDigest authorization
        `shouldBe` eksDrainSessionEndpointDigest freshSession
      awsEksDestroyAuthorizationCertificateAuthorityDigest authorization
        `shouldBe` eksDrainSessionCertificateAuthorityDigest freshSession
      awsEksDestroyAuthorizationProviderObservationRevision authorization
        `shouldBe` freshProviderObservationRevision
      awsEksDestroyAuthorizationKubernetesObservationRevision authorization
        `shouldBe` freshKubernetesObservationRevision
      awsEksDestroyAuthorizationSessionExpiresAtEpochSeconds authorization
        `shouldBe` freshSessionDeadline
      authorizeFixture manifestDecision freshVerified freshSession fixtureDrainEvidence
        `shouldSatisfy` hasManifestAuthority

    it "refuses a recreated Kubernetes UID and a different exact provider ARN" $ do
      let recreatedSession =
            freshSessionFor
              fixtureArn
              recreatedUid
              fixtureEndpoint
              fixtureCa
              freshProviderObservationRevision
              freshKubernetesObservationRevision
              destroyOperation
              freshSessionDeadline
          otherArnVerified =
            verifiedPresentAt freshProviderObservationRevision fixtureScope otherPartitionArn
          otherArnSession =
            freshSessionFor
              otherPartitionArn
              fixtureUid
              fixtureEndpoint
              fixtureCa
              freshProviderObservationRevision
              freshKubernetesObservationRevision
              destroyOperation
              freshSessionDeadline
      authorizeFixture primaryDecision freshVerified recreatedSession fixtureDrainEvidence
        `shouldBe` Left (AwsEksDestroyDrainedUidMismatch fixtureUid recreatedUid)
      authorizeFixture primaryDecision otherArnVerified otherArnSession fixtureDrainEvidence
        `shouldBe` Left (AwsEksDestroyDrainedArnMismatch fixtureArn otherPartitionArn)

    it "refuses endpoint and certificate-authority rotation after the recorded drain" $ do
      let endpointSession =
            freshSessionFor
              fixtureArn
              fixtureUid
              rotatedEndpoint
              fixtureCa
              freshProviderObservationRevision
              freshKubernetesObservationRevision
              destroyOperation
              freshSessionDeadline
          caSession =
            freshSessionFor
              fixtureArn
              fixtureUid
              fixtureEndpoint
              rotatedCa
              freshProviderObservationRevision
              freshKubernetesObservationRevision
              destroyOperation
              freshSessionDeadline
      authorizeFixture primaryDecision freshVerified endpointSession fixtureDrainEvidence
        `shouldSatisfy` isEndpointMismatch
      authorizeFixture primaryDecision freshVerified caSession fixtureDrainEvidence
        `shouldSatisfy` isCaMismatch

    it "requires the exact run, graph, four operation IDs, and persisted attempt" $ do
      let otherRunScope = scopeFor otherRunId
          otherRunBinding = bindingFor otherRunScope fixtureGraphDigest operationSet
          otherRunEvidence = drainEvidenceFor otherRunBinding attemptA
          otherGraphBinding = bindingFor fixtureScope otherGraphDigest operationSet
          otherGraphEvidence = drainEvidenceFor otherGraphBinding attemptA
      authorizeFixture primaryDecision freshVerified freshSession otherRunEvidence
        `shouldBe` Left (AwsEksDestroyDrainRunMismatch fixtureRunId otherRunId)
      authorizeFixture primaryDecision freshVerified freshSession otherGraphEvidence
        `shouldBe` Left
          (AwsEksDestroyDrainGraphMismatch fixtureGraphDigest otherGraphDigest)
      mapM_
        ( \(alternate, assertion) ->
            assertion
              ( authorizeFixture
                  primaryDecision
                  freshVerified
                  freshSession
                  (drainEvidenceFor alternate attemptA)
              )
        )
        operationMismatchRows
      authorizeFixture
        primaryDecision
        freshVerified
        freshSession
        (drainEvidenceFor fixtureBinding attemptB)
        `shouldBe` Left (AwsEksDestroyDrainAttemptMismatch attemptA attemptB)

    it "requires a newer, live session issued for the distinct destroy operation" $ do
      let staleProviderVerified =
            verifiedPresentAt selectionRevision fixtureScope fixtureArn
          staleProviderSession =
            freshSessionFor
              fixtureArn
              fixtureUid
              fixtureEndpoint
              fixtureCa
              selectionRevision
              freshKubernetesObservationRevision
              destroyOperation
              freshSessionDeadline
          staleKubernetesSession =
            freshSessionFor
              fixtureArn
              fixtureUid
              fixtureEndpoint
              fixtureCa
              freshProviderObservationRevision
              selectionRevision
              destroyOperation
              freshSessionDeadline
          wrongOperationSession =
            freshSessionFor
              fixtureArn
              fixtureUid
              fixtureEndpoint
              fixtureCa
              freshProviderObservationRevision
              freshKubernetesObservationRevision
              otherDestroyOperation
              freshSessionDeadline
          expiredSession =
            freshSessionFor
              fixtureArn
              fixtureUid
              fixtureEndpoint
              fixtureCa
              freshProviderObservationRevision
              freshKubernetesObservationRevision
              destroyOperation
              expiredSessionDeadline
      authorizeFixture primaryDecision staleProviderVerified staleProviderSession fixtureDrainEvidence
        `shouldBe` Left
          ( AwsEksDestroyProviderObservationNotFresh
              selectionRevision
              selectionRevision
          )
      authorizeFixture primaryDecision freshVerified staleKubernetesSession fixtureDrainEvidence
        `shouldBe` Left
          ( AwsEksDestroyKubernetesObservationNotFresh
              selectionRevision
              selectionRevision
          )
      authorizeFixture primaryDecision freshVerified wrongOperationSession fixtureDrainEvidence
        `shouldBe` Left
          (AwsEksDestroySessionOperationMismatch destroyOperation otherDestroyOperation)
      authorizeAwsEksDestroy
        expiredSessionDeadline
        providerRevision
        fixtureBinding
        attemptA
        destroyOperation
        freshVerified
        expiredSession
        primaryDecision
        fixtureDrainEvidence
        `shouldBe` Left
          (AwsEksDestroySessionExpired expiredSessionDeadline expiredSessionDeadline)
      authorizeAwsEksDestroy
        authorizationNow
        providerRevision
        fixtureBinding
        attemptA
        drainEffectOperation
        freshVerified
        freshSession
        primaryDecision
        fixtureDrainEvidence
        `shouldBe` Left
          (AwsEksDestroyOperationIdentityReused drainEffectOperation)

    it "treats observation revisions as opaque identities, not ordered counters" $ do
      let lowerSortingVerified =
            verifiedPresentAt lowerProviderObservationRevision fixtureScope fixtureArn
          lowerSortingSession =
            freshSessionFor
              fixtureArn
              fixtureUid
              fixtureEndpoint
              fixtureCa
              lowerProviderObservationRevision
              lowerKubernetesObservationRevision
              destroyOperation
              freshSessionDeadline
      authorizeFixture
        primaryDecision
        lowerSortingVerified
        lowerSortingSession
        fixtureDrainEvidence
        `shouldSatisfy` isAuthorization

    it "cannot authorize an already-absent/no-target arm or a cross-stack decision" $ do
      authorizeFixture primaryDecision freshVerifiedAbsent freshSession fixtureDrainEvidence
        `shouldBe` Left AwsEksDestroyObservationAlreadyAbsent
      authorizeFixture primaryDecision freshVerified freshSession fixtureNoTargetEvidence
        `shouldBe` Left AwsEksDestroyNoKubernetesTargetCannotAuthorizeMutation
      authorizeFixture crossStackDecision freshVerified freshSession fixtureDrainEvidence
        `shouldBe` Left (AwsEksDestroyDecisionKeyMismatch AwsEksKey AwsTestKey)
      authorizeFixture
        (StackAlreadyAbsent AwsEksKey (AbsenceEvidence "EKS already absent"))
        freshVerified
        freshSession
        fixtureDrainEvidence
        `shouldBe` Left AwsEksDestroyDecisionAlreadyAbsent
      authorizeFixture
        (StackDestroyFromVerifiedPrimary AwsEksKey manifestAuthority)
        freshVerified
        freshSession
        fixtureDrainEvidence
        `shouldBe` Left (AwsEksDestroyDecisionAuthorityMismatch manifestAuthority)

    it "creates only an EKS-specific revision/config-bound destroy request" $ do
      let request = fixtureDestroyRequest
      awsEksDestroyRequestAuthorization request `shouldBe` fixtureAuthorization
      awsEksDestroyRequestKey request `shouldBe` AwsEksKey
      awsEksDestroyRequestScope request `shouldBe` fixtureScope
      awsEksDestroyRequestOperationId request `shouldBe` destroyOperation
      awsEksDestroyRequestProviderIntent request
        `shouldBe` DestroyRegisteredStack
          (providerStackConfigRef eksConfig)
          providerRevision
          eksConfig
      awsEksDestroyRequestProviderCoordinate request
        `shouldBe` providerIntentCoordinate (awsEksDestroyRequestProviderIntent request)
      let manifestAuthorization =
            mustRight
              ( authorizeFixture
                  manifestDecision
                  freshVerified
                  freshSession
                  fixtureDrainEvidence
              )
          manifestRequest =
            mustRight
              (mkAwsEksDestroyRequest manifestAuthorization providerRevision eksConfig)
      awsEksDestroyRequestProviderIntent manifestRequest
        `shouldSatisfy` isNativeManifestReap
      mkAwsEksDestroyRequest fixtureAuthorization otherProviderRevision eksConfig
        `shouldBe` Left
          ( AwsEksDestroyProviderRevisionMismatch
              providerRevision
              otherProviderRevision
          )
      mkAwsEksDestroyRequest fixtureAuthorization providerRevision testConfig
        `shouldSatisfy` isConfigMismatch

    it "is the only capability that can enter the registered EKS reconcile fold" $ do
      let result =
            mustRight
              ( mkAwsEksRegisteredTargetReconcile
                  destroyOperation
                  fixtureEksTarget
                  fixtureScope
                  fixtureAuthorization
                  (RegisteredTargetMutationResponseLost "destroy response lost")
              )
      registeredTargetReconcileKey result `shouldBe` AwsEksKey
      registeredTargetReconcileCoordinateDigest result
        `shouldBe` registeredTargetCoordinateDigest fixtureEksTarget
      registeredTargetReconcileScope result `shouldBe` fixtureScope
      registeredTargetReconcileOperationId result `shouldBe` destroyOperation
      registeredTargetReconcileDisposition result
        `shouldBe` RegisteredTargetAwsEksMutation
          (RegisteredTargetMutationResponseLost "destroy response lost")
      mkAwsEksRegisteredTargetReconcile
        otherDestroyOperation
        fixtureEksTarget
        fixtureScope
        fixtureAuthorization
        RegisteredTargetMutationApplied
        `shouldBe` Left
          ( RegisteredTargetEksAuthorizationOperationMismatch
              otherDestroyOperation
              destroyOperation
          )
      mkAwsEksRegisteredTargetReconcile
        destroyOperation
        fixtureEksTarget
        (scopeFor otherRunId)
        fixtureAuthorization
        RegisteredTargetMutationApplied
        `shouldBe` Left
          ( RegisteredTargetEksAuthorizationScopeMismatch
              (scopeFor otherRunId)
              fixtureScope
          )
      mkAwsEksRegisteredTargetReconcile
        destroyOperation
        (fixtureTargetFor AwsTestKey)
        fixtureScope
        fixtureAuthorization
        RegisteredTargetMutationApplied
        `shouldBe` Left (RegisteredTargetEksKeyRequired AwsTestKey)

    it "closes only through a newer, independent exact provider-absence read-back" $ do
      let readBack = fixtureReadBackRequest
          observationRequest = awsEksDestroyReadBackObservationRequest readBack
      awsEksDestroyReadBackDestroyCoordinate readBack
        `shouldBe` awsEksDestroyRequestProviderCoordinate fixtureDestroyRequest
      awsEksDestroyReadBackRevision readBack `shouldBe` readBackRevision
      awsEksDestroyReadBackProviderIntent readBack
        `shouldBe` awsEksObservationRequestProviderIntent observationRequest
      awsEksDestroyReadBackProviderCoordinate readBack
        `shouldBe` awsEksObservationRequestProviderCoordinate observationRequest
      let absent = decodedReadBack readBack "registered EKS cluster is absent"
          completed = mustRight (completeAwsEksDestroyReadBack readBack absent)
      completeAwsEksDestroyAuthorization completed `shouldBe` fixtureAuthorization
      completeAwsEksDestroyKey completed `shouldBe` AwsEksKey
      completeAwsEksDestroyCoordinateDigest completed
        `shouldBe` awsEksDestroyAuthorizationCoordinateDigest fixtureAuthorization
      completeAwsEksDestroyScope completed `shouldBe` fixtureScope
      completeAwsEksDestroyOperationId completed `shouldBe` destroyOperation
      completeAwsEksDestroyDrainAttemptId completed `shouldBe` attemptA
      completeAwsEksDestroyObservationRevision completed `shouldBe` readBackRevision
      completeAwsEksDestroyAbsenceEvidence completed
        `shouldBe` AbsenceEvidence
          "Provider EKS DescribeCluster returned exact not-found evidence"
      let stillPresent = decodedReadBack readBack ("eks-cluster-arn:" <> fixtureArn)
      completeAwsEksDestroyReadBack readBack stillPresent
        `shouldSatisfy` isStillPresent
      mkAwsEksDestroyReadBackRequest fixtureDestroyRequest freshProviderObservationRevision
        `shouldBe` Left
          ( AwsEksDestroyReadBackRevisionNotFresh
              freshProviderObservationRevision
              freshProviderObservationRevision
          )
      mkAwsEksDestroyReadBackRequest fixtureDestroyRequest lowerReadBackRevision
        `shouldSatisfy` isReadBackRequest
      let otherScopeVerified =
            decodedVerified
              (mustRight (mkAwsEksDesiredAbsenceReadBackRequest readBackRevision (scopeFor otherRunId)))
              "registered EKS cluster is absent"
      completeAwsEksDestroyReadBack readBack otherScopeVerified
        `shouldBe` Left
          ( AwsEksDestroyReadBackScopeMismatch
              fixtureScope
              (scopeFor otherRunId)
          )

    it "keeps all capability constructors private and retains no client credential material" $ do
      source <-
        readFile "src/Prodbox/Lifecycle/Teardown/AwsEksDestroyAdapter.hs"
      let moduleHeader = takeWhile (/= "where") (lines source)
      unlines moduleHeader `shouldNotContain` "AwsEksDestroyAuthorization (.."
      unlines moduleHeader `shouldNotContain` "AwsEksDestroyRequest (.."
      unlines moduleHeader `shouldNotContain` "AwsEksDestroyReadBackRequest (.."
      unlines moduleHeader `shouldNotContain` "CompleteAwsEksDestroy (.."
      mapM_
        (\forbidden -> source `shouldNotContain` forbidden)
        [ "EksClientAuthProjection"
        , "eksClientAuthBearerToken"
        , "eksClientAuthEndpoint"
        , "eksClientAuthCertificateAuthorityData"
        , "withEksDrainClientProjection"
        , "internalEksDrainSessionProjection"
        ]
      let rendered = show fixtureAuthorization
      rendered `shouldNotContain` Text.unpack fixtureEndpoint
      rendered `shouldNotContain` Text.unpack fixtureCa
      rendered `shouldNotContain` Text.unpack fixtureBearer

authorizeFixture
  :: StackDesiredAbsenceDecision
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
  -> EksDrainSession
  -> EksDrainTargetsAbsentEvidence
  -> Either AwsEksDestroyRefusal AwsEksDestroyAuthorization
authorizeFixture decision verified session evidence =
  authorizeAwsEksDestroy
    authorizationNow
    providerRevision
    fixtureBinding
    attemptA
    destroyOperation
    verified
    session
    decision
    evidence

fixtureAuthorization :: AwsEksDestroyAuthorization
fixtureAuthorization =
  mustRight
    (authorizeFixture primaryDecision freshVerified freshSession fixtureDrainEvidence)

fixtureDestroyRequest :: AwsEksDestroyRequest
fixtureDestroyRequest =
  mustRight
    (mkAwsEksDestroyRequest fixtureAuthorization providerRevision eksConfig)

fixtureReadBackRequest :: AwsEksDestroyReadBackRequest
fixtureReadBackRequest =
  mustRight (mkAwsEksDestroyReadBackRequest fixtureDestroyRequest readBackRevision)

fixtureEksTarget :: RegisteredTargetBinding
fixtureEksTarget = fixtureTargetFor AwsEksKey

fixtureTargetFor :: RegisteredResourceKey -> RegisteredTargetBinding
fixtureTargetFor expectedKey =
  case [ target
       | node <- desiredAbsenceProgramNodes program
       , ReconcileRegisteredTargetAbsent target <- [programNodeOperation node]
       , registeredTargetKey target == expectedKey
       ] of
    [target] -> target
    targets ->
      error
        ( "expected one registered target for "
            <> show expectedKey
            <> ", got "
            <> show (length targets)
        )
 where
  program = mustRight (compileDesiredAbsenceProgram CascadeSurface)

fixtureDrainEvidence :: EksDrainTargetsAbsentEvidence
fixtureDrainEvidence = drainEvidenceFor fixtureBinding attemptA

drainEvidenceFor
  :: EksDrainOperationBinding
  -> CleanupAttemptId
  -> EksDrainTargetsAbsentEvidence
drainEvidenceFor binding attemptId =
  mustRight (confirmEksDrainTargetsAbsent attemptEvidence readBack)
 where
  scope = eksDrainBindingScope binding
  projection = projectionFor fixtureArn fixtureEndpoint fixtureCa
  verified = verifiedPresentAt initialProviderObservationRevision scope fixtureArn
  session =
    sessionFor
      initialSessionNow
      initialSessionDeadline
      (eksDrainBindingEffectOperationId binding)
      scope
      verified
      initialKubernetesObservationRevision
      fixtureUid
      projection
  selection =
    eksDrainTargetSelectionObservationFor
      session
      selectionRevision
      (EksDrainTargetSelectionComplete [])
  intent = mustRight (prepareEksKubernetesDrainIntent binding session selection)
  committed =
    mustRight
      ( confirmEksDrainIntentCommitted
          intent
          (EksDrainIntentReadBackPresent (encodeEksDrainIntent intent))
      )
  attempt = beginEksDrainAttempt committed attemptId
  attemptEvidence =
    mustRight
      ( recordEksDrainAttempt
          attempt
          (eksDrainAttemptObservationFor attempt EksDrainMutationApplied)
      )
  readBack =
    eksDrainTargetReadBackObservationFor
      attemptEvidence
      ( EksDrainObservedKubernetesTarget
          EksDrainKubernetesTargetReadBack
            { eksDrainReadBackProviderArn = fixtureArn
            , eksDrainReadBackKubernetesUid = fixtureUid
            , eksDrainReadBackEndpointDigest = eksDrainSessionEndpointDigest session
            , eksDrainReadBackCertificateAuthorityDigest =
                eksDrainSessionCertificateAuthorityDigest session
            , eksDrainReadBackLoadBalancerServiceClass =
                LoadBalancerServiceClassReadBack
                  (EksDrainResourceClassAbsent (AbsenceEvidence "all LB Services absent"))
            , eksDrainReadBackIngressClass =
                IngressClassReadBack
                  (EksDrainResourceClassAbsent (AbsenceEvidence "all Ingresses absent"))
            , eksDrainReadBackControllerOwnerClass =
                ControllerOwnerClassReadBack
                  (EksDrainResourceClassAbsent (AbsenceEvidence "controller owner absent"))
            , eksDrainReadBackDeletePolicyPvcs = []
            }
      )

fixtureNoTargetEvidence :: EksDrainTargetsAbsentEvidence
fixtureNoTargetEvidence =
  mustRight (confirmEksDrainTargetsAbsent attemptEvidence readBack)
 where
  absentVerified =
    verifiedAbsentAt initialProviderObservationRevision fixtureScope
  intent =
    mustRight (prepareEksNoKubernetesTargetIntent fixtureBinding absentVerified)
  committed =
    mustRight
      ( confirmEksDrainIntentCommitted
          intent
          (EksDrainIntentReadBackPresent (encodeEksDrainIntent intent))
      )
  attempt = beginEksDrainAttempt committed attemptA
  attemptEvidence =
    mustRight
      ( recordEksDrainAttempt
          attempt
          (eksDrainAttemptObservationFor attempt EksDrainSkippedNoKubernetesTarget)
      )
  readBack =
    eksDrainTargetReadBackObservationFor
      attemptEvidence
      EksDrainObservedNoKubernetesTarget

freshVerified :: VerifiedAwsEksObservation 'ObserveEksForDecision
freshVerified =
  verifiedPresentAt freshProviderObservationRevision fixtureScope fixtureArn

freshVerifiedAbsent :: VerifiedAwsEksObservation 'ObserveEksForDecision
freshVerifiedAbsent =
  verifiedAbsentAt freshProviderObservationRevision fixtureScope

freshSession :: EksDrainSession
freshSession =
  freshSessionFor
    fixtureArn
    fixtureUid
    fixtureEndpoint
    fixtureCa
    freshProviderObservationRevision
    freshKubernetesObservationRevision
    destroyOperation
    freshSessionDeadline

freshSessionFor
  :: Text
  -> Text
  -> Text
  -> Text
  -> ObservationRevision
  -> ObservationRevision
  -> CleanupOperationId
  -> Integer
  -> EksDrainSession
freshSessionFor arn uid endpoint ca providerObservationRevision kubernetesRevision operation deadline =
  sessionFor
    freshSessionMintedAt
    deadline
    operation
    fixtureScope
    (verifiedPresentAt providerObservationRevision fixtureScope arn)
    kubernetesRevision
    uid
    (projectionFor arn endpoint ca)

sessionFor
  :: Integer
  -> Integer
  -> CleanupOperationId
  -> ObservationEvidenceScope
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
  -> ObservationRevision
  -> Text
  -> EksClientAuthProjection
  -> EksDrainSession
sessionFor now deadline operation scope verified kubernetesRevision uid projection =
  mustRight
    ( mkEksDrainSession
        now
        deadline
        operation
        scope
        verified
        ( eksKubernetesIdentityObservationFor
            scope
            kubernetesRevision
            (mustArn verified)
            (EksKubernetesIdentityPresent uid)
            projection
        )
        projection
    )

projectionFor :: Text -> Text -> Text -> EksClientAuthProjection
projectionFor arn endpoint ca =
  mustRight
    ( testEksClientAuthProjection
        "123456789012"
        (fixtureAwsRegion FixtureUsEast1)
        "aws-eks-test-cluster"
        arn
        endpoint
        ca
        fixtureBearer
        projectionExpiresAt
    )

verifiedPresentAt
  :: ObservationRevision
  -> ObservationEvidenceScope
  -> Text
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
verifiedPresentAt revision scope arn =
  decodedVerified
    (mustRight (mkAwsEksDecisionObservationRequest revision scope))
    ("eks-cluster-arn:" <> arn)

verifiedAbsentAt
  :: ObservationRevision
  -> ObservationEvidenceScope
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
verifiedAbsentAt revision scope =
  decodedVerified
    (mustRight (mkAwsEksDecisionObservationRequest revision scope))
    "registered EKS cluster is absent"

decodedReadBack
  :: AwsEksDestroyReadBackRequest
  -> Text
  -> VerifiedAwsEksObservation 'ReadBackEksDesiredAbsent
decodedReadBack request =
  decodedVerified (awsEksDestroyReadBackObservationRequest request)

decodedVerified
  :: ExactAwsEksObservationRequest purpose
  -> Text
  -> VerifiedAwsEksObservation purpose
decodedVerified request evidence =
  case decodeAwsEksObservation
    request
    ( Right
        ( ProviderIntentExecutionObserved
            (awsEksObservationRequestProviderCoordinate request)
            evidence
        )
    ) of
    AwsEksObservationDecoded verified -> verified
    AwsEksObservationRejected err _ ->
      error ("expected verified EKS observation: " <> show err)

mustArn :: VerifiedAwsEksObservation purpose -> Text
mustArn verified = case verifiedAwsEksClusterArn verified of
  Just arn -> arn
  Nothing -> error "expected present EKS ARN"

fixtureBinding :: EksDrainOperationBinding
fixtureBinding = bindingFor fixtureScope fixtureGraphDigest operationSet

bindingFor
  :: ObservationEvidenceScope
  -> CleanupDigest
  -> ( CleanupOperationId
     , CleanupOperationId
     , CleanupOperationId
     , CleanupOperationId
     )
  -> EksDrainOperationBinding
bindingFor scope graphDigest (commitOperation, intentReadBack, effectOperation, drainReadBack) =
  mustRight
    ( mkEksDrainOperationBinding
        scope
        (runIdForScope scope)
        graphDigest
        commitOperation
        intentReadBack
        effectOperation
        drainReadBack
    )

runIdForScope :: ObservationEvidenceScope -> CleanupRunId
runIdForScope scope =
  case evidenceDurableRunScope scope of
    DurableObservationRunScope raw -> mustRight (mkCleanupRunId raw)

operationMismatchRows
  :: [(EksDrainOperationBinding, Either AwsEksDestroyRefusal AwsEksDestroyAuthorization -> Expectation)]
operationMismatchRows =
  [
    ( bindingFor
        fixtureScope
        fixtureGraphDigest
        (otherIntentCommitOperation, intentReadBackOperation, drainEffectOperation, drainReadBackOperation)
    , ( `shouldBe`
          Left
            ( AwsEksDestroyDrainIntentCommitOperationMismatch
                intentCommitOperation
                otherIntentCommitOperation
            )
      )
    )
  ,
    ( bindingFor
        fixtureScope
        fixtureGraphDigest
        (intentCommitOperation, otherIntentReadBackOperation, drainEffectOperation, drainReadBackOperation)
    , ( `shouldBe`
          Left
            ( AwsEksDestroyDrainIntentReadBackOperationMismatch
                intentReadBackOperation
                otherIntentReadBackOperation
            )
      )
    )
  ,
    ( bindingFor
        fixtureScope
        fixtureGraphDigest
        (intentCommitOperation, intentReadBackOperation, otherDrainEffectOperation, drainReadBackOperation)
    , ( `shouldBe`
          Left
            ( AwsEksDestroyDrainEffectOperationMismatch
                drainEffectOperation
                otherDrainEffectOperation
            )
      )
    )
  ,
    ( bindingFor
        fixtureScope
        fixtureGraphDigest
        (intentCommitOperation, intentReadBackOperation, drainEffectOperation, otherDrainReadBackOperation)
    , ( `shouldBe`
          Left
            ( AwsEksDestroyDrainReadBackOperationMismatch
                drainReadBackOperation
                otherDrainReadBackOperation
            )
      )
    )
  ]

operationSet
  :: ( CleanupOperationId
     , CleanupOperationId
     , CleanupOperationId
     , CleanupOperationId
     )
operationSet =
  ( intentCommitOperation
  , intentReadBackOperation
  , drainEffectOperation
  , drainReadBackOperation
  )

fixtureScope :: ObservationEvidenceScope
fixtureScope = scopeFor fixtureRunId

scopeFor :: CleanupRunId -> ObservationEvidenceScope
scopeFor runId =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope (cleanupRunIdText runId))
    fixtureFoundation
    (Just fixtureAwsScope)
    ReconcileDesiredAbsent

primaryDecision, manifestDecision, crossStackDecision :: StackDesiredAbsenceDecision
primaryDecision = StackDestroyFromVerifiedPrimary AwsEksKey primaryAuthority
manifestDecision = StackDestroyFromVerifiedManifest AwsEksKey manifestAuthority
crossStackDecision = StackDestroyFromVerifiedPrimary AwsTestKey primaryAuthority

primaryAuthority, manifestAuthority :: StackCleanupAuthority
primaryAuthority =
  VerifiedPrimaryCheckpoint
    (CheckpointProvenance "primary://aws-eks-destroy")
    (CheckpointVersion "primary-v1")
manifestAuthority =
  VerifiedOwnershipManifest
    (OwnershipManifestProvenance "manifest://aws-eks-destroy")
    (OwnershipManifestVersion "manifest-v1")
    [ObservedResourceIdentity ("eks-cluster/" <> fixtureArn)]

fixtureRunId, otherRunId :: CleanupRunId
fixtureRunId = mustRight (mkCleanupRunId "cleanup-run/eks-destroy")
otherRunId = mustRight (mkCleanupRunId "cleanup-run/eks-destroy-other")

fixtureGraphDigest, otherGraphDigest :: CleanupDigest
fixtureGraphDigest = mustRight (mkCleanupDigest (Text.replicate 64 "a"))
otherGraphDigest = mustRight (mkCleanupDigest (Text.replicate 64 "b"))

intentCommitOperation
  , intentReadBackOperation
  , drainEffectOperation
  , drainReadBackOperation
  , otherIntentCommitOperation
  , otherIntentReadBackOperation
  , otherDrainEffectOperation
  , otherDrainReadBackOperation
  , destroyOperation
  , otherDestroyOperation
    :: CleanupOperationId
intentCommitOperation = mustOperation "operation/eks-drain-intent-commit"
intentReadBackOperation = mustOperation "operation/eks-drain-intent-readback"
drainEffectOperation = mustOperation "operation/eks-drain-effect"
drainReadBackOperation = mustOperation "operation/eks-drain-readback"
otherIntentCommitOperation = mustOperation "operation/other-intent-commit"
otherIntentReadBackOperation = mustOperation "operation/other-intent-readback"
otherDrainEffectOperation = mustOperation "operation/other-drain-effect"
otherDrainReadBackOperation = mustOperation "operation/other-drain-readback"
destroyOperation = mustOperation "operation/eks-stack-destroy"
otherDestroyOperation = mustOperation "operation/other-eks-stack-destroy"

attemptA, attemptB :: CleanupAttemptId
attemptA = mustRight (mkCleanupAttemptId "attempt/eks-drain-a")
attemptB = mustRight (mkCleanupAttemptId "attempt/eks-drain-b")

providerRevision, otherProviderRevision :: ProviderRevision
providerRevision = mustRight (mkProviderRevision 17)
otherProviderRevision = mustRight (mkProviderRevision 18)

eksConfig, testConfig :: ProviderStackConfig
eksConfig = mustRight (mkAwsEksProviderStackConfig "203.0.113.10/32")
testConfig = mustRight (mkAwsTestProviderStackConfig "203.0.113.10/32")

initialProviderObservationRevision
  , initialKubernetesObservationRevision
  , selectionRevision
  , freshProviderObservationRevision
  , freshKubernetesObservationRevision
  , readBackRevision
  , lowerProviderObservationRevision
  , lowerKubernetesObservationRevision
  , lowerReadBackRevision
    :: ObservationRevision
initialProviderObservationRevision = ObservationRevision 20
initialKubernetesObservationRevision = ObservationRevision 21
selectionRevision = ObservationRevision 30
freshProviderObservationRevision = ObservationRevision 50
freshKubernetesObservationRevision = ObservationRevision 51
readBackRevision = ObservationRevision 60
lowerProviderObservationRevision = ObservationRevision 10
lowerKubernetesObservationRevision = ObservationRevision 11
lowerReadBackRevision = ObservationRevision 9

initialSessionNow
  , initialSessionDeadline
  , freshSessionMintedAt
  , authorizationNow
  , freshSessionDeadline
  , expiredSessionDeadline
  , projectionExpiresAt
    :: Integer
initialSessionNow = 1_000
initialSessionDeadline = 1_500
freshSessionMintedAt = 1_400
authorizationNow = 1_500
freshSessionDeadline = 1_900
expiredSessionDeadline = 1_500
projectionExpiresAt = 2_200

fixtureFoundation :: LinuxRke2FoundationId
fixtureFoundation = LinuxRke2FoundationId "home-linux-rke2"

fixtureAwsScope :: AwsScope
fixtureAwsScope =
  AwsScope (AwsAccountId "123456789012") (AwsRegion (fixtureAwsRegion FixtureUsEast1))

fixtureArn, otherPartitionArn, fixtureUid, recreatedUid :: Text
fixtureArn =
  ("arn:aws:eks:" <> (fixtureAwsRegion FixtureUsEast1) <> ":123456789012:cluster/aws-eks-test-cluster")
otherPartitionArn =
  ( "arn:aws-us-gov:eks:"
      <> (fixtureAwsRegion FixtureUsEast1)
      <> ":123456789012:cluster/aws-eks-test-cluster"
  )
fixtureUid = "eks-kube-system-uid-original"
recreatedUid = "eks-kube-system-uid-recreated"

fixtureEndpoint, rotatedEndpoint, fixtureCa, rotatedCa, fixtureBearer :: Text
fixtureEndpoint = "https://original.eks.amazonaws.com"
rotatedEndpoint = "https://recreated.eks.amazonaws.com"
fixtureCa = "Y2Etb3JpZ2luYWw="
rotatedCa = "Y2Etcm90YXRlZA=="
fixtureBearer = "destroy-session-bearer-secret"

hasManifestAuthority
  :: Either AwsEksDestroyRefusal AwsEksDestroyAuthorization -> Bool
hasManifestAuthority result = case result of
  Right authorization ->
    awsEksDestroyAuthorizationAuthorityKind authorization
      == AwsEksDestroyFromCompleteManifest ["eks-cluster/" <> fixtureArn]
  Left _ -> False

isAuthorization
  :: Either AwsEksDestroyRefusal AwsEksDestroyAuthorization -> Bool
isAuthorization result = case result of
  Right _ -> True
  Left _ -> False

isReadBackRequest
  :: Either AwsEksDestroyRefusal AwsEksDestroyReadBackRequest -> Bool
isReadBackRequest result = case result of
  Right _ -> True
  Left _ -> False

isEndpointMismatch
  :: Either AwsEksDestroyRefusal AwsEksDestroyAuthorization -> Bool
isEndpointMismatch result = case result of
  Left AwsEksDestroyDrainedEndpointDigestMismatch {} -> True
  _ -> False

isCaMismatch
  :: Either AwsEksDestroyRefusal AwsEksDestroyAuthorization -> Bool
isCaMismatch result = case result of
  Left AwsEksDestroyDrainedCertificateAuthorityDigestMismatch {} -> True
  _ -> False

isConfigMismatch :: Either AwsEksDestroyRefusal AwsEksDestroyRequest -> Bool
isConfigMismatch result = case result of
  Left AwsEksDestroyConfigInvalid {} -> True
  _ -> False

isNativeManifestReap :: ProviderIntent -> Bool
isNativeManifestReap intent = case intent of
  ReapNativeStackFamily _ config admitted ->
    config == eksConfig && admitted == ["eks-cluster/" <> fixtureArn]
  _ -> False

isStillPresent :: Either AwsEksDestroyRefusal CompleteAwsEksDestroy -> Bool
isStillPresent result = case result of
  Left AwsEksDestroyReadBackStillPresent {} -> True
  _ -> False

mustIdentity :: RegisteredResourceKey -> RegisteredIdentity
mustIdentity key = case lookupRegisteredIdentity key of
  Just identity -> identity
  Nothing -> error ("missing registered identity: " <> show key)

mustOperation :: Text -> CleanupOperationId
mustOperation = mustRight . mkCleanupOperationId

mustRight :: (Show errorValue) => Either errorValue value -> value
mustRight value = case value of
  Right result -> result
  Left err -> error ("expected Right, got " <> show err)
