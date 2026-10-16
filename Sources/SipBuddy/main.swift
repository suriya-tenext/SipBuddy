import AppKit

// Debug helper: `SipBuddy --slice sheet.png outDir` writes each row's sliced frames as PNGs.
let args = CommandLine.arguments
if args.count == 4, args[1] == "--slice" {
    guard let cg = ImageFiles.cgImage(at: URL(fileURLWithPath: args[2])) else { print("Could not read \(args[2])"); exit(1) }
    let out = URL(fileURLWithPath: args[3])
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for (r, row) in SpriteSlicer.rows(cg).enumerated() {
        print("row \(r): \(row.count) frames")
        for (i, f) in row.enumerated() { try? ImageFiles.png(f)?.write(to: out.appendingPathComponent("row\(r)-\(i).png")) }
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
