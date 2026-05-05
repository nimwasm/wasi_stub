
import ./wasi_stub/[cli, core]
export core

when isMainModule:
  try:
    let args = parseArgs()
    let input = readFileBinary(args.inputPath)
    let output = stubWasiFunctions(input, args.shouldStubSpec, args.returnValue)
    if args.listOnly:
      echo "NOTE: no output produced because the '--list' option was specified"
    else:
      let outPath = if args.outputPath.len > 0: args.outputPath else: defaultOutputPath(args.inputPath)
      writeOutput(args.inputPath, outPath, output)
  except CatchableError as exc:
    stderr.writeLine(exc.msg)
    quit(1)
