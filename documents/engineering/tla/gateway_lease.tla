---- MODULE gateway_lease ----
EXTENDS Naturals, FiniteSets

CONSTANTS Nodes, LeaseDuration, NoNode

ASSUME /\ Nodes # {}
       /\ LeaseDuration \in Nat \ {0}
       /\ NoNode \notin Nodes

NodeOrNone == Nodes \cup {NoNode}

VARIABLES
    now,
    owner,
    leaseEpoch,
    leaseExpiry,
    dnsOwner,
    dnsEpoch,
    alive

vars ==
    << now, owner, leaseEpoch, leaseExpiry, dnsOwner, dnsEpoch, alive >>

Init ==
    /\ now = 0
    /\ owner = NoNode
    /\ leaseEpoch = 0
    /\ leaseExpiry = 0
    /\ dnsOwner = NoNode
    /\ dnsEpoch = 0
    /\ alive = Nodes

LeaseExpired ==
    now >= leaseExpiry

LeaseActive ==
    /\ owner \in Nodes
    /\ ~LeaseExpired

Acquire(n) ==
    /\ n \in alive
    /\ n \in Nodes
    /\ (owner = NoNode \/ LeaseExpired)
    /\ owner' = n
    /\ leaseEpoch' = leaseEpoch + 1
    /\ leaseExpiry' = now + LeaseDuration
    /\ UNCHANGED << now, dnsOwner, dnsEpoch, alive >>

Renew(n) ==
    /\ n \in alive
    /\ n = owner
    /\ LeaseActive
    /\ leaseExpiry' = now + LeaseDuration
    /\ UNCHANGED << now, owner, leaseEpoch, dnsOwner, dnsEpoch, alive >>

ProjectDNS(n) ==
    /\ n \in alive
    /\ n = owner
    /\ LeaseActive
    /\ dnsOwner' = n
    /\ dnsEpoch' = leaseEpoch
    /\ UNCHANGED << now, owner, leaseEpoch, leaseExpiry, alive >>

Crash(n) ==
    /\ n \in alive
    /\ n \in Nodes
    /\ alive' = alive \ {n}
    /\ UNCHANGED << now, owner, leaseEpoch, leaseExpiry, dnsOwner, dnsEpoch >>

Recover(n) ==
    /\ n \in Nodes
    /\ n \notin alive
    /\ alive' = alive \cup {n}
    /\ UNCHANGED << now, owner, leaseEpoch, leaseExpiry, dnsOwner, dnsEpoch >>

Tick ==
    /\ now' = now + 1
    /\ UNCHANGED << owner, leaseEpoch, leaseExpiry, dnsOwner, dnsEpoch, alive >>

Next ==
    \/ Tick
    \/ \E n \in Nodes:
        \/ Acquire(n)
        \/ Renew(n)
        \/ ProjectDNS(n)
        \/ Crash(n)
        \/ Recover(n)

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(Tick)
    /\ \A n \in Nodes:
        /\ WF_vars(Acquire(n))
        /\ WF_vars(Renew(n))
        /\ WF_vars(ProjectDNS(n))

ValidGatewayNodes ==
    {n \in Nodes: owner = n /\ now < leaseExpiry}

MutualExclusion ==
    Cardinality(ValidGatewayNodes) <= 1

LeaseEpochDominatesDNS ==
    dnsEpoch <= leaseEpoch

DNSProjectionMatchesLeaderOrIsStale ==
    /\ dnsOwner \in NodeOrNone
    /\ dnsEpoch <= leaseEpoch

AnyAlive ==
    alive # {}

EventuallySomeLeader ==
    []((AnyAlive /\ LeaseExpired) => <> (owner \in Nodes /\ now < leaseExpiry))

THEOREM Spec => []MutualExclusion
THEOREM Spec => []LeaseEpochDominatesDNS

=============================================================================
