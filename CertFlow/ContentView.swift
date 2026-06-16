//
//  ContentView.swift
//  CertFlow
//
//  Created by GAO on 2026/6/15.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var fileItems: [P12FileItem] = []
    @State private var isDragging: Bool = false
    @State private var globalPassword: String = ""
    
    // 计算真正需要执行转换的任务数量
    var pendingTaskCount: Int {
        fileItems.filter { $0.status == .pending || $0.status == .failed }.count
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // 头部标题
            HStack {
                Text("🔐 CertFlow")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                if !fileItems.isEmpty {
                    Button("清空列表") {
                        fileItems.removeAll()
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                }
            }
            
            // 拖拽/导入区域（当列表为空时显示大框，不为空时变为顶部一个小条）
            if fileItems.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isDragging ? Color.blue : Color.gray.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .background(isDragging ? Color.blue.opacity(0.05) : Color.clear)
                    
                    VStack(spacing: 12) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("支持拖拽多个 .p12 文件到这里")
                            .font(.callout)
                            .foregroundColor(.gray)
                        Button("选择文件 (可多选)") { selectFiles() }
                            .buttonStyle(.bordered)
                    }
                }
                .frame(height: 180)
                .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
                    handleDroppedProviders(providers)
                }
            } else {
                // 快捷一键填充密码栏
                HStack {
                    Image(systemName: "arrow.down.doc.dash.fill")
                        .foregroundColor(.gray)
                    Text("批量设置密码:")
                        .font(.caption)
                    SecureField("输入后自动应用到下方所有文件", text: $globalPassword)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: globalPassword) { _, newValue in
                            for i in 0..<fileItems.count {
                                fileItems[i].password = newValue
                            }
                        }
                }
                .padding(8)
                .background(Color.black.opacity(0.03))
                .cornerRadius(6)
            }
            
            // 文件列表区域（支持多选、拖入和侧滑删除）
            if !fileItems.isEmpty {
                List {
                    ForEach($fileItems) { $item in
                        FileRowView(item: $item, onDelete: {
                            // 触发移除单个文件的回调
                            if let index = fileItems.firstIndex(where: { $0.id == item.id }) {
                                fileItems.remove(at: index)
                            }
                        })
                    }
                    // 激活 Mac 触控板双指左滑删除功能
                    .onDelete { indexSet in
                        fileItems.remove(atOffsets: indexSet)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 200)
                // 列表本身也支持继续拖入文件
                .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
                    handleDroppedProviders(providers)
                }
            }
            
            // 底部操作栏
            if !fileItems.isEmpty {
                Button(action: startBatchConversion) {
                    if pendingTaskCount > 0 {
                        Text("开始转换 (剩余 \(pendingTaskCount) 个任务)")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    } else {
                        Text("✅ 所有文件已转换完成")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pendingTaskCount == 0)
            }
        }
        .padding(20)
        .frame(width: 600, height: 480)
    }
    
    // 处理文件导入（过滤出 P12）
    func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url, url.pathExtension.lowercased() == "p12" {
                    DispatchQueue.main.async {
                        // 避免重复导入路径相同的文件
                        if !self.fileItems.contains(where: { $0.path == url.path }) {
                            self.fileItems.append(P12FileItem(path: url.path))
                        }
                    }
                }
            }
        }
        return true
    }
    
    // 打开系统文件选择器（多选）
    func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "p12")].compactMap({$0})
        
        if panel.runModal() == .OK {
            for url in panel.urls {
                if !self.fileItems.contains(where: { $0.path == url.path }) {
                    self.fileItems.append(P12FileItem(path: url.path))
                }
            }
        }
    }
    
    // 执行批量转换
    func startBatchConversion() {
        for index in 0..<fileItems.count {
            let currentItem = fileItems[index]
            
            guard currentItem.status == .pending || currentItem.status == .failed else {
                print("跳过无需重复工作的健康文件: \(currentItem.fileName)")
                continue // 直接跳过，进入下一个文件的循环
            }
            
            fileItems[index].status = .converting
            fileItems[index].logMessage = "⏳ 正在转换..."
            fileItems[index].certMeta = ""
            fileItems[index].networkStatus = ""
            
            Converter.convertAndVerify(item: currentItem) { finalStatus, message, meta, netStatus in
                DispatchQueue.main.async {
                    fileItems[index].status = finalStatus
                    fileItems[index].logMessage = message
                    fileItems[index].certMeta = meta
                    fileItems[index].networkStatus = netStatus
                }
            }
        }
    }
}

// MARK: - 子视图：单独的每一行文件组件
struct FileRowView: View {
    @Binding var item: P12FileItem
    var onDelete: () -> Void
    
    @State private var isHoveringRow: Bool = false
    @State private var isCommandKeyPressed: Bool = false
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // 1. 状态图标（错误时显示醒目的红色感叹号）
            statusIcon
            
            // 2. 文件名与状态日志
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName)
                    .fontWeight(.medium)
                    .foregroundColor(item.status == .failed ? .red.opacity(0.9) : .primary)
                
                // 标签栏
                HStack(spacing: 6) {
                    if !item.certMeta.isEmpty && item.status == .success {
                        Text(item.certMeta)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(getMetaTextColor(meta: item.certMeta))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(getMetaBackgroundColor(meta: item.certMeta))
                            .cornerRadius(3)
                    }
                    
                    if !item.networkStatus.isEmpty && item.status == .success {
                        Text(item.networkStatus)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(item.networkStatus.contains("成功") ? .blue : (item.networkStatus.contains("正在") ? .purple : .orange))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(item.networkStatus.contains("成功") ? Color.blue.opacity(0.1) : Color.black.opacity(0.04))
                            .cornerRadius(3)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .layoutPriority(1)
                
                if item.status == .failed {
                    // 如果是报错状态，嵌入一个干净的横向滚动视图
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(item.logMessage)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.red)
                            .textSelection(.enabled) // 依然支持鼠标划选复制
                        // 强制不换行，让整条长报错在一条水平线上无限延伸供滚动查看
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    // 限制滚动区域的最大宽度，防止把右侧的密码框和按钮挤出屏幕
                    .frame(maxWidth: 520, alignment: .leading)
                } else {
                    Group {
                        if isCommandKeyPressed && item.status == .success {
                            // 🚀 变身为纯粹的 Native 链接按钮，免疫任何 List/Scroll 拦截
                            Button(action: openInFinder) {
                                Text(item.logMessage)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.blue)
                                    .underline()
                                    .lineLimit(1)
                                    .truncationMode(.middle) // 按钮状态下优雅地在中段截断
                            }
                            .buttonStyle(.plain)
                        } else {
                            // 📅 常规状态：纯净的 ScrollView + 可划选 Text，无任何遮挡，完美滚动
                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(item.logMessage)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(item.status == .success ? .green : .gray)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                    }
                    // 放弃任何硬编码，使用弹性框架自动适配界面布局
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(item.status == .success ? "💡 鼠标左右滚动可查看完整路径\n💡 按住 ⌘ (Command) + 点击此路径，直接在 Finder 中高亮定位文件" : "")
                }
            }
            
            Spacer()
            
            // 3. 右侧动态操作区域
            /*
            if item.status == .failed {
                // 报错状态下的专属操作
                HStack(spacing: 8) {
                    // 快捷重新输入密码框（方便用户输错后直接在这里改）
                    SecureField("重试密码", text: $item.password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .controlSize(.small)
                    
                    // 悬停一键复制完整错误日志，方便去 Google 查
                    if isHovering {
                        Button(action: {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(item.logMessage, forType: .string)
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: "doc.on.doc")
                                Text("复制报错")
                            }
                            .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                        .help("复制完整错误日志")
                    }
                }
            } else if item.status == .success {
                // 成功状态下的操作：悬停复制 PEM 路径
                if isHovering {
                    Button(action: {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(item.logMessage, forType: .string)
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                            Text("复制路径")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("复制生成的 PEM 完整路径")
                }
            } else {
                // 等待或转换状态下：常规密码框
                SecureField("密码", text: $item.password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
             */
            HStack(spacing: 8) {
                if item.status == .failed {
                    SecureField("重试密码", text: $item.password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .controlSize(.small)
                } else if item.status == .pending {
                    SecureField("密码", text: $item.password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .controlSize(.small)
                }
                
                // 独立删除按钮：只有鼠标悬停在这一行时，并且文件没在“转换中”才会显示
                if isHoveringRow && item.status != .converting {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.red.opacity(0.8))
                            .padding(4)
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("从列表中移除该文件")
                }
            }
            .frame(width: 110, alignment: .trailing) // 固定右侧操作区宽度，防止图标抖动
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        // 增加背景轻微色块衬托报错行
        .background(item.status == .failed ? Color.red.opacity(0.02) : Color.clear)
        .cornerRadius(6)
        .onHover { hovering in
            self.isHoveringRow = hovering
            if hovering {
                self.isCommandKeyPressed = NSEvent.modifierFlags.contains(.command)
            }
        }
        // 挂载全局键盘修饰键监听器
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                // 动态捕捉用户是否按下了 Command 键
                withAnimation(.easeInOut(duration: 0.15)) {
                    self.isCommandKeyPressed = event.modifierFlags.contains(.command)
                }
                return event
            }
        }
    }
    
    private func openInFinder() {
        let cleanPath = item.logMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileURL = URL(fileURLWithPath: cleanPath)
        
        if FileManager.default.fileExists(atPath: cleanPath) {
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        } else {
            let directoryURL = fileURL.deletingLastPathComponent()
            DispatchQueue.main.async {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directoryURL.path)
            }
        }
    }

    
    // 状态图标判断
    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
            case .pending:
                Image(systemName: "lock.rectangle")
                    .foregroundColor(.gray)
                    .font(.title3)
            case .converting:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20, height: 20)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title3)
            case .failed:
                // 报错时闪烁或显示红色的警告图标
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(.title3)
        }
    }
    
    // MARK: - UI 动态色彩辅助函数
    func getMetaTextColor(meta: String) -> Color {
        if meta.contains("❌") { return .red }
        if meta.contains("⚠️") || meta.contains("🚨") { return .orange }
        return .secondary
    }
    
    func getMetaBackgroundColor(meta: String) -> Color {
        if meta.contains("❌") { return .red.opacity(0.1) }
        if meta.contains("⚠️") || meta.contains("🚨") { return .orange.opacity(0.1) }
        return Color.gray.opacity(0.1)
    }
}

// 仅支持单个文件
/*
struct ContentView: View {
    @State private var p12Path: String = ""
    @State private var password: String = ""
    @State private var statusMessage: String = "将 .p12 文件拖到虚线区域，或点击选择"
    @State private var isSuccess: Bool = false
    @State private var isDragging: Bool = false
    @State private var isHoveringStatus: Bool = false
    
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("🔐 CertFlow")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Spacer()
                Text("v1.0.0")
                    .font(.caption).foregroundColor(.gray)
            }
            
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isDragging ? Color.blue : Color.gray.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(isDragging ? Color.blue.opacity(0.05) : Color.clear)
                    .animation(.easeInOut, value: isDragging)
                
                VStack(spacing: 12) {
                    Image(systemName: p12Path.isEmpty ? "doc.badge.plus" : "key.icloud.fill")
                        .font(.system(size: 36))
                        .foregroundColor(p12Path.isEmpty ? .gray : .blue)
                    
                    if p12Path.isEmpty {
                        Text("拖拽 P12 文件到这里")
                            .font(.callout)
                            .foregroundColor(.gray)
                    } else {
                        Text(URL(fileURLWithPath: p12Path).lastPathComponent)
                            .font(.callout)
                            .fontWeight(.semibold)
                    }
                    
                    Button("选择文件") {
                        
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
            .frame(height: 140)
            // 监听拖拽手势
            .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
                if let provider = providers.first {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url = url, url.pathExtension.lowercased() == "p12" {
                            DispatchQueue.main.async {
                                self.p12Path = url.path
                                self.statusMessage = "已加载：\(url.lastPathComponent)"
                            }
                        }
                    }
                    return true
                }
                return false
            }
            
            // 密码输入框
            VStack(alignment: .leading, spacing: 6) {
                Text("P12 导出密码 (若无请留空):")
                    .font(.caption)
                    .foregroundColor(.gray)
                SecureField("Enter password...", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !p12Path.isEmpty { startConversion() } }
            }
            
            // 转换按钮
            Button(action: startConversion) {
                Text("转换至 PEM")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(p12Path.isEmpty)
            
            Divider()
            
            ZStack(alignment: .topTrailing) {
                ScrollView {
                    Text(statusMessage)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(isSuccess ? .green : (statusMessage.contains("失败") ? .red : .gray))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.trailing, 30) // 给复制按钮留出空间
                        .textSelection(.enabled) // 开启 macOS 原生的文本划选、高亮和复制功能
                }
                .frame(height: 60)
                .padding(8)
                .background(Color.black.opacity(0.03))
                .cornerRadius(8)
                .contextMenu {
                    Button(action: { copyAction() }) {
                        Text("复制有用信息")
                        Image(systemName: "doc.on.doc")
                    }
                }
                if isHoveringStatus && (isSuccess || statusMessage.contains("失败")) {
                    Button(action: { copyAction() }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                            .padding(6)
                            .background(Color(NSColor.windowBackgroundColor))
                            .cornerRadius(4)
                            .shadow(radius: 1)
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .help("复制路径或错误日志")
                }
            }
            .onHover { hovering in
                self.isHoveringStatus = hovering
            }
        }
        .padding(24)
        .frame(width: 480, height: 420)
    }
    
    // MARK: - 复制核心逻辑
    
    func copyAction() {
        if isSuccess {
            // 如果成功，我们只提取并复制最后那段单纯的文件路径
            if let pathRange = statusMessage.range(of: "/", options: .backwards) {
                let startIndex = pathRange.lowerBound
                let purePath = String(statusMessage[startIndex...])
                copyToClipboard(text: purePath)
                showTemporaryToast(message: "📋 路径已复制！")
            } else {
                copyToClipboard(text: statusMessage)
            }
        } else {
            // 如果失败，复制完整的报错信息，方便去搜索引擎查错
            copyToClipboard(text: statusMessage)
            showTemporaryToast(message: "📋 错误日志已复制！")
        }
    }
    
    // 复制文字到系统剪贴板
    func copyToClipboard(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    
    // 复制成功后在状态栏闪烁提示一下
    func showTemporaryToast(message: String) {
        let oldMessage = self.statusMessage
        self.statusMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // 如果用户没开始新转换，就恢复原状
            if self.statusMessage == message {
                self.statusMessage = oldMessage
            }
        }
    }
    
    // 调用系统文件选择器
    func selectFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "p12")].compactMap({$0})
        
        if panel.runModal() == .OK {
            self.p12Path = panel.url?.path ?? ""
            self.statusMessage = "已加载：\(panel.url?.lastPathComponent ?? "")"
        }
    }
    
    // 执行转换
    func startConversion() {
        statusMessage = "⏳ 正在转换中..."
        Converter.runP12ToPem(p12Path: p12Path, password: password) { success, message in
            DispatchQueue.main.async {
                self.isSuccess = success
                self.statusMessage = message
            }
        }
    }
}
*/

#Preview {
    ContentView()
}
