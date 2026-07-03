{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Lib.Storage
  ( ChartStorageBinding (..)
  , ChartStorageSpec (..)
  , StaticEbsVolumeBinding (..)
  , chartEbsPersistentVolumeManifest
  , chartEbsStorageManifest
  , chartStorageClassName
  , chartPersistentVolumeManifest
  , chartStorageManifest
  , defaultChartDataRootRelative
  , renderStorageReport
  , retainedStatefulSetPersistentVolumeClaimName
  , retainedStatefulSetPersistentVolumeName
  , storageBinding
  , testCaseDataRoot
  , testDataRootRelative
  , testManualPvHostRootEnv
  )
where

import Data.Aeson
  ( Value
  , object
  , (.=)
  )
import Data.Text qualified as Text
import Prodbox.Naming
  ( boundedResourceName
  )
import System.FilePath ((</>))

chartStorageClassName :: String
chartStorageClassName = "manual"

defaultChartDataRootRelative :: FilePath
defaultChartDataRootRelative = ".data"

testDataRootRelative :: FilePath
testDataRootRelative = ".test-data"

testManualPvHostRootEnv :: String
testManualPvHostRootEnv = "PRODBOX_TEST_MANUAL_PV_HOST_ROOT"

testCaseDataRoot :: FilePath -> FilePath
testCaseDataRoot caseId = testDataRootRelative </> caseId

data ChartStorageSpec = ChartStorageSpec
  { chartStorageSpecStatefulSetName :: String
  , chartStorageSpecPersistentVolumeClaimName :: String
  , chartStorageSpecStorageSize :: String
  , chartStorageSpecOrdinal :: Int
  , chartStorageSpecClaimSuffix :: String
  }
  deriving (Eq, Show)

data ChartStorageBinding = ChartStorageBinding
  { chartStorageBindingStatefulSetName :: String
  , chartStorageBindingReleaseName :: String
  , chartStorageBindingPersistentVolumeName :: String
  , chartStorageBindingPersistentVolumeClaimName :: String
  , chartStorageBindingStorageSize :: String
  , chartStorageBindingHostPath :: FilePath
  , chartStorageBindingOrdinal :: Int
  , chartStorageBindingClaimSuffix :: String
  }
  deriving (Eq, Show)

data StaticEbsVolumeBinding = StaticEbsVolumeBinding
  { staticEbsVolumeBindingPersistentVolumeName :: String
  , staticEbsVolumeBindingVolumeHandle :: String
  , staticEbsVolumeBindingAvailabilityZone :: String
  }
  deriving (Eq, Show)

storageBinding :: FilePath -> String -> String -> ChartStorageSpec -> ChartStorageBinding
storageBinding manualPvRoot namespace releaseName spec =
  ChartStorageBinding
    { chartStorageBindingStatefulSetName = chartStorageSpecStatefulSetName spec
    , chartStorageBindingReleaseName = releaseName
    , chartStorageBindingPersistentVolumeName =
        retainedStatefulSetPersistentVolumeName
          namespace
          (chartStorageSpecStatefulSetName spec)
          (chartStorageSpecOrdinal spec)
    , chartStorageBindingPersistentVolumeClaimName = chartStorageSpecPersistentVolumeClaimName spec
    , chartStorageBindingStorageSize = chartStorageSpecStorageSize spec
    , -- Sprint 4.31: the unified `.data/<namespace>/<StatefulSet>/<ordinal>`
      -- host-path scheme. No per-host machine-id prefix and no `<release>` /
      -- `<claim>` segment — the PVC↔PV identity is carried by `claimRef`.
      chartStorageBindingHostPath =
        manualPvRoot
          </> namespace
          </> chartStorageSpecStatefulSetName spec
          </> show (chartStorageSpecOrdinal spec)
    , chartStorageBindingOrdinal = chartStorageSpecOrdinal spec
    , chartStorageBindingClaimSuffix = chartStorageSpecClaimSuffix spec
    }

retainedStatefulSetPersistentVolumeName :: String -> String -> Int -> String
retainedStatefulSetPersistentVolumeName namespace statefulSetName ordinal =
  Text.unpack
    ( boundedResourceName
        "prodbox-retained"
        ( Text.intercalate
            "-"
            [ Text.pack namespace
            , Text.pack statefulSetName
            ]
        )
        (Text.pack (show ordinal))
    )

retainedStatefulSetPersistentVolumeClaimName :: String -> Int -> String
retainedStatefulSetPersistentVolumeClaimName statefulSetName ordinal =
  "data-" ++ statefulSetName ++ "-" ++ show ordinal

renderStorageReport :: [ChartStorageBinding] -> [String]
renderStorageReport bindings =
  concatMap renderBinding bindings
 where
  renderBinding binding =
    [ "STORAGE_BINDING"
    , "RELEASE=" ++ chartStorageBindingReleaseName binding
    , "STATEFULSET=" ++ chartStorageBindingStatefulSetName binding
    , "ORDINAL=" ++ show (chartStorageBindingOrdinal binding)
    , "CLAIM=" ++ chartStorageBindingClaimSuffix binding
    , "PV=" ++ chartStorageBindingPersistentVolumeName binding
    , "PVC=" ++ chartStorageBindingPersistentVolumeClaimName binding
    , "HOST_PATH=" ++ chartStorageBindingHostPath binding
    ]

chartStorageManifest :: String -> String -> [ChartStorageBinding] -> String -> Value
chartStorageManifest namespace rootChart bindings nodeHostname =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("List" :: String)
    , "items" .= (namespaceItem : storageClassItem : concatMap bindingItems bindings)
    ]
 where
  namespaceItem =
    namespaceManifestItem namespace rootChart

  storageClassItem =
    storageClassManifestItem

  bindingItems binding =
    [ persistentVolumeManifestItem namespace rootChart nodeHostname binding
    , object
        [ "apiVersion" .= ("v1" :: String)
        , "kind" .= ("PersistentVolumeClaim" :: String)
        , "metadata"
            .= object
              [ "name" .= chartStorageBindingPersistentVolumeClaimName binding
              , "namespace" .= namespace
              , "labels"
                  .= object
                    [ "prodbox.io/chart-root" .= rootChart
                    , "prodbox.io/statefulset" .= chartStorageBindingStatefulSetName binding
                    ]
              ]
        , "spec"
            .= object
              [ "accessModes" .= ["ReadWriteOnce" :: String]
              , "volumeMode" .= ("Filesystem" :: String)
              , "storageClassName" .= chartStorageClassName
              , "volumeName" .= chartStorageBindingPersistentVolumeName binding
              , "resources"
                  .= object
                    [ "requests"
                        .= object
                          [ "storage" .= chartStorageBindingStorageSize binding
                          ]
                    ]
              ]
        ]
    ]

chartPersistentVolumeManifest :: String -> String -> [ChartStorageBinding] -> String -> Value
chartPersistentVolumeManifest namespace rootChart bindings nodeHostname =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("List" :: String)
    , "items"
        .= ( namespaceManifestItem namespace rootChart
               : storageClassManifestItem
               : map (persistentVolumeManifestItem namespace rootChart nodeHostname) bindings
           )
    ]

chartEbsStorageManifest
  :: String -> String -> [ChartStorageBinding] -> [StaticEbsVolumeBinding] -> Either String Value
chartEbsStorageManifest namespace rootChart bindings ebsVolumes = do
  pairs <- staticEbsVolumeBindingsFor bindings ebsVolumes
  pure
    ( object
        [ "apiVersion" .= ("v1" :: String)
        , "kind" .= ("List" :: String)
        , "items" .= (namespaceItem : storageClassItem : concatMap bindingItems pairs)
        ]
    )
 where
  namespaceItem =
    namespaceManifestItem namespace rootChart

  storageClassItem =
    storageClassManifestItem

  bindingItems (binding, ebsVolume) =
    [ persistentEbsVolumeManifestItem namespace rootChart binding ebsVolume
    , object
        [ "apiVersion" .= ("v1" :: String)
        , "kind" .= ("PersistentVolumeClaim" :: String)
        , "metadata"
            .= object
              [ "name" .= chartStorageBindingPersistentVolumeClaimName binding
              , "namespace" .= namespace
              , "labels"
                  .= object
                    [ "prodbox.io/chart-root" .= rootChart
                    , "prodbox.io/statefulset" .= chartStorageBindingStatefulSetName binding
                    ]
              ]
        , "spec"
            .= object
              [ "accessModes" .= ["ReadWriteOnce" :: String]
              , "volumeMode" .= ("Filesystem" :: String)
              , "storageClassName" .= chartStorageClassName
              , "volumeName" .= chartStorageBindingPersistentVolumeName binding
              , "resources"
                  .= object
                    [ "requests"
                        .= object
                          [ "storage" .= chartStorageBindingStorageSize binding
                          ]
                    ]
              ]
        ]
    ]

chartEbsPersistentVolumeManifest
  :: String -> String -> [ChartStorageBinding] -> [StaticEbsVolumeBinding] -> Either String Value
chartEbsPersistentVolumeManifest namespace rootChart bindings ebsVolumes = do
  pairs <- staticEbsVolumeBindingsFor bindings ebsVolumes
  pure
    ( object
        [ "apiVersion" .= ("v1" :: String)
        , "kind" .= ("List" :: String)
        , "items"
            .= ( namespaceManifestItem namespace rootChart
                   : storageClassManifestItem
                   : map (uncurry (persistentEbsVolumeManifestItem namespace rootChart)) pairs
               )
        ]
    )

staticEbsVolumeBindingsFor
  :: [ChartStorageBinding]
  -> [StaticEbsVolumeBinding]
  -> Either String [(ChartStorageBinding, StaticEbsVolumeBinding)]
staticEbsVolumeBindingsFor bindings ebsVolumes =
  mapM matchVolume bindings
 where
  matchVolume binding =
    let pvName = chartStorageBindingPersistentVolumeName binding
        matches =
          [ ebsVolume
          | ebsVolume <- ebsVolumes
          , staticEbsVolumeBindingPersistentVolumeName ebsVolume == pvName
          ]
     in case matches of
          [ebsVolume] -> Right (binding, ebsVolume)
          [] -> Left ("missing retained EBS volume for persistent volume " ++ pvName)
          _ -> Left ("multiple retained EBS volumes matched persistent volume " ++ pvName)

namespaceManifestItem :: String -> String -> Value
namespaceManifestItem namespace rootChart =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("Namespace" :: String)
    , "metadata"
        .= object
          [ "name" .= namespace
          , "labels"
              .= object
                [ "prodbox.io/chart-root" .= rootChart
                ]
          ]
    ]

storageClassManifestItem :: Value
storageClassManifestItem =
  object
    [ "apiVersion" .= ("storage.k8s.io/v1" :: String)
    , "kind" .= ("StorageClass" :: String)
    , "metadata"
        .= object
          [ "name" .= chartStorageClassName
          , "labels"
              .= object
                [ "prodbox.io/chart-platform" .= ("true" :: String)
                ]
          ]
    , "provisioner" .= ("kubernetes.io/no-provisioner" :: String)
    , "reclaimPolicy" .= ("Retain" :: String)
    , "volumeBindingMode" .= ("WaitForFirstConsumer" :: String)
    , "allowVolumeExpansion" .= True
    ]

persistentVolumeManifestItem :: String -> String -> String -> ChartStorageBinding -> Value
persistentVolumeManifestItem namespace rootChart nodeHostname binding =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("PersistentVolume" :: String)
    , "metadata"
        .= object
          [ "name" .= chartStorageBindingPersistentVolumeName binding
          , "labels"
              .= object
                [ "prodbox.io/chart-root" .= rootChart
                , "prodbox.io/chart-namespace" .= namespace
                , "prodbox.io/statefulset" .= chartStorageBindingStatefulSetName binding
                ]
          ]
    , "spec"
        .= object
          [ "capacity"
              .= object
                [ "storage" .= chartStorageBindingStorageSize binding
                ]
          , "volumeMode" .= ("Filesystem" :: String)
          , "accessModes" .= ["ReadWriteOnce" :: String]
          , "persistentVolumeReclaimPolicy" .= ("Retain" :: String)
          , "storageClassName" .= chartStorageClassName
          , "claimRef"
              .= object
                [ "namespace" .= namespace
                , "name" .= chartStorageBindingPersistentVolumeClaimName binding
                ]
          , "hostPath"
              .= object
                [ "path" .= chartStorageBindingHostPath binding
                , "type" .= ("DirectoryOrCreate" :: String)
                ]
          , "nodeAffinity"
              .= object
                [ "required"
                    .= object
                      [ "nodeSelectorTerms"
                          .= [ object
                                 [ "matchExpressions"
                                     .= [ object
                                            [ "key" .= ("kubernetes.io/hostname" :: String)
                                            , "operator" .= ("In" :: String)
                                            , "values" .= [nodeHostname]
                                            ]
                                        ]
                                 ]
                             ]
                      ]
                ]
          ]
    ]

persistentEbsVolumeManifestItem
  :: String -> String -> ChartStorageBinding -> StaticEbsVolumeBinding -> Value
persistentEbsVolumeManifestItem namespace rootChart binding ebsVolume =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("PersistentVolume" :: String)
    , "metadata"
        .= object
          [ "name" .= chartStorageBindingPersistentVolumeName binding
          , "labels"
              .= object
                [ "prodbox.io/chart-root" .= rootChart
                , "prodbox.io/chart-namespace" .= namespace
                , "prodbox.io/statefulset" .= chartStorageBindingStatefulSetName binding
                ]
          ]
    , "spec"
        .= object
          [ "capacity"
              .= object
                [ "storage" .= chartStorageBindingStorageSize binding
                ]
          , "volumeMode" .= ("Filesystem" :: String)
          , "accessModes" .= ["ReadWriteOnce" :: String]
          , "persistentVolumeReclaimPolicy" .= ("Retain" :: String)
          , "storageClassName" .= chartStorageClassName
          , "claimRef"
              .= object
                [ "namespace" .= namespace
                , "name" .= chartStorageBindingPersistentVolumeClaimName binding
                ]
          , "csi"
              .= object
                [ "driver" .= ("ebs.csi.aws.com" :: String)
                , "volumeHandle" .= staticEbsVolumeBindingVolumeHandle ebsVolume
                , "fsType" .= ("ext4" :: String)
                ]
          , "nodeAffinity"
              .= object
                [ "required"
                    .= object
                      [ "nodeSelectorTerms"
                          .= [ object
                                 [ "matchExpressions"
                                     .= [ object
                                            [ "key" .= ("topology.ebs.csi.aws.com/zone" :: String)
                                            , "operator" .= ("In" :: String)
                                            , "values" .= [staticEbsVolumeBindingAvailabilityZone ebsVolume]
                                            ]
                                        ]
                                 ]
                             ]
                      ]
                ]
          ]
    ]
