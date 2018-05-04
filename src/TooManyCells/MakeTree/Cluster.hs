{- TooManyCells.MakeTree.Cluster
Gregory W. Schwartz

Collects the functions pertaining to the clustering of columns.
-}

{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

module TooManyCells.MakeTree.Cluster
    ( hdbscan
    , clustersToClusterList
    , hClust
    , hSpecClust
    , assignClusters
    , dendrogramToClusterList
    , clusterDiversity
    ) where

-- Remote
import BirchBeer.Types
import BirchBeer.Utility (getGraphLeaves, getGraphLeavesWithParents, dendrogramToGraph)
import Data.Function (on)
import Data.List (sortBy, groupBy, zip4, genericLength)
import Data.Int (Int32)
import Data.Maybe (fromMaybe, catMaybes, mapMaybe)
import Data.Monoid ((<>))
import Data.Tuple (swap)
import H.Prelude (io)
import Language.R as R
import Language.R.QQ (r)
import Math.Clustering.Hierarchical.Spectral.Sparse (hierarchicalSpectralCluster, B (..))
import Math.Clustering.Hierarchical.Spectral.Types (clusteringTreeToDendrogram, getClusterItemsDend)
import Math.Diversity.Diversity (diversity)
import Statistics.Quantile (continuousBy, s)
import System.IO (hPutStrLn, stderr)
import Safe (headMay)
import TextShow (showt)
import qualified Control.Lens as L
import qualified Data.ByteString.Lazy.Char8 as B
import qualified Data.Clustering.Hierarchical as HC
import qualified Data.Csv as CSV
import qualified Data.Foldable as F
import qualified Data.Graph.Inductive as G
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified Data.Sparse.Common as S
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU
import qualified Numeric.LinearAlgebra as H

-- Local
import TooManyCells.MakeTree.Adjacency
import TooManyCells.MakeTree.Types
import TooManyCells.Matrix.Types
import TooManyCells.Diversity.Types

-- | Cluster cLanguage.R.QQ (r)olumns of a sparse matrix using HDBSCAN.
hdbscan :: RMatObsRow s -> R s (R.SomeSEXP s)
hdbscan (RMatObsRow mat) = do
    [r| library(dbscan) |]

    clustering  <- [r| hdbscan(mat_hs, minPts = 5) |]

    return clustering

-- | Hierarchical clustering.
hClust :: SingleCells -> ClusterResults
hClust sc =
    ClusterResults { _clusterList = clustering
                   , _clusterDend = cDend
                   }
  where
    cDend = fmap ( V.singleton
                 . (\ (!w, _, !y, !z)
                   -> CellInfo { _barcode = w, _cellRow = y, _projection = z }
                   )
                 )
            dend
    clustering = assignClusters
               . fmap ( fmap ((\(!w, _, !y, !z) -> CellInfo w y z))
                      . HC.elements
                      )
               . flip HC.cutAt (findCut dend)
               $ dend
    dend = HC.dendrogram HC.CLINK items euclDist
    euclDist x y =
        sqrt . sum . fmap (** 2) $ S.liftU2 (-) (L.view L._2 y) (L.view L._2 x)
    items = (\ fs
            -> zip4
                   (V.toList $ _rowNames sc)
                   fs
                   (fmap Row . take (V.length . _rowNames $ sc) . iterate (+ 1) $ 0)
                   (V.toList $ _projections sc)
            )
          . S.toRowsL
          . unMatObsRow
          . _matrix
          $ sc

-- | Assign clusters to values. Thanks to hierarchical clustering, we can have
-- a cell belong to multiple clusters.
assignClusters :: [[a]] -> [(a, [Cluster])]
assignClusters =
    concat . zipWith (\c -> flip zip (repeat c)) (fmap ((:[]) . Cluster) [1..])

-- | Find cut value.
findCut :: HC.Dendrogram a -> HC.Distance
findCut = continuousBy s 9 10 . VU.fromList . F.toList . flattenDist
  where
    flattenDist (HC.Leaf _)          = Seq.empty
    flattenDist (HC.Branch !d !l !r) =
        (Seq.<|) d . (Seq.><) (flattenDist l) . flattenDist $ r

-- | Convert the cluster object from hdbscan to a cluster list.
clustersToClusterList :: SingleCells
                      -> R.SomeSEXP s
                      -> R s [(Cell, Cluster)]
clustersToClusterList sc clustering = do
    io . hPutStrLn stderr $ "Calculating clusters."
    clusters <- [r| clustering_hs$cluster |]
    return
        . zip (V.toList . _rowNames $ sc)
        . fmap (Cluster . fromIntegral)
        $ (R.fromSomeSEXP clusters :: [Int32])

-- | Hierarchical spectral clustering.
hSpecClust :: NormType
           -> SingleCells
           -> (ClusterResults, ClusterGraph CellInfo)
hSpecClust norm sc =
    ( ClusterResults { _clusterList = clustering
                     , _clusterDend = dend
                     }
    , gr
    )
  where
    clustering :: [(CellInfo, [Cluster])]
    clustering =
        concatMap (\ (!ns, (_, !xs))
                  -> zip (maybe [] F.toList xs) . repeat . fmap Cluster $ ns
                  )
            . F.toList
            . flip getGraphLeavesWithParents 0
            . unClusterGraph
            $ gr
    gr         = dendrogramToGraph dend
    dend       = clusteringTreeToDendrogram tree
    (tree, _)  = hSpecCommand norm
               . Left
               . unMatObsRow
               . _matrix
               $ sc
    items      = V.zipWith3
                    (\x y z -> CellInfo x y z)
                    (_rowNames sc)
                    (fmap Row . flip V.generate id . V.length . _rowNames $ sc)
                    (_projections sc)
    hSpecCommand B1Norm = hierarchicalSpectralCluster True Nothing items
    hSpecCommand _      = hierarchicalSpectralCluster False Nothing items

dendrogramToClusterList :: HC.Dendrogram (V.Vector CellInfo)
                        -> [(CellInfo, [Cluster])]
dendrogramToClusterList =
    concatMap (\ (!ns, (_, !xs))
                -> zip (maybe [] F.toList xs) . repeat . fmap Cluster $ ns
                )
        . F.toList
        . flip getGraphLeavesWithParents 0
        . unClusterGraph
        . dendrogramToGraph

-- | Find the diversity of each leaf cluster.
clusterDiversity :: Order
                 -> LabelMap
                 -> ClusterResults
                 -> [(Cluster, Diversity, Size)]
clusterDiversity (Order order) (LabelMap lm) =
    getDiversityOfCluster . _clusterList
  where
    getDiversityOfCluster :: [(CellInfo, [Cluster])]
                          -> [(Cluster, Diversity, Size)]
    getDiversityOfCluster =
        fmap (\ (!c, !xs)
             -> ( c
                , Diversity . diversity order . fmap cellInfoToLabel $ xs
                , Size $ genericLength xs)
             )
            . groupCellsByCluster
    cellInfoToLabel :: CellInfo -> Label
    cellInfoToLabel =
        flip (Map.findWithDefault (error "Cell missing a label.")) lm
            . Id
            . unCell
            . _barcode
    groupCellsByCluster :: [(CellInfo, [Cluster])] -> [(Cluster, [CellInfo])]
    groupCellsByCluster = fmap assignCluster
                        . groupBy ((==) `on` (headMay . snd))
                        . sortBy (compare `on` (headMay . snd))
    assignCluster :: [(CellInfo, [Cluster])] -> (Cluster, [CellInfo])
    assignCluster [] = error "Empty cluster."
    assignCluster all@(x:_) =
        ( fromMaybe (error "No cluster for cell.") . headMay . snd $ x
        , fmap fst all
        )
