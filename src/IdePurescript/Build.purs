module IdePurescript.Build where

import Prelude

import Control.Monad.Aff (Aff, makeAff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Exception (EXCEPTION, error, catchException)
import Control.Monad.Eff.Ref (readRef, REF, modifyRef, newRef)
import Control.Monad.Eff.Unsafe (unsafeCoerceEff)
import Control.Monad.Error.Class (throwError)
import Data.Array (uncons)
import Data.Bifunctor (bimap)
import Data.Either (either, Either(..))
import Data.Foldable (find)
import Data.List as List
import Data.Maybe (maybe, Maybe(..))
import Data.StrMap (fromFoldable)
import Data.String (Pattern(Pattern), split, indexOf)
import Data.Traversable (traverse_)
import Data.Tuple (Tuple(Tuple))
import IdePurescript.Exec (findBins, getPathVar)
import IdePurescript.PscErrors (PscResult(..), parsePscOutput)
import IdePurescript.PscIdeServer (ErrorLevel(..), Notify)
import Node.Buffer (BUFFER)
import Node.ChildProcess (ChildProcess, CHILD_PROCESS)
import Node.ChildProcess as CP
import Node.Encoding (Encoding(UTF8))
import Node.FS (FS)
import Node.Process (PROCESS)
import Node.Stream as S
import PscIde (NET)
import PscIde as P
import PscIde.Command (RebuildResult(..))
import PscIde.Server (Executable(Executable))

type BuildOptions =
  { command :: Command
  , directory :: String
  , useNpmDir :: Boolean
  }

data Command = Command String (Array String)

type BuildResult =
  { errors :: PscResult
  , success :: Boolean
  }

addExceptionEffect :: forall eff a. Eff eff a -> Eff (exception :: EXCEPTION | eff) a
addExceptionEffect = unsafeCoerceEff

spawn :: forall eff. BuildOptions
  -> Aff (cp :: CHILD_PROCESS, buffer :: BUFFER, fs :: FS, process :: PROCESS | eff)
      { cmdBins :: Array Executable, cp :: Maybe ChildProcess }
spawn { command: Command cmd args, directory, useNpmDir } = do
  pathVar <- liftEff $ getPathVar useNpmDir directory
  cmdBins <- findBins pathVar cmd
  cp <- liftEff $ case uncons cmdBins of
    Just { head: Executable cmdBin _ } -> Just <$>
      CP.spawn cmdBin args (CP.defaultSpawnOptions { cwd = Just directory, env = Just (fromFoldable $ List.singleton $ Tuple "PATH" $ either id id pathVar) })
    _ -> pure Nothing
  pure { cmdBins, cp }

type BuildEff eff = (cp :: CP.CHILD_PROCESS, buffer :: BUFFER, fs :: FS, ref :: REF, process :: PROCESS | eff)
build :: forall eff. Notify (BuildEff eff) -> BuildOptions -> Aff (BuildEff eff) BuildResult
build logCb buildOptions@{ command: Command cmd args, directory, useNpmDir } = do
  { cmdBins, cp: cp' } <- spawn buildOptions
  makeAff $ \err succ -> do
    logCb Info $ "Resolved build command (1st is used): "
    traverse_ (\(Executable x vv) -> do
      logCb Info $ x <> maybe "" (": " <> _) vv) cmdBins
    case cp' of
      Nothing -> err $ error $ "Didn't find command in PATH: " <> cmd
      Just cp -> do
        CP.onError cp (err <<< CP.toStandardError)
        let stderr = CP.stderr cp
        result <- newRef ""
        let res :: String -> Eff (BuildEff (exception :: EXCEPTION | eff)) Unit
            res s = do
              modifyRef result (\acc -> acc<>s)

        catchException err $ S.onDataString stderr UTF8 res
        CP.onClose cp (\exit -> case exit of
          CP.Normally n | n == 0 || n == 1 -> do
            pscOutput <- readRef result
            let lines = split (Pattern "\n") pscOutput
                json = find (\s -> indexOf (Pattern "{\"") s == Just 0) lines
            case parsePscOutput <$> json of
              Just (Left e) -> err $ error e
              Just (Right r) -> succ { errors: r, success: n == 0 }
              Nothing -> err $ error "Didn't find JSON output"
          _ -> err $ error "Process exited abnormally")

rebuild :: forall eff. Int -> String -> Aff (net :: NET | eff) BuildResult
rebuild port file = do
  res <- P.rebuild port file (Just file)
  either
    (throwError <<< error)
    (pure <<< onResult)
    res
  where

  onResult :: Either RebuildResult RebuildResult -> BuildResult
  onResult =
    either (\errors -> { errors: PscResult { errors, warnings: [] }, success: true })
           (\warnings -> { errors: PscResult { errors: [], warnings }, success: true  })
    <<<
    bimap unwrap unwrap
    where
    unwrap (RebuildResult r) = r
