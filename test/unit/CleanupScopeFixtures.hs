{-# LANGUAGE OverloadedStrings #-}

module CleanupScopeFixtures (fixtureHomeDns01Scope, fixtureInviteMailScope) where

import Data.List.NonEmpty (NonEmpty (..))
import Prodbox.Lifecycle.DnsRecord (mkHostedZoneId)
import Prodbox.Lifecycle.Teardown.ResourceScopeBindings
import Prodbox.Settings.Coordinate (mkS3BucketName)

fixtureHomeDns01Scope :: HomeDns01Scope
fixtureHomeDns01Scope = must (mkHomeDns01Scope (must (mkHostedZoneId "ZPARENTEXAMPLE")) ("auth.example.test" :| []))

fixtureInviteMailScope :: InviteMailScope
fixtureInviteMailScope =
  must
    ( mkInviteMailScope
        (must (mkS3BucketName "fixture-capture-mail"))
        (ExactInviteRecipient "test-abc123@receive.example.test")
    )

must :: (Show error) => Either error value -> value
must = either (error . show) id
