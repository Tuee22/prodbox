{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Typed chart-render inputs for the per-emitter stable workload, journal
-- mount, and Kubernetes Lease fence. Sprint 2.32 owns this protocol contract;
-- Sprint 3.26 consumes it when rendering the physically separated workloads.
module Prodbox.Gateway.Emitter.Persistence
  ( EmitterController (..)
  , JournalAccess (..)
  , EmitterPersistenceBinding
  , mkEmitterPersistenceBinding
  , persistenceNodeId
  , persistenceController
  , persistenceJournalMountPath
  , persistenceJournalAccess
  , persistenceLeaseName
  , persistenceServiceAccountName
  , emitterPersistenceValues
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Gateway.Emitter.Lease
  ( LeaseName
  , leaseNameText
  , mkLeaseName
  )
import Prodbox.Substrate (Substrate (..), substrateId)
import System.FilePath ((</>))

data EmitterController = EmitterStatefulSet
  deriving stock (Eq, Show)

-- The AWS constructor is the phase-2 claim-side render contract only. Sprint
-- 3.26 owns the physical PV, Retain reclaim policy, and concrete EBS volume
-- identity; none of those physical coordinates are guessed or rendered here.
data JournalAccess
  = HomeNodePinnedHostPath !FilePath
  | AwsRetainedEbsClaim
      { journalClaimName :: !Text
      , journalStorageClassName :: !Text
      , journalAccessMode :: !Text
      , journalRequestedStorage :: !Text
      }
  deriving stock (Eq, Show)

data EmitterPersistenceBinding = EmitterPersistenceBinding
  { persistenceNodeId :: !Text
  , persistenceController :: !EmitterController
  , persistenceJournalMountPath :: !FilePath
  , persistenceJournalAccess :: !JournalAccess
  , persistenceLeaseName :: !LeaseName
  , persistenceServiceAccountName :: !Text
  }
  deriving stock (Eq, Show)

journalMountPath :: FilePath
journalMountPath = "/var/lib/prodbox/gateway-emitter"

homeJournalRoot :: FilePath
homeJournalRoot = "/var/lib/prodbox/gateway-emitter-journals"

mkEmitterPersistenceBinding
  :: Substrate
  -> Text
  -> Either String EmitterPersistenceBinding
mkEmitterPersistenceBinding substrate rawNode = do
  nodeLabel <- either (Left . show) Right (mkLeaseName rawNode)
  lease <-
    either
      (Left . show)
      Right
      (mkLeaseName ("prodbox-emitter-" <> leaseNameText nodeLabel))
  let node = leaseNameText nodeLabel
      access = case substrate of
        SubstrateHomeLocal ->
          HomeNodePinnedHostPath (homeJournalRoot </> Text.unpack node)
        SubstrateAws ->
          AwsRetainedEbsClaim
            { journalClaimName = "gateway-" <> node <> "-emitter-journal"
            , journalStorageClassName = "manual"
            , journalAccessMode = "ReadWriteOncePod"
            , journalRequestedStorage = "1Gi"
            }
  Right
    EmitterPersistenceBinding
      { persistenceNodeId = node
      , persistenceController = EmitterStatefulSet
      , persistenceJournalMountPath = journalMountPath
      , persistenceJournalAccess = access
      , persistenceLeaseName = lease
      , persistenceServiceAccountName = "prodbox-gateway-daemon"
      }

emitterPersistenceValues :: Substrate -> [Text] -> Either String Value
emitterPersistenceValues substrate rawNodes = do
  bindings <- traverse (mkEmitterPersistenceBinding substrate) rawNodes
  ensureUniqueBindings bindings
  Right
    ( object
        [ "substrate" .= substrateId substrate
        , "controllerKind" .= ("StatefulSet" :: Text)
        , "journalMountPath" .= journalMountPath
        , "lease"
            .= object
              [ "apiVersion" .= ("coordination.k8s.io/v1" :: Text)
              , "resource" .= ("leases" :: Text)
              , "verbs" .= (["get", "create", "update"] :: [Text])
              ]
        , "nodes" .= map bindingValue bindings
        ]
    )

ensureUniqueBindings :: [EmitterPersistenceBinding] -> Either String ()
ensureUniqueBindings bindings = do
  ensureUnique "normalized node identity" (map persistenceNodeId bindings)
  ensureUnique "Lease coordinate" (map (leaseNameText . persistenceLeaseName) bindings)
  ensureUnique "journal storage coordinate" (map journalStorageCoordinate bindings)
 where
  ensureUnique label values
    | Set.size (Set.fromList values) == length values = Right ()
    | otherwise = Left ("duplicate or colliding " ++ label)

journalStorageCoordinate :: EmitterPersistenceBinding -> Text
journalStorageCoordinate binding = case persistenceJournalAccess binding of
  HomeNodePinnedHostPath path -> Text.pack path
  AwsRetainedEbsClaim claim _ _ _ -> claim

bindingValue :: EmitterPersistenceBinding -> Value
bindingValue binding =
  object
    [ "nodeId" .= persistenceNodeId binding
    , "leaseName" .= leaseNameText (persistenceLeaseName binding)
    , "serviceAccountName" .= persistenceServiceAccountName binding
    , "journal" .= accessValue (persistenceJournalAccess binding)
    ]

accessValue :: JournalAccess -> Value
accessValue access = case access of
  HomeNodePinnedHostPath path ->
    object
      [ "kind" .= ("nodePinnedHostPath" :: Text)
      , "hostPath" .= path
      ]
  AwsRetainedEbsClaim claim storageClass accessMode requestedStorage ->
    object
      [ "kind" .= ("retainedEbsClaim" :: Text)
      , "claimName" .= claim
      , "storageClassName" .= storageClass
      , "accessMode" .= accessMode
      , "requestedStorage" .= requestedStorage
      ]
