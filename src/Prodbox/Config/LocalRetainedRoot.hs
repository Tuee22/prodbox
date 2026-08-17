-- | The local retained-storage root used while recovering the one home RKE2
-- substrate.  The bootstrap value is deliberately non-authorizing: it can
-- locate already-established storage, but only a fresh authenticated Operator
-- projection can upgrade it to an Authority-bound root.
module Prodbox.Config.LocalRetainedRoot
  ( BootstrapRetainedRootLocator
  , AuthorityBoundRetainedRoot
  , LocalRetainedRootEntry (..)
  , LocalRetainedRootError (..)
  , RetainedRootMarkerReconcileOutcome (..)
  , bootstrapRetainedRootLocatorPath
  , authorityBoundRetainedRootPath
  , authorityBoundRetainedRootInForceConfig
  , renderLocalRetainedRootError
  , renderRetainedRootMarkerReconcileOutcome
  , locateBootstrapRetainedRoot
  , reconcileAuthorityBoundRetainedRootMarker
  , reobserveAuthorityBoundRetainedRoot
  , LocalRetainedRootFixtureRegression
  , fixedLocalRetainedRootFixtureRegression
  , localRetainedRootFixtureMarkerRoundTrips
  , localRetainedRootFixtureMarkerLengthFramed
  , localRetainedRootFixtureMismatchRefused
  , localRetainedRootFixtureLegacyRequiresAuthority
  , localRetainedRootFixtureLayoutClosed
  )
where

import Prodbox.Config.LocalRetainedRoot.Internal
