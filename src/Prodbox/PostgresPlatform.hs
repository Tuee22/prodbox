module Prodbox.PostgresPlatform
  ( patroniClusterName
  , patroniCredentialsSecretName
  , patroniDatabaseName
  , patroniFsGroup
  , patroniOperatorDeploymentName
  , patroniOperatorNamespace
  , patroniOperatorReleaseName
  , patroniPostgresqlCrdName
  , patroniPrimaryServiceHost
  , patroniReplicaServiceHost
  , patroniRunAsGroup
  , patroniRunAsUser
  , patroniStorageSize
  , patroniStandbySecretName
  , patroniSuperuserSecretName
  , patroniTeamId
  , patroniUsername
  )
where

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
patroniClusterName rootChart = patroniTeamId ++ "-" ++ rootChart ++ "-pg"

patroniPrimaryServiceHost :: String -> String -> String
patroniPrimaryServiceHost namespace rootChart =
  patroniClusterName rootChart ++ "-ha." ++ namespace ++ ".svc.cluster.local"

patroniReplicaServiceHost :: String -> String -> String
patroniReplicaServiceHost namespace rootChart =
  patroniClusterName rootChart ++ "-replicas." ++ namespace ++ ".svc.cluster.local"

patroniCredentialsSecretName :: String -> String
patroniCredentialsSecretName rootChart =
  patroniClusterName rootChart ++ "-pguser-" ++ patroniUsername

patroniSuperuserSecretName :: String -> String
patroniSuperuserSecretName rootChart =
  patroniClusterName rootChart ++ "-pguser-postgres"

patroniStandbySecretName :: String -> String
patroniStandbySecretName rootChart =
  patroniClusterName rootChart ++ "-primaryuser"
