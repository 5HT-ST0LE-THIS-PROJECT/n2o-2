import init.system.io

def String.init (s : String) := s.extract 0 (s.length - 1)

namespace Network.N2O.Internal

def Header := String × String
instance Header.HasToString : HasToString Header :=
⟨fun pair ⇒ pair.fst ++ ": " ++ pair.snd⟩

structure Req :=
(path : String)
(method : String)
(version : String)
(headers : List Header)

inductive Result (α : Type)
| reply {} : α → Result
| ok {} : Result
| unknown {} : Result

inductive Event (α : Type)
| init {} : Event
| message {} : α → Event
| terminate {} : Event

structure WS :=
(question : String)
(headers : Array (String × String))

def Header.dropBack : Header → Option Header
| (name, value) :=
  if name.back = ':' then some (name.init, value)
  else none

def Header.isHeader : String → Bool
| "get " := true
| "post " := true
| "option " := true
| _ := false

def WS.toReq (socket : WS) : Req :=
let headersList := socket.headers.toList;
let headers := List.filterMap Header.dropBack headersList;
{ path := Option.getOrElse
            (headersList.lookup "get " <|>
             headersList.lookup "post " <|>
             headersList.lookup "option ") "",
  method := Option.getOrElse
              (String.trimRight <$> Prod.fst <$>
                headersList.find (Header.isHeader ∘ Prod.fst)) "",
  version := Option.getOrElse
               (Prod.snd <$> headersList.find
                 (String.isPrefixOf "http" ∘ Prod.fst)) "",
  headers := headers }

end Network.N2O.Internal
