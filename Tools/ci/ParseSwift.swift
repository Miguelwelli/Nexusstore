// Parses every Swift file with the real compiler frontend (syntax-only) and reports failures.
// Usage: swift Tools/ci/ParseSwift.swift <file1> <file2> ...
import SwiftSyntax
import SwiftParser
import Foundation

var failures = 0
for path in CommandLine.arguments.dropFirst() {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("error: could not read \(path)")
        failures += 1
        continue
    }
    let tree = Parser.parse(source: source)
    let diagnostics = tree.diagnostics
    if !diagnostics.isEmpty {
        for diagnostic in diagnostics {
            print("error: \(path):\(diagnostic.location.line):\(diagnostic.location.column): \(diagnostic.message)")
        }
        failures += 1
    }
}
if failures > 0 {
    print("error: \(failures) file(s) failed to parse")
    exit(1)
}
print("ok: all \(CommandLine.arguments.count - 1) Swift files parsed by swift-syntax")
