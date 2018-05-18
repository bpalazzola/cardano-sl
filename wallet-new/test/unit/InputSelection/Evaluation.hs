{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell            #-}

module InputSelection.Evaluation (
    evaluateInputPolicies
  ) where

import           Universum

import           Control.Lens (Iso', from, (%=), (+=), (.=), (<<+=))
import           Control.Lens.TH (makeLenses, makePrisms, makeWrapped)
import           Control.Lens.Wrapped (_Wrapped)
import           Data.Conduit
import qualified Data.Conduit.Lift as Conduit
import qualified Data.Text.IO as Text
import           Formatting (build, sformat, (%))
import           Pos.Util.Chrono
import           System.Directory (createDirectoryIfMissing)
import           System.FilePath ((<.>), (</>))
import qualified System.IO as IO
import           Text.Printf (printf)

import           InputSelection.Generator (Event (..), Mean (..), StdDev (..), World (..))
import qualified InputSelection.Generator as Gen
import           InputSelection.Policy (InputSelectionPolicy, PrivacyMode (..), RunPolicy (..),
                                        TxStats (..))
import qualified InputSelection.Policy as Policy
import           Util.Histogram (Bin, BinSize (..), Histogram)
import qualified Util.Histogram as Histogram
import qualified Util.MultiSet as MultiSet
import           Util.Range
import           UTxO.DSL

{-------------------------------------------------------------------------------
  Statistics about the current value of the system
-------------------------------------------------------------------------------}

-- | Statistics about the /current/ value of the system
--
-- This information is solely based on the current value of the system, and not
-- affected by the system history. Consequently this does /NOT/ have a 'Monoid'
-- instance.
data CurrentStats = CurrentStats {
      -- | Current UTxO size
      currentUtxoSize      :: Int

      -- | Current UTxO histogram
    , currentUtxoHistogram :: Histogram
    }

deriveCurrentStats :: BinSize -> Utxo h a -> CurrentStats
deriveCurrentStats binSize utxo = CurrentStats {
      currentUtxoSize      = utxoSize utxo
    , currentUtxoHistogram = utxoHistogram binSize utxo
    }

utxoHistogram :: BinSize -> Utxo h a -> Histogram
utxoHistogram binSize =
    Histogram.discretize binSize . map fromIntegral . outputs
  where
    outputs :: Utxo h a -> [Value]
    outputs = map (outVal . snd) . utxoToList

{-------------------------------------------------------------------------------
  Auxiliary: time series
-------------------------------------------------------------------------------}

-- | Time series of values
--
-- When we render a single frame,
--
-- * for some vars we render the /current/ value;
--   for example, we render the current UTxO histogram
-- * for some vars we render the /summarized/ value;
--   for example, we render the overall histogram of number of inputs / tx
-- * for some vars we render a /time series/, from the start until this frame
--   for example, we show the UTxO growth over time
--
-- The 'TimeSeries' is meant to record the third kind of variable.
newtype TimeSeries a = TimeSeries (NewestFirst [] a)
  deriving (Functor)

makePrisms  ''TimeSeries
makeWrapped ''TimeSeries

timeSeriesList :: Iso' (TimeSeries a) [a]
timeSeriesList = _Wrapped . _Wrapped

-- | Bounds for a time series
timeSeriesRange :: TimeSeries Double -> Ranges
timeSeriesRange (TimeSeries (NewestFirst xs)) = Ranges {
      _xRange = Range 0 (fromIntegral (length xs))
    , _yRange = Range 0 (maximum xs)
    }

-- | Write time series to a format gnuplot can read
writeTimeSeries :: Show a => FilePath -> TimeSeries a -> IO ()
writeTimeSeries fp (TimeSeries (NewestFirst ss)) =
    withFile fp WriteMode $ \h ->
      forM_ (reverse ss) $
        IO.hPrint h

{-------------------------------------------------------------------------------
  Accumulated statistics
-------------------------------------------------------------------------------}

-- | Accumulated statistics at a given frame
data AccStats = AccStats {
      -- | Frame
      --
      -- This is just a simple counter
      _accFrame          :: !Int

      -- | Number of payment requests we failed to satisfy
    , _accFailedPayments :: !Int

      -- | Size of the UTxO over time
    , _accUtxoSize       :: !(TimeSeries Int)

      -- | Maximum UTxO histogram
      --
      -- While not particularly meaningful as statistic to display, this is
      -- useful to determine bounds for rendering.
    , _accUtxoHistogram  :: !Histogram

      -- | Transaction statistics
    , _accTxStats        :: !TxStats

      -- | Time series of the median change/payment ratio
    , _accMedianRatio    :: !(TimeSeries Double)
    }

makeLenses ''AccStats

initAccumulatedStats :: AccStats
initAccumulatedStats = AccStats {
      _accFrame          = 0
    , _accFailedPayments = 0
    , _accUtxoSize       = [] ^. from timeSeriesList
    , _accUtxoHistogram  = Histogram.empty
    , _accTxStats        = mempty
    , _accMedianRatio    = [] ^. from timeSeriesList
    }

-- | Construct statistics for the next frame
stepFrame :: CurrentStats -> AccStats -> AccStats
stepFrame CurrentStats{..} st =
    st & accFrame                        %~ succ
       & accUtxoHistogram                %~ Histogram.max currentUtxoHistogram
       & accUtxoSize    . timeSeriesList %~ (currentUtxoSize :)
       & accMedianRatio . timeSeriesList %~ (MultiSet.medianWithDefault 1 txStatsRatios :)
  where
    TxStats{..} = st ^. accTxStats

{-------------------------------------------------------------------------------
  Interpreter state
-------------------------------------------------------------------------------}

data IntState h a = IntState {
      _stUtxo       :: Utxo h a
    , _stPending    :: Utxo h a
    , _stStats      :: AccStats
    , _stFreshHash  :: Int

      -- | Change address
      --
      -- NOTE: At the moment we never modify this; we're not evaluating
      -- privacy, so change to a single address is fine.
    , _stChangeAddr :: a

      -- | Binsize used for histograms
      --
      -- We cannot actually currently change this as we run the interpreter
      -- because `Histogram.max` only applies to histograms wit equal binsizes.
    , _stBinSize    :: BinSize
    }

makeLenses ''IntState

initIntState :: BinSize -> Utxo h a -> a -> IntState h a
initIntState binSize utxo changeAddr = IntState {
      _stUtxo       = utxo
    , _stPending    = utxoEmpty
    , _stStats      = initAccumulatedStats
    , _stFreshHash  = 1
    , _stChangeAddr = changeAddr
    , _stBinSize    = binSize
    }

instance Monad m => RunPolicy (StateT (IntState h a) m) a where
  genChangeAddr = use stChangeAddr
  genFreshHash  = stFreshHash <<+= 1

{-------------------------------------------------------------------------------
  Interpreter proper
-------------------------------------------------------------------------------}

-- | Current UTxO statistics and accumulated statistics for each frame
mkFrame :: Monad m => StateT (IntState h a) m (CurrentStats, AccStats)
mkFrame = state aux
  where
    aux :: IntState h a -> ((CurrentStats, AccStats), IntState h a)
    aux st = ((currentStats, accStats), st & stStats .~ accStats)
      where
        currentStats = deriveCurrentStats (st ^. stBinSize) (st ^. stUtxo)
        accStats     = stepFrame currentStats (st ^. stStats)

-- | Interpreter for events, evaluating a policy
--
-- Turns a stream of events into a stream of observations and accumulated
-- statistics.
--
-- Returns the final state
intPolicy :: forall h a m. (Hash h a, Monad m)
          => InputSelectionPolicy h a (StateT (IntState h a) m)
          -> (a -> Bool)
          -> IntState h a -- Initial state
          -> ConduitT (Event h a) (CurrentStats, AccStats) m (IntState h a)
intPolicy policy ours initState =
    Conduit.execStateC initState $
      awaitForever $ \event -> do
        lift $ go event
        yield =<< lift mkFrame
  where
    go :: Event h a -> StateT (IntState h a) m ()
    go (Deposit new) =
        stUtxo %= utxoUnion new
    go NextSlot = do
        -- TODO: May want to commit only part of the pending transactions
        pending <- use stPending
        stUtxo    %= utxoUnion pending
        stPending .= utxoEmpty
    go (Pay outs) = do
        utxo <- use stUtxo
        mtx  <- policy utxo outs
        case mtx of
          Right (tx, txStats) -> do
            stUtxo               %= utxoRemoveInputs (trIns tx)
            stPending            %= utxoUnion (utxoRestrictToAddr ours (trUtxo tx))
            stStats . accTxStats %= mappend txStats
          Left _err ->
            stStats . accFailedPayments += 1

{-------------------------------------------------------------------------------
  Compute bounds
-------------------------------------------------------------------------------}

-- | Frame bounds
--
-- When we render all frames, they should also use the same bounds for the
-- animation to make any sense. This is also useful to have animations of
-- _different_ policies use the same bounds.
data Bounds = Bounds {
      -- | Range of the UTxO
      _boundsUtxoHistogram :: Ranges

      -- | Range of the UTxO size time series
    , _boundsUtxoSize      :: Ranges

      -- | Range of the transaction inputs
    , _boundsTxInputs      :: Ranges

      -- | Range of the median change/payment time series
    , _boundsMedianRatio   :: Ranges
    }

makeLenses ''Bounds

-- | Derive compute final bounds from accumulated statistics
--
-- We make some adjustments:
--
-- * We prune the UTxO above the specified bin. This allows us to filter out any
--   large "initial payments" from the UTxO graph; we typically have only one
--   such value and if we try to include it in the graph all the other outputs
--   will be squashed into a tiny corner on the left.
-- * For the change/payment ratio, we use a maximum y value of 3. Anything much
--   above that is not particularly interesting anyway.
-- * For number of transaciton inputs we set minimum x to 0 always.
deriveBounds :: AccStats -> Bin -> Bounds
deriveBounds AccStats{..} maxUtxoBin = Bounds {
      _boundsUtxoHistogram = Histogram.range (Histogram.pruneAbove maxUtxoBin _accUtxoHistogram)
    , _boundsUtxoSize      = timeSeriesRange (fromIntegral <$> _accUtxoSize)
    , _boundsTxInputs      = Histogram.range (txStatsNumInputs _accTxStats)
                           & xRange . rangeLo .~ 0
    , _boundsMedianRatio   = timeSeriesRange _accMedianRatio
                           & yRange . rangeHi .~ 2
    }

-- | Align a specific range
--
-- This is useful when aligning graphs.
unionBoundsAt :: Monoid a => Lens' Bounds a -> [Bounds] -> Bounds -> Bounds
unionBoundsAt l bs = l %~ mappend (mconcat (map (view l) bs))

{-------------------------------------------------------------------------------
  Gnuplot output
-------------------------------------------------------------------------------}

-- | Plot instructions
--
-- As we render the observations, we collect a bunch of plot instructions.
-- The reason that we do not execute these as we go is that we do not know
-- a priori which ranges we should use for the graphs (and it is important
-- that we use the same range for all frames).
data PlotInstr = PlotInstr {
      -- | Filename of the frame
      piFrame          :: FilePath

      -- | Number of failed payment attempts
    , piFailedPayments :: Int
    }

-- | Render in gnuplot syntax
renderPlotInstr :: BinSize -> Bounds -> PlotInstr -> Text
renderPlotInstr utxoBinSize bounds PlotInstr{..} = sformat
    ( "# Frame " % build % "\n"
    % "set output '" % build % ".png'\n"
    % "set multiplot\n"

    -- Plot the current UTxO
    % "set xrange " % build % "\n"
    % "set yrange " % build % "\n"
    % "set size 0.7,1\n"
    % "set origin 0,0\n"
    % "set xtics autofreq\n"
    % "set label 1 'failed: " % build % "' at graph 0.95, 0.90 front right\n"
    % "set boxwidth " % build % "\n"
    % "plot '" % build % ".histogram' using 1:2 with boxes\n"
    % "unset label 1\n"

    -- Plot UTxO size time series
    % "set xrange " % build % "\n"
    % "set yrange " % build % "\n"
    % "set size 0.25,0.4\n"
    % "set origin 0.05,0.55\n"
    % "unset xtics\n"
    % "plot '" % build % ".growth' notitle\n"

    -- Plot transaction number of inputs distribution
    % "set xrange " % build % "\n"
    % "set yrange " % build % "\n"
    % "set size 0.25,0.4\n"
    % "set origin 0.65,0.55\n"
    % "set xtics 1\n"
    % "set boxwidth 1\n"
    % "plot '" % build % ".txinputs' using 1:2 with boxes fillstyle solid notitle\n"

    -- Plot average change/payment ratio time series
    % "set xrange " % build % "\n"
    % "set yrange " % build % "\n"
    % "set size 0.25,0.4\n"
    % "set origin 0.65,0.15\n"
    % "unset xtics\n"
    % "plot '" % build % ".ratio' notitle\n"

    % "unset multiplot\n"
    )

    piFrame
    piFrame

    (bounds ^. boundsUtxoHistogram . xRange)
    (bounds ^. boundsUtxoHistogram . yRange)
    piFailedPayments
    utxoBinSize
    piFrame

    (bounds ^. boundsUtxoSize . xRange)
    (bounds ^. boundsUtxoSize . yRange)
    piFrame

    (bounds ^. boundsTxInputs . xRange)
    (bounds ^. boundsTxInputs . yRange)
    piFrame

    (bounds ^. boundsMedianRatio . xRange)
    (bounds ^. boundsMedianRatio . yRange)
    piFrame

-- | Resolution of the resulting file
data Resolution = Resolution {
      resolutionWidth  :: Int
    , resolutionHeight :: Int
    }

-- | Render a complete set of plot instructions
--
-- NOTE: We expect the resolution to have aspect ratio 2:1.
writePlotInstrs :: FilePath -> Resolution -> BinSize -> Bounds -> [PlotInstr] -> IO ()
writePlotInstrs fp (Resolution width height) utxoBinSize bounds is = do
    putStrLn $ sformat ("Writing '" % build % "'") fp
    withFile fp WriteMode $ \h -> do
      Text.hPutStrLn h $ sformat
          ( "set grid\n"
          % "set term png size " % build % ", " % build % "\n"
          )
          width height
      forM_ is $ Text.hPutStrLn h . renderPlotInstr utxoBinSize bounds

{-------------------------------------------------------------------------------
  Render observations
-------------------------------------------------------------------------------}

-- | Sink that writes statistics to disk
writeStats :: forall m. MonadIO m
           => FilePath -- ^ Prefix for the files to create
           -> ConduitT (CurrentStats, AccStats) Void m [PlotInstr]
writeStats prefix =
    loop []
  where
    loop :: [PlotInstr] -> ConduitT (CurrentStats, AccStats) Void m [PlotInstr]
    loop acc = do
        mObs <- await
        case mObs of
          Nothing  -> return $ reverse acc
          Just obs -> loop . (: acc) =<< liftIO (go obs)

    go :: (CurrentStats, AccStats) -> IO PlotInstr
    go (CurrentStats{..}, accStats) = do
        Histogram.writeFile (filepath <.> "histogram") currentUtxoHistogram
        Histogram.writeFile (filepath <.> "txinputs") (txStatsNumInputs txStats)
        writeTimeSeries (filepath <.> "growth") (accStats ^. accUtxoSize)
        writeTimeSeries (filepath <.> "ratio")  (accStats ^. accMedianRatio)
        return PlotInstr {
            piFrame          = filename
          , piFailedPayments = accStats ^. accFailedPayments
          }
      where
        filename = printf "%08d" (accStats ^. accFrame)
        filepath = prefix </> filename
        txStats  = accStats ^. accTxStats

{-------------------------------------------------------------------------------
  Run evaluation
-------------------------------------------------------------------------------}

-- | Evaluate a policy
--
-- Returns the accumulated statistics and the plot instructions; we return these
-- separately so that we combine bounds of related plots and draw them with the
-- same scales.
evaluatePolicy :: Hash h a
               => FilePath
               -> InputSelectionPolicy h a (StateT (IntState h a) IO)
               -> (a -> Bool)
               -> IntState h a
               -> ConduitT () (Event h a) IO ()
               -> IO (AccStats, [PlotInstr])
evaluatePolicy prefix policy ours initState generator = do
    createDirectoryIfMissing False prefix
    fmap (first (view stStats)) $
      runConduit $
        generator                       `fuse`
        intPolicy policy ours initState `fuseBoth`
        writeStats prefix

evaluateInputPolicies :: FilePath -> IO ()
evaluateInputPolicies prefix = do
    let exactInitUtxo = utxoEmpty
    (exactStats, exactPlot) <- evaluatePolicy
      (prefix </> "exact")
      Policy.exactSingleMatchOnly
      (const True)
      (initIntState utxoBinSize exactInitUtxo ())
      (Gen.test Gen.defTestParams)
    let exactBounds = deriveBounds exactStats 2000
    writePlotInstrs
      (prefix </> "exact" </> "mkframes.gnuplot")
      resolution
      utxoBinSize
      exactBounds
      exactPlot

    -- We evaluate largestFirst as well as the random policy (with and without
    -- privacy protection) against the same initial UTxO
    let initUtxo = utxoSingleton (Input (GivenHash 0) 0) (Output Us 1000000)
    (largestStats, largestPlot) <- evaluatePolicy
      (prefix </> "largest")
      Policy.largestFirst
      (== Us)
      (initIntState utxoBinSize initUtxo Us)
      (Gen.trivial (Mean 1000) (StdDev 100) 1000)
    (trivialOffStats, trivialOffPlot) <- evaluatePolicy
      (prefix </> "trivialOff")
      (Policy.random PrivacyModeOff)
      (== Us)
      (initIntState utxoBinSize initUtxo Us)
      (Gen.trivial (Mean 1000) (StdDev 100) 1000)
    (trivialOnStats, trivialOnPlot) <- evaluatePolicy
      (prefix </> "trivialOn")
      (Policy.random PrivacyModeOn)
      (== Us)
      (initIntState utxoBinSize initUtxo Us)
      (Gen.trivial (Mean 1000) (StdDev 100) 1000)

    -- Make sure we use the same bounds for the UTxO
    let largestBounds     = deriveBounds largestStats    2000
        trivialOffBounds  = deriveBounds trivialOffStats 2000
        trivialOnBounds   = deriveBounds trivialOnStats  2000

        commonUtxoBounds  = unionBoundsAt (boundsUtxoHistogram . xRange)
                              [largestBounds, trivialOffBounds, trivialOnBounds]

        largestBounds'    = commonUtxoBounds largestBounds
        trivialOffBounds' = commonUtxoBounds trivialOffBounds
        trivialOnBounds'  = commonUtxoBounds trivialOnBounds

    writePlotInstrs
      (prefix </> "largest" </> "mkframes.gnuplot")
      resolution
      utxoBinSize
      largestBounds'
      largestPlot
    writePlotInstrs
      (prefix </> "trivialOff" </> "mkframes.gnuplot")
      resolution
      utxoBinSize
      trivialOffBounds'
      trivialOffPlot
    writePlotInstrs
      (prefix </> "trivialOn" </> "mkframes.gnuplot")
      resolution
      utxoBinSize
      trivialOnBounds'
      trivialOnPlot
  where
    utxoBinSize = BinSize 10
    resolution  = Resolution {
                      resolutionWidth  = 800
                    , resolutionHeight = 400
                    }

{-

input selection
coin selection

bitcoinj coin selection? ("multiple classes" -- multiple policies)

https://github.com/bitcoin/bitcoin/issues/7664

See ApproximateBestSubset in wallet.cpp.

sweep?



-}


{-
http://murch.one/wp-content/uploads/2016/11/erhardt2016coinselection.pdf
"An Evaluation of Coin Selection Strategies", Master’s Thesis, Mark Erhardt

2.3.4
A transaction output is labeled as dust when its value is similar to the cost of
spending it.Precisely, Bitcoin Core sets the dust limit to a value where spending an
2.3. Transactions 7
output would exceed 1/3 of its value. T

https://youtu.be/vnHQwYxB08Y?t=39m


https://www.youtube.com/watch?v=IKSSWUBqMCM

companies; hundreds of entries in UTxO
individuals: tens of entries

batch payments!
  (Harding, BitcoinTechTalk -- safe up to 80% of transaction fees)

coin selection --
  relatively minor importance
    batching, better representation (SegWit), .. much larger impact
    coin selection only a few percent savings

* FIFO is actually a reasonable strategy (!)
* So is random
    self correcting -- if you have a large amount of small inputs,
    they'll be more likely to be picked!
    (i.e, if 90% of the wallet is small inputs, 90% change of picking them!)

Branch&Bound seems to do exhaustive search (backtracking algorithm) to find
exact matches, coupled with random selection.

A Traceability Analysis of Monero’s Blockchain
https://eprint.iacr.org/2017/338.pdf
-}
