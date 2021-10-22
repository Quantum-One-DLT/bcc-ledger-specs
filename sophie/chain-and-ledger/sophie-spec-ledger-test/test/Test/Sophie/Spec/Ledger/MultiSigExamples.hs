{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Test.Sophie.Spec.Ledger.MultiSigExamples
  ( applyTxWithScript,
    aliceOnly,
    bobOnly,
    aliceAndBob,
    aliceOrBob,
    aliceAndBobOrCarl,
    aliceAndBobOrCarlAndDaria,
    aliceAndBobOrCarlOrDaria,
  )
where

import qualified Bcc.Crypto.Hash as Hash
import Bcc.Ledger.Address
  ( Addr,
    pattern Addr,
  )
import Bcc.Ledger.BaseTypes
  ( Network (..),
    StrictMaybe (..),
    maybeToStrictMaybe,
  )
import Bcc.Ledger.Coin
import qualified Bcc.Ledger.Core as Core
import Bcc.Ledger.Credential
  ( pattern KeyHashObj,
    pattern ScriptHashObj,
    pattern StakeRefBase,
  )
import qualified Bcc.Ledger.Crypto as CC (Crypto)
import Bcc.Ledger.Era (Crypto)
import Bcc.Ledger.Keys
  ( GenDelegs (..),
    KeyHash (..),
    KeyPair,
    KeyRole (..),
    asWitness,
  )
import Bcc.Ledger.SafeHash (hashAnnotated)
import Bcc.Ledger.Sophie (SophieEra)
import Bcc.Ledger.Slot (SlotNo (..))
import qualified Bcc.Ledger.Val as Val
import Control.State.Transition.Extended (PredicateFailure, TRC (..))
import Data.Foldable (fold)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map (empty, fromList)
import Data.Sequence.Strict (StrictSeq (..))
import qualified Data.Sequence.Strict as StrictSeq
import qualified Data.Set as Set (fromList)
import GHC.Records (HasField (..))
import Sophie.Spec.Ledger.API
  ( ScriptHash,
    UTXOW,
  )
import Sophie.Spec.Ledger.LedgerState
  ( LedgerState (..),
    UTxOState,
    genesisState,
  )
import Sophie.Spec.Ledger.Metadata (Metadata)
import Sophie.Spec.Ledger.PParams (PParams, PParams' (..), emptyPParams, _maxTxSize)
import Sophie.Spec.Ledger.STS.Utxo (UtxoEnv (..))
import Sophie.Spec.Ledger.Scripts
  ( MultiSig,
    pattern RequireAllOf,
    pattern RequireAnyOf,
    pattern RequireMOf,
    pattern RequireSignature,
    pattern ScriptHash,
  )
import Sophie.Spec.Ledger.Tx
  ( Tx (..),
    TxId,
    WitnessSetHKD (..),
    hashScript,
  )
import Sophie.Spec.Ledger.TxBody
  ( TxBody (..),
    TxIn (..),
    TxOut (..),
    Wdrl (..),
  )
import Sophie.Spec.Ledger.UTxO (makeWitnessesVKey, txid)
import Test.Sophie.Spec.Ledger.ConcreteCryptoTypes
  ( Mock,
  )
import qualified Test.Sophie.Spec.Ledger.Examples.Cast as Cast
import Test.Sophie.Spec.Ledger.Generator.Core
  ( genesisCoins,
  )
import Test.Sophie.Spec.Ledger.Generator.EraGen (genesisId)
import Test.Sophie.Spec.Ledger.Generator.SophieEraGen ()
import Test.Sophie.Spec.Ledger.SentryUtils

-- Multi-Signature tests

-- This compile-time test asserts that the script hash and key hash use the
-- same hash size and indeed hash function. We do this by checking we can
-- type-check the following code that converts between them by using the hash
-- casting function which changes what the hash is of, without changing the
-- hashing algorithm.
--
_assertScriptHashSizeMatchesAddrHashSize ::
  ScriptHash crypto ->
  KeyHash r crypto
_assertScriptHashSizeMatchesAddrHashSize (ScriptHash h) =
  KeyHash (Hash.castHash h)

-- Multi-signature scripts
singleKeyOnly :: CC.Crypto crypto => Addr crypto -> MultiSig crypto
singleKeyOnly (Addr _ (KeyHashObj pk) _) = RequireSignature $ asWitness pk
singleKeyOnly _ = error "use VKey address"

aliceOnly :: CC.Crypto crypto => MultiSig crypto
aliceOnly = singleKeyOnly Cast.aliceAddr

bobOnly :: CC.Crypto crypto => MultiSig crypto
bobOnly = singleKeyOnly Cast.bobAddr

aliceOrBob :: CC.Crypto crypto => MultiSig crypto
aliceOrBob = RequireAnyOf [aliceOnly, singleKeyOnly Cast.bobAddr]

aliceAndBob :: CC.Crypto crypto => MultiSig crypto
aliceAndBob = RequireAllOf [aliceOnly, singleKeyOnly Cast.bobAddr]

aliceAndBobOrCarl :: CC.Crypto crypto => MultiSig crypto
aliceAndBobOrCarl = RequireMOf 1 [aliceAndBob, singleKeyOnly Cast.carlAddr]

aliceAndBobOrCarlAndDaria :: CC.Crypto crypto => MultiSig crypto
aliceAndBobOrCarlAndDaria =
  RequireAnyOf
    [ aliceAndBob,
      RequireAllOf [singleKeyOnly Cast.carlAddr, singleKeyOnly Cast.dariaAddr]
    ]

aliceAndBobOrCarlOrDaria :: CC.Crypto crypto => MultiSig crypto
aliceAndBobOrCarlOrDaria =
  RequireMOf
    1
    [ aliceAndBob,
      RequireAnyOf [singleKeyOnly Cast.carlAddr, singleKeyOnly Cast.dariaAddr]
    ]

initTxBody :: SophieTest era => [(Addr (Crypto era), Core.Value era)] -> TxBody era
initTxBody addrs =
  TxBody
    (Set.fromList [TxIn genesisId 0, TxIn genesisId 1])
    (StrictSeq.fromList $ map (uncurry TxOut) addrs)
    Empty
    (Wdrl Map.empty)
    (Coin 0)
    (SlotNo 0)
    SNothing
    SNothing

makeTxBody ::
  SophieTest era =>
  [TxIn (Crypto era)] ->
  [(Addr (Crypto era), Core.Value era)] ->
  Wdrl (Crypto era) ->
  TxBody era
makeTxBody inp addrCs wdrl =
  TxBody
    (Set.fromList inp)
    (StrictSeq.fromList [uncurry TxOut addrC | addrC <- addrCs])
    Empty
    wdrl
    (Coin 0)
    (SlotNo 10)
    SNothing
    SNothing

makeTx ::
  forall c.
  (Mock c) =>
  Core.TxBody (SophieEra c) ->
  [KeyPair 'Witness c] ->
  Map (ScriptHash c) (MultiSig c) ->
  Maybe (Metadata (SophieEra c)) ->
  Tx (SophieEra c)
makeTx txBody keyPairs msigs = Tx txBody txWits . maybeToStrictMaybe
  where
    txWits =
      mempty
        { addrWits = makeWitnessesVKey (hashAnnotated $ txBody) keyPairs,
          scriptWits = msigs
        }

aliceInitCoin :: Coin
aliceInitCoin = Coin 10000

bobInitCoin :: Coin
bobInitCoin = Coin 1000

genesis :: forall era. SophieTest era => LedgerState era
genesis = genesisState genDelegs0 utxo0
  where
    genDelegs0 = Map.empty
    utxo0 =
      genesisCoins @era
        genesisId
        [ TxOut Cast.aliceAddr (Val.inject aliceInitCoin),
          TxOut Cast.bobAddr (Val.inject bobInitCoin)
        ]

initPParams :: PParams era
initPParams = emptyPParams {_maxTxSize = 1000}

-- | Create an initial UTxO state where Alice has 'aliceInitCoin' and Bob
-- 'bobInitCoin' to spend. Then create and apply a transaction which, if
-- 'aliceKeep' is greater than 0, gives that amount to Alice and creates outputs
-- locked by a script for each pair of script, coin value in 'msigs'.
initialUTxOState ::
  forall c.
  Mock c =>
  Coin ->
  [(MultiSig c, Coin)] ->
  ( TxId c,
    Either
      [PredicateFailure (UTXOW (SophieEra c))]
      (UTxOState (SophieEra c))
  )
initialUTxOState aliceKeep msigs =
  let addresses =
        [(Cast.aliceAddr, aliceKeep) | Val.pointwise (>) aliceKeep mempty]
          ++ map
            ( \(msig, era) ->
                ( Addr
                    Testnet
                    (ScriptHashObj $ hashScript @(SophieEra c) msig)
                    (StakeRefBase $ ScriptHashObj $ hashScript @(SophieEra c) msig),
                  era
                )
            )
            msigs
   in let tx =
            makeTx
              (initTxBody addresses)
              (asWitness <$> [Cast.alicePay, Cast.bobPay])
              Map.empty
              Nothing
       in ( txid $ getField @"body" tx,
            runSophieBase $
              applySTSTest @(UTXOW (SophieEra c))
                ( TRC
                    ( UtxoEnv
                        (SlotNo 0)
                        initPParams
                        Map.empty
                        (GenDelegs Map.empty),
                      _utxoState genesis,
                      tx
                    )
                )
          )

-- | Start from genesis, consume Alice's and Bob's coins, create an output
-- spendable by Alice if 'aliceKeep' is greater than 0. For each pair of script
-- and coin value in 'lockScripts' create an output of that value locked by the
-- script. Sign the transaction with keys in 'signers'. Then create an
-- transaction that uses the scripts in 'unlockScripts' (and the output for
-- 'aliceKeep' in the case of it being non-zero) to spend all funds back to
-- Alice. Return resulting UTxO state or collected errors
applyTxWithScript ::
  forall c.
  (Mock c) =>
  [(MultiSig c, Coin)] ->
  [MultiSig c] ->
  Wdrl c ->
  Coin ->
  [KeyPair 'Witness c] ->
  Either [PredicateFailure (UTXOW (SophieEra c))] (UTxOState (SophieEra c))
applyTxWithScript lockScripts unlockScripts wdrl aliceKeep signers = utxoSt'
  where
    (txId, initUtxo) = initialUTxOState aliceKeep lockScripts
    utxoSt = case initUtxo of
      Right utxoSt'' -> utxoSt''
      _ ->
        error
          ( "must fail test before: "
              ++ show initUtxo
          )
    txbody =
      makeTxBody
        inputs'
        [(Cast.aliceAddr, (Val.inject $ aliceInitCoin <> bobInitCoin <> fold (unWdrl wdrl)))]
        wdrl
    inputs' =
      [ TxIn txId (fromIntegral n)
        | n <-
            [0 .. length lockScripts - (if (Val.pointwise (>) aliceKeep mempty) then 0 else 1)]
      ]
    -- alice? + scripts
    tx =
      makeTx
        txbody
        signers
        (Map.fromList $ map (\scr -> (hashScript @(SophieEra c) scr, scr)) unlockScripts)
        Nothing
    utxoSt' =
      runSophieBase $
        applySTSTest @(UTXOW (SophieEra c))
          ( TRC
              ( UtxoEnv
                  (SlotNo 0)
                  initPParams
                  Map.empty
                  (GenDelegs Map.empty),
                utxoSt,
                tx
              )
          )
