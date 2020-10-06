{-# Language RecordWildCards #-}
{-# Language LambdaCase #-}
{-# Language TypeApplications #-}
{-# Language OverloadedStrings #-}
{-# Language DataKinds #-}
{-# Language GADTs #-}
module HEVM where

import Prelude hiding (lookup)
import Syntax
import RefinedAst hiding (S)

import Data.Text (Text, pack, splitOn) -- hiding (length, drop, splitOn, null, breakOn, findIndex, splitAt)
import Data.Maybe
import Data.List hiding (lookup)
import Data.Map hiding (drop, null, findIndex, splitAt, foldl)
import qualified Data.ByteString as BS
import qualified Data.Map as Map
import Control.Monad.State.Strict (execState)
import Data.SBV.Control
import Data.SBV
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Control.Lens hiding (pre)
import Control.Monad
import qualified Data.Vector as Vec

import K hiding (storage)
import Prove
import Type

import EVM hiding (Query)
import EVM.VMTest
import EVM.Solidity hiding (Method)
import EVM.ABI
import EVM.Concrete
import EVM.SymExec
import EVM.Symbolic
import EVM.Types

type SolcJson = Map Text SolcContract

proveBehaviour :: SolcJson -> Behaviour -> Symbolic (Either (VM, [VM]) VM)
proveBehaviour sources behaviour = do
  -- todo: deal with ambiguities
  let sources' = mapKeys (last . splitOn ":") sources
      contractMap :: Map Id Addr -- TODO: this can be given as an option as well
                                 -- (in case you wanna verify against rpc or smth)
      contractMap = fromList $ zipWith 
                      (\id' i -> (id', createAddress (Addr 0) i)) (contractsInvolved behaviour) [0..]
  vm <- initialVm sources' behaviour contractMap
  -- make context for trivial invariant
  let ctx = mkVmContext sources' behaviour contractMap

      postC (pre, post) = mkPostCondition behaviour (ctx pre post)
  query $ do res <- verify vm Nothing Nothing (Just postC)
             case res of
               Right vm -> do showCounterexample vm Nothing
                              return res
               _ -> return res

contractsInvolved :: Behaviour -> [Id]
contractsInvolved beh =
  getContractId . getLoc <$> _stateUpdates beh

getContractId :: StorageLocation -> Id
getContractId (IntLoc (DirectInt a _)) = a
getContractId (BoolLoc (DirectBool a _)) = a
getContractId (BytesLoc (DirectBytes a _)) = a
getContractId (IntLoc (MappedInt a _ _)) = a
getContractId (BoolLoc (MappedBool a _ _)) = a
getContractId (BytesLoc (MappedBytes a _ _)) = a

    
interfaceCalldata :: Interface -> Symbolic Buffer
interfaceCalldata (Interface methodname vars) =
  let types = fmap (\(Decl typ name) -> typ) vars
      textsig = pack $ methodname ++ "(" ++ intercalate "," (show <$> types) ++ ")"
      sig' = litBytes $ selector textsig
  
  in SymbolicBuffer <$> (sig' <>) <$> concat <$> forM types mkabiArg

initialVm :: SolcJson -> Behaviour -> Map Id Addr -> Symbolic VM
initialVm sources b@Behaviour{..} contractMap = do
  let
    -- todo; ensure no duplicates
    this = fromMaybe (error ("Bytecode not found for: " <> show _contract <> ".\nSources available: " <> show (keys sources))) (lookup (pack _contract) sources)
    c = fromMaybe (error ("Address not found for: " ++ show _contract ++ ".\nAvailable: " ++ show (keys contractMap))) (lookup _contract contractMap)
  cd <- interfaceCalldata _interface
  caller' <- SAddr <$> sWord_
  value' <- sw256 <$> sWord_
  store <- return $ Concrete mempty --this can be removed if we use something else than loadSymVM
  contracts' <- forM (toList contractMap) $
    \(contractId, addr) -> do
        let code' = RuntimeCode $ view runtimeCode $
              fromMaybe (error "bytecode not found")
              (lookup (pack contractId) sources)
        c <- contractWithStore code' <$> Symbolic <$> newArray_ Nothing
        return (addr, c)

  let vm = loadSymVM
        (RuntimeCode $ view runtimeCode this)
        store
        (if _creation then InitialS else SymbolicS)
        caller'
        value'
        (cd, literal $ fromIntegral $ len cd)
        & over (env . contracts) (\a -> a <> (fromList contracts'))

  return $ initTx $ execState (loadContract c) vm

-- assumes preconditions as well
mkPostCondition :: Behaviour -> (Ctx, Maybe SMType) -> SBool
mkPostCondition
  (Behaviour name mode creation contract interface preCond postCond updates returns)
  (ctx, actualReturn) =
  if creation then error "todo: constructor"
  else 
    let storageConstraints = sAnd $ mkConstraint ctx <$> updates
        preCond' = symExpBool ctx Pre preCond
        postCond' = symExpBool ctx Pre postCond
        ret = symExp ctx Pre <$> returns
    in preCond' .=>
       (postCond' .&&
        storageConstraints .&&
        ret .== actualReturn)
--  let preCond = _

--  storageConstraints = mkStorageConstraints ctx (_stateUpdates behv) locs

mkVmContext :: SolcJson -> Behaviour -> Map Id Addr -> VM -> VM -> (Ctx, Maybe SMType)
mkVmContext solcjson (Behaviour method _ _ c1 (Interface _ decls) _ _ updates returns) contractMap pre post =
  let args = fromList $ flip fmap decls $
        \d@(Decl _ name) -> (name, locateCalldata d decls (fst $ view (state . calldata) pre))
      env' = error "TODO: make environment"
      construct = case returns of
        Just (ExpInt i) -> SymInteger
        Just (ExpBool b) -> SymBool
        Just (ExpBytes b) -> SymBytes
      ret = case view result post of
        Just (EVM.VMSuccess (ConcreteBuffer msg)) ->
          if BS.null msg
          then Nothing
          else Just (construct (fromIntegral (wordAt 0 msg)))
        Just _ -> _
        Nothing -> error "vm did not finish" --error "TODO: make return expression" -- returnexp
      -- add storage entries to the 'store' map as we go along
      ctx = foldl
       (\ctx'@(Ctx c m a s e) update' ->
         let
           (name, entry) = locateStorage ctx' solcjson contractMap method (pre, post) update'
         in Ctx c m a (Map.insert name entry s) e) (Ctx c1 method args mempty env') updates
  in (ctx, ret)

locateStorage :: Ctx -> SolcJson -> Map Id Addr -> Method -> (VM,VM) -> Either StorageLocation StorageUpdate -> (Id, (SMType, SMType))
locateStorage ctx solcjson contractMap method (pre, post) item =
  let item' = getLoc item
      contractId = getContractId $ item'
      addr = fromMaybe (error "internal error: could not find contract")
        (lookup contractId contractMap)

      Just preContract = view (env . contracts . at addr) pre
      Just postContract = view (env . contracts . at addr) post


      Just (S _ preValue) = readStorage (view storage preContract) (calculateSlot ctx solcjson item')
      Just (S _ postValue) = readStorage (view storage postContract) (calculateSlot ctx solcjson item')

      name :: StorageLocation -> Id
      name (IntLoc i) = nameFromItem method i
      name (BoolLoc i) = nameFromItem method i
      name (BytesLoc i) = nameFromItem method i

  in (name item',  (SymInteger (sFromIntegral preValue), SymInteger (sFromIntegral postValue)))


calculateSlot :: Ctx -> SolcJson -> StorageLocation -> SymWord
calculateSlot ctx solcjson loc =
  -- TODO: packing
  let
    source = fromMaybe (error "internal error: could not find contract") (lookup (pack (getContractId loc)) solcjson)
    layout = fromMaybe (error "internal error: no storageLayout") $ _storageLayout source
  in case loc of
 IntLoc (MappedInt contractId containerId ixs) ->
  let
     StorageItem _ offset slot = fromMaybe (error (show containerId ++ " not found in " ++ show contractId)) $ lookup (pack containerId) layout
     indexers = symExp ctx Pre <$> ixs
     start = sFromIntegral (literal (fromIntegral slot :: Integer))
  in sw256 $ foldl (\a b -> keccak' (SymbolicBuffer (toBytes a <> (toSymBytes b)))) start indexers

 IntLoc (DirectInt contractId containerId) ->
  let
     StorageItem _ offset slot = fromMaybe (error (show containerId ++ " not found in " ++ show contractId)) $ lookup (pack containerId) layout
  in sw256 (sFromIntegral (literal ((fromIntegral slot) :: Integer)))


toSymBytes :: SMType -> [SWord 8]
toSymBytes (SymInteger i) = toBytes (sFromIntegral i :: SWord 256)
toSymBytes (SymBool i) = ite i (toBytes (1 :: SWord 256)) (toBytes (0 :: SWord 256))
toSymBytes (SymBytes _) = error "unsupported"

locateCalldata :: Decl -> [Decl] -> Buffer -> SMType
locateCalldata d@(Decl typ name) decls calldata' =
  if any (\(Decl typ' _) -> abiKind typ' /= Static) decls
  then error "dynamic calldata args currently unsupported"
  else
    let
      -- every argument is static right now; length is always 32
      offset = w256 $ fromIntegral $ 4 + 32 * (fromMaybe
                                (error ("internal error: could not find calldata var: " ++
                                 name ++ " in interface declaration"))
                                (findIndex (== d) decls))
    in case metaType typ of
      -- all integers are 32 bytes
      Integer -> let S _ w = readSWord offset calldata'
                 in SymInteger $ sFromIntegral w
      -- interpret all nonzero values as boolean true
      Boolean -> SymBool $ readSWord offset calldata' ./= 0
      _ -> error "TODO: support bytes"


-- | Convenience functions for generating symbolic byte strings
freshbytes32 :: Symbolic [SWord 8]
freshbytes32 = toBytes <$> free_ @ (WordN 256)

-- | Adapted from SymExec.symAbiArg to fit into the `Symbolic` monad instead of
-- `Query`.
mkabiArg :: AbiType -> Symbolic [SWord 8]
mkabiArg (AbiUIntType n) | n `mod` 8 == 0 && n <= 256 = freshbytes32
                         | otherwise = error "bad type"

mkabiArg (AbiIntType n)  | n `mod` 8 == 0 && n <= 256 = freshbytes32
                         | otherwise = error "bad type"

mkabiArg AbiBoolType = freshbytes32

mkabiArg AbiAddressType = freshbytes32

mkabiArg (AbiBytesType n) | n <= 32 = freshbytes32
                          | otherwise = error "bad type"

-- TODO: is this encoding correct?
mkabiArg (AbiArrayType leng typ) =
  do args <- concat <$> mapM mkabiArg (replicate leng typ)
     return (litBytes (encodeAbiValue (AbiUInt 256 (fromIntegral leng))) <> args)

mkabiArg (AbiTupleType tuple) = concat <$> mapM mkabiArg (Vec.toList tuple)

mkabiArg n =
  error $ "Unsupported symbolic abiencoding for"
    <> show n
    <> ". Please file an issue at https://github.com/dapphub/dapptools if you really need this."


keccak' :: Buffer -> SWord 256
keccak' (SymbolicBuffer bytes) = case maybeLitBytes bytes of
  Nothing -> symkeccak' bytes
  Just bs -> keccak' (ConcreteBuffer bs)
keccak' (ConcreteBuffer bytes) = literal $ toSizzle $ wordValue $ keccakBlob bytes