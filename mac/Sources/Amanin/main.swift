import Foundation

if CommandLine.arguments.contains("--cli") {
    exit(CLI.run(Array(CommandLine.arguments.dropFirst())))
}
AmaninApp.main()
