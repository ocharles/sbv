-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.BitVectors.GenTest
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- Test generation from symbolic programs
-----------------------------------------------------------------------------

module Data.SBV.BitVectors.GenTest (genTest, TestVectors, getTestValues, renderTest, TestStyle(..)) where

import Data.Bits     (testBit)
import Data.Maybe    (fromMaybe)
import Data.List     (intercalate, groupBy)
import System.Random

import Data.SBV.BitVectors.Data
import Data.SBV.BitVectors.PrettyNum

-- | Type of test vectors (abstract)
newtype TestVectors = TV [([CW], [CW])]

-- | Retrieve the test vectors for further processing. This function
-- is useful in cases where 'renderTest' is not sufficient and custom
-- output (or further preprocessing) is needed.
getTestValues :: TestVectors -> [([CW], [CW])]
getTestValues (TV vs) = vs

-- | Generate a set of concrete test values from a symbolic program. The output
-- can be rendered as test vectors in different languages as necessary. Use the
-- function 'output' call to indicate what fields should be in the test result.
-- (Also see 'constrain' and 'pConstrain' for filtering acceptable test values.)
genTest :: Outputtable a => Int -> Symbolic a -> IO TestVectors
genTest n m = gen 0 []
  where gen i sofar
         | i == n = return $ TV $ reverse sofar
         | True   = do g <- newStdGen
                       t <- tc g
                       gen (i+1) (t:sofar)
        tc g = do (_, Result _ tvals _ _ cs _ _ _ _ _ cstrs os) <- runSymbolic' (Concrete g) (m >>= output)
                  let cval = fromMaybe (error "Cannot generate tests in the presence of uninterpeted constants!") . (`lookup` cs)
                      cond = all (cwToBool . cval) cstrs
                  if cond
                     then return (map snd tvals, map cval os)
                     else tc g  -- try again, with the same set of constraints

-- | Test output style
data TestStyle = Haskell String                     -- ^ As a Haskell value with given name
               | C       String                     -- ^ As a C array of structs with given name
               | Forte   String Bool ([Int], [Int]) -- ^ As a Forte/Verilog value with given name.
                                                    -- If the boolean is True then vectors are blasted big-endian, otherwise little-endian
                                                    -- The indices are the split points on bit-vectors for input and output values

-- | Render the test as a Haskell value with the given name @n@.
renderTest :: TestStyle -> TestVectors -> String
renderTest (Haskell n)    (TV vs) = haskell n vs
renderTest (C n)          (TV vs) = c       n vs
renderTest (Forte n b ss) (TV vs) = forte   n b ss vs

haskell :: String -> [([CW], [CW])] -> String
haskell n vs = intercalate "\n" [ "-- Automatically generated by SBV. Do not edit!"
                                   , n ++ " :: " ++ getType vs
                                   , n ++ " = [ " ++ intercalate ("\n" ++ pad ++  ", ") (map mkLine vs), pad ++ "]"
                                   ]
  where pad = replicate (length n + 3) ' '
        getType []         = "[a]"
        getType ((i, o):_) = "[(" ++ mapType typeOf i ++ ", " ++ mapType typeOf o ++ ")]"
        mkLine  (i, o)     = "("  ++ mapType valOf  i ++ ", " ++ mapType valOf  o ++ ")"
        mapType f cws = mkTuple $ map f $ groupBy (\c1 c2 -> (cwSigned c1, cwSize c1) == (cwSigned c2, cwSize c2)) cws
        mkTuple [x] = x
        mkTuple xs  = "(" ++ intercalate ", " xs ++ ")"
        typeOf []    = "()"
        typeOf [x]   = t x
        typeOf (x:_) = "[" ++ t x ++ "]"
        valOf  []    = "()"
        valOf  [x]   = s x
        valOf  xs    = "[" ++ intercalate ", " (map s xs) ++ "]"
        t cw = case (cwSigned cw, cwSize cw) of
                  (False, Size (Just  1)) -> "Bool"
                  (False, Size (Just  8)) -> "Word8"
                  (False, Size (Just 16)) -> "Word16"
                  (False, Size (Just 32)) -> "Word32"
                  (False, Size (Just 64)) -> "Word64"
                  (True,  Size (Just  8)) -> "Int8"
                  (True,  Size (Just 16)) -> "Int16"
                  (True,  Size (Just 32)) -> "Int32"
                  (True,  Size (Just 64)) -> "Int64"
                  (True,  Size Nothing)   -> "Integer"
                  _                       -> error $ "SBV.renderTest: Unexpected CW: " ++ show cw
        s cw = case (cwSigned cw, cwSize cw) of
                  (False, Size (Just 1)) -> show (cwToBool cw)
                  (sgn, Size (Just sz))  -> shex  False True (sgn, sz) (cwVal cw)
                  (_,   Size Nothing)    -> shexI False True           (cwVal cw)

c :: String -> [([CW], [CW])] -> String
c n vs = intercalate "\n" $
              [ "/* Automatically generated by SBV. Do not edit! */"
              , ""
              , "#include <stdio.h>"
              , "#include <inttypes.h>"
              , "#include <stdint.h>"
              , "#include <stdbool.h>"
              , ""
              , "/* The boolean type */"
              , "typedef bool SBool;"
              , ""
              , "/* Unsigned bit-vectors */"
              , "typedef uint8_t  SWord8 ;"
              , "typedef uint16_t SWord16;"
              , "typedef uint32_t SWord32;"
              , "typedef uint64_t SWord64;"
              , ""
              , "/* Signed bit-vectors */"
              , "typedef int8_t  SInt8 ;"
              , "typedef int16_t SInt16;"
              , "typedef int32_t SInt32;"
              , "typedef int64_t SInt64;"
              , ""
              , "typedef struct {"
              , "  struct {"
              ]
           ++ (if null vs then [] else zipWith (mkField "i") (fst (head vs)) [(0::Int)..])
           ++ [ "  } input;"
              , "  struct {"
              ]
           ++ (if null vs then [] else zipWith (mkField "o") (snd (head vs)) [(0::Int)..])
           ++ [ "  } output;"
              , "} " ++ n ++ "TestVector;"
              , ""
              , n ++ "TestVector " ++ n ++ "[] = {"
              ]
           ++ ["      " ++ intercalate "\n    , " (map mkLine vs)]
           ++ [ "};"
              , ""
              , "int " ++ n ++ "Length = " ++ show (length vs) ++ ";"
              , ""
              , "/* Stub driver showing the test values, replace with code that uses the test vectors. */"
              , "int main(void)"
              , "{"
              , "  int i;"
              , "  for(i = 0; i < " ++ n ++ "Length; ++i)"
              , "  {"
              , "    " ++ outLine
              , "  }"
              , ""
              , "  return 0;"
              , "}"
              ]
  where mkField p cw i = "    " ++ t ++ " " ++ p ++ show i ++ ";"
            where t = case (cwSigned cw, cwSize cw) of
                        (False, Size (Just  1)) -> "SBool"
                        (False, Size (Just  8)) -> "SWord8"
                        (False, Size (Just 16)) -> "SWord16"
                        (False, Size (Just 32)) -> "SWord32"
                        (False, Size (Just 64)) -> "SWord64"
                        (True,  Size (Just  8)) -> "SInt8"
                        (True,  Size (Just 16)) -> "SInt16"
                        (True,  Size (Just 32)) -> "SInt32"
                        (True,  Size (Just 64)) -> "SInt64"
                        (True,  Size Nothing)   -> error "SBV.rendertest: Unbounded integers are not supported when generating C test-cases."
                        _                       -> error $ "SBV.renderTest: Unexpected CW: " ++ show cw
        mkLine (is, os) = "{{" ++ intercalate ", " (map v is) ++ "}, {" ++ intercalate ", " (map v os) ++ "}}"
        v cw = case (cwSigned cw, cwSize cw) of
                  (False, Size (Just 1)) -> if cwToBool cw then "true " else "false"
                  (sgn, Size (Just sz))  -> shex  False True (sgn, sz) (cwVal cw)
                  (_,   Size Nothing)    -> shexI False True           (cwVal cw)
        outLine
          | null vs = "printf(\"\");"
          | True    = "printf(\"%*d. " ++ fmtString ++ "\\n\", " ++ show (length (show (length vs - 1))) ++ ", i"
                    ++ concatMap ("\n           , " ++ ) (zipWith inp is [(0::Int)..] ++ zipWith out os [(0::Int)..])
                    ++ ");"
          where (is, os) = head vs
                inp cw i = mkBool cw (n ++ "[i].input.i"  ++ show i)
                out cw i = mkBool cw (n ++ "[i].output.o" ++ show i)
                mkBool cw s = case (cwSigned cw, cwSize cw) of
                                (False, Size (Just 1)) -> "(" ++ s ++ " == true) ? \"true \" : \"false\""
                                _                      -> s
                fmtString = unwords (map fmt is) ++ " -> " ++ unwords (map fmt os)
        fmt cw = case (cwSigned cw, cwSize cw) of
                    (False, Size (Just  1)) -> "%s"
                    (False, Size (Just  8)) -> "0x%02\"PRIx8\""
                    (False, Size (Just 16)) -> "0x%04\"PRIx16\"U"
                    (False, Size (Just 32)) -> "0x%08\"PRIx32\"UL"
                    (False, Size (Just 64)) -> "0x%016\"PRIx64\"ULL"
                    (True,  Size (Just  8)) -> "%\"PRId8\""
                    (True,  Size (Just 16)) -> "%\"PRId16\""
                    (True,  Size (Just 32)) -> "%\"PRId32\"L"
                    (True,  Size (Just 64)) -> "%\"PRId64\"LL"
                    (True,  Size Nothing)   -> error "SBV.rendertest: Unsupported unbounded integers for C generation."
                    _                       -> error $ "SBV.renderTest: Unexpected CW: " ++ show cw

forte :: String -> Bool -> ([Int], [Int]) -> [([CW], [CW])] -> String
forte n bigEndian ss vs = intercalate "\n" $ [ "// Automatically generated by SBV. Do not edit!"
                                             , "let " ++ n ++ " ="
                                             , "   let c s = val [_, r] = str_split s \"'\" in " ++ blaster
                                             ]
                                          ++ [ "   in [ " ++ intercalate "\n      , " (map mkLine vs)
                                             , "      ];"
                                             ]
  where blaster
         | bigEndian = "map (\\s. s == \"1\") (explode (string_tl r))"
         | True      = "rev (map (\\s. s == \"1\") (explode (string_tl r)))"
        toF True  = '1'
        toF False = '0'
        blast cw = case (cwSigned cw, cwSize cw) of
                     (False, Size (Just  1)) -> [toF (cwToBool cw)]
                     (False, Size (Just  8)) -> xlt  8 (cwVal cw)
                     (False, Size (Just 16)) -> xlt 16 (cwVal cw)
                     (False, Size (Just 32)) -> xlt 32 (cwVal cw)
                     (False, Size (Just 64)) -> xlt 64 (cwVal cw)
                     (True,  Size (Just  8)) -> xlt  8 (cwVal cw)
                     (True,  Size (Just 16)) -> xlt 16 (cwVal cw)
                     (True,  Size (Just 32)) -> xlt 32 (cwVal cw)
                     (True,  Size (Just 64)) -> xlt 64 (cwVal cw)
                     (True,  Size Nothing)   -> error "SBV.rendertest: Unbounded integers are not supported when generating Forte test-cases."
                     _                       -> error $ "SBV.renderTest: Unexpected CW: " ++ show cw
        xlt s v = [toF (testBit v i) | i <- [s-1, s-2 .. 0]]
        mkLine  (i, o) = "("  ++ mkTuple (form (fst ss) (concatMap blast i)) ++ ", " ++ mkTuple (form (snd ss) (concatMap blast o)) ++ ")"
        mkTuple []  = "()"
        mkTuple [x] = x
        mkTuple xs  = "(" ++ intercalate ", " xs ++ ")"
        form []     [] = []
        form []     bs = error $ "SBV.renderTest: Mismatched index in stream, extra " ++ show (length bs) ++ " bit(s) remain."
        form (i:is) bs
          | length bs < i = error $ "SBV.renderTest: Mismatched index in stream, was looking for " ++ show i ++ " bit(s), but only " ++ show i ++ " remains."
          | i == 1        = let b:r = bs
                                v   = if b == '1' then "T" else "F"
                            in v : form is r
          | True          = let (f, r) = splitAt i bs
                                v      = "c \"" ++ show i ++ "'b" ++ f ++ "\""
                            in v : form is r
