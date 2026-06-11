# Grammar — Lexical Structure and Syntax

The lexical and syntactic surface of q64, gathered into one place. This
spec is the union of the "Grammar (informal)" sections previously scattered
across [`modules.md`](./modules.md), [`faces.md`](./faces.md),
[`generics.md`](./generics.md), [`concurrency.md`](./concurrency.md),
[`streams.md`](./streams.md), [`effects.md`](./effects.md),
[`errors.md`](./errors.md), [`memory.md`](./memory.md),
[`types.md`](./types.md), and [`env.md`](./env.md), reconciled into a
single grammar and supplemented with the connective tissue (top-level
program, expressions, statements, patterns) those specs assumed.

> **Status: draft (v0).** Surface forms are derived from the spec
> corpus as it stands after coherence audits PR #3–#7. Four areas are
> known under-specified and called out inline as `(* open *)`: the full
> pattern grammar (guards, or-patterns, exhaustive struct destructuring),
> region-parameter elision in `fn` signatures, the result-builder graph
> DSL beyond `graph { let … }`, and operator overloading on units.
> These items still need new design work.

## Notation

EBNF-style. The grammar is split into a lexical layer (tokens) and a
syntactic layer (productions over tokens). Lexical productions are
lowercase or `UPPER_CASE` for token classes; syntactic productions are
`PascalCase`.

```
A := B                  -- A is defined as B
A | B                   -- alternation; A or B
A?                      -- zero or one A
A*                      -- zero or more A
A+                      -- one or more A
A , B                   -- juxtaposition (in lexical rules, no implicit ws)
"keyword"               -- literal keyword
'c'                     -- literal character
[a-z]                   -- character class (lexical only)
(* note *)              -- non-normative comment
```

Outside lexical rules, juxtaposition implies optional whitespace between
tokens. Within lexical rules, juxtaposition is character-by-character.
The grammar is presented LL(k)-style with named lookahead notes; the
parser may implement any algorithm that recognizes the same language.

## Lexical structure

### Source encoding and whitespace

A q64 source file is a sequence of UTF-8 code points. The compiler
normalizes input via NFC before tokenization. Permitted whitespace
characters are `' '`, `'\t'`, `'\r'`, `'\n'`. The `'\r\n'` pair is
treated as a single newline; bare `'\r'` is `LEX010` ("stray carriage
return").

```
WS_INLINE := (' ' | '\t')+
NEWLINE   := '\n' | '\r\n'
```

Indentation is **not** syntactically significant. A `NEWLINE` outside
any `(` `[` `{` group and outside a continuation-yielding token (binary
operator, comma, open-bracket) terminates the current statement. An
explicit `;` may always be used as a statement separator and is never
required.

### Comments

```
LineComment := "//"   (~ NEWLINE)* NEWLINE
DocComment  := "//!"  (~ NEWLINE)* NEWLINE
```

`//!` doc comments at the top of a file form the module header (per
[`modules.md` §"Module-header doc comment"](./modules.md)). Block
comments are not in v0.

### Identifiers and keywords

```
IDENT       := IDENT_START IDENT_CONT*
IDENT_START := [A-Za-z_]
IDENT_CONT  := [A-Za-z0-9_]
```

`Self` (capitalized) is the implicit self-type inside a single-parameter
`face` body and is a reserved identifier. `self` (lowercase) is the
receiver-parameter name and is similarly reserved.

Reserved keywords:

```
actor   as      break    catch    const    continue
draw    dyn     else     enum     effect   face
fit     fn      for      forall   from     graph
handle  if      import   in       law      let
loop    match   move     on       out      panic
pub     ref     region   return   screen   scope
select  spawn   state    tell     trap     try
type    use     var      where    while
with_capabilities
```

`screen`, `draw`, and `on` are the QView frontend-DSL keywords (see
§"Screen declarations" and [`reactivity.md`](./reactivity.md)).

`Self`, `self`, and the auto-prelude names listed in
[`modules.md` §"The auto-prelude"](./modules.md) (`Vec`, `Option`,
`Result`, `Region`, `Arena`, …) are **not** keywords — they are ordinary
identifiers bound by the prelude.

### Numeric literals

```
INT_LIT      := DEC_INT | HEX_INT | OCT_INT | BIN_INT
DEC_INT      := DEC_DIGIT (DEC_DIGIT | '_')*
HEX_INT      := "0x" HEX_DIGIT (HEX_DIGIT | '_')*
OCT_INT      := "0o" OCT_DIGIT (OCT_DIGIT | '_')*
BIN_INT      := "0b" BIN_DIGIT (BIN_DIGIT | '_')*

FLOAT_LIT    := DEC_INT '.' DEC_DIGIT (DEC_DIGIT | '_')* FLOAT_EXP?
              | DEC_INT FLOAT_EXP
FLOAT_EXP    := ('e' | 'E') ('+' | '-')? DEC_DIGIT+

NUM_LITERAL  := (INT_LIT | FLOAT_LIT) Suffix?
Suffix       := '.' IDENT           (* type/width/unit suffix *)
```

A `Suffix` selects between (a) a primitive numeric type name
(`42.i32`, `1.u8`), (b) an arbitrary-width integer name (`0xFF.u24`),
and (c) a unit suffix (`48.kHz`, `-6.dB`, `1.MB`). Disambiguation is
mechanical: the trailing identifier names the target. Per
[`types.md` §"Numeric literals and suffixes"](./types.md), an unknown
suffix on an integer literal that looks like it could parse as a float
(`42.kHz`) resolves as the suffix form — the suffix rule beats float
interpretation when the trailing token is an identifier.

`_` underscores within the digit run are visual separators only and
carry no value.

### String literals

Three forms. Each either produces a `str` (when the literal is a
compile-time constant) or a `String<R>` in the enclosing scope's arena
(when the form does runtime work).

```
STR_PLAIN      := '"' StrItem* '"'
STR_RAW        := 'r' HASH* '"' RawItem* '"' HASH*
                  (* the HASH* on both sides must match; any non-negative
                     count permitted *)
STR_TYPED      := IDENT (STR_PLAIN | STR_RAW)
                  (* the IDENT is the typed prefix: url"…", re"…", … *)
HASH           := '#'

StrItem        := EscapeSeq
                | Interpolation
                | (~ ('"' | '\\' | '{'))
RawItem        := (~ '"')               (* no escapes, no interpolation *)

Interpolation  := '{' Expr '}'
                | "{{"                   (* literal { *)
                | "}}"                   (* literal } *)
EscapeSeq      := '\\' ('n' | 't' | 'r' | '0' | '\\' | '"' | '{' | '}')
                | '\\' 'x' HEX_DIGIT HEX_DIGIT
                | '\\' 'u' '{' HEX_DIGIT{1,6} '}'
```

A `STR_TYPED` whose `IDENT` does not name a reachable `StringLit` fit
is `LEX020` ("unknown string-literal prefix"). The set of in-scope
typed prefixes is governed by the auto-prelude rule in
[`modules.md` §"Typed-prefix string literals"](./modules.md). Triple-
quoted `"""…"""` is reserved syntax; full semantics land with a future
revision.

### Punctuators and operator tokens

```
( ) [ ] { } < > , ; : :: . .. ..= ? ?. -> => = |
+ - * / % ! & ^ ~ << >>
== != <= >= && || += -= *= /= %=
|>                      (* pipe; see Expressions *)
@                       (* annotation / effect prefix *)
```

`&` does **not** appear in type position (per
[`types.md` §"References"](./types.md)) — `LEX021` ("unexpected
character `&` in type position"). `&` is valid at expression level as
bitwise-and.

### Token-level disambiguation

The `<` and `>` tokens are reused for both generic brackets and
comparisons. Per [`generics.md` §"Why no turbofish"](./generics.md),
the disambiguation rule is context-sensitive:

- A `<` immediately following an identifier that resolves to a generic
  item parses as the open of `GenericArgs`.
- A `<` immediately following an expression of value type parses as
  less-than.
- Cases the parser cannot resolve from context are `PAR040` ("generic
  vs less-than ambiguity") with a repair suggesting parenthesization.

## Source files and items

A source file is a sequence of top-level items, optionally preceded by
a module-header doc comment and any number of imports.

```
SourceFile  := DocComment? ImportStmt* Item*

Item        := Visibility? ItemKind
ItemKind    := FnDecl
             | StructDecl
             | EnumDecl
             | TypeDecl
             | FaceDecl
             | FitDecl
             | ConstDecl
             | StateDecl
             | ScreenDecl
             | ActorDecl
             | EffectDecl
             | GraphDecl
             | ReExport

Visibility  := "pub"
```

Per [`modules.md` §"Block `pub` is forbidden"](./modules.md), the
block-`Visibility "{" Item* "}"` form is intentionally absent.
`pub` always prefixes a single item.

## Imports and re-exports

Per [`modules.md` §"Import grammar"](./modules.md):

```
ImportStmt       := "import" ImportPath ImportBinding?
ImportPath       := BareDotted | QuotedRelative
BareDotted       := IDENT ("." IDENT)*
QuotedRelative   := STR_PLAIN          (* the path is the literal's content *)
ImportBinding    := SelectiveList | AliasBinding
SelectiveList    := "." "{" IDENT ("," IDENT)* "}"
AliasBinding     := "as" IDENT

ReExport         := "pub" "use" ReExportSpec "from" ImportPath
ReExportSpec     := IDENT ("as" IDENT)?
                  | IDENT ("," IDENT)+        (* multi-name list *)
                  | SelectiveList             (* `.{a, b}` desugared above *)
```

Combinations forbidden by the spec but expressible in the grammar:

- Wildcards (`*`) in any import are `NAM003`.
- `SelectiveList` combined with `AliasBinding` is `NAM004`.
- Dashes in a `BareDotted` segment are `NAM011`.

## Type expressions

```
TypeExpr     := PathType
              | RefType
              | DynType
              | FnType
              | UnionType
              | ArrayType
              | SliceType
              | OptionalType
              | TupleType

PathType     := IDENT ("." IDENT)* GenericArgs?     (* Vec<i64>, q64.net.Url, Iterator.Item *)
RefType      := "ref" TypeExpr
DynType      := "dyn" FaceRef
FnType       := "fn" "(" FnTypeParams? ")" ("->" TypeExpr)? EffectSpec?
FnTypeParams := FnTypeParam ("," FnTypeParam)*
FnTypeParam  := ParamMode? IDENT ":" TypeExpr
              | ParamMode? TypeExpr               (* anonymous; tuple-like *)

UnionType    := TypeExpr ("|" TypeExpr)+           (* E1 | E2 sum sugar; per errors.md *)
ArrayType    := "[" TypeExpr ";" ConstExpr "]"     (* [T; N] *)
SliceType    := "[" TypeExpr "]"                   (* [T] *)
OptionalType := TypeExpr "?"                       (* T? sugar for Option<T> *)
TupleType    := "(" TypeExpr ("," TypeExpr)+ ","? ")"
              | "(" ")"                            (* unit *)

FaceRef      := PathType                           (* face name + optional GenericArgs *)
```

Per [`types.md` §"References"](./types.md), the `ref` keyword is
reused in three places: as a parameter mode (§Functions), in type
position (above), and in expression position (`ref binding`). The
parse is unambiguous because each occurrence sits in a syntactically
distinct slot.

## Generic parameters and arguments

Per [`generics.md` §Grammar](./generics.md):

```
GenericParams := "<" GenericParam ("," GenericParam)* ","? ">"
GenericParam  := TypeParam | ConstParam | RegionParam | EffectParam
TypeParam     := IDENT (":" BoundList)? ("=" TypeExpr)?
ConstParam    := "const" IDENT ":" TypeExpr ("=" ConstExpr)?
RegionParam   := IDENT ":" "Region" ("=" RegionExpr)?
EffectParam   := "@" IDENT ("=" EffectExpr)?

GenericArgs   := "<" GenericArg ("," GenericArg)* ","? ">"
GenericArg    := TypeExpr | ConstExpr | RegionExpr | EffectExpr

WhereClause   := "where" Bound ("," Bound)* ","?
Bound         := IDENT ":" BoundList                (* T: Eq + Ord *)
              | TypeExpr ":" BoundList              (* I.Item: Eq *)
              | FaceRef                             (* Convert<A, B> *)
BoundList     := FaceRef ("+" FaceRef)*

RegionExpr    := PathType                           (* a value-typed region binding *)
EffectExpr    := EffectMarker ("+" EffectMarker)*
EffectMarker  := "@" IDENT
ConstExpr     := Expr                               (* restricted by typeck to v0's permitted const set *)
```

The four parameter kinds may appear in any order; convention is types,
then consts, then regions, then effect variables.

## Functions

```
FnDecl        := "fn" IDENT GenericParams?
                  "(" Params? ")"
                  ("->" TypeExpr)?
                  EffectSpec?
                  WhereClause?
                  Block

Params        := Param ("," Param)* ","?
Param         := ParamMode? IDENT ":" TypeExpr
ParamMode     := "in" | "ref" | "out" | "move"

EffectSpec    := EffectMarker ("+" EffectMarker)*
```

Notes:

- `in` is the default mode and is usually omitted (per
  [`types.md` §"Parameter modes"](./types.md)).
- Call sites do **not** repeat the mode keyword. A call argument is
  always a bare expression; using `process(in: x)`-style is `TYP060`.
- A face-typed `Param` introduces an implicit anonymous generic per
  [`generics.md` §"Implicit face parameters"](./generics.md). The
  desugaring is performed after parsing.
- Region-parameter concrete syntax in `fn` signatures beyond what is
  spelled out by the explicit `R: Region` form is **(* open *)** per
  MIGRATION.md — defaults and elision rules are not yet pinned.

## Bindings, locals, and constants

```
ConstDecl     := "const" IDENT ":" TypeExpr "=" Expr
LetStmt       := "let" Pattern (":" TypeExpr)? "=" Expr
              | "let" IDENT ":" TypeExpr                  (* declared, definitely-assigned later *)
VarStmt       := "var" IDENT (":" TypeExpr)? ("=" Expr)?
```

`let` is immutable after init; `var` is mutable. The definitely-
assigned form (declared without `=`, assigned on every branch before
first use) is permitted for both per
[`types.md` §"Bindings"](./types.md).

## Struct, enum, and type declarations

```
StructDecl   := "struct" IDENT GenericParams? StructBody
StructBody   := RecordBody | TupleBody | UnitBody
RecordBody   := "{" Field ("," Field)* ","? "}"
Field        := IDENT ":" TypeExpr
TupleBody    := "(" TypeExpr ("," TypeExpr)* ","? ")"
UnitBody     := (* empty; bare `struct Name` with no body *)

EnumDecl     := "enum" IDENT GenericParams? "{" Variant ("," Variant)* ","? "}"
Variant      := IDENT VariantPayload?
VariantPayload := "(" TypeExpr ("," TypeExpr)* ","? ")"   (* tuple-like *)
               | "{" Field ("," Field)* ","? "}"          (* record-like *)

TypeDecl     := "type" IDENT GenericParams? "=" TypeExpr
```

Per [`types.md` §"Tuple structs"](./types.md):
`struct Name(T1, …)` is the tuple form; field access uses `.0`,
`.1`, etc.; the record and tuple forms cannot mix in a single
declaration. The bare unit form `struct Name` is permitted; empty
tuple `struct Name()` is **not** in v0.

Variant names are PascalCase, matching the rule in
[`errors.md` §"Result and Option"](./errors.md).

## Faces and fits

Per [`faces.md` §Grammar](./faces.md):

```
FaceDecl       := "face" IDENT GenericParams? FaceSuperList? FaceBody
FaceSuperList  := ":" FaceRef ("+" FaceRef)*
FaceBody       := "{" FaceItem* "}"
FaceItem       := TypeAlias | MethodSig | LawDecl
TypeAlias      := "type" IDENT ("=" TypeExpr)?
MethodSig      := "fn" IDENT GenericParams? "(" Params? ")"
                  ("->" TypeExpr)? EffectSpec? WhereClause?
                  MethodBody?              (* body present = default impl *)
MethodBody     := Block
LawDecl        := "law" IDENT ":" "forall" QuantList "=>" Expr
QuantList      := QuantBind ("," QuantBind)*
QuantBind      := IDENT (":" TypeExpr)?

FitDecl        := "fit" FitSpec WhereClause? FitBody
FitSpec        := TypeExpr ":" FaceRef           (* single-param face *)
                | FaceRef                          (* multi-param face *)
FitBody        := "{" FitItem* "}"
FitItem        := TypeAlias | MethodDecl
MethodDecl     := "fn" IDENT GenericParams? "(" Params? ")"
                  ("->" TypeExpr)? EffectSpec? WhereClause? Block
```

A face declaration's `GenericParams` may include effect variables
(`@e`) per [`faces.md` §"Effect-polymorphic faces"](./faces.md). The
substitution that fixes those variables happens in the typechecker;
the grammar does not distinguish effect-polymorphic faces from plain
ones.

## Effect declarations

Per [`effects.md` §"User-defined effects"](./effects.md):

```
EffectDecl := "effect" "@" IDENT
              (* the @ name must match ^@[a-z][a-z_]*$;
                 typechecker enforces, grammar does not *)
```

A user-defined effect is a pure declaration; it has no body. Its name
is the `@IDENT` token; the grammar admits `@CamelCase` but the
typechecker rejects with `EFF141`.

## Annotations

Annotations attach to declarations. They are written before the
declaration, on the same line or on a preceding line.

```
Annotation     := "@" IDENT ("(" AnnotationArgs? ")")?
AnnotationArgs := AnnotationArg ("," AnnotationArg)* ","?
AnnotationArg  := Expr                                  (* @derive(Eq, Hash) *)
                | IDENT "=" Expr                        (* @kind(name = …) — future *)
                | "*"                                   (* @no_derive(*) *)

AnnotatedItem  := Annotation* Item
```

The blessed annotation set, the four categories
(compiler-known markers, declaration markers, derive forms,
property wrappers), the casing convention, the position table,
and the `ANN` diagnostic band live in
[`annotations.md`](./annotations.md). This file fixes the
grammar; `annotations.md` fixes the catalog.

The `@`-name lexical class is shared with effect markers; the position
disambiguates. An `@`-name on a declaration line is an `Annotation`;
the same `@`-name after a return type is an `EffectMarker`.

## Patterns

Used by `match` arms, `let` destructuring, `if let`, `for` heads, and
`select` arm bindings.

```
Pattern        := WildPattern
                | LiteralPattern
                | IdentPattern
                | TuplePattern
                | TupleStructPattern
                | RecordStructPattern
                | EnumVariantPattern

WildPattern        := "_"
LiteralPattern     := NUM_LITERAL | STR_PLAIN | "true" | "false"
IdentPattern       := IDENT                       (* binds the matched value *)
TuplePattern       := "(" Pattern ("," Pattern)* ","? ")"
TupleStructPattern := PathType "(" Pattern ("," Pattern)* ","? ")"
RecordStructPattern := PathType "{" FieldPattern ("," FieldPattern)* ","? "}"
FieldPattern       := IDENT (":" Pattern)?
EnumVariantPattern := PathType                     (* nullary variant: None, Cancelled *)
                    | PathType "(" Pattern ("," Pattern)* ","? ")"
                    | PathType "{" FieldPattern ("," FieldPattern)* ","? "}"
```

**Deferred (* open *):** match guards (`Pattern if cond`), or-patterns
(`A | B`), nested struct destructuring beyond a single level, range
patterns, and exhaustiveness rules. Per MIGRATION.md, the full pattern
grammar is one of the four open items. The forms above are what the
current spec corpus exercises; they are the v0 floor.

## Statements

```
Stmt          := LetStmt
              | VarStmt
              | AssignStmt
              | ExprStmt
              | IfStmt
              | MatchStmt
              | ForStmt
              | LoopStmt
              | WhileStmt
              | BreakStmt
              | ContinueStmt
              | ReturnStmt
              | RegionStmt
              | ScopeStmt
              | SelectStmt
              | PanicStmt
              | WithCapsStmt

Block         := "{" Stmt* TailExpr? "}"
TailExpr      := Expr                            (* expression-as-value of the block *)

AssignStmt    := LValue AssignOp Expr
LValue        := Expr                            (* restricted by typeck; must be assignable *)
AssignOp      := "=" | "+=" | "-=" | "*=" | "/=" | "%="
ExprStmt      := Expr

IfStmt        := "if" IfCond Block ("else" (IfStmt | Block))?
IfCond        := Expr                            (* boolean *)
              | "let" Pattern "=" Expr           (* if-let *)

MatchStmt     := "match" Expr "{" MatchArm ("," MatchArm)* ","? "}"
MatchArm      := Pattern "->" (Block | Expr)

ForStmt       := "for" Pattern "in" Expr Block
LoopStmt      := "loop" Block
WhileStmt     := "while" Expr Block
BreakStmt     := "break" Expr?
ContinueStmt  := "continue"
ReturnStmt    := "return" Expr?

RegionStmt    := "region" IDENT ":" TypeExpr Block

PanicStmt     := "panic" Expr                    (* expr's type must fit Panic *)

WithCapsStmt  := "with_capabilities" "(" CapsOverrides ")" Block
CapsOverrides := CapsUse ("," CapsDeny)?
              | CapsDeny ("," CapsUse)?
CapsUse       := "use" ":" "{" CapField ("," CapField)* ","? "}"
CapsDeny      := "deny" ":" "[" FaceRef ("," FaceRef)* ","? "]"
CapField      := IDENT ":" Expr        (* e.g., net: MockNet.new() *)
```

Notes:

- `match`, `if`, `loop`, `scope`, and block expressions all yield
  values; "statement" and "expression" forms share productions. The
  `TailExpr` in a block is the block's value.
- `panic` is grammatically a statement in v0 (its return type is
  divergent). A future revision may admit `panic` in expression
  position; this is consistent with `errors.md`'s requirement that the
  payload fits `Panic`.

## Concurrency forms

Per [`concurrency.md` §Grammar](./concurrency.md):

```
ScopeStmt     := "scope" EffectAnnot? Block CatchArm*
EffectAnnot   := EffectMarker ("+" EffectMarker)*
CatchArm      := "catch" "(" IDENT ":" TypeExpr ")" Block

SpawnExpr     := "spawn" Block
              | "spawn" "scope" EffectAnnot? Block CatchArm*

ActorDecl     := "actor" IDENT GenericParams? ActorBody
ActorBody     := "{" ActorItem* "}"
ActorItem     := StateDecl | HandleDecl
StateDecl     := "state" IDENT (":" TypeExpr)? ("=" Expr)?
HandleDecl    := "handle" IDENT ("(" Params? ")")? ("->" TypeExpr)? Block

(* QView frontend DSL — spec/reactivity.md, spec/agent-ui.md. A `screen`
   groups reactive `state`, a declarative `draw` block of widget calls, and
   `on <event>` handlers; the view is written once in `draw` and a handler
   mutates state (the compiler re-emits the view). Lowers to the `qview.*`
   mutation ops. *)
ScreenDecl    := "screen" IDENT? "{" ScreenMember* "}"
ScreenMember  := StateDecl | DrawBlock | OnHandler
DrawBlock     := "draw" Block
OnHandler     := "on" IDENT ("(" Params? ")")? Block

ChannelExpr   := "channel" GenericArgs? "(" ChanArgs ")"
ChanArgs      := NamedArg ("," NamedArg)* ","?
NamedArg      := IDENT ":" Expr                 (* policy: …, capacity: …, region: … *)

SelectStmt    := "select" "{" SelectArm ("," SelectArm)* ","? "}"
SelectArm     := (Pattern "=")? Expr "->" (Block | Expr)
```

`spawn scope EffectAnnot? Block` is sugar for
`spawn { scope EffectAnnot? Block }` per
[`concurrency.md` §"Scope effect annotations"](./concurrency.md). The
parser produces the same AST as the desugared form.

## Stream forms

Per [`streams.md` §Grammar](./streams.md):

```
GraphDecl     := "graph" IDENT GenericParams?
                  "(" Params? ")" ("->" TypeExpr)?
                  Block

GraphExpr     := "graph" IDENT? Block            (* anonymous form; let g = graph { … } *)
```

A `graph` body is a sequence of `LetStmt`s whose RHS is a stage call or
a `|>` pipeline. The compiler walks the desugared call tree to build
the topology. The DSL form admits no other statement kinds in v0;
richer result-builder syntax (parallel splits, fan-in / fan-out
operators beyond `|>`) is **(* open *)** per MIGRATION.md and
[`streams.md` §"Open items deferred"](./streams.md).

The `@stage` and `@fuse` annotations attach to ordinary `fn`
declarations; they are not separate productions.

## Expressions

```
Expr          := AssignExpr
AssignExpr    := PipeExpr (AssignOp PipeExpr)*    (* parsed as a statement; here for completeness *)
PipeExpr      := OrExpr ("|>" OrExpr)*
OrExpr        := AndExpr ("||" AndExpr)*
AndExpr       := CmpExpr ("&&" CmpExpr)*
CmpExpr       := BitOrExpr (CmpOp BitOrExpr)?
BitOrExpr     := BitXorExpr ("|" BitXorExpr)*
BitXorExpr    := BitAndExpr ("^" BitAndExpr)*
BitAndExpr    := ShiftExpr ("&" ShiftExpr)*
ShiftExpr     := AddExpr (("<<" | ">>") AddExpr)*
AddExpr       := MulExpr (("+" | "-") MulExpr)*
MulExpr       := UnaryExpr (("*" | "/" | "%") UnaryExpr)*
UnaryExpr     := UnaryOp UnaryExpr | TryExpr
UnaryOp       := "!" | "-" | "~" | "ref" | "move"
TryExpr       := "try" CallExpr | CallExpr
CallExpr      := Postfix
Postfix       := Primary PostfixOp*
PostfixOp     := "." IDENT                              (* field / method *)
              | "." INT_LIT                             (* tuple field .0 *)
              | "?." IDENT                              (* Option chain; per errors.md *)
              | "(" CallArgs? ")"                       (* call *)
              | "[" Expr "]"                            (* subscript *)
              | GenericArgs                             (* turbofish-free; resolves per the < rule *)

Primary       := LiteralExpr
              | IDENT                                   (* including type-name paths once resolved *)
              | "Self"
              | "self"
              | "(" Expr ")"                            (* parens *)
              | TupleExpr
              | ArrayExpr
              | RecordExpr
              | RangeExpr
              | IfStmt
              | MatchStmt
              | LoopStmt
              | WhileStmt
              | ForStmt
              | Block
              | ScopeStmt
              | SpawnExpr
              | ChannelExpr
              | SelectStmt
              | GraphExpr
              | LambdaExpr
              | WithCapsStmt
              | "trap" "(" ")"

CallArgs      := CallArg ("," CallArg)* ","?
CallArg       := Expr                                   (* bare; no mode keyword per types.md *)

LiteralExpr   := NUM_LITERAL | STR_PLAIN | STR_RAW | STR_TYPED
              | "true" | "false"
              | "None"                                  (* prelude *)

TupleExpr     := "(" Expr ("," Expr)+ ","? ")"
              | "(" ")"
ArrayExpr     := "[" Expr ("," Expr)* ","? "]"          (* [T; N] literal; N inferred *)
              | "[" Expr ";" Expr "]"                   (* repeated init: [x; N] *)
RecordExpr    := PathType "{" (RecordInit ("," RecordInit)* ","?)? "}"
RecordInit    := IDENT ":" Expr
              | IDENT                                   (* shorthand: { x, y } *)

(* Record-literal restriction: in the bare condition / scrutinee /
   iterable head of `if` / `while` / `for` / `match` (and the RHS of an
   `if let`), `Path {` parses as the head expression followed by the
   statement's block — never as a record literal. Wrap in parentheses
   to force the literal: `if (Point { x: 1 }).ok { … }`. Inside
   parens, brackets, and argument lists the brace is unambiguous and
   the restriction lifts. Same rule as Rust's struct-literal
   restriction; it keeps `if x { … }` unambiguous without lookahead. *)
RangeExpr     := Expr ".." Expr
              | Expr "..=" Expr

LambdaExpr    := "|" LambdaParams? "|" Expr
LambdaParams  := IDENT ("," IDENT)*

CmpOp         := "==" | "!=" | "<" | "<=" | ">" | ">="
```

### Operator precedence

From tightest to loosest, with associativity. The grammar above
encodes this; the table is for reference.

| Level | Operators                                | Associativity |
|-------|------------------------------------------|---------------|
| 1     | postfix `.`, `?.`, `()`, `[]`, generic `< >` | left          |
| 2     | unary `-`, `!`, `~`, `ref`, `move`, `try`    | right         |
| 3     | `*`, `/`, `%`                                | left          |
| 4     | `+`, `-`                                     | left          |
| 5     | `<<`, `>>`                                   | left          |
| 6     | `&`                                          | left          |
| 7     | `^`                                          | left          |
| 8     | `|`                                          | left          |
| 9     | `==`, `!=`, `<`, `<=`, `>`, `>=`             | non-assoc     |
| 10    | `&&`                                         | left          |
| 11    | `||`                                         | left          |
| 12    | `|>`                                         | left          |
| 13    | `=`, `+=`, `-=`, `*=`, `/=`, `%=`            | right         |

Notes:

- `try` binds tighter than any binary operator so that `try expr.method()`
  parses as `try (expr.method())`. Per
  [`errors.md` §"The `try` keyword"](./errors.md), `try` is a prefix
  on the `CallExpr` level.
- `|>` is below all arithmetic and logical operators. `x + 1 |> f(y)`
  parses as `(x + 1) |> f(y)` ≡ `f(x + 1, y)`.
- Chained comparisons (`a < b < c`) are non-associative — parsing is
  rejected by the typechecker rather than the grammar, in line with
  most languages that pick one rule and stick to it.
- The expression-level `|` (bitwise-or) and the type-level `|`
  (anonymous union per `UnionType`) share a token; position
  disambiguates.

### Cast syntax

Casts are written as ordinary function calls per
[`types.md` §"Casts"](./types.md):

```q64
let x: i32 = i32(big)
```

The grammar accepts this through the regular `CallExpr` shape; cast
detection is a typechecker concern, not a parser one. There is no
dedicated `as`-cast operator (the `as` keyword is reserved for import
binding and is otherwise unused at expression level in v0).

### Static `Face.method` and `Face.Type` paths

Per [`faces.md` §"Static `Face.method` and `Face.Type` paths"](./faces.md),
`Face<…>.method(...)` is a regular `Postfix` chain: the `GenericArgs`
attach to the face identifier, the `.method` is a field/method access,
and the `()` is a call.

```
Convert<PCM<i16>, PCM<f32>>.convert(sample)
```

parses as `Postfix( PathType("Convert", GenericArgs(...)), ".convert", "(...)" )`.

## Diagnostic codes

Lexical and parser diagnostics use the `LEX*` and `PAR*` prefixes per
the per-subsystem convention in [`diagnostics.md`](./diagnostics.md).
The codes already defined in other specs are:

| Code     | Owner       | Short message                                                    |
|----------|-------------|------------------------------------------------------------------|
| `LEX020` | types.md    | unknown string-literal prefix                                    |
| `LEX021` | types.md    | unexpected character `&` in type position                        |
| `LEX022` | types.md    | ambiguous string-literal prefix                                  |
| `PAR040` | generics.md | generic vs less-than ambiguity                                   |

`LEX010` is reserved by this spec for "stray carriage return"
(§"Source encoding and whitespace"). Future lexical and parser codes
land in their respective bands; the implementation reserves
`LEX011`–`LEX099` and `PAR000`–`PAR039`, `PAR041`–`PAR099` for
allocation by future revisions.

## Examples

### Minimal file

```q64
//! hello — entry point.

fn main {
    env.out("Hello, q64.")
}
```

### Generic function with where clause and effect

```q64
pub fn collect<I, C>(it: I) -> C
where
    I: Iterator,
    I.Item: Eq + Hash,
    C: Collection<I.Item, _>,
{
    var out: C = C.new()
    for x in it { out.push(x) }
    out
}
```

### Effect-polymorphic face and fit

```q64
pub face Filter<T, @e> {
    fn step(self: ref Self, x: T) -> T @e
}

pub fit LowPass : Filter<PCM<f32>, @realtime> {
    fn step(self: ref Self, x: PCM<f32>) -> PCM<f32> @realtime {
        biquad(self, x)
    }
}
```

### Annotated struct and tuple struct

```q64
@shared
struct World {
    counter: Atomic<i64>,
    grid:    Shared<Grid, RwLock>,
}

pub struct UserId(i64)
```

### Pattern match with destructuring

```q64
match user?.profile?.name {
    Some(n) -> env.out("Hello, {n}!"),
    None    -> env.out("Hello, stranger."),
}
```

### Concurrency and a stream graph in one program

```q64
graph voice {
    let pcm    = mic_input()
    let denoised = pcm |> denoise(threshold: 0.05)
    let _      = denoised |> play
}

fn main {
    scope {
        let h = voice.start()
        select {
            _ = h.await()       -> {},
            _ = ctx.cancelled() -> h.cancel(),
        }
    } catch (e: Panic) {
        log.error("voice graph stopped: {e.fmt()}")
    }
}
```

## Open items deferred

These are the four grammar-shaped open items, reproduced
here so a reader of this spec can see exactly what is **not** pinned.

1. **Pattern matching grammar.** Guards (`Pattern if cond`),
   or-patterns (`A | B`), deep struct destructuring, range patterns,
   and exhaustiveness rules. §Patterns captures the v0 floor used by
   the rest of the spec corpus.
2. **Region parameters in `fn` signatures.** Defaults, elision rules,
   and the interaction with the implicit `scope` arena beyond the
   explicit `<R: Region>` form. §Functions admits the explicit shape;
   sugar is open.
3. **Stage / graph DSL.** Beyond the `graph { let … |> … }` shape in
   §"Stream forms", a richer result-builder syntax (parallel splits,
   fan-in / fan-out operators, conditional sub-graphs) is open per
   [`streams.md` §"Open items deferred"](./streams.md).
4. **Operator overloading on units.** This is a semantic concern, not
   a grammar one; the operator tokens are spelled here, but which
   types may declare fits for them (`Hz + Hz`, `Hz * Seconds`, …)
   lives with [`units.md`](./units.md) §"Dimensional algebra".

Additional grammar-shaped items inherited from other specs:

- **Triple-quoted block strings** (`"""…"""`) — reserved syntax per
  [`types.md` §"Multi-line and trim rules"](./types.md); trim
  algorithm pending.
- **Type-test patterns in `catch (e: Panic)` arms** — destructuring a
  `dyn Panic` by concrete type inside one catch body. Currently
  expressible as a sequence of typed `catch` arms; sugar deferred per
  [`errors.md` §"Open items deferred"](./errors.md).
- **Closure effect annotations** — explicit effect spec on a lambda
  literal. A closure's effects are inferred from its body per
  [`closures.md` §Effects](./closures.md); the literal-level
  annotation form is deferred there.
- **`try?` and `try!` shortcuts** — Swift-style fallible-cast sugar;
  not in v0 per [`errors.md` §"Variants deferred"](./errors.md).

## Related specs

Every owning spec is the source of truth for its productions; this
file consolidates without overriding.

- [`modules.md`](./modules.md) — `ImportStmt`, `ReExport`, top-level
  `Item` list, auto-prelude.
- [`faces.md`](./faces.md) — `FaceDecl`, `FitDecl`, `LawDecl`,
  `MethodSig`, `BoundList`, `DynType`.
- [`generics.md`](./generics.md) — `GenericParams`, `GenericArgs`,
  `WhereClause`, the four parameter kinds, the `<` disambiguation rule.
- [`types.md`](./types.md) — numeric tower, literal suffixes, parameter
  modes, `[T; N]` / `[T]` / `ref T`, tuple structs, optional types,
  the `LEX020` / `LEX021` codes.
- [`memory.md`](./memory.md) — `RegionStmt`, `@shared` / `@managed`
  annotations.
- [`errors.md`](./errors.md) — `try`, `panic`, `trap()`, `?.`,
  `Result`/`Option`, the `TYP3xx` band.
- [`effects.md`](./effects.md) — `EffectSpec`, `EffectMarker`,
  `EffectDecl`, the `@`-name lexical class.
- [`concurrency.md`](./concurrency.md) — `ScopeStmt`, `SpawnExpr`,
  `ActorDecl`, `ChannelExpr`, `SelectStmt`, `CatchArm`.
- [`streams.md`](./streams.md) — `GraphDecl`, `GraphExpr`, `|>`
  semantics, the `@stage` / `@fuse` annotations.
- [`env.md`](./env.md) — `WithCapsStmt`, `main` signatures.
- [`diagnostics.md`](./diagnostics.md) — envelope format for every
  `LEX*` / `PAR*` code listed above.
