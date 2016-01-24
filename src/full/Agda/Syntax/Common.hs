{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveFoldable             #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

{-| Some common syntactic entities are defined in this module.
-}
module Agda.Syntax.Common where

import Control.Applicative

import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as ByteString
import Data.Foldable
import Data.Hashable
import Data.Monoid
import Data.Traversable
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Test.QuickCheck hiding (Small)

import Agda.Syntax.Position

import Agda.Utils.Functor
import Agda.Utils.Pretty

#include "undefined.h"
import Agda.Utils.Impossible

---------------------------------------------------------------------------
-- * Delayed
---------------------------------------------------------------------------

-- | Used to specify whether something should be delayed.
data Delayed = Delayed | NotDelayed
  deriving (Typeable, Show, Eq, Ord)

instance KillRange Delayed where
  killRange = id

---------------------------------------------------------------------------
-- * Induction
---------------------------------------------------------------------------

data Induction = Inductive | CoInductive
  deriving (Typeable, Eq, Ord)

instance Show Induction where
  show Inductive   = "inductive"
  show CoInductive = "coinductive"

instance HasRange Induction where
  getRange _ = noRange

instance KillRange Induction where
  killRange = id

instance Arbitrary Induction where
  arbitrary = elements [Inductive, CoInductive]

instance CoArbitrary Induction where
  coarbitrary Inductive   = variant 0
  coarbitrary CoInductive = variant 1

---------------------------------------------------------------------------
-- * Hiding
---------------------------------------------------------------------------

data Hiding  = Hidden | Instance | NotHidden
  deriving (Typeable, Show, Eq, Ord)

-- | 'Hiding' is an idempotent partial monoid, with unit 'NotHidden'.
--   'Instance' and 'NotHidden' are incompatible.
instance Monoid Hiding where
  mempty = NotHidden
  mappend NotHidden h         = h
  mappend h         NotHidden = h
  mappend Hidden    Hidden    = Hidden
  mappend Instance  Instance  = Instance
  mappend _         _         = __IMPOSSIBLE__

instance KillRange Hiding where
  killRange = id

-- | Decorating something with 'Hiding' information.
data WithHiding a = WithHiding Hiding a
  deriving (Typeable, Eq, Ord, Show, Functor, Foldable, Traversable)

instance Decoration WithHiding where
  traverseF f (WithHiding h a) = WithHiding h <$> f a

instance Applicative WithHiding where
  pure = WithHiding mempty
  WithHiding h f <*> WithHiding h' a = WithHiding (mappend h h') (f a)

instance HasRange a => HasRange (WithHiding a) where
  getRange = getRange . dget

instance SetRange a => SetRange (WithHiding a) where
  setRange = fmap . setRange

instance KillRange a => KillRange (WithHiding a) where
  killRange = fmap killRange

-- | A lens to access the 'Hiding' attribute in data structures.
--   Minimal implementation: @getHiding@ and one of @setHiding@ or @mapHiding@.
class LensHiding a where

  getHiding :: a -> Hiding

  setHiding :: Hiding -> a -> a
  setHiding h = mapHiding (const h)

  mapHiding :: (Hiding -> Hiding) -> a -> a
  mapHiding f a = setHiding (f $ getHiding a) a

instance LensHiding Hiding where
  getHiding = id
  setHiding = const
  mapHiding = id

instance LensHiding (WithHiding a) where
  getHiding   (WithHiding h _) = h
  setHiding h (WithHiding _ a) = WithHiding h a
  mapHiding f (WithHiding h a) = WithHiding (f h) a

-- | Monoidal composition of 'Hiding' information in some data.
mergeHiding :: LensHiding a => WithHiding a -> a
mergeHiding (WithHiding h a) = mapHiding (mappend h) a

-- | @isHidden@ does not apply to 'Instance', only to 'Hidden'.
isHidden :: LensHiding a => a -> Bool
isHidden a = getHiding a == Hidden

-- | Visible ('NotHidden') arguments are @notHidden@. (DEPRECATED, use 'visible'.)
notHidden :: LensHiding a => a -> Bool
notHidden a = getHiding a == NotHidden

-- | 'NotHidden' arguments are @visible@.
visible :: LensHiding a => a -> Bool
visible a = getHiding a == NotHidden

-- | 'Instance' and 'Hidden' arguments are @notVisible@.
notVisible :: LensHiding a => a -> Bool
notVisible a = getHiding a /= NotHidden

hide :: LensHiding a => a -> a
hide = setHiding Hidden

makeInstance :: LensHiding a => a -> a
makeInstance = setHiding Instance

---------------------------------------------------------------------------
-- * Relevance
---------------------------------------------------------------------------

-- | An constructor argument is big if the sort of its type is bigger than
--   the sort of the data type.  Only parameters (and maybe forced arguments)
--   are allowed to be big.
--   @
--      List : Set -> Set
--      nil  : (A : Set) -> List A
--   @
--   @A@ is big in constructor @nil@ as the sort @Set1@ of its type @Set@
--   is bigger than the sort @Set@ of the data type @List@.
data Big = Big | Small
  deriving (Typeable, Show, Eq, Enum, Bounded)

instance Ord Big where
  Big <= Small = False
  _   <= _     = True

-- | A function argument can be relevant or irrelevant.
--   See "Agda.TypeChecking.Irrelevance".
data Relevance
  = Relevant    -- ^ The argument is (possibly) relevant at compile-time.
  | NonStrict   -- ^ The argument may never flow into evaluation position.
                --   Therefore, it is irrelevant at run-time.
                --   It is treated relevantly during equality checking.
  | Irrelevant  -- ^ The argument is irrelevant at compile- and runtime.
  | Forced Big  -- ^ The argument can be skipped during equality checking
                --   because its value is already determined by the type.
                --   If a constructor argument is big, it has to be regarded
                --   absent, otherwise we get into paradoxes.
  | UnusedArg   -- ^ The polarity checker has determined that this argument
                --   is unused in the definition.  It can be skipped during
                --   equality checking but should be mined for solutions
                --   of meta-variables with relevance 'UnusedArg'
    deriving (Typeable, Show, Eq)

allRelevances :: [Relevance]
allRelevances =
  [ Relevant
  , NonStrict
  , Irrelevant
  , Forced Small
  , Forced Big
  , UnusedArg
  ]

instance KillRange Relevance where
  killRange rel = rel -- no range to kill

instance Arbitrary Relevance where
  arbitrary = elements allRelevances

instance Ord Relevance where
  (<=) = moreRelevant

-- | A lens to access the 'Relevance' attribute in data structures.
--   Minimal implementation: @getRelevance@ and one of @setRelevance@ or @mapRelevance@.
class LensRelevance a where

  getRelevance :: a -> Relevance

  setRelevance :: Relevance -> a -> a
  setRelevance h = mapRelevance (const h)

  mapRelevance :: (Relevance -> Relevance) -> a -> a
  mapRelevance f a = setRelevance (f $ getRelevance a) a

instance LensRelevance Relevance where
  getRelevance = id
  setRelevance = const
  mapRelevance = id

isRelevant :: LensRelevance a => a -> Bool
isRelevant a = getRelevance a == Relevant

isIrrelevant :: LensRelevance a => a -> Bool
isIrrelevant a = getRelevance a == Irrelevant

-- | Information ordering.
-- @Relevant  \`moreRelevant\`
--  UnusedArg \`moreRelevant\`
--  Forced    \`moreRelevant\`
--  NonStrict \`moreRelevant\`
--  Irrelevant@
moreRelevant :: Relevance -> Relevance -> Bool
moreRelevant r r' =
  case (r, r') of
    -- top
    (_, Irrelevant) -> True
    (Irrelevant, _) -> False
    -- bottom
    (Relevant, _)   -> True
    (_, Relevant)   -> False
    -- second bottom
    (UnusedArg, _)  -> True
    (_, UnusedArg)  -> False
    -- third bottom
    (Forced{}, _)   -> True
    (_, Forced{})   -> False
    -- remaining case
    (NonStrict,NonStrict) -> True

irrelevantOrUnused :: Relevance -> Bool
irrelevantOrUnused r =
  case r of
    Irrelevant -> True
    UnusedArg  -> True
    NonStrict  -> False
    Relevant   -> False
    Forced{}   -> False

-- | @unusableRelevance rel == True@ iff we cannot use a variable of @rel@.
unusableRelevance :: Relevance -> Bool
unusableRelevance rel = NonStrict `moreRelevant` rel

-- | 'Relevance' composition.
--   'Irrelevant' is dominant, 'Relevant' is neutral.
composeRelevance :: Relevance -> Relevance -> Relevance
composeRelevance r r' =
  case (r, r') of
    (Irrelevant, _) -> Irrelevant
    (_, Irrelevant) -> Irrelevant
    (NonStrict, _)  -> NonStrict
    (_, NonStrict)  -> NonStrict
    (Forced b, Forced b') -> Forced (max b b')  -- prefer Big over Small
    (Forced b, _)     -> Forced b
    (_, Forced b)     -> Forced b
    (UnusedArg, _)  -> UnusedArg
    (_, UnusedArg)  -> UnusedArg
    (Relevant, Relevant) -> Relevant

-- | @inverseComposeRelevance r x@ returns the most irrelevant @y@
--   such that forall @x@, @y@ we have
--   @x \`moreRelevant\` (r \`composeRelevance\` y)@
--   iff
--   @(r \`inverseComposeRelevance\` x) \`moreRelevant\` y@ (Galois connection).
inverseComposeRelevance :: Relevance -> Relevance -> Relevance
inverseComposeRelevance r x =
  case (r, x) of
    (Relevant, x)        -> x          -- going to relevant arg.: nothing changes
    _ | r == x           -> Relevant   -- because Relevant is comp.-neutral
    (Forced{}, Forced{}) -> Relevant   -- same, but (==) does not ignore Big
    (UnusedArg, x)       -> x
    (Forced{}, UnusedArg)  -> Relevant
    (Forced{}, x)          -> x
    (Irrelevant, x)      -> Relevant   -- going irrelevant: every thing usable
    (_, Irrelevant)      -> Irrelevant -- otherwise: irrelevant things remain unusable
    (NonStrict, _)       -> Relevant   -- but @NonStrict@s become usable

-- | For comparing @Relevance@ ignoring @Forced@ and @UnusedArg@.
ignoreForced :: Relevance -> Relevance
ignoreForced Forced{}   = Relevant
ignoreForced UnusedArg  = Relevant
ignoreForced Relevant   = Relevant
ignoreForced NonStrict  = NonStrict
ignoreForced Irrelevant = Irrelevant

-- | Irrelevant function arguments may appear non-strictly in the codomain type.
irrToNonStrict :: Relevance -> Relevance
irrToNonStrict Irrelevant = NonStrict
-- irrToNonStrict NonStrict  = Relevant -- TODO: is that what we want (OR: NonStrict)  -- better be more conservative
irrToNonStrict rel        = rel

nonStrictToIrr :: Relevance -> Relevance
nonStrictToIrr NonStrict = Irrelevant
nonStrictToIrr rel       = rel

---------------------------------------------------------------------------
-- * Argument decoration
---------------------------------------------------------------------------

-- | A function argument can be hidden and/or irrelevant.

data ArgInfo c = ArgInfo
  { argInfoHiding    :: Hiding
  , argInfoRelevance :: Relevance
  , argInfoColors    :: [c]
  } deriving (Typeable, Eq, Ord, Functor, Foldable, Traversable, Show)

instance KillRange c => KillRange (ArgInfo c) where
  killRange (ArgInfo h r cs) = killRange3 ArgInfo h r cs

{- FAILED to define a lens for ArgInfo, since it is parametrized by c

   can't instantiate the following to f c = Arg c e
   since Haskell does not have lambda abstraction

class LensArgInfo f where
  getArgInfo :: f c -> ArgInfo c
  setArgInfo :: ArgInfo c' -> f c -> f c'
  setArgInfo ai = mapArgInfo (const ai)
  mapArgInfo :: (ArgInfo c -> ArgInfo c') -> f c -> f c'
  mapArgInfo f a = setArgInfo (f $ getArgInfo a) a

instance LensArgInfo ArgInfo where
  getArgInfo = id
  setArgInfo = const
  mapArgInfo = id
-}
{- FAILS because map is too restricted
class LensArgInfo c a where
  getArgInfo :: a -> ArgInfo c
  setArgInfo :: ArgInfo c -> a -> a
  setArgInfo ai = mapArgInfo (const ai)
  mapArgInfo :: (ArgInfo c -> ArgInfo c) -> a -> a
  mapArgInfo f a = setArgInfo (f $ getArgInfo a) a

instance LensArgInfo c (ArgInfo c) where
  getArgInfo = id
  setArgInfo = const
  mapArgInfo = id
-}

instance LensHiding (ArgInfo c) where
  getHiding = argInfoHiding
  setHiding h ai = ai { argInfoHiding = h }
  mapHiding f ai = ai { argInfoHiding = f (argInfoHiding ai) }

instance LensRelevance (ArgInfo c) where
  getRelevance = argInfoRelevance
  setRelevance h ai = ai { argInfoRelevance = h }
  mapRelevance f ai = ai { argInfoRelevance = f (argInfoRelevance ai) }

mapArgInfoColors :: ([c] -> [c']) -> ArgInfo c -> ArgInfo c'
mapArgInfoColors f info = info { argInfoColors = f $ argInfoColors info }

defaultArgInfo :: ArgInfo c
defaultArgInfo =  ArgInfo { argInfoHiding    = NotHidden
                          , argInfoRelevance = Relevant
                          , argInfoColors    = [] }

---------------------------------------------------------------------------
-- * Arguments
---------------------------------------------------------------------------

data Arg c e  = Arg
  { argInfo :: ArgInfo c
  , unArg :: e
  } deriving (Typeable, Ord, Functor, Foldable, Traversable)

instance Decoration (Arg c) where
  traverseF f (Arg ai a) = Arg ai <$> f a

instance HasRange a => HasRange (Arg c a) where
    getRange = getRange . unArg

instance SetRange a => SetRange (Arg c a) where
  setRange r = fmap $ setRange r

instance (KillRange c, KillRange a) => KillRange (Arg c a) where
  killRange (Arg info a) = killRange2 Arg info a

instance (Eq a, Eq c) => Eq (Arg c a) where
  Arg (ArgInfo h1 _ cs1) x1 == Arg (ArgInfo h2 _ cs2) x2 = (h1, cs1, x1) == (h2, cs2, x2)

instance (Show a, Show c) => Show (Arg c a) where
    show (Arg (ArgInfo h r cs) x) = showC cs $ showR r $ showH h $ show x
      where
        showH Hidden     s = "{" ++ s ++ "}"
        showH NotHidden  s = "(" ++ s ++ ")"
        showH Instance   s = "{{" ++ s ++ "}}"
        showR r s = case r of
          Irrelevant   -> "." ++ s
          NonStrict    -> "?" ++ s
          Forced Big   -> "!b" ++ s
          Forced Small -> "!" ++ s
          UnusedArg    -> "k" ++ s -- constant
          Relevant     -> "r" ++ s -- Andreas: I want to see it explicitly
        showC cs         s = show cs ++ s

instance LensHiding (Arg c e) where
  getHiding = getHiding . argInfo
  mapHiding = mapArgInfo . mapHiding

instance LensRelevance (Arg c e) where
  getRelevance = getRelevance . argInfo
  mapRelevance = mapArgInfo . mapRelevance

{- RETIRED
hide :: Arg c a -> Arg c a
hide = setArgHiding Hidden

makeInstance :: Arg c a -> Arg c a
makeInstance = setHiding Instance

isHiddenArg :: Arg c a -> Bool
isHiddenArg arg = argHiding arg /= NotHidden
-}

mapArgInfo :: (ArgInfo c -> ArgInfo c') -> Arg c a -> Arg c' a
mapArgInfo f arg = arg { argInfo = f $ argInfo arg }

argColors :: Arg c a -> [c]
argColors = argInfoColors . argInfo

mapArgColors :: ([c] -> [c']) -> Arg c a -> Arg c' a
mapArgColors = mapArgInfo . mapArgInfoColors

setArgColors :: [c] -> Arg c' a -> Arg c a
setArgColors = mapArgColors . const

defaultArg :: a -> Arg c a
defaultArg = Arg defaultArgInfo

defaultColoredArg :: ([c],a) -> Arg c a
defaultColoredArg (cs,a) = setArgColors cs $ defaultArg a

noColorArg :: Hiding -> Relevance -> a -> Arg c a
noColorArg h r = Arg ArgInfo { argInfoHiding    = h
                             , argInfoRelevance = r
                             , argInfoColors    = []
                             }

-- | @xs \`withArgsFrom\` args@ translates @xs@ into a list of 'Arg's,
-- using the elements in @args@ to fill in the non-'unArg' fields.
--
-- Precondition: The two lists should have equal length.

withArgsFrom :: [a] -> [Arg c b] -> [Arg c a]
xs `withArgsFrom` args =
  zipWith (\x arg -> fmap (const x) arg) xs args

withNamedArgsFrom :: [a] -> [NamedArg c b] -> [NamedArg c a]
xs `withNamedArgsFrom` args =
  zipWith (\x -> fmap (x <$)) xs args

---------------------------------------------------------------------------
-- * Names
---------------------------------------------------------------------------

class Eq a => Underscore a where
  underscore   :: a
  isUnderscore :: a -> Bool
  isUnderscore = (== underscore)

instance Underscore String where
  underscore = "_"

instance Underscore ByteString where
  underscore = ByteString.pack underscore

instance Underscore Doc where
  underscore = text underscore

---------------------------------------------------------------------------
-- * Function type domain
---------------------------------------------------------------------------

-- | Similar to 'Arg', but we need to distinguish
--   an irrelevance annotation in a function domain
--   (the domain itself is not irrelevant!)
--   from an irrelevant argument.
--
--   @Dom@ is used in 'Pi' of internal syntax, in 'Context' and 'Telescope'.
--   'Arg' is used for actual arguments ('Var', 'Con', 'Def' etc.)
--   and in 'Abstract' syntax and other situations.
data Dom c e = Dom
  { domInfo   :: ArgInfo c
  , unDom     :: e
  } deriving (Typeable, Eq, Ord, Functor, Foldable, Traversable)

instance Decoration (Dom c) where
  traverseF f (Dom ai a) = Dom ai <$> f a

instance HasRange a => HasRange (Dom c a) where
  getRange = getRange . unDom

instance (KillRange c, KillRange a) => KillRange (Dom c a) where
  killRange (Dom info a) = killRange2 Dom info a

instance (Show a, Show c) => Show (Dom c a) where
  show = show . argFromDom

instance LensHiding (Dom c e) where
  getHiding = getHiding . domInfo
  mapHiding = mapDomInfo . mapHiding

instance LensRelevance (Dom c e) where
  getRelevance = getRelevance . domInfo
  mapRelevance = mapDomInfo . mapRelevance

mapDomInfo :: (ArgInfo c -> ArgInfo c') -> Dom c a -> Dom c' a
mapDomInfo f arg = arg { domInfo = f $ domInfo arg }

domColors :: Dom c a -> [c]
domColors = argInfoColors . domInfo

argFromDom :: Dom c a -> Arg c a
argFromDom (Dom i a) = Arg i a

domFromArg :: Arg c a -> Dom c a
domFromArg (Arg i a) = Dom i a

defaultDom :: a -> Dom c a
defaultDom = Dom defaultArgInfo

---------------------------------------------------------------------------
-- * Named arguments
---------------------------------------------------------------------------

-- | Something potentially carrying a name.
data Named name a =
    Named { nameOf     :: Maybe name
          , namedThing :: a
          }
    deriving (Eq, Ord, Typeable, Functor, Foldable, Traversable)

-- | Standard naming.
type Named_ = Named RString

unnamed :: a -> Named name a
unnamed = Named Nothing

named :: name -> a -> Named name a
named = Named . Just

instance Decoration (Named name) where
  traverseF f (Named n a) = Named n <$> f a

instance HasRange a => HasRange (Named name a) where
    getRange = getRange . namedThing

instance SetRange a => SetRange (Named name a) where
  setRange r = fmap $ setRange r

instance (KillRange name, KillRange a) => KillRange (Named name a) where
  killRange (Named n a) = Named (killRange n) (killRange a)

instance Show a => Show (Named_ a) where
    show (Named Nothing x)  = show x
    show (Named (Just n) x) = rawNameToString (rangedThing n) ++ " = " ++ show x

-- | Only 'Hidden' arguments can have names.
type NamedArg c a = Arg c (Named_ a)

-- | Get the content of a 'NamedArg'.
namedArg :: NamedArg c a -> a
namedArg = namedThing . unArg

defaultNamedArg :: a -> NamedArg c a
defaultNamedArg = defaultArg . unnamed

-- | The functor instance for 'NamedArg' would be ambiguous,
--   so we give it another name here.
updateNamedArg :: (a -> b) -> NamedArg c a -> NamedArg c b
updateNamedArg = fmap . fmap

---------------------------------------------------------------------------
-- * Range decoration.
---------------------------------------------------------------------------

-- | Thing with range info.
data Ranged a = Ranged
  { rangeOf     :: Range
  , rangedThing :: a
  }
  deriving (Typeable, Functor, Foldable, Traversable)

-- | Thing with no range info.
unranged :: a -> Ranged a
unranged = Ranged noRange

instance Show a => Show (Ranged a) where
  show = show . rangedThing

instance Eq a => Eq (Ranged a) where
  Ranged _ x == Ranged _ y = x == y

instance Ord a => Ord (Ranged a) where
  compare (Ranged _ x) (Ranged _ y) = compare x y

instance HasRange (Ranged a) where
  getRange = rangeOf

instance KillRange (Ranged a) where
  killRange (Ranged _ x) = Ranged noRange x

instance Decoration Ranged where
  traverseF f (Ranged r x) = Ranged r <$> f x

---------------------------------------------------------------------------
-- * Raw names (before parsing into name parts).
---------------------------------------------------------------------------

-- | A @RawName@ is some sort of string.
type RawName = String

rawNameToString :: RawName -> String
rawNameToString = id

stringToRawName :: String -> RawName
stringToRawName = id

-- | String with range info.
type RString = Ranged RawName

---------------------------------------------------------------------------
-- * Constructor pattern info
---------------------------------------------------------------------------

-- | Where does the 'ConP' of come from?
data ConPOrigin
  = ConPImplicit  -- ^ Expanded from an implicit pattern.
  | ConPCon       -- ^ User wrote a constructor pattern.
  | ConPRec       -- ^ User wrote a record pattern.
  deriving (Typeable, Show, Eq, Ord, Enum, Bounded)

---------------------------------------------------------------------------
-- * Infixity, access, abstract, etc.
---------------------------------------------------------------------------

-- | Functions can be defined in both infix and prefix style. See
--   'Agda.Syntax.Concrete.LHS'.
data IsInfix = InfixDef | PrefixDef
    deriving (Typeable, Show, Eq, Ord)

-- | Access modifier.
data Access = PrivateAccess | PublicAccess
            | OnlyQualified  -- ^ Visible from outside, but not exported when opening the module
                             --   Used for qualified constructors.
    deriving (Typeable, Show, Eq, Ord)

-- | Abstract or concrete
data IsAbstract = AbstractDef | ConcreteDef
    deriving (Typeable, Show, Eq, Ord)

instance KillRange IsAbstract where
  killRange = id

-- | Is this definition eligible for instance search?
data IsInstance = InstanceDef | NotInstanceDef
    deriving (Typeable, Show, Eq, Ord)

type Nat    = Int
type Arity  = Nat

---------------------------------------------------------------------------
-- * NameId
---------------------------------------------------------------------------

-- | The unique identifier of a name. Second argument is the top-level module
--   identifier.
data NameId = NameId Integer Integer
    deriving (Eq, Ord, Typeable, Generic)

instance KillRange NameId where
  killRange = id

instance Show NameId where
  show (NameId x i) = show x ++ "@" ++ show i

instance Enum NameId where
  succ (NameId n m)     = NameId (n + 1) m
  pred (NameId n m)     = NameId (n - 1) m
  toEnum n              = __IMPOSSIBLE__  -- should not be used
  fromEnum (NameId n _) = fromIntegral n

instance Hashable NameId where
  {-# INLINE hashWithSalt #-}
  hashWithSalt salt (NameId n m) = hashWithSalt salt (n, m)

instance Arbitrary NameId where
  arbitrary = elements [ NameId x y | x <- [-1, 1], y <- [-1, 1] ]

instance CoArbitrary NameId

---------------------------------------------------------------------------
-- * Meta variables
---------------------------------------------------------------------------

-- | A meta variable identifier is just a natural number.
--
newtype MetaId = MetaId { metaId :: Nat }
    deriving (Eq, Ord, Num, Real, Enum, Integral, Typeable)

instance Pretty MetaId where
  pretty (MetaId n) = text $ "_" ++ show n

-- | Show non-record version of this newtype.
instance Show MetaId where
  showsPrec p (MetaId n) = showParen (p > 0) $
    showString "MetaId " . shows n

newtype Constr a = Constr a

---------------------------------------------------------------------------
-- * Interaction meta variables
---------------------------------------------------------------------------

newtype InteractionId = InteractionId { interactionId :: Nat }
    deriving (Eq,Ord,Num,Integral,Real,Enum)

instance Show InteractionId where
    show (InteractionId x) = "?" ++ show x

instance KillRange InteractionId where killRange = id

-----------------------------------------------------------------------------
-- * Import directive
-----------------------------------------------------------------------------

-- | The things you are allowed to say when you shuffle names between name
--   spaces (i.e. in @import@, @namespace@, or @open@ declarations).
data ImportDirective' a b = ImportDirective
  { importDirRange :: !Range
  , usingOrHiding  :: UsingOrHiding' a b
  , impRenaming    :: [Renaming' a b]
  , publicOpen     :: Bool -- ^ Only for @open@. Exports the opened names from the current module.
  }
  deriving (Typeable)

-- | Default is directive is @private@ (use everything, but do not export).
defaultImportDir :: ImportDirective' a b
defaultImportDir = ImportDirective noRange (Hiding []) [] False

data UsingOrHiding' a b
  = Hiding [ImportedName' a b]
  | Using  [ImportedName' a b]
  deriving (Typeable)

-- | An imported name can be a module or a defined name
data ImportedName' a b
  = ImportedModule  b
  | ImportedName    a
  deriving (Typeable, Eq, Ord)

setImportedName :: ImportedName' a a -> a -> ImportedName' a a
setImportedName (ImportedName   x) y = ImportedName   y
setImportedName (ImportedModule x) y = ImportedModule y

instance (Show a, Show b) => Show (ImportedName' a b) where
  show (ImportedModule x) = "module " ++ show x
  show (ImportedName   x) = show x

data Renaming' a b = Renaming
  { renFrom    :: ImportedName' a b
    -- ^ Rename from this name.
  , renTo      :: ImportedName' a b
    -- ^ To this one.  Must be same kind as 'renFrom'.
  , renToRange :: Range
    -- ^ The range of the \"to\" keyword.  Retained for highlighting purposes.
  }
  deriving (Typeable)

-- ** HasRange instances

instance (HasRange a, HasRange b) => HasRange (ImportDirective' a b) where
  getRange = importDirRange

instance (HasRange a, HasRange b) => HasRange (UsingOrHiding' a b) where
  getRange (Using  xs) = getRange xs
  getRange (Hiding xs) = getRange xs

instance (HasRange a, HasRange b) => HasRange (Renaming' a b) where
  getRange r = getRange (renFrom r, renTo r)

instance (HasRange a, HasRange b) => HasRange (ImportedName' a b) where
  getRange (ImportedName   x) = getRange x
  getRange (ImportedModule x) = getRange x

-- ** KillRange instances

instance (KillRange a, KillRange b) => KillRange (ImportDirective' a b) where
  killRange (ImportDirective _ u r p) =
    killRange2 (\u r -> ImportDirective noRange u r p) u r

instance (KillRange a, KillRange b) => KillRange (UsingOrHiding' a b) where
  killRange (Hiding i) = killRange1 Hiding i
  killRange (Using  i) = killRange1 Using  i

instance (KillRange a, KillRange b) => KillRange (Renaming' a b) where
  killRange (Renaming i n _) = killRange2 (\i n -> Renaming i n noRange) i n

instance (KillRange a, KillRange b) => KillRange (ImportedName' a b) where
  killRange (ImportedModule n) = killRange1 ImportedModule n
  killRange (ImportedName   n) = killRange1 ImportedName   n

-----------------------------------------------------------------------------
-- * Termination
-----------------------------------------------------------------------------

-- | Termination check? (Default = TerminationCheck).
data TerminationCheck m
  = TerminationCheck
    -- ^ Run the termination checker.
  | NoTerminationCheck
    -- ^ Skip termination checking (unsafe).
  | NonTerminating
    -- ^ Treat as non-terminating.
  | Terminating
    -- ^ Treat as terminating (unsafe).  Same effect as 'NoTerminationCheck'.
  | TerminationMeasure !Range m
    -- ^ Skip termination checking but use measure instead.
    deriving (Typeable, Show, Eq, Functor)

instance KillRange m => KillRange (TerminationCheck m) where
  killRange (TerminationMeasure _ m) = TerminationMeasure noRange (killRange m)
  killRange t                        = t

-----------------------------------------------------------------------------
-- * Positivity
-----------------------------------------------------------------------------

-- | Positivity check? (Default = True).
type PositivityCheck = Bool
