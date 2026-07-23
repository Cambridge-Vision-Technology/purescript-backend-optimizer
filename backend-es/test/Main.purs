module Test.Main where

import Prelude

import Ansi.Codes (Color(..))
import Ansi.Output (foreground, withGraphics)
import ArgParse.Basic (ArgParser)
import ArgParse.Basic as ArgParser
import Data.Array (findMap)
import Data.Array as Array
import Data.Array.NonEmpty (NonEmptyArray)
import Data.Array.NonEmpty as Data.Array.NonEmpty
import Data.Either (Either(..))
import Data.Foldable (foldMap, for_)
import Data.Foldable as Foldable
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, isJust)
import Data.Monoid (power)
import Data.Newtype (unwrap)
import Data.Set (Set)
import Data.Set as Set
import Data.String (Pattern(..))
import Data.String as String
import Data.String.CodeUnits as SCU
import Data.TraversableWithIndex (forWithIndex)
import Data.Tuple (Tuple(..), uncurry)
import Dodo as Dodo
import Effect (Effect)
import Effect.Aff (Aff, Error, attempt, launchAff_)
import Effect.Aff as Error
import Effect.Class (liftEffect)
import Effect.Class.Console as Console
import Effect.Ref as Ref
import Node.ChildProcess as ChildProcess
import Node.Encoding (Encoding(..))
import Node.FS.Aff as FS
import Node.Glob.Basic (expandGlobsCwd)
import Node.Path as Path
import Node.Process as Process
import PureScript.Backend.Optimizer.Builder (buildModules)
import PureScript.Backend.Optimizer.Codegen.EcmaScript (codegenModule)
import PureScript.Backend.Optimizer.Codegen.EcmaScript.Builder (coreFnModulesFromOutput)
import PureScript.Backend.Optimizer.Codegen.EcmaScript.Foreign (esForeignSemantics)
import PureScript.Backend.Optimizer.Convert (BackendModule)
import PureScript.Backend.Optimizer.CoreFn (Comment(..), Ident(..), Module(..), ModuleName(..), Qualified(..))
import PureScript.Backend.Optimizer.Directives (parseDirectiveFile)
import PureScript.Backend.Optimizer.Directives.Defaults (defaultDirectives)
import PureScript.Backend.Optimizer.Semantics.Foreign (coreForeignSemantics)
import PureScript.Backend.Optimizer.Tracer.Printer (printModuleSteps)
import PureScript.CST.Lexer (lexToken)
import PureScript.CST.Types as CST
import Test.SnapshotPolicy as Test.SnapshotPolicy
import Test.SnapshotRunner as Test.SnapshotRunner
import Test.Utils (bufferToUTF8, copyFile, loadModuleMain, mkdirp, spawnFromParent)

type TestArgs =
  { accept :: Boolean
  , filter :: NonEmptyArray String
  , traceIdents :: Set (Qualified Ident)
  , worker :: Boolean
  , diagnosticTimeout :: Boolean
  , diagnosticDescendant :: Boolean
  , deadline :: Test.SnapshotPolicy.Deadline
  }

data TraceChoice
  = TraceToOutput
  | TraceToStdOut

derive instance Eq TraceChoice

argParser :: ArgParser TestArgs
argParser =
  ArgParser.fromRecord
    { accept:
        ArgParser.flag [ "--accept", "-a" ]
          "Accepts snapshot output"
          # ArgParser.boolean
          # ArgParser.default false
    , filter:
        ArgParser.argument [ "--filter", "-f" ]
          "Filter tests matching a prefix"
          # ArgParser.unfolded1
          # ArgParser.default (pure "Snapshot.*")
    , traceIdents:
        ArgParser.argument [ "--trace-rewrites" ]
          "Traces rewrite passes for a top-level definition during optimizations.\n\
          \Outputs results to optimization-traces.txt."
          # ArgParser.unformat "QUALIFIED_NAME"
              ( \str ->
                  case lexToken str of
                    Right (CST.TokLowerName (Just (CST.ModuleName mod)) ident) ->
                      Right $ Set.singleton $ Qualified (Just (ModuleName mod)) (Ident ident)
                    _ ->
                      Left $ "Unable to parse qualified name: " <> str
              )
          # ArgParser.folded
    , worker:
        ArgParser.flag [ "--snapshot-worker" ] "Internal isolated snapshot execution"
          # ArgParser.boolean
          # ArgParser.default false
    , diagnosticTimeout:
        ArgParser.flag [ "--diagnostic-timeout" ] "Exercise deadline cleanup with an owned descendant"
          # ArgParser.boolean
          # ArgParser.default false
    , diagnosticDescendant:
        ArgParser.flag [ "--diagnostic-descendant" ] "Internal deadline-control descendant"
          # ArgParser.boolean
          # ArgParser.default false
    , deadline:
        ArgParser.argument [ "--deadline-ms" ] "Shorter diagnostic snapshot deadline, at most 60000 milliseconds"
          # ArgParser.unformat "MILLISECONDS" Test.SnapshotPolicy.parseDeadline
          # ArgParser.default Test.SnapshotPolicy.normalDeadline
    }

main :: Effect Unit
main = do
  cliArgs <- Array.drop 2 <$> Process.argv
  case ArgParser.parseArgs "test" "" argParser cliArgs of
    Left err -> do
      Console.error $ ArgParser.printArgError err
      Process.setExitCode 1
    Right args
      | args.diagnosticDescendant -> launchAff_ (Test.SnapshotRunner.stallDescendant unit)
      | args.worker -> launchAff_ do
          let
            selector = Data.Array.NonEmpty.head args.filter
          when (Data.Array.NonEmpty.length args.filter /= 1 || String.contains (Pattern "*") selector) do
            Error.throwError (Error.error "Isolated snapshot workers require one exact selector.")
          if args.diagnosticTimeout then Test.SnapshotRunner.stallWorker selector
          else runSnapshotTests args
      | otherwise -> Test.SnapshotRunner.launch (runSelectedSnapshots args)

runSelectedSnapshots :: TestArgs -> Aff Unit
runSelectedSnapshots args = do
  root <- liftEffect Process.cwd
  argv <- liftEffect Process.argv
  entry <- case Array.index argv 1 of
    Nothing -> Error.throwError (Error.error "Missing snapshot runner entry point.")
    Just value -> liftEffect (Path.resolve [] value)
  liftEffect $ Process.chdir $ Path.concat [ "backend-es", "test-snapshots" ]
  compileStarted <- liftEffect Process.uptime
  spawnFromParent "spago" [ "build" ]
  compileEnded <- liftEffect Process.uptime
  Console.error $ "snapshot shared compilation elapsedMs=" <> show ((compileEnded - compileStarted) * 1000.0)
  snapshotDir <- liftEffect Process.cwd
  snapshotPaths <- expandGlobsCwd [ "src/Snapshot.*.purs" ]
  modules <- coreFnModulesFromOutput "output" args.filter >>= case _ of
    Left errors -> Error.throwError (Error.error (show errors))
    Right values -> pure values
  let
    selected = Array.fromFoldable modules # Array.mapMaybe \(Module { name: ModuleName name, path }) ->
      if Set.member (Path.concat [ snapshotDir, path ]) snapshotPaths then Just name
      else Nothing
  Console.error $ "snapshot selection selectors=" <> show (Data.Array.NonEmpty.toArray args.filter) <> " count=" <> show (Array.length selected)
  when (Array.null selected) do
    Error.throwError (Error.error "Empty snapshot selection: count=0; refusing a successful zero-test run.")
  liftEffect $ Process.chdir root
  for_ selected \selector -> do
    let
      traces = foldMap (\(Qualified mod (Ident ident)) -> [ "--trace-rewrites", foldMap (\(ModuleName name) -> name <> ".") mod <> ident ]) args.traceIdents
      workerArgs = [ "--snapshot-worker", "--filter", selector ]
        <> (if args.accept then [ "--accept" ] else [])
        <> (if args.diagnosticTimeout then [ "--diagnostic-timeout" ] else [])
        <> traces
    receipt <- Test.SnapshotRunner.runSnapshot args.deadline entry selector workerArgs args.diagnosticTimeout
    Test.SnapshotRunner.requireSuccess receipt

runSnapshotTests :: TestArgs -> Aff Unit
runSnapshotTests { accept, filter, traceIdents } = do
  liftEffect $ Process.chdir $ Path.concat [ "backend-es", "test-snapshots" ]
  let
    selector = Data.Array.NonEmpty.head filter
  Test.SnapshotRunner.writePhase selector Test.SnapshotRunner.Setup
  snapshotDir <- liftEffect Process.cwd
  snapshotPaths <- expandGlobsCwd [ "src/Snapshot.*.purs" ]
  outputRef <- liftEffect $ Ref.new Map.empty
  let snapshotsOut = "snapshots-out"
  let testOut = Path.concat [ "output-es", selector ]
  mkdirp snapshotsOut
  mkdirp testOut
  coreFnModulesFromOutput "output" filter >>= case _ of
    Left errors -> do
      for_ errors \(Tuple filePath err) -> do
        Console.error $ filePath <> " " <> err
      liftEffect $ Process.exit' 1
    Right coreFnModules -> do
      Test.SnapshotRunner.writePhase selector Test.SnapshotRunner.Codegen
      let { directives } = parseDirectiveFile defaultDirectives
      copyFile (Path.concat [ "..", "runtime.js" ]) (Path.concat [ testOut, "runtime.js" ])
      stepsRef <- liftEffect $ Ref.new []
      coreFnModules # buildModules
        { directives
        , analyzeCustom: \_ _ -> Nothing
        , foreignSemantics: Map.union coreForeignSemantics esForeignSemantics
        , onCodegenModule: \build (Module { name: ModuleName name, path }) backendMod optimizationSteps -> do
            let
              formatted =
                Dodo.print Dodo.plainText (Dodo.twoSpaces { pageWidth = 180, ribbonRatio = 1.0 }) $
                  codegenModule { intTags: false } build.implementations backendMod
            let testFileDir = Path.concat [ testOut, name ]
            let testFilePath = Path.concat [ testFileDir, "index.js" ]
            mkdirp testFileDir
            FS.writeTextFile UTF8 testFilePath formatted
            unless (Set.isEmpty backendMod.foreign) do
              let foreignSiblingPath = fromMaybe path (String.stripSuffix (Pattern (Path.extname path)) path) <> ".js"
              let foreignOutputPath = Path.concat [ testFileDir, "foreign.js" ]
              copyFile foreignSiblingPath foreignOutputPath
            when (name == selector && Set.member (Path.concat [ snapshotDir, path ]) snapshotPaths) do
              void $ liftEffect $ Ref.modify (Map.insert name (Tuple formatted (hasFails backendMod))) outputRef
            unless (Array.null optimizationSteps) do
              liftEffect $ Ref.modify_ (flip Array.snoc (Tuple backendMod.name optimizationSteps)) stepsRef
        , onPrepareModule: \build coreFnMod@(Module { name }) -> do
            let total = show build.moduleCount
            let index = show (build.moduleIndex + 1)
            let padding = power " " (SCU.length total - SCU.length index)
            Console.log $ "[" <> padding <> index <> " of " <> total <> "] Building " <> unwrap name
            pure (Right coreFnMod)
        , traceIdents
        }
      allSteps <- liftEffect (Ref.read stepsRef)
      unless (Array.null allSteps) do
        let allDoc = Dodo.foldWithSeparator (Dodo.break <> Dodo.break) $ uncurry printModuleSteps <$> allSteps
        FS.writeTextFile UTF8 "optimization-traces.txt" $ Dodo.print Dodo.plainText Dodo.twoSpaces allDoc
      outputModules <- liftEffect $ Ref.read outputRef
      Console.error $ "snapshot worker selector=" <> selector <> " count=" <> show (Map.size outputModules)
      when (Map.isEmpty outputModules) do
        Error.throwError (Error.error "Empty snapshot selection: count=0 inside worker.")
      Test.SnapshotRunner.writePhase selector Test.SnapshotRunner.Assertions
      results <- forWithIndex outputModules \name (Tuple output failsWith) -> do
        let
          snapshotFilePath = Path.concat [ snapshotsOut, name <> ".js" ]
          runAcceptedTest = do
            result <- attempt $ foldMap liftEffect =<< loadModuleMain =<< liftEffect (Path.resolve [ testOut, name ] "index.js")
            case result of
              Left err | matchesFail err failsWith -> do
                Console.log $ withGraphics (foreground Red) "✗" <> " " <> name <> " failed."
                Console.log $ Error.message err
                pure false
              Right _ | isJust failsWith -> do
                Console.log $ withGraphics (foreground Red) "✗" <> " " <> name <> " succeeded when it should have failed."
                pure false
              _ ->
                pure true
        attempt (FS.readTextFile UTF8 snapshotFilePath) >>= case _ of
          Left _ -> do
            Console.log $ withGraphics (foreground Yellow) "✓" <> " " <> name <> " saved."
            FS.writeTextFile UTF8 snapshotFilePath output
            pure true
          Right prevOutput
            | output == prevOutput ->
                runAcceptedTest
            | accept -> do
                Console.log $ withGraphics (foreground Yellow) "✓" <> " " <> name <> " accepted."
                FS.writeTextFile UTF8 snapshotFilePath output
                runAcceptedTest
            | otherwise -> do
                Console.log $ withGraphics (foreground Red) "✗" <> " " <> name <> " failed."
                let testFilePath = Path.concat [ testOut, name, "index.js" ]
                res <- liftEffect $ ChildProcess.spawnSync "diff" [ snapshotFilePath, testFilePath ]
                Console.log =<< bufferToUTF8 res.stdout
                pure false
      unless (Foldable.and results) do
        liftEffect $ Process.exit' 1
      Test.SnapshotRunner.writePhase selector Test.SnapshotRunner.Complete

hasFails :: BackendModule -> Maybe String
hasFails = findMap go <<< _.comments
  where
  go = case _ of
    LineComment comm ->
      String.stripPrefix (Pattern "@fails ") (String.trim comm)
    _ ->
      Nothing

matchesFail :: Error -> Maybe String -> Boolean
matchesFail err = case _ of
  Just msg ->
    not $ String.contains (Pattern msg) $ Error.message err
  Nothing ->
    true
