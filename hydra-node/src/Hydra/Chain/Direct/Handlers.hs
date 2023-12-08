{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Provide infrastructure-independent "handlers" for posting transactions and following the chain.
--
-- This module encapsulates the transformation logic between cardano transactions and `HydraNode` abstractions
-- `PostChainTx` and `OnChainTx`, and maintainance of on-chain relevant state.
module Hydra.Chain.Direct.Handlers where

import Hydra.Prelude

import Cardano.Api.UTxO qualified as UTxO
import Cardano.Slotting.Slot (SlotNo (..))
import Control.Concurrent.Class.MonadSTM (modifyTVar, newTVarIO, writeTVar)
import Control.Monad.Class.MonadSTM (throwSTM)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Hydra.Cardano.Api (
  BlockHeader,
  ChainPoint (..),
  Tx,
  TxId,
  chainPointToSlotNo,
  fromLedgerTxIn,
  getChainPoint,
  getTxBody,
  getTxId,
 )
import Hydra.Chain (
  Chain (..),
  ChainCallback,
  ChainEvent (..),
  ChainStateHistory,
  ChainStateType,
  IsChainState,
  OnChainTx (..),
  PostChainTx (..),
  PostTxError (..),
  currentState,
  pushNewState,
  rollbackHistory,
 )
import Hydra.Chain.Direct.State (
  ChainContext (..),
  ChainStateAt (..),
  abort,
  chainSlotFromPoint,
  close,
  collect,
  commit',
  contest,
  contestationPeriod,
  fanout,
  getKnownUTxO,
  initialize,
 )
import Hydra.Chain.Direct.TimeHandle (TimeHandle (..))
import Hydra.Chain.Direct.Tx (
  AbortObservation (..),
  CloseObservation (..),
  ClosedThreadOutput (..),
  CollectComObservation (..),
  CommitObservation (..),
  ContestObservation (..),
  FanoutObservation (..),
  HeadObservation (..),
  OpenThreadOutput (..),
  RawInitObservation (..),
  headSeedToTxIn,
  mkHeadId,
  observeHeadTx,
  txInToHeadSeed,
 )
import Hydra.Chain.Direct.Wallet (
  ErrCoverFee (..),
  TinyWallet (..),
  TinyWalletLog,
 )
import Hydra.ContestationPeriod (toNominalDiffTime)
import Hydra.Ledger (ChainSlot (ChainSlot))
import Hydra.Ledger.Cardano (adjustUTxO)
import Hydra.Logging (Tracer, traceWith)
import Hydra.Party (partyFromChain)
import Hydra.Plutus.Extras (posixToUTCTime)
import Hydra.Plutus.Orphans ()
import System.IO.Error (userError)

-- | Handle of a mutable local chain state that is kept in the direct chain layer.
data LocalChainState m tx = LocalChainState
  { getLatest :: STM m (ChainStateType tx)
  , pushNew :: ChainStateType tx -> STM m ()
  , rollback :: ChainSlot -> STM m (ChainStateType tx)
  , history :: STM m (ChainStateHistory tx)
  }

-- | Initialize a new local chain state from a given chain state history.
newLocalChainState ::
  (MonadSTM m, IsChainState tx) =>
  ChainStateHistory tx ->
  m (LocalChainState m tx)
newLocalChainState chainState = do
  tv <- newTVarIO chainState
  pure
    LocalChainState
      { getLatest = getLatest tv
      , pushNew = pushNew tv
      , rollback = rollback tv
      , history = readTVar tv
      }
 where
  getLatest tv = currentState <$> readTVar tv

  pushNew tv cs =
    modifyTVar tv (pushNewState cs)

  rollback tv chainSlot = do
    rolledBack <-
      readTVar tv
        <&> rollbackHistory chainSlot
    writeTVar tv rolledBack
    pure (currentState rolledBack)

-- * Posting Transactions

-- | A callback used to actually submit a transaction to the chain.
type SubmitTx m = Tx -> m ()

-- | A way to acquire a 'TimeHandle'
type GetTimeHandle m = m TimeHandle

-- | Create a `Chain` component for posting "real" cardano transactions.
--
-- This component does not actually interact with a cardano-node, but creates
-- cardano transactions from `PostChainTx` transactions emitted by a
-- `HydraNode`, balancing and signing them using given `TinyWallet`, before
-- handing it off to the given 'SubmitTx' callback. There is also a 'draftTx'
-- option for drafting a commit tx on behalf of the user using their selected
-- utxo.
--
-- NOTE: Given the constraints on `m` this function should work within `IOSim`
-- and does not require any actual `IO` to happen which makes it highly suitable
-- for simulations and testing.
mkChain ::
  (MonadSTM m, MonadThrow (STM m)) =>
  Tracer m DirectChainLog ->
  -- | Means to acquire a new 'TimeHandle'.
  GetTimeHandle m ->
  TinyWallet m ->
  ChainContext ->
  LocalChainState m Tx ->
  SubmitTx m ->
  Chain Tx m
mkChain tracer queryTimeHandle wallet@TinyWallet{getUTxO} ctx LocalChainState{getLatest} submitTx =
  Chain
    { postTx = \tx -> do
        chainS@ChainStateAt{chainState} <- atomically getLatest
        traceWith tracer $ ToPost{toPost = tx}
        timeHandle <- queryTimeHandle
        vtx <-
          -- FIXME (MB): cardano keys should really not be here (as this
          -- point they are in the 'chainState' stored in the 'ChainContext')
          -- . They are only required for the init transaction and ought to
          -- come from the _client_ and be part of the init request
          -- altogether. This goes in the direction of 'dynamic heads' where
          -- participants aren't known upfront but provided via the API.
          -- Ultimately, an init request from a client would contain all the
          -- details needed to establish connection to the other peers and
          -- to bootstrap the init transaction. For now, we bear with it and
          -- keep the static keys in context.
          atomically (prepareTxToPost timeHandle wallet ctx chainS tx)
            >>= finalizeTx wallet ctx chainState mempty
        submitTx vtx
    , -- Handle that creates a draft commit tx using the user utxo.
      -- Possible errors are handled at the api server level.
      draftCommitTx = \headId utxoToCommit -> do
        ChainStateAt{chainState} <- atomically getLatest
        walletUtxos <- atomically getUTxO
        let walletTxIns = fromLedgerTxIn <$> Map.keys walletUtxos
        let userTxIns = Set.toList $ UTxO.inputSet utxoToCommit
        let matchedWalletUtxo = filter (`elem` walletTxIns) userTxIns
        -- prevent trying to spend internal wallet's utxo
        if null matchedWalletUtxo
          then
            traverse (finalizeTx wallet ctx chainState (fst <$> utxoToCommit)) $
              commit' ctx headId chainState utxoToCommit
          else pure $ Left SpendingNodeUtxoForbidden
    , -- Submit a cardano transaction to the cardano-node using the
      -- LocalTxSubmission protocol.
      submitTx
    }

-- | Balance and sign the given partial transaction.
finalizeTx ::
  MonadThrow m =>
  TinyWallet m ->
  ChainContext ->
  UTxO.UTxO ->
  UTxO.UTxO ->
  Tx ->
  m Tx
finalizeTx TinyWallet{sign, coverFee} ctx utxo userUTxO partialTx = do
  let headUTxO = getKnownUTxO ctx <> utxo <> userUTxO
  coverFee headUTxO partialTx >>= \case
    Left ErrNoFuelUTxOFound ->
      throwIO (NoFuelUTXOFound :: PostTxError Tx)
    Left ErrNotEnoughFunds{} ->
      throwIO (NotEnoughFuel :: PostTxError Tx)
    Left ErrScriptExecutionFailed{scriptFailure = (redeemerPtr, scriptFailure)} ->
      throwIO
        ( ScriptFailedInWallet
            { redeemerPtr = show redeemerPtr
            , failureReason = show scriptFailure
            } ::
            PostTxError Tx
        )
    Left e -> do
      throwIO
        ( InternalWalletError
            { headUTxO
            , reason = show e
            , tx = partialTx
            } ::
            PostTxError Tx
        )
    Right balancedTx -> do
      pure $ sign balancedTx

-- * Following the Chain

-- | A /handler/ that takes care of following the chain.
data ChainSyncHandler m = ChainSyncHandler
  { onRollForward :: BlockHeader -> [Tx] -> m ()
  , onRollBackward :: ChainPoint -> m ()
  }

-- | Conversion of a slot number to a time failed. This can be usually be
-- considered an internal error and may be happening because the used era
-- history is too old.
data TimeConversionException = TimeConversionException
  { slotNo :: SlotNo
  , reason :: Text
  }
  deriving stock (Eq, Show)
  deriving anyclass (Exception)

-- | Creates a `ChainSyncHandler` that can notify the given `callback` of events happening
-- on-chain.
--
-- This forms the other half of a `ChainComponent` along with `mkChain` but is decoupled from
-- actual interactions with the chain.
--
-- A `TimeHandle` is needed to do `SlotNo -> POSIXTime` conversions for 'Tick' events.
--
-- Throws 'TimeConversionException' when a received block's 'SlotNo' cannot be
-- converted to a 'UTCTime' with the given 'TimeHandle'.
chainSyncHandler ::
  forall m.
  (MonadSTM m, MonadThrow m) =>
  -- | Tracer for logging
  Tracer m DirectChainLog ->
  ChainCallback Tx m ->
  -- | Means to acquire a new 'TimeHandle'.
  GetTimeHandle m ->
  -- | Contextual information about our chain connection.
  ChainContext ->
  LocalChainState m Tx ->
  -- | A chain-sync handler to use in a local-chain-sync client.
  ChainSyncHandler m
chainSyncHandler tracer callback getTimeHandle ctx localChainState =
  ChainSyncHandler
    { onRollBackward
    , onRollForward
    }
 where
  ChainContext{networkId} = ctx
  LocalChainState{rollback, getLatest, pushNew} = localChainState

  onRollBackward :: ChainPoint -> m ()
  onRollBackward point = do
    traceWith tracer $ RolledBackward{point}
    rolledBackChainState <- atomically $ rollback (chainSlotFromPoint point)
    callback Rollback{rolledBackChainState}

  onRollForward :: BlockHeader -> [Tx] -> m ()
  onRollForward header receivedTxs = do
    let point = getChainPoint header
    traceWith tracer $
      RolledForward
        { point
        , receivedTxIds = getTxId . getTxBody <$> receivedTxs
        }

    case chainPointToSlotNo point of
      Nothing -> pure ()
      Just slotNo -> do
        timeHandle <- getTimeHandle
        case slotToUTCTime timeHandle slotNo of
          Left reason ->
            throwIO TimeConversionException{slotNo, reason}
          Right utcTime -> do
            let chainSlot = ChainSlot . fromIntegral $ unSlotNo slotNo
            callback (Tick{chainTime = utcTime, chainSlot})

    forM_ receivedTxs $
      maybeObserveSomeTx point
        >=> ( \case
                Nothing -> pure ()
                Just event -> callback event
            )

  maybeObserveSomeTx point tx = atomically $ do
    ChainStateAt{chainState} <- getLatest
    -- TODO: rename chainState to utxo
    let utxo = chainState
    let observation = observeHeadTx networkId utxo tx
    case convertObservation observation of
      Nothing -> pure Nothing
      Just observedTx -> do
        let newChainState =
              ChainStateAt
                { chainState = adjustUTxO tx utxo
                , recordedAt = Just point
                }
        pushNew newChainState
        pure $ Just Observation{observedTx, newChainState}

convertObservation :: HeadObservation -> Maybe (OnChainTx Tx)
convertObservation = \case
  NoHeadTx -> Nothing
  Init RawInitObservation{headId, contestationPeriod, onChainParties, seedTxIn} ->
    pure
      OnInitTx
        { headId = mkHeadId headId
        , headSeed = txInToHeadSeed seedTxIn
        , contestationPeriod
        , parties = concatMap partyFromChain onChainParties
        }
  Abort AbortObservation{} ->
    pure OnAbortTx
  Commit CommitObservation{party, committed} ->
    pure OnCommitTx{party, committed}
  CollectCom CollectComObservation{threadOutput = OpenThreadOutput{openThreadUTxO}} ->
    pure (OnCollectComTx $ UTxO.singleton openThreadUTxO)
  Close CloseObservation{headId, snapshotNumber, threadOutput = ClosedThreadOutput{closedContestationDeadline}} ->
    pure
      OnCloseTx
        { headId
        , snapshotNumber
        , contestationDeadline = posixToUTCTime closedContestationDeadline
        }
  Contest ContestObservation{snapshotNumber} ->
    pure OnContestTx{snapshotNumber}
  Fanout FanoutObservation{} ->
    pure OnFanoutTx

prepareTxToPost ::
  (MonadSTM m, MonadThrow (STM m)) =>
  TimeHandle ->
  TinyWallet m ->
  ChainContext ->
  ChainStateType Tx ->
  PostChainTx Tx ->
  STM m Tx
prepareTxToPost timeHandle wallet ctx@ChainContext{contestationPeriod} ChainStateAt{chainState} tx =
  case tx of
    InitTx params ->
      getSeedInput wallet >>= \case
        Just seedInput ->
          pure $ initialize ctx params seedInput
        Nothing ->
          throwIO (NoSeedInput @Tx)
    AbortTx{utxo, headSeed} ->
      case headSeedToTxIn headSeed of
        Nothing ->
          throwIO (InvalidSeed{headSeed} :: PostTxError Tx)
        Just seedTxIn ->
          case abort ctx seedTxIn chainState utxo of
            Left _ -> throwIO (FailedToConstructAbortTx @Tx)
            Right abortTx -> pure abortTx
    -- TODO: We do not rely on the utxo from the collect com tx here because the
    -- chain head-state is already tracking UTXO entries locked by commit scripts,
    -- and thus, can re-construct the committed UTXO for the collectComTx from
    -- the commits' datums.
    --
    -- Perhaps we do want however to perform some kind of sanity check to ensure
    -- that both states are consistent.
    CollectComTx{} ->
      pure $ collect ctx (error "TODO: create collectComTx using a UTxO only, and headId from CollectComTx along with some other parameters")
    CloseTx{headId, headSeed, headParameters, confirmedSnapshot} -> do
      (currentSlot, currentTime) <- throwLeft currentPointInTime
      upperBound <- calculateTxUpperBoundFromContestationPeriod currentTime
      case headSeedToTxIn headSeed of
        Nothing ->
          throwIO (InvalidSeed{headSeed} :: PostTxError Tx)
        Just seedTxIn ->
          case close ctx seedTxIn chainState headId headParameters confirmedSnapshot currentSlot upperBound of
            Left _ -> throwIO (FailedToConstructCloseTx @Tx)
            Right closeTx -> pure closeTx
    ContestTx{confirmedSnapshot} -> do
      (_, currentTime) <- throwLeft currentPointInTime
      upperBound <- calculateTxUpperBoundFromContestationPeriod currentTime
      pure (contest ctx (error "TODO: create contestTx using a UTxO only, and headId from ContestTx along with some other parameters. XXX: contesters needs to be tracked inside the HeadLogic") confirmedSnapshot upperBound)
    FanoutTx{utxo, contestationDeadline} -> do
      deadlineSlot <- throwLeft $ slotFromUTCTime contestationDeadline
      pure (fanout ctx (error "TODO: create fanoutTx using a UTxO only, along with some other parameters") utxo deadlineSlot)
 where
  -- XXX: Might want a dedicated exception type here
  throwLeft = either (throwSTM . userError . toString) pure

  TimeHandle{currentPointInTime, slotFromUTCTime} = timeHandle

  -- See ADR21 for context
  calculateTxUpperBoundFromContestationPeriod currentTime = do
    let effectiveDelay = min (toNominalDiffTime contestationPeriod) maxGraceTime
    let upperBoundTime = addUTCTime effectiveDelay currentTime
    upperBoundSlot <- throwLeft $ slotFromUTCTime upperBoundTime
    pure (upperBoundSlot, upperBoundTime)

-- | Maximum delay we put on the upper bound of transactions to fit into a block.
-- NOTE: This is highly depending on the network. If the security parameter and
-- epoch length result in a short horizon, this is problematic.
maxGraceTime :: NominalDiffTime
maxGraceTime = 200

--
-- Tracing
--

data DirectChainLog
  = ToPost {toPost :: PostChainTx Tx}
  | PostingTx {txId :: TxId}
  | PostedTx {txId :: TxId}
  | PostingFailed {tx :: Tx, postTxError :: PostTxError Tx}
  | RolledForward {point :: ChainPoint, receivedTxIds :: [TxId]}
  | RolledBackward {point :: ChainPoint}
  | Wallet TinyWalletLog
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Arbitrary DirectChainLog where
  arbitrary = genericArbitrary
  shrink = genericShrink
