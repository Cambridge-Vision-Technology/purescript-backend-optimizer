module PureScript.Backend.Optimizer.Builder
  ( BuildEnv
  , BuildOptions
  , BuildState
  , buildModules
  , trimIncrementalState
  ) where

import Prelude

import Data.Either (Either(..))
import Data.FoldableWithIndex (foldrWithIndex)
import Data.FunctorWithIndex (mapWithIndex)
import Data.List (List, foldM)
import Data.List as List
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set
import Data.Tuple (Tuple(..))
import PureScript.Backend.Optimizer.Analysis (BackendAnalysis)
import PureScript.Backend.Optimizer.Convert (BackendModule, OptimizationSteps, toBackendModule)
import PureScript.Backend.Optimizer.CoreFn (Ann, Ident, Import(..), Module(..), ModuleName, Qualified(..), isPrimModule)
import PureScript.Backend.Optimizer.Semantics (BackendExpr, Ctx, EvalRef(..), ExternImpl, InlineDirectiveMap)
import PureScript.Backend.Optimizer.Semantics.Foreign (ForeignEval)
import PureScript.Backend.Optimizer.Syntax (BackendSyntax)

type BuildEnv =
  { implementations :: Map (Qualified Ident) (Tuple BackendAnalysis ExternImpl)
  , directives :: InlineDirectiveMap
  , built :: Set ModuleName
  , moduleCount :: Int
  , moduleIndex :: Int
  }
type BuildState =
  { built :: Set ModuleName
  , directives :: InlineDirectiveMap
  , implementations :: Map (Qualified Ident) (Tuple BackendAnalysis ExternImpl)
  }

type BuildOptions m =
  { analyzeCustom :: Ctx -> BackendSyntax BackendExpr -> Maybe BackendAnalysis
  , directives :: InlineDirectiveMap
  , foreignSemantics :: Map (Qualified Ident) ForeignEval
  , onPrepareModule :: BuildEnv -> Module Ann -> m (Either BackendModule (Module Ann))
  , onCodegenModule :: BuildEnv -> Module Ann -> BackendModule -> OptimizationSteps -> m Unit
  , traceIdents :: Set (Qualified Ident)
  -- Restore a saved `BuildState`, where `built` is the list of modules that
  -- do not need to be rebuilt (as long as their dependencies are also built),
  -- and `directives` and `implementations` may be from the whole state or
  -- already filtered to those modules
  , incremental :: Maybe BuildState
  }

-- | Builds modules given a _sorted_ list of modules.
-- | See `PureScript.Backend.Optimizer.CoreFn.Sort.sortModules`.
buildModules :: forall m. Monad m => BuildOptions m -> List (Module Ann) -> m BuildState
buildModules options coreFnModulesUnfiltered =
  foldM go state0 coreFnModules
  where
  state0 = case options.incremental of
    Nothing -> { directives: options.directives, implementations: Map.empty, built: Set.empty }
    Just incrementalState ->
      let r = trimIncrementalState coreFnModulesUnfiltered incrementalState
      -- These directives are only module exports, but we also need to include
      -- the global directives first
      in r { directives = Map.union options.directives r.directives }
  coreFnModules = mapWithIndex Tuple $ coreFnModulesUnfiltered
    # List.filter \(Module { name }) -> not $ Set.member name state0.built
  moduleCount = List.length coreFnModules
  go { directives, implementations, built } (Tuple moduleIndex coreFnModule) = do
    let buildEnv = { built, implementations, directives, moduleCount, moduleIndex }
    prepared <- options.onPrepareModule buildEnv coreFnModule
    Tuple backendMod newImplementations <- case prepared of
      Left cachedMod -> do
        let newImplementations = foldrWithIndex Map.insert implementations cachedMod.implementations
        pure (Tuple cachedMod newImplementations)
      Right coreFnModule'@(Module { name }) -> do
        let
          Tuple optimizationSteps compiledMod = toBackendModule coreFnModule'
            { analyzeCustom: options.analyzeCustom
            , currentModule: name
            , currentLevel: 0
            , toLevel: Map.empty
            , implementations
            , moduleImplementations: Map.empty
            , directives
            , dataTypes: Map.empty
            , foreignSemantics: options.foreignSemantics
            , rewriteLimit: 10_000
            , traceIdents: options.traceIdents
            , optimizationSteps: []
            }
          newImplementations = foldrWithIndex Map.insert implementations compiledMod.implementations
        options.onCodegenModule (buildEnv { implementations = newImplementations }) coreFnModule' compiledMod optimizationSteps
        pure (Tuple compiledMod newImplementations)
    pure
      { directives: foldrWithIndex Map.insert directives backendMod.directives
      , implementations: newImplementations
      , built: Set.insert backendMod.name built
      }

trimIncrementalState :: List (Module Ann) -> BuildState -> BuildState
trimIncrementalState _ { built } | Set.isEmpty built =
  { built: Set.empty, directives: Map.empty, implementations: Map.empty }
trimIncrementalState allModules toVerify = { built, directives, implementations }
  where
  depMap = Map.fromFoldable $ allModules <#> \(Module { name, imports }) ->
    Tuple name (Set.filter (not isPrimModule) $ Set.fromFoldable $ imports <#> \(Import _ dep) -> dep)
  -- Trim the `built` set down to modules that are transitively built
  built = trimming $ toVerify.built
  -- Filter the module-export directives down to modules included in `built`
  directives = toVerify.directives # Map.filterKeys case _ of
    EvalExtern (Qualified (Just name) _) -> Set.member name built
    _ -> false
  -- Filter the identifier implementations down to modules included in `built`
  implementations = toVerify.implementations # Map.filterKeys case _ of
    Qualified (Just name) _ -> Set.member name built
    _ -> false

  trim moduleSet = moduleSet # Set.filter \name ->
    case Map.lookup name depMap of
      Nothing -> true -- Just assume it is okay, if dependency information was not included
      Just deps -> Set.subset deps moduleSet
  trimming moduleSet =
    case trim moduleSet of
      reduced | reduced == moduleSet -> moduleSet
      reduced -> trimming reduced
