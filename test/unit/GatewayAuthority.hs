{-# LANGUAGE OverloadedStrings #-}

module GatewayAuthority
  ( gatewayAuthoritySuite
  )
where

import Control.Monad (forM_)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Capacity.RuntimeMemory qualified as RuntimeMemory
import Prodbox.Gateway.ChildSchedule
import Prodbox.Gateway.DnsAuthority
import Prodbox.Gateway.Orders
import TestSupport

gatewayAuthoritySuite :: SuiteBuilder ()
gatewayAuthoritySuite = do
  ordersAdmissionSuite
  dnsAuthoritySuite
  childScheduleSuite

ordersAdmissionSuite :: SuiteBuilder ()
ordersAdmissionSuite =
  describe "bounded gateway Orders admission" $ do
    it "admits a literal first Orders document and exposes opaque witnesses" $ do
      let source = validOrdersSource 1
          literalSource = mustRight (preflightOrdersSource validOrdersLimits source)
          result = admitDecodedOrders literalSource FirstOrdersAdmission (validRawOrders 1)
      case result of
        Left err -> expectationFailure (show err)
        Right admitted -> do
          admittedOrdersVersion admitted `shouldBe` 1
          map admittedMemberNodeId (admittedOrdersMembers admitted)
            `shouldBe` ["node-a", "node-b"]
          admittedOrdersRankedMembers admitted `shouldBe` ["node-a", "node-b"]
          admittedOrdersHeartbeatTimeoutSeconds admitted `shouldBe` 5
          ordersAnchorVersion (admittedOrdersAnchor admitted) `shouldBe` 1
          Text.length (ordersHashHex (admittedOrdersHashWitness admitted)) `shouldBe` 64
          admittedOrdersFirstAdmissionWitness admitted `shouldSatisfy` isJust

    it "admits a strictly newer successor against the previous opaque anchor" $ do
      first <- admitOrdersDhall validOrdersLimits FirstOrdersAdmission (validOrdersSource 1)
      case first of
        Left err -> expectationFailure (show err)
        Right admittedFirst -> do
          successor <-
            admitOrdersDhall
              validOrdersLimits
              (SuccessorOrdersAdmission (admittedOrdersAnchor admittedFirst))
              (validOrdersSource 2)
          case successor of
            Left err -> expectationFailure (show err)
            Right admittedSuccessor -> do
              admittedOrdersVersion admittedSuccessor `shouldBe` 2
              admittedOrdersFirstAdmissionWitness admittedSuccessor `shouldBe` Nothing
              admittedOrdersHashWitness admittedSuccessor
                `shouldNotBe` admittedOrdersHashWitness admittedFirst

    it "rejects a successor whose version does not advance" $ do
      let firstSource = mustRight (preflightOrdersSource validOrdersLimits (validOrdersSource 2))
          first = mustRight (admitDecodedOrders firstSource FirstOrdersAdmission (validRawOrders 2))
          successorSource = mustRight (preflightOrdersSource validOrdersLimits (validOrdersSource 2))
      admitDecodedOrders
        successorSource
        (SuccessorOrdersAdmission (admittedOrdersAnchor first))
        (validRawOrders 2)
        `shouldBe` Left (OrdersVersionNotNewer 2 2)

    it "rejects every zero authored bound before parsing" $ do
      let cases =
            [ (validOrdersLimits {ordersMaxRawBytes = 0}, MaxRawOrdersBytes)
            , (validOrdersLimits {ordersMaxMembers = 0}, MaxOrdersMembers)
            , (validOrdersLimits {ordersMaxNodeIdBytes = 0}, MaxMemberNodeIdBytes)
            , (validOrdersLimits {ordersMaxEndpointBytes = 0}, MaxMemberEndpointBytes)
            , (validOrdersLimits {ordersMaxTrustKeyBytes = 0}, MaxMemberTrustKeyBytes)
            , (validOrdersLimits {ordersMaxEncodedStateBytes = 0}, MaxMemberEncodedStateBytes)
            ]
      forM_ cases $ \(limits, expectedField) ->
        preflightOrdersSource limits "not even Dhall"
          `shouldBe` Left (OrdersLimitMustBePositive expectedField)

    it "rejects oversized raw UTF-8 before parsing invalid syntax" $ do
      let limits = validOrdersLimits {ordersMaxRawBytes = 4}
      preflightOrdersSource limits "not valid Dhall"
        `shouldBe` Left (OrdersRawSourceTooLarge 15 4)

    it "counts source and member limits in UTF-8 bytes rather than characters" $ do
      let sourceLimits = validOrdersLimits {ordersMaxRawBytes = 1}
      preflightOrdersSource sourceLimits "é"
        `shouldBe` Left (OrdersRawSourceTooLarge 2 1)
      let memberLimits = validOrdersLimits {ordersMaxNodeIdBytes = 1}
          literalSource = mustRight (preflightOrdersSource memberLimits (validOrdersSource 1))
          raw =
            (validRawOrders 1)
              { members = [validRawMemberA {node_id = "é"}, validRawMemberB]
              , ranked_members = ["é", "node-b"]
              }
      admitDecodedOrders literalSource FirstOrdersAdmission raw
        `shouldBe` Left
          OrdersMemberFieldExceedsLimit
            { invalidOrdersMemberIndex = 0
            , invalidOrdersMemberField = MemberNodeId
            , actualOrdersMemberFieldBytes = 2
            , allowedOrdersMemberFieldBytes = 1
            }

    it "rejects imports and computed Dhall before generic decoding" $ do
      preflightOrdersSource validOrdersLimits "./orders.dhall"
        `shouldBe` Left OrdersSourceMustBeLiteral
      preflightOrdersSource
        validOrdersLimits
        "let orders = { version_utc = 1 } in orders"
        `shouldBe` Left OrdersSourceMustBeLiteral

    it "distinguishes literal shape decode failure from the source gate" $ do
      result <-
        admitOrdersDhall
          validOrdersLimits
          FirstOrdersAdmission
          "{ unexpected = 1 }"
      result `shouldSatisfy` isDhallDecodeFailure

    it "decodes and admits the supported literal Dhall shape end to end" $ do
      result <-
        admitOrdersDhall
          validOrdersLimits
          FirstOrdersAdmission
          (validOrdersSource 1)
      case result of
        Left err -> expectationFailure (show err)
        Right admitted ->
          map admittedMemberEndpoint (admittedOrdersMembers admitted)
            `shouldBe` ["https://node-a:8444", "https://node-b:8444"]

    it "anchors equivalent Orders semantics independently of Dhall formatting and field order" $ do
      original <-
        admitOrdersDhall
          validOrdersLimits
          FirstOrdersAdmission
          (validOrdersSource 1)
      reordered <-
        admitOrdersDhall
          validOrdersLimits
          FirstOrdersAdmission
          (equivalentOrdersSource 1)
      case (original, reordered) of
        (Right originalOrders, Right reorderedOrders) ->
          admittedOrdersHashWitness originalOrders
            `shouldBe` admittedOrdersHashWitness reorderedOrders
        (Left err, _) -> expectationFailure (show err)
        (_, Left err) -> expectationFailure (show err)

    it "rejects zero document version, heartbeat timeout, and member count" $ do
      let literalSource = mustRight (preflightOrdersSource validOrdersLimits (validOrdersSource 1))
      admitDecodedOrders
        literalSource
        FirstOrdersAdmission
        (validRawOrders 1) {version_utc = 0}
        `shouldBe` Left OrdersVersionMustBePositive
      admitDecodedOrders
        literalSource
        FirstOrdersAdmission
        (validRawOrders 1) {heartbeat_timeout_seconds = 0}
        `shouldBe` Left OrdersHeartbeatTimeoutMustBePositive
      admitDecodedOrders
        literalSource
        FirstOrdersAdmission
        (validRawOrders 1) {members = [], ranked_members = []}
        `shouldBe` Left OrdersMemberCountMustBePositive

    it "rejects member count above the admitted maximum" $ do
      let limits = validOrdersLimits {ordersMaxMembers = 1}
          literalSource = mustRight (preflightOrdersSource limits (validOrdersSource 1))
      admitDecodedOrders literalSource FirstOrdersAdmission (validRawOrders 1)
        `shouldBe` Left (OrdersMemberCountExceedsLimit 2 1)

    it "rejects empty and oversized member fields before building maps" $ do
      let literalSource = mustRight (preflightOrdersSource validOrdersLimits (validOrdersSource 1))
          firstMember = validRawMemberA
          fieldCases =
            [
              ( firstMember {node_id = ""}
              , OrdersMemberFieldMustNotBeEmpty 0 MemberNodeId
              )
            ,
              ( firstMember {endpoint = ""}
              , OrdersMemberFieldMustNotBeEmpty 0 MemberEndpoint
              )
            ,
              ( firstMember {trust_key = ""}
              , OrdersMemberFieldMustNotBeEmpty 0 MemberTrustKey
              )
            ,
              ( firstMember {encoded_state = ""}
              , OrdersMemberFieldMustNotBeEmpty 0 MemberEncodedState
              )
            ,
              ( firstMember {node_id = Text.replicate 65 "n"}
              , OrdersMemberFieldExceedsLimit 0 MemberNodeId 65 64
              )
            ,
              ( firstMember {endpoint = Text.replicate 257 "e"}
              , OrdersMemberFieldExceedsLimit 0 MemberEndpoint 257 256
              )
            ,
              ( firstMember {trust_key = Text.replicate 129 "k"}
              , OrdersMemberFieldExceedsLimit 0 MemberTrustKey 129 128
              )
            ,
              ( firstMember {encoded_state = Text.replicate 513 "s"}
              , OrdersMemberFieldExceedsLimit 0 MemberEncodedState 513 512
              )
            ]
      forM_ fieldCases $ \(invalidMember, expectedError) ->
        admitDecodedOrders
          literalSource
          FirstOrdersAdmission
          (validRawOrders 1)
            { members = [invalidMember, validRawMemberB]
            }
          `shouldBe` Left expectedError

    it "rejects duplicate member and ranking identifiers" $ do
      let literalSource = mustRight (preflightOrdersSource validOrdersLimits (validOrdersSource 1))
          duplicateMember = validRawMemberB {node_id = "node-a"}
      admitDecodedOrders
        literalSource
        FirstOrdersAdmission
        (validRawOrders 1) {members = [validRawMemberA, duplicateMember]}
        `shouldBe` Left (DuplicateOrdersMemberId "node-a")
      admitDecodedOrders
        literalSource
        FirstOrdersAdmission
        (validRawOrders 1) {ranked_members = ["node-a", "node-a"]}
        `shouldBe` Left (DuplicateRankedMemberId "node-a")

    it "requires ranked membership to be an exact permutation of members" $ do
      let literalSource = mustRight (preflightOrdersSource validOrdersLimits (validOrdersSource 1))
      admitDecodedOrders
        literalSource
        FirstOrdersAdmission
        (validRawOrders 1) {ranked_members = ["node-a", "unknown"]}
        `shouldBe` Left (RankedMemberUnknown "unknown")
      admitDecodedOrders
        literalSource
        FirstOrdersAdmission
        (validRawOrders 1) {ranked_members = ["node-a"]}
        `shouldBe` Left (OrdersMemberMissingFromRanking "node-b")
      let reversed =
            mustRight
              ( admitDecodedOrders
                  literalSource
                  FirstOrdersAdmission
                  (validRawOrders 1) {ranked_members = ["node-b", "node-a"]}
              )
      admittedOrdersRankedMembers reversed `shouldBe` ["node-b", "node-a"]

dnsAuthoritySuite :: SuiteBuilder ()
dnsAuthoritySuite =
  describe "credentialed and continuity-fenced DNS authority" $ do
    it "rejects zero credential generation and empty credential fields" $ do
      mkCredentialGeneration 0 `shouldBe` Left CredentialGenerationMustBePositive
      let cases =
            [ (validCredentialInput {dnsCredentialAccessKeyId = ""}, DnsAccessKeyId)
            , (validCredentialInput {dnsCredentialSecretAccessKey = " "}, DnsSecretAccessKey)
            , (validCredentialInput {dnsCredentialSessionToken = Just ""}, DnsSessionToken)
            , (validCredentialInput {dnsCredentialRegion = ""}, DnsRegion)
            ]
      forM_ cases $ \(input, field) ->
        mkDnsAwsCredentials input
          `shouldBe` Left (DnsCredentialFieldMustNotBeEmpty field)

    it "requires restart exactly when the credential generation changes" $ do
      let generationTwo = mustRight (mkCredentialGeneration 2)
      decideCredentialReload generationOne generationOne
        `shouldBe` CredentialGenerationUnchanged
      decideCredentialReload generationOne generationTwo
        `shouldBe` CredentialGenerationRestartRequired generationOne generationTwo
      decideCredentialReload generationTwo generationOne
        `shouldBe` CredentialGenerationRestartRequired generationTwo generationOne

    it "validates continuity fences and current claim identities" $ do
      mkContinuityFence 0 0 "hash"
        `shouldBe` Left ContinuityEpochMustBePositive
      mkContinuityFence 1 0 " "
        `shouldBe` Left ContinuityHashMustNotBeEmpty
      mkCurrentDnsClaim " " generationOne continuityFenceOne
        `shouldBe` Left DnsClaimNodeIdMustNotBeEmpty
      continuityFenceSequence continuityFenceOne `shouldBe` 0

    it "refuses every non-ready credential observation" $ do
      let invalidReason = DnsCredentialFieldMustNotBeEmpty DnsRegion
          cases =
            [
              ( CredentialsAbsent generationOne
              , CredentialsNotReady CredentialObjectAbsent
              )
            ,
              ( CredentialsInvalid generationOne invalidReason
              , CredentialsNotReady (CredentialObjectInvalid invalidReason)
              )
            ,
              ( CredentialsUnobservable "vault unavailable"
              , CredentialsNotReady (CredentialObjectUnobservable "vault unavailable")
              )
            ]
      forM_ cases $ \(observation, expectedError) ->
        authorizeDnsWrite
          "node-a"
          observation
          (ContinuityReady continuityFenceOne)
          (DnsClaimCurrent currentClaimOne)
          `shouldBe` Left expectedError

    it "refuses every non-ready continuity observation" $ do
      let cases =
            [ (ContinuityAbsent, ContinuityNotReady ContinuityObjectAbsent)
            ,
              ( ContinuityCorrupt "bad anchor"
              , ContinuityNotReady (ContinuityObjectCorrupt "bad anchor")
              )
            ,
              ( ContinuityUnobservable "store unavailable"
              , ContinuityNotReady (ContinuityObjectUnobservable "store unavailable")
              )
            ]
      forM_ cases $ \(observation, expectedError) ->
        authorizeDnsWrite
          "node-a"
          (CredentialsReady generationOne validDnsCredentials)
          observation
          (DnsClaimCurrent currentClaimOne)
          `shouldBe` Left expectedError

    it "refuses every claim observation except current" $ do
      let cases =
            [ (DnsClaimAbsent, DnsClaimNotCurrent ClaimAbsent)
            , (DnsClaimYielded, DnsClaimNotCurrent ClaimYielded)
            , (DnsClaimStale currentClaimOne, DnsClaimNotCurrent ClaimStale)
            ,
              ( DnsClaimUnobservable "claim unavailable"
              , DnsClaimNotCurrent (ClaimUnobservable "claim unavailable")
              )
            ]
      forM_ cases $ \(observation, expectedError) ->
        authorizeDnsWrite
          "node-a"
          (CredentialsReady generationOne validDnsCredentials)
          (ContinuityReady continuityFenceOne)
          observation
          `shouldBe` Left expectedError

    it "refuses a claim for another node, credential generation, or fence" $ do
      authorizeDnsWrite
        "node-b"
        (CredentialsReady generationOne validDnsCredentials)
        (ContinuityReady continuityFenceOne)
        (DnsClaimCurrent currentClaimOne)
        `shouldBe` Left (DnsClaimNodeMismatch "node-b" "node-a")
      let generationTwo = mustRight (mkCredentialGeneration 2)
      authorizeDnsWrite
        "node-a"
        (CredentialsReady generationTwo validDnsCredentials)
        (ContinuityReady continuityFenceOne)
        (DnsClaimCurrent currentClaimOne)
        `shouldBe` Left (DnsClaimCredentialGenerationMismatch 2 1)
      let fenceTwo = mustRight (mkContinuityFence 1 1 "hash-2")
      authorizeDnsWrite
        "node-a"
        (CredentialsReady generationOne validDnsCredentials)
        (ContinuityReady fenceTwo)
        (DnsClaimCurrent currentClaimOne)
        `shouldBe` Left DnsClaimContinuityFenceMismatch

    it "authorizes only the matching ready generation, fence, and current claim" $ do
      case validDnsAuthority of
        Left err -> expectationFailure (show err)
        Right authority -> do
          authorizedDnsNodeId authority `shouldBe` "node-a"
          credentialGenerationValue (authorizedCredentialGeneration authority) `shouldBe` 1
          authorizedContinuityFence authority `shouldBe` continuityFenceOne

    it "validates and binds the exact Route 53 request before interpretation" $ do
      mkDnsWriteRequest "" "gateway.example.test" 60 "us-east-1" "203.0.113.10"
        `shouldBe` Left DnsWriteZoneIdInvalid
      mkDnsWriteRequest "Z123" "bad_host" 60 "us-east-1" "203.0.113.10"
        `shouldBe` Left DnsWriteFqdnInvalid
      mkDnsWriteRequest "Z123" "gateway.example.test" 0 "us-east-1" "203.0.113.10"
        `shouldBe` Left (DnsWriteTtlInvalid 0)
      mkDnsWriteRequest "Z123" "gateway.example.test" 60 "us-east-1" "999.0.0.1"
        `shouldBe` Left DnsWriteIpv4Invalid
      let authority = mustRight validDnsAuthority
          request = mustRight validDnsRequest
          action = mustRight (authorizeDnsWriteRequest authority request)
      dnsWriteActionZoneId action `shouldBe` "Z123"
      dnsWriteActionFqdn action `shouldBe` "gateway.example.test"
      dnsWriteActionTtl action `shouldBe` 60
      dnsWriteActionIpv4 action `shouldBe` "203.0.113.10"
      let wrongRegion =
            mustRight
              (mkDnsWriteRequest "Z123" "gateway.example.test" 60 "us-west-2" "203.0.113.10")
      authorizeDnsWriteRequest authority wrongRegion
        `shouldBe` Left DnsWriteRequestRegionMismatch

    it "never reaches a DNS interpreter without ready credentials and continuity" $ do
      callCount <- newIORef (0 :: Int)
      let interpretIfAuthorized authorityResult =
            case authorityResult of
              Left _ -> pure ()
              Right authority ->
                case authorizeDnsWriteRequest authority (mustRight validDnsRequest) of
                  Left _ -> pure ()
                  Right _ -> modifyIORef' callCount (+ 1)
          absentCredentials =
            authorizeDnsWrite
              "node-a"
              (CredentialsAbsent generationOne)
              (ContinuityReady continuityFenceOne)
              (DnsClaimCurrent currentClaimOne)
          unobservableCredentials =
            authorizeDnsWrite
              "node-a"
              (CredentialsUnobservable "vault down")
              (ContinuityReady continuityFenceOne)
              (DnsClaimCurrent currentClaimOne)
          unobservableContinuity =
            authorizeDnsWrite
              "node-a"
              (CredentialsReady generationOne validDnsCredentials)
              (ContinuityUnobservable "store down")
              (DnsClaimCurrent currentClaimOne)
      mapM_ interpretIfAuthorized [absentCredentials, unobservableCredentials, unobservableContinuity]
      readIORef callCount `shouldReturn` 0

    it "renders a sealed AWS environment with metadata and profiles disabled" $ do
      let authority = mustRight validDnsAuthority
          environment = dnsWriteAwsEnvironment authority
      lookup "AWS_ACCESS_KEY_ID" environment `shouldBe` Just "AKIA_TEST"
      lookup "AWS_SECRET_ACCESS_KEY" environment `shouldBe` Just "test-secret"
      lookup "AWS_SESSION_TOKEN" environment `shouldBe` Just "test-session"
      lookup "AWS_REGION" environment `shouldBe` Just "us-east-1"
      lookup "AWS_DEFAULT_REGION" environment `shouldBe` Just "us-east-1"
      lookup "AWS_EC2_METADATA_DISABLED" environment `shouldBe` Just "true"
      lookup "AWS_SHARED_CREDENTIALS_FILE" environment `shouldBe` Just "/dev/null"
      lookup "AWS_CONFIG_FILE" environment `shouldBe` Just "/dev/null"
      lookup "AWS_SDK_LOAD_CONFIG" environment `shouldBe` Just "0"
      lookup "AWS_PROFILE" environment `shouldBe` Nothing
      lookup "AWS_DEFAULT_PROFILE" environment `shouldBe` Nothing
      lookup "HOME" environment `shouldBe` Nothing
      lookup "PATH" environment `shouldBe` Nothing

    it "omits the session token rather than inheriting one" $ do
      let credentials =
            mustRight
              ( mkDnsAwsCredentials
                  validCredentialInput {dnsCredentialSessionToken = Nothing}
              )
          authority =
            mustRight
              ( authorizeDnsWrite
                  "node-a"
                  (CredentialsReady generationOne credentials)
                  (ContinuityReady continuityFenceOne)
                  (DnsClaimCurrent currentClaimOne)
              )
      lookup "AWS_SESSION_TOKEN" (dnsWriteAwsEnvironment authority) `shouldBe` Nothing

    it "redacts credential secrets from Show output" $ do
      show validCredentialInput `shouldNotContain` "test-secret"
      show validDnsCredentials `shouldNotContain` "test-secret"
      show (mustRight validDnsAuthority) `shouldNotContain` "test-secret"

    it "redacts Orders sources, trust keys, and encoded state from Show output" $ do
      let literalSource = mustRight (preflightOrdersSource validOrdersLimits (validOrdersSource 1))
          admitted = mustRight (admitDecodedOrders literalSource FirstOrdersAdmission (validRawOrders 1))
      show literalSource `shouldNotContain` "trust-key-a"
      show validRawMemberA `shouldNotContain` "trust-key-a"
      show (admittedOrdersMembers admitted) `shouldNotContain` "state-a"
      show admitted `shouldNotContain` "trust-key-a"

childScheduleSuite :: SuiteBuilder ()
childScheduleSuite =
  describe "capacity-one bounded child scheduler" $ do
    it "derives a capacity-one scheduler from the Phase-1 child budget" $ do
      case newCapacityOneChildScheduler phaseOneChildBudget of
        Left err -> expectationFailure (show err)
        Right scheduler -> childSchedulerAvailable scheduler `shouldBe` True

    it "rejects any Phase-1 child budget whose permit count is not one" $ do
      newCapacityOneChildScheduler phaseOneConcurrentChildBudget
        `shouldBe` Left (ChildBudgetPermitCountMustBeOne 2)

    it "rejects a deadline that cannot fit the runtime timeout type" $ do
      let tooLarge = fromIntegral (maxBound :: Int) + 1
          budget =
            mustRuntimeRight
              ( RuntimeMemory.validateChildSchedule
                  RuntimeMemory.BoundedChildSchedule
                    { RuntimeMemory.rawChildPermitCount = 1
                    , RuntimeMemory.rawChildDeadlineMicros = Just tooLarge
                    , RuntimeMemory.rawChildPeakBytes = [100]
                    }
              )
      newCapacityOneChildScheduler budget
        `shouldBe` Left (ChildBudgetDeadlineOutOfRange tooLarge)

    it "rejects missing, zero, oversized, and over-budget timeouts" $ do
      let scheduler = mustRight (newCapacityOneChildScheduler phaseOneChildBudget)
          request = validChildRequest
          maxIntTooLarge = fromIntegral (maxBound :: Int) + 1
          cases =
            [ (request {rawChildRequestTimeoutMicros = Nothing}, ChildRequestTimeoutMissing)
            , (request {rawChildRequestTimeoutMicros = Just 0}, ChildRequestTimeoutMustBePositive)
            ,
              ( request {rawChildRequestTimeoutMicros = Just maxIntTooLarge}
              , ChildRequestTimeoutOutOfRange maxIntTooLarge
              )
            ,
              ( request {rawChildRequestTimeoutMicros = Just 1001}
              , ChildRequestTimeoutExceedsBudget 1001 1000
              )
            ]
      forM_ cases $ \(invalidRequest, expectedError) ->
        scheduleChild scheduler invalidRequest `shouldBe` Left expectedError

    it "rejects missing, zero, and over-budget child peaks" $ do
      let scheduler = mustRight (newCapacityOneChildScheduler phaseOneChildBudget)
          request = validChildRequest
          cases =
            [ (request {rawChildRequestPeakBytes = Nothing}, ChildRequestPeakMissing)
            , (request {rawChildRequestPeakBytes = Just 0}, ChildRequestPeakMustBePositive)
            ,
              ( request {rawChildRequestPeakBytes = Just 201}
              , ChildRequestPeakExceedsBudget 201 200
              )
            ]
      forM_ cases $ \(invalidRequest, expectedError) ->
        scheduleChild scheduler invalidRequest `shouldBe` Left expectedError

    it "rejects an empty child action name" $ do
      let scheduler = mustRight (newCapacityOneChildScheduler phaseOneChildBudget)
      scheduleChild scheduler validChildRequest {rawChildRequestName = " "}
        `shouldBe` Left ChildRequestNameMustNotBeEmpty

    it "issues a finite interpreter input and holds the only permit" $ do
      let scheduler = mustRight (newCapacityOneChildScheduler phaseOneChildBudget)
      case scheduleChild scheduler validChildRequest of
        Left err -> expectationFailure (show err)
        Right (scheduled, heldScheduler) -> do
          scheduledChildName scheduled `shouldBe` "route53-change"
          scheduledChildTimeoutMicros scheduled `shouldBe` 900
          scheduledChildPeakBytes scheduled `shouldBe` 150
          scheduledChildLeaseId scheduled `shouldBe` 1
          childSchedulerAvailable heldScheduler `shouldBe` False
          scheduleChild heldScheduler validChildRequest
            `shouldBe` Left (ChildPermitAlreadyHeld "route53-change")

    it "releases only the matching active lease and advances lease ids" $ do
      let idle = mustRight (newCapacityOneChildScheduler phaseOneChildBudget)
          (firstChild, heldFirst) = mustRight (scheduleChild idle validChildRequest)
          released = mustRight (completeChild heldFirst firstChild)
          (secondChild, heldSecond) = mustRight (scheduleChild released validChildRequest)
      scheduledChildLeaseId secondChild `shouldBe` 2
      completeChild heldSecond firstChild
        `shouldBe` Left (ChildLeaseDoesNotMatch 2 1)
      let releasedSecond = mustRight (completeChild heldSecond secondChild)
      childSchedulerAvailable releasedSecond `shouldBe` True
      completeChild releasedSecond secondChild `shouldBe` Left ChildPermitNotHeld

validOrdersLimits :: OrdersLimits
validOrdersLimits =
  OrdersLimits
    { ordersMaxRawBytes = 4096
    , ordersMaxMembers = 2
    , ordersMaxNodeIdBytes = 64
    , ordersMaxEndpointBytes = 256
    , ordersMaxTrustKeyBytes = 128
    , ordersMaxEncodedStateBytes = 512
    }

validRawMembers :: [RawOrdersMember]
validRawMembers =
  [validRawMemberA, validRawMemberB]

validRawMemberA :: RawOrdersMember
validRawMemberA =
  RawOrdersMember
    { node_id = "node-a"
    , endpoint = "https://node-a:8444"
    , trust_key = "trust-key-a"
    , encoded_state = "state-a"
    }

validRawMemberB :: RawOrdersMember
validRawMemberB =
  RawOrdersMember
    { node_id = "node-b"
    , endpoint = "https://node-b:8444"
    , trust_key = "trust-key-b"
    , encoded_state = "state-b"
    }

validRawOrders :: Natural -> RawOrdersDocument
validRawOrders version =
  RawOrdersDocument
    { version_utc = version
    , members = validRawMembers
    , ranked_members = ["node-a", "node-b"]
    , heartbeat_timeout_seconds = 5
    }

validOrdersSource :: Natural -> Text
validOrdersSource version =
  Text.unlines
    [ "{ version_utc = " <> Text.pack (show version)
    , ", members ="
    , "  [ { node_id = \"node-a\""
    , "    , endpoint = \"https://node-a:8444\""
    , "    , trust_key = \"trust-key-a\""
    , "    , encoded_state = \"state-a\""
    , "    }"
    , "  , { node_id = \"node-b\""
    , "    , endpoint = \"https://node-b:8444\""
    , "    , trust_key = \"trust-key-b\""
    , "    , encoded_state = \"state-b\""
    , "    }"
    , "  ]"
    , ", ranked_members = [ \"node-a\", \"node-b\" ]"
    , ", heartbeat_timeout_seconds = 5"
    , "}"
    ]

equivalentOrdersSource :: Natural -> Text
equivalentOrdersSource version =
  Text.unlines
    [ "{ heartbeat_timeout_seconds = 5"
    , ", ranked_members = [ \"node-a\", \"node-b\" ]"
    , ", members ="
    , "  [ { encoded_state = \"state-b\", trust_key = \"trust-key-b\", endpoint = \"https://node-b:8444\", node_id = \"node-b\" }"
    , "  , { trust_key = \"trust-key-a\", node_id = \"node-a\", encoded_state = \"state-a\", endpoint = \"https://node-a:8444\" }"
    , "  ]"
    , ", version_utc = " <> Text.pack (show version)
    , "}"
    ]

validCredentialInput :: DnsCredentialInput
validCredentialInput =
  DnsCredentialInput
    { dnsCredentialAccessKeyId = "AKIA_TEST"
    , dnsCredentialSecretAccessKey = "test-secret"
    , dnsCredentialSessionToken = Just "test-session"
    , dnsCredentialRegion = "us-east-1"
    }

generationOne :: CredentialGeneration
generationOne = mustRight (mkCredentialGeneration 1)

validDnsCredentials :: DnsAwsCredentials
validDnsCredentials = mustRight (mkDnsAwsCredentials validCredentialInput)

continuityFenceOne :: ContinuityFence
continuityFenceOne = mustRight (mkContinuityFence 1 0 "hash-1")

currentClaimOne :: CurrentDnsClaim
currentClaimOne =
  mustRight (mkCurrentDnsClaim "node-a" generationOne continuityFenceOne)

validDnsAuthority :: Either DnsAuthorityError DnsWriteAuthorized
validDnsAuthority =
  authorizeDnsWrite
    "node-a"
    (CredentialsReady generationOne validDnsCredentials)
    (ContinuityReady continuityFenceOne)
    (DnsClaimCurrent currentClaimOne)

validDnsRequest :: Either DnsAuthorityError DnsWriteRequest
validDnsRequest =
  mkDnsWriteRequest
    "Z123"
    "gateway.example.test"
    60
    "us-east-1"
    "203.0.113.10"

phaseOneChildBudget :: RuntimeMemory.ChildProcessBudget
phaseOneChildBudget =
  mustRuntimeRight
    ( RuntimeMemory.validateChildSchedule
        RuntimeMemory.BoundedChildSchedule
          { RuntimeMemory.rawChildPermitCount = 1
          , RuntimeMemory.rawChildDeadlineMicros = Just 1000
          , RuntimeMemory.rawChildPeakBytes = [100, 200]
          }
    )

phaseOneConcurrentChildBudget :: RuntimeMemory.ChildProcessBudget
phaseOneConcurrentChildBudget =
  mustRuntimeRight
    ( RuntimeMemory.validateChildSchedule
        RuntimeMemory.BoundedChildSchedule
          { RuntimeMemory.rawChildPermitCount = 2
          , RuntimeMemory.rawChildDeadlineMicros = Just 1000
          , RuntimeMemory.rawChildPeakBytes = [100, 100]
          }
    )

validChildRequest :: RawChildRequest
validChildRequest =
  RawChildRequest
    { rawChildRequestName = "route53-change"
    , rawChildRequestTimeoutMicros = Just 900
    , rawChildRequestPeakBytes = Just 150
    }

mustRight :: (Show err) => Either err value -> value
mustRight result =
  case result of
    Left err -> error ("invalid test fixture: " ++ show err)
    Right value -> value

mustRuntimeRight
  :: Either RuntimeMemory.RuntimeMemoryError value -> value
mustRuntimeRight = mustRight

isJust :: Maybe value -> Bool
isJust maybeValue =
  case maybeValue of
    Nothing -> False
    Just _ -> True

isDhallDecodeFailure :: Either OrdersAdmissionError value -> Bool
isDhallDecodeFailure result =
  case result of
    Left (OrdersDhallDecodeFailed _) -> True
    _ -> False
