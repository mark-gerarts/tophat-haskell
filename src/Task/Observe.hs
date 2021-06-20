module Task.Observe where

import Data.HashMap.Strict.InsOrd (InsOrdHashMap)
import qualified Data.HashMap.Strict.InsOrd as HashMap
import qualified Data.HashSet.InsOrd as HashSet
import Data.List (union)
import qualified Data.Store as Store
import Polysemy
import Polysemy.Mutate (Alloc, Read)
import Task
import Task.Input

---- Observations --------------------------------------------------------------
-- NOTE: Normalisation should never happen in any observation, they are immediate.

ui ::
  Members '[Alloc h, Read h] r => -- We need `Alloc` because `Value` needs it.
  Task h a ->
  Sem r Text
ui = \case
  Edit a e -> ui' a e
  Done _ -> pure "■ …"
  Pair t1 t2 -> pure (\l r -> unwords [l, " ⧓ ", r]) -< ui t1 -< ui t2
  Choose t1 t2 -> pure (\l r -> unwords [l, " ◆ ", r]) -< ui t1 -< ui t2
  Fail -> pure "↯"
  Trans _ t -> ui t
  Step t1 e2 ->
    pure go -< ui t1 -< do
      mv1 <- value t1
      case mv1 of
        Nothing -> pure []
        Just v1 -> pure <| options (e2 v1)
    where
      go s ls
        | null ls = concat [s, " ▶…"]
        | otherwise = concat [s, " ▷", display ls]
  Assert _ -> pure <| unwords ["assert", "…"]
  Share b -> pure <| unwords ["share", display b]
  Assign b _ -> pure <| unwords ["…", ":=", display b]

ui' ::
  Members '[Read h] r => -- We need `Read` to read from references.
  Name ->
  Editor h b ->
  Sem r Text
ui' n = \case
  Enter -> pure <| concat ["⊠^", display n, " [ ] "]
  Update b -> pure <| concat ["□^", display n, " [ ", display b, " ]"]
  View b -> pure <| concat ["⧇^", display n, " [ ", display b, " ]"]
  Select ts -> pure <| concat ["◇^", display n, " ", display <| HashSet.fromList <| HashMap.keys ts]
  Change l -> pure (\b -> concat ["⊟^", display n, " [ ", display b, " ]"]) -< Store.read l
  Watch l -> pure (\b -> concat ["⧈^", display n, " [ ", display b, " ]"]) -< Store.read l

value ::
  Members '[Alloc h, Read h] r => -- We need `Alloc` to allocate a fresh store to continue with.
  Task h a ->
  Sem r (Maybe a)
value = \case
  Edit Unnamed _ -> pure Nothing
  Edit (Named _) e -> value' e
  Trans f t -> pure (map f) -< value t
  Pair t1 t2 -> pure (><) -< value t1 -< value t2
  Done v -> pure (Just v)
  Choose t1 t2 -> pure (<|>) -< value t1 -< value t2
  Fail -> pure Nothing
  Step _ _ -> pure Nothing
  Assert b -> pure (Just b)
  Share b -> pure Just -< Store.alloc b
  Assign _ _ -> pure (Just ())

value' ::
  Members '[Read h] r => -- We need `Read` to read from references.
  Editor h a ->
  Sem r (Maybe a)
value' = \case
  Enter -> pure Nothing
  Update b -> pure (Just b)
  View b -> pure (Just b)
  Select _ -> pure Nothing
  Change l -> pure Just -< Store.read l
  Watch l -> pure Just -< Store.read l

failing ::
  Task h a ->
  Bool
failing = \case
  Edit _ e -> failing' e
  Trans _ t2 -> failing t2
  Pair t1 t2 -> failing t1 && failing t2
  Done _ -> False
  Choose t1 t2 -> failing t1 && failing t2
  Fail -> True
  Step t1 _ -> failing t1
  Assert _ -> False
  Share _ -> False
  Assign _ _ -> False

failing' ::
  Editor h a ->
  Bool
failing' = \case
  Enter -> False
  Update _ -> False
  View _ -> False
  Select ts -> all failing ts
  Change _ -> False
  Watch _ -> False

watching ::
  Task h a ->
  List (Some (Ref h)) -- There is no need for any effects.
watching = \case
  Edit Unnamed _ -> []
  Edit (Named _) e -> watching' e
  Trans _ t2 -> watching t2
  Pair t1 t2 -> watching t1 `union` watching t2
  Done _ -> []
  Choose t1 t2 -> watching t1 `union` watching t2
  Fail -> []
  Step t1 _ -> watching t1
  Assert _ -> []
  Share _ -> []
  Assign _ _ -> []

watching' ::
  Editor h a ->
  List (Some (Ref h)) -- There is no need for any effects.
watching' = \case
  Enter -> []
  Update _ -> []
  View _ -> []
  Select _ -> []
  Change (Store _ r) -> [pack r]
  Watch (Store _ r) -> [pack r]

-- | Calculate all possible options that can be send to this task,
-- | i.e. all possible label-activity pairs which select a task.
-- |
-- | Notes:
-- | * We need this to pair `Label`s with `Name`s, because we need to tag all deeper lables with the appropriate editor name.
-- | * We can't return a `HashMap _ (Task  a)` because deeper tasks can be of different types!
options ::
  Task h a -> -- There is no need for any effects.
  List (Input Dummy)
options = \case
  Edit n (Select ts) -> labels ts |> map (Option n)
  Trans _ t2 -> options t2
  Step t1 _ -> options t1
  -- Step t1 e2 -> pure (++) -< options t1 -< do
  --   mv1 <- value t1
  --   case mv1 of
  --     Nothing -> pure []
  --     Just v1 -> do
  --       let t2 = e2 v1
  --       options t2
  -- Pair t1 t2 -> pure [] --pure (++) -< options t1 -< options t2
  -- Choose t1 t2 -> pure [] --pure (++) -< options t1 -< options t2
  _ -> []

-- | Get all `Label`s out of a `Select` editor.
-- |
-- | Notes:
-- | * Goes one level deep!
labels ::
  InsOrdHashMap Label (Task h a) -> -- There is no need for any effects.
  List Label
labels = HashMap.keys << HashMap.filter (not << failing)

inputs ::
  Members '[Alloc h, Read h] r => -- We need `Alloc` and `Read` because we call `value`.
  Task h a ->
  Sem r (List (Input Dummy))
inputs t = case t of
  Edit Unnamed _ -> pure []
  Edit (Named k) e -> pure <| inputs' k e
  Trans _ t2 -> inputs t2
  Pair t1 t2 -> pure (++) -< inputs t1 -< inputs t2
  Done _ -> pure []
  Choose t1 t2 -> pure (++) -< inputs t1 -< inputs t2
  Fail -> pure []
  Step t1 e2 ->
    pure (++) -< inputs t1 -< do
      mv1 <- value t1
      case mv1 of
        Nothing -> pure []
        Just v1 -> do
          let t2 = e2 v1
          pure <| options t2
  Assert _ -> pure []
  Share _ -> pure []
  Assign _ _ -> pure []

inputs' ::
  forall h a.
  Nat ->
  Editor h a ->
  List (Input Dummy)
inputs' k t = case t of
  Enter -> [Insert k <| dummy beta]
  Update _ -> [Insert k <| dummy beta]
  View _ -> []
  Select ts -> labels ts |> map (Pick k)
  Change _ -> [Insert k <| dummy beta]
  Watch _ -> []
  where
    beta = Proxy :: Proxy a
