import N2O.Data.Bytes
import N2O.Data.Sum
import N2O.Data.Put
import N2O.Data.Parser

def Char.isAscii (c : Char) : Bool :=
c.val ≤ 127

def mapM {m : Type → Type} [Monad m] {α β : Type} (f : α → m β) : List α → m (List β)
| [] => pure []
| x :: xs => do
  ys ← mapM xs;
  y ← f x;
  pure (y :: ys)

abbrev Dict (α β : Type) := List (α × β)

inductive Term
| byte   : UInt8 → Term
-- there is now no Int32 in Lean
| int    : UInt32 → Term
--| float  : Float → Term
| atom   : String → Term
| tuple  : List Term → Term
| string : String → Term
| list   : List Term → Term
| binary : ByteArray → Term
| bigint : Int → Term
| dict   : List (Term × Term) → Term

partial def Term.toString : Term → String
| Term.byte x => toString x
| Term.int x => toString x
| Term.atom (String.mk []) => ""
| Term.atom s@(String.mk $ x :: xs) =>
  if x.isLower then s
  else "'" ++ s ++ "'"
| Term.tuple ts => "{" ++ String.intercalate ", " (List.map Term.toString ts) ++ "}"
| Term.string s => "\"" ++ s ++ "\""
| Term.list ts => "[" ++ String.intercalate ", " (List.map Term.toString ts) ++ "]"
| Term.binary s => "<<" ++ String.intercalate ", " (List.map toString s.toList) ++ ">>"
| Term.bigint x => toString x
| Term.dict x =>
  let printPair := λ (pair : Term × Term) =>
    "{" ++ Term.toString pair.1 ++ ", " ++ Term.toString pair.2 ++ "}";
  "[" ++ String.intercalate ", " (List.map printPair x) ++ "]"
instance : HasToString Term := ⟨Term.toString⟩

class BERT (α : Type) :=
(toTerm   : α → Term)
(fromTerm : Term → Sum String α)

instance Term.BERT : BERT Term :=
{ toTerm := id, fromTerm := Sum.inr }

instance Int.BERT : BERT UInt32 :=
{ toTerm := Term.int,
  fromTerm := λ t => match t with
    | Term.int val => Sum.inr val
    | _ => Sum.inl "invalid integer type" }

instance Integer.BERT : BERT Int :=
{ toTerm := Term.bigint,
  fromTerm := λ t => match t with
    | Term.bigint x => Sum.inr x
    | _ => Sum.inl "invalid integer type" }

instance String.BERT : BERT String :=
{ toTerm := Term.string,
  fromTerm := λ t => match t with
    | Term.string x => Sum.inr x
    | Term.atom x => Sum.inr x
    | _ => Sum.inl "invalid string type" }

instance List.BERT {α : Type} [BERT α] : BERT (List α) :=
{ toTerm := λ xs => Term.list (List.map BERT.toTerm xs),
  fromTerm := λ t => match t with
    | Term.list xs => mapM BERT.fromTerm xs
    | _ => Sum.inl "invalid list type" }

instance Dict.BERT {α β : Type} [BERT α] [BERT β] : BERT (Dict α β) :=
{ toTerm := λ xs => Term.dict (List.map (Prod.map BERT.toTerm BERT.toTerm) xs),
  fromTerm :=
    let termFromPair (pair : Term × Term) : Sum String (α × β) :=
    (do fst ← BERT.fromTerm pair.1;
        snd ← BERT.fromTerm pair.2;
        pure (fst, snd));
    λ t => match t with
    | Term.dict xs => mapM termFromPair xs
    | _ => Sum.inl "invalid dict type" }

instance Tuple.BERT {α β : Type} [BERT α] [BERT β] : BERT (α × β) :=
{ toTerm := λ x => Term.tuple [ BERT.toTerm x.1, BERT.toTerm x.2 ],
  fromTerm := λ t => match t with
    | Term.tuple [a, b] => do
      x ← BERT.fromTerm a;
      y ← BERT.fromTerm b;
      pure (x, y)
    | _ => Sum.inl "invalid tuple type" }

def word : ByteParser UInt16 := do
  res ← Parser.count Parser.byte 2;
  match res with
  | (a, b, _) =>
    let a' := UInt8.shiftl16 a (8 * 1);
    let b' := UInt8.shiftl16 b (8 * 0);
    pure (a' + b')

def dword : ByteParser UInt32 := do
  res ← Parser.count Parser.byte 4;
  match res with
  | (a, b, c, d, _) =>
    let a' := UInt8.shiftl32 a (8 * 3);
    let b' := UInt8.shiftl32 b (8 * 2);
    let c' := UInt8.shiftl32 c (8 * 1);
    let d' := UInt8.shiftl32 d (8 * 0);
    pure (a' + b' + c' + d')

-- decode
def readByte : ByteParser Term :=
do Parser.tok 97; val ← Parser.byte; pure (Term.byte val)

def readDword : ByteParser Term :=
do Parser.tok 98; res ← dword; pure (Term.int res)

def readASCIIString {α : Type} (p : ByteParser α)
  (toNat : α → Nat) (tok : UInt8) : ByteParser String := do
  Parser.tok tok; N ← p;
  chars ← Parser.count ByteParser.ch (toNat N);
  pure chars.toList.asString

def readAtom : ByteParser Term :=
Parser.decorateError "<atom>"
  (Term.atom <$> readASCIIString word UInt16.toNat 100)

def readSmallAtom : ByteParser Term :=
Parser.decorateError "<small atom>"
  (Term.atom <$> readASCIIString Parser.byte UInt8.toNat 115)

def readUTF8String {α : Type} (p : ByteParser α)
  (toNat : α → Nat) (tok : UInt8) : ByteParser String :=
do Parser.tok tok; N ← p; ByteParser.utf8.stringWithLength (toNat N)

def readUTF8Atom : ByteParser Term :=
Parser.decorateError "<UTF-8 atom>"
  (Term.atom <$> readUTF8String word UInt16.toNat 118)

def readUTF8SmallAtom : ByteParser Term :=
Parser.decorateError "<UTF-8 small atom>"
  (Term.atom <$> readUTF8String Parser.byte UInt8.toNat 119)

def readString : ByteParser Term :=
Parser.decorateError "<UTF-8 string>"
  (Term.string <$> readUTF8String word UInt16.toNat 107)

def readTuple (readTerm : ByteParser Term) : ByteParser Term := do
  Parser.tok 104; N ← Parser.byte;
  elems ← Parser.count readTerm N.toNat;
  pure (Term.tuple elems.toList)

def readLargeTuple (readTerm : ByteParser Term) : ByteParser Term := do
  Parser.tok 105; N ← dword;
  elems ← Parser.count readTerm N.toNat;
  pure (Term.tuple elems.toList)

def readNil : ByteParser Term := do Parser.tok 106; pure (Term.list [])
def readList (readTerm : ByteParser Term) : ByteParser Term := do
  Parser.tok 108; N ← dword;
  elems ← Parser.count readTerm N.toNat;
  _ ← optional readNil;
  pure (Term.list elems.toList)

def readBinary : ByteParser Term := do
  Parser.tok 109; N ← dword;
  elems ← Parser.count Parser.byte N.toNat;
  pure (Term.binary elems.toList.toByteArray)

def IsMinus : ByteParser Bool :=
(do Parser.tok 0; pure false) <|>
(do Parser.tok 1; pure true)

def readBignum' {α : Type}
  (p : ByteParser α) (toNat : α → Nat) (tok : UInt8) :
  ByteParser Term := do
  Parser.tok 110; n ← p;
  isMinus ← IsMinus; d ← Parser.count Parser.byte (toNat n);
  let x := Int.ofNat
    (List.foldl Nat.add 0 $
      List.map (λ (pair : Nat × UInt8) =>
                 pair.2.toNat * (256 ^ pair.1))
               d.toList.enum);
  pure (Term.bigint $ if isMinus then -x else x)

def readSmallBignum := readBignum' Parser.byte UInt8.toNat 110
def readLargeBignum := readBignum' dword UInt32.toNat 111

def readDict (readTerm : ByteParser Term) : ByteParser Term := do
  Parser.tok 116; L ← dword;
  pairs ← Parser.count (Prod.mk <$> readTerm <*> readTerm) L.toNat;
  pure (Term.dict pairs.toList)

def readTerm' (readTerm : ByteParser Term) : ByteParser Term :=
readByte <|> readDword <|> readAtom <|>
readUTF8SmallAtom <|> readUTF8Atom <|>
readTuple readTerm <|> readLargeTuple readTerm <|>
readList readTerm <|> readBinary <|> readSmallAtom <|>
readSmallBignum <|> readLargeBignum <|> readString <|>
readDict readTerm

def readTerm := do Parser.tok 131; Parser.fix readTerm'

-- encode
partial def Nat.toBytesAux : Nat → ByteArray → ByteArray | x, buff =>
if x > 256 then Nat.toBytesAux (x / 256) (buff.push (UInt8.ofNat $ x % 256))
else buff.push (UInt8.ofNat x)

def Nat.toBytes (x : Nat) : ByteArray :=
Nat.toBytesAux x ByteArray.empty

def writeBigint (x : Int) : Put :=
  let enc := Nat.toBytes x.natAbs;
  let sign := if x > 0 then Put.byte 0 else Put.byte 1;
  if enc.size < uint8Sz then
    Put.byte 110 >> Put.byte enc.size >> sign >> Put.tell enc
  else if enc.size < uint32Sz then
    Put.byte 111 >> Put.dword enc.size >> sign >> Put.tell enc
  else Put.fail "BERT integer too big"

def writeAtom (x : String) : Put :=
  if x.utf8ByteSize < uint8Sz then
    if x.all Char.isAscii then
      Put.byte 115 >> Put.byte x.length >> Put.tell x.bytes
    else Put.byte 119 >> Put.byte x.utf8ByteSize >> Put.unicode x
  else if x.utf8ByteSize < uint16Sz then
    if x.all Char.isAscii then
      Put.byte 100 >> Put.word x.length >> Put.tell x.bytes
    else Put.byte 118 >> Put.word x.utf8ByteSize >> Put.unicode x
  else Put.fail "BERT atom too long (≥ 65536)"
  
def writeString (x : String) : Put :=
  if x.utf8ByteSize < uint16Sz then
    Put.byte 107 >> Put.word x.utf8ByteSize >> Put.unicode x
  else Put.fail "BERT bytelist too long (≥ 65536)"

partial def writeTerm' : Term → Put
| Term.byte x => Put.byte 97 >> Put.raw x
| Term.int x => Put.byte 98 >> Put.tell x.toBytes
| Term.atom s => writeAtom s
| Term.tuple x =>
  let tuple := List.foldr (HasAndthen.andthen ∘ writeTerm') Put.nope;
  if x.length < uint8Sz then
    Put.byte 104 >> Put.byte x.length >> tuple x
  else if x.length < uint32Sz then
    Put.byte 105 >> Put.dword x.length >> tuple x
  else Put.fail "BERT tuple too long (≥ 4294967296)"
| Term.list x =>
  if x.length < uint32Sz then
    Put.byte 108 >> Put.dword x.length >>
    List.foldr (HasAndthen.andthen ∘ writeTerm') (Put.byte 106) x
  else Put.fail "BERT list too long (≥ 4294967296)"
| Term.binary x =>
  if x.size < uint32Sz then
    Put.byte 109 >> Put.dword x.size >> Put.tell x
  else Put.fail "BERT binary too long (≥ 4294967296)"
| Term.bigint x => writeBigint x
| Term.string s => writeString s
| Term.dict x =>
  let writePair :=
  λ (x : Term × Term) => writeTerm' x.1 >> writeTerm' x.2;
  if x.length < uint32Sz then
    Put.byte 116 >> Put.dword x.length >>
    List.foldr (HasAndthen.andthen ∘ writePair) Put.nope x
  else Put.fail "BERT dictionary too long (≥ 4294967296)"

def writeTerm (x : Term) : Sum String ByteArray :=
Put.run (Put.byte 131 >> writeTerm' x)
