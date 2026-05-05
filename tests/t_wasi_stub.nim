import std/[tables, unittest]

import wasi_stub

type
  Cursor = object
    data: string
    pos: int

proc readU8(cursor: var Cursor): uint8 =
  result = uint8(cursor.data[cursor.pos].ord)
  inc cursor.pos

proc readVarU32(cursor: var Cursor): uint32 =
  var shift = 0'u32
  while true:
    let byte = cursor.readU8()
    result = result or (uint32(byte and 0x7f'u8) shl shift)
    if (byte and 0x80'u8) == 0:
      break
    shift += 7

proc putVarU32(target: var string; value: uint32) =
  var v = value
  while true:
    var byte = uint8(v and 0x7f'u32)
    v = v shr 7
    if v == 0:
      target.add char(byte)
      break
    target.add char(byte or 0x80'u8)

proc encodeName(target: var string; name: string) =
  target.putVarU32(name.len.uint32)
  target.add name

proc encodeSection(id: uint8; payload: string): string =
  result.add char(id)
  result.putVarU32(payload.len.uint32)
  result.add payload

proc buildSampleWasm(): string =
  result.add "\x00asm\x01\x00\x00\x00"

  var typePayload = ""
  typePayload.putVarU32(1)
  typePayload.add '\x60'
  typePayload.putVarU32(1)
  typePayload.add '\x7f'
  typePayload.putVarU32(1)
  typePayload.add '\x7f'
  result.add encodeSection(1, typePayload)

  var importPayload = ""
  importPayload.putVarU32(1)
  importPayload.encodeName("wasi_snapshot_preview1")
  importPayload.encodeName("fd_write")
  importPayload.add '\x00'
  importPayload.putVarU32(0)
  result.add encodeSection(2, importPayload)

  var functionPayload = ""
  functionPayload.putVarU32(1)
  functionPayload.putVarU32(0)
  result.add encodeSection(3, functionPayload)

  var exportPayload = ""
  exportPayload.putVarU32(1)
  exportPayload.encodeName("main")
  exportPayload.add '\x00'
  exportPayload.putVarU32(1)
  result.add encodeSection(7, exportPayload)

  var codePayload = ""
  codePayload.putVarU32(1)
  var body = ""
  body.add '\x00'
  body.add '\x41'
  body.add '\x07'
  body.add '\x0b'
  codePayload.putVarU32(body.len.uint32)
  codePayload.add body
  result.add encodeSection(10, codePayload)

proc parseSectionCounts(binary: string): Table[uint8, uint32] =
  var cursor = Cursor(data: binary, pos: 8)
  while cursor.pos < cursor.data.len:
    let id = cursor.readU8()
    let size = cursor.readVarU32()
    result[id] = result.getOrDefault(id) + 1
    cursor.pos += int(size)

suite "wasi-stub":
  test "replaces a WASI import with a stubbed function slot":
    let input = buildSampleWasm()
    let output = stubWasiFunctions(input, newShouldStub(), 76)

    check output != input

    let counts = parseSectionCounts(output)
    check counts[2] == 1
    check counts[3] == 1
    check counts[10] == 1

    var cursor = Cursor(data: output, pos: 8)
    while cursor.pos < cursor.data.len:
      let id = cursor.readU8()
      let size = cursor.readVarU32()
      let sectionStart = cursor.pos
      if id == 2:
        var importCursor = Cursor(data: output[sectionStart ..< sectionStart + int(size)])
        check importCursor.readVarU32() == 0
      if id == 3:
        var functionCursor = Cursor(data: output[sectionStart ..< sectionStart + int(size)])
        check functionCursor.readVarU32() == 2
      if id == 10:
        var codeCursor = Cursor(data: output[sectionStart ..< sectionStart + int(size)])
        check codeCursor.readVarU32() == 2
      cursor.pos += int(size)
