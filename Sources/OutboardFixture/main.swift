import Foundation

// Sleeps. The Mac tests copy this executable into <tmp>/Foo.app/Contents/MacOS/Foo and run it, to prove that the running-app
// check sees a process executing from inside a bundle. It touches nothing.
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 120
Thread.sleep(forTimeInterval: seconds)
