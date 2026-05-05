import std/[sets, tables]

type
  StubMode = enum
    smAll
    smSome

  FunctionsToStub* = object
    case mode*: StubMode
    of smAll:
      discard
    of smSome:
      names*: HashSet[string]

  ShouldStub* = object
    modules*: Table[string, FunctionsToStub]

  ValueKind = enum
    vkI32, vkI64, vkF32, vkF64, vkV128, vkFuncRef, vkExternRef, vkUnsupported

  FunctionType = object
    results: seq[ValueKind]

  ImportKind = enum
    ikFunc, ikTable, ikMemory, ikGlobal, ikTag, ikUnsupported

  ImportEntry = object
    moduleName: string
    fieldName: string
    kind: ImportKind
    typeIndex: uint32
    raw: string

  Section = object
    id: uint8
    payload: string

  Cursor = object
    data: string
    pos: int

const DefDummyReturnValue* = 76
proc newShouldStub*(): ShouldStub =
  result.modules = initTable[string, FunctionsToStub]()
  result.modules["wasi_snapshot_preview1"] = FunctionsToStub(mode: smAll)

proc shouldStub*(spec: ShouldStub; moduleName, functionName: string): bool =
  if moduleName notin spec.modules:
    return false

  let decision = spec.modules[moduleName]
  case decision.mode
  of smAll:
    true
  of smSome:
    functionName in decision.names

proc addStubFunction*(spec: var ShouldStub; moduleName, functionName: string) =
  var entry = spec.modules.mgetOrPut(moduleName, FunctionsToStub(mode: smSome, names: initHashSet[string]()))
  case entry.mode
  of smAll:
    discard
  of smSome:
    entry.names.incl(functionName)
  spec.modules[moduleName] = entry

proc addStubModule*(spec: var ShouldStub; moduleName: string) =
  spec.modules[moduleName] = FunctionsToStub(mode: smAll)

proc newValueKind(byteValue: uint8): ValueKind =
  case byteValue
  of 0x7f'u8: vkI32
  of 0x7e'u8: vkI64
  of 0x7d'u8: vkF32
  of 0x7c'u8: vkF64
  of 0x7b'u8: vkV128
  of 0x70'u8: vkFuncRef
  of 0x6f'u8: vkExternRef
  else: vkUnsupported

proc newImportKind(byteValue: uint8): ImportKind =
  case byteValue
  of 0x00'u8: ikFunc
  of 0x01'u8: ikTable
  of 0x02'u8: ikMemory
  of 0x03'u8: ikGlobal
  of 0x04'u8: ikTag
  else: ikUnsupported

proc readU8(cursor: var Cursor): uint8 =
  if cursor.pos >= cursor.data.len:
    raise newException(ValueError, "unexpected end of wasm input")
  result = uint8(cursor.data[cursor.pos].ord)
  inc cursor.pos

proc readBytes(cursor: var Cursor; count: int): string =
  if count < 0 or cursor.pos + count > cursor.data.len:
    raise newException(ValueError, "unexpected end of wasm input")
  result = cursor.data[cursor.pos ..< cursor.pos + count]
  inc cursor.pos, count

proc readVarU32(cursor: var Cursor): uint32 =
  var shift = 0'u32
  while true:
    let byte = cursor.readU8()
    result = result or (uint32(byte and 0x7f'u8) shl shift)
    if (byte and 0x80'u8) == 0:
      break
    shift += 7
    if shift > 35:
      raise newException(ValueError, "invalid uleb128 value")

proc readName(cursor: var Cursor): string =
  let length = cursor.readVarU32()
  result = cursor.readBytes(int(length))

proc readLimits(cursor: var Cursor) =
  let flags = cursor.readU8()
  discard cursor.readVarU32()
  if (flags and 0x01'u8) != 0:
    discard cursor.readVarU32()

proc splitSections(binary: string): seq[Section] =
  if binary.len < 8 or binary[0] != '\x00' or binary[1] != 'a' or binary[2] != 's' or binary[3] != 'm':
    raise newException(ValueError, "input is not a wasm binary")
  if binary[4] != '\x01' or binary[5] != '\x00' or binary[6] != '\x00' or binary[7] != '\x00':
    raise newException(ValueError, "unsupported wasm version")

  var cursor = Cursor(data: binary, pos: 8)
  while cursor.pos < cursor.data.len:
    let id = cursor.readU8()
    let payloadLen = cursor.readVarU32()
    let payload = cursor.readBytes(int(payloadLen))
    result.add Section(id: id, payload: payload)

proc parseTypeSection(payload: string): seq[FunctionType] =
  var cursor = Cursor(data: payload)
  let count = cursor.readVarU32()
  result.setLen(int(count))
  for i in 0 ..< int(count):
    let form = cursor.readU8()
    if form != 0x60'u8:
      raise newException(ValueError, "only core function types are supported")
    let paramCount = cursor.readVarU32()
    for _ in 0 ..< int(paramCount):
      discard cursor.readU8()
    let resultCount = cursor.readVarU32()
    for _ in 0 ..< int(resultCount):
      result[i].results.add newValueKind(cursor.readU8())

proc skipImportDescriptor(cursor: var Cursor; kind: ImportKind) =
  case kind
  of ikFunc:
    discard cursor.readVarU32()
  of ikTable:
    discard cursor.readU8()
    readLimits(cursor)
  of ikMemory:
    readLimits(cursor)
  of ikGlobal:
    discard cursor.readU8()
    discard cursor.readU8()
  of ikTag:
    discard cursor.readU8()
    discard cursor.readVarU32()
  of ikUnsupported:
    raise newException(ValueError, "unsupported import kind")

proc parseImportSection(payload: string): seq[ImportEntry] =
  var cursor = Cursor(data: payload)
  let count = cursor.readVarU32()
  for _ in 0 ..< int(count):
    let start = cursor.pos
    let moduleName = cursor.readName()
    let fieldName = cursor.readName()
    let kindByte = cursor.readU8()
    let kind = newImportKind(kindByte)
    var typeIndex: uint32
    skipImportDescriptor(cursor, kind)
    let raw = payload[start ..< cursor.pos]
    if kind == ikFunc:
      var temp = Cursor(data: raw)
      discard temp.readName()
      discard temp.readName()
      discard temp.readU8()
      typeIndex = temp.readVarU32()
    result.add ImportEntry(
      moduleName: moduleName,
      fieldName: fieldName,
      kind: kind,
      typeIndex: typeIndex,
      raw: raw,
    )

proc parseFunctionSection(payload: string): seq[uint32] =
  var cursor = Cursor(data: payload)
  let count = cursor.readVarU32()
  result.setLen(int(count))
  for i in 0 ..< int(count):
    result[i] = cursor.readVarU32()

proc parseCodeSection(payload: string): seq[string] =
  var cursor = Cursor(data: payload)
  let count = cursor.readVarU32()
  for _ in 0 ..< int(count):
    let bodyLen = cursor.readVarU32()
    result.add cursor.readBytes(int(bodyLen))

proc putU32LE(target: var string; value: uint32) =
  for shift in [0'u32, 8, 16, 24]:
    target.add char((value shr shift) and 0xff'u32)

proc putU64LE(target: var string; value: uint64) =
  for shift in [0'u32, 8, 16, 24, 32, 40, 48, 56]:
    target.add char((value shr shift) and 0xff'u64)

proc bitsOf(value: float32): uint32 =
  var temp = value
  copyMem(addr result, addr temp, sizeof(result))

proc bitsOf(value: float64): uint64 =
  var temp = value
  copyMem(addr result, addr temp, sizeof(result))

proc putVarU32(target: var string; value: uint32) =
  var v = value
  while true:
    var byte = uint8(v and 0x7f'u32)
    v = v shr 7
    if v == 0:
      target.add char(byte)
      break
    target.add char(byte or 0x80'u8)

proc putSignedFromUnsigned(target: var string; value: uint64) =
  var v = value
  while true:
    let byte = uint8(v and 0x7f'u64)
    v = v shr 7
    if v == 0:
      if (byte and 0x40'u8) != 0:
        target.add char(byte or 0x80'u8)
        target.add '\x00'
      else:
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

proc encodeTypeSection(types: seq[FunctionType]): string =
  result.putVarU32(types.len.uint32)
  for typ in types:
    result.add '\x60'
    result.putVarU32(0)
    result.putVarU32(typ.results.len.uint32)
    for kind in typ.results:
      case kind
      of vkI32: result.add '\x7f'
      of vkI64: result.add '\x7e'
      of vkF32: result.add '\x7d'
      of vkF64: result.add '\x7c'
      of vkV128, vkFuncRef, vkExternRef, vkUnsupported:
        raise newException(ValueError, "stubbed functions with non-numeric returns are not supported")

proc encodeImportSection(entries: seq[ImportEntry]): string =
  result.putVarU32(entries.len.uint32)
  for entry in entries:
    result.add entry.raw

proc encodeFunctionSection(typeIndices: seq[uint32]): string =
  result.putVarU32(typeIndices.len.uint32)
  for typ in typeIndices:
    result.putVarU32(typ)

proc encodeCodeSection(bodies: seq[string]): string =
  result.putVarU32(bodies.len.uint32)
  for body in bodies:
    result.putVarU32(body.len.uint32)
    result.add body

proc encodeStubBody(typ: FunctionType; returnValue: uint32): string =
  result.add '\x00' # local decl count
  for kind in typ.results:
    case kind
    of vkI32:
      result.add '\x41'
      result.putSignedFromUnsigned(uint64(returnValue))
    of vkI64:
      result.add '\x42'
      result.putSignedFromUnsigned(uint64(returnValue))
    of vkF32:
      result.add '\x43'
      result.putU32LE(bitsOf(float32(returnValue)))
    of vkF64:
      result.add '\x44'
      result.putU64LE(bitsOf(float64(returnValue)))
    of vkV128, vkFuncRef, vkExternRef, vkUnsupported:
      raise newException(ValueError, "stubbed functions with non-numeric returns are not supported")
  result.add '\x0b'

proc buildStubList(types: seq[FunctionType]; imports: seq[ImportEntry]; shouldStubSpec: ShouldStub; returnValue: uint32): tuple[types: seq[uint32], bodies: seq[string], keptImports: seq[ImportEntry]] =
  for entry in imports:
    if entry.kind == ikFunc and shouldStubSpec.shouldStub(entry.moduleName, entry.fieldName):
      if int(entry.typeIndex) >= types.len:
        raise newException(ValueError, "import references an invalid type index")
      result.types.add entry.typeIndex
      result.bodies.add encodeStubBody(types[int(entry.typeIndex)], returnValue)
    else:
      result.keptImports.add entry

proc stubWasiFunctions*(binary: string; shouldStubSpec = newShouldStub(); returnValue: uint32 = DefDummyReturnValue): string =
  let sections = splitSections(binary)

  var types: seq[FunctionType]
  var imports: seq[ImportEntry]
  var functionTypes: seq[uint32]
  var codeBodies: seq[string]
  var typeSectionIdx = -1
  var importSectionIdx = -1
  var functionSectionIdx = -1
  var codeSectionIdx = -1

  for idx, section in sections:
    case section.id
    of 1'u8:
      types = parseTypeSection(section.payload)
      typeSectionIdx = idx
    of 2'u8:
      imports = parseImportSection(section.payload)
      importSectionIdx = idx
    of 3'u8:
      functionTypes = parseFunctionSection(section.payload)
      functionSectionIdx = idx
    of 10'u8:
      codeBodies = parseCodeSection(section.payload)
      codeSectionIdx = idx
    else:
      discard

  if imports.len == 0:
    return binary

  let stubbed = buildStubList(types, imports, shouldStubSpec, returnValue)
  if stubbed.types.len == 0:
    return binary

  var outputSections = sections
  outputSections[importSectionIdx].payload = encodeImportSection(stubbed.keptImports)
  if functionSectionIdx >= 0:
    outputSections[functionSectionIdx].payload = encodeFunctionSection(stubbed.types & functionTypes)
  if codeSectionIdx >= 0:
    outputSections[codeSectionIdx].payload = encodeCodeSection(stubbed.bodies & codeBodies)

  result.add "\x00asm\x01\x00\x00\x00"
  var functionInserted = functionSectionIdx >= 0
  var codeInserted = codeSectionIdx >= 0

  for section in outputSections:
    if not functionInserted and section.id != 0'u8 and section.id > 2'u8:
      result.add encodeSection(3'u8, encodeFunctionSection(stubbed.types))
      functionInserted = true
    if not codeInserted and section.id != 0'u8 and section.id > 10'u8:
      result.add encodeSection(10'u8, encodeCodeSection(stubbed.bodies))
      codeInserted = true
    result.add encodeSection(section.id, section.payload)

  if not functionInserted:
    result.add encodeSection(3'u8, encodeFunctionSection(stubbed.types))
  if not codeInserted:
    result.add encodeSection(10'u8, encodeCodeSection(stubbed.bodies))

  discard typeSectionIdx
