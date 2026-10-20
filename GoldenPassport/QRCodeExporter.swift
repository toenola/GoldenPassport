//
//  QRCodeExporter.swift
//  GoldenPassport
//
//  把已保存的 OTPAuth URL 导出为二维码，供其他 2FA App 扫描导入。
//
//  - 单个账号：标准 otpauth:// 二维码，几乎所有 2FA App 都支持
//  - 全部账号：Google Authenticator 的 otpauth-migration:// 批量迁移码，
//    Google Authenticator、Aegis、2FAS、Ente Auth 等支持一次扫描导入多个账号
//

import Cocoa
import CoreImage

struct OTPAccount {
    let type: String        // "totp" / "hotp"
    let label: String       // 解码后的 label，如 "GitHub:alice"
    let issuer: String
    let account: String
    let secret: Data
    let secretText: String  // 规范化后的 Base32 密钥，供手动输入密钥的 App 使用
    let algorithm: String   // "SHA1" / "SHA256" / "SHA512" / "MD5"
    let digits: Int
    let period: Int
    let counter: UInt64

    // otpauth://totp/Issuer:account?secret=BASE32&issuer=Issuer&digits=6&period=30
    init?(url: String) {
        guard let comps = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme?.lowercased() == "otpauth",
              let type = comps.host?.lowercased(),
              type == "totp" || type == "hotp" else {
            return nil
        }

        var params: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            params[item.name.lowercased()] = item.value ?? ""
        }
        guard let secretText = params["secret"],
              let secret = OTPAccount.base32Decode(secretText),
              !secret.isEmpty else {
            return nil
        }

        var label = comps.path
        if label.hasPrefix("/") {
            label.removeFirst()
        }
        var labelIssuer = ""
        var account = label
        if let colon = label.firstIndex(of: ":") {
            labelIssuer = String(label[..<colon]).trimmingCharacters(in: .whitespaces)
            account = String(label[label.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }

        self.type = type
        self.label = label
        self.issuer = params["issuer"].flatMap { $0.isEmpty ? nil : $0 } ?? labelIssuer
        self.account = account
        self.secret = secret
        self.secretText = secretText.uppercased().components(separatedBy: CharacterSet(charactersIn: " -=")).joined()
        self.algorithm = (params["algorithm"] ?? "SHA1").uppercased()
        self.digits = Int(params["digits"] ?? "") ?? 6
        self.period = Int(params["period"] ?? "") ?? 30
        self.counter = UInt64(params["counter"] ?? "") ?? 0
    }

    // RFC 4648 Base32，忽略大小写、空格、连字符和填充符
    static func base32Decode(_ text: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer: UInt64 = 0
        var bits = 0
        var bytes: [UInt8] = []
        for ch in text.uppercased() {
            if ch == "=" || ch == " " || ch == "-" {
                continue
            }
            guard let value = alphabet.firstIndex(of: ch) else {
                return nil
            }
            buffer = (buffer << 5) | UInt64(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> UInt64(bits)) & 0xFF))
            }
        }
        return Data(bytes)
    }
}

final class QRCodeExporter {
    /// Google Authenticator 自己导出时每个二维码放 10 个账号，保持一致，二维码不会过密
    static let migrationBatchSize = 10

    /// 单个账号要编码进二维码的内容：原样使用保存的 URL；
    /// 如果 URL 没有 label，其他 App 会显示成空白，这时用 GoldenPassport 里的名称补上
    static func exportURL(name: String, url: String) -> String? {
        guard let account = OTPAccount(url: url) else {
            return nil
        }
        if !account.label.isEmpty {
            return url
        }
        guard var comps = URLComponents(string: url) else {
            return nil
        }
        comps.path = "/" + name
        return comps.string
    }

    /// 生成 Google Authenticator 批量迁移二维码内容。
    /// 迁移格式不支持非 30 秒周期、非 6/8 位的账号，这些账号放进 skipped，需单个导出。
    static func migrationURLs(_ entries: [(key: String, value: String)],
                              batchSize: Int = migrationBatchSize) -> (urls: [String], skipped: [String]) {
        var params: [Data] = []
        var skipped: [String] = []
        for entry in entries {
            if let encoded = encodeOtpParameters(name: entry.key, url: entry.value) {
                params.append(encoded)
            } else {
                skipped.append(entry.key)
            }
        }
        if params.isEmpty {
            return ([], skipped)
        }

        let batchCount = (params.count + batchSize - 1) / batchSize
        let batchId = UInt64(arc4random_uniform(UInt32(Int32.max)))
        var urls: [String] = []
        for index in 0..<batchCount {
            var payload = Data()
            for p in params[(index * batchSize)..<min(params.count, (index + 1) * batchSize)] {
                payload.append(protoBytes(field: 1, p))
            }
            payload.append(protoVarint(field: 2, 1))                  // version
            payload.append(protoVarint(field: 3, UInt64(batchCount))) // batch_size
            payload.append(protoVarint(field: 4, UInt64(index)))      // batch_index
            payload.append(protoVarint(field: 5, batchId))            // batch_id

            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            let data = payload.base64EncodedString().addingPercentEncoding(withAllowedCharacters: allowed)!
            urls.append("otpauth-migration://offline?data=\(data)")
        }
        return (urls, skipped)
    }

    // MigrationPayload.OtpParameters，字段定义见 Google Authenticator 的 migration proto
    private static func encodeOtpParameters(name: String, url: String) -> Data? {
        guard let account = OTPAccount(url: url), account.period == 30 else {
            return nil
        }
        let algorithms: [String: UInt64] = ["SHA1": 1, "SHA256": 2, "SHA512": 3, "MD5": 4]
        let digitCounts: [Int: UInt64] = [6: 1, 8: 2]
        guard let algorithm = algorithms[account.algorithm],
              let digits = digitCounts[account.digits] else {
            return nil
        }

        var data = Data()
        data.append(protoBytes(field: 1, account.secret))
        data.append(protoBytes(field: 2, Data((account.account.isEmpty ? name : account.account).utf8)))
        if !account.issuer.isEmpty {
            data.append(protoBytes(field: 3, Data(account.issuer.utf8)))
        }
        data.append(protoVarint(field: 4, algorithm))
        data.append(protoVarint(field: 5, digits))
        data.append(protoVarint(field: 6, account.type == "hotp" ? 1 : 2))
        if account.type == "hotp" {
            data.append(protoVarint(field: 7, account.counter))
        }
        return data
    }

    private static func varint(_ value: UInt64) -> Data {
        var v = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 {
                byte |= 0x80
            }
            bytes.append(byte)
        } while v != 0
        return Data(bytes)
    }

    private static func protoVarint(field: UInt64, _ value: UInt64) -> Data {
        return varint(field << 3) + varint(value)
    }

    private static func protoBytes(field: UInt64, _ value: Data) -> Data {
        return varint(field << 3 | 2) + varint(UInt64(value.count)) + value
    }

    // MARK: - 图片

    /// 生成白底二维码图片，caption 不为空时在二维码下方标注账号名称
    static func qrCodeImage(for text: String, caption: String?) -> NSBitmapImageRep? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else {
            return nil
        }

        // 整数倍放大 + 关闭插值，保证模块边缘清晰
        let modules = Int(output.extent.width)
        let scale = max(4, 480 / max(modules, 1))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        guard let qr = CIContext(options: nil).createCGImage(scaled, from: scaled.extent) else {
            return nil
        }

        let margin = 4 * scale
        let captionHeight = (caption?.isEmpty ?? true) ? 0 : 64
        let width = qr.width + margin * 2
        let height = qr.height + margin * 2 + captionHeight

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.setFillColor(NSColor.white.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        cg.interpolationQuality = .none
        cg.draw(qr, in: CGRect(x: margin, y: margin + captionHeight, width: qr.width, height: qr.height))

        if let caption = caption, captionHeight > 0 {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingMiddle
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 24),
                .foregroundColor: NSColor.black,
                .paragraphStyle: style,
            ]
            let rect = NSRect(x: margin, y: margin / 2 + 8, width: width - margin * 2, height: captionHeight - 8)
            (caption as NSString).draw(in: rect, withAttributes: attrs)
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func pngData(_ rep: NSBitmapImageRep) -> Data? {
        return rep.representation(using: .png, properties: [:])
    }

    static func image(_ rep: NSBitmapImageRep) -> NSImage {
        let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        image.addRepresentation(rep)
        return image
    }

    /// 文件名里去掉路径分隔符等不安全字符
    static func safeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return cleaned.isEmpty ? "account" : cleaned
    }
}
