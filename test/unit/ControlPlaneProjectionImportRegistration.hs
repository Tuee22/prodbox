{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneProjectionImportRegistration
  ( controlPlaneProjectionImportRegistrationSuite
  )
where

import Data.ByteString.Lazy qualified as LazyByteString
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (ControlPlaneRequestInvalid, ControlPlaneRequestTooLarge)
  )
import Prodbox.ControlPlane.ProjectionImportRegistration
import Prodbox.Lifecycle.Authority.ProjectionImport
  ( migrationProjectionCoordinate
  , productionReplacementProjectionCoordinates
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCodec (..)
  , mkLongLivedCheckpointAuthority
  , modelBObjectLogicalName
  )
import Prodbox.Lifecycle.Lease (defaultSesLeasePolicy)
import TestSupport

controlPlaneProjectionImportRegistrationSuite :: SuiteBuilder ()
controlPlaneProjectionImportRegistrationSuite =
  describe "Sprint 4.50 sealed projection-import registration" $ do
    it "round-trips a bounded canonical registration and constructs the exact production plan" $ do
      registration <- acceptedRegistration validWire
      decodeProjectionImportRegistration
        "home-control"
        (encodeProjectionImportRegistration registration)
        `shouldBe` Right registration
      let codec = projectionImportRegistrationModelBCodec "home-control"
      encoded <- expectRight (encodeModelBValue codec registration)
      decodeModelBValue codec encoded `shouldBe` Right registration
      plan <-
        expectRight $
          productionProjectionImportFromRegistration
            legacyAuthority
            replacementAuthority
            defaultSesLeasePolicy
            registration
      let replacement = productionReplacementProjectionCoordinates plan
      fmap
        (modelBObjectLogicalName . migrationProjectionCoordinate replacement)
        [minBound .. maxBound]
        `shouldBe` [ "leases/123456789012/ca-central-1/aws-ses"
                   , "pulumi-stack/aws-ses"
                   , "target-commit-intents/123456789012/ca-central-1/aws-ses"
                   , "smtp-commit/123456789012/ca-central-1/aws-ses"
                   ]
      coordinate <-
        expectRight $
          projectionImportRegistrationCoordinate replacementAuthority
      modelBObjectLogicalName coordinate
        `shouldBe` "authority/projection-import-registration"

    it "refuses invalid account, region, capacity, lane, and missing local registration" $ do
      expectRegistrationError
        (validWire {projectionImportAwsAccountId = "1234"})
        ProjectionImportRegistrationAccountInvalid
      expectRegistrationError
        (validWire {projectionImportAwsRegion = "CA Central 1"})
        ProjectionImportRegistrationRegionInvalid
      expectRegistrationError
        (validWire {projectionImportTargetCapacity = 3})
        (ProjectionImportRegistrationCapacityMismatch 3 2)
      expectRegistrationError
        ( validWire
            { projectionImportTargets =
                [ homeTarget {projectionImportTargetKvPath = "other/path"}
                , awsTarget
                ]
            }
        )
        (ProjectionImportRegistrationTargetLaneInvalid 0)
      expectRegistrationError
        ( validWire
            { projectionImportTargetCapacity = 1
            , projectionImportTargets = [awsTarget]
            }
        )
        ProjectionImportRegistrationLocalTargetMissing

    it "distinguishes malformed and oversized sealed registration bytes" $ do
      decodeProjectionImportRegistration "home-control" "not-cbor"
        `shouldBe` Left
          (ProjectionImportRegistrationCodecInvalid ControlPlaneRequestInvalid)
      decodeProjectionImportRegistration
        "home-control"
        (LazyByteString.replicate (fromIntegral projectionImportRegistrationMaximumBytes + 1) 0)
        `shouldBe` Left
          (ProjectionImportRegistrationCodecInvalid ControlPlaneRequestTooLarge)

    it "redacts account and target coordinates from diagnostics" $ do
      registration <- acceptedRegistration validWire
      show validWire `shouldNotContain` "123456789012"
      show validWire `shouldNotContain` "target-secret-agent"
      show registration `shouldNotContain` "123456789012"
      show registration `shouldNotContain` "target-secret-agent"

acceptedRegistration
  :: ProjectionImportRegistrationWire
  -> IO ProjectionImportRegistration
acceptedRegistration wire =
  expectRight $
    mkProjectionImportRegistration "home-control" wire

expectRight :: (Show err) => Either err value -> IO value
expectRight result = case result of
  Left failure -> do
    expectationFailure (show failure)
    error "unreachable after expectation failure"
  Right value -> pure value

expectRegistrationError
  :: ProjectionImportRegistrationWire
  -> ProjectionImportRegistrationError
  -> IO ()
expectRegistrationError wire expected =
  case mkProjectionImportRegistration "home-control" wire of
    Left actual -> actual `shouldBe` expected
    Right _ -> expectationFailure "expected projection-import registration refusal"

validWire :: ProjectionImportRegistrationWire
validWire =
  ProjectionImportRegistrationWire
    { projectionImportAwsAccountId = "123456789012"
    , projectionImportAwsRegion = "ca-central-1"
    , projectionImportTargetCapacity = 2
    , projectionImportTargets = [homeTarget, awsTarget]
    }

homeTarget :: ProjectionImportTargetRegistrationWire
homeTarget =
  ProjectionImportTargetRegistrationWire
    { projectionImportTargetIdentity = "home-control"
    , projectionImportTargetVaultMount = "secret"
    , projectionImportTargetKvPath = "keycloak/smtp"
    }

awsTarget :: ProjectionImportTargetRegistrationWire
awsTarget =
  ProjectionImportTargetRegistrationWire
    { projectionImportTargetIdentity = "aws-eks-test-cluster"
    , projectionImportTargetVaultMount = "secret"
    , projectionImportTargetKvPath = "keycloak/smtp"
    }

legacyAuthority :: LongLivedCheckpointAuthority
legacyAuthority =
  either (error . show) id $
    mkLongLivedCheckpointAuthority
      "home-control"
      "prodbox-state"
      "lifecycle"
      "secret/lifecycle"

replacementAuthority :: LongLivedCheckpointAuthority
replacementAuthority =
  either (error . show) id $
    mkLongLivedCheckpointAuthority
      "home-control"
      "prodbox-state"
      "authority"
      "secret/lifecycle"
