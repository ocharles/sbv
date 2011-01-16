-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.Examples.BitPrecise.Legato
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- An encoding and correctness proof of Legato's multiplier in Haskell. Bill Legato came
-- up with an interesting way to multiply two 8-bit numbers on Mostek, as described here:
--   <http://www.cs.utexas.edu/~moore/acl2/workshop-2004/contrib/legato/Weakest-Preconditions-Report.pdf>
--
-- Here's Legato's algorithm, as coded in Mostek assembly:
--
-- @
--    step1 :       LDX #8         ; load X immediate with the integer 8 
--    step2 :       LDA #0         ; load A immediate with the integer 0 
--    step3 :       CLC            ; set C to 0
--    step4 : LOOP  ROR F1         ; rotate F1 right circular through C 
--    step5 :       BCC ZCOEF      ; branch to ZCOEF if C = 0 
--    step6 :       CLC            ; set C to 0 
--    step7 :       ADC F2         ; set A to A+F2+C and C to the carry 
--    step8 : ZCOEF ROR A          ; rotate A right circular through C 
--    step9 :       ROR LOW        ; rotate LOW right circular through C 
--    step10:       DEX            ; set X to X-1 
--    step11:       BNE LOOP       ; branch to LOOP if Z = 0 
-- @
--
-- NB. The CLC in step3 was later added by Warren Hunt; the
-- original spec did not include this statement. However, without this
-- addition, the algorithm does not work correctly for all starting states,
-- so we adopt this change as well.
--
-- This program came to be known as the Legato's challenge in the community, where
-- the challenge was to prove that it indeed does perform multiplication. This file
-- formalizes the Mostek architecture in Haskell and proves that Legato's algorithm
-- is indeed correct.
-----------------------------------------------------------------------------

module Data.SBV.Examples.BitPrecise.Legato where

import Data.Array
import Data.SBV

------------------------------------------------------------------
-- * Mostek architecture
------------------------------------------------------------------
-- | The memory is addressed by 32-bit words.
type Address  = SWord32

-- | We model only two registers of Mostek that is used in the above algorithm, can add more.
data Register = RegX  | RegA  deriving (Eq, Ord, Ix, Bounded, Enum)

-- | The carry flag ('FlagC') and the zero flag ('FlagZ')
data Flag = FlagC | FlagZ deriving (Eq, Ord, Ix, Bounded, Enum)

-- | Mostek was an 8-bit machine.
type Value = SWord8

-- | Convenient synonym for symbolic machine bits.
type Bit = SBool

-- | Register bank
type Registers = Array Register Value

-- | Flag bank
type Flags = Array Flag Bit

-- | The memory maps 32-bit words to 8-bit words. (The 'Model' data-type is
-- defined later, depending on the verification model used.)
type Memory = Model Word32 Word8        -- Model defined later

-- | Abstraction of the machine: The CPU consists of memory, registers, and flags.
-- Unlike traditional hardware, we assume the program is stored in some other memory area that
-- we need not model. (No self modifying programs!)
data Mostek = Mostek { memory    :: Memory
                     , registers :: Registers
                     , flags     :: Flags
                     }

-- | Given a machine state, compute a value out of it
type Extract a = Mostek -> a

-- | Programs are essentially state transformers (on the machine state)
type Program = Mostek -> Mostek

instance Mergeable Mostek where
  symbolicMerge b m1 m2 = Mostek { memory    = symbolicMerge b (memory m1)    (memory m2)
                                 , registers = symbolicMerge b (registers m1) (registers m2)
                                 , flags     = symbolicMerge b (flags m1)     (flags m2)
                                 }

------------------------------------------------------------------
-- * Low-level operations
------------------------------------------------------------------

-- | Get the value of a given register
getReg :: Register -> Extract Value
getReg r m = registers m ! r

-- | Set the value of a given register
setReg :: Register -> Value -> Program
setReg r v m = m {registers = registers m // [(r, v)]}

-- | Get the value of a flag
getFlag :: Flag -> Extract Bit
getFlag f m = flags m ! f

-- | Set the value of a flag
setFlag :: Flag -> Bit -> Program
setFlag f b m = m {flags = flags m // [(f, b)]}

-- | Read memory
peek :: Address -> Extract Value
peek a m = readArray (memory m) a

-- | Write to memory
poke :: Address -> Value -> Program
poke a v m = m {memory = writeArray (memory m) a v}

------------------------------------------------------------------
-- * Instruction set
------------------------------------------------------------------

-- | An instruction is modeled as a 'Program' transformer. We model
-- mostek programs in direct continuation passing style.
type Instruction = Program -> Program

-- | LDX: Set register @X@ to value @v@
ldx :: Value -> Instruction
ldx v k = k . setReg RegX v

-- | LDA: Set register @A@ to value @v@
lda :: Value -> Instruction
lda v k = k . setReg RegA v

-- | CLC: Clear the carry flag
clc :: Instruction
clc k = k . setFlag FlagC false

-- | ROR, memory version: Rotate the value at memory location @a@
-- to the right by 1 bit, using the carry flag as a transfer position.
-- That is, the final bit of the memory location becomes the new carry
-- and the carry moves over to the first bit. This very instruction
-- is one of the reasons why Legato's multiplier is quite hard to understand
-- and is typically presented as a verification challenge.
rorM :: Address -> Instruction
rorM a k m = k . setFlag FlagC c' . poke a v' $ m
  where v  = peek a m
        c  = getFlag FlagC m
        v' = setBitTo (v `rotateR` 1) 7 c
        c' = bitValue v 0

-- | ROR, register version: Same as 'rorM', except through register @r@.
rorR :: Register -> Instruction
rorR r k m = k . setFlag FlagC c' . setReg r v' $ m
  where v  = getReg r m
        c  = getFlag FlagC m
        v' = setBitTo (v `rotateR` 1) 7 c
        c' = bitValue v 0

-- | BCC: branch to label @l@ if the carry flag is false
bcc :: Program -> Instruction
bcc l k m = ite (c .== false) (l m) (k m)
  where c = getFlag FlagC m

-- | ADC: Increment the value of register @A@ by the value of memory contents
-- at address @a@, using the carry-bit as the carry-in for the addition.
adc :: Address -> Instruction
adc a k m = k . setFlag FlagZ (v' .== 0) . setFlag FlagC c' . setReg RegA v' $ m
  where v  = peek a m
        ra = getReg RegA m
        c  = getFlag FlagC m
        v' = v + ra + ite (c .== true) 1 0
        c' = bitValue v' 7 -- c is true if the sum overflowed

-- | DEX: Decrement the value of register @X@
dex :: Instruction
dex k m = k . setFlag FlagZ (x .== 0) . setReg RegX x $ m
  where x = getReg RegX m - 1

-- | BNE: Branch if the zero-flag is false
bne :: Program -> Instruction
bne l k m = ite (z .== false) (l m) (k m)
  where z = getFlag FlagZ m

-- | The 'end' combinator "stops" our program, providing the final continuation
-- that does nothing.
end :: Program
end = id

------------------------------------------------------------------
-- * Legato's algorithm in Haskell/SBV
------------------------------------------------------------------

-- | Parameterized by the addresses of locations of the factors (@F1@ and @F2@),
-- the following program multiplies them, storing the low-byte of the result
-- in the memory location @lowAddr@, and the high-byte in register @A@. The
-- implementation is a direct transliteration of Legato's algorithm given
-- at the top, using our notation.
legato :: Address -> Address -> Address -> Program
legato f1Addr f2Addr lowAddr = start
  where start   =    ldx 8
                   $ lda 0
                   $ clc
                   $ loop
        loop    =    rorM f1Addr
                   $ bcc zeroCoef
                   $ clc
                   $ adc f2Addr
                   $ zeroCoef
        zeroCoef =   rorR RegA
                   $ rorM lowAddr
                   $ dex
                   $ bne loop
                   $ end


------------------------------------------------------------------
-- * Verification interface
------------------------------------------------------------------
-- | Given address/value pairs for F1 and F2, and the location of where the low-byte
-- of the result should go, @runLegato@ takes an arbitrary machine state @m@ and
-- returns the high and low bytes of the multiplication.
runLegato :: (Address, Value) -> (Address, Value) -> Address -> Mostek -> (Value, Value)
runLegato (f1Addr, f1Val) (f2Addr, f2Val) loAddr m = (getReg RegA mFinal, peek loAddr mFinal)
  where m0     = poke f1Addr f1Val $ poke f2Addr f2Val m
        mFinal = legato f1Addr f2Addr loAddr m0

-- | Helper synonym for capturing relevant bits of Mostek
type InitVals = ( Value      -- Content of Register X
                , Value      -- Content of Register A
                , Value      -- Initial contents of memory
                , Bit        -- Value of FlagC
                , Bit        -- Value of FlagZ
                )

-- | Create an instance of the Mostek machine, initialized by the memory and the relevant
-- values of the registers and the flags
initMachine :: Memory -> InitVals -> Mostek
initMachine mem (rx, ra, mc, fc, fz) = Mostek { memory    = resetArray mem mc
                                              , registers = array (minBound, maxBound) [(RegX, rx),  (RegA, ra)]
                                              , flags     = array (minBound, maxBound) [(FlagC, fc), (FlagZ, fz)]
                                              }

-- | The correctness theorem. For all possible memory configurations, the factors (@x@ and @y@ below), the location
-- of the low-byte result and the initial-values of registers and the flags, this function will return True only if
-- running Legato's algorithm does indeed compute the product of @x@ and @y@ correctly.
legatoIsCorrect :: Memory -> (Address, Value) -> (Address, Value) -> Address -> InitVals -> SBool
legatoIsCorrect mem (addrX, x) (addrY, y) addrLow initVals
        = allDifferent [addrX, addrY, addrLow]    -- note the conditional: addresses must be distinct!
                ==> result .== expected
    where (hi, lo) = runLegato (addrX, x) (addrY, y) addrLow (initMachine mem initVals)
          result   = 256 * hi + lo
          expected = x * y

------------------------------------------------------------------
-- * Verification
------------------------------------------------------------------

-- | Choose the appropriate array model to be used for modeling the memory. (See 'Memory'.)
-- The 'SFunArray' is the function based model. 'SArray' is the SMT-Lib array's based model.
type Model = SFunArray
-- type Model = SArray

-- | The correctness theorem.
--   On a decent MacBook Pro, this proof takes about 30 seconds with 'SFunArray' memory model above
--   and about 30 minutes with the 'SArray' memory model
correctnessTheorem :: IO ThmResult
correctnessTheorem = proveWith timingSMTCfg $
    forAll ["mem", "addrX", "x", "addrY", "y", "addrLow", "regX", "regA", "memVals", "flagC", "flagZ"]
           legatoIsCorrect
