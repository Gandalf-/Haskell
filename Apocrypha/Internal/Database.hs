{-# LANGUAGE OverloadedStrings #-}

{-|
    Module      : Apocrypha.Internal.Database
    Description : Core database logic
    License     : MIT
    copyright   : 2018, Austin
    Maintainer  : austin@anardil.net
    Stability   : experimental
    Portability : POSIX
-}

module Apocrypha.Internal.Database where

import           Codec.Compression.Zlib   (compress, decompress)
import           Control.Exception        (SomeException, evaluate, try)
import           Data.Aeson
import qualified Data.Aeson.Encode.Pretty as P
import qualified Data.ByteString.Lazy     as BL
import qualified Data.HashMap.Strict      as HM
import           Data.Maybe               (fromMaybe)
import           Data.Text                (Text)
import qualified Data.Text                as T
import           Data.Text.Encoding       (decodeUtf8)
import qualified Data.Vector              as V
import           System.Directory         (doesFileExist, getHomeDirectory,
                                           renameFile)
import           System.FilePath.Posix    ((</>))


type Query = [Text]

data Action = Action
        { _value   :: !Value
        , _changed :: !Bool
        , _result  :: ![Text]
        , _top     :: !Object
        , _context :: !Context
        }
    deriving (Show, Eq)

data Context = Context
        { _enabled :: !Bool
        , _members :: ![Text]
        }
    deriving (Show, Eq)


-- | Presentation
showValue :: Value -> Text
showValue = decodeUtf8 . BL.toStrict . encoder
    where
        encoder = P.encodePretty' config
        config = P.Config (P.Spaces 4) P.compare P.Generic False


pretty :: Context -> Value -> [Text]
pretty _ Null = []
pretty c (Array v) =
        [T.intercalate "\n" . concatMap (pretty c) . V.toList $ v]

pretty _ v@(Object o)
        | HM.null o = []
        | otherwise = [showValue v]

pretty (Context True m) (String s) = addContext m s
pretty (Context _ _)    (String s) = [s]

pretty (Context True m) v = addContext m $ showValue v
pretty (Context _ _)    v = [showValue v]


addContext :: [Text] -> Text -> [Text]
-- ^ create the context explanation for a value
-- context is a list of keys that we had to traverse to get to the value
addContext context value =
        [T.intercalate " = " $ safeInit context ++ [value]]
    where
        safeInit [] = []
        safeInit xs = init xs


baseAction :: Value -> Action
baseAction db =
    case db of
        (Object o) -> Action db False [] o (Context False [])
        _          -> error "database top level is not a map"


-- | IO utilities
dbError :: Value -> Text -> Action
-- ^ create an error out of this level to pass back up, do not modify the
-- value, do not report changes
dbError v msg =
        Action v False ["error: " <> msg] HM.empty (Context False [])


getDB :: FilePath -> IO Value
-- ^ attempt to read the database
-- if it doesn't exist, create an empty db and read that
-- if it's compressed, decompress, otherwise read it plain
getDB path = do
        exists <- doesFileExist path
        if exists
          then fromMaybe Null . decode <$> safeRead
          else saveDB path emptyDB >> getDB path
    where
        emptyDB :: Value
        emptyDB = Object $ HM.fromList []

        compressRead :: BL.ByteString -> IO (Either SomeException BL.ByteString)
        compressRead b = try (evaluate $ decompress b)

        safeRead :: IO BL.ByteString
        safeRead = do
            content <- BL.readFile path
            result <- compressRead content

            case result of
                Left _  -> pure content
                Right v -> pure v


saveDB :: FilePath -> Value -> IO ()
-- ^ atomic write + move into place
saveDB path v = do
        BL.writeFile tmpFile $ prepare v
        renameFile tmpFile path
    where
        prepare :: Value -> BL.ByteString
        prepare = compress . encode
        tmpFile = path <> ".tmp"


defaultDB :: IO String
defaultDB = (</> ".db.json") <$> getHomeDirectory