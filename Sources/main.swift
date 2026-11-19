import AppKit
import XPC

let usage = """
    Usage: Knob                       run (launchd starts it when the screen connects)
           Knob --setup               choose the screen, sound control and apps
           Knob --check               show the setup and whether the screen is connected
           Knob --write-agent [path]  write the LaunchAgent that starts Knob at path (default: this copy)
    """

MainActor.assumeIsolated {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "--setup":
        exit(Setup.run() ? 0 : 1)
    case "--check":
        exit(Setup.check() ? 0 : 1)
    case "--write-agent":
        let program = arguments.count > 1 ? arguments[1] : (Bundle.main.executablePath ?? CommandLine.arguments[0])
        exit(Setup.writeAgent(program: program) ? 0 : 1)
    case "--help", "-h":
        print(usage)
        exit(0)
    default:
        break
    }

    // launchd starts Knob when the screen appears. The event has to be taken off its stream, or
    // launchd keeps delivering it.
    xpc_set_event_stream_handler("com.apple.iokit.matching", DispatchQueue.main) { _ in }

    let app = NSApplication.shared
    let delegate = AppDelegate()  // Lives as long as `run()`, which only returns at quit.
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
