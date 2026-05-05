

import ./[core, cli]
proc stubWasiFunctionsForPath*(inputPath, outputPath: string, shouldStubSpec = newShouldStub(), returnValue: uint32 = DefDummyReturnValue) =
  let input = readFileBinary(inputPath)
  let output = stubWasiFunctions(input, shouldStubSpec, returnValue)
  writeOutput(inputPath, outputPath, output)

