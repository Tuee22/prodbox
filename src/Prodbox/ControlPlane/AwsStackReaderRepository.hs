-- | Read-only facade for Lifecycle-Authority-retained AWS stack-reader
-- bundles.  Repository construction, canonical bundle decoding, and proof
-- reminting live in the package-private Internal module.  Public consumers can
-- only use an already-bound client and inspect opaque committed values.
module Prodbox.ControlPlane.AwsStackReaderRepository
  ( AwsStackReaderSubmissionKey
  , awsStackReaderSubmissionKeyText
  , AwsStackReaderAuthorityIdentity
  , awsStackReaderAuthorityIdentity
  , awsStackReaderAuthoritySubmissionKey
  , awsStackReaderAuthorityRunId
  , awsStackReaderAuthorityGraphDigest
  , awsStackReaderAuthorityOperationId
  , awsStackReaderAuthorityKey
  , awsStackReaderAuthorityCoordinateDigest
  , awsStackReaderAuthorityScope
  , awsStackReaderAuthorityLogicalName
  , maximumAwsStackReaderAuthorityIdentityBytes
  , encodeAwsStackReaderAuthorityIdentity
  , decodeAwsStackReaderAuthorityIdentity
  , AwsStackReaderCommitResult (..)
  , AwsStackReaderError (..)
  , maximumAwsStackReaderBytes
  , CommittedAwsStackReaderBundle
  , committedAwsStackReaderIdentity
  , committedAwsStackReaderDecisionInputs
  , committedAwsStackReaderProviderBinding
  , AwsStackReaderClient
  , commitAwsStackReaderBundleAttempt
  , independentlyReadBackCommittedAwsStackReaderBundle
  , commitAndReadBackAwsStackReaderBundle
  , readBackAwsStackDecisionInputs
  , readBackAwsStackProviderBinding
  , AwsStackReaderClientError (..)
  , nonAuthorizingAwsStackReaderDiagnosticClient
  )
where

import Prodbox.ControlPlane.AwsStackReaderRepository.Internal
  ( AwsStackReaderAuthorityIdentity
  , AwsStackReaderClient
  , AwsStackReaderClientError (..)
  , AwsStackReaderCommitResult (..)
  , AwsStackReaderError (..)
  , AwsStackReaderSubmissionKey
  , CommittedAwsStackReaderBundle
  , awsStackReaderAuthorityCoordinateDigest
  , awsStackReaderAuthorityGraphDigest
  , awsStackReaderAuthorityIdentity
  , awsStackReaderAuthorityKey
  , awsStackReaderAuthorityLogicalName
  , awsStackReaderAuthorityOperationId
  , awsStackReaderAuthorityRunId
  , awsStackReaderAuthorityScope
  , awsStackReaderAuthoritySubmissionKey
  , awsStackReaderSubmissionKeyText
  , commitAndReadBackAwsStackReaderBundle
  , commitAwsStackReaderBundleAttempt
  , committedAwsStackReaderDecisionInputs
  , committedAwsStackReaderIdentity
  , committedAwsStackReaderProviderBinding
  , decodeAwsStackReaderAuthorityIdentity
  , encodeAwsStackReaderAuthorityIdentity
  , independentlyReadBackCommittedAwsStackReaderBundle
  , maximumAwsStackReaderAuthorityIdentityBytes
  , maximumAwsStackReaderBytes
  , nonAuthorizingAwsStackReaderDiagnosticClient
  , readBackAwsStackDecisionInputs
  , readBackAwsStackProviderBinding
  )
