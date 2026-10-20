//
//  ExportQRCodeWindow.swift
//  GoldenPassport
//
//  导出二维码窗口：选择账号查看二维码，可复制、保存，或把全部账号批量导出为图片。
//

import Cocoa

class ExportQRCodeWindow: NSWindowController {
    private struct Item {
        let caption: String     // 显示在二维码下方的名称
        let payload: String     // 编码进二维码的内容
        let secret: String?     // 单个账号的 Base32 密钥，批量码为 nil
        let fileName: String
        let isBatch: Bool
    }

    private var popup: NSPopUpButton!
    private var imageView: NSImageView!
    private var captionLabel: NSTextField!
    private var hintLabel: NSTextField!
    private var copyTextButton: NSButton!
    private var copySecretButton: NSButton!
    private var copyButton: NSButton!
    private var saveButton: NSButton!
    private var exportAllButton: NSButton!

    private var items: [Item] = []
    private var skippedInBatch: [String] = []

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 540),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "导出二维码"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildUI()
        window.center()
    }

    private func buildUI() {
        let content = window!.contentView!

        popup = NSPopUpButton(frame: NSRect(x: 20, y: 496, width: 320, height: 26), pullsDown: false)
        popup.target = self
        popup.action = #selector(selectionChanged)
        content.addSubview(popup)

        imageView = NSImageView(frame: NSRect(x: 30, y: 188, width: 300, height: 300))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(imageView)

        captionLabel = makeLabel(frame: NSRect(x: 20, y: 158, width: 320, height: 22))
        captionLabel.font = NSFont.boldSystemFont(ofSize: 13)
        captionLabel.alignment = .center
        captionLabel.cell?.lineBreakMode = .byTruncatingMiddle
        content.addSubview(captionLabel)

        hintLabel = makeLabel(frame: NSRect(x: 20, y: 92, width: 320, height: 62))
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = NSColor.secondaryLabelColor
        hintLabel.cell?.wraps = true
        hintLabel.cell?.lineBreakMode = .byWordWrapping
        content.addSubview(hintLabel)

        // 没有扫码功能的 App 可以粘贴链接，或手动输入密钥
        copyTextButton = makeButton("复制链接", frame: NSRect(x: 14, y: 50, width: 112, height: 32), action: #selector(copyTextClicked))
        copySecretButton = makeButton("复制密钥", frame: NSRect(x: 124, y: 50, width: 112, height: 32), action: #selector(copySecretClicked))
        copyButton = makeButton("复制图片", frame: NSRect(x: 234, y: 50, width: 112, height: 32), action: #selector(copyClicked))
        saveButton = makeButton("保存图片…", frame: NSRect(x: 14, y: 14, width: 167, height: 32), action: #selector(saveClicked))
        exportAllButton = makeButton("全部导出图片…", frame: NSRect(x: 179, y: 14, width: 167, height: 32), action: #selector(exportAllClicked))
        content.addSubview(copyTextButton)
        content.addSubview(copySecretButton)
        content.addSubview(copyButton)
        content.addSubview(saveButton)
        content.addSubview(exportAllButton)
    }

    private func makeLabel(frame: NSRect) -> NSTextField {
        let label = NSTextField(frame: frame)
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        return label
    }

    private func makeButton(_ title: String, frame: NSRect, action: Selector) -> NSButton {
        let button = NSButton(frame: frame)
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        return button
    }

    /// 每次打开窗口前调用，读取最新的账号列表
    func reload() {
        let entries = DataManager.shared.allOTPAuthURLs()
        items = []
        for entry in entries {
            if let payload = QRCodeExporter.exportURL(name: entry.key, url: entry.value) {
                items.append(Item(caption: entry.key, payload: payload,
                                  secret: OTPAccount(url: payload)?.secretText,
                                  fileName: QRCodeExporter.safeFileName(entry.key), isBatch: false))
            }
        }
        let accountCount = items.count

        let migration = QRCodeExporter.migrationURLs(entries)
        skippedInBatch = migration.skipped
        for (index, url) in migration.urls.enumerated() {
            let title = "全部账号 · 批量迁移码 \(index + 1)/\(migration.urls.count)"
            items.append(Item(caption: title, payload: url, secret: nil,
                              fileName: "GoldenPassport-批量迁移码-\(index + 1)", isBatch: true))
        }

        popup.removeAllItems()
        for (index, item) in items.enumerated() {
            if index == accountCount && index > 0 {
                popup.menu?.addItem(NSMenuItem.separator())
            }
            let menuItem = NSMenuItem(title: item.caption, action: nil, keyEquivalent: "")
            menuItem.tag = index
            popup.menu?.addItem(menuItem)
        }

        let hasItems = !items.isEmpty
        popup.isEnabled = hasItems
        copyTextButton.isEnabled = hasItems
        copyButton.isEnabled = hasItems
        saveButton.isEnabled = hasItems
        exportAllButton.isEnabled = accountCount > 0
        if !hasItems {
            popup.addItem(withTitle: "没有可导出的账号")
        }
        selectionChanged()
    }

    private var selectedItem: Item? {
        guard let tag = popup.selectedItem?.tag, tag >= 0, tag < items.count, !items.isEmpty else {
            return nil
        }
        return items[tag]
    }

    @objc private func selectionChanged() {
        copySecretButton.isEnabled = selectedItem?.secret != nil
        guard let item = selectedItem else {
            imageView.image = nil
            captionLabel.stringValue = ""
            hintLabel.stringValue = "请先在状态栏菜单中添加认证信息。"
            return
        }

        imageView.image = QRCodeExporter.qrCodeImage(for: item.payload, caption: nil).map(QRCodeExporter.image)
        captionLabel.stringValue = item.caption

        copySecretButton.toolTip = "复制 Base32 密钥，用于在其他 App 中手动输入密钥"
        if item.isBatch {
            copyTextButton.title = "复制全部链接"
            copyTextButton.toolTip = "复制所有账号的 otpauth:// 链接，每行一个"
            var hint = "在 Google Authenticator 中选择「转移账号 → 导入账号」后逐张扫描；Aegis、2FAS、Ente Auth 等也支持此格式。"
            if !skippedInBatch.isEmpty {
                hint += "\n未包含（请单独导出）：" + skippedInBatch.joined(separator: "、")
            }
            hintLabel.stringValue = hint
        } else {
            copyTextButton.title = "复制链接"
            copyTextButton.toolTip = "复制 otpauth:// 链接，可粘贴到支持链接导入的 App"
            hintLabel.stringValue = "用其他 2FA App 扫描即可添加此账号。不能扫码时，可粘贴链接，或手动添加账号并粘贴密钥。\n二维码和密钥都能直接生成验证码，请勿外传。"
        }
    }

    private func selectedImage() -> NSBitmapImageRep? {
        guard let item = selectedItem else {
            return nil
        }
        return QRCodeExporter.qrCodeImage(for: item.payload, caption: item.caption)
    }

    @objc private func copyTextClicked() {
        guard let item = selectedItem else {
            return
        }
        // 批量码是 Google 专用格式，复制文本时改为所有账号的标准链接，每行一个，通用性更好
        let text = item.isBatch
            ? items.filter { !$0.isBatch }.map { $0.payload }.joined(separator: "\n")
            : item.payload
        copySensitiveText(text)
        flash(copyTextButton)
    }

    @objc private func copySecretClicked() {
        guard let secret = selectedItem?.secret else {
            return
        }
        copySensitiveText(secret)
        flash(copySecretButton)
    }

    /// 复制含密钥的文本，并标记为敏感内容，剪贴板历史类工具会跳过记录
    private func copySensitiveText(_ text: String) {
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string, concealed], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: concealed)
    }

    /// 按钮短暂显示「已复制」作为反馈
    private func flash(_ button: NSButton) {
        let title = button.title
        let done = "已复制 ✓"
        button.title = done
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if button.title == done {
                button.title = title
            }
        }
    }

    @objc private func copyClicked() {
        guard let rep = selectedImage() else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([QRCodeExporter.image(rep)])
        flash(copyButton)
    }

    @objc private func saveClicked() {
        guard let item = selectedItem, let rep = selectedImage(),
              let png = QRCodeExporter.pngData(rep) else {
            return
        }
        let savePanel = NSSavePanel()
        savePanel.title = "保存二维码"
        savePanel.allowedFileTypes = ["png"]
        savePanel.nameFieldStringValue = item.fileName + ".png"
        if savePanel.runModal() != NSApplication.ModalResponse.OK {
            return
        }
        do {
            try png.write(to: savePanel.url!)
        } catch {
            showAlert("保存失败：\(error.localizedDescription)", style: .warning)
        }
    }

    @objc private func exportAllClicked() {
        let openPanel = NSOpenPanel()
        openPanel.title = "选择导出文件夹"
        openPanel.prompt = "导出到此处"
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.allowsMultipleSelection = false
        if openPanel.runModal() != NSApplication.ModalResponse.OK {
            return
        }
        let folder = openPanel.url!

        var count = 0
        var failed: [String] = []
        for item in items where !item.isBatch {
            guard let rep = QRCodeExporter.qrCodeImage(for: item.payload, caption: item.caption),
                  let png = QRCodeExporter.pngData(rep) else {
                failed.append(item.caption)
                continue
            }
            do {
                try png.write(to: uniqueFileURL(in: folder, name: item.fileName), options: .withoutOverwriting)
                count += 1
            } catch {
                failed.append(item.caption)
            }
        }

        var message = "已导出 \(count) 个账号的二维码图片。"
        if !failed.isEmpty {
            message += "\n以下账号导出失败：" + failed.joined(separator: "、")
        }
        showAlert(message, style: failed.isEmpty ? .informational : .warning)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// 同名文件已存在时追加序号，避免覆盖
    private func uniqueFileURL(in folder: URL, name: String) -> URL {
        var url = folder.appendingPathComponent(name + ".png")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(index).png")
            index += 1
        }
        return url
    }

    private func showAlert(_ message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "确定")
        alert.beginSheetModal(for: window!, completionHandler: nil)
    }
}
