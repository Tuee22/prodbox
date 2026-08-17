-- | Public host cleanup journal boundary.
--
-- Persistent phase mutation and the run-wide execution lease remain in the
-- library-internal implementation consumed by 'HostCleanupRunner'.  Public
-- callers can prepare an unbound descriptor, persist an already-opaque Ready
-- proof, observe canonical state, and retire an exactly completed run, but
-- cannot advance terminal phases around the runner's proof checks.
module Prodbox.Lifecycle.HostCleanupIntent
  ( HostCleanupIntentStore
  , mkHostCleanupIntentStore
  , hostCleanupIntentRetainedRoot
  , hostCleanupIntentPath
  , hostCleanupIntentRetiredPath
  , hostCleanupIntentFormatVersion
  , maximumHostCleanupIntentBytes
  , HostCleanupScope
  , mkHostCleanupScope
  , hostCleanupFoundationId
  , hostCleanupObservationRunScope
  , hostCleanupObservationEvidenceScope
  , HostTerminalPermitId
  , mkHostTerminalPermitId
  , hostTerminalPermitIdText
  , HostCleanupTerminalIdentity
  , mkHostCleanupTerminalIdentity
  , hostCleanupTerminalOperationId
  , hostCleanupTerminalPermitId
  , HostCleanupReadyBinding
  , hostCleanupReadyRunId
  , hostCleanupReadyGraphDigest
  , hostCleanupReadyScope
  , hostCleanupReadyReportDigest
  , hostCleanupReadyPermitId
  , hostCleanupReadyUninstallOperationId
  , hostCleanupReadyCompletionOperationId
  , HostCleanupIntentPhase (..)
  , HostCleanupIntent
  , mkHostCleanupIntent
  , hostCleanupRunId
  , hostCleanupGraphDigest
  , hostCleanupRun
  , hostCleanupScope
  , hostCleanupTerminalIdentity
  , hostCleanupReadyBinding
  , hostCleanupIntentPhase
  , hostCleanupCompletionReceiptDigest
  , bindHostCleanupReady
  , hostCleanupReadyMatches
  , advanceHostCleanupIntent
  , encodeHostCleanupIntent
  , decodeHostCleanupIntent
  , ObservedHostCleanupIntent
  , observedHostCleanupIntent
  , restoreObservedHostCleanupReady
  , observeHostCleanupIntentForResume
  , observeHostCleanupIntent
  , prepareHostCleanupIntent
  , persistHostCleanupReady
  , HostCleanupIntentRetirementDigest
  , hostCleanupIntentRetirementDigestText
  , HostCleanupIntentRetirement (..)
  , retireHostCleanupIntent
  , HostCleanupIntentRegression
  , fixedHostCleanupIntentRegression
  , hostCleanupIntentRegressionBoundCodec
  , hostCleanupIntentRegressionBoundPreparationRefused
  , hostCleanupIntentRegressionReadyReadBack
  , hostCleanupIntentRegressionPhaseReplay
  , hostCleanupIntentRegressionRetirementReplay
  , HostCleanupIntentError (..)
  )
where

import Prodbox.Lifecycle.HostCleanupIntent.Internal
  ( HostCleanupIntent
  , HostCleanupIntentError (..)
  , HostCleanupIntentPhase (..)
  , HostCleanupIntentRegression
  , HostCleanupIntentRetirement (..)
  , HostCleanupIntentRetirementDigest
  , HostCleanupIntentStore
  , HostCleanupReadyBinding
  , HostCleanupScope
  , HostCleanupTerminalIdentity
  , HostTerminalPermitId
  , ObservedHostCleanupIntent
  , advanceHostCleanupIntent
  , bindHostCleanupReady
  , decodeHostCleanupIntent
  , encodeHostCleanupIntent
  , fixedHostCleanupIntentRegression
  , hostCleanupCompletionReceiptDigest
  , hostCleanupFoundationId
  , hostCleanupGraphDigest
  , hostCleanupIntentFormatVersion
  , hostCleanupIntentPath
  , hostCleanupIntentPhase
  , hostCleanupIntentRegressionBoundCodec
  , hostCleanupIntentRegressionBoundPreparationRefused
  , hostCleanupIntentRegressionPhaseReplay
  , hostCleanupIntentRegressionReadyReadBack
  , hostCleanupIntentRegressionRetirementReplay
  , hostCleanupIntentRetainedRoot
  , hostCleanupIntentRetiredPath
  , hostCleanupIntentRetirementDigestText
  , hostCleanupObservationEvidenceScope
  , hostCleanupObservationRunScope
  , hostCleanupReadyBinding
  , hostCleanupReadyCompletionOperationId
  , hostCleanupReadyGraphDigest
  , hostCleanupReadyMatches
  , hostCleanupReadyPermitId
  , hostCleanupReadyReportDigest
  , hostCleanupReadyRunId
  , hostCleanupReadyScope
  , hostCleanupReadyUninstallOperationId
  , hostCleanupRun
  , hostCleanupRunId
  , hostCleanupScope
  , hostCleanupTerminalIdentity
  , hostCleanupTerminalOperationId
  , hostCleanupTerminalPermitId
  , hostTerminalPermitIdText
  , maximumHostCleanupIntentBytes
  , mkHostCleanupIntent
  , mkHostCleanupIntentStore
  , mkHostCleanupScope
  , mkHostCleanupTerminalIdentity
  , mkHostTerminalPermitId
  , observeHostCleanupIntent
  , observeHostCleanupIntentForResume
  , observedHostCleanupIntent
  , persistHostCleanupReady
  , prepareHostCleanupIntent
  , restoreObservedHostCleanupReady
  , retireHostCleanupIntent
  )
