{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: the cascade's credential-disposition node, from issued
-- observations to the observation the evidence constructor consumes.
--
-- [Lifecycle Reconciliation Doctrine § 5b node 5](../../../../documents/engineering/lifecycle_reconciliation_doctrine.md#5b-canonical-recover-to-clean-cascade)
-- says the test-scoped EBS and credential nodes reconcile absent only after
-- their exact dependants are terminal, and the sprint requires that an
-- incomplete run retain every credential a nonterminal obligation still needs.
-- 'CascadeCredentialDispositionEvidence' is the proof of that half.  Its
-- constructor existed and nothing produced its input, so the only inhabitant in
-- the repository was the fixture's authored @Disposed@ — a proof about nothing.
--
-- Four properties carry the design.
--
--   * __The disposal set is derived from the credential inventory, not
--     authored.__  It is exactly the classes whose lifetime is
--     'RunScopedCredential'.  A credential class added to the inventory with
--     that lifetime is observed by this node without editing it, and a class
--     with any other lifetime cannot be reached through this boundary at all.
--
--   * __The operational credential is retained, and that is structural.__  A
--     cascade that revoked the Lifecycle-provider credential would fence the
--     terminal audit it had just run, which is why
--     "Prodbox.Lifecycle.Teardown.Program" emits no cascade credential
--     disposition node.  Here the same fact is a consequence of the lifetime
--     partition rather than a second rule: an operational or long-lived class
--     is not in the disposal set, so it is never asked about and can never be
--     reported disposed.
--
--   * __A present credential outranks an unanswered one.__  A class observed
--     still present is outstanding whatever the other observations did, because
--     a positive presence is a fact.  Only when nothing is outstanding does an
--     unanswered class decide the verdict, and then it decides it as
--     unobservable rather than as disposition.  This is the same asymmetry the
--     terminal audit applies to a blind query.
--
--   * __An empty disposal set is a refusal, not a vacuous proof.__  A run whose
--     inventory names no run-scoped credential has nothing this node could
--     establish, and reporting @Disposed@ over an empty set would be a proof
--     about nothing that the readiness composition would then accept.
--
-- The pure kernel folds and lowers.  Observing whether an IAM principal still
-- exists lives behind an injected boundary, and this module deliberately wires
-- no production one: on the AWS substrate that observation is a Provider effect
-- owned by Sprint @7.36@, and reaching for a host-direct IAM call here would
-- add an unregistered escape path.
module Prodbox.Lifecycle.Teardown.CascadeCredentialDisposition
  ( -- * Issuing the observations
    CascadeCredentialDispositionBoundary (..)
  , CredentialPresence (..)
  , cascadeDisposableCredentialClasses
  , cascadeRetainedCredentialClasses

    -- * Producing the observation
  , CascadeCredentialDispositionRefusal (..)
  , renderCascadeCredentialDispositionRefusal
  , foldCascadeCredentialAnswers
  , observeCascadeCredentialDisposition

    -- * Regression over the package-private fixture
  , CascadeCredentialDispositionRegression
  , fixedCascadeCredentialDispositionRegression
  , credentialDispositionRegressionEveryDisposableClassAsked
  , credentialDispositionRegressionOperationalClassRetained
  , credentialDispositionRegressionAbsentSetIsDisposed
  , credentialDispositionRegressionPresentIsOutstanding
  , credentialDispositionRegressionUnansweredIsNotDisposed
  , credentialDispositionRegressionPresentOutranksUnanswered
  , credentialDispositionRegressionDisposedAcceptedByEvidence
  , credentialDispositionRegressionOutstandingRefusedByEvidence
  )
where

import Data.Functor.Identity (Identity (Identity), runIdentity)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (LifecycleProviderCredential)
  , CredentialLifetime (RunScopedCredential)
  , awsCredentialDescriptorClass
  , awsCredentialDescriptorLifetime
  , awsCredentialDescriptorPrincipal
  , managedAwsCredentialInventory
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( CascadeCredentialDispositionObservation (..)
  , CascadeCredentialDispositionResult (..)
  , mkCascadeCredentialDispositionEvidence
  , withFixedCascadeEvidenceFixtureInternal
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , compiledDesiredAbsenceObservationScope
  )
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface (Cascade)
  , ObservationFailure (ObservationFailure)
  )
import Prodbox.Lifecycle.Teardown.Observation
  ( ObservedResourceIdentity (ObservedResourceIdentity)
  )

-- ---------------------------------------------------------------------------
-- Issuing the observations
-- ---------------------------------------------------------------------------

-- | What one exact observation of a credential principal established.
data CredentialPresence
  = -- | The principal is gone.  This is the only answer that disposes.
    CredentialPrincipalAbsent
  | -- | The principal is still there, carrying the identity that was observed
    -- so an incomplete run can name what it found.
    CredentialPrincipalPresent !ObservedResourceIdentity
  deriving (Eq, Show)

-- | The one injected effect: observe whether one credential class's principal
-- still exists.
--
-- It is keyed by class rather than by principal name, because the principal is
-- a field of the inventory entry and re-deriving it at the call site would let
-- the observed name drift from the declared one.
newtype CascadeCredentialDispositionBoundary m
  = CascadeCredentialDispositionBoundary
  { observeCredentialPrincipal
      :: AwsCredentialClass -> m (Either ObservationFailure CredentialPresence)
  }

-- | The classes a cascade disposes: exactly the run-scoped ones.
cascadeDisposableCredentialClasses :: [AwsCredentialClass]
cascadeDisposableCredentialClasses =
  [ awsCredentialDescriptorClass descriptor
  | descriptor <- managedAwsCredentialInventory
  , awsCredentialDescriptorLifetime descriptor == RunScopedCredential
  ]

-- | The complement: every class a cascade retains.
--
-- It is the complement rather than a second list, so a class cannot be omitted
-- from both and quietly become nobody's concern.
cascadeRetainedCredentialClasses :: [AwsCredentialClass]
cascadeRetainedCredentialClasses =
  [ credentialClass
  | credentialClass <- map awsCredentialDescriptorClass managedAwsCredentialInventory
  , credentialClass `notElem` cascadeDisposableCredentialClasses
  ]

-- ---------------------------------------------------------------------------
-- Producing the observation
-- ---------------------------------------------------------------------------

-- | Why no disposition observation could be produced at all.
--
-- A produced observation that found an outstanding credential, or that could
-- not see one, is not a refusal — it is a verdict, and it travels inside the
-- observation as a 'CascadeCredentialDispositionResult'.
data CascadeCredentialDispositionRefusal
  = -- | The inventory names no run-scoped credential, so this node has nothing
    -- to establish.  Reporting disposition over an empty set would be a proof
    -- about nothing.
    CascadeCredentialDispositionNothingToObserve
  deriving (Eq, Show)

renderCascadeCredentialDispositionRefusal
  :: CascadeCredentialDispositionRefusal -> Text
renderCascadeCredentialDispositionRefusal = \case
  CascadeCredentialDispositionNothingToObserve ->
    "the cascade credential disposition refuses: the credential inventory names \
    \no run-scoped class, so this node would prove nothing"

-- | Fold one answer per disposable class into the node's verdict.
--
-- Presence wins, then unanswered, then disposition.  The order is the whole
-- content of the fold: an outstanding credential is a fact that no number of
-- unanswered classes softens, and an unanswered class is never softened into
-- disposition by the classes that did answer.
foldCascadeCredentialAnswers
  :: NonEmpty (AwsCredentialClass, Either ObservationFailure CredentialPresence)
  -> CascadeCredentialDispositionResult
foldCascadeCredentialAnswers answers =
  case NonEmpty.nonEmpty outstanding of
    Just remaining -> CascadeCredentialsOutstanding remaining
    Nothing -> case NonEmpty.nonEmpty unanswered of
      Just failures -> CascadeCredentialDispositionUnobservable failures
      Nothing -> CascadeCredentialsDisposed
 where
  outstanding =
    [ identity
    | (_, Right (CredentialPrincipalPresent identity)) <- NonEmpty.toList answers
    ]
  unanswered =
    [failure | (_, Left failure) <- NonEmpty.toList answers]

-- | Observe every disposable credential class and produce the node's
-- observation.
--
-- The scope is derived from the compiled run rather than authored, so a
-- disposition can never be taken under a scope
-- 'mkCascadeCredentialDispositionEvidence' would then reject for a reason the
-- operator cannot see.
observeCascadeCredentialDisposition
  :: (Monad m)
  => CascadeCredentialDispositionBoundary m
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> m
       ( Either
           CascadeCredentialDispositionRefusal
           CascadeCredentialDispositionObservation
       )
observeCascadeCredentialDisposition boundary compiled =
  case NonEmpty.nonEmpty cascadeDisposableCredentialClasses of
    Nothing -> pure (Left CascadeCredentialDispositionNothingToObserve)
    Just classes -> do
      answers <-
        traverse
          (\credentialClass -> (,) credentialClass <$> observe credentialClass)
          classes
      pure
        ( Right
            CascadeCredentialDispositionObservation
              { cascadeCredentialDispositionScope =
                  compiledDesiredAbsenceObservationScope compiled
              , cascadeCredentialDispositionResult =
                  foldCascadeCredentialAnswers answers
              }
        )
 where
  observe = observeCredentialPrincipal boundary

-- ---------------------------------------------------------------------------
-- Regression over the package-private fixture
-- ---------------------------------------------------------------------------

data CascadeCredentialDispositionRegression
  = CascadeCredentialDispositionRegression
  { credentialDispositionRegressionEveryDisposableClassAsked :: !Bool
  , credentialDispositionRegressionOperationalClassRetained :: !Bool
  , credentialDispositionRegressionAbsentSetIsDisposed :: !Bool
  , credentialDispositionRegressionPresentIsOutstanding :: !Bool
  , credentialDispositionRegressionUnansweredIsNotDisposed :: !Bool
  , credentialDispositionRegressionPresentOutranksUnanswered :: !Bool
  , credentialDispositionRegressionDisposedAcceptedByEvidence :: !Bool
  , credentialDispositionRegressionOutstandingRefusedByEvidence :: !Bool
  }

fixedCascadeCredentialDispositionRegression
  :: IO (Either Text CascadeCredentialDispositionRegression)
fixedCascadeCredentialDispositionRegression =
  case withFixedCascadeEvidenceFixtureInternal
    (\compiled _run _ready _local _complete -> compiled) of
    Left err -> pure (Left err)
    Right compiled -> Right <$> runFixedCredentialDispositionRegression compiled

runFixedCredentialDispositionRegression
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> IO CascadeCredentialDispositionRegression
runFixedCredentialDispositionRegression compiled = do
  asked <- newIORef []
  _ <-
    observeCascadeCredentialDisposition
      ( CascadeCredentialDispositionBoundary
          ( \credentialClass -> do
              modifyIORef' asked (++ [credentialClass])
              pure (Right CredentialPrincipalAbsent)
          )
      )
      compiled
  issued <- readIORef asked
  pure
    CascadeCredentialDispositionRegression
      { -- Every disposable class is asked about, exactly once and in inventory
        -- order, so a class the inventory declares cannot be silently skipped.
        credentialDispositionRegressionEveryDisposableClassAsked =
          issued == cascadeDisposableCredentialClasses
            && not (null issued)
      , -- The credential the cascade must keep live to run its own terminal
        -- audit is not reachable through this boundary at all.
        credentialDispositionRegressionOperationalClassRetained =
          LifecycleProviderCredential `elem` cascadeRetainedCredentialClasses
            && LifecycleProviderCredential `notElem` cascadeDisposableCredentialClasses
      , credentialDispositionRegressionAbsentSetIsDisposed =
          resultOf (const (Right CredentialPrincipalAbsent))
            == Just CascadeCredentialsDisposed
      , credentialDispositionRegressionPresentIsOutstanding =
          isOutstanding (resultOf (const (Right (CredentialPrincipalPresent survivor))))
      , credentialDispositionRegressionUnansweredIsNotDisposed =
          isUnobservable (resultOf (const (Left unreachable)))
      , -- One class present and one class unanswered: the presence decides,
        -- because a positive presence is a fact whatever the other observation
        -- did.
        credentialDispositionRegressionPresentOutranksUnanswered =
          isOutstanding
            ( Just
                ( foldCascadeCredentialAnswers
                    ( NonEmpty.fromList
                        [ (LifecycleProviderCredential, Left unreachable)
                        ,
                          ( LifecycleProviderCredential
                          , Right (CredentialPrincipalPresent survivor)
                          )
                        ]
                    )
                )
            )
      , credentialDispositionRegressionDisposedAcceptedByEvidence =
          acceptedByEvidence (const (Right CredentialPrincipalAbsent))
      , credentialDispositionRegressionOutstandingRefusedByEvidence =
          not
            ( acceptedByEvidence
                (const (Right (CredentialPrincipalPresent survivor)))
            )
      }
 where
  survivor =
    ObservedResourceIdentity
      ( "iam-user/"
          <> Text.intercalate
            ","
            [ awsCredentialDescriptorPrincipal descriptor
            | descriptor <- managedAwsCredentialInventory
            , awsCredentialDescriptorClass descriptor
                `elem` cascadeDisposableCredentialClasses
            ]
      )
  unreachable = ObservationFailure "credential principal could not be observed"

  observationFor answer =
    runIdentity
      ( observeCascadeCredentialDisposition
          (CascadeCredentialDispositionBoundary (Identity . answer))
          compiled
      )

  resultOf answer = case observationFor answer of
    Left _ -> Nothing
    Right observation -> Just (cascadeCredentialDispositionResult observation)

  acceptedByEvidence answer = case observationFor answer of
    Left _ -> False
    Right observation ->
      case mkCascadeCredentialDispositionEvidence compiled observation of
        Left _ -> False
        Right _ -> True

isOutstanding :: Maybe CascadeCredentialDispositionResult -> Bool
isOutstanding = \case
  Just (CascadeCredentialsOutstanding _) -> True
  _ -> False

isUnobservable :: Maybe CascadeCredentialDispositionResult -> Bool
isUnobservable = \case
  Just (CascadeCredentialDispositionUnobservable _) -> True
  _ -> False
