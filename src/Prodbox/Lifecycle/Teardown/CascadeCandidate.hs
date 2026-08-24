-- | Non-authorizing diagnostics for the non-public recover-to-clean cascade
-- candidate entrypoint.  The inputs record, the resolved plan, the program
-- descriptor, both closed runtimes, and the drive itself remain
-- package-private, so holding one of these booleans authorizes nothing and
-- cannot start a cascade.
--
-- Sprint @6.5@ owns activating the entrypoint as the sole public writer and
-- deleting the legacy route it replaces.
module Prodbox.Lifecycle.Teardown.CascadeCandidate
  ( CascadeCandidateRegression
  , fixedCascadeCandidateRegression
  , cascadeCandidatePlanIsDeterministic
  , cascadeCandidateTerminalOperationIsCompiled
  , cascadeCandidateDeclaredLeaseIsRequired
  , cascadeCandidateIdentityBindsDescriptor
  , CascadeCandidatePlanSummary (..)
  , fixedCascadeCandidatePlanSummary
  )
where

import Prodbox.Lifecycle.Teardown.CascadeCandidate.Internal
