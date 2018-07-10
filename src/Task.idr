module Task

import Task.Universe
import Task.Event

%default total
%access public export

%hide Language.Reflection.Elab.Tactics.normalise


-- Types -----------------------------------------------------------------------

-- State --

StateTy : Universe.Ty
StateTy = ListTy (BasicTy IntTy)

State : Type
State = typeOf StateTy


-- Tasks --

data Task : Universe.Ty -> Type where
    -- Primitive combinators
    Then  : Show (typeOf a) => (this : Task a) -> (next : typeOf a -> Task b) -> Task b
    Next  : Show (typeOf a) => (this : Task a) -> (next : typeOf a -> Task b) -> Task b
    All   : Show (typeOf a) => Show (typeOf b) => (left : Task a) -> (right : Task b) -> Task (PairTy a b)
    One   : Show (typeOf a) => (left : Task a) -> (right : Task a) -> Task a
    Any   : Show (typeOf a) => (left : Task a) -> (right : Task a) -> Task a
    -- User interaction
    Watch : Task StateTy
    Edit  : (val : Maybe (typeOf a)) -> Task a
    -- Failure
    Fail  : Task a
    -- Share interaction
    Get   : Task StateTy
    Put   : (x : typeOf StateTy) -> Task UnitTy


-- Interface -------------------------------------------------------------------

pure : (typeOf a) -> Task a
pure = Edit . Just

(>>=) : Show (typeOf a) => Task a -> (typeOf a -> Task b) -> Task b
(>>=) = Then

infixl 1 >>?
(>>?) : Show (typeOf a) => Task a -> (typeOf a -> Task b) -> Task b
(>>?) = Next

infixr 3 <&>
(<&>) : Show (typeOf a) => Show (typeOf b) => Task a -> Task b -> Task (PairTy a b)
(<&>) = All

infixr 2 <?>
(<?>) : Show (typeOf a) => Task a -> Task a -> Task a
(<?>) = Any

infixr 2 <|>
(<|>) : Show (typeOf a) => Task a -> Task a -> Task a
(<|>) = One

unit : Task UnitTy
unit = pure ()

-- infixl 1 >>*
-- (>>*) : Show (typeOf a) => Task a -> List (typeOf a -> (Bool, Task b)) -> Task b
-- (>>*) t fs = t >>- convert fs where
--     convert : List (Universe.typeOf a -> (Bool, Task b)) -> Universe.typeOf a -> Task b
--     convert [] x        = fail
--     convert (f :: fs) x =
--         let
--         ( guard, next ) = f x
--         in
--         (if guard then next else fail) <|> convert fs x


-- Applicative and Functor --

-- (<*>) : Show (typeOf a) => Show (typeOf b) => Task (FUN a b) -> Task a -> Task b
-- (<*>) t1 t2 = do
--     f <- t1
--     x <- t2
--     pure $ f x

(<$>) : Show (typeOf a) => (typeOf a -> typeOf b) -> Task a -> Task b
(<$>) f t = do
    x <- t
    pure $ f x


-- Showing ---------------------------------------------------------------------

[editor_value] Show a => Show (Maybe a) where
    show Nothing  = "<no value>"
    show (Just x) = show x

ui : Show (typeOf a) => Task a -> State -> String
ui Fail             _ = "fail"
ui (Then this cont) s = ui this s ++ " >>..."
ui (Next this cont) s = ui this s ++ " ?>..."
ui (All left right) s = "(" ++ ui left s ++ "  <&>  " ++ ui right s ++ ")"
--FIXME: should we present UI's to the user for every or branch?
ui (One left right) s = "(" ++ ui left s ++ "  <?>  " ++ ui right s ++ ")"
ui (Any left right) s = "(" ++ ui left s ++ "  <|>  " ++ ui right s ++ ")"
ui (Edit val)       _ = "edit " ++ show @{editor_value} val
ui Watch            s = "watch " ++ show s
ui Get              _ = "get"
ui (Put x)          _ = "put " ++ show x ++ ""


-- Semantics -------------------------------------------------------------------

value : Task a -> State -> Maybe (typeOf a)
value (Edit val)       _ = val
value Watch            s = Just s
value (All left right) s = Just (!(value left s), !(value right s))
--NOTE: Uses semigroup instance of Maybe here
value (Any left right) s = value left s <+> value right s
value Get              s = Just s
value (Put _)          _ = Just ()
-- The rest never has a value because:
--   * `One` and `Next` need to wait for an user choice
--   * `Fail` runs forever and doesn't produce a value
--   * `Then` transforms values to another type
value _                _ = Nothing

choices : Task a -> List Path
choices (One Fail Fail)  = []
choices (One left Fail)  = map GoLeft (GoHere :: choices left)
choices (One Fail right) = map GoRight (GoHere :: choices right)
choices (One left right) = map GoLeft (GoHere :: choices left) ++ map GoRight (GoHere :: choices right)
choices _               = []

actions : Task a -> State -> List Event
actions (Next this next)      s =
    let
    here =
        case value this s of
            Just v  =>
                case next v of
                    t@(One _ _) => map (Continue . Just) $ choices t
                    Fail       => []
                    _          => [ Continue Nothing ]
            Nothing => []
    in
    map ToThis here ++ actions this s
actions (Then this next)      s = actions this s
actions (All left right)      s = map ToFirst (actions left s) ++ map ToSecond (actions right s)
actions (Any left right)      s = map ToFirst (actions left s) ++ map ToSecond (actions right s)
actions task@(One left right) s = map (ToThis . Pick) $ choices task
actions (Edit {a} val)        _ = [ ToThis (Change (Universe.defaultOf a)), ToThis Empty ]
actions Watch                 _ = [ ToThis (Change (Universe.defaultOf StateTy)) ]
actions Fail                  _ = []
actions Get                   _ = []
actions (Put x)               _ = []

normalise : Task a -> State -> ( Task a, State )
-- Step
normalise task@(Then this cont) state =
    --FIXME: normalise before???
    -- let
    -- ( newThis, newState ) = normalise this state
    -- in
    case value this state of
        Just v  =>
            case cont v of
                Fail   => ( task, state )
                next   => normalise next state
        Nothing =>
            ( task, state )
-- Evaluate
normalise (Next this cont) state =
    let
    ( newThis, newState ) = normalise this state
    in
    ( Next newThis cont, newState )
normalise (All left right) state =
    let
    ( newLeft, newState )    = normalise left state
    ( newRight, newerState ) = normalise right newState
    in
    ( All newLeft newRight, newerState )
normalise (Any left right) state =
    let
    ( newLeft, newState )   = normalise left state
    ( newRight, newerState ) = normalise right newState
    in
    case value newLeft newerState of
        Just _  => ( newLeft, newerState )
        Nothing =>
            case value newRight newerState of
                Just _  => ( newRight, newerState )
                Nothing => ( Any newLeft newRight, newerState )
-- State
normalise (Get) state =
    ( pure state, state )
normalise (Put x) state =
    ( unit, x )
-- Values
normalise task state =
    ( task, state )

handle : Task a -> Event -> State -> ( Task a, State )
handle task@(Next this cont) (ToThis (Continue mp)) state =
    -- If we pressed Continue...
    case value this state of
        -- ...and we have a value: we get on with the continuation,
        Just v =>
            case mp of
                --FIXME: prevent stepping to `Fail`???
                -- and automatically pick if we recieved a path
                Just path => handle (cont v) (ToThis (Pick path)) state
                -- or just continue otherwise
                Nothing   => normalise (cont v) state
        -- ...without a value: we stay put and have to wait for a value to appear.
        Nothing => ( task, state )
handle (Next this cont) event state =
    -- Pass the event to this
    let
    ( newThis, newState ) = handle this event state
    in
    ( Next newThis cont, newState )
handle (Then this cont) event state =
    -- Pass the event to this and normalise
    let
    ( newThis, newState ) = handle this event state
    in
    normalise (Then newThis cont) newState
--FIXME: normalise after each event handling of All and One???
handle (All left right) (ToFirst event) state =
    -- Pass the event to left
    let
    ( newLeft, newState ) = handle left event state
    in
    ( All newLeft right, newState )
handle (All left right) (ToSecond event) state =
    -- Pass the event to right
    let
    ( newRight, newState ) = handle right event state
    in
    ( All left newRight, newState )
handle (One left _) (ToThis (Pick (GoLeft p))) state =
    -- Go left
    handle left (ToThis (Pick p)) state
handle (One _ right) (ToThis (Pick (GoRight p))) state =
    -- Go right
    handle right (ToThis (Pick p)) state
handle (One left right) (ToThis (Pick GoHere)) state =
    -- Stay
    ( One left right, state )
handle (Edit _) (ToThis Empty) state =
    ( Edit Nothing, state )
handle (Edit {a} val) (ToThis (Change {b} newVal)) state with (decEq b a)
  handle (Edit _) (ToThis (Change newVal)) state | Yes Refl = ( Edit (Just newVal), state )
  handle (Edit val) _ state                    | No _     = ( Edit val, state )
handle Watch (ToThis (Change {b} newVal)) state with (decEq b StateTy)
  handle Watch (ToThis (Change newVal)) _ | Yes Refl = ( Watch, newVal )
  handle Watch _ state                  | No _     = ( Watch, state )
-- FIXME: Should pass more unhandled events down or not...
handle task _ state =
    ( task, state )
    -- Case `Fail`: evaluation continues indefinitely
    -- Case `Then`: should already be evaluated by `normalise`, otherwise pass events to `this`
    -- Case `Any`: should also be evaluated by `normalise`, otherwise wait for a value in one of the branches
    -- Cases `Get` and `Put`: this case can't happen, it is already evaluated by `normalise`
    -- FIXME: express this in the type system...

init : Task a -> ( Task a, State )
init = flip normalise []
