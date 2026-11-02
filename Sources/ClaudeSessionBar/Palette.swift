import AppKit
import SwiftUI

/// Counts taps on the title: 19 within 6 seconds opens the palette.
struct TapBurst {
    var needed = 19
    var window: TimeInterval = 6
    private var taps: [Date] = []

    init(needed: Int = 19, window: TimeInterval = 6) {
        self.needed = needed
        self.window = window
    }

    /// True on the tap that completes a burst; the count then starts over.
    mutating func register(at now: Date = Date()) -> Bool {
        taps = taps.filter { now.timeIntervalSince($0) < window } + [now]
        guard taps.count >= needed else { return false }
        taps = []
        return true
    }
}

/// Colours stored as "#RRGGBB" in sRGB.
enum HexColor {
    static func string(from color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    static func nsColor(_ hex: String) -> NSColor? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// Light colours get dark text on top, the way Bootstrap's yellow does.
    static func isLight(_ hex: String) -> Bool {
        guard let rgb = nsColor(hex) else { return false }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent > 0.6
    }
}

/// Shown under the header after the title easter egg: a saturation/brightness square, a hue bar,
/// a hex field and the saved colours.
struct PaletteSection: View {
    @ObservedObject var store: Store
    @ViewState private var hue: CGFloat = 0
    @ViewState private var saturation: CGFloat = 1
    @ViewState private var brightness: CGFloat = 1
    @ViewState private var hexText = ""

    private var currentHex: String? { store.customAccent }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("調色盤", "Palette")).font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    store.paletteOpen = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(tr("關閉調色盤", "Close the palette"))
            }
            HStack(spacing: 10) {
                saturationBrightnessSquare
                hueBar
            }
            .frame(height: 110)
            HStack(spacing: 8) {
                Circle().fill(store.accentColor).frame(width: 18, height: 18)
                TextField("#RRGGBB", text: $hexText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 84)
                    .onSubmit { applyHex(hexText) }
                Spacer()
                Button(tr("儲存目前顏色", "Save Colour")) { store.saveCurrentAccent() }
                    .disabled(
                        currentHex == nil || store.savedAccents.contains(currentHex ?? "")
                            || store.savedAccents.count >= Store.maxSavedAccents)
                    .help(
                        store.savedAccents.count >= Store.maxSavedAccents
                            ? tr("最多 \(Store.maxSavedAccents) 個，右鍵刪掉一個才能再存", "Up to \(Store.maxSavedAccents); right-click one to delete it first")
                            : tr("最多 \(Store.maxSavedAccents) 個", "Up to \(Store.maxSavedAccents)"))
                Button(tr("回到預設色", "Default Colours")) {
                    store.customAccent = nil
                    load(from: NSColor(store.accentColor))
                }
                .disabled(currentHex == nil)
            }
            .controlSize(.small)
            if !store.savedAccents.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 8), count: 14), alignment: .leading, spacing: 8) {
                    ForEach(store.savedAccents, id: \.self) { hex in swatch(hex) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .onAppear { load(from: NSColor(store.accentColor)) }
    }

    private var saturationBrightnessSquare: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(hue: hue, saturation: 1, brightness: 1))
                LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                Circle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .shadow(radius: 1)
                    .frame(width: 12, height: 12)
                    .offset(x: saturation * size.width - 6, y: (1 - brightness) * size.height - 6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    saturation = min(max(value.location.x / size.width, 0), 1)
                    brightness = 1 - min(max(value.location.y / size.height, 0), 1)
                    apply()
                })
        }
    }

    private var hueBar: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Color(hue: $0, saturation: 1, brightness: 1) },
                    startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.white, lineWidth: 2)
                    .shadow(radius: 1)
                    .frame(height: 6)
                    .offset(y: hue * height - 3)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    hue = min(max(value.location.y / height, 0), 1)
                    apply()
                })
        }
        .frame(width: 16)
    }

    private func swatch(_ hex: String) -> some View {
        let color = HexColor.nsColor(hex).map(Color.init(nsColor:)) ?? .clear
        let selected = currentHex == hex
        return Circle()
            .fill(color)
            .frame(width: 22, height: 22)
            .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.9 : 0.15), lineWidth: selected ? 2 : 1))
            .contentShape(Circle())
            .onTapGesture { applyHex(hex) }
            .contextMenu { Button(tr("刪除", "Delete")) { store.savedAccents.removeAll { $0 == hex } } }
            .help(hex)
    }

    private func apply() {
        let color = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        guard let hex = HexColor.string(from: color) else { return }
        hexText = hex
        if hex != store.customAccent { store.customAccent = hex }
    }

    private func applyHex(_ text: String) {
        let hex = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard let color = HexColor.nsColor(hex), let normalized = HexColor.string(from: color) else {
            hexText = store.customAccent ?? hexText
            return
        }
        store.customAccent = normalized
        load(from: color)
    }

    private func load(from color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        // Grey has no hue of its own; keep the bar where it is instead of jumping to red.
        if rgb.saturationComponent > 0.001 { hue = rgb.hueComponent }
        saturation = rgb.saturationComponent
        brightness = rgb.brightnessComponent
        hexText = HexColor.string(from: rgb) ?? ""
    }
}

/// --check-palette: the tap burst and colour conversions.
enum PaletteCheck {
    static func run() -> Bool {
        var ok = true
        func expect(_ pass: Bool, _ label: String) {
            print((pass ? "PASS " : "FAIL ") + label)
            ok = ok && pass
        }
        let start = Date()
        var burst = TapBurst()
        let opened = (0..<19).map { burst.register(at: start.addingTimeInterval(Double($0) * 0.3)) }
        expect(opened.last == true && opened.dropLast().allSatisfy { !$0 }, "19 taps in 5.4 s open the palette on the 19th")
        expect(!burst.register(at: start.addingTimeInterval(6)), "the count starts over after opening")
        var slow = TapBurst()
        let slowOpened = (0..<19).map { slow.register(at: start.addingTimeInterval(Double($0) * 0.4)) }
        expect(!slowOpened.contains(true), "19 taps spread over 7.2 s do not open it")
        var short = TapBurst()
        expect(!(0..<18).map { short.register(at: start.addingTimeInterval(Double($0) * 0.1)) }.contains(true), "18 quick taps do not open it")
        expect(HexColor.string(from: HexColor.nsColor("#0D6EFD")!) == "#0D6EFD", "hex round trip")
        expect(HexColor.nsColor("12345") == nil && HexColor.nsColor("#GGGGGG") == nil, "malformed hex is rejected")
        expect(HexColor.isLight("#FFC107") && !HexColor.isLight("#0D6EFD"), "yellow counts as light, blue as dark")
        let store = Store.shared
        let (savedList, savedCustom) = (store.savedAccents, store.customAccent)
        defer { (store.savedAccents, store.customAccent) = (savedList, savedCustom) }
        store.savedAccents = []
        for index in 0..<21 {
            store.customAccent = String(format: "#0000%02X", index)
            store.saveCurrentAccent()
        }
        expect(store.savedAccents.count == Store.maxSavedAccents, "saving stops at \(Store.maxSavedAccents) colours (got \(store.savedAccents.count))")
        store.saveCurrentAccent()
        expect(store.savedAccents.count == Store.maxSavedAccents, "a full palette refuses more")
        print(ok ? "ALL PASS" : "FAILED")
        return ok
    }
}
