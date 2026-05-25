module Skland.Json
  ( Json (..)
  , parseJson
  , lookupKey
  , lookupPath
  , asString
  , asInt
  , asArray
  , asObject
  , stringField
  , intField
  , compactObject
  , compactString
  )
where

import Data.Char (chr, digitToInt, isDigit, isSpace, ord)

data Json
  = JObject [(String, Json)]
  | JArray [Json]
  | JString String
  | JNumber String
  | JBool Bool
  | JNull
  deriving (Eq, Show)

parseJson :: String -> Either String Json
parseJson input =
  case parseValue (dropSpace input) of
    Right (value, rest) | all isSpace rest -> Right value
    Right (_, rest) -> Left ("JSON 后面有无法解析的内容: " <> take 80 rest)
    Left err -> Left err

lookupKey :: String -> Json -> Maybe Json
lookupKey key (JObject fields) = lookup key fields
lookupKey _ _ = Nothing

lookupPath :: [String] -> Json -> Maybe Json
lookupPath [] value = Just value
lookupPath (key : keys) value = lookupKey key value >>= lookupPath keys

asString :: Json -> Maybe String
asString (JString value) = Just value
asString (JNumber value) = Just value
asString _ = Nothing

asInt :: Json -> Maybe Int
asInt (JNumber value) =
  case reads value of
    [(n, "")] -> Just n
    _ -> Nothing
asInt (JString value) =
  case reads value of
    [(n, "")] -> Just n
    _ -> Nothing
asInt _ = Nothing

asArray :: Json -> Maybe [Json]
asArray (JArray values) = Just values
asArray _ = Nothing

asObject :: Json -> Maybe [(String, Json)]
asObject (JObject fields) = Just fields
asObject _ = Nothing

stringField :: String -> Json -> String
stringField key value = maybe "" id (lookupKey key value >>= asString)

intField :: String -> Json -> Int
intField key value = maybe 0 id (lookupKey key value >>= asInt)

compactObject :: [(String, String)] -> String
compactObject fields =
  "{" <> joinWith "," [compactString key <> ":" <> compactString value | (key, value) <- fields] <> "}"

compactString :: String -> String
compactString value = "\"" <> concatMap escape value <> "\""

parseValue :: String -> Either String (Json, String)
parseValue [] = Left "JSON 为空"
parseValue (c : rest)
  | isSpace c = parseValue (dropSpace rest)
parseValue ('{' : rest) = parseObject [] (dropSpace rest)
parseValue ('[' : rest) = parseArray [] (dropSpace rest)
parseValue ('"' : rest) = parseString [] rest
parseValue ('t' : 'r' : 'u' : 'e' : rest) = Right (JBool True, rest)
parseValue ('f' : 'a' : 'l' : 's' : 'e' : rest) = Right (JBool False, rest)
parseValue ('n' : 'u' : 'l' : 'l' : rest) = Right (JNull, rest)
parseValue input@(c : _)
  | c == '-' || isDigit c = parseNumber input
parseValue input = Left ("无法解析 JSON value: " <> take 80 input)

parseObject :: [(String, Json)] -> String -> Either String (Json, String)
parseObject fields ('}' : rest) = Right (JObject (reverse fields), rest)
parseObject fields input = do
  (key, afterKey) <- parseJsonString (dropSpace input)
  afterColon <- expect ':' (dropSpace afterKey)
  (value, afterValue) <- parseValue (dropSpace afterColon)
  case dropSpace afterValue of
    ',' : rest -> parseObject ((key, value) : fields) (dropSpace rest)
    '}' : rest -> Right (JObject (reverse ((key, value) : fields)), rest)
    rest -> Left ("JSON object 缺少逗号或右括号: " <> take 80 rest)

parseArray :: [Json] -> String -> Either String (Json, String)
parseArray values (']' : rest) = Right (JArray (reverse values), rest)
parseArray values input = do
  (value, afterValue) <- parseValue (dropSpace input)
  case dropSpace afterValue of
    ',' : rest -> parseArray (value : values) (dropSpace rest)
    ']' : rest -> Right (JArray (reverse (value : values)), rest)
    rest -> Left ("JSON array 缺少逗号或右括号: " <> take 80 rest)

parseString :: [Char] -> String -> Either String (Json, String)
parseString acc input = do
  (value, rest) <- parseStringChars acc input
  Right (JString value, rest)

parseJsonString :: String -> Either String (String, String)
parseJsonString ('"' : rest) = parseStringChars [] rest
parseJsonString input = Left ("JSON object key 不是字符串: " <> take 80 input)

parseStringChars :: [Char] -> String -> Either String (String, String)
parseStringChars _ [] = Left "JSON 字符串未闭合"
parseStringChars acc ('"' : rest) = Right (reverse acc, rest)
parseStringChars acc ('\\' : escaped : rest) =
  case escaped of
    '"' -> parseStringChars ('"' : acc) rest
    '\\' -> parseStringChars ('\\' : acc) rest
    '/' -> parseStringChars ('/' : acc) rest
    'b' -> parseStringChars ('\b' : acc) rest
    'f' -> parseStringChars ('\f' : acc) rest
    'n' -> parseStringChars ('\n' : acc) rest
    'r' -> parseStringChars ('\r' : acc) rest
    't' -> parseStringChars ('\t' : acc) rest
    'u' -> parseUnicode acc rest
    _ -> Left ("未知 JSON 转义: \\" <> [escaped])
parseStringChars acc (c : rest) = parseStringChars (c : acc) rest

parseUnicode :: [Char] -> String -> Either String (String, String)
parseUnicode acc input =
  let (hex, rest) = splitAt 4 input
   in if length hex == 4 && all isHex hex
        then parseStringChars (chr (foldl (\n c -> n * 16 + digitToInt c) 0 hex) : acc) rest
        else Left ("非法 unicode 转义: " <> take 8 input)

parseNumber :: String -> Either String (Json, String)
parseNumber input =
  let (number, rest) = span isNumberChar input
   in Right (JNumber number, rest)

isNumberChar :: Char -> Bool
isNumberChar c = isDigit c || c `elem` ("-+.eE" :: String)

isHex :: Char -> Bool
isHex c = isDigit c || c `elem` ("abcdefABCDEF" :: String)

expect :: Char -> String -> Either String String
expect expected (c : rest)
  | c == expected = Right rest
expect expected input = Left ("JSON 缺少 " <> [expected] <> ": " <> take 80 input)

dropSpace :: String -> String
dropSpace = dropWhile isSpace

escape :: Char -> String
escape '"' = "\\\""
escape '\\' = "\\\\"
escape '\n' = "\\n"
escape '\r' = "\\r"
escape '\t' = "\\t"
escape c
  | ord c < 32 = "\\u" <> pad4 (showHex (ord c))
  | otherwise = [c]

showHex :: Int -> String
showHex n =
  let digits = "0123456789abcdef"
      go x
        | x < 16 = [digits !! x]
        | otherwise = go (x `div` 16) <> [digits !! (x `mod` 16)]
   in go n

pad4 :: String -> String
pad4 value = replicate (4 - length value) '0' <> value

joinWith :: String -> [String] -> String
joinWith _ [] = ""
joinWith _ [x] = x
joinWith sep (x : xs) = x <> sep <> joinWith sep xs
