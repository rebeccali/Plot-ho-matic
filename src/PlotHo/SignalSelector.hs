{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE PackageImports #-}

module PlotHo.SignalSelector
       ( SignalSelector(..)
       , Selector(..)
       , newSignalSelectorArea
       , newMultiSignalSelectorArea
       , gettersAndTitle
       ) where

import qualified Control.Concurrent as CC
import Control.Monad ( unless, void, when )
import Data.IORef ( IORef, readIORef, writeIORef )
import Data.List ( foldl', intercalate, elemIndex, delete )
import qualified Data.Map as M
import Data.Maybe ( isNothing, fromJust, catMaybes )
import Data.Tree ( Tree )
import qualified Data.Tree as Tree
import "gtk3" Graphics.UI.Gtk ( AttrOp( (:=) ) )
import qualified "gtk3" Graphics.UI.Gtk as Gtk
import System.Glib.Signals ( on )
import System.Glib.UTFString ( DefaultGlibString )

import PlotHo.PlotTypes
import Debug.Trace

data SignalSelector a
  = SignalSelector
    { ssTreeView :: Gtk.TreeView
    , ssTreeStore :: Gtk.TreeStore ListViewInfo
    , ssSelectors :: a
    }

data Selector
 = Selector
  { sRebuildSignalTree :: forall a . Element' a -> SignalTree a -> IO ()
  , sToPlotValues :: IO (Maybe String, [(String, [[(Double, Double)]])])
  , sCheckedTreePaths :: Maybe (CC.MVar [DefaultGlibString])
  }

newMultiSignalSelectorArea :: [Element] -> Int -> IO (SignalSelector [Selector])
newMultiSignalSelectorArea elems numCols = do

  -- Be sure to get the # columns right or there will be a runtime error
  treeStore <- Gtk.treeStoreNew $ initialForest elems (numCols + 1)
  treeview <- Gtk.treeViewNewWithModel treeStore

  Gtk.treeViewSetHeadersVisible treeview True

  (setSignalAttrAndRender, _) <- signalColumn treeStore treeview "signal"
  -- add some columns

  attrAndColAndMVar <- mapM (\n -> checkMarkColumn treeStore treeview ("Plot " ++ show n)) [1,2..numCols]
  let (setAttrAndRenders, columns, checkedTreePathsMVar) = unzip3 $ attrAndColAndMVar
  -- set the attributes
  sequence_ setAttrAndRenders
  setSignalAttrAndRender

  let toSelector :: (Gtk.TreeViewColumn, CC.MVar [DefaultGlibString]) -> IO Selector
      toSelector (column, checkedMVar) = do
        graphInfoMVar <- CC.newMVar (Nothing, [])
        colNum <- getColumnNumber treeview column
        let updateGettersAndTitle' = updateGettersAndTitle graphInfoMVar treeStore colNum
        return $
          Selector
          { sRebuildSignalTree = rebuildSignalTree treeStore updateGettersAndTitle' treeview
          , sToPlotValues = toValues graphInfoMVar
          , sCheckedTreePaths = Just checkedMVar
          }

  selectors <- mapM toSelector $ zip columns checkedTreePathsMVar

  return $
    SignalSelector
    { ssTreeView = treeview
    , ssTreeStore = treeStore
    , ssSelectors = selectors
    }

newSignalSelectorArea :: [Element] -> IO ()
                      -> Maybe (CC.MVar [DefaultGlibString], Gtk.TreeStore ListViewInfo)
                      -> IO (SignalSelector Selector)
newSignalSelectorArea elems redraw mCheckedTreePathsMVar = do
  -- mvar with all the user input
  graphInfoMVar <- CC.newMVar (Nothing, [])
  treeStore <- Gtk.treeStoreNew $ initialForest elems 2
  treeview <- Gtk.treeViewNewWithModel treeStore

  Gtk.treeViewSetHeadersVisible treeview True

  -- add some columns
  -- the signal column
  (setSignalAttrAndRender, _) <- signalColumn treeStore treeview "signal"

  -- the selection column
  colVisible <- Gtk.treeViewColumnNew

  Gtk.treeViewColumnSetTitle colVisible "visible?"
  rendererVisible <- Gtk.cellRendererToggleNew
  Gtk.treeViewColumnPackStart colVisible rendererVisible True
  appendColumn treeview colVisible

  -- Now, we can set the attributes and render since the order of the columns is set.
  colVisibleNumber <- getColumnNumber treeview colVisible
  let updateGettersAndTitle' = updateGettersAndTitle graphInfoMVar treeStore colVisibleNumber
  Gtk.cellLayoutSetAttributes colVisible rendererVisible treeStore $ \lvi -> (markedAttribute colVisibleNumber lvi)

  setSignalAttrAndRender

  _ <- on rendererVisible Gtk.cellToggled $ \pathStr -> renderPlotSignal colVisibleNumber treeStore pathStr redraw updateGettersAndTitle'

  -- now it's all built, so we can prefill some checkboxes
  let rebuildSignalTree' = rebuildSignalTree treeStore updateGettersAndTitle' treeview
  case mCheckedTreePathsMVar of
    Nothing -> return ()
    Just (checkedTreePathsMVar, _) -> do
      checkedTreePaths <- CC.readMVar checkedTreePathsMVar
      putStrLn $ show checkedTreePaths
      updateGettersAndTitle'
      let render' pathstr = renderPlotSignal colVisibleNumber treeStore pathstr redraw updateGettersAndTitle'
      -- rebuild the signal tree!
      mapM_ (\(Element e) -> stageDataFromElement' rebuildSignalTree' e) elems
      mapM_ (turnMarkOnTreePath treeStore colVisibleNumber render') checkedTreePaths

  return
    SignalSelector
    { ssTreeView = treeview
    , ssTreeStore = treeStore
    , ssSelectors =
      Selector
      { sRebuildSignalTree = rebuildSignalTree'
      , sToPlotValues = toValues graphInfoMVar
      , sCheckedTreePaths = Nothing
      }
    }

signalColumn :: forall a . Gtk.TreeViewClass a => Gtk.TreeStore ListViewInfo -> a -> String
             -> IO (IO (), Gtk.TreeViewColumn)
signalColumn treeStore treeview columnName = do
  colSignal <- Gtk.treeViewColumnNew
  Gtk.treeViewColumnSetTitle colSignal columnName
  rendererSignal <- Gtk.cellRendererTextNew
  Gtk.treeViewColumnPackStart colSignal rendererSignal True
  appendColumn treeview colSignal
  let setAttributeAndRender :: IO ()
      setAttributeAndRender =
        Gtk.cellLayoutSetAttributes colSignal rendererSignal treeStore $
          \ListViewInfo {lviName = name, lviTypeOrGetter = typeOrGetter} ->
            [ Gtk.cellText := showName typeOrGetter (reverse name)
            ]
  return (setAttributeAndRender, colSignal)


checkMarkColumn :: forall a . Gtk.TreeViewClass a => Gtk.TreeStore ListViewInfo -> a -> String
                -> IO (IO (), Gtk.TreeViewColumn, CC.MVar [DefaultGlibString])
checkMarkColumn treeStore treeview columnName = do
  colCheckMark <- Gtk.treeViewColumnNew
  checkedTreePathsMVar <- CC.newMVar []
  Gtk.treeViewColumnSetTitle colCheckMark columnName
  rendererCheckMark <- Gtk.cellRendererToggleNew
  Gtk.treeViewColumnPackStart colCheckMark rendererCheckMark True
  appendColumn treeview colCheckMark
  let setAttributeAndRender :: IO ()
      setAttributeAndRender = do
        colNum <- getColumnNumber treeview colCheckMark
        Gtk.cellLayoutSetAttributes colCheckMark rendererCheckMark treeStore $ \lvi -> (markedAttribute colNum lvi)
        _ <- on rendererCheckMark Gtk.cellToggled $ \pathStr -> toggleCheckMarkAndTreePath treeStore colNum pathStr checkedTreePathsMVar
        return ()
    -- update which y axes are CheckMark
  return (setAttributeAndRender, colCheckMark, checkedTreePathsMVar)

appendColumn :: forall a . Gtk.TreeViewClass a => a -> Gtk.TreeViewColumn -> IO ()
appendColumn treeview col = do
  void $ Gtk.treeViewAppendColumn treeview col
  --TODO(rebecca): append proper number of columns to lvi? maybe

turnMarkOnTreePath :: Gtk.TreeStore ListViewInfo -> Int -> (DefaultGlibString -> IO ()) -> DefaultGlibString -> IO ()
turnMarkOnTreePath _ _ render' pathStr = render' pathStr


stageDataFromElement' :: forall a . (Element' a -> SignalTree a -> IO ()) -> Element' a -> IO ()
stageDataFromElement' rebuildSignalTree' element = do
  let msgStore = eMsgStore element
  -- get the latest data, just block if they're not available
  mdatalog <- CC.takeMVar msgStore
  case mdatalog of
    -- no data yet, do nothing
    Nothing -> CC.putMVar msgStore mdatalog
    Just (datalog, msignalTree) -> do
      case msignalTree of
        -- No new signal tree, no action necessary
        Nothing -> return ()
        -- If there is a new signal tree, we have to merge it with the old one.
        Just newSignalTree -> rebuildSignalTree' element newSignalTree

      -- write the data to the IORef so that the getters get the right stuff
      writeIORef (ePlotValueRef element) datalog

      -- Put the data back. Put Nothing to signify that the signal tree is up to date.
      CC.putMVar msgStore (Just (datalog, msignalTree))

getColumnNumber :: forall a . Gtk.TreeViewClass a => a -> Gtk.TreeViewColumn -> IO Int
getColumnNumber treeview col = do
  cols <- Gtk.treeViewGetColumns treeview
  let mColNum = elemIndex col cols
  case mColNum of
    Just n -> return n
    Nothing -> error "can't find column number"

setMark ::  Int -> [MarkedState] -> MarkedState -> [MarkedState]
setMark colNum oldStates mark = take colNum oldStates ++ [mark] ++ drop (colNum + 1) oldStates

getMark :: Int -> [MarkedState] -> Maybe MarkedState
getMark colNum oldStates | colNum < length oldStates = Just $ oldStates !! colNum
                         | otherwise = Nothing

markedAttribute :: Int -> ListViewInfo -> [AttrOp Gtk.CellRendererToggle]
markedAttribute colNum lvi = case (getMark colNum (lviMarked lvi)) of
  Just On           -> [ Gtk.cellToggleInconsistent := False
                  , Gtk.cellToggleActive := True
                  ]
  Just Off          -> [ Gtk.cellToggleInconsistent := False
                  , Gtk.cellToggleActive := False
                  ]
  Just Inconsistent -> [ Gtk.cellToggleActive := False
                  , Gtk.cellToggleInconsistent := True
                  ]
  Nothing -> trace "marked attribute getmark couldn't find mark" $ []


toggleCheckMark :: Gtk.TreeStore ListViewInfo -> Int -> DefaultGlibString -> IO ()
toggleCheckMark treeStore colNum pathStr = do
  let treePath = Gtk.stringToTreePath pathStr

      (_, changeSelfAndChildren) = getChildrenFuns treeStore

  val <- Gtk.treeStoreGetValue treeStore treePath
  let mmark = getMark colNum (lviMarked val)
      changeMark lvi newMark = lvi { lviMarked = setMark colNum (lviMarked lvi) newMark }
  case mmark of
    Nothing -> putStrLn "couldn't find mark"
    Just mark ->
      case (val, mark) of
        (ListViewInfo {lviTypeOrGetter = Left _ }, Off) ->
          changeSelfAndChildren (\lvi -> changeMark lvi On) treePath
        (ListViewInfo {lviTypeOrGetter = Left _ } ,On) ->
          changeSelfAndChildren (\lvi -> changeMark lvi Off) treePath
        (ListViewInfo {lviTypeOrGetter = Left _ }, Inconsistent) ->
          changeSelfAndChildren (\lvi -> changeMark lvi On) treePath
        (lvi@(ListViewInfo {lviTypeOrGetter = Right _}), On) ->
          Gtk.treeStoreSetValue treeStore treePath $ changeMark lvi Off
        (lvi@(ListViewInfo {lviTypeOrGetter = Right _}), Off) ->
          Gtk.treeStoreSetValue treeStore treePath $ changeMark lvi On
        (ListViewInfo {lviTypeOrGetter = Right _}, Inconsistent) ->
          error "cell getter can't be inconsistent"

toggleCheckMarkAndTreePath :: Gtk.TreeStore ListViewInfo -> Int -> DefaultGlibString -> CC.MVar [DefaultGlibString] -> IO ()
toggleCheckMarkAndTreePath treeStore colNum pathStr checkedTreePathsMVar = do
  toggleCheckMark treeStore colNum pathStr
  -- check if pathStr is in mvar. If not, add. If it is, remove.
  CC.modifyMVar_ checkedTreePathsMVar $ \paths -> case (elem pathStr) paths of
      True -> return $ delete pathStr paths
      False -> return (pathStr:paths)



renderPlotSignal :: Int -> Gtk.TreeStore ListViewInfo -> DefaultGlibString -> IO () -> IO () -> IO ()
renderPlotSignal colNum treeStore pathStr redraw updateGettersAndTitle' = do
  let i2p i = Gtk.treeModelGetPath treeStore i
      p2i p = do
        mi <- Gtk.treeModelGetIter treeStore p
        case mi of Nothing -> error "no iter at that path"
                   Just i -> return i

      treePath = Gtk.stringToTreePath pathStr
      (getChildrenPaths, _) = getChildrenFuns treeStore

      fixInconsistent path' = do
        mparentIter <- p2i path' >>= Gtk.treeModelIterParent treeStore
        case mparentIter of
          Nothing -> return ()
          Just parentIter -> do
            parentPath <- i2p parentIter
            siblingPaths <- getChildrenPaths parentPath
            siblings <- mapM (Gtk.treeStoreGetValue treeStore) siblingPaths
            parentLvi <- Gtk.treeStoreGetValue treeStore parentPath
            let changeParentMark = setMark colNum (lviMarked parentLvi)
                markedSiblings :: [MarkedState]
                markedSiblings = trace "getmark in render plot" (catMaybes ( map ((getMark colNum) . lviMarked) siblings))

                changeParent
                  | all (== On) markedSiblings =
                      Gtk.treeStoreChange treeStore parentPath (\lvi -> lvi {lviMarked = changeParentMark On})
                  | all (== Off) markedSiblings =
                      Gtk.treeStoreChange treeStore parentPath (\lvi -> lvi {lviMarked = changeParentMark Off})
                  | otherwise =
                      Gtk.treeStoreChange treeStore parentPath (\lvi -> lvi {lviMarked = changeParentMark Inconsistent})
            ret <- changeParent
            when (not ret) $ error "fixInconsistent couldn't change parent"
            fixInconsistent parentPath
            return ()
   -- toggle the check mark
  toggleCheckMark treeStore colNum pathStr
  fixInconsistent treePath
  updateGettersAndTitle'
  redraw

getChildrenFuns ::  Gtk.TreeStore ListViewInfo -> (Gtk.TreePath
                -> IO [Gtk.TreePath], (ListViewInfo -> ListViewInfo) -> Gtk.TreePath -> IO ())
getChildrenFuns treeStore = (getChildrenPaths, changeSelfAndChildren)
  where
    i2p i = Gtk.treeModelGetPath treeStore i
    p2i p = do
      mi <- Gtk.treeModelGetIter treeStore p
      case mi of Nothing -> error "no iter at that path"
                 Just i -> return i

    getChildrenPaths path' = do
      iter' <- p2i path'
      let getChildPath k = do
            mc <- Gtk.treeModelIterNthChild treeStore (Just iter') k
            case mc of
              Nothing -> error "no child"
              Just c -> i2p c
      n <- Gtk.treeModelIterNChildren treeStore (Just iter')
      mapM getChildPath (take n [0..])

    changeSelfAndChildren change path' = do
      childrenPaths <- getChildrenPaths path'
      ret <- Gtk.treeStoreChange treeStore path' change
      when (not ret) $ error "treeStoreChange fail"
      mapM_ (changeSelfAndChildren change) childrenPaths

-- traverse the whole graph and update the list of getters and the title
updateGettersAndTitle :: CC.MVar (Maybe String, [(String, IO [[(Double, Double)]])])
                      -> Gtk.TreeStore ListViewInfo -> Int -> IO ()
updateGettersAndTitle graphInfoMVar treeStore colNum = do
  -- first get all trees
  let getTrees k = do
        tree' <- Gtk.treeStoreLookup treeStore [k]
        case tree' of Nothing -> return []
                      Just tree -> fmap (tree:) (getTrees (k+1))
  theTrees <- getTrees 0
  let newGetters0 :: [([String], IO [[(Double, Double)]])]
      newGetters0 = zip names (gots <$> goodLvis)
        where
          goodLvis = [x | x <- (concatMap Tree.flatten theTrees),isGoodLvi x]
          isGoodLvi lvi = mark == On && rights lvi
            where
              mark = case (getMark colNum (lviMarked lvi)) of
                Just m -> m
                Nothing -> trace "updating getters getmark couldn't find" Off

              rights ListViewInfo { lviTypeOrGetter = t } = case t of
                Right _ -> True
                Left _ -> False
          names = lviName <$> goodLvis
          gots ListViewInfo{ lviTypeOrGetter = Right getter, lviPlotValueRef = plotValRef} = getter <$> readIORef plotValRef
          gots ListViewInfo{ lviTypeOrGetter = Left _, lviPlotValueRef = _} = error "error parsing getters"
            {-where
              getter ListViewInfo { lviTypeOrGetter = t } = case t of
                Right g -> g
                Left _ -> error "update getters and title left not filtered"
              plotValRef ListViewInfo { lviPlotValueRef = p } = p-}

  let newGetters :: [(String, IO [[(Double, Double)]])]
      newTitle :: Maybe String
      (newGetters, newTitle) = gettersAndTitle newGetters0

  void $ newTitle `seq` newGetters `seq`
    CC.swapMVar graphInfoMVar (newTitle, newGetters)

rebuildSignalTree :: forall a t . Gtk.TreeViewClass t
                  => Gtk.TreeStore ListViewInfo -> IO () -> t
                  -> Element' a -> SignalTree a
                  -> IO ()
rebuildSignalTree treeStore updateGettersAndTitle' treeview element meta = do
  let channel = eChannel element
      elementIndex = eIndex element
  putStrLn $ "rebuilding signal tree for " ++ show (chanName channel)

  mtreeIter <- Gtk.treeModelIterNthChild treeStore Nothing elementIndex

  treePath <- case mtreeIter of
    Nothing -> error $ "rebuildSignalTree: error looking up channel index " ++ show elementIndex
    Just treeIter -> i2p treeIter
      where
        i2p i = Gtk.treeModelGetPath treeStore i

  unless (treePath == [elementIndex]) $ error "rebuildSignalTree: I don't understand tree paths"

  moldTree <- Gtk.treeStoreLookup treeStore treePath
  oldTree <- case moldTree of
    Nothing -> error "rebuildSignalTree: the old tree wasn't found"
    Just r -> return r

  columns <- Gtk.treeViewGetColumns treeview
  let _ = oldTree :: Tree ListViewInfo

      plotValueRef :: IORef a
      plotValueRef = ePlotValueRef element

      merge :: [Tree ListViewInfo]
               -> [Tree ([String], Either String (a -> [[(Double, Double)]]))]
               -> [Tree ListViewInfo]
      merge old new = map convert new
        where
          oldMap :: M.Map ([String], Maybe String) (ListViewInfo, [Tree ListViewInfo])
          oldMap = M.fromList $ map f old
            where
              f (Tree.Node lvi lvis) = ((lviName lvi, maybeType), (lvi, lvis))
                where
                  maybeType = case lvi of
                    ListViewInfo {lviTypeOrGetter = Left typ} -> Just typ
                    _ -> Nothing

          convert :: Tree ([String], Either String (a -> [[(Double, Double)]]))
                     -> Tree ListViewInfo
          convert (Tree.Node (name, tog) others) = case M.lookup (name, maybeType) oldMap of
            Nothing ->
              Tree.Node (ListViewInfo name tog (take (length columns) (repeat Off)) plotValueRef) (merge [] others)
            Just (lvi, oldOthers) ->
              Tree.Node (ListViewInfo name tog (lviMarked lvi) plotValueRef) (merge oldOthers others)
            where
              maybeType = case tog of
                Left r -> Just r
                Right _ -> Nothing

      newTree :: Tree ListViewInfo
      newTree = case merge [oldTree] [meta] of
        [r] -> r
        [] -> error "rebuildSignalTree: merged old tree with new tree and got []"
        _ -> error "rebuildSignalTree: merged old tree with new tree and got a forest"

  removed <- Gtk.treeStoreRemove treeStore treePath
  unless removed $ error "rebuildSignalTree: error removing old tree"
  Gtk.treeStoreInsertTree treeStore [] elementIndex newTree
  updateGettersAndTitle'

toValues :: CC.MVar (Maybe String, [(String, IO [[(Double, Double)]])])
         -> IO (Maybe String, [(String, [[(Double, Double)]])])
toValues graphInfoMVar = do
  (mtitle, getters) <- CC.readMVar graphInfoMVar
  let _ = getters :: [(String, IO [[(Double, Double)]])]

      execGetter :: (String, IO [[(Double, Double)]]) -> IO (String, [[(Double, Double)]])
      execGetter (name, get) = do
        got <- get
        return (name, got)
  gotten <- mapM execGetter getters
  return (mtitle, gotten)

-- The greatest common prefix will be the title.
-- Everything after that is the field name.
gettersAndTitle :: forall a . [([String], a)] -> ([(String, a)], Maybe String)
gettersAndTitle fullGetters =
  ( map (\(x,y) -> (intercalate "." x, y)) gettersWithPrefixRemoved
  , mtitle
  )
  where
    mtitle :: Maybe String
    mtitle = case titleNames of
      [] -> Nothing
      ts -> Just $ intercalate "." (reverse ts)

    titleNames :: [String]
    gettersWithPrefixRemoved :: [([String], a)]
    (titleNames, gettersWithPrefixRemoved) = splitPartialCommonPrefix $ splitCommonPrefixes [] fullGetters

splitCommonPrefixes :: forall a . [String] -> [([String], a)] -> ([String], [([String], a)])
splitCommonPrefixes titles getters0
  | any isNothing mheads = (titles, getters0)
  | otherwise = case heads of
      [] -> (titles, getters0)
      (prefix, _):others
        -- if all prefixes match, do another recursion
        | all ((prefix ==) . fst) others -> splitCommonPrefixes (prefix:titles) (map snd heads)
        -- otherwise we're done
        | otherwise -> (titles, getters0)
  where
    mheads :: [Maybe (String, ([String], a))]
    mheads = map mhead getters0

    heads :: [(String, ([String], a))]
    heads = map fromJust mheads

    -- split out the first element if there is one
    mhead :: ([String], a) -> Maybe (String, ([String], a))
    mhead (x:xs, y) = Just (x, (xs, y))
    mhead ([], _) = Nothing


-- We've already split out all the common whole strings.
-- Now we want to get any partial strings.
splitPartialCommonPrefix :: ([String], [([String], a)]) -> ([String], [([String], a)])
splitPartialCommonPrefix (wholePrefixes, getters)
  -- if there is no common prefix, do nothing
  | null prefix = (wholePrefixes, getters)
  -- If there is a common prefix, add it to the wholePrefixes and remove it from the next names.
  | otherwise = (prefix:wholePrefixes, map (\(x,y) -> (removePrefix x, y)) getters)
  where
    removePrefix :: [String] -> [String]
    removePrefix [] = [] -- No names, I guess don't return anything. I think this is impossible
    removePrefix (x:xs) = case drop (length prefix) x of
      -- If the common prefix is a whole variable name, i guess we shouldn't remove it.
      [] -> x:xs
      -- Normal path
      r -> r:xs

    prefix :: String
    prefix
      | any null names = []
      | otherwise = case map head names of
          -- only do it if there are at least two
          first:others@(_:_) -> foldl' commonPrefix first others
          _ -> []
      where
        names :: [[String]]
        names = map fst getters

    commonPrefix (x:xs) (y:ys)
      | x == y = x : commonPrefix xs ys
    commonPrefix _ _ = []



initialForest :: [Element] -> Int -> [Tree ListViewInfo]
initialForest elems numCols = map (\(Element e) -> toNode e)  elems
  where
    toNode :: Element' a -> Tree ListViewInfo
    toNode element =
      Tree.Node
      { Tree.rootLabel =
          ListViewInfo
          { lviName = [chanName (eChannel element)]
          , lviMarked = take numCols $ repeat Off
          , lviTypeOrGetter = Left ""
          , lviPlotValueRef = ePlotValueRef element
          }
      , Tree.subForest = []
      }

showName :: Either String b -> [String] -> String
-- show a getter name
showName (Right _) (name:_) = name
showName (Right _) [] = error "showName on field got an empty list"
-- show a parent without type info
showName (Left "") (name:_) = name
-- show a parent with type info
showName (Left typeName) (name:_) = name ++ " (" ++ typeName ++ ")"
showName (Left _) [] = error "showName on parent got an empty list"