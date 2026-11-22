{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Non-authorizing coordinates for a deployment selected by an explicit
-- project anchor. Filesystem ownership and mount identity must still be
-- observed immediately before any effect.
module Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (..)
  , DeploymentScope
  , DeploymentScopeError (..)
  , ScopeRootObservation (..)
  , ScopeGenerationObservation (..)
  , ScopeArtifactObservation (..)
  , HeldArtifactResult (..)
  , FreshScopeResult (..)
  , deploymentScope
  , observeScopeRoot
  , withObservedScopeRoot
  , withScopeRootDescriptor
  , ScopeDescriptorIoFailure (..)
  , ScopeDescriptorOutcome (..)
  , ScopeDescriptorInterrupted (..)
  , withScopeRootDescriptorPreserving
  , observeScopeGeneration
  , observeScopeArtifact
  , withVerifiedScopeArtifact
  , prepareFreshScope
  , prepareFreshScopeWithConfig
  , validArtifactDeclaration
  , validRootGeneration
  , scopeEnvironment
  , scopeIdentifier
  , scopeRoot
  , scopeKindName
  , scopeKubeconfig
  , scopeApiPort
  , requireDisjointScopes
  )
where

import Control.Exception
  ( Exception
  , IOException
  , SomeException
  , bracket
  , fromException
  , mask
  , throwIO
  , try
  )
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.Bits ((.&.))
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower, isDigit)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf)
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CUInt (..))
import System.FilePath (isAbsolute, normalise, splitDirectories, takeDirectory, takeFileName, (</>))
import System.IO.Error
  ( IOErrorType
  , ioeGetErrorType
  , isAlreadyExistsError
  , isDoesNotExistError
  , isEOFError
  )
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , fileMode
  , fileOwner
  , fileSize
  , getFdStatus
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , isSymbolicLink
  , linkCount
  , modificationTimeHiRes
  , statusChangeTimeHiRes
  )
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (CMode (..), Fd (..), UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

foreign import capi "sys/stat.h mkdirat"
  makeScopeDirectoryAt :: CInt -> CString -> CMode -> IO CInt
foreign import capi "stdio.h renameat2"
  publishScopeAt :: CInt -> CString -> CInt -> CString -> CUInt -> IO CInt
foreign import capi "stdio.h value RENAME_NOREPLACE" scopeNoReplace :: CUInt

data DeploymentEnvironment = Production | Test
  deriving (Eq, Show)

data DeploymentScopeError
  = InvalidProjectAnchor
  | InvalidDeploymentIdentifier
  | InvalidApiPort
  | OverlappingDeploymentRoots
  | DuplicateKindName
  | DuplicateApiPort
  | ScopeAnchorMissing !FilePath
  | ScopePathSymlink !FilePath
  | ScopePathNotDirectory !FilePath
  | ScopePathForeignOwner !FilePath
  | ScopePathUnobservable !FilePath
  deriving (Eq, Show)

data ScopeRootObservation = ScopeRootAbsent | ScopeRootPresent
  deriving (Eq, Show)

data ScopeGenerationObservation
  = ScopeGenerationMissing
  | ScopeGenerationMatches
  | ScopeGenerationForeign
  | ScopeGenerationInvalid
  | ScopeGenerationUnobservable
  | ScopeGenerationPathChanged
  | ScopeGenerationInvalidExpected
  deriving (Eq, Show)

data ScopeArtifactObservation
  = ScopeArtifactDigestMatches !Integer
  | ScopeArtifactDigestMismatch
  | ScopeArtifactMissing
  | ScopeArtifactUnsafe
  | ScopeArtifactTooLarge
  | ScopeArtifactChanged
  | ScopeArtifactUnobservable
  | ScopeArtifactTimedOut
  | ScopeArtifactInvalidDeclaration
  deriving (Eq, Show)

data HeldArtifactResult value
  = HeldArtifactRefused !ScopeArtifactObservation
  | HeldArtifactObserved !value !Bool
  deriving (Eq, Show)

data ScopeDescriptorIoFailure
  = ScopeDescriptorCloseIo !IOErrorType
  | ScopeDescriptorOtherIo !IOErrorType
  deriving (Eq, Show)

data ScopeDescriptorOutcome value
  = ScopeDescriptorRefused !DeploymentScopeError ![ScopeDescriptorIoFailure]
  | ScopeDescriptorCallbackFailed !IOErrorType ![ScopeDescriptorIoFailure]
  | ScopeDescriptorUnconfirmed !IOErrorType ![ScopeDescriptorIoFailure]
  | ScopeDescriptorReturned !value
  | ScopeDescriptorCleanupFailedAfter !value ![ScopeDescriptorIoFailure]
  deriving (Eq, Show)

data ScopeDescriptorProgress value
  = ScopeDescriptorNotStarted
  | ScopeDescriptorStarted
  | ScopeDescriptorCallbackReturned !value
  | ScopeDescriptorCallbackThrew !SomeException

-- Preserve the original exception without rendering an arbitrary payload.
data ScopeDescriptorInterrupted = ScopeDescriptorInterrupted !SomeException ![ScopeDescriptorIoFailure]

instance Show ScopeDescriptorInterrupted where
  show (ScopeDescriptorInterrupted _ failures) = "scope interrupted; cleanup failures: " ++ show failures

instance Exception ScopeDescriptorInterrupted

data FreshScopeResult
  = FreshScopePrepared
  | FreshScopeAlreadyExists
  | FreshScopeInvalidGeneration
  | FreshScopeStagingExists !FilePath
  | FreshScopeIncomplete !FilePath
  | FreshScopeUnobservable
  | FreshScopeNestedInRetainedRoot !FilePath
  deriving (Eq, Show)

data DeploymentScope = DeploymentScope
  { scopeEnvironment :: !DeploymentEnvironment
  , scopeIdentifier :: !String
  , scopeRoot :: !FilePath
  , scopeKindName :: !String
  , scopeKubeconfig :: !FilePath
  , scopeApiPort :: !Int
  }
  deriving (Eq, Show)

-- | Construct a candidate only; callers must inspect the actual filesystem,
-- ownership marker, listeners, and cluster before mutation. The identifier
-- grammar is a bounded DNS label, so no path component is caller-controlled.
deploymentScope
  :: FilePath -> DeploymentEnvironment -> String -> Int -> Either DeploymentScopeError DeploymentScope
deploymentScope projectAnchor environment identifier apiPort
  | not (isAbsolute projectAnchor)
      || length projectAnchor > 4096
      || projectAnchor == "/"
      || normalise projectAnchor /= projectAnchor
      || any (`elem` [".", ".."]) (splitDirectories projectAnchor)
      || (environment == Test && ".data" `elem` splitDirectories projectAnchor)
      || '\0' `elem` projectAnchor =
      Left InvalidProjectAnchor
  | not (validIdentifier identifier) = Left InvalidDeploymentIdentifier
  | apiPort <= 0 || apiPort > 65535 = Left InvalidApiPort
  | otherwise =
      Right
        DeploymentScope
          { scopeEnvironment = environment
          , scopeIdentifier = identifier
          , scopeRoot = root
          , scopeKindName = "prodbox-" ++ prefix ++ "-" ++ identifier
          , scopeKubeconfig = root </> "control" </> "kubeconfig"
          , scopeApiPort = apiPort
          }
 where
  (directory, prefix) = case environment of
    Production -> (".data", "p")
    Test -> (".test-data", "t")
  root = projectAnchor </> directory </> identifier

validIdentifier :: String -> Bool
validIdentifier [] = False
validIdentifier identifier@(first : rest) =
  length identifier <= 40
    && all validCharacter identifier
    && validEdge first
    && validEdge (foldl' (\_ character -> character) first rest)
 where
  validEdge character = isAsciiLower character || isAsciiDigit character
  validCharacter character = validEdge character || character == '-'
  isAsciiDigit character = isDigit character && character >= '0' && character <= '9'

-- | Check all declared scope coordinates before attempting concurrent work.
-- Filesystem aliasing and an occupied port are separate observations.
requireDisjointScopes :: DeploymentScope -> DeploymentScope -> Either DeploymentScopeError ()
requireDisjointScopes left right
  | rootsOverlap (scopeRoot left) (scopeRoot right) = Left OverlappingDeploymentRoots
  | scopeKindName left == scopeKindName right = Left DuplicateKindName
  | scopeApiPort left == scopeApiPort right = Left DuplicateApiPort
  | otherwise = Right ()

-- | Prepare a new root only. Create the selected shared parent when absent,
-- under a descriptor-verified caller-owned anchor. A named staging directory preserves incomplete work; an
-- existing root or staging name is never adopted or replaced. This durable
-- local identity is not a lifecycle permit or proof of cloud absence.
prepareFreshScope :: DeploymentScope -> String -> IO FreshScopeResult
prepareFreshScope = prepareScope False

-- | As part of the same exclusive staged enrollment, create the private
-- configuration directory needed by the selected bootstrap authoring path.
prepareFreshScopeWithConfig :: DeploymentScope -> String -> IO FreshScopeResult
prepareFreshScopeWithConfig = prepareScope True

prepareScope :: Bool -> DeploymentScope -> String -> IO FreshScopeResult
prepareScope includeConfig scope generation
  | not (validRootGeneration generation) = pure FreshScopeInvalidGeneration
  | otherwise = do
      -- A root declared inside another scope's retained root would create
      -- records in a root this scope does not own: refuse before any write.
      enclosing <- enclosingRetainedRoot (anchorPath : ancestors anchorPath)
      case enclosing of
        Just found -> pure (FreshScopeNestedInRetainedRoot found)
        Nothing -> do
          owner <- getEffectiveUserID
          outcome <- try (walkParent True owner $ \parent identities -> prepare owner parent identities)
          pure $ either (const FreshScopeUnobservable) id (outcome :: Either IOException FreshScopeResult)
 where
  ancestors path = let parent = takeDirectory path in if parent == path then [] else parent : ancestors parent
  enclosingRetainedRoot [] = pure Nothing
  enclosingRetainedRoot (directory : rest) = do
    marker <- try (getSymbolicLinkStatus (directory </> "scope-generation.json"))
    case marker of
      Right _ -> pure (Just directory)
      Left (failure :: IOException)
        | isDoesNotExistError failure -> enclosingRetainedRoot rest
        | otherwise -> pure (Just directory)
  parentPath = takeDirectory (scopeRoot scope)
  anchorPath = takeDirectory parentPath
  parentName = takeFileName parentPath
  name = takeFileName (scopeRoot scope)
  stagingName = ".enroll-" ++ name ++ "-" ++ generation
  stagingPath = parentPath </> stagingName
  flags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}
  components = filter (/= "/") (splitDirectories anchorPath)
  identity status = (toInteger (deviceID status), toInteger (fileID status))
  walkParent createParent owner use = bracket (Posix.openFd "/" Posix.ReadOnly flags) Posix.closeFd $ \root ->
    descend createParent owner root "/" components [] use
  descend createParent owner current path names identities use = do
    status <- getFdStatus current
    if not (isDirectory status) || (path == anchorPath && not (safeArtifactDirectory owner status))
      then ioError (userError "unsafe scope anchor")
      else case names of
        [] -> do
          if createParent
            then do
              created <- try $ withCString parentName $ \nameBytes ->
                throwErrnoIfMinus1_ "mkdirat scope parent" (makeScopeDirectoryAt (fdNumber current) nameBytes 0o700)
              case created of
                Right () -> pure ()
                Left (failure :: IOException)
                  | isAlreadyExistsError failure -> pure ()
                  | otherwise -> throwIO failure
              fileSynchronise current
            else pure ()
          bracket (Posix.openFdAt (Just current) parentName Posix.ReadOnly flags) Posix.closeFd $ \parent -> do
            parentStatus <- getFdStatus parent
            if safeArtifactDirectory owner parentStatus
              then use parent (reverse (identity parentStatus : identity status : identities))
              else ioError (userError "unsafe scope parent")
        nextName : remaining ->
          bracket (Posix.openFdAt (Just current) nextName Posix.ReadOnly flags) Posix.closeFd $ \next ->
            descend createParent owner next (path </> nextName) remaining (identity status : identities) use
  prepare owner parent identities = do
    existing <- try (getSymbolicLinkStatus (scopeRoot scope))
    case existing of
      Right _ -> pure FreshScopeAlreadyExists
      Left (failure :: IOException)
        | not (isDoesNotExistError failure) -> pure FreshScopeUnobservable
        | otherwise -> do
            created <- try $ withCString stagingName $ \staged ->
              throwErrnoIfMinus1_ "mkdirat scope staging" (makeScopeDirectoryAt (fdNumber parent) staged 0o700)
            case created of
              Left (creationFailure :: IOException)
                | isAlreadyExistsError creationFailure -> pure (FreshScopeStagingExists stagingPath)
                | otherwise -> pure FreshScopeUnobservable
              Right () -> do
                result <- try (writeAndPublish owner parent identities)
                case result of
                  Left (_ :: IOException) -> pure (FreshScopeIncomplete stagingPath)
                  Right False -> pure (FreshScopeIncomplete stagingPath)
                  Right True -> do
                    observed <- observeScopeGeneration scope generation
                    pure $
                      if observed == Right ScopeGenerationMatches
                        then FreshScopePrepared
                        else FreshScopeIncomplete stagingPath
  writeAndPublish owner parent identities =
    bracket (Posix.openFdAt (Just parent) stagingName Posix.ReadOnly flags) Posix.closeFd $ \staging -> do
      status <- getFdStatus staging
      if not (safeArtifactDirectory owner status)
        then pure False
        else do
          if includeConfig
            then do
              withCString "config" $ \nameBytes ->
                throwErrnoIfMinus1_ "mkdirat scope config" (makeScopeDirectoryAt (fdNumber staging) nameBytes 0o700)
              bracket (Posix.openFdAt (Just staging) "config" Posix.ReadOnly flags) Posix.closeFd fileSynchronise
            else pure ()
          let marker =
                Aeson.encode $
                  Aeson.object
                    [ "schema_version" Aeson..= (1 :: Int)
                    , "environment" Aeson..= case scopeEnvironment scope of Production -> ("production" :: String); Test -> "test"
                    , "deployment_id" Aeson..= scopeIdentifier scope
                    , "generation" Aeson..= generation
                    , "root_device" Aeson..= toInteger (deviceID status)
                    , "root_inode" Aeson..= toInteger (fileID status)
                    ]
              markerFlags =
                Posix.defaultFileFlags
                  { Posix.nofollow = True
                  , Posix.cloexec = True
                  , Posix.exclusive = True
                  , Posix.creat = Just 0o600
                  }
          bracket
            (Posix.openFdAt (Just staging) "scope-generation.json" Posix.WriteOnly markerFlags)
            Posix.closeFd
            $ \fd -> do
              writeAllScope fd (LazyByteString.toStrict marker)
              fileSynchronise fd
          fileSynchronise staging
          fileSynchronise parent
          fresh <- try (walkParent False owner $ \_ current -> pure current)
          freshStage <-
            try $
              bracket (Posix.openFdAt (Just parent) stagingName Posix.ReadOnly flags) Posix.closeFd getFdStatus
          if not
            ( case (fresh, freshStage) of
                (Right current, Right staged) -> current == identities && identity staged == identity status
                (_ :: Either IOException [(Integer, Integer)], _ :: Either IOException FileStatus) -> False
            )
            then pure False
            else do
              withCString stagingName $ \staged -> withCString name $ \target ->
                throwErrnoIfMinus1_
                  "renameat2 scope"
                  (publishScopeAt (fdNumber parent) staged (fdNumber parent) target scopeNoReplace)
              fileSynchronise parent
              published <-
                bracket (Posix.openFdAt (Just parent) name Posix.ReadOnly flags) Posix.closeFd getFdStatus
              pure (identity published == identity status)
  fdNumber (Fd number) = number

writeAllScope :: Fd -> ByteString.ByteString -> IO ()
writeAllScope fd bytes
  | ByteString.null bytes = pure ()
  | otherwise = do
      count <- PosixBytes.fdWrite fd bytes
      if count <= 0
        then ioError (userError "short scope write")
        else writeAllScope fd (ByteString.drop (fromIntegral count) bytes)

rootsOverlap :: FilePath -> FilePath -> Bool
rootsOverlap left right =
  let leftParts = splitDirectories left
      rightParts = splitDirectories right
   in leftParts `isPrefixOf` rightParts || rightParts `isPrefixOf` leftParts

-- | Inspect existing components without following symlinks. This is a local
-- observation, not evidence of an owned generation or permission to create,
-- mount, or delete anything. Effect boundaries must perform their own
-- descriptor-bound checks and observe the identity marker.
observeScopeRoot :: DeploymentScope -> IO (Either DeploymentScopeError ScopeRootObservation)
observeScopeRoot scope = do
  owner <- getEffectiveUserID
  case splitDirectories root of
    [] -> pure (Left (ScopePathUnobservable root))
    first : rest -> inspect owner (scanl (</>) first rest)
 where
  root = scopeRoot scope
  scopeParent = takeDirectory root
  anchor = takeDirectory scopeParent
  inspect _ [] = pure (Right ScopeRootPresent)
  inspect owner (path : remaining) = do
    observed <- try (getSymbolicLinkStatus path)
    case observed of
      Left (err :: IOException)
        | isDoesNotExistError err ->
            pure $
              if path `elem` scanAnchorComponents anchor
                then Left (ScopeAnchorMissing path)
                else Right ScopeRootAbsent
        | otherwise -> pure (Left (ScopePathUnobservable path))
      Right status
        | isSymbolicLink status -> pure (Left (ScopePathSymlink path))
        | not (isDirectory status) -> pure (Left (ScopePathNotDirectory path))
        | path `elem` [scopeParent, root] && fileOwner status /= owner ->
            pure (Left (ScopePathForeignOwner path))
        | otherwise -> inspect owner remaining
  scanAnchorComponents path = case splitDirectories path of
    [] -> []
    first : rest -> scanl (</>) first rest

-- | Hold the observed root open and supply a fresh descriptor-relative
-- comparison to the caller. This detects a replaced path at the instant of
-- comparison; it does not establish generation ownership or close the race
-- between that comparison and a later effect.
withObservedScopeRoot
  :: forall a
   . DeploymentScope
  -> (IO Bool -> IO a)
  -> IO (Either DeploymentScopeError a)
withObservedScopeRoot scope action = do
  withScopeRootDescriptor scope (\_ same -> action same)

withScopeRootDescriptor
  :: forall a
   . DeploymentScope
  -> (Fd -> IO Bool -> IO a)
  -> IO (Either DeploymentScopeError a)
withScopeRootDescriptor scope action = do
  owner <- getEffectiveUserID
  result <- try $ walkScopeRoot scope owner Posix.closeFd $ \held identities -> do
    try
      ( action held $ do
          fresh <- try (walkScopeRoot scope owner Posix.closeFd $ \_ observed -> pure observed)
          heldStatus <- try (getFdStatus held) :: IO (Either IOException FileStatus)
          pure $ case (fresh, heldStatus) of
            (Right observed, Right status) -> observed == identities && scopeIdentity status == lastScopeIdentity identities
            (_ :: Either IOException [(Integer, Integer)], _) -> False
      )
      :: IO (Either IOException a)
  case result of
    Left (_ :: IOException) -> pure (Left (ScopePathUnobservable (scopeRoot scope)))
    Right (Left failure) -> throwIO failure
    Right (Right value) -> pure (Right value)

-- | Preserve a callback result and descriptor-close error categories
-- independently. This is an observation, not an exclusion or settlement
-- guarantee. Non-I/O callback exceptions propagate, preserving cleanup errors
-- and the original exception together if descriptor cleanup also fails.
withScopeRootDescriptorPreserving
  :: forall value
   . DeploymentScope
  -> (Fd -> IO Bool -> IO value)
  -> IO (ScopeDescriptorOutcome value)
withScopeRootDescriptorPreserving scope action = mask $ \restoreWalk -> do
  owner <- getEffectiveUserID
  progress <- newIORef ScopeDescriptorNotStarted
  failures <- newIORef []
  let closeTracked descriptor = do
        closed <- try (Posix.closeFd descriptor)
        case closed of
          Left (failure :: IOException) -> do
            modifyIORef' failures (ScopeDescriptorCloseIo (ioeGetErrorType failure) :)
            throwIO failure
          Right () -> pure ()
      sameRoot held identities = do
        fresh <- try (walkScopeRoot scope owner Posix.closeFd $ \_ observed -> pure observed)
        heldStatus <- try (getFdStatus held) :: IO (Either IOException FileStatus)
        pure $ case (fresh, heldStatus) of
          (Right observed, Right status) -> observed == identities && scopeIdentity status == lastScopeIdentity identities
          (_ :: Either IOException [(Integer, Integer)], _) -> False
  result <- try $ restoreWalk $ walkScopeRoot scope owner closeTracked $ \held identities -> mask $ \restore -> do
    writeIORef progress ScopeDescriptorStarted
    attempted <- try (restore (action held (sameRoot held identities)))
    case attempted of
      Left (failure :: SomeException) -> do
        writeIORef progress (ScopeDescriptorCallbackThrew failure)
        throwIO failure
      Right value -> do
        writeIORef progress (ScopeDescriptorCallbackReturned value)
        pure value
  current <- readIORef progress
  closeFailures <- reverse <$> readIORef failures
  case (result :: Either SomeException value, current) of
    (Right value, _) -> pure (ScopeDescriptorReturned value)
    (Left _, ScopeDescriptorCallbackThrew original) ->
      case fromException original of
        Just ioFailure -> pure (ScopeDescriptorCallbackFailed (ioeGetErrorType ioFailure) closeFailures)
        Nothing ->
          if null closeFailures
            then throwIO original
            else throwIO (ScopeDescriptorInterrupted original closeFailures)
    (Left failure, ScopeDescriptorNotStarted) -> handleIo failure $ \ioFailure ->
      ScopeDescriptorRefused (ScopePathUnobservable (scopeRoot scope)) (withOther ioFailure closeFailures)
    (Left failure, ScopeDescriptorStarted) -> handleIo failure $ \ioFailure ->
      ScopeDescriptorUnconfirmed (ioeGetErrorType ioFailure) closeFailures
    (Left failure, ScopeDescriptorCallbackReturned value) -> handleIo failure $ \ioFailure ->
      ScopeDescriptorCleanupFailedAfter value (withOther ioFailure closeFailures)
 where
  handleIo failure build = maybe (throwIO failure) (pure . build) (fromException failure)
  withOther failure [] = [ScopeDescriptorOtherIo (ioeGetErrorType failure)]
  withOther _ failures = failures

walkScopeRoot
  :: DeploymentScope
  -> UserID
  -> (Fd -> IO ())
  -> (Fd -> [(Integer, Integer)] -> IO value)
  -> IO value
walkScopeRoot scope owner release use =
  bracket (Posix.openFd "/" Posix.ReadOnly flags) release $ \root ->
    descend root "/" components []
 where
  flags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}
  components = filter (/= "/") (splitDirectories (scopeRoot scope))
  parent = takeDirectory (scopeRoot scope)
  anchor = takeDirectory parent
  descend fd path names identities = do
    status <- getFdStatus fd
    if not (isDirectory status)
      || (path `elem` [anchor, parent, scopeRoot scope] && not (safeArtifactDirectory owner status))
      then ioError (userError "unsafe scope directory")
      else case names of
        [] -> use fd (reverse (scopeIdentity status : identities))
        name : remaining ->
          bracket (Posix.openFdAt (Just fd) name Posix.ReadOnly flags) release $ \next ->
            descend next (path </> name) remaining (scopeIdentity status : identities)

scopeIdentity :: FileStatus -> (Integer, Integer)
scopeIdentity status = (fromIntegral (deviceID status), fromIntegral (fileID status))

lastScopeIdentity :: [(Integer, Integer)] -> (Integer, Integer)
lastScopeIdentity = foldl' (\_ current -> current) (0, 0)

-- | Independently inspect a local generation record relative to the held
-- scope root. A match is a local observation, not admission authority; missing
-- or corrupt metadata does not prove that any cloud resources are absent.
observeScopeGeneration
  :: DeploymentScope -> String -> IO (Either DeploymentScopeError ScopeGenerationObservation)
observeScopeGeneration scope expectedGeneration
  | not (validRootGeneration expectedGeneration) = pure (Right ScopeGenerationInvalidExpected)
  | otherwise = withScopeRootDescriptor scope $ \root same -> do
      owner <- getEffectiveUserID
      attempted <-
        try $ do
          rootStatus <- getFdStatus root
          mask $ \restore -> do
            opened <- try (Posix.openFdAt (Just root) "scope-generation.json" Posix.ReadOnly markerFlags)
            case opened of
              Left (failure :: IOException) ->
                pure $
                  Left (if isDoesNotExistError failure then ScopeGenerationMissing else ScopeGenerationUnobservable)
              Right descriptor -> do
                readResult <- try $ bracket (pure descriptor) Posix.closeFd (restore . readMarker owner rootStatus)
                pure $
                  either
                    (const (Left ScopeGenerationUnobservable))
                    Right
                    (readResult :: Either IOException (ScopeGenerationObservation, FileStatus))
      observation <- case attempted of
        Left (_ :: IOException) -> pure ScopeGenerationUnobservable
        Right (Left failure) -> pure failure
        Right (Right (observed, prior))
          | observed == ScopeGenerationUnobservable -> pure observed
          | otherwise -> do
              rechecked <-
                try $
                  bracket
                    (Posix.openFdAt (Just root) "scope-generation.json" Posix.ReadOnly markerFlags)
                    Posix.closeFd
                    getFdStatus
              pure $ case rechecked of
                Right current | safeMarker owner current && sameMarker prior current -> observed
                (_ :: Either IOException FileStatus) -> ScopeGenerationUnobservable
      stillSame <- same
      pure $ if stillSame then observation else ScopeGenerationPathChanged
 where
  markerFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
  readMarker owner rootStatus fd = do
    before <- getFdStatus fd
    if not (safeMarker owner before)
      then pure (ScopeGenerationUnobservable, before)
      else do
        bytes <- readMarkerBytes fd [] 0
        after <- getFdStatus fd
        let observation
              | not (sameMarker before after) = ScopeGenerationUnobservable
              | ByteString.length bytes > 4096 = ScopeGenerationInvalid
              | otherwise = case Aeson.eitherDecodeStrict' bytes >>= parseEither parseMarker of
                  Left _ -> ScopeGenerationInvalid
                  Right (environment, identifier, generation, rootDevice, rootInode) ->
                    if environment == environmentName (scopeEnvironment scope)
                      && identifier == scopeIdentifier scope
                      && generation == expectedGeneration
                      && rootDevice == fromIntegral (deviceID rootStatus)
                      && rootInode == fromIntegral (fileID rootStatus)
                      then ScopeGenerationMatches
                      else ScopeGenerationForeign
        pure (observation, after)
  safeMarker owner status =
    isRegularFile status
      && fileOwner status == owner
      && linkCount status == 1
      && fileSize status <= 4096
      && fileMode status .&. 0o022 == 0
  sameMarker before after =
    deviceID before == deviceID after
      && fileID before == fileID after
      && fileSize before == fileSize after
      && modificationTimeHiRes before == modificationTimeHiRes after
      && statusChangeTimeHiRes before == statusChangeTimeHiRes after
  environmentName Production = "production"
  environmentName Test = "test"

validRootGeneration :: String -> Bool
validRootGeneration generation =
  length generation == 32
    && all
      (\character -> (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f'))
      generation

readMarkerBytes :: Fd -> [ByteString.ByteString] -> Int -> IO ByteString.ByteString
readMarkerBytes fd chunks total
  | total > 4096 = pure (ByteString.concat (reverse chunks))
  | otherwise = do
      result <- try (PosixBytes.fdRead fd (fromIntegral (4097 - total)))
      case result of
        Left (failure :: IOException)
          | isEOFError failure -> pure (ByteString.concat (reverse chunks))
          | otherwise -> throwIO failure
        Right chunk
          | ByteString.null chunk -> pure (ByteString.concat (reverse chunks))
          | otherwise -> readMarkerBytes fd (chunk : chunks) (total + ByteString.length chunk)

parseMarker :: Aeson.Value -> Parser (String, String, String, Integer, Integer)
parseMarker = Aeson.withObject "scope generation" $ \object -> do
  if KeyMap.size object == 6 then pure () else fail "unexpected generation fields"
  version <- object Aeson..: "schema_version" :: Parser Int
  if version == 1 then pure () else fail "unsupported generation version"
  (,,,,)
    <$> object Aeson..: "environment"
    <*> object Aeson..: "deployment_id"
    <*> object Aeson..: "generation"
    <*> object Aeson..: "root_device"
    <*> object Aeson..: "root_inode"

-- | Hash one declared artifact under the selected root's @artifacts@
-- directory. The result describes one local observation only: it does not
-- verify archive contents, architecture, provenance, or authority to load it.
observeScopeArtifact
  :: DeploymentScope
  -> FilePath
  -> String
  -> Integer
  -> IO (Either DeploymentScopeError ScopeArtifactObservation)
observeScopeArtifact scope relativePath expectedDigest maximumBytes
  | not (validArtifactDeclaration relativePath expectedDigest maximumBytes) =
      pure (Right ScopeArtifactInvalidDeclaration)
  | otherwise = withScopeRootDescriptor scope $ \root sameRoot -> do
      result <- try (observe root sameRoot)
      pure $
        either (const ScopeArtifactUnobservable) id (result :: Either IOException ScopeArtifactObservation)
 where
  observe root sameRoot = do
    owner <- getEffectiveUserID
    rootStatus <- getFdStatus root
    if not (safeArtifactDirectory owner rootStatus)
      then pure ScopeArtifactUnsafe
      else do
        initial <- try (withArtifactFile owner root components (inspect owner))
        observed <- case initial of
          Left (_ :: IOException) -> pure ScopeArtifactUnobservable
          Right (Left failure) -> pure failure
          Right (Right (result, before)) -> case result of
            ScopeArtifactDigestMatches _ -> recheck owner root before result
            ScopeArtifactDigestMismatch -> recheck owner root before result
            _ -> pure result
        stillSame <- sameRoot
        pure (if stillSame then observed else ScopeArtifactChanged)
  components = splitDirectories relativePath
  inspect owner descriptor = do
    before <- getFdStatus descriptor
    if not (safeArtifactFile owner before)
      then pure (ScopeArtifactUnsafe, before)
      else
        if toInteger (fileSize before) > maximumBytes
          then pure (ScopeArtifactTooLarge, before)
          else do
            hashed <- timeout 60000000 (hashArtifact descriptor maximumBytes 0 SHA256.init)
            after <- getFdStatus descriptor
            pure
              ( if not (sameArtifactVersion before after)
                  then ScopeArtifactChanged
                  else case hashed of
                    Nothing -> ScopeArtifactTimedOut
                    Just (Left failure) -> failure
                    Just (Right (digest, size)) ->
                      if size /= toInteger (fileSize before)
                        then ScopeArtifactChanged
                        else
                          if digest == expectedDigest
                            then ScopeArtifactDigestMatches size
                            else ScopeArtifactDigestMismatch
              , after
              )
  recheck owner root before result = do
    fresh <- try (withArtifactFile owner root components getFdStatus)
    pure $ case fresh of
      Right (Right after) | sameArtifactVersion before after -> result
      (_ :: Either IOException (Either ScopeArtifactObservation FileStatus)) -> ScopeArtifactChanged

-- | Hold and verify one retained artifact while a caller observes or uses it.
-- The callback gets a fresh recheck for effect boundaries. A changed result
-- retains the callback's value, but does not authorize a subsequent effect.
withVerifiedScopeArtifact
  :: forall value
   . DeploymentScope
  -> FilePath
  -> String
  -> Integer
  -> (Fd -> IO Bool -> IO value)
  -> IO (Either DeploymentScopeError (HeldArtifactResult value))
withVerifiedScopeArtifact scope path digest maximumBytes action
  | not (validArtifactDeclaration path digest maximumBytes) =
      pure (Right (HeldArtifactRefused ScopeArtifactInvalidDeclaration))
  | otherwise = withScopeRootDescriptor scope $ \root sameRoot -> do
      owner <- getEffectiveUserID
      opened <- try $ do
        rootStatus <- getFdStatus root
        if not (safeArtifactDirectory owner rootStatus)
          then pure (Left ScopeArtifactUnsafe)
          else withArtifactFile owner root (splitDirectories path) (inspect owner root sameRoot)
      case opened of
        Left (_ :: IOException) -> pure (HeldArtifactRefused ScopeArtifactUnobservable)
        Right (Left failure) -> pure (HeldArtifactRefused failure)
        Right (Right (Left failure)) -> pure (HeldArtifactRefused failure)
        Right (Right (Right (Left failure, _))) -> throwIO failure
        Right (Right (Right (Right value, stable))) -> pure (HeldArtifactObserved value stable)
 where
  inspect owner root sameRoot descriptor = do
    before <- getFdStatus descriptor
    if not (safeArtifactFile owner before)
      then pure (Left ScopeArtifactUnsafe)
      else
        if toInteger (fileSize before) > maximumBytes
          then pure (Left ScopeArtifactTooLarge)
          else do
            hashed <- timeout 60000000 (hashArtifact descriptor maximumBytes 0 SHA256.init)
            after <- getFdStatus descriptor
            let checked = case hashed of
                  Nothing -> Left ScopeArtifactTimedOut
                  Just (Left failure) -> Left failure
                  Just (Right (observed, size))
                    | not (sameArtifactVersion before after) || size /= toInteger (fileSize before) ->
                        Left ScopeArtifactChanged
                    | observed /= digest -> Left ScopeArtifactDigestMismatch
                    | otherwise -> Right ()
            case checked of
              Left failure -> pure (Left failure)
              Right () -> do
                let recheck = do
                      checkedPath <- try $ do
                        rootStatus <- getFdStatus root
                        heldStatus <- getFdStatus descriptor
                        named <- withArtifactFile owner root (splitDirectories path) getFdStatus
                        stable <- sameRoot
                        pure $
                          safeArtifactDirectory owner rootStatus
                            && stable
                            && sameArtifactVersion before heldStatus
                            && case named of Right status -> sameArtifactVersion before status; Left _ -> False
                      pure $ either (const False) id (checkedPath :: Either IOException Bool)
                stable <- recheck
                if not stable
                  then pure (Left ScopeArtifactChanged)
                  else do
                    result <- try (action descriptor recheck) :: IO (Either IOException value)
                    final <- recheck
                    pure (Right (result, final))

validArtifactDeclaration :: FilePath -> String -> Integer -> Bool
validArtifactDeclaration path digest maximumBytes =
  not (isAbsolute path)
    && length path <= 512
    && normalise path == path
    && ( case splitDirectories path of
           "artifacts" : names@(_ : _) -> all validComponent names
           _ -> False
       )
    && length digest == 71
    && take 7 digest == "sha256:"
    && all hexadecimal (drop 7 digest)
    && maximumBytes > 0
    && maximumBytes <= 4 * 1024 * 1024 * 1024
 where
  validComponent component = not (null component) && component `notElem` [".", ".."] && '\0' `notElem` component
  hexadecimal character = (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')

withArtifactFile
  :: UserID
  -> Fd
  -> [FilePath]
  -> (Fd -> IO value)
  -> IO (Either ScopeArtifactObservation value)
withArtifactFile owner root = descend root
 where
  directoryFlags =
    Posix.defaultFileFlags
      { Posix.nofollow = True
      , Posix.cloexec = True
      , Posix.directory = True
      , Posix.nonBlock = True
      }
  fileFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
  descend _ [] _ = pure (Left ScopeArtifactInvalidDeclaration)
  descend parent [name] use = openArtifact parent name fileFlags $ \file -> do
    status <- getFdStatus file
    if safeArtifactFile owner status then Right <$> use file else pure (Left ScopeArtifactUnsafe)
  descend parent (name : rest) use = openArtifact parent name directoryFlags $ \directory -> do
    status <- getFdStatus directory
    if safeArtifactDirectory owner status
      then descend directory rest use
      else pure (Left ScopeArtifactUnsafe)
  openArtifact parent name flags use = mask $ \restore -> do
    opened <- try (Posix.openFdAt (Just parent) name Posix.ReadOnly flags)
    case opened of
      Left (failure :: IOException) ->
        pure $
          Left (if isDoesNotExistError failure then ScopeArtifactMissing else ScopeArtifactUnobservable)
      Right descriptor -> bracket (pure descriptor) Posix.closeFd (restore . use)

safeArtifactDirectory :: UserID -> FileStatus -> Bool
safeArtifactDirectory owner status = isDirectory status && fileOwner status == owner && fileMode status .&. 0o022 == 0

safeArtifactFile :: UserID -> FileStatus -> Bool
safeArtifactFile owner status =
  isRegularFile status
    && fileOwner status == owner
    && linkCount status == 1
    && fileMode status .&. 0o022 == 0

sameArtifactVersion :: FileStatus -> FileStatus -> Bool
sameArtifactVersion before after =
  deviceID before == deviceID after
    && fileID before == fileID after
    && fileOwner before == fileOwner after
    && fileMode before == fileMode after
    && linkCount before == linkCount after
    && fileSize before == fileSize after
    && modificationTimeHiRes before == modificationTimeHiRes after
    && statusChangeTimeHiRes before == statusChangeTimeHiRes after

hashArtifact
  :: Fd -> Integer -> Integer -> SHA256.Ctx -> IO (Either ScopeArtifactObservation (String, Integer))
hashArtifact descriptor limit total context = do
  result <- try (PosixBytes.fdRead descriptor (fromIntegral (min 65536 (limit - total + 1))))
  case result of
    Left (failure :: IOException)
      | isEOFError failure -> pure (Right (renderArtifactDigest (SHA256.finalize context), total))
      | otherwise -> throwIO failure
    Right bytes
      | ByteString.null bytes -> pure (Right (renderArtifactDigest (SHA256.finalize context), total))
      | total + toInteger (ByteString.length bytes) > limit -> pure (Left ScopeArtifactTooLarge)
      | otherwise ->
          let next = SHA256.update context bytes
           in next `seq` hashArtifact descriptor limit (total + toInteger (ByteString.length bytes)) next

renderArtifactDigest :: ByteString.ByteString -> String
renderArtifactDigest digest = "sha256:" ++ concatMap renderByte (ByteString.unpack digest)
 where
  renderByte byte = [digit (byte `div` 16), digit (byte `mod` 16)]
  digit value
    | value < 10 = toEnum (fromEnum '0' + fromIntegral value)
    | otherwise = toEnum (fromEnum 'a' + fromIntegral value - 10)
