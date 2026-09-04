import Foundation
import AlwmIPC

@main
enum AlwmCtlMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else {
            printUsage()
            exit(1)
        }

        if args[0] == "--help" || args[0] == "-h" {
            printUsage()
            exit(0)
        }

        let command: String
        let rest: [String]
        if args[0] == "command" {
            guard args.count > 1 else {
                fputs("missing command\n", stderr)
                exit(1)
            }
            command = args[1]
            rest = Array(args.dropFirst(2))
        } else {
            command = args[0]
            rest = Array(args.dropFirst())
        }

        let request = IPCRequest(command: command, args: rest)
        do {
            let response = try IPCClient.send(request)
            if response.ok {
                print(response.message)
                if let data = response.data {
                    for (k, v) in data.sorted(by: { $0.key < $1.key }) {
                        print("\(k)=\(v)")
                    }
                }
                exit(0)
            } else {
                fputs("error: \(response.message)\n", stderr)
                exit(2)
            }
        } catch {
            fputs("failed to contact ALWM at \(AlwmIPC.defaultSocketPath): \(error)\n", stderr)
            fputs("Is ALWM running?\n", stderr)
            exit(3)
        }
    }

    static func printUsage() {
        print(
            """
            alwmctl — control ALWM

            Usage:
              alwmctl <command> [args...]
              alwmctl command <command> [args...]

            Commands:
              focus left|right|up|down
              move left|right|up|down
              switch-workspace <id>
              move-to-workspace <id>
              overview
              quake
              palette
              float toggle|on|off
              settings
              dump
              relayout
              rescan
              status
            """
        )
    }
}
