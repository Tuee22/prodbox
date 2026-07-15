{-# LANGUAGE ImportQualifiedPost #-}

-- | Sprint 1.63 conformance-tier suite: the legacy-escape registry ↔ source
-- bijection. Pure tables prove both directions of the bijection against
-- synthetic scanned files; the final case proves the committed registry is
-- seeded exactly from the current call sites (so @prodbox dev check@ stays
-- green).
module EscapeRegistry
  ( escapeRegistrySuite
  )
where

import Data.List (isInfixOf)
import Prodbox.CheckCode (checkLegacyEscapeRegistry)
import Prodbox.Legacy.EscapeRegistry
  ( escapeMarkerClose
  , escapeMarkerOpen
  , escapeRegistryViolations
  , escapeSiteFile
  , escapeSiteMarker
  , registeredLegacyEscapeSites
  )
import System.Directory (getCurrentDirectory)
import TestSupport

-- | Render a source marker comment for a given id, using the module's own
-- split delimiters so this test file never contains a literal, scannable
-- marker token.
markerComment :: String -> String
markerComment markerId =
  "-- " ++ escapeMarkerOpen ++ markerId ++ escapeMarkerClose ++ "\n"

-- | A synthetic scan in which every registered site carries exactly its
-- declared marker at its declared file.
greenScannedFiles :: [(FilePath, String)]
greenScannedFiles =
  [ (escapeSiteFile site, markerComment (escapeSiteMarker site))
  | site <- registeredLegacyEscapeSites
  ]

firstRegisteredMarker :: String
firstRegisteredMarker =
  case registeredLegacyEscapeSites of
    (site : _) -> escapeSiteMarker site
    [] -> ""

firstRegisteredFile :: FilePath
firstRegisteredFile =
  case registeredLegacyEscapeSites of
    (site : _) -> escapeSiteFile site
    [] -> ""

escapeRegistrySuite :: SuiteBuilder ()
escapeRegistrySuite =
  describe "Sprint 1.63 legacy escape registry (conformance tier)" $ do
    it "is green when every registered marker sits at its declared call site" $
      escapeRegistryViolations greenScannedFiles `shouldBe` []

    it "flags an unregistered marker discovered in source" $ do
      let files = ("src/Prodbox/BrandNew.hs", markerComment "brand-new-escape") : greenScannedFiles
      escapeRegistryViolations files
        `shouldSatisfy` any ("unregistered legacy-escape marker" `isInfixOf`)

    it "flags a registered entry whose call site has disappeared" $ do
      let files =
            [ (escapeSiteFile site, markerComment (escapeSiteMarker site))
            | site <- registeredLegacyEscapeSites
            , escapeSiteMarker site /= firstRegisteredMarker
            ]
      escapeRegistryViolations files
        `shouldSatisfy` any ("has no surviving" `isInfixOf`)

    it "flags a registered marker discovered in the wrong file" $ do
      let files =
            [ ( if escapeSiteMarker site == firstRegisteredMarker
                  then "src/Prodbox/WrongPlace.hs"
                  else escapeSiteFile site
              , markerComment (escapeSiteMarker site)
              )
            | site <- registeredLegacyEscapeSites
            ]
      escapeRegistryViolations files
        `shouldSatisfy` any ("but the registry declares" `isInfixOf`)

    it "flags a registered marker appearing at more than one call site" $ do
      let files = (firstRegisteredFile, markerComment firstRegisteredMarker) : greenScannedFiles
      escapeRegistryViolations files
        `shouldSatisfy` any ("is registered once but appears at" `isInfixOf`)

    it "matches the real repository (registry seeded from the current call sites)" $ do
      repoRoot <- getCurrentDirectory
      violations <- checkLegacyEscapeRegistry repoRoot
      violations `shouldBe` []
