{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.98 witness for the 'ObservationStratum' index on 'AbsenceEvidence'.
--
-- Absence used to be one type. A directory that was not there, a cluster the
-- provider said did not exist, and a Kubernetes read-back that returned nothing
-- all produced the same value, and only the enclosing wrapper types kept them
-- apart — which the reconciliation doctrine admitted in a dated correction. The
-- index makes the separation nominal.
--
-- Three properties are asserted here, and a fourth by the fact that this module
-- and the whole tree compile:
--
--   * TEXT ERASURE. The stratum tag is a fully-erased phantom, so re-tagging
--     could never change what a journal, receipt or wire carries. This matters
--     because 'absenceEvidenceText' is what reaches durable storage.
--   * SEALED CONSTRUCTOR. Every value comes from one of three minting functions
--     named for the authority that observed the absence, so a claim carries its
--     provenance in its type rather than in whichever module happened to build
--     it.
--   * WELL-TYPED PATHS. A provider absence inhabits 'ExactResourceAbsent'; a
--     host-local absence inhabits the local-uninstall position; a Kubernetes
--     absence inhabits the drain read-back position.
--   * COMPILE WITNESS. The ill-typed expressions documented at
--     'compileWitnessRejections' below do not typecheck; uncommenting any of
--     them fails the build. That the production teardown path compiles is the
--     positive half of the same proof.
module AbsenceStratumWitness
  ( absenceStratumWitnessSuite
  , compileWitnessRejections
  )
where

import Data.Text qualified as Text
import Prodbox.Lifecycle.Teardown.Observation
  ( ExactObservationResult (..)
  , absenceEvidenceText
  , hostLocalAbsence
  , kubernetesReadBackAbsence
  , providerWorkerAbsence
  )
import TestSupport

absenceStratumWitnessSuite :: SuiteBuilder ()
absenceStratumWitnessSuite =
  describe "Sprint 4.98 absence-stratum index witness" $ do
    it "erases the stratum tag: identical text across all three strata" $ do
      let sentence = "authoritative-not-found"
      absenceEvidenceText (hostLocalAbsence sentence) `shouldBe` sentence
      absenceEvidenceText (providerWorkerAbsence sentence) `shouldBe` sentence
      absenceEvidenceText (kubernetesReadBackAbsence sentence) `shouldBe` sentence
      -- The three are different types and the same bytes.  Anything durable
      -- that already holds an absence sentence stays byte-identical, which is
      -- why this index could be added without a wire migration.
      absenceEvidenceText (hostLocalAbsence sentence)
        `shouldBe` absenceEvidenceText (kubernetesReadBackAbsence sentence)

    it "admits a provider absence into the exact observation result" $ do
      let evidence = providerWorkerAbsence "provider-worker exact family returned its canonical empty set"
      case ExactResourceAbsent evidence of
        ExactResourceAbsent recovered ->
          absenceEvidenceText recovered
            `shouldBe` "provider-worker exact family returned its canonical empty set"
        _ -> expectationFailure "a provider absence did not inhabit ExactResourceAbsent"

    it "keeps the projection total and the constructor the only way in" $ do
      -- 'absenceEvidenceText' is deliberately stratum-agnostic: rendering an
      -- absence into a receipt is legitimate for any authority.  What is not
      -- legitimate is minting one without saying which authority observed it,
      -- and there is no exported constructor that allows it.
      let long = Text.replicate 64 "x"
      Text.length (absenceEvidenceText (hostLocalAbsence long)) `shouldBe` 64
      absenceEvidenceText (providerWorkerAbsence "") `shouldBe` ""

-- | The cross-stratum expressions this index exists to reject.  Each is
-- commented because each is a type error; uncommenting any one fails the build,
-- which is the assertion.
--
-- The first is the one the sprint names, and it is not hypothetical: before the
-- index, @exactLocalRke2Absence@ — a sentence about this host's filesystem —
-- had exactly the type that @ExactResourceAbsent@ demanded, so nothing stopped
-- a local observation from being presented as proof that an AWS resource was
-- gone.
--
-- > -- A host-local absence in a provider-absence position:
-- > hostInProviderPosition :: ExactObservationResult
-- > hostInProviderPosition = ExactResourceAbsent (hostLocalAbsence "a directory was not there")
--
-- > -- A Kubernetes read-back in a provider-absence position:
-- > kubernetesInProviderPosition :: ExactObservationResult
-- > kubernetesInProviderPosition =
-- >   ExactResourceAbsent (kubernetesReadBackAbsence "no PVCs returned")
--
-- > -- Minting without naming an authority (the constructor is not exported):
-- > unprovenanced :: AbsenceEvidence 'ProviderApi
-- > unprovenanced = AbsenceEvidence "trust me"
--
-- > -- Coercing one stratum to another (there is no conversion in any
-- > -- direction, deliberately):
-- > launder :: AbsenceEvidence 'HostLocal -> AbsenceEvidence 'ProviderApi
-- > launder = id
compileWitnessRejections :: ()
compileWitnessRejections = ()
