import AppKit
import SwiftUI

// Builds AppIcon.icns from square artwork (tools/icon-art.png, generated with Higgsfield gpt_image_2_5):
// clips it to the macOS icon shape (an 824 pt squircle on a 1024 pt canvas) and adds the drop shadow.
// Usage: swiftc -swift-version 5 tools/make-icon.swift -o /tmp/make-icon
//        /tmp/make-icon tools/icon-art.png AppIcon.icns docs/icon.png

struct IconView: View {
    let art: NSImage

    var body: some View {
        Image(nsImage: art)
            .resizable()
            .frame(width: 824, height: 824)
            .clipShape(RoundedRectangle(cornerRadius: 186, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 186, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                              lineWidth: 4))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            .frame(width: 1024, height: 1024)
    }
}

@MainActor func render(_ art: NSImage, _ size: Int) -> Data {
    let renderer = ImageRenderer(content: IconView(art: art).scaleEffect(CGFloat(size) / 1024)
        .frame(width: CGFloat(size), height: CGFloat(size)))
    renderer.scale = 1
    return NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
}

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    let art = NSImage(contentsOfFile: args[1])!
    let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.removeItem(at: set)
    try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try! render(art, base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
        try! render(art, base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    if args.count > 3 { try! render(art, 1024).write(to: URL(fileURLWithPath: args[3])) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", set.path, "-o", args[2]]
    try! p.run()
    p.waitUntilExit()
}
