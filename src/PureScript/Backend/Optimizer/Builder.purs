module PureScript.Backend.Optimizer.Builder
  ( BuildEnv
  , BuildOptions
  , BuildState
  , buildModules
  , trimIncrementalState
  ) where

import Prelude

import Data.Either as Data.Either
import Data.FunctorWithIndex as Data.FunctorWithIndex
import Data.List as Data.List
import Data.Map as Data.Map
import Data.Maybe as Data.Maybe
import Data.Set as Data.Set
import Data.Tuple as Data.Tuple
import PureScript.Backend.Optimizer.Analysis as Analysis
import PureScript.Backend.Optimizer.Convert as Convert
import PureScript.Backend.Optimizer.CoreFn as CoreFn
import PureScript.Backend.Optimizer.QIMap as QIMap
import PureScript.Backend.Optimizer.Semantics as Semantics
import PureScript.Backend.Optimizer.Semantics.Foreign as Semantics.Foreign
import PureScript.Backend.Optimizer.Syntax as Syntax

type BuildEnv =
  { implementations :: QIMap.QIMap (Data.Tuple.Tuple Analysis.BackendAnalysis Semantics.ExternImpl)
  , directives :: Semantics.InlineDirectiveMap
  , built :: Data.Set.Set CoreFn.ModuleName
  , moduleCount :: Int
  , moduleIndex :: Int
  }

type BuildState =
  { built :: Data.Set.Set CoreFn.ModuleName
  , directives :: Semantics.InlineDirectiveMap
  , implementations :: QIMap.QIMap (Data.Tuple.Tuple Analysis.BackendAnalysis Semantics.ExternImpl)
  }

type BuildOptions m =
  { analyzeCustom :: Semantics.Ctx -> Syntax.BackendSyntax Semantics.BackendExpr -> Data.Maybe.Maybe Analysis.BackendAnalysis
  , directives :: Semantics.InlineDirectiveMap
  , foreignSemantics :: Data.Map.Map (CoreFn.Qualified CoreFn.Ident) Semantics.Foreign.ForeignEval
  , onPrepareModule :: BuildEnv -> CoreFn.Module CoreFn.Ann -> m (Data.Either.Either Convert.BackendModule (CoreFn.Module CoreFn.Ann))
  , onCodegenModule :: BuildEnv -> CoreFn.Module CoreFn.Ann -> Convert.BackendModule -> Convert.OptimizationSteps -> m Unit
  , traceIdents :: Data.Set.Set (CoreFn.Qualified CoreFn.Ident)
  , incremental :: Data.Maybe.Maybe BuildState
  }

buildModules :: forall m. Monad m => BuildOptions m -> Data.List.List (CoreFn.Module CoreFn.Ann) -> m BuildState
buildModules options allModules = Data.List.foldM go state0 coreFnModules
  where
  foreignSemantics = QIMap.fromMap options.foreignSemantics
  state0 = case options.incremental of
    Data.Maybe.Nothing -> { directives: options.directives, implementations: QIMap.empty, built: Data.Set.empty }
    Data.Maybe.Just incrementalState ->
      let
        trimmed = trimIncrementalState allModules incrementalState
      in
        trimmed { directives = Semantics.unionDirectives options.directives trimmed.directives }
  coreFnModules = Data.FunctorWithIndex.mapWithIndex Data.Tuple.Tuple $ allModules
    # Data.List.filter (not <<< flip Data.Set.member state0.built <<< CoreFn.moduleName)
  moduleCount = Data.List.length coreFnModules
  go { directives, implementations, built } (Data.Tuple.Tuple moduleIndex coreFnModule) = do
    let
      buildEnv = { built, implementations, directives, moduleCount, moduleIndex }
    prepared <- options.onPrepareModule buildEnv coreFnModule
    Data.Tuple.Tuple backendMod newImplementations <- case prepared of
      Data.Either.Left cachedMod ->
        pure (Data.Tuple.Tuple cachedMod (QIMap.union cachedMod.implementations implementations))
      Data.Either.Right preparedModule@(CoreFn.Module { name }) -> do
        let
          Data.Tuple.Tuple optimizationSteps compiledMod = Convert.toBackendModule preparedModule
            { analyzeCustom: options.analyzeCustom
            , currentModule: name
            , currentLevel: 0
            , toLevel: Data.Map.empty
            , implementations
            , moduleImplementations: QIMap.empty
            , directives
            , dataTypes: Data.Map.empty
            , foreignSemantics
            , rewriteLimit: 10_000
            , traceIdents: options.traceIdents
            , optimizationSteps: []
            }
          newImplementations = QIMap.union compiledMod.implementations implementations
        options.onCodegenModule (buildEnv { implementations = newImplementations }) preparedModule compiledMod optimizationSteps
        pure (Data.Tuple.Tuple compiledMod newImplementations)
    pure
      { directives: Semantics.unionDirectives backendMod.directives directives
      , implementations: newImplementations
      , built: Data.Set.insert backendMod.name built
      }

trimIncrementalState :: Data.List.List (CoreFn.Module CoreFn.Ann) -> BuildState -> BuildState
trimIncrementalState _ { built } | Data.Set.isEmpty built =
  { built: Data.Set.empty, directives: Semantics.noDirectives, implementations: QIMap.empty }
trimIncrementalState allModules toVerify = { built, directives, implementations }
  where
  depMap = Data.Map.fromFoldable $ allModules <#> \(CoreFn.Module { name, imports }) ->
    Data.Tuple.Tuple name (Data.Set.filter (not CoreFn.isPrimModule) $ Data.Set.fromFoldable $ CoreFn.importName <$> imports)
  built = trimming toVerify.built
  directives = Data.Tuple.Tuple (QIMap.matchModules built (Data.Tuple.fst toVerify.directives)) Data.Map.empty
  implementations = QIMap.matchModules built toVerify.implementations

  trim moduleSet = moduleSet # Data.Set.filter \name ->
    case Data.Map.lookup name depMap of
      Data.Maybe.Nothing -> true
      Data.Maybe.Just deps -> Data.Set.subset deps moduleSet
  trimming moduleSet = case trim moduleSet of
    reduced | reduced == moduleSet -> moduleSet
    reduced -> trimming reduced
