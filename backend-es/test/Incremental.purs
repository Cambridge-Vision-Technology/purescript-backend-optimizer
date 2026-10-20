module Test.Incremental where

import Prelude

import Data.Array as Data.Array
import Data.Either as Data.Either
import Data.Foldable as Data.Foldable
import Data.List as Data.List
import Data.Map as Data.Map
import Data.Maybe as Data.Maybe
import Data.Set as Data.Set
import Data.Tuple as Data.Tuple
import Dodo as Dodo
import Effect as Effect
import Effect.Class as Effect.Class
import Effect.Class.Console as Effect.Class.Console
import Effect.Exception as Effect.Exception
import Effect.Ref as Effect.Ref
import Node.Path as Node.Path
import Node.Process as Node.Process
import PureScript.Backend.Optimizer.Builder as Builder
import PureScript.Backend.Optimizer.Codegen.EcmaScript as EcmaScript
import PureScript.Backend.Optimizer.Convert as Convert
import PureScript.Backend.Optimizer.CoreFn as CoreFn
import PureScript.Backend.Optimizer.QIMap as QIMap
import PureScript.Backend.Optimizer.Semantics as Semantics
import Test.SnapshotPolicy as Test.SnapshotPolicy
import Test.SnapshotRunner as Test.SnapshotRunner
import Test.Utils as Test.Utils

type Preparation =
  { name :: CoreFn.ModuleName
  , moduleCount :: Int
  , moduleIndex :: Int
  , built :: Data.Set.Set CoreFn.ModuleName
  }

type Observations =
  { preparations :: Array Preparation
  , generated :: Data.Map.Map CoreFn.ModuleName String
  , cached :: Data.Map.Map CoreFn.ModuleName Convert.BackendModule
  }

require :: String -> Boolean -> Effect.Effect Unit
require message condition = unless condition (Effect.Exception.throw message)

span :: CoreFn.SourceSpan
span = { path: "incremental-api.purs", start: { line: 1, column: 1 }, end: { line: 1, column: 1 } }

annotation :: CoreFn.Ann
annotation = CoreFn.Ann { span, meta: Data.Maybe.Nothing }

qualified :: CoreFn.ModuleName -> CoreFn.Qualified CoreFn.Ident
qualified name = CoreFn.Qualified (Data.Maybe.Just name) (CoreFn.Ident "value")

moduleA :: CoreFn.ModuleName
moduleA = CoreFn.ModuleName "Incremental.A"

moduleB :: CoreFn.ModuleName
moduleB = CoreFn.ModuleName "Incremental.B"

moduleC :: CoreFn.ModuleName
moduleC = CoreFn.ModuleName "Incremental.C"

makeModule :: CoreFn.ModuleName -> Array CoreFn.ModuleName -> CoreFn.Expr CoreFn.Ann -> CoreFn.Module CoreFn.Ann
makeModule name dependencies value = CoreFn.Module
  { name
  , path: "incremental-api.purs"
  , span
  , imports: CoreFn.Import annotation <$> Data.Array.cons (CoreFn.ModuleName "Prim") dependencies
  , exports: [ CoreFn.Ident "value" ]
  , reExports: []
  , decls: [ CoreFn.NonRec (CoreFn.Binding annotation (CoreFn.Ident "value") value) ]
  , foreign: []
  , comments: [ CoreFn.LineComment " @inline export value always" ]
  }

modules :: Int -> Data.List.List (CoreFn.Module CoreFn.Ann)
modules seed = Data.List.fromFoldable
  [ makeModule moduleA [] (CoreFn.ExprLit annotation (CoreFn.LitInt seed))
  , makeModule moduleB [ moduleA ] (CoreFn.ExprVar annotation (qualified moduleA))
  , makeModule moduleC [ moduleB ] (CoreFn.ExprVar annotation (qualified moduleB))
  ]

observe
  :: Data.Maybe.Maybe Builder.BuildState
  -> Data.Map.Map CoreFn.ModuleName Convert.BackendModule
  -> Data.Maybe.Maybe (CoreFn.Module CoreFn.Ann)
  -> Data.List.List (CoreFn.Module CoreFn.Ann)
  -> Effect.Effect { state :: Builder.BuildState, observations :: Observations }
observe incremental cached replacement input = do
  observations <- Effect.Ref.new { preparations: [], generated: Data.Map.empty, cached: Data.Map.empty }
  let
    options :: Builder.BuildOptions Effect.Effect
    options =
      { incremental
      , directives: Semantics.noDirectives
      , analyzeCustom: \_ _ -> Data.Maybe.Nothing
      , foreignSemantics: Data.Map.empty
      , traceIdents: Data.Set.empty
      , onPrepareModule: \env coreModule -> do
          let
            name = CoreFn.moduleName coreModule
          Effect.Ref.modify_ (\seen -> seen { preparations = Data.Array.snoc seen.preparations { name, moduleCount: env.moduleCount, moduleIndex: env.moduleIndex, built: env.built } }) observations
          when (name == moduleB) do
            require "Preparation must see the preceding implementation" (QIMap.member (qualified moduleA) env.implementations)
            require "Preparation must see the preceding export directive"
              (Data.Map.member Semantics.InlineRef (Semantics.lookupDirective (Semantics.EvalExtern (qualified moduleA)) env.directives))
          pure case Data.Map.lookup name cached of
            Data.Maybe.Just backendModule -> Data.Either.Left backendModule
            Data.Maybe.Nothing -> Data.Either.Right case replacement of
              Data.Maybe.Just prepared | CoreFn.moduleName prepared == name -> prepared
              _ -> coreModule
      , onCodegenModule: \env prepared backendModule _ -> do
          let
            name = CoreFn.moduleName prepared
            rendered = Dodo.print Dodo.plainText Dodo.twoSpaces (EcmaScript.codegenModule { intTags: false } env.implementations backendModule)
          require "Codegen must see the current implementation" (QIMap.member (qualified name) env.implementations)
          require "Codegen must precede marking the current module built" (not (Data.Set.member name env.built))
          Effect.Ref.modify_
            (\seen -> seen { generated = Data.Map.insert name rendered seen.generated, cached = Data.Map.insert name backendModule seen.cached })
            observations
      }
  state <- Builder.buildModules options input
  seen <- Effect.Ref.read observations
  pure { state, observations: seen }

cleanReuse :: Effect.Effect Unit
cleanReuse = do
  clean <- observe Data.Maybe.Nothing Data.Map.empty Data.Maybe.Nothing (modules 42)
  let
    expectedBuilt = Data.Set.fromFoldable [ moduleA, moduleB, moduleC ]
  require "Clean build must prepare all three modules in order"
    ( clean.observations.preparations ==
        [ { name: moduleA, moduleCount: 3, moduleIndex: 0, built: Data.Set.empty }
        , { name: moduleB, moduleCount: 3, moduleIndex: 1, built: Data.Set.singleton moduleA }
        , { name: moduleC, moduleCount: 3, moduleIndex: 2, built: Data.Set.fromFoldable [ moduleA, moduleB ] }
        ]
    )
  require "Clean build must return all implementations and built modules"
    (clean.state.built == expectedBuilt && QIMap.moduleNames clean.state.implementations == expectedBuilt)
  require "Clean public codegen output must use the supplied seed transitively"
    (Data.Array.all (_ == "// @inline export value always\nconst value = 42;\nexport {value};\n") (Data.Array.fromFoldable clean.observations.generated) && Data.Map.size clean.observations.generated == 3)
  reused <- observe (Data.Maybe.Just clean.state) Data.Map.empty Data.Maybe.Nothing (modules 42)
  require "A fully reused build must call neither preparation nor codegen"
    (Data.Array.null reused.observations.preparations && Data.Map.isEmpty reused.observations.generated && reused.state.built == expectedBuilt)
  let
    partial = clean.state { built = Data.Set.singleton moduleA }
    trimmed = Builder.trimIncrementalState (modules 42) partial
  require "Trim must discard stale implementations and directives"
    (QIMap.moduleNames trimmed.implementations == Data.Set.singleton moduleA && QIMap.moduleNames (Data.Tuple.fst trimmed.directives) == Data.Set.singleton moduleA)
  rebuilt <- observe (Data.Maybe.Just partial) Data.Map.empty Data.Maybe.Nothing (modules 42)
  require "Partial reuse must renumber just the two remaining modules"
    (map _.moduleIndex rebuilt.observations.preparations == [ 0, 1 ] && map _.moduleCount rebuilt.observations.preparations == [ 2, 2 ])
  require "Partial reuse must retain clean codegen results"
    (rebuilt.observations.generated == Data.Map.delete moduleA clean.observations.generated && rebuilt.state.built == expectedBuilt)
  let
    invalid = clean.state { built = Data.Set.fromFoldable [ moduleB, moduleC ] }
    invalidTrimmed = Builder.trimIncrementalState (modules 99) invalid
  require "Trim must invalidate dependencies transitively"
    (Data.Set.isEmpty invalidTrimmed.built && Data.Set.isEmpty (QIMap.moduleNames invalidTrimmed.implementations) && Data.Set.isEmpty (QIMap.moduleNames (Data.Tuple.fst invalidTrimmed.directives)))
  changed <- observe (Data.Maybe.Just invalid) Data.Map.empty Data.Maybe.Nothing (modules 99)
  require "Invalidated modules must not use stale seed implementations"
    (Data.Map.size changed.observations.generated == 3 && Data.Array.all (_ == "// @inline export value always\nconst value = 99;\nexport {value};\n") (Data.Array.fromFoldable changed.observations.generated))

onPrepareModule :: Effect.Effect Unit
onPrepareModule = do
  clean <- observe Data.Maybe.Nothing Data.Map.empty Data.Maybe.Nothing (modules 42)
  backendA <- case Data.Map.lookup moduleA clean.observations.cached of
    Data.Maybe.Nothing -> Effect.Exception.throw "Missing clean backend module"
    Data.Maybe.Just value -> pure value
  cached <- observe Data.Maybe.Nothing (Data.Map.singleton moduleA backendA) Data.Maybe.Nothing (modules 99)
  require "Left must skip codegen only for the cached module, not preparation"
    (map _.name cached.observations.preparations == [ moduleA, moduleB, moduleC ] && Data.Map.size cached.observations.generated == 2)
  require "Left must carry cached implementations and export directives into dependents"
    (cached.observations.generated == Data.Map.delete moduleA clean.observations.generated && cached.state.built == clean.state.built)
  let
    originalA = makeModule moduleA [] (CoreFn.ExprLit annotation (CoreFn.LitInt 42))
  prepared <- observe Data.Maybe.Nothing Data.Map.empty (Data.Maybe.Just originalA) (modules 99)
  require "Right must convert and codegen the prepared module, not the original input"
    (prepared.observations.generated == clean.observations.generated)
  combined <- observe (Data.Maybe.Just (clean.state { built = Data.Set.singleton moduleA }))
    (Data.Map.delete moduleA clean.observations.cached)
    Data.Maybe.Nothing
    (modules 99)
  require "State reuse and Left callbacks must compose without codegen"
    (map _.name combined.observations.preparations == [ moduleB, moduleC ] && Data.Map.isEmpty combined.observations.generated && combined.state.built == clean.state.built)

main :: Effect.Effect Unit
main = Test.SnapshotRunner.launch do
  args <- Data.Array.drop 2 <$> Effect.Class.liftEffect Node.Process.argv
  case args of
    [ selector, "--worker" ] -> do
      Effect.Class.liftEffect (Node.Process.chdir (Node.Path.concat [ "backend-es", "test-snapshots" ]))
      Test.SnapshotRunner.writePhase selector Test.SnapshotRunner.Assertions
      Effect.Class.liftEffect case selector of
        "incremental-clean-reuse" -> cleanReuse
        "incremental-on-prepare-module" -> onPrepareModule
        _ -> Effect.Exception.throw "Unknown incremental implementation test selector"
      Effect.Class.Console.error ("implementation test selector=" <> selector <> " count=1 passed")
      Test.SnapshotRunner.writePhase selector Test.SnapshotRunner.Complete
    [ selector ] -> do
      requireSelector selector
      Test.Utils.mkdirp (Node.Path.concat [ "backend-es", "test-snapshots" ])
      argv <- Effect.Class.liftEffect Node.Process.argv
      entry <- Effect.Class.liftEffect case Data.Array.index argv 1 of
        Data.Maybe.Nothing -> Effect.Exception.throw "Missing implementation test entry point"
        Data.Maybe.Just value -> Node.Path.resolve [] value
      receipt <- Test.SnapshotRunner.runSnapshot Test.SnapshotPolicy.normalDeadline entry selector [ selector, "--worker" ] false
      Test.SnapshotRunner.requireSuccess receipt
    _ -> Effect.Class.liftEffect (Effect.Exception.throw "Expected one exact incremental implementation test selector")
  where
  requireSelector selector = Effect.Class.liftEffect
    (require "Unknown incremental implementation test selector" (Data.Foldable.elem selector [ "incremental-clean-reuse", "incremental-on-prepare-module" ]))
