
import ./core
import std/[os, parseopt, strutils, tables]

proc readFileBinary*(path: string): string =
  result = readFile(path)

proc writeOutput*(inputPath, outputPath: string; output: string) =
  writeFile(outputPath, output)
  setFilePermissions(outputPath, getFilePermissions(inputPath))

proc defaultOutputPath*(inputPath: string): string =
  let dir = parentDir(inputPath)
  let stem = splitFile(inputPath).name
  var candidate = joinPath(dir, stem & " - stubbed.wasm")
  var index = 1
  while fileExists(candidate):
    candidate = joinPath(dir, stem & " - stubbed (" & $index & ").wasm")
    inc index
  candidate

proc parseArgs*(): tuple[inputPath: string, outputPath: string, listOnly: bool, shouldStubSpec: ShouldStub, returnValue: uint32] =
  result.shouldStubSpec = newShouldStub()
  result.returnValue = 76
  var stubModuleValues: seq[string]
  var stubFunctionValues: seq[string]
  var sawStubOption = false

  var parser = initOptParser(commandLineParams())
  while true:
    parser.next()
    case parser.kind
    of cmdEnd:
      break
    of cmdArgument:
      if result.inputPath.len == 0:
        result.inputPath = parser.key
      else:
        raise newException(ValueError, "unexpected positional argument: " & parser.key)
    of cmdLongOption, cmdShortOption:
      case parser.key
      of "o", "output":
        result.outputPath = parser.val
      of "stub-module":
        sawStubOption = true
        stubModuleValues.add parser.val
      of "stub-function":
        sawStubOption = true
        stubFunctionValues.add parser.val
      of "r", "return-value":
        result.returnValue = parseUInt(parser.val).uint32
      of "list":
        result.listOnly = true
      of "h", "help":
        echo "Usage: wasi_stub <file> [--stub-module MODULE[,MODULE...]] [--stub-function MODULE:FUNC[,MODULE:FUNC...]] [--return-value N] [--list] [-o OUTPUT]"
        quit(0)
      else:
        raise newException(ValueError, "unknown option: " & parser.key)

  if result.inputPath.len == 0:
    raise newException(ValueError, "missing input file")

  if sawStubOption:
    result.shouldStubSpec.modules.clear()
    for value in stubFunctionValues:
      for item in value.split(','):
        if item.len == 0:
          continue
        let parts = item.split(':', 1)
        if parts.len != 2:
          raise newException(ValueError, "malformed --stub-function value: " & item)
        result.shouldStubSpec.addStubFunction(parts[0], parts[1])
    for value in stubModuleValues:
      for item in value.split(','):
        if item.len > 0:
          result.shouldStubSpec.addStubModule(item)