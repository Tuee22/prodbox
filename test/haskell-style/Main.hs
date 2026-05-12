module Main (main) where

import Prodbox.CheckCode (haskellStyleViolations)
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import TestSupport

main :: IO ()
main = mainWithSuite "prodbox-haskell-style" $ do
  describe "repo style invariants" $ do
    it "has no repository-specific Haskell style violations" $ do
      repoRoot <- getCurrentDirectory
      violations <- haskellStyleViolations repoRoot
      violations `shouldBe` []

    it "pins the doctrine-required fourmolu settings" $ do
      repoRoot <- getCurrentDirectory
      fourmoluContents <- readFile (repoRoot </> "fourmolu.yaml")
      mapM_
        (fourmoluContents `shouldContain`)
        [ "indentation: 2"
        , "column-limit: 100"
        , "function-arrows: leading"
        , "comma-style: leading"
        , "import-export-style: leading"
        , "indent-wheres: false"
        , "record-brace-space: true"
        , "newlines-between-decls: 1"
        , "haddock-style: single-line"
        , "let-style: auto"
        , "in-style: right-align"
        , "unicode: never"
        , "respectful: true"
        ]

    it "keeps the generated command registry target marker-delimited" $ do
      repoRoot <- getCurrentDirectory
      commandDoc <- readFile (repoRoot </> "documents" </> "cli" </> "commands.md")
      commandDoc `shouldContain` "<!-- prodbox:command-registry.markdown:start -->"
      commandDoc `shouldContain` "<!-- prodbox:command-registry.markdown:end -->"
