module Test.CoreFnJson where

import Prelude

import Data.Argonaut as Data.Argonaut
import Data.Array as Data.Array
import Data.Either as Data.Either
import Data.Foldable as Data.Foldable
import Data.Int as Data.Int
import Data.Maybe as Data.Maybe
import Effect as Effect
import Effect.Console as Effect.Console
import Effect.Exception as Effect.Exception
import PureScript.Backend.Optimizer.CoreFn as CoreFn
import PureScript.Backend.Optimizer.CoreFn.Json as CoreFn.Json

data Expected = Accepted Number | Rejected String

type Case = { literal :: String, expected :: Expected }

type Decoder =
  { name :: String
  , decode :: Data.Argonaut.Json -> Data.Either.Either Data.Argonaut.JsonDecodeError (CoreFn.Module CoreFn.Ann)
  }

data Location = Expression | Binder

locations :: Array Location
locations = [ Expression, Binder ]

erlangCases :: Array Case
erlangCases =
  [ { literal: "2147483647", expected: Accepted 2147483647.0 }
  , { literal: "2147483648", expected: Accepted 2147483648.0 }
  , { literal: "9007199254740991", expected: Accepted 9007199254740991.0 }
  , { literal: "-9007199254740991", expected: Accepted (-9007199254740991.0) }
  , { literal: "1000000000000", expected: Accepted 1000000000000.0 }
  , { literal: "-2147483647", expected: Accepted (-2147483647.0) }
  , { literal: "-2147483648", expected: Accepted (-2147483648.0) }
  , { literal: "-2147483649", expected: Accepted (-2147483649.0) }
  , { literal: "-1000000000000", expected: Accepted (-1000000000000.0) }
  , { literal: "0", expected: Accepted 0.0 }
  , { literal: "9007199254740992", expected: Rejected "9007199254740992.0" }
  , { literal: "-9007199254740992", expected: Rejected "-9007199254740992.0" }
  , { literal: "1.5", expected: Rejected "1.5" }
  , { literal: "-1.5", expected: Rejected "-1.5" }
  ]

defaultCases :: Array Case
defaultCases =
  [ { literal: "2147483647", expected: Accepted 2147483647.0 }
  , { literal: "-2147483648", expected: Accepted (-2147483648.0) }
  , { literal: "0", expected: Accepted 0.0 }
  , { literal: "2147483648", expected: Rejected "Int" }
  , { literal: "-2147483649", expected: Rejected "Int" }
  , { literal: "9007199254740991", expected: Rejected "Int" }
  , { literal: "-9007199254740991", expected: Rejected "Int" }
  , { literal: "1000000000000", expected: Rejected "Int" }
  , { literal: "-1000000000000", expected: Rejected "Int" }
  , { literal: "1.5", expected: Rejected "Int" }
  , { literal: "-1.5", expected: Rejected "Int" }
  ]

annotation :: String -> Data.Argonaut.Json -> Data.Either.Either Data.Argonaut.JsonDecodeError CoreFn.Ann
annotation path _ =
  if path == "src/Decoder/Boundaries.purs" then Data.Either.Right CoreFn.emptyAnn
  else Data.Either.Left (Data.Argonaut.TypeMismatch "annotation module path")

erlangDecoders :: Array Decoder
erlangDecoders =
  [ { name: "decodeModuleWithTarget Erlang", decode: CoreFn.Json.decodeModuleWithTarget CoreFn.Json.Erlang }
  , { name: "decodeModuleWithTarget' Erlang", decode: CoreFn.Json.decodeModuleWithTarget' CoreFn.Json.Erlang annotation }
  ]

defaultDecoders :: Array Decoder
defaultDecoders =
  [ { name: "decodeModule", decode: CoreFn.Json.decodeModule }
  , { name: "decodeModule'", decode: CoreFn.Json.decodeModule' annotation }
  , { name: "decodeModuleWithTarget JavaScript", decode: CoreFn.Json.decodeModuleWithTarget CoreFn.Json.JavaScript }
  , { name: "decodeModuleWithTarget' JavaScript", decode: CoreFn.Json.decodeModuleWithTarget' CoreFn.Json.JavaScript annotation }
  ]

moduleInput :: Location -> String -> String
moduleInput location literal =
  """{"moduleName":["Decoder","Boundaries"],"modulePath":"src/Decoder/Boundaries.purs","sourceSpan":{"start":[1,1],"end":[1,2]},"imports":[],"exports":["value"],"reExports":{},"foreign":[],"comments":[],"decls":[{"bindType":"NonRec","annotation":{},"identifier":"value","expression":"""
    <> expression
    <> "}]}"
  where
  intLiteral = """{"literalType":"IntLiteral","value":""" <> literal <> "}"
  literalExpression = """{"annotation":{},"type":"Literal","value":""" <> intLiteral <> "}"
  recordExpression = """{"annotation":{},"type":"Literal","value":{"literalType":"ObjectLiteral","value":[["integer",""" <> literalExpression <> "]]}}"
  arrayExpression = """{"annotation":{},"type":"Literal","value":{"literalType":"ArrayLiteral","value":[""" <> recordExpression <> "]}}"
  literalBinder = """{"annotation":{},"binderType":"LiteralBinder","literal":""" <> intLiteral <> "}"
  recordBinder = """{"annotation":{},"binderType":"LiteralBinder","literal":{"literalType":"ObjectLiteral","value":[["integer",""" <> literalBinder <> "]]}}"
  arrayBinder = """{"annotation":{},"binderType":"LiteralBinder","literal":{"literalType":"ArrayLiteral","value":[""" <> recordBinder <> "]}}"
  expression = case location of
    Expression ->
      """{"annotation":{},"type":"Let","binds":[{"bindType":"Rec","binds":[{"annotation":{},"identifier":"nested","expression":"""
        <> arrayExpression
        <> """}]}],"expression":{"annotation":{},"type":"Var","value":{"identifier":"nested"}}}"""
    Binder ->
      """{"annotation":{},"type":"Case","caseExpressions":[],"caseAlternatives":[{"isGuarded":false,"binders":[{"annotation":{},"binderType":"NamedBinder","identifier":"named","binder":"""
        <> arrayBinder
        <> """}],"expression":{"annotation":{},"type":"Literal","value":{"literalType":"BooleanLiteral","value":true}}}]}"""

decodedInteger :: forall a. Location -> CoreFn.Module a -> Data.Maybe.Maybe Number
decodedInteger location (CoreFn.Module decoded) = case location, decoded.decls of
  Expression,
  [ CoreFn.NonRec
      ( CoreFn.Binding _ _
          ( CoreFn.ExprLet _
              [ CoreFn.Rec
                  [ CoreFn.Binding _ _
                      ( CoreFn.ExprLit _
                          ( CoreFn.LitArray
                              [ CoreFn.ExprLit _ (CoreFn.LitRecord [ CoreFn.Prop "integer" (CoreFn.ExprLit _ (CoreFn.LitInt integer)) ]) ]
                          )
                      )
                  ]
              ]
              _
          )
      )
  ] -> Data.Maybe.Just (Data.Int.toNumber integer)
  Binder,
  [ CoreFn.NonRec
      ( CoreFn.Binding _ _
          ( CoreFn.ExprCase _ _
              [ CoreFn.CaseAlternative
                  [ CoreFn.BinderNamed _ _
                      ( CoreFn.BinderLit _
                          ( CoreFn.LitArray
                              [ CoreFn.BinderLit _ (CoreFn.LitRecord [ CoreFn.Prop "integer" (CoreFn.BinderLit _ (CoreFn.LitInt integer)) ]) ]
                          )
                      )
                  ]
                  _
              ]
          )
      )
  ] -> Data.Maybe.Just (Data.Int.toNumber integer)
  _, _ -> Data.Maybe.Nothing

integerError :: Data.Argonaut.JsonDecodeError -> Data.Argonaut.JsonDecodeError
integerError (Data.Argonaut.AtIndex _ error) = integerError error
integerError error = error

checkCase :: Boolean -> Decoder -> Location -> Case -> Effect.Effect Unit
checkCase erlang decoder location test = do
  json <- case Data.Argonaut.jsonParser (moduleInput location test.literal) of
    Data.Either.Left error -> Effect.Exception.throw ("Invalid CoreFn test input: " <> error)
    Data.Either.Right value -> pure value
  let
    result = decoder.decode json
    matched = case test.expected, result of
      Accepted expected, Data.Either.Right decoded -> decodedInteger location decoded == Data.Maybe.Just expected
      Rejected expected, Data.Either.Left error ->
        integerError error == Data.Argonaut.TypeMismatch
          ( if erlang then
              "IntLiteral in module Decoder.Boundaries: expected an integer within [-9007199254740991, 9007199254740991], received " <> expected
            else expected
          )
      _, _ -> false
    context = decoder.name <> " literal=" <> test.literal <> " location=" <> case location of
      Expression -> "expression"
      Binder -> "binder"
  unless matched (Effect.Exception.throw (context <> " failed: " <> Data.Either.either Data.Argonaut.printJsonDecodeError (const "unexpected decoded module/value") result))

main :: Effect.Effect Unit
main = do
  Data.Foldable.for_ erlangDecoders \decoder ->
    Data.Foldable.for_ locations \location ->
      Data.Foldable.for_ erlangCases (checkCase true decoder location)
  Data.Foldable.for_ defaultDecoders \decoder ->
    Data.Foldable.for_ locations \location ->
      Data.Foldable.for_ defaultCases (checkCase false decoder location)
  let
    assertions = Data.Array.length locations * (Data.Array.length erlangCases * Data.Array.length erlangDecoders + Data.Array.length defaultCases * Data.Array.length defaultDecoders)
  Effect.Console.error ("implementation test selector=corefn-int-literals count=1 cases=25 assertions=" <> show assertions <> " passed")
