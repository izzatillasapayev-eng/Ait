// Промо-ролик Ait: 10 секунд, 1080×1920 (9:16), без звука.
//   swift make-promo.swift Ait-promo.mp4              — видео
//   swift make-promo.swift --stills папка 0.8 3.5 …   — отдельные кадры PNG для проверки
import AppKit
import AVFoundation

let W: CGFloat = 1080, H: CGFloat = 1920
let fps = 30
let duration = 10.0

// MARK: - Анимационные помощники

func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
func prog(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func easeOutBack(_ x: Double) -> Double { let c = 1.70158; return 1 + (c + 1) * pow(x - 1, 3) + c * pow(x - 1, 2) }
/// Плавно появляется на [a, b] и исчезает на [c, d].
func visible(_ t: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
    min(easeOut(prog(t, a, b)), 1 - easeOut(prog(t, c, d)))
}
func lerp(_ a: CGFloat, _ b: CGFloat, _ x: Double) -> CGFloat { a + (b - a) * CGFloat(x) }

func hex(_ v: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
}

// MARK: - Рисование

var ctx: CGContext!

func group(alpha: Double, dx: CGFloat = 0, dy: CGFloat = 0, scale: CGFloat = 1, around: CGPoint = .zero, _ body: () -> Void) {
    guard alpha > 0.001 else { return }
    ctx.saveGState()
    ctx.setAlpha(CGFloat(alpha))
    ctx.translateBy(x: dx + around.x, y: dy + around.y)
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -around.x, y: -around.y)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return italic ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
}

func attributed(_ s: String, _ f: NSFont, _ c: NSColor, align: NSTextAlignment = .center, kern: CGFloat = 0) -> NSAttributedString {
    let p = NSMutableParagraphStyle()
    p.alignment = align
    p.lineSpacing = f.pointSize * 0.12
    return NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c, .paragraphStyle: p, .kern: kern])
}

/// Текст по центру ширины `width` вокруг centerX, верхний край — y. Возвращает высоту.
@discardableResult
func text(_ s: String, _ f: NSFont, _ c: NSColor, y: CGFloat, centerX: CGFloat = W / 2, width: CGFloat = W - 120, kern: CGFloat = 0) -> CGFloat {
    let str = attributed(s, f, c, kern: kern)
    let h = ceil(str.boundingRect(with: NSSize(width: width, height: 4000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    str.draw(with: NSRect(x: centerX - width / 2, y: y, width: width, height: h), options: [.usesLineFragmentOrigin, .usesFontLeading])
    return h
}

func textLeft(_ s: String, _ f: NSFont, _ c: NSColor, in r: NSRect) {
    attributed(s, f, c, align: .left).draw(with: r, options: [.usesLineFragmentOrigin, .usesFontLeading])
}

func textSize(_ s: String, _ f: NSFont, width: CGFloat = 4000) -> CGSize {
    let r = attributed(s, f, .white, align: .left).boundingRect(with: NSSize(width: width, height: 4000), options: [.usesLineFragmentOrigin, .usesFontLeading])
    return CGSize(width: ceil(r.width), height: ceil(r.height))
}

func rounded(_ r: CGRect, _ radius: CGFloat, fill: NSColor, stroke: NSColor? = nil, lineWidth: CGFloat = 2) {
    let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }
}

func withShadow(_ blur: CGFloat, _ dy: CGFloat, _ alpha: CGFloat, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: dy)  // контекст перевёрнут: положительное — вниз
    s.shadowColor = NSColor.black.withAlphaComponent(alpha)
    s.set()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

func circle(_ c: CGPoint, _ r: CGFloat, _ color: NSColor) {
    color.setFill()
    NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
}

func radialGlow(_ c: CGPoint, _ r: CGFloat, _ color: NSColor) {
    let colors = [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
}

let waveform: NSImage = {
    let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .semibold)
    let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    return NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}()

func icon(center: CGPoint, size s: CGFloat) {
    let r = CGRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s)
    let path = NSBezierPath(roundedRect: r, xRadius: s * 0.225, yRadius: s * 0.225)
    withShadow(s * 0.12, s * 0.05, 0.45) {
        NSColor.black.setFill()
        path.fill()
    }
    NSGradient(colors: [hex(0x12C7A8), hex(0x296BED), hex(0x4A40D9)])!.draw(in: path, angle: 60)
    let ws = waveform.size
    let k = s * 0.5 / ws.height
    let wr = CGRect(x: center.x - ws.width * k / 2, y: center.y - ws.height * k / 2, width: ws.width * k, height: ws.height * k)
    waveform.draw(in: wr, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

func pill(_ label: String, center: CGPoint, f: NSFont, fill: NSColor, stroke: NSColor?, color: NSColor, padX: CGFloat = 34, height: CGFloat = 78) {
    let size = textSize(label, f)
    let r = CGRect(x: center.x - size.width / 2 - padX, y: center.y - height / 2, width: size.width + padX * 2, height: height)
    rounded(r, height / 2, fill: fill, stroke: stroke)
    textLeft(label, f, color, in: NSRect(x: r.minX + padX, y: center.y - size.height / 2, width: size.width + 4, height: size.height))
}

// MARK: - Сцены

let spoken = "Привет! Ертең кездесейік, в десять утра?"
let accent = hex(0x2DD4BF)

func background(_ t: Double) {
    NSGradient(colors: [hex(0x070B18), hex(0x0E1533), hex(0x0A0F24)])!.draw(in: CGRect(x: 0, y: 0, width: W, height: H), angle: 90)
    // для GIF фон неподвижен: тогда кодировщик хранит только изменившиеся области кадра
    let drift = ProcessInfo.processInfo.environment["AIT_STATIC_BG"] == nil ? CGFloat(sin(t * 0.6)) * 40 : 0
    radialGlow(CGPoint(x: 160 + drift, y: 330), 700, hex(0x12C7A8, 0.20))
    radialGlow(CGPoint(x: 960 - drift, y: 1600), 800, hex(0x4A40D9, 0.26))
    radialGlow(CGPoint(x: 540, y: 980), 650, hex(0x296BED, 0.10))
}

func intro(_ t: Double) {
    let out = easeInOut(prog(t, 1.15, 1.45))
    group(alpha: 1 - out, dy: -CGFloat(out) * 60) {
        let s = prog(t, 0.0, 0.6)
        group(alpha: easeOut(prog(t, 0, 0.3)), scale: CGFloat(0.55 + 0.45 * easeOutBack(s)), around: CGPoint(x: W / 2, y: 690)) {
            icon(center: CGPoint(x: W / 2, y: 690), size: 300)
        }
        group(alpha: easeOut(prog(t, 0.2, 0.6)), dy: CGFloat(1 - easeOut(prog(t, 0.2, 0.6))) * 30) {
            text("Ait", font(170, .heavy), .white, y: 880, kern: -2)
        }
        group(alpha: easeOut(prog(t, 0.35, 0.8)), dy: CGFloat(1 - easeOut(prog(t, 0.35, 0.8))) * 30) {
            text("Голосовой ввод\nна русском и казахском", font(68, .semibold), hex(0xE5E7EB), y: 1100)
        }
        group(alpha: easeOut(prog(t, 0.55, 0.9))) {
            pill("для Mac", center: CGPoint(x: W / 2, y: 1330), f: font(38, .medium), fill: hex(0xFFFFFF, 0.08), stroke: hex(0xFFFFFF, 0.22), color: hex(0xD1D5DB))
        }
    }
}

// Тайминг демонстрации
let pressAt = 1.85, releaseAt = 4.25, insertAt = 4.6, sendAt = 5.35
let speakFrom = 2.2, speakTo = 3.9

// Окно чата
let win = CGRect(x: 70, y: 470, width: 940, height: 820)
let field = CGRect(x: 104, y: 1290 - 40 - 96, width: 872, height: 96)

func caption(_ t: Double, step: String, title: String, a: Double, b: Double, c: Double, d: Double) {
    let v = visible(t, a, b, c, d)
    group(alpha: v, dy: CGFloat(1 - easeOut(prog(t, a, b))) * 24) {
        text(step, font(32, .bold), accent, y: 222, kern: 4)
        text(title, font(72, .bold), .white, y: 268)
    }
}

func chatWindow(_ t: Double) {
    withShadow(60, 30, 0.55) { rounded(win, 40, fill: hex(0xFFFFFF)) }
    ctx.saveGState()
    NSBezierPath(roundedRect: win, xRadius: 40, yRadius: 40).addClip()
    hex(0xF2F2F5).setFill()
    NSBezierPath(rect: CGRect(x: win.minX, y: win.minY, width: win.width, height: 92)).fill()
    hex(0xE2E2E7).setFill()
    NSBezierPath(rect: CGRect(x: win.minX, y: win.minY + 92, width: win.width, height: 2)).fill()
    ctx.restoreGState()
    for (i, c) in [hex(0xFF5F57), hex(0xFEBC2E), hex(0x28C840)].enumerated() {
        circle(CGPoint(x: win.minX + 46 + CGFloat(i) * 40, y: win.minY + 46), 13, c)
    }
    text("Айгерим", font(36, .semibold), hex(0x1C1C1E), y: win.minY + 24, centerX: win.midX, width: 400)

    func incoming(_ s: String, y: CGFloat) {
        let f = font(38)
        let size = textSize(s, f, width: 600)
        let r = CGRect(x: win.minX + 40, y: y, width: size.width + 56, height: size.height + 36)
        rounded(r, 30, fill: hex(0xE9E9EB))
        textLeft(s, f, hex(0x111111), in: NSRect(x: r.minX + 28, y: r.minY + 18, width: size.width + 4, height: size.height))
    }
    incoming("Сәлем! Ертең кездесеміз бе?", y: win.minY + 140)
    incoming("Во сколько тебе удобно?", y: win.minY + 250)

    let sent = prog(t, sendAt, sendAt + 0.4)
    if sent > 0 {
        let f = font(38)
        let size = textSize(spoken, f, width: 560)
        let r = CGRect(x: win.maxX - 40 - size.width - 56, y: win.minY + 370, width: size.width + 56, height: size.height + 36)
        group(alpha: easeOut(sent), dy: CGFloat(1 - easeOut(sent)) * 80, scale: CGFloat(0.9 + 0.1 * easeOutBack(sent)), around: CGPoint(x: r.maxX, y: r.maxY)) {
            rounded(r, 30, fill: hex(0x2F6FDE))
            textLeft(spoken, f, .white, in: NSRect(x: r.minX + 28, y: r.minY + 18, width: size.width + 4, height: size.height))
        }
    }

    let inserted = prog(t, insertAt, insertAt + 0.25)
    let glow = visible(t, insertAt, insertAt + 0.2, insertAt + 0.5, insertAt + 0.9)
    rounded(field, 48, fill: hex(0xF4F4F7), stroke: glow > 0 ? hex(0x2F6FDE, CGFloat(glow)) : hex(0xD6D6DC), lineWidth: glow > 0 ? 4 : 2)
    let f = font(36)
    let textOrigin = CGPoint(x: field.minX + 36, y: field.midY - 22)
    let typed = inserted > 0 && t < sendAt
    if typed {
        group(alpha: easeOut(inserted)) {
            textLeft(spoken, f, hex(0x111111), in: NSRect(x: textOrigin.x, y: textOrigin.y, width: field.width - 72, height: 50))
        }
    } else {
        textLeft("Сообщение", f, hex(0x9A9AA0), in: NSRect(x: textOrigin.x, y: textOrigin.y, width: 400, height: 50))
    }
    let cursorX = typed ? textOrigin.x + textSize(spoken, f).width + 4 : textOrigin.x - 4
    if Int(t * 2.2) % 2 == 0 || (t > pressAt && t < insertAt) {
        hex(0x2F6FDE).setFill()
        NSBezierPath(rect: CGRect(x: cursorX, y: field.midY - 24, width: 3, height: 48)).fill()
    }
}

func keycap(_ t: Double) {
    let pressed = t >= pressAt && t < releaseAt
    let press = pressed ? easeOut(prog(t, pressAt, pressAt + 0.1)) : (t >= releaseAt ? 1 - easeOut(prog(t, releaseAt, releaseAt + 0.15)) : 0)
    let cx = W / 2, top: CGFloat = 1420 + CGFloat(press) * 10
    let r = CGRect(x: cx - 160, y: top, width: 320, height: 200)
    if press > 0 {
        radialGlow(CGPoint(x: cx, y: r.midY), 260, hex(0x2F6FDE, CGFloat(0.45 * press)))
    }
    let edge = CGFloat(16 - 11 * press)
    rounded(CGRect(x: r.minX, y: r.minY + edge, width: r.width, height: r.height), 36, fill: hex(0x8E8E99))
    let path = NSBezierPath(roundedRect: r, xRadius: 36, yRadius: 36)
    NSGradient(colors: [hex(pressed ? 0xE4E6EC : 0xFBFBFD), hex(pressed ? 0xC9CCD6 : 0xDCDDE3)])!.draw(in: path, angle: -90)
    text("⌥", font(92, .medium), hex(0x2B2B30), y: r.minY + 18, centerX: cx, width: 300)
    text("option", font(36, .medium), hex(0x55555C), y: r.minY + 128, centerX: cx, width: 300)
    text("правый", font(34, .medium), hex(0x9CA3AF), y: 1650, centerX: cx, width: 400)
}

func hud(_ t: Double) {
    let listening = t < releaseAt
    let label = listening ? "Слушаю… отпусти, чтобы вставить" : "Распознаю…"
    let f = font(32, .medium)
    let size = textSize(label, f)
    let h: CGFloat = 76
    let w = size.width + 100
    let r = CGRect(x: W / 2 - w / 2, y: 1316, width: w, height: h)
    withShadow(30, 12, 0.5) { rounded(r, h / 2, fill: hex(0x1C1C1E, 0.96)) }
    let speaking = t > speakFrom && t < speakTo + 0.1
    let level = speaking ? CGFloat(0.45 + 0.55 * abs(sin(t * 11.0) * cos(t * 4.3))) : 0.25
    circle(CGPoint(x: r.minX + 42, y: r.midY), 8 + 8 * level, listening ? hex(0xFF453A) : hex(0x0A84FF))
    textLeft(label, f, .white, in: NSRect(x: r.minX + 72, y: r.midY - size.height / 2, width: size.width + 4, height: size.height))
}

func speech(_ t: Double) {
    let words = spoken.split(separator: " ")
    let shown = Int(Double(words.count) * prog(t, speakFrom, speakTo) + 0.999)
    guard shown > 0 else { return }
    group(alpha: visible(t, speakFrom, speakFrom + 0.15, 4.35, 4.55)) {
        let s = "«" + words.prefix(shown).joined(separator: " ") + (shown < words.count ? "" : "»")
        text(s, font(42, .regular, italic: true), hex(0xA5B4FC), y: 390)
    }
}

func demo(_ t: Double) {
    group(alpha: visible(t, 1.3, 1.65, 6.0, 6.3)) {
        caption(t, step: "ШАГ 1", title: "Зажми правый ⌥", a: 1.4, b: 1.65, c: 2.45, d: 2.6)
        caption(t, step: "ШАГ 2", title: "Говори", a: 2.6, b: 2.75, c: 4.3, d: 4.45)
        caption(t, step: "ШАГ 3", title: "Текст уже в поле", a: 4.45, b: 4.6, c: 9, d: 9)
        speech(t)
        let slide = easeOut(prog(t, 1.3, 1.75))
        group(alpha: slide, dy: CGFloat(1 - slide) * 90) { chatWindow(t) }
        group(alpha: visible(t, pressAt, pressAt + 0.15, insertAt, insertAt + 0.2)) { hud(t) }
        group(alpha: visible(t, 1.5, 1.7, 5.4, 5.7)) { keycap(t) }
    }
}

func symbolTile(_ name: String, center: CGPoint, color: NSColor) {
    let r = CGRect(x: center.x - 56, y: center.y - 56, width: 112, height: 112)
    rounded(r, 30, fill: color.withAlphaComponent(0.18), stroke: color.withAlphaComponent(0.55))
    let config = NSImage.SymbolConfiguration(pointSize: 52, weight: .semibold)
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
    let tinted = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    let s = symbol.size
    tinted.draw(in: CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

let benefits: [(String, NSColor, String, String)] = [
    ("bolt.fill", hex(0xFACC15), "Мгновенно", "фраза распознаётся за ~0.05 с"),
    ("scope", hex(0x2DD4BF), "Точно", "~5% ошибок на русском и казахском*"),
    ("textformat", hex(0x60A5FA), "С пунктуацией", "точки, запятые, заглавные буквы"),
    ("lock.fill", hex(0xA78BFA), "Локально", "без интернета — звук не покидает Mac"),
    ("leaf.fill", hex(0x4ADE80), "Легко", "~0.3 GB при диктовке, 24 MB в простое"),
]

func finale(_ t: Double) {
    let a = easeOut(prog(t, 6.15, 6.55))
    group(alpha: a, dy: CGFloat(1 - a) * 40) {
        icon(center: CGPoint(x: 230, y: 300), size: 150)
        textLeft("Ait", font(110, .heavy), .white, in: NSRect(x: 340, y: 222, width: 600, height: 140))
        textLeft("голосовой ввод на русском\nи казахском для Mac", font(38, .medium), hex(0xCBD5E1), in: NSRect(x: 344, y: 350, width: 700, height: 110))
    }
    for (i, item) in benefits.enumerated() {
        let start = 6.5 + Double(i) * 0.22
        let ba = easeOut(prog(t, start, start + 0.35))
        let y: CGFloat = 610 + CGFloat(i) * 190
        group(alpha: ba, dx: CGFloat(1 - ba) * 60) {
            symbolTile(item.0, center: CGPoint(x: 150, y: y + 56), color: item.1)
            textLeft(item.2, font(56, .bold), .white, in: NSRect(x: 240, y: y - 4, width: 800, height: 70))
            textLeft(item.3, font(38, .regular), hex(0xCBD5E1), in: NSRect(x: 240, y: y + 64, width: 800, height: 56))
        }
    }
    let ua = easeOut(prog(t, 7.75, 8.15))
    group(alpha: ua, dy: CGFloat(1 - ua) * 20) {
        pill("github.com/izzatillasapayev-eng/Ait", center: CGPoint(x: W / 2, y: 1640), f: font(40, .semibold),
             fill: hex(0xFFFFFF, 0.1), stroke: hex(0xFFFFFF, 0.3), color: .white, padX: 40, height: 92)
        text("Бесплатно · открытый код · * тест FLEURS, модель GigaAM", font(28, .regular), hex(0x8B95A7), y: 1720)
    }
}

func render(_ t: Double) {
    background(t)
    if t < 1.5 { intro(t) }
    if t > 1.25 && t < 6.35 { demo(t) }
    if t > 6.1 { finale(t) }
}

// MARK: - Вывод

func withContext(_ c: CGContext, _ body: () -> Void) {
    ctx = c
    c.translateBy(x: 0, y: H)
    c.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
    body()
    NSGraphicsContext.current = nil
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
let args = CommandLine.arguments

if args.count > 2, args[1] == "--stills" {
    let dir = URL(fileURLWithPath: args[2])
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for value in args.dropFirst(3) {
        let t = Double(value)!
        let c = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo)!
        withContext(c) { render(t) }
        let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(String(format: "frame-%05.2f.png", t)))
    }
    print("кадры: \(dir.path)")
    exit(0)
}

let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "Ait-promo.mp4")
try? FileManager.default.removeItem(at: out)
let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: Int(W),
    AVVideoHeightKey: Int(H),
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 10_000_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoExpectedSourceFrameRateKey: fps,
    ],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: Int(W),
    kCVPixelBufferHeightKey as String: Int(H),
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let frames = Int(duration * Double(fps))
for frame in 0..<frames {
    while !input.isReadyForMoreMediaData { usleep(2000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    guard let pb = buffer else { fatalError("нет буфера") }
    CVPixelBufferLockBaseAddress(pb, [])
    let c = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(W), height: Int(H), bitsPerComponent: 8,
                      bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: space, bitmapInfo: bitmapInfo)!
    withContext(c) { render(Double(frame) / Double(fps)) }
    CVPixelBufferUnlockBaseAddress(pb, [])
    adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "видео: \(out.path)" : "ошибка: \(String(describing: writer.error))")
