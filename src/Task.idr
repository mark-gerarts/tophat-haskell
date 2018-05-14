module Task

import Task.Universe
import Task.Event

%default total
%access public export


-- Types -----------------------------------------------------------------------

-- State --

StateTy : Universe.Ty
StateTy = BasicTy IntTy

State : Type
State = typeOf StateTy


-- Tasks --

data Task : Universe.Ty -> Type where
    -- Primitive combinators
    Then  : Show (typeOf a) => (this : Task a) -> (next : typeOf a -> Task b) -> Task b
    Next  : Show (typeOf a) => (this : Task a) -> (next : typeOf a -> Task b) -> Task b
    And   : Show (typeOf a) => Show (typeOf b) => (left : Task a) -> (right : Task b) -> Task (PairTy a b)
    Or    : Show (typeOf a) => (left : Task a) -> (right : Task a) -> Task a
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

infixr 3 |*|
(|*|) : Show (typeOf a) => Show (typeOf b) => Task a -> Task b -> Task (PairTy a b)
(|*|) = And
-- FIXME: should do the same trick as below, but need to prove `((a, b), c) = (a, (b, c))` for PairTy
-- (|*|) (And x y) z = And x (And y z)
-- (|*|) x y         = And x y

infixr 2 |+|
(|+|) : Show (typeOf a) => Task a -> Task a -> Task a
(|+|) (Or x y) z = Or x (Or y z)
(|+|) x y        = Or x y

unit : Task UnitTy
unit = pure ()

state : Int -> State
state = id

-- infixl 1 >>*
-- (>>*) : Show (typeOf a) => Task a -> List (typeOf a -> (Bool, Task b)) -> Task b
-- (>>*) t fs = t >>- convert fs where
--     convert : List (Universe.typeOf a -> (Bool, Task b)) -> Universe.typeOf a -> Task b
--     convert [] x        = fail
--     convert (f :: fs) x =
--         let
--         ( guard, next ) = f x
--         in
--         (if guard then next else fail) |+| convert fs x


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
ui (Then this cont) s = ui this s ++ " => <cont>"
ui (Next this cont) s = ui this s ++ " -> <cont>"
ui (And left right) s = "(" ++ ui left s ++ " * " ++ ui right s ++ ")"
--FIXME: should we present UI's to the user for every or branch?
ui (Or left right)  s = "(" ++ ui left s ++ " + " ++ ui right s ++ ")"
ui (Edit val)       _ = "edit " ++ show @{editor_value} val
ui Watch            s = "watch " ++ show s
ui Get              _ = "get"
ui (Put x)          _ = "put " ++ show x ++ ""


-- Semantics -------------------------------------------------------------------

observe : Task a -> State -> Maybe (typeOf a)
observe (Edit val)       _ = val
observe Watch            s = Just s
observe (And left right) s = Just (!(observe left s), !(observe right s))
observe Get              s = Just s
observe (Put _)          _ = Just ()
-- The rest never has a value because:
--   * `Or` needs to wait for an user choice
--   * `Fail` runs forever and doesn't produce a value
--   * `Next` transforms values to another type
observe _                _ = Nothing

choices : Task a -> List Path
choices (Or Fail Fail)  = []
choices (Or left Fail)  = [ First ]
choices (Or Fail right) = [ Second ] ++ map Other (choices right)
choices (Or left right) = [ First, Second ] ++ map Other (choices right)
choices _               = []

actions : Task a -> State -> List Event
actions (Next this next)     s =
    let
    here =
        case observe this s of
            Just v  =>
                case next v of
                    t@(Or _ _) => map (Continue . Just) $ choices t
                    Fail       => []
                    _          => [ Continue Nothing ]
            Nothing => []
    in
    map Here here ++ actions this s
actions (Then this next)     s = actions this s
actions (And left right)     s = map ToLeft (actions left s) ++ map ToRight (actions right s)
actions task@(Or left right) s = map (Here . Pick) $ choices task
actions (Edit {a} val)       _ = [ Here (Change (Universe.defaultOf a)), Here Empty ]
actions Watch                _ = [ Here (Change (Universe.defaultOf StateTy)) ]
actions Fail                 _ = []
actions Get                  _ = []
actions (Put x)              _ = []

normalise : Task a -> State -> ( Task a, State )
-- Step
normalise task@(Then this cont) state =
    --FIXME: normalise before???
    -- let
    -- ( newThis, newState ) = normalise this state
    -- in
    case observe this state of
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
normalise (And left right) state =
    let
    ( newLeft, newState )    = normalise left state
    ( newRight, newerState ) = normalise right newState
    in
    ( And newLeft newRight, newerState )
-- State
normalise (Get) state =
    ( pure state, state )
normalise (Put x) state =
    ( unit, x )
-- Values
normalise task state =
    ( task, state )

handle : Task a -> Event -> State -> ( Task a, State )
handle task@(Next this cont) (Here (Continue futr)) state =
    -- If we pressed Continue...
    case observe this state of
        -- ...and we have a value: we get on with the continuation,
        Just v =>
            case futr of
                --FIXME: prevent stepping to `Fail`???
                -- and automatically pick if we recieved a path
                Just path => handle (cont v) (Here (Pick path)) state
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
--FIXME: normalise after each event handling of And and Or???
handle (And left right) (ToLeft event) state =
    -- Pass the event to left
    let
    ( newLeft, newState ) = handle left event state
    in
    ( And newLeft right, newState )
handle (And left right) (ToRight event) state =
    -- Pass the event to right
    let
    ( newRight, newState ) = handle right event state
    in
    ( And left newRight, newState )
handle (Or left right) (Here (Pick First)) state =
    -- Pick the first
    ( left, state )
handle (Or left right) (Here (Pick Second)) state =
    -- Pick the second
    ( right, state )
handle (Or left right) (Here (Pick (Other p))) state =
    -- Pick the second and continue
    handle right (Here (Pick p)) state
handle (Edit _) (Here Empty) state =
    ( Edit Nothing, state )
handle (Edit {a} val) (Here (Change {b} newVal)) state with (decEq b a)
  handle (Edit _) (Here (Change newVal)) state | Yes Refl = ( Edit (Just newVal), state )
  handle (Edit val) _ state                    | No _     = ( Edit val, state )
handle Watch (Here (Change {b} newVal)) state with (decEq b StateTy)
  handle Watch (Here (Change newVal)) _ | Yes Refl = ( Watch, newVal )
  handle Watch _ state                  | No _     = ( Watch, state )
-- FIXME: Should pass more unhandled events down or not...
handle task _ state =
    ( task, state )
    -- Case `Fail`: evaluation continues indefinitely
    -- Case `Then`: should already be evaluated by `normalise`, otherwise pass events to `this`
    -- Cases `Get` and `Put`: this case can't happen, it is already evaluated by `normalise`
    -- FIXME: express this in the type system...

init : Task a -> State -> ( Task a, State )
init = normalise
