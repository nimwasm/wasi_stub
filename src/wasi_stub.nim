
import ./wasi_stub/[cli, core, main]
export core, main

when isMainModule:
  try:
    let args = parseArgs()
    if args.listOnly:
      echo "NOTE: no output produced because the '--list' option was specified"
    else:
      let outPath = if args.outputPath.len > 0: args.outputPath else: defaultOutputPath(args.inputPath)
      stubWasiFunctionsForPath(args.inputPath, outPath, args.shouldStubSpec, args.returnValue)
  except CatchableError as exc:
    stderr.writeLine(exc.msg)
    quit(1)
