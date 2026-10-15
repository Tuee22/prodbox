-- | Where an ephemeral Kubernetes client configuration lives, and whether a path
-- is one.
--
-- A kubeconfig that prodbox mints for another cluster (the EKS cluster of an
-- AWS-substrate run) is written under a private temporary directory by
-- "Prodbox.Lifecycle.Teardown.EphemeralKubectl" and exported through the
-- process's @KUBECONFIG@ for the length of one bracket. The clients of the
-- retained home cluster resolve their own kubeconfig from the home files first
-- and from the ambient @KUBECONFIG@ last, so that a development host whose only
-- kubeconfig is exported still resolves. With both home files unreadable, that
-- last candidate would address EKS during an AWS run and say nothing about the
-- substitution.
--
-- The names are defined here, once, because the creator and the resolver that
-- has to leave the creator's output out must agree on them, and a leaf module is
-- the one place both can import without either importing the other.
module Prodbox.Infra.EphemeralKubeconfigPath
  ( ephemeralKubectlDirectoryPrefix
  , ephemeralKubeconfigFileName
  , isEphemeralKubeconfigPath
  )
where

import Data.List (isPrefixOf)
import System.FilePath (takeDirectory, takeFileName)

-- | The prefix of the private directory an ephemeral kubeconfig is written in.
ephemeralKubectlDirectoryPrefix :: String
ephemeralKubectlDirectoryPrefix = "prodbox-ephemeral-kubectl-"

-- | The kubeconfig's name inside that directory.
ephemeralKubeconfigFileName :: FilePath
ephemeralKubeconfigFileName = "kubeconfig.json"

-- | Whether a path is a kubeconfig of the shape prodbox mints for a cluster that
-- is not the retained home cluster: the creator's file name inside a directory
-- with the creator's prefix. A kubeconfig an operator exported is not of this
-- shape, and a path that has only one of the two marks is not either, so the
-- predicate only ever excludes what prodbox itself made.
isEphemeralKubeconfigPath :: FilePath -> Bool
isEphemeralKubeconfigPath path =
  takeFileName path == ephemeralKubeconfigFileName
    && ephemeralKubectlDirectoryPrefix `isPrefixOf` takeFileName (takeDirectory path)
