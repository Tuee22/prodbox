module Prodbox.PostgresPlatform (
    patroniClusterName,
    patroniCredentialsSecretName,
    patroniDatabaseName,
    patroniFsGroup,
    patroniOperatorDeploymentName,
    patroniOperatorNamespace,
    patroniOperatorReleaseName,
    patroniPostgresqlCrdName,
    patroniPrimaryServiceHost,
    patroniReplicaServiceHost,
    patroniRunAsGroup,
    patroniRunAsUser,
    patroniStorageSize,
    patroniStandbySecretName,
    patroniSuperuserSecretName,
    patroniTeamId,
    patroniUsername,
)
where

patroniOperatorNamespace :: String
patroniOperatorNamespace = "postgres-operator"

patroniOperatorReleaseName :: String
patroniOperatorReleaseName = "postgres-operator"

patroniOperatorDeploymentName :: String
patroniOperatorDeploymentName = patroniOperatorReleaseName

patroniPostgresqlCrdName :: String
patroniPostgresqlCrdName = "postgresqls.acid.zalan.do"

patroniTeamId :: String
patroniTeamId = "prodbox"

patroniDatabaseName :: String
patroniDatabaseName = "keycloak"

patroniUsername :: String
patroniUsername = "keycloak"

patroniStorageSize :: String
patroniStorageSize = "20Gi"

patroniRunAsUser :: Int
patroniRunAsUser = 101

patroniRunAsGroup :: Int
patroniRunAsGroup = 103

patroniFsGroup :: Int
patroniFsGroup = 103

patroniClusterName :: String -> String
patroniClusterName rootChart = patroniTeamId ++ "-" ++ rootChart ++ "-postgres"

patroniPrimaryServiceHost :: String -> String -> String
patroniPrimaryServiceHost namespace rootChart =
    patroniClusterName rootChart ++ "." ++ namespace ++ ".svc.cluster.local"

patroniReplicaServiceHost :: String -> String -> String
patroniReplicaServiceHost namespace rootChart =
    patroniClusterName rootChart ++ "-repl." ++ namespace ++ ".svc.cluster.local"

patroniCredentialsSecretName :: String -> String
patroniCredentialsSecretName rootChart =
    patroniUsername
        ++ "."
        ++ patroniClusterName rootChart
        ++ ".credentials.postgresql.acid.zalan.do"

patroniSuperuserSecretName :: String -> String
patroniSuperuserSecretName rootChart =
    "postgres."
        ++ patroniClusterName rootChart
        ++ ".credentials.postgresql.acid.zalan.do"

patroniStandbySecretName :: String -> String
patroniStandbySecretName rootChart =
    "standby."
        ++ patroniClusterName rootChart
        ++ ".credentials.postgresql.acid.zalan.do"
