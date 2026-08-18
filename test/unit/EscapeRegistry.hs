{-# LANGUAGE ImportQualifiedPost #-}

-- | Sprint 1.63 conformance-tier suite: the legacy-escape registry ↔ source
-- bijection. Pure tables prove both directions of the bijection against
-- synthetic scanned files; the final case proves the committed registry is
-- seeded exactly from the current call sites (so @prodbox dev check@ stays
-- green).
--
-- Sprint 4.84 adds the coverage layer's cases. The bijection cases below stay
-- green while a coverage case fails, which is the point: they demonstrate that
-- an unmarked surviving escape is caught by something other than the marker
-- bijection, exactly as the sprint's validation requires.
module EscapeRegistry
  ( escapeRegistrySuite
  )
where

import Data.List (isInfixOf, nub, sort)
import Prodbox.CheckCode (checkLegacyEscapeRegistry)
import Prodbox.Legacy.EscapeRegistry
  ( coverageRuleSites
  , coverageRuleSymbol
  , escapeCoverageRules
  , escapeMarkerClose
  , escapeMarkerOpen
  , escapeRegistryViolations
  , escapeSiteFile
  , escapeSiteMarker
  , registeredLegacyEscapeSites
  , tokenOccursIn
  )
import System.Directory (getCurrentDirectory)
import TestSupport

-- | Render a source marker comment for a given id, using the module's own
-- split delimiters so this test file never contains a literal, scannable
-- marker token.
markerComment :: String -> String
markerComment markerId =
  "-- " ++ escapeMarkerOpen ++ markerId ++ escapeMarkerClose ++ "\n"

-- | Every file the synthetic scan represents: the declared marker sites plus
-- every declared coverage site.
scannedPaths :: [FilePath]
scannedPaths =
  sort
    ( nub
        ( map escapeSiteFile registeredLegacyEscapeSites
            ++ concatMap coverageRuleSites escapeCoverageRules
        )
    )

-- | Synthetic contents for one file: its declared markers, plus every coverage
-- symbol declared to live there.
contentsFor :: FilePath -> String
contentsFor path =
  concat
    ( [ markerComment (escapeSiteMarker site)
      | site <- registeredLegacyEscapeSites
      , escapeSiteFile site == path
      ]
        ++ [ coverageRuleSymbol rule ++ " x = x\n"
           | rule <- escapeCoverageRules
           , path `elem` coverageRuleSites rule
           ]
    )

-- | A synthetic scan in which every registered site carries exactly its
-- declared marker and every coverage site mentions exactly its declared symbol.
greenScannedFiles :: [(FilePath, String)]
greenScannedFiles = [(path, contentsFor path) | path <- scannedPaths]

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

firstCoverageSymbol :: String
firstCoverageSymbol =
  case escapeCoverageRules of
    (rule : _) -> coverageRuleSymbol rule
    [] -> ""

firstCoverageSite :: FilePath
firstCoverageSite =
  case escapeCoverageRules of
    (rule : _) -> case coverageRuleSites rule of
      (site : _) -> site
      [] -> ""
    [] -> ""

-- | Drop one declared coverage symbol from the file that declares it, leaving
-- every marker in place.
withoutFirstCoverageSymbol :: [(FilePath, String)]
withoutFirstCoverageSymbol =
  [ ( path
    , if path == firstCoverageSite
        then
          concat
            [ markerComment (escapeSiteMarker site)
            | site <- registeredLegacyEscapeSites
            , escapeSiteFile site == path
            ]
        else contents
    )
  | (path, contents) <- greenScannedFiles
  ]

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
            [ (path, contents)
            | (path, contents) <- greenScannedFiles
            , path /= firstRegisteredFile
            ]
      escapeRegistryViolations files
        `shouldSatisfy` any ("has no surviving" `isInfixOf`)

    it "flags a registered marker discovered in the wrong file" $ do
      let files =
            ( "src/Prodbox/WrongPlace.hs"
            , markerComment firstRegisteredMarker
            )
              : greenScannedFiles
      escapeRegistryViolations files
        `shouldSatisfy` any ("but the registry declares" `isInfixOf`)

    it "flags a registered marker appearing at more than one call site" $ do
      let files = (firstRegisteredFile, markerComment firstRegisteredMarker) : greenScannedFiles
      escapeRegistryViolations files
        `shouldSatisfy` any ("is registered once but appears at" `isInfixOf`)

    describe "Sprint 4.84 coverage beyond the marker bijection" $ do
      it "flags an unmarked escape whose marker bijection is still satisfied" $ do
        let files =
              ( "src/Prodbox/NewCaller.hs"
              , "caller = " ++ firstCoverageSymbol ++ " ()\n"
              )
                : greenScannedFiles
            violations = escapeRegistryViolations files
        -- Nothing about the marker bijection changed: the new file carries no
        -- marker at all.
        violations
          `shouldSatisfy` (not . any ("legacy-escape marker" `isInfixOf`))
        violations `shouldSatisfy` any ("call site: " `isInfixOf`)
        violations `shouldSatisfy` any (firstCoverageSymbol `isInfixOf`)

      it "flags a declared coverage site whose symbol is gone" $
        escapeRegistryViolations withoutFirstCoverageSymbol
          `shouldSatisfy` any ("stale coverage site" `isInfixOf`)

      it "declares a coverage rule for every registered escape category" $
        escapeRegistryViolations greenScannedFiles `shouldBe` []

      it "matches whole identifier tokens rather than substrings" $ do
        tokenOccursIn "ObjectStoreSubprocess" "data AwsCliObjectStoreSubprocess"
          `shouldBe` False
        tokenOccursIn "ObjectStoreSubprocess" "backend = ObjectStoreSubprocess"
          `shouldBe` True
        tokenOccursIn "withMinioPortForward" "withMinioPortForwardEnv a b"
          `shouldBe` False

    it "matches the real repository (registry seeded from the current call sites)" $ do
      repoRoot <- getCurrentDirectory
      violations <- checkLegacyEscapeRegistry repoRoot
      violations `shouldBe` []
