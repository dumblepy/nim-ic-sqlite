## Usage: nim c -r runner/profile_summary.nim <results/profile-run-id>
import std/[json, os]
import ./validate

proc main() =
  if paramCount() != 1: raise newException(ValueError, "pass a profile result directory")
  let resultDir = paramStr(1)
  let path = resultDir / "profile_measurements.jsonl"
  validateProfileResults(path)
  var markdown = "# Profile summary\n\n| Profile | Nim instructions | Rust instructions | Nim / Rust |\n|---|---:|---:|---:|\n"
  for profile in ["read", "write", "get_many_in", "growth"]:
    var nimInstructions, rustInstructions: uint64
    for line in lines(path):
      let row = parseJson(line)
      if row["profile"].getStr() != profile: continue
      if row["implementation"].getStr() == "nim": nimInstructions = uint64(row["instructions"].getBiggestInt())
      else: rustInstructions = uint64(row["instructions"].getBiggestInt())
    if rustInstructions == 0: raise newException(ValueError, "zero Rust instructions")
    markdown.add("| " & profile & " | " & $nimInstructions & " | " & $rustInstructions & " | " & $(float64(nimInstructions) / float64(rustInstructions)) & " |\n")
  writeFile(resultDir / "profile_summary.md", markdown)

when isMainModule: main()
