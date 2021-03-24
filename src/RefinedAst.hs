{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RecordWildCards #-}
{-# Language MultiParamTypeClasses #-}
{-# Language FlexibleContexts #-}
{-# Language ScopedTypeVariables #-}
{-# Language TypeFamilies #-}
{-# Language TypeApplications #-}
{-# LANGUAGE LambdaCase #-}

module RefinedAst where

import Data.Function (on)
import Data.Text (pack)
import Data.Type.Equality
import Data.Typeable
import Data.Map.Strict (Map)
import Data.List.NonEmpty hiding (fromList)
import Data.ByteString (ByteString)

import EVM.Solidity (SlotType(..))

import Syntax (Id, Interface, EthEnv)
import Utils
import Data.Aeson
import Data.Aeson.Types
import Data.Vector (fromList)


-- AST post typechecking
data Claim = C Constructor | B Behaviour | I Invariant | S Store deriving (Show, Eq)

type Store = Map Id (Map Id SlotType)

data Invariant = Invariant
  { _icontract :: Id
  , _ipreconditions :: [Exp Bool]
  , _predicate :: Exp Bool
  } deriving (Show, Eq)

data Constructor = Constructor
  { _cname :: Id,
    _cmode :: Mode,
    _cinterface :: Interface,
    _cpreconditions :: [Exp Bool],
    _cpostconditions :: [Exp Bool],
    _initialStorage :: [StorageUpdate],
    _cstateUpdates :: [Either StorageLocation StorageUpdate]
  } deriving (Show, Eq)

data Behaviour = Behaviour
  {_name :: Id,
   _mode :: Mode,
   _contract :: Id,
   _interface :: Interface,
   _preconditions :: [Exp Bool],
   _postconditions :: [Exp Bool],
   _stateUpdates :: [Either StorageLocation StorageUpdate],
   _returns :: Maybe ReturnExp
  } deriving (Show, Eq)

data Mode
  = Pass
  | Fail
  | OOG
  deriving (Eq, Show)

--types understood by proving tools
data MType
  = Integer
  | Boolean
  | ByteStr
--  | Mapping (Map MType MType)
  deriving (Eq, Ord, Show, Read)

data StorageUpdate
  = IntUpdate (TStorageItem Integer) (Exp Integer)
  | BoolUpdate (TStorageItem Bool) (Exp Bool)
  | BytesUpdate (TStorageItem ByteString) (Exp ByteString)
  deriving (Show, Eq)

data StorageLocation
  = IntLoc (TStorageItem Integer)
  | BoolLoc (TStorageItem Bool)
  | BytesLoc (TStorageItem ByteString)
  deriving (Show, Eq)

data TStorageItem a where
  DirectInt    :: Id -> Id -> TStorageItem Integer
  DirectBool   :: Id -> Id -> TStorageItem Bool
  DirectBytes  :: Id -> Id -> TStorageItem ByteString
  MappedInt    :: Id -> Id -> NonEmpty ReturnExp -> TStorageItem Integer
  MappedBool   :: Id -> Id -> NonEmpty ReturnExp -> TStorageItem Bool
  MappedBytes  :: Id -> Id -> NonEmpty ReturnExp -> TStorageItem ByteString

deriving instance Show (TStorageItem a)
deriving instance Eq (TStorageItem a)

-- typed expressions
data ExpF r t where
  -- booleans
  And  :: r Bool -> r Bool -> ExpF r Bool
  Or   :: r Bool -> r Bool -> ExpF r Bool
  Impl :: r Bool -> r Bool -> ExpF r Bool
  Neg :: r Bool -> ExpF r Bool
  LE :: r Integer -> r Integer -> ExpF r Bool
  LEQ :: r Integer -> r Integer -> ExpF r Bool
  GEQ :: r Integer -> r Integer -> ExpF r Bool
  GE :: r Integer -> r Integer -> ExpF r Bool
  LitBool :: Bool -> ExpF r Bool
  BoolVar :: Id -> ExpF r Bool
  -- integers
  Add :: r Integer -> r Integer -> ExpF r Integer
  Sub :: r Integer -> r Integer -> ExpF r Integer
  Mul :: r Integer -> r Integer -> ExpF r Integer
  Div :: r Integer -> r Integer -> ExpF r Integer
  Mod :: r Integer -> r Integer -> ExpF r Integer
  Exp :: r Integer -> r Integer -> ExpF r Integer
  LitInt :: Integer -> ExpF r Integer
  IntVar :: Id -> ExpF r Integer
  IntEnv :: EthEnv -> ExpF r Integer
  -- bounds
  IntMin :: Int -> ExpF r Integer
  IntMax :: Int -> ExpF r Integer
  UIntMin :: Int -> ExpF r Integer
  UIntMax :: Int -> ExpF r Integer
  -- bytestrings
  Cat :: r ByteString -> r ByteString -> ExpF r ByteString
  Slice :: r ByteString -> r Integer -> r Integer -> ExpF r ByteString
  ByVar :: Id -> ExpF r ByteString
  ByStr :: String -> ExpF r ByteString
  ByLit :: ByteString -> ExpF r ByteString
  ByEnv :: EthEnv -> ExpF r ByteString
  -- builtins
  NewAddr :: r Integer -> r Integer -> ExpF r Integer

  -- polymorphic
  Eq  :: (Typeable t, Show t) => r t -> r t -> ExpF r Bool
  NEq :: (Typeable t, Show t) => r t -> r t -> ExpF r Bool
  ITE :: r Bool -> r t -> r t -> ExpF r t
  TEntry :: (TStorageItem t) -> ExpF r t

deriving instance Show a => Show (ExpF (HFix ExpF) a)

instance HEq r => HEq (ExpF r) where
  heq = (==)

instance Eq (Exp a) where
  (==) = (==) `on` unHFix

type Exp = HFix ExpF

instance HFunctor ExpF where
  hfmap eta = \case
    And p q -> And (eta p) (eta q)
    LitBool p -> LitBool p
    Eq x y -> Eq (eta x) (eta y)
    TEntry t -> TEntry t

instance HFoldable ExpF where
  hfoldMap f = \case
    And p q -> f p <> f q
    LitBool _ -> mempty
    Eq x y -> f x <> f y
    TEntry _ -> mempty

instance HRecursive Exp where
  type HBase Exp = ExpF
  hproject = unHFix

instance HEq r => Eq (ExpF r t) where
  And a b == And c d = a `heq` c && b `heq` d
  Or a b == Or c d = a `heq` c && b `heq` d
  Impl a b == Impl c d = a `heq` c && b `heq` d
  Neg a == Neg b = a `heq` b
  LE a b == LE c d = a `heq` c && b `heq` d
  LEQ a b == LEQ c d = a `heq` c && b `heq` d
  GEQ a b == GEQ c d = a `heq` c && b `heq` d
  GE a b == GE c d = a `heq` c && b `heq` d
  LitBool a == LitBool b = a == b
  BoolVar a == BoolVar b = a == b

  Add a b == Add c d = a `heq` c && b `heq` d
  Sub a b == Sub c d = a `heq` c && b `heq` d
  Mul a b == Mul c d = a `heq` c && b `heq` d
  Div a b == Div c d = a `heq` c && b `heq` d
  Mod a b == Mod c d = a `heq` c && b `heq` d
  Exp a b == Exp c d = a `heq` c && b `heq` d
  LitInt a == LitInt b = a == b
  IntVar a == IntVar b = a == b
  IntEnv a == IntEnv b = a == b

  IntMin a == IntMin b = a == b
  IntMax a == IntMax b = a == b
  UIntMin a == UIntMin b = a == b
  UIntMax a == UIntMax b = a == b

  Cat a b == Cat c d = a `heq` c && b `heq` d
  Slice a b c == Slice d e f = a `heq` d && b `heq` e && c `heq` f
  ByVar a == ByVar b = a == b
  ByStr a == ByStr b = a == b
  ByLit a == ByLit b = a == b
  ByEnv a == ByEnv b = a == b

  NewAddr a b == NewAddr c d = a `heq` c && b `heq` d

  Eq (a :: r t1) (b :: r t1) == Eq (c :: r t2) (d :: r t2) = case eqT @t1 @t2 of
    Just Refl -> a `heq` c && b `heq` d
    Nothing -> False
  NEq (a :: r t1) (b :: r t1) == NEq (c :: r t2) (d :: r t2) = case eqT @t1 @t2 of
    Just Refl -> a `heq` c && b `heq` d
    Nothing -> False
  ITE a b c == ITE d e f = a `heq` d && b `heq` e && c `heq` f
  TEntry a == TEntry b = a == b

  _ == _ = False

instance Semigroup (Exp Bool) where
  a <> b = And a b

instance Monoid (Exp Bool) where
  mempty = LitBool True

data ReturnExp
  = ExpInt    (Exp Integer)
  | ExpBool   (Exp Bool)
  | ExpBytes  (Exp ByteString)
  deriving (Eq, Show)

-- intermediate json output helpers ---
instance ToJSON Claim where
  toJSON (S storages) = object [ "kind" .= (String "Storages")
                                          , "storages" .= toJSON storages]
  toJSON (I (Invariant {..})) = object [ "kind" .= (String "Invariant")
                                       , "predicate" .= toJSON _predicate
                                       , "preconditions" .= toJSON _ipreconditions
                                       , "contract" .= _icontract]
  toJSON (C (Constructor {..})) = object  [ "kind" .= (String "Constructor")
                                          , "contract" .= _cname
                                          , "mode" .= (String . pack $ show _cmode)
                                          , "interface" .= (String . pack $ show _cinterface)
                                          , "preConditions" .= (toJSON _cpreconditions)
                                          , "postConditions" .= (toJSON _cpostconditions)
                                          , "storage" .= toJSON _initialStorage
                                          ]
  toJSON (B (Behaviour {..})) = object  [ "kind" .= (String "Behaviour")
                                        , "name" .= _name
                                        , "contract" .= _contract
                                        , "mode" .= (String . pack $ show _mode)
                                        , "interface" .= (String . pack $ show _interface)
                                        , "preConditions" .= (toJSON _preconditions)
                                        , "postConditions" .= (toJSON _postconditions)
                                        , "stateUpdates" .= toJSON _stateUpdates
                                        , "returns" .= toJSON _returns]

instance ToJSON SlotType where
  toJSON (StorageValue t) = object ["type" .= show t]
  toJSON (StorageMapping ixTypes valType) = object [ "type" .= (String "mapping")
                                                   , "ixTypes" .= show (toList ixTypes)
                                                   , "valType" .= show valType]

instance ToJSON StorageLocation where
  toJSON (IntLoc a) = object ["location" .= toJSON a]
  toJSON (BoolLoc a) = object ["location" .= toJSON a]
  toJSON (BytesLoc a) = object ["location" .= toJSON a]

instance ToJSON StorageUpdate where
  toJSON (IntUpdate a b) = object ["location" .= toJSON a ,"value" .= toJSON b]
  toJSON (BoolUpdate a b) = object ["location" .= toJSON a ,"value" .= toJSON b]
  toJSON (BytesUpdate a b) = object ["location" .= toJSON a ,"value" .= toJSON b]

instance ToJSON (TStorageItem b) where
  toJSON (DirectInt a b) = object ["sort" .= (pack "int")
                                  , "name" .= (String $ pack a <> "." <> pack b)]
  toJSON (DirectBool a b) = object ["sort" .= (pack "bool")
                                   , "name" .= (String $ pack a <> "." <> pack b)]
  toJSON (DirectBytes a b) = object ["sort" .= (pack "bytes")
                                    , "name" .= (String $ pack a <> "." <> pack b)]
  toJSON (MappedInt a b c) = mapping a b c
  toJSON (MappedBool a b c) = mapping a b c
  toJSON (MappedBytes a b c) = mapping a b c

instance ToJSON ReturnExp where
   toJSON (ExpInt a) = object ["sort" .= (pack "int")
                              ,"expression" .= toJSON a]
   toJSON (ExpBool a) = object ["sort" .= (String $ pack "bool")
                               ,"expression" .= toJSON a]
   toJSON (ExpBytes a) = object ["sort" .= (String $ pack "bytestring")
                               ,"expression" .= toJSON a]

instance ToJSON (Exp Integer) where
  toJSON (Add a b) = symbol "+" a b
  toJSON (Sub a b) = symbol "-" a b
  toJSON (Exp a b) = symbol "^" a b
  toJSON (Mul a b) = symbol "*" a b
  toJSON (Div a b) = symbol "/" a b
  toJSON (NewAddr a b) = symbol "newAddr" a b
  toJSON (IntVar a) = String $ pack a
  toJSON (LitInt a) = toJSON $ show a
  toJSON (IntMin a) = toJSON $ show $ intmin a
  toJSON (IntMax a) = toJSON $ show $ intmax a
  toJSON (UIntMin a) = toJSON $ show $ uintmin a
  toJSON (UIntMax a) = toJSON $ show $ uintmax a
  toJSON (IntEnv a) = String $ pack $ show a
  toJSON (TEntry a) = toJSON a
  toJSON (ITE a b c) = object [  "symbol"   .= pack "ite"
                              ,  "arity"    .= (Data.Aeson.Types.Number 3)
                              ,  "args"     .= Array (fromList [toJSON a, toJSON b, toJSON c])]
  toJSON v = error $ "todo: json ast for: " <> show v

instance ToJSON (Exp Bool) where
  toJSON (And a b)  = symbol "and" a b
  toJSON (Or a b)   = symbol "or" a b
  toJSON (LE a b)   = symbol "<" a b
  toJSON (GE a b)   = symbol ">" a b
  toJSON (Impl a b) = symbol "=>" a b
  toJSON (NEq a b)  = symbol "=/=" a b
  toJSON (Eq a b)   = symbol "==" a b
  toJSON (LEQ a b)  = symbol "<=" a b
  toJSON (GEQ a b)  = symbol ">=" a b
  toJSON (LitBool a) = String $ pack $ show a
  toJSON (BoolVar a) = toJSON a
  toJSON (Neg a) = object [  "symbol"   .= pack "not"
                          ,  "arity"    .= (Data.Aeson.Types.Number 1)
                          ,  "args"     .= (Array $ fromList [toJSON a])]
  toJSON v = error $ "todo: json ast for: " <> show v

instance ToJSON (Exp ByteString) where
  toJSON a = String $ pack $ show a


mapping :: (ToJSON a1, ToJSON a2, ToJSON a3) => a1 -> a2 -> a3 -> Value
mapping c a b = object [  "symbol"   .= pack "lookup"
                       ,  "arity"    .= (Data.Aeson.Types.Number 3)
                       ,  "args"     .= (Array $ fromList [toJSON c, toJSON a, toJSON b])]

symbol :: (ToJSON a1, ToJSON a2) => String -> a1 -> a2 -> Value
symbol s a b = object [  "symbol"   .= pack s
                      ,  "arity"    .= (Data.Aeson.Types.Number 2)
                      ,  "args"     .= (Array $ fromList [toJSON a, toJSON b])]

intmin :: Int -> Integer
intmin a = negate $ 2 ^ (a - 1)

intmax :: Int -> Integer
intmax a = 2 ^ (a - 1) - 1

uintmin :: Int -> Integer
uintmin _ = 0

uintmax :: Int -> Integer
uintmax a = 2 ^ a - 1