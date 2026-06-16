module Prodbox.PostgresPlatform
  ( patroniClusterName
  , patroniCredentialsSecretName
  , patroniDatabaseName
  , patroniFsGroup
  , patroniOperatorDeploymentName
  , patroniOperatorNamespace
  , patroniOperatorReleaseName
  , patroniPersistentVolumeClaimName
  , patroniPostgresqlCrdName
  , patroniPrimaryServiceName
  , patroniPrimaryServiceHost
  , patroniReplicaServiceName
  , patroniReplicaServiceHost
  , patroniRunAsGroup
  , patroniRunAsUser
  , patroniStorageSpecs
  , patroniStorageSize
  , patroniStandbySecretName
  , patroniSuperuserSecretName
  , patroniTeamId
  , patroniUsername
  , patroniVaultMaterializerServiceAccountName
  )
where

import Data.Text qualified as Text
import Prodbox.Lib.Storage
  ( ChartStorageSpec (..)
  )
import Prodbox.Naming (boundedResourceName)

patroniOperatorNamespace :: String
patroniOperatorNamespace = "postgres-operator"

patroniOperatorReleaseName :: String
patroniOperatorReleaseName = "postgres-operator"

patroniOperatorDeploymentName :: String
patroniOperatorDeploymentName = patroniOperatorReleaseName

patroniPostgresqlCrdName :: String
patroniPostgresqlCrdName = "perconapgclusters.pgv2.percona.com"

patroniTeamId :: String
patroniTeamId = "prodbox"

patroniDatabaseName :: String
patroniDatabaseName = "keycloak"

patroniUsername :: String
patroniUsername = "keycloak"

patroniStorageSize :: String
patroniStorageSize = "20Gi"

patroniRunAsUser :: Int
patroniRunAsUser = 1001

patroniRunAsGroup :: Int
patroniRunAsGroup = 1001

patroniFsGroup :: Int
patroniFsGroup = 1001

patroniClusterName :: String -> String
patroniClusterName rootChart =
  Text.unpack
    (boundedResourceName (Text.pack patroniTeamId) (Text.pack rootChart) (Text.pack "pg"))

patroniPrimaryServiceName :: String -> String
patroniPrimaryServiceName rootChart =
  patroniClusterName rootChart ++ "-ha"

patroniReplicaServiceName :: String -> String
patroniReplicaServiceName rootChart =
  patroniClusterName rootChart ++ "-replicas"

patroniPrimaryServiceHost :: String -> String -> String
patroniPrimaryServiceHost namespace rootChart =
  patroniPrimaryServiceName rootChart ++ "." ++ namespace ++ ".svc.cluster.local"

patroniReplicaServiceHost :: String -> String -> String
patroniReplicaServiceHost namespace rootChart =
  patroniReplicaServiceName rootChart ++ "." ++ namespace ++ ".svc.cluster.local"

patroniPersistentVolumeClaimName :: String -> Int -> String
patroniPersistentVolumeClaimName rootChart ordinal =
  patroniClusterName rootChart ++ "-instance1-" ++ show ordinal ++ "-pgdata"

patroniStorageSpecs :: String -> [ChartStorageSpec]
patroniStorageSpecs rootChart =
  map mkSpec [0 .. 2]
 where
  clusterName = patroniClusterName rootChart

  mkSpec ordinal =
    ChartStorageSpec
      { chartStorageSpecStatefulSetName = clusterName
      , chartStorageSpecPersistentVolumeClaimName = patroniPersistentVolumeClaimName rootChart ordinal
      , chartStorageSpecStorageSize = patroniStorageSize
      , chartStorageSpecOrdinal = ordinal
      , chartStorageSpecClaimSuffix = "data"
      }

patroniCredentialsSecretName :: String -> String
patroniCredentialsSecretName rootChart =
  Text.unpack
    ( boundedResourceName
        (Text.pack (patroniClusterName rootChart))
        (Text.pack "pguser")
        (Text.pack patroniUsername)
    )

patroniSuperuserSecretName :: String -> String
patroniSuperuserSecretName rootChart =
  Text.unpack
    ( boundedResourceName
        (Text.pack (patroniClusterName rootChart))
        (Text.pack "pguser")
        (Text.pack "postgres")
    )

patroniStandbySecretName :: String -> String
patroniStandbySecretName rootChart =
  Text.unpack
    ( boundedResourceName
        (Text.pack (patroniClusterName rootChart))
        (Text.pack "primaryuser")
        Text.empty
    )

patroniVaultMaterializerServiceAccountName :: String -> String
patroniVaultMaterializerServiceAccountName namespace =
  patroniClusterName namespace
