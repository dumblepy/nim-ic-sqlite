## Values accepted by the typed statement API.  Callers never need SQLite's
## C-level bind constants or ownership rules.

type
  SqlValueKind* = enum
    svNull, svInt, svFloat, svText, svBlob
  SqlValue* = object
    case kind*: SqlValueKind
    of svNull:
      discard
    of svInt:
      intValue*: int64
    of svFloat:
      floatValue*: float64
    of svText:
      textValue*: string
    of svBlob:
      blobValue*: seq[byte]

proc sqlNull*(): SqlValue = SqlValue(kind: svNull)
proc sqlInt*(value: int64): SqlValue = SqlValue(kind: svInt, intValue: value)
proc sqlFloat*(value: float64): SqlValue = SqlValue(kind: svFloat, floatValue: value)
proc sqlText*(value: string): SqlValue = SqlValue(kind: svText, textValue: value)
proc sqlBlob*(value: openArray[byte]): SqlValue =
  SqlValue(kind: svBlob, blobValue: @value)
