-- Test-topology schema for Sprint 1.54.
--
-- The Haskell mirror lives in Prodbox.TestTopology, with decode entrypoints in
-- Prodbox.Settings. This Dhall file owns the pure authored-test-run vocabulary
-- and contract predicates that prodbox.test.dhall documents can import.

let Cluster = ./cluster/Schema.dhall

let FixtureId =
      < AwsAdminForTestSimulation | AcmeEab | VaultUnlockBundle >

let FailoverScenario = < LeaderKill | NetworkPartition >

let Budget =
      { max_nodes : Natural
      , wall_clock_seconds : Natural
      }

let RunVariant =
      { cluster : Cluster.ClusterTopology
      , replicas : Natural
      , failover : Optional FailoverScenario
      }

let Suite =
      { name : Text
      , variants : List RunVariant
      , budget : Budget
      , fixtures : List FixtureId
      }

let TestTopology =
      { suites : List Suite
      , fixtures : List FixtureId
      }

let lessOrEq =
      \(a : Natural) ->
      \(b : Natural) ->
        Natural/isZero (Natural/subtract b a)

let positive =
      \(n : Natural) ->
        if Natural/isZero n then False else True

let fixtureEq =
      \(left : FixtureId) ->
      \(right : FixtureId) ->
        merge
          { AwsAdminForTestSimulation =
              merge
                { AwsAdminForTestSimulation = True
                , AcmeEab = False
                , VaultUnlockBundle = False
                }
                right
          , AcmeEab =
              merge
                { AwsAdminForTestSimulation = False
                , AcmeEab = True
                , VaultUnlockBundle = False
                }
                right
          , VaultUnlockBundle =
              merge
                { AwsAdminForTestSimulation = False
                , AcmeEab = False
                , VaultUnlockBundle = True
                }
                right
          }
          left

let fixtureDeclared =
      \(declared : List FixtureId) ->
      \(fixture : FixtureId) ->
        List/fold
          FixtureId
          declared
          Bool
          (\(candidate : FixtureId) -> \(ok : Bool) -> fixtureEq candidate fixture || ok)
          False

let fixturesDeclared =
      \(declared : List FixtureId) ->
      \(fixtures : List FixtureId) ->
        List/fold
          FixtureId
          fixtures
          Bool
          (\(fixture : FixtureId) -> \(ok : Bool) -> fixtureDeclared declared fixture && ok)
          True

let variantFitsWithin =
      \(budget : Budget) ->
      \(variant : RunVariant) ->
            positive variant.replicas
        &&  lessOrEq variant.replicas budget.max_nodes
        &&  Cluster.contractOK variant.cluster

let variantsOK =
      \(budget : Budget) ->
      \(variants : List RunVariant) ->
        List/fold
          RunVariant
          variants
          Bool
          (\(variant : RunVariant) -> \(ok : Bool) -> variantFitsWithin budget variant && ok)
          True

let variantsNonEmpty =
      \(variants : List RunVariant) ->
        positive (List/length RunVariant variants)

let budgetOK =
      \(budget : Budget) ->
            positive budget.max_nodes
        &&  positive budget.wall_clock_seconds

let suiteOK =
      \(declared : List FixtureId) ->
      \(suite : Suite) ->
            variantsNonEmpty suite.variants
        &&  budgetOK suite.budget
        &&  variantsOK suite.budget suite.variants
        &&  fixturesDeclared declared suite.fixtures

let suitesOK =
      \(topology : TestTopology) ->
        List/fold
          Suite
          topology.suites
          Bool
          (\(suite : Suite) -> \(ok : Bool) -> suiteOK topology.fixtures suite && ok)
          True

let contractOK =
      \(topology : TestTopology) ->
            positive (List/length Suite topology.suites)
        &&  suitesOK topology

let selfMachine =
      { machine_id = "prodbox-home"
      , machine_substrate = Cluster.WorkerSubstrate.LinuxCpu
      , compute_worker =
          { worker_substrate = Cluster.WorkerSubstrate.LinuxCpu
          , manages_all_local_devices = True
          }
      }

let selfVariant =
      { cluster =
          Cluster.ClusterTopology.Rke2 { machines = [ selfMachine ] : List Cluster.Machine }
      , replicas = 1
      , failover = None FailoverScenario
      }

let self =
      { suites =
          [ { name = "unit"
            , variants = [ selfVariant ] : List RunVariant
            , budget = { max_nodes = 1, wall_clock_seconds = 1800 }
            , fixtures = [] : List FixtureId
            }
          ] : List Suite
      , fixtures = [] : List FixtureId
      }

let selfContract =
      assert : contractOK self === True

in  { Cluster = Cluster
    , FixtureId = FixtureId
    , FailoverScenario = FailoverScenario
    , Budget = Budget
    , RunVariant = RunVariant
    , Suite = Suite
    , TestTopology = TestTopology
    , lessOrEq = lessOrEq
    , fixtureEq = fixtureEq
    , fixtureDeclared = fixtureDeclared
    , fixturesDeclared = fixturesDeclared
    , variantFitsWithin = variantFitsWithin
    , variantsOK = variantsOK
    , variantsNonEmpty = variantsNonEmpty
    , budgetOK = budgetOK
    , suiteOK = suiteOK
    , contractOK = contractOK
    }
