-- | Read-only facade for a Lifecycle-Authority-retained Provider AWS-scope
-- proof.  The constructor and all raw receipt decoders remain package-private;
-- callers can inspect only a proof recovered by an Authority-owned reader.
module Prodbox.ControlPlane.ProviderAwsScopeReceipt
  ( VerifiedAuthorityProviderAwsScope
  , verifiedAuthorityProviderAwsScopeAccountId
  , verifiedAuthorityProviderAwsScopeRegion
  , verifiedAuthorityProviderAwsScopeRevision
  , verifiedAuthorityProviderAwsScopeOperationId
  , verifiedAuthorityProviderAwsScopeCoordinate
  , AuthorityProviderAwsScopeReader
  , readBackVerifiedAuthorityProviderAwsScope
  , ProviderAwsScopeReceiptError (..)
  )
where

import Prodbox.ControlPlane.ProviderAwsScopeReceipt.Internal
  ( AuthorityProviderAwsScopeReader
  , ProviderAwsScopeReceiptError (..)
  , VerifiedAuthorityProviderAwsScope
  , readBackVerifiedAuthorityProviderAwsScope
  , verifiedAuthorityProviderAwsScopeAccountId
  , verifiedAuthorityProviderAwsScopeCoordinate
  , verifiedAuthorityProviderAwsScopeOperationId
  , verifiedAuthorityProviderAwsScopeRegion
  , verifiedAuthorityProviderAwsScopeRevision
  )
