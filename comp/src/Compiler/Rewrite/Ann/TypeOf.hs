{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TupleSections     #-}

-- Module      : Compiler.Rewrite.Ann.TypeOf
-- Copyright   : (c) 2013-2015 Brendan Hay <brendan.g.hay@gmail.com>
-- License     : This Source Code Form is subject to the terms of
--               the Mozilla Public License, v. 2.0.
--               A copy of the MPL can be found in the LICENSE file or
--               you can obtain it at http://mozilla.org/MPL/2.0/.
-- Maintainer  : Brendan Hay <brendan.g.hay@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)

module Compiler.Rewrite.Ann.TypeOf where

import           Compiler.Rewrite.Ann.Syntax
import           Compiler.Types
import           Control.Lens                 hiding (enum, (??))
import qualified Data.Foldable                as Fold
import           Data.Text                    (Text)
import qualified Data.Text                    as Text
import           Language.Haskell.Exts.Syntax hiding (Int, List, Lit)

data TType
    = TType      Id
    | TLit       (Lit Identity)
    | TNatural
    | TMaybe     TType
    | TFlatten   TType
    | TSensitive TType
    | TList      Text TType
    | TList1     Text TType
    | TMap       (Text, Text, Text) TType TType
      deriving (Show)

internal :: TType -> Type
internal = \case
    TType        x       -> tycon (x ^. typeId)
    TLit         x       -> literal True x
    TNatural             -> tycon "Nat"
    TMaybe       x       -> TyApp (tycon "Maybe") (internal x)
    TFlatten     x       -> TyApp (tycon "Flatten") (internal x)
    TSensitive   x       -> TyApp (tycon "Sensitive") (internal x)
    TList      i x       -> TyApp (TyApp (tycon "List") (singleton i)) (internal x)
    TList1     i x       -> TyApp (TyApp (tycon "List1") (singleton i)) (internal x)
    TMap   (e, i, j) k v ->
        TyApp
          (TyApp
            (TyApp
               (TyApp
                  (TyApp (tycon "EMap") (singleton e))
                  (singleton i))
               (singleton j))
            (internal k))
          (internal v)

external :: TType -> Type
external = \case
    TType        x   -> tycon (x ^. typeId)
    TLit         x   -> literal False x
    TNatural         -> tycon "Natural"
    TMaybe       x   -> TyApp (tycon "Maybe") (external x)
    TFlatten     x   -> external x
    TSensitive   x   -> external x
    TList      _ x   -> TyList (external x)
    TList1     _ x   -> TyApp (tycon "NonEmpty") (external x)
    TMap       _ k v -> TyApp (TyApp (tycon "HashMap") (external k)) (external v)

literal :: Bool -> Lit Identity -> Type
literal i = tycon . \case
    Int             -> "Int"
    Long            -> "Integer"
    Double          -> "Double"
    Text            -> "Text"
    Blob            -> "Base64"
    Bool            -> "Bool"
    Time (Identity ts)
        | i         -> "UTCTime"
        | otherwise -> Text.pack (show ts)

singleton :: Text -> Type
singleton = tycon -- . ("\"" <>) . (<> "\"")

mapping :: TType -> (Exp -> Exp)
mapping = compose . iso'
  where
    compose xs e = Fold.foldl' (\y -> InfixApp y (symop ".")) e xs

    iso' = \case
        TLit  (Time {}) -> [var "_Time"]
        TNatural        -> [var "_Nat"]
        TMaybe     x    -> case iso' x of; [] -> []; xs -> var "mapping" : xs
        TFlatten   x    -> var "_Flatten"   : iso' x
        TSensitive x    -> var "_Sensitive" : iso' x
        TList      {}   -> [var "_List"]  -- Coercible.
        TList1     {}   -> [var "_List1"] -- Coercible.
        TMap       {}   -> [var "_Map"]   -- Coercible.
        _               -> []

list :: HasInfo a => a -> Ref Identity -> TType -> TType
list i r = sensitive i . flatten i . c (r ^. refLocationName . _Identity)
  where
    c | i ^. infoMin > Just 0 = TList1
      | otherwise             = TList

natural :: HasInfo a => a -> (TType -> TType)
natural x
    | Just i <- x ^. infoMin
    , i >= 0    = const TNatural
    | otherwise = id

sensitive :: HasInfo a => a -> (TType -> TType)
sensitive x
    | x ^. infoSensitive = TSensitive
    | otherwise          = id

flatten :: HasInfo a => a -> (TType -> TType)
flatten x
    | x ^. infoFlattened = TFlatten
    | otherwise          = id

optional :: Bool -> TType -> TType
optional True  t = t
optional False t =
    case t of
        TMaybe {} -> t
        TList  {} -> t
        TList1 {} -> t
        TMap   {} -> t
        _         -> TMaybe t
