module Hydra.TUI.Drawing.Utils where

import Brick (Widget, emptyWidget, txt)
import qualified Data.Text as Text
import Hydra.Cardano.Api (SerialiseAsRawBytes, serialiseToRawBytesHexText)
import Hydra.Prelude

drawHex :: SerialiseAsRawBytes a => a -> Widget n
drawHex = txt . (" - " <>) . serialiseToRawBytesHexText

drawShow :: forall a n. Show a => a -> Widget n
drawShow = txt . (" - " <>) . show

maybeWidget :: (a -> Widget n) -> Maybe a -> Widget n
maybeWidget = maybe emptyWidget

ellipsize :: Int -> Text -> Text
ellipsize n t = Text.take (n - 2) t <> ".."
